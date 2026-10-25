import AppKit
import SwiftUI

/// The panes of the settings window.
public enum SettingsTab: String, Hashable, Sendable, CaseIterable {
    case general, cloud, recognizer, clients

    /// The `UserDefaults` key of the last pane, which the settings open to.
    public static let storageKey = "settingsPane"
}

/// The menu bar menu: the status lines, "Refresh Now", and the settings.
struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

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
        Button("Set Up MCP Clients…") { SettingsRouter.show(.clients, with: openSettings) }
        // The settings open to the pane that was open last.
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit rePossess") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Opens the settings from places that have no `openSettings` action of their own:
/// a second open of the app from the Finder, and `--settings <pane>` at launch.
///
/// The menu bar label, which exists for as long as the app runs, watches ``requests``
/// and opens the settings with its environment's `openSettings`.
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()

    /// The requests so far; the label opens the settings when the count changes.
    private(set) var requests = 0
    /// The pane of the latest request, or `nil` to open the pane that was open last.
    private(set) var pane: SettingsTab?

    /// Asks the label to open the settings.
    func open(_ pane: SettingsTab?) {
        self.pane = pane
        requests += 1
    }

    /// Selects a pane, when one is given, and opens the settings in front of the other apps.
    static func show(_ pane: SettingsTab?, with openSettings: OpenSettingsAction) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsTab.storageKey) }
        // A menu bar app is not active, so its window would open behind the front app.
        NSApplication.shared.activate()
        openSettings()
    }
}

/// The menu bar icon, which also opens the settings for ``SettingsRouter``.
struct MenuBarLabel: View {
    @Bindable var model: AppModel
    let router: SettingsRouter
    @Environment(\.openSettings) private var openSettings
    @State private var handled = 0

    var body: some View {
        Image(systemName: model.refreshing ? "arrow.triangle.2.circlepath" : "scribble.variable")
            .accessibilityLabel("rePossess")
            .onAppear(perform: handle)
            .onChange(of: router.requests) { handle() }
    }

    /// Opens the settings once for each request, including one made before the label appeared.
    private func handle() {
        guard router.requests != handled else { return }
        handled = router.requests
        SettingsRouter.show(router.pane, with: openSettings)
    }
}

/// Brings the settings window to the front each time it opens.
///
/// An accessory app (`LSUIElement`) is not active when the owner chooses a menu item,
/// so `SettingsLink` and `openSettings` can open the window behind the front app.
/// When the window comes on screen, this view activates the app and orders the window front.
/// It acts only when the window goes from hidden to shown,
/// so that uncovering an open window does not take the focus from another app.
struct SettingsWindowBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> BridgeView { BridgeView() }
    func updateNSView(_ nsView: BridgeView, context: Context) {}

    final class BridgeView: NSView {
        private var observation: NSKeyValueObservation?
        private var wasVisible = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard let window else { return }
            observation = window.observe(\.isVisible, options: [.initial]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.windowChanged() }
            }
        }

        private func windowChanged() {
            guard let window else { return }
            let visible = window.isVisible
            defer { wasVisible = visible }
            guard visible, !wasVisible else { return }
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

/// Opens the settings when the owner opens the app again from the Finder, as iMCP does.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsRouter.shared.open(nil) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.stop() }
    }
}

/// The app: a menu bar item and the settings window, with no Dock icon (`LSUIElement`).
public struct RePossessMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    public init() {
        let model = AppModel()
        AppDelegate.model = model
        model.start()
        // Read the status again when the menu opens, so that its relative times are current.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in MainActor.assumeIsolated { model.updateSnapshot() } }
        if let pane = model.options.settingsAtLaunch {
            SettingsRouter.shared.open(pane)
        }
        _model = State(initialValue: model)
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model, router: SettingsRouter.shared)
        }
        .menuBarExtraStyle(.menu)
        Settings {
            SettingsView(model: model)
        }
    }
}
