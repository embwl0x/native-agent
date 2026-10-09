import Foundation
import Observation
import PersistenceCore
import ProviderRouting
import BackgroundLoops
import TelegramBot

/// Mounted Telegram management state. The core owns configuration and transport
/// status; the facade adds bounded diagnostic feeds and the app's routing pick.
@MainActor
@Observable
public final class TelegramFacade {
    public nonisolated let dataRoot: URL
    public var status: TelegramPresentationSnapshot?

    public nonisolated init(dataRoot: URL) { self.dataRoot = dataRoot }

    public nonisolated func configuration() async -> TelegramConfigurationSummary? {
        guard let config = try? TelegramBot.TelegramConfig.loadSavedConfiguration(dataRoot: dataRoot) else { return nil }
        let routing = try? await SwiftNativeProviderRouting(dataRoot: dataRoot).computeModelPreferences()["telegram"]
        let brain = resolveTelegramBrain(routing: routing, legacyModel: config.model,
                                         legacyReasoningEffort: config.reasoningEffort)
        return TelegramConfigurationSummary(config: config, model: brain.model, reasoningEffort: brain.reasoningEffort)
    }

    public nonisolated func load(manager: BackgroundLoopsManager = .shared, credentialUnavailable: Bool = false,
                                 routingSnapshot: ProviderRoutingSnapshot? = nil) async throws -> TelegramPresentationSnapshot {
        var snapshot = try await loadStatus(manager: manager, credentialUnavailable: credentialUnavailable,
                                            routingSnapshot: routingSnapshot)
        let telegramDir = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        let receiptsRead: TelegramDiagnosticFeedRead<TelegramReceipt> = await telegramDiagnosticFeed(
            path: telegramDir.appendingPathComponent("receipts.jsonl"),
            limit: 50
        )
        let blockedRead: TelegramDiagnosticFeedRead<TelegramBlockedEvent> = await telegramDiagnosticFeed(
            path: telegramDir.appendingPathComponent("blocked.jsonl"),
            limit: 50
        )
        let errorsRead: TelegramDiagnosticFeedRead<TelegramErrorEvent> = await telegramDiagnosticFeed(
            path: telegramDir.appendingPathComponent("errors.jsonl"),
            limit: 50
        )
        snapshot.receipts = receiptsRead.rows
        snapshot.blocked = blockedRead.rows
        snapshot.errors = errorsRead.rows
        snapshot.receiptsIssue = receiptsRead.issue
        snapshot.blockedIssue = blockedRead.issue
        snapshot.errorsIssue = errorsRead.issue
        return snapshot
    }

    public nonisolated func loadStatus(manager: BackgroundLoopsManager = .shared, credentialUnavailable: Bool = false,
                                       routingSnapshot: ProviderRoutingSnapshot? = nil) async throws -> TelegramPresentationSnapshot {
        // Read config and state once for this projection; retain
        // only credential-free configuration in observable state.
        let cfg = try TelegramBot.TelegramConfig.loadSavedConfiguration(dataRoot: dataRoot, resolveCredential: !credentialUnavailable)
        let telegramBrain: SurfacePreference?
        if let routingSnapshot {
            telegramBrain = routingSnapshot.preferences["telegram"]
        } else {
            telegramBrain = try? await SwiftNativeProviderRouting(dataRoot: dataRoot)
                .computeModelPreferences()["telegram"]
        }
        let resolvedTelegramBrain = resolveTelegramBrain(
            routing: telegramBrain,
            legacyModel: cfg?.model,
            legacyReasoningEffort: cfg?.reasoningEffort
        )
        let telegramDir = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        let stateURL = telegramDir.appendingPathComponent("state.json")
        var lastSeenUpdateId: Int?
        var lastSeenAt: String?
        var lastReplyAt: String?
        var lastError: String?
        var pollBackoffFailures: Int?
        var lastPollAt: String?
        var lastDiagnosticsClearedAt: String?
        if let data = try? Data(contentsOf: stateURL),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Current key first, legacy key second; an unrepresentable double
            // is treated as absent so the legacy key still gets its turn.
            lastSeenUpdateId = [raw["lastSeenUpdateId"], raw["lastUpdateId"]].lazy.compactMap { value -> Int? in
                if let i = value as? Int { return i }
                if let d = value as? Double { return Int(exactly: d.rounded(.towardZero)) }
                return nil
            }.first
            lastSeenAt = raw["lastSeenAt"] as? String
            lastReplyAt = raw["lastReplyAt"] as? String
            lastError = raw["lastError"] as? String
            if let i = raw["pollBackoffFailures"] as? Int {
                pollBackoffFailures = i
            } else if let d = raw["pollBackoffFailures"] as? Double {
                pollBackoffFailures = Int(exactly: d.rounded(.towardZero))
            }
            lastPollAt = raw["lastPollAt"] as? String
            lastDiagnosticsClearedAt = raw["lastDiagnosticsClearedAt"] as? String
        }
        if let loop = await manager.loopRunner(loopId: "telegram_poll") as? TelegramPollLoop,
           let polledAt = await loop.lastSuccessfulPollAt {
            lastPollAt = ISO8601DateFormatter().string(from: polledAt)
        }
        let voiceBackend = cfg?.voiceTranscriptionBackend ?? TelegramBot.TelegramConfig.defaultVoiceTranscriptionBackend
        let voiceModel = cfg?.voiceTranscriptionModel ?? TelegramBot.TelegramConfig.defaultVoiceTranscriptionModel
        let voiceStatus = TelegramVoiceTranscriptionStatus(
            enabled: cfg?.voiceTranscriptionEnabled ?? TelegramBot.TelegramConfig.defaultVoiceTranscriptionEnabled,
            backend: voiceBackend,
            model: voiceModel,
            maxBytes: cfg?.voiceMaxBytes ?? TelegramBot.TelegramConfig.defaultVoiceMaxBytes
        )
        // F4 fix-6: pollerEnabled reports ACTUAL loop-running state from the
        // BackgroundLoopsManager — registered AND its runtime is running —
        // not just config.enabled. Config-says-on / loop-not-running is the
        // exact regression the UI used to hide (status panel looked healthy
        // while the poller was dead).
        let loopStatuses = await manager.status()
        let pollerRunning = loopStatuses.contains(where: { $0.name == "telegram_poll" && $0.running })
        return TelegramPresentationSnapshot(
            transport: TelegramBot.TelegramStatus(
                enabled: cfg?.enabled ?? false,
                tokenConfigured: cfg?.tokenConfigured ?? false,
                pollerEnabled: pollerRunning,
                lastSeenUpdateId: lastSeenUpdateId,
                lastSeenAt: lastSeenAt,
                lastReplyAt: lastReplyAt,
                lastError: credentialUnavailable ? DeviceSecretKeychain.Failure.unavailable.localizedDescription
                    : lastError ?? (cfg == nil ? "No bot token saved — paste one to enable." : nil)
            ),
            configuration: TelegramConfigurationSummary(
                config: cfg, model: resolvedTelegramBrain.model,
                reasoningEffort: resolvedTelegramBrain.reasoningEffort
            ),
            pollBackoffFailures: pollBackoffFailures,
            lastPollAt: lastPollAt,
            lastDiagnosticsClearedAt: lastDiagnosticsClearedAt,
            voiceTranscription: voiceStatus,
            receipts: [], blocked: [], errors: []
        )
    }

    nonisolated private func telegramDiagnosticFeed<Row: Decodable>(
        path: URL,
        limit: Int
    ) async -> TelegramDiagnosticFeedRead<Row> {
        do {
            let receipt = try await SwiftNativePersistenceCore().tailJSONLReadReceipt(
                path,
                limit: limit,
                maxBytes: 1_048_576
            )
            let decoder = JSONDecoder.nativeAgent
            var rows: [Row] = []
            var undecodableSchemaRows = 0
            for raw in receipt.rows {
                guard let data = try? raw.serializedData(pretty: false),
                      let row = try? decoder.decode(Row.self, from: data) else {
                    undecodableSchemaRows += 1
                    continue
                }
                rows.append(row)
            }

            var warnings: [String] = []
            let unreadableCount = receipt.malformedJSONRowCount + undecodableSchemaRows
            if unreadableCount > 0 {
                warnings.append("\(unreadableCount) unreadable diagnostic \(unreadableCount == 1 ? "row was" : "rows were") omitted from this panel.")
            }
            if receipt.truncatedToByteWindow {
                warnings.append("Only the newest bounded portion of this diagnostic feed was read; older entries are not shown.")
            }
            return TelegramDiagnosticFeedRead(rows: rows, issue: warnings.isEmpty ? nil : warnings.joined(separator: " "))
        } catch {
            return TelegramDiagnosticFeedRead(
                rows: [],
                issue: "This diagnostic feed is unavailable and was not treated as empty."
            )
        }
    }
}

private struct TelegramDiagnosticFeedRead<Row> {
    let rows: [Row]
    let issue: String?
}
