import AppKit
import SwiftUI

/// The tabs of the settings window.
public enum SettingsTab: String, Hashable, Sendable, CaseIterable {
    case general, cloud, recognizer, clients
}

/// The menu bar menu: the status lines, "Refresh Now", and the settings.
struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        ForEach(Array(model.snapshot.lines.enumerated()), id: \.offset) { _, line in
            Text(line)
        }
        if model.refreshing {
            Text("Refreshing…")
        } else if let outcome = model.lastOutcome {
            Text(StatusSnapshot.shorten(outcome.summary))
        }
        if model.recognizing {
            Text("Recognizing handwriting…")
        } else if let last = model.lastRecognition {
            Text(StatusSnapshot.shorten(last))
        }
        Divider()
        Button("Refresh Now") { model.refresh(.manual) }
            .disabled(model.refreshing || model.library == nil)
            .keyboardShortcut("r")
        Divider()
        Button("Set Up MCP Clients…") { SettingsWindow.shared.show(.clients) }
        Button("Settings…") { SettingsWindow.shared.show(.general) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit rePossess") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The settings window, which AppKit hosts so that the app can open it from the menu,
/// when the app is opened again, and at launch with `--settings <tab>`.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    var model: AppModel?
    private var window: NSWindow?

    func show(_ tab: SettingsTab) {
        guard let model else { return }
        model.settingsTab = tab
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "rePossess Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("rePossess Settings")
            window.center()
            self.window = window
        }
        // A menu bar app is not active, so its window would open behind the front app.
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

/// Opens the settings when the owner opens the app again from the Finder, as iMCP does.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindow.shared.show(.general) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { SettingsWindow.shared.model?.stop() }
    }
}

/// The app: a menu bar item and the settings window, with no Dock icon (`LSUIElement`).
public struct RePossessMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    public init() {
        let model = AppModel()
        SettingsWindow.shared.model = model
        model.start()
        // Read the status again when the menu opens, so that its relative times are current.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in MainActor.assumeIsolated { model.updateSnapshot() } }
        if let tab = model.options.settingsAtLaunch {
            Task { @MainActor in SettingsWindow.shared.show(tab) }
        }
        _model = State(initialValue: model)
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.refreshing ? "arrow.triangle.2.circlepath" : "scribble.variable")
                .accessibilityLabel("rePossess")
        }
        .menuBarExtraStyle(.menu)
    }
}
