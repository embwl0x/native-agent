import Foundation
import os
import PersistenceCore
// Blueprint: | `ChatGPTDotIPCTransport.swift` | `ChatGPTDotIPCTransport` enum; `listen`, `reconnect`, `stop`, `readiness`; retained socket observation and helper pipes close on the delegation runner's shutdown; generation guards reject old callbacks, accepted room deliveries retain their handles until exit |

public enum ChatGPTDotIPCTransport {
    public typealias Conversation = @Sendable (URL, AgentPeerContact, [JSONValue], String?, [String: JSONValue]?) async throws -> JSONValue
    private static let handler = OSAllocatedUnfairLock<Conversation?>(initialState: nil)

    public static func installConversation(_ conversation: @escaping Conversation) {
        handler.withLock { $0 = conversation }
    }

    public static func conversation(_ root: URL, _ peer: AgentPeerContact, _ messages: [JSONValue], _ sent: String?, window: [String: JSONValue]? = nil) async throws -> JSONValue {
        guard let conversation = handler.withLock({ $0 }) else {
            return .object(["status": .string("unavailable"), "detail": .string("Dot's conversation is unavailable.")])
        }
        return try await conversation(root, peer, messages, sent, window)
    }

    public static func owns(_ peer: AgentPeerContact) -> Bool {
        peer.transport == .mcpHost && AgentPeerStore.hostRowID(peer.endpoint) == "chatgpt-dot"
    }

    /// Dot's state is the listener's last word, never a cached check.
    public static var readiness: JSONValue { listener.withLock { $0.state } }

    public static var available: Bool {
        if case .object(let value) = readiness { return value["status"] == .string("available") }
        return false
    }

    /// Dot is inbound only (User 10-16): he reaches her by running the local
    /// message command on this Mac; she cannot start a message to him, since
    /// ChatGPT 26.1013 and later keeps his conversation in its cloud and no
    /// window here owns it. Not a broken reply path, nothing to repair. The
    /// listener's word is the reason; should ChatGPT ever hand the
    /// conversation back to a local window, sends work again by themselves.
    public static var inboundOnly: Bool {
        guard case .object(let value) = readiness else { return true }
        // Loading is a moment, not a way: a send then waits, as it always did.
        return ![.string("available"), .string("not_checked"), .string("loading")].contains(value["status"] ?? .null)
    }

    public static var detail: String {
        if available { return "In-house ChatGPT Dot · two-way" }
        let reason: String = if case .object(let value) = readiness, case .string(let why)? = value["detail"], !why.isEmpty { why } else { "Dot messaging has not been checked yet." }
        guard inboundOnly else { return reason }
        return "Inbound only. Dot reaches her by running the local message command on this Mac (nativeagent-link message, with his contact file). "
            + "She cannot start a message to him, and a reply typed in his own chat does not arrive here: " + reason
    }

    public static let didChange = Notification.Name("ChatGPTDotIPCTransport.didChange")

    private static func unavailable(_ detail: String, status: String = "unavailable") -> JSONValue {
        .object(["status": .string(status), "sent": .bool(false), "completed": .bool(false), "detail": .string(detail)])
    }

    /// Dot's room is followed by one long-lived helper (`chatgpt_dot_ipc.js
    /// listen`) for as long as ChatGPT keeps its connection. ChatGPT pushes
    /// every change; each line the helper prints is Dot's state, with his
    /// room when he can be followed, and his messages go to her Dot session as
    /// they land (one that is hers wakes her). A helper that ends says why
    /// and the next starts at once while ChatGPT runs; one that dies right
    /// after that restart waits for ChatGPT's socket to be replaced.
    private struct Listener {
        var dataRoot: URL?
        var events: FileChangeEvents?
        var observation: Task<Void, Never>?
        var deliveries: [UUID: Task<Void, Never>] = [:]
        var generation = UUID()
        var process: Process?
        var output: FileHandle?
        /// The helper's stdin, held open: closing it (or this app ending) ends the helper.
        var lifeline: Pipe?
        var socket: UInt64?
        /// This helper is the restart after one ended, and how many lines it printed.
        var restarted = false
        var lines = 0
        var state = ChatGPTDotIPCTransport.unavailable("Dot messaging has not been checked yet.", status: "not_checked")
    }
    private static let listener = OSAllocatedUnfairLock(uncheckedState: Listener())
    private static let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock")

    /// Once, for the app's data root: follow Dot from now on.
    public static func listen(dataRoot: URL) {
        listener.withLock { state in
            guard state.dataRoot == nil, !Task.isCancelled else { return }
            state.dataRoot = dataRoot
            let events = FileChangeEvents(paths: [socket], emitInitial: true)
            let generation = state.generation
            state.events = events
            state.observation = Task.detached {
                defer {
                    events.cancel()
                    listener.withLock {
                        if $0.generation == generation { $0.observation = nil; $0.events = nil }
                    }
                }
                for await _ in events.stream {
                    guard !Task.isCancelled else { return }
                    reconnect(generation: generation)
                }
            }
        }
    }

    /// Stop passive ingress at once. Messages already accepted finish under
    /// their retained delivery tasks; their actual exits release those handles.
    public static func stop() {
        let retired = listener.withLock { state in
            state.generation = UUID()
            let retired = (state.events, state.observation, state.process, state.lifeline, state.output)
            state.dataRoot = nil
            state.state = unavailable("Dot messaging has not been checked yet.", status: "not_checked")
            state.events = nil; state.observation = nil
            state.process = nil; state.lifeline = nil; state.output = nil
            return retired
        }
        retired.0?.cancel(); retired.1?.cancel()
        retired.4?.readabilityHandler = nil
        try? retired.3?.fileHandleForWriting.close()
        if retired.2?.isRunning == true { retired.2?.terminate() }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Starts the listener unless one runs. Without a Dot contact there is nothing to follow.
    public static func reconnect() { reconnect(generation: listener.withLock { $0.generation }) }

    private static func reconnect(restarted: Bool = false, generation: UUID) {
        guard let root = listener.withLock({ $0.generation == generation && $0.lifeline == nil ? $0.dataRoot : nil }),
              (try? AgentPeerStore(dataRoot: root).list().contains(where: owns)) == true else { return }
        let environment = AgentBridgeRuntime.processEnvironment()
        guard let helper = AgentBridgeRuntime.helperURL(named: "chatgpt_dot_ipc.js", dataRoot: root),
              let node = AgentBridgeRuntime.executableURL(named: "node", environment: environment) else {
            return settle(unavailable("Dot messaging helper or Node.js is unavailable."), generation: generation)
        }
        let process = Process(), lifeline = Pipe(), output = Pipe()
        process.executableURL = node
        process.arguments = [helper.path, "listen"]
        process.currentDirectoryURL = root
        process.environment = environment
        process.standardInput = lifeline
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let pending = OSAllocatedUnfairLock(initialState: Data())
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            let lines = pending.withLock { buffer -> [Data] in
                buffer.append(chunk)
                var lines: [Data] = []
                while let end = buffer.firstIndex(of: 0x0A) {
                    lines.append(buffer[buffer.startIndex..<end])
                    buffer.removeSubrange(buffer.startIndex...end)
                }
                return lines
            }
            listener.withLock { if $0.lifeline === lifeline { $0.lines += lines.count } }
            lines.forEach { receive($0, root: root, generation: generation) }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                ended(lifeline, generation: generation)
            }
        }
        do { try listener.withLock { state in
            guard state.generation == generation, state.dataRoot == root, state.lifeline == nil else { return }
            (state.process, state.lifeline, state.socket) = (process, lifeline, socketInode())
            (state.restarted, state.lines) = (restarted, 0)
            state.output = output.fileHandleForReading
            try process.run()
        } } catch {
            output.fileHandleForReading.readabilityHandler = nil
            listener.withLock {
                if $0.lifeline === lifeline { $0.process = nil; $0.lifeline = nil; $0.output = nil }
            }
            settle(unavailable("Dot messaging helper or Node.js is unavailable."), generation: generation)
        }
    }

    private static func receive(_ line: Data, root: URL, generation: UUID) {
        guard case .object(var fields)? = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        let room = fields.removeValue(forKey: "messages")
        settle(.object(fields), generation: generation)
        guard case .array(let messages)? = room else { return }
        deliver(generation: generation) {
            guard let peer = try? AgentPeerStore(dataRoot: root).list().first(where: owns) else { return }
            do {
                _ = try await conversation(root, peer, messages, nil)
                // A wait on Dot looks again.
                AgentConversationRunning.shared.changed()
            } catch {
                nativeLog("Dot's room could not be brought into her session: %@", error.localizedDescription)
            }
        }
    }

    /// The helper is gone. It said why in its last line; one that did not
    /// stopped unexpectedly. While ChatGPT runs the next starts now, unless
    /// this one was already that restart and died at once (its last line was
    /// its only one): then its reason stands until ChatGPT's socket changes.
    private static func ended(_ lifeline: Pipe, generation: UUID) {
        guard let (state, started, quick) = listener.withLock({ value -> (JSONValue, UInt64?, Bool)? in
            guard value.generation == generation, value.lifeline === lifeline else { return nil }
            (value.process, value.lifeline, value.output) = (nil, nil, nil)
            return (value.state, value.socket, value.restarted && value.lines <= 1)
        }) else { return }
        guard case .object(let fields) = state else { return }
        if fields["status"] != .string("unavailable") {
            settle(unavailable("Dot's listener stopped unexpectedly."), generation: generation)
        }
        guard let now = socketInode() else { return }
        if now != started { reconnect(generation: generation) }
        else if !quick, fields["reason"] != .string("app_not_running") { reconnect(restarted: true, generation: generation) }
    }

    private static func socketInode() -> UInt64? {
        var info = stat()
        return stat(socket.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// A new state is news at once: the contact rows and her contact health follow it.
    private static func settle(_ state: JSONValue, generation: UUID) {
        guard let root = listener.withLock({ value -> URL?? in
            guard value.generation == generation, value.dataRoot != nil, value.state != state else { return nil }
            value.state = state
            return .some(value.dataRoot)
        }) else { return }
        NotificationCenter.default.post(name: didChange, object: nil)
        guard let root else { return }
        // Inbound only has no send path to be unavailable: a mark an earlier refused send left is lifted here, once.
        if inboundOnly, let peers = try? AgentPeerStore(dataRoot: root).list() {
            for peer in peers where owns(peer) && peer.unavailableAt != nil {
                AgentPeerStore(dataRoot: root).clearUnavailable(peerID: peer.id, since: .distantPast)
            }
        }
        deliver(generation: generation) {
            await AgentContactHealth.shared.refresh(dataRoot: root)
            // Room messages a failed ingestion kept are tried again.
            guard listener.withLock({ $0.generation == generation && $0.dataRoot != nil }) else { return }
            guard let peer = try? AgentPeerStore(dataRoot: root).list().first(where: owns) else { return }
            _ = try? await conversation(root, peer, [], nil)
        }
    }

    private static func deliver(generation: UUID, work: @escaping @Sendable () async -> Void) {
        listener.withLock { state in
            guard state.generation == generation, state.dataRoot != nil else { return }
            let id = UUID()
            state.deliveries[id] = Task {
                defer { listener.withLock { $0.deliveries[id] = nil } }
                await work()
            }
        }
    }
}
