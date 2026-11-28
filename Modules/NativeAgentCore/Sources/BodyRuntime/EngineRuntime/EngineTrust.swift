import Foundation
import NativeAgentShared
import Observation
import PersistenceCore
import DeskCore
import MacNerves
import NativeAgentCore
import SenseCore
// Blueprint: | `EngineTrust.swift` | Checked policy, audit and capability publication through canonical mutation owners |

/// Audit availability and receipt decoding must remain root-specific.
public struct MacControlAuditEntry: Identifiable, Decodable, Sendable {
    // Prefer receipt identity so List rows deduplicate reliably.
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
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        receiptID = try c.decode(String.self, forKey: .receiptID)
        let decodedMethod = try c.decode(String.self, forKey: .method)
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
        let decodedExecutionTime = try c.decode(String.self, forKey: .executedAt)
        executedAt = decodedExecutionTime
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked)
        blockReason = try c.decodeIfPresent(String.self, forKey: .blockReason)

        // Derive summaries only from required canonical evidence.
        ts = decodedExecutionTime
        method = decodedMethod
        action = method
        // Empty canonical `block_reason` must not hide receipt stderr.
        detail = Self.firstNonEmpty(blockReason, stderr)
        if let b = blocked {
            allowed = !b
        } else {
            allowed = nil
        }
    }

    /// Treat empty strings as absent so a successful row’s empty block reason cannot hide useful stderr.
    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for c in candidates {
            if let s = c, !s.isEmpty { return s }
        }
        return nil
    }

}

public enum MacControlAuditLogRead: Sendable {
    case entries([MacControlAuditEntry], malformedLineCount: Int)
    case unreadable(String)

    fileprivate static func read(dataRoot: URL, limit: Int = 100) async -> Self {
        do {
            let details = try await ExperienceStore.at(dataRoot).details(.init(kinds: ["mac.act.audit"], limit: limit, newestFirst: true))
            var malformed = 0
            let entries = details
                .compactMap { detail -> MacControlAuditEntry? in
                    do {
                        return try JSONDecoder().decode(MacControlAuditEntry.self, from: detail.row)
                    } catch {
                        malformed += 1
                        return nil
                    }
                }
            return .entries(entries, malformedLineCount: malformed)
        } catch {
            return .unreadable(UserFacingError.cause(error, action: "read the audit log"))
        }
    }
}


/// Share one root’s checked Trust policy across surfaces and phone publication; retain `TrustPolicyToolWriter` and backup executors as mutation owners.
@MainActor
@Observable
public final class TrustFacade {
    public nonisolated let dataRoot: URL
    private nonisolated let connectorActionStatuses: (@Sendable () async throws -> [String: String])?

    public private(set) var policy: TrustPolicy?
    public private(set) var policyReadError: String?
    /// Effects follow committed policy changes, never a checked read.
    @ObservationIgnored public var policyDidChange: (@MainActor () -> Void)?

    @ObservationIgnored private lazy var policyRead = LatestRead()
    @ObservationIgnored private var settingsFeed: SettingsFeedProjection?

    public func bindSettingsFeed(_ feed: SettingsFeedProjection) {
        settingsFeed = feed
        publishSettings()
    }

    private func publishSettings() { settingsFeed?.updateTrust(policy: policy, issue: policyReadError) }

    public func publishPolicy(_ saved: TrustPolicy?) {
        policyRead.write {
            policy = saved
            policyReadError = nil
            publishSettings()
        }
        policyDidChange?()
        Task { await capabilitiesDidChange?() }
    }

    private func readPolicy() async -> (raw: Result<[String: JSONValue], Error>, typed: Result<TrustPolicy, Error>) {
        var changed = false
        let result = await policyRead.read({
            let checked: Result<[String: JSONValue], Error>
            do { checked = .success(try await center.loadTrustPolicyChecked()) }
            catch { checked = .failure(error) }
            let typed: Result<TrustPolicy, Error> = await Task.detached(priority: .userInitiated) {
                Result { try TrustPolicy(policyObject: checked.get()) }
            }.value
            return (raw: checked, typed: typed)
        }, publish: { _, typed in
            switch typed {
            case .success(let value):
                if policy != value { policy = value; changed = true }
                if policyReadError != nil { changed = true }
                policyReadError = nil
            case .failure(let error):
                if policy != nil || policyReadError != error.localizedDescription { changed = true }
                policy = nil
                policyReadError = error.localizedDescription
            }
            publishSettings()
        })
        if changed { await capabilitiesDidChange?() }
        return result
    }

    public private(set) var capabilityCatalogSources: [CapabilityCatalogSource] = []
    public private(set) var catalogRefresh: PanelRefreshStatus?

    public var capabilityNetwork: CapabilityTrustNetwork?
    public internal(set) var latestCapabilityTrustEvaluation: CapabilityTrustEvaluation?
    @ObservationIgnored let capabilityEvaluationRead = LatestRead()
    @ObservationIgnored nonisolated(unsafe) private var abilityObserver: NotificationCenter.ObservationToken?
    @ObservationIgnored private var capabilityChangeTask: Task<Void, Never>?
    @ObservationIgnored private var capabilityChangeRequested = false
    @ObservationIgnored var capabilitiesDidChange: (@MainActor @Sendable () async -> Void)?
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
            var sources: [CapabilityCatalogSource]?
            var network: CapabilityTrustNetwork?
            var failures: [(endpoint: String, label: String, error: Error)] = []
            do { summary = try await loadCapabilities() }
            catch { failures.append(("capability summary", "getCapabilities", error)) }
            do { sources = try await catalogSources() }
            catch { failures.append(("catalog sources", "getCapabilityCatalogSources", error)) }
            do { network = try await loadCapabilityNetwork() }
            catch { failures.append(("capability trust", "getCapabilityTrust", error)) }
            return (summary, sources, network, failures)
        }, publish: { read in
            if let value = read.0 { capabilitySummary = value }
            capabilitySummaryError = read.3.first { $0.endpoint == "capability summary" }?.error.localizedDescription
            if let value = read.1 { capabilityCatalogSources = value }
            if let value = read.2 { capabilityNetwork = value }
            catalogRefresh = PanelRefreshStatus(lastAttemptAt: Date(),
                lastSuccessAt: read.3.isEmpty ? Date() : catalogRefresh?.lastSuccessAt,
                failedEndpoints: read.3.map { $0.endpoint })
        })
        await capabilitiesDidChange?()
        return read.3
    }

    public nonisolated init(
        dataRoot: URL,
        // Only capability reads require connector binding.
        connectorActionStatuses: (@Sendable () async throws -> [String: String])? = nil
    ) {
        self.dataRoot = dataRoot
        self.connectorActionStatuses = connectorActionStatuses
        abilityObserver = NotificationCenter.default.addObserver(for: AbilityStore.DidChange.self) { [weak self] event in
            await self?.capabilitySourceChanged(event.path)
        }
    }

    isolated deinit {
        if let abilityObserver { NotificationCenter.default.removeObserver(abilityObserver) }
        capabilityChangeTask?.cancel()
    }

    private func capabilitySourceChanged(_ path: String) {
        let root = AbilityStore(dataRoot: dataRoot).root
        let changed = URL(fileURLWithPath: path)
        guard changed.path == root.path || changed.deletingLastPathComponent().path == root.path else { return }
        capabilityChangeRequested = true
        guard capabilityChangeTask == nil else { return }
        capabilityChangeTask = Task { [weak self] in
            guard let self else { return }
            defer { capabilityChangeTask = nil }
            repeat {
                capabilityChangeRequested = false
                _ = await refreshCapabilityCatalog()
            } while capabilityChangeRequested && !Task.isCancelled
        }
    }

    public func checkCapabilityTrust(id: String) async throws -> CapabilityTrustEvaluation {
        let evaluation = try await capabilityEvaluationRead.read({ try await evaluateCapability(id: id) }, publish: {
            latestCapabilityTrustEvaluation = $0
        })
        _ = await refreshCapabilityCatalog()
        return evaluation
    }

    public nonisolated func notify(
        title: String, message: String, notificationCenterAdapter: any NotificationPosting, turn: Turn
    ) async throws -> Bool {
        try await runMacControl(action: .notify, body: [
            "title": .string(title), "message": .string(message),
        ], notificationCenterAdapter: notificationCenterAdapter, turn: turn).ok
    }

    public nonisolated func runMacControl(
        action: MacControlWorkbenchAction, body: [String: JSONValue], notificationCenterAdapter: any NotificationPosting, turn: Turn
    ) async throws -> MacControlResult {
        let client = makeMacControl(
            policyProvider: TrustCenterMacControlPolicyProvider(
                dataRoot: dataRoot, operatorOrigin: SecurityOriginContext(surface: "native_actions")),
            auditDataRoot: dataRoot,
            notificationCenterAdapter: notificationCenterAdapter
        )
        return try await client.dispatch(action: action.rawValue, body: body, turn: turn, context: .init(dataRoot: dataRoot))
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
        let records = try rows.map { try CapabilityRecord(catalogRow: $0) }
        var active = 0
        let activeStatuses: Set<String> = ["active", "installed", "ready", "configured"]
        var identities: Set<String> = []
        for record in records {
            guard !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuntimeReadError.unreadableFeed(
                    "The capability list does not add up (one or more entries have no stable id). Refresh before relying on it.")
            }
            guard identities.insert(record.id).inserted else {
                throw RuntimeReadError.unreadableFeed("The capability list does not add up (the list contains duplicate ids). Refresh before relying on it.")
            }
            let status = (record.status ?? "").lowercased()
            if activeStatuses.contains(status) { active += 1 }
        }
        return CapabilitySummaryResponse(
            records: records,
            summary: CapabilityCounts(total: records.count, active: active)
        )
    }

    /// Damaged policy bytes must throw, never produce a typed default.
    public func load() async throws -> TrustPolicy {
        try await readPolicy().typed.get()
    }

    public nonisolated func auditLog(limit: Int = 100) async -> MacControlAuditLogRead {
        await MacControlAuditLogRead.read(dataRoot: dataRoot, limit: limit)
    }

    /// Read raw checked policy for fields outside the typed model, including inboxPolicy.
    public nonisolated func rawPolicy() async throws -> [String: JSONValue] {
        try await readPolicy().raw.get()
    }

    /// Phone fields and Trust interpretation must come from this read’s own checked generation.
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

    public nonisolated func listBackups() async throws -> [BackupRecord] {
        try TrustBackupPersistence.readBackupRecords(root: dataRoot)
    }

    @discardableResult
    public func refreshBackups() async throws -> [BackupRecord] {
        try await listBackups()
    }

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
    /// Missing catalog state has no saved rows; damaged bytes throw and remain unchanged.
    public nonisolated func catalogSources() async throws -> [CapabilityCatalogSource] {
        try CapabilityCatalogStoreReader.catalogSources(dataRoot: dataRoot).map { try CapabilityCatalogSource(row: .object($0)) }
    }
}

extension TrustFacade {
    public func inboxEnabled() async throws -> Bool {
        let object = try await rawPolicy()
        if case .object(let policy)? = object["inboxPolicy"], case .bool(let saved)? = policy["enabled"] {
            return saved
        }
        return true
    }
}

extension TrustFacade {
    public nonisolated static func autonomyKernel(for policy: TrustPolicy) -> AutonomyKernelSummary {
        let trustEnabled = policy.enableAutonomy
        let enabled = trustEnabled || TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy)
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
            ]
        )
    }

}
