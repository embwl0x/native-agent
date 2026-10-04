import AppKit
import CryptoKit
import Foundation
import os
import PersistenceCore

public enum ChatGPTDotIPCTransport {
    public typealias Conversation = @Sendable (URL, AgentPeerContact, [JSONValue], String?) async throws -> JSONValue
    private static let handler = OSAllocatedUnfairLock<Conversation?>(initialState: nil)
    private static let polled = OSAllocatedUnfairLock(initialState: [String: Date]())

    public static func recentSendFile(_ root: URL) -> URL { root.appendingPathComponent("agents/dot-recent-send.json") }

    public static func nextPull(dataRoot: URL, now: Date) -> Date? {
        guard let bytes = try? Data(contentsOf: recentSendFile(dataRoot)),
              let text = try? JSONDecoder().decode(String.self, from: bytes),
              let sent = ISO8601DateFormatter().date(from: text),
              now.timeIntervalSince(sent) >= 0 else { return nil }
        // No end: Dot may research for hours. Every 30 s at first, then every 2 minutes.
        let every: TimeInterval = now.timeIntervalSince(sent) < 600 ? 30 : 120
        return polled.withLock { max(sent.addingTimeInterval(30), ($0[dataRoot.path] ?? sent).addingTimeInterval(every)) }
    }

    public static func takePull(dataRoot: URL, now: Date) -> Bool {
        guard let due = nextPull(dataRoot: dataRoot, now: now), due <= now else { return false }
        return polled.withLock {
            guard due <= now else { return false }
            $0[dataRoot.path] = now
            return true
        }
    }

    public static func installConversation(_ conversation: @escaping Conversation) {
        handler.withLock { $0 = conversation }
    }

    public static func conversation(_ root: URL, _ peer: AgentPeerContact, _ messages: [JSONValue], _ sent: String?) async throws -> JSONValue {
        guard let conversation = handler.withLock({ $0 }) else {
            return .object(["status": .string("unavailable"), "detail": .string("Dot's conversation is unavailable.")])
        }
        return try await conversation(root, peer, messages, sent)
    }

    public static let updatedDetail = "ChatGPT app updated; Dot messaging needs a check"
    private static let checked = OSAllocatedUnfairLock(initialState: (stamp: "", receipt: JSONValue.null, retryAfter: Date.distantPast))

    public static func owns(_ peer: AgentPeerContact) -> Bool {
        peer.transport == .mcpHost && AgentPeerStore.hostRowID(peer.endpoint) == "chatgpt-dot"
    }

    public static var readiness: JSONValue {
        let local = localState()
        guard local.status == "not_checked" else { return unavailable(local.detail) }
        return checked.withLock { value in
            guard value.stamp == local.stamp,
                  case .object(let fields) = value.receipt,
                  fields["status"] == .string("available") || Date() < value.retryAfter else {
                return unavailable("Dot messaging has not been checked yet.", status: "not_checked")
            }
            return value.receipt
        }
    }

    public static var available: Bool {
        if case .object(let value) = readiness { return value["status"] == .string("available") }
        return false
    }

    public static var detail: String {
        if case .object(let value) = readiness, case .string(let detail)? = value["detail"] { return detail }
        return "In-house ChatGPT Dot · two-way"
    }

    public static var stamp: String { localState().stamp }

    public static func retainHandshake(_ receipt: JSONValue, stamp: String) {
        guard !stamp.isEmpty, stamp == self.stamp else { return }
        checked.withLock { $0 = (stamp, receipt, Date().addingTimeInterval(15)) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static let didChange = Notification.Name("ChatGPTDotIPCTransport.didChange")

    private static func unavailable(_ detail: String, status: String = "unavailable") -> JSONValue {
        .object(["status": .string(status), "sent": .bool(false), "completed": .bool(false), "detail": .string(detail)])
    }

    private static func localState() -> (status: String, stamp: String, detail: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        guard running.count == 1, let app = running.first, let url = app.bundleURL else {
            return ("unavailable", "", "ChatGPT app isn't running; Dot messaging is unavailable.")
        }
        guard let infoData = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.openai.codex" else {
            return ("unavailable", "", updatedDetail)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let socket = home.appendingPathComponent(".codex/ipc/ipc.sock").path
        guard let archive = try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("Contents/Resources/app.asar").path),
              let modified = archive[.modificationDate] as? Date, let size = archive[.size] as? NSNumber,
              let attributes = try? FileManager.default.attributesOfItem(atPath: socket),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let data = try? Data(contentsOf: home.appendingPathComponent(".codex/.codex-global-state.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atoms = root["electron-persisted-atom-state"] as? [String: Any],
              let primary = atoms["primary-aeon-selection-v1"] as? [String: Any],
              let response = primary["response"] as? [String: Any],
              let selection = response["selection"] as? [String: Any], selection["available"] as? Bool == true,
              let account = primary["accountId"] as? String,
              let aeon = selection["aeon_id"] as? String, aeon.hasPrefix(account + "~"),
              let thread = selection["thread_id"] as? String, !thread.isEmpty,
              let room = selection["messaging_room_id"] as? String, !room.isEmpty else {
            return ("unavailable", "", "Dot's current conversation cannot be followed.")
        }
        let identity = [url.path, String(app.processIdentifier), inode.stringValue, String(modified.timeIntervalSince1970),
            size.stringValue, account, aeon, thread, room].joined(separator: "\n")
        return ("not_checked", SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined(), "")
    }
}
