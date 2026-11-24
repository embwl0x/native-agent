import SenseCore
import Foundation
import MindCore
import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import DeskCore
// Blueprint: | `InlineInteractionVerification.swift` | Canonical owners alone confirm completion. |
extension InlineInteractionCoordinator {
    /// Provider publication and launch recovery re-read the transcript and canonical auth owner. No tap, saved draft or missing row settles an ask.
    public func settleProviderRequests() async {
        let rows: [InboxItemRecord]
        do { rows = try await ForPerson.at(dataRoot).inbox() }
        catch {
            recordControlFailure("provider-requests", error: error)
            return
        }
        for row in rows where row.source == InlineInteractionDelivery.source {
            do {
                let pointer = try InlineInteractionDelivery.Pointer(item: row)
                guard let card = try await interaction(id: pointer.interactionID, sessionID: pointer.sessionID),
                      card.kind == .apiKey, card.secret == nil, card.state.isOpen || card.state.isRetryable else { continue }
                _ = await completeIfVerified(id: card.id, sessionID: pointer.sessionID)
            } catch { recordControlFailure(row.id, error: error) }
        }
    }

    // Re-read canonical owners after controls close so cancellation cannot masquerade as success.
    enum Verification: Sendable {
        case success(InlineInteraction.Outcome)
        case failure(String)
    }
    /// Rechecks write only verified completion; a grant still in progress must not fail its card.
    @discardableResult
    public func completeIfVerified(
        id: String,
        sessionID: String,
        expectedRevision: Int? = nil,
        selection: String? = nil,
        scope: InlineInteraction.Scope? = nil,
        includeRetryable: Bool = false,
        checkMail: Bool = true) async -> Bool {
        let current: InlineInteraction
        do {
            // No card remains for this local watch to settle. This retires only the watch; it records no successful effect or outcome.
            guard let found = try await interaction(id: id, sessionID: sessionID) else { return true }
            current = found
        } catch {
            recordControlFailure(id, error: error)
            return false
        }
        guard current.state.isOpen || (current.state.isRetryable && (includeRetryable || (current.kind == .apiKey && current.secret == nil)))
        else { return current.state.isTerminal }
        if let expectedRevision, current.revision != expectedRevision { return true }
        guard !Task.isCancelled else { return false }
        let picked = selection ?? current.target
        // Every door's check comes here: a model card read back at the group's model as it was raised was not answered.
        if current.kind == .modelChoice, let baseline = current.modelAtStart, picked == baseline { return false }
        guard case .success(let outcome) = await verify(
            current, selection: picked, scope: scope, checkMail: checkMail
        ) else { return false }
        do {
            return try await finish(current, verification: .success(outcome), sessionID: sessionID,
                                    door: "owner_readback", turn: nil).state.outcome != nil
        } catch let error as ResolveError {
            if case .staleRevision = error { return true }
            recordControlFailure(id, error: error)
            return false
        } catch {
            recordControlFailure(id, error: error)
            return false
        }
    }
    /// Before an ask is filed, already-satisfied setup needs no card. Saved cards are read as saved and complete only through the resolver.
    public func verifiedSetupSummary(
        _ interaction: InlineInteraction) async -> String? {
        guard interaction.state.isOpen, interaction.continuationFailure == nil else { return nil }
        switch interaction.kind {
        case .connector, .permission, .apiKey, .capability: break
        default: return nil
        }
        guard case .success(let outcome) = await verify(
            interaction, selection: interaction.target, scope: nil,
            checkMail: false
        ) else { return nil }
        return outcome.summary
    }
    func verify(
        _ interaction: InlineInteraction,
        selection: String?,
        scope: InlineInteraction.Scope?,
        checkMail: Bool = true
    ) async -> Verification {
        switch interaction.kind {
        case .connector:
            return await verifyConnector(interaction, checkMail: checkMail)
        case .permission:
            return await verifyPermission(interaction)
        case .modelChoice:
            return await verifyModelChoice(interaction, selection: selection, scope: scope)
        case .apiKey where interaction.secret != nil:
            // The checked credential and executable identities never visit MainActor; only the credential-free verification returns.
            return await Task.detached { Self.verifySecret(interaction) }.value
        case .apiKey:
            return await verifyProviderConnection(interaction)
        case .capability:
            return await verifyCapability(interaction)
        case .choose:
            guard let picked = selection,
                  let option = interaction.options.first(where: { $0.id == picked })
            else {
                return .failure("That isn't one of the options.")
            }
            return .success(.init(selection: option.id, summary: option.label))
        case .unknown:
            return .failure("This build doesn't know that kind of request.")
        }
    }

    private func verifyConnector(
        _ interaction: InlineInteraction, checkMail: Bool
    ) async -> Verification {
        if interaction.target == "mail" {
            let readiness = await platform.mailReadiness(check: checkMail)
            guard readiness.status == "ready" else {
                if let next = readiness.next { return .failure(next) }
                return .failure(readiness.word)
            }
            let summary = "Mail connected" + (readiness.next.map { ". " + $0 } ?? "")
            return .success(.init(selection: "mail", summary: summary))
        }
        if interaction.target == "chrome" {
            let status: (enabled: Bool, connected: Bool)
            do { status = try await platform.chromeConnectionStatus() }
            catch { return .failure(TurnSecretRedactor.redactText(error.localizedDescription)) }
            guard status.enabled, status.connected else {
                return .failure("Chrome isn't connected yet. "
                    + platform.chromeSteps)
            }
            return .success(.init(selection: "chrome", summary: "Chrome connected"))
        }
        if interaction.target == "iphone" {
            guard let standing = await platform.phoneStanding() else {
                return .failure("Paired iPhone storage is unavailable. Restore access to the paired-phone store before checking setup again.")
            }
            // The card asks for a phone that can approve: its device key paired with the Pair button, not merely a phone that chats.
            guard standing.canApprove else {
                return .failure(standing.line + " Open NativeAgent on the iPhone, then choose Pair here when the codes match.")
            }
            return .success(.init(selection: "iphone", summary: "iPhone can approve"))
        }
        // Read derived connector auth state so a rejected saved token cannot count as connected.
        let target = ConnectorSetup.canonicalID(interaction.target)
        let records: [InlineInteractionConnectorStatus]
        do { records = try await platform.connectorRecords() }
        catch { return .failure(TurnSecretRedactor.redactText(error.localizedDescription)) }
        guard let record = records.first(where: {
            ConnectorSetup.canonicalID($0.id) == target
        }) else {
            return .failure("\(interaction.title) isn't in Connectors on this Mac.")
        }
        // Telegram configuration proves a saved enabled bot; only a successful poll proves health.
        let name = await Task.detached { InlineInteractionRegistry.connectorDisplayName(target, dataRoot: self.dataRoot) }.value
        guard record.authState == "connected"
            || (target == "telegram" && record.authState == "configured" && record.healthStatus != "disabled")
        else {
            return .failure(
                "\(name) still isn't connected."
            )
        }
        return .success(.init(
            selection: target,
            summary: "\(name) connected"
        ))
    }

    private func verifyPermission(
        _ interaction: InlineInteraction) async -> Verification {
        // Verify the entire chain against each capability's owner; integration axes and Trust categories have separate stores.
        let granted: [String: MacIntegrationPermission]
        if interaction.allTargets.contains(where: { MacIntegrationID.all.contains($0) }) {
            do { granted = try await MacIntegrationPermissionStore(dataRoot: dataRoot).currentChecked() }
            catch { return .failure(error.localizedDescription) }
        } else { granted = [:] } // This card has no integration axes to read.
        var missing: [String] = []
        for capability in interaction.allTargets {
            if capability == "applescript" || capability == "automation" {
                return .failure("Automation consent is per app. Request permission with target applescript:<bundle_id>.")
            }
            if InlineInteractionRegistry.isMacControlCategory(capability) {
                do {
                let allowed = try await Task.detached {
                    try InlineInteractionRegistry.macControlCategoryAllowed(capability, dataRoot: self.dataRoot)
                }.value
                if !allowed {
                    missing.append(capability)
                }
                } catch { return .failure(error.localizedDescription) }
                continue
            }
            if !MacIntegrationID.all.contains(capability),
               SystemPermissionPreflight.cardSettingsCapability(capability) != nil { continue }
            let permission = granted[capability]
            // Only the requested axis can settle this need.
            let mode = interaction.mode
            let readOK = (permission?.read ?? false)
            let writeOK = (permission?.write ?? false)
            let allowed: Bool
            switch mode {
            case .read: allowed = readOK
            case .write: allowed = writeOK
            case .readWrite, .none:
                // Both axes must land when the card promises reading and changing, including needs without a mode.
                let promisedRead = MacIntegrationID.supportsRead(capability)
                let promisedWrite = MacIntegrationID.supportsWrite(capability)
                allowed = (!promisedRead || readOK) && (!promisedWrite || writeOK)
            }
            if !allowed { missing.append(capability) }
        }
        guard missing.isEmpty else {
            let names = missing.map { InlineInteractionRegistry.macCapabilityDisplayName($0) }
            // A launch-applied grant's probe can stay denied until the process restarts, so a denial does not prove the switch is off.
            let launchApplied = SystemPermissionPreflight.launchPending(missing)
            let restart = launchApplied.isEmpty ? "" : " If you turned "
                + InlineInteractionRegistry.englishList(launchApplied.map(\.displayName))
                + " on, it takes effect after I restart: use Restart on this card."
            return .failure(
                "Still not allowed: \(InlineInteractionRegistry.englishList(names))." + restart
            )
        }
        if let blocked = await SystemPermissionPreflight.cardBlockReason(
            interaction.allTargets, mode: interaction.mode, requiresLaunch: true
        ) {
            return .failure(blocked)
        }
        let names = interaction.allTargets.map {
            InlineInteractionRegistry.macCapabilityDisplayName($0)
        }
        return .success(.init(
            selection: interaction.target,
            summary: "\(InlineInteractionRegistry.englishList(names)) allowed"
        ))
    }

    private func verifyModelChoice(
        _ interaction: InlineInteraction, selection: String?, scope: InlineInteraction.Scope?) async -> Verification {
        let resolvedScope = scope ?? interaction.primaryScope ?? .persistent
        guard let picked = selection, !picked.isEmpty else {
            return .failure("No model was chosen.")
        }
        guard let qualified = InlineInteractionRegistry.splitModelOptionID(picked) else {
            return .failure("This model choice does not name its account. Choose an account-qualified model in Providers.")
        }
        let model = qualified.modelID
        if resolvedScope == .thisRequestOnly {
            // Request-only binding is verified by construction because the resumed turn carries the named model.
            return .success(.init(
                // Qualified identity preserves the account the person selected.
                selection: picked,
                summary: "Using \(model) for this one",
                scope: .thisRequestOnly
            ))
        }
        // Confirm a permanent choice against Providers' saved routing snapshot before claiming it landed.
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let snapshot: ProviderRoutingSnapshot
        do { snapshot = try await router.checkedRoutingSnapshotReadOnly() }
        catch { return .failure(TurnSecretRedactor.redactText(error.localizedDescription)) }
        let group = ProviderSurfaceGroups.all.first { $0.id == interaction.target }
        let surfaces = group?.surfaces ?? [interaction.target]
        let matched = surfaces.contains { surface in
            ProviderRoutingSurfaceLookup.value(snapshot.preferences, surface)?.model == model
                && ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, surface) == qualified.providerID
        }
        guard matched else {
            return .failure("\(group?.title ?? interaction.target) isn't on \(model) yet.")
        }
        return .success(.init(
            selection: picked,
            summary: "\(group?.title ?? interaction.target) now uses \(model)",
            scope: .persistent
        ))
    }

    private func verifyProviderConnection(
        _ interaction: InlineInteraction) async -> Verification {
        // Readiness belongs to the requested account. Another account cannot satisfy an unchanged API-key route.
        let target = InlineInteractionRegistry.canonicalProviderID(interaction.target)
        let providers: [InlineInteractionProviderStatus]
        do { providers = try await platform.providers() }
        catch { return .failure(TurnSecretRedactor.redactText(error.localizedDescription)) }
        guard let provider = providers.first(where: { $0.providerID == target }) else {
            return .failure("No provider named \(interaction.target).")
        }
        guard provider.eligible, provider.authState == "ready" else {
            return .failure("\(provider.displayName)'s saved connection is not verified yet. Test the connection in Providers on the Mac.")
        }
        let model = provider.defaultModel ?? provider.firstModel
        return .success(.init(
            selection: provider.providerID,
            summary: model.map { "Connected \u{00B7} \($0) ready" } ?? "\(provider.displayName) ready"
        ))
    }

    private func verifyCapability(
        _ interaction: InlineInteraction) async -> Verification {
        // Trust re-read. The flag is the authority; the tap is not.
        guard let flag = InlineInteractionRegistry.capabilityFlags[interaction.target] else {
            return .failure("That isn't a switch this build has.")
        }
        let policy: [String: JSONValue]
        do { policy = try await SwiftNativeTrustCenter(dataRoot: self.dataRoot).loadTrustPolicyChecked() }
        catch { return .failure("Trust policy is unavailable: \(error.localizedDescription)") }
        guard case .object(let block)? = policy[flag.policyBlock],
              block[flag.policyKey] == .bool(true)
        else {
            return .failure("\(flag.displayName) is still off.")
        }
        if let blocked = await platform.cardBlockReason([flag.id], mode: nil) {
            return .failure(blocked)
        }
        return .success(.init(
            selection: flag.id,
            summary: "\(flag.displayName) on"
        ))
    }

    private nonisolated static func verifySecret(_ interaction: InlineInteraction) -> Verification {
        let name = String(interaction.target.dropFirst("secret:".count))
        let kept: Keyring.Entry?
        do { kept = try Keyring.entry(name) }
        catch { return .failure("The keyring could not be read, so whether \(name) is kept is unknown. Try again.") }
        if interaction.secret?.remove == true {
            return kept == nil ? .success(.init(selection: interaction.target, summary: "\(name) removed"))
                : .failure("\(name) is still kept.")
        }
        guard let ask = interaction.secret, let kept, kept.at >= interaction.createdAt else {
            return .failure("\(name) isn't kept yet.")
        }
        do {
            guard try Keyring.granted(kept, hosts: ask.hosts, programs: ask.programs) else {
                return .failure("\(name)'s requested destinations are not granted yet.")
            }
        } catch { return .failure(TurnSecretRedactor.redactText(error.localizedDescription)) }
        return .success(.init(selection: interaction.target, summary: "\(name) kept \u{00B7} for \(ask.line)"))
    }
}
