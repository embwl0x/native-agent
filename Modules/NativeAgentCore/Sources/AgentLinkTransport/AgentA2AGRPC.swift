import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import GRPCProtobuf
import SwiftProtobuf
import PersistenceCore

/// The protobuf binding projects the existing canonical ProtoJSON requests and
/// receipts. Task ownership, continuation and stream recovery stay with A2A.
enum AgentA2AGRPC {
    static func send(_ request: AgentA2AWire.Request, bearerToken: String?,
                     timeout: TimeInterval) async throws -> AgentPeerHTTP.Response {
        try AgentPeerHTTP.validateURL(request.url)
        guard let method = request.grpcMethod, let host = request.url.host,
              request.url.query == nil, ["", "/"].contains(request.url.path),
              timeout.isFinite, timeout > 0, timeout <= 600 else {
            throw AgentPeerHTTP.TransportError.invalidRequest
        }
        let port = request.url.port ?? (request.url.scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { throw AgentPeerHTTP.TransportError.invalidURL }
        var metadata: Metadata = ["a2a-version": "1.0"]
        if let bearerToken {
            guard AgentPeerHTTP.validToken(bearerToken) else { throw AgentPeerHTTP.TransportError.invalidRequest }
            metadata.addString("Bearer " + bearerToken, forKey: "authorization")
        }
        let body = try (request.body ?? .object([:])).serializedData(pretty: false)
        guard body.count <= AgentPeerHTTP.maximumResponseBytes else { throw AgentPeerHTTP.TransportError.invalidRequest }
        let json = String(decoding: body, as: UTF8.self)
        var options = CallOptions.defaults
        options.timeout = .milliseconds(Int64(timeout * 1_000))
        options.maxRequestMessageBytes = AgentPeerHTTP.maximumResponseBytes
        options.maxResponseMessageBytes = AgentPeerHTTP.maximumResponseBytes
        // No retry policy: a lost reply must never replay an accepted send.
        let transport = try HTTP2ClientTransport.TransportServices(
            target: .dns(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: port),
            transportSecurity: request.url.scheme == "https" ? .tls : .plaintext)
        let callMetadata = metadata
        let callOptions = options
        do {
            return try await withGRPCClient(transport: transport) { client in
                switch method {
                case "SendMessage":
                    return try await unary(client, method, json, callMetadata, callOptions, Lf_A2a_V1_SendMessageRequest.self, Lf_A2a_V1_SendMessageResponse.self)
                case "SendStreamingMessage":
                    return try await stream(client, method, json, callMetadata, callOptions, Lf_A2a_V1_SendMessageRequest.self)
                case "GetTask":
                    return try await unary(client, method, json, callMetadata, callOptions, Lf_A2a_V1_GetTaskRequest.self, Lf_A2a_V1_Task.self)
                case "ListTasks":
                    return try await unary(client, method, json, callMetadata, callOptions, Lf_A2a_V1_ListTasksRequest.self, Lf_A2a_V1_ListTasksResponse.self)
                case "CancelTask":
                    return try await unary(client, method, json, callMetadata, callOptions, Lf_A2a_V1_CancelTaskRequest.self, Lf_A2a_V1_Task.self)
                case "SubscribeToTask":
                    return try await stream(client, method, json, callMetadata, callOptions, Lf_A2a_V1_SubscribeToTaskRequest.self)
                case "CreateTaskPushNotificationConfig":
                    return try await unary(client, method, json, callMetadata, callOptions, Lf_A2a_V1_TaskPushNotificationConfig.self, Lf_A2a_V1_TaskPushNotificationConfig.self)
                case "GetTaskPushNotificationConfig":
                    return try await unary(client, method, json, callMetadata, callOptions, Lf_A2a_V1_GetTaskPushNotificationConfigRequest.self, Lf_A2a_V1_TaskPushNotificationConfig.self)
                case "ListTaskPushNotificationConfigs":
                    return try await unary(client, method, json, callMetadata, callOptions, Lf_A2a_V1_ListTaskPushNotificationConfigsRequest.self, Lf_A2a_V1_ListTaskPushNotificationConfigsResponse.self)
                case "DeleteTaskPushNotificationConfig":
                    return try await unary(client, method, json, callMetadata, callOptions, Lf_A2a_V1_DeleteTaskPushNotificationConfigRequest.self, Google_Protobuf_Empty.self)
                case "GetExtendedAgentCard":
                    return try await unary(client, method, json, callMetadata, callOptions, Lf_A2a_V1_GetExtendedAgentCardRequest.self, Lf_A2a_V1_AgentCard.self)
                default: throw AgentA2AWire.WireError.unsupported("gRPC operation \(method)")
                }
            }
        } catch let error as RPCError where error.code == .unauthenticated || error.code == .permissionDenied {
            return AgentPeerHTTP.Response(statusCode: error.code == .unauthenticated ? 401 : 403, json: nil)
        } catch {
            if Task.isCancelled { throw AgentPeerHTTP.TransportError.cancelled }
            throw error
        }
    }

    private static func descriptor(_ method: String) -> MethodDescriptor {
        MethodDescriptor(service: ServiceDescriptor(fullyQualifiedService: "lf.a2a.v1.A2AService"), method: method)
    }

    private static func unary<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message>(
        _ client: GRPCClient<HTTP2ClientTransport.TransportServices>, _ method: String,
        _ json: String, _ metadata: Metadata, _ options: CallOptions,
        _ input: Input.Type, _ output: Output.Type
    ) async throws -> AgentPeerHTTP.Response {
        try await client.unary(request: ClientRequest(message: Input(jsonString: json), metadata: metadata),
            descriptor: descriptor(method), serializer: ProtobufSerializer<Input>(),
            deserializer: ProtobufDeserializer<Output>(), options: options) { response in
                let data = try response.message.jsonUTF8Data()
                guard data.count <= AgentPeerHTTP.maximumResponseBytes else { throw AgentPeerHTTP.TransportError.tooLarge }
                return AgentPeerHTTP.Response(statusCode: 200, json: try JSONValue.parse(data))
            }
    }

    private static func stream<Input: SwiftProtobuf.Message>(
        _ client: GRPCClient<HTTP2ClientTransport.TransportServices>, _ method: String,
        _ json: String, _ metadata: Metadata, _ options: CallOptions, _ input: Input.Type
    ) async throws -> AgentPeerHTTP.Response {
        try await client.serverStreaming(request: ClientRequest(message: Input(jsonString: json), metadata: metadata),
            descriptor: descriptor(method), serializer: ProtobufSerializer<Input>(),
            deserializer: ProtobufDeserializer<Lf_A2a_V1_StreamResponse>(), options: options) { response in
                var events: [JSONValue] = []
                var bytes = 0
                do {
                    // Pull one event at a time; HTTP/2 applies receive backpressure.
                    for try await message in response.messages {
                        try Task.checkCancellation()
                        let data = try message.jsonUTF8Data()
                        guard data.count <= AgentPeerHTTP.maximumResponseBytes - bytes else { throw AgentPeerHTTP.TransportError.tooLarge }
                        bytes += data.count
                        events.append(try JSONValue.parse(data))
                    }
                } catch let error as RPCError where !events.isEmpty && !Task.isCancelled &&
                    (error.code == .unavailable || error.code == .deadlineExceeded || error.code == .cancelled) {
                    return AgentPeerHTTP.Response(statusCode: 200, json: nil, events: events, interrupted: true)
                }
                return AgentPeerHTTP.Response(statusCode: 200, json: nil, events: events)
            }
    }
}
