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
// Blueprint: | `HerTouched.swift` | Retained touched-application facts |

/// Her recent windows, in memory and in data/her_screen/touched.json.
final class HerTouched: @unchecked Sendable {
    static let shared = HerTouched()
    private let lock = NSLock()
    private var byRoot: [String: [HerScreen.Touched]] = [:]

    private func file(_ root: URL) -> URL { root.appendingPathComponent("her_screen/touched.json") }

    private func load(_ root: URL) -> [HerScreen.Touched] {
        if let rows = byRoot[root.standardizedFileURL.path] { return rows }
        let rows = (try? Data(contentsOf: file(root))).flatMap { try? JSONDecoder().decode([HerScreen.Touched].self, from: $0) } ?? []
        byRoot[root.standardizedFileURL.path] = rows
        return rows
    }

    func rows(_ root: URL) -> [HerScreen.Touched] { lock.withLock { load(root) } }

    func update(_ root: URL, _ body: (inout [HerScreen.Touched]) -> Void) {
        lock.withLock {
            var rows = load(root)
            body(&rows)
            byRoot[root.standardizedFileURL.path] = rows
            try? SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(rows), to: file(root))
        }
    }
}
