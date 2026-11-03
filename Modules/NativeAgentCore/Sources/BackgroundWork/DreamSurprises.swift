import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import CognitiveSubstrate
import Cognition
import DreamREMCycle
import TurnTrace
import Transcripts

// Blueprint: | `DreamSurprises.swift` | `DreamBackgroundWork.makeDreamSurpriseProvider`: CPU-only, 2,500-character dream material from retained failed dispatches grouped by action/code, Expansion misses, final after-turn no-op misses, live organism violations and the owner's saved corrections; no new recorder; preview dispatch receipts are excluded from learning material |

extension DreamBackgroundWork {
    public static func makeDreamSurpriseProvider(
        dataRoot: URL, cognitionRuntime: NativeCognitionRuntime
    ) -> DreamSurpriseProvider {
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        return { since, through in
            let traces = try await DreamSurprises.traceLines(dataRoot: dataRoot, since: since, through: through)
            let afterTurn = try await SwiftNativeMemoryV2.afterTurnMissesForDream(
                dataRoot: dataRoot, since: since, through: through)
            await cognitionRuntime.bootstrap()
            // Read her live owner, never the persisted body behind its back.
            let body = await cognitionRuntime.organismKernel.exportPersistentState()
            let predictions = Array(body?.predictionLedger.predictions.values ?? [:].values)
            var violations = predictions.filter { row in
                row.status == .violated && row.lastUpdatedAt > since && row.lastUpdatedAt <= through
            }
            violations.sort { left, right in
                left.lastUpdatedAt == right.lastUpdatedAt ? left.id < right.id : left.lastUpdatedAt > right.lastUpdatedAt
            }
            var organism: [String] = []
            if !violations.isEmpty {
                organism.append("Body predictions: \(violations.count) violated.")
                for row in violations.prefix(3) {
                    let subject: String = row.horizon.map { "; about " + $0.label } ?? ""
                    organism.append("Expected " + row.kind.humanLabel + " (" + row.sourceOrgan + subject + "); it did not happen.")
                }
            }
            let records = try await memory.listMemory(kind: nil)
            let corrections = records.filter { record in
                guard record.status == "active",
                      !MemoryStorage.metadataFlag(record.extras, MemoryStorage.pendingAdmissionKey),
                      let date = ChatSessionRecollections.parseTimestamp(.string(record.createdAt)),
                      date > since, date <= through else { return false }
                let meta = record.extras?.objectValue ?? [:]
                let replaces = meta[MemoryManagerLane.supersedesKey] != nil
                    || meta["supersedes"] != nil
                guard MemoryRecallScoring.isCorrection(record, tags: record.tags ?? []) || replaces else { return false }
                let speaker = (record.evidence ?? meta["evidence"])?.objectValue?["speaker"]?.stringValue
                // Only attributed owner evidence makes this User's correction.
                return speaker == CognitiveCare.ownerKey || speaker == "user"
            }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
            let corrected = corrections.isEmpty ? [] : ["User's corrections: \(corrections.count) saved."]
                + corrections.prefix(3).map { $0.text }
            return DreamSurprises.block(sections: [traces.failures, afterTurn, traces.expansion, organism, corrected])
        }
    }
}

private enum DreamSurprises {
    /// Give every present kind room before spending the rest on examples.
    static func block(sections: [[String]]) -> String {
        let present = sections.filter { !$0.isEmpty }
        guard !present.isEmpty else { return "" }
        // Leave room for the prompt-owned header within the 2,500-character block.
        let allowance = (2_400 - present.count) / present.count
        return present.map { lines in
            var left = allowance
            return lines.compactMap { line -> String? in
                let flat = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                guard !flat.isEmpty, left > 4 else { return nil }
                let clipped = flat.count <= min(220, left - 3)
                    ? flat : String(flat.prefix(min(219, left - 4))) + "…"
                let rendered = "- \(clipped)\n"
                left -= rendered.count
                return rendered
            }.joined()
        }.joined(separator: "\n")
    }

    struct FailureKey: Hashable { let action, code: String }
    struct Failure { var count: Int; let reason: String }

    static func traceLines(dataRoot: URL, since: Date, through: Date) async throws
        -> (failures: [String], expansion: [String]) {
        let root = TurnTracePersistLane(dataRootOverride: dataRoot).resolvedDataRoot()
        let directory = root.appendingPathComponent("turn_traces", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        let calendar = TurnTracePersistLane.dayCalendar
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { url in
                guard url.pathExtension == "jsonl",
                      let day = TurnTracePersistLane.day(from: url.deletingPathExtension().lastPathComponent),
                      let end = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
                return end > since && day <= through
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var failures: [FailureKey: Failure] = [:]
        var expansionCount = 0
        var expansionExamples: [String] = []
        for file in files {
            // A day file still being written ends mid-row: its complete events still count.
            let read = try await TurnTraceReplayReader.read(file)
            for event in read.events where event.ts > since && event.ts <= through {
                guard let fields = event.payload.objectValue else { continue }
                // Preview traces are inspection, never surprise material for
                // the next real dream, including a refused preview.
                guard fields["receipt"]?.objectValue?["preview"] != .bool(true) else { continue }
                if event.kind == "tool.dispatch", fields["status"] == .string("failed") {
                    let action = fields["receipt"]?.objectValue?["action"]?.stringValue
                        ?? fields["shown"]?.stringValue ?? fields["name"]?.stringValue ?? "unknown action"
                    let code = fields["failure_code"]?.stringValue ?? fields["code"]?.stringValue ?? "unlabelled failure"
                    let key = FailureKey(action: action, code: code)
                    if failures[key] != nil { failures[key]!.count += 1 }
                    else {
                        var reasons: [String] = []
                        for field in ["reason", "error", "detail", "errorDetail"] {
                            if let reason = fields[field]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !reason.isEmpty, !reasons.contains(reason) { reasons.append(reason) }
                        }
                        let reason = reasons.isEmpty ? "No reason recorded" : reasons.joined(separator: "; ")
                        let path = fields["argument_path"]?.stringValue.map { " (argument: \($0))" } ?? ""
                        failures[key] = Failure(count: 1, reason: reason + path)
                    }
                } else if event.kind == "expansion.check", fields["outcome"] == .string("miss") {
                    expansionCount += 1
                    let situation = fields["situation"]?.stringValue ?? "unrecorded situation"
                    let prediction = fields["prediction"]?.stringValue ?? "unrecorded call"
                    expansionExamples.append("At \(situation), expected \(prediction); the next call differed or never came.")
                    if expansionExamples.count > 3 { expansionExamples.removeFirst() }
                }
            }
        }
        let grouped = failures.sorted {
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            if $0.key.action != $1.key.action { return $0.key.action < $1.key.action }
            return $0.key.code < $1.key.code
        }.prefix(8).map { "\($0.key.action) [\($0.key.code)] ×\($0.value.count): \($0.value.reason)" }
        return (grouped.isEmpty ? [] : ["Failed tool calls (by action and code):"] + grouped,
                expansionCount == 0 ? [] : ["Expansion predictions: \(expansionCount) missed."] + expansionExamples)
    }
}
