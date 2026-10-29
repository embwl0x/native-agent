import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import TurnTrace
import ApprovalInbox
import MemoryV2
import DreamREMCycle
import PersistenceCore
import ProviderRouting
// Blueprint: | `WeeklySelfImprovementLoop+Evidence.swift` | Weekly chat, live error-feed and Doctor evidence; deterministic conversation sampling weighted by caring receipts; `SelfImprovementLearning`, prior-card outcomes and standing-lesson recurrence |

extension WeeklySelfImprovementLoop {
    /// Reads a week of real usage into a compact, LLM-readable summary.
    func gatherSignals(now: Date) throws -> String {
        let weekAgo = now.addingTimeInterval(-interval)
        let fm = FileManager.default
        var sections: [String] = []

        // Sample chat by day and session first, then feeling weight, with deterministic ordering.
        let messagesDir = dataRoot.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        let feltWeights = try Self.feltWeights(dataRoot: dataRoot)
        var candidates: [SampledUserMessage] = []
        var totalMessages = 0
        var sessionCount = 0
        let files: [URL]
        do { files = try fm.contentsOfDirectory(at: messagesDir, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            files = []
            sections.append("## Chat source\nTranscript directory has not been created.")
        }
        do {
            for file in files where file.pathExtension == "jsonl" {
                let text = try String(contentsOf: file, encoding: .utf8)
                let sessionId = file.deletingPathExtension().lastPathComponent
                // Rows without createdAt use file modification time for ordering and day buckets.
                guard let mtime = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date else {
                    throw Self.sourceError(file, "modification date is unavailable")
                }
                var sessionHadRecent = false
                for (index, line) in text.split(separator: "\n").enumerated() {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { throw Self.sourceError(file, "malformed transcript row \(index + 1)") }
                    let stamp = (obj["createdAt"] as? String).flatMap(Self.parseISO)
                    let at = stamp ?? mtime
                    if at < weekAgo { continue }
                    totalMessages += 1
                    sessionHadRecent = true
                    if Self.isHumanMessage(obj),
                       let content = obj["content"] as? String, !content.isEmpty {
                        let messageId = obj["id"] as? String ?? ""
                        candidates.append(SampledUserMessage(
                            at: at,
                            day: Self.todayString(at),
                            sessionId: sessionId,
                            messageId: messageId,
                            content: TurnSecretRedactor.redactText(content).prefix(280).description,
                            weight: Self.weight(
                                sessionId: sessionId, messageId: messageId, in: feltWeights)
                        ))
                    }
                }
                if sessionHadRecent { sessionCount += 1 }
            }
        }
        let userMessages = Self.sampleUserMessages(candidates, limit: 40).map(\.line)
        sections.append(try completionPolicy("weekly-improvement", section: "chat-activity", arguments: [
            String(totalMessages), String(sessionCount),
            userMessages.isEmpty ? "(none)" : userMessages.map { "- \($0)" }.joined(separator: "\n")]))

        // 2. Errors logged this week.
        for feed in ErrorFeeds.errorFeeds {
            sections.append(try Self.recentLines(
                at: feed.url(dataRoot: dataRoot),
                since: weekAgo, label: "\(feed.label) error log (last 7 days)", limit: 30
            ))
        }

        // 3. Doctor health.
        let doctorPath = dataRoot.appendingPathComponent("doctor", isDirectory: true)
            .appendingPathComponent("latest.json")
        if let text = try Self.optionalText(at: doctorPath) {
            guard let bytes = text.data(using: .utf8),
                  let _ = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw Self.sourceError(doctorPath, "expected a Doctor report object")
            }
            sections.append("## Doctor health (latest)\n\(text.prefix(1500))")
        } else {
            sections.append("## Doctor health\nNo saved report exists.")
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Week sampling

    private static func isHumanMessage(_ row: [String: Any]) -> Bool {
        guard row["role"] as? String == "user" else { return false }
        if row["metadata"] != nil, !(row["metadata"] is [String: Any]) { return false }
        let metadata = row["metadata"] as? [String: Any] ?? [:]
        guard metadata["mechanicalKind"] == nil,
              metadata["kind"] as? String != "compaction_summary" else { return false }
        if let kind = metadata["turnKind"] as? String, kind != "live" { return false }
        let humanSurfaces = ["app", "chat", "mac", "default", "telegram", "slack", "ios", "iphone", "mobile", "icloud"]
        for key in ["origin", "envelope"] {
            if let recorded = metadata[key] {
                guard let provenance = recorded as? [String: Any], provenance["agent"] == nil,
                      let surface = provenance["surface"] as? String,
                      humanSurfaces.contains(surface) else { return false }
                if key == "origin", ["app", "chat", "mac", "default"].contains(surface) { return false }
            }
        }
        guard let source = row["source"] as? String else { return false }
        return humanSurfaces.contains(source)
    }

    /// One user turn inside the week's window, carrying the ids that make it
    /// citable back to the conversation it came from.
    struct SampledUserMessage: Sendable {
        let at: Date
        let day: String
        let sessionId: String
        let messageId: String
        let content: String
        let weight: Double

        /// The prompt line names the source turn as evidence.
        var line: String {
            let source = messageId.isEmpty ? sessionId : "\(sessionId):\(messageId)"
            return "[\(day) \(source)] \(content)"
        }
    }

    /// Caring receipts in `cognition/caring_appraisals.jsonl` key each user turn
    /// by session and message id. Repairs weigh three, landed outcomes one;
    /// none and failure rows contribute nothing. Absence is fresh history;
    /// unreadable existing evidence fails the pass.
    static func feltWeights(dataRoot: URL) throws -> [String: Double] {
        let url = dataRoot.appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("caring_appraisals.jsonl")
        guard let text = try optionalText(at: url) else { return [:] }
        var weights: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw sourceError(url, "malformed appraisal row")
            }
            guard let turn = (obj["turn"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !turn.isEmpty,
                  let outcome = obj["outcome"] as? String
            else { continue }
            let weight: Double
            switch outcome {
            case "repair": weight = 3
            case "caredFor", "needMet", "roomMade": weight = 1
            case "none", "interpretation_failed", "unparseable": continue
            default: continue
            }
            weights[turn] = max(weights[turn] ?? 0, weight)
            // Also bare-keyed: a receipt may carry the message id alone, the
            // same dual keying the dream's felt index uses.
            if let messageId = turn.split(separator: ":").last, !messageId.isEmpty {
                weights[String(messageId)] = max(weights[String(messageId)] ?? 0, weight)
            }
        }
        return weights
    }

    static func weight(sessionId: String, messageId: String, in weights: [String: Double]) -> Double {
        guard !weights.isEmpty, !messageId.isEmpty else { return 0 }
        return weights["\(sessionId):\(messageId)"] ?? weights[messageId] ?? 0
    }

    /// Cover day/session buckets newest-active first, choosing their most-felt
    /// turn; fill the remaining budget by feeling weight, breaking ties toward
    /// recent turns. Restore chronological order for the analyst.
    static func sampleUserMessages(
        _ all: [SampledUserMessage], limit: Int
    ) -> [SampledUserMessage] {
        guard limit > 0, !all.isEmpty else { return [] }
        func moreMeaningful(_ lhs: Int, _ rhs: Int) -> Bool {
            let l = all[lhs], r = all[rhs]
            if l.weight != r.weight { return l.weight > r.weight }
            if l.at != r.at { return l.at > r.at }
            return lhs < rhs
        }
        var buckets: [String: [Int]] = [:]
        for index in all.indices {
            buckets["\(all[index].day)|\(all[index].sessionId)", default: []].append(index)
        }
        let bucketTimes = buckets.mapValues { indices in
            indices.reduce(Date.distantPast) { max($0, all[$1].at) }
        }
        var taken = Set<Int>()
        // PHASE 1 — reach.
        let bucketOrder = buckets.keys.sorted { lhs, rhs in
            let lat = bucketTimes[lhs] ?? .distantPast
            let rat = bucketTimes[rhs] ?? .distantPast
            if lat != rat { return lat > rat }
            return lhs < rhs
        }
        for key in bucketOrder {
            if taken.count >= limit { break }
            guard let best = buckets[key]?.min(by: moreMeaningful) else { continue }
            taken.insert(best)
        }
        // PHASE 2 — meaning.
        for index in all.indices.sorted(by: moreMeaningful) {
            if taken.count >= limit { break }
            taken.insert(index)
        }
        return taken.sorted { lhs, rhs in
            if all[lhs].at != all[rhs].at { return all[lhs].at < all[rhs].at }
            return lhs < rhs
        }.map { all[$0] }
    }

    /// Tail of a JSONL log, keeping rows whose `createdAt`/`ts` is within the
    /// window (rows without a parseable timestamp are kept — better noisy than
    /// silently dropped).
    private static func recentLines(
        at url: URL, since: Date, label: String, limit: Int
    ) throws -> String {
        guard let text = try optionalText(at: url) else {
            return "## \(label)\n(source absent)"
        }
        var kept: [String] = []
        for line in text.split(separator: "\n").reversed() {
            if kept.count >= limit { break }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw sourceError(url, "expected a JSON object in the retained error feed")
            }
            do {
                let ts = (obj["lastAt"] as? String ?? obj["createdAt"] as? String ?? obj["at"] as? String
                    ?? obj["ts"] as? String ?? obj["timestamp"] as? String).flatMap(parseISO)
                if let ts, ts < since { continue }
            }
            kept.append(TurnSecretRedactor.redactText(String(line)).prefix(280).description)
        }
        return "## \(label)\n\(kept.isEmpty ? "(none)" : kept.reversed().joined(separator: "\n"))"
    }

    private static func optionalText(at url: URL) throws -> String? {
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch { throw sourceError(url, error.localizedDescription) }
    }

    private static func sourceError(_ url: URL, _ cause: String) -> NSError {
        NSError(domain: "WeeklySelfImprovementLoop", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Weekly source unavailable at \(url.path): \(cause). Retained bytes were preserved."])
    }
}

/// What a weekly pass learns from: prompt sections already rendered, and the
/// standing corrections it may graduate (memory id → text).
public struct SelfImprovementLearning: Sendable {
    public var signals: String
    public var standing: [String: String]

    public init(signals: String = "", standing: [String: String] = [:]) {
        self.signals = signals
        self.standing = standing
    }
}

extension MaintenanceBackgroundWork {
    /// The previous pass's cards, by the ids its digest recorded — its
    /// one-tap proposals (`approval:`) and its standing lessons (`rem:`) — and
    /// what became of each, its execution receipt included.
    static func passOutcomes(cards: [String], inbox: SwiftNativeApprovalInbox, dataRoot: URL) async -> String {
        let rem = REMProposalStore(dataRoot: dataRoot).loadAll()
        var lines: [String] = []
        for card in cards {
            var what = card, approvalID: String?
            if card.hasPrefix("approval:") {
                approvalID = String(card.dropFirst("approval:".count))
            } else if let row = rem.first(where: { "rem:" + $0.id == card }) {
                what = "standing lesson: " + row.proposalText
                approvalID = row.approvalId
            }
            guard let approvalID else { lines.append("- \(what): not on a card now (it is staged again)"); continue }
            guard let record = try? await inbox.get(approvalID) else { lines.append("- \(what): its card is gone"); continue }
            if card.hasPrefix("approval:") { what = record.title }
            var failed = false
            if case .object(let executed)? = record.executedAction { failed = executed["error"] != nil }
            let outcome = record.status == "pending" ? "ignored, still waiting"
                : record.decision == "approved" ? (record.executedAction == nil ? "approved, not yet carried out"
                    : failed ? "approved, but carrying it out failed: \(record.detail ?? "")" : "approved and carried out")
                : record.decision == "denied" || record.status == "denied" ? "denied" : "ignored (\(record.decision ?? record.status))"
            lines.append("- \(what): \(outcome)")
        }
        return "## The last pass: its proposals and what became of them\n" + (lines.isEmpty ? "(none recorded)" : lines.joined(separator: "\n"))
    }

    /// A standing correction recurs in at least two independent conversations,
    /// covers half the observed turns in each, and covers two thirds of the
    /// week's conversations. Every context-building conversation counts in the
    /// denominator, including those with no recalls; no installation-volume floor.
    static func standingLessons(dataRoot: URL, now: Date = Date()) async throws -> [String: String] {
        let events = try await TurnTraceRecentReader(dataRootOverride: dataRoot)
            .read(now: now, since: now.addingTimeInterval(-7 * 86_400)).events
        var sessionOf: [String: String] = [:]
        for event in events { if let session = event.sessionId { sessionOf[event.turnId] = session } }
        var turns: [String: Int] = [:]
        var recalls: [String: [String: Int]] = [:]
        for event in events where event.kind == "context.summary" {
            guard let session = sessionOf[event.turnId], case .object(let payload) = event.payload,
                  case .array(let ids)? = payload["injectedMemoryIds"] else { continue }
            turns[session, default: 0] += 1
            for case .string(let id) in ids { recalls[id, default: [:]][session, default: 0] += 1 }
        }
        func throughout(_ id: String) -> Int {
            (recalls[id] ?? [:]).filter { Double($0.value) >= Double(turns[$0.key] ?? 0) / 2 }.count
        }
        let rows = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            .listMemories(persona: nil, status: "active", limit: nil)
        return Dictionary(uniqueKeysWithValues: rows.filter {
            ["correction", "instruction"].contains($0.metadata?.objectValue?["kind"]?.stringValue ?? "")
                && throughout($0.id) >= 2
                && Double(throughout($0.id)) >= Double(turns.count) * (2.0 / 3.0)
        }.map { ($0.id, $0.content) })
    }
}
