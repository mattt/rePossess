import AppKit
import RePossessCloud
import RePossessRecognize
import SwiftUI

/// The settings window: refreshes and login, pairing, the recognizer, and the MCP clients.
///
/// The `Settings` scene shows the panes as toolbar items with their symbols,
/// titles the window with the open pane, and keeps the last pane in `UserDefaults`.
struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage(SettingsTab.storageKey) private var pane = SettingsTab.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettings(model: model).settingsPane()
            }
            Tab("Cloud", systemImage: "icloud", value: .cloud) {
                CloudSettings(model: model).settingsPane()
            }
            Tab("Handwriting", systemImage: "scribble", value: .recognizer) {
                RecognizerSettings(model: model).settingsPane()
            }
            Tab("MCP Clients", systemImage: "terminal", value: .clients) {
                ClientSettings(model: model).settingsPane()
            }
        }
        .background(SettingsWindowBridge())
    }
}

extension View {
    /// A pane's size: a stable width, and the content's height up to a bound, past which the pane scrolls.
    func settingsPane() -> some View {
        modifier(SettingsPaneSize())
    }
}

/// Sizes a pane to its content: a grouped form reports no height of its own,
/// so the pane measures the form at its ideal height and gives the window that height, up to a bound.
struct SettingsPaneSize: ViewModifier {
    @State private var height: CGFloat = SettingsLayout.minimumHeight

    func body(content: Content) -> some View {
        ScrollView {
            content
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    height = $0
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: SettingsLayout.width)
        .frame(height: min(max(height, SettingsLayout.minimumHeight), SettingsLayout.maximumHeight))
    }
}

/// The settings panes' dimensions, in points.
enum SettingsLayout {
    static let width: CGFloat = 600
    static let minimumHeight: CGFloat = 160
    static let maximumHeight: CGFloat = 640
}

// MARK: General

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var opensAtLogin = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.options.libraryRoot.path)
                            .textSelection(.enabled)
                            .truncationMode(.middle)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.options.libraryRoot])
                        }
                    }
                }
                if let error = model.libraryError { Text(error).foregroundStyle(.red) }
            }
            Section("Refresh") {
                Picker("Refresh the mirror", selection: $model.intervalMinutes) {
                    ForEach(RefreshSchedule.choices, id: \.self) { minutes in
                        Text(RefreshSchedule.label(minutes: minutes)).tag(minutes)
                    }
                }
                Text(
                    """
                    rePossess refreshes over USB when the tablet connects, \
                    and on this schedule over USB when the tablet is connected, or else from reMarkable's cloud. \
                    After each refresh it sends the queued pushes, and recognizes new handwriting \
                    when a recognizer is set.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                LabeledContent("Mirror") {
                    // Relative times in whole minutes, from the status that the app reads every 15 seconds.
                    Text(model.snapshot.refreshTimes())
                }
                Button("Refresh Now") { model.refresh(.manual) }
                    .disabled(model.refreshing || model.library == nil)
            }
            Section("Login") {
                Toggle("Open rePossess at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, enabled in
                        guard enabled != model.opensAtLogin else { return }
                        do {
                            try model.setOpensAtLogin(enabled)
                            loginError = nil
                        } catch {
                            loginError = "\(error)"
                            opensAtLogin = model.opensAtLogin
                        }
                    }
                if let loginError { Text(loginError).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear { opensAtLogin = model.opensAtLogin }
    }
}

// MARK: Cloud

struct CloudSettings: View {
    @Bindable var model: AppModel
    @State private var code = ""
    @State private var message: String?
    @State private var pairing = false
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            switch model.snapshot.pairing {
            case .keychainOff:
                Section("Pairing") {
                    Text(
                        "This run of rePossess does not use the Keychain (--no-keychain), so it cannot pair, unpair, or refresh from the cloud."
                    )
                }
            case .paired(let service):
                Section("Pairing") {
                    LabeledContent("Status") {
                        Text("Paired. The device token is in the login keychain under \"\(service)\".")
                    }
                    Button("Unpair…", role: .destructive) { confirmUnpair = true }
                        .confirmationDialog("Unpair rePossess?", isPresented: $confirmUnpair) {
                            Button("Unpair", role: .destructive) { message = model.unpair() }
                        } message: {
                            Text(
                                "rePossess deletes the device token from the login keychain and sends nothing to reMarkable. Remove the desktop-macos device on my.remarkable.com to revoke the token."
                            )
                        }
                }
            case .notPaired:
                Section("Pairing") {
                    Text(
                        "Pairing adds this Mac to your reMarkable account as a desktop-macos device, so that rePossess can reach the tablet through reMarkable's cloud."
                    )
                    Link("Get a one-time code from my.remarkable.com", destination: CloudHosts.connectPage)
                    HStack {
                        TextField("One-time code", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .frame(maxWidth: 160)
                        Button("Pair") {
                            pairing = true
                            Task {
                                message = await model.pair(code: code)
                                code = ""
                                pairing = false
                            }
                        }
                        .disabled(!PairingCode.isPlausible(code) || pairing)
                        if pairing { ProgressView().controlSize(.small) }
                    }
                }
            }
            if let message {
                Section { Text(message).textSelection(.enabled) }
            }
            Section("Status") {
                ForEach(model.snapshot.cloudLines, id: \.self) { Text($0) }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Clients

struct ClientSettings: View {
    @Bindable var model: AppModel
    @State private var change: ClaudeDesktopConfig.Change?
    @State private var message: String?

    var body: some View {
        let setup = model.clientSetup
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Each client starts the helper inside this app, which serves rePossess over MCP and reads the same library. The configuration names the helper's path, so move rePossess to the Applications folder before you add it to a client."
                )
                .fixedSize(horizontal: false, vertical: true)
                if !model.options.isDefaultLibrary {
                    Text(
                        "This run uses the library \(model.options.libraryRoot.path), so the configuration adds --library."
                    )
                    .foregroundStyle(.orange)
                }
                Snippet(title: "Claude Code: run in Terminal", text: setup.claudeCodeCommand)
                Snippet(title: "Claude Code: a project's .mcp.json", text: setup.claudeCodeJSON)
                Snippet(title: "Claude Desktop: claude_desktop_config.json", text: setup.claudeDesktopJSON)
                HStack {
                    Button("Add to Claude Desktop…") { preview(setup) }
                    Text(ClaudeDesktopConfig.defaultURL.path).font(.caption).foregroundStyle(.secondary)
                }
                Snippet(title: "Codex: run in Terminal", text: setup.codexCommand)
                Snippet(title: "Codex: ~/.codex/config.toml", text: setup.codexTOML)
                if let message { Text(message).textSelection(.enabled) }
            }
            .padding()
        }
        .frame(minHeight: 480)
        .sheet(item: $change) { change in
            ConfigPreview(change: change, url: ClaudeDesktopConfig.defaultURL) { confirmed in
                self.change = nil
                guard confirmed else { return }
                do {
                    let backup = try ClaudeDesktopConfig().write(change)
                    message =
                        "Added repossess to Claude Desktop's configuration."
                        + (backup.map { " The earlier file is in \($0.path)." } ?? "")
                        + " Quit and reopen Claude Desktop to load it."
                } catch {
                    message = "\(error)"
                }
            }
        }
    }

    private func preview(_ setup: ClientSetup) {
        do {
            let prepared = try ClaudeDesktopConfig().prepare(setup)
            if prepared.unchanged {
                message = "Claude Desktop's configuration already has this entry."
            } else {
                change = prepared
            }
        } catch {
            message = "\(error)"
        }
    }
}

extension ClaudeDesktopConfig.Change: Identifiable {
    public var id: String { after }
}

/// A configuration with a Copy button.
struct Snippet: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// The file before and after the change, with the backup and the write behind one button.
struct ConfigPreview: View {
    let change: ClaudeDesktopConfig.Change
    let url: URL
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add repossess to Claude Desktop").font(.title3)
            Text(
                change.before == nil
                    ? "\(url.path) does not exist. rePossess will create it with the text below."
                    : "rePossess will copy \(url.lastPathComponent) to a backup beside it, then write the text below. Other servers and settings stay; the keys are sorted."
                        + (change.replacesServer ? " The existing repossess entry is replaced." : "")
            )
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) {
                if let before = change.before {
                    FileText(title: "Now", text: before)
                }
                FileText(title: "After", text: change.after)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button(change.before == nil ? "Create the File" : "Back Up and Write") { done(true) }
            }
        }
        .padding()
        .frame(width: 720, height: 480)
    }
}

struct FileText: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.quaternary.opacity(0.5))
        }
    }
}
