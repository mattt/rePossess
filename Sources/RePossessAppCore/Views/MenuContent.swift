import AppKit
import SwiftUI

/// The tabs of the settings window.
public enum SettingsTab: String, Hashable, Sendable {
    case general, cloud, recognizer, clients
}

/// The menu bar menu: the status lines, "Refresh Now", and the windows.
struct MenuContent: View {
    @Bindable var model: AppModel
    @Binding var tab: SettingsTab
    @Environment(\.openWindow) private var openWindow

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
        Button("Set Up MCP Clients…") { show(.clients) }
        Button("Settings…") { show(.general) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit rePossess") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ selected: SettingsTab) {
        tab = selected
        openWindow(id: SettingsView.windowID)
        // A menu bar app is not active, so its window would open behind the front app.
        NSApplication.shared.activate()
    }
}

/// The app: a menu bar item and the settings window, with no Dock icon (`LSUIElement`).
public struct RePossessMenuBarApp: App {
    @State private var model: AppModel
    @State private var tab = SettingsTab.general

    public init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, tab: $tab)
        } label: {
            Image(systemName: model.refreshing ? "arrow.triangle.2.circlepath" : "scribble.variable")
                .accessibilityLabel("rePossess")
        }
        .menuBarExtraStyle(.menu)

        Window("rePossess Settings", id: SettingsView.windowID) {
            SettingsView(model: model, tab: $tab)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
