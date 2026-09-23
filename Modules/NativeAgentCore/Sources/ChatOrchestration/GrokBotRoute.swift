import Foundation
import NativeAgentCore
import PersistenceCore

/// Only nonsecret correlation and delivery state are persisted here.
public struct GrokPendingRequest: Codable, Sendable {
    public let messageID: String
    public let peerID: String
    public let conversationID: String
    public let expiresAt: Date
    public var state: String
    public var runID: String?
}

public struct GrokRequestStore: Sendable {
    public let root: URL
    public init(dataRoot: URL) { root = dataRoot.appendingPathComponent("agents/grok-requests") }
    private func url(_ id: String) throws -> URL {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw GrokLinkCredential.Failure.invalid }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root.appendingPathComponent(id + ".json")
    }
    public func create(id: String, peer: String, conversation: String, now: Date = Date()) throws -> GrokPendingRequest {
        guard NativeAgentChatSessionID.normalizedPathComponent(conversation) == conversation else { throw GrokLinkCredential.Failure.invalid }
        let file = try url(id)
        return try CredentialFileLock.withLock(file) {
            guard !FileManager.default.fileExists(atPath: file.path) else { throw GrokLinkCredential.Failure.invalid }
            let request = GrokPendingRequest(messageID: id, peerID: peer, conversationID: conversation,
                expiresAt: now.addingTimeInterval(600), state: "sending")
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(request), to: file)
            return request
        }
    }
    public func read(_ id: String, peer: String, now: Date = Date()) throws -> GrokPendingRequest {
        let file = try url(id)
        return try CredentialFileLock.withLock(file) {
            var value = try load(file)
            guard value.peerID == peer else { throw GrokLinkCredential.Failure.invalid }
            if value.expiresAt < now && ["sending", "accepted", "outcome unknown"].contains(value.state) {
                value.state = "no answer in time"
            }
            return value
        }
    }
    private func load(_ file: URL) throws -> GrokPendingRequest {
        let data = try Data(contentsOf: file)
        guard data.count <= 8192 else { throw GrokLinkCredential.Failure.invalid }
        return try JSONDecoder().decode(GrokPendingRequest.self, from: data)
    }
    @discardableResult public func update(_ id: String, peer: String, _ edit: (inout GrokPendingRequest) throws -> Void) throws -> GrokPendingRequest {
        let file = try url(id)
        return try CredentialFileLock.withLock(file) {
            var value = try load(file)
            guard value.peerID == peer else { throw GrokLinkCredential.Failure.invalid }
            try edit(&value)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(value), to: file)
            return value
        }
    }
    public func claimReply(_ reply: GrokReplyInput, peer: String, now: Date = Date()) throws -> GrokPendingRequest {
        try update(reply.message_id, peer: peer) { value in
            // No time limit: Grok may wait on a person's approval. The state check stops duplicates.
            guard ["sending", "accepted", "outcome unknown"].contains(value.state) else {
                throw GrokLinkCredential.Failure.invalid
            }
            // Before enqueue: a crash or an ambiguous enqueue never duplicates a turn.
            value.state = "delivering reply"
        }
    }
}

public enum GrokBotRoute {
    public static let bundleID = "com.anysphere.sand"
    public static func routineName(_ peer: String) -> String { "NativeAgent reply " + peer }
    public static let securePasteBlocker = "Grok Bot's Routines panel did not expose one unambiguous webhook URL and readable key through Accessibility. Setup stopped. Paste the URL and key together in the secure field on this card; never in chat."
    public static func instruction(peer: String, command: String) -> String {
        // Only app-owned fixed arguments form the command. Reply data is stdin.
        let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        Each webhook body contains message_id, conversation_id and text. Answer text, preserving any requested nonce.
        Return the answer to NativeAgent by running this exact command ON THE LOCAL COMPUTER through Grok Bot's supported local execution:
        \(quoted) reply --contact \(peer)
        Supply a single JSON object {"message_id":"the exact incoming message_id","text":"your answer"} on the command's standard input. Use a data-safe stdin facility; never interpolate reply text into shell syntax, command arguments or an unquoted heredoc. Do not run substitutions from the text. Do not choose a callback URL or read any credentials or configuration. The helper owns authentication locally. Run it once; do not retry an uncertain result. Respect the person's local execution policy and ask for approval when required.
        """
    }
    public static func projection(_ pending: GrokPendingRequest) -> JSONValue {
        .object(["agent": .string("peer:" + pending.peerID), "transport": .string("grokBot"),
            "message_id": .string(pending.messageID), "conversation_id": .string(pending.conversationID),
            "status": .string(pending.state), "completed": .bool(pending.state == "answered"),
            "automatic_resend": .bool(false),
            "detail": .string(pending.state == "accepted" ? "Accepted, waiting for Grok. The run started; it has not answered. Its answer arrives by itself as the next turn in this conversation, so end this turn now without waiting, checking or reading for it. If none comes, Grok Bot may be waiting for the person to approve the local reply command."
                : pending.state == "no answer in time" ? "No answer in time. Check Grok Bot for a local run not approved or usage exhausted; this app cannot infer those from silence. Do not resend automatically."
                : pending.state)])
    }
    public static func send(peer: AgentPeerContact, text: String, conversation: String, messageID: String,
                            dataRoot: URL, credential: GrokLinkCredential,
                            post: @Sendable (URLRequest) async throws -> Int = postOnce) async throws -> JSONValue {
        guard peer.grokSetup == "set up", let address = credential.webhookURL,
              let key = credential.webhookKey, let url = URL(string: address) else { throw GrokLinkCredential.Failure.unavailable }
        let store = GrokRequestStore(dataRoot: dataRoot)
        _ = try store.create(id: messageID, peer: peer.id, conversation: conversation)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message_id": messageID, "conversation_id": conversation, "text": text])
        let state: String
        do {
            let code = try await post(request)
            // The documented contract establishes only 200. Other status
            // codes do not prove usage exhaustion or a local policy denial.
            state = code == 200 ? "accepted" : "webhook refused the request (HTTP \(code))"
        } catch { state = "outcome unknown" } // Never expose URLSession errors/URLs.
        let pending = try store.update(messageID, peer: peer.id) {
            if $0.state == "sending" { $0.state = state }
        }
        if pending.state == "accepted" {
            AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peer.id, outbound: true)
        }
        return projection(pending)
    }
    public static func postOnce(_ request: URLRequest) async throws -> Int {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: GrokNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw GrokLinkCredential.Failure.unavailable }
        return http.statusCode // No response body, header, URL or credential enters a result.
    }
}
private final class GrokNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
