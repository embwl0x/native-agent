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
public enum RuntimeReadProjection {
    public static func getSessionContext(
        sessionId: String,
        model: String? = nil,
        providerID: String,
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
        let statistics = await ChatTranscriptCache.shared.contextStatistics(at: messagesPath)
        let totalChars = statistics.totalChars
        let messageCount = statistics.messageCount

        let resolvedModel = (model?.isEmpty == false ? model! : "")
        // gpt-5.5 review #3 (NEEDS_FIX): chars/4 systematically
        // underestimates Anthropic tokenization by ~10–15%. Use ~3.5 for
        // claude-* and 4 for everyone else so the displayed percent is closer
        // to what the provider actually charges. Rounded conservatively
        // (higher token count → bar fills faster → user compacts sooner).
        let divisor: Double = resolvedModel.lowercased().contains("claude") ? 3.5 : 4.0
        let transcriptTokens = max(0, Int((Double(totalChars) / divisor).rounded()))

        // Her window (`effectiveWindowTokens`): 60% of the selected model's on
        // this session's effective route, capped by a Custom size; an injected size is Custom.
        // The ring is of it, the same window the composer card reads, and she
        // compacts at it. A window no catalog row states is 0: unknown.
        var windowConfig = ChatSessionAutocompactionConfig.productionDefault()
        if let configuredThresholdTokens, configuredThresholdTokens > 0 {
            windowConfig.thresholdTokens = configuredThresholdTokens
            windowConfig.contextWindowMode = .custom
        }
        let budget = windowConfig.effectiveWindowTokens(forModel: resolvedModel, providerID: providerID, dataRoot: root) ?? 0

        let providerUsagePath = root
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

        let threshold = windowConfig.effectiveThresholdTokens(forModel: resolvedModel, providerID: providerID, dataRoot: root)

        // A carried-over receipt counts tokens against the PREVIOUS model's
        // window, so an 800k figure over a fresh 128k budget would read 600%.
        // The used figure stays honest; only the displayed fraction is capped
        // at full, which is what "the window is full" means on the new model.
        let rawPercent: Double = budget > 0 ? (Double(usedTokens) / Double(budget)) * 100.0 : 0.0
        let percent: Double = receiptMatchesModel ? rawPercent : min(rawPercent, 100.0)
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
            // Turn-over-turn deltas only mean something within one model's own
            // accounting, so they drop on a switch even though the used figure
            // carries. The first turn on the new model restates them.
            previous_turn_tokens: receiptMatchesModel ? providerReceipt?.previousTurnInputTokens : nil,
            turn_delta_tokens: receiptMatchesModel ? providerReceipt?.turnInputDeltaTokens : nil,
            budget: budget,
            percent: percent,
            message_count: messageCount,
            compactable: compactable,
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
        let (data, startsMidFile) = try SwiftNativePersistenceCore.activityTail(dataRoot: root)
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        if startsMidFile && !lines.isEmpty { lines.removeFirst() }
        let tail = lines.filter { bytes in
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
