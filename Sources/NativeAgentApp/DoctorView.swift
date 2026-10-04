import ProviderRouting
import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import DoctorChecks
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

/// The bottom-of-report summary is a receipt view: it describes the checks we
/// have and when their full Doctor pass completed. It intentionally derives
/// severity from the individual check rows, not the report's free-form status
/// string, which can be stale after live-coverage reconciliation.
enum DoctorReportFooterPresentation {
    struct State: Equatable {
        let title: String
        let detail: String
        let status: String
    }

    static let maximumClockSkew: TimeInterval = 60

    static func resolve(
        report: DoctorReport?,
        completedAt: Date?,
        isRunning: Bool,
        now: Date
    ) -> State? {
        guard let report else { return nil }
        let summary = DoctorPlainCopy.summarize(report.checks)

        if isRunning {
            return State(
                title: "Refreshing health report",
                detail: "The results above are from before this run and are not current until it finishes.",
                status: "warn"
            )
        }
        guard let completedAt else {
            return State(
                title: "Health report time unavailable",
                detail: "This report has \(summary.total) \(summary.total == 1 ? "check" : "checks"), but its completion time is unavailable. Run health checks to refresh it.",
                status: "warn"
            )
        }

        let age = now.timeIntervalSince(completedAt)
        guard age >= -maximumClockSkew else {
            return State(
                title: "Health report time is invalid",
                detail: "The report completion time is ahead of this Mac's clock. Run health checks again after checking the clock.",
                status: "warn"
            )
        }

        let observedStatus = summary.statusText
        let ageText = relativeAge(max(0, age))
        if age > AppModel.supportSnapshotDoctorReuseTTL {
            return State(
                title: "Health report is older than \(Int(AppModel.supportSnapshotDoctorReuseTTL)) seconds",
                detail: "Completed \(ageText). \(DoctorPlainCopy.detail(for: summary)) Run health checks again for a current report.",
                status: observedStatus == "failed" ? "failed" : "warn"
            )
        }
        return State(
            title: "Health report completed \(ageText)",
            detail: DoctorPlainCopy.detail(for: summary),
            status: observedStatus
        )
    }

    private static func relativeAge(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds)) seconds ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        let hours = Int(seconds / 3_600)
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        let days = Int(seconds / 86_400)
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}

/// The toolbar action must acknowledge both a completed report and the less
/// common case where Doctor could not produce one. `statusText` is shared with
/// other surfaces, so it cannot be the only place that a button failure lands.
enum DoctorRunButtonPresentation {
    struct Notice: Equatable {
        let detail: String
        let status: String
    }

    static func notice(for outcome: AppModel.DoctorRunOutcome, repair: Bool) -> Notice {
        switch outcome {
        case .unavailable(let reason):
            return Notice(
                detail: "Health checks could not run: \(reason)",
                status: "failed"
            )
        case .completed(let status, let failingChecks):
            let verb = repair ? "Repair finished" : "Health checks finished"
            if !failingChecks.isEmpty {
                let count = failingChecks.count
                return Notice(
                    detail: "\(verb), but \(count) \(count == 1 ? "check is" : "checks are") still failing. Review the report below.",
                    status: "failed"
                )
            }
            let statusBucket = DoctorPlainCopy.bucket(for: status)
            if statusBucket == "failing" {
                return Notice(
                    detail: "\(verb), but the report is failing. Review the report below.",
                    status: "failed"
                )
            }
            return Notice(
                detail: statusBucket == "warning"
                    ? "\(verb) with items that need attention. Review the report below."
                    : "\(verb). Review the current report below.",
                status: statusBucket == "warning" ? "warn" : "ok"
            )
        }
    }
}

enum DoctorSupportSnapshotPresentation {
    struct Notice: Equatable {
        let detail: String
        let status: String
    }

    static func notice(for outcome: AppModel.SupportDiagnosticsLoadOutcome) -> Notice {
        switch outcome {
        case .unavailable(let reason):
            return Notice(detail: "The support report is unavailable: \(reason)", status: "warn")
        case .failed(let reason):
            return Notice(detail: "The support report failed: \(reason)", status: "failed")
        case .loaded(let diagnostics, let reusedDoctorReport):
            let source = reusedDoctorReport ? "using the recent health report" : "from a fresh set of health checks"
            let status = diagnostics.doctorStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = (status?.isEmpty == false) ? " Status: \(status!)." : ""
            let tone: String
            switch DoctorPlainCopy.bucket(for: status ?? "") {
            case "failing": tone = "failed"
            case "warning": tone = "warn"
            default: tone = "ok"
            }
            return Notice(detail: "The support report is ready \(source).\(suffix)", status: tone)
        }
    }
}

/// The Doctor core marks only app-owned, conservative repairs with this
/// instruction. Other repair text is a human next step (for example provider
/// authentication) and must never make the local repair button runnable.
enum DoctorSafeRepairIssuesPresentation {
    struct Plan: Equatable {
        let checkIDs: [String]

        var count: Int { checkIDs.count }
        var canRun: Bool { !checkIDs.isEmpty }
    }

    enum State: Equatable {
        case needsDoctorReport
        case noSafeIssues
        case ready(Plan)
        case running

        var canRun: Bool {
            if case .ready(let plan) = self { return plan.canRun }
            return false
        }

        var detail: String {
            switch self {
            case .needsDoctorReport:
                return "Repair checks everything and fixes what is broken."
            case .noSafeIssues:
                return "Nothing left for Repair to fix."
            case .ready(let plan):
                return "\(plan.count) issue\(plan.count == 1 ? "" : "s") to fix — press Repair."
            case .running:
                return "Repairing…"
            }
        }

        var systemImage: String {
            switch self {
            case .ready: "cross.case.fill"
            case .needsDoctorReport, .noSafeIssues: "checkmark.circle"
            case .running: "hourglass"
            }
        }

        var status: String {
            switch self {
            case .ready: "warn"
            case .needsDoctorReport, .noSafeIssues, .running: "info"
            }
        }
    }

    static func state(report: DoctorReport?, isRunning: Bool) -> State {
        if isRunning { return .running }
        guard let report else { return .needsDoctorReport }
        let plan = plan(for: report.checks)
        return plan.canRun ? .ready(plan) : .noSafeIssues
    }

    static func plan(for checks: [CheckResult]) -> Plan {
        Plan(checkIDs: DoctorSafeRepairPolicy.checkIDs(for: checks))
    }

    /// Count completion receipts separately from available repair handlers.
    static func appliedRepairCount(in checks: [CheckResult]) -> Int {
        DoctorSafeRepairPolicy.appliedRepairCount(in: checks)
    }

    static func completionMessage(report: DoctorReport) -> String {
        let remaining = report.checks.filter { isAdverse($0.status) }.count
        if report.repaired {
            return remaining == 0
                ? "Repair applied safe fixes."
                : "Repair applied safe fixes, but \(remaining) issue\(remaining == 1 ? " remains" : "s remain")."
        }
        return remaining == 0
            ? "Repair finished; no changes were needed."
            : "Repair finished, but no safe fixes were applied."
    }

    private static func isAdverse(_ status: String) -> Bool {
        DoctorSafeRepairPolicy.isAdverse(status)
    }
}

struct DoctorView: View {
    @Environment(AppModel.self) private var appModel
    @State private var loopVerdicts: [LoopHealthVerdict] = []
    @State private var runNotice: DoctorRunButtonPresentation.Notice?
    @State private var snapshotNotice: DoctorSupportSnapshotPresentation.Notice?

    private var unhealthyLoops: [LoopHealthVerdict] {
        loopVerdicts.filter { $0.level != .ok }
    }

    private var healthyCount: Int {
        loopVerdicts.count - unhealthyLoops.count
    }

    private var loopPanelTint: Color {
        if loopVerdicts.contains(where: { $0.level == .fail }) { return .red }
        if loopVerdicts.contains(where: { $0.level == .warn }) { return .orange }
        return .green
    }

    private var groupedChecks: [(String, [CheckResult])] {
        guard let checks = appModel.engine.doctor.report?.checks else { return [] }
        let order = [
            "Provider", "Runtime", "Cognition", "Connectors", "Data", "Tools",
            "Autonomy", "Release",
        ]
        let grouped = Dictionary(grouping: checks, by: category)
        return order.compactMap { key in
            guard let values = grouped[key], !values.isEmpty else { return nil }
            return (key, values)
        }
    }

    // UI-2 (public-user honesty, 2026-08-01): the page used to open on
    // CODEX_HOME paths, raw loop IDs, and a bare "Ok" status word. A person who
    // did not write this app cannot read any of that. The plain summary leads;
    // every technical string still ships, one disclosure down.
    private var checkSummary: DoctorPlainCopy.Summary {
        DoctorPlainCopy.summarize(appModel.engine.doctor.report?.checks ?? [])
    }

    private var reportFooter: DoctorReportFooterPresentation.State? {
        DoctorReportFooterPresentation.resolve(
            report: appModel.engine.doctor.report,
            completedAt: appModel.engine.doctor.reportCompletedAt,
            isRunning: appModel.engine.doctor.isRunning,
            now: Date()
        )
    }

    private var safeRepairState: DoctorSafeRepairIssuesPresentation.State {
        DoctorSafeRepairIssuesPresentation.state(
            report: appModel.engine.doctor.report,
            isRunning: appModel.engine.doctor.isRunning
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // User 09-29: one button. It runs every check, leaves what is
                // right alone, fixes what is broken, and opens the one screen a
                // person must act on. The support report is a right-click away.
                Button(appModel.engine.doctor.isRunning ? "Repairing…" : "Repair", systemImage: "cross.case.fill") {
                    beginRepair()
                }
                .disabled(appModel.engine.doctor.isRunning)
                .accessibilityIdentifier("doctor.run")
                .contextMenu {
                    Button(appModel.supportDiagnosticsLoading ? "Preparing the report…" : "Make a support report") {
                        beginSupportSnapshot()
                    }
                    .disabled(appModel.supportDiagnosticsLoading || appModel.engine.doctor.isRunning)
                }
                // PATCH-2026-05-30: in-flight indicator so the user sees the
                // Doctor is working during the ~7-15s probe. Previously the
                // UI looked frozen and people thought it wasn't running.
                // TimelineView ticks once per second to show elapsed duration.
                if appModel.engine.doctor.isRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        if let started = appModel.engine.doctor.runStartedAt {
                            TimelineView(.periodic(from: started, by: 1.0)) { ctx in
                                let elapsed = max(0, Int(ctx.date.timeIntervalSince(started)))
                                Text("Running health checks · \(elapsed)s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Running health checks…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 8)
                }
            }

            Label(safeRepairState.detail, systemImage: safeRepairState.systemImage)
                .font(.caption)
                .foregroundStyle(AdvancedStatusWords.color(safeRepairState.status))

            if let runNotice {
                Label(runNotice.detail, systemImage: runNotice.status == "failed" ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(AdvancedStatusWords.color(runNotice.status))
                    .accessibilityIdentifier("doctor.run.notice")
            }

            if let snapshotNotice {
                Label(snapshotNotice.detail, systemImage: snapshotNotice.status == "failed" ? "exclamationmark.triangle.fill" : "shippingbox.fill")
                    .font(.callout)
                    .foregroundStyle(AdvancedStatusWords.color(snapshotNotice.status))
                    .accessibilityIdentifier("doctor.supportSnapshot.notice")
            }

            // Watchdog readout lives in Diagnostics ▸ Status (the canonical
            // health surface). It rendered identically here too until the
            // 2026-07-03 dead-weight audit flagged the duplication.

            healthSummaryPanel

            // Background-loop health (2026-07-16): github_tracking failed every
            // tick for 4 days with zero surfacing. Rule + receipt parsing live
            // in DoctorLoopHealth (pure, unit-tested); this is display only.
            NativePanel(title: "Background tasks", systemImage: "arrow.triangle.2.circlepath", tint: loopPanelTint) {
                if loopVerdicts.isEmpty {
                    Text("Background tasks have not started yet.")
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(unhealthyLoops) { verdict in
                            HStack(alignment: .firstTextBaseline) {
                                InlineStatusDot(status: verdict.level.statusText)
                                VStack(alignment: .leading, spacing: 2) {
                                    // UI-2: plain name in the headline; the raw
                                    // loop ID moves into the Details list below.
                                    Text(DoctorPlainCopy.friendlyLoopName(verdict.loopId))
                                        .font(NativeAgentFont.section)
                                    Text(verdict.detail)
                                        .font(NativeAgentFont.body)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                StatusBadge(text: verdict.level.statusText.uppercased(), status: verdict.level.statusText)
                            }
                        }
                        if unhealthyLoops.isEmpty {
                            HStack {
                                InlineStatusDot(status: "ok")
                                Text(DoctorPlainCopy.allLoopsHealthyText(count: loopVerdicts.count))
                                    .font(NativeAgentFont.body)
                                    .foregroundStyle(.secondary)
                            }
                        } else if healthyCount > 0 {
                            Text(DoctorPlainCopy.otherLoopsHealthyText(count: healthyCount))
                                .font(NativeAgentFont.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                        DisclosureGroup("Details") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(loopVerdicts) { verdict in
                                    Text("\(verdict.loopId) — \(verdict.level.statusText)")
                                        .font(NativeAgentFont.mono)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(NativeAgentFont.label)
                    }
                }
            }
            .task(id: appModel.engine.doctor.isRunning) {
                loopVerdicts = await DoctorLoopHealth.current()
            }

            if appModel.engine.doctor.report != nil {
                // UI-2: the raw report status word and the support badge moved
                // into healthSummaryPanel above, so the page leads with a
                // sentence instead of "Ok".
                List {
                    ForEach(groupedChecks, id: \.0) { group, checks in
                        Section(DoctorPlainCopy.sectionTitle(for: group)) {
                            ForEach(checks) { check in
                                DoctorCheckRow(check: check)
                            }
                            // One Details disclosure per section holds the raw
                            // check IDs that support asks for.
                            DisclosureGroup("Details") {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(checks) { check in
                                        Text("\(check.id) — \(check.status)")
                                            .font(NativeAgentFont.mono)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .font(NativeAgentFont.label)
                        }
                    }
                }
                if let reportFooter {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        InlineStatusDot(status: reportFooter.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reportFooter.title)
                                .font(NativeAgentFont.label)
                            Text(reportFooter.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        StatusBadge(text: reportFooter.status.uppercased(), status: reportFooter.status)
                    }
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("doctor.report.footer")
                }
            } else {
                NativeEmptyState(
                    title: "Health checks",
                    detail: "Repair checks the app, model connections, web search, Telegram, conversations, tools, and background work, and fixes what is broken.",
                    systemImage: "cross.case"
                )
            }
        }
        // No inset of its own: the page frame's column is the edge, as on
        // every alive page.
        .navigationTitle("Health checks")
        .motionArrival(when: appModel.engine.doctor.report != nil)
        .task {
            await appModel.refreshLiveDoctorCoverage()
        }
    }

    private func beginRepair() {
        runNotice = nil
        Task {
            let outcome = await appModel.runDoctor(repair: true, repairScope: .button)
            runNotice = DoctorRunButtonPresentation.notice(for: outcome, repair: true)
            // What only a person can do (sign in, choose a model) lives on
            // Providers: take them there instead of leaving a note.
            if appModel.engine.doctor.report?.checks.contains(where: {
                $0.id == "live.providers" && DoctorSafeRepairPolicy.isAdverse($0.status)
            }) == true {
                NativeAgentAppCoordinator.shared.request(.sidebar(.providers))
            }
        }
    }

    private func beginSupportSnapshot() {
        snapshotNotice = nil
        Task {
            let outcome = await appModel.loadSupportDiagnostics()
            snapshotNotice = DoctorSupportSnapshotPresentation.notice(for: outcome)
        }
    }

    // UI-2: the page's new lead. Plain sentence + plain counts; the raw report
    // status word and check tally live one disclosure down.
    @ViewBuilder
    private var healthSummaryPanel: some View {
        NativePanel(
            title: "Overall health",
            systemImage: "heart.text.square",
            tint: DoctorPlainCopy.tint(for: checkSummary)
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    InlineStatusDot(status: checkSummary.statusText)
                    Text(DoctorPlainCopy.headline(for: checkSummary))
                        .font(NativeAgentFont.section)
                    Spacer()
                    if let diagnostics = appModel.supportDiagnostics {
                        StatusBadge(text: "Support \(diagnostics.version)", status: diagnostics.doctorStatus)
                    }
                }
                Text(DoctorPlainCopy.detail(for: checkSummary))
                    .font(NativeAgentFont.body)
                    .foregroundStyle(.secondary)
                if let report = appModel.engine.doctor.report {
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("report status: \(report.status)")
                            Text("checks run: \(report.checks.count)")
                            Text("safe repairs applied: \(report.repaired ? "yes" : "no")")
                        }
                        .font(NativeAgentFont.mono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                    .font(NativeAgentFont.label)
                }
            }
        }
    }

    private func category(for check: CheckResult) -> String {
        Self.categoryID(for: check.id)
    }

    static func categoryID(for id: String) -> String {
        switch id {
        case "codex_login", "llm", "codex_login_helper", "live.providers": "Provider"
        case "daemon_lifecycle", "legacy_launch_agent", "launch_agent", "live.background_loops", "live.bridges",
             // Per-turn prompt-prefix cache health is a property of the running
             // app, not of stored data.
             "prompt_prefix_health": "Runtime"
        // Her subconscious is not a subsystem of the body — it gets its own
        // group so a capsule that stopped arriving reads as what it is.
        case "subconscious_vitals": "Cognition"
        case "searxng", "telegram", "connectors", "live.telegram", "live.search": "Connectors"
        case "storage", "chat_sessions", "session_identity", "persona_engine", "backups", "write_test", "live.memory": "Data"
        case "tools", "live.tools": "Tools"
        case "autonomy", "live.autonomy": "Autonomy"
        default: "Release"
        }
    }
}

// MARK: - Plain-English Doctor copy
//
// UI-2 (2026-08-01, public era): pure string/count helpers so the honesty copy
// is unit-testable without a UI snapshot harness. No SwiftUI types here on
// purpose — everything below is a value in, a String or Int out.
enum DoctorPlainCopy {
    struct Summary: Equatable {
        var healthy = 0
        var warning = 0
        var failing = 0
        var unclear = 0

        var total: Int { healthy + warning + failing + unclear }

        /// Vocabulary understood by NativeAgentTheme.statusColor / StatusBadge.
        var statusText: String {
            if failing > 0 { return "failed" }
            if warning > 0 { return "warn" }
            if total == 0 { return "unknown" }
            return "ok"
        }
    }

    /// Bucket a raw doctor check status into the three words a person can act
    /// on. Mirrors the NativeAgentTheme.statusColor vocabulary so the dot next
    /// to the sentence never disagrees with the sentence.
    static func bucket(for status: String) -> String {
        switch status.lowercased() {
        case "ok", "done", "passed", "succeeded", "active", "valid", "ready", "scheduled":
            return "healthy"
        case "warn", "warning", "blocked", "needs_setup", "planned", "interrupted", "disabled":
            return "warning"
        case "fail", "failed", "error", "timeout", "quarantined":
            return "failing"
        default:
            return "unclear"
        }
    }

    static func summarize(_ checks: [CheckResult]) -> Summary {
        var summary = Summary()
        for check in checks {
            switch bucket(for: check.status) {
            case "healthy": summary.healthy += 1
            case "warning": summary.warning += 1
            case "failing": summary.failing += 1
            default: summary.unclear += 1
            }
        }
        return summary
    }

    static func headline(for summary: Summary) -> String {
        if summary.total == 0 { return "No checks have run yet." }
        if summary.failing > 0 { return "Some parts of the app are not working." }
        if summary.warning > 0 { return "The app is running, but some parts need attention." }
        if summary.unclear > 0 { return "The app is running. Some checks came back unclear." }
        return "Everything looks healthy."
    }

    static func detail(for summary: Summary) -> String {
        guard summary.total > 0 else {
            return "Press Repair to check everything and fix what is broken."
        }
        var parts = ["\(summary.healthy) working"]
        if summary.warning > 0 { parts.append("\(summary.warning) need attention") }
        if summary.failing > 0 { parts.append("\(summary.failing) not working") }
        if summary.unclear > 0 { parts.append("\(summary.unclear) unclear") }
        let checked = summary.total == 1 ? "1 area checked" : "\(summary.total) areas checked"
        return "\(checked): " + parts.joined(separator: ", ") + "."
    }

    static func tint(for summary: Summary) -> Color {
        if summary.failing > 0 { return .red }
        if summary.warning > 0 { return .orange }
        if summary.total == 0 { return .secondary }
        return .green
    }

    /// Group keys come from DoctorView.categoryID, which speaks in code words.
    /// These are the same seven groups said out loud.
    static func sectionTitle(for group: String) -> String {
        switch group {
        case "Provider": return "AI provider"
        case "Runtime": return "The app itself"
        case "Cognition": return "\(AgentVoice.live.possessive) inner state"
        case "Connectors": return "Connected services"
        case "Data": return "Your data"
        case "Tools": return "Tools"
        case "Autonomy": return "Actions I take on my own"
        // "Release" holds the store-validity checks (JSON stores, chat logs,
        // memory database) — "App version" mislabeled them (taste pass).
        case "Release": return "Stored data health"
        default: return group
        }
    }

    /// Turn a loop identifier such as `github_tracking` into `Github tracking`.
    /// The raw identifier still renders inside the Details disclosure.
    static func friendlyLoopName(_ loopId: String) -> String {
        let spaced = loopId
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard let first = spaced.first else { return loopId }
        return String(first).uppercased() + spaced.dropFirst()
    }

    static func allLoopsHealthyText(count: Int) -> String {
        count == 1 ? "1 background task is running normally."
                   : "All \(count) background tasks are running normally."
    }

    static func otherLoopsHealthyText(count: Int) -> String {
        count == 1 ? "1 other background task is running normally."
                   : "\(count) other background tasks are running normally."
    }
}

struct DoctorCheckRow: View {
    var check: CheckResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                InlineStatusDot(status: check.status)
                Text(check.title.withoutStaleNextGenPhaseCopy)
                    .font(NativeAgentFont.section)
                Spacer()
                StatusBadge(text: check.status.uppercased(), status: check.status)
            }
            Text(check.detail.withoutStaleNextGenPhaseCopy)
                .font(NativeAgentFont.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let repair = check.repair, !repair.isEmpty {
                Text(repair.withoutStaleNextGenPhaseCopy)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            if let action = check.human_action, !action.isEmpty {
                Text(action.withoutStaleNextGenPhaseCopy)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            if let receipt = check.receipt, !receipt.isEmpty {
                Text(receipt.withoutStaleNextGenPhaseCopy)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
