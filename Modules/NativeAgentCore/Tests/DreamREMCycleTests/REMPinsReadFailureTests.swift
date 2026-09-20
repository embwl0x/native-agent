import Foundation
import Testing
@testable import DreamREMCycle

@Test
func REMPinsReader_retainsLastPinsOnUnreadableFileAndRetries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = root.appendingPathComponent("rem_pins.json")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        REMPinsReader._resetCacheForTesting(dataRoot: root)
        try? FileManager.default.removeItem(at: root)
    }
    let first = ["GROWTH.md": [REMPin(id: "first", text: "First", createdAt: "2026-09-01")]]
    let next = ["GROWTH.md": [REMPin(id: "next", text: "Next", createdAt: "2026-09-02")]]
    try JSONEncoder().encode(first).write(to: path)
    #expect(REMPinsReader.read(dataRoot: root) == first)

    let original = try JSONEncoder().encode(next)
    try original.write(to: path)
    let changedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes(
        [.modificationDate: changedDate, .posixPermissions: 0], ofItemAtPath: path.path
    )
    #expect(REMPinsReader.read(dataRoot: root) == first)
    #expect(REMPinsReader.read(dataRoot: root) == first)
    #expect(REMPinsReader._testCacheStats(dataRoot: root).decodeAttempts == 3)

    // Restoring access without changing mtime must retry the same pending bytes.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    #expect(try Data(contentsOf: path) == original)
    #expect(REMPinsReader.read(dataRoot: root) == next)
    try FileManager.default.removeItem(at: path)
    #expect(REMPinsReader.read(dataRoot: root).isEmpty)
}
