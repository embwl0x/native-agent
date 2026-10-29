import Foundation
import NativeAgentShared
import Darwin
import Network
import ChatTurnRuntime
import ChatTurnContracts
import AgentConversations
import ChatToolParsing
import Cognition
import ContextFlow
import PersonaEngine
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore
import Privacy
import MacControl
// Blueprint: | `ClaudeBridgeDebug.swift` | Authenticated organism debug routes using the listener's existing request claim and response latch |

extension ClaudeBridgeRuntime {
    func handleOrganismDebug(conn: NWConnection, body: Data, path: String) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeJSON(conn, status: 400, obj: ["error": "invalid_json"])
            return
        }
        let action = (json["action"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let rawScenario = (json["scenario"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldClear = action == "clear" || rawScenario.lowercased() == "clear"
        // Clamped here: Int(ttlSeconds) below traps on "inf" or 1e300.
        let ttlSeconds = Self.timeInterval(json["ttlSeconds"]).flatMap { $0.isFinite ? min(600, max(5, $0)) : nil } ?? 120

        // Same WorkLatch + asyncAfter bound as handleMessage/handleTool.
        let workLatch = WorkLatch()
        let workTask = startRequest(conn: conn, latch: workLatch, priority: .utility) { [weak self] _ in
            guard let self else { return }
            // Every response path below goes through respond(...), so the work Task and the deadline timer can never both write the response.
            func respond(_ status: Int, _ obj: [String: Any]) {
                guard workLatch.claim() else { return }
                self.writeJSON(conn, status: status, obj: obj)
            }
            let runtime = host.cognition
            if action == "reset" || action == "reset_continuity" {
                let outcome = await runtime.resetOrganismContinuityChecked()
                guard !Task.isCancelled else { return }
                guard outcome.applied else {
                    respond(409, ["status": outcome.status.rawValue, "error": outcome.error ?? outcome.status.rawValue,
                                  "organism": ClaudeBridgeReadout.organismSnapshotJSON(outcome.snapshot)])
                    return
                }
                self.publishOrganismDebugEvent(status: "reset")
                respond(200, [
                    "status": "reset",
                    "organism": ClaudeBridgeReadout.organismSnapshotJSON(outcome.snapshot),
                    "debug": NSNull(),
                ])
                return
            }
            if action == "settle" || action == "settle_continuity" {
                let outcome = await runtime.settleOrganismContinuityChecked()
                guard !Task.isCancelled else { return }
                guard outcome.applied else {
                    respond(409, ["status": outcome.status.rawValue, "error": outcome.error ?? outcome.status.rawValue,
                                  "organism": ClaudeBridgeReadout.organismSnapshotJSON(outcome.snapshot)])
                    return
                }
                self.publishOrganismDebugEvent(status: "settled")
                respond(200, [
                    "status": "settled",
                    "organism": ClaudeBridgeReadout.organismSnapshotJSON(outcome.snapshot),
                    "debug": NSNull(),
                ])
                return
            }
            if shouldClear {
                let snapshot = await runtime.clearOrganismDebugBodyOverride()
                guard !Task.isCancelled else { return }
                self.publishOrganismDebugEvent(status: "cleared")
                respond(200, [
                    "status": "cleared",
                    "organism": ClaudeBridgeReadout.organismSnapshotJSON(snapshot),
                    "debug": NSNull(),
                ])
                return
            }

            guard !rawScenario.isEmpty else {
                respond(400, [
                    "error": "missing_scenario",
                    "allowedScenarios": OrganismDebugBodyScenario.allCases.map(\.rawValue),
                ])
                return
            }

            do {
                let snapshot = try await runtime.setOrganismDebugBodyOverride(
                    scenario: rawScenario,
                    ttlSeconds: ttlSeconds
                )
                guard !Task.isCancelled else { return }
                let debug = await runtime.organismDebugBodyOverrideStatus()
                guard !Task.isCancelled else { return }
                self.publishOrganismDebugEvent(
                    status: "active",
                    scenario: rawScenario,
                    ttlSeconds: Int(ttlSeconds)
                )
                respond(200, [
                    "status": "active",
                    "organism": ClaudeBridgeReadout.organismSnapshotJSON(snapshot),
                    "debug": Self.organismDebugStatusJSON(debug),
                ])
            } catch {
                respond(400, [
                    "error": "invalid_scenario",
                    "detail": String(describing: error),
                    "allowedScenarios": OrganismDebugBodyScenario.allCases.map(\.rawValue),
                ])
            }
        }
        guard let workTask else { writeJSON(conn, status: 503, obj: ["error": "server_stopping_or_busy"]); return }
        workLatch.arm(afterSeconds: Self.readWorkDeadlineSeconds) { [weak self] in
            guard let self, workLatch.claim() else { return }
            workTask.cancel()
            self.writeJSON(conn, status: 504, obj: [
                "error": "work_timeout",
                "path": path,
                "seconds": Self.readWorkDeadlineSeconds,
                "outcome": "unknown",
            ])
        }
    }

    private static func organismDebugStatusJSON(_ status: OrganismDebugBodyOverrideStatus?) -> Any {
        guard let status else { return NSNull() }
        return [
            "scenario": status.scenario.rawValue,
            "expiresAt": NativeTimestampFormat.plainZulu(status.expiresAt),
        ]
    }


    private static func timeInterval(_ value: Any?) -> TimeInterval? {
        if let interval = value as? TimeInterval { return interval }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return TimeInterval(string) }
        return nil
    }
}
