import AppKit
import RePossessCloud
import RePossessLibrary
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
    @State private var loginNotice: Notice?

    @AppStorage(SetupProgress.finishedKey) private var setupFinished = false

    var body: some View {
        let snapshot = model.snapshot
        Form {
            if !setupFinished {
                GetStartedSection(model: model, finished: $setupFinished)
            }
            Section {
                Picker("Refresh interval", selection: $model.intervalMinutes) {
                    ForEach(RefreshSchedule.choices, id: \.self) { minutes in
                        Text(RefreshSchedule.label(minutes: minutes)).tag(minutes)
                    }
                }
                // Relative times in whole minutes, from the status that the app reads every 15 seconds.
                LabeledContent("Last refresh", value: snapshot.lastRefreshText)
                LabeledContent("Next refresh", value: snapshot.nextRefreshText)
                HStack(spacing: 8) {
                    Button("Refresh Now") { model.refresh(.manual) }
                        .disabled(model.refreshing || model.library == nil)
                    if model.refreshing {
                        ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
                        Text("Refreshing…").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.refreshNotices, id: \.text) { NoticeView(notice: $0) }
            } header: {
                Text("Refresh")
            } footer: {
                Text(
                    "rePossess refreshes over USB when the tablet connects, and on this schedule over USB or from reMarkable's cloud. After each refresh, it sends the documents that wait and reads new handwriting when recognition is on."
                )
                .foregroundStyle(.secondary)
            }
            if !model.menuStatus.queue.isEmpty {
                Section {
                    ForEach(model.menuStatus.queue, id: \.self) { Text($0) }
                } header: {
                    Text("Documents to Send")
                } footer: {
                    Text(
                        "rePossess sends each document at the next refresh. An unconfirmed delivery got no answer; rePossess checks whether it arrived before it sends it again."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Section("Login") {
                Toggle("Open rePossess at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, enabled in
                        guard enabled != model.opensAtLogin else { return }
                        do {
                            try model.setOpensAtLogin(enabled)
                            loginNotice = nil
                        } catch {
                            loginNotice = .failed("The login item could not be changed.", error)
                            opensAtLogin = model.opensAtLogin
                        }
                    }
                if let loginNotice { NoticeView(notice: loginNotice) }
            }
            Section {
                LabeledContent("Folder") {
                    Text(model.options.libraryRoot.path)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.options.libraryRoot.path)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.options.libraryRoot])
                }
                .accessibilityLabel("Show the library folder in Finder")
                if let error = model.libraryError {
                    NoticeView(notice: Notice(kind: .failed, text: "The library could not be opened.", details: error))
                }
            } header: {
                Text("Local Library")
            } footer: {
                Text(
                    "The local library holds a copy of the tablet's documents, their index, and the documents that wait to be sent."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { opensAtLogin = model.opensAtLogin }
    }
}

// MARK: Clients

struct ClientSettings: View {
    @Bindable var model: AppModel
    @AppStorage(SetupProgress.clientsKey) private var clientsOpened = false
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
        .onAppear { clientsOpened = true }
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

/// The first-run setup at the top of General: connect the tablet, then an AI client.
/// Handwriting stays an optional later step. The owner can finish it or set it up later.
struct GetStartedSection: View {
    @Bindable var model: AppModel
    @Binding var finished: Bool
    @AppStorage(SettingsTab.storageKey) private var pane = SettingsTab.general
    @AppStorage(SetupProgress.clientsKey) private var clientsOpened = false

    var body: some View {
        let connected = model.tabletReachable
        Section {
            LabeledContent("1. Connect the tablet") {
                if connected {
                    StatusLabel(title: model.snapshot.usbPresent ? "On USB" : "Connected", symbol: "checkmark.circle")
                } else {
                    StatusLabel(title: "Not Yet", symbol: "circle")
                }
            }
            if !connected {
                Text(
                    "By USB: on the tablet, turn on Settings > General settings > Storage > USB web interface, then connect the cable. When macOS asks whether rePossess may find devices on your local network, choose Allow. rePossess never changes the tablet's settings."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Pair with reMarkable Cloud…") { pane = .cloud }
            }
            LabeledContent("2. Connect an AI client") {
                StatusLabel(
                    title: clientsOpened ? "Opened" : "Not Yet",
                    symbol: clientsOpened ? "checkmark.circle" : "circle"
                )
            }
            Button("Set Up MCP Clients…") { pane = .clients }
            HStack {
                Button("Set Up Later") { finished = true }
                Spacer()
                Button("Done") { finished = true }
                    .disabled(!connected)
            }
        } header: {
            Text("Get Started")
        } footer: {
            Text(
                "Handwriting recognition is optional; turn it on later in Handwriting. Set Up Later hides these steps; nothing opens them again at login."
            )
            .foregroundStyle(.secondary)
        }
    }
}

extension AppModel {
    /// The refresh's problems for the General pane, with the full text behind "Details".
    /// The menu's problem rows open this pane, or Cloud for a cloud error.
    var refreshNotices: [Notice] {
        var notices: [Notice] = []
        let library = snapshot.library
        for (source, name) in [(Source.usb, "USB"), (.cloud, "cloud")] {
            guard let error = library?.lastError[source] else { continue }
            let when = library?.lastErrorAt[source].map { " " + StatusSnapshot.age($0, now: snapshot.now) } ?? ""
            notices.append(Notice(kind: .failed, text: "The last \(name) refresh failed\(when).", details: error))
        }
        guard notices.isEmpty, !refreshing, let outcome = lastOutcome else { return notices }
        switch outcome.result {
        case .failed(let message):
            notices.append(Notice(kind: .failed, text: "The last refresh failed.", details: message))
        case .noPath, .busyElsewhere:
            notices.append(.info(outcome.summary))
        case .finished, .alreadyRunning:
            break
        }
        return notices
    }
}
