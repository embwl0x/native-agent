import Foundation
import PersistenceCore
import PersonaEngine
import NativeAgentShared

// Blueprint: | `FirstConversationPersonaProgression.swift` | `FirstConversationPersonaProgression`: exact-session one-shot progression tokens and pending voice step; Trust authorizes writes; atomic spending prevents reuse |

// The first conversation progresses from SOUL.md to VOICE.md by spending
// exact-session, exact-title one-shot tokens. Trust authorizes every write.
public enum FirstConversationPersonaProgression {

    /// The section-title prefix the flow writes under. Used ONLY to detect that
    /// a role section already exists; it is never what a dispatch is matched
    /// against — that is the exact title carried in the token.
    public static let roleSectionPrefix = "Who I am to "

    /// Durable "this persona has been met" marker. Written when the opener's
    /// turn finishes; never removed.
    public static let metMarkerFilename = ".first_conversation"

    /// The one-shot progression token.
    public static let writeTokenFilename = ".first_conversation.write"

    /// Where the token goes when it is spent. Kept rather than deleted so the
    /// trail records that this step was completed.
    public static let spentTokenFilename = ".first_conversation.write.spent"

    /// The tool whose matching write advances the conversation.
    public static let writeTool = "persona_append_section"

    /// The document the first answer goes into.
    public static let soulDocument = "SOUL.md"

    // The voice step opens after the matching soul write spends its token.
    public static let voiceSectionPrefix = "How I talk with "
    public static let voiceDocument = "VOICE.md"
    public static let voiceTokenFilename = ".first_conversation.voice"
    public static let voiceSpentTokenFilename = ".first_conversation.voice.spent"
    public static let voiceDeliveredFilename = ".first_conversation.voice.delivered"

    /// The exact title this flow must write under, for a given person.
    /// Computed by the app from the profile and pinned into the token, so the
    /// model cannot widen it by changing the suffix.
    public static func roleSectionTitle(personName: String) -> String {
        let trimmed = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(roleSectionPrefix)them" : "\(roleSectionPrefix)\(trimmed)"
    }

    // MARK: - The token

    public struct WriteToken: Sendable, Equatable {
        public let sessionID: String
        public let title: String
        /// When this step was armed; an unanswered step expires after one hour.
        public let armedAt: Date
    }

    /// How long the token stays live after the opener lands.
    public static let writeTokenLifetime: TimeInterval = 3600

    /// Arm a step once per persona; a live or spent token prevents re-arming.
    @discardableResult
    public static func armWriteToken(
        dataRoot: URL,
        sessionID: String,
        title: String,
        token: String, spent spentName: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let session = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sectionTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, !sectionTitle.isEmpty,
              !sectionTitle.contains("\n") else { return false }

        let root = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot)
        let live = root.appendingPathComponent(token)
        let spent = root.appendingPathComponent(spentName)
        guard !fileManager.fileExists(atPath: live.path),
              !fileManager.fileExists(atPath: spent.path) else { return false }

        let payload: [String: Any] = [
            "session_id": session,
            "title": sectionTitle,
            "armed_at": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return NativePrivateFile.write(data, to: live)
    }

    /// The title the matching write used, live or spent — what the receipt row
    /// matches against so only that one write gets the settled receipt.
    public static func recordedWriteTitle(
        dataRoot: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let root = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot)
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

    /// Match the persona writer's NFKC, whitespace and case normalization.
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
    public static func advanceIfMatching(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL?,
        sessionID: String?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard tool == writeTool, let dataRoot else { return false }
        let session = (sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return false }

        guard case .string(let rawKind)? = input["kind"],
              case .string(let rawTitle)? = input["title"],
              case .string(let rawContent)? = input["content"] else { return false }

        // Kind: soul, or the voice step it arms, and nothing else.
        let kind = canonicalKind(rawKind)
        guard kind == "soul" || kind == "voice" else { return false }

        // Both title and body are single lines, so neither can introduce another section.
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !content.isEmpty,
              !title.contains("\n"), !title.contains("\r"),
              !content.contains("\n"), !content.contains("\r") else { return false }

        let root = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot)
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
            document: soulDocument, sectionPrefix: roleSectionPrefix,
            documentMayBeAbsent: false, session: session, title: title,
            fileManager: fileManager
        ) else { return false }
        if title.hasPrefix(roleSectionPrefix) {
            _ = armWriteToken(dataRoot: dataRoot, sessionID: session,
                title: voiceSectionPrefix + title.dropFirst(roleSectionPrefix.count),
                token: voiceTokenFilename, spent: voiceSpentTokenFilename, fileManager: fileManager)
        }
        return true
    }

    /// One token's checks and its atomic consume.
    private static func consume(
        root: URL, token tokenName: String, spent spentName: String,
        document: String, sectionPrefix: String, documentMayBeAbsent: Bool,
        session: String, title: String, fileManager: FileManager
    ) -> Bool {
        let live = root.appendingPathComponent(tokenName)

        // Spending requires the exact armed session and title.
        guard let token = decodeToken(at: live) else { return false }
        // An expired step is removed and cannot be spent.
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

    /// The voice step's instruction until provider acceptance, while its write
    /// token is live for this session. Delivery never spends write eligibility.
    public static func pendingVoiceDirective(
        dataRoot: URL?,
        sessionID: String?,
        fileManager: FileManager = .default
    ) -> String? {
        guard let dataRoot, let sessionID, !sessionID.isEmpty else { return nil }
        let root = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot)
        guard !fileManager.fileExists(atPath: root.appendingPathComponent(voiceDeliveredFilename).path) else { return nil }
        let live = root.appendingPathComponent(voiceTokenFilename)
        guard fileManager.fileExists(atPath: live.path),
              let token = decodeToken(at: live),
              token.sessionID == sessionID,
              Date().timeIntervalSince(token.armedAt) < writeTokenLifetime else { return nil }
        return """
        [First conversation: after writing who you are to them, ask once how they want you \
        to sound. On their answer, use app {action:"persona.append",args:{kind:"voice",title:"\(token.title)",content}} \
        with that exact title and one first-person sentence on one line, based only on their words. \
        A named person's style means cadence, humor, warmth, vocabulary and energy, never their identity; \
        SOUL.md remains who you are. Say once the voice can change any time. In the same reply say \
        "If there's anything you'd rather I never do, tell me whenever it comes to mind." \
        and ask "What are you working on?" If they skip the voice question or ask something else, \
        answer them, keep your default voice, write nothing and never ask again. Do not mention this note.]
        """
    }

    public static func markVoiceDirectiveDelivered(dataRoot: URL, sessionID: String, expectedDirective: String) {
        guard pendingVoiceDirective(dataRoot: dataRoot, sessionID: sessionID) == expectedDirective else { return }
        let path = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot).appendingPathComponent(voiceDeliveredFilename)
        do { try Data().write(to: path, options: .withoutOverwriting) }
        catch { nativeLog("Voice instruction delivery could not be recorded: \(error)") }
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
