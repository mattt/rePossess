import AppKit
import RePossessCloud
import RePossessRecognize
import SwiftUI

/// The settings window: refreshes and login, pairing, the recognizer, and the MCP clients.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            CloudSettings(model: model)
                .tabItem { Label("Cloud", systemImage: "icloud") }
                .tag(SettingsTab.cloud)
            RecognizerSettings(model: model)
                .tabItem { Label("Handwriting", systemImage: "scribble") }
                .tag(SettingsTab.recognizer)
            ClientSettings(model: model)
                .tabItem { Label("MCP Clients", systemImage: "terminal") }
                .tag(SettingsTab.clients)
        }
        .frame(width: 640, height: 600)
        .padding()
    }
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

// MARK: Recognizer

struct RecognizerSettings: View {
    @Bindable var model: AppModel
    @State private var provider: RecognizerProvider?
    @State private var modelName = ""
    @State private var baseURL = ""
    /// The owner's consent to send page images, for one provider and address only.
    @State private var consent = PageImageConsent()
    @State private var apiKey = ""
    @State private var message: String?

    /// The configuration that the fields describe, or the reason that they do not make one.
    var draft: Result<RecognizerConfiguration, RecognizerError>? {
        guard let provider else { return nil }
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        do {
            return .success(
                try RecognizerConfiguration(
                    provider: provider,
                    model: provider.needsModel ? modelName : nil,
                    baseURL: url.isEmpty ? nil : URL(string: url)
                )
            )
        } catch let error as RecognizerError {
            return .failure(error)
        } catch {
            return .failure(.configuration("\(error)"))
        }
    }

    var body: some View {
        Form {
            Section("Recognizer") {
                Picker("Provider", selection: $provider) {
                    Text("Off").tag(RecognizerProvider?.none)
                    ForEach(RecognizerProvider.allCases, id: \.self) { p in
                        Text(Self.name(p)).tag(RecognizerProvider?.some(p))
                    }
                }
                if let provider, provider.needsModel {
                    TextField(
                        "Model",
                        text: $modelName,
                        prompt: Text("The provider's name for a model that reads images")
                    )
                }
                if provider == .openai || provider == .ollama {
                    TextField("Address", text: $baseURL, prompt: Text("Leave empty for the default"))
                }
                destination
                if let provider, provider.needsAPIKey {
                    HStack {
                        SecureField("API key", text: $apiKey)
                        Button("Keep in Keychain") {
                            do {
                                try model.saveAPIKey(
                                    apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                    provider: provider
                                )
                                message = "Kept the \(provider.rawValue) API key in the login keychain."
                            } catch {
                                message = "\(error)"
                            }
                            apiKey = ""
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text(
                        !model.options.usesKeychain
                            ? NoKeychain.message
                            : model.hasAPIKey(provider)
                                ? "An API key for \(provider.rawValue) is in the login keychain."
                                : "No API key for \(provider.rawValue) is in the login keychain."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                if provider == .client {
                    Text(
                        "The client's model reads handwriting only when an MCP client that offers sampling calls recognize_pages. The app does not recognize in the background with it."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Use This Recognizer") { apply() }
                        .disabled(!canApply)
                    if model.recognizer != nil {
                        Button("Turn Off") {
                            do {
                                try model.turnRecognitionOff()
                                provider = nil
                                message = "Recognition is off. Recognized text stays in the cache."
                            } catch {
                                message = "\(error)"
                            }
                        }
                    }
                }
                if let message { Text(message).textSelection(.enabled) }
            }
            Section("Now") {
                Text(model.snapshot.recognizerLine)
                if let configuration = model.recognizer {
                    Text(Self.whereImagesGo(configuration)).foregroundStyle(.secondary)
                }
            }
            if provider == .mlx || model.recognizer?.provider == .mlx {
                ModelSection(model: model)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        // A new provider or address needs a new consent, even when the owner changes it back.
        .onChange(of: draftDestination) { _, destination in consent.draftChanged(to: destination) }
    }

    /// The destination of the draft's page images, or `nil` when they stay on this Mac or there is no draft.
    var draftDestination: PageImageDestination? {
        guard case .success(let configuration) = draft else { return nil }
        return PageImageDestination(configuration)
    }

    /// The plain statement of where page images go for the chosen provider, and the consent it needs.
    @ViewBuilder var destination: some View {
        switch draft {
        case .success(let configuration):
            if let receiver = PageImageDestination(configuration) {
                Label {
                    Text(
                        "With this provider, an image of each page with handwriting leaves this Mac and goes to \(configuration.destination)."
                    )
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                LabeledContent("Page images go to") {
                    Text(receiver.label).textSelection(.enabled)
                }
                // The checkbox names the destination, and its state belongs to that destination only.
                Toggle("Send page images to \(receiver.address)", isOn: consentBinding(for: configuration))
                    .toggleStyle(.checkbox)
            } else {
                Text(Self.whereImagesGo(configuration)).foregroundStyle(.secondary)
            }
        case .failure(let error):
            Text(error.description).foregroundStyle(.secondary)
        case nil:
            Text("Recognition is off. AI clients read handwriting from the page images.")
                .foregroundStyle(.secondary)
        }
    }

    /// The checkbox's state: on only when the consent names this configuration's destination.
    func consentBinding(for configuration: RecognizerConfiguration) -> Binding<Bool> {
        Binding(
            get: { consent.allows(configuration) },
            set: { agreed in
                if agreed { consent.grant(configuration) } else { consent.revoke() }
            }
        )
    }

    var canApply: Bool {
        guard case .success(let configuration) = draft else { return false }
        return consent.allows(configuration)
    }

    func apply() {
        guard case .success(let configuration) = draft else { return }
        do {
            // The model checks the consent against the destination again before it saves.
            try model.setRecognizer(configuration, consent: consent)
            message = "rePossess now reads handwriting with \(configuration.label)."
            model.recognizeInBackground()
        } catch {
            message = "\(error)"
        }
    }

    func load() {
        guard let configuration = model.recognizer else { return }
        provider = configuration.provider
        modelName = configuration.model ?? ""
        baseURL = configuration.baseURL?.absoluteString ?? ""
        consent = PageImageConsent(saved: configuration)
    }

    /// Where the recognizer sends page images, in one sentence.
    /// It describes recognition only; a connected AI client can also ask for page images.
    static func whereImagesGo(_ configuration: RecognizerConfiguration) -> String {
        if configuration.provider == .client {
            return
                "For recognition, page images go to the MCP client that asks for it. That client decides which model receives them."
        }
        if configuration.sendsPageImages {
            return "For recognition, page images leave this Mac and go to \(configuration.destination)."
        }
        if configuration.provider == .ollama {
            return "For recognition, page images go to \(configuration.destination)."
        }
        return "Recognition keeps page images on this Mac."
    }

    static func name(_ provider: RecognizerProvider) -> String {
        switch provider {
        case .mlx: "Qwen3-VL 8B through MLX (on this Mac)"
        case .foundationModels: "Apple's Foundation Models (on this Mac)"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI, or a server with its API"
        case .gemini: "Google Gemini"
        case .ollama: "Ollama"
        case .client: "The MCP client's model (sampling)"
        }
    }
}

/// The pinned MLX model: where it is, and its download, which only the owner's click starts.
struct ModelSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("The MLX model") {
            let store = model.modelStore
            let gigabytes = String(format: "%.1f GB", Double(store.model.totalBytes) / 1e9)
            if let folder = store.locate(), !model.downloading {
                Text("The pinned model is on this Mac: \(folder.path)").textSelection(.enabled)
            } else {
                Text(
                    "The pinned model, \(store.model.repository), is not on this Mac. The download is \(gigabytes) from Hugging Face, and rePossess checks every file's SHA-256."
                )
                HStack {
                    Button("Download \(gigabytes)") { model.startModelDownload() }
                        .disabled(model.downloading)
                    if model.downloading {
                        Button("Stop") { model.cancelModelDownload() }
                    }
                }
            }
            if let fraction = model.downloadFraction, model.downloading || fraction < 1 {
                ProgressView(value: fraction)
            }
            if let line = model.downloadMessage {
                Text(line).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
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
