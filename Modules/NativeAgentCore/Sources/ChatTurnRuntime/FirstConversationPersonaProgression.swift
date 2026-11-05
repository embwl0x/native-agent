import Foundation
import PersistenceCore
import PersonaEngine
import NativeAgentShared
import NativeAgentCore
import Experiences

// Blueprint: | `FirstConversationPersonaProgression.swift` | `FirstConversationPersonaProgression`; One-shot session/title progression |

// Exact-session, exact-title one-shot tokens order persona progression; Trust still authorizes every write.
public enum FirstConversationPersonaProgression {

    /// Use the prefix only to detect an existing role section; admission must match the token's exact title.
    public static let roleSectionPrefix = "Who I am to "

    /// Keep the durable completion marker so the opener cannot repeat.
    public static let metMarkerFilename = ".first_conversation"

    public static let writeTokenFilename = ".first_conversation.write"

    /// Retain spent tokens as evidence that the step completed.
    public static let spentTokenFilename = ".first_conversation.write.spent"

    public static let writeTool = "persona_append_section"

    public static let soulDocument = "SOUL.md"

    // Arm voice only after the matching soul write spends its token.
    public static let voiceSectionPrefix = "How I talk with "
    public static let voiceDocument = "VOICE.md"
    public static let voiceTokenFilename = ".first_conversation.voice"
    public static let voiceSpentTokenFilename = ".first_conversation.voice.spent"
    public static let voiceDeliveredFilename = ".first_conversation.voice.delivered"

    /// Pin the profile-derived title in the token so the model cannot widen its section by changing a suffix.
    public static func roleSectionTitle(personName: String) -> String {
        let trimmed = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(roleSectionPrefix)\(trimmed)"
    }

    // MARK: - The token

    static let voiceQuestion = """
    Ask how they would like you to sound with them, close to: "And how would you like me \
    to sound? Energetic, calm, serious, playful, joking, sarcastic, warm, blunt — or name \
    someone you'd like me to sound like."
    """

    static func roleAnswerInstruction(title: String) -> String {
        """
        When they answer what they want you to be, repeat it back in THEIR words — no praise, \
        no label — and write ONE line with app {action:"persona.append",args:{kind:"soul",title:"\(title)",content}}. \
        Use that exact title and a single first-person sentence on one line, based only on \
        what they actually said. A one-word answer gets a one-clause line. You may say once \
        you are writing it as who you are rather than as a setting. Then, in the same reply: \
        \(voiceQuestion) If they skip or ask something else, answer them, write nothing and \
        never raise either question again.
        """
    }

    static let voiceAnswerInstruction = """
    Use the exact voice title supplied by this step and one first-person sentence on one \
    line, based only on their words. A named person's style means cadence, humor, warmth, \
    vocabulary and energy, never their identity; SOUL.md remains who you are. Say once the \
    voice can change any time. If they skip or ask something else, answer them, keep your \
    default voice, write nothing and never ask again.
    """

    static let handBackInstruction = """
    Hand the floor back in one turn: the rest you will pick up from working with them. \
    Say "If there's anything you'd rather I never do, tell me whenever it comes to mind." \
    and ask "What are you working on?"
    """

    static func nextTurnDirective(title: String) -> String {
        "[First conversation. You have just asked this person what they want you to be. \(roleAnswerInstruction(title: title)) Never mention this note.]"
    }

    public struct WriteToken: Sendable, Equatable {
        public let sessionID: String
        public let title: String
        /// Expire unanswered steps after one hour.
        public let armedAt: Date
    }

    public static let writeTokenLifetime: TimeInterval = 3600

    /// Create once, or verify the exact already-committed intent during settlement repair.
    public static func armWriteToken(
        dataRoot: URL,
        sessionID: String,
        title: String,
        token: String, spent spentName: String,
        fileManager: FileManager = .default
    ) throws {
        let session = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sectionTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, !sectionTitle.isEmpty,
              !sectionTitle.contains("\n"), !sectionTitle.contains("\r") else {
            throw ToolFailureError("First-conversation progression needs an exact session and single-line title.", effects: .none)
        }

        let root = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot)
        let live = root.appendingPathComponent(token)
        let spent = root.appendingPathComponent(spentName)
        var alreadyArmed = false
        for path in [spent, live] {
            if let saved = try decodeToken(at: path) {
                guard saved.sessionID == session, saved.title == sectionTitle else {
                    throw ToolFailureError("""
                        First-conversation progression at \(path.path) belongs to another session or title. Preserve it and \
                        reconcile before continuing.
                        """, effects: .none)
                }
                alreadyArmed = true
            }
        }
        if alreadyArmed { return }

        let payload: [String: Any] = [
            "session_id": session,
            "title": sectionTitle,
            "armed_at": Date().timeIntervalSince1970,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: live)
        guard let saved = try decodeToken(at: live), saved.sessionID == session, saved.title == sectionTitle else {
            throw ToolFailureError("The first-conversation token did not read back at \(live.path). Repair the retained progression before continuing.",
                effects: .unknown)
        }
    }

    /// Match the receipt against the live or spent token's exact title so unrelated writes cannot settle it.
    public static func recordedWriteTitle(
        dataRoot: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let root = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot)
        do {
            return try decodeToken(at: root.appendingPathComponent(writeTokenFilename))?.title
                ?? decodeToken(at: root.appendingPathComponent(spentTokenFilename))?.title
        } catch {
            RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .run, operation: "first_conversation.token",
                owner: root.path, words: """
                    The first-conversation token is unavailable: \(error.localizedDescription). Repair its retained file; no spent-token title was \
                    substituted.
                    """)
            return nil
        }
    }

    private static func decodeToken(at url: URL) throws -> WriteToken? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = object["session_id"] as? String,
              let title = object["title"] as? String,
              !session.isEmpty, !title.isEmpty,
              let seconds = object["armed_at"] as? TimeInterval, seconds.isFinite else {
            throw ToolFailureError("""
                The first-conversation token is malformed: \(url.path). Repair its retained session, title and armed_at before advancing the \
                conversation.
                """, effects: .none, owner: url.path, recovery: .repair)
        }
        let armedAt = Date(timeIntervalSince1970: seconds)
        return WriteToken(sessionID: session, title: title, armedAt: armedAt)
    }

    private static func exists(_ url: URL) throws -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return false }
    }

    // MARK: - The decision

    /// Called only after a successful authorized persona append. This bookkeeping
    /// cannot authorize a write, and failed/preview/admission-only calls never enter it.
    public static func settleSuccessfulWrite(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL?,
        sessionID: String?,
        fileManager: FileManager = .default
    ) async throws -> Bool {
        guard tool == writeTool, let dataRoot else { return false }
        let session = (sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return false }

        guard case .string(let rawKind)? = input["kind"],
              case .string(let rawTitle)? = input["title"],
              case .string(let rawContent)? = input["content"] else { return false }

        let kind = SwiftNativePersonaEngine.canonicalizeKind(rawKind)
        guard kind == "soul" || kind == "voice" else { return false }

        // Both title and body are single lines, so neither can introduce another section.
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !content.isEmpty,
              !title.contains("\n"), !title.contains("\r"),
              !content.contains("\n"), !content.contains("\r") else { return false }

        let root = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot)
        let live = root.appendingPathComponent(kind == "voice" ? voiceTokenFilename : writeTokenFilename)
        nonisolated(unsafe) let fileManager = fileManager
        return try await SwiftNativePersistenceCore.withFileLock(live) {
            guard let token = try decodeToken(at: live), token.sessionID == session, token.title == title,
                  Date().timeIntervalSince(token.armedAt) < writeTokenLifetime else { return false }
            let document = root.appendingPathComponent(kind == "voice" ? voiceDocument : soulDocument)
            let body = try String(contentsOf: document, encoding: .utf8)
            // The writer appends the trimmed title and unmodified content. A success
            // response alone cannot stand in for these committed persona bytes.
            guard body.contains("\n\n## \(title)\n\(rawContent)") else {
                throw ToolFailureError("""
                    The successful persona append could not be verified at \(document.path). Read it before repeating the write; progression remains \
                    owed.
                    """, effects: .unknown)
            }
            if kind == "soul" {
                guard title.hasPrefix(roleSectionPrefix) else { return false }
                try armWriteToken(dataRoot: dataRoot, sessionID: session,
                    title: voiceSectionPrefix + title.dropFirst(roleSectionPrefix.count),
                    token: voiceTokenFilename, spent: voiceSpentTokenFilename, fileManager: fileManager)
            }
            // Commit the next step first. A failed settlement keeps the source token
            // and exact intent for repair, never inviting another persona append.
            let spent = root.appendingPathComponent(kind == "voice" ? voiceSpentTokenFilename : spentTokenFilename)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(contentsOf: live), to: spent)
            try fileManager.removeItem(at: live)
            try SwiftNativePersistenceCore.syncDirectory(root)
            return true
        }
    }

    /// The voice step's instruction until provider acceptance, while its write
    /// token is live for this session. Delivery never spends write eligibility.
    public static func pendingVoiceDirective(
        dataRoot: URL?,
        sessionID: String?,
        fileManager: FileManager = .default
    ) throws -> String? {
        guard let dataRoot, let sessionID, !sessionID.isEmpty else { return nil }
        let root = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot)
        guard try !exists(root.appendingPathComponent(voiceDeliveredFilename)) else { return nil }
        let live = root.appendingPathComponent(voiceTokenFilename)
        guard let token = try decodeToken(at: live),
              token.sessionID == sessionID,
              Date().timeIntervalSince(token.armedAt) < writeTokenLifetime else { return nil }
        return """
        [First conversation: after writing who you are to them: \(voiceQuestion) \
        On their answer, use app {action:"persona.append",args:{kind:"voice",title:"\(token.title)",content}}. \
        \(voiceAnswerInstruction) \(handBackInstruction) Do not mention this note.]
        """
    }

    public static func markVoiceDirectiveDelivered(dataRoot: URL, sessionID: String, expectedDirective: String) throws {
        guard try pendingVoiceDirective(dataRoot: dataRoot, sessionID: sessionID) == expectedDirective else { return }
        let path = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot).appendingPathComponent(voiceDeliveredFilename)
        try Data().write(to: path, options: .withoutOverwriting)
    }

    public static func bodyHasRoleSection(_ body: String) -> Bool {
        bodyHasSection(body, prefix: roleSectionPrefix)
    }

    /// Match actual headings so quoted role words inside an answer cannot falsely complete progression.
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
