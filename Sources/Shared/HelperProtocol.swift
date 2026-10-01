import Foundation
import Security

enum HelperConstants {
    static let machServiceName = "com.caffy.helper"
    static let daemonPlistName = "com.caffy.helper.plist"
    static let appBundleID = "com.caffy.app"
    static let helperBundleID = "com.caffy.helper"
}

/// App 与 root helper 之间的 XPC 接口。
@objc protocol CaffyHelperProtocol {
    /// 开启/关闭"禁止系统休眠"。reply 为 nil 表示成功，否则为错误描述。
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (String?) -> Void)
    /// 读取当前系统的 SleepDisabled 状态。
    func isSleepDisabled(reply: @escaping (Bool) -> Void)
    func version(reply: @escaping (String) -> Void)
}

enum CodeSigning {
    /// 当前进程签名所属的 Team ID；未签名或 ad-hoc 签名时为 nil。
    static func currentTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// 要求对端是同一 Team 签名、且 bundle identifier 匹配的代码。
    static func requirement(forIdentifier identifier: String) -> String? {
        guard let team = currentTeamID() else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
