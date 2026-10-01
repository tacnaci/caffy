import Foundation
import os

let log = Logger(subsystem: HelperConstants.helperBundleID, category: "helper")

/// 通过 pmset 切换系统的 SleepDisabled 开关（禁止一切休眠，包括合盖）。
/// 只要还有任一客户端连接持有"禁止休眠"，就保持禁止；全部断开后自动恢复。
final class SleepController {
    private let queue = DispatchQueue(label: "com.caffy.helper.sleep")
    private var holders = Set<ObjectIdentifier>()

    func setDisabled(_ disabled: Bool, by client: ObjectIdentifier) -> String? {
        queue.sync {
            let wasHolder = holders.contains(client)
            if disabled {
                holders.insert(client)
            } else {
                holders.remove(client)
            }
            let error = apply()
            if error != nil {
                // pmset 失败时回滚，保持 holders 与系统实际状态一致
                if wasHolder {
                    holders.insert(client)
                } else {
                    holders.remove(client)
                }
            }
            return error
        }
    }

    /// 客户端连接断开（App 退出或崩溃）时调用。
    func release(_ client: ObjectIdentifier) {
        queue.sync {
            guard holders.remove(client) != nil else { return }
            log.notice("client disconnected while holding sleep assertion; restoring sleep")
            _ = apply()
        }
    }

    /// 无条件恢复休眠。helper 启动和退出时调用。
    func reset() {
        queue.sync {
            holders.removeAll()
            _ = apply()
        }
    }

    private func apply() -> String? {
        let disable = !holders.isEmpty
        do {
            _ = try Self.pmset(["-a", "disablesleep", disable ? "1" : "0"])
            log.notice("disablesleep = \(disable ? 1 : 0, privacy: .public)")
            return nil
        } catch {
            log.error("pmset failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    private struct PmsetError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func pmset(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw PmsetError(message: "pmset \(arguments.joined(separator: " ")) failed: \(output)")
        }
        return output
    }
}
