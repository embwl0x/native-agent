import AuthoredCapabilities
import BackgroundWork
import DoctorChecks
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `DiagnosticsFace.swift` | Diagnostics reads the Doctor, runs and living-status owners in memory; native actions return to their existing host |

extension NativeAgentEngine {
    @MainActor func diagnosticsFace() -> (face: PartFace, epoch: UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let report = doctor.report
        let summary = DoctorPlainCopy.summarize(report?.checks ?? [])
        let line = doctor.isRunning ? "Running health checks." : doctor.latestRunFailure ?? DoctorPlainCopy.headline(for: summary)
        let actions: [PartFace.Action] = doctor.isRunning ? [] : [
            .init(id: "doctor.run", label: "Run checks"),
            .init(id: "doctor.repair", label: "Repair safe issues"),
            .init(id: "doctor.support_report", label: "Support report"),
        ]
        var sections: [PartFace.Section] = [.init(id: "doctor", style: .list,
            footer: doctor.reportAvailabilityIssue ?? DoctorPlainCopy.detail(for: summary), rows: [
            .init(id: "doctor", title: "Health checks",
                value: doctor.reportAvailabilityIssue == nil ? summary.statusText : "unavailable",
                at: doctor.reportCompletedAt.map(NativeTimestampFormat.plainZulu),
                tone: doctor.isRunning ? .live : doctor.latestRunFailure == nil ? DiagnosticsFaceCopy.tone(summary.statusText) : .attention,
                actions: actions),
        ])]
        if doctor.isRunning {
            sections.append(.init(id: "running", title: "Running health checks", style: .waiting, rows: [
                .init(id: "doctor.running", title: "Running health checks", detail: doctor.runStartedAt == nil
                    ? "The run's start time is unavailable. Retained checks are not current until it finishes."
                    : "Retained checks are not current until this run finishes.",
                    at: doctor.runStartedAt.map(NativeTimestampFormat.plainZulu), tone: .live),
            ]))
        }
        // Readings are counted in Checks; only what is wrong or about to be stands in Needs attention.
        let attention = (report?.checks ?? []).filter { ["warning", "failing", "unclear"].contains(DoctorPlainCopy.bucket(for: $0.status)) }
        var attentionRows = attention.map { check -> PartFace.Row in
            let canRepair = doctor.reportAvailabilityIssue == nil && check.repair_available == true && DoctorSafeRepairPolicy.isAdverse(check.status)
            let detail = [check.detail, DoctorSafeRepairPolicy.isAdverse(check.status) ? check.harm : nil,
                check.recoveryAction(), check.receipt].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            return .init(id: check.id, title: check.title, detail: detail, value: check.status,
                tone: DiagnosticsFaceCopy.tone(check.status), open: DiagnosticsFaceCopy.ownerPage(check),
                actions: canRepair ? [.init(id: "doctor.repair", label: "Repair")] : nil)
        }
        if attentionRows.isEmpty {
            attentionRows = [.init(id: "attention.empty", title: report == nil || summary.total == 0
                ? "No measured checks yet" : "No measured checks need attention",
                detail: doctor.reportAvailabilityIssue ?? (summary.total == 0 ? "Run checks to read this Mac's health." : nil),
                tone: doctor.reportAvailabilityIssue == nil && summary.total > 0 ? .quiet : .attention)]
        }
        sections.append(.init(id: "attention", title: "Needs attention", style: .list,
            footer: doctor.reportAvailabilityIssue, rows: attentionRows))
        sections.append(diagnosticsBackground())
        let groups = DoctorReadout.groupedChecks(report?.checks ?? []).map { group, checks -> PartFace.Row in
            let summary = DoctorPlainCopy.summarize(checks)
            return .init(id: "checks." + group, title: DoctorPlainCopy.sectionTitle(for: group),
                value: DiagnosticsFaceCopy.counts(summary), tone: DiagnosticsFaceCopy.tone(summary.statusText))
        }
        sections.append(.init(id: "checks", title: "Checks", style: .values, footer: doctor.reportAvailabilityIssue,
            rows: groups.isEmpty ? [.init(id: "checks.empty", title: "No measured checks yet", tone: .attention)] : groups))
        sections.append(diagnosticsMac())
        sections.append(diagnosticsLiving())
        sections.append(diagnosticsActivity())
        sections.append(diagnosticsRuns())
        return (.init(title: "Diagnostics", line: line, sections: sections), epoch)
    }

    @MainActor private func diagnosticsBackground() -> PartFace.Section {
        let verdicts = doctor.loopVerdicts
        let faults = verdicts.filter { $0.level.isFault }
        var rows = faults.map { verdict in
            PartFace.Row(id: "loop." + verdict.loopId, title: DoctorPlainCopy.friendlyLoopName(verdict.loopId),
                detail: verdict.detail, value: verdict.level.statusText, tone: DiagnosticsFaceCopy.tone(verdict.level.statusText))
        }
        let loopChecks = doctor.report?.checks.filter { ["background_loops", "live.background_loops"].contains($0.checkID) } ?? []
        for check in loopChecks where !["healthy", "off", "not needed"].contains(DoctorPlainCopy.bucket(for: check.status)) {
            rows.append(.init(id: "background.check." + check.id, title: check.title, detail: check.detail,
                value: check.status, tone: DiagnosticsFaceCopy.tone(check.status)))
        }
        if let watchdog = doctor.watchdog, watchdog.runtimeLifecycleStatus != "ok" {
            rows.append(.init(id: "background.runtime", title: "Background scheduling", detail: watchdog.runtimeLifecycleDetail,
                value: watchdog.runtimeLifecycleStatus, tone: DiagnosticsFaceCopy.tone(watchdog.runtimeBadgeStatus)))
        }
        if rows.isEmpty {
            if verdicts.isEmpty {
                rows = [.init(id: "background.unmeasured", title: "Background work has not been measured", tone: .attention)]
            } else if verdicts.contains(where: { $0.level == .ok }) {
                rows = [.init(id: "background.healthy", title: doctor.reportAvailabilityIssue == nil
                    ? "All background work is healthy" : "Last measured background work was healthy",
                    detail: "Off and unneeded work is excluded from this health verdict.", tone: .done)]
            } else {
                rows = [.init(id: "background.inactive", title: "Background work is off or not needed", tone: .quiet)]
            }
        }
        return .init(id: "background", title: "Background work", style: .list, footer: doctor.reportAvailabilityIssue, rows: rows)
    }

    @MainActor private func diagnosticsMac() -> PartFace.Section {
        var rows: [PartFace.Row] = []
        if let health = doctor.health {
            let uptime = Int(exactly: health.uptimeSeconds.rounded(.towardZero)).flatMap { $0 >= 0 ? "\($0)s" : nil }
            rows += [.init(id: "mac.version", title: "Version", value: health.version),
                .init(id: "mac.uptime", title: "Uptime", value: uptime ?? "Unavailable"),
                .init(id: "mac.data", title: "Data folder", value: UserDisplayFormatters.tildifyPath(health.dataDir))]
        } else {
            rows.append(.init(id: "mac.unmeasured", title: "This Mac has not published its status", tone: .attention))
        }
        rows.append(.init(id: "mac.runs", title: "Runs", value: runs.readSucceeded == true ? "\(runs.rows.count)" : "Unavailable"))
        rows.append(.init(id: "mac.sessions", title: "Sessions", detail: transcripts.sessionIndexError,
            value: transcripts.sessionIndexError == nil ? "\(transcripts.sessions.count) loaded" : "Unavailable"))
        return .init(id: "mac", title: "This Mac", style: .values, rows: rows)
    }

    @MainActor private func diagnosticsLiving() -> PartFace.Section {
        var rows: [PartFace.Row] = []
        if let snapshot = cognitionView.livingSnapshot {
            rows = [
                .init(id: "living.posture", title: "Posture", value: snapshot.posture, tone: DiagnosticsFaceCopy.tone(snapshot.postureStatus)),
                .init(id: "living.body", title: "Body", value: snapshot.bodyState),
                .init(id: "living.behavior", title: "Behavior", value: snapshot.behaviorLine),
                .init(id: "living.desk", title: "Desk", value: snapshot.deskSummary),
                .init(id: "living.approvals", title: "Approvals", value: snapshot.approvalsSummary),
                .init(id: "living.dream", title: "Dream", value: snapshot.lastDreamSummary),
            ]
        } else {
            rows.append(.init(id: "living.unmeasured", title: "Living status is unavailable", tone: .attention))
        }
        var notices: [String] = []
        if let status = cognitionView.livingRefreshStatus, !status.failedEndpoints.isEmpty {
            notices.append("Current state could not be read: " + status.failedEndpoints.joined(separator: ", ")
                + (rows.count == 6 ? ". Showing the last known state." : "."))
        }
        if case .some(.unavailable(let detail)) = cognitionView.livingWatchAvailability {
            notices.append("Live status updates are unavailable: " + detail)
        }
        return .init(id: "living", title: "Living status", style: .values,
            footer: notices.isEmpty ? nil : notices.joined(separator: "\n"), rows: rows)
    }

    @MainActor private func diagnosticsActivity() -> PartFace.Section {
        let refresh = doctor.activityRefresh
        let failed = refresh?.failedEndpoints.contains("activity") == true
        var rows = doctor.activityEvents.suffix(8).reversed().map { event in
            PartFace.Row(id: "activity." + event.id, title: event.title,
                detail: DiagnosticsFaceCopy.datedDetail(event.detail, at: event.createdAt), value: event.status,
                at: event.createdAt, tone: DiagnosticsFaceCopy.tone(event.status))
        }
        if rows.isEmpty {
            rows = [.init(id: "activity.empty", title: failed ? "Recent activity is unavailable"
                : refresh == nil ? "Recent activity has not been read" : "No activity recorded yet", tone: .quiet)]
        }
        return .init(id: "activity", title: "Recent activity", style: .timeline,
            footer: failed ? "The activity log could not refresh. Any displayed events are the last loaded reading." : nil, rows: rows)
    }

    @MainActor private func diagnosticsRuns() -> PartFace.Section {
        var rows = runs.rows.prefix(15).map { run in
            let badge = RunStatusBadgePresentation.badge(for: run.status)
            let model = run.model.flatMap { $0.isEmpty ? nil : $0 } ?? "Model unavailable"
            let duration = run.durationSeconds.map(CompactDurationFormatter.string) ?? "Duration unavailable"
            return PartFace.Row(id: run.id, title: RunKindVocabulary.displayName(run.kind, on: .mac),
                detail: DiagnosticsFaceCopy.datedDetail(model + " · " + duration, at: run.createdAt), value: badge.label,
                at: run.createdAt, symbol: RunKindVocabulary.symbol(run.kind), tone: DiagnosticsFaceCopy.tone(badge.themeStatus),
                open: "page:diagnostics/" + run.id)
        }
        if rows.isEmpty {
            rows = [.init(id: "runs.empty", title: runs.readSucceeded == false ? "Run history is unavailable"
                : runs.readSucceeded == nil ? "Run history has not been read" : "No runs recorded yet", tone: .quiet)]
        }
        return .init(id: "runs", title: "Runs", style: .timeline,
            footer: runs.readSucceeded == false ? "The run history could not refresh. Any displayed runs are the last loaded reading." : nil, rows: rows)
    }

    @MainActor func actDiagnostics(row: String, action: String, value: String?) async throws -> String? {
        guard value == nil else { throw PartCallError(code: "bad_value", message: "Diagnostics actions take no value.") }
        let allowed = row == "doctor" ? ["doctor.run", "doctor.repair", "doctor.support_report"] : ["doctor.repair"]
        guard allowed.contains(action) else { throw PartCallError(code: "unknown_action", message: "Read Diagnostics for its current actions.") }
        var checkID: String?
        if row != "doctor" {
            guard action == "doctor.repair", doctor.reportAvailabilityIssue == nil,
                  let check = doctor.report?.checks.first(where: { $0.id == row }),
                  check.repair_available == true, DoctorSafeRepairPolicy.isAdverse(check.status) else {
                throw PartCallError(code: "repair_unavailable", message: "This check has no current safe repair. Run checks and read its remedy.")
            }
            checkID = check.checkID
        }
        guard let perform = doctor.faceAction else {
            throw PartCallError(code: "unattached", message: "The app's Diagnostics actions have not attached. Reopen NativeAgent.")
        }
        return try await perform(action, checkID)
    }

    @MainActor public func bindDiagnosticsFace(action: @escaping @MainActor (String, String?) async throws -> String?) {
        doctor.faceAction = action
        let changed: @MainActor () -> Void = { [weak self] in
            Task { @MainActor [weak self] in await self?.pages.refresh(page: "diagnostics") }
        }
        doctor.diagnosticsDidChange = changed
        runs.diagnosticsDidChange = changed
        cognitionView.livingStatusDidChange = changed
        changed()
    }
}
