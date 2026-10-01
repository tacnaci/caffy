import Foundation
import os
import ServiceManagement

private let log = Logger(subsystem: HelperConstants.appBundleID, category: "helper-client")

/// 负责安装 root helper（SMAppService）并通过 XPC 与之通信。
final class HelperClient {
    private let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    private var connection: NSXPCConnection?

    /// helper 重启（崩溃后由 launchd 拉起）时回调，App 需重新下发状态。
    var onInterrupted: (() -> Void)?

    var status: SMAppService.Status { service.status }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        resetConnection()
        try await service.unregister()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        let message: String? = try await call { proxy, done in
            proxy.setSleepDisabled(disabled) { done(.success($0)) }
        }
        if let message { throw HelperError.helper(message) }
    }

    func isSleepDisabled() async throws -> Bool {
        try await call { proxy, done in
            proxy.isSleepDisabled { done(.success($0)) }
        }
    }

    /// 确认正在运行的 helper 就是本 App 包内的那份二进制。
    ///
    /// App 覆盖安装后旧 helper 仍在运行，统一用注销再注册的方式替换：注销时 launchd 会停掉旧 helper
    /// （它在 SIGTERM 时恢复休眠），注册后拉起包内的新 helper。实测系统会保留用户的批准，无需再次允许。
    /// 不通过 XPC 让旧 helper 自行退出，是因为升级后有时联系不上旧 helper，而这条路径两种情况都能处理。
    func ensureCurrentVersion() async throws {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CaffyHelper").path
        guard let expected = CodeSigning.cdhash(atPath: bundled) else { throw HelperError.unavailable }
        let running = try? await codeIdentity()
        if running == expected { return }

        log.notice("helper outdated (running \(running ?? "unreachable", privacy: .public), bundled \(expected, privacy: .public)), re-registering")
        try await unregister()
        try await registerWithRetry()
        guard status == .enabled else { throw HelperError.needsApproval }

        // 新 helper 由 launchd 拉起，可能需要几秒
        for _ in 0..<24 {
            resetConnection()
            try await Task.sleep(nanoseconds: 500_000_000)
            if (try? await codeIdentity()) == expected {
                log.notice("helper updated")
                return
            }
        }
        throw HelperError.upgradeFailed
    }

    /// 刚注销后立即注册可能因系统尚未处理完而失败，稍等重试。
    private func registerWithRetry() async throws {
        var lastError: Error?
        for _ in 0..<10 {
            do {
                try register()
                return
            } catch {
                lastError = error
                log.error("register failed: \(error.localizedDescription, privacy: .public)")
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError ?? HelperError.unavailable
    }

    private func codeIdentity() async throws -> String? {
        try await call { proxy, done in
            proxy.codeIdentity { done(.success($0)) }
        }
    }

    /// App 退出时同步通知 helper 恢复休眠（helper 在连接断开时也会兜底）。
    func restoreSleepSynchronously() {
        guard let connection else { return }
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { _ in } as? CaffyHelperProtocol
        proxy?.setSleepDisabled(false) { _ in }
        connection.invalidate()
        self.connection = nil
    }

    private func call<T>(_ body: @escaping (CaffyHelperProtocol, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let connection = try currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let done: (Result<T, Error>) -> Void = { result in
                if once.claim() { continuation.resume(with: result) }
            }
            // 对端不认识该方法（旧版 helper）时可能既不回复也不报错
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { done(.failure(HelperError.timeout)) }
            let proxy = connection.remoteObjectProxyWithErrorHandler { done(.failure($0)) }
            guard let helper = proxy as? CaffyHelperProtocol else {
                return done(.failure(HelperError.unavailable))
            }
            body(helper, done)
        }
    }

    private func resetConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func currentConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        guard let requirement = CodeSigning.requirement(forIdentifier: HelperConstants.helperBundleID) else {
            throw HelperError.unsigned
        }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CaffyHelperProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.onInterrupted?() }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                if self?.connection === connection { self?.connection = nil }
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

enum HelperError: LocalizedError {
    case unavailable
    case unsigned
    case timeout
    case needsApproval
    case upgradeFailed
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "无法连接辅助程序"
        case .unsigned: "App 未使用开发者证书签名，无法与辅助程序通信"
        case .timeout: "辅助程序无响应"
        case .needsApproval: "辅助程序已更新，请在「系统设置 › 通用 › 登录项与扩展」中重新允许 Caffy"
        case .upgradeFailed: "辅助程序更新失败，请重启电脑后再试"
        case .helper(let message): message
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
