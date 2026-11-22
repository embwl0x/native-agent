import AppToolRuntime
import AppKit
import Connectors
import Combine
import ChatToolRuntime
import ChatTurnContracts
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
// Blueprint: | `EngineMacIntegration.swift` | `MacIntegrationFacade`, `LatestRead`; Shared checked grants and watch readiness |

/// Share checked permissions, nonprompting OS grants and watch readiness per root.
@MainActor @Observable
public final class MacIntegrationFacade: MacAssistantStatusClient {
    public static let systemStatusesDidChange = Notification.Name("NativeAgent.macSystemStatusesDidChange")
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
    public private(set) var checkedPermissions: Result<MacIntegrationPermissionStore.Snapshot, Error>?
    @ObservationIgnored private lazy var permissionRead = LatestRead()
    @ObservationIgnored private lazy var watchRead = LatestRead()
    @ObservationIgnored private lazy var mailCheckRead = LatestRead()
    @ObservationIgnored private var permissionObservation: AnyCancellable?
    @ObservationIgnored private var activationObservation: AnyCancellable?
    @ObservationIgnored private var permissionWatcher: FileChangeWatcher?
    @ObservationIgnored private var settingsFeed: SettingsFeedProjection?

    public func bindSettingsFeed(_ feed: SettingsFeedProjection) {
        settingsFeed = feed
        publishSettings()
    }

    private func publishSettings() {
        settingsFeed?.updatePermissions(statuses: systemStatuses, issue: permissionLoadError, isReading: isLoading)
    }
    /// The last Check Mail result, kept on disk across restarts: it speaks only for what the live readings cannot tell (a read that
    /// failed, account coverage, Mail not running), and is dropped once a grant it was read under reads otherwise, even across a restart.
    /// The kept result and the Mail Automation and Full Disk Access readings it was read under, read from disk on first use on the main actor.
    @ObservationIgnored private var keptMailCheckStore: (check: (status: String, word: String, next: String?)?, under: [String: String])?
    private var keptMailCheck: (check: (status: String, word: String, next: String?)?, under: [String: String]) {
        get {
            if let kept = keptMailCheckStore { return kept }
            let saved = MacIntegrationFacade.savedMailCheck(dataRoot: dataRoot)
            let kept = (check: saved?.check, under: saved?.under ?? [:])
            keptMailCheckStore = kept
            return kept
        }
        set { keptMailCheckStore = newValue }
    }
    private var mailCheck: (status: String, word: String, next: String?)? {
        get { keptMailCheck.check }
        set { keptMailCheck.check = newValue }
    }
    private var mailCheckUnder: [String: String] {
        get { keptMailCheck.under }
        set { keptMailCheck.under = newValue }
    }
    /// What Mail's read path lacks that the app can see without a check; nil when nothing is missing.
    private var mailPathGap: (status: String, word: String, next: String?)?
    private nonisolated static let mailCheckGrants = [AppleScriptExecution.automationStatusKey(app: "Mail"), "fullDiskAccess"]

    public nonisolated init(dataRoot: URL, deviceSync: DeviceSync?, platform: AppConnectorStatusPlatform) {
        self.dataRoot = dataRoot
        self.deviceSync = deviceSync
        self.platform = platform
    }

    private nonisolated static func mailCheckFile(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("security/mail_check.json")
    }

    private nonisolated static func savedMailCheck(dataRoot: URL)
        -> (check: (status: String, word: String, next: String?), under: [String: String])? {
        guard let data = try? Data(contentsOf: mailCheckFile(dataRoot)),
              let saved = try? JSONDecoder().decode([String: String].self, from: data),
              let status = saved["status"], let word = saved["word"] else { return nil }
        return ((status, word, saved["next"]), saved.filter { mailCheckGrants.contains($0.key) })
    }

    /// What Mail's read path needs that the app can see without a check: Mail's local store and its Envelope Index readable (Full Disk
    /// Access), and at least one account in it. Nil when all are there.
    nonisolated static func mailReadPathGap() -> (status: String, word: String, next: String?)? {
        typealias Gap = (status: String, word: String, next: String?)
        let files = FileManager.default
        let library = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        let noAccount: Gap = ("needs_setup", "Needs a Mail account",
                              "Add and enable a Mail account in System Settings → Internet Accounts, then open Mail once.")
        let noAccess: Gap = ("needs_permission", "Needs Full Disk Access",
                             "Turn on NativeAgent in System Settings → Privacy & Security → Full Disk Access; Mail's index is read there.")
        let noIndex: Gap = ("needs_setup", "Mail has no index yet", "Open Mail once so it builds its index, then check again.")
        func gap(_ error: Error, missing: Gap) -> Gap {
            guard let error = error as? CocoaError else { return ("unavailable", "Mail's store unreadable", error.localizedDescription) }
            if [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) { return missing }
            if error.code == .fileReadNoPermission { return noAccess }
            return ("unavailable", "Mail's store unreadable", error.localizedDescription)
        }
        let versions: [String]
        do { versions = try files.contentsOfDirectory(atPath: library.path) } catch { return gap(error, missing: noAccount) }
        guard let version = versions.compactMap({ $0.hasPrefix("V") ? Int($0.dropFirst()) : nil }).max() else { return noAccount }
        let store = library.appendingPathComponent("V\(version)")
        do { try FileHandle(forReadingFrom: store.appendingPathComponent("MailData/Envelope Index")).close() }
        catch { return gap(error, missing: noIndex) }
        do { return try files.contentsOfDirectory(atPath: store.path).contains { UUID(uuidString: $0) != nil } ? nil : noAccount }
        catch { return gap(error, missing: noAccount) }
    }

    /// Record the check result as it stands with the grant readings it was read under, on disk too; nil forgets it.
    private func keepMailCheck(_ check: (status: String, word: String, next: String?)?) {
        mailCheck = check
        mailCheckUnder = check == nil ? [:] : systemStatuses.filter { Self.mailCheckGrants.contains($0.key) }
        let file = Self.mailCheckFile(dataRoot)
        do {
            if let check {
                var saved = mailCheckUnder.merging(["status": check.status, "word": check.word]) { $1 }
                saved["next"] = check.next
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(saved).write(to: file, options: .atomic)
            } else if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            nativeLog("Mail check result not kept on disk: %@", error.localizedDescription)
        }
    }

    /// Observe saved writes and returns to the body or its window; release both subscriptions with their facade.
    public func observePermissionChanges() {
        // The permission store posts off-main; hop before the main-actor closure to avoid isolation traps.
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
        activationObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .map { notice in
                let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                return PersonOnlyWindows.isOwnProcess(app?.processIdentifier)
            }
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh(refreshWatches: false) }
            }
    }

    @discardableResult
    public func refresh(refreshWatches: Bool = true) async -> Result<MacIntegrationPermissionStore.Snapshot, Error> {
        if permissionWatcher == nil {
            let permissions = dataRoot.appendingPathComponent("security/mac_integration_permissions.json")
            let watcher = await FileChangeWatcher.armed(paths: [permissions]) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            if permissionWatcher == nil { permissionWatcher = watcher } else { watcher.cancel() }
        }
        isLoading = true
        let (result, _, _) = await permissionRead.read {
            let result: Result<MacIntegrationPermissionStore.Snapshot, Error>
            do { result = .success(try await MacIntegrationPermissionStore(dataRoot: dataRoot).snapshotChecked()) }
            catch { result = .failure(error) }
            let grants = await Task.detached(priority: .userInitiated) {
                var statuses = ["speech_recognition": Self.badgeKey(SystemPermissionPreflight.status(.speechRecognition)),
                 "microphone": Self.badgeKey(SystemPermissionPreflight.status(.microphone)),
                 "calendar": LocalPIMConnectorActions.currentCalendarAuthorizationStatus(),
                 "reminders": LocalPIMConnectorActions.currentReminderAuthorizationStatus(),
                 "contacts": MacContactsExecutor.currentAuthorizationStatus(),
                 "accessibility": SystemPermissionPreflight.status(.accessibility).rawValue,
                 "screenRecording": SystemPermissionPreflight.status(.screenRecording).rawValue,
                 "fullDiskAccess": SystemPermissionPreflight.status(.fullDiskAccess).rawValue]
                for app in AppleScriptExecution.automationTargetApps {
                    statuses[AppleScriptExecution.automationStatusKey(app: app)] = await AppleScriptExecution.automationStatus(app: app, ask: false)
                }
                return statuses
            }.value
            let gap = await Task.detached(priority: .userInitiated) { Self.mailReadPathGap() }.value
            return (result, grants, gap)
        } publish: { result, grants, gap in
            // Only a change from an earlier reading clears the kept result; the first reading after launch is no change.
            if case .success(let prior)? = checkedPermissions, case .success(let snapshot) = result,
               prior.permissions["mail"] != snapshot.permissions["mail"] { keepMailCheck(nil) }
            checkedPermissions = result
            mailPathGap = gap
            // A kept result read under a grant that now reads otherwise (consent or Full Disk Access changed, also while the app was
            // closed) no longer holds; an unknown reading (Mail not running) says nothing.
            if mailCheck != nil, Self.mailCheckGrants.contains(where: { key in
                guard let live = grants[key], !["unknown", "app_not_running"].contains(live) else { return false }
                return mailCheckUnder[key] != live
            }) { keepMailCheck(nil) }
            let grantsChanged = systemStatuses != grants
            systemStatuses = grants
            isLoading = false
            publishSettings()
            if grantsChanged { NotificationCenter.default.post(name: Self.systemStatusesDidChange, object: dataRoot) }
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

    public func set(_ id: String, mode: MacIntegrationPermissionMode, allowed: Bool,
                    surface: String = "mac_ui", provenance: MacIntegrationPermissionMutationProvenance = .local()) async throws {
        do {
            let stored = try await MacIntegrationPermissionStore(dataRoot: dataRoot).setWithReceipt(
                integrationId: id, read: mode == .read ? allowed : nil, write: mode == .write ? allowed : nil,
                actionID: UUID().uuidString.lowercased(), surface: surface, provenance: provenance)
            permissionRead.write {
                // The write fences older reads; the page keeps every switch, this one as stored, until the reread publishes.
                if case .success(let snapshot)? = checkedPermissions { checkedPermissions = .success(snapshot.with(id, stored)) }
                if id == "mail" { keepMailCheck(nil) }
            }
            // A check that began under the old switch no longer speaks for Mail.
            mailCheckRead.write {}
            await refresh()
        } catch {
            await refresh()
            throw error
        }
    }

    public func refreshWatches(refreshPermissions: Bool = true) async {
        // `readWatches` publishes its visible failure before throwing.
        _ = try? await readWatches(lightweight: false, refreshPermissions: refreshPermissions)
    }

    public nonisolated func macAssistantStatus(lightweight: Bool) async throws -> MacAssistantStatusResult {
        try await readWatches(lightweight: lightweight, refreshPermissions: true)
    }

    private func readWatches(lightweight: Bool, refreshPermissions: Bool) async throws -> MacAssistantStatusResult {
        let result = await watchRead.read {
            // Both pages share the checked snapshot and OS grants.
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
                        $0.schema?.macIntegration?.integration == MacIntegrationID.scheduler
                    }.map(\.id),
                    watchCatalog: { [dataRoot] in try await MacAssistantParts.watchCatalog(dataRoot: dataRoot) })
                return Result<MacAssistantStatusResult, Error>.success(response)
            } catch {
                return .failure(error)
            }
        } publish: { result in
            let next: MacAssistantWatchSetupLoadState
            switch result {
            case .success(let response): next = .current(response)
            case .failure(let error): next = watchState.afterFailure(UserFacingError.message(error, action: "refresh background watches"))
            }
            if !watchState.hasSameContent(as: next) {
                watchState = next
                NotificationCenter.default.post(name: Self.watchesDidChange, object: nil)
            }
        }
        return try result.get().projected(lightweight: lightweight)
    }

    /// Only an explicit check enters Mail; a grant alone never proves readiness.
    public func mailReadiness(check: Bool) async -> (status: String, word: String, next: String?) {
        if check { await checkMail() }
        else { await refresh(refreshWatches: false) }
        return currentMailReadiness()
    }

    /// The check's result is a committed fact: a grants read that started while Mail was being read (the consent prompt, Mail's launch,
    /// the window coming back, a permission write) never discards it. Of overlapping checks, the newest-started one's result stands.
    public func checkMail() async {
        guard case .success(let snapshot) = await refresh(refreshWatches: false), snapshot.permissions["mail"]?.read == true else {
            await refreshWatches(refreshPermissions: false)
            return
        }
        _ = await mailCheckRead.read { () -> (status: String, word: String, next: String?) in
            let evidence: (status: String, word: String, next: String?)
            do {
                // The person's Check Mail reads mail.recent through the door, as any read of it runs.
                evidence = MacAssistantStatusResult.mailReadiness(from: try await MacAssistantParts.verb("mail.recent", input: ["limit": .int(1)],
                    dataRoot: dataRoot, envelope: .personOnMac("mac_ui:mail.check")))
            } catch {
                evidence = (status: "failed", word: "Check failed", next: UserFacingError.cause(error, action: "check Mail"))
            }
            // Mail may ask consent or launch during its read: publish the grants it changed first, so their change cannot clear this result.
            await refresh(refreshWatches: false)
            return evidence
        } publish: { evidence in
            permissionRead.write { keepMailCheck(evidence) }
        }
        await refreshWatches(refreshPermissions: false)
    }

    /// Mail's readiness from what is true now: the watch's read switch and the live Automation grant decide; the kept check result
    /// speaks only where the grant cannot (a failed read or coverage gap, Mail not running), so a restart never resets a working watch.
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
        switch systemStatuses[AppleScriptExecution.automationStatusKey(app: "Mail")] {
        case "denied"?:
            return ("needs_permission", "Needs macOS permission",
                    "Allow NativeAgent to control Mail in System Settings → Privacy & Security → Automation.")
        case "granted"?:
            if let mailPathGap { return mailPathGap }
            return mailCheck ?? ("ready", "Ready", nil)
        default:
            if let mailPathGap { return mailPathGap }
            if let mailCheck { return mailCheck }
            return ("probe_needed", "Needs check", "Use Check Mail to let NativeAgent read Mail.")
        }
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
                return (id, ["status": .string("needs_policy"), "detail": .string("Read access is disabled in Mac Integrations."), "nextStep": .string(
                    "Enable read access in Mac Integrations.")])
            }
            return (id, LocalPIMConnectorActions.authorizationStatusPayload(localId: id, wizardStatus: systemStatuses[integration] ?? "unknown"))
        })
    }

    public nonisolated static func badgeKey(_ status: SystemPermissionStatus) -> String {
        status == .notDetermined ? "not_determined" : status.rawValue
    }
}

extension MacIntegrationFacade {
    /// Watch content or availability changed (current, stale or unavailable), excluding its sampling timestamp.
    public static let watchesDidChange = Notification.Name("MacIntegrationFacade.watchesDidChange")
}

public enum MacAssistantWatchSetupLoadState: Equatable, Sendable {
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

    func afterFailure(_ message: String) -> Self {
        guard let response else { return .unavailable(message: message) }
        return .stale(response, message: message)
    }

    func hasSameContent(as other: Self) -> Bool {
        switch (self, other) {
        case (.loading, .loading): true
        case (.current(let left), .current(let right)): left.hasSameContent(as: right)
        case (.stale(let left, let message), .stale(let right, let otherMessage)):
            message == otherMessage && left.hasSameContent(as: right)
        case (.unavailable(let message), .unavailable(let otherMessage)): message == otherMessage
        default: false
        }
    }
}
