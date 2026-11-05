import ActivityWatch
import Foundation
import MacControl
import MacIntegration
import NativeAgentShared
import TrustCenter
// Blueprint: | `EngineTrustFace+Readings.swift` | Trust's security, system grants, watches and activity readings with source failures |

extension NativeAgentEngine {
    /// The watches as the Mac-assistant owner last published them; computing them is that owner's refresh, never a page read.
    @MainActor func trustWatchesFace() async -> PartFace.Section {
        do {
            let status: MacAssistantStatusResult
            switch macIntegration.watchState {
            case .current(let response), .stale(let response, _): status = response
            case .loading:
                return .init(id: "watches", title: "Background watches", style: .note,
                    rows: [.init(id: "watches.reading", title: "Reading the background watches…", tone: .quiet)])
            case .unavailable(let message): throw PartCallError(code: "watches_unavailable", message: message)
            }
            var rows: [PartFace.Row] = status.watchTemplates.map {
                .init(id: "watch." + $0.id, title: $0.displayTitle, detail: $0.displaySummary, value: $0.status)
            }
            rows += status.access.map { item in
                .init(id: item.id == "local_mail" ? "watches.mail" : "watch.access." + item.id,
                    title: item.title, detail: [item.detail, item.nextStep ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"),
                    value: item.status, open: item.id == "iphone_push" && item.status != "ready" ? "page:pairing" : nil,
                    actions: item.id == "local_mail" ? [.init(id: "check_mail", label: "Check Mail")] : nil)
            }
            return .init(id: "watches", title: "Background watches", footer: status.summary
                + " These are ready-made watches; none runs until you ask to schedule it.", rows: rows)
        } catch { return trustFaceFailure("watches", "Background watches", error) }
    }

    @MainActor func trustSecurityFace() async -> [PartFace.Section] {
        var sections: [PartFace.Section] = []
        do {
            let status = try await SwiftNativeSecurityCenter(dataRoot: dataRoot).status(limit: 10)
            var rows: [PartFace.Row] = [
                .init(id: "security.mode", title: "Mode", value: status.mode),
                .init(id: "trust.developer_mode", title: "Developer mode",
                    detail: "Destructive actions on this Mac; the riskiest setting.", value: status.developerMode ? "On" : "Off"),
                trustFaceToggle("trust.pause_everything", "Pause everything", status.killSwitchEnabled,
                    "On, every action stops until you lift it.", safe: true)
            ]
            rows += status.flags.filter { $0.id != "security_center" }.map {
                .init(id: "security.flag." + $0.id, title: $0.title, detail: $0.detail, value: $0.enabled ? $0.status : "off")
            }
            sections.append(.init(id: "security", title: "Security", rows: rows))
            sections.append(.init(id: "security_receipts", title: "Recent security receipts", style: .timeline,
                footer: status.recentReceipts.isEmpty ? "No receipts recorded." : status.auditReceiptsPath, rows: status.recentReceipts.map {
                    .init(id: "security.receipt." + $0.id, title: $0.tool, detail: $0.reason + " · " + $0.surface + " · " + $0.risk,
                        value: $0.decision, at: $0.at)
                }))
        } catch { sections.append(trustFaceFailure("security", "Security", error)) }
        switch await trust.auditLog(limit: 100) {
        case .entries(let entries, let malformed):
            sections.append(.init(id: "mac_audit", title: "Mac control audit", style: .timeline,
                footer: malformed > 0 ? "Could not decode \(malformed) audit entries."
                    : entries.isEmpty ? "No Mac control receipts recorded." : nil,
                rows: entries.map { .init(id: "audit." + $0.id, title: $0.action, detail: $0.detail,
                    value: $0.allowed.map { $0 ? "Allowed" : "Blocked" } ?? "Outcome not recorded", at: $0.ts) }))
        case .unreadable(let detail):
            sections.append(.init(id: "mac_audit", title: "Mac control audit", rows: [
                .init(id: "audit.unavailable", title: "Could not read the audit log", detail: detail, tone: .failed)
            ]))
        }
        return sections
    }

    @MainActor func trustSystemFace() -> PartFace.Section {
        var labels = Dictionary(uniqueKeysWithValues: MacIntegrationFrameworkPermission.allCases.map { ($0.rawValue, $0.label) })
        labels["accessibility"] = "Accessibility"
        labels["screenRecording"] = "Screen Recording"
        labels["fullDiskAccess"] = "Full Disk Access"
        for app in AppleScriptExecution.automationTargetApps { labels[AppleScriptExecution.automationStatusKey(app: app)] = app + " automation" }
        var rows = macIntegration.systemStatuses.sorted { $0.key < $1.key }.map { key, status in
            PartFace.Row(id: "system." + key, title: labels[key] ?? key, detail: "macOS privacy grant; separate from app Read and Write permissions.",
                value: status)
        }
        if rows.isEmpty {
            rows.append(.init(id: "system.unavailable", title: "macOS grants have not published a reading.", tone: .attention))
        }
        rows.append(.init(id: "system.controls", title: "macOS permissions",
            detail: "Only you can grant access, in the foreground on this Mac. Ordinary text chat needs none of these grants.",
            actions: [.init(id: "macos_permissions", label: "Open permission controls on this Mac")]))
        return .init(id: "system", title: "System permissions", rows: rows)
    }

    @MainActor func trustActivityFace() async -> [PartFace.Section] {
        let controller = activityWatch
        var rows: [PartFace.Row] = []
        do {
            let policy = try await controller.checkedPolicy()
            rows.append(trustFaceToggle("trust.activity_capture", "Record which apps you use", policy.captureEnabled,
                "Records the app in front and its duration. Nothing was recorded before you enabled it."))
            let titles = ActivityPolicy.TitleCapture(policy: policy)
            rows.append(.init(id: "activity.titles", title: "Window titles",
                detail: "Redaction removes shaped secrets, not private content. Browser titles include private browsing; macOS cannot reliably identify it.",
                control: .choice([
                    .init(id: "apps", label: "App names only"), .init(id: "windows", label: "Window titles"),
                    .init(id: "browsers", label: "Window and browser titles")
                ], selected: titles == .appNamesOnly ? "apps" : titles == .windowTitles ? "windows" : "browsers",
                    confirm: "Change which window titles are recorded? Titles may reveal private information even after redaction.")))
            let full = trust.policy.map(TrustAccessModeCapabilityCatalog.fullMacGrantIsActive) == true
            rows.append(full ? .init(id: "trust.activity_model_access", title: "Let me answer from activity history",
                detail: "When I answer from it, the answer goes to the chat's AI provider. The database stays on this Mac.", value: "On with Full Mac")
                : .init(id: "trust.activity_model_access", title: "Let me answer from activity history",
                    detail: "Answers reach the chat's AI provider; the database stays on this Mac. Recording must be on.",
                    value: !policy.captureEnabled ? "Recording is off" : nil,
                    control: policy.captureEnabled ? .toggle(policy.allowModelAccess,
                        confirm: policy.allowModelAccess ? nil : "Let me use recorded activity in answers sent to your chat provider?") : nil))
            rows.append(.init(id: "activity.retention", title: "Keep history for",
                detail: "Older history is deleted at cleanup. Shortening this removes the extra at the next cleanup.",
                control: .choice([7, 14, 30, 90].map { .init(id: String($0), label: "\($0) days") }, selected: String(policy.retentionDays),
                    confirm: "Change how long recorded activity is kept?")))
            rows += controller.removableExclusions.map { id in
                .init(id: "activity.excluded." + id, title: id, value: "Excluded",
                    control: .toggle(true, confirm: "Allow activity recording for this app again?"))
            }
            rows.append(.init(id: "activity.exclude", title: "Exclude an app",
                detail: "Skips the app before reading its name or title, and permanently deletes its recorded history.",
                actions: [.init(id: "exclude_app", label: "Choose an app on this Mac")]))
        } catch {
            rows.append(.init(id: "activity.unavailable", title: "Activity settings unavailable", detail: error.localizedDescription, tone: .failed))
        }
        rows += controller.presentationIssues.map { issue in
            .init(id: "activity.issue." + issue.id.uuidString, title: "Activity capture notice", detail: issue.message,
                at: ISO8601DateFormatter().string(from: issue.occurredAt), tone: issue.severity == .notice ? .quiet : .failed)
        }
        if let purged = controller.lastPurgedRowCount {
            rows.append(.init(id: "activity.deleted", title: "Last deletion", value: "\(purged) recorded spans deleted"))
        }
        rows.append(.init(id: "activity.wipe", title: "Delete all recorded activity",
            detail: "Permanently deletes the record, including recovery logs. Settings stay; if recording is on it keeps going.",
            actions: [.init(id: "wipe", label: "Delete everything", role: .destructive)]))
        return [.init(id: "activity", title: "Activity capture", footer:
            "Never records typed text, field contents or screenshots, or while locked or asleep. "
                + "The history never leaves this Mac: no iCloud, backup or export. "
                + "My own windows and the lock screen are always excluded.", rows: rows)]
    }
}
