import Foundation

/// Typed evidence that a connector action failed for ONE specific reason: the
/// account is not connected yet.
///
/// Before this, each connector said so in prose ("Paste a Personal Access
/// Token in Connectors > GitHub"), the prose reached the model as a generic
/// failure, and the person got told to go find a settings page. Matching that
/// prose back out would be a parser over English, which is exactly the thing
/// an inline card must not be built on: a card offers an ACTION, and an action
/// may only be offered on evidence, never on a guess about a sentence.
///
/// So the connectors keep their own error types and their own wording, and
/// each one answers one extra question: *is this failure a missing
/// credential, and for which connector?* Only a non-nil answer may become a
/// "Connect X" card. Every other failure — a bad request, a rate limit, a
/// corrupt store, a network fault — returns nil and stays a failure, because
/// a setup invitation raised over an unrelated fault is a lie that costs the
/// person a trip through OAuth for nothing.
public protocol ConnectorCredentialsMissing: Error {
    /// Canonical connector ID when THIS error means "not connected yet",
    /// otherwise nil.
    var missingConnectorID: String? { get }
}

public extension Error {
    /// The connector this error says is not connected, if it says that at all.
    var missingConnectorID: String? {
        (self as? any ConnectorCredentialsMissing)?.missingConnectorID
    }
}
