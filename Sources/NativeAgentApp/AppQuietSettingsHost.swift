import ActivityWatch
import AppToolRuntime
import Cognition
import Context
import Foundation
import PersistenceCore
import NativeAgentShared
import ProviderRouting
import Research
import TrustCenter
import TriggerScheduler
import MemoryV2
import Onboarding
import DeviceSync
import EngineRuntime
// Blueprint: | `AppQuietSettingsHost.swift` | Owner-declared settings; phone rows use signed requests, with no Mac copies |

/// Settings adapters must share the UI's observed model actions.
@MainActor
class AppQuietSettingsHost: QuietLowerOnlySettingsHost {
    let appModel: AppModel
    let presentation: BodyFacePresentation?

    init(_ appModel: AppModel) { self.appModel = appModel; presentation = nil }
    init(_ appModel: AppModel, presentation: BodyFacePresentation?) { self.appModel = appModel; self.presentation = presentation }

    var dataRootOverride: URL? { appModel.engine.dataRoot }
    var trustPolicy: TrustPolicy? { appModel.engine.trust.policy }
    var personality: PersonalityProfile? { appModel.engine.persona.profile }
    var personalityError: String? { appModel.engine.persona.profileError }
    var dreamError: String? { appModel.dreamError }
    var chatModel: String {
        get { appModel.chatModel }
        set { appModel.chatModel = newValue }
    }
    var chatReasoningEffort: String {
        get { appModel.chatReasoningEffort }
        set { appModel.chatReasoningEffort = newValue }
    }
    var chatFastMode: Bool {
        get { appModel.chatFastMode }
        set { appModel.chatFastMode = newValue }
    }
    var chatFileAccess: String { appModel.chatFileAccess }
    var chatProvider: String { appModel.chatProvider }
    var searchServiceURL: String { appModel.searxngBaseURL }

    var platformSettings: [QuietSetting] {
        let model = appModel
        var rows = [
            QuietSetting(
                id: "phone.settings", page: "pairing", label: "iPhone settings", kind: .text,
                note: """
                    Read this directory while the paired phone app is open. It returns phone-owned setting ids, current values, kinds and choices; use those \
                    ids with setting.get/set. Enabling a phone sense, place or Lock Screen task names asks on the phone. Saving a new location and deleting \
                    a place use the phone's Places controls.
                    """,
                readsAnotherDevice: true,
                read: { _ in
                    let result = try await self.phoneSettingsRequest(kind: .settingsRead, params: [:])
                    guard let rows = result.values["settings"] else {
                        throw QuietSettingError.unavailable(
                            "The phone returned no settings directory. Reopen NativeAgent on the paired iPhone and read phone.settings again."
                        )
                    }
                    // Validate the current wire shape before presenting it.
                    _ = try self.decodePhoneSettings([MobileAppSetting].self, from: rows)
                    return .string(rows)
                }
            ),
            QuietSetting(
                id: "settings.shotgun_shortcut", page: "settings", label: "Shotgun shortcut", kind: .choice,
                choices: ShotgunShortcut.allCases.map(\.rawValue),
                note: "The keys that open Shotgun, saved and registered at once; if macOS refuses them, the choice stays saved and I say why.",
                read: { _ in
                    guard let saved = UserDefaults.standard.object(forKey: ShotgunShortcut.storageKey) else {
                        return .string(ShotgunShortcut.optionSpace.rawValue)
                    }
                    guard let raw = saved as? String, ShotgunShortcut(rawValue: raw) != nil else {
                        throw QuietSettingError.unavailable("The saved Shotgun shortcut is invalid. Choose a shortcut in Settings to repair it.")
                    }
                    return .string(raw)
                },
                write: { _, value, _ in
                    guard case .string(let raw) = value, let shortcut = ShotgunShortcut(rawValue: raw) else {
                        throw QuietSettingError.badValue("Choose a listed Shotgun shortcut.")
                    }
                    try ShotgunController.shared.setShortcut(shortcut)
                }
            ).watchingDefaults(ShotgunShortcut.storageKey),
            QuietSetting(
                id: "memories.meaning_based", page: "settings", label: "Meaning-based memory", kind: .boolean,
                note: """
                    On, I find memories by what they mean with a model on this Mac, off by matching words; either change re-indexes my saved \
                    memories, and the switch alone does not prove the model loaded.
                    """,
                read: .meaningBasedMemory,
                write: { _, value, context in
                    let enabled = try QuietSettings.boolValue(value, "Meaning-based memory")
                    try await model.engine.memory.toggleEmbeddings(enabled)
                    guard let snapshot = await model.engine.memory.readEmbeddingSnapshot() else {
                        throw QuietSettingError.unavailable("Memory's embedding runtime became unavailable after saving. Inspect Memory before another change.")
                    }
                    context.detail.record("effective_backend", .string(snapshot.effectiveBackend))
                    if let problem = snapshot.lastLoadError { context.detail.record("model_load_error", .string(problem)) }
                }
            ).ownedByMind(),
            QuietSetting(
                id: "settings.show_tour", page: "settings", label: "Show the tour", kind: .boolean,
                read: { _ in
                    guard let saved = UserDefaults.standard.object(forKey: "nativeagent.showTour") else { return .bool(false) }
                    guard let enabled = saved as? Bool else {
                        throw QuietSettingError.unavailable("The saved tour switch is not a Boolean. Use Take the tour in Settings to repair it.")
                    }
                    return .bool(enabled)
                },
                write: { _, value, _ in
                    let enabled = try QuietSettings.boolValue(value, "Show the tour")
                    UserDefaults.standard.set(enabled, forKey: "nativeagent.showTour")
                    if enabled {
                        if let presentation = self.presentation { try await presentation.present(.replayTour) }
                        else { OnboardingTourReplay.shared.requestReplay() }
                    }
                }
            ).watchingDefaults("nativeagent.showTour"),
            QuietSetting(
                id: "providers.credentials", page: "providers", label: "Provider sign-ins and API keys", kind: .text,
                note: "Credentials never go through chat. Use the account's secure setup control.",
                read: { _ in
                    .string("""
                        On the Mac, Providers → Accounts → Add key or Sign in opens protected entry directly. \
                        Enter keys and sign in only there; the phone and Telegram carry no credential entry.
                        """)
                }
            ),
            QuietSetting(
                id: "telegram.credentials", page: "telegram", label: "Telegram bot token", kind: .text,
                note: "Tokens never go through chat or the phone settings projection.",
                read: { _ in .string("On the Mac, open Telegram → Bot token to add or replace the token in its secure field.") }
            )
        ]
        // Read and choose accounts through the provider owner so the adapter keeps no second account state. Only a connected account
        // (`auth_status.eligible`) has a default model to choose; an account that is not connected, or whose configuration is broken,
        // has no setting here, and its own status and repair stay on its account row in the Providers page's content.
        for account in model.engine.providers.connections where account.auth_status.eligible {
            let id = account.provider_id
            @MainActor @Sendable func checkedProvider() async throws -> ProviderInfo {
                let provider = try await model.engine.providers.provider(id: id)
                guard provider.auth_status.state != "unavailable" else {
                    throw QuietSettingError.unavailable("""
                        \(id)'s provider configuration is unavailable: \(provider.auth_status.detail) Repair providers/\(id).json in the app data folder, \
                        then reload Providers before reading or changing its default model.
                        """)
                }
                // Choices are available when this credential has a list to choose from; a note beside the list is information, not a fault.
                guard !provider.models.isEmpty else {
                    let cause = provider.models_note.map { ": \($0)" } ?? "."
                    throw QuietSettingError.unavailable(
                        "\(id)'s model choices are unavailable\(cause) Refresh its models in Providers before reading or changing its default model."
                    )
                }
                return provider
            }
            rows.append(QuietSetting(
                id: "providers.\(id).default_model", page: "providers", label: "\(account.display_name) default model", kind: .choice,
                // The choices are the rows this slot may hold (`ModelSlot.mayHold`): offered ones, and the saved default itself.
                liveChoices: { _ in
                    let provider = try await checkedProvider()
                    return provider.models.filter { ModelSlot.mayHold($0.id, row: $0, savedInSlot: provider.default_model) }.map(\.id)
                },
                note: "The account sheet's default model. Empty means no default has been saved. Does not change credentials or surface overrides.",
                read: { _ in
                    let provider = try await checkedProvider()
                    guard let saved = provider.default_model else { return .string("") }
                    return .string(saved)
                },
                write: { _, value, _ in
                    let provider = try await checkedProvider()
                    guard case .string(let wanted) = value else { throw QuietSettingError.badValue("Choose one of this account's offered models.") }
                    let row = provider.models.first { $0.id == wanted }
                    guard ModelSlot.mayHold(wanted, row: row, savedInSlot: provider.default_model) else {
                        if row != nil {
                            throw QuietSettingError.unavailable(ModelSlot.refusal(note: provider.models_note, accountName: provider.display_name))
                        }
                        throw QuietSettingError.badValue("Choose one of this account's offered models.")
                    }
                    // Patch only the model through ProviderRouting; this control has no credential or auth-mode input.
                    _ = try await model.engine.providers.routing.configureProvider(id: id, config: .object(["default_model": .string(wanted)]))
                    _ = await model.engine.providers.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
                }
            ))
        }
        return rows
    }

    private func decodePhoneSettings<Value: Decodable>(_ type: Value.Type, from body: String) throws -> Value {
        do { return try JSONDecoder().decode(type, from: Data(body.utf8)) }
        catch {
            throw QuietSettingError.unavailable("""
                The phone's settings reply could not be decoded: \(error.localizedDescription). Install the matching companion revision, reopen it and read \
                phone.settings again.
                """)
        }
    }

    private func phoneSettingsRequest(kind: PhoneRequest.Kind, params: [String: String]) async throws -> PhoneRequestResult {
        guard let sync = appModel.engine.deviceSync else {
            throw QuietSettingError.unavailable(
                "Phone sync is not running in this app. Open Connectors → iPhone and repair the connection."
            )
        }
        let count = try PairedPhoneStore.pairedCountChecked(at: sync.dataRoot.appendingPathComponent("paired_phones.json"))
        guard count == 1 else {
            throw QuietSettingError.unavailable(count == 0
                ? "No phone is paired. Open Connectors → iPhone to pair it."
                : "More than one phone is paired; this request channel cannot select one safely. Use that phone's NativeAgent Settings.")
        }
        let request = PhoneRequest(kind: kind, params: params, waitSeconds: kind == .settingsRead ? 20 : 60)
        // This settings port holds no enclosing deadline; the request owns its expiry.
        let reply = try await sync.bridge.phoneRequests.request(request, deadline: nil)
        let result = try decodePhoneSettings(PhoneRequestResult.self, from: reply.text)
        guard result.requestID == request.id, result.status == .completed else {
            throw QuietSettingError.unavailable((result.message ?? "The phone returned \(result.status.rawValue).")
                + " No completed setting change is confirmed. Reopen NativeAgent on the paired iPhone and read phone.settings before repeating a change.")
        }
        return result
    }

    private func readPhoneSetting(_ id: String) async throws -> MobileAppSetting {
        let reply = try await phoneSettingsRequest(kind: .settingsRead, params: ["id": id])
        guard let body = reply.values["setting"] else {
            throw QuietSettingError.unavailable(
                "The phone returned no setting row. Reopen NativeAgent on the paired iPhone and read phone.settings again."
            )
        }
        let row = try decodePhoneSettings(MobileAppSetting.self, from: body)
        guard row.id == id else {
            throw QuietSettingError.unavailable(
                "The phone answered for a different setting. Reopen NativeAgent on the paired iPhone and read phone.settings again."
            )
        }
        return row
    }

    func phoneSetting(id: String) async throws -> QuietSetting? {
        if id == "phone.settings" { return platformSettings.first { $0.id == id } }
        let descriptor = try await readPhoneSetting(id)
        guard let kind = QuietSetting.Kind(rawValue: descriptor.type) else {
            throw QuietSettingError.unavailable(
                "The phone returned an unknown setting kind. Install the matching companion revision, reopen it and read phone.settings again."
            )
        }
        let read: @MainActor @Sendable (any QuietSettingsHost) async throws -> JSONValue = { _ in
            let row = try await self.readPhoneSetting(id)
            if let reason = row.unavailableReason { throw QuietSettingError.unavailable(reason) }
            guard let value = row.value else {
                throw QuietSettingError.unavailable(
                    "The phone supplied no value. Reopen NativeAgent on the paired iPhone and read phone.settings for its owner's errors."
                )
            }
            if kind == .boolean {
                guard value == "true" || value == "false" else {
                    throw QuietSettingError.unavailable(
                        "The phone supplied an invalid switch value. Install the matching companion revision, reopen it and read phone.settings again."
                    )
                }
                return .bool(value == "true")
            }
            if kind == .list { return .array(value.split(separator: "\n").map { .string(String($0)) }) }
            return .string(value)
        }
        let write: (@MainActor @Sendable (any QuietSettingsHost, JSONValue, QuietSettingWrite) async throws -> Void)?
        if descriptor.writable {
            write = { _, value, _ in
                let text: String
                switch value {
                case .bool(let enabled): text = enabled ? "true" : "false"
                case .string(let raw): text = raw
                default: throw QuietSettingError.badValue("Use this phone setting's reported kind and choices.")
                }
                _ = try await self.phoneSettingsRequest(kind: .settingsWrite, params: ["id": id, "value": text])
            }
        } else {
            write = nil
        }
        return QuietSetting(id: id, page: "pairing", label: descriptor.label, kind: kind, choices: descriptor.choices,
            note: """
                Owned by this iPhone. Keep its NativeAgent app open for reads and changes. Consent increases ask on the phone; a timeout \
                confirms no outcome.
                """,
            readsAnotherDevice: true, read: read, write: write)
    }

    func saveChatBrainDefaultsFailure() async -> String? {
        let result = await appModel.saveChatBrainDefaults()
        switch result {
        case .saved, .unchanged: return nil
        case .failed: return result.agentMessage
        }
    }

    func saveMacControlPolicy(
        _ policy: MacControlPolicyWireSnapshot,
        comparedTo baseline: MacControlPolicyWireSnapshot,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async throws -> TrustPolicy {
        try await appModel.saveMacControlPolicy(policy, comparedTo: baseline, guardedByLockedPolicy: guardedByLockedPolicy)
    }

    func applySavedTrustPolicy(_ policy: TrustPolicy, status: String) {
        appModel.applySavedTrustPolicy(policy, status: status)
    }

    func saveProviderGroupSelection(
        group: ProviderSurfaceGroup, providerID: String?, model: String?,
        reasoningEffort: String?, serviceTier: String?, clearOverride: Bool
    ) async throws -> ProviderGroupWriteResult {
        try await appModel.engine.saveProviderGroupSelection(
            group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, clearOverride: clearOverride
        )
    }

    func listQuietProviderAccounts() async throws -> [QuietProviderAccount] {
        try await appModel.engine.providers.list().providers.map {
            QuietProviderAccount(providerID: $0.provider_id, authState: $0.auth_status.state,
                                 eligible: $0.auth_status.eligible, models: $0.models,
                                 refusal: ModelSlot.refusal(note: $0.models_note, accountName: $0.display_name))
        }
    }

    func agentAccessMode(from policy: TrustPolicy) -> String {
        TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy)
    }

    func applyTrustPreset(
        _ preset: MobileTrustAction.Preset,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async -> QuietTrustPresetOutcome {
        switch await TrustPolicyPresetAction.apply(
            preset, appModel: appModel, guardedByLockedPolicy: guardedByLockedPolicy
        ) {
        case .confirmationRequired: return .confirmationRequired
        case .applied: return .applied
        case .failed(let detail): return .failed(detail)
        }
    }

    func saveMultimodalPolicy(
        field: String, enabled: Bool,
        guardedByLockedPolicy: @escaping @Sendable ([String: JSONValue]) throws -> Void
    ) async throws -> TrustPolicy {
        do {
            return try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                body: ["multimodalPolicy": [field: enabled]],
                dataRoot: appModel.engine.dataRoot,
                guardedByLockedPolicy: guardedByLockedPolicy)
        } catch {
            appModel.engine.trust.publishPolicy(nil)
            appModel.recordTrustActionFailure("Multimodal policy save failed: \(error.localizedDescription)")
            throw error
        }
    }

    func dreamEnabled() async throws -> Bool { try await appModel.engine.cognitionView.dreamEnabled() }
    func setDreamCycleEnabled(_ enabled: Bool) async -> Bool { await appModel.setDreamCycleEnabled(enabled) }
    func setRemCycleEnabled(_ enabled: Bool) async -> Bool { await appModel.setRemCycleEnabled(enabled) }
    func savePersonalityChecked(_ profile: PersonalityProfile) async throws {
        try await appModel.savePersonalityChecked(profile)
    }
    func patchMemoryPolicy(knowledgeGraphEnabled: Bool?, adaptivePromotion: Bool?) async -> Bool {
        await appModel.patchMemoryPolicy(
            knowledgeGraphEnabled: knowledgeGraphEnabled,
            adaptivePromotion: adaptivePromotion)
    }
    func saveMemoryPolicy(crossSessionRecall: Bool) async {
        await appModel.saveMemoryPolicy(
            crossSessionRecall: crossSessionRecall)
    }

    func setInnerLifeEnabled(_ enabled: Bool) async -> (enabled: Bool, problem: String?) {
        let (state, problem) = await appModel.setInnerLifeEnabled(enabled)
        return (state.enabled, problem)
    }

    /// Use the same runtime setters as Settings and Cognition.
    func setCognitionLane(_ lane: QuietCognitionLane, enabled: Bool) async {
        await lane.setEnabled(enabled, runtime: NativeAgentEngine.liveCognition)
    }
    func setReflectionBudget(_ budget: Int) async {
        await NativeAgentEngine.liveCognition.setReflectionBudget(budget)
    }
    func setContextFlowMode(_ mode: ContextFlowMode) async throws -> ContextFlowMode {
        let status = await NativeAgentEngine.live.contextFlow.setMode(mode)
        guard let effectiveMode = status.effectiveMode else {
            throw QuietSettingError.unavailable(status.unavailableReason ?? "Fluid context is unavailable.")
        }
        return effectiveMode
    }
    /// Pair each key with the same manager call as the Settings switch.
    func setGlobalHotkeyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "globalHotkeyEnabled")
        GlobalHotkey.shared.setEnabled(enabled)
    }

    func savePersonalityName(_ name: String) async -> String? {
        switch await appModel.savePersonalityName(name) {
        case .saved: return nil
        case .refused(let detail), .failed(let detail): return detail
        }
    }

    func saveSearchServiceURL(_ url: String) async throws {
        _ = try await SwiftNativeResearchClient(dataRoot: appModel.engine.dataRoot)
            .saveSearXNGBaseURL(url)
        try await appModel.engine.configuration.readSearXNG(dataRoot: appModel.engine.dataRoot)
    }
    func findSearchService(context: QuietSettingWrite) async throws -> String {
        switch await appModel.autodetectSearXNG() {
        case .found(let baseURL, let gaps):
            if !gaps.isEmpty { context.detail.record("discovery_gaps", .array(gaps.map { .string($0) })) }
            return baseURL
        case .notFound(let detail), .failed(let detail): throw QuietSettingError.unavailable(detail)
        }
    }

    // The Settings face and this door read and switch triggers through the one inbox owner.
    func inboxTriggers() async throws -> [QuietInboxTrigger] {
        try await appModel.engine.inbox.triggers().map {
            QuietInboxTrigger(
                name: $0.name, enabled: $0.enabled)
        }
    }
    func setInboxTrigger(_ name: String, enabled: Bool) async throws {
        try await appModel.engine.inbox.setTrigger(name, enabled: enabled)
    }

    // Activity capture's breadth and keeping, read and saved through the one activity owner; each save is read back.
    var activityTitleCapture: String {
        get async throws {
            let policy = try await appModel.engine.activityWatch.checkedPolicy()
            switch ActivityPolicy.TitleCapture(policy: policy) {
            case .appNamesOnly: return "apps"
            case .windowTitles: return "windows"
            case .windowAndBrowserTitles: return "browsers"
            }
        }
    }
    func setActivityTitleCapture(_ choice: String) async throws {
        let controller = appModel.engine.activityWatch
        let titles: ActivityPolicy.TitleCapture
        switch choice {
        case "apps": titles = .appNamesOnly
        case "windows": titles = .windowTitles
        case "browsers": titles = .windowAndBrowserTitles
        default: throw QuietSettingError.badValue("Choose apps, windows or browsers.")
        }
        guard await controller.apply({ $0 = titles.applied(to: $0) }) else {
            throw QuietSettingError.unavailable(controller.lastError ?? "Activity settings were not saved.")
        }
    }
    var activityRetentionDays: Int { get async throws { try await appModel.engine.activityWatch.checkedPolicy().retentionDays } }
    func setActivityRetentionDays(_ days: Int) async throws {
        let controller = appModel.engine.activityWatch
        await controller.setRetentionDays(days)
        guard try await controller.checkedPolicy().retentionDays == days else {
            throw QuietSettingError.unavailable(controller.lastError ?? "The retention choice was not saved.")
        }
    }
    var activityExclusions: [String] { appModel.engine.activityWatch.removableExclusions }
    func removeActivityExclusion(_ bundleID: String) async throws {
        let controller = appModel.engine.activityWatch
        guard controller.removableExclusions.contains(bundleID) else {
            throw QuietSettingError.unavailable("That exclusion cannot be changed here.")
        }
        await controller.removeExclusion(bundleID: bundleID)
        guard !(try await controller.checkedPolicy().excludedBundleIDs.contains(bundleID)) else {
            throw QuietSettingError.unavailable(controller.lastError ?? "The exclusion was not removed.")
        }
    }
}
