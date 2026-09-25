import Foundation
import PersistenceCore

// MARK: - The first conversation's one write is not confirm-tier
//
// User's decision, 2026-09-15 (mockups/onboarding/NOTE.md §4.2 put the question
// to him): when the agent opens the first conversation and asks the person what
// they want it to be, the single line it writes down is NOT held behind an
// approval card.
//
// WHY THE GUARD IS WRONG HERE, SPECIFICALLY. `PersonaWriteGuard` exists because
// a permissive Trust posture would otherwise let the agent silently rewrite its
// own identity documents. That is a real hazard and the guard keeps it for every
// other persona write. But on this one turn the person has just said, in their
// own words, who they want the agent to be — and the receipt under the answer
// shows the exact sentence and the exact document it went into. Asking a
// stranger to authorize writing down the thing they just typed is not a
// confirmation, it is a form.
//
// WHAT KEEPS THIS HONEST — rewritten 2026-09-15 after Sol's review (P0-1/2/3).
// The first version was a re-evaluatable predicate over loose facts: any
// dispatcher could ask it, a prefix match let a changed suffix re-open it, and
// the "already written?" read raced the append. It is now a ONE-SHOT BEARER
// TOKEN with an atomic consume:
//
//   * The token is armed by the app ONLY after the opener actually lands, and
//     carries the chat session id it was armed for and the EXACT section title
//     that write must use (derived from the profile, not from the model).
//   * A dispatch is exempt only when it is `persona_append_section`, kind
//     `soul`, on that session, with that exact single-line title, single-line
//     content, into a SOUL.md that carries no "Who I am to …" section yet.
//   * Granting it arms ONE more token of the same shape (User, 2026-09-25):
//     kind `voice`, title "How I talk with …", into a VOICE.md without that
//     section — the answer to "how would you like me to sound".
//   * Granting it RENAMES the token. Rename is atomic on POSIX, so of any
//     number of concurrent or repeated dispatches exactly one can ever win —
//     which is what closes the check-then-append race (P0-3) without reaching
//     into the persona engine's flock. A second write is simply not exempt and
//     meets the ordinary confirm card.
//
// The token is consumed on GRANT, not on success, so a write that is admitted
// and then fails does not leave a live exemption behind. That fails closed: the
// person's next attempt gets the ordinary approval card rather than a second
// silent write.
//
// Everything else about the write is unchanged: the engine still backs the
// document up, still refuses `kind: "user"`, and SecurityCenter still records
// the dispatch. The exemption is audited at its use site rather than being
// silent (see `ChatOrchestrationClient+DispatchWrappers`).
public enum FirstConversationPersonaExemption {

    /// The section-title prefix the flow writes under. Used ONLY to detect that
    /// a role section already exists; it is never what a dispatch is matched
    /// against — that is the exact title carried in the token.
    public static let roleSectionPrefix = "Who I am to "

    /// Durable "this persona has been met" marker. Written when the opener's
    /// turn finishes; never removed.
    public static let metMarkerFilename = ".first_conversation"

    /// The one-shot exemption token.
    public static let writeTokenFilename = ".first_conversation.write"

    /// Where the token goes when it is spent. Kept rather than deleted so the
    /// trail shows the exemption was used once and by whom.
    public static let spentTokenFilename = ".first_conversation.write.spent"

    /// The only tool this exemption will ever consider.
    public static let exemptTool = "persona_append_section"

    /// The document the first answer goes into.
    public static let exemptDocument = "SOUL.md"

    // User, 2026-09-25: the natural next question is how the person would like
    // the agent to sound. Its one line goes into VOICE.md under the same
    // one-shot rules, armed only when the soul write is granted.
    public static let voiceSectionPrefix = "How I talk with "
    public static let voiceDocument = "VOICE.md"
    public static let voiceTokenFilename = ".first_conversation.voice"
    public static let voiceSpentTokenFilename = ".first_conversation.voice.spent"

    /// The exact title this flow must write under, for a given person.
    /// Computed by the app from the profile and pinned into the token, so the
    /// model cannot widen it by changing the suffix.
    public static func roleSectionTitle(personName: String) -> String {
        let trimmed = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(roleSectionPrefix)them" : "\(roleSectionPrefix)\(trimmed)"
    }

    // MARK: - Persona root, scoped to one data root

    /// The persona directory belonging to THIS data root, and only this one.
    ///
    /// Deliberately not `PersonaRootResolver.resolve`: that chain is right for
    /// "which persona is this process running", but wrong for every question
    /// asked here, because its later steps fall back to a
    /// `NATIVE_AGENT_PERSONA_ROOT` override and then to the dev checkout. A
    /// question about a scratch or test data root could therefore be answered
    /// by a completely different persona's documents — and a marker written on
    /// the way out would land in that other persona's directory. (Caught
    /// 2026-09-15: a first-run eval wrote its marker into the repo's `persona/`.)
    public static func personaRoot(
        forDataRoot dataRoot: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let parent = dataRoot.appendingPathComponent("persona", isDirectory: true)
        let entries = (try? fileManager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            if fileManager.fileExists(
                atPath: entry.appendingPathComponent(exemptDocument).path
            ) { return entry }
        }
        return parent
    }

    // MARK: - The token

    public struct WriteToken: Sendable, Equatable {
        public let sessionID: String
        public let title: String
        /// When the opener armed this token. A first conversation the person
        /// walked away from used to leave the exemption live forever — nothing
        /// but a matching write ever spent it — so an answer skipped in the
        /// morning still admitted a silent persona write that night.
        public let armedAt: Date
    }

    /// How long the exemption stays live after the opener lands.
    public static let writeTokenLifetime: TimeInterval = 3600

    /// Arm the one-shot exemption. Called by the app only once the opener's own
    /// turn has finished successfully, so no dispatch can reach a live token
    /// before the agent has actually asked the question.
    ///
    /// Re-arming is refused when a token (spent or live) already exists — the
    /// exemption is once per persona, and an armer that could overwrite a spent
    /// token would give back what the consume just took away.
    @discardableResult
    public static func armWriteToken(
        dataRoot: URL,
        sessionID: String,
        title: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let session = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sectionTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, !sectionTitle.isEmpty,
              !sectionTitle.contains("\n") else { return false }

        let root = personaRoot(forDataRoot: dataRoot, fileManager: fileManager)
        let live = root.appendingPathComponent(writeTokenFilename)
        let spent = root.appendingPathComponent(spentTokenFilename)
        guard !fileManager.fileExists(atPath: live.path),
              !fileManager.fileExists(atPath: spent.path) else { return false }

        let payload: [String: Any] = [
            "session_id": session,
            "title": sectionTitle,
            "armed_at": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try data.write(to: live, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// The live token, or nil.
    public static func liveWriteToken(
        dataRoot: URL,
        fileManager: FileManager = .default
    ) -> WriteToken? {
        let url = personaRoot(forDataRoot: dataRoot, fileManager: fileManager)
            .appendingPathComponent(writeTokenFilename)
        return decodeToken(at: url)
    }

    /// The title the exempt write used, live or spent — what the receipt row
    /// matches against so only that one write gets the settled receipt.
    public static func recordedWriteTitle(
        dataRoot: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let root = personaRoot(forDataRoot: dataRoot, fileManager: fileManager)
        return decodeToken(at: root.appendingPathComponent(writeTokenFilename))?.title
            ?? decodeToken(at: root.appendingPathComponent(spentTokenFilename))?.title
    }

    private static func decodeToken(at url: URL) -> WriteToken? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = object["session_id"] as? String,
              let title = object["title"] as? String,
              !session.isEmpty, !title.isEmpty else { return nil }
        // A token written before `armed_at` existed carries no lifetime, so it
        // reads as armed at the epoch — already expired. That fails closed:
        // the person's write meets the ordinary confirm card instead.
        let armedAt = Date(
            timeIntervalSince1970: object["armed_at"] as? TimeInterval ?? 0
        )
        return WriteToken(sessionID: session, title: title, armedAt: armedAt)
    }

    // MARK: - The decision

    /// Canonicalize a `kind` exactly as `PersonaWriteGuard` and the persona
    /// executors do (NFKC → strip → lowercase), so a fullwidth or padded kind
    /// can neither bypass the guard nor sneak into this allowlist.
    private static func canonicalKind(_ value: String?) -> String {
        (value ?? "")
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// True — and the token is SPENT — only when this exact dispatch is the one
    /// write the first conversation exists to make.
    ///
    /// Side-effecting on purpose: the rename is the exactly-once bound, and it
    /// happens last, after every check, so a refused dispatch never burns it.
    public static func consumeIfExempt(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL?,
        sessionID: String?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard tool == exemptTool, let dataRoot else { return false }
        let session = (sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return false }

        guard case .string(let rawKind)? = input["kind"],
              case .string(let rawTitle)? = input["title"],
              case .string(let rawContent)? = input["content"] else { return false }

        // Kind: soul, or the voice step it arms, and nothing else.
        let kind = canonicalKind(rawKind)
        guard kind == "soul" || kind == "voice" else { return false }

        // P0-2 — single line, both sides. A multiline title or body could carry
        // its own `## heading` and append sections nobody authorized.
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !content.isEmpty,
              !title.contains("\n"), !title.contains("\r"),
              !content.contains("\n"), !content.contains("\r") else { return false }

        let root = personaRoot(forDataRoot: dataRoot, fileManager: fileManager)
        if kind == "voice" {
            return consume(
                root: root, token: voiceTokenFilename, spent: voiceSpentTokenFilename,
                document: voiceDocument, sectionPrefix: voiceSectionPrefix,
                documentMayBeAbsent: true, session: session, title: title,
                fileManager: fileManager
            )
        }
        guard consume(
            root: root, token: writeTokenFilename, spent: spentTokenFilename,
            document: exemptDocument, sectionPrefix: roleSectionPrefix,
            documentMayBeAbsent: false, session: session, title: title,
            fileManager: fileManager
        ) else { return false }
        armVoiceStep(root: root, session: session, soulTitle: title, fileManager: fileManager)
        return true
    }

    /// One token's checks and its atomic consume.
    private static func consume(
        root: URL, token tokenName: String, spent spentName: String,
        document: String, sectionPrefix: String, documentMayBeAbsent: Bool,
        session: String, title: String, fileManager: FileManager
    ) -> Bool {
        let live = root.appendingPathComponent(tokenName)

        // The token: right session, and the EXACT title it was armed with. No
        // prefix match — that was the hole.
        guard let token = decodeToken(at: live) else { return false }
        // An exemption the person never used is deleted, not merely refused:
        // leaving it on disk kept a live bearer token sitting in the persona
        // directory for the life of the install.
        guard Date().timeIntervalSince(token.armedAt) < writeTokenLifetime else {
            try? fileManager.removeItem(at: live)
            return false
        }
        guard token.sessionID == session, token.title == title else { return false }

        // The document must still be innocent of this section, however it is
        // titled. Belt to the token's braces.
        let url = root.appendingPathComponent(document)
        let body: String
        if let read = try? String(contentsOf: url, encoding: .utf8) {
            body = read
        } else if documentMayBeAbsent, !fileManager.fileExists(atPath: url.path) {
            body = ""
        } else {
            return false
        }
        guard !bodyHasSection(body, prefix: sectionPrefix) else { return false }

        // LAST: atomic consume. Exactly one caller can win this rename.
        do {
            try fileManager.moveItem(at: live, to: root.appendingPathComponent(spentName))
            return true
        } catch {
            return false
        }
    }

    /// After the soul line is granted: arm the voice line's one-shot token.
    /// Once per persona, like the soul token. While it is live, every turn of
    /// that session carries `pendingVoiceDirective` — a one-shot directive
    /// written here could be eaten by this same turn's next tool round.
    private static func armVoiceStep(
        root: URL, session: String, soulTitle: String,
        fileManager: FileManager
    ) {
        guard soulTitle.hasPrefix(roleSectionPrefix) else { return }
        let title = voiceSectionPrefix + soulTitle.dropFirst(roleSectionPrefix.count)
        let live = root.appendingPathComponent(voiceTokenFilename)
        let payload: [String: Any] = [
            "session_id": session,
            "title": title,
            "armed_at": Date().timeIntervalSince1970,
        ]
        guard !fileManager.fileExists(atPath: live.path),
              !fileManager.fileExists(
                atPath: root.appendingPathComponent(voiceSpentTokenFilename).path),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: live, options: [.atomic])
    }

    /// The voice step's instruction, for as long as its token is live for this
    /// session (spent or an hour old ends it). Nil everywhere else, so every
    /// other turn is byte-identical.
    public static func pendingVoiceDirective(
        dataRoot: URL?,
        sessionID: String?,
        fileManager: FileManager = .default
    ) -> String? {
        guard let dataRoot, let sessionID, !sessionID.isEmpty else { return nil }
        let live = personaRoot(forDataRoot: dataRoot, fileManager: fileManager)
            .appendingPathComponent(voiceTokenFilename)
        guard fileManager.fileExists(atPath: live.path),
              let token = decodeToken(at: live),
              token.sessionID == sessionID,
              Date().timeIntervalSince(token.armedAt) < writeTokenLifetime else { return nil }
        return """
        [First conversation. After writing who you are to them, you ask (once) how they \
        would like you to sound. When they answer it, write ONE line with \
        persona_append_section(kind: "voice", title: "\(token.title)"): a single first-person \
        sentence, on one line, built only from what they said. If they named someone to sound \
        like, write that person's style — cadence, humor, warmth, vocabulary, energy (e.g. \
        "dry, deadpan, short sentences, understated humor") — never a claim to be them; SOUL.md \
        stays who you are. Use that title exactly and say once it can change any time. In that \
        same reply hand the floor back: the open door — "If there's anything you'd rather I \
        never do, tell me whenever it comes to mind." — and one question: "What are you \
        working on?" If they skipped it or asked something else, answer them, keep your \
        default voice, write nothing, and do not raise it again. Never mention this note.]
        """
    }

    public static func bodyHasRoleSection(_ body: String) -> Bool {
        bodyHasSection(body, prefix: roleSectionPrefix)
    }

    /// True when a persona document already carries a `## <prefix>…` heading.
    /// Matching on the heading rather than raw text keeps a person who happened
    /// to type those words inside an answer from tripping it.
    static func bodyHasSection(_ body: String, prefix sectionPrefix: String) -> Bool {
        let prefix = sectionPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("##") else { continue }
            let heading = String(trimmed.drop(while: { $0 == "#" }))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if heading.hasPrefix(prefix) { return true }
        }
        return false
    }
}
