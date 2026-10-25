import AppKit
import SwiftUI

/// The MCP clients that the pane sets up.
enum MCPClient: String, CaseIterable, Identifiable {
    case claudeCode, claudeDesktop, codex

    var id: Self { self }

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex"
        }
    }

    /// The `UserDefaults` key of the client that the pane shows.
    static let storageKey = "setupClient"
}

/// The MCP Clients pane: one client's setup at a time, its recommended method first,
/// and the configuration to add by hand behind "Manual Setup".
struct ClientSettings: View {
    @Bindable var model: AppModel
    @AppStorage(SetupProgress.clientsKey) private var clientsOpened = false
    @AppStorage(MCPClient.storageKey) private var client = MCPClient.claudeCode
    @State private var change: ClaudeDesktopConfig.Change?
    @State private var notice: Notice?

    var body: some View {
        let setup = model.clientSetup
        Form {
            if !model.isInApplications || !model.options.isDefaultLibrary {
                Section {
                    if !model.isInApplications {
                        Label {
                            Text(
                                "This copy of rePossess is not in the Applications folder, and the configuration names its path. Move rePossess to Applications, open it from there, and then set up each client."
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                    if !model.options.isDefaultLibrary {
                        Label {
                            Text(
                                "This run uses the library \(model.options.libraryRoot.path), so the configuration adds --library."
                            )
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Picker("Client", selection: $client) {
                    ForEach(MCPClient.allCases) { Text($0.name).tag($0) }
                }
                switch client {
                case .claudeDesktop:
                    Text(
                        "rePossess adds itself to Claude Desktop's configuration file. You review the change before anything is written."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Add to Claude Desktop…") { preview(setup) }
                    if let notice { NoticeView(notice: notice) }
                case .claudeCode:
                    command(setup.claudeCodeCommand, client: .claudeCode)
                case .codex:
                    command(setup.codexCommand, client: .codex)
                }
                DisclosureGroup("Manual Setup") {
                    manual(setup)
                }
            } header: {
                Text("Set Up a Client")
            } footer: {
                Text(
                    "Quit and reopen the client after setup, so that it starts rePossess. The client starts the helper inside this app, which reads the same library."
                )
                .foregroundStyle(.secondary)
            }
            Section {
                Text(
                    "A connected AI client can read your documents' text and ask for page images. The client may send what it reads to its own model provider, under that client's settings."
                )
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("What Clients Can Read")
            }
        }
        .formStyle(.grouped)
        .onAppear { clientsOpened = true }
        .onChange(of: client) { notice = nil }
        .sheet(item: $change) { change in
            ConfigPreview(change: change, url: ClaudeDesktopConfig.defaultURL) { confirmed in
                self.change = nil
                guard confirmed else { return }
                write(change)
            }
        }
    }

    /// A command to run in Terminal, with its Copy button.
    @ViewBuilder func command(_ text: String, client: MCPClient) -> some View {
        Text("Run this command in Terminal:")
        CodeBlock(text: text)
        CopyButton(title: "Copy Setup Command", text: text, what: "the \(client.name) setup command")
    }

    /// The configuration to add by hand for the chosen client.
    @ViewBuilder func manual(_ setup: ClientSetup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch client {
            case .claudeCode:
                Text("Add this to a project's .mcp.json, or pass it to claude --mcp-config:")
                CodeBlock(text: setup.claudeCodeJSON)
                CopyButton(title: "Copy Configuration", text: setup.claudeCodeJSON, what: "the .mcp.json configuration")
            case .claudeDesktop:
                Text("Add this server to \(ClaudeDesktopConfig.defaultURL.path):")
                    .textSelection(.enabled)
                CodeBlock(text: setup.claudeDesktopJSON)
                CopyButton(
                    title: "Copy Configuration",
                    text: setup.claudeDesktopJSON,
                    what: "the Claude Desktop configuration"
                )
            case .codex:
                Text("Add this table to ~/.codex/config.toml:")
                CodeBlock(text: setup.codexTOML)
                CopyButton(title: "Copy Configuration", text: setup.codexTOML, what: "the Codex configuration")
            }
        }
        .padding(.top, 4)
    }

    private func preview(_ setup: ClientSetup) {
        do {
            let prepared = try ClaudeDesktopConfig().prepare(setup)
            if prepared.unchanged {
                notice = .info("Claude Desktop's configuration already has this server. Nothing needs to change.")
            } else {
                notice = nil
                change = prepared
            }
        } catch {
            notice = .failed("rePossess did not change Claude Desktop's configuration.", error)
        }
    }

    private func write(_ change: ClaudeDesktopConfig.Change) {
        do {
            let backup = try ClaudeDesktopConfig().write(change)
            notice = Notice(
                kind: .done,
                text: "Added rePossess to Claude Desktop's configuration. Quit and reopen Claude Desktop to load it.",
                details: backup.map { "The earlier file is in \($0.path)." }
            )
        } catch {
            notice = .failed("rePossess did not change Claude Desktop's configuration.", error)
        }
    }
}

extension ClaudeDesktopConfig.Change: Identifiable {
    public var id: String { after }
}

extension AppModel {
    /// Whether the app runs from the Applications folder, where the clients' configuration expects it.
    var isInApplications: Bool { ClientSetup.isInApplications(Bundle.main.bundleURL) }
}

/// Configuration text in a readable, selectable block.
struct CodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A button that copies text, then says "Copied" beside itself and to VoiceOver.
struct CopyButton: View {
    let title: String
    let text: String
    /// What the button copies, for VoiceOver, such as "the Codex setup command".
    let what: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Button(title) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                AccessibilityNotification.Announcement("Copied").post()
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    copied = false
                }
            }
            .accessibilityHint("Copies \(what)")
            if copied {
                Label("Copied", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The review of a change to Claude Desktop's file: what changes, the file after it,
/// and the file now, with the write behind one button.
struct ConfigPreview: View {
    let change: ClaudeDesktopConfig.Change
    let url: URL
    let done: (Bool) -> Void

    var summary: String {
        if change.before == nil {
            return "\(url.lastPathComponent) does not exist. rePossess will create it with one server, repossess."
        }
        return
            (change.replacesServer
            ? "rePossess will replace the existing repossess server."
            : "rePossess will add a server named repossess.")
            + " Every other server and setting stays, and the keys are sorted."
            + " rePossess first copies the file to a backup beside it."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add rePossess to Claude Desktop").font(.title3).bold()
            Text(summary).fixedSize(horizontal: false, vertical: true)
            LabeledContent("File") {
                Text(url.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(url.path)
            }
            Text("The file after the change").font(.headline)
            ScrollView {
                Text(change.after)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("The file after the change")
            if let before = change.before {
                DisclosureGroup("The File Now") {
                    ScrollView {
                        Text(before)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 200)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button(change.before == nil ? "Create the File" : "Back Up and Write") { done(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 560)
    }
}
