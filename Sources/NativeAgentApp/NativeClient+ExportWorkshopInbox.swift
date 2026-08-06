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
import CapabilityFoundry

private struct SessionProviderUsageReceipt: Decodable {
    let model: String
    let lastRequestInputTokens: Int
    let previousTurnInputTokens: Int?
    let turnInputDeltaTokens: Int?
}

extension NativeClient {
    func createProductionExport() async throws -> ProductionExport {
        let root = PersistenceCore.defaultDataRoot()
        let now = Self.nativeArtifactTimestamp()
        let id = UUID().uuidString.lowercased()
        let exportRoot = root
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        let stageDir = exportRoot.appendingPathComponent(id, isDirectory: true)
        let archiveURL = exportRoot.appendingPathComponent("\(id)-nativeagent-export.tar.gz")

        let fm = FileManager.default
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: stageDir)
        try? fm.removeItem(at: archiveURL)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        try Self.writeCodableJSON(try await getProductionHardening(), to: stageDir.appendingPathComponent("production_hardening.json"))
        try Self.writeCodableJSON(try await getPrivacyMap(), to: stageDir.appendingPathComponent("privacy_map.json"))

        let dataDir = stageDir.appendingPathComponent("data", isDirectory: true)
        let copied = try Self.copySelectedDataPaths(
            root: root,
            destinationRoot: dataDir,
            relativePaths: Self.productionExportRelativePaths
        )
        var scope = Self.scopeNames(for: copied)
        if !scope.contains("diagnostics") { scope.insert("diagnostics", at: 0) }

        let manifest = Self.artifactManifest(
            id: id,
            kind: "export",
            createdAt: now,
            scope: scope,
            copied: copied,
            redactions: Self.productionRedactions
        )
        try Self.writeJSONValue(manifest, to: stageDir.appendingPathComponent("manifest.json"))

        try await Self.createTarGz(sourceDirectory: stageDir, archiveURL: archiveURL)
        let checksum = try await Self.sha256Hex(ofFile: archiveURL, currentDirectory: exportRoot)
        let sizeBytes = try Self.fileSizeBytes(archiveURL)
        let record = ProductionExport(
            id: id,
            kind: "export",
            path: archiveURL.path,
            scope: scope,
            checksum: checksum,
            sizeBytes: sizeBytes,
            createdAt: now
        )
        try await Self.appendProductionExport(record, registryRoot: exportRoot)
        return record
    }

    func createSupportBundle() async throws -> ProductionExport {
        let root = PersistenceCore.defaultDataRoot()
        let now = Self.nativeArtifactTimestamp()
        let id = UUID().uuidString.lowercased()
        let supportRoot = root
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("support", isDirectory: true)
        let exportRoot = root
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        let stageDir = supportRoot.appendingPathComponent(id, isDirectory: true)
        let archiveURL = supportRoot.appendingPathComponent("\(id)-nativeagent-support.tar.gz")

        let fm = FileManager.default
        try fm.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: stageDir)
        try? fm.removeItem(at: archiveURL)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        try Self.writeCodableJSON(try await getSupportDiagnostics(), to: stageDir.appendingPathComponent("support_diagnostics.json"))
        try Self.writeCodableJSON(try await getHealth(), to: stageDir.appendingPathComponent("health.json"))

        let dataDir = stageDir.appendingPathComponent("data", isDirectory: true)
        let copied = try Self.copySelectedDataPaths(
            root: root,
            destinationRoot: dataDir,
            relativePaths: Self.supportBundleRelativePaths
        )
        var scope = Self.scopeNames(for: copied)
        if !scope.contains("diagnostics") { scope.insert("diagnostics", at: 0) }

        let manifest = Self.artifactManifest(
            id: id,
            kind: "support",
            createdAt: now,
            scope: scope,
            copied: copied,
            redactions: Self.supportRedactions
        )
        try Self.writeJSONValue(manifest, to: stageDir.appendingPathComponent("manifest.json"))

        try await Self.createTarGz(sourceDirectory: stageDir, archiveURL: archiveURL)
        let checksum = try await Self.sha256Hex(ofFile: archiveURL, currentDirectory: supportRoot)
        let sizeBytes = try Self.fileSizeBytes(archiveURL)
        let record = ProductionExport(
            id: id,
            kind: "support",
            path: archiveURL.path,
            scope: scope,
            checksum: checksum,
            sizeBytes: sizeBytes,
            createdAt: now
        )
        try await Self.appendProductionExport(record, registryRoot: exportRoot)
        return record
    }

    // WAVE 40 W07 (§6.220): executions CRUD-admin WRITE seam behind
    // `.missionsWrites` (default OFF). The SwiftNative write impls
    // (SwiftNativeWorkshopRunner.submit / updateWorkshopExecution / cancel) and their
    // cross-process flock on workshop/executions/<id>/{mission.json,timeline.jsonl}
    // were built in waves 33/34/35 W07; this flips the CONSUMER seam so the Mac
    // UI's create/update/cancel land natively without the daemon.
    func createWorkshopTask(title: String, objective: String) async throws -> WorkshopExecutionRecord {
        // Native submit mirrors the daemon's `/v1/missions` queue-bridge:
        // runner.submit(title, objective, "manual", "none") — same defaults
        // as the Python handler. submit()
        // validates a non-empty objective (throws WorkshopExecutionError.invalidRequest
        // "missing_objective", parity with the daemon's 400). NOTHING
        // auto-starts in submit itself; the execution lands in `queued` and
        // WorkshopExecutorLoop (executor port, 2026-06-10 — registered via
        // BackgroundLoopsAssembly, gated on enableAutonomy + missionPolicy)
        // claims and runs it on its next drain pass.
        let runner = makeWorkshopExecutionRunner()
        let spec = WorkshopExecution.WorkshopExecutionSpec(
            title: title,
            objective: objective,
            triggerSource: "manual",
            trustRequired: "none"
        )
        let result = try await WorkshopExecution.WorkshopDirectedTaskSubmitter(
            dataRoot: PersistenceCore.defaultDataRoot(),
            runner: runner
        ).submit(spec: spec)
        // The daemon's create response is a SUMMARY ({id,mission_id,status,
        // title,plan_steps}); the FULL record is a strict superset that
        // decodes into the (snake_case-tolerant) app WorkshopExecutionRecord just the
        // same. Serialize the asdict-faithful record and decode.
        let data = try result.execution.toJSON().serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(WorkshopExecutionRecord.self, from: data)
    }

    func getTriggers() async throws -> [TriggerRecord] {
        // SUBSYSTEM #17 cluster C3 (2026-05-31): SwiftNative TriggerScheduler
        // covers list/enable/disable/configure for both schedules behind the
        // .triggerScheduler flag. fire_now for supported inbox/execution cases is
        // native; unsupported cases fail closed.
        return try await swiftListWorkshopTriggers()
    }

    // PATCH-2026-05-07: proactive-inbox-1 Inbox action helper (avoids Sendable Any issue at call site)
    func inboxAction(_ id: String, action: String) async throws {
        // "reply" needs text input the act handler doesn't have. If a caller
        // hits this entry point with `reply`, surface the gap honestly
        // instead of silently mapping to `act`. (gpt-5.5 review HIGH: act
        // could otherwise recurse into reply → infinite loop.)
        let normalizedAction = action == "deny" ? "reject" : action
        if normalizedAction == "reply" {
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -410,
                userInfo: [NSLocalizedDescriptionKey: "Reply requires text input; use inboxReply(id:text:) instead of inboxAction(id:\"reply\")."]
            )
        }
        let nativeActions: Set<String> = ["read", "archive", "dismiss", "act", "approve", "reject", "open_approvals", "repair"]
        let endpointAction = nativeActions.contains(normalizedAction) ? normalizedAction : "act"

        // Wave 32 W16 (2026-06-01): consume the SwiftNative NotificationInbox for
        // status-write actions — read / archive / dismiss. archive/dismiss fire
        // the proactive-outcome ledger before the index.json overlay write under
        // the inbox file lock. Other actions are handled below or fail closed.
        if endpointAction == "read" || endpointAction == "archive" || endpointAction == "dismiss" {
            if await Self.updateVisibleNotificationInboxStatus(id: id, action: endpointAction) {
                return
            }
            // A5.2 (2026-07-24): the legacy silo fallback (makeNotificationInbox
            // → items.jsonl/index.json) is GONE — the silo is retired and
            // frozen, so a fallback "success" there updated dead storage while
            // the visible card stayed put, masking the live-store failure. The
            // live store is the only store; a failed write surfaces as the
            // retryable error below (same resurrect-audit rationale, 2026-06-09).
            NSLog("[NativeClient] inboxAction(\(endpointAction)) id=\(id): live inbox status write declined")
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -423,
                userInfo: [NSLocalizedDescriptionKey:
                    "Inbox \(endpointAction) for \(id) didn't persist (transient lock/IO failure or stale row) — retry."]
            )
        }
        // F6 (eval E06 fix-2): wire approve/reject through the
        // SwiftNativeApprovalInbox actor so the inbox row actually moves out
        // of pending.
        if endpointAction == "approve" || endpointAction == "reject" {
            // Route through resolveApproval so approval-action executors (e.g.
            // self_improvement.apply) actually FIRE. Resolving the inbox actor
            // directly here would mark the record terminal WITHOUT executing,
            // leaving an approved-but-unapplied dead-end.
            do {
                _ = try await resolveApproval(id: id, decision: endpointAction)
            } catch ApprovalInboxError.alreadyResolved(let resolvedID, let status) {
                // Idempotent re-tap: the record is already terminal. Treat as
                // success so a double-tap doesn't surface a spurious error.
                NSLog("[NativeClient] inboxAction(\(endpointAction)) id=\(resolvedID): already resolved (\(status)); treating as success")
            } catch {
                // Surface real failures to the caller instead of reporting
                // unconditional success over a swallowed error.
                NSLog("[NativeClient] inboxAction(\(endpointAction)) id=\(id): \(error)")
                throw error
            }
            return
        }
        if endpointAction == "open_approvals" {
            await Self.openApprovalsFromInboxAction(id: id)
            return
        }
        if endpointAction == "repair" {
            let message = try await BackgroundLoopsAssembly.repairHeartbeatInboxItem(id: id)
            _ = await Self.updateVisibleNotificationInboxStatus(id: id, action: "archive")
            NSLog("[NativeClient] inboxAction(repair) id=\(id): \(message)")
            return
        }
        // DAEMON-KILL (2026-06-06) + gpt-5.5 review-2 BLOCKING:
        // The earlier attempt looked up the inbox item, picked the first
        // non-"view" action from its `actions` array, and recursed into
        // inboxAction with that id. But every TriggerScheduler item ships
        // with the standard fan-out `[view, act, archive, dismiss]` — so the
        // "first non-view" candidate WAS literally "act", causing infinite
        // recursion (TriggerScheduler.swift:750-755).
        //
        // The standard fan-out is a presentation set, not a fallback action
        // list — archive/dismiss are housekeeping moves, NOT what the user
        // meant by "Act." A per-kind primary-action resolver (kind →
        // handler) is not ported yet, so the honest move is to fail closed
        // with -410 and let the UI surface the gap. Don't auto-archive.
        if endpointAction == "act" {
            let items = try await getInboxItems(unreadOnly: false)
            guard let item = items.first(where: { $0.id == id }) else {
                throw NSError(
                    domain: "NativeAgentSwiftOnly",
                    code: -410,
                    userInfo: [NSLocalizedDescriptionKey: "Inbox item \(id) not found"]
                )
            }
            if Self.primaryInboxActionID(for: item) == "open_approvals" {
                await Self.openApprovalsFromInboxAction(id: id)
                return
            }
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -410,
                userInfo: [NSLocalizedDescriptionKey:
                    "Inbox item \(id): primary-action resolver not wired in Swift port yet. "
                    + "Use the explicit archive/dismiss/approve/reject actions, "
                    + "or open the item for full context."]
            )
        }
        // Unknown action — fail honestly rather than silently no-op.
        throw NSError(
            domain: "NativeAgentSwiftOnly",
            code: -410,
            userInfo: [NSLocalizedDescriptionKey: "Inbox action \(endpointAction) has no native resolver"]
        )
    }

    static func primaryInboxActionID(for item: InboxItemRecord) -> String? {
        item.fallbackPrimaryAction?.id
    }

    static func openApprovalsFromInboxAction(id: String) async {
        _ = await updateVisibleNotificationInboxStatus(id: id, action: "read")
        await MainActor.run {
            NotificationCenter.default.post(name: .openApprovalsRequest, object: nil)
        }
    }

    // LIVE-ESTIMATE (2026-06-07):
    // Previously read <dataRoot>/chat/sessions/<id>/context.json and zeroed
    // everything when that file was missing. That made the chat composer's
    // context pill show "0 / 0" on Swift-only sessions.
    //
    // New behavior: transcript growth is estimated live from message history,
    // while total request occupancy comes from the latest provider usage
    // receipt written off the LLM return path. This keeps the meter honest:
    // persona, Fluid Context, cognition, and tool schemas no longer disappear
    // from the displayed count. If no matching receipt exists yet, the UI
    // explicitly falls back to a transcript-only estimate.
    func getSessionContext(sessionId: String, model: String? = nil) async throws -> SessionContextStatus {
        try await getSessionContext(
            sessionId: sessionId,
            model: model,
            dataRoot: PersistenceCore.defaultDataRoot(),
            configuredThresholdTokens: nil
        )
    }

    func getSessionContext(
        sessionId: String,
        model: String? = nil,
        dataRoot: URL,
        configuredThresholdTokens: Int?
    ) async throws -> SessionContextStatus {
        // gpt-5.5 review #1 (BLOCKING): The legacy context.json on disk could
        // be stale, and the Swift compactSession() writer below still recorded
        // `auto_compact_threshold: 75` (intended as a percent in the old
        // schema) and a fixed `budget: 200_000`. Honoring that file produced
        // permanently stale data — wrong budget, percent-as-token-threshold,
        // and a model field that read "swift-native-compactor". Live values
        // are now the only source of truth.
        let root = dataRoot

        // Live estimate from messages on disk.
        let messagesPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        var totalChars = 0
        var messageCount = 0
        if let data = try? Data(contentsOf: messagesPath),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                // gpt-5.5 review #5 (NIT): only count rows that actually
                // decode. A partially-flushed row at the tail was previously
                // inflating messageCount even though its tokens were skipped.
                if let rowData = trimmed.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: rowData) as? [String: Any] {
                    messageCount += 1
                    if let content = obj["content"] as? String {
                        totalChars += content.count
                    } else if let content = obj["content"] {
                        // Tool-result rows store content as a JSON array;
                        // re-serialize to charge for the bytes.
                        if let blob = try? JSONSerialization.data(withJSONObject: content) {
                            totalChars += blob.count
                        }
                    }
                }
            }
        }

        let resolvedModel = (model?.isEmpty == false ? model! : "")
        // gpt-5.5 review #3 (NEEDS_FIX): chars/4 systematically
        // underestimates Anthropic tokenization by ~10–15%. Use ~3.5 for
        // claude-* and 4 for everyone else so the displayed percent is closer
        // to what the provider actually charges. Rounded conservatively
        // (higher token count → bar fills faster → user compacts sooner).
        let divisor: Double = resolvedModel.lowercased().contains("claude") ? 3.5 : 4.0
        let transcriptTokens = max(0, Int((Double(totalChars) / divisor).rounded()))

        let budget = ProviderRouting.contextLength(forModel: resolvedModel)

        let providerUsagePath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("session_state", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("provider_usage.json")
        let providerReceipt: SessionProviderUsageReceipt? = {
            guard let data = try? Data(contentsOf: providerUsagePath),
                  let receipt = try? JSONDecoder().decode(SessionProviderUsageReceipt.self, from: data),
                  receipt.lastRequestInputTokens >= 0,
                  receipt.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return nil
            }
            return receipt
        }()
        // A matching provider receipt is the authority even when selective
        // history or compaction makes the real request smaller than the full
        // transcript stored on disk.
        let usedTokens = providerReceipt?.lastRequestInputTokens ?? transcriptTokens
        let promptTokens = max(0, usedTokens - transcriptTokens)

        // The user's preference is the ceiling. The shared compaction policy
        // clamps it to 40% of the selected model's window so a 200k global
        // preference cannot fire too late on a 128k model.
        let configuredThreshold: Int = {
            if let configuredThresholdTokens, configuredThresholdTokens > 0 {
                return configuredThresholdTokens
            }
            let storedThreshold = UserDefaults.standard.integer(
                forKey: "nativeagent.compactionThresholdTokens"
            )
            return storedThreshold > 0
                ? storedThreshold
                : ChatSessionAutocompactionConfig.defaultThresholdTokens
        }()
        let threshold = ChatSessionAutocompactionConfig(
            thresholdTokens: configuredThreshold
        ).effectiveThresholdTokens(forModel: resolvedModel)

        let percent: Double = budget > 0 ? (Double(usedTokens) / Double(budget)) * 100.0 : 0.0
        // gpt-5.5 review #2 (NEEDS_FIX): dropping the `messageCount > 20`
        // gate. compactSession(force: true) bypasses its own >20 guard, and
        // short-but-huge transcripts (heavy tool output across <20 turns)
        // were previously denied the button despite being over budget.
        let compactable = transcriptTokens >= threshold

        return SessionContextStatus(
            session_id: sessionId,
            used_tokens: usedTokens,
            transcript_tokens: transcriptTokens,
            prompt_tokens: promptTokens,
            previous_turn_tokens: providerReceipt?.previousTurnInputTokens,
            turn_delta_tokens: providerReceipt?.turnInputDeltaTokens,
            budget: budget,
            percent: percent,
            message_count: messageCount,
            compactable: compactable,
            auto_compact_threshold: threshold,
            model: resolvedModel,
            context_loaded: providerReceipt != nil,
            context_mode: providerReceipt == nil ? "transcript_estimate" : "provider_receipt",
            context_fingerprint: nil,
            context_prompt_chars: totalChars
        )
    }

    func compactSession(sessionId: String, force: Bool = false) async throws -> CompactionResult {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CompactionResult(
                compacted: false,
                session_id: sessionId,
                messages_before: 0,
                messages_after: 0,
                summary_chars: 0,
                messages_replaced: 0,
                reason: "empty session id",
                percent: nil,
                error: nil
            )
        }
        let root = PersistenceCore.defaultDataRoot()
        let messagesPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(trimmed).jsonl")
        let sessionDir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(trimmed, isDirectory: true)
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(messagesPath) {
            // U5 W-A item 1 (:11481): a swallowed read rendered ANY read
            // failure as "nothing to compact". Honesty-only fix (plan-
            // verified NOT data-loss: empty read → replaceCount == 0 →
            // early return, no write, backup taken) — propagate I/O errors
            // and throw on bytes-but-no-rows instead of claiming there is
            // nothing to compact. Missing file (fresh session) still reads
            // as [] → honest "not enough messages".
            let rows = try await Self.readJSONLHonest(
                persistence, path: messagesPath, context: "compactSession")
            let before = rows.count
            // Match the user's old-system continuity preference: keep the last
            // 20 rows hot and uncompacted so short confirmations like
            // "yeah do that" still have the assistant turn they refer to.
            let keepCount = 20
            guard before > keepCount || force else {
                return CompactionResult(
                    compacted: false,
                    session_id: trimmed,
                    messages_before: before,
                    messages_after: before,
                    summary_chars: 0,
                    messages_replaced: 0,
                    reason: "not enough messages to compact",
                    percent: nil,
                    error: nil
                )
            }
            let replaceCount = max(0, before - keepCount)
            guard replaceCount > 0 else {
                return CompactionResult(
                    compacted: false,
                    session_id: trimmed,
                    messages_before: before,
                    messages_after: before,
                    summary_chars: 0,
                    messages_replaced: 0,
                    reason: "nothing to compact",
                    percent: nil,
                    error: nil
                )
            }
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: messagesPath.path) {
                let stamp = Self.fileSafeTimestamp()
                let backup = sessionDir.appendingPathComponent("messages.compact.\(stamp).jsonl")
                try? FileManager.default.copyItem(at: messagesPath, to: backup)
            }
            let replaced = Array(rows.prefix(replaceCount))
            let kept = Array(rows.suffix(keepCount))
            let summary = Self.compactionSummary(for: replaced)
            let nowISO = ISO8601DateFormatter().string(from: Date())
            let summaryRow: JSONValue = .object([
                "id": .string("compact-\(UUID().uuidString.lowercased())"),
                "sessionId": .string(trimmed),
                "role": .string("system"),
                "content": .string(summary),
                "createdAt": .string(nowISO),
                "source": .string("native_compaction"),
                "metadata": .object([
                    "kind": .string("compaction_summary"),
                    "messages_replaced": .int(Int64(replaceCount)),
                ]),
            ])
            let nextRows = [summaryRow] + kept
            var payload = Data()
            for row in nextRows {
                payload.append(Data((try row.serialize(pretty: false)).utf8))
                payload.append(0x0A)
            }
            try FileManager.default.createDirectory(at: messagesPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: messagesPath, options: .atomic)
            // gpt-5.5 review #1 (BLOCKING follow-through): the legacy
            // context.json writer was the source of stale data
            // (`auto_compact_threshold: 75` as a percent, fixed 200k budget,
            // model="swift-native-compactor"). getSessionContext is now
            // entirely live-computed from messages.jsonl, so the writer is
            // gone. The next refresh() pass will reflect the post-compaction
            // state directly.
            return CompactionResult(
                compacted: true,
                session_id: trimmed,
                messages_before: before,
                messages_after: nextRows.count,
                summary_chars: summary.count,
                messages_replaced: replaceCount,
                reason: "swift-native-compaction",
                percent: nil,
                error: nil
            )
        }
    }

    static func visibleNotificationInboxPath(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    @discardableResult
    static func updateVisibleNotificationInboxStatus(
        id: String,
        action: String,
        inboxPath: URL = visibleNotificationInboxPath(),
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) async -> Bool {
        let status: String
        let readAt: String?
        switch action {
        case "read":
            status = "read"
            readAt = NotificationInboxStore.nowISO()
        case "archive":
            status = "archived"
            readAt = nil
        case "dismiss":
            status = "dismissed"
            readAt = nil
        default:
            return false
        }

        // U5 W-A item 1 (:11597): the read swallow turned a corrupt/
        // unreadable inbox into rows=[] → "row not found" → false, silently
        // dropping the status write (archived-card-resurrection class). The
        // resolve site keeps its markArchived fallback; the swallow itself
        // is fixed — read failures throw, get LOGGED, and return false
        // without ever treating corrupt-as-empty.
        do {
            return try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
                let rows = try await Self.readJSONLHonest(
                    persistence, path: inboxPath,
                    context: "updateVisibleNotificationInboxStatus")
                guard !rows.isEmpty else { return false }
            var updated = false
            var serialized: [String] = []
            serialized.reserveCapacity(rows.count)

            for row in rows {
                guard case .object(var obj) = row,
                      case .string(let rowID)? = obj["id"],
                      rowID == id else {
                    serialized.append(try row.serialize(pretty: false))
                    continue
                }
                obj["status"] = .string(status)
                if let readAt {
                    obj["read_at"] = .string(readAt)
                }
                serialized.append(try JSONValue.object(obj).serialize(pretty: false))
                updated = true
            }
            guard updated else { return false }

            try FileManager.default.createDirectory(
                at: inboxPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = Data((serialized.joined(separator: "\n") + "\n").utf8)
            try payload.write(to: inboxPath, options: [.atomic])
            _ = chmod(inboxPath.path, 0o600)
            return true
            }
        } catch {
            NSLog("[inbox] updateVisibleNotificationInboxStatus(\(action)) failed for \(id): \(String(describing: error))")
            return false
        }
    }

    // PATCH-2026-05-07 / DAEMON-DEAD PORT (2026-06-02): read
    // <dataRoot>/notifications/inbox.jsonl directly. Cross-ref NotificationInbox.
    // Lossy per-row decode — one malformed record doesn't nuke the list.
    //
    // 2026-06-06: sort newest-first by created_at. The file is append-only,
    // so without this the just-fired card (e.g. tonight's dream) lands at
    // the BOTTOM of the inbox list and gets buried under older entries —
    // the user sees the push but can't find the card. Both consumers (Mac
    // InboxView's List(displayItems) and MacSyncEngine.nativeInboxSnapshotData
    // → iOS InboxStore) inherit this ordering, so iOS inbox surfaces it
    // the same way without an extra sort there.
    func getInboxItems(unreadOnly: Bool = false) async throws -> [InboxItemRecord] {
        let root = PersistenceCore.defaultDataRoot()
        let inboxPath = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let persistence = SwiftNativePersistenceCore()
        // U5 W-A item 1 (:11647): the read was swallowed into [] — a
        // corrupt/unreadable inbox file rendered as an EMPTY inbox.
        // readJSONLHonest propagates I/O errors AND throws on
        // bytes-but-no-rows; per-row decode stays lossy (one malformed
        // record doesn't nuke the list) but ALL rows failing to decode
        // throws too (decodeLossyArray's all-fail rule).
        let rows = try await Self.readJSONLHonest(
            persistence, path: inboxPath, context: "getInboxItems")
        let decoder = JSONDecoder()
        var items: [InboxItemRecord] = []
        var decodeFailures = 0
        for row in rows {
            guard let data = try? row.serializedData(pretty: false),
                  let item = try? decoder.decode(InboxItemRecord.self, from: data) else {
                decodeFailures += 1
                continue
            }
            if unreadOnly && !item.isUnread { continue }
            items.append(item)
        }
        if !rows.isEmpty && decodeFailures == rows.count {
            throw NSError(domain: "NativeAgent", code: -3, userInfo: [
                NSLocalizedDescriptionKey:
                    "getInboxItems: all \(rows.count) inbox row(s) failed to decode — "
                    + "refusing to render a corrupt inbox as empty"
            ])
        }
        // Newest-first by created_at. ISO-8601 strings sort lexicographically
        // in chronological order, so a string compare is correct; entries
        // with missing/blank created_at fall to the bottom.
        items.sort { lhs, rhs in
            if lhs.created_at.isEmpty { return false }
            if rhs.created_at.isEmpty { return true }
            return lhs.created_at > rhs.created_at
        }
        return items
    }

    // PATCH-2026-05-07: proactive-inbox-1 Get inbox trigger configs
    func getInboxTriggers() async throws -> [InboxTriggerConfig] {
        // SUBSYSTEM #17 cluster C3 (2026-05-31): SwiftNative TriggerScheduler.
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        return try await swiftListInboxTriggers()
    }

    // PATCH-2026-05-07: proactive-inbox-1 Trigger management helpers (Sendable-safe, discard return)
    func inboxTriggerEnable(_ name: String, enabled: Bool) async throws {
        // SUBSYSTEM #17 cluster C3 (2026-05-31): SwiftNative TriggerScheduler.
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        try await swiftInboxTriggerEnable(name: name, enabled: enabled)
        return
    }

    /// Typed shim for /v1/inbox/triggers/<name>/configure. InboxSettingsView
    /// uses this owner-preserving path instead of bypassing TriggerScheduler.
    /// Body shape: dict of arbitrary per-kind keys
    /// (e.g. {"paths": [...]} for file_watch).
    func inboxTriggerConfigure(_ name: String, body: [String: Any]) async throws {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        try await swiftInboxTriggerConfigure(name: name, body: body)
        return
    }

    func inboxTriggerFireNow(_ name: String, stub: Bool) async throws -> (itemId: String?, wasStub: Bool) {
        // Wave 12 (2026-05-31): SwiftNative path covers the stub=true canonical
        // kinds (file_watch/idle/time/execution_complete/session_pattern). The
        // non-stub action path now fails closed if the Swift scheduler cannot
        // execute it.
        // FIRE site: carries the paired-device push sender (see
        // TriggerNotifierBinding) so a manual fire pushes exactly like the
        // periodic tick does.
        let client = TriggerNotifierBinding.makeNotifyingTriggerScheduler()
        let result = try await client.fireInboxTrigger(name: name, isStub: stub)
        if let err = result.error, !err.isEmpty {
            throw NSError(domain: "NativeAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: err])
        }
        if result.status == "not_found" {
            // Match HTTP error envelope shape: daemon returns {"error":"not_found"}
            // and HTTP path throws the bare string. Keep behavior symmetric so
            // callers (InboxSettingsView) branch on the same text.
            throw NSError(domain: "NativeAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "not_found"])
        }
        // A fire the notifier did not handle (notify:false) still has to reach
        // the REAL notifications inbox — otherwise "Fire now" reports success
        // and the user's inbox stays empty (board M18). And if that mirror
        // FAILS, say so: a manual fire whose card never landed is an error,
        // not a success with an invisible item (gpt-5.5 review, 2026-07-09).
        if !(await TriggerNotifierBinding.mirrorNonNotifiedFire(result)) {
            throw NSError(domain: "NativeAgent", code: -1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Trigger fired but its card could not be written to the notifications inbox — check disk/logs (trigger_mirror)."
            ])
        }
        // Post-rebuild (2026-07-09): `result.stub` now means "is this a PLACEHOLDER"
        // — time/idle fires carry real content and return stub == false even when
        // requested with isStub: true. Surface the truth to the UI instead of
        // dropping it (gpt-5.5 review MED: the settings panel said "Fired (stub)"
        // for genuinely real briefs).
        return (result.itemId, result.stub ?? true)
    }

    // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/inbox/self_test

    func submitWorkshopExecution(title: String, objective: String, triggerSource: String = "manual") async throws -> WorkshopActionResult {
        // Compatibility seam retained for the live Workshop create consumer.
        // Gate it behind the SAME `.missionsWrites` wire flag as the legacy
        // create route so every create path stays native together. Mirrors the
        // retired `/v1/missions` queue-bridge response while current storage and
        // product ownership remain Workshop. It threads `triggerSource` through;
        // compatibility callers may still pass "trigger:<name>".
        // The daemon's create response is the SUMMARY {id,mission_id,status,title,
        // plan_steps}; build the equivalent WorkshopActionResult from the native
        // submit envelope + record.
        let runner = makeWorkshopExecutionRunner()
        let spec = WorkshopExecution.WorkshopExecutionSpec(
            title: title,
            objective: objective,
            triggerSource: triggerSource,
            trustRequired: "none"
        )
        let result = try await WorkshopExecution.WorkshopDirectedTaskSubmitter(
            dataRoot: PersistenceCore.defaultDataRoot(),
            runner: runner
        ).submit(spec: spec)
        return WorkshopActionResult(
            // MINOR STATUS DIVERGENCE (documented §6.220): the daemon's
            // create handler flips status→"running" inside submit() and
            // returns "running"; the SwiftNative submit() persists "queued"
            // and execution is deferred to WorkshopExecutorLoop's next drain
            // pass (executor port, 2026-06-10) rather than a submit-time
            // auto-start. Cosmetic only — this drives the "Execution queued:
            // <id>" toast, not control flow; loadMissions() re-reads the
            // live status from the queue right after. Reporting the enqueue
            // status is honest.
            executionId: result.executionId,
            status: result.execution.status,
            title: result.execution.title,
            plan_steps: result.execution.plan.count,
            id: result.executionId,
            desk_handle: result.deskItem.handle,
            desk_alias: result.deskItem.alias
        )
    }

    // Swift-native execution start. Do not synthesize `running`: the Executions
    // module owns execution state.
    //
    // gpt-5.5 executor-port blocker #1 (2026-06-10): this used to call the
    // WorkshopRunnerClient protocol's start(), which deliberately throws
    // .unavailable (the runner holds no executor closures) — the UI "Start
    // execution" path was dead. Explicit starts now route through the
    // ASSEMBLED WorkshopExecutorLoop instance published at app boot by
    // BackgroundLoopsAssembly.makeMissionExecutorLoopRunner →
    // WorkshopExecutorRef.shared (the AppRestartCoordinator.shared.configure
    // wiring pattern). Unconfigured ref (headless/test process, loops not
    // started yet) → honest "executor not running" error, never a silent
    // no-op; the execution stays durably queued for the next drain pass.
    func startWorkshopExecution(id: String) async throws -> WorkshopActionResult {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentWorkshop", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "startWorkshopExecution: empty id"
            ])
        }
        guard let executor = WorkshopExecutorRef.shared.current() else {
            throw NSError(domain: "NativeAgentWorkshop", code: 503, userInfo: [
                NSLocalizedDescriptionKey: "startWorkshopExecution: Workshop executor is not running in this process "
                    + "(background loops have not been assembled) — Workshop execution left queued"
            ])
        }
        let record = try await executor.start(executionId: trimmed)
        return WorkshopActionResult(
            executionId: record.id,
            status: record.status,
            title: record.title,
            plan_steps: record.plan.count,
            id: record.id
        )
    }

    // DAEMON-DEAD PORT (2026-06-02): read the approvals file, mark the matching
    // step record approved, write back under a flock. Then return the current
    // execution detail (native read).
    //
    // R5 (eval E06 fix-3): canonical path is `<root>/workflows/approvals/requests.json`
    // — matches the ApprovalInbox list reader source-of-truth
    // (ApprovalInbox.approvalsPath) and the daemon's notification-status reader.
    // Any pre-existing rows at the legacy `<root>/approvals/requests.json` are
    // migrated once: merged into the canonical file (canonical wins on id-conflict),
    // then the legacy file is renamed to `requests.json.migrated` so a second boot
    // skips the merge.
    func approveStep(executionId: String, stepId: String) async throws -> WorkshopExecution.WorkshopExecutionRecord {
        let root = PersistenceCore.defaultDataRoot()
        let approvalsPath = root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let legacyApprovalsPath = root
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let persistence = SwiftNativePersistenceCore()
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        try await persistence.withFileLock(approvalsPath) {
            // One-time migrate: if legacy path exists and has rows, merge into
            // the canonical file (canonical wins on id-conflict), then rename
            // the legacy file so subsequent boots skip the merge.
            if FileManager.default.fileExists(atPath: legacyApprovalsPath.path) {
                let legacyRaw = await persistence.readJSON(legacyApprovalsPath, defaultValue: .array([]))
                if case .array(let legacyRows) = legacyRaw, !legacyRows.isEmpty {
                    let canonicalRaw = await persistence.readJSON(approvalsPath, defaultValue: .array([]))
                    var canonicalRows: [JSONValue] = {
                        if case .array(let a) = canonicalRaw { return a }
                        return []
                    }()
                    func rowKey(_ v: JSONValue) -> String? {
                        guard case .object(let obj) = v else { return nil }
                        let m: String? = { if case .string(let s) = obj["executionId"] ?? obj["execution_id"] ?? obj["missionId"] ?? obj["mission_id"] ?? .null { return s }; return nil }()
                        let s: String? = { if case .string(let s) = obj["stepId"] ?? obj["step_id"] ?? obj["id"] ?? .null { return s }; return nil }()
                        guard let m = m, let s = s else { return nil }
                        return "\(m)#\(s)"
                    }
                    let existing: Set<String> = Set(canonicalRows.compactMap(rowKey))
                    for row in legacyRows {
                        if let k = rowKey(row), !existing.contains(k) {
                            canonicalRows.append(row)
                        }
                    }
                    try await persistence.writeJSON(.array(canonicalRows), to: approvalsPath)
                }
                let migratedPath = legacyApprovalsPath
                    .deletingLastPathComponent()
                    .appendingPathComponent("requests.json.migrated")
                try? FileManager.default.removeItem(at: migratedPath)
                try? FileManager.default.moveItem(at: legacyApprovalsPath, to: migratedPath)
            }
            let raw = await persistence.readJSON(approvalsPath, defaultValue: .array([]))
            var rows: [JSONValue] = {
                if case .array(let a) = raw { return a }
                return []
            }()
            var matched = false
            for i in rows.indices {
                guard case .object(var obj) = rows[i] else { continue }
                let rowWorkshopExecution: String? = { if case .string(let s) = obj["executionId"] ?? obj["execution_id"] ?? obj["missionId"] ?? obj["mission_id"] ?? .null { return s }; return nil }()
                let rowStep: String? = { if case .string(let s) = obj["stepId"] ?? obj["step_id"] ?? obj["id"] ?? .null { return s }; return nil }()
                if rowWorkshopExecution == executionId && rowStep == stepId {
                    obj["status"] = .string("approved")
                    obj["decision"] = .string("approved")
                    obj["resolvedAt"] = .string(nowISO)
                    rows[i] = .object(obj)
                    matched = true
                }
            }
            if !matched {
                rows.append(.object([
                    "executionId": .string(executionId),
                    "stepId": .string(stepId),
                    "status": .string("approved"),
                    "decision": .string("approved"),
                    "resolvedAt": .string(nowISO),
                ]))
            }
            try await persistence.writeJSON(.array(rows), to: approvalsPath)
        }
        guard let record = await makeWorkshopExecutionRunner().getWorkshopExecution(executionId) else {
            throw DaemonError.notFound("workshop execution \(executionId)")
        }
        return record
    }

    func rejectStep(executionId: String, stepId: String, reason: String = "Rejected by user") async throws -> WorkshopExecution.WorkshopExecutionRecord {
        // residue/R6: daemon step-reject route retired. Mirror approveStep's
        // canonical-path R-M-W under flock; flip decision to "rejected" + carry
        // the reason. Same approvals.json file the ApprovalInbox reads.
        let root = PersistenceCore.defaultDataRoot()
        let approvalsPath = root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let persistence = SwiftNativePersistenceCore()
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        try await persistence.withFileLock(approvalsPath) {
            let raw = await persistence.readJSON(approvalsPath, defaultValue: .array([]))
            var rows: [JSONValue] = {
                if case .array(let a) = raw { return a }
                return []
            }()
            var matched = false
            for i in rows.indices {
                guard case .object(var obj) = rows[i] else { continue }
                let rowWorkshopExecution: String? = { if case .string(let s) = obj["executionId"] ?? obj["execution_id"] ?? obj["missionId"] ?? obj["mission_id"] ?? .null { return s }; return nil }()
                let rowStep: String? = { if case .string(let s) = obj["stepId"] ?? obj["step_id"] ?? obj["id"] ?? .null { return s }; return nil }()
                if rowWorkshopExecution == executionId && rowStep == stepId {
                    obj["status"] = .string("rejected")
                    obj["decision"] = .string("rejected")
                    obj["reason"] = .string(reason)
                    obj["resolvedAt"] = .string(nowISO)
                    rows[i] = .object(obj)
                    matched = true
                }
            }
            if !matched {
                rows.append(.object([
                    "executionId": .string(executionId),
                    "stepId": .string(stepId),
                    "status": .string("rejected"),
                    "decision": .string("rejected"),
                    "reason": .string(reason),
                    "resolvedAt": .string(nowISO),
                ]))
            }
            try await persistence.writeJSON(.array(rows), to: approvalsPath)
        }
        guard let record = await makeWorkshopExecutionRunner().getWorkshopExecution(executionId) else {
            throw DaemonError.notFound("workshop execution \(executionId)")
        }
        return record
    }

    func setTriggerEnabled(name: String, enabled: Bool) async throws -> WorkshopActionResult {
        // SUBSYSTEM #17 cluster C3 (2026-05-31): SwiftNative TriggerScheduler
        // returns a TriggerStatus envelope ({"name","enabled","status"}); map
        // onto WorkshopActionResult for the remaining settings callers.
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        return try await swiftWorkshopTriggerEnable(name: name, enabled: enabled)
    }

    // SUBSYSTEM #17: retired Swift wrapper for /v1/missions/triggers/<name>/fire_now.

    // SUBSYSTEM #17: retired Swift wrapper missionSelfTest.

    // PATCH-2026-05-06: dev-mode added to JSON body so daemon receives it
}
