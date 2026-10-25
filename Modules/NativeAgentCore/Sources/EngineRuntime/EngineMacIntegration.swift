import Connectors
import Combine
import ChatToolRuntime
import DeviceSync
import Foundation
import MacControl
import MacIntegration
import NativeAgentCore
import Observation
import PersistenceCore
import TrustCenter
// Blueprint: | `EngineMacIntegration.swift` | `MacIntegrationFacade`: root-specific checked permissions, nonprompting OS grants and watch readiness publish through `LatestRead`; explicit Mail evidence shares the same owner and invalidation; Setup, Mac Integration, connector actions and quiet pages share these reads; permission-file and root-specific notifications invalidate the same owner; phone serialization uses its own returned checked permission result |

/// One root's checked Mac permissions, nonprompting OS grants and watch readiness.
@MainActor @Observable
public final class MacIntegrationFacade: LocalPIMStatusProvider, MacAssistantStatusClient {
    public nonisolated let dataRoot: URL
    private nonisolated let deviceSync: DeviceSync?
    private nonisolated let platform: any ConnectorStatusPlatform
    public var permissions: [String: MacIntegrationPermission] {
        if case .success(let snapshot)? = checkedPermissions { return snapshot.permissions }
        return [:]
    }
    public var permissionLoadError: String? {
        if case .failure(let error)? = checkedPermissions {
            return UserFacingError.message(error, action: "load the saved Mac Integration permissions")
        }
        return nil
    }
    public private(set) var isLoading = true
    public private(set) var systemStatuses: [String: String] = [:]
    public private(set) var watchState: MacAssistantWatchSetupLoadState = .loading
    public private(set) var isLoadingWatches = false
    public private(set) var checkedPermissions: Result<MacIntegrationPermissionStore.Snapshot, Error>?
    @ObservationIgnored private lazy var permissionRead = LatestRead()
    @ObservationIgnored private lazy var watchRead = LatestRead()
    @ObservationIgnored private var permissionObservation: AnyCancellable?
    @ObservationIgnored private var permissionWatcher: FileChangeWatcher?
    private var mailCheck: (status: String, word: String, next: String?)?

    public nonisolated init(dataRoot: URL, deviceSync: DeviceSync?, platform: any ConnectorStatusPlatform) {
        self.dataRoot = dataRoot
        self.deviceSync = deviceSync
        self.platform = platform
    }

    /// The existing permission signal belongs to this engine; the cancellable
    /// releases its observer with the facade. Writes identify their root.
    public func observePermissionChanges() {
        permissionObservation = NotificationCenter.default.publisher(for: SystemPermissionPreflight.permissionDidChange)
            .sink { [weak self] notification in
                let root = notification.object as? URL
                Task { @MainActor [weak self] in
                    if let self, root == nil || root?.standardizedFileURL == self.dataRoot.standardizedFileURL {
                        await self.refresh()
                    }
                }
            }
    }

    @discardableResult
    public func refresh(refreshWatches: Bool = true) async -> Result<MacIntegrationPermissionStore.Snapshot, Error> {
        if permissionWatcher == nil {
            permissionWatcher = FileChangeWatcher(paths: [dataRoot.appendingPathComponent("security/mac_integration_permissions.json")]) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        isLoading = true
        let (result, _) = await permissionRead.read {
            let result: Result<MacIntegrationPermissionStore.Snapshot, Error>
            do { result = .success(try await MacIntegrationPermissionStore(dataRoot: dataRoot).snapshotChecked()) }
            catch { result = .failure(error) }
            let statuses = await Task.detached(priority: .userInitiated) {
                ["speech_recognition": Self.badgeKey(SystemPermissionPreflight.status(.speechRecognition)),
                 "microphone": Self.badgeKey(SystemPermissionPreflight.status(.microphone)),
                 "calendar": LocalPIMConnectorActions.currentCalendarAuthorizationStatus(),
                 "reminders": LocalPIMConnectorActions.currentReminderAuthorizationStatus(),
                 "contacts": MacContactsExecutor.currentAuthorizationStatus(),
                 "accessibility": SystemPermissionPreflight.status(.accessibility).rawValue,
                 "screenRecording": SystemPermissionPreflight.status(.screenRecording).rawValue,
                 "fullDiskAccess": SystemPermissionPreflight.status(.fullDiskAccess).rawValue]
            }.value
            var grants = statuses
            for app in SystemAppleScriptAdapter.automationTargetApps {
                grants["apple_events_\(app.lowercased())"] = await SystemAppleScriptAdapter.automationStatus(app: app, ask: false)
            }
            return (result, grants)
        } publish: { result, grants in
            switch result {
            case .success(let snapshot):
                if permissions["mail"] != snapshot.permissions["mail"] { mailCheck = nil }
            case .failure:
                mailCheck = nil
            }
            checkedPermissions = result
            if systemStatuses["fullDiskAccess"] != grants["fullDiskAccess"]
                || systemStatuses["apple_events_mail"] != grants["apple_events_mail"] { mailCheck = nil }
            systemStatuses = grants
            isLoading = false
        }
        if refreshWatches, watchState.response != nil { await self.refreshWatches(refreshPermissions: false) }
        return result
    }

    public func macIntegrationPermissionsSnapshot() async throws -> [String: [String: Bool]] {
        let snapshot = try await refresh(refreshWatches: false).get()
        return snapshot.permissions.reduce(into: [:]) { projection, entry in
            var axes: [String: Bool] = [:]
            if MacIntegrationID.supportsRead(entry.key) { axes["read"] = entry.value.read }
            if MacIntegrationID.supportsWrite(entry.key) { axes["write"] = entry.value.write }
            projection[entry.key] = axes
        }
    }

    public func set(_ id: String, mode: MacIntegrationPermissionMode, allowed: Bool) async throws {
        do {
            try await MacIntegrationPermissionStore(dataRoot: dataRoot).set(
                integrationId: id, read: mode == .read ? allowed : nil, write: mode == .write ? allowed : nil)
            permissionRead.write {
                checkedPermissions = nil
                mailCheck = nil
            }
            await refresh()
        } catch {
            await refresh()
            throw error
        }
    }

    public func refreshWatches(refreshPermissions: Bool = true) async {
        // readWatches publishes a visible failure before throwing.
        _ = try? await readWatches(lightweight: false, refreshPermissions: refreshPermissions)
    }

    public nonisolated func macAssistantStatus(lightweight: Bool) async throws -> MacAssistantStatusResult {
        try await readWatches(lightweight: lightweight, refreshPermissions: true)
    }

    private func readWatches(lightweight: Bool, refreshPermissions: Bool) async throws -> MacAssistantStatusResult {
        isLoadingWatches = true
        let result = await watchRead.read {
            // The same checked snapshot and OS grants supply both pages.
            if refreshPermissions { await refresh(refreshWatches: false) }
            do {
                guard let deviceSync else { throw CocoaError(.featureUnsupported) }
                let client = makeMacAssistantStatusClient(
                    loadTrustPolicy: { [dataRoot] in await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy() },
                    proofs: NativeAppConnectorProofProvider(root: dataRoot, platform: platform),
                    push: NativeAppMobilePushStatusProvider(deviceSync: deviceSync),
                    dispatcherTools: StaticDispatcherToolAvailabilityProvider(availableTools: SwiftToolDispatcher.catalogRegisteredToolNames),
                    localPIM: self,
                    watchCatalog: { [dataRoot] in try await MacAssistantParts.watchCatalog(dataRoot: dataRoot) })
                let response = try await client.macAssistantStatus(lightweight: false)
                return Result<MacAssistantStatusResult, Error>.success(response)
            } catch {
                return .failure(error)
            }
        } publish: { result in
            switch result {
            case .success(let response): watchState = .current(response)
            case .failure(let error): watchState = watchState.afterFailure(UserFacingError.message(error, action: "refresh background watches"))
            }
            isLoadingWatches = false
        }
        return try result.get().projected(lightweight: lightweight)
    }

    public func checkMail() async {
        let evidence: (status: String, word: String, next: String?)
        do {
            evidence = MacAssistantStatusResult.mailReadiness(
                from: await MacAssistantParts.recover(try await MacAppleScriptBridge.mailListRecent(input: ["limit": .int(1)]), integration:"mail", dataRoot:dataRoot))
        } catch {
            evidence = ("failed", "Check failed", UserFacingError.cause(error, action: "check Mail"))
        }
        await refresh(refreshWatches: false)
        permissionRead.write { mailCheck = evidence }
        await refreshWatches(refreshPermissions: false)
    }

    public nonisolated func localStatuses() async -> [String: [String: JSONValue]] {
        await localStatusProjection()
    }

    private func localStatusProjection() -> [String: [String: JSONValue]] {
        let integrations = [("local_mail", "mail"), ("local_calendar", "calendar"), ("local_reminders", "reminders")]
        if case .failure(let error)? = checkedPermissions {
            return Dictionary(uniqueKeysWithValues: integrations.map { ($0.0, ["status": .string("unavailable"), "detail": .string(error.localizedDescription)]) })
        }
        return Dictionary(uniqueKeysWithValues: integrations.map { id, integration in
            if permissions[integration]?.read != true {
                return (id, ["status": .string("needs_policy"), "detail": .string("Read access is disabled in Mac Integrations."), "nextStep": .string("Enable read access in Mac Integrations.")])
            }
            if integration == "mail" {
                if let mailCheck {
                    var status = ["status": JSONValue.string(mailCheck.status)]
                    if let next = mailCheck.next { status["nextStep"] = .string(next) }
                    return (id, status)
                }
                return (id, [:])
            }
            return (id, LocalPIMConnectorActions.authorizationStatusPayload(localId: id, wizardStatus: systemStatuses[integration] ?? "unknown"))
        })
    }

    public nonisolated static func badgeKey(_ status: SystemPermissionStatus) -> String {
        status == .notDetermined ? "not_determined" : status.rawValue
    }
}

public enum MacAssistantWatchSetupLoadState: Equatable {
    case loading
    case current(MacAssistantStatusResult)
    case stale(MacAssistantStatusResult, message: String)
    case unavailable(message: String)

    public var response: MacAssistantStatusResult? {
        switch self {
        case .current(let response), .stale(let response, _): response
        case .loading, .unavailable: nil
        }
    }

    public var badgeStatus: String {
        switch self {
        case .loading: "unknown"
        case .current(let response): response.status
        case .stale: "attention"
        case .unavailable: "failed"
        }
    }

    public var diagnosticText: String? {
        switch self {
        case .stale(_, let message), .unavailable(let message): message
        case .loading, .current: nil
        }
    }

    func afterFailure(_ message: String) -> Self {
        guard let response else { return .unavailable(message: message) }
        return .stale(response, message: message)
    }
}
