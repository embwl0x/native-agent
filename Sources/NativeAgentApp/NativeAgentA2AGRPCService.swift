import Foundation
import ChatOrchestration
import GRPCCore
import GRPCProtobuf
import SwiftProtobuf
import NativeAgentCore

/// Protobuf is a wire projection of the same canonical endpoint used by JSON-RPC and HTTP+JSON.
struct NativeAgentA2AGRPCService: Lf_A2a_V1_A2AService.ServiceProtocol {
    let endpoint: @Sendable () -> AgentContactA2AEndpoint
    let authenticate: @Sendable (Metadata) throws -> AgentBridgePrincipal

    static func authenticate(metadata: Metadata, liveToken: String, dataRoot: URL,
                             readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) }) throws -> AgentBridgePrincipal {
        var headers: [String: String] = [:]
        for key in ["authorization", AgentBridgePrincipal.peerIDHeader, AgentBridgePrincipal.peerSecretHeader] {
            let values = Array(metadata[stringValues: key])
            guard values.count <= 1 else { throw RPCError(code: .unauthenticated, message: "Unauthorized") }
            headers[key] = values.first
        }
        headers = ClaudeBridge.contactHeaders(path: "/a2a", headers: headers, liveToken: liveToken,
            dataRoot: dataRoot, readCredential: readCredential)
        switch BridgeCore.authorize(authorizationHeader: headers["authorization"], liveToken: liveToken) {
        case .serverStopping: throw RPCError(code: .unavailable, message: "Server stopping")
        case .unauthorized: throw RPCError(code: .unauthenticated, message: "Unauthorized")
        case .authorized: break
        }
        let principal = AgentBridgePrincipal.resolve(headers: headers, dataRoot: dataRoot, readCredential: readCredential)
        guard principal.peerID != nil, !principal.replyOnly
        else { throw RPCError(code: .unauthenticated, message: "Unauthorized") }
        return principal
    }

    private func handle<Input: SwiftProtobuf.Message>(_ request: ServerRequest<Input>, method: String) async throws -> AgentContactA2AEndpoint.Response {
        let principal = try authenticate(request.metadata)
        try Task.checkCancellation()
        let versions = Array(request.metadata[stringValues: "a2a-version"])
        guard versions.count <= 1 else { throw RPCError(code: .invalidArgument, message: "One A2A version is required") }
        if let version = versions.first, version != "1.0", version != "1.0.0" {
            throw GoogleRPCStatus(code: .unimplemented, message: "gRPC supports A2A 1.0",
                details: .errorInfo(reason: "VERSION_NOT_SUPPORTED", domain: "a2a-protocol.org"))
        }
        let params = try JSONSerialization.jsonObject(with: request.message.jsonUTF8Data())
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "grpc", "method": method, "params": params], options: [.sortedKeys])
        let response = await endpoint().handle(body, principal: principal, version: versions.first ?? "1.0")
        try Task.checkCancellation()
        return response
    }

    private func decode<Output: SwiftProtobuf.Message>(_ envelope: [String: Any], as type: Output.Type = Output.self) throws -> Output {
        if let error = envelope["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -32603
            let mapping: (RPCError.Code, String)
            switch code {
            case -32001: mapping = (.notFound, "TASK_NOT_FOUND")
            case -32002: mapping = (.failedPrecondition, "TASK_NOT_CANCELABLE")
            case -32003: mapping = (.unimplemented, "PUSH_NOTIFICATION_NOT_SUPPORTED")
            case -32004: mapping = (.unimplemented, "UNSUPPORTED_OPERATION")
            case -32005: mapping = (.invalidArgument, "CONTENT_TYPE_NOT_SUPPORTED")
            case -32006: mapping = (.internalError, "INVALID_AGENT_RESPONSE")
            case -32007: mapping = (.failedPrecondition, "EXTENDED_AGENT_CARD_NOT_CONFIGURED")
            case -32008: mapping = (.failedPrecondition, "EXTENSION_SUPPORT_REQUIRED")
            case -32009: mapping = (.unimplemented, "VERSION_NOT_SUPPORTED")
            case -32601: mapping = (.unimplemented, "METHOD_NOT_FOUND")
            case -32603: mapping = (.internalError, "INTERNAL_ERROR")
            default: mapping = (.invalidArgument, "INVALID_PARAMS")
            }
            throw GoogleRPCStatus(code: mapping.0, message: error["message"] as? String ?? "Request failed",
                details: .errorInfo(reason: mapping.1, domain: "a2a-protocol.org"))
        }
        let bytes = try JSONSerialization.data(withJSONObject: envelope["result"] ?? [:])
        return try Output(jsonUTF8Data: bytes)
    }

    private func unary<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message>(_ request: ServerRequest<Input>, method: String) async throws -> ServerResponse<Output> {
        guard case .json(let value) = try await handle(request, method: method) else {
            throw RPCError(code: .internalError, message: "Unexpected stream")
        }
        return ServerResponse(message: try decode(value))
    }

    private func stream<Input: SwiftProtobuf.Message>(_ request: ServerRequest<Input>, method: String) async throws -> StreamingServerResponse<Lf_A2a_V1_StreamResponse> {
        switch try await handle(request, method: method) {
        case .json(let value):
            let _: Lf_A2a_V1_StreamResponse = try decode(value)
            throw RPCError(code: .internalError, message: "Expected stream")
        case .stream(_, let events, _):
            return StreamingServerResponse { writer in
                for await event in events {
                    try Task.checkCancellation()
                    try await writer.write(try decode(NativeAgentA2AWire.event(event, id: "grpc", version: "1.0")))
                    switch event {
                    case .snapshot(let task), .status(let task, _):
                        if task.state.terminal || task.state == .inputRequired { return [:] }
                    case .artifact: break
                    }
                }
                return [:]
            }
        }
    }

    func sendMessage(request: ServerRequest<Lf_A2a_V1_SendMessageRequest>, context: ServerContext) async throws -> ServerResponse<Lf_A2a_V1_SendMessageResponse> {
        try await unary(request, method: "SendMessage")
    }
    func sendStreamingMessage(request: ServerRequest<Lf_A2a_V1_SendMessageRequest>, context: ServerContext) async throws -> StreamingServerResponse<Lf_A2a_V1_StreamResponse> {
        try await stream(request, method: "SendStreamingMessage")
    }
    func getTask(request: ServerRequest<Lf_A2a_V1_GetTaskRequest>, context: ServerContext) async throws -> ServerResponse<Lf_A2a_V1_Task> {
        try await unary(request, method: "GetTask")
    }
    func listTasks(request: ServerRequest<Lf_A2a_V1_ListTasksRequest>, context: ServerContext) async throws -> ServerResponse<Lf_A2a_V1_ListTasksResponse> {
        try await unary(request, method: "ListTasks")
    }
    func cancelTask(request: ServerRequest<Lf_A2a_V1_CancelTaskRequest>, context: ServerContext) async throws -> ServerResponse<Lf_A2a_V1_Task> {
        try await unary(request, method: "CancelTask")
    }
    func subscribeToTask(request: ServerRequest<Lf_A2a_V1_SubscribeToTaskRequest>, context: ServerContext) async throws -> StreamingServerResponse<Lf_A2a_V1_StreamResponse> {
        try await stream(request, method: "SubscribeToTask")
    }
    func createTaskPushNotificationConfig(request: ServerRequest<Lf_A2a_V1_TaskPushNotificationConfig>, context: ServerContext) async throws -> ServerResponse<Lf_A2a_V1_TaskPushNotificationConfig> {
        try await unary(request, method: "CreateTaskPushNotificationConfig")
    }
    func getTaskPushNotificationConfig(request: ServerRequest<Lf_A2a_V1_GetTaskPushNotificationConfigRequest>, context: ServerContext) async throws -> ServerResponse<Lf_A2a_V1_TaskPushNotificationConfig> {
        try await unary(request, method: "GetTaskPushNotificationConfig")
    }
    func listTaskPushNotificationConfigs(request: ServerRequest<Lf_A2a_V1_ListTaskPushNotificationConfigsRequest>, context: ServerContext) async throws -> ServerResponse<Lf_A2a_V1_ListTaskPushNotificationConfigsResponse> {
        try await unary(request, method: "ListTaskPushNotificationConfigs")
    }
    func deleteTaskPushNotificationConfig(request: ServerRequest<Lf_A2a_V1_DeleteTaskPushNotificationConfigRequest>, context: ServerContext) async throws -> ServerResponse<Google_Protobuf_Empty> {
        try await unary(request, method: "DeleteTaskPushNotificationConfig")
    }
    func getExtendedAgentCard(request: ServerRequest<Lf_A2a_V1_GetExtendedAgentCardRequest>, context: ServerContext) async throws -> ServerResponse<Lf_A2a_V1_AgentCard> {
        try await unary(request, method: "GetExtendedAgentCard")
    }
}
