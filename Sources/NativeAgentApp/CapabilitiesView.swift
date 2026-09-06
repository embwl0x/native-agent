import Foundation
import SwiftUI

// MARK: - The Advanced page kit
//
// 2026-09-03 finish pass. Capabilities, Knowledge Graph and Dreams sit inside
// `ShellPageFrame` (SetupView.swift:110), which already draws the back row, the
// title and the sheet. These are the only surfaces the three pages add on top
// of it: one card, one eyebrow, one empty state, one waiting line — everything
// else is words on the sheet. Type comes from `ShellType`, colour from
// `NativeAgentShell`, and nothing here paints a material.

/// The one card the Advanced pages draw: a group of controls, or a list row.
/// Today's fill and stroke at Today's radius, 16 of padding — the same card
/// Setup's Advanced list uses for a route row.
struct AdvancedCard<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .fill(TodayPalette.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .strokeBorder(TodayPalette.cardStroke, lineWidth: 1)
        )
    }
}

/// A section head, spelled exactly like the Advanced list's: 13 semibold,
/// uppercase, 0.6 of tracking, on the sheet rather than on a plate.
struct AdvancedEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ShellType.labelSemibold)
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(NativeAgentShell.secondary)
            .padding(.horizontal, 2)
    }
}

/// An eyebrow and the card under it — what a panel becomes on these pages.
struct AdvancedSection<Content: View>: View {
    let title: String
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdvancedEyebrow(text: title)
            AdvancedCard(spacing: spacing) { content }
        }
    }
}

/// What would fill this, said in the page's own left column. No plate, no
/// glyph, no tinted button — an empty state is a sentence, not a poster.
struct AdvancedEmptyState: View {
    let title: String
    var detail: String = ""
    var actionTitle: String?
    var actionIsDisabled = false
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            if !detail.isEmpty {
                Text(detail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .disabled(actionIsDisabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

/// A read that has not landed yet. One line, one small spinner — never a
/// centred `ProgressView` claiming the whole pane.
struct AdvancedWaitingLine: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A status, said in the room's three state colours. `calm` when a thing is up,
/// `trouble` when it is not, the teal ONLY where something waits on a person
/// (house rule 1), and the quiet ink for everything that is merely a fact.
enum AdvancedStatusWords {
    static func color(_ status: String?) -> Color {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending", "awaiting_approval", "needs_approval":
            return NativeAgentShell.needsYou
        case "ok", "done", "passed", "succeeded", "active", "valid", "ready",
             "scheduled", "granted", "installed", "approved", "trusted", "healthy":
            return NativeAgentShell.calm
        case "fail", "failed", "error", "timeout", "quarantined", "evidence_failed",
             "denied", "revoked", "refused", "warn", "warning", "blocked",
             "needs_setup", "interrupted", "disabled", "rolled_back", "stale":
            return NativeAgentShell.trouble
        default:
            return NativeAgentShell.secondary
        }
    }

    /// No slugs in front of a person: `needs_setup` is "Needs setup".
    static func label(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = known[trimmed.lowercased()] { return known }
        let spaced = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first, first.isLowercase else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }

    private static let known: [String: String] = [
        "ok": "OK",
        "warn": "Warning",
        "fail": "Failed",
        "info": "Working",
        "mcp": "MCP",
    ]
}

/// One status word. The badge it replaces was a tinted capsule; on the sheet a
/// coloured word says the same thing without a second plate.
struct AdvancedStatusWord: View {
    let status: String?
    var text: String?

    var body: some View {
        Text(AdvancedStatusWords.label(text ?? status ?? ""))
            .font(ShellType.caption)
            .foregroundStyle(AdvancedStatusWords.color(status))
            .lineLimit(1)
    }
}

/// A fact beside a row — what the pill used to carry, without the pill.
struct AdvancedMeta: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.tertiary)
            .lineLimit(1)
    }
}

/// A number and what it counts. Bare by construction: these sit INSIDE a card,
/// and a card inside a card is the plate-on-plate the pass exists to remove.
struct AdvancedStat: View {
    let title: String
    let value: String
    var detail: String = ""
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(ShellType.bodySemibold)
                .monospacedDigit()
                .foregroundStyle(status.map(AdvancedStatusWords.color) ?? NativeAgentShell.text)
                .lineLimit(1)
            Text(title)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(1)
            if !detail.isEmpty {
                Text(AdvancedStatusWords.label(detail))
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tile that DOES sit on the sheet — the five counts at the top of
/// Capabilities — so it wears the card itself.
struct AdvancedSummaryTile: View {
    let title: String
    let value: String

    var body: some View {
        AdvancedCard(spacing: 2) {
            Text(value)
                .font(ShellType.title)
                .monospacedDigit()
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
            Text(title)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(1)
        }
    }
}

/// Type the shell has no token for: a code is a code, and 13 monospaced is the
/// one exception the kit allows. Sized off `ShellType`, never a loose number.
enum AdvancedType {
    static let code = Font.system(size: ShellType.labelSize, design: .monospaced)
    static let codeCaption = Font.system(size: ShellType.captionSize, design: .monospaced)
}

/// A bare fold: a chevron, the words, and one gesture on the whole row. No
/// plate, and the motion goes through the shell's fold spring.
struct AdvancedFold<Content: View>: View {
    let title: String
    var subtitle: String = ""
    /// What the fold would otherwise hide — the one signal that survives a
    /// collapse.
    var attention: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(
                    NativeAgentMotion.respecting(ShellFoldMotion.open, reduceMotion: reduceMotion)
                ) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(ShellType.labelSemibold)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(ShellType.bodySemibold)
                            .foregroundStyle(NativeAgentShell.text)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if let attention {
                        AdvancedStatusWord(status: "warn", text: attention)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .transition(ShellFoldMotion.transition(reduceMotion: reduceMotion))
            }
        }
    }
}

enum CapabilitiesDisclosurePreference {
    static let nextGenKey = "capabilitiesShowNextGen"

    static func isNextGenExpanded(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: nextGenKey)
    }

    static func setNextGenExpanded(_ isExpanded: Bool, in defaults: UserDefaults) {
        defaults.set(isExpanded, forKey: nextGenKey)
    }
}

enum CapabilitiesPresentation {
    /// Missing metadata is privileged ambiguity, never permission to run.
    static func runRequiresApproval(_ action: NativeActionRecord) -> Bool {
        action.requiresApproval != false
    }
}

/// The overview tiles are evidence from a scoped Capabilities refresh, not
/// launch defaults. A dash is intentional: it says the source was not loaded
/// (or failed) instead of silently reporting zero capabilities.
enum CapabilitiesRefreshPresentation {
    struct SummaryTiles: Equatable {
        let capabilities: String
        let workflows: String
        let mcp: String
        let nextGen: String
        let approvals: String
        let notice: String?
    }

    static func summary(
        capabilityCount: Int?,
        workflowCount: Int,
        mcpCount: Int,
        nextGenReadyCount: Int,
        nextGenTotalCount: Int,
        approvalCount: Int,
        refresh: AppModel.PanelRefreshStatus?
    ) -> SummaryTiles {
        let failures = Set(refresh?.failedEndpoints.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } ?? [])
        func value(_ value: String, endpoint: String) -> String {
            guard refresh != nil, !failures.contains(endpoint) else { return "—" }
            return value
        }
        let unavailable = refresh == nil
            ? "Capability summary is loading."
            : failures.isEmpty ? nil
            : "Some capability data is unavailable; tiles marked — were not loaded."
        return SummaryTiles(
            capabilities: value(capabilityCount.map { String($0) } ?? "—", endpoint: "capability summary"),
            workflows: value(String(workflowCount), endpoint: "workflows"),
            mcp: value(String(mcpCount), endpoint: "mcp servers"),
            nextGen: value("\(nextGenReadyCount)/\(nextGenTotalCount)", endpoint: "nextgen summary"),
            approvals: value(String(approvalCount), endpoint: "approvals"),
            notice: unavailable
        )
    }
}

/// The footer is scoped to Capabilities. `AppModel.statusText` is intentionally
/// global and can be replaced by a chat, approval, or background operation
/// before this view redraws; rendering it here made unrelated work look like a
/// Capabilities result.
enum CapabilitiesStatusLinePresentation {
    struct State: Equatable {
        let text: String
        let status: String
    }

    static func resolve(refresh: AppModel.PanelRefreshStatus?) -> State {
        guard let refresh else {
            return State(
                text: "Capabilities data has not loaded yet.",
                status: "info"
            )
        }
        guard !refresh.isStale else {
            let count = refresh.failedEndpoints.count
            let source = count == 1 ? "source" : "sources"
            guard refresh.lastSuccessAt != nil else {
                return State(
                    text: "Capabilities data is unavailable: \(count) \(source) did not load.",
                    status: "failed"
                )
            }
            return State(
                text: "Capabilities refresh is incomplete: \(count) \(source) did not load. Showing last known data where available.",
                status: "warn"
            )
        }
        return State(text: "Capabilities data is current.", status: "ok")
    }
}

struct CapabilitiesStatusTextLine: View {
    let state: CapabilitiesStatusLinePresentation.State

    var body: some View {
        Text(state.text)
            .font(ShellType.caption)
            .foregroundStyle(AdvancedStatusWords.color(state.status))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("capabilities.statusText")
    }
}

/// The compact MCP Builder depends on three separately-read authorities. Do
/// not collapse a failed registry/session/consent read into an empty builder;
/// the detailed MCP hub remains the canonical full surface.
enum CapabilityMCPBuilderPresentation {
    enum ReadState: Equatable {
        case loading
        case empty
        case available
        case stale
        case unavailable
    }

    struct State: Equatable {
        let servers: ReadState
        let sessions: ReadState
        let consents: ReadState
        let sessionErrorCount: Int

        var collapsedAttentionBadge: String? {
            if sessionErrorCount > 0 {
                return "\(sessionErrorCount) error\(sessionErrorCount == 1 ? "" : "s")"
            }
            if servers == .unavailable || sessions == .unavailable || consents == .unavailable {
                return "MCP unavailable"
            }
            if servers == .stale || sessions == .stale || consents == .stale {
                return "MCP stale"
            }
            return nil
        }

        var serverEmptyCopy: String? {
            switch servers {
            case .loading:
                return "MCP servers have not loaded yet."
            case .empty:
                return "No MCP servers configured."
            case .unavailable:
                return "MCP server registry is unavailable. Refresh Capabilities to try again."
            case .available, .stale:
                return nil
            }
        }

        var detailNotice: String? {
            if sessions == .unavailable || consents == .unavailable {
                return "Live MCP session or consent details are unavailable; do not rely on missing status rows."
            }
            if sessions == .stale || consents == .stale {
                return "Some MCP session or consent details are from the last successful refresh."
            }
            if servers == .stale {
                return "Showing the last loaded MCP server registry."
            }
            return nil
        }
    }

    static func resolve(
        serverCount: Int,
        sessionCount: Int,
        consentCount: Int,
        sessionErrorCount: Int,
        hasRefreshAttempt: Bool,
        failedEndpoints: [String]
    ) -> State {
        let failures = Set(failedEndpoints.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return State(
            servers: readState(
                count: serverCount,
                hasRefreshAttempt: hasRefreshAttempt,
                failed: failures.contains("mcp servers")
            ),
            sessions: readState(
                count: sessionCount,
                hasRefreshAttempt: hasRefreshAttempt,
                failed: failures.contains("mcp sessions")
            ),
            consents: readState(
                count: consentCount,
                hasRefreshAttempt: hasRefreshAttempt,
                failed: failures.contains("mcp consent")
            ),
            sessionErrorCount: max(0, sessionErrorCount)
        )
    }

    private static func readState(count: Int, hasRefreshAttempt: Bool, failed: Bool) -> ReadState {
        if failed { return count > 0 ? .stale : .unavailable }
        if !hasRefreshAttempt { return count > 0 ? .available : .loading }
        return count > 0 ? .available : .empty
    }
}

enum NativeMacPowerPanelPresentation {
    enum ReadState: Equatable {
        case loading
        case available
        case stale
        case unavailable
    }

    struct Tile: Equatable {
        let value: String
        let detail: String
        let status: String
        let readState: ReadState
    }

    struct Action: Equatable {
        let canDryRun: Bool
        let canRun: Bool
        let blockedDetail: String?
    }

    static func tile(
        value: String?,
        detail: String?,
        runtimeStatus: String?,
        hasRefreshAttempt: Bool,
        readFailed: Bool
    ) -> Tile {
        let hasContent = runtimeStatus?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if readFailed {
            return Tile(
                value: value ?? "—",
                detail: hasContent ? "Showing last loaded data; refresh failed." : "Status unavailable; refresh failed.",
                status: "warn",
                readState: hasContent ? .stale : .unavailable
            )
        }
        guard hasContent else {
            return Tile(
                value: "—",
                detail: hasRefreshAttempt ? "Status unavailable." : "Checking status…",
                status: hasRefreshAttempt ? "warn" : "info",
                readState: hasRefreshAttempt ? .unavailable : .loading
            )
        }
        return Tile(
            value: value ?? "—",
            detail: nonEmpty(detail) ?? "No detail reported.",
            status: runtimeStatus ?? "unknown",
            readState: .available
        )
    }

    static func action(
        requiresApproval: Bool?,
        dryRunAvailable: Bool?,
        fullMacYoloAdmitted: Bool = false
    ) -> Action {
        if requiresApproval != false, !fullMacYoloAdmitted {
            return Action(
                canDryRun: dryRunAvailable != false,
                canRun: false,
                blockedDetail: "Approval is required before this action can run."
            )
        }
        if dryRunAvailable == false {
            return Action(
                canDryRun: false,
                canRun: true,
                blockedDetail: "Dry run is unavailable for this action."
            )
        }
        return Action(canDryRun: true, canRun: true, blockedDetail: nil)
    }

    static func readState(
        itemCount: Int,
        hasRefreshAttempt: Bool,
        readFailed: Bool
    ) -> ReadState {
        if readFailed { return itemCount > 0 ? .stale : .unavailable }
        if itemCount > 0 { return .available }
        return hasRefreshAttempt ? .available : .loading
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CapabilityCatalogInstallOutcome: Equatable {
    case installed(name: String)
    case refused(message: String)

    var message: String {
        switch self {
        case .installed(let name): "Installed signed pack \(name)."
        case .refused(let message): "Pack install refused: \(message)"
        }
    }

    var systemImage: String {
        switch self {
        case .installed: "checkmark.seal.fill"
        case .refused: "exclamationmark.triangle.fill"
        }
    }

    var status: String {
        switch self {
        case .installed: "ok"
        case .refused: "warn"
        }
    }
}

struct CapabilityCatalogInstallOutcomeRow: View {
    let outcome: CapabilityCatalogInstallOutcome

    var body: some View {
        Text(outcome.message)
            .font(ShellType.label)
            .foregroundStyle(AdvancedStatusWords.color(outcome.status))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("capabilities.catalog.install-outcome")
    }
}

/// The hardening report is an externalized runtime authority, not a local
/// inference. Keep its missing and unavailable states explicit so an export
/// can be used to diagnose the latter without claiming the former is healthy.
enum CapabilityProductionExportButtonsPresentation {
    struct Notice: Equatable {
        let detail: String
        let status: String
    }

    static func notice(for outcome: ProductionExportCreationOutcome) -> Notice {
        switch outcome {
        case .verified(let export):
            let kind = export.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = kind?.isEmpty == false ? kind!.capitalized : "Export"
            let bytes = export.sizeBytes ?? 0
            return Notice(
                detail: "\(label) created and verified: \(export.path) (\(bytes) bytes).",
                status: "ok"
            )
        case .failed(let support, let detail):
            let label = support ? "Support bundle" : "Export"
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return Notice(
                detail: "\(label) was not verified: \(trimmed.isEmpty ? "no error detail was returned" : trimmed)",
                status: "failed"
            )
        }
    }
}

struct CapabilityProductionHardeningPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var exportNotice: CapabilityProductionExportButtonsPresentation.Notice?
    @State private var isCreatingExport = false

    var body: some View {
        AdvancedSection(title: "Production hardening") {
            if let hardening = appModel.productionHardening {
                HStack(spacing: 8) {
                    AdvancedStatusWord(status: hardening.status)
                    if let doctor = hardening.doctorStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !doctor.isEmpty {
                        AdvancedStatusWord(status: doctor, text: "Doctor \(doctor)")
                    }
                    Spacer()
                    Button(isCreatingExport ? "Creating export…" : "Export") {
                        Task { await createExport(support: false) }
                    }
                    .controlSize(.small)
                    .disabled(isCreatingExport)
                    .accessibilityIdentifier("capabilities.hardening.export")
                    Button(isCreatingExport ? "Creating bundle…" : "Support bundle") {
                        Task { await createExport(support: true) }
                    }
                    .controlSize(.small)
                    .disabled(isCreatingExport)
                    .accessibilityIdentifier("capabilities.hardening.support-bundle")
                }

                if let detail = hardening.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !detail.isEmpty {
                    Text(detail)
                        .font(ShellType.label)
                        .foregroundStyle(AdvancedStatusWords.color(hardening.status))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capabilities.hardening.detail")
                }

                if let exportNotice {
                    Text(exportNotice.detail)
                        .font(ShellType.label)
                        .foregroundStyle(AdvancedStatusWords.color(exportNotice.status))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capabilities.hardening.export-receipt")
                }

                if let latest = appModel.productionExports.first {
                    CapabilityDetailRow(
                        title: (latest.kind ?? "export").capitalized,
                        detail: "\(latest.path) · \(latest.sizeBytes ?? 0) bytes",
                        status: "ok"
                    )
                }

                if let release = hardening.release {
                    VStack(alignment: .leading, spacing: 12) {
                        if !release.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            AdvancedStatusWord(
                                status: release.status,
                                text: "Release: \(AdvancedStatusWords.label(release.status))"
                            )
                        }
                        if release.items.isEmpty {
                            Text("The release checklist has no recorded checks.")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                        } else {
                            ForEach(release.items.prefix(8)) { item in
                                CapabilityDetailRow(
                                    title: item.title,
                                    detail: item.detail,
                                    status: item.status
                                )
                            }
                        }
                    }
                } else {
                    Text("This report did not include a release checklist.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            } else {
                Text("Production summary has not loaded yet.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
        .accessibilityIdentifier("capabilities.production-hardening")
    }

    @MainActor
    private func createExport(support: Bool) async {
        guard !isCreatingExport else { return }
        isCreatingExport = true
        defer { isCreatingExport = false }
        exportNotice = CapabilityProductionExportButtonsPresentation.notice(
            for: await appModel.createProductionExport(support: support)
        )
    }
}

struct CapabilitiesView: View {
    @Environment(AppModel.self) private var appModel
    @State private var mode: CapabilityWorkspaceMode
    @State private var routeText = "Research a topic, build a reusable tool if it repeats, and keep it approval-gated."
    @State private var researchObjective = "Find current best practices for lightweight autonomous agent capability systems."
    @State private var researchLabRunsState: CapabilitiesResearchLabPresentation.RunList = .loading
    @State private var researchLabMessage: CapabilitiesResearchLabPresentation.Message?
    @State private var isRunningResearchLab = false
    @State private var mcpQuery = "NativeAgent capabilities"
    @State private var catalogSourceName = "Local NativeAgent Catalog"
    @State private var catalogSourceURL = ""
    @State private var catalogSourceOutcome: AppModel.CapabilityCatalogSourceSaveOutcome?
    /// Per-action result from the checked SecurityCenter authority owner.
    /// Missing stays conservative: the Run button remains disabled until a
    /// current policy/origin read proves admitted Full Mac YOLO.
    @State private var nativeActionYoloAdmission: [String: Bool] = [:]
    private let loadsOnAppear: Bool
    // 2026-07-22 page-tighten: the two heaviest always-expanded blocks
    // (Next-Gen Runtime migration cockpit in Overview, MCP Builder in Build —
    // whose canonical home is the dedicated MCP tab) collapse by default;
    // open-state persists across visits like the Trust Advanced group.
    @AppStorage(CapabilitiesDisclosurePreference.nextGenKey) private var showNextGen = false
    @AppStorage("capabilitiesShowMCPBuilder") private var showMCPBuilder = false

    init(initialMode: CapabilityWorkspaceMode = .overview, loadsOnAppear: Bool = true) {
        _mode = State(initialValue: initialMode)
        self.loadsOnAppear = loadsOnAppear
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Workspace", selection: $mode) {
                    ForEach(CapabilityWorkspaceMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                summaryGrid

                switch mode {
                case .overview:
                    overview
                case .build:
                    build
                case .operate:
                    operate
                case .hardening:
                    hardening
                }

                CapabilitiesStatusTextLine(
                    state: CapabilitiesStatusLinePresentation.resolve(
                        refresh: appModel.panelRefreshStatus[.capabilities]
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
        .navigationTitle("Capabilities")
        .task {
            guard loadsOnAppear else { return }
            await appModel.refreshForSidebarItem(.capabilities)
            await refreshNativeActionYoloAdmission()
            await refreshResearchLabRuns()
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task {
                    await appModel.refreshForSidebarItem(.capabilities)
                    await refreshNativeActionYoloAdmission()
                    await refreshResearchLabRuns()
                }
            }
        }
    }

    private var summaryGrid: some View {
        let tiles = CapabilitiesRefreshPresentation.summary(
            capabilityCount: appModel.capabilitySummary?.summary.total,
            workflowCount: appModel.workflows.count,
            mcpCount: appModel.mcpServers.count,
            nextGenReadyCount: nextGenReadyCount,
            nextGenTotalCount: nextGenTotalCount,
            approvalCount: appModel.approvals.filter { $0.status.lowercased() == "pending" }.count,
            refresh: appModel.panelRefreshStatus[.capabilities]
        )
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                AdvancedSummaryTile(title: "Capabilities", value: tiles.capabilities)
                AdvancedSummaryTile(title: "Workflows", value: tiles.workflows)
                AdvancedSummaryTile(title: "MCP servers", value: tiles.mcp)
                AdvancedSummaryTile(title: "Next-gen phases", value: tiles.nextGen)
                AdvancedSummaryTile(title: "Approvals", value: tiles.approvals)
            }
            if let notice = tiles.notice {
                Text(notice)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // 2026-07-22 page-tighten: the two heaviest blocks fold away by default.
    // 2026-07-23 audit F5-L1: a fold hides its inner attention state (e.g. an
    // MCP session's lastError). When the underlying state carries an attention
    // signal, the fold row says so, so the signal survives the collapse. Nil =
    // nothing to say (identical to before).
    // 2026-09-03 kit pass: the plate and the tinted badge are gone. A fold is a
    // chevron, the words and one gesture (AdvancedFold); the attention signal is
    // now a word in the room's trouble colour on the same row.
    private func collapsedCard<Content: View>(
        title: String,
        subtitle: String,
        isExpanded: Binding<Bool>,
        attentionBadge: String? = nil,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        AdvancedFold(
            title: title,
            subtitle: subtitle,
            attention: attentionBadge,
            isExpanded: isExpanded
        ) {
            content()
        }
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            // L3#7 (2026-08-11): the "Capability Foundry" panel is deleted.
            // E-1 already stripped its fake counters; what was left was a
            // status badge and 2-3 lane tiles over a subsystem that was never
            // ported (no auto-implementation ledger, no review pipeline). The
            // Core CapabilityFoundry stays behind its MCP metadata consumer;
            // the panel claimed a workshop that does not exist.

            collapsedCard(
                title: "Next-gen runtime",
                subtitle: "Phase readiness, dry-run probes, and migration receipts.",
                isExpanded: $showNextGen,
                attentionBadge: nextGenReviewCount > 0 ? "\(nextGenReviewCount) to review" : nil,
                accessibilityIdentifier: "capabilities.show-next-gen"
            ) {
                nextGenRuntime
            }

            AdvancedSection(title: "Foundry index") {
                switch CapabilitiesFoundryIndexPresentation.state(summary: appModel.capabilitySummary) {
                case .populated(let summary):
                    HStack(spacing: 12) {
                        AdvancedStatusWord(status: "ok", text: "\(summary.summary.active) active")
                        AdvancedStatusWord(
                            status: summary.summary.review > 0 ? "warn" : "ok",
                            text: "\(summary.summary.review) to review"
                        )
                        AdvancedStatusWord(
                            status: summary.summary.autoloaded == 0 ? "ok" : "warn",
                            text: "\(summary.summary.autoloaded) autoloaded"
                        )
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(summary.records.prefix(14))) { capability in
                            CapabilityRow(capability: capability)
                        }
                    }
                case .empty:
                    AdvancedEmptyState(
                        title: "No indexed capabilities",
                        detail: CapabilitiesFoundryIndexPresentation.emptyDetail
                    )
                case .unavailable:
                    AdvancedEmptyState(
                        title: "Foundry index unavailable",
                        detail: CapabilitiesFoundryIndexPresentation.unavailableDetail
                    )
                case .inconsistent(let reason):
                    AdvancedEmptyState(
                        title: "Foundry index needs a refresh",
                        detail: CapabilitiesFoundryIndexPresentation.inconsistentDetail(reason)
                    )
                }
            }

            AdvancedSection(title: "Personal OS") {
                if let personalOS = appModel.personalOS {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                        ForEach(personalOS.spaces) { space in
                            AdvancedStat(title: space.name, value: "\(space.count)", detail: space.kind ?? "space")
                        }
                    }
                } else {
                    Text("Personal OS summary has not loaded yet.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }
        }
    }

    private var nextGenLoadedPhases: [NextGenPhase] {
        var seen = Set<String>()
        let combined = appModel.nextGenPhases + (appModel.nextGenSummary?.phases ?? [])
        return combined
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                switch (lhs.phaseNumber, rhs.phaseNumber) {
                case let (left?, right?):
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
            }
    }

    private var nextGenReadyCount: Int {
        if let count = appModel.nextGenSummary?.readyPhaseCount {
            return count
        }
        return nextGenLoadedPhases.filter { $0.ready == true || $0.displayStatus == "ready" }.count
    }

    private var nextGenTotalCount: Int {
        appModel.nextGenSummary?.totalPhaseCount ?? nextGenLoadedPhases.count
    }

    // F5-L1 attention signals surfaced on the collapsed card headers.
    // Next-Gen: phases not yet ready are the review-needed count. MCP: sessions
    // reporting a non-empty lastError (the detail otherwise hidden at :532).
    private var nextGenReviewCount: Int {
        max(0, nextGenTotalCount - nextGenReadyCount)
    }

    private var mcpBuilderPresentation: CapabilityMCPBuilderPresentation.State {
        let refresh = appModel.panelRefreshStatus[.capabilities]
        return CapabilityMCPBuilderPresentation.resolve(
            serverCount: appModel.mcpServers.count,
            sessionCount: appModel.mcpSessions.count,
            consentCount: appModel.mcpConsent.count,
            sessionErrorCount: appModel.mcpSessions.filter {
                !($0.lastError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }.count,
            hasRefreshAttempt: refresh != nil,
            failedEndpoints: refresh?.failedEndpoints ?? []
        )
    }

    private var nextGenReceipts: [NextGenReceipt] {
        var seen = Set<String>()
        let combined =
            (appModel.latestNextGenReceipt.map { [$0] } ?? []) +
            appModel.nextGenReceipts +
            (appModel.nextGenSummary?.displayReceipts ?? []) +
            nextGenLoadedPhases.compactMap(\.latestReceipt)
        return combined.filter { seen.insert($0.id).inserted }
    }

    /// L3#6 (2026-08-11): the catalog (`nextgen_phases.json`) is a data file and
    /// can list any action id; the read-only executor is a fixed switch. Only
    /// ids that switch actually has a case for get a button — everything else
    /// resolves to `default:` → 410 "not backed by a Swift read-only executor
    /// yet", which is a button that cannot do its job. One set intersection.
    private var nextGenActions: [NextGenAction] {
        var seen = Set<String>()
        let combined = (appModel.nextGenSummary?.actions ?? []) + nextGenLoadedPhases.flatMap { $0.actions ?? [] }
        return combined
            .filter { NativeClient.isNextGenActionBacked($0.id) }
            .filter { seen.insert($0.id).inserted }
    }

    private var nextGenRuntime: some View {
        AdvancedCard {
            if appModel.nextGenSummary == nil && nextGenLoadedPhases.isEmpty && appModel.latestNextGenReceipt == nil {
                Text("Next-gen runtime summary has not loaded yet.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            } else {
                HStack(spacing: 12) {
                    AdvancedStatusWord(status: appModel.nextGenSummary?.readinessStatus ?? "ready")
                    if let current = appModel.nextGenSummary?.currentPhaseName ?? appModel.nextGenSummary?.currentPhaseId {
                        AdvancedMeta(current.withoutStaleNextGenPhaseCopy)
                    }
                    AdvancedMeta("\(nextGenLoadedPhases.count) phases")
                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                    AdvancedStat(
                        title: "Phase readiness",
                        value: "\(nextGenReadyCount)/\(nextGenTotalCount)",
                        detail: appModel.nextGenSummary?.readiness ?? "ready phases",
                        status: appModel.nextGenSummary?.readinessStatus ?? "ready"
                    )
                    AdvancedStat(
                        title: "Receipts",
                        value: "\(appModel.nextGenSummary?.receiptCount ?? nextGenReceipts.count)",
                        detail: nextGenReceipts.first?.displayStatus ?? "none yet",
                        status: nextGenReceipts.first?.displayStatus ?? "warn"
                    )
                    AdvancedStat(
                        title: "Dry-run probes",
                        value: "\(appModel.nextGenSummary?.actionCount ?? nextGenActions.count)",
                        detail: appModel.isRunningNextGenAction ? "running" : "available",
                        status: appModel.isRunningNextGenAction ? "running" : "ready"
                    )
                }

                if !nextGenLoadedPhases.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(nextGenLoadedPhases) { phase in
                            NextGenPhaseRow(phase: phase, isRunning: appModel.isRunningNextGenAction) { actionId in
                                Task { await appModel.runNextGenAction(id: actionId, dryRun: true) }
                            }
                        }
                    }
                }

                if !nextGenActions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(nextGenActions.prefix(4)) { action in
                            Button(action.displayName) {
                                Task { await appModel.runNextGenAction(action, dryRun: true) }
                            }
                            .disabled(appModel.isRunningNextGenAction || action.dryRunAvailable == false)
                        }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                }

                if !nextGenReceipts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(nextGenReceipts.prefix(6)) { receipt in
                            // 2026-06-07 ui-taste-sweep #83: humanized title +
                            // subtitle replaces the raw kv-dump. rawPairs adds
                            // a "Show details" disclosure for the full payload.
                            let h = receipt.humanized
                            CapabilityDetailRow(
                                title: h.title,
                                detail: h.subtitle,
                                status: receipt.displayStatus,
                                rawPairs: h.rawPairs.isEmpty ? nil : h.rawPairs
                            )
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("capabilities.show-next-gen.content")
    }

    private var build: some View {
        VStack(alignment: .leading, spacing: 24) {
            // W3 (eval5): surface the "feature disabled / not implemented"
            // envelope for Build-tab actions (capability pack install,
            // MCP warm/refresh) so users see why nothing happened
            // instead of a fake success toast.
            if let disabled = appModel.disabledFeature, !disabled.isEmpty {
                Text(disabled)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WorkflowBuilderPanel()

            AdvancedSection(title: "Capability catalog") {
                HStack(spacing: 8) {
                    Button("Install the signed demo pack") {
                        Task { await appModel.installDemoCapabilityPack() }
                    }
                    .controlSize(.small)
                    .disabled(appModel.isInstallingDemoCapabilityPack)
                    .accessibilityIdentifier("capabilities.catalog.install-signed-demo")
                    .accessibilityHint("Verifies the demo pack signature before any capability files are written. Evaluate trust is informational and is not required to install.")
                    Button("Check for updates") {
                        Task { await appModel.checkCapabilityUpdates() }
                    }
                    .controlSize(.small)
                    if let capability = appModel.capabilitySummary?.records.first {
                        Button("Evaluate trust") {
                            Task { await appModel.evaluateCapabilityTrust(capability) }
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                    AdvancedMeta("\(appModel.capabilityPackInstalls.count) installed")
                }

                if let outcome = appModel.capabilityCatalogInstallOutcome {
                    CapabilityCatalogInstallOutcomeRow(outcome: outcome)
                }

                HStack(spacing: 8) {
                    TextField("Source name", text: $catalogSourceName)
                        .textFieldStyle(.roundedBorder)
                        .font(ShellType.label)
                        .accessibilityIdentifier("capabilities.catalogSource.name")
                    TextField("Source URL or path", text: $catalogSourceURL)
                        .textFieldStyle(.roundedBorder)
                        .font(ShellType.label)
                        .accessibilityIdentifier("capabilities.catalogSource.url")
                    Button(appModel.capabilityCatalogSourceSaveInFlight ? "Saving source…" : "Add source") {
                        addCatalogSource()
                    }
                    .controlSize(.small)
                    .disabled(appModel.capabilityCatalogSourceSaveInFlight)
                    .accessibilityIdentifier("capabilities.catalogSource.add")
                }

                if let catalogSourceOutcome {
                    Text(catalogSourceOutcome.detail)
                        .font(ShellType.label)
                        .foregroundStyle(AdvancedStatusWords.color(catalogSourceOutcome.status))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capabilities.catalogSource.outcome")
                }

                if !appModel.capabilityCatalogSources.isEmpty || appModel.capabilityTrust != nil || appModel.latestCapabilityUpdateCheck != nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                        AdvancedStat(title: "Sources", value: "\(appModel.capabilityCatalogSources.count)", detail: appModel.capabilityCatalogSources.first?.status ?? "not checked")
                        AdvancedStat(title: "Trusted", value: "\(appModel.capabilityTrust?.summary?.trusted ?? 0)", detail: "\(appModel.capabilityTrust?.summary?.review ?? 0) to review")
                        AdvancedStat(title: "Updates", value: "\(appModel.latestCapabilityUpdateCheck?.updates.count ?? 0)", detail: appModel.latestCapabilityUpdateCheck?.status ?? "not checked")
                    }
                }

                if let trust = appModel.latestCapabilityTrustEvaluation {
                    CapabilityDetailRow(title: trust.name ?? trust.id, detail: trust.reasons.prefix(2).joined(separator: " "), status: trust.trustTier)
                }

                if appModel.capabilityCatalog.isEmpty {
                    AdvancedEmptyState(
                        title: "No catalog items",
                        detail: "Adding a source, or installing a signed pack, fills this list."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(appModel.capabilityCatalog) { item in
                            CatalogRow(item: item)
                        }
                    }
                }

                if !appModel.capabilityPackInstalls.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(appModel.capabilityPackInstalls.prefix(4)) { install in
                            HStack(alignment: .top, spacing: 8) {
                                CapabilityDetailRow(
                                    title: install.name ?? install.packId,
                                    detail: "\(install.version ?? "unknown") · \(install.signature?.prefix(12) ?? "unsigned")",
                                    status: install.status
                                )
                                Spacer()
                                Button("Roll back") {
                                    Task { await appModel.rollbackCapabilityPack(install) }
                                }
                                .controlSize(.small)
                                .disabled(install.status == "rolled_back")
                            }
                        }
                    }
                }
            }

            collapsedCard(
                title: "MCP builder",
                subtitle: "Server warm and restart, tool calls, and consent — the full hub lives in the MCP page.",
                isExpanded: $showMCPBuilder,
                attentionBadge: mcpBuilderPresentation.collapsedAttentionBadge
            ) {
                mcpBuilderPanel
            }
        }
    }

    private func addCatalogSource() {
        catalogSourceOutcome = nil
        Task {
            let outcome = await appModel.addCatalogSource(name: catalogSourceName, url: catalogSourceURL)
            catalogSourceOutcome = outcome
            if outcome.didSave {
                catalogSourceName = ""
                catalogSourceURL = ""
            }
        }
    }

    private var mcpBuilderPanel: some View {
        let presentation = mcpBuilderPresentation
        return AdvancedCard {
            HStack {
                Button("Open the MCP page") {
                    NotificationCenter.default.post(name: .openCommandRouteRequest, object: "mcp")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            TextField("MCP test query", text: $mcpQuery)
                .textFieldStyle(.roundedBorder)
                .font(ShellType.label)
            if let detailNotice = presentation.detailNotice {
                Text(detailNotice)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let serverEmptyCopy = presentation.serverEmptyCopy {
                Text(serverEmptyCopy)
                    .font(ShellType.label)
                    .foregroundStyle(presentation.servers == .unavailable ? NativeAgentShell.trouble : NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(appModel.mcpServers) { server in
                        VStack(alignment: .leading, spacing: 8) {
                            MCPServerRow(server: server) {
                                Task { await appModel.loadMCPDetails(server) }
                            }
                            HStack(spacing: 8) {
                                Button("Warm") {
                                    Task { await appModel.warmMCPServer(server) }
                                }
                                Button("Restart") {
                                    Task { await appModel.restartMCPServer(server) }
                                }
                                Button("Refresh the cache") {
                                    Task { await appModel.refreshMCPCache(server) }
                                }
                                if let session = appModel.mcpSessions.first(where: { $0.serverId == server.id }) {
                                    AdvancedStatusWord(status: session.status ?? "configured")
                                    if let error = session.lastError, !error.isEmpty {
                                        Text(error)
                                            .font(ShellType.caption)
                                            .foregroundStyle(NativeAgentShell.trouble)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if !appModel.mcpTools.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(appModel.mcpTools.prefix(6)) { tool in
                        HStack(alignment: .top, spacing: 8) {
                            CapabilityDetailRow(title: tool.name, detail: tool.description ?? "MCP tool", status: "ok")
                            Spacer()
                            if let server = appModel.selectedMCPServer {
                                Button("Grant") {
                                    Task { await appModel.grantMCPConsent(server: server, toolName: tool.name) }
                                }
                                .controlSize(.small)
                                Button("Call") {
                                    Task { await appModel.callMCPTool(server: server, tool: tool, query: mcpQuery) }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            if let call = appModel.latestMCPCall {
                CapabilityDetailRow(
                    title: call.toolName,
                    detail: [call.serverId, call.resultPreview]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "),
                    status: call.evidenceStatus == "failed" ? "evidence_failed" : call.status
                )
            }

            if !appModel.mcpConsent.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(appModel.mcpConsent.prefix(4)) { consent in
                        HStack(alignment: .top, spacing: 8) {
                            CapabilityDetailRow(
                                title: consent.toolName ?? consent.id,
                                detail: consent.argumentSummary ?? consent.serverId ?? "MCP consent",
                                status: consent.status ?? "granted"
                            )
                            Spacer()
                            Button("Revoke") {
                                Task { await appModel.revokeMCPConsent(consent) }
                            }
                            .controlSize(.small)
                            .disabled(consent.status == "revoked")
                        }
                    }
                }
            }
        }
    }

    private var operate: some View {
        VStack(alignment: .leading, spacing: 24) {
            AdvancedSection(title: "Intent router") {
                TextField("Task to route", text: $routeText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(ShellType.label)
                    .lineLimit(2...4)
                Button("Plan a route") {
                    Task { await appModel.routeIntent(routeText) }
                }
                .disabled(appModel.routePresentation.isPlanning)

                switch appModel.routePresentation {
                case .idle:
                    EmptyView()
                case .planning:
                    AdvancedWaitingLine("Planning the route…")
                case let .failed(message):
                    Text("The router did not produce a plan: \(message)")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                case let .plan(plan):
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            AdvancedStatusWord(status: plan.risk, text: plan.goalType)
                            AdvancedStatusWord(status: plan.risk)
                            if plan.requiresApproval {
                                AdvancedStatusWord(status: "pending", text: "Waiting on you")
                            }
                            Spacer()
                        }
                        ForEach(plan.nextActions, id: \.self) { action in
                            Text(action)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        AdvancedEyebrow(text: "Matched capabilities")
                        switch IntentRoutePresentation.plan(plan).capabilityMatchState {
                        case let .matches(capabilities):
                            ForEach(capabilities.prefix(5)) { capability in
                                CapabilityRow(capability: capability, compact: true)
                            }
                        case .noMatches:
                            Text("The router finished, but no installed capability matched this task.")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        case nil:
                            EmptyView()
                        }
                    }
                }
            }

            AdvancedSection(title: "Research lab") {
                TextField("Research objective", text: $researchObjective, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(ShellType.label)
                    .lineLimit(2...4)
                Button("Run the research lab") {
                    Task { await runResearchLab() }
                }
                .disabled(isRunningResearchLab)

                if let researchLabMessage {
                    researchLabMessageRow(researchLabMessage)
                }

                switch researchLabRunsState {
                case .loading:
                    AdvancedWaitingLine("Reading the research lab's receipts…")
                case .empty:
                    AdvancedEmptyState(
                        title: "No research runs",
                        detail: "A run started here leaves its receipt in this list."
                    )
                case .loaded(let runs):
                    researchLabRunRows(runs)
                case .unavailable(let detail, let retained):
                    Text("Research lab receipts are unavailable: \(detail)")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if !retained.isEmpty {
                        AdvancedEyebrow(text: "Last known receipts")
                        researchLabRunRows(retained)
                    }
                }
            }

            AdvancedSection(title: "Trace timeline") {
                let traceState = appModel.capabilityTraceTimeline
                if case .sourceAbsent = traceState {
                    AdvancedEmptyState(
                        title: "No trace history yet",
                        detail: "The durable trace feed has not been created."
                    )
                } else if case .empty = traceState {
                    AdvancedEmptyState(
                        title: "No traces yet",
                        detail: "Routing a task, saving a workflow, or installing a catalog item writes the first one."
                    )
                } else if case .unavailable(let detail) = traceState {
                    Text("Trace history is unavailable")
                        .font(ShellType.bodySemibold)
                        .foregroundStyle(NativeAgentShell.trouble)
                    Text(detail)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if case .partial(_, let rejectedRows) = traceState {
                        Text("\(rejectedRows) malformed \(rejectedRows == 1 ? "trace" : "traces") withheld from this timeline.")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.trouble)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(traceState.traces.prefix(14)) { trace in
                            CapabilityDetailRow(title: trace.title, detail: trace.kind, status: trace.status ?? "ok")
                        }
                    }
                }
            }

            SkillMemoryGraphPanel()
        }
    }

    @MainActor
    private func runResearchLab() async {
        isRunningResearchLab = true
        defer { isRunningResearchLab = false }
        let outcome = await appModel.runResearchLab(objective: researchObjective)
        researchLabMessage = CapabilitiesResearchLabPresentation.message(for: outcome)
        if case .recorded(let run) = outcome {
            researchLabRunsState = CapabilitiesResearchLabPresentation.list(
                rows: [run] + appModel.researchLabRuns.filter { $0.id != run.id }
            )
            await refreshResearchLabRuns()
        }
    }

    @MainActor
    private func refreshResearchLabRuns() async {
        researchLabRunsState = await appModel.refreshResearchLabRunsForCapabilities()
    }

    @ViewBuilder
    private func researchLabMessageRow(_ message: CapabilitiesResearchLabPresentation.Message) -> some View {
        Text(message.text)
            .font(ShellType.labelSemibold)
            .foregroundStyle(researchLabColor(message.tone))
            .fixedSize(horizontal: false, vertical: true)
        if let detail = message.detail {
            Text(detail)
                .font(ShellType.caption)
                .foregroundStyle(researchLabColor(message.tone))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func researchLabRunRows(_ runs: [ResearchLabRun]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(runs.prefix(4)) { run in
                let message = CapabilitiesResearchLabPresentation.message(for: run)
                CapabilityDetailRow(
                    title: run.objective,
                    detail: message.detail ?? message.text,
                    status: run.status
                )
            }
        }
    }

    private func researchLabColor(_ tone: CapabilitiesResearchLabPresentation.Tone) -> Color {
        switch tone {
        case .neutral, .progress:
            NativeAgentShell.secondary
        case .success:
            NativeAgentShell.calm
        case .warning, .failure:
            NativeAgentShell.trouble
        }
    }

    private var hardening: some View {
        VStack(alignment: .leading, spacing: 24) {
            AdvancedSection(title: "Autonomy kernel") {
                if let kernel = appModel.autonomyKernel {
                    HStack(spacing: 12) {
                        AdvancedStatusWord(status: kernel.status)
                        if let mode = kernel.mode {
                            AdvancedMeta(AdvancedStatusWords.label(mode))
                        }
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(kernel.guardrails) { guardrail in
                            CapabilityDetailRow(title: guardrail.title, detail: guardrail.id, status: guardrail.status)
                        }
                    }
                } else {
                    Text("Kernel summary has not loaded yet.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }

            CapabilitiesApprovalInboxPanel()

            AdvancedSection(title: "Native macOS power") {
                // 2026-07-21 audit fix (dead-surface honesty): the
                // `nativePower.surfaces` list and the "App Intents" tile were
                // removed — getNativePower() is a DAEMON-KILL P1 stub that
                // returns surfaces: [] forever, and /v1/native/intents was
                // retired with no SwiftNative successor (the dead intent-registry
                // chain was fully deleted 2026-08-14), so both rendered permanent
                // empty/"Loading" furniture. The remaining tiles and action
                // rows below are fed by live readers.
                let refresh = appModel.panelRefreshStatus[.capabilities]
                let failedEndpoints = Set((refresh?.failedEndpoints ?? []).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })
                let notificationTile = NativeMacPowerPanelPresentation.tile(
                    value: appModel.notificationStatus?.pendingApprovals.map(String.init),
                    detail: "pending approvals",
                    runtimeStatus: appModel.notificationStatus?.status,
                    hasRefreshAttempt: refresh != nil,
                    readFailed: failedEndpoints.contains("notification status")
                )
                let browserTile = NativeMacPowerPanelPresentation.tile(
                    value: appModel.browserRuntimeStatus?.receiptCount.map(String.init),
                    detail: appModel.browserRuntimeStatus?.domainPolicy,
                    runtimeStatus: appModel.browserRuntimeStatus?.status,
                    hasRefreshAttempt: refresh != nil,
                    readFailed: failedEndpoints.contains("browser status")
                )
                let vectorTile = NativeMacPowerPanelPresentation.tile(
                    value: appModel.memoryVectorStatus?.nodeCount.map(String.init),
                    detail: appModel.memoryVectorStatus?.providerModel,
                    runtimeStatus: appModel.memoryVectorStatus?.status,
                    hasRefreshAttempt: refresh != nil,
                    readFailed: failedEndpoints.contains("memory vector status")
                )
                let nativeActionsState = NativeMacPowerPanelPresentation.readState(
                    itemCount: appModel.nativeActions.count,
                    hasRefreshAttempt: refresh != nil,
                    readFailed: failedEndpoints.contains("native actions")
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                    AdvancedStat(
                        title: "Notifications",
                        value: notificationTile.value,
                        detail: notificationTile.detail,
                        status: notificationTile.status
                    )
                    AdvancedStat(
                        title: "Browser",
                        value: browserTile.value,
                        detail: browserTile.detail,
                        status: browserTile.status
                    )
                    AdvancedStat(
                        title: "Vector memory",
                        value: vectorTile.value,
                        detail: vectorTile.detail,
                        status: vectorTile.status
                    )
                }

                if nativeActionsState == .unavailable {
                    Text("The native action registry is unavailable. Refresh Capabilities before relying on what is listed here.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                } else if nativeActionsState == .loading {
                    Text("Native actions have not loaded yet.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                } else if appModel.nativeActions.isEmpty {
                    Text("No native actions are registered.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                } else {
                    if nativeActionsState == .stale {
                        Text("Showing the last loaded native action registry.")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.trouble)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(appModel.nativeActions.prefix(6)) { action in
                            let actionPresentation = NativeMacPowerPanelPresentation.action(
                                requiresApproval: action.requiresApproval,
                                dryRunAvailable: action.dryRunAvailable,
                                fullMacYoloAdmitted: nativeActionYoloAdmission[action.id] == true
                            )
                            HStack(alignment: .top, spacing: 8) {
                                CapabilityDetailRow(
                                    title: action.name,
                                    detail: AdvancedStatusWords.label(action.kind ?? action.id),
                                    status: action.risk ?? "ok"
                                )
                                Spacer()
                                Button("Dry run") {
                                    Task { await appModel.runNativeAction(action, dryRun: true) }
                                }
                                .controlSize(.small)
                                .disabled(!actionPresentation.canDryRun)
                                Button("Run") {
                                    Task { await appModel.runNativeAction(action, dryRun: false) }
                                }
                                .controlSize(.small)
                                .disabled(!actionPresentation.canRun)
                            }
                            if let blockedDetail = actionPresentation.blockedDetail {
                                Text(blockedDetail)
                                    .font(ShellType.caption)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                // B2.3 residue restoration (gpt-5.5 review BLOCKING): the
                // retired Command Center's "Recent Receipts" rollup listed the
                // last FOUR native-action receipts; this row showed only the
                // latest, which silently narrowed visibility when the roll-up
                // died. Canonical home is here, next to the actions themselves.
                if !appModel.nativeActionReceipts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(appModel.nativeActionReceipts.prefix(4)) { receipt in
                            CapabilityDetailRow(
                                title: AdvancedStatusWords.label(receipt.name ?? receipt.actionId),
                                detail: receipt.createdAt ?? AdvancedStatusWords.label(receipt.actionId),
                                status: receipt.status
                            )
                        }
                    }
                }

                if let connectorRegistry = appModel.connectorActionRegistry {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            AdvancedEyebrow(text: "\(connectorRegistry.actions.count) connector actions")
                            Spacer()
                            if let latest = appModel.latestConnectorActionReceipt ?? connectorRegistry.latestReceipt {
                                AdvancedStatusWord(status: latest.status)
                            }
                        }
                        ForEach(connectorRegistry.actions.prefix(4)) { action in
                            HStack(spacing: 8) {
                                CapabilityDetailRow(
                                    title: action.name,
                                    detail: "\(AdvancedStatusWords.label(action.connectorId ?? "connector")) · \(AdvancedStatusWords.label(action.authState ?? "unknown"))",
                                    status: action.connectorStatus ?? (action.enabled == true ? "ok" : "warn")
                                )
                                Spacer()
                                Button("Dry run") {
                                    Task { await appModel.runConnectorAction(action) }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                CapabilitiesRunGauntletAndBrowserActions()
            }

            CapabilityProductionHardeningPanel()
        }
    }

    @MainActor
    private func refreshNativeActionYoloAdmission() async {
        let actionIDs = appModel.nativeActions
            .filter { $0.requiresApproval != false }
            .map(\.id)
        var checked: [String: Bool] = [:]
        for actionID in actionIDs {
            checked[actionID] = await appModel.fullMacYoloAuthorityAdmitted(
                tool: actionID,
                surface: "native_actions"
            )
        }
        nativeActionYoloAdmission = checked
    }
}

struct CapabilitiesRunGauntletAndBrowserActions: View {
    @Environment(AppModel.self) private var appModel
    @State private var isRunningBrowserDryRun = false
    @State private var isRunningGauntlet = false

    private var latestGauntlet: ImprovementGauntletRun? {
        appModel.latestGauntletRun ?? appModel.improvementGauntletStatus?.latestRun
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("Browser dry run") {
                    Task {
                        isRunningBrowserDryRun = true
                        defer { isRunningBrowserDryRun = false }
                        await appModel.runBrowserDryRun()
                    }
                }
                .controlSize(.small)
                .disabled(isRunningBrowserDryRun)
                .accessibilityIdentifier("capabilities.browser-dry-run")

                Button("Cancel the browser run") {
                    Task { await appModel.cancelBrowserRun() }
                }
                .controlSize(.small)
                .accessibilityIdentifier("capabilities.browser-cancel")

                Button("Run the gauntlet") {
                    Task {
                        isRunningGauntlet = true
                        defer { isRunningGauntlet = false }
                        await appModel.runImprovementGauntlet()
                    }
                }
                .controlSize(.small)
                .disabled(isRunningGauntlet)
                .accessibilityIdentifier("capabilities.run-gauntlet")

                Spacer()
                if let latestGauntlet {
                    AdvancedStatusWord(status: latestGauntlet.status)
                }
            }

            if let run = appModel.latestBrowserRun {
                let presentation = CapabilitiesRunActionPresentation.browserOutcome(for: run)
                CapabilityDetailRow(
                    title: presentation.title,
                    detail: presentation.detail,
                    status: presentation.status
                )
                .accessibilityIdentifier("capabilities.browser-dry-run.outcome")
            }

            if let gauntlet = latestGauntlet {
                let presentation = CapabilitiesRunActionPresentation.gauntletOutcome(for: gauntlet)
                CapabilityDetailRow(
                    title: presentation.title,
                    detail: presentation.detail,
                    status: presentation.status
                )
                .accessibilityIdentifier("capabilities.run-gauntlet.outcome")

                if !presentation.failedCheckTitles.isEmpty {
                    Text("Failed: \(presentation.failedCheckTitles.joined(separator: ", "))")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capabilities.run-gauntlet.failures")
                }
            }

            if appModel.statusText.hasPrefix("Browser dry run:")
                || appModel.statusText.hasPrefix("Browser run failed:")
                || appModel.statusText.hasPrefix("Gauntlet:")
                || appModel.statusText.hasPrefix("Gauntlet failed:") {
                Text(appModel.statusText)
                    .font(ShellType.caption)
                    .foregroundStyle(appModel.statusText.contains("failed:") ? NativeAgentShell.trouble : NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capabilities.run-actions.status")
            }
        }
    }
}

/// The concrete outcome language shared by the capabilities actions and their
/// direct behavioral coverage. The action owners supply receipts; this model
/// makes their visible summary a pure, independently auditable projection.
struct CapabilitiesRunActionPresentation: Equatable {
    struct Outcome: Equatable {
        let title: String
        let detail: String
        let status: String
        let failedCheckTitles: [String]
    }

    static func browserOutcome(for run: BrowserRun) -> Outcome {
        Outcome(
            title: "Latest Browser Run",
            detail: "\(run.dryRun == true ? "Dry run" : "Not a dry run") · \(run.url ?? "no URL recorded")",
            status: run.status,
            failedCheckTitles: []
        )
    }

    static func gauntletOutcome(for run: ImprovementGauntletRun) -> Outcome {
        let checks = run.checks ?? []
        let passed = checks.filter(\.passed).count
        return Outcome(
            title: "Latest Gauntlet",
            detail: checks.isEmpty ? "No checks recorded" : "\(passed)/\(checks.count) checks passed",
            status: run.status,
            failedCheckTitles: checks.filter { !$0.passed }.map(\.title)
        )
    }
}

struct CapabilitiesApprovalInboxPanel: View {
    @Environment(AppModel.self) private var appModel

    private var readState: CapabilitiesApprovalInboxPresentation.ReadState {
        CapabilitiesApprovalInboxPresentation.readState(
            approvalCount: appModel.approvals.count,
            refresh: appModel.panelRefreshStatus[.capabilities]
        )
    }

    var body: some View {
        AdvancedSection(title: "Approval inbox") {
            switch readState {
            case .loading:
                AdvancedWaitingLine("Reading the approval requests…")
            case .empty:
                AdvancedEmptyState(
                    title: "No approval requests",
                    detail: "Anything the agent needs a yes for waits here."
                )
            case .unavailable:
                Text("The approval inbox is unavailable. Refresh Capabilities before relying on an empty queue.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capabilities.approvals.unavailable")
            case .stale:
                Text("Showing the last loaded approval requests; the latest refresh failed.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                approvalRows
            case .available:
                approvalRows
            }

            if let outcome = appModel.capabilitiesApprovalInboxOutcome {
                Text(outcome.visibleMessage)
                    .font(ShellType.label)
                    .foregroundStyle(outcomeColor(outcome))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("capabilities.approvals.outcome")
            }
        }
    }

    @ViewBuilder
    private var approvalRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(appModel.approvals.prefix(8)) { approval in
                HStack(alignment: .top, spacing: 8) {
                    CapabilityDetailRow(
                        title: approval.title,
                        detail: approval.reason ?? approval.action,
                        status: approval.status.lowercased() == "pending" ? approval.risk : approval.status
                    )
                    Spacer()
                    if approval.status.lowercased() == "pending" {
                        Button("Approve") {
                            Task { await appModel.resolveCapabilitiesApprovalInbox(approval, decision: "approved") }
                        }
                        .controlSize(.small)
                        .disabled(appModel.isResolvingApproval(id: approval.id))
                        .accessibilityIdentifier("capabilities.approvals.approve.\(approval.id)")
                        .accessibilityHint(appModel.isResolvingApproval(id: approval.id)
                            ? "This approval is already being decided."
                            : "Approve this request once.")
                        Button("Deny") {
                            Task { await appModel.resolveCapabilitiesApprovalInbox(approval, decision: "denied") }
                        }
                        .controlSize(.small)
                        .disabled(appModel.isResolvingApproval(id: approval.id))
                        .accessibilityIdentifier("capabilities.approvals.deny.\(approval.id)")
                        .accessibilityHint(appModel.isResolvingApproval(id: approval.id)
                            ? "This approval is already being decided."
                            : "Deny this request once.")
                    }
                }
            }
        }
    }

    private func outcomeColor(_ outcome: CapabilitiesApprovalInboxResolution) -> Color {
        switch CapabilitiesApprovalInboxPresentation.outcomeTone(outcome) {
        case "success": NativeAgentShell.calm
        default: NativeAgentShell.trouble
        }
    }
}

struct CapabilityRow: View {
    var capability: CapabilityRecord
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text((capability.name ?? capability.id).withoutStaleNextGenPhaseCopy)
                    .font(compact ? ShellType.labelSemibold : ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer()
                AdvancedStatusWord(status: capability.status ?? "ok", text: capability.status ?? "ready")
            }
            HStack(spacing: 8) {
                AdvancedMeta(AdvancedStatusWords.label(capability.kind))
                if let risk = capability.riskClass, !risk.isEmpty {
                    AdvancedMeta(AdvancedStatusWords.label(risk))
                }
                if let useCount = capability.useCount, useCount > 0 {
                    AdvancedMeta("\(useCount) uses")
                }
            }
            if !compact, let description = capability.description, !description.isEmpty {
                Text(description.withoutStaleNextGenPhaseCopy)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct NextGenPhaseRow: View {
    var phase: NextGenPhase
    var isRunning: Bool
    var runProbe: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CapabilityDetailRow(
                title: phase.displayName,
                detail: phase.displayDetail,
                status: phase.displayStatus
            )
            Spacer()
            // L3#6: a phase's primaryDryRunActionId comes from the catalog data
            // file and may name an id the read-only executor has no case for.
            // Render the probe only when an executor backs it.
            if let actionId = phase.primaryDryRunActionId, NativeClient.isNextGenActionBacked(actionId) {
                Button("Probe") {
                    runProbe(actionId)
                }
                .controlSize(.small)
                .disabled(isRunning)
            } else {
                AdvancedStatusWord(status: "warn", text: "No probe")
            }
        }
    }

}

struct SkillMemoryGraphPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var graphQuery = "memory workflow capability"

    var body: some View {
        AdvancedSection(title: "Skill memory graph") {
            if let graph = appModel.agentGraph {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    AdvancedStat(title: "Nodes", value: "\(graph.summary.nodes)", detail: "memories, runs, Desk tasks, capabilities")
                    AdvancedStat(title: "Edges", value: "\(graph.summary.edges)", detail: "produced and used links")
                    AdvancedStat(title: "Capabilities", value: "\(graph.summary.capabilities ?? 0)", detail: "indexed objects")
                }

                if let error = appModel.graphLoadError {
                    Text("The graph refresh failed; what is shown may be stale: \(error)")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if let status = appModel.graphStatus {
                        AdvancedStatusWord(status: status.status)
                        AdvancedMeta("\(status.entityCount ?? appModel.graphEntities.count) entities")
                    }
                    TextField("Search the graph", text: $graphQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(ShellType.label)
                    Button("Search") {
                        Task { await appModel.searchGraph(graphQuery) }
                    }
                    .controlSize(.small)
                    Button("Refresh") {
                        Task { await appModel.refreshGraph() }
                    }
                    .controlSize(.small)
                }

                if graph.nodes.isEmpty {
                    Text("The checked graph is empty. New retained memories and linked capability activity appear here once indexed.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !appModel.graphSearchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(appModel.graphSearchResults.prefix(8)) { result in
                            CapabilityDetailRow(
                                title: result.node.label ?? AdvancedStatusWords.label(result.id),
                                detail: result.explanation ?? "Score \(String(format: "%.2f", result.score))",
                                status: result.node.status ?? "ok"
                            )
                        }
                    }
                }

                if !appModel.graphEntities.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(appModel.graphEntities.prefix(5)) { entity in
                            CapabilityDetailRow(
                                title: entity.name,
                                detail: "\(entity.mentions ?? 0) mentions · confidence \(String(format: "%.2f", entity.confidence ?? 0))",
                                status: entity.kind ?? "ok"
                            )
                        }
                    }
                }
            } else if let error = appModel.graphLoadError {
                AdvancedEmptyState(
                    title: "Skill memory graph unavailable",
                    detail: "The graph could not be read: \(error)",
                    actionTitle: "Refresh the graph",
                    action: { Task { await appModel.refreshGraph() } }
                )
            } else {
                AdvancedEmptyState(
                    title: "Skill memory graph not loaded",
                    detail: "Refresh to read the current graph. This is not an empty-graph result.",
                    actionTitle: "Refresh the graph",
                    action: { Task { await appModel.refreshGraph() } }
                )
            }
        }
    }
}

// The workflow RUN engine was retired 2026-09-01 (User authorized). This panel
// keeps the registry half: it lists the saved workflow definitions and can
// create a new one. There is no Run / Resume / Cancel / Rollback any more —
// the live way to have work done is workshop/executions.
struct WorkflowBuilderPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var workflowName = ""
    @State private var creatingWorkflow = false
    @State private var creationError: String?

    var body: some View {
        AdvancedSection(title: "Workflow builder") {
            TextField("New workflow name", text: $workflowName)
                .textFieldStyle(.roundedBorder)
                .font(ShellType.label)
                .disabled(creatingWorkflow)

            HStack(spacing: 8) {
                Button("Create a workflow") {
                    Task { await createWorkflow() }
                }
                .controlSize(.small)
                .disabled(creatingWorkflow || workflowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if creatingWorkflow {
                    AdvancedWaitingLine("Saving and verifying…")
                }
                Spacer()
            }

            Text("Saves a reviewable workflow definition to the registry. The workflow run engine was retired on 2026-09-01 — nothing here executes; hand work to a Workshop execution instead.")
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let creationError {
                Text(creationError)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appModel.workflows.isEmpty {
                AdvancedEmptyState(
                    title: "No workflows",
                    detail: "A workflow saved here shows up in this list. Refresh Capabilities to confirm the current registry."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(appModel.workflows) { workflow in
                        WorkflowRow(workflow: workflow)
                    }
                }
            }
        }
    }

    @MainActor
    private func createWorkflow() async {
        creatingWorkflow = true
        defer { creatingWorkflow = false }
        do {
            _ = try await appModel.createWorkflow(named: workflowName)
            workflowName = ""
            creationError = nil
        } catch {
            creationError = "Could not create workflow: \(error.localizedDescription)"
        }
    }
}

struct WorkflowRow: View {
    var workflow: WorkflowRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(workflow.name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer()
                AdvancedStatusWord(status: workflow.status ?? "ok", text: workflow.status ?? "active")
            }
            if let description = workflow.description, !description.isEmpty {
                Text(description)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                AdvancedMeta("\(workflow.steps.count) steps")
                if let trigger = workflow.trigger, !trigger.isEmpty {
                    AdvancedMeta(AdvancedStatusWords.label(trigger))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct CatalogRow: View {
    var item: CapabilityCatalogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(item.name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer()
                AdvancedStatusWord(
                    status: item.installed == true ? "ok" : "warn",
                    text: item.status ?? "available"
                )
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let kind = item.kind {
                    AdvancedMeta(AdvancedStatusWords.label(kind))
                }
                if let risk = item.riskClass {
                    AdvancedMeta(AdvancedStatusWords.label(risk))
                }
                Spacer()
                AdvancedMeta(item.installed == true ? "Installed by a verified pack" : "Catalog metadata")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct MCPServerRow: View {
    var server: MCPServerRecord
    var load: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CapabilityDetailRow(
                title: server.name,
                detail: "\(server.transport ?? "stdio") · \(server.endpoint?.isEmpty == false ? server.endpoint! : server.command ?? "not configured") · \(server.toolCount ?? 0) tools",
                status: server.healthStatus ?? server.status ?? "warn"
            )
            Spacer()
            Button("Load", action: load)
                .controlSize(.small)
        }
    }
}

struct CapabilityDetailRow: View {
    var title: String
    var detail: String
    var status: String
    /// 2026-09-03 kit pass: the row carries words, not a status-tinted glyph.
    /// The parameter stays because ToolsView (outside this pass) still passes
    /// one; nothing draws it.
    var systemImage: String = ""
    // 2026-06-07 ui-taste-sweep #83: when caller has the raw key/value
    // pairs (e.g. NextGenReceipt), pass them here. Row gets a fold labeled
    // "Details" that reveals each pair on its own line. Nil = legacy callers
    // (no fold rendered, identical to old behavior).
    var rawPairs: [(String, String)]? = nil

    @State private var showsPairs = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.withoutStaleNextGenPhaseCopy)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer()
                AdvancedStatusWord(status: status)
            }
            let trimmedDetail = detail.withoutStaleNextGenPhaseCopy
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDetail.isEmpty {
                Text(trimmedDetail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(3)
            }
            if let pairs = rawPairs, !pairs.isEmpty {
                Button {
                    withAnimation(
                        NativeAgentMotion.respecting(ShellFoldMotion.open, reduceMotion: reduceMotion)
                    ) {
                        showsPairs.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsPairs ? "chevron.down" : "chevron.right")
                        Text("Details")
                    }
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsPairs ? "Expanded" : "Collapsed")
                .padding(.top, 2)

                if showsPairs {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(pair.0)
                                    .font(AdvancedType.codeCaption)
                                    .foregroundStyle(NativeAgentShell.tertiary)
                                Text(pair.1.isEmpty ? "—" : pair.1)
                                    .font(AdvancedType.codeCaption)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .transition(ShellFoldMotion.transition(reduceMotion: reduceMotion))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
