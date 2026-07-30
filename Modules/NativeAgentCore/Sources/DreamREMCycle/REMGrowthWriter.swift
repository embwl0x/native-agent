import Foundation
import PersistenceCore

// MARK: - REMGrowthWriter (2026-07-03)
//
// The missing half of the REM approve path. Since the Swift cutover,
// approving a rem.proposal card flipped the row's status and emitted the
// chat-injection pin — but never wrote the lesson into GROWTH.md, even
// though the approval card promises exactly that ("Approve to add this
// compact lesson to GROWTH.md") and the distillation prompt tells the LLM
// "the approval flow will pick a short heading". User approved the first
// repaired-pipeline proposal on 2026-07-03, watched GROWTH.md not change,
// and caught the gap. This writer keeps the card's promise.
//
// Shape contract: GROWTH.md entries are `## <short lowercase heading>`
// followed by one compact paragraph (see persona/GROWTH.md). The heading is
// derived from the reflex's first clause; the body is the approved
// proposalText verbatim.
public enum REMGrowthWriter {

    /// Thrown when `personaRoot` doesn't look like a real persona root
    /// (no SOUL.md and no GROWTH.md). The resolver's last-resort fallback is
    /// `<dataRoot>/memory`; minting a GROWTH.md there would bypass the
    /// PersonaEngine pre-onboarding guard AND land the lesson in the stale
    /// fallback copy nobody reads (gpt-5.5 review MED, 2026-07-03 — the
    /// same wrong-directory class as the persona-distill incident).
    public struct PersonaRootUnready: Error, CustomStringConvertible {
        public let path: String
        public var description: String {
            "REMGrowthWriter: \(path) has neither SOUL.md nor GROWTH.md — "
            + "refusing to mint a GROWTH.md outside a real persona root."
        }
    }

    /// True when `text` exists in `body` as a standalone entry paragraph —
    /// bounded by line breaks (or document edges), never a substring of a
    /// longer paragraph (gpt-5.5 review MED: containment alone would
    /// false-positive skip a shorter lesson embedded in an existing entry).
    static func containsEntryParagraph(_ body: String, _ text: String) -> Bool {
        if body == text { return true }
        if body.hasPrefix(text + "\n") { return true }
        if body.hasSuffix("\n" + text) { return true }
        return body.contains("\n" + text + "\n")
    }

    /// Append an approved REM lesson to `<personaRoot>/GROWTH.md` under the
    /// same cross-process flock every other GROWTH writer holds. Idempotent:
    /// when the doc already contains the exact proposal text as its own
    /// entry paragraph (a reconcile re-fire after a crash window, or a
    /// manual backfill) nothing is written and `false` returns. A missing
    /// GROWTH.md is created ONLY when the root carries a SOUL.md (a real
    /// persona root mid-migration); an unready root throws so the caller's
    /// approval never flips. Returns `true` when the entry landed.
    @discardableResult
    public static func appendApprovedLesson(
        personaRoot: URL,
        proposalText: String
    ) async throws -> Bool {
        let text = proposalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let growth = personaRoot.appendingPathComponent("GROWTH.md")
        let fm = FileManager.default
        if !fm.fileExists(atPath: growth.path),
           !fm.fileExists(atPath: personaRoot.appendingPathComponent("SOUL.md").path) {
            throw PersonaRootUnready(path: personaRoot.path)
        }
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(growth) {
            let body = (try? String(contentsOf: growth, encoding: .utf8)) ?? ""
            if containsEntryParagraph(body, text) { return false }
            // Body only — no derived `## heading` (User, 2026-07-03): any
            // heading machine-derived from the lesson just repeats its first
            // clause, and GROWTH rides into every chat turn, so duplicate
            // bytes are a per-turn prompt tax. Her hand-authored entries
            // keep their labels; REM entries are one clean paragraph.
            let entry = "\n\(text)\n"
            let rebuilt = body.isEmpty
                ? "# GROWTH.md\n" + entry
                : (body.hasSuffix("\n") ? body + entry : body + "\n" + entry)
            try rebuilt.data(using: .utf8)!.write(to: growth, options: .atomic)
            return true
        }
    }
}
