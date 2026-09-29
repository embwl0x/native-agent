import Foundation

/// Read-only evidence from the app's rendered/canonical transcript projection.
/// The bubble and its metadata remain app-owned; retry validation lives here.
public protocol MacChatRetryMessage {
    var id: String { get }
    var role: String { get }
    var content: String { get }
    var retryHasAttachments: Bool { get }
    var retryUserRowPersisted: Bool? { get }
    var retryInputHadAttachments: Bool? { get }
}

/// Immutable evidence that a retry still targets the same transcript tail.
/// The provider call is intentionally admitted only after both the local
/// projection and the canonical transcript still match this snapshot.
public struct MacChatRetrySnapshot: Equatable, Sendable {
    public let sessionId: String
    public let assistantMessageId: String
    public let priorUserMessageId: String
    public let priorUserText: String
    public let predecessorRelevantMessageId: String?
    public let isSyntheticNotice: Bool
    public let userRowPersisted: Bool
    public let inputHadAttachments: Bool

    public static func capture<Message: MacChatRetryMessage>(
        target: Message,
        messages: [Message],
        sessionId: String,
        isSyntheticNotice: Bool
    ) -> Self? {
        guard target.role == "assistant",
              let targetIndex = messages.firstIndex(where: { $0.id == target.id }),
              messages.last(where: { $0.role == "assistant" })?.id == target.id,
              !messages[(targetIndex + 1)...].contains(where: {
                  $0.role == "user" || $0.role == "assistant"
              }),
              let priorUserIndex = messages[..<targetIndex].lastIndex(where: { $0.role == "user" })
        else { return nil }
        let priorUser = messages[priorUserIndex]
        let priorText = priorUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !priorText.isEmpty else { return nil }
        let predecessor = messages[..<priorUserIndex]
            .last(where: { $0.role == "user" || $0.role == "assistant" })?.id
        return Self(
            sessionId: sessionId,
            assistantMessageId: target.id,
            priorUserMessageId: priorUser.id,
            priorUserText: priorText,
            predecessorRelevantMessageId: predecessor,
            isSyntheticNotice: isSyntheticNotice,
            userRowPersisted: isSyntheticNotice
                ? (target.retryUserRowPersisted ?? true)
                : true,
            inputHadAttachments: priorUser.retryHasAttachments
                || target.retryInputHadAttachments == true
        )
    }

    public func stillMatchesLocal<Message: MacChatRetryMessage>(_ messages: [Message]) -> Bool {
        guard let target = messages.first(where: { $0.id == assistantMessageId }) else {
            return false
        }
        return Self.capture(
            target: target,
            messages: messages,
            sessionId: sessionId,
            isSyntheticNotice: isSyntheticNotice
        ) == self
    }

    public func matchesCanonical<Message: MacChatRetryMessage>(_ messages: [Message]) -> Bool {
        let relevant = messages.filter { $0.role == "user" || $0.role == "assistant" }
        if isSyntheticNotice {
            guard !relevant.contains(where: { $0.id == assistantMessageId }) else { return false }
            if userRowPersisted {
                guard let user = relevant.last,
                      user.id == priorUserMessageId,
                      user.role == "user" else { return false }
                return user.content.trimmingCharacters(in: .whitespacesAndNewlines) == priorUserText
            }
            guard !relevant.contains(where: { $0.id == priorUserMessageId }) else { return false }
            return relevant.last?.id == predecessorRelevantMessageId
                || (relevant.isEmpty && predecessorRelevantMessageId == nil)
        }

        guard let assistantIndex = relevant.firstIndex(where: { $0.id == assistantMessageId }),
              assistantIndex == relevant.indices.last,
              let user = relevant[..<assistantIndex].last(where: { $0.role == "user" }),
              user.id == priorUserMessageId else { return false }
        return user.content.trimmingCharacters(in: .whitespacesAndNewlines) == priorUserText
    }
}
