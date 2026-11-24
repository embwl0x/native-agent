import Foundation
import SenseCore
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import MacNerves

// Blueprint: | `InlineInteractionCoordinator+ChatLifecycle.swift` | `InlineInteractionCoordinator`; Verify control effects. |

extension InlineInteractionCoordinator {
    /// Adjacent identical declined or failed asks render once, at the newest receipt, with a repeat count. Separated asks remain separate events.
    private static func collapsingAnsweredRepeats(
        _ pairs: [(rowID: String, interaction: InlineInteraction)]
    ) -> (pairs: [(rowID: String, interaction: InlineInteraction)], counts: [String: Int]) {
        func answeredKey(_ interaction: InlineInteraction) -> String? {
            guard interaction.kind != .choose else { return nil }
            switch interaction.state {
            case .declined: return "declined|" + Self.askKey(interaction)
            // Different failure reasons are different answers.
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

    public struct CollapsedCards {
        public var pairs: [(rowID: String, interaction: InlineInteraction)]
        public var counts: [String: Int]
        /// Folded asks exclude superseded rows, which still have a quiet line.
        public var foldedCount: Int

        public var heading: String {
            let cards = pairs.count == 1 ? "1 card" : "\(pairs.count) cards"
            return foldedCount > 0 ? "\(cards), \(foldedCount) folded" : cards
        }
    }

    /// Open asks are reused by the transcript writer; fold terminal repeats only.
    public static func collapsedCards(
        _ pairs: [(rowID: String, interaction: InlineInteraction)]
    ) -> CollapsedCards {
        let collapsed = collapsingAnsweredRepeats(pairs)
        return CollapsedCards(
            pairs: collapsed.pairs,
            counts: collapsed.counts,
            foldedCount: max(0, pairs.count - collapsed.pairs.count)
        )
    }

    /// Ask identity follows need, purpose and axis, independently of wording or the blocked tool.
    private static func askKey(_ interaction: InlineInteraction) -> String {
        "\(interaction.kind.rawValue)|\(interaction.target)|\(interaction.mode?.rawValue ?? "")"
    }

    /// A choice made in Providers is read from its checked routing snapshot.
    public func selectionForReturn(_ interaction: InlineInteraction) async throws -> String? {
        guard interaction.kind == .modelChoice else { return interaction.target }
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let snapshot = try await router.checkedRoutingSnapshotReadOnly()
        let surfaces = ProviderSurfaceGroups.all
            .first { $0.id == interaction.target }?.surfaces ?? [interaction.target]
        for surface in surfaces {
            if let model = ProviderRoutingSurfaceLookup.value(snapshot.preferences, surface)?.model,
               !model.isEmpty, let provider = ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, surface),
               !provider.isEmpty {
                return InlineInteractionRegistry.modelOptionID(providerID: provider, modelID: model)
            }
        }
        return nil
    }

    public func runControl(
        _ interaction: InlineInteraction, descriptor: InlineInteractionDescriptor,
        sessionID: String, value: String?, choice: String?, values: [String: String],
        fullSetup: Bool, turn: Turn, controls: any InlineInteractionControlPort,
        present: @MainActor (InlineInteractionDescriptor.Control) async throws -> Void,
        watch: @MainActor () -> Void, refresh: @MainActor () async -> Void
    ) async throws {
        func finish(selection: String?, error: String? = nil, note: String? = nil) async {
            let secrets = values.values.map { Data($0.utf8) } + (value.map { [Data($0.utf8)] } ?? [])
            await completeControl(interaction.id, sessionID: sessionID, expectedRevision: interaction.revision, selection: selection,
                scope: nil, setupError: error.map { FaceSecretRedaction.text($0, secrets: secrets) },
                note: note.map { FaceSecretRedaction.text($0, secrets: secrets) }, door: "mac")
            await refresh()
        }
        func finishEffect() async {
            let effect = await applyControlEffect(interaction, descriptor: descriptor, value: value,
                values: values, controls: controls)
            if effect.watch { watch() }
            else { await finish(selection: descriptor.target, error: effect.error, note: effect.note) }
        }
        switch descriptor.control {
        case .internetAccounts:
            // Mail readiness determines the control: check permission first, and open Internet Accounts only for a missing account.
            do {
                _ = try await MacIntegrationPermissionStore(dataRoot: dataRoot).setWithReceipt(
                    integrationId: "mail", read: true, write: nil, actionID: "\(interaction.id)-mail",
                    surface: "inline_card", provenance: .local(), onlyAddingAxes: true)
            } catch {
                await finish(selection: nil, error: error.localizedDescription)
                return
            }
            let readiness = await platform.mailReadiness(check: true)
            if readiness.status == "ready" {
                await finish(selection: "mail", note: "Mail connected" + (readiness.next.map { ". " + $0 } ?? ""))
                return
            }
            watch()
            if readiness.status == "needs_setup" { try await present(.internetAccounts) }
        case .chromeSetup:
            if !controls.chromeControlEnabled, !controls.fullMacGrantIsActive {
                try await controls.enableChromeControl()
            }
            if await completeIfVerified(id: interaction.id, sessionID: sessionID, expectedRevision: interaction.revision) {
                await refresh()
                return
            }
            if let error = await controls.setUpChromeControl(turn: turn) {
                await finish(selection: "chrome", error: error)
            } else {
                watch()
            }
        case .connectorManualToken where !fullSetup && !values.isEmpty:
            await finishEffect()
        case .providerAPIKey:
            do {
                try await controls.openProviderEntry(provider: descriptor.target, dataRoot: dataRoot)
                _ = try await returnToPending(interaction, sessionID: sessionID)
                await refresh()
            } catch { await finish(selection: nil, error: error.localizedDescription) }
        case .macPermissionGrant, .capabilityFlag:
            await finishEffect()
        case .keyring:
            var refused: String? = "This card carries no secret to keep."
            let name = String(interaction.target.dropFirst("secret:".count))
            if interaction.secret?.remove == true {
                do { try await Keyring.forget(name); refused = nil } catch { refused = "\(name) could not be removed: \(error.localizedDescription)" }
            } else if let ask = interaction.secret {
                // Not now while a sign-in runs leaves the card declined: the late token is not kept.
                let id = interaction.id
                refused = await NativeOAuthFlow.grantSecret(name, ask: ask, pasted: value, open: {
                    do {
                        guard let current = try await self.interaction(id: id, sessionID: sessionID) else { return false }
                        return current.state == .running && current.revision == interaction.revision
                    } catch {
                        await self.recordControlFailure(id, error: error)
                        return false
                    }
                }, shown: refresh)
            }
            await finish(selection: interaction.target, error: refused)
        case .providerGroupModel:
            if choice == InlineInteractionRegistry.persistentChoiceOptionID {
                try await present(.providerGroupModel)
            } else if let picked = choice, !picked.isEmpty {
                await completeModelChoice(interaction, picked: picked,
                    sessionID: sessionID, door: "mac", controls: controls)
                await refresh()
            } else {
                try await present(.providerGroupModel)
            }
        case .inlineChoice:
            await finish(selection: choice)
        case .pairDevice, .connectorManualToken, .trustPostureRequired:
            try await present(descriptor.control)
        case .unavailable, .unknown:
            break
        }
    }

    /// Effects run only from the person's local control; phone answers use the canonical Inbox row or non-destructive verification.
    func applyControlEffect(
        _ interaction: InlineInteraction, descriptor: InlineInteractionDescriptor, value: String?, values: [String: String],
        controls: any InlineInteractionControlPort) async -> (error: String?, note: String?, watch: Bool) {
        switch descriptor.control {
        case .connectorManualToken:
            let outcome = await controls.saveConnectorCredentials(connector: descriptor.target, values: values, dataRoot: dataRoot)
            return (outcome.error, outcome.note, false)
        case .macPermissionGrant:
            do { return (nil, nil, try await grantPermissions(interaction, controls: controls)) }
            catch { return (error.localizedDescription, nil, false) }
        case .capabilityFlag:
            do { return (nil, nil, try await setCapabilityFlag(interaction, controls: controls)) }
            catch { return (error.localizedDescription, nil, false) }
        default: return (nil, nil, false)
        }
    }

    /// Back from a control left unfinished: the card settles if its owner verifies it, else goes back to pending so it can be answered again.
    public func settleOrReopen(_ id: String, sessionID: String, expectedRevision: Int, selection: String? = nil,
                                      scope: InlineInteraction.Scope? = nil) async {
        guard !(await completeIfVerified(id: id, sessionID: sessionID, expectedRevision: expectedRevision,
                                         selection: selection, scope: scope)) else { return }
        do {
            if let current = try await interaction(id: id, sessionID: sessionID),
               current.revision == expectedRevision, case .running = current.state {
                _ = try await returnToPending(current, sessionID: sessionID)
            }
        } catch {
            recordControlFailure(id, error: error)
        }
    }

    public func grantPermissions(
        _ interaction: InlineInteraction,
        controls: any InlineInteractionControlPort) async throws -> Bool {
        // Grant only the requested axis across the whole chain, matching the scope the card showed.
        let mode = interaction.mode
        var categories: [String] = []
        for capability in interaction.allTargets {
            if InlineInteractionRegistry.isMacControlCategory(capability) {
                categories.append(capability)
                continue
            }
            guard MacIntegrationID.all.contains(capability) else { continue }
            do {
                _ = try await MacIntegrationPermissionStore(dataRoot: dataRoot).setWithReceipt(
                    integrationId: capability,
                    read: MacIntegrationID.supportsRead(capability) && (mode?.wantsRead ?? true),
                    write: MacIntegrationID.supportsWrite(capability) && (mode?.wantsWrite ?? true),
                    actionID: "\(interaction.id)-\(capability)",
                    surface: "inline_card",
                    provenance: .local(),
                    // Merge the requested axis under the store lock so granting it cannot revoke the other axis.
                    onlyAddingAxes: true
                )
            } catch {
                throw error
            }
        }
        if !categories.isEmpty {
            try await controls.grantMacControlCategories(categories, dataRoot: dataRoot, logTag: "interaction")
        }
        // The card keeps running while macOS leaves anything unresolved, or while a grant waits on the restart only this card's tap performs.
        let allowed = try await macOSAllowed(interaction)
        shownPanes[interaction.id] = nil
        let unresolved = try await platform.askMacOSForCard(allowed, mode: mode, passed: [])
        if !unresolved.isEmpty { return true }
        return !(await SystemPermissionPreflight.awaitingLaunch(allowed)).isEmpty
    }

    /// What of a card macOS may be asked for: only what the app side allowed, so a Trust write refused outside Full Mac never leads to a macOS
    /// prompt.
    func macOSAllowed(_ interaction: InlineInteraction) async throws -> [String] {
        let granted: [String: MacIntegrationPermission]
        if interaction.allTargets.contains(where: { MacIntegrationID.all.contains($0) }) {
            granted = try await MacIntegrationPermissionStore(dataRoot: dataRoot).currentChecked()
        } else { granted = [:] } // OS-only/category cards do not read integration authority.
        var allowed: [String] = []
        for capability in interaction.allTargets {
            if !MacIntegrationID.all.contains(capability), !InlineInteractionRegistry.isMacControlCategory(capability) {
                if SystemPermissionPreflight.cardSettingsCapability(capability) != nil { allowed.append(capability) }
            } else if InlineInteractionRegistry.isMacControlCategory(capability) {
                let permitted = try await Task.detached {
                    try InlineInteractionRegistry.macControlCategoryAllowed(capability, dataRoot: self.dataRoot)
                }.value
                if permitted { allowed.append(capability) }
            } else if (granted[capability]?.read ?? false) || (granted[capability]?.write ?? false) {
                allowed.append(capability)
            }
        }
        return allowed
    }

    public func setCapabilityFlag(
        _ interaction: InlineInteraction,
        controls: any InlineInteractionControlPort) async throws -> Bool {
        // Patch only the named field under the owner lock so concurrent changes to other switches survive.
        guard let flag = InlineInteractionRegistry.capabilityFlags[interaction.target] else {
            return false
        }
        try await controls.grantCapabilityFlag(policyKey: flag.policyKey, dataRoot: dataRoot, logTag: "interaction")
        if flag.id != "screen_capture" || controls.screenCaptureEnabled,
           !(try await platform.askMacOSForCard([flag.id], mode: nil, passed: [])).isEmpty {
            return true
        }
        // Trust is re-read by the resolver; the tap is not the authority.
        return false
    }

    public func saveModelSelection(target: String, picked: String, controls: any InlineInteractionControlPort) async throws {
        guard let group = ProviderSurfaceGroups.all.first(where: { $0.id == target }) else {
            throw ProviderRoutingError.invalidRequest
        }
        guard let option = InlineInteractionRegistry.splitModelOptionID(picked) else {
            throw ToolFailureError("This model choice does not name its account. Choose a current account-qualified model option in Providers.",
                effects: .none, code: "model_choice_identity_unavailable")
        }
        try await controls.saveProviderGroupSelection(group: group, providerID: option.providerID,
            model: option.modelID)
    }

    /// Every door begins on the card revision and settles from the Mac control's actual save outcome.
    public func answerModelChoice(
        _ card: InlineInteraction, sessionID: String, picked: String, scope: InlineInteraction.Scope?,
        attribution: String? = nil, door: String? = nil, controls: @MainActor () -> (any InlineInteractionControlPort)?) async throws -> InlineInteraction {
        let running = try await begin(id: card.id, sessionID: sessionID, expectedRevision: card.revision)
        return try await settleModelChoice(card, sessionID: sessionID, picked: picked, scope: scope,
            expectedRevision: running.revision, attribution: attribution, door: door, controls: controls())
    }

    /// The Mac card's control already began the card.
    public func completeModelChoice(
        _ interaction: InlineInteraction, picked: String, sessionID: String, door: String? = nil,
        controls: any InlineInteractionControlPort) async {
        do {
            _ = try await settleModelChoice(interaction, sessionID: sessionID, picked: picked,
                scope: interaction.primaryScope ?? .persistent, expectedRevision: interaction.revision, door: door, controls: controls)
        } catch { recordControlFailure(interaction.id, error: error) }
    }

    private func settleModelChoice(
        _ card: InlineInteraction, sessionID: String, picked: String, scope: InlineInteraction.Scope?,
        expectedRevision: Int? = nil, attribution: String? = nil, door: String? = nil,
        controls: (any InlineInteractionControlPort)?) async throws -> InlineInteraction {
        let current = try await require(id: card.id, sessionID: sessionID)
        try checkRevision(current, expectedRevision)
        guard case .running = current.state else { throw ResolveError.alreadySettled(current.state.name) }
        var setupError: String?
        if (scope ?? .persistent) == .persistent {
            do {
                guard let controls else {
                    throw NSError(domain: "InteractionCard", code: 2, userInfo: [NSLocalizedDescriptionKey: "The Mac's controls are unavailable."])
                }
                try await saveModelSelection(target: card.target, picked: picked, controls: controls)
            } catch { setupError = error.localizedDescription }
        }
        return try await complete(id: card.id, sessionID: sessionID, selection: picked, scope: scope,
            expectedRevision: expectedRevision, attribution: attribution, setupError: setupError, door: door, turn: nil)
    }

    /// Complete against the session captured at the tap; a control can outlive a conversation switch, and a refusal must not disappear into UI refresh.
    public func completeControl(
        _ id: String, sessionID: String, expectedRevision: Int, selection: String?, scope: InlineInteraction.Scope?,
        setupError: String?, note: String?, door: String? = nil) async {
        do {
            _ = try await complete(id: id, sessionID: sessionID, selection: selection, scope: scope, expectedRevision: expectedRevision,
                setupError: setupError, note: note, door: door, turn: nil)
        } catch {
            recordControlFailure(id, error: error)
        }
    }

    /// A running permission card carries itself. On every wake (the person back in the agent's window, System Settings quit) it re-reads
    /// macOS. When the grant it waited on is on, or the person came back without it (that pane joins `shownPanes`), the one walk goes on
    /// (`askMacOSForCard`) and the card records what it waits on after that ask. `asking` is the person's Continue: the walk starts over from
    /// the first grant still off, so a pane closed without granting opens again. Only a tap starts a walk, so a pending card is never driven;
    /// the first wake after the tap only records, because the tap's own walk just asked.
    public func walk(id: String, sessionID: String, handed: Bool, asking: Bool = false) async {
        let current: InlineInteraction
        do {
            guard let found = try await interaction(id: id, sessionID: sessionID) else { return }
            current = found
        } catch {
            recordControlFailure(id, error: error)
            return
        }
        guard current.kind == .permission, case .running = current.state else {
            shownPanes[id] = nil
            return
        }
        guard handed || asking || current.waitingOn != nil,
              await Self.descriptor(for: current, dataRoot: dataRoot).control == .macPermissionGrant else { return }
        if asking { shownPanes[id] = nil }
        var now = await SystemPermissionPreflight.waitingOn(current.allTargets, mode: current.mode, passed: shownPanes[id] ?? [])
        guard !Task.isCancelled else { return }
        // Back from the pane it waited on, still off: that pane was shown; the walk goes on past it.
        if !asking, case .target(let shown)? = current.waitingOn, now == current.waitingOn, shownPanes[id]?.contains(shown) != true {
            shownPanes[id, default: []].insert(shown)
            now = await SystemPermissionPreflight.waitingOn(current.allTargets, mode: current.mode, passed: shownPanes[id] ?? [])
        }
        if asking || (current.waitingOn != nil && now != current.waitingOn) {
            do {
                _ = try await platform.askMacOSForCard(try await macOSAllowed(current), mode: current.mode,
                    passed: shownPanes[id] ?? [])
            } catch { recordControlFailure(id, error: error) }
            now = await SystemPermissionPreflight.waitingOn(current.allTargets, mode: current.mode, passed: shownPanes[id] ?? [])
        }
        guard now != current.waitingOn, !Task.isCancelled else { return }
        var moved = current
        moved.waitingOn = now
        moved.revision += 1
        let revision = current.revision
        do {
            try await persist(moved, sessionID: sessionID, expecting: { card in
                guard case .running = card.state else { return false }
                return card.revision == revision
            })
        } catch {
            recordControlFailure(id, error: error)
        }
    }

    func recordControlFailure(_ id: String, error: any Error) {
        // The CAS loser did no work: Not now or another tap already moved it.
        if let error = error as? ResolveError, case .staleRevision = error { return }
        RepairOwed.owe(dataRoot, id: "interaction-control-\(id)", kind: .act,
            operation: "interaction.control", owner: "transcript",
            words: TurnSecretRedactor.redactText(error.localizedDescription))
    }
}

extension InlineInteractionCoordinator {
    /// BackgroundLoops owns this observation's task and cancellation.
    public func observeGrants() async {
        guard generation == nil, !Task.isCancelled else { return }
        let identity = UUID()
        generation = identity
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        // Subscribe before the first read; taps use the same coalesced wake.
        let permissions = self.platform.permissionChanges()
        let source = Task {
            defer { continuation.finish() }
            for await _ in permissions {
                guard !Task.isCancelled else { return }
                continuation.yield(())
            }
        }
        permissionSource = source
        continuation.yield(())
        await withTaskCancellationHandler {
            for await _ in changes {
                guard current(identity) else { return }
                await recheckGrants(identity)
            }
        } onCancel: {
            continuation.finish()
        }
        await settle { @MainActor [self] in
            source.cancel()
            await source.value
            continuation.finish()
            if self.generation == identity {
                self.generation = nil
                self.wake = nil
                self.permissionSource = nil
                self.grantWatches = [:]
                self.refreshers = [:]
            }
        }
    }

    private func current(_ identity: UUID) -> Bool {
        generation == identity && !Task.isCancelled
    }

    public func watchUntilGranted(_ id: String, sessionID: String, refresh: @escaping @MainActor () async -> Void) {
        guard let wake, permissionSource?.isCancelled == false else { return }
        grantWatches[id] = (id, sessionID)
        refreshers[id] = refresh
        wake.yield(())
    }

    private func recheckGrants(_ identity: UUID) async {
        var waiting = grantWatches
        let cards: [(id: String, sessionID: String)]
        do { cards = try await self.platform.openInteractionCards() }
        catch {
            RepairOwed.owe(dataRoot, id: "interaction-card-census", kind: .act,
                operation: "interaction.cards", owner: "inbox",
                words: """
                    Open permission cards could not be read: \(error.localizedDescription). Repair the inbox; no card has been declared absent or \
                    settled.
                    """)
            return
        }
        for card in cards {
            let key = card.id
            if waiting[key] != nil { continue }
            guard current(identity) else { return }
            let found: InlineInteraction?
            do { found = try await self.interaction(id: card.id, sessionID: card.sessionID) }
            catch {
                self.recordControlFailure(card.id, error: error)
                continue
            }
            guard let current = found,
                  current.kind == .permission, current.state.isOpen else { continue }
            guard self.current(identity) else { return }
            waiting[key] = (card.id, card.sessionID)
        }
        var settled = false
        var completed: [@MainActor () async -> Void] = []
        for (key, card) in waiting {
            guard current(identity) else { return }
            if await self.completeIfVerified(id: card.id, sessionID: card.sessionID) {
                guard current(identity) else { return }
                grantWatches[key] = nil
                if let refresh = refreshers.removeValue(forKey: key) { completed.append(refresh) }
                settled = true
            } else {
                await self.walk(id: card.id, sessionID: card.sessionID, handed: grantWatches[key] != nil)
            }
        }
        guard settled, current(identity) else { return }
        await self.platform.refreshInteractionInbox()
        for refresh in completed {
            guard current(identity) else { return }
            await refresh()
        }
    }
}
