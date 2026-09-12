#if DEBUG
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore

/// THE TEST BED for the memory manager (User, 2026-09-11: "tested on his real
/// transcripts before it goes live").
///
/// Reads the chat transcripts already on disk, runs the memory-manager pass over
/// the last fourteen days of real (person, agent) exchanges with the app's LIVE
/// routing, and writes a markdown report. It WRITES NOTHING to memory: it stages
/// nothing, promotes nothing, and credits no recall usage — the suite that runs
/// it asserts the write verbs are absent from this file. The only memory
/// reads are the same two the live lane does — top-K recall for the prompt and
/// the pending list — and a read of the proposals table for the OLD lane's side
/// of the comparison.
///
/// Entry point, the SimplicitySnapshots shape: DEBUG-only, env-var gated.
///   MEMORY_REPLAY_DIR=<dir> swift test --filter memoryManagerReplay
/// Optional:
///   MEMORY_REPLAY_DAYS   (default 14)
///   MEMORY_REPLAY_LIMIT  (default 0 = every eligible turn)
enum MemoryManagerReplay {

    // MARK: - What one turn looks like on disk

    struct TranscriptRow: Decodable {
        let id: String?
        let role: String?
        let content: String?
        let createdAt: String?
        let sessionId: String?
        let source: String?
    }

    struct Turn {
        let sessionId: String
        let createdAt: String
        let userMessage: String
        let assistantMessage: String
    }

    struct Row {
        let turn: Turn
        let decisions: [MemoryManagerDecision]
        /// nil reason = staged; otherwise why the staging gate refused it.
        let verdicts: [(decision: MemoryManagerDecision, rejection: String?)]
        let failed: Bool
    }

    // MARK: - Entry point

    static func render(to directory: URL) async throws {
        let environment = ProcessInfo.processInfo.environment
        let days = Int(environment["MEMORY_REPLAY_DAYS"] ?? "") ?? 14
        let limit = Int(environment["MEMORY_REPLAY_LIMIT"] ?? "") ?? 0
        let dataRoot = PersistenceCore.defaultDataRoot()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let turns = try readTurns(dataRoot: dataRoot, days: days)
        let selected = limit > 0 ? Array(turns.suffix(limit)) : turns
        FileHandle.standardError.write(Data(
            "memory-replay: \(turns.count) eligible turns in \(days)d, running \(selected.count)\n".utf8
        ))

        let memory = SwiftNativeMemoryV2.shared
        let manager = MindMemoryManager()
        var rows: [Row] = []
        var failures = 0

        for (index, turn) in selected.enumerated() {
            let existing: [MemoryManagerExistingMemory] = await {
                guard let response = try? await memory.recall(
                    MemoryV2RecallRequest(
                        text: "\(turn.userMessage)\n\(turn.assistantMessage)",
                        topK: MemoryManagerLane.recallTopK
                    ),
                    recordingUsage: false
                ) else { return [] }
                return response.scored.map {
                    MemoryManagerExistingMemory(id: $0.record.id, content: $0.record.text)
                }
            }()
            let pending: [String] = await {
                guard let all = try? await memory.listProposals(status: "pending") else { return [] }
                return all
                    .filter { !MemoryMoments.isMoment($0.metadata) }
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(MemoryManagerLane.pendingCap)
                    .map(\.content)
            }()
            let request = MemoryManagerRequest(
                userMessage: turn.userMessage,
                assistantMessage: turn.assistantMessage,
                existing: existing,
                pending: pending,
                personName: NativeCognitionRuntime.resolveUserName(dataRoot: dataRoot)
            )
            guard let decisions = await manager.review(request) else {
                failures += 1
                rows.append(Row(turn: turn, decisions: [], verdicts: [], failed: true))
                FileHandle.standardError.write(Data("memory-replay: [\(index + 1)/\(selected.count)] call failed\n".utf8))
                continue
            }
            // The same gate the live lane applies, minus the embedding
            // near-duplicate drop — that one needs the write path's comparison
            // set and this replay stages nothing.
            let verdicts = decisions
                .filter { $0.action != .skip }
                .map { decision -> (MemoryManagerDecision, String?) in
                    if decision.confidence < MemoryManagerLane.confidenceFloor {
                        return (decision, "confidence \(String(format: "%.2f", decision.confidence)) below \(MemoryManagerLane.confidenceFloor)")
                    }
                    return (decision, MemoryManagerLane.statementRejectionReason(
                        decision.statement,
                        userMessage: turn.userMessage,
                        assistantMessage: turn.assistantMessage
                    ))
                }
            rows.append(Row(turn: turn, decisions: decisions, verdicts: verdicts, failed: false))
            let stagedNow = verdicts.filter { $0.1 == nil }.count
            FileHandle.standardError.write(Data(
                "memory-replay: [\(index + 1)/\(selected.count)] \(stagedNow) staged\n".utf8
            ))
        }

        let legacy = await legacyProposals(memory: memory, days: days)
        let markdown = report(
            rows: rows,
            totalTurns: turns.count,
            ranTurns: selected.count,
            failures: failures,
            days: days,
            legacy: legacy
        )
        try markdown.write(
            to: directory.appendingPathComponent("report.md"),
            atomically: true,
            encoding: .utf8
        )
        FileHandle.standardError.write(Data(
            "memory-replay: wrote \(directory.appendingPathComponent("report.md").path)\n".utf8
        ))
    }

    // MARK: - Transcripts

    static func readTurns(dataRoot: URL, days: Int) throws -> [Turn] {
        let chat = dataRoot.appendingPathComponent("chat")
        var files: [URL] = []
        let fm = FileManager.default
        let flat = chat.appendingPathComponent("messages")
        if let names = try? fm.contentsOfDirectory(atPath: flat.path) {
            files += names.filter { $0.hasSuffix(".jsonl") }.map(flat.appendingPathComponent)
        }
        let sessions = chat.appendingPathComponent("sessions")
        if let dirs = try? fm.contentsOfDirectory(atPath: sessions.path) {
            for dir in dirs {
                let sub = sessions.appendingPathComponent(dir)
                guard let names = try? fm.contentsOfDirectory(atPath: sub.path) else { continue }
                files += names
                    .filter { $0.hasPrefix("messages") && $0.hasSuffix(".jsonl") }
                    .map(sub.appendingPathComponent)
            }
        }
        // The compaction archives under sessions/ repeat rows from messages/;
        // a message id is the identity, so a row read twice is one row.
        var unique: [String: TranscriptRow] = [:]
        let decoder = JSONDecoder()
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let row = try? decoder.decode(TranscriptRow.self, from: data),
                      let id = row.id else { continue }
                unique[id] = row
            }
        }
        let cutoff = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(days) * 86_400)
        )
        var bySession: [String: [TranscriptRow]] = [:]
        for row in unique.values {
            guard let session = row.sessionId, !session.isEmpty else { continue }
            // A bot's session has the agent's own brief in the user seat.
            guard !session.hasPrefix("bot-"), row.source != "bot" else { continue }
            guard let role = row.role, role == "user" || role == "assistant" else { continue }
            guard let created = row.createdAt, created >= cutoff else { continue }
            bySession[session, default: []].append(row)
        }
        var turns: [Turn] = []
        for (session, rows) in bySession {
            let ordered = rows.sorted {
                ($0.createdAt ?? "", $0.id ?? "") < ($1.createdAt ?? "", $1.id ?? "")
            }
            for (index, row) in ordered.enumerated() where row.role == "user" {
                let user = (row.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !user.isEmpty else { continue }
                // Bridge/peer traffic: another agent in the user seat.
                guard !user.hasPrefix("[from:") else { continue }
                guard let reply = ordered[(index + 1)...].first(where: { $0.role == "assistant" }) else {
                    continue
                }
                let assistant = (reply.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !assistant.isEmpty else { continue }
                turns.append(Turn(
                    sessionId: session,
                    createdAt: row.createdAt ?? "",
                    userMessage: user,
                    assistantMessage: assistant
                ))
            }
        }
        return turns.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - The old lane, from ground truth

    /// What the DELETED lane actually staged from these same transcripts.
    ///
    /// Deliberately not a replica of the old regex code: the rows it produced are
    /// sitting in the live proposals table with their dates and sessions, which is
    /// stronger evidence than re-running a copy of it. Source prefixes
    /// `adaptive-promoter:` and `semantic-adaptive-extractor` were that lane's.
    static func legacyProposals(memory: SwiftNativeMemoryV2, days: Int) async -> [ProposalRecord] {
        guard let all = try? await memory.listProposals(status: nil) else { return [] }
        let cutoff = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(days) * 86_400)
        )
        return all
            .filter { proposal in
                guard let source = proposal.source else { return false }
                return source.hasPrefix("adaptive-promoter")
                    || source.hasPrefix("semantic-adaptive-extractor")
            }
            .filter { !MemoryMoments.isMoment($0.metadata) }
            .filter { $0.createdAt >= cutoff }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - The report

    static func report(
        rows: [Row],
        totalTurns: Int,
        ranTurns: Int,
        failures: Int,
        days: Int,
        legacy: [ProposalRecord]
    ) -> String {
        let staged = rows.flatMap { row in row.verdicts.filter { $0.rejection == nil } }
        let refused = rows.flatMap { row in row.verdicts.filter { $0.rejection != nil } }
        var out = """
        # Memory manager replay — \(Self.today())

        The new memory-manager pass run over real chat transcripts from this Mac's
        data root, with live routing (the Providers "Memory" row). Nothing was
        written: no proposal staged, no memory accepted, no recall usage credited.

        | | |
        | --- | --- |
        | Window | last \(days) days |
        | Turns read (person seat, not bot, not bridge) | \(totalTurns) |
        | Turns run through the manager | \(ranTurns) |
        | Model calls that failed or timed out | \(failures) |
        | NEW proposals (would stage) | \(staged.count) |
        | New statements the gate refused | \(refused.count) |
        | OLD lane proposals over the same window (live table, ground truth) | \(legacy.count) |

        ## New lane — every turn that produced a proposal

        """
        let producing = rows.filter { row in row.verdicts.contains { $0.rejection == nil } }
        if producing.isEmpty {
            out += "_No turn produced a proposal._\n"
        }
        for row in producing {
            out += "\n### \(Self.day(row.turn.createdAt)) · session `\(String(row.turn.sessionId.prefix(8)))`\n\n"
            out += "**He said:** \(Self.clip(row.turn.userMessage, 400))\n\n"
            for (decision, rejection) in row.verdicts where rejection == nil {
                out += "- **\(decision.statement)**\n"
                out += "  - kind `\(decision.kind)` · confidence \(String(format: "%.2f", decision.confidence)) · action `\(decision.action.rawValue)`"
                if let id = decision.updatesId { out += " · updates `\(String(id.prefix(8)))`" }
                out += "\n"
                out += "  - why: \(decision.whyItMatters.isEmpty ? "—" : decision.whyItMatters)\n"
            }
        }

        out += "\n## New lane — what the gate refused\n\n"
        if refused.isEmpty {
            out += "_Nothing was refused._\n"
        }
        for (decision, rejection) in refused {
            out += "- \(Self.clip(decision.statement, 180)) — _\(rejection ?? "")_\n"
        }

        out += """

        ## Old lane — what it actually staged, same window

        These are live rows, not a re-run: the deleted lane's proposals as they
        landed, with their own dates and status. This is the side of the
        comparison User has been looking at on the Memories page.

        """
        if legacy.isEmpty {
            out += "_No rows from the old lane in this window._\n"
        }
        for proposal in legacy {
            out += "- `\(Self.day(proposal.createdAt))` **\(Self.clip(proposal.content, 200))** — status `\(proposal.status)`\n"
        }
        return out
    }

    /// The report is committed to the repo, and the transcripts it quotes carry
    /// the person's home directory (old-lane tool receipts are full of it). Fold
    /// it to `~` on the way out — the repo's leak check refuses a personal home
    /// path, and rightly.
    static func redact(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    static func clip(_ text: String, _ cap: Int) -> String {
        let folded = redact(text)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.count <= cap ? folded : String(folded.prefix(cap)) + "…"
    }

    static func day(_ iso: String) -> String { String(iso.prefix(16)) }

    static func today() -> String {
        String(ISO8601DateFormatter().string(from: Date()).prefix(10))
    }
}
#endif
