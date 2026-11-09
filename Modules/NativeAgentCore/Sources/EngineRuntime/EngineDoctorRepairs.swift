import Foundation
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import BackgroundLoops
import PersistenceCore
import DoctorChecks
import BackgroundWork
import Cognition
import ProviderRouting
import MacControl
import Research
import AgentConversations
import TelegramBot
import Synchronization
// Blueprint: | `EngineDoctorRepairs.swift` | Owner repairs with receipts; search stays on its configured endpoint |

extension EngineDoctorRuntime {
    public func doctorRecordRepair(checkID: String, receipt: String, status: String) async throws {
        nativeLog("[Doctor repair] %@: %@; recheck=%@", checkID, receipt, status)
    }

    public func doctorLiveRepair(for check: CheckResult, scope: DoctorRepairScope) async -> DoctorExecutableRepair? {
        do { return try await checkedDoctorRepair(for: check, scope: scope) }
        catch { return DoctorExecutableRepair(checkID: check.id) { throw error } }
    }

    private func checkedDoctorRepair(for check: CheckResult, scope: DoctorRepairScope) async throws -> DoctorExecutableRepair? {
        guard check.ask == nil else { return nil }
        let requestedRoot = dataRoot
        guard requestedRoot.resolvingSymlinksInPath().standardizedFileURL
            == PersistenceCore.defaultDataRoot().resolvingSymlinksInPath().standardizedFileURL else { return nil }
        switch check.id {
        case "icloud_bridge_state":
            guard check.owner != .builder else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                await port.doctorRepairPhoneSync() ?? .unverified("Phone sync has no mounted transport; repair remains owed.")
            }
        case "live.memory":
            guard !check.detail.hasPrefix("quick_check on ") else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                try await SwiftNativeMemoryV2.shared.repairCanonicalAttachment()
                return .completed("Completed: attached the canonical memory store and reconciled its knowledge graph.")
            }
        case "live.providers":
            let pendingPath = requestedRoot.appendingPathComponent("providers/pending-surface-configuration.json")
            let pendingSelection = FileManager.default.fileExists(atPath: pendingPath.path)
            let needsProbe: Bool
            switch try await DoctorProviderPathReading.read(dataRoot: requestedRoot, turn: turn).runtime {
            case .healthy(.stale), .healthy(.failed): needsProbe = true
            default: needsProbe = false
            }
            guard pendingSelection || needsProbe else { return nil }
            if !pendingSelection {
                let snapshot = try await SwiftNativeProviderRouting(dataRoot: requestedRoot).checkedRoutingSnapshotReadOnly()
                guard ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, "chat") != nil else { return nil }
            }
            return DoctorExecutableRepair(checkID: check.id) {
                do {
                    let routing = SwiftNativeProviderRouting(dataRoot: requestedRoot)
                    let snapshot = try await (FileManager.default.fileExists(atPath: pendingPath.path)
                        ? routing.checkedRoutingSnapshot()
                        : routing.checkedRoutingSnapshotReadOnly())
                    guard let providerID = ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, "chat") else {
                        let row = await providerDoctorCoverageCheck()
                        return .unverified("Repair could not test the active provider: \(row.detail)")
                    }
                    let test = try await NativeAgentEngine.live.providers.testProvider(providerID)
                    // Share the Providers page’s connection-test verdict.
                    guard test.tested && test.status == "ok" else {
                        return .unverified(
                            "Repair attempted: the \(providerID) connection test did not pass: \(Self.safeDetail(test.detail ?? test.error ?? test.status))")
                    }
                    let row = await providerDoctorCoverageCheck()
                    return row.status == "ok"
                        ? .completed("Completed: recovered provider selection if needed and checked the active provider connection.")
                        : .unverified("Repair attempted: \(row.detail)")
                } catch {
                    let row = await providerDoctorCoverageCheck()
                    return .unverified("Repair could not finish: \(Self.safeDetail(error.localizedDescription)) \(row.detail)")
                }
            }
        case "live.inspector_feed":
            return await port.doctorInspectorRepair(for: check)
        case DoctorEmbeddingDownloadCheck.id:
            return await DoctorEmbeddingDownloadCheck.repair(dataRoot: requestedRoot, scope: scope)
        case "live.search":
            let mayOpenDockerDesktop = scope == .button
            return DoctorExecutableRepair(checkID: check.id) {
                let research = SwiftNativeResearchClient(dataRoot: requestedRoot)
                guard let base = try await doctorSearchURL(), !base.isEmpty else {
                    return .unverified("Search is not configured. Use Research setup to select a SearXNG address.")
                }
                do {
                    if try await research.checkSearXNG(base: base, answering: true) {
                        guard try await doctorSearchURL() == base else {
                            return .unverified("The previous search server at \(base) answers, but the configured address changed; its new address was kept.")
                        }
                        return .completed("Completed: the configured SearXNG answers at \(base).")
                    }
                } catch where Task.isCancelled || error is CancellationError { throw CancellationError() }
                catch {
                    return .unverified("The configured search at \(base) could not be checked: \(error.localizedDescription)")
                }
                guard try await doctorSearchURL() == base else {
                    return .unverified("Repair skipped: the configured search address changed.")
                }
                let container: String
                do {
                    container = try await SystemDockerPSExecutor()
                        .startLocalSearXNG(base: base, mayOpenDockerDesktop: mayOpenDockerDesktop)
                } catch where Task.isCancelled || error is CancellationError || error is ProcessRunCancellation { throw CancellationError() }
                catch {
                    return .unverified("Web search is down: nothing answers at \(base). \(error.localizedDescription)")
                }
                guard try await doctorSearchURL() == base else {
                    return .unverified("Started container \(container.prefix(12)) for \(base), but the search setting changed.")
                }
                guard try await research.checkSearXNG(base: base, answering: true) else {
                    return .unverified("Started container \(container.prefix(12)); \(base) refused the readiness request. Check the container's logs.")
                }
                guard try await doctorSearchURL() == base else {
                    return .unverified("Started container \(container.prefix(12)) for \(base), but the search setting changed.")
                }
                return .completed("Completed: started container \(container.prefix(12)); search answers at its configured address \(base).")
            }
        case "live.telegram":
            let state = try await doctorTelegramSnapshot()
            guard state.enabled, state.tokenConfigured, !state.pollerEnabled else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                let facade = TelegramFacade(dataRoot: dataRoot)
                let manager = port.doctorManager
                // Observe both poll notices and their cleared state file to catch completion.
                let events = EventDeadlinePhysiology.storeAndFileEvents(
                    paths: [dataRoot.appendingPathComponent("telegram/state.json")],
                    notifications: [TelegramLongPollSession.successfulPoll])
                let before = try await facade.loadStatus(manager: manager)
                try Task.checkCancellation()
                guard before.enabled, before.tokenConfigured else {
                    return .unverified("Repair skipped: Telegram configuration changed.")
                }
                let registered = await manager.registered()
                try Task.checkCancellation()
                if !registered.contains("telegram_poll") {
                    let outcome = await port.doctorRestartLoop(id: "telegram_poll")
                    try Task.checkCancellation()
                    guard outcome.didRestart else {
                        return .unverified("Repair failed: \(outcome.surfaceMessage ?? "Telegram poller could not restart.")")
                    }
                }
                _ = await manager.start()
                try Task.checkCancellation()
                // Observe the admitted poll instead of issuing a duplicate getUpdates request.
                var iterator = events.makeAsyncIterator()
                repeat {
                    try Task.checkCancellation()
                    let after = try await facade.loadStatus(manager: manager)
                    try Task.checkCancellation()
                    if let error = after.credentialIssue { throw TelegramBotError.underlying(error) }
                    if let error = after.routingIssue { throw TelegramBotError.underlying(error) }
                    if let error = after.actionableError { throw TelegramBotError.underlying(error) }
                    if after.lastPollAt != nil, after.lastPollAt != before.lastPollAt, after.pollerEnabled {
                        return .completed("Completed: restarted Telegram's poller and confirmed a successful poll.")
                    }
                } while await iterator.next() != nil
                try Task.checkCancellation()
                throw TelegramBotError.underlying("Telegram poll observation ended before a successful poll was confirmed.")
            }
        case "live.bridges":
            let names = await doctorBridgeSnapshots().filter {
                $0.expected && $0.health.boundPort == nil && !$0.health.isActive
            }.map(\.name)
            guard !names.isEmpty else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                // Ready callbacks publish bridge descriptors; observe those transitions before reading listener health.
                let changes = FileChangeEvents(paths: [
                    AgentHostDirectory.bridgeDiscoveryDirectory(dataRoot: dataRoot).appendingPathComponent("bridge.json"),
                    dataRoot.appendingPathComponent("browser_ipc.json"),
                ])
                defer { changes.cancel() }
                guard await changes.waitUntilArmed() else {
                    throw ToolFailureError("Bridge descriptor changes could not be observed. Repair remains unconfirmed.", effects: .none)
                }
                try Task.checkCancellation()
                // Start methods retain their own gates, callbacks and tokens.
                for name in names {
                    try Task.checkCancellation()
                    await port.doctorStartBridge(name: name)
                }
                try Task.checkCancellation()
                var iterator = changes.stream.makeAsyncIterator()
                repeat {
                    try Task.checkCancellation()
                    let rows = await doctorBridgeSnapshots().filter { names.contains($0.name) }
                    try Task.checkCancellation()
                    for row in rows {
                        if let failure = row.health.failure { throw ToolFailureError("\(row.name): \(failure)", effects: .unknown) }
                    }
                    if Set(rows.map(\.name)) == Set(names), rows.allSatisfy({ $0.health.boundPort != nil }) {
                        return .completed("Completed: rebound \(names.joined(separator: ", ")) and verified the listening ports.")
                    }
                } while await iterator.next() != nil
                try Task.checkCancellation()
                throw ToolFailureError("Bridge descriptor observation ended before listening ports were confirmed.", effects: .unknown)
            }
        case DoctorLoopHealth.doctorCheckID:
            return await DoctorLoopHealth.safeRepair(manager: port.doctorManager)
        case let id where id.hasPrefix(DoctorLoopRecovery.checkPrefix):
            return await DoctorLoopRecovery.repair(
                checkID: check.id,
                manager: port.doctorManager,
                dataRoot: requestedRoot,
                restart: { await port.doctorRestartLoop(id: $0) }
            )
        default: return await doctorCognitionRepair(for: check)
        }
    }
}
