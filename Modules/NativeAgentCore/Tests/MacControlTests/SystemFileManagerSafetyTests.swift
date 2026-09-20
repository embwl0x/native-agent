import Foundation
import Testing
@testable import MacControl
import Darwin

@Test func systemFileAdapterRejectsPipesAndKeepsBoundedReads() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pipe = root.appendingPathComponent("pipe")
    #expect(mkfifo(pipe.path, 0o600) == 0)
    let adapter = SystemFileManagerAdapter()
    #expect(throws: (any Error).self) { try adapter.readData(at: pipe, maxBytes: 10) }
    #expect(throws: (any Error).self) { try adapter.writeData(Data([1]), to: pipe, append: true) }
    let file = root.appendingPathComponent("file")
    try adapter.writeData(Data("before".utf8), to: file, append: false)
    try adapter.writeData(Data("after".utf8), to: file, append: false)
    try adapter.writeData(Data("!".utf8), to: file, append: true)
    #expect(try adapter.readData(at: file, maxBytes: 3) == Data("aft".utf8))
    #expect(try adapter.readData(at: file, maxBytes: 100) == Data("after!".utf8))
    #expect(throws: (any Error).self) { try adapter.writeData(Data([1]), to: root, append: false) }
    #expect(try adapter.readData(at: file, maxBytes: 100) == Data("after!".utf8))
}
