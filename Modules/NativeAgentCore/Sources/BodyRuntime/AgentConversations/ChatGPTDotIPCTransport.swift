import Foundation
import Synchronization
import PersistenceCore
import NativeAgentShared
import NativeAgentCore
// Blueprint: | `ChatGPTDotIPCTransport.swift` | `ChatGPTDotIPCTransport`, `listen`, `reconnect`, `stop`, `readiness` |

public struct ChatGPTDotIPCTransport: Sendable {
    typealias Conversation = @Sendable (Turn?, URL, AgentPeerContact, [JSONValue], String?, [String: JSONValue]?) async throws -> JSONValue
    let dataRoot: URL
    let hasBody: Bool
    let conversation: Conversation

    public static func owns(_ peer: AgentPeerContact) -> Bool {
        peer.transport == .mcpHost && AgentPeerStore.hostRowID(peer.endpoint) == "chatgpt-dot"
    }

    struct Snapshot: Sendable {
        let readiness: JSONValue

        var available: Bool {
            if case .object(let value) = readiness { return value["status"] == .string("available") }
            return false
        }

        var inboundOnly: Bool {
            guard case .object(let value) = readiness else { return true }
            return ![.string("available"), .string("not_checked"), .string("loading")].contains(value["status"] ?? .null)
        }

        var detail: String {
            if available { return "In-house ChatGPT Dot · two-way" }
            let reason: String = if case .object(let value) = readiness, case .string(let why)? = value["detail"],
                !why.isEmpty { why } else { "Dot messaging has not been checked yet." }
            guard inboundOnly else { return reason }
            return "Inbound only. Dot reaches the agent by running the local message command on this Mac (nativeagent-link message, with Dot's contact file). "
                + "The agent cannot start a message to Dot, and a reply typed in Dot's own chat does not arrive here: " + reason
        }
    }

    var snapshot: Snapshot { Self.snapshot(at: dataRoot) }

    static var sendStatus: Snapshot { macListener.withLock { Snapshot(readiness: $0.state) } }

    static func snapshot(at root: URL) -> Snapshot {
        macListener.withLock { value in
            Snapshot(readiness: value.dataRoot?.standardizedFileURL == root.standardizedFileURL ? value.state : unchecked)
        }
    }

    struct DidChange: BodySignal {}

    private static func unavailable(_ detail: String, status: String = "unavailable") -> JSONValue {
        .object(["status": .string(status), "sent": .bool(false), "completed": .bool(false), "detail": .string(detail)])
    }

    /// Follow pushed IPC state through one long-lived helper. Restart once while ChatGPT runs; an immediate second exit waits for socket replacement to avoid a
    /// restart loop.
    private struct Listener {
        var dataRoot: URL?
        var events: FileChangeEvents?
        var observation: Task<Void, Never>?
        var deliveries: [UUID: Task<Void, Never>] = [:]
        var stopping = false
        var generation = UUID()
        var process: Process?
        var output: FileHandle?
        /// Keep stdin open for the helper’s lifetime; closing it ends the child.
        var lifeline: Pipe?
        var socket: UInt64?
        /// Track the single restart and its output count to detect immediate failure.
        var restarted = false
        var lines = 0
        var state = ChatGPTDotIPCTransport.unchecked
    }
    private static let unchecked = unavailable("Dot messaging has not been checked yet.", status: "not_checked")
    private static let macListener = Mutex(Listener())
    private static let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock")

    func listen() {
        guard hasBody else { return }
        Self.macListener.withLock { state in
            guard state.dataRoot == nil, !state.stopping, !Task.isCancelled else { return }
            state.dataRoot = dataRoot
            let events = FileChangeEvents(paths: [Self.socket], emitInitial: true)
            let generation = state.generation
            state.events = events
            state.observation = Task.detached {
                defer {
                    events.cancel()
                    Self.macListener.withLock {
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

    /// Close ingress, cancel accepted work and join its actual settlement.
    func stop() async {
        guard hasBody else { return }
        let retired = Self.macListener.withLock { state in
            state.stopping = true
            state.generation = UUID()
            let retired = (state.events, state.observation, state.process, state.lifeline, state.output,
                           Array(state.deliveries.values), state.generation,
                           state.state != Self.unchecked)
            state.dataRoot = nil
            state.state = Self.unchecked
            state.events = nil; state.observation = nil
            state.process = nil; state.lifeline = nil; state.output = nil
            return retired
        }
        retired.0?.cancel(); retired.1?.cancel()
        retired.4?.readabilityHandler = nil
        try? retired.3?.fileHandleForWriting.close()
        if retired.2?.isRunning == true { retired.2?.terminate() }
        for task in retired.5 { task.cancel() }
        await retired.1?.value
        for task in retired.5 { await task.value }
        Self.macListener.withLock { state in
            if state.generation == retired.6 { state.stopping = false }
        }
        if retired.7 { NotificationCenter.default.post(DidChange()) }
    }

    /// No saved contact means there is no conversation to follow.
    static func reconnectMac(dataRoot: URL) {
        guard macListener.withLock({ $0.dataRoot?.standardizedFileURL == dataRoot.standardizedFileURL }) else { return }
        NativeAgentEngine.live.agents.dotTransport.reconnect()
    }

    func reconnect() {
        guard hasBody else { return }
        reconnect(generation: Self.macListener.withLock { $0.generation })
    }

    private func reconnect(restarted: Bool = false, generation: UUID) {
        guard let root = Self.macListener.withLock({ $0.generation == generation && $0.lifeline == nil ? $0.dataRoot : nil }),
              (try? AgentPeerStore(dataRoot: root).list().contains(where: Self.owns)) == true else { return }
        let environment = AgentBridgeRuntime.processEnvironment()
        guard let helper = AgentBridgeRuntime.helperURL(named: "chatgpt_dot_ipc.js", dataRoot: root),
              let node = AgentBridgeRuntime.executableURL(named: "node", environment: environment) else {
            return settle(Self.unavailable("Dot messaging helper or Node.js is unavailable."), generation: generation)
        }
        let process = Process(), lifeline = Pipe(), output = Pipe()
        process.executableURL = node
        process.arguments = [helper.path, "listen"]
        process.currentDirectoryURL = root
        process.environment = ManagedProcess.agentEnvironment(environment)
        process.standardInput = lifeline
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let pending = Mutex(Data())
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
            Self.macListener.withLock { if $0.lifeline === lifeline { $0.lines += lines.count } }
            lines.forEach { receive($0, generation: generation) }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                ended(lifeline, generation: generation)
            }
        }
        do { try Self.macListener.withLock { state in
            guard state.generation == generation, state.dataRoot == root, state.lifeline == nil else { return }
            (state.process, state.lifeline, state.socket) = (process, lifeline, Self.socketInode())
            (state.restarted, state.lines) = (restarted, 0)
            state.output = output.fileHandleForReading
            try process.run()
        } } catch {
            output.fileHandleForReading.readabilityHandler = nil
            Self.macListener.withLock {
                if $0.lifeline === lifeline { $0.process = nil; $0.lifeline = nil; $0.output = nil }
            }
            settle(Self.unavailable("Dot messaging helper or Node.js is unavailable."), generation: generation)
        }
    }

    private func receive(_ line: Data, generation: UUID) {
        guard case .object(var fields)? = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        let messages = fields.removeValue(forKey: "messages")?.arrayValue
        settle(.object(fields), messages: messages, generation: generation)
    }

    /// After one immediate restart failure, retain its reason until the socket changes instead of looping.
    private func ended(_ lifeline: Pipe, generation: UUID) {
        guard let (state, started, quick) = Self.macListener.withLock({ value -> (JSONValue, UInt64?, Bool)? in
            guard value.generation == generation, value.lifeline === lifeline else { return nil }
            (value.process, value.lifeline, value.output) = (nil, nil, nil)
            return (value.state, value.socket, value.restarted && value.lines <= 1)
        }) else { return }
        guard case .object(let fields) = state else { return }
        if fields["status"] != .string("unavailable") {
            settle(Self.unavailable("Dot's listener stopped unexpectedly."), generation: generation)
        }
        guard let now = Self.socketInode() else { return }
        if now != started { reconnect(generation: generation) }
        else if !quick, fields["reason"] != .string("app_not_running") { reconnect(restarted: true, generation: generation) }
    }

    private static func socketInode() -> UInt64? {
        var info = stat()
        return stat(socket.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// Publish transport changes immediately so contact rows and health agree.
    private func settle(_ state: JSONValue, messages: [JSONValue]? = nil, generation: UUID) {
        guard let (root, changed) = Self.macListener.withLock({ value -> (URL, Bool)? in
            guard value.generation == generation, let root = value.dataRoot else { return nil }
            let changed = value.state != state
            value.state = state
            return (root, changed)
        }) else { return }
        if changed { NotificationCenter.default.post(DidChange()) }
        // Inbound-only has no outbound path to mark unavailable.
        if changed, snapshot.inboundOnly, let peers = try? AgentPeerStore(dataRoot: root).list() {
            for peer in peers where Self.owns(peer) && peer.unavailableAt != nil {
                AgentPeerStore(dataRoot: root).clearUnavailable(peerID: peer.id, since: .distantPast)
            }
        }
        guard changed || messages != nil else { return }
        deliver(generation: generation) {
            if changed { await AgentContactHealth.shared.refresh(dataRoot: root) }
            guard Self.macListener.withLock({ $0.generation == generation && $0.dataRoot != nil }) else { return }
            guard let peer = try? AgentPeerStore(dataRoot: root).list().first(where: Self.owns) else { return }
            do {
                // Also drain messages retained after failed ingestion.
                _ = try await conversation(nil, root, peer, messages ?? [], nil, nil)
                if messages != nil { AgentConversationRunning.shared.changed() }
            } catch {
                nativeLog("Dot's room could not be brought into the agent's session: %@", error.localizedDescription)
            }
        }
    }

    private func deliver(generation: UUID, work: @escaping @Sendable () async -> Void) {
        Self.macListener.withLock { state in
            guard state.generation == generation, state.dataRoot != nil else { return }
            let id = UUID()
            state.deliveries[id] = Task {
                defer { Self.macListener.withLock { $0.deliveries[id] = nil } }
                await work()
            }
        }
    }
}
