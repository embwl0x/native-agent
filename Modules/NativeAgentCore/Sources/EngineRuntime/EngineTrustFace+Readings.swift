import ActivityWatch
import AppToolRuntime
import Foundation
import MacControl
import MacIntegration
import NativeAgentShared
import TrustCenter
// Blueprint: | `EngineTrustFace+Readings.swift` | Trust's security, live macOS grants (the reach and per-app Automation), watches and activity readings with source failures; each action its door call |

extension NativeAgentEngine {
    /// The watches as the Mac-assistant owner last published them; computing them is that owner's refresh, never a page read.
    func trustWatchesFace() async -> PartFace.Section {
        let watchState = await macIntegration.watchState
        do {
            let status: MacAssistantStatusResult
            let issue: String?
            switch watchState {
            case .current(let response): (status, issue) = (response, nil)
            case .stale(let response, let message): (status, issue) = (response, "Last watch reading; refresh failed: " + message)
            case .loading:
                return .init(id: "watches", title: "Background watches", style: .note,
                    rows: [.init(id: "watches.reading", title: "Reading the background watches…", tone: .quiet)])
            case .unavailable(let message): throw PartCallError(code: "watches_unavailable", message: message)
            }
            var rows: [PartFace.Row] = status.watchTemplates.map {
                .init(id: "watch." + $0.id, title: $0.displayTitle,
                    detail: [$0.displaySummary, $0.readinessIssue ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"), value: $0.status)
            }
            rows += status.access.map { item in
                .init(id: item.id == "local_mail" ? "watches.mail" : "watch.access." + item.id,
                    title: item.title, detail: [item.detail, item.nextStep ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"),
                    value: item.status, open: item.id == "iphone_push" && item.status != "ready" ? "page:pairing" : nil,
                    actions: item.id == "local_mail" ? [.init(id: "check_mail", label: "Check Mail", doors: ["mac"],
                                                              call: PartFace.Call("trust.check_mail"))] : nil)
            }
            return .init(id: "watches", title: "Background watches", footer: status.summary
                + " These are ready-made watches; none runs until you ask to schedule it." + (issue.map { " " + $0 } ?? ""), rows: rows)
        } catch { return trustFaceFailure("watches", "Background watches", error) }
    }

    func trustSecurityFace() async -> [PartFace.Section] {
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
                .init(id: "security.flag." + $0.id, title: $0.title, detail: $0.detail, value: $0.status)
            }
            sections.append(.init(id: "security", title: "Security", rows: rows))
            sections.append(.init(id: "security_receipts", title: "Recent security receipts", style: .timeline,
                footer: status.recentReceipts.isEmpty ? status.flags.first { $0.id == "audit_receipts" }?.detail : status.auditReceiptsPath,
                rows: status.recentReceipts.map {
                    .init(id: "security.receipt." + $0.id, title: $0.tool, detail: $0.reason + " · " + $0.surface + " · " + $0.risk,
                        value: $0.decision, at: $0.at)
                }))
        } catch { sections.append(trustFaceFailure("security", "Security", error)) }
        switch await trust.auditLog(limit: 100) {
        case .entries(let entries, let malformed):
            sections.append(.init(id: "mac_audit", title: "Mac control audit", style: .timeline,
                footer: malformed > 0 ? "Could not decode \(malformed) audit entries."
                    : entries.isEmpty ? "No Mac control refusal receipts retained in the experience record. The Mac Control inventory counts operation files."
                        : nil,
                rows: entries.map { .init(id: "audit." + $0.id, title: $0.action, detail: $0.detail,
                    value: $0.allowed.map { $0 ? "Allowed" : "Blocked" } ?? "Outcome not recorded", at: $0.ts) }))
        case .unreadable(let detail):
            sections.append(.init(id: "mac_audit", title: "Mac control audit", rows: [
                .init(id: "audit.unavailable", title: "Could not read the audit log", detail: detail, tone: .failed)
            ]))
        }
        return sections
    }

    /// The reach on this Mac: each macOS grant read live and without prompting, as the permission card reads it and in the order a card asks;
    /// never a saved copy. Automation is per app, read by the Mac-access owner's last non-prompting probe, and asked in context the first time
    /// that app is needed. Asking and opening System Settings are the person's levers, in the foreground on this Mac (`trust.ask_grant`,
    /// `trust.grant_settings`); the agent asks with its own permission card.
    func trustSystemFace() async -> PartFace.Section {
        let systemStatuses = await macIntegration.systemStatuses
        // A grant is asked in the foreground on this Mac, so its actions run from the Mac door only; each names its own grant targets.
        func ask(_ targets: [String], _ label: String = "Ask macOS") -> PartFace.Action {
            .init(id: "ask", label: label, role: .primary, doors: ["mac"],
                  call: PartFace.Call("trust.ask_grant", ["targets": .array(targets.map { .string($0) })]))
        }
        func open(_ target: String) -> PartFace.Action {
            .init(id: "open_settings", label: "Open System Settings", doors: ["mac"],
                  call: PartFace.Call("trust.grant_settings", ["target": .string(target)]))
        }
        var rows: [PartFace.Row] = []
        var off = 0
        for target in SystemPermissionPreflight.frictionOrder(trustReachGrants.map { "privacy:" + $0.rawValue }) {
            guard let gate = SystemPermissionPreflight.cardSettingsCapability(target) else { continue }
            let path = "Turned on in " + SystemPermissionPreflight.settingsPath(gate) + "."
            if await SystemPermissionPreflight.cardBlockReason([target], mode: nil) != nil {
                off += 1
                rows.append(.init(id: "grant." + gate.rawValue, title: gate.displayName, detail: path, value: "Not granted", tone: .attention,
                    actions: [ask([target]), open(target)]))
            } else {
                let restart = !SystemPermissionPreflight.launchPending([target]).isEmpty
                rows.append(.init(id: "grant." + gate.rawValue, title: gate.displayName, detail: path,
                    value: restart ? "Granted, takes effect after one restart" : "Granted", tone: restart ? .attention : .done,
                    actions: [open(target)]))
            }
        }
        for app in AppleScriptExecution.automationTargetApps {
            guard let bundle = AppleScriptExecution.automationTargetBundleIDs[app] else { continue }
            let id = "grant.automation." + app.lowercased(), title = "Automation for " + app, target = "applescript:" + bundle
            let detail = "Asked in context, the first time \(app) is needed."
            guard let state = systemStatuses[AppleScriptExecution.automationStatusKey(app: app)] else {
                off += 1
                rows.append(.init(id: id, title: title, detail: detail, value: "Not read yet", tone: .attention, actions: [open(target)]))
                continue
            }
            let words = ["granted": "Granted", "denied": "Denied", "not_determined": "Not set", "app_not_running": "Unverified, app not running"]
            if state != "granted" { off += 1 }
            rows.append(.init(id: id, title: title, detail: detail, value: words[state] ?? state.capitalized,
                tone: state == "granted" ? .done : .attention,
                actions: ["not_determined", "unknown", "app_not_running"].contains(state) ? [ask([target]), open(target)] : [open(target)]))
        }
        rows.append(off == 0 ? PartFace.Row(id: "grant.all", title: "Every grant is on", tone: .done)
            : PartFace.Row(id: "grant.all", title: "Ask for every prompt not yet answered",
                detail: "Speech Recognition, Microphone, Calendar, Reminders, Contacts and app Automation ask in place; the switches above "
                    + "that macOS keeps in System Settings open there.",
                actions: [ask(MacIntegrationFrameworkPermission.allCases.map { "privacy:" + $0.capability.rawValue }
                    + AppleScriptExecution.automationTargetApps.compactMap { AppleScriptExecution.automationTargetBundleIDs[$0].map { "applescript:" + $0 } },
                    "Ask for each one")]))
        return .init(id: "system", title: "macOS grants", footer: "Separate from the app Read and Write switches above. Only you grant access, "
            + "in the foreground on this Mac; ordinary text chat needs none. My greeting raises one permission card for every grant still off; "
            + "Full Mac stays your own switch, under Access and policy.", rows: rows)
    }

    func trustActivityFace() async -> [PartFace.Section] {
        let (controller, state) = await MainActor.run {
            let controller = activityWatch
            return (controller, (policy: trust.policy, issues: controller.presentationIssues,
                                 purged: controller.lastPurgedRowCount))
        }
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
                    confirm: "Change which window titles are recorded? Titles may reveal private information even after redaction.",
                    call: settingSetCall("trust.activity_titles"))))
            let full = state.policy.map(TrustAccessModeCapabilityCatalog.fullMacGrantIsActive) == true
            rows.append(full ? .init(id: "trust.activity_model_access", title: "Let me answer from activity history",
                detail: "When I answer from it, the answer goes to the chat's AI provider. The database stays on this Mac.", value: "On with Full Mac")
                : .init(id: "trust.activity_model_access", title: "Let me answer from activity history",
                    detail: "Answers reach the chat's AI provider; the database stays on this Mac. Recording must be on.",
                    value: !policy.captureEnabled ? "Recording is off" : nil,
                    control: policy.captureEnabled ? .toggle(policy.allowModelAccess,
                        confirm: policy.allowModelAccess ? nil : "Let me use recorded activity in answers sent to your chat provider?",
                        call: settingSetCall("trust.activity_model_access")) : nil))
            rows.append(.init(id: "activity.retention", title: "Keep history for",
                detail: "Older history is deleted at cleanup. Shortening this removes the extra at the next cleanup.",
                control: .choice(QuietSettings.activityRetentionChoices.map { .init(id: $0, label: "\($0) days") },
                    selected: String(policy.retentionDays), confirm: "Change how long recorded activity is kept?",
                    call: settingSetCall("trust.activity_retention"))))
            rows += policy.excludedBundleIDs.subtracting(ActivityPolicy.alwaysExcludedBundleIDs).sorted().map { id in
                .init(id: "activity.excluded." + id, title: id, value: "Excluded",
                    control: .toggle(true, confirm: "Allow activity recording for this app again?", call: settingSetCall("trust.activity_excluded_" + id)))
            }
            rows.append(.init(id: "activity.exclude", title: "Exclude an app",
                detail: "Skips the app before reading its name or title, and permanently deletes its recorded history.",
                actions: [.init(id: "exclude_app", label: "Choose an app on this Mac", doors: ["mac"], call: PartFace.Call("trust.exclude_app"))]))
        } catch {
            rows.append(.init(id: "activity.unavailable", title: "Activity settings unavailable", detail: error.localizedDescription, tone: .failed))
        }
        rows += state.issues.map { issue in
            .init(id: "activity.issue." + issue.id.uuidString, title: "Activity capture notice", detail: issue.message,
                at: ISO8601DateFormatter().string(from: issue.occurredAt), tone: issue.severity == .notice ? .quiet : .failed)
        }
        if let purged = state.purged {
            rows.append(.init(id: "activity.deleted", title: "Last deletion", value: "\(purged) recorded spans deleted"))
        }
        rows.append(.init(id: "activity.wipe", title: "Delete all recorded activity",
            detail: "Permanently deletes the record, including recovery logs. Settings stay; if recording is on it keeps going.",
            actions: [.init(id: "wipe", label: "Delete everything", role: .destructive, call: PartFace.Call("history.clear"))]))
        return [.init(id: "activity", title: "Activity capture", footer:
            "Never records typed text, field contents or screenshots, or while locked or asleep. "
                + "The history never leaves this Mac: no iCloud, backup or export. "
                + "My own windows and the lock screen are always excluded.", rows: rows)]
    }
}

/// The macOS grants that make up the reach on this Mac, as the permission card names them. Automation is per app and asked in context, so it is
/// not part of the reach.
private let trustReachGrants: [SystemPermissionCapability] = [.notifications, .calendars, .reminders, .contacts, .microphone, .speechRecognition,
    .accessibility, .screenRecording, .inputMonitoring, .fullDiskAccess]
