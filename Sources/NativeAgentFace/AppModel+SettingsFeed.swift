import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+SettingsFeed.swift` | Finished settings readers and scene-held preference write admission |

extension AppModel {
    func setFacePreference(_ value: PartFace.Value, for key: String) {
        enqueueWindowAction(.preference(key: key, value: value))
    }
    func checkedFaceAct(_ act: FaceAct) async throws -> FaceActReply {
        let reply = try await client.act(act)
        switch reply {
        case .failed(let failure), .refused(let failure): throw failure
        default: return reply
        }
    }
    func committedFaceAct(_ act: FaceAct) async throws -> CommittedResult {
        let reply = try await checkedFaceAct(act)
        let result: CommittedResult
        switch reply {
        case .committed(let value), .operation(.completed(let value)): result = value
        default: throw PartCallError(code: "unconfirmed_reply", message: "I have not confirmed this operation's committed result.")
        }
        if let failure = result.publicationFailure { setFailureStatus(failure, action: "publish the saved result") }
        return result
    }
    func facePreference<Value: FacePreferenceScalar>(_ key: String, as: Value.Type) -> Value? {
        face.slot(.settings).select("preference.value:\(key)", as: SettingsFace.self) { $0?.preferences[key].flatMap(Value.read) }
    }
    var settingsViewModeIssue: String? {
        face.slot(.settings).select("preference.issue:nativeagent.viewMode", as: SettingsFace.self) {
            $0?.preferenceIssues["nativeagent.viewMode"]
        }
    }
    var settingsPersonaDisplayName: String {
        face.slot(.settings).select("persona.displayName", as: SettingsFace.self) { $0?.persona.displayName ?? "" }
    }
    var personaProfile: PersonalityProfile? {
        face.slot(.settings).select("persona.profile", as: SettingsFace.self) { $0?.persona.profile }
    }
    var personaDocuments: [PersonaDocSpec] {
        face.slot(.settings).select("persona.documents", as: SettingsFace.self) { $0?.persona.documents ?? [] }
    }
    var personaProfileIssue: String? {
        face.slot(.settings).select("persona.profileIssue", as: SettingsFace.self) { $0?.persona.profileIssue }
    }
    var personaDocumentsIssue: String? {
        face.slot(.settings).select("persona.documentsIssue", as: SettingsFace.self) { $0?.persona.documentsIssue }
    }
    var settingsScreenCaptureEnabled: Bool? {
        face.slot(.settings).select("trust.screenCapture", as: SettingsFace.self) { $0?.trust.policy?.multimodalPolicy?.screen_capture }
    }
    var settingsChromeControlEnabled: Bool? {
        face.slot(.settings).select("trust.chromeControl", as: SettingsFace.self) { $0?.trust.policy?.chromeControlPolicy?.enabled }
    }
    var settingsFullMacGrantIsActive: Bool? {
        face.slot(.settings).select("trust.fullMacGrant", as: SettingsFace.self) { $0?.trust.fullMacGrantIsActive }
    }
}
