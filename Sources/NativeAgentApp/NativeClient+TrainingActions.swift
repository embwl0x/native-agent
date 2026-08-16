import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser


extension NativeClient {
    func getTrainingRuns() async throws -> [TrainingRunSummary] {
        // wave 31 W09 — PORTED-DORMANT (gate: .selfImprovement, default OFF).
        return try await swiftGetTrainingRuns()
    }

    // wave 37 W10 (§6.159): GET /v1/training/runs/<id> detail sibling. Returns
    // the daemon's FULL graded-run dict (NOT the 5-field list projection) as a
    // raw `[String: Any]`, matching the `postDictionary`-style raw return used by
    // the other no-typed-model training routes (approve/reject). There is no
    // app-side full-run model and no UI caller today (audit: zero callers across
    // Mac/iOS/scripts/tests), so a raw dict keeps the seam in place for a future
    // detail view without inventing a speculative Codable shape. A missing run
    // throws the same 404-style NSError shape.
    func getTrainingRun(id: String) async throws -> [String: Any] {
        return try await swiftGetTrainingRun(id: id)
    }

    func getTrainingProposals() async throws -> [TrainingProposalSummary] {
        // wave 31 W09 — PORTED-DORMANT (gate: .selfImprovement, default OFF).
        return try await swiftGetTrainingProposals()
    }

    func runDrills(surface: String) async throws -> [String: Any] {
        let runID = String(UUID().uuidString.lowercased().prefix(8))
        let started = Date()
        let suite = "swift_native_runtime"
        let checks: [JSONValue] = [
            await swiftDrillCheck(id: "D-01", title: "Native health snapshot") {
                try Self.codableJSON(try await self.getHealth())
            },
            await swiftDrillCheck(id: "D-02", title: "Persona source files readable") {
                try Self.personaDrillOutput()
            },
            await swiftDrillCheck(id: "D-03", title: "MemoryV2 recall path") {
                let response = try await SwiftNativeMemoryV2.shared.recall(
                    MemoryV2RecallRequest(text: "NativeAgent assistant user", topK: 3, persona: nil)
                )
                return .object([
                    "total": .int(Int64(response.total)),
                    "hits": try Self.codableJSON(response.hits),
                ])
            },
            await swiftDrillCheck(id: "D-04", title: "Tool registry readable") {
                let tools = try await self.getTools()
                return .object([
                    "toolCount": .int(Int64(tools.count)),
                    "active": .int(Int64(tools.filter { ($0.status ?? "").lowercased() == "active" }.count)),
                ])
            },
            await swiftDrillCheck(id: "D-05", title: "Connector action registry readable") {
                let actions = try await self.getConnectorActions()
                return .object([
                    "status": .string(actions.status),
                    "actionCount": .int(Int64(actions.actions.count)),
                    "receiptCount": .int(Int64(actions.receiptCount ?? 0)),
                ])
            },
        ]
        let finished = Date()
        let passedCount = checks.filter { check in
            guard case .object(let obj) = check, case .bool(true)? = obj["passed"] else { return false }
            return true
        }.count
        let failedIDs = checks.compactMap { check -> String? in
            guard case .object(let obj) = check else { return nil }
            guard case .bool(true)? = obj["passed"] else {
                if case .string(let id)? = obj["prompt_id"] { return id }
                return nil
            }
            return nil
        }
        let startedISO = SwiftNativeManifestSigner.isoTimestamp(started)
        let finishedISO = SwiftNativeManifestSigner.isoTimestamp(finished)
        let run: JSONValue = .object([
            "run_id": .string(runID),
            "suite_name": .string(suite),
            "surface": .string(surface),
            "started_at": .string(startedISO),
            "finished_at": .string(finishedISO),
            "responses": .array(checks),
        ])
        let graded: JSONValue = .object([
            "run_id": .string(runID),
            "suite_name": .string(suite),
            "graded_at": .string(finishedISO),
            "total_score": .int(Int64(passedCount)),
            "max_score": .int(Int64(checks.count)),
            "graded_prompts": .array(checks),
        ])
        let drift: JSONValue = .object([
            "run_id": .string(runID),
            "baseline_path": .null,
            "generated_at": .string(finishedISO),
            "regression_categories": .array([]),
            "zero_score_prompts": .array(failedIDs.map { .string($0) }),
            "recurring_anti_behaviors": .array([]),
            "must_fix_auto_caps": .array([]),
            "summary": .string(failedIDs.isEmpty ? "Swift drill checks passed." : "Failed drill checks: \(failedIDs.joined(separator: ", "))"),
        ])
        try await Self.writeDrillRunFiles(runID: runID, run: run, graded: graded, drift: drift)
        return try Self.foundationDictionary(.object([
            "ok": .bool(failedIDs.isEmpty),
            "status": .string(failedIDs.isEmpty ? "passed" : "failed"),
            "run_id": .string(runID),
            "suite_name": .string(suite),
            "surface": .string(surface),
            "ran": .int(Int64(checks.count)),
            "passed": .int(Int64(passedCount)),
            "failed": .int(Int64(failedIDs.count)),
            "failedPromptIds": .array(failedIDs.map { .string($0) }),
            "createdAt": .string(finishedISO),
        ]))
    }

    func swiftDrillCheck(
        id: String,
        title: String,
        _ body: () async throws -> JSONValue
    ) async -> JSONValue {
        let started = Date()
        do {
            let output = try await body()
            return .object([
                "prompt_id": .string(id),
                "category": .string("swift_native_runtime"),
                "prompt_text": .string(title),
                "response_text": .string("passed"),
                "surface": .string("swift"),
                "elapsed_ms": .int(Int64(Date().timeIntervalSince(started) * 1000)),
                "passed": .bool(true),
                "score": .int(1),
                "max_score": .int(1),
                "output": output,
                "error": .null,
            ])
        } catch {
            return .object([
                "prompt_id": .string(id),
                "category": .string("swift_native_runtime"),
                "prompt_text": .string(title),
                "response_text": .string("failed"),
                "surface": .string("swift"),
                "elapsed_ms": .int(Int64(Date().timeIntervalSince(started) * 1000)),
                "passed": .bool(false),
                "score": .int(0),
                "max_score": .int(1),
                "output": .null,
                "error": .string(error.localizedDescription),
            ])
        }
    }

    static func personaDrillOutput() throws -> JSONValue {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let repoRoot = PersistenceCore.resolveSandboxRepoRoot(dataRoot: dataRoot)
            ?? dataRoot.deletingLastPathComponent()
        let personaRoot = repoRoot.appendingPathComponent("persona", isDirectory: true)
        let names = ["SOUL.md", "VOICE.md", "USER.md", "GROWTH.md"]
        var files: [JSONValue] = []
        for name in names {
            let path = personaRoot.appendingPathComponent(name)
            let data = try Data(contentsOf: path)
            files.append(.object([
                "name": .string(name),
                "path": .string(path.path),
                "bytes": .int(Int64(data.count)),
            ]))
        }
        return .object([
            "personaRoot": .string(personaRoot.path),
            "files": .array(files),
        ])
    }

    static func writeDrillRunFiles(
        runID: String,
        run: JSONValue,
        graded: JSONValue,
        drift: JSONValue
    ) async throws {
        let dir = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("training_journal", isDirectory: true)
            .appendingPathComponent("drill_runs", isDirectory: true)
        let persistence = SwiftNativePersistenceCore()
        let runPath = dir.appendingPathComponent("\(runID).json")
        let gradedPath = dir.appendingPathComponent("\(runID)-graded.json")
        let driftPath = dir.appendingPathComponent("\(runID)-drift.json")
        try await persistence.withFileLock(runPath) {
            try await persistence.writeJSON(run, to: runPath)
        }
        try await persistence.withFileLock(gradedPath) {
            try await persistence.writeJSON(graded, to: gradedPath)
        }
        try await persistence.withFileLock(driftPath) {
            try await persistence.writeJSON(drift, to: driftPath)
        }
    }

    func approveTrainingProposal(id: String) async throws -> [String: Any] {
        return try await swiftApproveTrainingProposal(id: id)
    }

    func rejectTrainingProposal(id: String, reason: String) async throws -> [String: Any] {
        // wave 33 W10 — PORTED-DORMANT (gate: .selfImprovement, default OFF).
        return try await swiftRejectTrainingProposal(id: id, reason: reason)
    }

    func getPromotionCandidates() async throws -> [PromotionCandidateSummary] {
        // wave 31 W09 — PORTED-DORMANT (gate: .selfImprovement, default OFF).
        return try await swiftGetPromotionCandidates()
    }

    func getPromotionPending() async throws -> [PromotionCandidateSummary] {
        // wave 31 W09 — PORTED-DORMANT (gate: .selfImprovement, default OFF).
        return try await swiftGetPromotionPending()
    }

    // SUBSYSTEM #17: retired Swift wrapper runPromotionSelfTest + daemon /v1/promotion/self_test route — promotion.py::PromotionEngine.self_test() preserved.

    func approvePromotionPending(id: String) async throws -> [String: Any] {
        let raw = try await NativeClient._trainingPromotionActor().approvePromotionStageLocal(candidateId: id)
        return try NativeClient._jsonValueToDictionary(raw)
    }

    func rejectPromotionPending(id: String, reason: String) async throws -> [String: Any] {
        let raw = try await NativeClient._trainingPromotionActor().rejectPromotionStageLocal(candidateId: id, reason: reason)
        return try NativeClient._jsonValueToDictionary(raw)
    }
}
