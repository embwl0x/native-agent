import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.installSignedDemoPack

@MainActor
@Suite("Capabilities signed demo-pack install")
struct CapabilitiesInstallSignedDemoPackEvalTests {
    @Test("an invalid pack is refused before it can initialize or install anything, without Evaluate Trust")
    func invalidInstallIsPrewriteAndIndependentOfTrustEvaluation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        #expect(app.latestCapabilityTrustEvaluation == nil)
        await app.installCapabilityPackForCatalog(wronglySignedPack(id: "unsigned-before-write"))

        guard case .refused(let message)? = app.capabilityCatalogInstallOutcome else {
            Issue.record("The mounted catalog install action must surface a signature refusal")
            return
        }
        #expect(message.contains("Signature mismatch."))
        #expect(app.latestCapabilityTrustEvaluation == nil)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("catalog/packs/unsigned-before-write.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("catalog/installs.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("catalog/.pack_signing_key").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("catalog/trust/roots.json").path
        ))

        await app.installDemoCapabilityPack()
        guard case .installed(let name)? = app.capabilityCatalogInstallOutcome else {
            Issue.record("The signed demo action must expose an installed receipt")
            return
        }
        #expect(name == "NativeAgent Demo Operator Pack")
        #expect(!app.isInstallingDemoCapabilityPack)
        #expect(app.latestCapabilityTrustEvaluation == nil)

        let reloaded = NativeClient(baseURL: "", dataRootOverride: root)
        let installs = try await reloaded.getCapabilityPackInstalls()
        let receipt = try #require(installs.first { $0.packId == "nativeagent-demo-operator-pack" })
        #expect(receipt.status == "installed")
        #expect(receipt.signature?.isEmpty == false)
    }

    private func wronglySignedPack(id: String) -> [String: JSONValue] {
        [
            "id": .string(id),
            "name": .string("Wrongly signed pack"),
            "version": .string("1.0.0"),
            "signature": .string("definitely-not-a-valid-signature"),
            "items": .object([
                "catalog": .array([]),
                "skills": .array([]),
                "workflows": .array([]),
            ]),
        ]
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capabilities-signed-demo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
