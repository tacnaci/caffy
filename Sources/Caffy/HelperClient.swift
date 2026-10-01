import Foundation
import ServiceManagement

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
        connection?.invalidate()
        connection = nil
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
            let proxy = connection.remoteObjectProxyWithErrorHandler { done(.failure($0)) }
            guard let helper = proxy as? CaffyHelperProtocol else {
                return done(.failure(HelperError.unavailable))
            }
            body(helper, done)
        }
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
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "无法连接辅助程序"
        case .unsigned: "App 未使用开发者证书签名，无法与辅助程序通信"
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
