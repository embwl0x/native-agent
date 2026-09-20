import Foundation
import MemoryV2
import PersistenceCore

/// Lane 4 — duplicate check before a proposed save.
///
/// The candidate and the closest existing memories go out, and the question
/// back is whether they are the same underlying fact or event. A yes at 0.90
/// or better SUGGESTS "looks like a duplicate of <id>" in the tool result.
///
/// It never prevents, merges, rewrites or deletes anything. The save happens
/// either way, and the log records that it did.
enum JevMemoryDedup {

    static let threshold = 0.90
    /// Question-key prefix for the per-candidate nouls. `JevAnswers` folds
    /// everything under one prefix into a single log field.
    private static let samePrefix = "same_fact."
    /// Below this the existing memory is not close enough to be worth asking
    /// about, and no call is made at all.
    ///
    /// Read against the recall score this is compared to, which is NOT a
    /// cosine: it is `(cosine + 0.25 × max-normalized BM25) × recency × ...`,
    /// so it runs past 1.0. A same-fact paraphrase measures ~0.945 cosine on
    /// the calibrated pairs and lands around 1.05-1.25 blended — roughly twice
    /// this floor. 0.55 is a topicality gate, the same number the supersession
    /// lane uses for "the same subject at all"; it is not what was keeping
    /// paraphrases away from this lane. Do not raise it above ~0.75, and do
    /// not copy a cosine-scale constant here.
    private static let candidateFloor = 0.55

    struct Suggestion: Sendable {
        /// Every existing memory that reads as the same fact, strongest first.
        /// Never empty when a suggestion exists.
        let ids: [String]
        let note: String
        /// The strongest match, which is what a single-id reader wants.
        var id: String { ids[0] }
    }

    /// The whole lane, end to end. This is the ONE lane that is still awaited
    /// on a live path, because its suggestion has to be in the tool result
    /// that reports the save — so it is capped hard, and a Stop cancels it
    /// rather than letting the save run on behind a dead turn.
    static let budget: Duration = .milliseconds(1500)

    /// Ask, and return a suggestion only when there is one. Nil on every other
    /// path, including the lane being off, the budget running out and the call
    /// failing. Cancellation is rethrown, never read as "no duplicate".
    static func suggestion(
        candidate: String,
        memory: SwiftNativeMemoryV2,
        sessionID: String,
        dataRoot: URL
    ) async throws -> Suggestion? {
        guard JevSettings.isEnabled(.memoryDedup, dataRoot: dataRoot) else { return nil }
        let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 12 else { return nil }
        return try await withBudget(sessionID: sessionID, dataRoot: dataRoot) {
            try await ask(text: text, memory: memory, sessionID: sessionID, dataRoot: dataRoot)
        }
    }

    /// Which side of the race finished first. The two are told apart because a
    /// timeout and an honest "no duplicate" both yield nil, and only one of
    /// them is worth a log row.
    private enum Outcome: Sendable {
        case answered(Suggestion?)
        case timedOut
    }

    /// Race `body` against the budget. A HARD cap: the losing side is
    /// cancelled, so a slow call cannot go on holding the save after its time
    /// is up. On timeout the row says `abstained` and the save proceeds
    /// unannotated. A cancellation is rethrown — a Stop is not a timeout.
    private static func withBudget(
        sessionID: String,
        dataRoot: URL,
        _ body: @escaping @Sendable () async throws -> Suggestion?
    ) async throws -> Suggestion? {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { .answered(try await body()) }
            group.addTask {
                try await Task.sleep(for: budget)
                return .timedOut
            }
            defer { group.cancelAll() }
            let first: Outcome
            do {
                first = try await group.next() ?? .timedOut
            } catch {
                if JevClient.isCancellation(error) { throw CancellationError() }
                return nil
            }
            switch first {
            case .answered(let suggestion):
                return suggestion
            case .timedOut:
                JevLog.shared.note(
                    lane: .memoryDedup,
                    summary: "duplicate check abstained",
                    context: JevLogContext(
                        sessionID: sessionID,
                        acted: "over \(budget) budget; saved without a duplicate check"
                    ),
                    dataRoot: dataRoot
                )
                return nil
            }
        }
    }

    private static func ask(
        text: String,
        memory: SwiftNativeMemoryV2,
        sessionID: String,
        dataRoot: URL
    ) async throws -> Suggestion? {

        // The probe must not credit a recall that nobody read.
        let response = try? await memory.recall(
            MemoryV2RecallRequest(text: text, topK: 5),
            recordingUsage: false
        )
        // No `record.text != text` filter. An existing record with the SAME
        // text is the strongest duplicate there is, and this runs BEFORE the
        // save, so that row is a genuine prior memory and not the candidate
        // seeing itself. Excluding it meant the one case nobody could argue
        // with was the one case never reported.
        let scored = response?.scored ?? []
        let near = scored
            .filter { $0.score >= candidateFloor }
            .prefix(3)

        // A row on EVERY run, before any early return. Without this a lane
        // that found nothing and a lane that never ran are the same absence in
        // the log, and the drive could not tell them apart. The numbers are
        // here so the floor can be read against reality rather than guessed at.
        let topScore = scored.map(\.score).max() ?? 0
        JevLog.shared.note(
            lane: .memoryDedup,
            summary: "duplicate probe: \(near.count) of \(scored.count) recalled cleared the floor",
            context: JevLogContext(
                sessionID: sessionID,
                acted: near.isEmpty
                    ? String(format: "no near match; top %.3f below floor %.2f", topScore, candidateFloor)
                    : String(format: "top %.3f, floor %.2f; asking", topScore, candidateFloor)
            ),
            dataRoot: dataRoot
        )
        guard !near.isEmpty else { return nil }

        var existing: [String: String] = [:]
        for entry in near { existing[entry.record.id] = entry.record.text.jevTruncated(400) }

        let state: [String: JSONValue] = [
            "message": .string(text.jevTruncated(1000)),
            "existing": .object(existing.mapValues(JSONValue.string)),
        ]
        // One noul PER CANDIDATE, not a choice across them.
        //
        // The choice folded exactly as the pre-turn family choice did: on the
        // rerun a single candidate scored `same_fact` 0.97 while `duplicate_of`
        // answered `none 1.00`, so the suggestion never reached the tool
        // result. Asked one at a time there is nothing to fold toward — each
        // candidate is judged against the candidate text alone.
        //
        // The prefix matters: `JevAnswers` folds `same_fact.*` into one field.
        let questions = duplicateQuestions(ids: Array(existing.keys))

        let context = JevLogContext(sessionID: sessionID)
        guard let answers = try await JevClient.shared.ask(
            lane: .memoryDedup, state: state, questions: questions,
            summary: text, dataRoot: dataRoot, context: context
        ) else { return nil }
        // Every candidate that clears the bar, strongest first — not just one.
        let ranked = existing.keys
            .compactMap { id -> (id: String, score: Double)? in
                guard let score = answers.noul(samePrefix + id) else { return nil }
                return (id, score)
            }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }

        JevLog.shared.note(
            lane: .memoryDedup,
            summary: "duplicate scores over \(ranked.count) candidate(s)",
            context: JevLogContext(sessionID: sessionID, acted: ranked.isEmpty ? "no candidate scored"
                : ranked.map { "\($0.id) \(JevAnswers.round2($0.score))" }.joined(separator: ", ")),
            dataRoot: dataRoot
        )
        let matches = ranked.filter { $0.score >= threshold }.map(\.id)
        guard !matches.isEmpty else { return nil }
        let named = matches.count == 1 ? "a duplicate of \(matches[0])"
            : "a duplicate of \(matches.count) existing memories: \(matches.joined(separator: ", "))"
        return Suggestion(ids: matches,
            note: "This looks like \(named). It was saved anyway; nothing was merged or removed.")
    }

    static func duplicateQuestions(ids: [String]) -> [String: JevQuestion] {
        var questions: [String: JevQuestion] = [:]
        for id in ids {
            questions[samePrefix + id] = .noul(
                instructions: JevInstructions(question: "Does the entry under the key `\(id)` in `existing` record the SAME "
                    + "underlying fact or event as `message`, such that saving `message` would record "
                    + "it twice? Two entries about the same subject are not duplicates unless they say "
                    + "the same thing happened or is true. Judge this entry alone.")
            )
        }

        return questions
    }

    /// Record that the save went ahead, which is the point of the row: the
    /// suggestion never changes the outcome, so the log is where its accuracy
    /// can be read back.
    static func noteSaved(
        _ suggestion: Suggestion?,
        savedID: String,
        sessionID: String,
        dataRoot: URL
    ) async {
        guard let suggestion else { return }
        JevLog.shared.note(
            lane: .memoryDedup,
            summary: "suggested duplicate of \(suggestion.ids.joined(separator: ", "))",
            context: JevLogContext(sessionID: sessionID, acted: "saved as \(savedID)"),
            dataRoot: dataRoot
        )
    }
}
