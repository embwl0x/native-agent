import AppToolRuntime
import Connectors
import Combine
import ChatToolRuntime
import DeviceSync
import Foundation
import MacControl
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
import TrustCenter
import UserNotifications
// Blueprint: | `EngineMacIntegration.swift` | `MacIntegrationFacade`: root-specific checked permissions, nonprompting OS grants and watch readiness publish through `LatestRead`; Mail readiness accepts checked covered accounts with named gaps for status pages, card verification and transcript projections, publishing after refreshed grants and surviving Mail launch/quit; unreadable Trust policy marks its dependent watch access unavailable without hiding local integrations or phone readiness; scheduler names read the app declarations; Setup, Mac Integration, connector actions and quiet pages share these reads; permission-file and root-specific notifications invalidate the same owner; phone serialization uses its own returned checked permission result |

/// One root's checked Mac permissions, nonprompting OS grants and watch readiness.
@MainActor @Observable
public final class MacIntegrationFacade: MacAssistantStatusClient {
    public nonisolated let dataRoot: URL
    private nonisolated let deviceSync: DeviceSync?
    private nonisolated let platform: AppConnectorStatusPlatform
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

    public nonisolated init(dataRoot: URL, deviceSync: DeviceSync?, platform: AppConnectorStatusPlatform) {
        self.dataRoot = dataRoot
        self.deviceSync = deviceSync
        self.platform = platform
    }

    /// The existing permission signal belongs to this engine; the cancellable
    /// releases its observer with the facade. Writes identify their root.
    public func observePermissionChanges() {
        // The permission store posts from its own actor: hop to main before this
        // main-actor closure runs (a background call traps the isolation check).
        permissionObservation = NotificationCenter.default.publisher(for: SystemPermissionPreflight.permissionDidChange)
            .receive(on: DispatchQueue.main)
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
    public func refresh(refreshWatches: Bool = true, checkMail: Bool = false) async -> Result<MacIntegrationPermissionStore.Snapshot, Error> {
        if permissionWatcher == nil {
            permissionWatcher = FileChangeWatcher(paths: [dataRoot.appendingPathComponent("security/mac_integration_permissions.json")]) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        isLoading = true
        let (result, _, _) = await permissionRead.read {
            let result: Result<MacIntegrationPermissionStore.Snapshot, Error>
            do { result = .success(try await MacIntegrationPermissionStore(dataRoot: dataRoot).snapshotChecked()) }
            catch { result = .failure(error) }
            var mailEvidence: (status: String, word: String, next: String?)?
            if checkMail, case .success(let snapshot) = result, snapshot.permissions["mail"]?.read == true {
                do {
                    mailEvidence = MacAssistantStatusResult.mailReadiness(
                        from: await MacAssistantParts.recover(try await MacAppleScriptBridge.mailListRecent(input: ["limit": .int(1)]), integration:"mail", dataRoot:dataRoot))
                } catch {
                    mailEvidence = (status: "failed", word: "Check failed", next: UserFacingError.cause(error, action: "check Mail"))
                }
            }
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
            for app in AppleScriptExecution.automationTargetApps {
                grants[AppleScriptExecution.automationStatusKey(app: app)] = await AppleScriptExecution.automationStatus(app: app, ask: false)
            }
            return (result, grants, mailEvidence)
        } publish: { result, grants, mailEvidence in
            switch result {
            case .success(let snapshot):
                if permissions["mail"] != snapshot.permissions["mail"] { mailCheck = nil }
            case .failure:
                mailCheck = nil
            }
            checkedPermissions = result
            let mailAutomationKey = AppleScriptExecution.automationStatusKey(app: "Mail")
            let priorAutomation = systemStatuses[mailAutomationKey]
            let automation = grants[mailAutomationKey]
            // A stopped app or an unknown probe says nothing about consent.
            // A newly observed refusal invalidates even after such a gap;
            // observing granted again after a launch does not erase the read.
            let consentChanged = priorAutomation != automation
                && (automation == "denied" || automation == "not_determined"
                    || (automation == "granted" && (priorAutomation == "denied" || priorAutomation == "not_determined")))
            if systemStatuses["fullDiskAccess"] != grants["fullDiskAccess"] || consentChanged { mailCheck = nil }
            systemStatuses = grants
            // Mail may have launched during its read. Publish the refreshed
            // grants first, then its checked evidence in this same snapshot.
            if let mailEvidence { mailCheck = mailEvidence }
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
                let availableTools = SwiftToolDispatcher.catalogRegisteredToolNames
                let push = await ConnectorReadiness.mobilePushStatus(deviceSync: deviceSync)
                let macControl: (status: String, nextStep: String)
                let notifications: (status: String, nextStep: String)
                let trust: Result<[String: JSONValue], Error>
                do {
                    trust = .success(try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicyChecked())
                } catch {
                    trust = .failure(error)
                }
                switch trust {
                case .failure(let error):
                    let issue = UserFacingError.message(error, action: "read Mac watch policy")
                    macControl = ("unavailable", issue)
                    notifications = ("unavailable", issue)
                case .success(let policy):
                    let macPolicy = policy["macControlPolicy"]?.objectValue ?? [:]
                    let macEnabled = macPolicy["enabled"] == .bool(true)
                    let notificationsAllowed = macPolicy["notifications_allowed"].map { $0 == .bool(true) } ?? true
                    do {
                        let macProven = try await ConnectorReadiness.isProven(id: "mac", root: dataRoot, platform: platform)
                        macControl = (!macEnabled ? "needs_policy" : macProven ? "ready" : "probe_needed",
                                      !macEnabled ? "Turn on Mac control above." : macProven ? "" : "Run mac.self_test once to prove the bridge.")
                    } catch {
                        macControl = ("unavailable", UserFacingError.message(error, action: "read Mac control proof"))
                    }
                    if !(macEnabled && notificationsAllowed) {
                        notifications = ("needs_policy", "Turn on Notifications under Advanced Mac control, then send a test notification.")
                    } else {
                        let center = UNUserNotificationCenter.current()
                        let settings = await center.notificationSettings()
                        switch settings.authorizationStatus {
                        case .authorized, .provisional:
                            let delivered = await center.deliveredNotifications()
                            notifications = (delivered.isEmpty ? "probe_needed" : "ready",
                                             delivered.isEmpty ? "Send a notification to prove delivery; no delivered notification is currently retained." : "")
                        case .denied, .notDetermined:
                            notifications = ("needs_permission", "Allow NativeAgent notifications in macOS notification settings.")
                        default:
                            notifications = ("unavailable", "macOS notification authorization evidence is unavailable.")
                        }
                    }
                }
                let response = try await MacAssistantStatusResult.compose(
                    macControl: macControl, notifications: notifications, pushStatus: push,
                    availableTools: availableTools,
                    localStatuses: localStatusProjection(),
                    schedulerActions: try AppActions.seedActions.filter {
                        MacIntegrationGates.byTool[$0.tool]?.integration == MacIntegrationID.scheduler
                    }.map(\.id),
                    watchCatalog: { [dataRoot] in try await MacAssistantParts.watchCatalog(dataRoot: dataRoot) })
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

    /// Rendering reads the same evidence as the status page. Only an explicit
    /// check enters Mail; a grant on its own never establishes readiness.
    public func mailReadiness(check: Bool) async -> (status: String, word: String, next: String?) {
        if check { await checkMail() }
        else { await refresh(refreshWatches: false) }
        return currentMailReadiness()
    }

    public func checkMail() async {
        await refresh(refreshWatches: false, checkMail: true)
        await refreshWatches(refreshPermissions: false)
    }

    /// One combined verdict for every consumer. Missing or invalidated read
    /// evidence needs a check, even when all permission probes are granted.
    private func currentMailReadiness() -> (status: String, word: String, next: String?) {
        guard let checkedPermissions else {
            return ("unavailable", "Permission evidence unavailable", "Refresh Mac Integrations to read Mail access.")
        }
        switch checkedPermissions {
        case .failure(let error):
            return ("unavailable", "Permission evidence unavailable", error.localizedDescription)
        case .success(let snapshot):
            guard snapshot.permissions["mail"]?.read == true else {
                return ("needs_policy", "Read access off", "Enable read access in Mac Integrations.")
            }
        }
        guard let mailCheck else {
            return ("probe_needed", "Needs check", "Use Check Mail to check account coverage.")
        }
        return mailCheck
    }

    private func localStatusProjection() -> [String: [String: JSONValue]] {
        let integrations = [("local_mail", "mail"), ("local_calendar", "calendar"), ("local_reminders", "reminders")]
        return Dictionary(uniqueKeysWithValues: integrations.map { id, integration in
            if integration == "mail" {
                let readiness = currentMailReadiness()
                var status = ["status": JSONValue.string(readiness.status)]
                if let next = readiness.next { status["nextStep"] = .string(next) }
                return (id, status)
            }
            if case .failure(let error)? = checkedPermissions {
                return (id, ["status": .string("unavailable"), "detail": .string(error.localizedDescription)])
            }
            if permissions[integration]?.read != true {
                return (id, ["status": .string("needs_policy"), "detail": .string("Read access is disabled in Mac Integrations."), "nextStep": .string("Enable read access in Mac Integrations.")])
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
