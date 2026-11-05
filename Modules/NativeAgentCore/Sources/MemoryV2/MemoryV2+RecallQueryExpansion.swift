import Foundation
import Synchronization
import ChatTurnContracts
import NativeAgentCore

// Blueprint: | `MemoryV2+RecallQueryExpansion.swift` | `MemoryRecallQueryExpansion`: persona/user name-aware first-person recall rewrites |

/// English pronoun expansion with explicit conversational roles. Stored facts name people in third person; recall keeps both the words and their named reading.
/// This is an English retrieval aid, not language-independent parsing.
public enum MemoryRecallQueryExpansion {
    public struct Names: Sendable, Equatable {
        public var agent: String?
        public var user: String?
        public var isEmpty: Bool { agent == nil && user == nil }
    }

    /// Explicit recall is authored by the resident agent, addressing the user.
    public static func rewrite(_ text: String, names: Names) -> String? {
        rewrite(text, speaker: names.agent, addressee: names.user)
    }

    /// The same recorded origin stamped on the incoming turn distinguishes a human's words (including a relay) from another agent's own words. Route labels
    /// never make a relay's speaker the transporting agent.
    public static func rewriteIncoming(_ text: String, names: Names, turn: Turn) -> String? {
        let origin = turn.origin
        let recordedAgent = origin?.agent
        let speaker = origin?.authored == .agent
            ? recordedAgent.flatMap { $0 == "self" ? names.agent : $0 }
            : names.user
        return rewrite(text, speaker: speaker, addressee: names.agent)
    }

    public static func rewrite(_ text: String, speaker: String?, addressee: String?) -> String? {
        guard speaker != nil || addressee != nil else { return nil }
        var out = text
        func swap(_ pattern: String, _ replacement: String, caseInsensitive: Bool = true) {
            let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(
                in: out, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
        }
        if let agent = speaker {
            swap("\\b(?:me|myself)\\b", agent)
            swap("\\b(?:my|mine)\\b", agent + "'s")
            // Match contractions before bare pronouns so a word boundary cannot leave an apostrophe suffix after the name.
            swap("\\bI'm\\b", agent + " is", caseInsensitive: false)
            swap("\\bI\\b", agent, caseInsensitive: false)
        }
        if let user = addressee {
            swap("\\b(?:you|yourself)\\b", user)
            swap("\\b(?:your|yours)\\b", user + "'s")
        }
        return out == text ? nil : out
    }

    /// Cache canonical profile names by modification date to avoid parsing on every recall.
    public static func names(storeDirectory: URL) throws -> Names {
        let url = storeDirectory.appendingPathComponent("profile.json")
        let modified: Date?
        do { modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { modified = nil }
        return try cache.withLock { cache in
            if let cached = cache[url.path], cached.modified == modified { return cached.names }
            let profile = try SwiftNativeKnowledgeGraphIndexer.profileNames(profileURL: url)
            let names = Names(agent: profile.agent, user: profile.user)
            cache[url.path] = (modified, names)
            return names
        }
    }

    private static let cache = Mutex<[String: (modified: Date?, names: Names)]>([:])
}
