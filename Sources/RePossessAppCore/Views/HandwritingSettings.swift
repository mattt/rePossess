import RePossessRecognize
import SwiftUI

/// The Handwriting pane: whether recognition is on, the active recognizer and its readiness,
/// its API key, and the MLX model.
///
/// The pane shows only the saved configuration.
/// A new or changed recognizer is a draft in ``RecognizerSetupSheet``,
/// and the saved one stays active until the owner confirms the sheet.
struct RecognizerSettings: View {
    @Bindable var model: AppModel
    @State private var setup: SetupRequest?
    @State private var notice: Notice?

    /// A request for the setup sheet.
    struct SetupRequest: Identifiable {
        let id = UUID()
        var draft: RecognizerDraft
        /// Whether the sheet turns recognition on, rather than changing the provider.
        var enabling: Bool
    }

    var body: some View {
        let readiness = model.recognizerReadiness
        Form {
            Section {
                Toggle("Recognize handwriting", isOn: enabled)
                if readiness != .off {
                    LabeledContent("Status") {
                        StatusLabel(title: readiness.title, symbol: readiness.symbol, attention: readiness.needsAction)
                    }
                }
                if let configuration = model.recognizer {
                    LabeledContent("Provider") { Text(configuration.label).multilineTextAlignment(.trailing) }
                    LabeledContent("Page images") {
                        Text(Self.whereImagesGo(configuration)).multilineTextAlignment(.trailing)
                    }
                    if let waiting = model.snapshot.recognition?.waiting, waiting > 0 {
                        LabeledContent("Pages waiting", value: waiting.formatted())
                    }
                    if model.recognizing {
                        LabeledContent("Now") {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).accessibilityLabel("Recognizing handwriting")
                                Text("Recognizing handwriting…")
                            }
                        }
                    }
                    Button("Change Provider…") {
                        setup = SetupRequest(draft: RecognizerDraft(configuration), enabling: false)
                    }
                }
                if let failure = model.recognitionFailure {
                    NoticeView(
                        notice: Notice(kind: .failed, text: "The last recognition failed.", details: failure),
                        persistent: true
                    )
                }
                if let notice { NoticeView(notice: notice) }
            } header: {
                Text("Handwriting")
            } footer: {
                Text(readiness.detail).foregroundStyle(.secondary)
            }
            if let configuration = model.recognizer, configuration.provider.needsAPIKey {
                Section {
                    APIKeyFields(model: model, provider: configuration.provider)
                } header: {
                    Text("API Key")
                } footer: {
                    Text(APIKeyFields.footer(model)).foregroundStyle(.secondary)
                }
            }
            if model.recognizer?.provider == .mlx, model.recognizer?.modelPath == nil {
                ModelSection(model: model)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $setup) { request in
            RecognizerSetupSheet(model: model, draft: request.draft, enabling: request.enabling) { result in
                setup = nil
                if let result { notice = result }
            }
        }
    }

    /// The toggle: on shows the setup sheet, and off removes the configuration at once.
    var enabled: Binding<Bool> {
        Binding(
            get: { model.recognizer != nil || model.snapshot.recognizerError != nil },
            set: { on in
                if on {
                    notice = nil
                    setup = SetupRequest(draft: RecognizerDraft(), enabling: true)
                } else {
                    turnOff()
                }
            }
        )
    }

    func turnOff() {
        do {
            try model.turnRecognitionOff()
            // The helper process that already runs keeps its configuration and finishes its pages.
            notice = .done(
                model.recognizing
                    ? "Recognition is off. The run in progress finishes its pages, and no new run starts."
                    : "Recognition is off. Text that was already recognized stays."
            )
        } catch {
            notice = .failed("Recognition could not be turned off.", error)
        }
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
}

/// The sheet that sets up a recognizer: the provider, its fields, where page images go,
/// the consent for that destination, and the API key.
/// Nothing changes until the owner confirms it.
struct RecognizerSetupSheet: View {
    @Bindable var model: AppModel
    @State private var draft: RecognizerDraft
    /// The owner's consent to send page images, for one provider and address only.
    @State private var consent: PageImageConsent
    @State private var failure: Notice?
    @FocusState private var focus: Field?
    let enabling: Bool
    let done: (Notice?) -> Void

    enum Field: Hashable {
        case model, address
    }

    init(model: AppModel, draft: RecognizerDraft, enabling: Bool, done: @escaping (Notice?) -> Void) {
        self.model = model
        self.enabling = enabling
        self.done = done
        _draft = State(initialValue: draft)
        _consent = State(initialValue: enabling ? PageImageConsent() : PageImageConsent(saved: model.recognizer))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Provider", selection: $draft.provider) {
                        ForEach(RecognizerProvider.allCases, id: \.self) { provider in
                            Text(RecognizerDraft.name(provider)).tag(provider)
                        }
                    }
                } header: {
                    Text(enabling ? "Turn On Handwriting Recognition" : "Change Provider")
                } footer: {
                    Text(RecognizerDraft.explanation(draft.provider)).foregroundStyle(.secondary)
                }
                if draft.showsModel || draft.showsAddress {
                    Section {
                        if draft.showsModel {
                            TextField("Model", text: $draft.model, prompt: Text("The provider's model name"))
                                .focused($focus, equals: .model)
                                .onSubmit(save)
                            if let problem = draft.modelProblem {
                                FieldHint(text: problem, problem: false)
                            }
                        }
                        if draft.showsAddress {
                            TextField("Address", text: $draft.address, prompt: Text(draft.defaultAddress ?? ""))
                                .focused($focus, equals: .address)
                                .onSubmit(save)
                            if let problem = draft.addressProblem {
                                FieldHint(text: problem, problem: true)
                            } else if draft.address.trimmingCharacters(in: .whitespaces).isEmpty,
                                let address = draft.defaultAddress
                            {
                                FieldHint(text: "Leave it empty to use \(address).", problem: false)
                            }
                        }
                    }
                }
                Section("Page Images") { destination }
                if draft.provider.needsAPIKey {
                    Section {
                        APIKeyFields(model: model, provider: draft.provider)
                    } header: {
                        Text("API Key")
                    } footer: {
                        Text(APIKeyFields.footer(model)).foregroundStyle(.secondary)
                    }
                }
                if draft.provider == .mlx, draft.modelPath == nil {
                    Section("Model") {
                        LabeledContent("Qwen3-VL 8B") {
                            if model.modelStore.locate() != nil {
                                StatusLabel(title: "On This Mac", symbol: "checkmark.circle")
                            } else {
                                StatusLabel(title: "Not Downloaded", symbol: "arrow.down.circle", attention: true)
                            }
                        }
                        if model.modelStore.locate() == nil {
                            FieldHint(
                                text:
                                    "After you turn recognition on, download the 5.8 GB model in the Handwriting pane. Nothing downloads until you start it.",
                                problem: false
                            )
                        }
                    }
                }
                if let failure {
                    Section { NoticeView(notice: failure) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(enabling ? "Turn On Recognition" : "Save Changes", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 540, height: 560)
        .scrollDisabled(false)
        .defaultFocus($focus, draft.showsModel ? .model : nil)
        // A new provider or address needs a new consent, even when the owner changes it back.
        .onChange(of: draftDestination) { _, destination in consent.draftChanged(to: destination) }
    }

    /// The destination of the draft's page images, or `nil` when they stay on this Mac or the draft is not valid.
    var draftDestination: PageImageDestination? {
        draft.configuration.flatMap(PageImageDestination.init)
    }

    /// Where page images go for the draft, and the consent that a destination off the Mac needs.
    @ViewBuilder var destination: some View {
        if let configuration = draft.configuration {
            if let receiver = PageImageDestination(configuration) {
                Label {
                    Text(
                        "An image of each page with handwriting leaves this Mac and goes to \(configuration.destination)."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                LabeledContent("Page images go to") {
                    Text(receiver.label).textSelection(.enabled)
                }
                // The checkbox names the destination, and its state belongs to that destination only.
                Toggle("Send page images to \(receiver.address)", isOn: consentBinding(for: configuration))
                    .toggleStyle(.checkbox)
            } else {
                Text(RecognizerSettings.whereImagesGo(configuration))
            }
        } else {
            Text("Complete the fields above to see where page images go.").foregroundStyle(.secondary)
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

    var canSave: Bool {
        guard let configuration = draft.configuration else { return false }
        return consent.allows(configuration)
    }

    func save() {
        guard canSave, let configuration = draft.configuration else { return }
        do {
            // The model checks the consent against the destination again before it saves.
            try model.setRecognizer(configuration, consent: consent)
            model.recognizeInBackground()
            done(.done("Recognition is on with \(configuration.label)."))
        } catch let error as ConsentError {
            failure = .failed(error.description)
        } catch {
            failure = .failed("The recognizer was not saved.", error)
        }
    }
}

/// Guidance under a field: a hint, or a problem with a warning symbol.
struct FieldHint: View {
    let text: String
    let problem: Bool

    var body: some View {
        if problem {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .font(.callout)
        } else {
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The API key rows: whether a key is saved, without showing it, and a field to save one.
struct APIKeyFields: View {
    @Bindable var model: AppModel
    let provider: RecognizerProvider
    @State private var key = ""
    @State private var notice: Notice?

    var body: some View {
        LabeledContent("\(provider.owner) API key") {
            switch model.apiKeySource(provider) {
            case nil: StatusLabel(title: "Not Saved", symbol: "key", attention: true)
            case "the login keychain": StatusLabel(title: "Saved in Keychain", symbol: "checkmark.circle")
            case let variable?: StatusLabel(title: "From \(variable)", symbol: "checkmark.circle")
            }
        }
        HStack {
            SecureField("New key", text: $key, prompt: Text("Paste the key"))
                .accessibilityLabel("New \(provider.owner) API key")
                .onSubmit(save)
            Button("Save API Key", action: save)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.options.usesKeychain)
        }
        if let notice { NoticeView(notice: notice) }
    }

    func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try model.saveAPIKey(trimmed, provider: provider)
            notice = .done("Saved the \(provider.owner) API key in the login keychain.")
        } catch {
            notice = .failed("The API key was not saved.", error)
        }
        key = ""
    }

    /// The footer: where the key is kept, or why it cannot be saved in this run.
    static func footer(_ model: AppModel) -> String {
        model.options.usesKeychain
            ? "rePossess keeps the key in the login keychain and never shows it again. An environment variable, such as ANTHROPIC_API_KEY, takes precedence."
            : NoKeychain.message
    }
}

/// The pinned MLX model: whether it is on this Mac, and its download, which only the owner's click starts.
struct ModelSection: View {
    @Bindable var model: AppModel

    var body: some View {
        let store = model.modelStore
        let folder = store.locate()
        let size = ModelDownloadState.size(store.model.totalBytes)
        let state = model.downloadState
        Section {
            LabeledContent("Qwen3-VL 8B") {
                if folder != nil, !state.isRunning {
                    StatusLabel(title: "On This Mac", symbol: "checkmark.circle")
                } else if state.isRunning {
                    StatusLabel(title: "Downloading", symbol: "arrow.down.circle")
                } else if case .stopped = state {
                    StatusLabel(title: "Download Stopped", symbol: "pause.circle", attention: true)
                } else {
                    StatusLabel(title: "Not Downloaded", symbol: "arrow.down.circle", attention: true)
                }
            }
            if let bytes = state.bytes {
                ProgressView(value: Double(bytes.done), total: Double(max(bytes.total, 1))) {
                    EmptyView()
                } currentValueLabel: {
                    Text(state.progressText ?? "")
                }
                .accessibilityLabel("Model download")
                .accessibilityValue(state.progressText ?? "")
            }
            if folder == nil || state.isRunning {
                HStack {
                    switch state {
                    case .running:
                        Button("Stop Download") { model.cancelModelDownload() }
                    case .stopped:
                        Button("Resume Download") { model.startModelDownload() }
                    default:
                        Button("Download Model (\(size))") { model.startModelDownload() }
                    }
                }
            }
            if case .failed(let message) = state {
                NoticeView(
                    notice: Notice(kind: .failed, text: "The download failed.", details: message),
                    persistent: true
                )
            }
            if case .finished = state {
                NoticeView(
                    notice: .done("The model is on this Mac, and every file matches its pinned SHA-256."),
                    persistent: true
                )
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repository: \(store.model.repository)")
                    Text("Revision: \(store.model.revision)")
                    if let folder { Text("Folder: \(folder.path)") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("Model")
        } footer: {
            Text(
                folder == nil
                    ? "The model is \(size) from Hugging Face. rePossess checks each file's SHA-256, and a stopped download continues where it stopped."
                    : "rePossess reads handwriting with this model on this Mac."
            )
            .foregroundStyle(.secondary)
        }
    }
}
