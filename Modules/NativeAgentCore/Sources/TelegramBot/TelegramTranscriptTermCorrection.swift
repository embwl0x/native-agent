import Foundation

/// W5 L1#11 "voice term correction": speech-to-text reliably mangles this
/// install's domain nouns — "Kodak" for Codex, "Ayla" for Agent, "gate hub"
/// for GitHub. The mangled noun then travels through the whole turn: recall
/// queries miss, tool arguments are wrong, and the reply names a thing that
/// does not exist.
///
/// Scope discipline (deliberately narrow):
/// - TRANSCRIPTS ONLY. Typed Telegram text is never routed through here.
/// - Word-boundary, case-insensitive matching. No substring rewriting, so
///   "decode" can never become "deCodex".
/// - The corrected text is what the model sees; the ORIGINAL transcript stays
///   retrievable in the receipt row, and the `[transcript corrected: N terms]`
///   marker goes to metadata — never into the user-visible message.
enum TelegramTranscriptTermCorrection {
    /// The single extension point. Add a `(heard, canonical)` pair and both
    /// the correction pass and its tests pick it up. Keep entries specific
    /// enough that they cannot fire on ordinary English.
    static let table: [(heard: String, canonical: String)] = [
        // Codex. NOTE: "codecs" is deliberately absent — it is ordinary
        // English in exactly the audio context these transcripts come from.
        ("kodex", "Codex"),
        ("kodak", "Codex"),
        ("codex", "Codex"),
        // The agent's own name is not shipped here: it is whatever the user
        // configured, and its manglings live in
        // <dataRoot>/config/transcript_terms.json (see `installTerms`).
        // GitHub. NOTE: "get help" is deliberately ABSENT even though one real
        // transcript produced it ("look at my get help") — "get help" is
        // ordinary English ("get help from codex") and correcting it would
        // corrupt meaning. The rarer manglings stay.
        ("gate hub", "GitHub"),
        ("git hub", "GitHub"),
        ("github", "GitHub"),
        // NativeAgent
        ("native agent", "NativeAgent"),
        ("nativeagent", "NativeAgent"),
        // Claude. "Katana" stays out — it is an ordinary noun.
        ("cortina", "Claude"),
        ("cor tana", "Claude"),
        ("cortanna", "Claude"),
        ("claude", "Claude"),
        // Kimi
        ("kimmy", "Kimi"),
        ("kimmi", "Kimi"),
        ("kimme", "Kimi"),
        ("kimi", "Kimi"),
        // Sparkle (the macOS updater) — case normalization only.
        ("sparkle", "Sparkle"),
    ]

    struct Result: Sendable, Equatable {
        /// Transcript with canonical spellings substituted.
        let text: String
        /// How many individual term occurrences actually changed.
        let correctedCount: Int
        /// The transcript exactly as the recognizer produced it.
        let original: String

        var didCorrect: Bool { correctedCount > 0 }

        /// Metadata/log marker. Never appended to user-visible text.
        var marker: String? {
            correctedCount > 0 ? "[transcript corrected: \(correctedCount) terms]" : nil
        }
    }

    /// Apply the table to a transcript. Longer phrases run first so a
    /// multi-word mangling ("git hub") is consumed before any single-word
    /// entry can bite a piece of it.
    static func correct(_ transcript: String, extra: [(heard: String, canonical: String)] = []) -> Result {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(text: transcript, correctedCount: 0, original: transcript)
        }
        var text = transcript
        var corrected = 0
        let ordered = (table + extra).sorted { $0.heard.count > $1.heard.count }
        for entry in ordered {
            guard let regex = boundaryRegex(for: entry.heard) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            guard !matches.isEmpty else { continue }
            // Count only the occurrences that are not already canonical, so a
            // correctly-spelled "GitHub" in the transcript costs nothing.
            var changed = 0
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: text) else { continue }
                if text[matchRange] == entry.canonical { continue }
                text.replaceSubrange(matchRange, with: entry.canonical)
                changed += 1
            }
            corrected += changed
        }
        return Result(text: text, correctedCount: corrected, original: transcript)
    }

    /// Per-install corrections, typically the agent's own name as the
    /// transcriber mishears it: `<dataRoot>/config/transcript_terms.json`,
    /// `{"terms": [{"heard": "ayla", "canonical": "Agent"}]}`. Cached by file
    /// modification date; a missing or malformed file contributes nothing.
    static func installTerms(dataRoot: URL) -> [(heard: String, canonical: String)] {
        let url = dataRoot.appendingPathComponent("config", isDirectory: true).appendingPathComponent("transcript_terms.json")
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        return installTermsLock.withLock {
            if let cached = installTermsCache, cached.path == url.path, cached.modified == modified { return cached.terms }
            var terms: [(heard: String, canonical: String)] = []
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = object["terms"] as? [[String: Any]] {
                for row in rows {
                    guard let heard = (row["heard"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let canonical = (row["canonical"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !heard.isEmpty, !canonical.isEmpty, heard.count <= 40, canonical.count <= 40
                    else { continue }
                    terms.append((heard, canonical))
                }
            }
            installTermsCache = (url.path, modified, terms)
            return terms
        }
    }
    private static let installTermsLock = NSLock()
    nonisolated(unsafe) private static var installTermsCache: (path: String, modified: Date?, terms: [(heard: String, canonical: String)])?

    private static func boundaryRegex(for heard: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: heard)
        // Whitespace in a multi-word entry matches any run of whitespace, so
        // "git  hub" across a recognizer pause still corrects.
        let flexible = escaped.replacingOccurrences(of: "\\ ", with: "\\s+")
            .replacingOccurrences(of: " ", with: "\\s+")
        return try? NSRegularExpression(
            pattern: "\\b\(flexible)\\b",
            options: [.caseInsensitive]
        )
    }
}
