import Foundation
import NativeAgentCore
import PersistenceCore
import Research
import KnowledgeGraph
import CapabilityFoundry
import Privacy

// MARK: - Errors

public enum MCPSubprocessError: Error, Equatable, Sendable {
    /// `tools/list` / `resources/list` / etc returned a JSON-RPC error object.
    case rpcError(code: Int, message: String)
    /// Server's `initialize` reply or any request body missed an expected key.
    case malformedResponse(String)
    /// Child closed stdout before the framed body could finish.
    case streamClosed
    /// Process failed to spawn (executable missing, perm denied, etc.).
    case spawnFailed(String)
    /// `request(...)` timed out waiting for the response with the matching id.
    case timeout(method: String, seconds: Double)
    /// Server is not stdio-transport — live methods refuse to handle it.
    case unsupportedTransport(String)
    /// Server's `command` field was empty/whitespace.
    case missingCommand
    /// Generic HTTP/SSE MCP transport failed. Carries the offending server id
    /// plus the HTTP status (when the failure was a non-2xx response) so the
    /// error is never mistaken for a fallthrough to another transport.
    case httpTransport(serverId: String, status: Int?, detail: String)
}

extension MCPSubprocessError: LocalizedError {
    public var errorDescription: String? {
        let description: String
        switch self {
        case .rpcError(let code, let message):
            description = "MCP server error (\(code)): \(message)"
        case .malformedResponse(let detail):
            description = detail
        case .streamClosed:
            description = "The MCP connection is closed."
        case .spawnFailed(let detail):
            description = "Could not start the MCP server: \(detail)"
        case .timeout(let method, let seconds):
            description = "MCP request \(method) timed out after \(seconds) seconds."
        case .unsupportedTransport(let transport):
            description = "Unsupported MCP transport: \(transport)"
        case .missingCommand:
            description = "MCP server has no executable command configured."
        case .httpTransport(let serverId, let status, let detail):
            let statusText = status.map { " (HTTP \($0))" } ?? ""
            description = "MCP server \(serverId)\(statusText): \(detail)"
        }
        return TurnSecretRedactor.redactText(NativeAgentSecretRedactor.redactText(description))
    }
}

// MARK: - Session status

/// Live snapshot mirroring `Runtime.list_mcp_session_statuses()` shape
///. One row per known server; pid + lastWarmedAt are
/// populated only when the subprocess is currently running.
public struct MCPSessionStatus: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var serverId: String
    public var serverName: String?
    public var transport: String?
    public var status: String
    public var healthStatus: String
    public var toolCount: Int
    public var resourceCount: Int
    public var lastWarmedAt: String?
    public var lastUsedAt: String?
    public var pid: Int32?
    public var lastError: String?

    public init(
        id: String,
        serverId: String,
        serverName: String? = nil,
        transport: String? = nil,
        status: String,
        healthStatus: String,
        toolCount: Int = 0,
        resourceCount: Int = 0,
        lastWarmedAt: String? = nil,
        lastUsedAt: String? = nil,
        pid: Int32? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.serverName = serverName
        self.transport = transport
        self.status = status
        self.healthStatus = healthStatus
        self.toolCount = toolCount
        self.resourceCount = resourceCount
        self.lastWarmedAt = lastWarmedAt
        self.lastUsedAt = lastUsedAt
        self.pid = pid
        self.lastError = lastError
    }
}

// MARK: - Framed pipe reader

/// Newline-delimited frame parser fed by Pipe.readabilityHandler bytes (MCP
/// stdio transport: one JSON-RPC message per `\n`-terminated line). Buffers
/// incoming chunks, splits on `\n`, and emits one parsed JSONValue message
/// per complete non-empty line. Not actor-isolated — the producer (the
/// readabilityHandler closure, called on a background queue) hands bytes in
/// via `append`, and the consumer (the owning actor) pulls completed frames
/// via `drain`.
///
/// Thread safety: serialized by an internal `NSLock` — both `append` and
/// `drain` may race because they run on different threads.
final class MCPFrameReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    /// Already-parsed but un-consumed frames.
    private var pending: [JSONValue] = []
    private var pendingBytes = 0
    /// Set when the pipe reports EOF — `drain` will surface this once the
    /// last in-flight frame has been delivered.
    private var closed = false
    /// Hard cap on a single line. Defends against a malicious or broken
    /// server streaming unbounded bytes with no `\n` — the buffer would
    /// otherwise grow until OOM. 64 MB is well above any legitimate MCP
    /// `tools/list` / `resources/list` response — the daemon's own tools
    /// cache rarely exceeds a few hundred KB.
    static let maxFrameBytes: Int = 64 * 1024 * 1024
    static let maxPendingBytes = maxFrameBytes
    static let maxPendingFrames = 256
    /// Tombstone for the most recent line the reader dropped because it
    /// wasn't valid JSON (or blew the size cap). Surfaced via `drain()` so
    /// the actor can fail pending request waiters with a precise error class.
    private var malformedFrameNotice: String?

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if data.isEmpty {
            closed = true
            return
        }
        buffer.append(data)
        // Drain as many complete `\n`-terminated lines as possible from
        // `buffer` into `pending`. A trailing partial line stays buffered
        // until its newline arrives in a later chunk.
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            // Tolerate `\r\n` line endings — trim a single trailing `\r`.
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty { continue }
            if line.count > MCPFrameReader.maxFrameBytes {
                malformedFrameNotice = "line exceeds \(MCPFrameReader.maxFrameBytes) bytes"
                continue
            }
            guard pending.count < Self.maxPendingFrames,
                  line.count <= Self.maxPendingBytes - pendingBytes else {
                malformedFrameNotice = "queued stdout frames exceed \(Self.maxPendingFrames) frames or \(Self.maxPendingBytes) bytes"
                closed = true
                pending.removeAll(keepingCapacity: false)
                pendingBytes = 0
                buffer.removeAll(keepingCapacity: false)
                return
            }
            if let value = try? JSONValue.parse(line) {
                pending.append(value)
                pendingBytes += line.count
            } else {
                // Non-JSON bytes on stdout mean the server is broken (or
                // logging to the wrong fd) — stamp a tombstone so the actor
                // fails waiters fast and evicts the subprocess.
                malformedFrameNotice = "non-JSON line on stdout (\(line.count) bytes)"
            }
        }
        // No newline yet — cap the partial-line buffer so a server that
        // never sends `\n` can't grow it without bound.
        if buffer.count > MCPFrameReader.maxFrameBytes {
            buffer.removeAll(keepingCapacity: false)
            malformedFrameNotice = "unterminated line exceeds \(MCPFrameReader.maxFrameBytes) bytes"
        }
    }

    /// Returns (frames, closed, malformedNotice). Frames are removed from
    /// the queue. `malformedNotice` is non-nil exactly when the parser had
    /// to drop a line because it wasn't valid JSON (or blew the size cap);
    /// the notice is consumed (cleared) on each drain so a subsequent valid
    /// frame doesn't keep re-surfacing the same error.
    func drain() -> (frames: [JSONValue], closed: Bool, malformedNotice: String?) {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        let notice = malformedFrameNotice
        malformedFrameNotice = nil
        return (out, closed, notice)
    }
}
