import TrustPersistence
import AppToolRuntime
import Cognition
import Foundation
import NativeAgentShared
import Observation
import PersistenceCore
import TrustCenter
import MacControl
import NativeAgentCore
import Privacy
// Blueprint: | `EngineTrust.swift` | TrustFacade owns checked policy, effective feature verdicts and security status/invalidation; raw/typed policy and phone serialization publish through LatestRead, committed policy through write. Catalog/source/install/network publication, Privacy Map and inbox policy each share a LatestRead; catalog/inbox commits use write. Policy derives autonomy guardrails; connected-agent rows belong to engine.contacts. Rooted Mac audit decoding retains availability and canonical/legacy receipt fields. |

/// Root-specific audit read availability and canonical/legacy receipt decoding.
public struct MacControlAuditEntry: Identifiable, Decodable, Sendable {
    // Identifiable row id: stable per row but built from receiptID when
    // present so rows are deduped reliably in the List.
    public var id: String { receiptID ?? "\(ts)-\(method)" }

    var receiptID: String?
    var method: String
    var category: String?
    var argsHash: String?
    var trigger: String?
    var triggerSource: String?
    var approvalRequired: Bool?
    var approved: Bool?
    var exitCode: Int?
    var stdout: String?
    var stderr: String?
    var durationMs: Int?
    var executedAt: String?
    var blocked: Bool?
    var blockReason: String?

    public var ts: String
    public var action: String
    public var detail: String?
    public var allowed: Bool?

    enum CodingKeys: String, CodingKey {
        // Canonical (snake_case on disk).
        case receiptID = "id"
        case method
        case category
        case argsHash = "args_hash"
        case trigger
        case triggerSource = "trigger_source"
        case approvalRequired = "approval_required"
        case approved
        case exitCode = "exit_code"
        case stdout
        case stderr
        case durationMs = "duration_ms"
        case executedAt = "executed_at"
        case blocked
        case blockReason = "block_reason"
        // Legacy fields some pre-cutover rows may still carry.
        case ts
        case action
        case detail
        case allowed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Canonical fields.
        receiptID = try c.decodeIfPresent(String.self, forKey: .receiptID)
        let decodedMethod = try c.decodeIfPresent(String.self, forKey: .method)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        argsHash = try c.decodeIfPresent(String.self, forKey: .argsHash)
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
        triggerSource = try c.decodeIfPresent(String.self, forKey: .triggerSource)
        approvalRequired = try c.decodeIfPresent(Bool.self, forKey: .approvalRequired)
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        stdout = try c.decodeIfPresent(String.self, forKey: .stdout)
        stderr = try c.decodeIfPresent(String.self, forKey: .stderr)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        executedAt = try c.decodeIfPresent(String.self, forKey: .executedAt)
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked)
        blockReason = try c.decodeIfPresent(String.self, forKey: .blockReason)

        // UI summary fields, synthesized from canonical if missing.
        ts = try c.decodeIfPresent(String.self, forKey: .ts)
            ?? executedAt
            ?? ""
        let legacyAction = try c.decodeIfPresent(String.self, forKey: .action)
        method = decodedMethod ?? legacyAction ?? ""
        action = legacyAction ?? decodedMethod ?? "unknown"
        // Empty canonical `block_reason` must not hide stderr when deriving historical receipt detail.
        let decodedDetail = try c.decodeIfPresent(String.self, forKey: .detail)
        detail = Self.firstNonEmpty(decodedDetail, blockReason, stderr)
        if let explicit = try c.decodeIfPresent(Bool.self, forKey: .allowed) {
            allowed = explicit
        } else if let b = blocked {
            allowed = !b
        } else {
            allowed = nil
        }
    }

    /// Pick the first non-nil, non-empty string. Treats `""` as absent so the
    /// canonical-row pattern `block_reason: ""` (successful execution rows)
    /// doesn't mask a useful `stderr` underneath.
    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for c in candidates {
            if let s = c, !s.isEmpty { return s }
        }
        return nil
    }

}

public enum MacControlAuditLogRead: Sendable {
    case entries([MacControlAuditEntry], malformedLineCount: Int)
    case sourceAbsent(URL)
    case unreadable(String)

    fileprivate static func read(from url: URL, limit: Int = 100) -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .sourceAbsent(url) }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var malformed = 0
            let entries = content
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line -> MacControlAuditEntry? in
                    guard let data = line.data(using: .utf8) else {
                        malformed += 1
                        return nil
                    }
                    do {
                        return try JSONDecoder().decode(MacControlAuditEntry.self, from: data)
                    } catch {
                        malformed += 1
                        return nil
                    }
                }
            return .entries(Array(entries.suffix(limit).reversed()), malformedLineCount: malformed)
        } catch {
            return .unreadable(UserFacingError.cause(error, action: "read the audit log"))
        }
    }
}


/// `NativeAgentEngine.trust`: the TrustCenter for one data root, in core
/// types. The Trust Center pages, Setup, chat and the badges render `policy`;
/// Backups render `backups`; Capabilities renders `capabilityNetwork`. Reads
/// and publication use the same owner for the phone lanes. Policy writes still
/// run through the one trust-write chokepoint (`TrustPolicyToolWriter`)
/// and backups through the backup executors.
@MainActor
@Observable
public final class TrustFacade {
    public nonisolated let dataRoot: URL
    private nonisolated let connectorActionStatuses: (@Sendable () async throws -> [String: String])?

    /// The saved policy as of the last read or write.
    public private(set) var policy: TrustPolicy? {
        didSet { policyDidChange?() }
    }
    @ObservationIgnored public var policyDidChange: (@MainActor () -> Void)?
    /// Effective switches from the same checked policy the rest of Trust renders.
    /// Absence means unavailable, never a manufactured default permission.
    public struct FeatureVerdict: Sendable {
        public let enabled: Bool
        public let forced: Bool
    }
    public var unattendedWork: FeatureVerdict? {
        policy.map(Self.unattendedWork(for:))
    }
    private nonisolated static func unattendedWork(for policy: TrustPolicy) -> FeatureVerdict {
        let forced = TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy)
        return FeatureVerdict(enabled: policy.enableAutonomy || forced, forced: forced)
    }
    public var deskTasks: FeatureVerdict? {
        guard let policy else { return nil }
        if policy.developerMode { return FeatureVerdict(enabled: true, forced: true) }
        return (policy.workshopPolicy?.enabled).map { FeatureVerdict(enabled: $0, forced: false) }
    }
    public var memoryPermissions: TrustMemoryPolicy? { policy?.memoryPolicy }

    public private(set) var securityStatus: SecurityCenterStatus?
    public private(set) var isRefreshingSecurity = false
    public private(set) var securityRefreshError: String?
    @ObservationIgnored private var securityRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var securityRefreshRequested = false
    @ObservationIgnored private lazy var policyRead = LatestRead()

    public func publishPolicy(_ saved: TrustPolicy?) {
        policyRead.write {
            policy = saved
            securityStatus = nil
        }
    }

    private func readPolicy() async -> Result<[String: JSONValue], Error> {
        let result = await policyRead.read({
            let checked: Result<[String: JSONValue], Error>
            do { checked = .success(try await center.loadTrustPolicyChecked()) }
            catch { checked = .failure(error) }
            let status: Result<SecurityCenterStatus, Error>
            do {
                status = .success(try await SwiftNativeSecurityCenter(dataRoot: dataRoot).status(policy: checked, limit: 10))
            } catch {
                status = .failure(error)
            }
            return (checked, status)
        }, publish: { checked, status in
            policy = try? TrustPolicy(policyObject: checked.get())
            switch status {
            case .success(let value):
                securityStatus = value
                securityRefreshError = nil
            case .failure(let error):
                securityRefreshError = UserFacingError.cause(error, action: "read security status")
            }
        })
        return result.0
    }

    /// Policy, its effective switches and Security Center share one invalidation
    /// boundary and one checked policy generation. The view holds no snapshot.
    public func observeSecurity() async {
        await EventDeadlinePhysiology.refreshOnChanges(paths:
            ["trust/policy.json", "security/audit.jsonl", "telegram/config.json", "paired_phones.json"]
                .map { dataRoot.appendingPathComponent($0) }
                + [TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)]
        ) { await self.refreshSecurity() }
    }

    public func refreshSecurity() async {
        if let securityRefreshTask {
            securityRefreshRequested = true
            await securityRefreshTask.value
            return
        }
        isRefreshingSecurity = true
        let task = Task { @MainActor in
            defer {
                isRefreshingSecurity = false
                securityRefreshTask = nil
            }
            repeat {
                securityRefreshRequested = false
                _ = await readPolicy()
            } while securityRefreshRequested
        }
        securityRefreshTask = task
        await task.value
    }

    /// Local backups, newest first, as of the last read.
    public var backups: [BackupRecord] = []
    public private(set) var capabilityCatalog: [CapabilityCatalogItem] = []
    public private(set) var capabilityCatalogSources: [CapabilityCatalogSource] = []
    public private(set) var capabilityPackInstalls: [CapabilityPackInstall] = []
    public private(set) var catalogRefresh: PanelRefreshStatus?
    public var autonomyKernel: AutonomyKernelSummary? { policy.map(Self.autonomyKernel(for:)) }

    public var capabilityNetwork: CapabilityTrustNetwork?
    public private(set) var capabilitySummary: CapabilitySummaryResponse?
    public private(set) var capabilitySummaryError: String?
    public private(set) var privacyMap: PrivacyMap?

    public func refreshPrivacyMap() async {
        let root = dataRoot
        _ = await privacyRead.read({
            await Task.detached(priority: .utility) {
                PrivacyMap(dataRoot: root, generatedAt: SwiftNativeManifestSigner.isoTimestamp(Date()))
            }.value
        }, publish: { privacyMap = $0 })
    }
    @ObservationIgnored private let privacyRead = LatestRead()
    @ObservationIgnored private let catalogRead = LatestRead()

    public func refreshCapabilityCatalog() async -> [(endpoint: String, label: String, error: Error)] {
        let read = await catalogRead.read({
            var summary: CapabilitySummaryResponse?
            var items: [CapabilityCatalogItem]?
            var sources: [CapabilityCatalogSource]?
            var installs: [CapabilityPackInstall]?
            var network: CapabilityTrustNetwork?
            var failures: [(endpoint: String, label: String, error: Error)] = []
            do { summary = try await loadCapabilities() }
            catch { failures.append(("capability summary", "getCapabilities", error)) }
            do { items = try await catalog() }
            catch { failures.append(("capability catalog", "getCapabilityCatalog", error)) }
            do { sources = try await catalogSources() }
            catch { failures.append(("catalog sources", "getCapabilityCatalogSources", error)) }
            do { installs = try await packInstalls() }
            catch { failures.append(("pack installs", "getCapabilityPackInstalls", error)) }
            do { network = try await loadCapabilityNetwork() }
            catch { failures.append(("capability trust", "getCapabilityTrust", error)) }
            return (summary, items, sources, installs, network, failures)
        }, publish: { read in
            if let value = read.0 { capabilitySummary = value }
            capabilitySummaryError = read.5.first { $0.endpoint == "capability summary" }?.error.localizedDescription
            if let value = read.1 { capabilityCatalog = value }
            if let value = read.2 { capabilityCatalogSources = value }
            if let value = read.3 { capabilityPackInstalls = value }
            if let value = read.4 { capabilityNetwork = value }
            catalogRefresh = PanelRefreshStatus(lastAttemptAt: Date(),
                lastSuccessAt: read.5.isEmpty ? Date() : catalogRefresh?.lastSuccessAt,
                failedEndpoints: read.5.map { $0.endpoint })
        })
        return read.5
    }
    public private(set) var inboxPolicyEnabled = false
    public private(set) var inboxPolicyError: Error?
    public private(set) var hasReadInboxPolicy = false
    @ObservationIgnored private let inboxPolicyRead = LatestRead()

    /// Observe policy publication, then read the checked local authority.
    /// SecurityCenter has no per-tool Full Mac admission to copy or retain.
    public var nativeActionYoloAdmitted: Bool {
        _ = policy
        return SwiftNativeSecurityCenter.localFullMacYoloAdmitted(dataRoot: dataRoot)
    }

    public nonisolated init(
        dataRoot: URL,
        // Policy-only readers need no connector binding. Capability reads do.
        connectorActionStatuses: (@Sendable () async throws -> [String: String])? = nil
    ) {
        self.dataRoot = dataRoot
        self.connectorActionStatuses = connectorActionStatuses
    }

    public nonisolated func notify(
        title: String, message: String, notificationCenterAdapter: any NotificationPosting
    ) async throws -> Bool {
        try await runMacControl(action: .notify, body: [
            "title": .string(title), "message": .string(message),
        ], notificationCenterAdapter: notificationCenterAdapter).ok
    }

    public nonisolated func runMacControl(
        action: MacControlWorkbenchAction, body: [String: JSONValue], notificationCenterAdapter: any NotificationPosting
    ) async throws -> MacControlResult {
        let client = makeMacControl(
            policyProvider: TrustCenterMacControlPolicyProvider(
                dataRoot: dataRoot, operatorOrigin: SecurityOriginContext(surface: "native_actions")),
            auditAppendPath: MacControlActionRoutes.auditPath(dataRoot: dataRoot),
            notificationCenterAdapter: notificationCenterAdapter
        )
        return try await client.dispatch(action: action.rawValue, body: body)
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
            connectorActionStatuses: connectorActionStatuses
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
        var identities: Set<String> = []
        for record in records {
            guard !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuntimeReadError.unreadableFeed("The capability list does not add up (one or more entries have no stable id). Refresh before relying on it.")
            }
            guard identities.insert(record.id).inserted else {
                throw RuntimeReadError.unreadableFeed("The capability list does not add up (the list contains duplicate ids). Refresh before relying on it.")
            }
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
    public func load() async throws -> TrustPolicy {
        let checked = await readPolicy()
        return try TrustPolicy(policyObject: checked.get())
    }

    public nonisolated func auditLog(limit: Int = 100) async -> MacControlAuditLogRead {
        let path = MacControlActionRoutes.auditPath(dataRoot: dataRoot)
        return await Task.detached(priority: .utility) {
            MacControlAuditLogRead.read(from: path, limit: limit)
        }.value
    }

    /// The raw checked policy, for blocks the typed model does not name
    /// (inboxPolicy).
    public nonisolated func rawPolicy() async throws -> [String: JSONValue] {
        try await readPolicy().get()
    }

    /// The phone receives every checked field and the same resolved Trust
    /// interpretation as the Mac, from this read's own policy generation.
    public nonisolated func snapshotData() async throws -> Data {
        var snapshot = try await rawPolicy()
        let policy = try TrustPolicy(policyObject: snapshot)
        let accessMode = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy)
        snapshot["resolvedPreset"] = MobileTrustAction.Preset.matching(policy: policy, accessMode: accessMode)
            .map { .string($0.rawValue) } ?? .null
        snapshot["effectivePermissionLevel"] = .string(
            TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy) ? "full_mac_os" : policy.permissionLevel)
        return try JSONValue.object(snapshot).serializedData(pretty: false)
    }

    /// Read both `index.json` and historical `registry.json`, deduplicated by id, newest first.
    public nonisolated func listBackups() async throws -> [BackupRecord] {
        try TrustBackupPersistence.readBackupRecords(root: dataRoot)
    }

    @ObservationIgnored private let backupsRead = LatestRead()

    @discardableResult
    public func refreshBackups() async throws -> [BackupRecord] {
        try await backupsRead.read({ try await listBackups() }, publish: { backups = $0 })
    }

    /// The capability trust network: roots, catalog sources and one trust
    /// record per capability.
    public nonisolated func loadCapabilityNetwork() async throws -> CapabilityTrustNetwork {
        try await capabilityTrust().network()
    }

    public nonisolated func evaluateCapability(id: String) async throws -> CapabilityTrustEvaluation {
        try await capabilityTrust().evaluate(capabilityId: id)
    }

    nonisolated private func capabilityTrust() throws -> SwiftNativeCapabilityTrust {
        guard let connectorActionStatuses else { throw CapabilityTrustError.unavailable }
        return SwiftNativeCapabilityTrust(
            dataRoot: dataRoot, connectorActionStatuses: connectorActionStatuses
        )
    }
}

// MARK: - Capability catalog

extension TrustFacade {
    public func observeInboxPolicy() async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: [SavedTrustPolicyAuthority.policyURL(dataRoot: dataRoot)]) {
            do { _ = try await self.inboxEnabled() }
            catch { print("[inbox settings] \(error.localizedDescription)") }
        }
    }

    /// The capability catalog: saved rows merged with the built-in defaults.
    /// Read-only; the merge is never written back.
    public nonisolated func catalog() async throws -> [CapabilityCatalogItem] {
        try await listCapabilityCatalog(dataRoot: dataRoot).map { try CapabilityCatalogItem(row: .object($0)) }
    }

    public func refreshCatalogSources() async throws {
        let result: Result<[CapabilityCatalogSource], Error> = await catalogRead.read({
            do { return .success(try await catalogSources()) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let sources):
                capabilityCatalogSources = sources
                catalogRefresh?.failedEndpoints.removeAll { $0 == "catalog sources" }
            case .failure:
                catalogRefresh = PanelRefreshStatus(lastAttemptAt: Date(),
                    lastSuccessAt: catalogRefresh?.lastSuccessAt, failedEndpoints: ["catalog sources"])
            }
        })
        _ = try result.get()
    }

    /// Catalog sources, defaults overlaid on the saved store. Missing state
    /// reads as the defaults; a damaged store throws and is never rewritten.
    public nonisolated func catalogSources() async throws -> [CapabilityCatalogSource] {
        try CapabilityCatalogStoreReader.catalogSources(dataRoot: dataRoot).map { try CapabilityCatalogSource(row: .object($0)) }
    }

    /// Installed capability packs, newest first.
    public nonisolated func packInstalls() async throws -> [CapabilityPackInstall] {
        try await catalogWrites.listCapabilityPackInstalls().map { try CapabilityPackInstall(row: .object($0)) }
    }

    /// Add or update one catalog source under the sources lock, with its trace.
    public func saveCatalogSource(name: String, url: String, kind: String) async throws -> CapabilityCatalogSource {
        let saved = try CapabilityCatalogSource(row: .object(try await catalogWrites.upsertCatalogSource([
            "name": .string(name),
            "url": .string(url),
            "kind": .string(kind),
        ])))
        catalogRead.write {
            if let index = capabilityCatalogSources.firstIndex(where: { $0.id == saved.id }) {
                capabilityCatalogSources[index] = saved
            } else { capabilityCatalogSources.append(saved) }
        }
        return saved
    }

    nonisolated private var catalogWrites: SwiftNativeCatalogWrites {
        SwiftNativeCatalogWrites(dataRoot: dataRoot)
    }
}

extension TrustFacade {
    public func inboxEnabled() async throws -> Bool {
        let result: Result<Bool, Error> = await inboxPolicyRead.read({
            do {
                let object = try await rawPolicy()
                let enabled: Bool
                if case .object(let policy)? = object["inboxPolicy"], case .bool(let saved)? = policy["enabled"] {
                    enabled = saved
                } else { enabled = true }
                return .success(enabled)
            } catch { return .failure(error) }
        }, publish: { result in
            hasReadInboxPolicy = true
            switch result {
            case .success(let enabled): inboxPolicyEnabled = enabled; inboxPolicyError = nil
            case .failure(let error): inboxPolicyError = error
            }
        })
        return try result.get()
    }
    public func setInboxEnabled(_ enabled: Bool) async throws {
        _ = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
            body: ["inboxPolicy": ["enabled": enabled]], dataRoot: dataRoot)
        inboxPolicyRead.write {
            inboxPolicyEnabled = enabled
            inboxPolicyError = nil
            hasReadInboxPolicy = true
        }
    }
}

extension TrustFacade {
    public nonisolated static func autonomyKernel(for policy: TrustPolicy) -> AutonomyKernelSummary {
        let trustEnabled = policy.enableAutonomy
        let enabled = unattendedWork(for: policy).enabled
        let mode = policy.autonomyDefault ?? "supervised"
        let disabledReason: String? = {
            if !enabled { return "Trust Center autonomy is disabled" }
            return nil
        }()

        let outside = policy.filePolicy?.outsideWorkspaceDefault ?? "deny"
        let backupRequired = policy.filePolicy?.requireBackupBeforeWrite ?? true

        return AutonomyKernelSummary(
            status: enabled ? "ok" : "off",
            mode: mode,
            enabled: enabled,
            processEnabled: true,
            trustEnabled: trustEnabled,
            disabledReason: disabledReason,
            guardrails: [
                KernelGuardrail(
                    id: "trust.enableAutonomy",
                    title: "Saved autonomy switch",
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
            ],
            approvalClasses: [
                ApprovalClass(id: "external_send", title: "External sends", requiresApproval: true),
                ApprovalClass(id: "filesystem_write", title: "Filesystem writes", requiresApproval: true),
                ApprovalClass(id: "system_change", title: "System changes", requiresApproval: true),
                ApprovalClass(id: "safe_read", title: "Safe reads", requiresApproval: false),
            ],
            createdAt: SwiftNativeManifestSigner.isoTimestamp(Date())
        )
    }

}
