import Foundation
import Testing
@testable import NativeAgentApp
import PersistenceCore
import TrustCenter

// EVAL FENCE: app.settings / ui.Capabilities.capabilityCatalog

@MainActor
@Suite("Capabilities catalog — signed install boundary")
struct CapabilitiesCatalogBehaviorEvalTests {
    @Test("the catalog installs a signed pack durably and keeps unsigned or tampered packs visibly refused")
    func signedInstallReloadsWhileInvalidPacksCannotWritePastTheCatalogBoundary() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = NativeClient(baseURL: "http://127.0.0.1:1", dataRootOverride: root)
        let unsigned = pack(id: "catalog-eval-unsigned")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        await app.installCapabilityPackForCatalog(unsigned)

        guard case .refused(let refusal)? = app.capabilityCatalogInstallOutcome else {
            Issue.record("Unsigned catalog pack must be refused by the visible catalog action.")
            return
        }
        #expect(refusal.contains("Missing required field(s): signature"))
        #expect(refusal.contains("Signature mismatch."))
        #expect(app.statusText.contains("Pack install refused:"))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("catalog/packs/catalog-eval-unsigned.json").path
        ))

        // The row is a direct projection of this production presentation
        // model. Assert its visible text, tone and icon without relying on
        // private AppKit wrappers for SwiftUI's Label accessibility tree.
        let refusedPresentation = CapabilityCatalogInstallOutcome.refused(message: refusal)
        #expect(refusedPresentation.message == "Pack install refused: \(refusal)")
        #expect(refusedPresentation.systemImage == "exclamationmark.triangle.fill")
        #expect(refusedPresentation.status == "warn")

        let signer = SwiftNativeCapabilityPackSigner(
            dataRoot: root,
            persistence: SwiftNativePersistenceCore()
        )
        let signed = try await signer.sign(pack(id: "catalog-eval-signed"))
        let receipt = try await client.installCapabilityPack(signed)
        #expect(receipt.packId == "catalog-eval-signed")
        #expect(receipt.status == "installed")

        let reloaded = NativeClient(baseURL: "http://127.0.0.1:1", dataRootOverride: root)
        let installs = try await reloaded.getCapabilityPackInstalls()
        #expect(installs.contains { $0.id == receipt.id && $0.status == "installed" })
        let catalog = try await reloaded.getCapabilityCatalog()
        #expect(catalog.contains {
            $0.id == "catalog:catalog-eval-signed" && $0.installed == true
        })

        var tampered = try await signer.sign(pack(id: "catalog-eval-tampered"))
        tampered["name"] = .string("Tampered after signing")
        do {
            _ = try await client.installCapabilityPack(tampered)
            Issue.record("Tampered catalog pack must not cross the install boundary.")
        } catch {
            #expect(error.localizedDescription.contains("Signature mismatch."))
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("catalog/packs/catalog-eval-tampered.json").path
        ))
        let installsAfterTamper = try await reloaded.getCapabilityPackInstalls()
        #expect(!installsAfterTamper.contains { $0.packId == "catalog-eval-tampered" })
    }

    private func pack(id: String) -> [String: JSONValue] {
        [
            "id": .string(id),
            "name": .string("Catalog Eval \(id)"),
            "version": .string("1.0.0"),
            "items": .object([
                "catalog": .array([
                    .object([
                        "id": .string("catalog:\(id)"),
                        "name": .string("Catalog item \(id)"),
                        "kind": .string("skill_pack"),
                        "description": .string("A signed catalog evaluation fixture."),
                        "riskClass": .string("app_data_read"),
                    ])
                ]),
                "skills": .array([]),
                "workflows": .array([]),
            ]),
        ]
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capabilities-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
