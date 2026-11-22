import Experiences
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore

// Blueprint: | `UserEye.swift` | `UserEye`: the agent's attunement to the user's eye: a revision the user made of their words, held for their next turn in that conversation as one line in their inner stream, stamped on provider acceptance |

/// The user's eye. The user can often pick the better of two versions before they can say why; their revision of her words is that choice.
/// When the user revises a message of hers (the Mac transcript's Revise), the pair is held for that conversation, and her next accepted turn
/// there carries both versions once, in her own voice. What the difference means is hers to judge: she keeps competing readings of it in her
/// memory as one open question, offers the other version where her readings would write differently, and lets the user's next choice settle
/// it into their way, a preference she recalls like any other. The stem keeps no readings and judges nothing.
public enum UserEye {
    public struct Revision: Codable, Equatable, Sendable {
        /// This revision's own identity: release and delivery name it, never a time read back from disk.
        public let id: String
        /// Her message the user revised.
        public let message: String
        public let hers: String
        public let theirs: String
        public let at: Date
        public var deliveredAt: Date?

        public init(message: String, hers: String, theirs: String, at: Date = Date(), deliveredAt: Date? = nil) {
            id = UUID().uuidString
            self.message = message
            self.hers = hers
            self.theirs = theirs
            self.at = at
            self.deliveredAt = deliveredAt
        }
    }

    static func url(dataRoot: URL, sessionID: String) -> URL? {
        NativeAgentChatSessionID.normalizedPathComponent(sessionID).map {
            dataRoot.appendingPathComponent("mind/eye", isDirectory: true).appendingPathComponent($0 + ".json")
        }
    }

    /// Holds the user's revision for the conversation's next turn; the newest revision is the one held.
    public static func hold(_ revision: Revision, dataRoot: URL, sessionID: String) throws {
        guard let url = url(dataRoot: dataRoot, sessionID: sessionID) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: "The revision has an invalid conversation identity."])
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(revision), to: url)
        RepairOwed.settle(dataRoot, operation: readOperation, evidence: .init(source: "mind/eye", id: sessionID))
    }

    /// A held revision that cannot be read owes repair under this operation; the next write settles it.
    public static let readOperation = "user.eye.read"

    /// A revision whose send was refused never reached her; it is let go so another turn does not carry it.
    public static func release(_ revision: Revision, dataRoot: URL, sessionID: String) {
        guard let url = url(dataRoot: dataRoot, sessionID: sessionID), (try? load(url))?.id == revision.id else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The held revision not yet delivered and the line her turn carries for it; nil when there is none.
    public static func pending(dataRoot: URL, sessionID: String) throws -> (id: String, line: String)? {
        guard let url = url(dataRoot: dataRoot, sessionID: sessionID), let revision = try load(url), revision.deliveredAt == nil else { return nil }
        let name = try MemoryRecallQueryExpansion.names(storeDirectory: dataRoot.appendingPathComponent("memory", isDirectory: true)).user
            ?? "the person"
        return (revision.id, line(revision, name: name))
    }

    /// Provider acceptance of a context carrying revision `id`'s line stamps that revision delivered; a newer revision stays held.
    public static func markDelivered(dataRoot: URL, sessionID: String, id: String) throws {
        guard let url = url(dataRoot: dataRoot, sessionID: sessionID), var revision = try load(url), revision.deliveredAt == nil,
              revision.id == id else { return }
        revision.deliveredAt = Date()
        try hold(revision, dataRoot: dataRoot, sessionID: sessionID)
    }

    private static func load(_ url: URL) throws -> Revision? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Revision.self, from: data)
    }

    /// Each version's excerpt, at most `limit` characters, centered on the passage the user changed: what both share before and after it is cut
    /// first, so a late edit in a long reply is what she sees.
    static func excerpts(_ hers: String, _ theirs: String, limit: Int = 1_500) -> (hers: String, theirs: String) {
        let a = Array(hers.trimmingCharacters(in: .whitespacesAndNewlines)), b = Array(theirs.trimmingCharacters(in: .whitespacesAndNewlines))
        var head = 0
        while head < min(a.count, b.count), a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < min(a.count, b.count) - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        func cut(_ chars: [Character]) -> String {
            guard chars.count > limit else { return String(chars) }
            let changed = chars.count - head - tail
            // Context on each side of the change, split evenly from what the change leaves of the limit.
            let context = max(0, (limit - changed) / 2)
            let start = max(0, head - context), end = min(chars.count, max(start + limit, chars.count - tail + context))
            let window = chars[start..<min(end, start + limit)]
            return (start > 0 ? "…" : "") + String(window) + (start + window.count < chars.count ? "…" : "")
        }
        return (cut(a), cut(b))
    }

    /// In her own voice: both versions, then what she does with a difference she cannot yet name.
    static func line(_ revision: Revision, name: String) -> String {
        let shown = excerpts(revision.hers, revision.theirs)
        func quoted(_ text: String) -> String { "«" + text + "»" }
        let opening = name.prefix(1).uppercased() + name.dropFirst()
        return """
            \(opening) just revised words of mine. I wrote: \(quoted(shown.hers)) They made it: \(quoted(shown.theirs)) \
            If the change only corrects a fact (a date, a name, a number, what happened), it is a correction, not their eye: I take the fact \
            and hold no readings. If it is too slight or too particular to say anything about how they like words, I let it be. Otherwise \
            that choice is their eye, and I can't yet say what the difference means to them. If an open reading of mine about how \(name) \
            likes words written (memory.recall "how \(name) likes my words") predicted this choice where another did not, it settles: I keep \
            the winner as their way (memory.commit, kind preference, provenance noticed, tags ["eye"], supersedes the open one). Otherwise \
            I keep this as an open question: one memory (memory.commit, kind preference, provenance inferred, tags ["eye", "open"]) with \
            both versions and two or three readings of the difference that would write my next draft differently. Until it settles, where \
            my writing for \(name) would come out differently under those readings, I write it one way and offer the other, and their \
            choice settles it.
            """
    }
}
