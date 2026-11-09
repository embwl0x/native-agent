import ActivityWatch
import AuthoredCapabilities
import AppToolRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
import TrustPersistence
// Blueprint: | `EngineFaceActs+SettingsTrust.swift` | Trust and activity acts preserve locked edit admission and publish exact committed policy values |

extension EngineFaceActs {
    func readTrustRevision() async throws -> FaceActReply {
        let policy = try await engine.trust.load()
        return .result(.string(try policy.editRevision()))
    }

    func savePolicy(_ fields: [String: JSONValue], revision: String? = nil) async throws -> FaceActReply {
        let root = engine.dataRoot
        let admission: (@Sendable ([String: JSONValue]) throws -> Void)?
        if let revision {
            admission = { locked in try TrustPolicy.requireEditRevision(revision, policyObject: locked, dataRoot: root) }
        } else { admission = nil }
        let raw = try await SwiftNativeTrustCenter(dataRoot: engine.dataRoot).applyPolicyPatchChecked(fields,
            guardedByLockedPolicy: admission)
        return await trustReply(try TrustPolicy(policyObject: raw))
    }

    func savePolicyBlock(_ block: String, fields: [String: PartFace.Value], revision: String) async throws -> FaceActReply {
        let offered: Set<String>
        switch block {
        case "memoryPolicy": offered = ["cross_session_recall", "knowledge_graph_enabled", "adaptive_promotion"]
        case "multimodalPolicy": offered = ["screen_capture", "vision_api_calls", "file_ingestion_pdf", "file_ingestion_docx",
                                            "image_generation_openai", "tts_openai"]
        default: throw Self.failure("policy_block_unknown", "That policy block is unavailable.")
        }
        guard !fields.isEmpty, Set(fields.keys).isSubset(of: offered), fields.values.allSatisfy({ JSONValue($0).boolValue != nil }) else {
            throw Self.failure("policy_fields_invalid", "Choose an offered policy switch; no policy was changed.")
        }
        return try await savePolicy([block: .object(fields.mapValues(JSONValue.init))], revision: revision)
    }

    func applyTrustPreset(_ request: TrustPresetRequest) async throws -> FaceActReply {
        let root = engine.dataRoot
        guard let preset = MobileTrustAction.Preset(rawValue: request.preset) else {
            throw Self.failure("trust_preset_unknown", "Choose an offered Trust preset.")
        }
        let saved = try await preset.save(dataRoot: engine.dataRoot, fullMacConfirmed: request.confirmed,
            guardedByLockedPolicy: { locked in try TrustPolicy.requireEditRevision(request.expectedRevision, policyObject: locked, dataRoot: root) })
        try await engine.settingsFeed.setPreference(.string(preset.plan.agentAccessMode), key: "chatFileAccess")
        return await trustReply(saved)
    }

    func saveMacIntegrationPreset(_ preset: String) async throws -> FaceActReply {
        guard ["off", "watch", "assistant", "full"].contains(preset) else {
            throw Self.failure("mac_preset_unknown", "Choose Off, Watch, Assistant or Full Mac.")
        }
        let current = try await engine.trust.load()
        let saved = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMacIntegrationPreset(preset, currentPolicy: current)
        return await trustReply(saved)
    }

    func saveMacControlPolicy(_ request: MacControlPolicyWrite) async throws -> FaceActReply {
        let saved = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMacControlPolicy(request.policy,
            comparedTo: request.baseline)
        return await trustReply(saved)
    }

    func trustReply(_ policy: TrustPolicy) async -> FaceActReply {
        await engine.trust.publishPolicy(policy)
        var value = TrustSettingsFace()
        value.policy = policy
        value.effectiveMacControlPolicy = TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(policy)
        value.fullMacGrantIsActive = TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy)
        let preset = MobileTrustAction.Preset.matching(policy: policy,
            accessMode: TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy))
        value.activePreset = preset?.rawValue
        value.word = preset?.title ?? "Custom Trust"
        return .trust(value)
    }

    func restoreBackup(_ id: String, confirmed: Bool) async throws -> FaceActReply {
        guard confirmed else { throw Self.failure("restore_confirmation_required", "Confirm restoring this backup before continuing.") }
        let saved = try await TrustBackupPersistence.restoreBackup(id: id, dataRoot: engine.dataRoot)
        return try Self.committed(saved, identities: [id])
    }

    func saveActivityPolicy(_ request: ActivityPolicyWrite) async throws -> FaceActReply {
        let fields = request.fields.mapValues(JSONValue.init)
        let allowed: Set<String> = ["captureEnabled", "captureTitles", "browserTitlesEnabled", "appNameOnlyMode", "allowModelAccess", "retentionDays"]
        guard !fields.isEmpty, Set(fields.keys).isSubset(of: allowed) else {
            throw Self.failure("activity_fields_invalid", "Choose an offered activity setting.")
        }
        var changes: [String: JSONValue] = [:]
        for (key, value) in fields {
            if key == "retentionDays" {
                guard let days = value.exactIntegerValue, (1...365).contains(days) else {
                    throw Self.failure("activity_retention_invalid", "Choose a retention between 1 and 365 days.")
                }
            } else if value.boolValue == nil { throw Self.failure("activity_switch_invalid", "An activity switch takes on or off.") }
            changes[key] = value
        }
        let controller = await engine.activityWatch
        let initial = try await controller.checkedPolicy()
        let expected = try Self.activityRevision(initial)
        guard expected == request.expectedRevision else { throw Self.failure("activity_conflict", "Activity settings changed. Read them again.") }
        let edits = changes
        let saved = await controller.apply(expecting: initial) { policy in
            if let value = edits["captureEnabled"]?.boolValue { policy.captureEnabled = value }
            if let value = edits["captureTitles"]?.boolValue { policy.captureTitles = value }
            if let value = edits["browserTitlesEnabled"]?.boolValue { policy.browserTitlesEnabled = value }
            if let value = edits["appNameOnlyMode"]?.boolValue { policy.appNameOnlyMode = value }
            if let value = edits["allowModelAccess"]?.boolValue { policy.allowModelAccess = value }
            if let value = edits["retentionDays"]?.exactIntegerValue { policy.retentionDays = value }
        }
        guard saved else { throw Self.failure("activity_save_failed", await controller.lastError ?? "Activity settings could not be saved.") }
        return try Self.committed(try await controller.checkedPolicy())
    }

    func excludeActivityApp(_ id: String, confirmed: Bool) async throws -> FaceActReply {
        guard confirmed, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Self.failure("activity_exclusion_confirmation_required", "Choose and confirm the app before deleting its history.")
        }
        let controller = await engine.activityWatch
        await controller.addExclusion(bundleID: id)
        guard try await controller.checkedPolicy().excludedBundleIDs.contains(id), let removed = await controller.lastPurgedRowCount else {
            throw Self.failure("activity_exclusion_failed", await controller.lastError ?? "The exclusion and history deletion could not both be confirmed.",
                effects: .unknown)
        }
        return try Self.committed(removed, identities: [id])
    }

    func removeActivityExclusion(_ id: String) async throws -> FaceActReply {
        let controller = await engine.activityWatch
        guard !ActivityPolicy.alwaysExcludedBundleIDs.contains(id) else {
            throw Self.failure("activity_exclusion_required", "This app must stay excluded from activity recording.")
        }
        await controller.removeExclusion(bundleID: id)
        let saved = try await controller.checkedPolicy()
        guard !saved.excludedBundleIDs.contains(id) else {
            throw Self.failure("activity_exclusion_failed", await controller.lastError ?? "The exclusion could not be removed.")
        }
        return try Self.committed(saved, identities: [id])
    }

    func wipeActivity(_ confirmed: Bool) async throws -> FaceActReply {
        guard confirmed else { throw Self.failure("activity_wipe_confirmation_required", "Confirm deleting recorded activity before continuing.") }
        switch await engine.activityWatch.wipeAll() {
        case .deleted(let rows): return try Self.committed(rows)
        case .failed(let message): throw Self.failure("activity_wipe_failed", message, effects: .unknown)
        }
    }

    static func activityRevision(_ policy: ActivityPolicy) throws -> String {
        guard case .object(var fields) = try JSONValue.fromEncodable(policy) else {
            throw failure("activity_policy_shape", "Activity policy has no object representation.")
        }
        fields["excludedBundleIDs"] = .array(policy.excludedBundleIDs.sorted().map(JSONValue.string))
        return try JSONValue.object(fields).serializedData(pretty: false).base64EncodedString()
    }
}
