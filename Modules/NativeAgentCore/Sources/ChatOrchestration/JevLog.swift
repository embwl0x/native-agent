import Foundation
import PersistenceCore

/// The five advisory lanes, plus the one lane the agent drives itself. The raw
/// value is the log row's `lane` field.
public enum JevLane: String, Sendable, CaseIterable {
    case preTurn = "pre_turn"
    case toolCall = "tool_call"
    case postTurn = "post_turn"
    case memoryDedup = "memory_dedup"
    case shadowRank = "shadow_rank"
    /// Not advisory: the `second_opinion` tool, where the agent asks its own
    /// typed questions. Same row shape as the five, so one log reads whole.
    case secondOpinion = "second_opinion"

    /// The settings id that turns this lane off on its own.
    public var settingID: String { "jev.lane.\(rawValue)" }
}

/// Identity carried alongside a call so a row can be found again, plus the
/// slot for what actually happened afterwards.
struct JevLogContext: Sendable {
    var sessionID: String?
    var turnID: String?
    var runID: String?
    /// What the agent actually did, filled in after the fact: for a pre-turn
    /// brief, the tools really dispatched that turn; for a dedup check,
    /// whether the save happened.
    var acted: String?

    init(sessionID: String? = nil, turnID: String? = nil, runID: String? = nil, acted: String? = nil) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.runID = runID
        self.acted = acted
    }
}

/// `<dataRoot>/jev/log.jsonl`: one JSON object per call, rotated at 10 MB. The
/// field names match the reference hooks' log where they overlap (ts, lane,
/// summary, answers, usage, secs, err) so both logs read the same.
///
/// The root is the one the CALLER was built with, passed in on every write —
/// never the process default, which would scatter rows across roots whenever a
/// dispatcher was constructed with an injected root.
///
/// Rows can carry a person's words, so the directory is 0700, the file 0600,
/// and every free-text field goes through the app's canonical redactor first.
///
/// The log is the whole product of the shadow lanes and the only place a
/// finding that never reached the agent can be read back.
actor JevLog {
    static let shared = JevLog()

    private static let rotateBytes = 10 * 1024 * 1024

    /// Serialize an explicit diagnostic read with this owner's appends and
    /// rotation. Detached calls may still be in flight; absence is not a skip.
    func evidence(dataRoot: URL, sessionID: String, turnID: String?) -> JSONValue {
        JevEvidenceReader.projection(dataRoot: dataRoot, sessionID: sessionID, turnID: turnID)
    }

    private func directory(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("jev", isDirectory: true)
    }

    private static func nowStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    /// Hand a finished row to the actor and return. NOTHING waits on the disk.
    ///
    /// Every lane goes through this. The row is built on the caller's side —
    /// pure string work — and only the write is enqueued, so an advisory lane
    /// can never make a turn wait on a log flush. Rows can therefore land in
    /// the file in a slightly different order than they were produced, which
    /// is why every row carries its own `ts`.
    private nonisolated func enqueue(_ row: [String: JSONValue], dataRoot: URL) {
        Task { await self.write(row, dataRoot: dataRoot) }
    }

    nonisolated func append(
        lane: JevLane,
        summary: String,
        answers: JevAnswers?,
        seconds: TimeInterval,
        error: String?,
        context: JevLogContext,
        dataRoot: URL,
        extra: [String: JSONValue] = [:]
    ) {
        var row: [String: JSONValue] = [
            "ts": .string(Self.nowStamp()),
            "lane": .string(lane.rawValue),
            "summary": .string(Self.redacted(summary)),
            "secs": .double((seconds * 100).rounded() / 100),
            "prompt_version": .string(JevCatalog.promptVersion),
        ]
        Self.addContext(context, to: &row)
        if let error { row["err"] = .string(Self.redacted(error)) }
        if let answers {
            row["answers"] = .object(answers.flattened.mapValues(JSONValue.string))
            row["usage"] = .object([
                "input_tokens": .int(Int64(answers.inputTokens)),
                "output_tokens": .int(Int64(answers.outputTokens)),
            ])
            row["model"] = .string(answers.modelVersion)
        }
        for (key, value) in extra { row[key] = NativeAgentSecretRedactor.redactValue(value) }
        enqueue(row, dataRoot: dataRoot)
    }

    /// Append a bare row with no call behind it — used to record what the
    /// agent actually did after an earlier row was written.
    nonisolated func note(
        lane: JevLane,
        summary: String,
        context: JevLogContext,
        dataRoot: URL,
        extra: [String: JSONValue] = [:]
    ) {
        var row: [String: JSONValue] = [
            "ts": .string(Self.nowStamp()),
            "lane": .string(lane.rawValue),
            "summary": .string(Self.redacted(summary)),
            "prompt_version": .string(JevCatalog.promptVersion),
        ]
        Self.addContext(context, to: &row)
        for (key, value) in extra { row[key] = NativeAgentSecretRedactor.redactValue(value) }
        enqueue(row, dataRoot: dataRoot)
    }

    /// The 160-char summary, through the same redactor every other free-text
    /// field uses. Redact FIRST, then cut: cutting first can slice a secret in
    /// half and leave the half that still matches nothing.
    static func redacted(_ text: String) -> String {
        NativeAgentSecretRedactor.redactText(text).jevTruncated(160)
    }

    /// WHAT WAS TOLD, on any row where a note or a line actually left the lane.
    ///
    /// The log recorded what the lanes answered and never what they SAID, so
    /// nobody could read back whether a brief helped — the finding and the
    /// delivered words were in different places, and one of them was nowhere.
    /// These three fields close that: the delivered text, the turn whose
    /// content produced it, and whether it reached the agent at all.
    ///
    /// `reachedAgent` means exactly one thing, and it is the strongest thing
    /// the helper can honestly observe: the line was APPENDED TO THE TURN'S
    /// CONTEXT, or attached to the tool result the model reads next. That is
    /// the last point on the path the helper can see. It is not proof the
    /// model read it, weighed it, or that the assembled request still carried
    /// it — nothing is threaded further down to find out. Queued-but-not-yet-
    /// delivered is false, and so is a line that lost the three-line cap. Same
    /// redactor as every other free-text field, redacted before it is cut.
    static func delivery(told: String, sourceTurn: String?, reachedAgent: Bool) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "told": .string(NativeAgentSecretRedactor.redactText(told).jevTruncated(300)),
            "reached_agent": .bool(reachedAgent),
        ]
        if let sourceTurn, !sourceTurn.isEmpty { fields["source_turn"] = .string(sourceTurn) }
        return fields
    }

    private static func addContext(_ context: JevLogContext, to row: inout [String: JSONValue]) {
        if let value = context.sessionID { row["sessionId"] = .string(value) }
        if let value = context.turnID { row["turnId"] = .string(value) }
        if let value = context.runID { row["runId"] = .string(value) }
        if let value = context.acted { row["acted"] = .string(Self.redacted(value)) }
    }

    private func write(_ row: [String: JSONValue], dataRoot: URL) {
        let manager = FileManager.default
        let directory = directory(dataRoot)
        let file = directory.appendingPathComponent("log.jsonl")
        do {
            // 0700: the rows quote what a person typed, so the directory is
            // no more readable than the conversation store itself.
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            rotateIfNeeded(manager, directory: directory, file: file)
            var line = try JSONValue.object(row).serializedData(pretty: false)
            line.append(0x0A)
            if manager.fileExists(atPath: file.path) {
                // REPAIR ON EVERY OPEN, not only at creation. `createFile`'s
                // attributes apply once; a log written by an older build, or
                // left behind by a restore or a copy, keeps whatever mode it
                // arrived with and would otherwise stay world-readable for
                // ever. Throwing on purpose: if the mode cannot be fixed the
                // row is dropped rather than appended to a readable file.
                try manager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path
                )
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                guard manager.createFile(
                    atPath: file.path,
                    contents: line,
                    attributes: [.posixPermissions: 0o600]
                ) else { return }
                try manager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path
                )
            }
        } catch {
            // The log is never allowed to affect a turn.
        }
    }

    /// Move the current file aside and let the next write create a fresh one.
    ///
    /// The backup is NOT removed first: a remove-then-failed-move loses the
    /// only copy there was. `moveItem` onto an existing path fails, so the
    /// replace is done with `replaceItemAt`, and when that cannot be done the
    /// current file simply stays and grows by one more row — exceeding the
    /// bound by a row beats destroying a rotation.
    private func rotateIfNeeded(_ manager: FileManager, directory: URL, file: URL) {
        guard
            let size = try? manager.attributesOfItem(atPath: file.path)[.size] as? Int,
            size >= Self.rotateBytes
        else { return }
        let rolled = directory.appendingPathComponent("log.1.jsonl")
        if manager.fileExists(atPath: rolled.path) {
            _ = try? manager.replaceItemAt(rolled, withItemAt: file)
        } else {
            try? manager.moveItem(at: file, to: rolled)
        }
    }
}
