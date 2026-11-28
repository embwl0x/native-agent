import MindCore
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import SenseCore
import DeskCore
import ProviderRouting
import MacNerves
// Blueprint: | `ChatActions+ContextTraceTools.swift` | `SwiftToolDispatcher`: `impl_context_lookup`, `impl_scratchpad_read`, bounded anchored `impl_recent_trace_summary` pages; receipts span conversations by default, rank non-read actions first and scan complete retained since windows; `trace.usage` and `trace.model_calls` share this route and `TurnTraceRecentReader` for recorded sums, purpose counts and retention coverage; event reads stay in the calling conversation unless scope:all, every conversation and the background life; explicit session filters and bound turn refs |

// MARK: - Context, scratchpad, and trace tools

extension SwiftToolDispatcher {
    func impl_context_lookup(args: ContextLookupArgs) async throws -> JSONValue {
        if let type = args.type, type != "lookup_feature_surface" {
            throw AutonomyGateError.toolDenied(reason: "capabilities.lookup type must be lookup_feature_surface.")
        }
        let result = await SwiftNativeContextClient().lookup(query: args.query ?? "")
        // "ready" describes the catalog, not pending execution.
        guard case .object(var fields) = result.toJSON() else { return result.toJSON() }
        fields["status"] = .string("ok")
        return .object(fields)
    }

    func impl_scratchpad_read(args: ScratchpadReadArgs) async throws -> JSONValue {
        let sessionID = (args.sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "scratchpad_read requires session_id")
        }
        guard NativeAgentChatSessionID.isSafePathComponent(sessionID) else {
            throw AutonomyGateError.toolDenied(reason: "scratchpad_read invalid session_id")
        }

        let raw = try await ChatSessionScratch.read(dataRoot: dataRoot, sessionID: sessionID)
        guard case .object(let scratch) = raw else {
            return .object([
                "status": .string("ok"),
                "session_id": .string(sessionID),
                "found": .bool(false),
                "keys": .array([]),
                "entries": .object([:]),
            ])
        }

        if let key = args.key?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return .object([
                "status": .string("ok"),
                "session_id": .string(sessionID),
                "key": .string(key),
                "found": .bool(scratch[key] != nil),
                "value": scratch[key] ?? .null,
            ])
        }

        let keys = Array(scratch.keys.sorted().prefix(50))
        var entries: [String: JSONValue] = [:]
        for key in keys {
            if let value = scratch[key] {
                entries[key] = value
            }
        }
        return .object([
            "status": .string("ok"),
            "session_id": .string(sessionID),
            "found": .bool(!scratch.isEmpty),
            "keys": .array(keys.map { .string($0) }),
            "entries": .object(entries),
            "truncated": .bool(scratch.count > keys.count),
        ])
    }

    func impl_recent_trace_summary(turn: Turn, invocation: ChatToolInvocation, input: RecentTraceSummaryArgs) async throws -> JSONValue {
        let call = TraceSummaryCall(turn: turn, invocation: invocation, input: input)
        if let answer = try await traceSummaryFilters(call) { return answer }
        let currentSession = ChatToolSessionInjection.currentSession(turn: turn)
        var ownSessionOnly = turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) == true
        let snapshot: TurnTraceRecentReader.Snapshot
        do {
            if ownSessionOnly {
                snapshot = try await readScopedTraceSnapshot(call, currentSession: currentSession)
            } else {
                let globalSnapshot = try await readTraceSnapshot(call, sessionID: nil)
                if turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) == true {
                    ownSessionOnly = true
                    snapshot = try await readScopedTraceSnapshot(call, currentSession: currentSession)
                } else {
                    snapshot = globalSnapshot
                }
            }
        } catch {
            return .object([
                "status": .string("failed"),
                "error": .string(String(describing: error)),
                "count": .int(0),
                "traces": .array([]),
                "source": .string("detail"),
            ])
        }
        call.ownSessionOnly = ownSessionOnly
        call.currentSession = ownSessionOnly ? currentSession : nil
        try traceSummaryRank(call, snapshot: snapshot)
        try traceSummaryPage(call)
        return try traceSummaryResponse(call, snapshot: snapshot)
    }

    private func readScopedTraceSnapshot(_ call: TraceSummaryCall, currentSession: String?) async throws -> TurnTraceRecentReader.Snapshot {
        guard let currentSession else { return TurnTraceRecentReader.Snapshot(events: []) }
        if let filter = call.normalizedSessionFilter, filter != currentSession {
            return TurnTraceRecentReader.Snapshot(events: [])
        }
        return try await readTraceSnapshot(call, sessionID: currentSession)
    }

    private func readTraceSnapshot(_ call: TraceSummaryCall, sessionID: String?) async throws -> TurnTraceRecentReader.Snapshot {
        let settledTurn = call.kindFilter == TurnTraceEvent.dispatchSettledKind && call.turnID?.isEmpty == false ? call.turnID : nil
        return try await TurnTraceRecentReader(dataRootOverride: dataRoot).read(now: call.anchorDate ?? call.now,
            history: call.receiptID != nil || call.completedTurns != nil || call.turnID?.isEmpty == false,
            since: call.since ?? (call.receiptID != nil ? Date.distantPast : nil),
            holding: call.receiptID != nil ? ["tool.dispatch"] : [],
            trace: settledTurn,
            kinds: call.receiptID != nil ? ["tool.dispatch"] : nil,
            kindContains: call.receiptID == nil && call.completedTurns == nil && call.normalizedSessionFilter == nil
                && call.turnID?.isEmpty != false
                ? call.kindFilter : nil,
            receipt: call.receiptID,
            sessionID: sessionID)
    }

    /// The read's filters, each refused when malformed; model calls and usage are answered here, and a kind that names an action answers
    /// with the call that selects it.
    private func traceSummaryFilters(_ call: TraceSummaryCall) async throws -> JSONValue? {
        let turn = call.turn, input = call.input
        func requireUntaintedGlobalRead(_ view: String) throws {
            guard turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) != true else {
                throw AutonomyGateError.toolDenied(reason: "\(view) reads every conversation; a turn an untrusted agent steers reads only its own.")
            }
        }
        if input.view == "model_calls" {
            try requireUntaintedGlobalRead("model_calls")
            let result = try await TurnTraceRecentReader(dataRootOverride: dataRoot).modelCalls()
            try requireUntaintedGlobalRead("model_calls")
            return result
        }
        let usage = input.view == "usage"
        if usage {
            try requireUntaintedGlobalRead("usage")
        }
        let now = Date()
        let requestedLimit = input.limit?.wire.exactIntegerValue ?? 10
        let limit = max(1, min(requestedLimit, 50))
        let offset = max(0, input.offset?.wire.exactIntegerValue ?? 0)
        let effectsOnly = input.effectsOnly == true
        let receiptID = input.receiptID
        let receiptView = effectsOnly || input.view == "receipts"
        let since: Date?
        if let raw = input.since ?? (usage ? "today" : nil) {
            since = raw == "today" ? Calendar.current.startOfDay(for: now) : NativeTimestampFormat.parseISO8601(raw)
            guard since != nil else {
                throw AutonomyGateError.toolDenied(reason: "since must be today or an ISO-8601 timestamp with Z or an offset.")
            }
        } else { since = nil }
        if usage, let since {
            let by = input.by ?? "model"
            guard ["model", "surface", "day"].contains(by), since <= now else {
                throw AutonomyGateError.toolDenied(reason: "Usage requires by model, surface or day and since no later than now.")
            }
            let result = try await TurnTraceRecentReader(dataRootOverride: dataRoot).usage(since: since, now: now, by: by)
            try requireUntaintedGlobalRead("usage")
            return result
        }
        let completedTurns = (input.completedTurns?.wire.exactIntegerValue).map { max(1, min($0, 50)) }
        let kindFilter = input.kind
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let kindFilter, ToolNameAliases.appAction(kindFilter) != nil || ToolNameAliases.isFoldedAction(kindFilter) {
            var next = input.wire
            next["kind"] = .string("tool.dispatch")
            next["name"] = .string(kindFilter)
            return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("trace_kind_is_tool"),
                "detail": .string("kind selects events such as tool.dispatch; name selects an action. Nothing was read."),
                "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("trace.recent"), "args": .object(next)])])])
        }
        let nameFilter = input.name.map { ToolNameAliases.appAction(ToolNameAliases.canonical($0)) ?? $0.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        let statusFilter = input.status
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        let normalizedSessionFilter: String? = {
            guard let text = input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }()
        switch input.scope {
        case nil, "conversation"?: break
        case "all"? where normalizedSessionFilter == nil: break
        case "all"?:
            throw ToolFailureError("scope:all reads every conversation; session_id names one. Give one of them. Nothing was read.",
                                   argumentPath: "session_id", effects: .none)
        default: throw ToolFailureError("scope is conversation or all. Nothing was read.", argumentPath: "scope", effects: .none)
        }
        let turnID = input.turnID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = input.fields ?? []
        if fields.contains(where: { $0.isEmpty }) {
            throw ToolFailureError("fields takes 1–16 payload keys of at most 80 characters.", argumentPath: "fields", effects: .none)
        }
        // A continuation anchor is the record's own time for an event, in the record's own representation (seconds since 1970, every digit),
        // so the read and the cutoff meet the anchor exactly. The page continues from the newest retained event at or before it, whether or not
        // that exact event is still retained, and reads the anchor's own day. An ISO-8601 time is read as written.
        var anchorDate: Date?
        if let raw = input.before {
            guard let date = Double(raw).map(Date.init(timeIntervalSince1970:)) ?? TurnTraceEvent.parseISO8601(raw) else {
                throw ToolFailureError("before takes the timestamp a next_call carries. Nothing was read.", argumentPath: "before", effects: .none)
            }
            anchorDate = min(date, now)
        }
        call.now = now; call.limit = limit; call.offset = offset; call.effectsOnly = effectsOnly; call.receiptID = receiptID
        call.receiptView = receiptView; call.since = since; call.completedTurns = completedTurns; call.kindFilter = kindFilter
        call.nameFilter = nameFilter; call.statusFilter = statusFilter; call.normalizedSessionFilter = normalizedSessionFilter
        call.turnID = turnID; call.fields = fields; call.anchorDate = anchorDate
        return nil
    }

    /// The retained events in time order up to the anchor, the completed turns asked for, and receipts ranked non-read first.
    private func traceSummaryRank(_ call: TraceSummaryCall, snapshot: TurnTraceRecentReader.Snapshot) throws {
        let turn = call.turn, normalizedSessionFilter = call.normalizedSessionFilter, anchorDate = call.anchorDate
        let completedTurns = call.completedTurns, turnID = call.turnID, receiptView = call.receiptView
        let sessionTurnIDs: Set<String>
        if let normalizedSessionFilter {
            sessionTurnIDs = Set(snapshot.events.compactMap { event in
                event.sessionId == normalizedSessionFilter && event.turnId != "unknown"
                    ? event.turnId
                    : nil
            })
        } else {
            sessionTurnIDs = []
        }

        var events = snapshot.events.filter { event in
            !call.ownSessionOnly || call.currentSession.map { event.sessionId == $0 } == true
        }.sorted(by: { $0.ts > $1.ts })
        if let anchorDate { events = events.filter { $0.ts <= anchorDate } }
        var completedIDs: [String] = []
        if let completedTurns {
            for event in events where TurnTraceEvent.isTerminalKind(event.kind) {
                guard event.turnId != "unknown", !completedIDs.contains(event.turnId),
                      normalizedSessionFilter == nil || sessionTurnIDs.contains(event.turnId),
                      turnID?.isEmpty != false || event.turnId == turnID else { continue }
                completedIDs.append(event.turnId)
                if completedIDs.count == completedTurns { break }
            }
        }

        // Every event has a time, standalone receipts included, so every page carries an anchor its continuation can find.
        let anchor: JSONValue = events.first.map { JSONValue.string(String($0.ts.timeIntervalSince1970)) } ?? .null
        func nonReadReceipt(_ event: TurnTraceEvent) throws -> Bool {
            guard event.kind == "tool.dispatch", case .object(let payload) = event.payload,
                  payload["phase"] == .string("end") else { return false }
            let receipt = if case .object(let receipt)? = payload["receipt"] { receipt } else { [String: JSONValue]() }
            let result = if case .object(let result)? = receipt["resultReceipt"] { result } else { [String: JSONValue]() }
            let action = receipt["action"]?.stringValue ?? payload["name"]?.stringValue ?? payload["tool"]?.stringValue ?? ""
            let arguments = payload["args"]?.stringValue.flatMap { try? JSONValue.parse(Data($0.utf8)) }
            let args = if case .object(let args)? = arguments { args } else { [String: JSONValue]() }
            let policy = try AppActionBinding.action(input: ["action": .string(action), "args": args["args"] ?? .object(args)], turn: turn)
            return result["effects"] == .string("occurred")
                || (policy?.read == false && (arguments != nil || policy?.readWhen.isEmpty == true))
        }
        // Rank after anchoring in time so continuation offsets retain this ordering.
        let classified = try events.map { (event: $0, nonRead: try receiptView && nonReadReceipt($0)) }
        let ranked = receiptView ? classified.filter(\.nonRead) + classified.filter { !$0.nonRead } : classified
        events = ranked.map(\.event)
        call.sessionTurnIDs = sessionTurnIDs; call.events = events; call.completedIDs = completedIDs; call.anchor = anchor; call.ranked = ranked
    }

    /// One page of matching events as bounded summaries; selected payload fields share one byte budget across the page.
    private func traceSummaryPage(_ call: TraceSummaryCall) throws {
        let ranked = call.ranked, since = call.since, completedTurns = call.completedTurns, completedIDs = call.completedIDs
        let turnID = call.turnID, normalizedSessionFilter = call.normalizedSessionFilter, sessionTurnIDs = call.sessionTurnIDs
        let receiptID = call.receiptID, kindFilter = call.kindFilter, statusFilter = call.statusFilter, nameFilter = call.nameFilter
        let receiptView = call.receiptView, effectsOnly = call.effectsOnly, offset = call.offset, fields = call.fields, limit = call.limit
        // Shared across all returned events, in serialized UTF-8 bytes.
        var remainingPayloadBytes = 8 * 1024
        var summaries: [JSONValue] = []
        var matched = 0, summaryBytes = 0, hasMore = false
        for (event, nonRead) in ranked {
            if let since, event.ts < since { continue }
            if completedTurns != nil, !completedIDs.contains(event.turnId) { continue }
            if let turnID, !turnID.isEmpty, event.turnId != turnID { continue }
            if let normalizedSessionFilter,
               event.sessionId != normalizedSessionFilter,
               !sessionTurnIDs.contains(event.turnId) {
                continue
            }
            let kind = event.kind
            let payload: [String: JSONValue]
            if case .object(let object) = event.payload {
                payload = object
            } else {
                payload = [:]
            }
            let status = payload["status"]?.stringValue ?? ""
            if let receiptID {
                guard payload["phase"] == .string("end"), case .object(let receipt)? = payload["receipt"],
                      receipt["id"] == .string(receiptID) else { continue }
            }
            if let kindFilter, !kind.lowercased().contains(kindFilter) {
                continue
            }
            if let statusFilter, status.lowercased() != statusFilter {
                continue
            }

            let title = payload["name"]?.stringValue
                ?? payload["tool"]?.stringValue
                ?? payload["model"]?.stringValue
                ?? ""
            let action = if case .object(let receipt)? = payload["receipt"] { receipt["action"]?.stringValue } else { String?.none }
            if let nameFilter {
                guard kind == "tool.dispatch", nameFilter == (ToolNameAliases.appAction(ToolNameAliases.canonical(title)) ?? title.lowercased())
                    || nameFilter == action?.lowercased() else { continue }
            }
            if receiptView, kind != "tool.dispatch" || payload["phase"] != .string("end") { continue }
            if effectsOnly {
                guard case .object(let receipt)? = payload["receipt"],
                      receipt["preview"] != .bool(true), receipt["resultClass"] == .string("succeeded"),
                      case .object(let result)? = receipt["resultReceipt"],
                      result["effects"] != .string("none"), result["execution"] != .string("not_run") else { continue }
                guard nonRead else { continue }
            }
            matched += 1
            if matched <= offset { continue }
            let payloadKeys = Array(payload.keys.sorted().prefix(30))
            let row = event.jsonRow
            guard case .object(let object) = row else { continue }
            var summary: [String: JSONValue] = [
                "id": { if case .object(let receipt)? = payload["receipt"] { return receipt["id"] ?? .null }; return .null }(),
                "turn_id": .string(event.turnId),
                "kind": .string(kind),
                "title": .string(String(title.prefix(160))),
                "status": .string(status),
                "createdAt": object["ts"] ?? .null,
                "session_id": event.sessionId.map(JSONValue.string) ?? .null,
                "surface": event.surface.map(JSONValue.string) ?? .null,
                "payload_keys": .array(payloadKeys.map { .string($0) }),
                "receipt": payload["receipt"] ?? .null,
            ]
            if receiptView {
                summary["phase"] = payload["phase"]
                summary["action"] = action.map(JSONValue.string)
                summary["result_recovery"] = payload["result_recovery"]
                summary.removeValue(forKey: "payload_keys")
                if effectsOnly || nonRead {
                    summary["args"] = payload["args"]
                    summary["result"] = payload["result"]
                }
            }
            if !fields.isEmpty, remainingPayloadBytes > 2 {
                var selected: [String: JSONValue] = [:]
                var truncated = false
                for key in fields {
                    guard let value = payload[key] else { continue }
                    if key == "result", kind == "tool.dispatch", ["trace.recent", "recent_trace_summary"].contains(action ?? title) {
                        truncated = true
                        continue
                    }
                    var candidate = selected
                    candidate[key] = value
                    let redacted = TurnTraceRedactor.redactValue(.object(candidate))
                    if try redacted.serializedData(pretty: false).count <= remainingPayloadBytes,
                       case .object(let safe) = redacted {
                        selected = safe
                    } else {
                        truncated = true
                    }
                }
                let values = JSONValue.object(selected)
                remainingPayloadBytes = max(0, remainingPayloadBytes - (try values.serializedData(pretty: false).count))
                // Once the shared budget is spent, later events carry no payload at all.
                summary["payload"] = values
                summary["payload_truncated"] = .bool(truncated)
            }
            let byteCount = try JSONValue.object(summary).serializedData(pretty: false).count
            if summaries.count >= limit || summaryBytes + byteCount > 24 * 1024 {
                hasMore = true
                break
            }
            summaryBytes += byteCount
            summaries.append(.object(summary))
        }
        call.summaries = summaries; call.hasMore = hasMore
    }

    /// The page with its read references, the app's lives, coverage and the next call, bounded to the response budget.
    private func traceSummaryResponse(_ call: TraceSummaryCall, snapshot: TurnTraceRecentReader.Snapshot) throws -> JSONValue {
        let input = call.input, turn = call.turn, invocation = call.invocation, offset = call.offset, events = call.events
        let normalizedSessionFilter = call.normalizedSessionFilter, sessionTurnIDs = call.sessionTurnIDs, turnID = call.turnID
        let anchor = call.anchor, completedIDs = call.completedIDs, completedTurns = call.completedTurns, receiptView = call.receiptView
        let receiptID = call.receiptID, effectsOnly = call.effectsOnly, hasMore = call.hasMore
        var summaries = call.summaries
        var next = input.wire
        next["offset"] = .int(Int64(offset + summaries.count))
        next["before"] = anchor
        let candidateIDs = Array(events.filter { event in
            TurnTraceEvent.isTerminalKind(event.kind) && (normalizedSessionFilter == nil || sessionTurnIDs.contains(event.turnId))
        }.reduce(into: [String]()) { ids, event in
            if event.turnId != "unknown", !ids.contains(event.turnId) { ids.append(event.turnId) }
        }.prefix(6))
        let missingTurn = turnID?.isEmpty == false && !events.contains { $0.turnId == turnID }
        let reads = summaries.compactMap { value -> (tool: String, input: [String: JSONValue], title: String)? in
            guard case .object(let row) = value, let id = row["turn_id"]?.stringValue else { return nil }
            return ("recent_trace_summary", ["turn_id": .string(id), "view": .string("receipts"), "session_id": row["session_id"] ?? .null], "Trace turn")
        } + (missingTurn ? candidateIDs.map { id in
            let session = events.first { $0.turnId == id && $0.sessionId != nil }?.sessionId
            return ("recent_trace_summary", ["turn_id": .string(id), "view": .string("receipts"), "session_id": session.map(JSONValue.string)
                ?? .null], "Trace turn")
        } : [])
        let refs: [JSONValue]
        let refNote: String
        do {
            refs = try AgentWorkspace.readReferences(workspace: ChatWorkspaceBinding.operation(turn: turn, invocation: invocation, jobs: jobStore),
                reads, dataRoot: dataRoot)
            refNote = "Open an observed read_ref or candidate_turn_ref with app {item:ref}; its exact turn and session are bound server-side."
        } catch {
            refs = reads.map { _ in .null }
            refNote = "Read references were not saved: \(error.localizedDescription)"
        }
        summaries = summaries.enumerated().map { index, value in
            guard case .object(var row) = value else { return value }
            if refs[index] != .null { row["read_ref"] = row["turn_id"] == .string("unknown") ? .null : refs[index] }
            return .object(row)
        }
        // Restarts are part of what happened: every read carries the app's lives, whatever its filters and page.
        let lives: JSONValue, livesNote: String
        do {
            lives = .array(try BodyReport.lives(dataRoot))
            livesNote = "The app's lives, newest first, with how each ended. A row older than lives[0].started_at happened before the latest start."
        } catch {
            lives = .null
            livesNote = "The record of the app's starts and ends could not be read: \(error.localizedDescription)"
        }
        var response: [String: JSONValue] = [
            "status": .string(missingTurn ? "no_match" : snapshot.completeSequences ? "ok" : "partial"),
            "lives": lives,
            "lives_note": .string(livesNote),
            "detail": missingTurn ? .string("No retained turn matches turn_id. Use an exact candidate_turn_id; no matching trace evidence was read.") : .null,
            "candidate_turn_ids": missingTurn ? .array(candidateIDs.map(JSONValue.string)) : .array([]),
            "candidate_turn_refs": missingTurn ? .array(refs.suffix(candidateIDs.count).filter { $0 != .null }) : .array([]),
            "read_ref_note": .string(refNote),
            "count": .int(Int64(summaries.count)),
            "has_more": .bool(hasMore),
            "next_call": hasMore ? .object(["tool": .string("app"), "input": .object(["action": .string("trace.recent"), "args": .object(next)])]) : .null,
            "traces": .array(summaries),
            "source": .string("detail"),
            "sources": .array([.string("detail")]),
            "scan_truncated": .bool(snapshot.limitReached),
            "unreadable_rows": .int(Int64(snapshot.unreadable)),
            "completed_turn_ids": .array(completedIDs.map(JSONValue.string)),
            "requested_completed_turns": completedTurns.map { .int(Int64($0)) } ?? .null,
            "shown_note": .string("shown is an action label, not evidence that the screen moved."),
            "scanned_count": .int(Int64(snapshot.events.count)),
            "session_id": (normalizedSessionFilter ?? call.currentSession).map(JSONValue.string) ?? .null,
            "scope": .string(normalizedSessionFilter != nil || call.ownSessionOnly
                ? "session" : "all: every conversation and the background life (rows with session_id null)"),
        ]
        if receiptView {
            response["order_note"] = .string("""
                Non-read actions first, then reads; newest first within each group. Receipts include attempts and failures; inspect resultClass \
                and resultReceipt for recorded effects.
                """)
        }
        if receiptID != nil, summaries.isEmpty {
            response["status"] = .string("unavailable")
            response["detail"] = .string(!snapshot.completeSequences
                ? "The receipt was not found in incomplete retained evidence. Its absence and the operation's outcome are unknown; do not replay it."
                : "No retained dispatch receipt matches receipt_id. This does not establish the original operation's outcome; do not replay it.")
        }
        if effectsOnly {
            response["effects_note"] = .string("""
                Successful non-read actions, excluding previews and explicit no-effect results. args/result are bounded redacted previews for \
                target and effect; paired inner/app receipts can describe one action. No matches is not proof of no changes; check \
                scan_truncated and has_more. Dispatch success does not prove the effect still persists.
                """)
        }
        let bounded = try EncodedPrefix.largestPrefix(count: summaries.count, maximumEncodedBytes: 32 * 1024) { count in
            if count < summaries.count {
                next["offset"] = .int(Int64(offset + count))
                response["count"] = .int(Int64(count))
                response["traces"] = .array(Array(summaries.prefix(count)))
                response["has_more"] = .bool(true)
                response["next_call"] = .object(["tool": .string("app"), "input": .object(["action": .string("trace.recent"), "args": .object(next)])])
            }
            return try JSONValue.object(response).serializedData(pretty: false)
        }
        guard bounded.data.count <= 32 * 1024, bounded.included > 0 || summaries.isEmpty else {
            return .object(["status": .string("failed"), "effects": .string("none"),
                "detail": .string("Trace filters exceed the response budget. Shorten the filter values and retry.")])
        }
        return try JSONValue.parse(bounded.data)
    }

}

/// One trace read: its filters as parsed, the events it ranked and the page it filled.
private final class TraceSummaryCall {
    let turn: Turn
    let invocation: ChatToolInvocation
    let input: RecentTraceSummaryArgs
    var now = Date.distantPast
    var limit = 0
    var offset = 0
    var effectsOnly = false
    var receiptID: String?
    var receiptView = false
    var since: Date?
    var completedTurns: Int?
    var kindFilter: String?
    var nameFilter: String?
    var statusFilter: String?
    var normalizedSessionFilter: String?
    var turnID: String?
    var fields: [String] = []
    var anchorDate: Date?
    var ownSessionOnly = false
    var currentSession: String?
    var sessionTurnIDs: Set<String> = []
    var events: [TurnTraceEvent] = []
    var completedIDs: [String] = []
    var anchor: JSONValue = .null
    var ranked: [(event: TurnTraceEvent, nonRead: Bool)] = []
    var summaries: [JSONValue] = []
    var hasMore = false

    init(turn: Turn, invocation: ChatToolInvocation, input: RecentTraceSummaryArgs) {
        self.turn = turn
        self.invocation = invocation
        self.input = input
    }
}
