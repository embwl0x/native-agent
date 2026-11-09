import AuthoredCapabilities
import DreamREMCycle
import Foundation
import NativeAgentCore
import NativeAgentShared
import Onboarding
import PersistenceCore
import Research
import TrustPersistence
// Blueprint: | `EngineFaceActs+Owners.swift` | Body onboarding, backup, research and dream acts return their owner's checked outcomes |

extension EngineFaceActs {
    @concurrent static func dream(_ root: URL, rem: Bool) async throws -> JSONValue {
        let result = rem ? try await NativeAgentEngine.runRem(dataRoot: root)
            : try await NativeAgentEngine.runDream(dataRoot: root, trigger: .manual)
        return .object(try NativeActionWire.jsonValueBody(result))
    }

    func createBackup(_ reason: String) async throws -> FaceActReply {
        let saved = try await TrustBackupPersistence.createBackup(reason: reason, dataRoot: engine.dataRoot)
        let issue: WireFailure?
        do { _ = try await engine.trust.refreshBackups(); issue = nil }
        catch { issue = WireFailure(code: "backup_publication", message: "The backup was created, but its list could not be refreshed.",
            cause: error.localizedDescription, effects: .known) }
        return .committed(.init(identities: [saved.id], value: PartFace.Value(try JSONValue.fromEncodable(saved)),
            revision: nil, effects: .known, publicationFailure: issue))
    }

    func research(_ query: String) async throws -> FaceActReply {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw Self.failure("empty_query", "Enter a research query.") }
        let result = try await SwiftNativeResearchClient(dataRoot: engine.dataRoot).search(query: clean)
        let rows = result.results.map { value in
            PartFace.Value.object(["title": .string(value.title), "url": .string(value.url), "snippet": .string(value.snippet),
                "source": value.source.map(PartFace.Value.string) ?? .null])
        }
        return .result(.object(["results": .array(rows), "unresponsiveEngines": .array(result.unresponsiveEngines.map(PartFace.Value.string)),
            "gaps": .array(result.gaps.map(PartFace.Value.string))]))
    }

    func onboarding(_ act: OnboardingAct) async throws -> FaceActReply {
        let client = engine.onboarding
        switch act {
        case .greet:
            throw Self.failure("greeting_platform_required", "The first conversation is owned by the Mac greeting transaction.")
        case .start:
            let read = try await client.startOnboarding()
            let disposition = await postOnboarding(read)
            return .result(.object(["hasExisting": .bool(read.hasExisting), "pendingRecovery": .bool(read.pendingRecovery),
                "disposition": .string(disposition), "detail": read.profileUnreadable.map(PartFace.Value.string) ?? .null,
                "requiresPresentation": .bool(disposition != "alreadyOnboarded"),
                "resetRequired": .bool(read.resetRequired), "profileRepairRequired": .bool(read.profileRepairRequired),
                "profileUnreadable": read.profileUnreadable.map(PartFace.Value.string) ?? .null,
                "currentPersonaName": read.currentPersonaName.map(PartFace.Value.string) ?? .null]))
        case .complete(let name, let type, let user):
            let result = try await engine.completeOnboarding(payload: .init(agentName: name, personaType: type, userName: user), resident: engine)
            return completion(result)
        case .resume:
            return completion(try await engine.resumePendingOnboarding(resident: engine))
        case .repairProfile(let name, let type, let user):
            let result = try await engine.repairOnboardingProfile(payload: .init(agentName: name, personaType: type, userName: user),
                publishProfile: { [engine] in
                    do { _ = try await engine.persona.loadProfile() }
                    catch { SystemToastCenter.shared.push(error: error.localizedDescription, autoDismissAfter: nil) }
                }, resident: engine)
            return completion(result)
        case .reset(let confirmed):
            let result = try await engine.resetOnboarding(confirm: confirmed, resident: engine)
            return .result(.object(["ok": .bool(result.ok), "backedUp": .array(result.backedUp.map(PartFace.Value.string)),
                "error": result.error.map(PartFace.Value.string) ?? .null]))
        }
    }

    private func completion(_ result: OnboardingCompleteResult) -> FaceActReply {
        .result(.object(["ok": .bool(result.ok), "agentName": result.agentName.map(PartFace.Value.string) ?? .null,
            "personaType": result.personaType.map(PartFace.Value.string) ?? .null, "userName": result.userName.map(PartFace.Value.string) ?? .null,
            "error": result.error.map(PartFace.Value.string) ?? .null, "detail": result.detail.map(PartFace.Value.string) ?? .null]))
    }

    func postOnboarding(_ read: OnboardingStartResult) async -> String {
        let disposition: String
        switch read.disposition(buildFailed: false) {
        case .resume: disposition = "resume"
        case .repairProfile: disposition = "repairProfile"
        case .profileUnreadable: disposition = "profileUnreadable"
        case .reset: disposition = "reset"
        case .alreadyOnboarded: disposition = "alreadyOnboarded"
        case .blockedNeedsReset: disposition = "blockedNeedsReset"
        case .fresh: disposition = "fresh"
        }
        let rows = read.abilityOverview.map {
            PartFace.Row(id: $0.id, title: $0.title, detail: $0.detail, actions: [])
        }
        await engine.face.post(OnboardingFace(disposition: disposition, agentName: read.currentPersonaName, userName: nil,
            abilityOverview: rows, progress: nil, greeting: nil, state: .ready), at: .onboarding)
        return disposition
    }
}
