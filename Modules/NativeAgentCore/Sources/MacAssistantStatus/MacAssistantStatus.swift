import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Subsystem #17 wave 11 (2026-05-31) — MacAssistantStatus Swift port
//
// PORTED-PARTIAL: composition runs against SwiftNativeTrustCenter for
// macControlPolicy reads. Three sub-queries are still conservative Swift
// defaults until their backing proof/probe subsystems expose richer native
// state:
//
//   - connector_proof_status(provider)  -> ConnectorProofProvider
//   - mobile_push_status()              -> MobilePushStatusProvider
//   - _dispatcher_tool_available(name)  -> DispatcherToolAvailabilityProvider
//
// Each provider has a protocol + conservative Swift-native impl + static test
// impl. The status renderer never contacts a daemon and never creates watcher
// jobs; it emits manifest/setup state only.

// MARK: - Result types

public struct MacAssistantAccessItem: Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: String
    public let detail: String
    public let setupRoute: String
    public let requiredFor: [String]
    public let nextStep: String?
    public let actionIds: [String]?
    public let toolNames: [String]?

    public init(
        id: String,
        title: String,
        status: String,
        detail: String,
        setupRoute: String,
        requiredFor: [String],
        nextStep: String? = nil,
        actionIds: [String]? = nil,
        toolNames: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.setupRoute = setupRoute
        self.requiredFor = requiredFor
        self.nextStep = nextStep
        self.actionIds = actionIds
        self.toolNames = toolNames
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "status": .string(status),
            "detail": .string(detail),
            "setupRoute": .string(setupRoute),
            "requiredFor": .array(requiredFor.map { .string($0) }),
        ]
        if let next = nextStep, !next.isEmpty {
            obj["nextStep"] = .string(next)
        }
        if let ids = actionIds, !ids.isEmpty {
            obj["actionIds"] = .array(ids.map { .string($0) })
        }
        if let tools = toolNames, !tools.isEmpty {
            obj["toolNames"] = .array(tools.map { .string($0) })
        }
        return .object(obj)
    }
}

public struct MacAssistantWatchTemplate: Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: String
    public let summary: String
    public let scheduleLabel: String
    public let sources: [String]
    public let requiredAccess: [String]
    public let actionIds: [String]
    public let jobPayload: JSONValue

    public init(
        id: String,
        title: String,
        status: String,
        summary: String,
        scheduleLabel: String,
        sources: [String],
        requiredAccess: [String],
        actionIds: [String],
        jobPayload: JSONValue
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.scheduleLabel = scheduleLabel
        self.sources = sources
        self.requiredAccess = requiredAccess
        self.actionIds = actionIds
        self.jobPayload = jobPayload
    }

    public func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "title": .string(title),
            "status": .string(status),
            "summary": .string(summary),
            "scheduleLabel": .string(scheduleLabel),
            "sources": .array(sources.map { .string($0) }),
            "requiredAccess": .array(requiredAccess.map { .string($0) }),
            "actionIds": .array(actionIds.map { .string($0) }),
            "jobPayload": jobPayload,
        ])
    }
}

public struct MacAssistantStatusResult: Sendable, Equatable {
    public let status: String
    public let summary: String
    public let access: [JSONValue]
    public let watchTemplates: [JSONValue]
    public let blockedAccessCount: Int
    public let templateAttentionCount: Int
    public let schedulerActions: [String]
    public let createsJobs: Bool
    public let lazyContract: JSONValue
    public let createdAt: String

    public init(
        status: String,
        summary: String,
        access: [JSONValue],
        watchTemplates: [JSONValue],
        blockedAccessCount: Int,
        templateAttentionCount: Int,
        schedulerActions: [String],
        createsJobs: Bool,
        lazyContract: JSONValue,
        createdAt: String
    ) {
        self.status = status
        self.summary = summary
        self.access = access
        self.watchTemplates = watchTemplates
        self.blockedAccessCount = blockedAccessCount
        self.templateAttentionCount = templateAttentionCount
        self.schedulerActions = schedulerActions
        self.createsJobs = createsJobs
        self.lazyContract = lazyContract
        self.createdAt = createdAt
    }

    public func toJSON() -> JSONValue {
        .object([
            "status": .string(status),
            "summary": .string(summary),
            "access": .array(access),
            "watchTemplates": .array(watchTemplates),
            "blockedAccessCount": .int(Int64(blockedAccessCount)),
            "templateAttentionCount": .int(Int64(templateAttentionCount)),
            "schedulerActions": .array(schedulerActions.map { .string($0) }),
            "createsJobs": .bool(createsJobs),
            "lazyContract": lazyContract,
            "createdAt": .string(createdAt),
        ])
    }
}

// MARK: - Cross-system provider protocols

public protocol ConnectorProofProvider: Sendable {
    /// Returns the connector proof dict for `provider`. Expected keys:
    /// `"verified"` (bool), `"nextStep"` (string, optional).
    func proofStatus(provider: String) async -> [String: JSONValue]
}

public protocol MobilePushStatusProvider: Sendable {
    /// Expected keys: `"status"`, `"tokenConfigured"`, `"nextStep"` (all
    /// optional).
    func pushStatus() async -> [String: JSONValue]
}

public protocol DispatcherToolAvailabilityProvider: Sendable {
    func isAvailable(toolName: String) async -> Bool
}

public protocol LocalPIMStatusProvider: Sendable {
    /// Expected keys: `"status"` plus optional `"nextStep"` and `"detail"`.
    /// Status values should use the same vocabulary as access rows:
    /// ready, probe_needed, needs_permission, needs_setup, failed.
    func localStatus(id: String) async -> [String: JSONValue]
}

// MARK: - Swift-native conservative provider impls

public struct SwiftNativeConservativeConnectorProofProvider: ConnectorProofProvider {
    public init() {}
    public func proofStatus(provider: String) async -> [String: JSONValue] {
        return [
            "verified": .bool(false),
            "nextStep": .string("Configure connector proof in the NativeAgent app"),
        ]
    }
}

public struct SwiftNativeConservativeMobilePushStatusProvider: MobilePushStatusProvider {
    public init() {}
    public func pushStatus() async -> [String: JSONValue] {
        return [
            "status": .string("unknown"),
            "nextStep": .string("Configure mobile push in NativeAgent settings"),
        ]
    }
}

public struct SwiftNativeConservativeDispatcherToolAvailabilityProvider: DispatcherToolAvailabilityProvider {
    public init() {}
    public func isAvailable(toolName: String) async -> Bool { false }
}

public struct SwiftNativeConservativeLocalPIMStatusProvider: LocalPIMStatusProvider {
    public init() {}
    public func localStatus(id: String) async -> [String: JSONValue] { [:] }
}

// MARK: - Static test impls

public struct StaticConnectorProofProvider: ConnectorProofProvider {
    public let proofs: [String: [String: JSONValue]]
    public init(proofs: [String: [String: JSONValue]] = [:]) {
        self.proofs = proofs
    }
    public func proofStatus(provider: String) async -> [String: JSONValue] {
        proofs[provider] ?? ["verified": .bool(false)]
    }
}

public struct StaticMobilePushStatusProvider: MobilePushStatusProvider {
    public let value: [String: JSONValue]
    public init(value: [String: JSONValue] = [:]) {
        self.value = value
    }
    public func pushStatus() async -> [String: JSONValue] { value }
}

public struct StaticDispatcherToolAvailabilityProvider: DispatcherToolAvailabilityProvider {
    public let availableTools: Set<String>
    public init(availableTools: Set<String> = []) {
        self.availableTools = availableTools
    }
    public func isAvailable(toolName: String) async -> Bool {
        availableTools.contains(toolName)
    }
}

public struct StaticLocalPIMStatusProvider: LocalPIMStatusProvider {
    public let statuses: [String: [String: JSONValue]]
    public init(statuses: [String: [String: JSONValue]] = [:]) {
        self.statuses = statuses
    }
    public func localStatus(id: String) async -> [String: JSONValue] {
        statuses[id] ?? [:]
    }
}

// MARK: - Client protocol

public protocol MacAssistantStatusClient: Sendable {
    func macAssistantStatus(lightweight: Bool) async throws -> MacAssistantStatusResult
}

// MARK: - SwiftNative impl

public actor SwiftNativeMacAssistantStatusClient: MacAssistantStatusClient {
    private let loadTrustPolicy: @Sendable () async -> [String: JSONValue]
    private let proofs: ConnectorProofProvider
    private let push: MobilePushStatusProvider
    private let dispatcherTools: DispatcherToolAvailabilityProvider
    private let localPIM: LocalPIMStatusProvider
    private let now: @Sendable () -> Date

    public init(
        loadTrustPolicy: @escaping @Sendable () async -> [String: JSONValue],
        proofs: ConnectorProofProvider = SwiftNativeConservativeConnectorProofProvider(),
        push: MobilePushStatusProvider = SwiftNativeConservativeMobilePushStatusProvider(),
        dispatcherTools: DispatcherToolAvailabilityProvider = SwiftNativeConservativeDispatcherToolAvailabilityProvider(),
        localPIM: LocalPIMStatusProvider = SwiftNativeConservativeLocalPIMStatusProvider(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loadTrustPolicy = loadTrustPolicy
        self.proofs = proofs
        self.push = push
        self.dispatcherTools = dispatcherTools
        self.localPIM = localPIM
        self.now = now
    }

    public func macAssistantStatus(lightweight: Bool) async throws -> MacAssistantStatusResult {
        let trust = await loadTrustPolicy()
        var macEnabled = false
        var notificationsAllowedRaw: Bool = true
        var notificationsKeyPresent = false
        if case .object(let macPolicy)? = trust["macControlPolicy"] {
            if case .bool(let b)? = macPolicy["enabled"] {
                macEnabled = b
            }
            if let v = macPolicy["notifications_allowed"] {
                notificationsKeyPresent = true
                if case .bool(let b) = v { notificationsAllowedRaw = b } else { notificationsAllowedRaw = false }
            }
        }
        let notificationsAllowed = notificationsKeyPresent ? notificationsAllowedRaw : true

        let emailProof = await proofs.proofStatus(provider: "email")
        let calendarProof = await proofs.proofStatus(provider: "calendar")
        let pushStatus = await push.pushStatus()

        func proofState(_ proof: [String: JSONValue]) -> String {
            if case .bool(true)? = proof["verified"] { return "ready" }
            return "needs_proof"
        }
        func proofNextStep(_ proof: [String: JSONValue]) -> String {
            if case .string(let s)? = proof["nextStep"] { return s }
            return ""
        }
        let macState = macEnabled ? "ready" : "needs_policy"
        let macNotificationsState = (macEnabled && notificationsAllowed) ? "ready" : "needs_policy"

        // iPhone push state — ready if status in {ok,ready,configured}
        // OR tokenConfigured is truthy.
        var pushReady = false
        if case .string(let s)? = pushStatus["status"] {
            let lower = s.lowercased()
            if lower == "ok" || lower == "ready" || lower == "configured" {
                pushReady = true
            }
        }
        if !pushReady, case .bool(true)? = pushStatus["tokenConfigured"] {
            pushReady = true
        }
        let pushState = pushReady ? "ready" : "needs_setup"
        var pushNextStep = ""
        if case .string(let s)? = pushStatus["nextStep"] { pushNextStep = s }

        func localAccessState(id: String, toolName: String) async -> (status: String, detail: String?, nextStep: String?) {
            let local = await localPIM.localStatus(id: id)
            let localStatus: String? = {
                if case .string(let s)? = local["status"] {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return nil
            }()
            let detail: String? = {
                if case .string(let s)? = local["detail"], !s.isEmpty { return s }
                return nil
            }()
            let nextStep: String? = {
                if case .string(let s)? = local["nextStep"], !s.isEmpty { return s }
                return nil
            }()
            if let localStatus {
                return (localStatus, detail, nextStep)
            }
            let available = await dispatcherTools.isAvailable(toolName: toolName)
            return (available ? "probe_needed" : "needs_setup", detail, nextStep)
        }

        let mailAccess = await localAccessState(id: "local_mail", toolName: "mail_list_recent")
        let calAccess = await localAccessState(id: "local_calendar", toolName: "calendar_list_upcoming")
        let remAccess = await localAccessState(id: "local_reminders", toolName: "reminders_list_due_today")
        let mailState = mailAccess.status
        let calState = calAccess.status
        let remState = remAccess.status

        let emailState = proofState(emailProof)
        let calendarState = proofState(calendarProof)

        let access: [MacAssistantAccessItem] = [
            MacAssistantAccessItem(
                id: "mac_control",
                title: "Mac Control Bridge",
                status: macState,
                detail: "App-owned local control bridge for shortcuts, notifications, file reads, and Apple Events.",
                setupRoute: "sidebar:trust",
                requiredFor: ["local_mail", "local_calendar", "local_reminders", "mac_notifications"],
                nextStep: macEnabled ? "" : "Enable Mac Control in Trust Center.",
                actionIds: ["mac.self_test"]
            ),
            MacAssistantAccessItem(
                id: "mac_notifications",
                title: "Mac Notifications",
                status: macNotificationsState,
                detail: "Posts local macOS notifications through the app-owned bridge.",
                setupRoute: "sidebar:trust",
                requiredFor: ["watch_receipts"],
                nextStep: macNotificationsState == "ready" ? "" : "Enable Mac Control notifications and send a test notification.",
                actionIds: ["mac.notify"]
            ),
            MacAssistantAccessItem(
                id: "iphone_push",
                title: "iPhone Push",
                status: pushState,
                detail: "APNS path for watch receipts and activity opens on iOS.",
                setupRoute: "sidebar:settings",
                requiredFor: ["remote_watch_receipts"],
                nextStep: pushNextStep,
                actionIds: ["mobile.notify"]
            ),
            MacAssistantAccessItem(
                id: "gmail",
                title: "Gmail",
                status: emailState,
                detail: "Cloud email watcher source. Uses connector proof, not token presence alone.",
                setupRoute: "sidebar:connectors",
                requiredFor: ["gmail_unread_digest"],
                nextStep: proofNextStep(emailProof),
                actionIds: ["gmail.status", "gmail.list_inbox", "gmail.search"]
            ),
            MacAssistantAccessItem(
                id: "google_calendar",
                title: "Google Calendar",
                status: calendarState,
                detail: "Cloud calendar watcher source. Requires a fresh account proof before event reads.",
                setupRoute: "sidebar:connectors",
                requiredFor: ["calendar_window_watch"],
                nextStep: proofNextStep(calendarProof),
                actionIds: ["calendar.status", "calendar.list_events", "calendar.find_availability"]
            ),
            MacAssistantAccessItem(
                id: "local_mail",
                title: "Local Mail.app",
                status: mailState,
                detail: mailAccess.detail ?? "Read-only Mail.app inbox scan via Apple Events. First real run may trigger macOS privacy approval.",
                setupRoute: "sidebar:trust",
                requiredFor: ["local_mail_watch"],
                nextStep: mailAccess.nextStep ?? (mailState == "ready" ? "" : "Run mac.mail_list_recent once from the app to prove Mail.app access."),
                actionIds: ["mac.mail_list_recent"],
                toolNames: ["mail_list_recent", "mail_search"]
            ),
            MacAssistantAccessItem(
                id: "local_calendar",
                title: "Local Calendar.app",
                status: calState,
                detail: calAccess.detail ?? "Read-only Calendar access through EventKit. The first probe opens the macOS Calendar permission prompt.",
                setupRoute: "sidebar:trust",
                requiredFor: ["local_calendar_watch"],
                nextStep: calAccess.nextStep ?? (calState == "ready" ? "" : "Run mac.calendar_list_upcoming once from the app to prove Calendar access."),
                actionIds: ["mac.calendar_list_upcoming"],
                toolNames: ["calendar_list_upcoming"]
            ),
            MacAssistantAccessItem(
                id: "local_reminders",
                title: "Local Reminders.app",
                status: remState,
                detail: remAccess.detail ?? "Read-only Reminders access through EventKit. The first probe opens the macOS Reminders permission prompt.",
                setupRoute: "sidebar:trust",
                requiredFor: ["local_reminders_watch"],
                nextStep: remAccess.nextStep ?? (remState == "ready" ? "" : "Run mac.reminders_list_due_today once from the app to prove Reminders access."),
                actionIds: ["mac.reminders_list_due_today"],
                toolNames: ["reminders_list_due_today"]
            ),
        ]

        let statusById: [String: String] = Dictionary(uniqueKeysWithValues: access.map { ($0.id, $0.status) })
        func templateStatus(_ required: [String]) -> String {
            let states = required.map { statusById[$0] ?? "needs_setup" }
            if !states.isEmpty && states.allSatisfy({ $0 == "ready" }) { return "ready" }
            if states.contains("needs_proof") { return "needs_proof" }
            if states.contains("needs_policy") { return "needs_policy" }
            if states.contains("needs_permission") { return "needs_permission" }
            return "probe_needed"
        }

        let templates: [MacAssistantWatchTemplate] = [
            MacAssistantWatchTemplate(
                id: "gmail_unread_digest",
                title: "Gmail unread digest",
                status: templateStatus(["gmail", "iphone_push"]),
                summary: "Poll unread Gmail and leave a connector receipt that can feed proactive digesting.",
                scheduleLabel: "Every 30 minutes",
                sources: ["gmail"],
                requiredAccess: ["gmail", "iphone_push"],
                actionIds: ["gmail.list_inbox", "scheduler.schedule_job"],
                jobPayload: .object([
                    "name": .string("Watch Gmail unread inbox"),
                    "kind": .string("connector_action"),
                    "schedule": .object(["type": .string("every"), "minutes": .int(Int64(30))]),
                    "payload": .object([
                        "actionId": .string("gmail.list_inbox"),
                        "input": .object(["query": .string("is:unread"), "max": .int(Int64(10))]),
                    ]),
                ])
            ),
            MacAssistantWatchTemplate(
                id: "google_calendar_window_watch",
                title: "Google Calendar window watch",
                status: templateStatus(["google_calendar", "iphone_push"]),
                summary: "Poll upcoming Google Calendar events through the proof-gated Calendar connector.",
                scheduleLabel: "Every 30 minutes",
                sources: ["google_calendar"],
                requiredAccess: ["google_calendar", "iphone_push"],
                actionIds: ["calendar.list_events", "scheduler.schedule_job"],
                jobPayload: .object([
                    "name": .string("Watch Google Calendar"),
                    "kind": .string("connector_action"),
                    "schedule": .object(["type": .string("every"), "minutes": .int(Int64(30))]),
                    "payload": .object([
                        "actionId": .string("calendar.list_events"),
                        "input": .object(["max": .int(Int64(20))]),
                    ]),
                ])
            ),
            MacAssistantWatchTemplate(
                id: "local_mail_watch",
                title: "Local Mail.app watch",
                status: templateStatus(["local_mail", "mac_control"]),
                summary: "Poll local Mail.app read-only via the app-owned dispatcher.",
                scheduleLabel: "Every 30 minutes",
                sources: ["mail.app"],
                requiredAccess: ["local_mail", "mac_control"],
                actionIds: ["mac.mail_list_recent", "scheduler.schedule_job"],
                jobPayload: .object([
                    "name": .string("Watch local Mail.app"),
                    "kind": .string("connector_action"),
                    "schedule": .object(["type": .string("every"), "minutes": .int(Int64(30))]),
                    "payload": .object([
                        "actionId": .string("mac.mail_list_recent"),
                        "input": .object([
                            "limit": .int(Int64(20)),
                            "hours_back": .int(Int64(24)),
                            "unread_only": .bool(true),
                        ]),
                    ]),
                ])
            ),
            MacAssistantWatchTemplate(
                id: "local_calendar_watch",
                title: "Local Calendar.app watch",
                status: templateStatus(["local_calendar", "mac_control"]),
                summary: "Poll local Calendar.app read-only for the next day.",
                scheduleLabel: "Every 30 minutes",
                sources: ["calendar.app"],
                requiredAccess: ["local_calendar", "mac_control"],
                actionIds: ["mac.calendar_list_upcoming", "scheduler.schedule_job"],
                jobPayload: .object([
                    "name": .string("Watch local Calendar.app"),
                    "kind": .string("connector_action"),
                    "schedule": .object(["type": .string("every"), "minutes": .int(Int64(30))]),
                    "payload": .object([
                        "actionId": .string("mac.calendar_list_upcoming"),
                        "input": .object(["hours_ahead": .int(Int64(24))]),
                    ]),
                ])
            ),
            MacAssistantWatchTemplate(
                id: "local_reminders_watch",
                title: "Local Reminders.app watch",
                status: templateStatus(["local_reminders", "mac_control"]),
                summary: "Poll due and overdue Reminders.app items read-only.",
                scheduleLabel: "Hourly",
                sources: ["reminders.app"],
                requiredAccess: ["local_reminders", "mac_control"],
                actionIds: ["mac.reminders_list_due_today", "scheduler.schedule_job"],
                jobPayload: .object([
                    "name": .string("Watch due reminders"),
                    "kind": .string("connector_action"),
                    "schedule": .object(["type": .string("hourly"), "minute": .int(Int64(5))]),
                    "payload": .object([
                        "actionId": .string("mac.reminders_list_due_today"),
                        "input": .object(["include_completed": .bool(false)]),
                    ]),
                ])
            ),
            MacAssistantWatchTemplate(
                id: "morning_brief_watch",
                title: "Morning brief watch",
                status: templateStatus(["gmail", "google_calendar", "iphone_push"]),
                summary: "Use the proactive scanner to turn email and calendar context into a useful daily brief card.",
                scheduleLabel: "Daily at 08:30",
                sources: ["gmail", "google_calendar", "proactive_autonomy"],
                requiredAccess: ["gmail", "google_calendar", "iphone_push"],
                actionIds: ["scheduler.schedule_job"],
                jobPayload: .object([
                    "name": .string("Morning assistant brief"),
                    "kind": .string("proactive_scan"),
                    "schedule": .object(["type": .string("daily"), "at": .string("08:30")]),
                    "payload": .object([
                        "reason": .string("watch:morning_brief"),
                        "limit": .int(Int64(8)),
                        "surfaceLimit": .int(Int64(2)),
                        "watchTemplateId": .string("morning_brief_watch"),
                        "sources": .array([.string("gmail"), .string("calendar")]),
                    ]),
                ])
            ),
        ]

        let okStates: Set<String> = ["ready", "probe_needed"]
        let blocked = access.filter { !okStates.contains($0.status) }.count
        let templateAttention = templates.filter { $0.status != "ready" }.count

        let accessJSON: [JSONValue]
        let templatesJSON: [JSONValue]
        if lightweight {
            // Allow-list keys for lightweight; emit only when present + truthy
            // (matching Python's `... and value` filter — drops "" / [] / null).
            let accessKeys: [String] = ["id", "title", "status", "setupRoute", "nextStep"]
            accessJSON = access.prefix(5).map { item in
                let full = item.toJSON()
                guard case .object(let dict) = full else { return full }
                var out: [String: JSONValue] = [:]
                for k in accessKeys {
                    if let v = dict[k], MacAssistantStatusResult.isTruthy(v) {
                        out[k] = v
                    }
                }
                return .object(out)
            }
            let tplKeys: [String] = ["id", "title", "status", "summary", "scheduleLabel", "sources", "requiredAccess", "actionIds"]
            templatesJSON = templates.prefix(3).map { tpl in
                let full = tpl.toJSON()
                guard case .object(let dict) = full else { return full }
                var out: [String: JSONValue] = [:]
                for k in tplKeys {
                    if let v = dict[k], MacAssistantStatusResult.isTruthy(v) {
                        out[k] = v
                    }
                }
                return .object(out)
            }
        } else {
            accessJSON = access.map { $0.toJSON() }
            templatesJSON = templates.map { $0.toJSON() }
        }

        let lazyContract: JSONValue = .object([
            "chatInjection": .string("none"),
            "watchBodiesLoaded": .bool(false),
            "jobCreation": .string("explicit scheduler action only"),
            "providerProbe": .string("status/read action only, never during status rendering"),
        ])
        let createdAt = MacAssistantStatusResult.isoTimestamp(now())

        return MacAssistantStatusResult(
            status: blocked == 0 ? "ready" : "attention",
            summary: "Mac assistant watch setup is manifest-only here; no watcher jobs are created until scheduler.schedule_job is called.",
            access: accessJSON,
            watchTemplates: templatesJSON,
            blockedAccessCount: blocked,
            templateAttentionCount: templateAttention,
            schedulerActions: ["scheduler.schedule_job", "scheduler.create_job", "scheduler.list_jobs", "scheduler.cancel_job"],
            createsJobs: false,
            lazyContract: lazyContract,
            createdAt: createdAt
        )
    }
}

extension MacAssistantStatusResult {
    /// Mirrors Python's `... and value` truthiness used in the lightweight
    /// dict comprehension: empty string / empty array / empty object / null /
    /// `false` / `0` all drop out.
    static func isTruthy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// ISO-8601 with fractional seconds + `+00:00` (matches the retired
    /// `now_iso()`; same convention as SystemOps.isoTimestamp).
    static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") { return String(zulu.dropLast()) + "+00:00" }
        return zulu
    }
}

// MARK: - Factory

public func makeMacAssistantStatusClient(
    loadTrustPolicy: (@Sendable () async -> [String: JSONValue])? = nil,
    proofs: ConnectorProofProvider = SwiftNativeConservativeConnectorProofProvider(),
    push: MobilePushStatusProvider = SwiftNativeConservativeMobilePushStatusProvider(),
    dispatcherTools: DispatcherToolAvailabilityProvider = SwiftNativeConservativeDispatcherToolAvailabilityProvider(),
    localPIM: LocalPIMStatusProvider = SwiftNativeConservativeLocalPIMStatusProvider()
) -> any MacAssistantStatusClient {
    let loader: @Sendable () async -> [String: JSONValue] = loadTrustPolicy ?? {
        await SwiftNativeTrustCenter().loadTrustPolicy()
    }
    return SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: loader,
        proofs: proofs,
        push: push,
        dispatcherTools: dispatcherTools,
        localPIM: localPIM
    )
}
