import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+PersonalitySelfImprovement.swift` | Persona forms and document refresh through checked body acts |

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


    @concurrent nonisolated private static func decodePersonaProfile(_ value: PartFace.Value) async throws -> PersonalityProfile {
        try JSONDecoder().decode(PersonalityProfile.self, from: JSONEncoder().encode(value))
    }
}
