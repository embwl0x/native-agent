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
// Blueprint: | `AgentTouched.swift` | commit before publishing retained app facts; preserve unreadable bytes |

/// The agent's recent windows, in memory and in touched.json under the data root's screen folder.
final class AgentTouched: @unchecked Sendable {
    static let shared = AgentTouched()
    private let lock = NSLock()
    private var byRoot: [String: [AgentScreen.Touched]] = [:]

    /// The retained recent-windows file, for readers that watch it.
    static func path(_ root: URL) -> URL { shared.file(root) }

    private func file(_ root: URL) -> URL { root.appendingPathComponent("her_screen/touched.json") }

    private func load(_ root: URL) throws -> [AgentScreen.Touched] {
        if let rows = byRoot[root.standardizedFileURL.path] { return rows }
        let rows: [AgentScreen.Touched]
        do { rows = try JSONDecoder().decode([AgentScreen.Touched].self, from: Data(contentsOf: file(root))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { rows = [] }
        byRoot[root.standardizedFileURL.path] = rows
        return rows
    }

    func rows(_ root: URL) throws -> [AgentScreen.Touched] { try lock.withLock { try load(root) } }

    func update(_ root: URL, _ body: (inout [AgentScreen.Touched]) -> Void) throws {
        try lock.withLock {
            var rows = try load(root)
            body(&rows)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(rows), to: file(root))
            byRoot[root.standardizedFileURL.path] = rows
        }
    }
}
