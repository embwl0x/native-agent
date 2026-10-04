import TrustPersistence
import Foundation
import Observation
import MCPDispatcher
import PersistenceCore
import TrustCenter

/// `NativeAgentEngine.trust` (S10): the TrustCenter for one data root, in core
/// types. The Trust Center pages, Setup, chat and the badges render `policy`;
/// Backups render `backups`; Capabilities renders `capabilityNetwork`. Reads
/// are nonisolated so the phone lanes use the same owner. Policy writes still
/// run through the one trust-write chokepoint (`NativeClient.postTrustWrite`)
/// and backups through the backup executors.
@MainActor
@Observable
public final class TrustFacade {
    public nonisolated let dataRoot: URL
    private nonisolated let connectorActionStatuses: (@Sendable () async throws -> [String: String])?

    /// The saved policy as of the last read or write.
    public var policy: TrustPolicy? {
        didSet { policyDidChange?() }
    }
    @ObservationIgnored public var policyDidChange: (@MainActor () -> Void)?
    /// Local backups, newest first, as of the last read.
    public var backups: [BackupRecord] = []
    public var capabilityNetwork: CapabilityTrustNetwork?
    public var capabilitySummary: CapabilitySummaryResponse?

    public nonisolated init(
        dataRoot: URL,
        // Policy-only readers need no connector binding. Capability reads do.
        connectorActionStatuses: (@Sendable () async throws -> [String: String])? = nil
    ) {
        self.dataRoot = dataRoot
        self.connectorActionStatuses = connectorActionStatuses
    }

    nonisolated private var center: SwiftNativeTrustCenter {
        SwiftNativeTrustCenter(dataRoot: dataRoot)
    }

    public nonisolated func loadCapabilities() async throws -> CapabilitySummaryResponse {
        guard let connectorActionStatuses else { throw CapabilityTrustError.unavailable }
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let root = dataRoot
        let rows = try await capabilityRecordsFull(
            dataRoot: root, nowISO: nowISO,
            connectorActionStatuses: connectorActionStatuses,
            mcpServers: { try await listMCPServersAsDicts(dataRoot: root) }
        )
        var records: [CapabilityRecord] = []
        var firstError: Error?
        for row in rows {
            do { records.append(try CapabilityRecord(catalogRow: row)) }
            catch {
                if firstError == nil { firstError = error }
                print("[NativeAgent] getCapabilities(swiftNative) dropped a malformed element: \(error)")
            }
        }
        if records.isEmpty, let firstError { throw firstError }
        var byKind: [String: Int] = [:]
        var active = 0
        var review = 0
        var autoloaded = 0
        let activeStatuses: Set<String> = ["active", "installed", "ready", "configured"]
        let reviewStatuses: Set<String> = ["review", "proposal", "draft", "drafted", "needs_setup"]
        for record in records {
            byKind[record.kind ?? "", default: 0] += 1
            let status = (record.status ?? "").lowercased()
            if activeStatuses.contains(status) { active += 1 }
            if reviewStatuses.contains(status) { review += 1 }
            if record.autoload == true { autoloaded += 1 }
        }
        return CapabilitySummaryResponse(
            records: records,
            summary: CapabilityCounts(total: records.count, active: active, review: review,
                                      autoloaded: autoloaded, byKind: byKind),
            createdAt: nowISO
        )
    }

    /// The typed policy of one checked generation; damaged policy bytes throw.
    public nonisolated func load() async throws -> TrustPolicy {
        try await center.getTrust()
    }

    /// The raw checked policy, for blocks the typed model does not name
    /// (inboxPolicy).
    public nonisolated func rawPolicy() async throws -> [String: JSONValue] {
        try await center.loadTrustPolicyChecked()
    }

    /// The phone's trust_policy.json: the raw checked policy's bytes.
    public nonisolated func snapshotData() async throws -> Data {
        try await center.loadTrustPolicyJSON()
    }

    /// Both backup indexes (index.json, the daemon-era registry.json), deduped
    /// by id, newest first.
    public nonisolated func listBackups() async throws -> [BackupRecord] {
        try TrustBackupPersistence.readBackupRecords(root: dataRoot)
    }

    /// The capability trust network: roots, catalog sources and one trust
    /// record per capability.
    public nonisolated func loadCapabilityNetwork() async throws -> CapabilityTrustNetwork {
        try await capabilityTrust().network()
    }

    public nonisolated func evaluateCapability(id: String) async throws -> CapabilityTrustEvaluation {
        try await capabilityTrust().evaluate(capabilityId: id)
    }

    nonisolated private func capabilityTrust() throws -> any CapabilityTrustProtocol {
        guard let connectorActionStatuses else { throw CapabilityTrustError.unavailable }
        return makeCapabilityTrust(
            dataRoot: dataRoot, connectorActionStatuses: connectorActionStatuses,
            mcpServers: { [dataRoot] in
                try await listMCPServersAsDicts(dataRoot: dataRoot)
            }
        )
    }
}
