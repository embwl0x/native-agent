import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacAssistantStatus.swift` | `Resources/abilities/mac-watch-catalog.js`: Checked readiness verdicts beside the catalog part's words; never creates jobs |

// Status rendering reads readiness evidence and never creates watch jobs.

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
    public let actionIds: [String]
    public let jobPayload: JSONValue
    public let displayTitle: String
    public let displaySummary: String
}

/// The catalog part's words for one access row; the row's status, route and ids stay native.
public struct MacAssistantAccessWords: Codable, Sendable, Equatable {
    public let title: String
    public let detail: String
    public let nextStep: String?
}

/// What the catalog part returns: inactive recipes, each access row's words and the status summary.
public struct MacAssistantWatchCatalog: Codable, Sendable, Equatable {
    public let recipes: [MacAssistantWatchRecipe]
    public let access: [String: MacAssistantAccessWords]
    public let summary: String
}

/// A row the catalog part gives no words for is a part to repair, never a row drawn without them.
public struct MacAssistantMissingWords: LocalizedError {
    public let id: String
    public var errorDescription: String? {
        "The mac-watch-catalog part gives no words for access row \(id). Repair its access table; no status was composed."
    }
}

public struct MacAssistantWatchTemplate: Sendable, Equatable, Identifiable {
    public let recipe: MacAssistantWatchRecipe
    public let status: String
    public let requiredAccess: [String]
    public let readinessIssue: String?
    public var id: String { recipe.id }
    public var title: String { recipe.title }
    public var summary: String { recipe.summary }
    public var scheduleLabel: String { recipe.scheduleLabel }
    public var sources: [String] { recipe.sources }
    public var actionIds: [String] { recipe.actionIds }
    public var jobPayload: JSONValue { recipe.jobPayload }
    public var displayTitle: String { recipe.displayTitle }
    public var displaySummary: String { recipe.displaySummary }

    public init(recipe: MacAssistantWatchRecipe, access: [MacAssistantAccessItem]) {
        self.recipe = recipe
        guard case .object(let job) = recipe.jobPayload, job["kind"] == .string("connector_action"),
              case .object(let payload)? = job["payload"], case .string(let action)? = payload["actionId"], !action.isEmpty else {
            status = "unavailable"
            requiredAccess = []
            readinessIssue = "The watch payload does not name a connector action to read. Repair its catalog recipe."
            return
        }
        guard let source = access.first(where: { $0.actionIds?.contains(action) == true }) else {
            status = "unavailable"
            requiredAccess = []
            readinessIssue = "No access reading owns the watch's action \(action). Its readiness is unavailable."
            return
        }
        status = source.status
        requiredAccess = [source.id]
        readinessIssue = source.nextStep
    }

    public func toJSON() -> JSONValue {
        var fields: [String: JSONValue] = [
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
        ]
        if let readinessIssue, !readinessIssue.isEmpty { fields["readinessIssue"] = .string(readinessIssue) }
        return .object(fields)
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

    /// Sampling time is not a change in watch content; the caller still receives its own reading's timestamp.
    public func hasSameContent(as other: Self) -> Bool {
        status == other.status && summary == other.summary && access == other.access && watchTemplates == other.watchTemplates
            && blockedAccessCount == other.blockedAccessCount && templateAttentionCount == other.templateAttentionCount
            && schedulerActions == other.schedulerActions && lazyContract == other.lazyContract && lightweight == other.lightweight
    }

    public func toJSON() -> JSONValue {
        let accessJSON = access.map { $0.toJSON() }
        let templatesJSON = watchTemplates.map { $0.toJSON() }
        func project(_ rows: [JSONValue], keys: [String]) -> [JSONValue] {
            guard lightweight else { return rows }
            return rows.map { row in
                guard case .object(let object) = row else { return row }
                return .object(object.filter { keys.contains($0.key) && $0.value.isTruthy })
            }
        }
        return .object([
            "status": .string(status),
            "summary": .string(summary),
            "access": .array(project(accessJSON, keys: ["id", "title", "status", "setupRoute", "nextStep"])),
            "watchTemplates": .array(project(templatesJSON, keys: ["id", "title", "status", "summary", "scheduleLabel", "sources", "requiredAccess",
                "actionIds", "readinessIssue"])),
            "blockedAccessCount": .int(Int64(blockedAccessCount)),
            "templateAttentionCount": .int(Int64(templateAttentionCount)),
            "schedulerActions": .array(schedulerActions.map { .string($0) }),
            "createsJobs": .bool(createsJobs),
            "lazyContract": lazyContract,
            "createdAt": .string(createdAt),
        ])
    }
}

// MARK: - Client protocol

public protocol MacAssistantStatusClient: Sendable {
    func macAssistantStatus(lightweight: Bool) async throws -> MacAssistantStatusResult
}

extension MacAssistantStatusResult {
    public static func compose(
        macControl: (status: String, nextStep: String), notifications: (status: String, nextStep: String),
        pushStatus: [String: JSONValue],
        availableTools: Set<String>, localStatuses: [String: [String: JSONValue]],
        schedulerActions: [String],
        watchCatalog: @Sendable () async throws -> MacAssistantWatchCatalog
    ) async throws -> MacAssistantStatusResult {
        let catalog = try await watchCatalog()
        func words(_ id: String) throws -> MacAssistantAccessWords {
            guard let words = catalog.access[id] else { throw MacAssistantMissingWords(id: id) }
            return words
        }
        func step(_ words: MacAssistantAccessWords, _ id: String) throws -> String {
            guard let next = words.nextStep else { throw MacAssistantMissingWords(id: id + ".nextStep") }
            return next
        }
        let pushState: String
        switch (pushStatus["status"].flatMap { if case .string(let s) = $0 { s.lowercased() } else { nil } }) {
        case "ok", "ready": pushState = "ready"
        case "failed", "error": pushState = "failed"
        case "configured": pushState = "probe_needed"
        default: pushState = pushStatus["tokenConfigured"] == .bool(true) ? "probe_needed" : "needs_setup"
        }
        var pushNextStep = ""
        if case .string(let s)? = pushStatus["nextStep"] { pushNextStep = s }

        func localAccessState(id: String, toolName: String) -> (status: String, detail: String?, nextStep: String?) {
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
            let available = availableTools.contains(toolName)
            return (available ? "probe_needed" : "unavailable", detail, nextStep)
        }

        let mailTool = "mail.recent"
        let calendarTool = "mac_calendar_list_upcoming"
        let remindersTool = "mac_reminders_list_due_today"
        let mailAccess = localAccessState(id: "local_mail", toolName: mailTool)
        let calAccess = localAccessState(id: "local_calendar", toolName: calendarTool)
        let remAccess = localAccessState(id: "local_reminders", toolName: remindersTool)
        let mailState = mailAccess.status
        let calState = calAccess.status
        let remState = remAccess.status

        let control = try words("mac_control"), notified = try words("mac_notifications"), push = try words("iphone_push")
        let mail = try words("local_mail"), calendar = try words("local_calendar"), reminders = try words("local_reminders")
        let access: [MacAssistantAccessItem] = [
            MacAssistantAccessItem(
                id: "mac_control",
                title: control.title,
                status: macControl.status,
                detail: control.detail,
                setupRoute: "sidebar:trust",
                requiredFor: ["mac_notifications"],
                nextStep: macControl.nextStep,
                actionIds: ["mac.self_test"]
            ),
            MacAssistantAccessItem(
                id: "mac_notifications",
                title: notified.title,
                status: notifications.status,
                detail: notified.detail,
                setupRoute: "sidebar:trust",
                requiredFor: ["watch_receipts"],
                nextStep: notifications.nextStep,
                actionIds: ["notify.mac"]
            ),
            MacAssistantAccessItem(
                id: "iphone_push",
                title: push.title,
                status: pushState,
                detail: push.detail,
                setupRoute: "sidebar:settings",
                requiredFor: ["remote_watch_receipts"],
                nextStep: pushNextStep,
                actionIds: ["notify.phone"]
            ),
            MacAssistantAccessItem(
                id: "local_mail",
                title: mail.title,
                status: mailState,
                detail: mail.detail + (mailAccess.detail.map { " \($0)" } ?? ""),
                setupRoute: "sidebar:trust",
                requiredFor: ["local_mail_watch"],
                nextStep: try mailAccess.nextStep ?? (mailState == "ready" ? "" : step(mail, "local_mail")),
                actionIds: ["mail.recent"],
                toolNames: [mailTool, "mail.search"]
            ),
            MacAssistantAccessItem(
                id: "local_calendar",
                title: calendar.title,
                status: calState,
                detail: calendar.detail + (calAccess.detail.map { " \($0)" } ?? ""),
                setupRoute: "sidebar:trust",
                requiredFor: ["local_calendar_watch"],
                nextStep: try calAccess.nextStep ?? (calState == "ready" ? "" : step(calendar, "local_calendar")),
                actionIds: ["calendar.upcoming"],
                toolNames: [calendarTool]
            ),
            MacAssistantAccessItem(
                id: "local_reminders",
                title: reminders.title,
                status: remState,
                detail: reminders.detail + (remAccess.detail.map { " \($0)" } ?? ""),
                setupRoute: "sidebar:trust",
                requiredFor: ["local_reminders_watch"],
                nextStep: try remAccess.nextStep ?? (remState == "ready" ? "" : step(reminders, "local_reminders")),
                actionIds: ["reminders.due_today"],
                toolNames: [remindersTool]
            ),
        ]

        let templates = catalog.recipes.map { recipe in
            MacAssistantWatchTemplate(recipe: recipe, access: access)
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
            summary: catalog.summary,
            access: access,
            watchTemplates: templates,
            blockedAccessCount: blocked,
            templateAttentionCount: templateAttention,
            schedulerActions: schedulerActions,
            lazyContract: lazyContract,
            createdAt: createdAt
        )
    }
}

extension MacAssistantStatusResult {
    public static func mailReadiness(from result: JSONValue) -> (status: String, word: String, next: String?) {
        guard case .object(let out) = result else {
            return ("unavailable", "Coverage unavailable", "Mail gave no answer I could read. Use Check Mail again when Mail is available.")
        }
        let text = { (key: String) -> String? in
            if case .string(let s)? = out[key], !s.isEmpty { return s }
            return nil
        }
        switch text("status") {
        case "completed":
            guard text("account_coverage") == "complete" else {
                return ("unavailable", "Coverage unavailable", """
                    Mail did not establish account coverage. Use Check Mail again to read the current mailbox accounts.
                    """)
            }
            return ("ready", "Ready", nil)
        case "partial":
            guard text("account_coverage") == "partial",
                  case .array(let gaps)? = out["accounts_not_listed"], !gaps.isEmpty,
                  let message = text("message") else {
                return ("unavailable", "Coverage unavailable", """
                    Mail did not identify its account coverage gaps. Use Check Mail again to read the current mailbox accounts.
                    """)
            }
            var next = "Open Mail, check account and mailbox availability, then use Check Mail again."
            next = message + " " + next
            return ("ready", "Ready with account gaps", next)
        case "denied":
            return ("needs_permission", "Needs macOS permission",
                    "Allow NativeAgent to control Mail in System Settings → Privacy & Security → Automation.")
        case "failed":
            if text("reason") == "mailbox_coverage_unavailable" {
                return ("unavailable", "Coverage unavailable", text("message"))
            }
            if text("reason") == "not_configured" {
                return ("needs_setup", "Needs setup", text("fix"))
            } else {
                return ("failed", "Check failed", text("error") ?? text("reason").map { "Mail said: \($0.replacingOccurrences(of: "_", with: " "))." })
            }
        default:
            return ("unavailable", "Coverage unavailable", "Mail returned no recognized read outcome. Use Check Mail again when Mail is available.")
        }
    }
}
