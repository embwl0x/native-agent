import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SkillLifecycle.reviewSheetInstall

@MainActor
@Suite("Skill lifecycle review-sheet installation")
struct SkillLifecycleReviewSheetInstallEvalTests {
    @Test("a reviewed draft writes and rereads the exact injected registry before reporting installed")
    func reviewedDraftProducesAConfirmedInstallReceipt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(root: root, state: "drafted")

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.loadSkillManifests()
        let draft = try #require(app.skillManifests.first)

        let outcome = await app.installReviewedSkill(draft)

        guard case .installed(let receipt) = outcome else {
            Issue.record("Expected an installed receipt, got \(outcome)")
            return
        }
        #expect(receipt.requestedName == "review-draft")
        #expect(receipt.confirmedName == "Reviewed Draft")
        #expect(receipt.confirmedState == "installed")
        #expect(SkillReviewInstallPresentation.successMessage(for: receipt)
            == "‘Reviewed Draft’ is installed and available to recall.")

        let reread = try registryState(at: root)
        #expect(reread == "installed")
        #expect(app.skillLifecycleFeedback == nil)
    }

    @Test("the review sheet refuses non-drafts without changing their authority row")
    func nonDraftCannotBeInstalledFromReviewSheet() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(root: root, state: "dormant")

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.loadSkillManifests()
        let dormant = try #require(app.skillManifests.first)

        let outcome = await app.installReviewedSkill(dormant)

        #expect(outcome == .refused(
            detail: "Only a drafted skill can be installed from this review sheet. This skill is currently dormant."
        ))
        #expect(try registryState(at: root) == "dormant")
    }

    @Test("a damaged registry produces a visible failure and preserves the authority bytes")
    func corruptedRegistryCannotProduceASuccessShapedInstall() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("skills/manifest_registry.json")
        try FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{ malformed registry".utf8)
        try corrupt.write(to: registry, options: .atomic)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let outcome = await app.installReviewedSkill(skillInfo(root: root, state: "drafted"))

        guard case .failed(let detail) = outcome else {
            Issue.record("A corrupt registry must fail instead of reporting installed")
            return
        }
        #expect(detail.hasPrefix("Install failed:"))
        #expect(app.skillLifecycleFeedback?.kind == .failure)
        #expect(try Data(contentsOf: registry) == corrupt)
    }

    @Test("OAuth cancellation or failure cannot advance a connector draft into installation")
    func oauthAdmissionControlsTheInstallContinuation() async {
        var installCalls = 0
        let cancelled = await SkillReviewInstallPresentation.installAfterAuthorizedOAuth(
            oauthSucceeded: true,
            wasCancelled: true,
            install: {
                installCalls += 1
                return true
            }
        )
        let refused = await SkillReviewInstallPresentation.installAfterAuthorizedOAuth(
            oauthSucceeded: false,
            wasCancelled: false,
            install: {
                installCalls += 1
                return true
            }
        )
        let admitted = await SkillReviewInstallPresentation.installAfterAuthorizedOAuth(
            oauthSucceeded: true,
            wasCancelled: false,
            install: {
                installCalls += 1
                return true
            }
        )

        #expect(!cancelled)
        #expect(!refused)
        #expect(admitted)
        #expect(installCalls == 1)
    }

    @Test("the review install control makes an ineligible draft visibly non-actionable")
    func reviewInstallControlShowsTheSamePreflightRefusalThatGuardsTheWriter() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let info = skillInfo(root: root, state: "dormant")
        let control = SkillReviewInstallPresentation.installControl(
            for: info,
            isInstalling: false
        )
        #expect(!control.isEnabled)
        #expect(control.refusal
            == "Only a drafted skill can be installed from this review sheet. This skill is currently dormant.")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-review-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSkill(root: URL, state: String) throws {
        let directory = root.appendingPathComponent("skills/review-draft", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeJSON([
            "skills": [
                "review-draft": [
                    "state": state,
                    "version": "1.0.0",
                    "type": "tool",
                    "path": directory.path,
                ],
            ],
        ], to: root.appendingPathComponent("skills/manifest_registry.json"))
        try writeJSON([
            "schemaVersion": 1,
            "name": "Reviewed Draft",
            "version": "1.0.0",
            "type": "tool",
            "description": "A reviewable skill draft.",
        ], to: directory.appendingPathComponent("manifest.json"))
    }

    private func skillInfo(root: URL, state: String) -> SkillInfo {
        let registry = SkillRegistryEntry(
            name: "review-draft",
            state: state,
            version: "1.0.0",
            type: "tool",
            installedAt: nil,
            path: root.appendingPathComponent("skills/review-draft").path
        )
        let manifest = SkillManifest(
            schemaVersion: 1,
            name: "Reviewed Draft",
            version: "1.0.0",
            type: "tool",
            description: "A reviewable skill draft.",
            author: nil,
            permissions: nil,
            tools: nil,
            oauth: nil,
            tags: nil,
            homepage: nil
        )
        return SkillInfo(id: "review-draft", manifest: manifest, registry: registry, readme: nil)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private func registryState(at root: URL) throws -> String? {
        let data = try Data(contentsOf: root.appendingPathComponent("skills/manifest_registry.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let skills = object?["skills"] as? [String: [String: Any]]
        return skills?["review-draft"]?["state"] as? String
    }

}
