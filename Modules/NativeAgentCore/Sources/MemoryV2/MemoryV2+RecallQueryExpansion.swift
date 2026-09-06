import Foundation

/// The agent asks her memory in the first person ("what does User call me")
/// while many rows name her in the third ("User uses different names for
/// Agent…"), and she says "you" where a row says the user's name. The MiniLM
/// vector for "me" is nowhere near the vector for a name, so the best row
/// for the question never surfaced (2026-09-05: the pet-names row ranked
/// outside the top ten for "what User calls me when he is being affectionate"
/// and first for "pet names User uses for Agent"). Recall now also asks the
/// question with the names substituted and keeps the better score per row,
/// so a memory written in either voice answers a question asked in either.
public enum MemoryRecallQueryExpansion {
    public struct Names: Sendable, Equatable {
        public var agent: String?
        public var user: String?
        public var isEmpty: Bool { agent == nil && user == nil }
    }

    /// The question with first-person words replaced by the agent's name and
    /// second-person words by the user's, or nil when nothing changed.
    public static func rewrite(_ text: String, names: Names) -> String? {
        guard !names.isEmpty else { return nil }
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
        if let agent = names.agent {
            swap("\\b(?:me|myself)\\b", agent)
            swap("\\b(?:my|mine)\\b", agent + "'s")
            // "I'm" before "I": the word boundary after I sits before the
            // apostrophe, so the bare rule would leave "Agent'm".
            swap("\\bI'm\\b", agent + " is", caseInsensitive: false)
            swap("\\bI\\b", agent, caseInsensitive: false)
        }
        if let user = names.user {
            swap("\\b(?:you|yourself)\\b", user)
            swap("\\b(?:your|yours)\\b", user + "'s")
        }
        return out == text ? nil : out
    }

    /// Agent and user names from `profile.json` beside the store, cached by
    /// file modification date so the hot recall path pays one stat, not a
    /// parse, per call.
    public static func names(storeDirectory: URL) -> Names {
        let url = storeDirectory.appendingPathComponent("profile.json")
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        return cacheLock.withLock {
            if let cached = cache[url.path], cached.modified == modified { return cached.names }
            var names = Names()
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                names.agent = usable(object["name"] as? String, rejecting: ["assistant", "the assistant", "agent", "the agent"])
                names.user = usable(object["userName"] as? String, rejecting: ["user", "the user"])
            }
            cache[url.path] = (modified, names)
            return names
        }
    }

    private static func usable(_ raw: String?, rejecting: Set<String>) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              !rejecting.contains(trimmed.lowercased()),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (modified: Date?, names: Names)] = [:]
}
