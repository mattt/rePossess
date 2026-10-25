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
                ForEach(model.refreshNotices) { NoticeView(notice: $0, persistent: true) }
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
                    NoticeView(
                        notice: Notice(kind: .failed, text: "The library could not be opened.", details: error),
                        persistent: true
                    )
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
