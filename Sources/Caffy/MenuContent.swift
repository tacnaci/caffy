import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(statusText)

        if let error = state.lastError {
            Text("⚠️ \(error)")
        }

        Button(state.isActive ? "关闭防休眠" : "开启防休眠") {
            state.toggle()
        }
        .keyboardShortcut("t")
        .disabled(state.isBusy)

        Picker("开启时长", selection: $state.durationMinutes) {
            ForEach(AppState.durationChoices, id: \.minutes) { choice in
                Text(choice.title).tag(choice.minutes)
            }
        }

        Divider()

        Toggle("过热时自动恢复休眠", isOn: $state.thermalGuard)
        Toggle("低电量时自动恢复休眠", isOn: $state.lowBatteryGuard)
        Picker("低电量阈值", selection: $state.batteryThreshold) {
            ForEach(AppState.batteryThresholdChoices, id: \.self) { value in
                Text("\(value)%").tag(value)
            }
        }
        .disabled(!state.lowBatteryGuard)

        Divider()

        Toggle("登录时启动", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }
        ))

        Menu("辅助程序") {
            Text(helperStatusText)
            switch state.helperStatus {
            case .enabled:
                Button("卸载辅助程序") { state.uninstallHelper() }
            case .requiresApproval:
                Button("打开系统设置以批准…") { state.helper.openApprovalSettings() }
            default:
                Button("安装辅助程序") { state.ensureHelperInstalled() }
            }
            Button("刷新状态") { state.refreshHelperStatus() }
        }

        Divider()

        Button("关于 Caffy") {
            // 菜单栏 App 默认不在前台，先激活，否则关于窗口可能被其他窗口挡住
            if #available(macOS 14, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        Button("退出 Caffy") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        guard state.isActive else { return "防休眠：已关闭" }
        guard let endDate = state.endDate else { return "防休眠：已开启（不限时）" }
        return "防休眠：已开启，至 \(endDate.formatted(date: .omitted, time: .shortened))"
    }

    private var helperStatusText: String {
        switch state.helperStatus {
        case .enabled: "状态：已启用"
        case .requiresApproval: "状态：等待在系统设置中批准"
        case .notRegistered: "状态：未安装"
        case .notFound: "状态：未找到（请确认 App 位于 /Applications）"
        @unknown default: "状态：未知"
        }
    }
}
