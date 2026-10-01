import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater: Updater

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
            // 菜单栏 App 默认不在前台，先激活，否则关于窗口可能被其他窗口挡住
            if #available(macOS 14, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
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
