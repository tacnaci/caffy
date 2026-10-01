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
        didSet {
            defaults.set(durationMinutes, forKey: "durationMinutes")
            // 开启期间修改时长立即生效，从开启时刻重新计算
            updateEndDate()
            tick()
        }
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
    private var helperVerified = false
    private var helperVerification: Task<Void, Error>?
    private var activatedAt: Date?
    /// 开启期间阻止 App Nap，避免后台时定时与电量检查被系统推迟
    private var activity: NSObjectProtocol?

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

        helper.onConnectionLost = { [weak self] in self?.helperConnectionLost() }
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkGuards() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        // 覆盖安装新版本后尽早替换掉仍在运行的旧 helper
        if helperStatus == .enabled {
            Task {
                do {
                    try await verifyHelper()
                } catch {
                    lastError = error.localizedDescription
                }
            }
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
                try await verifyHelper()
                try await helper.setSleepDisabled(true)
                markActive()
                requestNotificationPermission()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func deactivate(_ reason: DeactivationReason) {
        guard isActive, !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            await performDeactivate(reason)
        }
    }

    /// 只有 helper 确认恢复休眠后才切换为关闭；失败时保持开启状态，
    /// 由用户或下一次定时检查重试，避免界面显示已关闭而系统仍禁止休眠。
    @discardableResult
    private func performDeactivate(_ reason: DeactivationReason) async -> Bool {
        do {
            try await helper.setSleepDisabled(false)
        } catch {
            lastError = "关闭防休眠失败：\(error.localizedDescription)"
            return false
        }
        markInactive()
        if let text = reason.notificationText {
            notify(text)
        }
        return true
    }

    func prepareForTermination() {
        // 断开连接即可：helper 检测到连接断开会自动恢复休眠，不在退出流程里同步等待它
        helper.disconnect()
    }

    private func markActive() {
        isActive = true
        activatedAt = Date()
        updateEndDate()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Caffy 定时与电量保护检查")
        }
    }

    private func markInactive() {
        isActive = false
        activatedAt = nil
        endDate = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func updateEndDate() {
        guard isActive, let activatedAt else { return }
        endDate = durationMinutes > 0 ? activatedAt.addingTimeInterval(TimeInterval(durationMinutes * 60)) : nil
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
        guard !isBusy else { return }
        isBusy = true
        helperVerified = false
        Task {
            defer { isBusy = false }
            if isActive {
                await performDeactivate(.user)
            }
            do {
                try await helper.unregister()
                // helper 被停止时会恢复休眠
                markInactive()
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

    /// 确认 helper 与本 App 同版本，多处同时调用时共用同一次检查。
    private func verifyHelper() async throws {
        if helperVerified { return }
        if let helperVerification { return try await helperVerification.value }
        let task = Task { try await helper.ensureCurrentVersion() }
        helperVerification = task
        defer { helperVerification = nil }
        do {
            try await task.value
            helperVerified = true
        } catch {
            refreshHelperStatus()
            throw error
        }
    }

    /// 与 helper 的连接意外中断或失效（helper 崩溃重启、被停用等），helper 那边已恢复休眠。
    /// 若 App 仍处于开启状态则重新下发；helper 已不可用时同步为关闭，避免界面与实际不符。
    private func helperConnectionLost() {
        guard isActive else { return }
        Task {
            do {
                try await helper.setSleepDisabled(true)
            } catch {
                markInactive()
                refreshHelperStatus()
                lastError = "辅助程序已停止，防休眠已关闭：\(error.localizedDescription)"
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
