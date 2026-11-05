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
// Blueprint: | `AgentNamed.swift` | The agent's named room bindings and first-draw state |

final class AgentNamed: @unchecked Sendable {
    static let shared = AgentNamed()
    private let cache = AgentRoomCache<AgentWorkspaceAction>(lasting: true)
    private let drawn = AgentRoomCache<Bool>()

    func keep(_ root: URL, _ names: [String: AgentWorkspaceAction], room: String, scope: String) {
        let items = names.filter { room != "windows" && $0.key.split(separator: ".").last.flatMap { Int($0) } != nil }
        cache.keep(root, items, room: room)
        cache.keep(root, names.filter { items[$0.key] == nil }, room: scope + "\u{0}" + room, scope: scope)
    }

    func action(_ root: URL, _ name: String, scope: String) -> AgentWorkspaceAction? {
        cache.value(root, scope + "\u{0}" + name) ?? cache.value(root, name)
    }

    /// A withdrawn verb cannot survive its item's redraw.
    func withdrawn(_ root: URL, _ name: String, scope: String) -> Bool { cache.withdrawn(root, scope + "\u{0}" + name) }

    func removeSession(_ key: String) { cache.removeSession(key); drawn.removeSession(key) }

    func firstDraw(_ root: URL, _ room: String, scope: String) -> Bool {
        let room = scope + "\u{0}" + room
        if drawn.value(root, room) != nil { return false }
        drawn.keep(root, [room: true], room: room)
        return true
    }
}
