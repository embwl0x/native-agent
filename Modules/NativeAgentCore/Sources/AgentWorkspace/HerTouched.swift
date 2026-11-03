import AppKit
import Foundation
import NativeAgentShared
import MacControl
import NativeAgentCore
import PersistenceCore
import Desk
import StandingBots
import ChatSessionWork
import Transcripts
import ChatToolParsing
import Darwin
// Blueprint: | `HerTouched.swift` | Checked retained touched-application facts; only missing first-use storage is empty, damaged bytes are preserved and writes commit before cache publication |

/// Her recent windows, in memory and in data/her_screen/touched.json.
final class HerTouched: @unchecked Sendable {
    static let shared = HerTouched()
    private let lock = NSLock()
    private var byRoot: [String: [HerScreen.Touched]] = [:]

    private func file(_ root: URL) -> URL { root.appendingPathComponent("her_screen/touched.json") }

    private func load(_ root: URL) throws -> [HerScreen.Touched] {
        if let rows = byRoot[root.standardizedFileURL.path] { return rows }
        let rows: [HerScreen.Touched]
        do { rows = try JSONDecoder().decode([HerScreen.Touched].self, from: Data(contentsOf: file(root))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { rows = [] }
        byRoot[root.standardizedFileURL.path] = rows
        return rows
    }

    func rows(_ root: URL) throws -> [HerScreen.Touched] { try lock.withLock { try load(root) } }

    func update(_ root: URL, _ body: (inout [HerScreen.Touched]) -> Void) throws {
        try lock.withLock {
            var rows = try load(root)
            body(&rows)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(rows), to: file(root))
            byRoot[root.standardizedFileURL.path] = rows
        }
    }
}
