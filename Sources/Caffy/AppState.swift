import Foundation
import ServiceManagement
import UserNotifications

enum DeactivationReason {
    case user, timer, lowBattery, overheated

    var notificationText: String? {
        switch self {
        case .user: nil
        case .timer: "已到设定时长，已恢复休眠"
        case .lowBattery: "电量过低，已恢复休眠"
        case .overheated: "设备温度过高，已恢复休眠"
        }
    }

    var blockedText: String? {
        switch self {
        case .lowBattery: "电量过低，无法开启"
        case .overheated: "设备温度过高，无法开启"
        default: nil
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let durationChoices: [(minutes: Int, title: String)] = [
        (30, "30 分钟"), (60, "1 小时"), (120, "2 小时"), (240, "4 小时"), (0, "不限时"),
    ]
    static let batteryThresholdChoices = [10, 20, 30, 50]

    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var endDate: Date?
    @Published private(set) var helperStatus: SMAppService.Status
    @Published private(set) var launchAtLogin: Bool
    @Published var lastError: String?

    @Published var durationMinutes: Int {
        didSet { defaults.set(durationMinutes, forKey: "durationMinutes") }
    }
    @Published var lowBatteryGuard: Bool {
        didSet { defaults.set(lowBatteryGuard, forKey: "lowBatteryGuard"); checkGuards() }
    }
    @Published var batteryThreshold: Int {
        didSet { defaults.set(batteryThreshold, forKey: "batteryThreshold"); checkGuards() }
    }
    @Published var thermalGuard: Bool {
        didSet { defaults.set(thermalGuard, forKey: "thermalGuard"); checkGuards() }
    }

    let helper = HelperClient()
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    init() {
        defaults.register(defaults: [
            "durationMinutes": 0,
            "lowBatteryGuard": true,
            "batteryThreshold": 20,
            "thermalGuard": true,
        ])
        durationMinutes = defaults.integer(forKey: "durationMinutes")
        lowBatteryGuard = defaults.bool(forKey: "lowBatteryGuard")
        batteryThreshold = defaults.integer(forKey: "batteryThreshold")
        thermalGuard = defaults.bool(forKey: "thermalGuard")
        helperStatus = helper.status
        launchAtLogin = SMAppService.mainApp.status == .enabled

        helper.onInterrupted = { [weak self] in self?.helperDidRestart() }
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkGuards() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - 开关

    func toggle() {
        if isActive {
            deactivate(.user)
        } else {
            activate()
        }
    }

    func activate() {
        guard !isBusy else { return }
        lastError = nil
        if let reason = guardViolation() {
            lastError = reason.blockedText
            return
        }
        guard ensureHelperInstalled() else { return }

        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await helper.setSleepDisabled(true)
                isActive = true
                endDate = durationMinutes > 0 ? Date().addingTimeInterval(TimeInterval(durationMinutes * 60)) : nil
                requestNotificationPermission()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func deactivate(_ reason: DeactivationReason) {
        guard isActive else { return }
        isActive = false
        endDate = nil
        Task {
            do {
                try await helper.setSleepDisabled(false)
            } catch {
                lastError = error.localizedDescription
            }
        }
        if let text = reason.notificationText {
            notify(text)
        }
    }

    func prepareForTermination() {
        guard isActive else { return }
        helper.restoreSleepSynchronously()
    }

    // MARK: - 辅助程序

    /// 返回 helper 当前是否可用；不可用时尝试注册，并在需要时引导用户去系统设置批准。
    @discardableResult
    func ensureHelperInstalled() -> Bool {
        refreshHelperStatus()
        switch helperStatus {
        case .enabled:
            return true
        case .requiresApproval:
            lastError = "请在「系统设置 › 通用 › 登录项与扩展」中允许 Caffy"
            helper.openApprovalSettings()
            return false
        default:
            do {
                try helper.register()
            } catch {
                lastError = "安装辅助程序失败：\(error.localizedDescription)"
            }
            refreshHelperStatus()
            if helperStatus == .requiresApproval {
                lastError = "请在「系统设置 › 通用 › 登录项与扩展」中允许 Caffy，然后再次开启"
                helper.openApprovalSettings()
            }
            return helperStatus == .enabled
        }
    }

    func uninstallHelper() {
        deactivate(.user)
        Task {
            do {
                try await helper.unregister()
            } catch {
                lastError = "卸载辅助程序失败：\(error.localizedDescription)"
            }
            refreshHelperStatus()
        }
    }

    func refreshHelperStatus() {
        helperStatus = helper.status
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "设置登录时启动失败：\(error.localizedDescription)"
        }
        refreshHelperStatus()
    }

    private func helperDidRestart() {
        // helper 重启时会把休眠恢复，若 App 仍处于开启状态则重新下发。
        guard isActive else { return }
        Task {
            do {
                try await helper.setSleepDisabled(true)
            } catch {
                isActive = false
                endDate = nil
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - 定时与保护

    private func tick() {
        if isActive, let endDate, Date() >= endDate {
            deactivate(.timer)
            return
        }
        checkGuards()
    }

    private func checkGuards() {
        guard isActive, let reason = guardViolation() else { return }
        deactivate(reason)
    }

    private func guardViolation() -> DeactivationReason? {
        if thermalGuard, PowerMonitor.isOverheated {
            return .overheated
        }
        if lowBatteryGuard, let battery = PowerMonitor.battery(),
           !battery.onACPower, battery.percent <= batteryThreshold {
            return .lowBattery
        }
        return nil
    }

    // MARK: - 通知

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Caffy"
        content.body = text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
