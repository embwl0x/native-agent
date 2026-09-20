import ChatOrchestration
import Foundation
import MacIntegration
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import SwiftUI

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
        // Once per conversation per launch: a continuation this process never
        // claimed, but disk says is claimed, belongs to a process that died
        // between the claim and the turn. Release it and run the turn the
        // person already paid for with a tap.
        if reclaim {
            await InlineInteractionResolver.reclaimStrandedContinuations(
                sessionID: sessionID, dataRoot: dataRoot
            )
        }
        // A transcript that could not be read is NOT a conversation with no
        // cards. Keep what is already on screen rather than blanking every card
        // the person is looking at; the resolver logged the error once.
        let pairs: [(rowID: String, interaction: InlineInteraction)]
        switch await InlineInteractionResolver.checkedInteractionsByRow(
            sessionID: sessionID, dataRoot: dataRoot
        ) {
        case .success(let read): pairs = read
        case .failure: return
        }
        // The read above is asynchronous and the person can switch
        // conversations while it runs. Publishing a stale read would put one
        // transcript's cards under another's rows, so a refresh that no longer
        // describes the open conversation is dropped.
        guard self.sessionID == sessionID, refreshGeneration == generation else { return }
        var built: [String: [InlineCardModel]] = [:]
        let collapsed = Self.collapsedCards(pairs)
        for pair in collapsed.pairs {
            let descriptor = InlineInteractionResolver.descriptor(
                for: pair.interaction, dataRoot: dataRoot
            )
            built[pair.rowID, default: []].append(
                InlineCardProjection.model(
                    pair.interaction, descriptor: descriptor,
                    repeatCount: collapsed.counts[pair.interaction.id] ?? 1
                )
            )
        }
        cardsByRow = built
    }

    /// One live card per ask (Agent, 2026-09-13).
    ///
    /// The raise site is where this becomes durable: a new need supersedes the
    /// older identical ones on disk, under the transcript's own lock. This is
    /// the READ side of the same rule, and it exists because the transcript
    /// outlives the rule — a conversation written before it, or by a surface
    /// that raised its need somewhere else, still has four live "Connect
    /// Notion" cards in it. The newest keeps the controls; the rest render as
    /// the one quiet line. Nothing is written here: a read of the page must
    /// not rewrite the page.
    static func collapsingOlderAsks(
        _ pairs: [(rowID: String, interaction: InlineInteraction)]
    ) -> [(rowID: String, interaction: InlineInteraction)] {
        // `checkedInteractionsByRow` hands them back in transcript order, so
        // the LAST open one of each ask is the one the person was asked most
        // recently — and the only one that keeps its buttons.
        // A row that says NOTHING about the ask cannot be the one that answers
        // it. A `.superseded` row is a copy that already went quiet, and an
        // `.unknown` row is a state this build does not understand — either
        // one arriving later than a live pending card used to claim "newest"
        // and shadow it, so the only card with buttons went quiet behind a row
        // that has none, and the question became unanswerable on the glass.
        // A `choose` names no thing it is about — empty target, nil mode — so
        // the ask key cannot tell two unrelated questions apart. Collapsing
        // them silenced the first question because a second, different one was
        // asked later. Only the kinds that name what they are for collapse;
        // this is the read side of the same exclusion the raise site makes.
        var newest: [String: Int] = [:]
        for (index, pair) in pairs.enumerated() where pair.interaction.kind != .choose {
            switch pair.interaction.state {
            case .superseded, .unknown: continue
            default: newest[Self.askKey(pair.interaction)] = index
            }
        }
        return pairs.enumerated().map { index, pair in
            // Only a still-waiting ask goes quiet. The newest one keeps
            // whatever it is — live, or the receipt it settled into — so
            // answering it does not hand the question back to an older copy.
            guard pair.interaction.state.isOpen,
                  let newest = newest[Self.askKey(pair.interaction)],
                  newest != index
            else { return pair }
            return (pair.rowID, pair.interaction.superseded(at: pair.interaction.createdAt))
        }
    }

    /// CONSECUTIVE IDENTICAL ANSWERED ASKS ARE ONE THING THAT HAPPENED.
    ///
    /// Pending asks already supersede each other, so only the newest keeps its
    /// buttons — but declined and failed ones accumulate, and a conversation
    /// that asked for Notion ten times reads as nagging on the glass and in the
    /// quiet page read alike (Agent, 2026-09-14: ten Connect Notion cards).
    ///
    /// A run of neighbouring pairs with the same ask key, all answered the same
    /// way, collapses to its LAST member — the one whose receipt is current —
    /// and that member's id carries how many it stands for. Consecutive only:
    /// an ask answered, then asked again after other work, is a second thing
    /// that happened and keeps its own line. Nothing is written here.
    static func collapsingAnsweredRepeats(
        _ pairs: [(rowID: String, interaction: InlineInteraction)]
    ) -> (pairs: [(rowID: String, interaction: InlineInteraction)], counts: [String: Int]) {
        func answeredKey(_ interaction: InlineInteraction) -> String? {
            guard interaction.kind != .choose else { return nil }
            switch interaction.state {
            case .declined: return "declined|" + Self.askKey(interaction)
            // A FAILURE IS ITS REASON. Two asks for the same thing that broke
            // in two different ways are two different answers, and folding
            // them would print one reason over the other's — so the reason is
            // part of what makes two failures the same failure. A failed card
            // is never folded out of sight either way: the survivor of a run
            // keeps its reason and its Try again control.
            case .failed(let reason): return "failed|\(reason)|" + Self.askKey(interaction)
            default: return nil
            }
        }
        var kept: [(rowID: String, interaction: InlineInteraction)] = []
        var counts: [String: Int] = [:]
        var index = 0
        while index < pairs.count {
            guard let key = answeredKey(pairs[index].interaction) else {
                kept.append(pairs[index])
                index += 1
                continue
            }
            var end = index
            while end + 1 < pairs.count, answeredKey(pairs[end + 1].interaction) == key { end += 1 }
            let survivor = pairs[end]
            kept.append(survivor)
            if end > index { counts[survivor.interaction.id] = end - index + 1 }
            index = end + 1
        }
        return (kept, counts)
    }

    /// THE CARDS A CONVERSATION SHOWS, AND WHAT IT SWALLOWED TO SHOW THEM.
    ///
    /// ONE FUNCTION, BOTH SURFACES. The glass and the quiet page read used to
    /// compose the same two collapse passes side by side and then count the
    /// result independently — so the heading was free to disagree with the
    /// lines under it, and did: Agent's 2026-09-14 read said "1 card in this
    /// conversation" over a receipt marked "(×2)", which is two asks reported
    /// as one with nothing saying so. The count and the lines now come out of
    /// the same call, and the heading says what was folded.
    struct CollapsedCards {
        var pairs: [(rowID: String, interaction: InlineInteraction)]
        /// How many asks each surviving line stands for, by interaction id.
        var counts: [String: Int]
        /// Asks that disappeared into a surviving line — the total minus the
        /// lines. Never the superseded ones: those still have a line of their
        /// own, they are just quiet.
        var foldedCount: Int

        /// The heading both surfaces print: the distinct VISIBLE lines, and how
        /// many asks were folded into them.
        var heading: String {
            let cards = pairs.count == 1 ? "1 card" : "\(pairs.count) cards"
            return foldedCount > 0 ? "\(cards), \(foldedCount) folded" : cards
        }
    }

    /// The two collapse passes and the count, in one place.
    static func collapsedCards(
        _ pairs: [(rowID: String, interaction: InlineInteraction)]
    ) -> CollapsedCards {
        let quieted = collapsingOlderAsks(pairs)
        let collapsed = collapsingAnsweredRepeats(quieted)
        return CollapsedCards(
            pairs: collapsed.pairs,
            counts: collapsed.counts,
            foldedCount: max(0, quieted.count - collapsed.pairs.count)
        )
    }

    /// What makes two asks the same ask: what is needed, what it is needed
    /// for, and which axis. Not the wording, and not the tool that hit it.
    static func askKey(_ interaction: InlineInteraction) -> String {
        "\(interaction.kind.rawValue)|\(interaction.target)|\(interaction.mode?.rawValue ?? "")"
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
        case .primary(let value, let choice):
            Task {
                await self.begin(
                    card.id, sessionID: sessionID,
                    value: value, choice: choice, appModel: appModel
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
        for (id, originSessionID) in pending {
            guard let current = await InlineInteractionResolver.interaction(
                id: id, sessionID: originSessionID, dataRoot: dataRoot
            ), current.state.isOpen else { continue }
            let selection = await selectionForReturn(current)
            _ = try? await InlineInteractionResolver.complete(
                id: id,
                sessionID: originSessionID,
                selection: selection,
                scope: current.kind == .modelChoice ? .persistent : nil,
                dataRoot: dataRoot
            )
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
        appModel: AppModel
    ) async {
        guard let current = await InlineInteractionResolver.interaction(
            id: id, sessionID: sessionID, dataRoot: dataRoot
        ) else { return }
        let descriptor = InlineInteractionResolver.descriptor(for: current, dataRoot: dataRoot)

        // `begin` refuses a stale revision and a dead control, which is what
        // makes a duplicate tap and a card with no control both safe.
        do {
            _ = try await InlineInteractionResolver.begin(
                id: id,
                sessionID: sessionID,
                expectedRevision: current.revision,
                dataRoot: dataRoot
            )
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
        appModel: AppModel
    ) async {
        switch control {
        case .internetAccounts:
            awaitingReturn[interaction.id] = sessionID
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
        case .connectorManualToken, .connectorOAuth:
            // Connectors' own wizard, opened on the connector the card names.
            // It closes; `sheetClosed` asks Connectors what actually happened.
            connectorSheet = ConnectorSheetRequest(
                id: interaction.id, provider: descriptor.target, sessionID: sessionID
            )

        case .macPermissionGrant:
            await grantPermissions(interaction, sessionID: sessionID, appModel: appModel)

        case .trustPostureRequired:
            // Nothing is granted and nothing is written. The person's posture
            // is theirs; Trust opens, and coming back to Chat is what asks the
            // policy whether it actually changed.
            awaitingReturn[interaction.id] = sessionID
            _ = NativeAgentAppCoordinator.shared.request(.sidebar(.trust))

        case .capabilityFlag:
            await setCapabilityFlag(interaction, sessionID: sessionID, appModel: appModel)

        case .providerAPIKey:
            await saveAPIKey(
                interaction, sessionID: sessionID, value: value, appModel: appModel
            )

        case .providerGroupModel:
            if choice == InlineInteractionRegistry.persistentChoiceOptionID {
                // The explicit permanent choice. A card never writes a group's
                // model behind Providers' back, so this goes where every other
                // permanent change goes, and the return re-reads the snapshot.
                awaitingReturn[interaction.id] = sessionID
                _ = NativeAgentAppCoordinator.shared.request(.sidebar(.providers))
            } else if let picked = choice, !picked.isEmpty {
                // The card had the list, so the pick resolves here at the
                // scope the primary promised — for one image, nothing is
                // written anywhere.
                await complete(
                    interaction.id,
                    sessionID: sessionID,
                    selection: picked,
                    scope: interaction.primaryScope ?? .persistent
                )
            } else {
                // No list to pick from: Providers owns the choice. The card
                // stays running, and coming back to Chat is what asks the
                // routing snapshot what the group now runs on.
                awaitingReturn[interaction.id] = sessionID
                _ = NativeAgentAppCoordinator.shared.request(.sidebar(.providers))
            }

        case .inlineChoice:
            await complete(
                interaction.id, sessionID: sessionID, selection: choice, scope: nil
            )

        case .unavailable, .unknown:
            // `begin` already refused; nothing opens.
            break
        }
    }

    /// The connector sheet closed. Connectors is the authority on whether an
    /// account is connected — a cancelled sheet and a rejected token both
    /// settle as "still not connected", with the card and its retry intact.
    func connectorSheetClosed() async {
        guard let request = connectorSheet else { return }
        connectorSheet = nil
        await complete(
            request.id, sessionID: request.sessionID,
            selection: request.provider, scope: nil
        )
    }

    private func grantPermissions(
        _ interaction: InlineInteraction,
        sessionID: String,
        appModel: AppModel
    ) async {
        // Every capability in the chain, in one grant — the card asked once.
        // The need carries the axis the blocked call wanted, so each capability
        // gets THAT axis and no more, which is exactly what the card's scope
        // lines told the person they were allowing.
        let mode = interaction.mode
        var categories: [String] = []
        for capability in interaction.allTargets {
            if InlineInteractionRegistry.isMacControlCategory(capability) {
                categories.append(capability)
                continue
            }
            guard MacIntegrationID.all.contains(capability) else { continue }
            do {
                _ = try await MacIntegrationPermissionStore.shared.setWithReceipt(
                    integrationId: capability,
                    read: MacIntegrationID.supportsRead(capability) && (mode?.wantsRead ?? true),
                    write: MacIntegrationID.supportsWrite(capability) && (mode?.wantsWrite ?? true),
                    actionID: "\(interaction.id)-\(capability)",
                    surface: "inline_card",
                    provenance: .local(),
                    // The card asked for ONE axis and says so on its scope
                    // line; granting it must not revoke the other one the
                    // person already gave. Additive, merged under the store's
                    // own lock.
                    onlyAddingAxes: true
                )
            } catch {
                NSLog("[interaction] grant failed for \(capability): \(error)")
            }
        }
        if !categories.isEmpty {
            await grantMacControlCategories(categories, appModel: appModel)
        }
        // The store is re-read by the resolver; a capability that did not take
        // fails the card rather than settling it.
        await complete(
            interaction.id, sessionID: sessionID,
            selection: interaction.target, scope: nil
        )
    }

    /// Trust's own Mac Control write — the SAME one-field patch the
    /// `interaction_act` path makes, through the same helper. The card flips
    /// exactly the categories it named (plus the master gate they hang off,
    /// which is what makes them mean anything) and touches no other field of
    /// the saved policy: writing back the whole CACHED block stomped every
    /// unrelated verb the person had changed since that cache was read. The
    /// posture check is re-run inside the locked generation the patch merges
    /// into, so a posture lowered since the card was drawn refuses the write
    /// and the resolver's re-read fails the card in the owner's own words.
    private func grantMacControlCategories(
        _ categories: [String],
        appModel: AppModel
    ) async {
        await AppChatToolDispatcher.applyMacControlCategoryGrant(
            categories, appModel: appModel, dataRoot: dataRoot, logTag: "interaction"
        )
    }

    private func setCapabilityFlag(
        _ interaction: InlineInteraction,
        sessionID: String,
        appModel: AppModel
    ) async {
        // The ONE field the card named, patched into the locked generation
        // through the same helper `interaction_act` uses. Sending back the
        // whole cached multimodal block overwrote any other switch the person
        // had flipped since that cache was read.
        guard let flag = InlineInteractionRegistry.capabilityFlags[interaction.target] else {
            await complete(
                interaction.id, sessionID: sessionID,
                selection: interaction.target, scope: nil
            )
            return
        }
        await AppChatToolDispatcher.applyCapabilityFlagGrant(
            policyKey: flag.policyKey, appModel: appModel,
            dataRoot: dataRoot, logTag: "interaction"
        )
        // Trust is re-read by the resolver; the tap is not the authority.
        await complete(
            interaction.id, sessionID: sessionID,
            selection: interaction.target, scope: nil
        )
    }

    private func saveAPIKey(
        _ interaction: InlineInteraction,
        sessionID: String,
        value: String?,
        appModel: AppModel
    ) async {
        let key = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            // Providers' own configure call — the same one its sheet makes.
            // `defaultModel: nil` so saving a key never silently repoints the
            // provider at a different model.
            _ = try? await appModel.configureProvider(
                interaction.target, apiKey: key, authMode: "api_key", defaultModel: nil
            )
        }
        // Readiness is Providers' answer, not the fact that a key was typed: a
        // key it rejects leaves the card live, with its retry.
        await complete(
            interaction.id, sessionID: sessionID,
            selection: interaction.target, scope: nil
        )
    }

    /// `sessionID` is the conversation the card was tapped in, carried from
    /// the tap rather than read off the binding: the async work above can
    /// outlast a conversation switch, and completing against whichever
    /// transcript happens to be open by then writes the answer into the wrong
    /// one and leaves the real card running for ever. The refusal is logged
    /// rather than swallowed, for the same reason.
    private func complete(
        _ id: String,
        sessionID: String,
        selection: String?,
        scope: InlineInteraction.Scope?
    ) async {
        do {
            _ = try await InlineInteractionResolver.complete(
                id: id,
                sessionID: sessionID,
                selection: selection,
                scope: scope,
                dataRoot: dataRoot
            )
        } catch {
            NSLog("[interaction] complete failed for \(id): \(error)")
        }
        await refreshCurrent()
    }

    /// Re-read whatever conversation is open NOW. Every post-action refresh
    /// goes through this: the action belongs to the session it started in, the
    /// cards on screen belong to the session on screen.
    private func refreshCurrent() async {
        await refresh(sessionID: sessionID)
    }

    /// What a model choice resolved through Providers settled ON. The person
    /// picked it there, so the group's own snapshot is the answer; the resolver
    /// then reads that same snapshot back before the card claims anything.
    private func selectionForReturn(_ interaction: InlineInteraction) async -> String? {
        guard interaction.kind == .modelChoice else { return interaction.target }
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        guard let snapshot = try? await router.checkedRoutingSnapshotReadOnly() else { return nil }
        let surfaces = ProviderSurfaceGroups.all
            .first { $0.id == interaction.target }?.surfaces ?? [interaction.target]
        for surface in surfaces {
            if let model = ProviderRoutingSurfaceLookup.value(snapshot.preferences, surface)?.model,
               !model.isEmpty {
                return model
            }
        }
        return nil
    }
}
