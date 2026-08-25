import Context
import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

private final class Wave8DispatchPressureSource:
    NativeContextMemoryPressureDispatchSource,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var event: DispatchSource.MemoryPressureEvent = []
    private var handler: (@Sendable () -> Void)?
    private(set) var resumeCount = 0
    private(set) var cancelCount = 0

    var data: DispatchSource.MemoryPressureEvent { lock.withLock { event } }
    func setEventHandler(handler: @escaping @Sendable () -> Void) { lock.withLock { self.handler = handler } }
    func resume() { lock.withLock { resumeCount += 1 } }
    func cancel() { lock.withLock { cancelCount += 1 } }

    func fire(_ event: DispatchSource.MemoryPressureEvent) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            self.event = event
            return self.handler
        }
        handler?()
    }
}

private struct Wave8DispatchPressureSourceFactory: NativeContextMemoryPressureDispatchSourceFactory {
    let source: Wave8DispatchPressureSource
    func makeSource(queue: DispatchQueue) -> any NativeContextMemoryPressureDispatchSource { source }
}

private struct Wave8EmbeddingProvider: EmbeddingProvider {
    let dimensions = 8
    let modelId = "context-wave8-embedding"
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: dimensions)
            vector[text.utf8.reduce(0) { ($0 + Int($1)) % dimensions }] = 1
            return vector
        }
    }
}

private struct Wave8RuntimeFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextReportsOnlyWave8-\(UUID().uuidString)", isDirectory: true)
        // Isolated runtimes select an identity directory below `persona/`.
        // Seed the canonical identity there so ContextFlow can publish a real
        // generation before the pressure source asks it to trim one.
        let persona = root
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        // ContextFlow publishes only after the PersonaCompiler can produce its
        // complete canonical mirror. SOUL/VOICE form the active stable kernel;
        // USER/GROWTH/AGENTS are the remaining required source atoms in that
        // same generation (MEMORY is deliberately optional).
        let canonicalDocuments = [
            "SOUL.md": "# SOUL\nWave 8 fixture identity.",
            "VOICE.md": "# VOICE\nKeep boundary evidence exact.",
            "USER.md": "# USER\nThe operator needs greenhouse calibration evidence.",
            "GROWTH.md": "# GROWTH\nKeep durable context coherent.",
            "AGENTS.md": "# AGENTS\nUse the canonical context boundary.",
        ]
        for (name, body) in canonicalDocuments {
            try body.write(
                to: persona.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func wave8Memory(id: String, text: String) -> MemoryV2.MemoryRecord {
    MemoryV2.MemoryRecord(id: id, text: text, layer: "semantic", memoryKind: "fact", createdAt: "2026-08-24T12:00:00Z", sourceRunId: "context-wave8-eval", status: "active", confidence: 0.9)
}

private func seedWave8WarmMemory(_ storage: InMemoryMemoryStorage) async throws {
    let prefix = "The greenhouse calibration record has durable evidence for dawn irrigation. "
    let padding = String(repeating: "calibration ", count: 1_300)
    // Each selected memory is represented in both its warm arena entry and
    // the hot selection index. 700 padded rows overflow the 32 MiB arena
    // before it can publish any generation, which correctly leaves prepare
    // unavailable but never exercises the pressure path. 400 rows keep the
    // real snapshot below the hard budget while still above warning's 16 MiB
    // trim target, so this test proves a genuine eviction receipt.
    for index in 0..<400 {
        _ = try await storage.insert(
            record: wave8Memory(id: "record-wave8-pressure-\(index)", text: "\(prefix)\(index) \(padding)"),
            embedding: nil
        )
    }
}

@Suite("core.context reports-only Wave 8", .serialized)
struct ContextReportsOnlyWave8EvalTests {
    // Ledger row: context.runtime.memoryPressureSource
    @Test("the runtime Dispatch pressure path starts, trims its real arena, records the receipt, and cancels")
    func runtimeDispatchPressureLifecycleAndTrim() async throws {
        let fixture = try Wave8RuntimeFixture()
        defer { fixture.cleanUp() }
        let storage = InMemoryMemoryStorage()
        try await seedWave8WarmMemory(storage)
        let source = Wave8DispatchPressureSource()
        let observer = DispatchContextMemoryPressureObserver(sourceFactory: Wave8DispatchPressureSourceFactory(source: source))
        let runtime = NativeContextFlowRuntime(
            dataRoot: fixture.root,
            configurationOverride: NativeContextFlowConfiguration(mode: .active, budget: .mib32),
            memoryOverride: SwiftNativeMemoryV2(embedder: Wave8EmbeddingProvider(), storage: storage),
            memoryPressureObserver: observer
        )
        await runtime.start()
        #expect(await runtime.memoryPressureSourceIsInstalled())
        #expect(source.resumeCount == 1)

        // Pressure only trims a published arena generation. Prepare one real
        // turn first, so a missing generation is an explicit setup failure
        // instead of being silently collapsed by the runtime's receipt path.
        _ = try await runtime.prepareContextTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "What should I know about greenhouse calibration?"
        ))

        source.fire(.warning)
        await runtime.stop()
        let receipt = try #require(await runtime.memoryPressureReceipt())
        #expect(receipt.pressure == .warning)
        #expect(receipt.afterLogicalBytes < receipt.beforeLogicalBytes)
        let storedReceipts = try await ContextSQLiteStore(dataRoot: fixture.root).recentReceipts()
        let storedReceipt = try #require(storedReceipts.first(where: { $0.kind == .pressure }))
        #expect(storedReceipt.details["pressure"] == ContextArenaPressure.warning.rawValue)
        #expect(storedReceipt.details["after_bytes"] == String(receipt.afterLogicalBytes))
        #expect(!(await runtime.memoryPressureSourceIsInstalled()))
        #expect(source.cancelCount == 1)
    }

    // Ledger row: runtime.attachMemoryProvenance
    @Test("runtime live and frozen preparation expose a partial provenance miss without changing either packet")
    func runtimePreparationReportsPartialMemoryProvenance() async throws {
        let fixture = try Wave8RuntimeFixture()
        defer { fixture.cleanUp() }
        let storage = InMemoryMemoryStorage()
        _ = try await storage.insert(record: wave8Memory(id: "record-wave8-a", text: "The greenhouse irrigation schedule runs at dawn and needs calibration."), embedding: nil)
        _ = try await storage.insert(record: wave8Memory(id: "record-wave8-b", text: "The greenhouse irrigation sensor reports humidity before dawn calibration."), embedding: nil)
        let provenance = MemoryAtomRecordIndex()
        let runtime = NativeContextFlowRuntime(
            dataRoot: fixture.root,
            configurationOverride: NativeContextFlowConfiguration(mode: .active, budget: .mib32),
            memoryOverride: SwiftNativeMemoryV2(embedder: Wave8EmbeddingProvider(), storage: storage),
            memoryProvenanceIndex: provenance
        )
        let request = ContextTurnRequest(surface: .chat, origin: .localAuthenticated, userMessage: "What should I know about greenhouse dawn calibration?")

        let full = try await runtime.prepareContextTurn(request)
        let selectedMemoryAtoms = full.packet.selectedItems.compactMap { item -> ContextAtomID? in
            switch item.pointer.kind {
            case .memory, .correction: return item.pointer.atomID
            default: return nil
            }
        }
        #expect(selectedMemoryAtoms.count >= 2)
        #expect(Set(full.selectedMemoryRecordIDs) == Set(["record-wave8-a", "record-wave8-b"]))
        let fullResolution = try #require(await runtime.memoryProvenanceResolution())
        #expect(fullResolution.requestedMemoryAtomCount >= 2)
        #expect(fullResolution.resolvedMemoryAtomCount == fullResolution.requestedMemoryAtomCount)
        #expect(fullResolution.unresolvedMemoryAtomCount == 0)

        let retainedRecordID = try #require(full.selectedMemoryRecordIDs.first)
        let retainedAtomID = try #require(selectedMemoryAtoms.first)
        provenance.replaceAll([retainedAtomID: retainedRecordID])

        let live = try await runtime.prepareContextTurn(request)
        let liveResolution = try #require(await runtime.memoryProvenanceResolution())
        #expect(liveResolution.requestedMemoryAtomCount >= 2)
        #expect(liveResolution.resolvedMemoryAtomCount == 1)
        #expect(liveResolution.unresolvedMemoryAtomCount >= 1)
        #expect(live.selectedMemoryRecordIDs == [retainedRecordID])
        #expect(liveResolution.packetUnchanged)

        let frozen = try await runtime.prepareFrozenContextTurn(request)
        let frozenResolution = try #require(await runtime.memoryProvenanceResolution())
        #expect(frozenResolution.requestedMemoryAtomCount >= 2)
        #expect(frozenResolution.resolvedMemoryAtomCount == 1)
        #expect(frozenResolution.unresolvedMemoryAtomCount >= 1)
        #expect(frozen.selectedMemoryRecordIDs == [retainedRecordID])
        #expect(frozenResolution.packetUnchanged)
        await runtime.stop()
    }
}
