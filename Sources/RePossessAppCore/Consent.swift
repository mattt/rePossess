import Foundation
import RePossessRecognize

/// The party that receives page images for a recognizer: the provider and the host that it sends them to.
///
/// Two configurations with the same destination differ only in what the receiver does with the images,
/// such as the model's name; a different provider, host, or port is a different receiver.
public struct PageImageDestination: Hashable, Sendable {
    public var provider: RecognizerProvider
    /// The receiving host with its port when the address names one, such as `api.anthropic.com`,
    /// or "the MCP client" for the client's model.
    public var address: String

    /// The destination of a configuration, or `nil` when its page images stay on this Mac.
    public init?(_ configuration: RecognizerConfiguration) {
        guard configuration.sendsPageImages else { return nil }
        provider = configuration.provider
        if configuration.provider == .client {
            address = "the MCP client"
        } else {
            let url = configuration.effectiveBaseURL
            let host = (url?.host() ?? configuration.receivingHost ?? "unknown host").lowercased()
            address = url?.port.map { "\(host):\($0)" } ?? host
        }
    }

    /// The destination in words, such as "api.anthropic.com (Anthropic)".
    public var label: String {
        provider == .client ? address : "\(address) (\(provider.owner))"
    }
}

/// The owner's consent to send page images off the Mac, for one destination only.
///
/// The settings keep a consent while the owner edits the recognizer.
/// A consent covers the destination that it names:
/// a change of provider or address needs a new consent,
/// and ``AppModel/setRecognizer(_:consent:)`` checks it again before it saves.
public struct PageImageConsent: Equatable, Sendable {
    /// The destination that the owner agreed to, or `nil` when there is no consent.
    public private(set) var destination: PageImageDestination?

    public init(destination: PageImageDestination? = nil) {
        self.destination = destination
    }

    /// The consent that a saved configuration carries:
    /// the owner agreed to its destination when it was saved.
    public init(saved configuration: RecognizerConfiguration?) {
        destination = configuration.flatMap(PageImageDestination.init)
    }

    /// Whether the consent covers a configuration.
    /// A configuration that keeps page images on this Mac needs no consent.
    public func allows(_ configuration: RecognizerConfiguration) -> Bool {
        guard let needed = PageImageDestination(configuration) else { return true }
        return needed == destination
    }

    /// Records the owner's consent to a configuration's destination.
    public mutating func grant(_ configuration: RecognizerConfiguration) {
        destination = PageImageDestination(configuration)
    }

    /// Withdraws the consent.
    public mutating func revoke() {
        destination = nil
    }

    /// Withdraws the consent when the draft's destination is not the one that the owner agreed to,
    /// so that changing the provider or the address and changing it back still needs a new consent.
    public mutating func draftChanged(to destination: PageImageDestination?) {
        if destination != self.destination { revoke() }
    }
}

/// The error when a configuration would send page images to a destination without the owner's consent.
public struct ConsentError: Error, CustomStringConvertible, Equatable {
    public var destination: PageImageDestination

    public var description: String {
        "Page images would go to \(destination.label), and you have not agreed to send them there. "
            + "Select the checkbox to send page images to \(destination.address), then try again."
    }
}
