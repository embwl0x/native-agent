import EngineRuntime
import ApprovalTransactions
import AppToolRuntime
import ChatTurnRuntime
import ChatTurnContracts
import Foundation
import NativeAgentCore
import NativeAgentShared
import SwiftUI
import TrustCenter

// Blueprint: | `InlineInteractionChatBinding.swift` | `InlineInteractionChatBinding`: card controls and verify-on-return settlement |

@MainActor
@Observable
final class InlineInteractionChatBinding {

    var connectorSheet: ConnectorSheetRequest?

    /// Simple view uses a floating panel because it has no pages; Advanced routes to the page.
    var panelPage: SidebarItem?

    private var sessionID: String = ""
    private var engine = NativeAgentEngine.live
    private var dataRoot: URL { engine.dataRoot }

    /// Key page-backed interactions by their originating conversation so returning from setup verifies the owner once without settling another transcript.
    private var awaitingReturn: [String: (sessionID: String, revision: Int)] = [:]

    struct ConnectorSheetRequest: Identifiable, Equatable {
        let id: String
        let provider: String
        /// A sheet can outlive a conversation switch; settle the transcript that raised it.
        let sessionID: String
        let revision: Int
    }

    // MARK: - Actions

    func handle(
        card: InlineCardModel,
        action: InlineCardAction,
        appModel: AppModel
    ) {
        let sessionID = card.sessionID
        self.sessionID = sessionID
        engine = appModel.engine
        guard !sessionID.isEmpty else { return }
        switch action {
        case .secondary:
            Task { await self.decline(card.id, sessionID: sessionID, appModel: appModel) }
        case .primary(let value, let choice, let values):
            Task {
                await self.begin(
                    card.id, sessionID: sessionID,
                    value: value, choice: choice, values: values, appModel: appModel
                )
            }
        case .fullSetup:
            Task {
                await self.begin(
                    card.id, sessionID: sessionID,
                    value: nil, choice: nil, fullSetup: true, appModel: appModel
                )
            }
        case .retry:
            Task {
                await self.begin(
                    card.id, sessionID: sessionID,
                    value: nil, choice: nil, appModel: appModel
                )
            }
        case .stop:
            Task {
                await InlineInteractionResolver.invalidateContinuation(
                    id: card.id, sessionID: sessionID, dataRoot: self.dataRoot
                )
                await self.refreshCurrent()
            }
        }
    }

    func verifyOnReturn() async {
        guard !awaitingReturn.isEmpty, !sessionID.isEmpty else { return }
        let pending = awaitingReturn
        awaitingReturn.removeAll()
        await InlineInteractionResolver.verifyOnReturn(pending, dataRoot: dataRoot) {
            await self.refreshCurrent()
        }
        await refreshCurrent()
    }

    // MARK: - Begin, open, complete

    private func decline(_ id: String, sessionID: String, appModel: AppModel) async {
        do {
            _ = try await InlineInteractionResolver.decline(
                id: id, sessionID: sessionID, turn: nil, dataRoot: dataRoot
            )
        } catch {
            appModel.setFailureStatus(error, action: "decline that request")
        }
        await refreshCurrent()
    }

    private func begin(
        _ id: String,
        sessionID: String,
        value: String?,
        choice: String?,
        values: [String: String] = [:],
        fullSetup: Bool = false,
        appModel: AppModel
    ) async {
        // This local control tap starts its own act; it is not the card's waiting turn.
        let turn = TurnRequest(message: "", sessionID: sessionID, surface: "chat",
            envelope: TurnEnvelope.personOnMac("mac_ui:interaction." + id)).turn()
        let current: InlineInteraction
        let descriptor: InlineInteractionDescriptor
        do {
            guard let prepared = try await InlineInteractionResolver.beginControl(
                id, sessionID: sessionID, dataRoot: dataRoot
            ) else { return }
            current = prepared.interaction
            descriptor = prepared.descriptor
        } catch {
            appModel.setFailureStatus(error, action: "begin that request")
            await refreshCurrent()
            return
        }
        await refreshCurrent()
        await open(
            sessionID: sessionID,
            interaction: current,
            descriptor: descriptor,
            value: value,
            choice: choice,
            values: values,
            fullSetup: fullSetup,
            turn: turn,
            appModel: appModel
        )
    }

    private func open(
        sessionID: String,
        interaction: InlineInteraction,
        descriptor: InlineInteractionDescriptor,
        value: String?,
        choice: String?,
        values: [String: String],
        fullSetup: Bool,
        turn: Turn,
        appModel: AppModel
    ) async {
        await InlineInteractionResolver.runControl(
            interaction, descriptor: descriptor, sessionID: sessionID,
            value: value, choice: choice, values: values, fullSetup: fullSetup, turn: turn,
            controls: AppInlineInteractionControlPort(appModel: appModel), dataRoot: dataRoot,
            present: { control in
                switch control {
                case .internetAccounts:
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") else {
                        appModel.systemToasts.push(error: "Could not form the Internet Accounts Settings URL.")
                        return
                    }
                    if !NSWorkspace.shared.open(url) {
                        appModel.systemToasts.push(error: "Could not open Internet Accounts in System Settings.")
                    }
                case .pairDevice:
                    self.openPage(.connectors, for: interaction.id, sessionID: sessionID, revision: interaction.revision)
                    UserDefaults.standard.set("iphone", forKey: ShellRailTab.storageKey(.connectors))
                case .connectorManualToken where descriptor.target == "telegram":
                    self.openPage(.telegram, for: interaction.id, sessionID: sessionID, revision: interaction.revision)
                case .connectorManualToken:
                    self.connectorSheet = ConnectorSheetRequest(
                        id: interaction.id, provider: descriptor.target, sessionID: sessionID, revision: interaction.revision)
                case .trustPostureRequired:
                    self.openPage(.trust, for: interaction.id, sessionID: sessionID, revision: interaction.revision)
                case .providerGroupModel:
                    self.openPage(.providers, for: interaction.id, sessionID: sessionID, revision: interaction.revision)
                default: break
                }
            },
            watch: { self.watchUntilGranted(interaction.id, sessionID: sessionID) },
            refresh: { await self.refreshCurrent() }
        )
    }

    func openPage(_ item: SidebarItem, for id: String? = nil, sessionID: String = "", revision: Int? = nil) {
        if let id, let revision { awaitingReturn[id] = (sessionID, revision) }
        if SimpleViewMode.isShowing {
            panelPage = item
        } else {
            _ = ApplicationLifetime.shared.request(.sidebar(item))
        }
    }

    func panelClosed() async {
        panelPage = nil
        await connectorSheetClosed()
        await verifyOnReturn()
    }

    func settlePanelIfDone() async {
        var waiting = awaitingReturn
        if let sheet = connectorSheet { waiting[sheet.id] = (sheet.sessionID, sheet.revision) }
        guard !waiting.isEmpty else { return }
        guard await InlineInteractionResolver.settleVerifiedControls(waiting, dataRoot: dataRoot, didSettle: { id in
            self.awaitingReturn[id] = nil
        }) else { return }
        panelPage = nil
        connectorSheet = nil
        await refreshCurrent()
    }

    /// A closed setup sheet is not evidence of a connection; ask Connectors before settling, and reserve failure wording for an actual attempt.
    func connectorSheetClosed() async {
        guard let request = connectorSheet else { return }
        connectorSheet = nil
        await settleOrReopen(request.id, sessionID: request.sessionID, revision: request.revision)
    }

    private func settleOrReopen(_ id: String, sessionID: String, revision: Int) async {
        await InlineInteractionResolver.settleOrReopen(id, sessionID: sessionID, expectedRevision: revision, dataRoot: dataRoot)
        await refreshCurrent()
    }

    // MARK: - Grants made in System Settings

    @ObservationIgnored private let grantWatch = InlineInteractionResolver.GrantWatch.shared

    private func watchUntilGranted(_ id: String, sessionID: String) {
        grantWatch.watchUntilGranted(id, sessionID: sessionID, dataRoot: dataRoot) { [weak self] in
            await self?.refreshCurrent()
        }
    }

    /// Refresh the visible conversation after actions; settlement still belongs to the originating session.
    private func refreshCurrent() async {
        await engine.transcripts.refreshCards(in: sessionID)
    }
}
