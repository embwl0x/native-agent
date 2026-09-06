import Foundation
import Testing
import PersistenceCore

@Test func recollectionScanReadsOnlyAppendedBytesAndKeepsLastSummary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("recollection-scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("fixture.jsonl")
    let row = #"{"id":"summary","content":"Our shared conversation","metadata":{"kind":"compaction_summary"}}"# + "\n"
    try Data((row + String(repeating: "{\"content\":\"ordinary turn\"}\n", count: 10_000)).utf8).write(to: path)
    let first = try ChatSessionRecollections.scanLatest(path: path, sessionId: "fixture")
    let appended = Data("{\"content\":\"one more turn\"}\n".utf8)
    let writer = try FileHandle(forWritingTo: path)
    try writer.seekToEnd()
    try writer.write(contentsOf: appended)
    try writer.close()
    let second = try ChatSessionRecollections.scanLatest(path: path, sessionId: "fixture",
                                                        offset: first.nextOffset, previous: first.recollection)
    #expect(second.recollection == first.recollection)
    #expect(second.recollection?.rowId == "summary")
    #expect(second.bytesRead == appended.count)
}
