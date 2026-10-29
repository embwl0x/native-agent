import Transcripts
import Foundation
import NativeAgentShared
import PersistenceCore
import TrustPersistence
import TrustCenter
import ProviderRouting
import ChatSessionWork
import PersonaEngine
// Blueprint: | `RuntimeReadProjection.swift` | Autonomy delegates to TrustFacade's policy projection; unused personal-OS compiler read is deleted (Capabilities renders the published profile); `getSessionContext` requires the effective session provider |

private struct SessionProviderUsageReceipt: Decodable {
    let model: String
    let lastRequestInputTokens: Int
    let previousTurnInputTokens: Int?
    let turnInputDeltaTokens: Int?
}

/// Mac-local activity rows; historical missionId remains readable permanently.
public struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var detail: String?
    public var status: String
    public var executionId: String?
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, status, createdAt, executionId
        case legacyExecutionId = "missionId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.title = try c.decode(String.self, forKey: .title)
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail)
        self.status = try c.decode(String.self, forKey: .status)
        self.createdAt = try c.decode(String.self, forKey: .createdAt)
        self.executionId = try c.decodeIfPresent(String.self, forKey: .executionId)
            ?? c.decodeIfPresent(String.self, forKey: .legacyExecutionId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encode(status, forKey: .status)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(executionId, forKey: .executionId)
    }
}

public struct ActivityTailRecord: Sendable {
    public let event: ActivityEvent
    public let subject: String?
    public let needsReconciliation: Bool
}

public struct ActivityTailReadout: Sendable {
    public let records: [ActivityTailRecord]
    public let malformedRowCount: Int
}

/// Runtime read decisions shared by local and remote surfaces.
public enum RuntimeReadouts {
    public static func getSessionContext(
        sessionId: String,
        model: String? = nil,
        providerID: String,
        dataRoot: URL,
        configuredThresholdTokens: Int?
    ) async throws -> SessionContextStatus {
        // Saved context.json is not authoritative; derive status from current transcript, provider receipts and routing.
        // Live estimate from messages on disk.
        let messagesPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        let statistics = await ChatTranscriptCache.shared.contextStatistics(at: messagesPath)
        let totalChars = statistics.totalChars
        let messageCount = statistics.messageCount

        let resolvedModel = (model?.isEmpty == false ? model! : "")
        let transcriptTokens = max(0, Int((Double(totalChars) / ContextBudgetPolicy.transcriptCharactersPerToken).rounded()))

        // Her window (`effectiveWindowTokens`): 60% of the selected model's on
        // this session's effective route, capped by a Custom size; an injected size is Custom.
        // The ring is of it, the same window the composer card reads, and she
        // compacts at it. A window no catalog row states is 0: unknown.
        var windowConfig = ChatSessionAutocompactionConfig.productionDefault()
        if let configuredThresholdTokens, configuredThresholdTokens > 0 {
            windowConfig.thresholdTokens = configuredThresholdTokens
            windowConfig.contextWindowMode = .custom
        }
        let window = windowConfig.effectiveWindowTokens(forModel: resolvedModel, providerID: providerID, dataRoot: dataRoot)
        let budget = window ?? 0

        let providerUsagePath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("session_state", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("provider_usage.json")
        let providerReceipt: SessionProviderUsageReceipt? = {
            guard let data = try? Data(contentsOf: providerUsagePath),
                  let receipt = try? JSONDecoder().decode(SessionProviderUsageReceipt.self, from: data),
                  receipt.lastRequestInputTokens >= 0 else {
                return nil
            }
            return receipt
        }()
        // What the session has spent does not vanish because the person picked
        // a different model mid-conversation: the same history is still in the
        // window. Only the denominator changes (`budget`, keyed to
        // `resolvedModel` above), so the ring re-scales instead of dropping to
        // 0%. A new conversation still starts empty — that reset is the absence
        // of this per-session receipt file, not a model comparison.
        let receiptMatchesModel = providerReceipt.map {
            $0.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } ?? false
        // A matching provider receipt is the authority even when selective
        // history or compaction makes the real request smaller than the full
        // transcript stored on disk.
        let usedTokens = providerReceipt?.lastRequestInputTokens ?? transcriptTokens
        let promptTokens = max(0, usedTokens - transcriptTokens)

        let threshold = window ?? windowConfig.thresholdTokens

        // A carried-over receipt counts tokens against the PREVIOUS model's
        // window, so an 800k figure over a fresh 128k budget would read 600%.
        // The used figure stays honest; only the displayed fraction is capped
        // at full, which is what "the window is full" means on the new model.
        let rawPercent: Double = budget > 0 ? (Double(usedTokens) / Double(budget)) * 100.0 : 0.0
        let percent: Double = receiptMatchesModel ? rawPercent : min(rawPercent, 100.0)

        return SessionContextStatus(
            session_id: sessionId,
            used_tokens: usedTokens,
            transcript_tokens: transcriptTokens,
            prompt_tokens: promptTokens,
            // Turn-over-turn deltas only mean something within one model's own
            // accounting, so they drop on a switch even though the used figure
            // carries. The first turn on the new model restates them.
            previous_turn_tokens: receiptMatchesModel ? providerReceipt?.previousTurnInputTokens : nil,
            turn_delta_tokens: receiptMatchesModel ? providerReceipt?.turnInputDeltaTokens : nil,
            budget: budget,
            percent: percent,
            message_count: messageCount,
            // A short transcript can still exceed its window.
            compactable: transcriptTokens >= threshold,
            auto_compact_threshold: threshold,
            model: resolvedModel,
            context_loaded: providerReceipt != nil,
            context_mode: providerReceipt == nil
                ? "transcript_estimate"
                : (receiptMatchesModel ? "provider_receipt" : "provider_receipt_prior_model"),
            context_fingerprint: nil,
            context_prompt_chars: totalChars
        )
    }

    public static func getAutonomyKernel(dataRoot: URL) async throws -> AutonomyKernelSummary {
        TrustFacade.autonomyKernel(for: try await TrustFacade(dataRoot: dataRoot).load())
    }

    public static func getActivity(root: URL) async throws -> [ActivityEvent] {
        let readout = try await getActivityReadout(root: root)
        guard !readout.records.isEmpty || readout.malformedRowCount == 0 else {
            throw NSError(
                domain: "NativeAgentActivity",
                code: -422,
                userInfo: [NSLocalizedDescriptionKey: "activity ledger contains no readable event records"]
            )
        }
        return readout.records.map(\.event)
    }

    public static func getActivityReadout(root: URL) async throws -> ActivityTailReadout {
        let read = try SwiftNativePersistenceCore.tailPhysicalLines(
            SwiftNativePersistenceCore.activityEventsPath(dataRoot: root), limit: .max, maxBytes: 1_048_576)
        let tail = (read?.lines ?? []).dropFirst(read?.leadingFragment == true ? 1 : 0).filter { bytes in
            guard let line = String(data: Data(bytes), encoding: .utf8) else { return true }
            return !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.suffix(200)
        guard !tail.isEmpty else { return ActivityTailReadout(records: [], malformedRowCount: 0) }

        let decoder = JSONDecoder.nativeAgent
        var records: [ActivityTailRecord] = []
        var malformedRowCount = 0
        for bytes in tail {
            let data = Data(bytes)
            guard String(data: data, encoding: .utf8) != nil,
                  let event = try? decoder.decode(ActivityEvent.self, from: data) else {
                malformedRowCount += 1
                continue
            }
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let fields = payload?["payload"] as? [String: Any]
            let subject: String?
            if let occurrenceKey = fields?["occurrenceKey"] as? String, !occurrenceKey.isEmpty {
                subject = "occurrence:\(occurrenceKey)"
            } else if let executionId = event.executionId, !executionId.isEmpty {
                subject = "execution:\(executionId)"
            } else if let jobId = fields?["jobId"] as? String, !jobId.isEmpty {
                subject = "job:\(jobId)"
            } else if let handle = (fields?["itemHandle"] ?? fields?["itemId"] ?? fields?["handle"]) as? String, !handle.isEmpty {
                subject = "item:\(handle)"
            } else {
                subject = nil
            }
            records.append(ActivityTailRecord(
                event: event,
                subject: subject,
                needsReconciliation: fields?["outcome"] as? String == "unknown_after_restart"
            ))
        }
        return ActivityTailReadout(records: records, malformedRowCount: malformedRowCount)
    }
}
