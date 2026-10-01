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
    /// 正在运行的 helper 的 cdhash（启动时计算），App 据此判断 helper 是否为自己包内的版本。
    func codeIdentity(reply: @escaping (String?) -> Void)
}

enum CodeSigning {
    /// 当前进程签名所属的 Team ID；未签名或 ad-hoc 签名时为 nil。
    static func currentTeamID() -> String? {
        guard let code = staticSelf() else { return nil }
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        return signingInfo(code, flags)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// 当前进程磁盘上可执行文件的 cdhash。文件被覆盖后会读到新文件，所以只应在启动时调用。
    static func currentCDHash() -> String? {
        staticSelf().flatMap(cdhash(of:))
    }

    static func cdhash(atPath path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        return cdhash(of: code)
    }

    private static func cdhash(of code: SecStaticCode) -> String? {
        guard let data = signingInfo(code, [])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func staticSelf() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    private static func signingInfo(_ code: SecStaticCode, _ flags: SecCSFlags) -> [String: Any]? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }

    /// 要求对端是同一 Team 签名、且 bundle identifier 匹配的代码。
    static func requirement(forIdentifier identifier: String) -> String? {
        guard let team = currentTeamID() else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
