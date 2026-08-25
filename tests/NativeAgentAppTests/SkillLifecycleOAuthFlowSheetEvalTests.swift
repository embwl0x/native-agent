import Foundation
import NativeAgentCore
import Skills
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SkillLifecycle.oauthFlowSheet
@MainActor
@Suite("Skill Lifecycle OAuth flow sheet", .serialized)
struct SkillLifecycleOAuthFlowSheetEvalTests {
    @Test("a cancelled OAuth admission leaves the draft registry byte-for-byte unchanged")
    func cancellationCannotHalfInstallTheSkill() async throws {
        let root = try temporaryRoot("cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        try await createDraftSkill(at: root)
        let registry = root.appendingPathComponent("skills/registry.json")
        let before = try Data(contentsOf: registry)
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.loadSkillManifests()
        let draft = try #require(app.skillManifests.first { $0.id == "oauth-fixture" })
        var installCalls = 0

        let installed = await SkillReviewInstallPresentation.installAfterAuthorizedOAuth(
            oauthSucceeded: true,
            wasCancelled: true,
            install: {
                installCalls += 1
                if case .installed = await app.installReviewedSkill(draft) { return true }
                return false
            }
        )

        #expect(!installed)
        #expect(installCalls == 0)
        #expect(try Data(contentsOf: registry) == before)
        #expect(try await skillStatus(named: "oauth-fixture", at: root) == "draft")
    }

    @Test("only a completed OAuth admission enables the same mounted skill registry")
    func successRunsTheCanonicalInstallOnTheMountedRoot() async throws {
        let root = try temporaryRoot("success")
        defer { try? FileManager.default.removeItem(at: root) }
        try await createDraftSkill(at: root)
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.loadSkillManifests()
        let draft = try #require(app.skillManifests.first { $0.id == "oauth-fixture" })
        var installCalls = 0

        let installed = await SkillReviewInstallPresentation.installAfterAuthorizedOAuth(
            oauthSucceeded: true,
            wasCancelled: false,
            install: {
                installCalls += 1
                if case .installed = await app.installReviewedSkill(draft) { return true }
                return false
            }
        )

        #expect(installed)
        #expect(installCalls == 1)
        #expect(try await skillStatus(named: "oauth-fixture", at: root) == "active")
    }

    @Test("only verified connector routes can open the OAuth sheet")
    func providerRoutingFailsClosedBeforeAnyInstallCanStart() {
        #expect(SkillReviewInstallPresentation.connectorID(for: "Gmail") == "gmail")
        #expect(SkillReviewInstallPresentation.connectorID(for: "calendar") == "calendar")
        #expect(SkillReviewInstallPresentation.connectorID(for: "unverified-service") == nil)
    }

    private func createDraftSkill(at root: URL) async throws {
        let writer = SwiftNativeSkillsClient(
            root: root,
            legacyManifestPath: root.appendingPathComponent("legacy-manifest.json")
        )
        _ = try await writer.createSkill(body: .object([
            "name": .string("oauth-fixture"),
            "description": .string("Hermetic OAuth connector fixture"),
            "triggers": .array([.string("fixture")]),
            "content": .string("# OAuth Fixture\n\nThis fixture is safe.\n"),
            "status": .string("draft"),
            "autoCreated": .bool(true),
        ]))
    }

    private func skillStatus(named name: String, at root: URL) async throws -> String? {
        let reader = SwiftNativeSkillsClient(
            root: root,
            legacyManifestPath: root.appendingPathComponent("legacy-manifest.json")
        )
        for row in try await reader.listSkills() {
            guard case .object(let object) = row,
                  case .string(let rowName)? = object["name"],
                  rowName == name,
                  case .string(let status)? = object["status"] else {
                continue
            }
            return status
        }
        return nil
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-oauth-flow-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
