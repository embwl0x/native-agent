import Foundation
import ChatOrchestration
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import MacIntegration
import MacControl

extension InlineInteractionResolver {
    /// Legacy transcripts can contain repeated open asks. Only the newest
    /// retains controls; projection never rewrites the transcript.
    private static func collapsingOlderAsks(
        _ pairs: [(rowID: String, interaction: InlineInteraction)]
    ) -> [(rowID: String, interaction: InlineInteraction)] {
        // Transcript order defines newest. Superseded/unknown rows cannot
        // shadow a readable ask; choose cards do not name a shared target.
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

    /// Adjacent identical declined or failed asks render once, at the newest
    /// receipt, with a repeat count. Separated asks remain separate events.
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

    /// Both visible cards and the quiet page use this projection and count.
    public struct CollapsedCards {
        public var pairs: [(rowID: String, interaction: InlineInteraction)]
        /// How many asks each surviving line stands for, by interaction id.
        public var counts: [String: Int]
        /// Folded asks exclude superseded rows, which still have a quiet line.
        public var foldedCount: Int

        /// The heading both surfaces print: the distinct VISIBLE lines, and how
        /// many asks were folded into them.
        public var heading: String {
            let cards = pairs.count == 1 ? "1 card" : "\(pairs.count) cards"
            return foldedCount > 0 ? "\(cards), \(foldedCount) folded" : cards
        }
    }

    /// The two collapse passes and the count, in one place.
    public static func collapsedCards(
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
    private static func askKey(_ interaction: InlineInteraction) -> String {
        "\(interaction.kind.rawValue)|\(interaction.target)|\(interaction.mode?.rawValue ?? "")"
    }

    /// A choice made in Providers is read from its checked routing snapshot.
    public static func selectionForReturn(_ interaction: InlineInteraction, dataRoot: URL) async throws -> String? {
        guard interaction.kind == .modelChoice else { return interaction.target }
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let snapshot = try await router.checkedRoutingSnapshotReadOnly()
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

    public static func beginControl(
        _ id: String, sessionID: String, dataRoot: URL
    ) async throws -> (interaction: InlineInteraction, descriptor: InlineInteractionDescriptor)? {
        guard let current = await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot) else { return nil }
        let control = descriptor(for: current, dataRoot: dataRoot)
        _ = try await begin(id: id, sessionID: sessionID, expectedRevision: current.revision, dataRoot: dataRoot)
        return (current, control)
    }

    public static func runControl(
        _ interaction: InlineInteraction, descriptor: InlineInteractionDescriptor,
        sessionID: String, value: String?, choice: String?, values: [String: String],
        fullSetup: Bool, controls: any InlineInteractionControlPort, dataRoot: URL,
        present: @MainActor (InlineInteractionDescriptor.Control) -> Void,
        watch: @MainActor () -> Void, refresh: @MainActor () async -> Void
    ) async {
        func finish(selection: String?, error: String? = nil, note: String? = nil) async {
            await completeControl(interaction.id, sessionID: sessionID, selection: selection,
                scope: nil, setupError: error, note: note, dataRoot: dataRoot)
            await refresh()
        }
        switch descriptor.control {
        case .internetAccounts:
            watch()
            present(.internetAccounts)
        case .chromeSetup:
            if !controls.chromeControlEnabled, !controls.fullMacGrantIsActive {
                await controls.enableChromeControl()
            }
            if await completeIfVerified(id: interaction.id, sessionID: sessionID, dataRoot: dataRoot) {
                await refresh()
                return
            }
            if let error = await controls.setUpChromeControl() {
                await finish(selection: "chrome", error: error)
            } else {
                watch()
            }
        case .connectorManualToken where !fullSetup && !values.isEmpty:
            let outcome = await controls.saveConnectorCredentials(
                connector: descriptor.target, values: values, dataRoot: dataRoot)
            await finish(selection: descriptor.target, error: outcome.error, note: outcome.note)
        case .macPermissionGrant:
            if await grantPermissions(interaction, controls: controls, dataRoot: dataRoot) { watch() }
            else { await finish(selection: interaction.target) }
        case .capabilityFlag:
            if await setCapabilityFlag(interaction, controls: controls, dataRoot: dataRoot) { watch() }
            else { await finish(selection: interaction.target) }
        case .providerAPIKey:
            let target = InlineInteractionRegistry.canonicalProviderID(interaction.target)
            let outcome = await saveAPIKey(interaction, value: value, controls: controls, dataRoot: dataRoot)
            await finish(selection: target, error: outcome.error, note: outcome.note)
        case .providerGroupModel:
            if choice == InlineInteractionRegistry.persistentChoiceOptionID {
                present(.providerGroupModel)
            } else if let picked = choice, !picked.isEmpty {
                await completeModelChoice(interaction, target: descriptor.target, picked: picked,
                    sessionID: sessionID, controls: controls, dataRoot: dataRoot)
                await refresh()
            } else {
                present(.providerGroupModel)
            }
        case .inlineChoice:
            await finish(selection: choice)
        case .pairDevice, .connectorManualToken, .connectorOAuth, .trustPostureRequired:
            present(descriptor.control)
        case .unavailable, .unknown:
            break
        }
    }

    public static func settleOrReopen(_ id: String, sessionID: String, dataRoot: URL) async {
        if !(await completeIfVerified(id: id, sessionID: sessionID, dataRoot: dataRoot)),
           let current = await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot),
           case .running = current.state {
            _ = try? await returnToPending(current, sessionID: sessionID, dataRoot: dataRoot)
        }
    }

    public static func verifyOnReturn(_ pending: [String: String], dataRoot: URL, refresh: @MainActor () async -> Void) async {
        for (id, sessionID) in pending {
            guard let current = await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot),
                  current.state.isOpen else { continue }
            if current.kind == .connector {
                await settleOrReopen(id, sessionID: sessionID, dataRoot: dataRoot)
                await refresh()
                continue
            }
            let selection = try? await selectionForReturn(current, dataRoot: dataRoot)
            _ = try? await complete(id: id, sessionID: sessionID, selection: selection,
                scope: current.kind == .modelChoice ? .persistent : nil, dataRoot: dataRoot)
        }
    }

    public static func grantPermissions(
        _ interaction: InlineInteraction,
        controls: any InlineInteractionControlPort,
        dataRoot: URL
    ) async -> Bool {
        // Every capability in the chain, in one grant — the card asked once.
        // The need carries the axis the blocked call wanted, so each capability
        // gets THAT axis and no more, which is exactly what the card's scope
        // lines told the person they were allowing.
        let mode = interaction.mode
        var categories: [String] = []
        for capability in interaction.allTargets {
            if let bundleID = SystemAppleScriptAdapter.automationTarget(capability) {
                _ = await SystemAppleScriptAdapter.automationPermission(bundleID: bundleID, ask: true)
                continue
            }
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
                nativeLog("[interaction] grant failed for \(capability): \(error)")
            }
        }
        if !categories.isEmpty {
            await controls.grantMacControlCategories(categories, dataRoot: dataRoot, logTag: "interaction")
        }
        // macOS is asked only for what the app side actually allowed: a Trust
        // write refused outside Full Mac never leads to a macOS prompt.
        let granted = (try? await MacIntegrationPermissionStore.shared.currentChecked()) ?? [:]
        let allowed = interaction.allTargets.filter { capability in
            InlineInteractionRegistry.isMacControlCategory(capability)
                ? InlineInteractionRegistry.macControlCategoryAllowed(capability, dataRoot: dataRoot)
                : (granted[capability]?.read ?? false) || (granted[capability]?.write ?? false)
        }
        if await platform.askMacOSForCard(allowed, mode: mode) {
            return true
        }

        // The store is re-read by the resolver; a capability that did not take
        // fails the card rather than settling it.
        return false
    }

    public static func setCapabilityFlag(
        _ interaction: InlineInteraction,
        controls: any InlineInteractionControlPort,
        dataRoot: URL
    ) async -> Bool {
        // The ONE field the card named, patched into the locked generation
        // through the same helper `interaction_act` uses. Sending back the
        // whole cached multimodal block overwrote any other switch the person
        // had flipped since that cache was read.
        guard let flag = InlineInteractionRegistry.capabilityFlags[interaction.target] else {
            return false
        }
        await controls.grantCapabilityFlag(policyKey: flag.policyKey, dataRoot: dataRoot, logTag: "interaction")
        if flag.id != "screen_capture" || controls.screenCaptureEnabled,
           await platform.askMacOSForCard([flag.id], mode: nil) {
            return true
        }
        // Trust is re-read by the resolver; the tap is not the authority.
        return false
    }

    public static func saveAPIKey(
        _ interaction: InlineInteraction, value: String?, controls: any InlineInteractionControlPort, dataRoot: URL
    ) async -> (error: String?, note: String?) {
        let key = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let target = InlineInteractionRegistry.canonicalProviderID(interaction.target)
        if key.isEmpty, let signIn = InlineInteractionRegistry.providerSignIn(for: target) {
            return (await controls.signInProvider(signIn, dataRoot: dataRoot), nil)
        }
        if target == "anthropic_oauth_direct" || !key.isEmpty {
            return await controls.saveProviderCredential(provider: target, value: key)
        }
        return (nil, nil)
    }

    public static func saveModelSelection(target: String, picked: String, controls: any InlineInteractionControlPort) async throws {
        guard let group = ProviderSurfaceGroups.all.first(where: { $0.id == target }) else {
            throw ProviderRoutingError.invalidRequest
        }
        let option = InlineInteractionRegistry.splitModelOptionID(picked)
        try await controls.saveProviderGroupSelection(group: group, providerID: option?.providerID,
            model: option?.modelID ?? picked)
    }

    public static func completeModelChoice(
        _ interaction: InlineInteraction, target: String, picked: String, sessionID: String,
        controls: any InlineInteractionControlPort, dataRoot: URL
    ) async {
        let scope = interaction.primaryScope ?? .persistent
        if scope == .persistent {
            do {
                try await saveModelSelection(target: target, picked: picked, controls: controls)
            } catch {
                await completeControl(interaction.id, sessionID: sessionID, selection: picked,
                    scope: scope, setupError: error.localizedDescription, note: nil, dataRoot: dataRoot)
                return
            }
        }
        await completeControl(interaction.id, sessionID: sessionID, selection: picked,
            scope: scope, setupError: nil, note: nil, dataRoot: dataRoot)
    }

    public static func settleVerifiedControls(
        _ waiting: [String: String], dataRoot: URL, didSettle: @MainActor (String) -> Void
    ) async -> Bool {
        for (id, sessionID) in waiting {
            guard await completeIfVerified(id: id, sessionID: sessionID, dataRoot: dataRoot) else { return false }
            didSettle(id)
        }
        return true
    }

    /// Complete against the session captured at the tap; a control can outlive
    /// a conversation switch, and a refusal must not disappear into UI refresh.
    public static func completeControl(
        _ id: String, sessionID: String, selection: String?, scope: InlineInteraction.Scope?,
        setupError: String?, note: String?, dataRoot: URL
    ) async {
        do {
            _ = try await complete(id: id, sessionID: sessionID, selection: selection,
                scope: scope, setupError: setupError, note: note, dataRoot: dataRoot)
        } catch {
            nativeLog("[interaction] complete failed for \(id): \(error)")
        }
    }
}

extension InlineInteractionResolver {
    @MainActor
    public final class GrantWatch {
        public init() {}
        private var dataRoot: URL { PersistenceCore.defaultDataRoot() }
        private var grantWatches: [String: String] = [:]
        private var grantWatchTask: Task<Void, Never>?

        /// A card that sent the person to System Settings settles by itself when
        /// the grant lands: re-checked the moment the app becomes active again and
        /// every few seconds while it waits, for two minutes. Nothing is written
        /// until the owner says yes; at the cap the card is completed once, which
        /// fails it honestly, with its retry, if the grant never came.
        public func watchUntilGranted(_ id: String, sessionID: String, refresh: @escaping @MainActor () async -> Void) {
            grantWatches[id] = sessionID
            guard grantWatchTask == nil else { return }
            grantWatchTask = Task { [weak self] in
                var wasActive = InlineInteractionResolver.platform.applicationIsActive
                for tick in 1...120 {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    let active = InlineInteractionResolver.platform.applicationIsActive
                    let cameBack = active && !wasActive
                    wasActive = active
                    guard cameBack || tick % 3 == 0 else { continue }
                    if await self.recheckGrants(final: false, refresh: refresh) {
                        self.grantWatchTask = nil
                        return
                    }
                }
                await self?.recheckGrants(final: true, refresh: refresh)
                self?.grantWatchTask = nil
            }
        }

        /// True when nothing is left waiting.
        @discardableResult
        private func recheckGrants(final: Bool, refresh: @MainActor () async -> Void) async -> Bool {
            for (id, sessionID) in grantWatches {
                if final {
                    _ = try? await InlineInteractionResolver.complete(
                        id: id, sessionID: sessionID, dataRoot: dataRoot
                    )
                    grantWatches[id] = nil
                } else if await InlineInteractionResolver.completeIfVerified(
                    id: id, sessionID: sessionID, dataRoot: dataRoot
                ) {
                    grantWatches[id] = nil
                }
            }
            await refresh()
            return grantWatches.isEmpty
        }

    }
}
