import RePossessCloud
import RePossessLibrary
import SwiftUI

/// The Cloud pane: the account's state and its last refresh when paired, and a short pairing task when not.
struct CloudSettings: View {
    @Bindable var model: AppModel
    @State private var code = ""
    @State private var notice: Notice?
    @State private var pairing = false
    @State private var confirmUnpair = false
    @FocusState private var codeFocused: Bool

    /// The site where the owner manages the account's devices.
    static let accountSite = URL(string: "https://my.remarkable.com/")!

    var body: some View {
        Form {
            switch model.snapshot.pairing {
            case .keychainOff:
                Section {
                    LabeledContent("Status") { StatusLabel(title: "Not Available", symbol: "lock.slash") }
                } header: {
                    Text("Account")
                } footer: {
                    Text(
                        "This run of rePossess does not use the Keychain (--no-keychain), so it cannot pair, unpair, or refresh from the cloud."
                    )
                    .foregroundStyle(.secondary)
                }
            case .paired(let service):
                paired(service: service)
            case .notPaired:
                pairingForm
            }
            if let notice {
                Section { NoticeView(notice: notice) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Unpair rePossess?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { show(model.unpair()) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "rePossess deletes its device token from this Mac and sends nothing to reMarkable. reMarkable still lists this Mac as a device until you remove it on my.remarkable.com."
            )
        }
    }

    /// The account when paired: its state, the last refresh from the cloud, and any current problem.
    @ViewBuilder func paired(service: String) -> some View {
        let library = model.snapshot.library
        Section {
            LabeledContent("Status") { StatusLabel(title: "Paired", symbol: "checkmark.circle") }
            LabeledContent("Last cloud refresh") {
                Text(library?.lastRefresh[.cloud].map { StatusSnapshot.age($0, now: model.snapshot.now) } ?? "Not yet")
            }
            if let error = library?.lastError[.cloud] {
                let when = library?.lastErrorAt[.cloud].map { " " + StatusSnapshot.age($0, now: model.snapshot.now) }
                NoticeView(
                    notice: Notice(kind: .failed, text: "The last cloud refresh failed\(when ?? "").", details: error)
                )
            }
            Button("Unpair…", role: .destructive) { confirmUnpair = true }
            DisclosureGroup("Technical Details") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device type: desktop-macos")
                    Text("Keychain item: \(service)")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("Account")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("rePossess keeps the device token for your reMarkable account in the login keychain.")
                Link("Manage Devices on my.remarkable.com", destination: Self.accountSite)
            }
            .foregroundStyle(.secondary)
        }
    }

    /// The pairing task: where to get a code, the code, and Pair.
    @ViewBuilder var pairingForm: some View {
        Section {
            LabeledContent("1. Get a code") {
                Link("Open my.remarkable.com", destination: CloudHosts.connectPage)
            }
            TextField("2. Enter the code", text: $code, prompt: Text("8 letters or digits"))
                .font(.body.monospaced())
                .focused($codeFocused)
                .onSubmit(pair)
            HStack(spacing: 8) {
                Button("Pair", action: pair)
                    .disabled(!PairingCode.isPlausible(code) || pairing)
                if pairing {
                    ProgressView().controlSize(.small).accessibilityLabel("Pairing")
                    Text("Pairing…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Pair with reMarkable Cloud")
        } footer: {
            Text(
                "Pairing lets rePossess reach the tablet through reMarkable's cloud when it is not connected by USB. The code works once, and pairing adds this Mac to your account as a device."
            )
            .foregroundStyle(.secondary)
        }
    }

    /// Pairs with the code; Return and the button both come here, with the same check.
    func pair() {
        guard PairingCode.isPlausible(code), !pairing else { return }
        pairing = true
        notice = nil
        Task {
            let outcome = await model.pair(code: code)
            if !outcome.keepsCode { code = "" }
            pairing = false
            show(outcome)
            if !outcome.succeeded { codeFocused = true }
        }
    }

    func show(_ outcome: PairingOutcome) {
        notice = Notice(kind: outcome.succeeded ? .done : .failed, text: outcome.summary, details: outcome.details)
    }
}
