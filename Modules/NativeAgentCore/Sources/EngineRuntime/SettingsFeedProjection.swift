import Foundation
import CoreFoundation
import AppToolRuntime
import SlackBot
import NativeAgentShared
import TrustCenter
import Privacy
// Blueprint: | `SettingsFeedProjection.swift` | Ordered settings-group admission, off-main projection and equal-value suppression |

public actor SettingsFeedProjection {
    private enum Change: Sendable {
        case providers(ProviderSettingsFace)
        case trust(TrustPolicy?, String?)
        case persona(PersonalityProfile?, [PersonaDocSpec], String?, String?)
        case connectors(Result<SlackIngressPolicy, Error>?)
        case permissions([String: String], String?, Bool)
        case dock(String, PermissionSettingsFace.Dock?)
        case preferences([String: PartFace.Value], [String: String], [String: PartFace.Value])
        case search(String?, String?)
        case updates(SoftwareUpdateSettingsFace.Source)
        case delivery(FaceDeliveryReceipt)
    }

    private let feed: FaceFeedSource
    private nonisolated let admission: AsyncStream<Change>.Continuation
    private var current = SettingsFace()
    private var sent: SettingsFace?
    private var declaredPreferences: [String: PartFace.Value] = [:]

    public init(feed: FaceFeedSource) {
        self.feed = feed
        let (changes, admission) = AsyncStream.makeStream(of: Change.self)
        self.admission = admission
        Task { [weak self] in
            for await change in changes {
                if let self { await self.apply(change) }
                else if case .delivery(let receipt) = change { await receipt.close() }
            }
        }
    }

    deinit { admission.finish() }

    /// One drain preserves committed owner order while feed delivery suspends.
    private func apply(_ change: Change) async {
        switch change {
        case .providers(let value): current.providers = value
        case .trust(let policy, let issue):
            current.trust.policy = policy
            current.trust.issue = issue.map(NativeAppSecretRedactor.redactText)
            projectTrust()
        case .persona(let profile, let documents, let profileIssue, let documentsIssue):
            current.persona.profile = profile
            current.persona.documents = documents
            current.persona.profileIssue = profileIssue.map(NativeAppSecretRedactor.redactText)
            current.persona.documentsIssue = documentsIssue.map(NativeAppSecretRedactor.redactText)
            current.persona.displayName = profileIssue == nil ? profile.map { NativeAgentIdentity.displayName($0.name) } ?? "" : ""
        case .connectors(let policy):
            var value = ConnectorSettingsFace()
            switch policy {
            case .success(let policy):
                value.slack = .init(allowedChannelIds: policy.allowedChannelIds, allowedUserIds: policy.allowedUserIds,
                                    requireMention: policy.requireMention)
            case .failure(let error): value.slackIssue = NativeAppSecretRedactor.redactText(error.localizedDescription)
            case nil: break
            }
            current.connectors = value
        case .permissions(let statuses, let issue, let reading):
            current.permissions.systemStatuses = statuses
            current.permissions.issue = issue.map(NativeAppSecretRedactor.redactText)
            current.permissions.isReading = reading
        case .dock(let key, let value):
            current.permissions.docks[key] = value.map { .init(line: NativeAppSecretRedactor.redactText($0.line), highlight: $0.highlight) }
        case .preferences(let values, let issues, let declared):
            current.preferences = values
            current.preferenceIssues = issues.mapValues(NativeAppSecretRedactor.redactText)
            current.hasReadPreferences = true
            declaredPreferences = declared
            projectTrust()
        case .search(let value, let issue):
            current.searchURL = value
            current.searchIssue = issue.map(NativeAppSecretRedactor.redactText)
        case .updates(let value):
            current.updates = .init(source: .init(availableVersion: value.availableVersion, canCheck: value.canCheck,
                automaticChecks: value.automaticChecks, failure: value.failure.map(NativeAppSecretRedactor.redactText),
                unavailable: value.unavailable))
        case .delivery(let receipt): await receipt.complete(); return
        }
        if sent != current {
            sent = current
            await feed.post(current, at: .settings)
        }
    }

    private func projectTrust() {
        guard let policy = current.trust.policy else {
            current.trust.effectiveMacControlPolicy = nil
            current.trust.word = current.trust.issue == nil ? "Reading Trust…" : "Trust unavailable"
            current.trust.activePreset = nil
            current.trust.fullMacGrantIsActive = nil
            return
        }
        current.trust.effectiveMacControlPolicy = TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(policy)
        current.trust.fullMacGrantIsActive = TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy)
        guard case .string(let access)? = current.preferences["chatFileAccess"] else {
            current.trust.word = current.hasReadPreferences ? "Trust unavailable" : "Reading Trust…"
            current.trust.activePreset = nil
            return
        }
        let mode = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy, fallback: access)
        let preset = MobileTrustAction.Preset.matching(policy: policy, accessMode: mode)
        current.trust.word = preset?.title ?? "Custom Trust"
        current.trust.activePreset = preset?.rawValue
    }

    public nonisolated func updateProviders(_ value: ProviderSettingsFace) { admission.yield(.providers(value)) }
    public nonisolated func updateTrust(policy: TrustPolicy?, issue: String?) { admission.yield(.trust(policy, issue)) }
    public nonisolated func updatePersona(profile: PersonalityProfile?, documents: [PersonaDocSpec], profileIssue: String?, documentsIssue: String?) {
        admission.yield(.persona(profile, documents, profileIssue, documentsIssue))
    }
    public nonisolated func updateConnectors(_ value: Result<SlackIngressPolicy, Error>?) { admission.yield(.connectors(value)) }
    public nonisolated func updatePermissions(statuses: [String: String], issue: String?, isReading: Bool) {
        admission.yield(.permissions(statuses, issue, isReading))
    }
    public nonisolated func updateDock(_ value: PermissionSettingsFace.Dock?, capability: String) { admission.yield(.dock(capability, value)) }
    public nonisolated func updatePreferences(_ values: [String: PartFace.Value], issues: [String: String], declared: [String: PartFace.Value]) {
        admission.yield(.preferences(values, issues, declared))
    }
    public nonisolated func updateSearch(_ value: String?, issue: String?) { admission.yield(.search(value, issue)) }
    public nonisolated func updateUpdates(_ value: SoftwareUpdateSettingsFace.Source) { admission.yield(.updates(value)) }

    public nonisolated func deliverFaces() async throws {
        let receipt = FaceDeliveryReceipt()
        if case .terminated = admission.yield(.delivery(receipt)) { await receipt.close() }
        try await receipt.wait()
    }

    public func useDeclaredPreference(_ key: String) throws {
        guard let value = declaredPreferences[key] else {
            throw PartCallError(code: "preference_default_unavailable", message: "This preference has no declared default. Set it explicitly in Settings.")
        }
        try setPreference(value, key: key)
    }

    public func setPreference(_ value: PartFace.Value, key: String) throws {
        if storedPreference(key, equals: value) { return }
        switch value {
        case .bool(let value):
            UserDefaults.standard.set(value, forKey: key)
        case .string(let value):
            UserDefaults.standard.set(value, forKey: key)
        case .double(let value):
            UserDefaults.standard.set(value, forKey: key)
        case .int(let value):
            UserDefaults.standard.set(value, forKey: key)
        case .null:
            if UserDefaults.standard.object(forKey: key) != nil { UserDefaults.standard.removeObject(forKey: key) }
        case .array, .object:
            throw PartCallError(code: "preference_type_unsupported", message: "This preference requires a scalar value.")
        }
    }

    private func storedPreference(_ key: String, equals value: PartFace.Value) -> Bool {
        let saved = UserDefaults.standard.object(forKey: key)
        switch value {
        case .bool(let expected):
            guard let number = saved as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue == expected
        case .double(let expected):
            guard let number = saved as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue == expected
        case .int(let expected):
            guard let number = saved as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue == Double(expected)
        case .string(let expected): return saved as? String == expected
        case .null: return saved == nil
        case .array, .object: return false
        }
    }
}
