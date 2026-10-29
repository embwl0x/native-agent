import Foundation
import NativeAgentShared
import MemoryV2
import Observation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `StarterPersona.swift` | Starter persona publication through canonical document owners |
extension SwiftNativeOnboardingClient {
    public enum StarterOutcome: Equatable {
        case created
        case notesUnsaved(documentID: String, draft: String)
        case failed(String)
    }
    @MainActor
    public static func createStarterPersona(
        agentName: String,
        userName: String,
        notes: String,
        complete: (String, String) async throws -> OnboardingCompleteResult,
        reload: () async -> [PersonaDocSpec]?,
        append: (String, String) async -> Bool,
        failureMessage: (Error) -> String
    ) async -> StarterOutcome {
        do {
            let response = try await complete(
                agentName.trimmingCharacters(in: .whitespacesAndNewlines),
                userName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard response.ok else {
                return .failed(response.detail ?? response.error ?? "Could not create the persona.")
            }
            guard let documents = await reload() else {
                return .failed(
                    "The persona was created, but its documents could not be reloaded to save your setup notes. Retry from the Personality page before editing anything else."
                )
            }
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedNotes.isEmpty,
                  let soul = documents.first(where: { $0.id.uppercased() == "SOUL" })
            else {
                return .created
            }
            let section = "\n\n## From setup\n" + trimmedNotes + "\n"
            // Only the section crosses the suspension; the append owner reads
            // the current SOUL under its write lock. The snapshot is for recovery only.
            guard await append(soul.id, section) else {
                return .notesUnsaved(documentID: soul.id, draft: soul.content + section)
            }
            return .created
        } catch {
            return .failed(failureMessage(error))
        }
    }
}
