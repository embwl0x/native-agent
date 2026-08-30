import Foundation
import NativeAgentShared
import ProviderRouting
import Testing
@testable import NativeAgentApp

private actor MobileProviderSnapshotTransport: DeviceSyncTransport {
    nonisolated let role: NADeviceRole = .mac
    private(set) var catalogs: [String] = []

    func send(_ message: BridgeMessage) async throws {}
    func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async {}
    func publishPairing(secret: Data) async throws {}
    func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async {}
    func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async {}
    func setStatus(key: String, value: String) async throws {
        if key == NAProviderCatalogStatusCodec.statusKey { catalogs.append(value) }
    }
}

@Suite("Mobile provider projections use checked routing snapshots")
struct MobileProviderSnapshotTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileProviderSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func select(_ routing: SwiftNativeProviderRouting, model: String = "gpt-5.6-sol") async throws {
        try await routing.saveSurfaceConfiguration(
            surface: "ios", model: model, reasoningEffort: "high",
            serviceTier: "priority", providerId: "openai_oauth_direct"
        )
    }

    @Test func preferenceReaderReturnsTheCanonicalRecoveredTupleAtTheInjectedRoot() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        try await select(routing)
        let snapshot = try await routing.checkedRoutingSnapshot()
        let result = try await NativeClient(baseURL: "").getModelPreferences(dataRoot: root)
        #expect(result.preferences.map(\.surface) == snapshot.preferences.keys.sorted())
        for row in result.preferences {
            let canonical = try #require(snapshot.preferences[row.surface])
            #expect(row.model == canonical.model)
            #expect(row.reasoningEffort == canonical.reasoningEffort)
            #expect(row.serviceTier == canonical.serviceTier)
        }
        #expect(snapshot.activeProviders["ios"] == "openai_oauth_direct")
    }

    @Test(arguments: [("surfaces.json", "not-json"), ("surfaces.json", "[]"), ("active.json", "[]")])
    func corruptSavedRoutingThrowsInsteadOfPublishingAnEmptySuccess(fixture: (String, String)) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        try await select(routing)
        let path = root.appendingPathComponent("providers/\(fixture.0)")
        let damaged = Data(fixture.1.utf8)
        try damaged.write(to: path)
        do {
            _ = try await NativeClient(baseURL: "").getModelPreferences(dataRoot: root)
            Issue.record("Damaged routing was treated as healthy preferences")
        } catch {}
        #expect(try Data(contentsOf: path) == damaged)
    }

    @Test func catalogProjectionDoesNotRereadProviderIdentityAfterSnapshotCapture() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        try await select(routing)
        let captured = try await routing.checkedRoutingSnapshot()
        try await routing.saveSurfaceConfiguration(
            surface: "ios", model: "gpt-5.6", reasoningEffort: "low",
            serviceTier: "default", providerId: "openai"
        )
        let next = try await routing.checkedRoutingSnapshot()
        #expect(next.activeProviders["ios"] == "openai")
        let projection = iCloudBridge.providerSurfaceSelections(from: captured)
        #expect(projection["ios"]?.providerID == "openai_oauth_direct")
        #expect(projection["ios"]?.model == captured.preferences["ios"]?.model)
        #expect(projection["ios"]?.reasoningEffort == captured.preferences["ios"]?.reasoningEffort)
        #expect(projection["ios"]?.serviceTier == captured.preferences["ios"]?.serviceTier)
    }

    @Test @MainActor
    func realCatalogPublicationPreservesLastGoodPhoneStateOnDamagedRoutingAndRecovers() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        try await select(routing)
        let transport = MobileProviderSnapshotTransport()
        let bridge = iCloudBridge(testDeviceTransport: transport, testDataRoot: root)
        #expect(await bridge.publishProviderCatalogStatus(providers: []))
        let firstWrites = await transport.catalogs
        #expect(firstWrites.count == 1)
        let first = try NAProviderCatalogStatusCodec.decode(try #require(firstWrites.first))
        #expect(first.surfaces["ios"]?.providerID == "openai_oauth_direct")

        let path = root.appendingPathComponent("providers/surfaces.json")
        let original = try Data(contentsOf: path)
        let damaged = Data("damaged-picker".utf8)
        try damaged.write(to: path)
        #expect(await bridge.publishProviderCatalogStatus(providers: []) == false)
        #expect(await transport.catalogs == firstWrites)
        #expect(try Data(contentsOf: path) == damaged)

        try original.write(to: path)
        #expect(await bridge.publishProviderCatalogStatus(providers: []))
        #expect(await transport.catalogs == firstWrites)
        try await select(routing, model: "gpt-5.6-luna")
        #expect(await bridge.publishProviderCatalogStatus(providers: []))
        let recoveredWrites = await transport.catalogs
        #expect(recoveredWrites.count == 2)
        let recovered = try NAProviderCatalogStatusCodec.decode(try #require(recoveredWrites.last))
        #expect(recovered.surfaces["ios"]?.model == "gpt-5.6-luna")
        #expect(recovered.surfaces["ios"]?.providerID == "openai_oauth_direct")
    }
}
