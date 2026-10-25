import Foundation
import NativeAgentCore
import Observation
import NativeAgentShared
import PersistenceCore
import PersonaEngine
// Blueprint: | `EnginePersona.swift` | PersonaFacade owns profile/documents and retained read availability for Mac, editors and DeviceSync over unchanged PersonaEngine content readers/writers. LatestRead orders reads/failures, committed profile/name/document saves use write; chat/settlement scaffolding keeps its existing effect without discarded diagnostic compilation. |

/// The saved profile and editable documents for this root. Mac presentation
/// and phone publication share these reads; PersonaEngine owns their content.
@MainActor
@Observable
public final class PersonaFacade {
    public nonisolated let dataRoot: URL
    private nonisolated let owner: SwiftNativePersonaEngine
    public private(set) var profile: PersonalityProfile?
    public private(set) var documents: [PersonaDocSpec] = []
    public private(set) var profileError: String?
    public private(set) var documentsError: String?
    @ObservationIgnored private let profileRead = LatestRead()
    @ObservationIgnored private let documentsRead = LatestRead()

    public nonisolated init(dataRoot: URL, isolated: Bool) {
        self.dataRoot = dataRoot
        self.owner = isolated ? .isolated(dataRoot: dataRoot) : SwiftNativePersonaEngine(
            root: PersonaRootResolver.resolve(dataRootProvider: { dataRoot }), dataRoot: dataRoot
        )
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
        })
        return try result.get()
    }

    /// Chat arrival and turn settlement retain their existing scaffold effect;
    /// no diagnostic packet is compiled and discarded for that effect.
    @discardableResult
    public nonisolated func prepareDocuments() async throws -> [String] {
        try await owner.scaffoldMissingDocs()
    }

    public func saveProfile(_ value: PersonalityProfile) async throws {
        let saved = try await owner.savePersonality(value).sharedProfile
        profileRead.write { profile = saved; profileError = nil }
        _ = try? await loadDocuments()
    }

    public func saveName(_ name: String) async throws -> PersonalityProfile {
        let saved = try await owner.saveName(name)
        profileRead.write { profile = saved; profileError = nil }
        return saved
    }

    public func saveDocument(id: String, content: String, appending: Bool) async throws -> PersonaDocSpec {
        let saved = try await owner.savePersonalityDoc(id: id, content: content, appending: appending)
        documentsRead.write {
            documentsError = nil
            if let index = documents.firstIndex(where: { $0.id == saved.id }) {
                documents[index] = saved
            } else {
                documents.append(saved)
            }
        }
        _ = try? await prepareDocuments()
        return saved
    }
}
