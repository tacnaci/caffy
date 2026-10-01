import Combine
import Sparkle

/// 封装 Sparkle：菜单中的「检查更新」与后台定时检查
@MainActor
final class Updater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    /// 定时检查发现了新版本。菜单栏 App 通常不在前台，Sparkle 不会抢焦点弹窗，由菜单项提示用户
    @Published private(set) var hasPendingUpdate = false

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
    }

    /// 已有更新窗口时（例如定时检查发现的）会把它带到前台
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}

// Sparkle 在主线程回调这些方法，但协议本身未标注 @MainActor
extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            if !userInitiated {
                hasPendingUpdate = true
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { hasPendingUpdate = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { hasPendingUpdate = false }
    }
}
