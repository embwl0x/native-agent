import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+PersonalitySelfImprovement.swift` | Persona, proposals and explicit mind work through checked body acts |

@MainActor
extension AppModel {
    func readPersonaFormState(documents: Bool) async throws -> PersonaSettingsFace {
        try await client.act(.readPersona(documents: documents)).checkedPersona(documents: documents)
    }

    func savePersonaFormName(_ name: String) async throws -> PersonalityProfile {
        let saved = try await client.act(.savePersonaName(name)).checkedCommit()
        return try await Self.decodePersonaProfile(saved.value)
    }

    func savePersonaFormDocument(id: String, content: String, expectedContent: String) async throws -> PersonaDocSpec {
        let saved = try await client.act(.savePersonaDocument(id: id, content: content, append: false,
            expectedContent: expectedContent)).checkedCommit()
        return try await Self.decodePersonaDocument(saved.value)
    }

    @concurrent nonisolated private static func decodePersonaDocument(_ value: PartFace.Value) async throws -> PersonaDocSpec {
        try JSONDecoder().decode(PersonaDocSpec.self, from: JSONEncoder().encode(value))
    }

    func savePersonalityChecked(_ profile: PersonalityProfile) async throws {
        _ = try await client.act(.savePersonaProfile(profile)).checkedCommit()
        statusText = "Personality saved"
    }

    @discardableResult
    func loadSupportDiagnostics() async throws -> PartFace.Value {
        try await client.act(.requestSupportSnapshot).checkedValue()
    }

    @discardableResult
    func reloadPersonalityDocuments() async -> Bool {
        do {
            try await client.act(.refresh(.panel(SidebarItem.personality.rawValue))).checkedAcknowledgement()
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            statusText = FaceActionFeedback.message(error, action: "load the personality docs")
            return false
        }
    }

    @discardableResult
    func savePersonalityDoc(id: String, content: String, appending: Bool = false) async -> Bool {
        do {
            _ = try await client.act(.savePersonaDocument(id: id, content: content, append: appending)).checkedCommit()
            statusText = "\(id) saved"
            return true
        } catch {
            statusText = FaceActionFeedback.message(error, action: "save that personality doc")
            return false
        }
    }

    func loadMemoryProposals() async { _ = await requestFaceRefresh(.panel(SidebarItem.memories.rawValue)) }

    func approveMemoryProposal(id: String) async throws {
        try await client.act(.resolveMemoryProposal(id: id, decision: .accept)).checkedAcknowledgement()
    }

    func rejectMemoryProposal(id: String) async throws {
        try await client.act(.resolveMemoryProposal(id: id, decision: .reject)).checkedAcknowledgement()
    }

    func runRemPass() async -> DreamsActionFeedback {
        do {
            let result = try await client.act(.runREM).checkedValue()
            return .completed(result)
        } catch {
            let detail = FaceActionFeedback.message(error, action: "run the REM cycle")
            dreamError = detail
            return .failed(detail)
        }
    }

    func setDreamCycleEnabled(_ enabled: Bool) async -> Bool {
        await saveDreamSetting(.setDreamCycleEnabled(enabled))
    }

    func setRemCycleEnabled(_ enabled: Bool) async -> Bool {
        await saveDreamSetting(.setREMCycleEnabled(enabled))
    }

    private func saveDreamSetting(_ act: FaceAct) async -> Bool {
        do {
            _ = try await client.act(act).checkedCommit()
            dreamError = nil
            return true
        } catch {
            dreamError = FaceActionFeedback.message(error, action: "save the dream setting")
            return false
        }
    }

    func setInnerLifeEnabled(_ enabled: Bool) async throws -> PartFace.Value {
        try await client.act(.setInnerLifeEnabled(enabled)).checkedValue()
    }

    func runDreamPassForDreams() async -> DreamsActionFeedback {
        do {
            let result = try await client.act(.runDream).checkedValue()
            dreamError = nil
            return .completed(result)
        } catch {
            dreamError = FaceActionFeedback.message(error, action: "run the dream cycle")
            return .failed(error.localizedDescription)
        }
    }

    @concurrent nonisolated private static func decodePersonaProfile(_ value: PartFace.Value) async throws -> PersonalityProfile {
        try JSONDecoder().decode(PersonalityProfile.self, from: JSONEncoder().encode(value))
    }
}
