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
// Blueprint: | `EngineDoctorRepairs.swift` | EngineDoctorRuntime selects and executes owner repairs, persists compatible receipts and retains the search-backend absence marker |

extension EngineDoctorRuntime {
    /// An absent backend keeps Docker Desktop closed until the URL changes or Repair is pressed.
    private var searchBackendAbsentPath: URL {
        dataRoot
            .appendingPathComponent("doctor/search_backend_absent.json")
    }

    public func doctorSearchBackendAbsent(base: String) -> Bool {
        guard let data = try? Data(contentsOf: searchBackendAbsentPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["base"] as? String == base
    }

    public func doctorRecordRepair(checkID: String, receipt: String, status: String) async throws {
        let path = dataRoot
            .appendingPathComponent("doctor/repair_receipts.jsonl")
        try await SwiftNativePersistenceCore.appendJSONL(.object([
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "check_id": .string(checkID), "receipt": .string(receipt), "status": .string(status),
        ]), to: path)
    }

    public func doctorLiveRepair(for check: CheckResult, scope: DoctorRepairScope) async -> DoctorExecutableRepair? {
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
            switch try? await DoctorProviderPathReading.read(dataRoot: requestedRoot).runtime {
            case .some(.healthy(.stale)), .some(.healthy(.failed)): needsProbe = true
            default: needsProbe = false
            }
            guard pendingSelection || needsProbe else { return nil }
            if !pendingSelection {
                guard let snapshot = try? await SwiftNativeProviderRouting(dataRoot: requestedRoot)
                    .checkedRoutingSnapshotReadOnly(),
                    ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, "chat") != nil else { return nil }
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
                    let test = try await ProvidersFacade(dataRoot: requestedRoot).testProvider(providerID)
                    // Same verdict the Providers page uses for Test Connection.
                    guard test.tested && test.status == "ok" else {
                        return .unverified("Repair attempted: the \(providerID) connection test did not pass: \(Self.safeDetail(test.detail ?? test.error ?? test.status))")
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
            guard let base = (try? await doctorSearchURL())?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !base.isEmpty else { return nil }
            let mayOpenDockerDesktop = scope == .button || !doctorSearchBackendAbsent(base: base)
            let absentPath = searchBackendAbsentPath
            return DoctorExecutableRepair(checkID: check.id) {
                let research = SwiftNativeResearchClient(dataRoot: requestedRoot)
                // A SearXNG already answering (common port or running
                // container) becomes the search URL.
                let found = try await research.autodetectSearXNG()
                if found.found, let url = found.baseURL {
                    try? FileManager.default.removeItem(at: absentPath)
                    return .completed("Completed: SearXNG answers at \(url); search now uses it.")
                }
                // Otherwise start the stopped local container behind the configured URL.
                let container: String
                do {
                    container = try await SystemDockerPSExecutor()
                        .startLocalSearXNG(base: base, mayOpenDockerDesktop: mayOpenDockerDesktop)
                } catch let error as SearXNGStartError where error.noBackend {
                    try await SwiftNativePersistenceCore.writeJSON(.object([
                        "base": .string(base), "at": .string(ISO8601DateFormatter().string(from: Date())),
                    ]), to: absentPath)
                    return .unverified("No search backend: nothing answers at \(base). \(error.message)")
                } catch {
                    return .unverified("Web search is down: nothing answers at \(base). \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: absentPath)
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                repeat {
                    try await Task.sleep(for: .seconds(2))
                    if await research.checkSearXNG(base: base) {
                        return .completed("Completed: started the local SearXNG container \(container.prefix(12)); search answers at \(base).")
                    }
                } while ContinuousClock.now < deadline
                return .unverified("Started the local SearXNG container \(container.prefix(12)), but \(base) did not answer within 30 seconds.")
            }
        case "live.telegram":
            guard let state = try? await doctorTelegramSnapshot(), state.enabled,
                  state.tokenConfigured, !state.pollerEnabled else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                let facade = TelegramFacade(dataRoot: dataRoot)
                let manager = port.doctorManager
                // The poll notice and the state file it then clears both wake the check.
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
                // Observe the owner's ordinary bounded long poll, never send
                // a second getUpdates request or force a duplicate tick.
                let result = await raceAgainstTimeout(seconds: 35) {
                    var iterator = events.makeAsyncIterator()
                    repeat {
                        try Task.checkCancellation()
                        let after = try await facade.loadStatus(manager: manager)
                        try Task.checkCancellation()
                        if after.lastPollAt != nil, after.lastPollAt != before.lastPollAt,
                           after.pollerEnabled, after.actionableError == nil { return true }
                    } while await iterator.next() != nil
                    return false
                }
                if case .value(true) = result {
                    return .completed("Completed: restarted Telegram's poller and confirmed a successful poll.")
                }
                if case .failure(let detail) = result { throw TelegramBotError.underlying(detail) }
                if case .cancelled = result { throw CancellationError() }
                return .unverified("Repair attempted: Telegram's poller was started, but no successful poll was confirmed within 35 seconds.")
            }
        case "live.bridges":
            let names = await doctorBridgeSnapshots().filter {
                $0.expected && $0.health.boundPort == nil && !$0.health.isActive
            }.map(\.name)
            guard !names.isEmpty else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                // The bridges publish their descriptors from their ready callbacks.
                // Watch those existing transitions, then read authoritative listener health.
                let changes = FileChangeEvents(paths: [
                    AgentHostDirectory.bridgeDiscoveryDirectory(dataRoot: dataRoot).appendingPathComponent("bridge.json"),
                    dataRoot.appendingPathComponent("browser_ipc.json"),
                ])
                defer { changes.cancel() }
                await changes.waitUntilArmed()
                try Task.checkCancellation()
                // Start methods retain their own gates, callbacks and tokens.
                for name in names {
                    try Task.checkCancellation()
                    await port.doctorStartBridge(name: name)
                }
                try Task.checkCancellation()
                let result = await raceAgainstTimeout(seconds: 3) {
                    var iterator = changes.stream.makeAsyncIterator()
                    repeat {
                        try Task.checkCancellation()
                        let rows = await doctorBridgeSnapshots().filter { names.contains($0.name) }
                        try Task.checkCancellation()
                        if rows.allSatisfy({ $0.health.boundPort != nil }) { return true }
                    } while await iterator.next() != nil
                    return false
                }
                if case .value(true) = result {
                    return .completed("Completed: rebound \(names.joined(separator: ", ")) and verified the listening ports.")
                }
                if case .cancelled = result { throw CancellationError() }
                return .unverified("Repair attempted: \(names.joined(separator: ", ")) did not confirm a bound port within 3 seconds.")
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
