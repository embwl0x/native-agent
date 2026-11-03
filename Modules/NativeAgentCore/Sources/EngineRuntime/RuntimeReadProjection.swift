import Transcripts
import Foundation
import NativeAgentShared
import PersistenceCore
import TrustPersistence
import TrustCenter
import ProviderRouting
import ChatSessionWork
import PersonaEngine
// Blueprint: | `RuntimeReadProjection.swift` | Checked Mac activity history rejects damaged rows; canonical activity identity is executionId only. Session context projects matching provider-observed input usage and the detected window; absent measurements are unavailable, never estimates or zeroes. Autonomy delegates to TrustFacade's policy projection. |

/// Mac-local activity rows use the canonical execution identity.
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
        // The ring reports observed provider usage. Compaction separately sizes
        // the next built request through the same measurement owner.
        let resolvedModel = (model?.isEmpty == false ? model! : "")
        // The detected model window, limited by a Custom cap. Unknown stays unknown.
        var windowConfig = ChatSessionAutocompactionConfig.productionDefault()
        if let configuredThresholdTokens, configuredThresholdTokens > 0 {
            windowConfig.thresholdTokens = configuredThresholdTokens
            windowConfig.contextWindowMode = .custom
        }
        let window = windowConfig.effectiveWindowTokens(forModel: resolvedModel, providerID: providerID, dataRoot: dataRoot)
        guard let window, window > 0 else {
            throw ProviderRoutingError.configurationFailed(windowConfig.configurationFailure
                ?? "The selected model's context window is unavailable. Refresh its catalog in Providers.")
        }
        let measurement = try await SessionContextMeasurement.read(sessionId: sessionId,
            model: resolvedModel, providerID: providerID, dataRoot: dataRoot, windowTokens: window)
        guard let usedTokens = measurement.observedInputTokens else {
            throw RuntimeReadError.unreadableFeed("Context usage has not been observed for this session's selected provider and model. Send a turn on this route to obtain a provider usage receipt.")
        }
        let budget = window
        let threshold = windowConfig.triggerTokens(in: window, outputTokens: measurement.outputTokens)
        let percent = (Double(usedTokens) / Double(budget)) * 100.0

        return SessionContextStatus(
            session_id: sessionId,
            used_tokens: usedTokens,
            transcript_tokens: nil,
            prompt_tokens: nil,
            previous_turn_tokens: measurement.previousTurnTokens,
            turn_delta_tokens: measurement.turnDeltaTokens,
            budget: budget,
            percent: percent,
            message_count: measurement.messageCount,
            // A short transcript can still exceed its window.
            compactable: usedTokens >= threshold,
            auto_compact_threshold: threshold,
            model: resolvedModel,
            context_loaded: true,
            context_mode: "provider_usage_receipt",
            context_fingerprint: nil,
            context_prompt_chars: measurement.renderedCharacters
        )
    }

    public static func getAutonomyKernel(dataRoot: URL) async throws -> AutonomyKernelSummary {
        TrustFacade.autonomyKernel(for: try await TrustFacade(dataRoot: dataRoot).load())
    }

    public static func getActivity(root: URL) async throws -> [ActivityEvent] {
        let readout = try await getActivityReadout(root: root)
        guard readout.malformedRowCount == 0 else {
            throw NSError(
                domain: "NativeAgentActivity",
                code: -422,
                userInfo: [NSLocalizedDescriptionKey: "Activity history is unavailable (\(readout.malformedRowCount) damaged rows in the recent ledger). Repair the retained rows before relying on a complete history."]
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
