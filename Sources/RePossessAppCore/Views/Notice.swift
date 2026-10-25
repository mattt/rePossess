import SwiftUI

/// The result of an action, shown beside the control that started it.
///
/// Every pane shows results the same way: a symbol with the text, so that color is not the only sign,
/// and an error's full text behind a "Details" disclosure.
struct Notice: Equatable {
    enum Kind: Equatable {
        case done, failed, info
    }

    var kind: Kind
    var text: String
    /// The full technical text, such as an error's description.
    var details: String?

    static func done(_ text: String) -> Notice { Notice(kind: .done, text: text) }
    static func info(_ text: String) -> Notice { Notice(kind: .info, text: text) }

    /// A failure with a short summary and the error's full text as details.
    static func failed(_ summary: String, _ error: (any Error)? = nil) -> Notice {
        Notice(kind: .failed, text: summary, details: error.map { "\($0)" })
    }

    var symbol: String {
        switch kind {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    var color: Color {
        switch kind {
        case .done: .green
        case .failed: .red
        case .info: .secondary
        }
    }
}

/// A ``Notice``, which VoiceOver announces when it appears or changes.
struct NoticeView: View {
    let notice: Notice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(notice.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: notice.symbol).foregroundStyle(notice.color)
            }
            if let details = notice.details, details != notice.text {
                DisclosureGroup("Details") {
                    Text(details)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { announce() }
        .onChange(of: notice) { announce() }
    }

    private func announce() {
        AccessibilityNotification.Announcement(notice.text).post()
    }
}

/// A status with its symbol, such as the recognizer's readiness, for a `LabeledContent` row.
struct StatusLabel: View {
    let title: String
    let symbol: String
    var attention = false

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(attention ? Color.orange : Color.secondary)
        }
    }
}
