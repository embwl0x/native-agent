import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared

// Blueprint: | `ConversationAnchor.swift` | `ConversationAnchor`: shared current-person conversation publication, protected sessions and adoption decisions across surfaces; only a session whose row records it as their direct conversation may anchor (`mayAnchor`), whatever door publishes |

// MARK: - The conversation anchor
//
// Keep the person's current conversation one tap away without merging surfaces' sessions.
//
// That is this file, and it is deliberately tiny. There is no routing table,
// no attachment graph, no thread key space, no feature flag. There is ONE
// durable fact:
//
//     the session id of the person's conversation most recently made active
//
// Publishers write it. The Mac and the phone pin and default to it. Retention
// refuses to archive it. Nothing else changes: every surface keeps minting and
// selecting its own sessions exactly as before, and the anchor is simply the
// one everybody agrees to keep in front.
//
// # SURFACE-AGNOSTIC BY CONSTRUCTION
//
// NativeAgent is built so any messaging surface can be connected later —
// Signal, WhatsApp, whatever User adds. The owner's private Telegram chat, the
// Mac composer, the phone and Siri publish it; Slack does not currently publish.
// Nothing in this owner branches on that list. A new adapter calls
// `publish` with its own source name and its own conversation kind; the
// consuming side (Mac pin strip, main-window default, iOS snapshot, retention)
// reads `ConversationAnchor.current` and never mentions any surface by name.
// If a consumer ever needs a `if source == "telegram"`, this design has failed.
//
// # WHY KIND, NOT A SURFACE ALLOWLIST
//
// A Slack channel must never become the anchor: it is a shared room with other
// humans in it, not User's conversation. Expressing that as a list of surface
// names would be exactly the coupling this file exists to avoid — and it would
// be wrong the moment someone connects a surface that has both DMs and rooms.
// So the ADAPTER declares what the conversation IS (`ChatThreadKind`), and only
// `.direct` may anchor. A Signal DM anchors; a Signal group would not; and
// neither case required an edit here. Once a session has a row, the kind
// recorded on it when it was created (`threadKind`) decides, not the door
// that publishes: her conversation with another agent or a helper's own
// thread is never his, even when User types in it, and a pin that names one is
// never read (`mayAnchor`). `SessionConversation` is the shared row reader;
// this anchor owns no separate classification rule.
//
// # MOST-RECENT WINS
//
// If User is talking on two remote surfaces, the anchor is the one he most
// recently became active on. That is the only rule, it needs no arbitration
// table, and it degrades correctly as surfaces are added.

/// The publish/consume seam. Static because it owns exactly one file and has
/// no state of its own.
/// Storage: anchor_pin.json is excluded from local backup and data export;
/// included in off-disk backup, the phone's chat navigation and PrivacyMap/chat.
public enum ConversationAnchor {
    /// Posted after a publish moves the anchor.
    public static let didPublish = Notification.Name("NativeAgent.ConversationAnchor.didPublish")

    /// `<dataRoot>/chat/anchor_pin.json`.
    public static func path(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("anchor_pin.json")
    }

    /// Why a publish was refused. Refusals are VALUES, not silence: a surface
    /// adapter that anchors nothing should be able to say why.
    public enum PublishRefusal: String, Sendable, Equatable {
        /// No session id.
        case emptySessionID
        /// A shared room, another agent's thread, a builder lane, or a probe.
        /// Only a direct conversation with the human may be the anchor.
        case notADirectConversation
        /// No source name. An anchor nobody can attribute is not honest.
        case emptySource
        /// A NEWER anchor is already published. Most-recent wins, so a publish
        /// that stalled behind the lock does not get to reinstate the
        /// conversation the human has already moved on from.
        case supersededByNewerAnchor
    }

    public enum PublishOutcome: Sendable, Equatable {
        case published(ConversationAnchorPin)
        /// Already the anchor. New activity still advances its ordering stamp;
        /// no identity-change notification is posted.
        case unchanged(ConversationAnchorPin)
        case refused(PublishRefusal)
    }

    /// Publish `sessionId` as the anchor.
    ///
    /// # For a new surface adapter
    ///
    /// Call this whenever USER sends at that door, declaring what the session
    /// is (an agent contact's thread he types in is `.agent`), and on
    /// `/new`/`/resume`.
    /// A same-session publish advances activity without an identity-change
    /// notification. Never call it for a turn
    /// an agent, peer, bot or wake started: those must not move him.
    ///
    /// # Locking
    ///
    /// Written under the SHARED `chat/sessions.json` lock, not under a lock of
    /// its own. The anchor and the session index are read together — retention
    /// consults the anchor while holding the sessions lock to decide what it
    /// may archive — so giving the anchor a second lock would create two
    /// orders to acquire them in, which is how deadlocks are built. One lock,
    /// one order, no new discipline to remember.
    ///
    /// Best-effort by design: a publish failure must never fail the human's
    /// message. It returns the refusal or throws the IO error to a caller that
    /// is expected to log and continue.
    /// `now` is the accepted selection intent's activity time. Capture it before
    /// detaching or awaiting publication; lock acquisition is not human activity.
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
            guard (sessions.kind(cleanSession) ?? conversationKind).isHisConversation else { return .refused(.notADirectConversation) }
            let parent = anchorPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let existing = readUnlocked(at: anchorPath)
            // Preserve activity order even if an older publication was delayed.
            // The numeric stamp retains precision lost by ISO display formatting.
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

    /// The current anchor, or nil — nil too when the pin names a conversation
    /// that is not his own with her (written before its row was consulted).
    /// A plain read — no lock, because a torn read
    /// of an atomically-written file is not possible and a stale-by-milliseconds
    /// pin is harmless (the next refresh corrects it).
    public static func current(dataRoot: URL = defaultDataRoot()) -> ConversationAnchorPin? {
        readUnlocked(at: path(dataRoot: dataRoot))?.pin
    }

    /// Convenience for the common consumer: just the id.
    public static func currentSessionId(dataRoot: URL = defaultDataRoot()) -> String? {
        current(dataRoot: dataRoot)?.sessionId
    }

    /// Retention's hook. The anchor is the conversation User is IN; archiving it
    /// out from under him because 200 other rows are newer would be the worst
    /// possible moment to enforce a cap.
    ///
    /// Deliberately independent of the pinned-session mechanism: the Mac's pin
    /// strip auto-INCLUDES the anchor for visibility, but a human can unpin
    /// anything, and an unpin must not be able to make the live conversation
    /// archivable.
    public static func protectedSessionIds(dataRoot: URL = defaultDataRoot()) -> Set<String> {
        guard let id = currentSessionId(dataRoot: dataRoot) else { return [] }
        return [id]
    }

    /// Put the anchor at the FRONT of a pinned-session list, without disturbing
    /// the human's own pins or their order, and without duplicating it if they
    /// have already pinned it themselves.
    ///
    /// This is the whole Mac/iOS consumption story, and it is intentionally a
    /// pure function over a list: auto-pinning by WRITING to
    /// `pinned_session_ids.json` would fight the human every time they unpinned
    /// it, and would rewrite the file (and re-publish the phone snapshot) on
    /// every `/new`.
    public static func merged(
        into pinnedSessionIds: [String],
        dataRoot: URL = defaultDataRoot()
    ) -> [String] {
        merged(into: pinnedSessionIds, anchorSessionId: currentSessionId(dataRoot: dataRoot))
    }

    /// Testable core of `merged(into:dataRoot:)`.
    public static func merged(
        into pinnedSessionIds: [String],
        anchorSessionId: String?
    ) -> [String] {
        guard let anchor = anchorSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !anchor.isEmpty else { return pinnedSessionIds }
        return [anchor] + pinnedSessionIds.filter { $0 != anchor }
    }

    /// Only a row recording his direct conversation with her may anchor.
    /// Helper, peer and builder conversations never anchor, whoever types in them.
    /// Before a row exists, publish may use its creator's declared kind;
    /// reading an existing pin requires a row.
    public static func mayAnchor(_ sessionId: String, dataRoot: URL = defaultDataRoot()) -> Bool {
        mayAnchor(sessionId, sessionsPath: path(dataRoot: dataRoot)
            .deletingLastPathComponent().appendingPathComponent("sessions.json"))
    }

    static func mayAnchor(_ sessionId: String, sessionsPath: URL) -> Bool {
        SessionConversation.kind(sessionId, dataRoot: sessionsPath.deletingLastPathComponent().deletingLastPathComponent())?.isHisConversation == true
    }

    // MARK: - Internals

    static func readUnlocked(at path: URL) -> (pin: ConversationAnchorPin, activityAt: Date?)? {
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .object(let object) = parsed,
              case .string(let sessionId)? = object["sessionId"] else { return nil }
        let clean = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              mayAnchor(clean, sessionsPath: path.deletingLastPathComponent().appendingPathComponent("sessions.json"))
        else { return nil }
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

    /// Lenient on purpose: a pin written by an older build, or by a surface
    /// that omitted fractional seconds, must not be treated as "unorderable
    /// therefore newer" — that would wedge the anchor permanently. Anything
    /// unparseable simply makes no recency claim and loses.
    private static func parseISO8601(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(trimmed)
    }
}
