import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let state = AppState()

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { state.prepareForTermination() }
    }
}

@main
struct CaffyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: delegate.state)
        } label: {
            MenuBarIcon(state: delegate.state)
        }
    }
}

struct MenuBarIcon: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(systemName: state.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
    }
}
