import Testing
import Foundation
@testable import PersistenceCore

// Sweep R4 item 5. The chat session index owns its own serialization
// (ChatSessionIndexFile) and therefore could not go through `writeJSON`, so it
// used a bare `Data.write(.atomic)`: crash-safe, but with neither the temp-file
// fsync nor the parent-directory fsync that make the replacement survive power
// loss. `writeDataAtomicDurable` is the missing primitive.

@Suite("Durable atomic data write")
struct DurableAtomicDataWriteTests {

    private func tempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-atomic-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("writes exactly the bytes given, creating intermediate directories")
    func writesExactBytes() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let payload = Data(#"[{"id":"s1"}]"#.utf8)

        try await SwiftNativePersistenceCore().writeDataAtomicDurable(payload, to: path)

        #expect(try Data(contentsOf: path) == payload)
    }

    @Test("replacement leaves no temp file and no partially written target")
    func replacementIsClean() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("sessions.json")
        let persistence = SwiftNativePersistenceCore()

        try await persistence.writeDataAtomicDurable(Data(#"["old"]"#.utf8), to: path)
        try await persistence.writeDataAtomicDurable(Data(#"["new","rows"]"#.utf8), to: path)

        #expect(try Data(contentsOf: path) == Data(#"["new","rows"]"#.utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers == ["sessions.json"], "an atomic replacement must not leave temp files behind")
    }

    @Test("the file is created 0600, like every other PersistenceCore write")
    func writesPrivateMode() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("sessions.json")
        try await SwiftNativePersistenceCore().writeDataAtomicDurable(Data("[]".utf8), to: path)
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    @Test("an unwritable parent surfaces as a thrown error, never a silent no-op")
    func unwritableParentThrows() async throws {
        let root = tempRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let path = root.appendingPathComponent("sessions.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        await #expect(throws: (any Error).self) {
            try await SwiftNativePersistenceCore().writeDataAtomicDurable(Data("[]".utf8), to: path)
        }
    }
}
