import AuthoredCapabilities
import BackgroundWork
import DoctorChecks
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `DiagnosticsPacket.swift` | Diagnostics' packet for `native-diagnostics`: measured verdicts and row keys, each action calling its Doctor verb |

extension NativeAgentEngine {
    /// Why a run did not finish, as one plain sentence: its error's own words without the error type's wrapper, or the reason its report names.
    static func runCause(_ run: RunRecord) -> String? {
        var words = run.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if words.isEmpty, let data = run.output?.data(using: .utf8),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let reason = report["reason"] as? String {
            words = reason.replacingOccurrences(of: "_", with: " ")
        }
        // `someFailure("the words")` reads as the words.
        if let open = words.range(of: "(\""), words[..<open.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber }) {
            words = String(words[open.upperBound...]).replacingOccurrences(of: "\\'", with: "'")
            if words.hasSuffix("\")") { words.removeLast(2) }
        }
        // A bare code (`subprocess_exit_1`) reads as words.
        if !words.contains(" ") { words = words.replacingOccurrences(of: "_", with: " ") }
        guard let line = words.split(whereSeparator: \.isNewline).first, !line.isEmpty else { return nil }
        let sentence = line.range(of: ": ").map { line[..<$0.lowerBound] } ?? line[...]
        return String((sentence.count >= 24 ? sentence : line[...]).prefix(160))
    }

    /// What `native-diagnostics` draws Diagnostics from. Each status arrives with the stem's bucket for it, each check with whether it is adverse
    /// and safely repairable; the part words, groups and orders them. Lists the page shows in part are bounded tails: the last 8 loaded activity
    /// events in record order and the first 15 runs of the ledger. The read moment is the epoch.
    @concurrent func diagnosticsPacket() async throws -> PartFaces.Packet {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let cognitionView = await self.cognitionView.livingStatus.reading
        let (doctor, runs, transcripts) = await MainActor.run {
            let doctor = self.doctor, runs = self.runs
            return ((isRunning: doctor.isRunning, report: doctor.report, reportAvailabilityIssue: doctor.reportAvailabilityIssue,
                     loopVerdicts: doctor.loopVerdicts, watchdog: doctor.watchdog, health: doctor.health, activityEvents: doctor.activityEvents,
                     activityRefresh: doctor.activityRefresh, runStartedAt: doctor.runStartedAt, latestRunFailure: doctor.latestRunFailure,
                     reportCompletedAt: doctor.reportCompletedAt),
                    (rows: runs.rows, readSucceeded: runs.readSucceeded),
                    (sessions: self.transcripts.sessions, sessionIndexError: self.transcripts.sessionIndexError))
        }
        var keys: [String: JSONValue] = [:]
        // Each action's id is the Doctor verb it calls; a check's repair names its check.
        if !doctor.isRunning {
            let actions = ["doctor.run", "doctor.repair", "doctor.support_report"].map { PageKeyAction.calls($0, $0).json }
            keys["doctor"] = .object(["actions": .array(actions)])
        }
        var checks: JSONValue = .null
        if let report = doctor.report {
            var rows: [JSONValue] = []
            for check in report.checks {
                let repairable = doctor.reportAvailabilityIssue == nil && check.repair_available == true && DoctorSafeRepairPolicy.isAdverse(check.status)
                var key: [String: JSONValue] = [:]
                if let open = DiagnosticsFacts.ownerPage(check) { key["open"] = .string(open) }
                if repairable {
                    key["actions"] = .array([PageKeyAction.calls("doctor.repair", "doctor.repair", ["check_id": .string(check.checkID)]).json])
                }
                if !key.isEmpty { keys[check.id] = .object(key) }
                rows.append(.object(DiagnosticsFacts.verdict(check.status).merging([
                    "id": .string(check.id), "checkID": .string(check.checkID), "title": .string(check.title), "detail": .string(check.detail),
                    "adverse": .bool(DoctorSafeRepairPolicy.isAdverse(check.status)), "harm": faceText(check.harm),
                    "recovery": faceText(check.recoveryAction()), "receipt": faceText(check.receipt),
                ]) { $1 }))
            }
            checks = .array(rows)
        }
        let loops: [JSONValue] = doctor.loopVerdicts.map { verdict in
            .object(DiagnosticsFacts.verdict(verdict.level.statusText).merging([
                "loopId": .string(verdict.loopId), "name": .string(DoctorPlainCopy.friendlyLoopName(verdict.loopId)), "detail": .string(verdict.detail),
                "fault": .bool(verdict.level.isFault), "ok": .bool(verdict.level == .ok),
            ]) { $1 })
        }
        var watchdog: JSONValue = .null
        if let status = doctor.watchdog {
            let badge = status.runtimeBadgeStatus
            watchdog = .object(["status": .string(status.runtimeLifecycleStatus), "detail": .string(status.runtimeLifecycleDetail),
                "badge": .string(badge), "badgeBucket": .string(DoctorPlainCopy.bucket(for: badge))])
        }
        var mac: JSONValue = .null
        if let health = doctor.health {
            mac = .object(["version": .string(health.version), "dataDir": .string(UserDisplayFormatters.tildifyPath(health.dataDir)),
                "startedAt": DiagnosticsFacts.stamp(health.launchedAt)])
        }
        var recentRuns: [JSONValue] = []
        for run in runs.rows.prefix(15) {
            keys[run.id] = .object(["open": .string("page:diagnostics/" + run.id)])
            // A run says what it was and, when it did not finish, why: the first line of its own error or skip note.
            let cause = ["succeeded", "completed"].contains(run.status.lowercased()) ? nil : Self.runCause(run)
            recentRuns.append(.object(["id": .string(run.id), "kind": .string(run.kind), "status": .string(run.status),
                "name": .string(RunKindVocabulary.displayName(run.kind, on: .mac)), "cause": faceText(cause),
                "model": faceText(run.model), "durationSeconds": run.durationSeconds.map(JSONValue.double) ?? .null,
                "createdAt": .string(run.createdAt), "timeReadable": .bool(UserDisplayFormatters.parseISOTimestamp(run.createdAt) != nil)]))
        }
        var living: [String: JSONValue] = ["snapshot": .null, "failedEndpoints": .null, "watchUnavailable": .null]
        if let snapshot = cognitionView.livingSnapshot {
            living["snapshot"] = .object([
                "posture": .string(snapshot.posture), "postureStatus": .string(snapshot.postureStatus),
                "postureBucket": .string(DoctorPlainCopy.bucket(for: snapshot.postureStatus)), "bodyState": .string(snapshot.bodyState),
                "behaviorLine": .string(snapshot.behaviorLine), "deskSummary": .string(snapshot.deskSummary),
                "approvalsSummary": .string(snapshot.approvalsSummary), "lastDreamSummary": .string(snapshot.lastDreamSummary),
            ])
        }
        if let status = cognitionView.livingRefreshStatus { living["failedEndpoints"] = .array(status.failedEndpoints.map(JSONValue.string)) }
        if case .some(.unavailable(let detail)) = cognitionView.livingWatchAvailability { living["watchUnavailable"] = .string(detail) }
        let tail: [JSONValue] = doctor.activityEvents.suffix(8).map { event in
            .object(DiagnosticsFacts.verdict(event.status).merging([
                "id": .string(event.id), "title": .string(event.title), "detail": faceText(event.detail),
                "createdAt": .string(event.createdAt), "timeReadable": .bool(UserDisplayFormatters.parseISOTimestamp(event.createdAt) != nil),
            ]) { $1 })
        }
        let refresh = doctor.activityRefresh
        let facts: [String: JSONValue] = [
            "doctor": .object([
                "running": .bool(doctor.isRunning), "runStartedAt": DiagnosticsFacts.stamp(doctor.runStartedAt),
                "runFailure": faceText(doctor.latestRunFailure), "reportIssue": faceText(doctor.reportAvailabilityIssue),
                "completedAt": DiagnosticsFacts.stamp(doctor.reportCompletedAt), "checks": checks,
            ]),
            "loops": .array(loops), "watchdog": watchdog, "mac": mac,
            "runs": .object(["read": runs.readSucceeded.map(JSONValue.bool) ?? .null, "count": .int(Int64(runs.rows.count)),
                             "recent": .array(recentRuns)]),
            "sessions": .object(["count": .int(Int64(transcripts.sessions.count)), "error": faceText(transcripts.sessionIndexError)]),
            "living": .object(living),
            "activity": .object(["refreshed": .bool(refresh != nil), "failed": .bool(refresh?.failedEndpoints.contains("activity") == true),
                                 "tail": .array(tail)]),
            "keys": .object(keys),
        ]
        return .init(facts: .object(facts), epoch: epoch)
    }

    /// Diagnostics reads again whenever the Doctor, the run ledger or the living status changes.
    @MainActor public func bindDiagnosticsFace() {
        let changed: @MainActor () -> Void = { [weak self] in
            Task { @MainActor [weak self] in await self?.pages.refresh(page: "diagnostics") }
        }
        doctor.diagnosticsDidChange = changed
        runs.diagnosticsDidChange = changed
        changed()
    }
}

private enum DiagnosticsFacts {
    /// Where a check's row leads: the page that owns its remedy.
    static func ownerPage(_ check: CheckResult) -> String? {
        switch check.checkID {
        case "live.providers", "oauth_token_expiry": return "page:providers"
        case "live.telegram": return "page:telegram"
        case "status.desk_attention": return "page:desk"
        default: return nil
        }
    }

    /// A status with the Doctor's bucket for it (healthy, warning, failing, reading, off, not needed or unclear).
    static func verdict(_ status: String) -> [String: JSONValue] {
        ["status": .string(status), "bucket": .string(DoctorPlainCopy.bucket(for: status))]
    }


    static func stamp(_ date: Date?) -> JSONValue { date.map { .string(NativeTimestampFormat.plainZulu($0)) } ?? .null }
}
