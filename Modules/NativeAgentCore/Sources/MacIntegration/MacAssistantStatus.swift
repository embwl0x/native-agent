import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `MacAssistantStatus.swift` | assistant status client, result, lightweight serialization of an existing full result, Mail readiness projection and native watch access evidence; typed catalog data and UI words come from `Resources/abilities/mac-watch-catalog.js`, never creating jobs; missing/disabled/invalid catalog is unavailable, never an empty catalog |

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

public struct MacAssistantAccessItem: Sendable, Equatable, Identifiable {
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

/// Editable catalog data. Access status and job creation stay native.
public struct MacAssistantWatchRecipe: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let scheduleLabel: String
    public let sources: [String]
    public let requiredAccess: [String]
    public let actionIds: [String]
    public let jobPayload: JSONValue
    public let displayTitle: String
    public let displaySummary: String
}

public struct MacAssistantWatchTemplate: Sendable, Equatable, Identifiable {
    public let recipe: MacAssistantWatchRecipe
    public let status: String
    public var id: String { recipe.id }
    public var title: String { recipe.title }
    public var summary: String { recipe.summary }
    public var scheduleLabel: String { recipe.scheduleLabel }
    public var sources: [String] { recipe.sources }
    public var requiredAccess: [String] { recipe.requiredAccess }
    public var actionIds: [String] { recipe.actionIds }
    public var jobPayload: JSONValue { recipe.jobPayload }
    public var displayTitle: String { recipe.displayTitle }
    public var displaySummary: String { recipe.displaySummary }

    public init(recipe: MacAssistantWatchRecipe, status: String) {
        self.recipe = recipe
        self.status = status
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
            "displayTitle": .string(displayTitle),
            "displaySummary": .string(displaySummary),
        ])
    }
}

public struct MacAssistantStatusResult: Sendable, Equatable {
    public let status: String
    public let summary: String
    public let access: [MacAssistantAccessItem]
    public let watchTemplates: [MacAssistantWatchTemplate]
    public let blockedAccessCount: Int
    public let templateAttentionCount: Int
    public let schedulerActions: [String]
    public var createsJobs: Bool { false }
    public let lazyContract: JSONValue
    public let createdAt: String
    private let lightweight: Bool

    public init(
        status: String,
        summary: String,
        access: [MacAssistantAccessItem],
        watchTemplates: [MacAssistantWatchTemplate],
        blockedAccessCount: Int,
        templateAttentionCount: Int,
        schedulerActions: [String],
        lazyContract: JSONValue,
        createdAt: String,
        lightweight: Bool = false
    ) {
        self.status = status
        self.summary = summary
        self.access = access
        self.watchTemplates = watchTemplates
        self.blockedAccessCount = blockedAccessCount
        self.templateAttentionCount = templateAttentionCount
        self.schedulerActions = schedulerActions
        self.lazyContract = lazyContract
        self.createdAt = createdAt
        self.lightweight = lightweight
    }

    public func projected(lightweight: Bool) -> Self {
        Self(status: status, summary: summary,
             access: lightweight ? Array(access.prefix(5)) : access,
             watchTemplates: lightweight ? Array(watchTemplates.prefix(3)) : watchTemplates,
             blockedAccessCount: blockedAccessCount, templateAttentionCount: templateAttentionCount,
             schedulerActions: schedulerActions, lazyContract: lazyContract, createdAt: createdAt,
             lightweight: lightweight)
    }

    public func toJSON() -> JSONValue {
        let accessJSON = access.map { $0.toJSON() }
        let templatesJSON = watchTemplates.map { $0.toJSON() }
        func project(_ rows: [JSONValue], keys: [String]) -> [JSONValue] {
            guard lightweight else { return rows }
            return rows.map { row in
                guard case .object(let object) = row else { return row }
                return .object(object.filter { keys.contains($0.key) && Self.isTruthy($0.value) })
            }
        }
        return .object([
            "status": .string(status),
            "summary": .string(summary),
            "access": .array(project(accessJSON, keys: ["id", "title", "status", "setupRoute", "nextStep"])),
            "watchTemplates": .array(project(templatesJSON, keys: ["id", "title", "status", "summary", "scheduleLabel", "sources", "requiredAccess", "actionIds"])),
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
    func localStatuses() async -> [String: [String: JSONValue]]
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
    private let watchCatalog: @Sendable () async throws -> [MacAssistantWatchRecipe]

    public init(
        loadTrustPolicy: @escaping @Sendable () async -> [String: JSONValue],
        proofs: ConnectorProofProvider,
        push: MobilePushStatusProvider,
        dispatcherTools: DispatcherToolAvailabilityProvider,
        localPIM: LocalPIMStatusProvider,
        watchCatalog: @escaping @Sendable () async throws -> [MacAssistantWatchRecipe]
    ) {
        self.loadTrustPolicy = loadTrustPolicy
        self.proofs = proofs
        self.push = push
        self.dispatcherTools = dispatcherTools
        self.localPIM = localPIM
        self.watchCatalog = watchCatalog
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

        let pushStatus = await push.pushStatus()
        // Ready means proven: a successful Mac action receipt in the proof
        // window. A switch that is on is only waiting for that proof.
        let macProven = await proofs.proofStatus(provider: "mac")["verified"] == .bool(true)
        let macState = !macEnabled ? "needs_policy" : macProven ? "ready" : "probe_needed"
        let macNotificationsState = !(macEnabled && notificationsAllowed) ? "needs_policy" : "probe_needed"

        let pushState: String
        switch (pushStatus["status"].flatMap { if case .string(let s) = $0 { s.lowercased() } else { nil } }) {
        case "ok", "ready": pushState = "ready"
        case "failed", "error": pushState = "failed"
        case "configured": pushState = "probe_needed"
        default: pushState = pushStatus["tokenConfigured"] == .bool(true) ? "probe_needed" : "needs_setup"
        }
        var pushNextStep = ""
        if case .string(let s)? = pushStatus["nextStep"] { pushNextStep = s }

        let localStatuses = await localPIM.localStatuses()
        func localAccessState(id: String, toolName: String) async -> (status: String, detail: String?, nextStep: String?) {
            let local = localStatuses[id] ?? [:]
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

        let access: [MacAssistantAccessItem] = [
            MacAssistantAccessItem(
                id: "mac_control",
                title: "Mac Control Bridge",
                status: macState,
                detail: "App-owned local control bridge for shortcuts, notifications, file reads, and Apple Events.",
                setupRoute: "sidebar:trust",
                requiredFor: ["local_mail", "local_calendar", "local_reminders", "mac_notifications"],
                nextStep: !macEnabled ? "Enable Mac Control in Trust Center." : macProven ? "" : "Run mac.self_test once to prove the bridge.",
                actionIds: ["mac.self_test"]
            ),
            MacAssistantAccessItem(
                id: "mac_notifications",
                title: "Mac Notifications",
                status: macNotificationsState,
                detail: "Posts local macOS notifications through the app-owned bridge.",
                setupRoute: "sidebar:trust",
                requiredFor: ["watch_receipts"],
                nextStep: "Enable Mac Control notifications and send a test notification.",
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
            let states = required.map { statusById[$0] ?? "unavailable" }
            if !states.isEmpty && states.allSatisfy({ $0 == "ready" }) { return "ready" }
            if states.contains("unavailable") { return "unavailable" }
            if states.contains("failed") { return "failed" }
            if states.contains("needs_setup") { return "needs_setup" }
            if states.contains("needs_policy") { return "needs_policy" }
            if states.contains("needs_permission") { return "needs_permission" }
            return "probe_needed"
        }

        let templates = try await watchCatalog().map { recipe in
            MacAssistantWatchTemplate(recipe: recipe, status: templateStatus(recipe.requiredAccess))
        }

        let blocked = access.filter { !["ready", "probe_needed"].contains($0.status) }.count
        let unproven = access.contains { $0.status == "probe_needed" }
        let templateAttention = templates.filter { $0.status != "ready" }.count

        let lazyContract: JSONValue = .object([
            "chatInjection": .string("none"),
            "watchBodiesLoaded": .bool(false),
            "jobCreation": .string("explicit scheduler action only"),
            "providerProbe": .string("status/read action only, never during status rendering"),
        ])
        let createdAt = NativeTimestampFormat.fractionalUTCOffset(Date())

        return MacAssistantStatusResult(
            status: blocked > 0 ? "attention" : (unproven ? "probe_needed" : "ready"),
            summary: "Mac assistant watch setup is manifest-only here; no watcher jobs are created until scheduler.schedule_job is called.",
            access: access,
            watchTemplates: templates,
            blockedAccessCount: blocked,
            templateAttentionCount: templateAttention,
            schedulerActions: ["scheduler.schedule_job", "scheduler.create_job", "scheduler.list_jobs", "scheduler.cancel_job"],
            lazyContract: lazyContract,
            createdAt: createdAt
        ).projected(lightweight: lightweight)
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
}

// MARK: - Factory

public func makeMacAssistantStatusClient(
    loadTrustPolicy: (@Sendable () async -> [String: JSONValue])? = nil,
    proofs: ConnectorProofProvider,
    push: MobilePushStatusProvider,
    dispatcherTools: DispatcherToolAvailabilityProvider,
    localPIM: LocalPIMStatusProvider,
    watchCatalog: @escaping @Sendable () async throws -> [MacAssistantWatchRecipe]
) -> any MacAssistantStatusClient {
    let loader: @Sendable () async -> [String: JSONValue] = loadTrustPolicy ?? {
        await SwiftNativeTrustCenter().loadTrustPolicy()
    }
    return SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: loader,
        proofs: proofs,
        push: push,
        dispatcherTools: dispatcherTools,
        localPIM: localPIM,
        watchCatalog: watchCatalog
    )
}

extension MacAssistantStatusResult {
    public static func mailReadiness(from result: JSONValue) -> (status: String, word: String, next: String?) {
        guard case .object(let out) = result else {
            return ("failed", "Check failed", "Mail gave no answer I could read.")
        }
        let text = { (key: String) -> String? in
            if case .string(let s)? = out[key], !s.isEmpty { return s }
            return nil
        }
        switch text("status") {
        case "completed":
            return ("ready", "Ready", nil)
        case "denied":
            return ("needs_permission", "Needs macOS permission",
                    "Allow NativeAgent to control Mail in System Settings → Privacy & Security → Automation.")
        default:
            if text("reason") == "not_configured" {
                return ("needs_setup", "Needs setup", text("fix"))
            } else {
                return ("failed", "Check failed", text("error") ?? text("reason").map { "Mail said: \($0.replacingOccurrences(of: "_", with: " "))." })
            }
        }
    }
}
