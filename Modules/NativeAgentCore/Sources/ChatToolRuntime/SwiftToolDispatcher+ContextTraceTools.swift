import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ToolRegistry
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution

// MARK: - Context, scratchpad, and trace tools

extension SwiftToolDispatcher {
    func impl_context_lookup(input: [String: JSONValue]) async throws -> JSONValue {
        var body = input
        if jsonString(body["type"]) == nil,
           jsonString(body["lookup"]) == nil,
           jsonString(body["id"]) == nil {
            body["type"] = .string("lookup_feature_surface")
        }
        let client = SwiftNativeContextClient(dataRoot: dataRoot)
        guard let result = await client.lookup(body: body) else {
            return .object([
                "status": .string("unsupported"),
                "runtime": .string("swift-native"),
                "error": .string("context_lookup currently supports only the Swift-native feature-surface operating map branch."),
                "supported_types": .array([
                    .string("lookup_feature_surface"),
                    .string("feature_surface"),
                    .string("features"),
                ]),
            ])
        }
        // The lookup has finished. "ready" describes the feature catalog, not
        // a tool still waiting to run.
        guard case .object(var fields) = result.toJSON() else { return result.toJSON() }
        fields["status"] = .string("ok")
        return .object(fields)
    }

    func impl_scratchpad_read(input: [String: JSONValue]) async throws -> JSONValue {
        let input = input.filter { $0.value != .string("") }
        let rawSessionID = jsonString(input["session_id"])
            ?? jsonString(input["sessionId"])
            ?? ""
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "scratchpad_read requires session_id")
        }
        guard isSafeSessionPathComponent(sessionID) else {
            throw AutonomyGateError.toolDenied(reason: "scratchpad_read invalid session_id")
        }

        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("scratch.json")
        let raw = try await SwiftNativePersistenceCore().readJSON(path, ifMissing: .object([:]))
        guard case .object(let scratch) = raw else {
            return .object([
                "status": .string("ok"),
                "session_id": .string(sessionID),
                "found": .bool(false),
                "keys": .array([]),
                "entries": .object([:]),
            ])
        }

        if let key = jsonString(input["key"])?.trimmingCharacters(in: .whitespacesAndNewlines),
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

    func impl_recent_trace_summary(input: [String: JSONValue]) async throws -> JSONValue {
        let usage = jsonString(input["view"]) == "usage"
        let now = Date()
        let requestedLimit = optionalInt(input, "limit") ?? 10
        let limit = max(1, min(requestedLimit, 50))
        let offset = max(0, optionalInt(input, "offset") ?? 0)
        let effectsOnly = input["effects_only"] == .bool(true)
        let receiptView = effectsOnly || jsonString(input["view"]) == "receipts"
        let since: Date?
        if let raw = jsonString(input["since"]) ?? (usage ? "today" : nil) {
            let formatter = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions.insert(.withFractionalSeconds)
            since = raw == "today" ? Calendar.current.startOfDay(for: now) : formatter.date(from: raw) ?? fractional.date(from: raw)
            guard since != nil else {
                throw AutonomyGateError.toolDenied(reason: "since must be today or an ISO-8601 timestamp with Z or an offset.")
            }
        } else { since = nil }
        if usage, let since {
            let by = jsonString(input["by"]) ?? "model"
            guard ["model", "surface", "day"].contains(by), since <= now else {
                throw AutonomyGateError.toolDenied(reason: "Usage requires by model, surface or day and since no later than now.")
            }
            return try await TurnTraceRecentReader(dataRootOverride: dataRoot).usage(since: since, now: now, by: by)
        }
        let completedTurns = optionalInt(input, "completed_turns").map { max(1, min($0, 50)) }
        let kindFilter = jsonString(input["kind"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let kindFilter, ToolNameAliases.appAction(kindFilter) != nil || ToolNameAliases.isFoldedAction(kindFilter) {
            var next = input.filter { !$0.key.hasPrefix("__") }
            next["kind"] = .string("tool.dispatch")
            next["name"] = .string(kindFilter)
            return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("trace_kind_is_tool"),
                "detail": .string("kind selects events such as tool.dispatch; name selects a tool or action. Nothing was read."),
                "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("trace.recent"), "args": .object(next)])])])
        }
        let nameFilter = jsonString(input["name"]).map { ToolNameAliases.appAction(ToolNameAliases.canonical($0)) ?? $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        let statusFilter = jsonString(input["status"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        // Normalize each alias before choosing one: a blank optional primary
        // must not erase an explicit compatibility-alias filter.
        let normalizedSessionFilter = ["session_id", "sessionId"]
            .compactMap { jsonString(input[$0])?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let turnID = jsonString(input["turn_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String] = []
        if let requested = input["fields"], requested != .null {
            guard (turnID?.isEmpty == false || completedTurns != nil),
                  case .array(let values) = requested, !values.isEmpty, values.count <= 16,
                  values.allSatisfy({ value in
                      guard case .string(let key) = value else { return false }
                      return !key.isEmpty && key.count <= 80
                  }) else {
                throw AutonomyGateError.toolDenied(reason: "fields requires turn_id or completed_turns and 1–16 payload keys of at most 80 characters.")
            }
            fields = values.compactMap { jsonString($0) }
        }
        // Shared across all returned events, in serialized UTF-8 bytes.
        var remainingPayloadBytes = 8 * 1024

        let snapshot: TurnTraceRecentReader.Snapshot
        do {
            snapshot = try await TurnTraceRecentReader(dataRootOverride: dataRoot).read(history: completedTurns != nil || turnID?.isEmpty == false, since: since)
        } catch {
            return .object([
                "status": .string("failed"),
                "error": .string(String(describing: error)),
                "count": .int(0),
                "traces": .array([]),
                "source": .string("data/turn_traces/<current-day>.jsonl"),
            ])
        }

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

        var events = snapshot.events.sorted(by: { $0.ts > $1.ts })
        if let before = input["before"] {
            guard let index = events.firstIndex(where: { event in
                guard case .object(let row) = event.jsonRow else { return false }
                return row["ts"] == before
            }) else {
                return .object(["status": .string("no_match"), "effects": .string("none"),
                    "detail": .string("The continuation anchor is no longer retained. Read trace.recent again without before and offset.")])
            }
            events = Array(events[index...])
        }
        var completedIDs: [String] = []
        if let completedTurns {
            for event in events where ["turn.terminal", "turn.cancelled", "turn.failed"].contains(event.kind) {
                guard event.turnId != "unknown", !completedIDs.contains(event.turnId),
                      normalizedSessionFilter == nil || sessionTurnIDs.contains(event.turnId),
                      turnID?.isEmpty != false || event.turnId == turnID else { continue }
                completedIDs.append(event.turnId)
                if completedIDs.count == completedTurns { break }
            }
        }

        let anchor: JSONValue = { if let event = events.first, case .object(let row) = event.jsonRow { return row["ts"] ?? .null }; return .null }()
        func nonReadReceipt(_ event: TurnTraceEvent) -> Bool {
            guard event.kind == "tool.dispatch", case .object(let payload) = event.payload,
                  payload["phase"] == .string("end") else { return false }
            let receipt = if case .object(let receipt)? = payload["receipt"] { receipt } else { [String: JSONValue]() }
            let result = if case .object(let result)? = receipt["resultReceipt"] { result } else { [String: JSONValue]() }
            let action = jsonString(receipt["action"]) ?? jsonString(payload["name"]) ?? jsonString(payload["tool"]) ?? ""
            let arguments = jsonString(payload["args"]).flatMap { try? JSONValue.parse(Data($0.utf8)) }
            let args = if case .object(let args)? = arguments { args } else { [String: JSONValue]() }
            let policy = AppActionPolicy.action(input: ["action": .string(action), "args": args["args"] ?? .object(args)])
            return result["effects"] == .string("occurred")
                || (policy?.read == false && (arguments != nil || policy?.readWhen.isEmpty == true))
        }
        if receiptView {
            // Rank after anchoring in time so continuation offsets retain this ordering.
            let ranked = events.map { (event: $0, nonRead: nonReadReceipt($0)) }
            events = ranked.filter(\.nonRead).map(\.event) + ranked.filter { !$0.nonRead }.map(\.event)
        }
        var summaries: [JSONValue] = []
        var matched = 0, summaryBytes = 0, hasMore = false
        for event in events {
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
            let status = jsonString(payload["status"]) ?? ""
            if let kindFilter, !kind.lowercased().contains(kindFilter) {
                continue
            }
            if let statusFilter, status.lowercased() != statusFilter {
                continue
            }

            let title = jsonString(payload["name"])
                ?? jsonString(payload["tool"])
                ?? jsonString(payload["model"])
                ?? ""
            let action = if case .object(let receipt)? = payload["receipt"] { jsonString(receipt["action"]) } else { String?.none }
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
                guard nonReadReceipt(event) else { continue }
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
                summary.removeValue(forKey: "payload_keys")
                if effectsOnly || nonReadReceipt(event) {
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

        var next = input.filter { !$0.key.hasPrefix("__") }
        next["offset"] = .int(Int64(offset + summaries.count))
        next["before"] = anchor
        let candidateIDs = Array(events.filter { event in
            ["turn.terminal", "turn.cancelled", "turn.failed"].contains(event.kind)
                && (normalizedSessionFilter == nil || sessionTurnIDs.contains(event.turnId))
        }.reduce(into: [String]()) { ids, event in
            if event.turnId != "unknown", !ids.contains(event.turnId) { ids.append(event.turnId) }
        }.prefix(6))
        let missingTurn = turnID?.isEmpty == false && !events.contains { $0.turnId == turnID }
        let reads = summaries.compactMap { value -> (tool: String, input: [String: JSONValue], title: String)? in
            guard case .object(let row) = value, let id = jsonString(row["turn_id"]) else { return nil }
            return ("recent_trace_summary", ["turn_id": .string(id), "view": .string("receipts"), "session_id": row["session_id"] ?? .null], "Trace turn")
        } + (missingTurn ? candidateIDs.map { id in
            let session = events.first { $0.turnId == id && $0.sessionId != nil }?.sessionId
            return ("recent_trace_summary", ["turn_id": .string(id), "view": .string("receipts"), "session_id": session.map(JSONValue.string) ?? .null], "Trace turn")
        } : [])
        let refs: [JSONValue]
        let refNote: String
        do {
            refs = try AgentWorkspace.readReferences(reads, dataRoot: dataRoot)
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
        var response: [String: JSONValue] = [
            "status": .string(missingTurn ? "no_match" : "ok"),
            "detail": missingTurn ? .string("No retained turn matches turn_id. Use an exact candidate_turn_id; no matching trace evidence was read.") : .null,
            "candidate_turn_ids": missingTurn ? .array(candidateIDs.map(JSONValue.string)) : .array([]),
            "candidate_turn_refs": missingTurn ? .array(refs.suffix(candidateIDs.count).filter { $0 != .null }) : .array([]),
            "read_ref_note": .string(refNote),
            "count": .int(Int64(summaries.count)),
            "has_more": .bool(hasMore),
            "next_call": hasMore ? .object(["tool": .string("app"), "input": .object(["action": .string("trace.recent"), "args": .object(next)])]) : .null,
            "traces": .array(summaries),
            "source": .string("data/turn_traces/\(snapshot.sourceURL.lastPathComponent)"),
            "sources": .array(snapshot.sourceURLs.map { .string("data/turn_traces/\($0.lastPathComponent)") }),
            "scan_truncated": .bool(snapshot.truncated),
            "completed_turn_ids": .array(completedIDs.map(JSONValue.string)),
            "requested_completed_turns": completedTurns.map { .int(Int64($0)) } ?? .null,
            "shown_note": .string("shown is an action label, not evidence that the screen moved."),
            "scanned_count": .int(Int64(snapshot.events.count)),
            "session_id": normalizedSessionFilter.map(JSONValue.string) ?? .null,
            "scope": .string(normalizedSessionFilter == nil ? "all conversations" : "session"),
        ]
        if receiptView {
            response["order_note"] = .string("Non-read actions first, then reads; newest first within each group. Receipts include attempts and failures; inspect resultClass and resultReceipt for recorded effects.")
        }
        if effectsOnly {
            response["effects_note"] = .string("Successful non-read actions, excluding previews and explicit no-effect results. args/result are bounded redacted previews for target and effect; paired inner/app receipts can describe one action. No matches is not proof of no changes; check scan_truncated and has_more. Dispatch success does not prove the effect still persists.")
        }
        while try JSONValue.object(response).serializedData(pretty: false).count > 32 * 1024 {
            guard summaries.count > 1 else {
                return .object(["status": .string("failed"), "effects": .string("none"),
                    "detail": .string("Trace filters exceed the response budget. Shorten the filter values and retry.")])
            }
            summaries.removeLast()
            next["offset"] = .int(Int64(offset + summaries.count))
            response["count"] = .int(Int64(summaries.count))
            response["traces"] = .array(summaries)
            response["has_more"] = .bool(true)
            response["next_call"] = .object(["tool": .string("app"), "input": .object(["action": .string("trace.recent"), "args": .object(next)])])
        }
        return .object(response)
    }

    private func isSafeSessionPathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 160 else { return false }
        if value == "." || value == ".." { return false }
        if value.contains("/") || value.contains("\\") || value.contains("\0") { return false }
        return !value.split(separator: ":", omittingEmptySubsequences: false).contains("..")
    }
}
