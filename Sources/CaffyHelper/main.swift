import Foundation

let controller = SleepController()
// 必须在启动时计算：App 升级后磁盘上的文件会被替换，届时再算会得到新版本的值
let launchedCDHash = CodeSigning.currentCDHash()

final class HelperService: NSObject, CaffyHelperProtocol {
    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping (String?) -> Void) {
        guard let connection else { return reply("connection lost") }
        reply(controller.setDisabled(disabled, by: ObjectIdentifier(connection)))
    }

    func version(reply: @escaping (String) -> Void) {
        reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
    }

    func codeIdentity(reply: @escaping (String?) -> Void) {
        reply(launchedCDHash)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let id = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: CaffyHelperProtocol.self)
        connection.exportedObject = HelperService(connection: connection)
        connection.invalidationHandler = { controller.release(id) }
        connection.interruptionHandler = { controller.release(id) }
        connection.resume()
        return true
    }
}

// 启动时复位：防止上次 App 与 helper 同时异常退出（如断电）后残留 disablesleep=1。
controller.reset()

// launchd 停止 helper（注销、关机）时同样复位。
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    controller.reset()
    exit(0)
}
termSource.resume()

guard let requirement = CodeSigning.requirement(forIdentifier: HelperConstants.appBundleID) else {
    log.fault("helper is not signed with a team identity; refusing to serve")
    exit(1)
}

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.setConnectionCodeSigningRequirement(requirement)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
log.notice("helper started")
dispatchMain()
