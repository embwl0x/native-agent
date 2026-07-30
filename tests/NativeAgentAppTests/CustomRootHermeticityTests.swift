import CognitiveSubstrate
import Context
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Custom-root hermeticity", .serialized)
struct CustomRootHermeticityTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgent-CustomRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func cognitionPursuitIntentReadsInjectedDeskRoot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let why = "fixture pursuit lives only in this body"
        let done = "fixture pursuit reaches its bounded finish"
        let pursuit = Pursuit(
            why: why,
            evidence: PromotionDossier(citations: [
                .feltSalience(dates: ["2026-07-12", "2026-07-13"]),
            ]),
            doneLooksLike: done,
            abandonCondition: "stop if the fixture becomes irrelevant"
        )
        _ = try await SwiftNativeDeskStore(dataRoot: root).openPursuit(
            project: "hermeticity",
            title: "custom-root pursuit",
            pursuit: pursuit
        )
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: CognitiveConfiguration()
        )

        await runtime.bootstrap()
        let signals = await runtime.attentionSignals(at: Date())

        #expect(signals?.activeTask == why)
        #expect(signals?.goal == done)
    }

    @Test func contextPersonaProviderReadsOnlyInjectedPersonaRoot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = root
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: identity, withIntermediateDirectories: true)
        let marker = "fixture-context-soul-\(UUID().uuidString)"
        try Data(marker.utf8).write(to: identity.appendingPathComponent("SOUL.md"))

        let provider = PersonaContextFlowProvider(dataRoot: root, mode: .shadow)
        let mirrors = try await provider.requiredDocumentMirrors()
        let rendered = mirrors.flatMap(\.documents).map(\.text).joined(separator: "\n")

        #expect(rendered.contains(marker))
    }

    @Test func legacyChatReadersUseInjectedRoot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "fixture-session"
        let messages = root
            .appendingPathComponent("chat/messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        try Data("{\"role\":\"assistant\",\"content\":\"alternate-root-message\",\"createdAt\":\"2026-07-13T00:00:00Z\"}\n".utf8)
            .write(to: messages.appendingPathComponent("\(sessionID).jsonl"))
        let receipts = root.appendingPathComponent("context/receipts.jsonl")
        try FileManager.default.createDirectory(
            at: receipts.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"sessionId\":\"\(sessionID)\",\"fingerprint\":\"alternate-root-receipt\"}\n".utf8)
            .write(to: receipts)

        let rows = try await NativeClient.getChatMessages(
            sessionId: sessionID,
            dataRoot: root
        )
        let receipt = try await NativeClient.getLatestContextReceipt(
            sessionId: sessionID,
            dataRoot: root
        )

        #expect(rows.map(\.content) == ["alternate-root-message"])
        #expect(receipt.fingerprint == "alternate-root-receipt")
    }

    @Test func legacyProviderHelpersUseInjectedRoot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex_home", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data(#"{"fixture":{"model":"alternate-root-model","reasoningEffort":"low"}}"#.utf8)
            .write(to: providers.appendingPathComponent("surfaces.json"))
        try Data(#"{"tokens":{"access_token":"fixture-not-a-real-token"}}"#.utf8)
            .write(to: codexHome.appendingPathComponent("auth.json"))
        let client = NativeClient(baseURL: "http://127.0.0.1")

        let preferences = try await client.getModelPreferences(dataRoot: root)
        let verification = try await NativeClient.verifyCodex(dataRoot: root)
        let authStatus = try await client.getCodexAuthStatus(dataRoot: root)

        #expect(preferences.preferences.contains(where: {
            $0.surface == "fixture" && $0.model == "alternate-root-model"
        }))
        #expect(verification.ok)
        #expect(authStatus.appOwnedLoggedIn)
        #expect(authStatus.codexHome == codexHome.path)
        #expect(NativeClient.codexDeviceLoginHome(dataRoot: root)
            == codexHome.standardizedFileURL)
    }

    /// Thermal state and low-power mode are the body read's only process-global
    /// senses. Under a custom root they must read nominal: a warm host would
    /// otherwise set `resourceInhibited` on the residual-repair opportunity,
    /// which nils every candidate wake and silently disarms the residual
    /// deadline in any embedded or test body.
    @Test func bodyReadDoesNotSenseHostThermalStateUnderCustomRoot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 7_100_000)

        let read = NativeCognitionRuntime.makeOrganismBodyRead(dataRoot: root, now: now)

        #expect(read.resourcePressure == .nominal)
        #expect(read.resourcePressureReading?.category == .nominal)
        #expect(read.resourcePressureReading?.lowPowerMode == false)
    }
}
