import EngineRuntime
import Foundation
import SystemOps
import ToolRegistry
import SwiftUI
import TrustCenter
import ApprovalInbox
// Blueprint: | `CapabilitiesView+MacActions.swift` | `CapabilitiesView`: native Mac actions, checked availability and browser/improvement run receipts |

enum NativeMacPowerPanelPresentation {
    struct Tile: Equatable {
        let value: String
        let detail: String
        let status: String
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
                status: "warn"
            )
        }
        guard hasContent else {
            return Tile(
                value: "—",
                detail: hasRefreshAttempt ? "Status unavailable." : "Checking status…",
                status: hasRefreshAttempt ? "warn" : "info"
            )
        }
        return Tile(
            value: value ?? "—",
            detail: nonEmpty(detail) ?? "No detail reported.",
            status: runtimeStatus ?? "unknown"
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension CapabilitiesView {
    var nativeMacPower: some View {
            AdvancedSection(title: "Mac actions") {
                let failedEndpoints = Set(((appModel.engine.tools.nativePowerRefresh?.failedEndpoints ?? [])
                    + (appModel.engine.memory.statusRefresh?.failedEndpoints ?? [])).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })
                let notificationTile = NativeMacPowerPanelPresentation.tile(
                    value: appModel.engine.tools.notificationStatus?.pendingApprovals.map(String.init),
                    detail: "pending approvals",
                    runtimeStatus: appModel.engine.tools.notificationStatus?.status,
                    hasRefreshAttempt: appModel.engine.tools.nativePowerRefresh != nil,
                    readFailed: failedEndpoints.contains("notification status")
                )
                let browserTile = NativeMacPowerPanelPresentation.tile(
                    value: appModel.engine.tools.browserStatus?.receiptCount.map(String.init),
                    detail: "recent receipts",
                    runtimeStatus: appModel.engine.tools.browserStatus?.status,
                    hasRefreshAttempt: appModel.engine.tools.nativePowerRefresh != nil,
                    readFailed: failedEndpoints.contains("browser status")
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
                }

                if appModel.engine.tools.nativeActions.isEmpty {
                    Text("No Mac actions are available.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                } else {
                    let fullMacYoloAdmitted = appModel.engine.trust.nativeActionYoloAdmitted
                    ForEach(appModel.engine.tools.nativeActions.prefix(showAllNativeActions ? appModel.engine.tools.nativeActions.count : 6)) { action in
                            let actionPresentation = NativeMacPowerPanelPresentation.action(
                                requiresApproval: action.requiresApproval,
                                dryRunAvailable: action.dryRunAvailable,
                                fullMacYoloAdmitted: fullMacYoloAdmitted
                            )
                            VStack(alignment: .leading, spacing: 4) {
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

                if appModel.engine.tools.nativeActions.count > 6 {
                    HStack {
                        Button(showAllNativeActions ? "Show fewer actions" : "Show all actions") {
                            showAllNativeActions.toggle()
                        }
                        .accessibilityIdentifier("capabilities.show-all-native-actions")
                        Text("Showing \(showAllNativeActions ? appModel.engine.tools.nativeActions.count : 6) of \(appModel.engine.tools.nativeActions.count) loaded actions")
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                }

                // Recent receipts stay beside the actions that produced them.
                ForEach(appModel.engine.tools.nativeActionReceipts.prefix(4)) { receipt in
                    CapabilityDetailRow(
                        title: AdvancedStatusWords.label(receipt.name ?? receipt.actionId),
                        detail: receipt.createdAt ?? AdvancedStatusWords.label(receipt.actionId),
                        status: receipt.status
                    )
                }

                if let connectorRegistry = appModel.engine.connectors.actions {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            AliveEyebrow("\(connectorRegistry.actions.count) connector actions")
                            Spacer()
                            if let latest = connectorRegistry.latestReceipt {
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

    }
}

struct CapabilitiesRunGauntletAndBrowserActions: View {
    @Environment(AppModel.self) private var appModel
    @State private var isRunningBrowserDryRun = false
    @State private var isRunningGauntlet = false

    var body: some View {
        let latestGauntlet = appModel.engine.doctor.latestImprovementGauntletRun
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

                Button("Run the improvement checks") {
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

            if let run = appModel.engine.tools.browserStatus?.latestReceipt {
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
                    Text("Checks not passed: \(presentation.failedCheckTitles.joined(separator: ", "))")
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

/// Visible action summaries derive from the owner’s recorded receipts.
struct CapabilitiesRunActionPresentation: Equatable {
    struct Outcome: Equatable {
        let title: String
        let detail: String
        let status: String
        let failedCheckTitles: [String]
    }

    static func browserOutcome(for run: BrowserRun) -> Outcome {
        Outcome(
            title: "Latest browser run",
            detail: "\(run.dryRun == true ? "Dry run" : "Not a dry run") · \(run.url ?? "no URL recorded")",
            status: run.status,
            failedCheckTitles: []
        )
    }

    static func gauntletOutcome(for run: ImprovementGauntletRun) -> Outcome {
        let checks = run.checks ?? []
        let passed = checks.filter(\.passed).count
        return Outcome(
            title: "Latest improvement run",
            detail: checks.isEmpty ? "No checks recorded" : "\(passed)/\(checks.count) checks passed",
            status: run.status,
            failedCheckTitles: checks.filter { !$0.passed }.map(\.title)
        )
    }
}
