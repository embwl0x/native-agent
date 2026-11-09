import Foundation
import NativeAgentCore
// Blueprint: | `SessionHistoryTail.swift` | Stateless whole-turn checkpoints from the admitted replay and its row sizes. |

struct SessionTranscriptError: LocalizedError, Sendable {
    let errorDescription: String?
}

// Half-budget checkpoints derive from the transcript's cumulative replay size; finer whole-turn cuts follow them.
package struct SessionHistoryTail: Sendable {
    package struct Checkpoint: Sendable {
        package let row: Int
        package let characters: Int
        package let previousCharacters: Int
        package let threshold: Int
    }
    private let admission: SessionHistoryMessages.Admission
    private let prefixCharacters: [Int]
    private let starts: [Int]
    package var rowCount: Int { admission.renderables.count }
    package var characters: Int { prefixCharacters[rowCount] }

    package init(_ admission: SessionHistoryMessages.Admission, rowCharacters: [String: Int]) {
        self.admission = admission
        var prefix = [0]
        for (index, entry) in admission.renderables.enumerated() {
            prefix.append(prefix[index] + (rowCharacters[entry.row.historyIdentity] ?? 0))
        }
        prefixCharacters = prefix
        var starts = Self.turnStarts(admission.renderables.map(\.row))
        // The end of prior history is the current turn's start, including a single oversized prior turn.
        if !admission.renderables.isEmpty { starts.append(admission.renderables.count) }
        self.starts = starts
    }

    /// A whole turn starts at a person's row that no earlier run still holds; the first row opens the first turn.
    static func turnStarts(_ rows: [SessionHistoryPromptRenderer.Renderable]) -> [Int] {
        var runEnds: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            if let run = row.runId, !run.isEmpty { runEnds[run] = index }
        }
        var starts: [Int] = []
        var heldThrough = -1
        for (index, row) in rows.enumerated() {
            if index > 0, index > heldThrough, row.role == "user", !row.isTool { starts.append(index) }
            if let run = row.runId, let end = runEnds[run] { heldThrough = max(heldThrough, end) }
        }
        return starts
    }

    package static func select(_ messages: [ChatMessage], beforeQuestionID: String? = nil,
                               excludingRunID: String? = nil) -> [ChatMessage] {
        let end = beforeQuestionID.flatMap { id in messages.firstIndex { $0.extras?.objectValue?["id"] == .string(id) } } ?? messages.count
        return messages[..<end].filter {
            excludingRunID == nil || $0.extras?.objectValue?["runId"]?.stringValue != excludingRunID
        }
    }

    package func checkpoints(halfBudgetCharacters: Int) -> [Checkpoint] {
        precondition(halfBudgetCharacters > 0)
        var checkpoints: [Checkpoint] = []
        var crossed = 0
        var previous = 0
        for start in starts {
            let characters = prefixCharacters[start]
            let multiple = characters / halfBudgetCharacters
            if multiple > crossed {
                checkpoints.append(Checkpoint(row: start, characters: characters, previousCharacters: previous,
                    threshold: (crossed + 1) * halfBudgetCharacters))
                crossed = multiple
            }
            previous = characters
        }
        // When no half-budget cut fits (a long new message), each later whole-turn start is the next cut to try.
        let last = checkpoints.last?.row ?? 0
        var before = checkpoints.last?.characters ?? 0
        for start in starts where start > last {
            let characters = prefixCharacters[start]
            checkpoints.append(Checkpoint(row: start, characters: characters, previousCharacters: before, threshold: characters))
            before = characters
        }
        return checkpoints
    }

    package static func halfBudgetCharacters(windowTokens: Int, outputTokens: Int) -> Int {
        max(1, Int(Double(ContextBudgetPolicy.inputTokens(windowTokens: windowTokens, outputTokens: outputTokens))
            * ContextBudgetPolicy.transcriptCharactersPerToken / 2))
    }

    /// Skip checkpoints whose remaining row bodies cannot fit, without constructing their messages or measuring requests.
    /// Keep the final whole-turn start when even an empty history cannot make the current input fit.
    package func fittingCheckpoints(halfBudgetCharacters: Int, maximumRetainedCharacters: Double,
                                   afterCharacters: Int = -1) -> ArraySlice<Checkpoint> {
        let candidates = checkpoints(halfBudgetCharacters: halfBudgetCharacters).filter { $0.characters > afterCharacters }
        guard let first = candidates.firstIndex(where: { Double(characters - $0.characters) <= maximumRetainedCharacters }) else {
            return candidates.suffix(1)
        }
        return candidates[first...]
    }

    package func project(after checkpoint: Checkpoint) -> SessionHistoryMessages.Result {
        SessionHistoryMessages.project(.init(renderables: Array(admission.renderables.dropFirst(checkpoint.row))))
    }
}
