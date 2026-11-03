import Foundation
import Observation
import PersistenceCore
import ProviderRouting
import BackgroundLoops
import TelegramBot
import AppToolRuntime
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `EngineTelegram.swift` | `TelegramFacade.loadStatus` consumes one checked configuration/credential result and checked routing with distinct unavailable causes; `load` adds checked diagnostic feeds; `refresh` alone publishes through `LatestRead`, including diagnostic-clear readback; credential badges read TelegramPresentationSnapshot.tokenConfigured directly |

/// Mounted Telegram management state. The core owns configuration and transport
/// status; the facade adds bounded diagnostic feeds and the app's routing pick.
@MainActor
@Observable
public final class TelegramFacade {
    public nonisolated let dataRoot: URL
    public var status: TelegramPresentationSnapshot?
    @ObservationIgnored private let statusRead = LatestRead()

    @discardableResult
    public func refresh(manager: BackgroundLoopLifetimes = .shared) async throws -> TelegramPresentationSnapshot {
        try await statusRead.read({ try await load(manager: manager) }, publish: { status = $0 })
    }

    public nonisolated init(dataRoot: URL) { self.dataRoot = dataRoot }

    public nonisolated func toolStatusEnvelope() async throws -> JSONValue {
        let status = try await load()
        return status.toolStatusEnvelope(now: Date())
    }

    public nonisolated func load(manager: BackgroundLoopLifetimes = .shared,
                                 routingSnapshot: ProviderRoutingSnapshot? = nil) async throws -> TelegramPresentationSnapshot {
        var snapshot = try await loadStatus(manager: manager,
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

    public nonisolated func loadStatus(manager: BackgroundLoopLifetimes = .shared,
                                       routingSnapshot: ProviderRoutingSnapshot? = nil) async throws -> TelegramPresentationSnapshot {
        let read = await SwiftNativeTelegramBot.readTransportStatus(
            dataRoot: dataRoot, manager: manager)
        let cfg = try read.configuration.get()
        let telegramBrain: SurfacePreference?
        var routingIssue: String?
        do {
            let routing: ProviderRoutingSnapshot
            if let routingSnapshot {
                routing = routingSnapshot
            } else {
                routing = try await SwiftNativeProviderRouting(dataRoot: dataRoot)
                    .checkedRoutingSnapshot()
            }
            // Ask the owner to validate the saved route, including a named
            // group failure when Telegram inherits an unusable Chat pick.
            _ = try routing.routeAdmission(for: "telegram", choice: nil, inheritChat: false)
            telegramBrain = routing.preferences["telegram"]
        } catch LLMError.providerError(let issue) {
            telegramBrain = nil
            routingIssue = issue
        } catch {
            telegramBrain = nil
            routingIssue = error.localizedDescription
        }
        var snapshot = TelegramPresentationSnapshot(
            transport: read.status,
            configuration: TelegramConfigurationSummary(
                config: cfg, model: telegramBrain?.model,
                reasoningEffort: telegramBrain?.reasoningEffort
            ),
            pollBackoffFailures: read.pollBackoffFailures,
            lastPollAt: read.status.extras?.stringFields["lastPollAt"],
            lastDiagnosticsClearedAt: read.lastDiagnosticsClearedAt,
            voiceTranscription: read.voiceTranscription,
            receipts: [], blocked: [], errors: []
        )
        snapshot.credentialIssue = read.credentialError?.localizedDescription
        snapshot.routingIssue = routingIssue
        return snapshot
    }

    nonisolated private func telegramDiagnosticFeed<Row: Decodable>(
        path: URL,
        limit: Int
    ) async -> TelegramDiagnosticFeedRead<Row> {
        let read: (rows: [Row], malformedRows: Int, blankRows: Int, truncated: Bool, readFailed: Bool, failure: String?) =
            await RuntimeReadouts.tailJSONL(path: path, limit: limit)
        if read.readFailed {
            return TelegramDiagnosticFeedRead(
                rows: [],
                issue: "This diagnostic feed is unavailable and was not treated as empty."
            )
        }
        var warnings: [String] = []
        let unreadableCount = read.malformedRows + read.blankRows
        if unreadableCount > 0 {
            warnings.append("\(unreadableCount) unreadable diagnostic \(unreadableCount == 1 ? "row was" : "rows were") omitted from this panel.")
        }
        if read.truncated {
            warnings.append("Only the newest bounded portion of this diagnostic feed was read; older entries are not shown.")
        }
        return TelegramDiagnosticFeedRead(rows: read.rows, issue: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }
}

private struct TelegramDiagnosticFeedRead<Row> {
    let rows: [Row]
    let issue: String?
}
