import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater: Updater
    @ObservedObject var awakeCommand: AwakeCommand

    var body: some View {
        Text(statusText)

        if let error = state.lastError {
            Text(verbatim: "⚠️ \(error)")
        }

        Button(state.isActive ? String(localized: "Turn Off Keep Awake") : String(localized: "Turn On Keep Awake")) {
            state.toggle()
        }
        .keyboardShortcut("t")
        .disabled(state.isBusy)

        Picker("Duration", selection: $state.durationMinutes) {
            ForEach(AppState.durationChoices, id: \.minutes) { choice in
                Text(choice.title).tag(choice.minutes)
            }
        }

        Divider()

        Toggle("Restore Sleep When Overheated", isOn: $state.thermalGuard)
        Toggle("Restore Sleep on Low Battery", isOn: $state.lowBatteryGuard)
        Picker("Low Battery Threshold", selection: $state.batteryThreshold) {
            ForEach(AppState.batteryThresholdChoices, id: \.self) { value in
                Text(verbatim: "\(value)%").tag(value)
            }
        }
        .disabled(!state.lowBatteryGuard)

        Menu("Run While Awake") {
            Toggle("Enabled", isOn: Binding(
                get: { awakeCommand.isEnabled },
                set: { awakeCommand.setEnabled($0) }
            ))
            .disabled(awakeCommand.command.isEmpty)
            Text(awakeCommandStatusText)
            if !awakeCommand.history.isEmpty {
                Divider()
                // 点选即切换，运行中会用新命令重新启动
                ForEach(awakeCommand.history, id: \.self) { command in
                    Toggle(isOn: Binding(
                        get: { command == awakeCommand.command },
                        set: { _ in awakeCommand.setCommand(command) }
                    )) {
                        Text(verbatim: Self.summary(of: command))
                    }
                }
                Divider()
            }
            Button("Set Command…") { editAwakeCommand() }
            Button("Clear History") { awakeCommand.clearHistory() }
                .disabled(awakeCommand.history.count <= 1)
            Button("Show Log") {
                awakeCommand.log.prepare()
                NSWorkspace.shared.open(awakeCommand.log.url)
            }
        }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }
        ))

        Toggle("Automatically Check for Updates", isOn: Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }
        ))

        Menu("Helper") {
            Text(helperStatusText)
            switch state.helperStatus {
            case .enabled:
                Button("Uninstall Helper") { state.uninstallHelper() }
            case .requiresApproval:
                Button("Open System Settings to Approve…") { state.helper.openApprovalSettings() }
            default:
                Button("Install Helper") { state.ensureHelperInstalled() }
            }
            Button("Refresh Status") { state.refreshHelperStatus() }
        }

        Divider()

        Button("About Caffy") {
            activateApp()
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        Button(updater.hasPendingUpdate ? String(localized: "Update Available…") : String(localized: "Check for Updates…")) {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)

        Button("Quit Caffy") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        guard state.isActive else { return String(localized: "Keep Awake: Off") }
        guard let endDate = state.endDate else { return String(localized: "Keep Awake: On (No Limit)") }
        let time = endDate.formatted(date: .omitted, time: .shortened)
        return String(localized: "Keep Awake: On Until \(time)")
    }

    private var awakeCommandStatusText: String {
        if awakeCommand.command.isEmpty { return String(localized: "Status: No Command Set") }
        if !awakeCommand.isEnabled { return String(localized: "Status: Off") }
        switch awakeCommand.status {
        case .idle: return String(localized: "Status: Starts When Keep Awake Is On")
        case .running: return String(localized: "Status: Running")
        case let .restarting(exitCode, delay):
            return String(localized: "Status: Exited (Code \(Int(exitCode))), Restarting in \(delay) s")
        }
    }

    /// 菜单项不会自动截断，过长的命令会把整个菜单撑宽。截掉中间，
    /// 保留开头和结尾，只有末尾参数不同的几条命令也能分清
    private static func summary(of command: String) -> String {
        guard command.count > 50 else { return command }
        return String(command.prefix(24)) + "…" + String(command.suffix(25))
    }

    private func editAwakeCommand() {
        activateApp()
        let alert = NSAlert()
        alert.messageText = String(localized: "Command to Run While Awake")
        alert.informativeText = String(localized: "Runs with /bin/zsh -c as you while Keep Awake is on, and stops when it turns off. Restarts automatically if it exits.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.stringValue = awakeCommand.command
        field.placeholderString = "cd ~/frp && frpc -c frpc.toml"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wasEmpty = awakeCommand.command.isEmpty
        awakeCommand.setCommand(field.stringValue)
        // 第一次设置命令时顺带启用，之后保留用户的开关选择
        if wasEmpty, !awakeCommand.command.isEmpty {
            awakeCommand.setEnabled(true)
        }
    }

    /// 菜单栏 App 默认不在前台，先激活，否则弹出的窗口可能被其他窗口挡住
    private func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var helperStatusText: String {
        switch state.helperStatus {
        case .enabled: String(localized: "Status: Enabled")
        case .requiresApproval: String(localized: "Status: Waiting for Approval in System Settings")
        case .notRegistered: String(localized: "Status: Not Installed")
        case .notFound: String(localized: "Status: Not Found (Make Sure Caffy Is in /Applications)")
        @unknown default: String(localized: "Status: Unknown")
        }
    }
}
