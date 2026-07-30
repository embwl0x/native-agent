import Foundation
import NativeAgentCore
import PersistenceCore
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
        return result.toJSON()
    }

    func impl_scratchpad_read(input: [String: JSONValue]) async throws -> JSONValue {
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
        let raw = await SwiftNativePersistenceCore().readJSON(path, defaultValue: .object([:]))
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
        let requestedLimit = optionalInt(input, "limit") ?? 10
        let limit = max(1, min(requestedLimit, 50))
        let kindFilter = jsonString(input["kind"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        let statusFilter = jsonString(input["status"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        let sessionFilter = jsonString(input["session_id"])
            ?? jsonString(input["sessionId"])
        let normalizedSessionFilter = sessionFilter
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let snapshot: TurnTraceRecentReader.Snapshot
        do {
            snapshot = try await TurnTraceRecentReader(dataRootOverride: dataRoot).read()
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

        var summaries: [JSONValue] = []
        for event in snapshot.events.sorted(by: { $0.ts > $1.ts }) {
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
            let payloadKeys = Array(payload.keys.sorted().prefix(30))
            let row = event.jsonRow
            guard case .object(let object) = row else { continue }
            summaries.append(.object([
                "id": .null,
                "turn_id": .string(event.turnId),
                "kind": .string(kind),
                "title": .string(String(title.prefix(160))),
                "status": .string(status),
                "createdAt": object["ts"] ?? .null,
                "session_id": event.sessionId.map(JSONValue.string) ?? .null,
                "surface": event.surface.map(JSONValue.string) ?? .null,
                "payload_keys": .array(payloadKeys.map { .string($0) }),
                "receipt": .null,
            ]))
            if summaries.count >= limit { break }
        }

        return .object([
            "status": .string("ok"),
            "count": .int(Int64(summaries.count)),
            "traces": .array(summaries),
            "source": .string("data/turn_traces/\(snapshot.sourceURL.lastPathComponent)"),
            "scanned_count": .int(Int64(snapshot.events.count)),
            "session_id": normalizedSessionFilter.map(JSONValue.string) ?? .null,
        ])
    }

    private func isSafeSessionPathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 160 else { return false }
        if value == "." || value == ".." { return false }
        if value.contains("/") || value.contains("\\") || value.contains("\0") { return false }
        return !value.split(separator: ":", omittingEmptySubsequences: false).contains("..")
    }
}
