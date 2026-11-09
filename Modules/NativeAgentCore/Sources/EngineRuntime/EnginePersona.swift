import Foundation
import NativeAgentCore
import Observation
import NativeAgentShared
import PersistenceCore
import PersonaEngine
// Blueprint: | `EnginePersona.swift` | Checked profile and document publication with independent save/read outcomes |

/// Mac and phone share profile reads; PersonaEngine owns the content.
@MainActor
@Observable
public final class PersonaFacade {
    public nonisolated let dataRoot: URL
    public nonisolated let personaRoot: URL
    private nonisolated let owner: SwiftNativePersonaEngine
    public private(set) var profile: PersonalityProfile?
    public private(set) var documents: [PersonaDocSpec] = []
    public private(set) var profileError: String?
    public private(set) var documentsError: String?
    /// Wait for a checked profile before naming identity; errors must never become names.
    public var displayName: String {
        guard profileError == nil, let profile else { return "" }
        return NativeAgentIdentity.displayName(profile.name)
    }
    @ObservationIgnored private let profileRead = LatestRead()
    @ObservationIgnored private let documentsRead = LatestRead()
    @ObservationIgnored private var settingsFeed: SettingsFeedProjection?

    public func bindSettingsFeed(_ feed: SettingsFeedProjection) {
        settingsFeed = feed
        publishSettings()
    }

    private func publishSettings() {
        settingsFeed?.updatePersona(profile: profile, documents: documents, profileIssue: profileError, documentsIssue: documentsError)
    }

    public nonisolated init(dataRoot: URL, isolated: Bool) {
        self.dataRoot = dataRoot
        self.personaRoot = isolated ? PersonaRootResolver.resolveIsolated(dataRoot: dataRoot) : PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        self.owner = SwiftNativePersonaEngine(root: personaRoot, dataRoot: dataRoot)
    }

    @discardableResult
    public func loadProfile() async throws -> PersonalityProfile {
        let result: Result<PersonalityProfile, Error> = await profileRead.read({
            do { return .success(try await SwiftNativePersonaEngine.readPersonality(dataRoot: dataRoot)) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let next): profile = next; profileError = nil
            case .failure(let error): profileError = error.localizedDescription
            }
            publishSettings()
        })
        return try result.get()
    }

    @discardableResult
    public func loadDocuments() async throws -> [PersonaDocSpec] {
        let result: Result<[PersonaDocSpec], Error> = await documentsRead.read({
            do { return .success(try await owner.listPersonaDocSpecs().docs) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let next): documents = next; documentsError = nil
            case .failure(let error): documentsError = UserFacingError.cause(error, action: "load the personality docs")
            }
            publishSettings()
        })
        return try result.get()
    }

    @discardableResult
    public func saveProfile(_ value: PersonalityProfile) async throws -> (profile: PersonalityProfile, documentsIssue: String?) {
        let saved = try await owner.savePersonality(value).sharedProfile
        profileRead.write { profile = saved; profileError = nil; publishSettings() }
        do {
            _ = try await loadDocuments()
            return (saved, nil)
        } catch { return (saved, error.localizedDescription) }
    }

    public func saveName(_ name: String) async throws -> PersonalityProfile {
        let saved = try await owner.saveName(name)
        profileRead.write { profile = saved; profileError = nil; publishSettings() }
        return saved
    }

    public func saveDocument(id: String, content: String, appending: Bool, expectedContent: String? = nil) async throws -> PersonaDocSpec {
        let saved = try await owner.savePersonalityDoc(id: id, content: content, appending: appending, expectedContent: expectedContent)
        documentsRead.write {
            documentsError = nil
            if let index = documents.firstIndex(where: { $0.id == saved.id }) {
                documents[index] = saved
            } else {
                documents.append(saved)
            }
            publishSettings()
        }
        return saved
    }
}
