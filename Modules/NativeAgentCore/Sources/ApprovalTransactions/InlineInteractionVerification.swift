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
import Dispatcher
import Browser
import NotificationInbox
// Blueprint: | `InlineInteractionVerification.swift` | Canonical owners alone confirm completion. |
extension InlineInteractionResolver {
    // Re-read canonical owners after controls close so cancellation cannot masquerade as success.
    enum Verification {
        case success(InlineInteraction.Outcome)
        case failure(String)
    }
    /// Rechecks write only verified completion; a grant still in progress must not fail its card.
    @discardableResult
    public static func completeIfVerified(
        id: String,
        sessionID: String,
        expectedRevision: Int? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Bool {
        let current: InlineInteraction
        do {
            // No card remains for this local watch to settle. This retires only the watch; it records no successful effect or outcome.
            guard let found = try await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot) else { return true }
            current = found
        } catch {
            recordControlFailure(id, dataRoot: dataRoot, error: error)
            return false
        }
        guard current.state.isOpen else { return current.state.isTerminal }
        if let expectedRevision, current.revision != expectedRevision { return true }
        guard !Task.isCancelled else { return false }
        guard case .success(let outcome) = await verify(
            current, selection: current.target, scope: nil, dataRoot: dataRoot
        ) else { return false }
        do {
            return try await finish(current, verification: .success(outcome), sessionID: sessionID,
                                    turn: nil, dataRoot: dataRoot).state.outcome != nil
        } catch let error as ResolveError {
            if case .staleRevision = error { return true }
            recordControlFailure(id, dataRoot: dataRoot, error: error)
            return false
        } catch {
            recordControlFailure(id, dataRoot: dataRoot, error: error)
            return false
        }
    }
    /// Project confirmed owner state without writing or resuming; choices stay with controls and Mail reads existing readiness.
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
        guard case .success(let outcome) = await verify(
            interaction, selection: interaction.target, scope: nil, dataRoot: dataRoot,
            checkMail: false
        ) else { return interaction }
        return interaction.settled(outcome, at: interaction.settledAt ?? interaction.createdAt)
    }
    static func verify(
        _ interaction: InlineInteraction,
        selection: String?,
        scope: InlineInteraction.Scope?,
        dataRoot: URL,
        checkMail: Bool = true
    ) async -> Verification {
        switch interaction.kind {
        case .connector:
            if interaction.target == "mail" {
                let readiness = await platform.mailReadiness(root: dataRoot, check: checkMail)
                guard readiness.status == "ready" else {
                    if let next = readiness.next { return .failure(next) }
                    return .failure(readiness.word)
                }
                let summary = "Mail connected" + (readiness.next.map { ". " + $0 } ?? "")
                return .success(.init(selection: "mail", summary: summary))
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
            let target = InlineInteractionRegistry.canonicalConnectorID(interaction.target)
            let records: [InlineInteractionConnectorStatus]
            do { records = try await platform.connectorRecords(root: dataRoot) }
            catch { return .failure(TurnSecretRedactor.redactText(error.localizedDescription)) }
            guard let record = records.first(where: {
                InlineInteractionRegistry.canonicalConnectorID($0.id) == target
            }) else {
                return .failure("\(interaction.title) isn't in Connectors on this Mac.")
            }
            // Telegram configuration proves a saved enabled bot; only a successful poll proves health.
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
                    if try !InlineInteractionRegistry.macControlCategoryAllowed(
                        capability, dataRoot: dataRoot
                    ) {
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
            // A launch-applied grant needs a restart even when its probe already agrees.
            let atLaunch = SystemPermissionPreflight.awaitingLaunch(interaction.allTargets)
            guard atLaunch.isEmpty else {
                let names = InlineInteractionRegistry.englishList(atLaunch.map(\.displayName))
                return .failure("\(names) is on, and it takes effect after I restart: use Restart on this card.")
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
        case .apiKey where interaction.secret != nil:
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
            // Providers readiness, through key or sign-in, must confirm connection; rejected keys cannot settle.
            let target = InlineInteractionRegistry.canonicalProviderID(interaction.target)
            let doors = [target] + [InlineInteractionRegistry.providerSignIn(for: target)?.oauthProviderID]
                .compactMap { $0 }
            let providers: [InlineInteractionProviderStatus]
            do { providers = try await platform.providers() }
            catch { return .failure(TurnSecretRedactor.redactText(error.localizedDescription)) }
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
            let policy: [String: JSONValue]
            do { policy = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicyChecked() }
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
