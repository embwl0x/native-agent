import Foundation
import Testing
@testable import PersistenceCore

/// EVAL COVERAGE — `core.persistence.replaceJSONL.durabilityDivergence`.
///
/// `SnapshotTailOpLog` is snapshot-before-truncate. Its inherited protocol
/// replacement must serialize exactly as the native writer AND complete the
/// parent-directory durability phase before it reports success.
@Suite("Persistence default durability boundary")
struct PersistenceDefaultDurabilityEvalTests {
    @Test func minimalInheritedConformerMatchesNativeBytesAndFlushesTheParentDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("persistence-default-durability-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inheritedOps = root.appendingPathComponent("inherited.jsonl")
        let nativeOps = root.appendingPathComponent("native.jsonl")
        let base = root.appendingPathComponent("base.json")
        let snapshot: JSONValue = .object(["snapshot": .bool(true)])
        let rows: [JSONValue] = [
            .object(["op": .string("retained-tail"), "n": .int(7)]),
            .object(["op": .string("second-tail"), "n": .int(8)]),
        ]
        let phases = AtomicWritePhaseCapture()

        try await SwiftNativePersistenceCore.$atomicWriteDurabilityObserver.withValue({ phase in
            phases.record(phase)
        }) {
            try await SnapshotTailOpLog.commitCompaction(
                baseJSON: snapshot,
                tailRows: rows,
                basePath: base,
                opsPath: inheritedOps,
                persistence: MinimalInheritedPersistence()
            )
        }
        try await SwiftNativePersistenceCore().replaceJSONL(rows, to: nativeOps)

        #expect(try Data(contentsOf: inheritedOps) == Data(contentsOf: nativeOps))
        #expect(try Data(contentsOf: base) == snapshot.serializedData(pretty: true))
        // This minimal conformer deliberately owns its base write. The ONE
        // observed pair is therefore the inherited truncate itself; a bare
        // Data.write replacement would produce zero native durability phases.
        #expect(phases.snapshot().filter { $0 == .temporaryFileSynced }.count == 1)
        #expect(phases.snapshot().filter { $0 == .parentDirectorySynced }.count == 1)
    }
}

/// Implements only the original five persistence requirements. In particular,
/// it does not implement `replaceJSONL` or `writeDataAtomicDurable`; both must
/// dispatch to the safe production defaults.
private struct MinimalInheritedPersistence: PersistenceCoreProtocol {
    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue { defaultValue }

    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try value.serializedData(pretty: true).write(to: path, options: .atomic)
    }

    func appendJSONL(_ record: JSONValue, to path: URL) async throws {}

    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] { [] }

    func readJSONL(_ path: URL) async throws -> [JSONValue] { [] }
}

private final class AtomicWritePhaseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [SwiftNativePersistenceCore.AtomicWriteDurabilityPhase] = []

    func record(_ phase: SwiftNativePersistenceCore.AtomicWriteDurabilityPhase) {
        lock.withLock { phases.append(phase) }
    }

    func snapshot() -> [SwiftNativePersistenceCore.AtomicWriteDurabilityPhase] {
        lock.withLock { phases }
    }
}
