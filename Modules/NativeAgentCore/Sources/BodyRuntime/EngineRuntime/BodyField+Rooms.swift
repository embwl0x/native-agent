import AppKit
import Foundation
import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

// Blueprint: | `BodyField+Rooms.swift` | Room-facing console and application snapshot and the body's four-hour window history |

extension BodyField {
    func closeRooms() async {
        room = nil
        let recent = windows
        windows = nil
        await recent?.close()
    }

    func refreshRoom(front: String?, opened: [pid_t: String]) {
        let session = defaultMacSessionStateSource().currentState()
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard app.activationPolicy == .regular, !PersonOnlyWindows.isOwnProcess(app.processIdentifier),
                  !app.isTerminated, let name = app.localizedName else { return nil }
            return AgentScreen.clip(name, 24) + (opened[app.processIdentifier] == name ? " (opened by me)" : "")
        }
        let next = MacRoom(front: front, readable: session.sessionReadable,
                           onConsole: session.onConsole, locked: session.screenIsLocked,
                           running: Set(apps).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        guard room != next else { return }
        room = next
        NotificationCenter.default.post(AgentWorkspaceScreenPreview.DidChange())
    }

    func macRoom(_ root: URL) throws -> MacRoom {
        guard !stopped else { throw PartCallError(code: "mac_body_stopped", message: "The Mac body field has stopped.") }
        guard root == self.root, let room else { throw Self.roomUnavailable }
        return room
    }

    func recentWindows(_ root: URL) async throws -> [MacRoomWindow] {
        try ensureRoomOpen()
        guard root == self.root, let windows else { throw Self.roomUnavailable }
        return try await windows.recent()
    }

    func saw(_ window: MacRoomWindow, in root: URL, acted: Bool) async throws {
        try ensureRoomOpen()
        guard root == self.root, let windows else { throw Self.roomUnavailable }
        try await windows.record(window, acted: acted)
    }

    private static let roomUnavailable = PartCallError(code: "mac_body_unavailable", message: "The Mac body field is unavailable for this workspace.")

    private func ensureRoomOpen() throws {
        guard windows != nil else { throw AgentScreen.NameFailure("The Mac body field is closed.") }
    }

    actor Windows {
        private let file: URL
        private var rows: [MacRoomWindow]?
        private var closed = false
        init(_ root: URL) {
            let file = root.appendingPathComponent("mind/mac_windows.json")
            self.file = file
        }

        func recent() async throws -> [MacRoomWindow] {
            return try load()
        }

        private func load() throws -> [MacRoomWindow] {
            guard !closed else { throw CancellationError() }
            if rows == nil {
                do { rows = try JSONDecoder().decode([MacRoomWindow].self, from: Data(contentsOf: file)) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { rows = [] }
            }
            let now = Date()
            return (rows ?? []).filter { $0.isRecent(at: now) }
        }

        func record(_ window: MacRoomWindow, acted: Bool) async throws {
            var next = try load()
            guard acted || next.contains(where: { $0.app == window.app }) else { return }
            if next.contains(where: { $0.app == window.app && $0.kind == window.kind && $0.at > window.at }) { return }
            next.removeAll { $0.app == window.app && $0.kind == window.kind }
            next = Array((next + [window]).sorted { $0.at > $1.at }.prefix(8))
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(next), to: file)
            rows = next
            changed()
        }

        private func changed() {
            NotificationCenter.default.post(BodyField.WindowsChanged())
            NotificationCenter.default.post(AgentWorkspaceScreenPreview.DidChange())
        }

        func close() async {
            closed = true
        }
    }
}
