import EngineRuntime
import ApprovalTransactions
import AppToolRuntime
import ChatOrchestration
import Foundation
import NativeAgentShared
import PersistenceCore
import SwiftUI
import TrustCenter

/// What the transcript injects into `\.inlineCardSource` and
/// `\.inlineCardAction`: the persisted interactions of the open conversation,
/// keyed by the tool row they were raised on, and the one handler that turns a
/// tap into "open the control that already exists, then ask its owner".
///
/// Everything durable lives in the transcript and is read back through
/// `InlineInteractionResolver`. This holds only what a view needs between
/// reads: the projected cards, and whichever sheet is currently open. A
/// relaunch rebuilds it from disk, with each card's state intact, because it
/// never was the authority in the first place.
@MainActor
@Observable
final class InlineInteractionChatBinding {

    /// Cards by transcript row id. Rebuilt whole on every refresh; a card whose
    /// revision moved is replaced in place because its `id` — the request, not
    /// the message — is stable across re-observations.
    private(set) var cardsByRow: [String: [InlineCardModel]] = [:]

    /// The connector setup sheet, when a card opened one. `ConnectorWizardView`
    /// is the control Connectors already ships; the card presents that, it does
    /// not reimplement a token field.
    var connectorSheet: ConnectorSheetRequest?

    /// Simple view has no pages: a page a card opens (Telegram, Trust,
    /// Providers) shows here instead, in the floating glass panel over the
    /// chat (SimpleSetupPanel.swift). Always nil in Advanced.
    var panelPage: SidebarItem?

    private var sessionID: String = ""
    private var dataRoot: URL { PersistenceCore.defaultDataRoot() }

    /// Interactions the person left through a control (Trust, Providers) and
    /// has not come back from. On return to chat each is re-verified with its
    /// owner exactly once — that return IS the "the control closed" signal for
    /// the controls that are pages rather than sheets.
    /// Keyed by interaction id, valued by the conversation that raised it:
    /// the person can switch conversations while they are away in Trust or
    /// Providers, and the answer still belongs to the transcript that asked.
    private var awaitingReturn: [String: String] = [:]

    /// The pending debounced read started by `refreshSoon`.
    @ObservationIgnored private var coalescedRefresh: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    struct ConnectorSheetRequest: Identifiable, Equatable {
        let id: String
        let provider: String
        /// The conversation the card was tapped in. A sheet outlives a
        /// conversation switch, and what it settles belongs to the transcript
        /// that asked, never to whichever one is open when it closes.
        let sessionID: String
    }

    // MARK: - Source

    func cards(forRow rowID: String) -> [InlineCardModel] {
        cardsByRow[rowID] ?? []
    }

    /// One transcript read, projected. Called on session change and on every
    /// `.chatTurnCompleted` — the same signal the resolver posts after it
    /// persists, which is what makes a settled card become its receipt without
    /// the view polling anything.
    /// `reclaim` is false for the offscreen copy a quiet read mounts. The
    /// projection below only reads and assigns; the reclaim pass WRITES — it
    /// persists released claims and starts the turns they were holding — and a
    /// read of the page must not do that.
    /// The coalesced form, for the transcript-version edge.
    ///
    /// 2026-09-14: every structural write to the transcript bumps that version,
    /// and one turn bumps it many times — the user row, each tool receipt, the
    /// reply. Each bump used to start its own `refresh`, and a refresh READS
    /// AND JSON-PARSES THE WHOLE TRANSCRIPT, then reassigns `cardsByRow`, which
    /// invalidates the card mount under every row. A burst now settles into one
    /// read. Nothing waits on this: a card appearing a quarter-second after the
    /// row it hangs off is not something anyone can see, and the explicit edges
    /// (appearance, session switch, turn completion) still refresh immediately.
    func refreshSoon(sessionID: String) {
        coalescedRefresh?.cancel()
        coalescedRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.coalescedRefresh = nil
            await self.refresh(sessionID: sessionID)
        }
    }

    func refresh(sessionID: String, reclaim: Bool = true) async {
        coalescedRefresh?.cancel()
        coalescedRefresh = nil
        refreshGeneration &+= 1
        let generation = refreshGeneration
        self.sessionID = sessionID
        guard !sessionID.isEmpty else {
            cardsByRow = [:]
            return
        }
        if let built = await InlineCardProjection.cardsByRow(
            sessionID: sessionID, dataRoot: dataRoot, reclaim: reclaim,
            isCurrent: { self.sessionID == sessionID && self.refreshGeneration == generation }
        ) {
            cardsByRow = built
        }
    }

    // MARK: - Actions

    func handle(
        card: InlineCardModel,
        action: InlineCardAction,
        appModel: AppModel
    ) {
        let sessionID = self.sessionID
        guard !sessionID.isEmpty else { return }
        switch action {
        case .secondary:
            // "Not now." The resolver settles it as declined and resumes the
            // turn with the consequence the card promised, so she carries on
            // and says plainly what she could not do.
            Task { await self.decline(card.id, sessionID: sessionID) }
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
            // Retry is begin again. A failed card that collects something
            // sends `.primary` instead, so a retyped key is not thrown away.
            Task {
                await self.begin(
                    card.id, sessionID: sessionID,
                    value: nil, choice: nil, appModel: appModel
                )
            }
        case .stop:
            // A need is waiting on a person; there is nothing in flight. Stop
            // means "this card stops being able to start a turn".
            Task {
                await InlineInteractionResolver.invalidateContinuation(
                    id: card.id, sessionID: sessionID, dataRoot: self.dataRoot
                )
                await self.refreshCurrent()
            }
        }
    }

    /// The person came back to Chat. Every card that sent them to a page is
    /// asked of its OWNER whether the thing is now done — settling it, or
    /// failing it with the owner's own words and keeping the retry.
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

    private func decline(_ id: String, sessionID: String) async {
        _ = try? await InlineInteractionResolver.decline(
            id: id, sessionID: sessionID, dataRoot: dataRoot
        )
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
        let current: InlineInteraction
        let descriptor: InlineInteractionDescriptor
        do {
            guard let prepared = try await InlineInteractionResolver.beginControl(
                id, sessionID: sessionID, dataRoot: dataRoot
            ) else { return }
            current = prepared.interaction
            descriptor = prepared.descriptor
        } catch {
            await refreshCurrent()
            return
        }
        await refreshCurrent()
        await open(
            descriptor.control,
            sessionID: sessionID,
            interaction: current,
            descriptor: descriptor,
            value: value,
            choice: choice,
            values: values,
            fullSetup: fullSetup,
            appModel: appModel
        )
    }

    /// Open the EXISTING control the descriptor names. Nothing here decides
    /// whether the thing is done — that is always the owner's answer, asked
    /// through `complete`.
    private func open(
        _ control: InlineInteractionDescriptor.Control,
        sessionID: String,
        interaction: InlineInteraction,
        descriptor: InlineInteractionDescriptor,
        value: String?,
        choice: String?,
        values: [String: String],
        fullSetup: Bool,
        appModel: AppModel
    ) async {
        await InlineInteractionResolver.runControl(
            interaction, descriptor: descriptor, sessionID: sessionID,
            value: value, choice: choice, values: values, fullSetup: fullSetup,
            controls: AppInlineInteractionControlPort(appModel: appModel), dataRoot: dataRoot,
            present: { control in
                switch control {
                case .internetAccounts:
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                case .pairDevice:
                    UserDefaults.standard.set("iphone", forKey: ShellRailTab.storageKey(.connectors))
                    self.openPage(.connectors, for: interaction.id, sessionID: sessionID)
                case .connectorManualToken where descriptor.target == "telegram":
                    self.openPage(.telegram, for: interaction.id, sessionID: sessionID)
                case .connectorManualToken, .connectorOAuth:
                    self.connectorSheet = ConnectorSheetRequest(
                        id: interaction.id, provider: descriptor.target, sessionID: sessionID)
                case .trustPostureRequired:
                    self.openPage(.trust, for: interaction.id, sessionID: sessionID)
                case .providerGroupModel:
                    self.openPage(.providers, for: interaction.id, sessionID: sessionID)
                default: break
                }
            },
            watch: { self.watchUntilGranted(interaction.id, sessionID: sessionID) },
            refresh: { await self.refreshCurrent() }
        )
    }

    /// A page a card (or the chat's own empty state) needs: the panel in
    /// Simple view, the page itself in Advanced. With an interaction, coming
    /// back is what asks its owner whether the thing is done.
    func openPage(_ item: SidebarItem, for id: String? = nil, sessionID: String = "") {
        if let id { awaitingReturn[id] = sessionID }
        if SimpleViewMode.isShowing {
            panelPage = item
        } else {
            _ = NativeAgentAppCoordinator.shared.request(.sidebar(item))
        }
    }

    /// The Simple panel closed, by Esc or its close button: the same
    /// questions a closed sheet and a return to Chat ask.
    func panelClosed() async {
        panelPage = nil
        await connectorSheetClosed()
        await verifyOnReturn()
    }

    /// While the Simple panel is up: settle what it was opened for the moment
    /// the owner says done, and close it. Writes nothing until then.
    func settlePanelIfDone() async {
        var waiting = awaitingReturn
        if let sheet = connectorSheet { waiting[sheet.id] = sheet.sessionID }
        guard !waiting.isEmpty else { return }
        guard await InlineInteractionResolver.settleVerifiedControls(waiting, dataRoot: dataRoot, didSettle: { id in
            self.awaitingReturn[id] = nil
        }) else { return }
        panelPage = nil
        connectorSheet = nil
        await refreshCurrent()
    }

    /// The connector sheet closed. Connectors is the authority on whether an
    /// account is connected. Closed without it connecting, nothing was tried
    /// on the card, so the card goes back to its fresh "Connect <Name>" ask;
    /// "still isn't connected" and "Try again" belong to a real failed attempt
    /// (the card's own fields, which carry the owner's refusal).
    func connectorSheetClosed() async {
        guard let request = connectorSheet else { return }
        connectorSheet = nil
        await settleOrReopen(request.id, sessionID: request.sessionID)
    }

    /// Settle if the owner now says done; otherwise put a card this tap left
    /// running back to pending.
    private func settleOrReopen(_ id: String, sessionID: String) async {
        await InlineInteractionResolver.settleOrReopen(id, sessionID: sessionID, dataRoot: dataRoot)
        await refreshCurrent()
    }

    // MARK: - Grants made in System Settings

    @ObservationIgnored private let grantWatch = InlineInteractionResolver.GrantWatch.shared

    private func watchUntilGranted(_ id: String, sessionID: String) {
        grantWatch.watchUntilGranted(id, sessionID: sessionID) { [weak self] in
            await self?.refreshCurrent()
        }
    }

    /// Re-read whatever conversation is open NOW. Every post-action refresh
    /// goes through this: the action belongs to the session it started in, the
    /// cards on screen belong to the session on screen.
    private func refreshCurrent() async {
        await refresh(sessionID: sessionID)
    }
}
