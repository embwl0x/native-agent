import Foundation
import XCTest
import NativeAgentShared
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens` and `ios.sync`.
///
/// A provider picker may show a previous, proven Mac projection while a new
/// payload is malformed, but a *valid empty* projection is authoritative and
/// must clear it.  Treating those states alike fabricates an available model;
/// treating them both as failure leaves removed providers selectable forever.
///
/// This is an owner-level projection eval. It is evidence for picker/sync rows,
/// but does not claim a SwiftUI action or the CloudKit file-group lifecycle.
@MainActor
final class ProviderProjectionTruthfulnessEvalTests: XCTestCase {
    private func catalog(
        providers: [NAProviderCatalogProvider],
        surfaces: [String: NAProviderSurfaceSelection]
    ) -> String {
        let value = NAProviderCatalogStatus(providers: providers, surfaces: surfaces)
        return try! NAProviderCatalogStatusCodec.encode(value)
    }

    private func provider(id: String = "provider-a", model: String = "model-a") -> NAProviderCatalogProvider {
        NAProviderCatalogProvider(
            providerID: id,
            displayName: "Provider A",
            authState: "ready",
            authModes: ["oauth"],
            models: [
                NAProviderCatalogModel(
                    id: model,
                    name: "Model A",
                    contextLength: 128_000,
                    supportsStreaming: true,
                    supportsVision: true,
                    supportsTools: true,
                    supportsJSONMode: true,
                    defaultReasoningEffort: "high",
                    supportedReasoningEfforts: ["low", "high"],
                    supportsFast: false
                )
            ]
        )
    }

    func test_validEmptyCatalogClearsAProviderThatTheMacRemoved() {
        let engine = iCloudSyncEngine.shared
        let priorProviders = engine.providers
        let priorSurfaces = engine.surfaceModels
        let priorLastSyncAt = engine.lastSyncAt
        let priorSyncError = engine.syncError
        defer {
            engine.providers = priorProviders
            engine.surfaceModels = priorSurfaces
            engine.lastSyncAt = priorLastSyncAt
            engine.syncError = priorSyncError
        }

        XCTAssertTrue(engine.applyProviderCatalogStatus(catalog(
            providers: [provider()],
            surfaces: [
                "ios": NAProviderSurfaceSelection(
                    providerID: "provider-a",
                    model: "model-a",
                    reasoningEffort: "high",
                    serviceTier: "default"
                )
            ]
        )))
        XCTAssertEqual(engine.providers.map(\.provider_id), ["provider-a"])
        XCTAssertEqual(engine.surfaceModels["ios"]?.model, "model-a")

        XCTAssertTrue(engine.applyProviderCatalogStatus(catalog(providers: [], surfaces: [:])))
        XCTAssertTrue(engine.providers.isEmpty, "a valid empty Mac catalog left a removed provider selectable")
        XCTAssertTrue(engine.surfaceModels.isEmpty, "a valid empty Mac selection left a stale model pill on screen")
        XCTAssertNil(engine.syncError)
    }

    func test_malformedOrFutureCatalogKeepsTheLastProvenSelection() {
        let engine = iCloudSyncEngine.shared
        let priorProviders = engine.providers
        let priorSurfaces = engine.surfaceModels
        let priorLastSyncAt = engine.lastSyncAt
        let priorSyncError = engine.syncError
        defer {
            engine.providers = priorProviders
            engine.surfaceModels = priorSurfaces
            engine.lastSyncAt = priorLastSyncAt
            engine.syncError = priorSyncError
        }

        XCTAssertTrue(engine.applyProviderCatalogStatus(catalog(
            providers: [provider(id: "proven", model: "proven-model")],
            surfaces: [
                "ios": NAProviderSurfaceSelection(
                    providerID: "proven",
                    model: "proven-model",
                    reasoningEffort: "high",
                    serviceTier: "priority"
                )
            ]
        )))
        let provenProviders = engine.providers
        let provenSurfaces = engine.surfaceModels

        let unsupported = NAProviderCatalogStatus(
            version: NAProviderCatalogStatus.currentVersion + 1,
            providers: [],
            surfaces: [:]
        )
        XCTAssertFalse(engine.applyProviderCatalogStatus(try! NAProviderCatalogStatusCodec.encode(unsupported)))
        XCTAssertEqual(engine.providers, provenProviders)
        XCTAssertEqual(engine.surfaceModels, provenSurfaces)
        XCTAssertNotNil(engine.syncError, "a rejected catalog needs visible stale/unavailable evidence")

        XCTAssertFalse(engine.applyProviderCatalogStatus("not json"))
        XCTAssertEqual(engine.providers, provenProviders)
        XCTAssertEqual(engine.surfaceModels, provenSurfaces)
    }

    func test_wireControlsTrimSelectionsButNeverEmitBlankOverrides() {
        let controls = ChatRuntimeControls(
            model: "  model-a  ",
            reasoningEffort: "  high ",
            serviceTier: "  priority ",
            fileAccess: "  workspace ",
            providerId: "  provider-a "
        )
        let metadata = MacBridgeClient.chatSendMetadata(
            controls: controls,
            suppressRemoteUserAppend: true,
            replacementAssistantMessageID: UUID()
        )
        XCTAssertEqual(metadata["model"], "model-a")
        XCTAssertEqual(metadata["reasoningEffort"], "high")
        XCTAssertEqual(metadata["serviceTier"], "priority")
        XCTAssertEqual(metadata["fileAccess"], "workspace")
        XCTAssertEqual(metadata["providerId"], "provider-a")

        let blank = ChatRuntimeControls(
            model: " ", reasoningEffort: "\n", serviceTier: "",
            fileAccess: "\t", providerId: " "
        ).metadata(transport: "icloud")
        for key in ["model", "reasoningEffort", "serviceTier", "fileAccess", "providerId"] {
            XCTAssertNil(blank[key], "\(key) was sent as an empty override instead of allowing the Mac's checked routing snapshot")
        }
        XCTAssertEqual(blank["source"], "ios")
        XCTAssertEqual(blank["transport"], "icloud")
        XCTAssertFalse(blank["routeKey"]?.isEmpty ?? true)
    }
}
