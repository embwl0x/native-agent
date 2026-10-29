import AuthoredCapabilities
import Experiences
import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace
import ProviderRouting
import TrustCenter
import ToolRegistry
import MacControl
import Transcripts
import Studio
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import Desk
import ChatSessionWork
import AgentConversations
import ChatToolParsing
import DreamREMCycle
import WorkshopExecution
import Dispatcher
import Browser
import NotificationInbox
// Blueprint: | `InlineInteractionVerification.swift` | Real-world card completion verification |
extension InlineInteractionResolver {
    //
    // One rule, six kinds: ask the canonical owner, never the card, and never
    // the transcript. Each of these re-reads live state AFTER the control
    // closed, which is also what makes a cancelled sheet settle as "not done"
    // instead of as success.
    enum Verification {
        case success(InlineInteraction.Outcome)
        case failure(String)
    }
    /// Settle a waiting card ONLY if its owner now says it is done; otherwise
    /// write nothing. For re-checks while the person is away in System
    /// Settings: a grant still in progress must not fail the card under them.
    @discardableResult
    public static func completeIfVerified(
        id: String,
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Bool {
        guard let current = await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot),
              current.state.isOpen
        else { return true }
        guard !Task.isCancelled else { return false }
        guard case .success(let outcome) = await verify(
            current, selection: current.target, scope: nil, dataRoot: dataRoot
        ) else { return false }
        return (try? await finish(
            current, verification: .success(outcome), sessionID: sessionID, dataRoot: dataRoot
        ))?.state.outcome != nil
    }
    /// READ SIDE ONLY. A card whose thing is already done — connected in the
    /// sheet, on the Connectors page, by Agent, before a relaunch — draws as
    /// the receipt its owner would give now. Nothing is written and nothing
    /// resumes: the owner's live state is the answer, every read. Kinds that
    /// need a pick (model, choose) are left to their own controls; Mail reads
    /// macOS's live grant instead of its AppleScript probe.
    public static func liveProjection(
        _ interaction: InlineInteraction,
        dataRoot: URL
    ) async -> InlineInteraction {
        switch interaction.state {
        case .pending, .running, .failed, .declined: break
        default: return interaction
        }
        switch interaction.kind {
        case .connector, .permission, .apiKey, .capability: break
        default: return interaction
        }
        if interaction.kind == .connector, interaction.target == "mail" {
            // Mail's own check is an AppleScript round trip; the cheap read is
            // macOS's live Automation grant (never prompts; Mail not running
            // reads as unknown, so the card stays), plus read access here.
            guard await MacIntegrationPermissionStore(dataRoot: dataRoot).allows(MacIntegrationID.mail, mode: .read),
                  await platform.probeAppleEventApp("Mail") == "granted"
            else { return interaction }
            return interaction.settled(.init(selection: "mail", summary: "Mail connected"),
                                       at: interaction.settledAt ?? interaction.createdAt)
        }
        guard case .success(let outcome) = await verify(
            interaction, selection: interaction.target, scope: nil, dataRoot: dataRoot
        ) else { return interaction }
        return interaction.settled(outcome, at: interaction.settledAt ?? interaction.createdAt)
    }
    static func verify(
        _ interaction: InlineInteraction,
        selection: String?,
        scope: InlineInteraction.Scope?,
        dataRoot: URL
    ) async -> Verification {
        switch interaction.kind {
        case .connector:
            if interaction.target == "mail" {
                let store = MacIntegrationPermissionStore(dataRoot: dataRoot)
                guard await store.allows(MacIntegrationID.mail, mode: .read) else {
                    return .failure("Mail read access is off or unavailable in Trust → Mac → Mail.")
                }
                let result = try? await platform.mailListRecent(input: ["limit": .int(1)])
                guard case .object(let object) = result, object["status"] == .string("completed") else {
                    return .failure("Mail still needs an enabled account and access to its inbox.")
                }
                return .success(.init(selection: "mail", summary: "Mail connected"))
            }
            if interaction.target == "chrome" {
                let status = await platform.chromeConnectionStatus()
                guard status.enabled, status.connected else {
                    return .failure("Chrome isn't connected yet. "
                        + platform.chromeSteps)
                }
                return .success(.init(selection: "chrome", summary: "Chrome connected"))
            }
            if interaction.target == "iphone" {
                guard await platform.pairedPhoneCount() > 0 else {
                    return .failure("No iPhone is paired yet: open NativeAgent on the iPhone, then choose Pair here when the codes match.")
                }
                return .success(.init(selection: "iphone", summary: "iPhone paired"))
            }
            // Connectors' own derived auth state — the same field the
            // Connectors page shows. A pasted-but-invalid token does not read
            // as connected here, which is the point.
            let target = InlineInteractionRegistry.canonicalConnectorID(interaction.target)
            let records = (try? await platform.connectorRecords(root: dataRoot)) ?? []
            guard let record = records.first(where: {
                InlineInteractionRegistry.canonicalConnectorID($0.id) == target
            }) else {
                return .failure("\(interaction.title) isn't in Connectors on this Mac.")
            }
            // Telegram's row says `configured` (a saved, enabled bot) rather
            // than `connected`; with health ok that is its connected.
            // Telegram's row says `configured` (a saved, enabled bot); its health is a
            // separate reading that only a successful poll proves.
            guard record.authState == "connected"
                || (target == "telegram" && record.authState == "configured" && record.healthStatus != "disabled")
            else {
                return .failure(
                    "\(InlineInteractionRegistry.connectorDisplayName(target, dataRoot: dataRoot)) still isn't connected."
                )
            }
            return .success(.init(
                selection: target,
                summary: "\(InlineInteractionRegistry.connectorDisplayName(target, dataRoot: dataRoot)) connected"
            ))
        case .permission:
            // EVERY capability in the chain, re-read from ITS OWN owner. A
            // chain asked once must be granted once — a partial grant is not a
            // settled card.
            //
            // Two owners, not one. MacIntegration capabilities live in the
            // permission store; Trust's Mac Control categories live in
            // `trust/policy.json` behind the posture gate, and before this a
            // card for one of those could never settle because only the store
            // was ever asked.
            let store = MacIntegrationPermissionStore(dataRoot: dataRoot)
            let granted = (try? await store.currentChecked()) ?? [:]
            var missing: [String] = []
            for capability in interaction.allTargets {
                if capability == "applescript" || capability == "automation" {
                    return .failure("Automation consent is per app. Request permission with target applescript:<bundle_id>.")
                }
                if InlineInteractionRegistry.isMacControlCategory(capability) {
                    if !InlineInteractionRegistry.macControlCategoryAllowed(
                        capability, dataRoot: dataRoot
                    ) {
                        missing.append(capability)
                    }
                    continue
                }
                if !MacIntegrationID.all.contains(capability),
                   SystemPermissionPreflight.cardSettingsCapability(capability) != nil { continue }
                let permission = granted[capability]
                // Only the axis that was asked for. A read need settles on
                // read; it does not wait for a write the card never requested,
                // and it is not settled by a write alone.
                let mode = interaction.mode
                let readOK = (permission?.read ?? false)
                let writeOK = (permission?.write ?? false)
                let allowed: Bool
                switch mode {
                case .read: allowed = readOK
                case .write: allowed = writeOK
                case .readWrite, .none:
                    // BOTH axes, because both is what the card said. A
                    // `read_write` need asked for both, and a legacy need with
                    // no mode is drawn as "covering reading and changing" and
                    // granted on both axes — so one axis landing is a partial
                    // grant, and a partial grant is not a settled card.
                    let promisedRead = MacIntegrationID.supportsRead(capability)
                    let promisedWrite = MacIntegrationID.supportsWrite(capability)
                    allowed = (!promisedRead || readOK) && (!promisedWrite || writeOK)
                }
                if !allowed { missing.append(capability) }
            }
            guard missing.isEmpty else {
                let names = missing.map { InlineInteractionRegistry.macCapabilityDisplayName($0) }
                // A launch-applied grant's probe can stay denied until the
                // process restarts, so a denial does not prove the switch is off.
                var seen: Set<SystemPermissionCapability> = []
                let launchApplied = missing.compactMap(SystemPermissionPreflight.cardSettingsCapability).filter {
                    SystemPermissionPreflight.appliesAtLaunch.contains($0) && seen.insert($0).inserted
                }
                let restart = launchApplied.isEmpty ? "" : " If you turned "
                    + InlineInteractionRegistry.englishList(launchApplied.map(\.displayName))
                    + " on, it takes effect only after I restart. Tell me to restart and I will, then Try again here."
                return .failure(
                    "Still not allowed: \(InlineInteractionRegistry.englishList(names))." + restart
                )
            }
            // On in System Settings, but a grant macOS applies only at launch
            // is not this process's until it restarts: the card does not
            // settle on a probe that agrees too early.
            let atLaunch = SystemPermissionPreflight.awaitingLaunch(interaction.allTargets)
            guard atLaunch.isEmpty else {
                let names = InlineInteractionRegistry.englishList(atLaunch.map(\.displayName))
                return .failure(
                    "\(names) is on, and it takes effect only after I restart. "
                    + "Tell me to restart and I will, then Try again here."
                )
            }
            if let blocked = await platform.cardBlockReason(interaction.allTargets, mode: interaction.mode) {
                return .failure(blocked)
            }
            let names = interaction.allTargets.map {
                InlineInteractionRegistry.macCapabilityDisplayName($0)
            }
            return .success(.init(
                selection: interaction.target,
                summary: "\(InlineInteractionRegistry.englishList(names)) allowed"
            ))
        case .modelChoice:
            let resolvedScope = scope ?? interaction.primaryScope ?? .persistent
            guard let picked = selection, !picked.isEmpty else {
                return .failure("No model was chosen.")
            }
            // A pick names the account and the model. A card written before
            // that — or a permanent change read back from Providers — carries
            // the model alone.
            let model = InlineInteractionRegistry.splitModelOptionID(picked)?.modelID ?? picked
            if resolvedScope == .thisRequestOnly {
                // Nothing to read back: the binding IS the resolution, and it
                // is applied to the resumed request rather than stored. It is
                // verified by construction — a model was named, and this turn
                // will run on it.
                return .success(.init(
                    // The QUALIFIED id is carried, so the binding around the
                    // resumed turn runs on the account the person picked.
                    selection: picked,
                    summary: "Using \(model) for this one",
                    scope: .thisRequestOnly
                ))
            }
            // A permanent change was written by Providers' own group save.
            // Read the routing snapshot back and confirm the group actually
            // moved before the card claims it did.
            let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
            guard let snapshot = try? await router.checkedRoutingSnapshotReadOnly() else {
                return .failure("Couldn't read your provider settings back.")
            }
            let group = ProviderSurfaceGroups.all.first { $0.id == interaction.target }
            let surfaces = group?.surfaces ?? [interaction.target]
            let matched = surfaces.contains { surface in
                ProviderRoutingSurfaceLookup.value(snapshot.preferences, surface)?.model == model
            }
            guard matched else {
                return .failure("\(group?.title ?? interaction.target) isn't on \(model) yet.")
            }
            return .success(.init(
                selection: model,
                summary: "\(group?.title ?? interaction.target) now uses \(model)",
                scope: .persistent
            ))
        case .apiKey where interaction.secret != nil:
            // The keyring's own answer: removed; or a value kept since this
            // card was raised that may go everywhere asked.
            let name = String(interaction.target.dropFirst("secret:".count))
            let kept: Keyring.Entry?
            do { kept = try Keyring.entry(name) } catch {
                return .failure("The keyring could not be read, so whether \(name) is kept is unknown. Try again.")
            }
            if interaction.secret?.remove == true {
                return kept == nil ? .success(.init(selection: interaction.target, summary: "\(name) removed"))
                    : .failure("\(name) is still kept.")
            }
            guard let ask = interaction.secret, Keyring.granted(name, hosts: ask.hosts, programs: ask.programs),
                  let kept, kept.at >= interaction.createdAt else {
                return .failure("\(name) isn't kept yet.")
            }
            return .success(.init(selection: interaction.target,
                                  summary: "\(name) kept \u{00B7} for \(ask.line)" + (kept.account.map { " \u{00B7} account \($0)" } ?? "")))
        case .apiKey:
            // The provider's own readiness, as Providers reports it. A key
            // that was typed but rejected is not ready, and does not settle.
            // A provider you sign into counts as connected through either
            // door: the pasted key's own row, or the signed-in account's.
            let target = InlineInteractionRegistry.canonicalProviderID(interaction.target)
            let doors = [target] + [InlineInteractionRegistry.providerSignIn(for: target)?.oauthProviderID]
                .compactMap { $0 }
            let providers = (try? await platform.providers()) ?? []
            let rows = doors.compactMap { id in providers.first { $0.providerID == id } }
            guard let first = rows.first else {
                return .failure("No provider named \(interaction.target).")
            }
            guard let provider = rows.first(where: \.eligible) else {
                return .failure("\(first.displayName) still isn't ready.")
            }
            let model = provider.defaultModel ?? provider.firstModel
            return .success(.init(
                selection: provider.providerID,
                summary: model.map { "Connected \u{00B7} \($0) ready" } ?? "\(provider.displayName) ready"
            ))
        case .capability:
            // Trust re-read. The flag is the authority; the tap is not.
            guard let flag = InlineInteractionRegistry.capabilityFlags[interaction.target] else {
                return .failure("That isn't a switch this build has.")
            }
            let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
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
}
