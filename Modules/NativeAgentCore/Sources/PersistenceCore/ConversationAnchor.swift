import Foundation
import NativeAgentCore

// MARK: - The conversation anchor
//
// User, 2026-09-01: "I use /new to clear Agent's head." He does NOT want one
// eternal absorbing thread. What he wants is that the conversation he is
// ACTUALLY IN — right now, on his phone, wherever — is one tap away on the Mac
// and on the iPhone, without any surface losing its own multiple sessions.
//
// That is this file, and it is deliberately tiny. There is no routing table,
// no attachment graph, no thread key space, no feature flag. There is ONE
// durable fact:
//
//     the session id of the remote conversation most recently made active
//
// Publishers write it. The Mac and the phone pin and default to it. Retention
// refuses to archive it. Nothing else changes: every surface keeps minting and
// selecting its own sessions exactly as before, and the anchor is simply the
// one everybody agrees to keep in front.
//
// # SURFACE-AGNOSTIC BY CONSTRUCTION
//
// NativeAgent is built so any messaging surface can be connected later —
// Signal, WhatsApp, whatever User adds. Telegram is merely the only publisher
// that exists today, and NOTHING in this file knows that. A new adapter calls
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
// neither case required an edit here.
//
// # MOST-RECENT WINS
//
// If User is talking on two remote surfaces, the anchor is the one he most
// recently became active on. That is the only rule, it needs no arbitration
// table, and it degrades correctly as surfaces are added.

/// The published anchor. Deliberately three fields — anything more would be a
/// routing table wearing a pin's name.
public struct ConversationAnchorPin: Sendable, Equatable, Codable {
    /// The chat session id the anchor names. A storage key, as always: it is
    /// NOT identity and confers no trust (see `TurnEnvelope`).
    public let sessionId: String
    /// Which surface published it — for display and diagnostics ONLY. No
    /// consumer may branch on this value.
    public let source: String
    /// ISO8601. Most recent publish wins.
    public let updatedAt: String

    public init(sessionId: String, source: String, updatedAt: String) {
        self.sessionId = sessionId
        self.source = source
        self.updatedAt = updatedAt
    }
}

/// The publish/consume seam. Static because it owns exactly one file and has
/// no state of its own.
public enum ConversationAnchor {
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
        /// A shared room, a builder lane, or a probe. Only a direct
        /// conversation with the human may be the anchor.
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
        /// Already the anchor; the file was not rewritten. Republishing the
        /// same id on every inbound message would churn the file and the phone
        /// snapshot for no change.
        case unchanged(ConversationAnchorPin)
        case refused(PublishRefusal)
    }

    /// Publish `sessionId` as the anchor.
    ///
    /// # For a new surface adapter
    ///
    /// Call this whenever the conversation the human is active in CHANGES —
    /// the first message of a conversation, and again whenever the human
    /// starts a fresh one (Telegram's `/new`, a `/resume` onto a different
    /// session). Do not call it per message; `unchanged` makes that harmless,
    /// but it is not what the hook is for.
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
    @discardableResult
    public static func publish(
        sessionId: String,
        source: String,
        conversationKind: ChatThreadKind,
        dataRoot: URL = defaultDataRoot(),
        now: Date = Date(),
        persistence: PersistenceCoreProtocol = SwiftNativePersistenceCore()
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

        return try await persistence.withFileLock(sessionsPath) { () async throws -> PublishOutcome in
            let parent = anchorPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let existing = readUnlocked(at: anchorPath)
            if let existing, existing.sessionId == cleanSession {
                return .unchanged(existing)
            }
            // THE STAMP IS TAKEN HERE, INSIDE THE LOCK — not at call time.
            //
            // "Most recent wins" is the anchor's only rule, so the thing that
            // decides a race has to be the thing that serializes it. Stamping
            // before the lock let a publish that then stalled (a slow adapter,
            // a contended lock, a suspended task) commit a timestamp OLDER than
            // one already on disk, silently reinstating a conversation User had
            // already left with `/new`. Stamping under the lock makes lock
            // order publish order, and the recency check below then holds
            // trivially for anything the clock cannot order — a skewed or
            // deliberately-supplied `now`.
            let committedAt = max(now, Date())
            if let existing,
               let existingAt = parseISO8601(existing.updatedAt),
               existingAt > committedAt {
                return .refused(.supersededByNewerAnchor)
            }
            let pin = ConversationAnchorPin(
                sessionId: cleanSession,
                source: cleanSource,
                updatedAt: iso8601(committedAt)
            )
            try await persistence.writeJSON(
                .object([
                    "sessionId": .string(pin.sessionId),
                    "source": .string(pin.source),
                    "updatedAt": .string(pin.updatedAt),
                ]),
                to: anchorPath
            )
            return .published(pin)
        }
    }

    /// The current anchor, or nil. A plain read — no lock, because a torn read
    /// of an atomically-written file is not possible and a stale-by-milliseconds
    /// pin is harmless (the next refresh corrects it).
    public static func current(dataRoot: URL = defaultDataRoot()) -> ConversationAnchorPin? {
        readUnlocked(at: path(dataRoot: dataRoot))
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

    // MARK: - Defaulting to the anchor without yanking the human

    /// Whether the main chat window should adopt the anchor as its selection.
    ///
    /// THE RULE, and the reason it is a function rather than an assignment:
    /// default to the anchor, but NEVER take the human off a session they
    /// chose. Same protection iOS already gives itself in
    /// `shouldReturnToMainSession` — a snapshot arriving mid-thought must not
    /// move the screen.
    ///
    /// - `userChoseThisLaunch`: the human has explicitly selected or created a
    ///   session since this launch. Once true, this returns false forever.
    /// - `liveSessionIds`: the anchor must actually exist and be live;
    ///   selecting an archived or unknown id would empty the window.
    public static func shouldAdoptAnchor(
        anchorSessionId: String?,
        currentSelection: String,
        userChoseThisLaunch: Bool,
        liveSessionIds: Set<String>
    ) -> Bool {
        guard !userChoseThisLaunch else { return false }
        guard let anchor = anchorSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !anchor.isEmpty,
              liveSessionIds.contains(anchor) else { return false }
        return currentSelection.trimmingCharacters(in: .whitespacesAndNewlines) != anchor
    }

    // MARK: - Internals

    static func readUnlocked(at path: URL) -> ConversationAnchorPin? {
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .object(let object) = parsed,
              case .string(let sessionId)? = object["sessionId"] else { return nil }
        let clean = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let source: String = {
            if case .string(let value)? = object["source"] { return value }
            return ""
        }()
        let updatedAt: String = {
            if case .string(let value)? = object["updatedAt"] { return value }
            return ""
        }()
        return ConversationAnchorPin(sessionId: clean, source: source, updatedAt: updatedAt)
    }

    /// Lenient on purpose: a pin written by an older build, or by a surface
    /// that omitted fractional seconds, must not be treated as "unorderable
    /// therefore newer" — that would wedge the anchor permanently. Anything
    /// unparseable simply makes no recency claim and loses.
    private static func parseISO8601(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
