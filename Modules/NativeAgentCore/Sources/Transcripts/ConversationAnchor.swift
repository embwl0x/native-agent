import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared

// Blueprint: | `ConversationAnchor.swift` | `ConversationAnchor`, `mayAnchor`: Direct-user anchor; unknown protection holds retention |

// MARK: - The conversation anchor
// Keep the user's active conversation reachable across surfaces without merging their sessions. Adapters declare conversation kind; only direct user
// conversations may anchor, independent of surface names. Existing rows use SessionConversation ownership, so typing in a peer or helper thread never makes it
// the user's conversation. The most recent accepted activity wins, even when publications arrive out of order.

/// A stateless owner keeps one durable conversation anchor. Off-disk backup, phone navigation and PrivacyMap/chat include it; local backup and export exclude
/// it.
public enum ConversationAnchor {
    /// Notify only when anchor identity changes.
    public static let didPublish = Notification.Name("NativeAgent.ConversationAnchor.didPublish")

    public static func path(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("anchor_pin.json")
    }

    /// Return refusals explicitly so a surface can explain why it did not anchor.
    public enum PublishRefusal: String, Sendable, Equatable {
        case emptySessionID
        /// Shared rooms, peer/helper threads and builder work cannot become the user's direct conversation.
        case notADirectConversation
        /// Require a source so every published anchor is attributable.
        case emptySource
        /// A delayed publication cannot replace newer accepted activity.
        case supersededByNewerAnchor
    }

    public enum PublishOutcome: Sendable, Equatable {
        case published(ConversationAnchorPin)
        /// Already the anchor. New activity still advances its ordering stamp; no identity-change notification is posted.
        case unchanged(ConversationAnchorPin)
        case refused(PublishRefusal)
    }

    /// Publish only for user activity, declaring the conversation's actual kind; peer, bot and wake turns must never move the user. Same-session activity
    /// advances ordering without an identity-change notification. Share the sessions-index lock with retention to avoid inconsistent protection reads and
    /// opposing lock orders. Publication failure must not fail the user's message; callers log refusals or thrown IO errors and continue. Capture accepted
    /// activity time before awaiting or detaching: acquiring a lock is not user activity.
    @discardableResult
    public static func publish(
        sessionId: String,
        source: String,
        conversationKind: ChatThreadKind,
        dataRoot: URL = defaultDataRoot(),
        now: Date = Date()
    ) async throws -> PublishOutcome {
        let cleanSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSession.isEmpty else { return .refused(.emptySessionID) }
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanSource.isEmpty else { return .refused(.emptySource) }
        guard conversationKind == .direct else { return .refused(.notADirectConversation) }

        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let anchorPath = path(dataRoot: dataRoot)

        let outcome = try await SwiftNativePersistenceCore.withFileLock(sessionsPath) { () async throws -> PublishOutcome in
            // The row's recorded kind outranks the publisher's claim.
            let sessions = try SessionConversation(dataRoot: dataRoot)
            guard (sessions.kind(cleanSession) ?? conversationKind).isPersonConversation else { return .refused(.notADirectConversation) }
            let parent = anchorPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let existing = try readUnlocked(at: anchorPath)
            // Preserve activity order even if an older publication was delayed. The numeric stamp retains precision lost by ISO display formatting.
            let committedStamp = NativeTimestampFormat.fractionalZulu(now)
            if let existing,
               let existingAt = existing.activityAt ?? parseISO8601(existing.pin.updatedAt),
               existingAt > now {
                return .refused(.supersededByNewerAnchor)
            }
            let pin = ConversationAnchorPin(
                sessionId: cleanSession,
                source: cleanSource,
                updatedAt: committedStamp
            )
            try await SwiftNativePersistenceCore.writeJSON(
                .object([
                    "sessionId": .string(pin.sessionId),
                    "source": .string(pin.source),
                    "updatedAt": .string(pin.updatedAt),
                    "activityAt": .double(now.timeIntervalSince1970),
                ]),
                to: anchorPath
            )
            return existing?.pin.sessionId == cleanSession ? .unchanged(pin) : .published(pin)
        }
        if case .published = outcome { NotificationCenter.default.post(name: didPublish, object: nil) }
        return outcome
    }

    /// Reject pins outside the user's direct conversation. Atomic writes permit unlocked reads; brief staleness corrects on refresh.
    public static func current(dataRoot: URL = defaultDataRoot()) -> ConversationAnchorPin? {
        do { return try readUnlocked(at: path(dataRoot: dataRoot))?.pin }
        catch {
            nativeLog("Conversation anchor unavailable: %@", error.localizedDescription)
            return nil
        }
    }

    public static func currentSessionId(dataRoot: URL = defaultDataRoot()) -> String? {
        current(dataRoot: dataRoot)?.sessionId
    }

    public static func checkedCurrent(dataRoot: URL = defaultDataRoot()) throws -> ConversationAnchorPin? {
        try readUnlocked(at: path(dataRoot: dataRoot))?.pin
    }

    /// Protect the live conversation independently of user pins so unpinning cannot make it archivable. Unknown protection throws: a damaged anchor never means
    /// no anchor.
    public static func protectedSessionIds(dataRoot: URL = defaultDataRoot()) throws -> Set<String> {
        guard let pin = try readUnlocked(at: path(dataRoot: dataRoot))?.pin else { return [] }
        return [pin.sessionId]
    }

    /// Prepend the anchor without changing user pin order or duplicating it; writing auto-pins would fight unpinning and republish each selection.
    public static func merged(
        into pinnedSessionIds: [String],
        dataRoot: URL = defaultDataRoot()
    ) -> [String] {
        merged(into: pinnedSessionIds, anchorSessionId: currentSessionId(dataRoot: dataRoot))
    }

    public static func merged(
        into pinnedSessionIds: [String],
        anchorSessionId: String?
    ) -> [String] {
        guard let anchor = anchorSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !anchor.isEmpty else { return pinnedSessionIds }
        return [anchor] + pinnedSessionIds.filter { $0 != anchor }
    }

    /// Existing pins require a direct-user row; only pre-row publication may rely on the creator's declared kind.
    public static func mayAnchor(_ sessionId: String, dataRoot: URL = defaultDataRoot()) -> Bool {
        mayAnchor(sessionId, sessionsPath: path(dataRoot: dataRoot)
            .deletingLastPathComponent().appendingPathComponent("sessions.json"))
    }

    static func mayAnchor(_ sessionId: String, sessionsPath: URL) -> Bool {
        SessionConversation.kind(sessionId, dataRoot: sessionsPath.deletingLastPathComponent().deletingLastPathComponent())?.isPersonConversation == true
    }

    // MARK: - Internals

    static func readUnlocked(at path: URL) throws -> (pin: ConversationAnchorPin, activityAt: Date?)? {
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch { throw unavailable(path, error.localizedDescription) }
        let parsed: JSONValue
        do { parsed = try JSONValue.parse(data) }
        catch { throw unavailable(path, error.localizedDescription) }
        guard
              case .object(let object) = parsed,
              case .string(let sessionId)? = object["sessionId"] else {
            throw unavailable(path, "The saved anchor has no sessionId.")
        }
        let clean = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw unavailable(path, "The saved anchor has an empty sessionId.") }
        // A failed index read cannot prove the user's conversation lost ownership.
        let root = path.deletingLastPathComponent().deletingLastPathComponent()
        let sessions = try SessionConversation(dataRoot: root)
        guard sessions.kind(clean)?.isPersonConversation == true else { return nil }
        let source: String = {
            if case .string(let value)? = object["source"] { return value }
            return ""
        }()
        let updatedAt: String = {
            if case .string(let value)? = object["updatedAt"] { return value }
            return ""
        }()
        let seconds: Double? = switch object["activityAt"] {
        case .double(let value)?: value
        case .int(let value)?: Double(value)
        default: nil
        }
        return (ConversationAnchorPin(sessionId: clean, source: source, updatedAt: updatedAt),
                seconds.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil })
    }

    private static func unavailable(_ path: URL, _ reason: String) -> PersistenceCoreError {
        .ioFailure("""
            The conversation anchor at \(path.path) is unavailable: \(reason) Conversations have been left in place; repair or restore access to the saved \
            anchor, preserving its bytes.
            """)
    }

    /// Current surfaces write valid ISO8601 timestamps; precision does not change ordering. Anything unparseable makes no recency claim.
    private static func parseISO8601(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(trimmed)
    }
}
