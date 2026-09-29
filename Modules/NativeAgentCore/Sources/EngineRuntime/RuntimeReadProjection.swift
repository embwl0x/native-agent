import Transcripts
import Foundation
import NativeAgentShared
import PersistenceCore
import TrustPersistence
import TrustCenter
import ProviderRouting
import ChatOrchestration
import SelfImprovement

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

        // Her window (`effectiveWindowTokens`): 60% of the selected model's,
        // capped by a Custom size; an injected size is Custom. The ring is of
        // it, the same window the composer card reads, and she compacts at it.
        // An unknown model takes the same 60% of the catalog's gauge default.
        var windowConfig = ChatSessionAutocompactionConfig.productionDefault()
        if let configuredThresholdTokens, configuredThresholdTokens > 0 {
            windowConfig.thresholdTokens = configuredThresholdTokens
            windowConfig.contextWindowMode = .custom
        }
        let gaugeWindow = ProviderRouting.contextLength(forModel: resolvedModel)
        let budget = windowConfig.effectiveWindowTokens(forModel: resolvedModel)
            ?? windowConfig.effectiveWindowTokens(nativeWindowTokens: gaugeWindow)
            ?? gaugeWindow

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

        let threshold = windowConfig.effectiveThresholdTokens(forModel: resolvedModel)

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

    public static func getLatestContextReceipt(
        sessionId: String,
        dataRoot: URL
    ) async throws -> ContextReceipt {
        // Swift-native cutover port P2: was GET /v1/context/latest. Tail-scan
        // `<dataRoot>/context/receipts.jsonl` (append-only, newest-last),
        // return the newest entry whose sessionId matches; if no sessionId
        // filter hits, fall back to the absolute newest. Missing file or
        // empty → synthesized empty receipt (ContextReceipt's custom
        // init(from:) decodeIfPresent's every key, so `{}` is valid).
        let url = dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return try JSONDecoder.nativeAgent.decode(ContextReceipt.self, from: Data("{}".utf8))
        }
        let decoder = JSONDecoder.nativeAgent
        var newestForSession: ContextReceipt? = nil
        var newestAny: ContextReceipt? = nil
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            guard let row = try? decoder.decode(ContextReceipt.self, from: lineData) else { continue }
            newestAny = row
            if row.sessionId == sessionId { newestForSession = row }
        }
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSessionId.isEmpty {
            if let receipt = newestForSession { return receipt }
            return try decoder.decode(ContextReceipt.self, from: Data("{}".utf8))
        }
        if let receipt = newestAny { return receipt }
        return try decoder.decode(ContextReceipt.self, from: Data("{}".utf8))
    }

    public static func getPersonalOS<Failure: Error>(dataRoot: URL, unreadableFeed: (String) -> Failure) async throws -> PersonalOSSummary {
        /// HONEST MINIMAL: NativeAgent ships a single active persona today
        /// (persona/profile.json), so the PersonalOS summary surfaces exactly
        /// one space derived from that file's `name`/`active` key. The daemon
        /// never aggregated additional spaces — there is no fan-out to port —
        /// so this is the real shape, not a stub. If/when multi-persona
        /// support lands, this aggregator is the seam to extend.
        let path = dataRoot
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent("profile.json")
        let primaryName: String?
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                let data = try Data(contentsOf: path)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw unreadableFeed(
                        "Persona profile is not a JSON object"
                    )
                }
                if let name = object["name"] {
                    guard let string = name as? String else {
                        throw unreadableFeed(
                            "Persona profile name is not text"
                        )
                    }
                    primaryName = string
                } else if let active = object["active"] {
                    guard let string = active as? String else {
                        throw unreadableFeed(
                            "Persona profile active name is not text"
                        )
                    }
                    primaryName = string
                } else {
                    primaryName = nil
                }
            } catch let error as Failure {
                throw error
            } catch {
                throw unreadableFeed(
                    "Persona profile is unreadable: \(error.localizedDescription)"
                )
            }
        } else {
            primaryName = nil
        }
        let spaces: [PersonalOSSpace]
        if let name = primaryName {
            spaces = [PersonalOSSpace(id: "persona", name: name, count: 1, kind: "persona")]
        } else {
            spaces = []
        }
        return PersonalOSSummary(
            spaces: spaces,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    public static func getAutonomyKernel(dataRoot: URL, improvements: () async throws -> [ImprovementRun]) async throws -> AutonomyKernelSummary {
        // DAEMON-DEAD PORT (2026-06-03): summarize the Swift-owned autonomy
        // gates from Trust policy plus local improvement run state. This is a
        // status surface only; action execution remains guarded by its own
        // native engines.
        let policy = try await TrustFacade(dataRoot: dataRoot).load()
        // U5 W-A item 1 (:5156): propagate — a failed improvements read
        // previously rendered as "0 running improvements" (healthy-empty).
        let improvements = try await improvements()
        let runningImprovements = improvements.filter {
            ["running", "queued", "planning", "executing"].contains(($0.status ?? "").lowercased())
        }.count
        let processEnabled = true
        let trustEnabled = policy.enableAutonomy
        let enabled = processEnabled && trustEnabled
        let mode = policy.autonomyDefault ?? "supervised"
        let disabledReason: String? = {
            if !processEnabled { return "App autonomy process gate is disabled" }
            if !trustEnabled { return "Trust Center autonomy is disabled" }
            return nil
        }()

        let outside = policy.filePolicy?.outsideWorkspaceDefault ?? "deny"
        let backupRequired = policy.filePolicy?.requireBackupBeforeWrite ?? true
        let trainingEnabled = policy.trainingPolicy?.autonomous_training ?? false
        let promotionEnabled = policy.promotionPolicy?.enabled ?? false
        let memoryHygiene = policy.memoryPolicy?.hygiene_enabled ?? true

        return AutonomyKernelSummary(
            status: enabled ? "ok" : "off",
            mode: mode,
            enabled: enabled,
            processEnabled: processEnabled,
            trustEnabled: trustEnabled,
            disabledReason: disabledReason,
            guardrails: [
                KernelGuardrail(
                    id: "trust.enableAutonomy",
                    title: "Trust autonomy switch",
                    status: trustEnabled ? "ok" : "off"
                ),
                KernelGuardrail(
                    id: "file.outsideWorkspaceDefault",
                    title: "Outside-workspace file policy",
                    status: outside == "allow" ? "wide" : "guarded"
                ),
                KernelGuardrail(
                    id: "file.requireBackupBeforeWrite",
                    title: "Write backup requirement",
                    status: backupRequired ? "ok" : "warn"
                ),
                KernelGuardrail(
                    id: "training.autonomous_training",
                    title: "Autonomous training",
                    status: trainingEnabled ? "ok" : "off"
                ),
                KernelGuardrail(
                    id: "promotion.enabled",
                    title: "Promotion engine",
                    status: promotionEnabled ? "ok" : "off"
                ),
                KernelGuardrail(
                    id: "memory.hygiene_enabled",
                    title: "Memory hygiene",
                    status: memoryHygiene ? "ok" : "off"
                ),
            ],
            approvalClasses: [
                ApprovalClass(id: "external_send", title: "External sends", requiresApproval: true),
                ApprovalClass(id: "filesystem_write", title: "Filesystem writes", requiresApproval: true),
                ApprovalClass(id: "system_change", title: "System changes", requiresApproval: true),
                ApprovalClass(id: "safe_read", title: "Safe reads", requiresApproval: false),
            ],
            runningImprovements: runningImprovements,
            createdAt: SwiftNativeManifestSigner.isoTimestamp(Date())
        )
    }

    public static func decodeTailLines(_ data: Data, dropFirstPartial: Bool) -> [String] {
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        if dropFirstPartial && !parts.isEmpty { parts.removeFirst() }
        return parts
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
        // DAEMON-KILL P1: tail of <dataRoot>/activity/events.jsonl.
        let path = root
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path.path) else { return ActivityTailReadout(records: [], malformedRowCount: 0) }
        let attributes = try fileManager.attributesOfItem(atPath: path.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else { return ActivityTailReadout(records: [], malformedRowCount: 0) }

        let maximumBytes = UInt64(1_048_576)
        let count = min(size, maximumBytes)
        let startsMidFile = size > count
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        if startsMidFile {
            try handle.seek(toOffset: size - count)
        }
        let data = handle.readData(ofLength: Int(count))
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
