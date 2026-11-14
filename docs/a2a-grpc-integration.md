# A2A 1.0 gRPC integration

NativeAgent serves and consumes these A2A 1.0 operations over gRPC:

- SendMessage and SendStreamingMessage
- GetTask, ListTasks, CancelTask and SubscribeToTask
- CreateTaskPushNotificationConfig, GetTaskPushNotificationConfig,
  ListTaskPushNotificationConfigs and DeleteTaskPushNotificationConfig
- GetExtendedAgentCard

JSON-RPC and HTTP+JSON remain available, with 0.3 JSON-RPC compatibility.
HTTP+JSON subscriptions use `GET /a2a/tasks/{id}:subscribe`. Work stopped by
a data restore projects as terminal `canceled`, with its restore reason in
the status message, on every A2A binding.
The agent reaches peers through `app` agent actions; see
[Agent conversations](agent-communication.md).

## Runtime ownership

`Modules/NativeAgentCore/Sources/Agents/NativeAgentA2AGRPCListener.swift` binds an ephemeral
`127.0.0.1` HTTP/2 port. Once bound, it publishes `a2a-grpc.json` in the bridge
discovery directory and makes the port available to the agent card. Shutdown
removes the descriptor and begins graceful transport shutdown.

`NativeAgentA2AGRPCService.swift` authenticates metadata, converts generated
protobuf messages and dispatches through `AgentContactA2AEndpoint` to the
engine's existing task owner. Streaming awaits each transport write. Protocol
errors use Google RPC status details; gRPC does not introduce another task store.

The outbound adapter is
`Modules/NativeAgentCore/Sources/AgentLinkTransport/AgentA2AGRPC.swift`.
It sends configured bearer credentials as metadata, sets a timeout, uses TLS
for HTTPS, and permits plaintext only under the existing loopback URL policy.
It has no retry policy: losing a reply must not replay an accepted send.
Outgoing `agent.message` file attachments use the shared A2A message builder:
`files: [{path}]`, at most four regular files and 8 MiB total, admitted through
the ordinary attachment fence and secret-content inspection before the request.
The captured bytes map to 1.0 `raw`/`filename`/`mediaType` parts (0.3 uses
`kind: file` and `file.bytes`/`name`/`mimeType`). See
[outgoing files](agent-communication.md#outgoing-files) for transport support and
inspection limits. These outgoing limits are distinct from received output limits.
Produced files retain the shared 10,000,000-byte file limit; encoded output
parts share a 16,000,000-byte budget. HTTP and gRPC accept complete messages
up to 32 MiB, including encoded files and task metadata. Streams bound each
frame and the assembled task rather than counting all prior frames again:
consumed SSE frames are released, and a final artifact replaces its draft.
HTTP completion returns the receipt already accumulated from complete frames;
an incomplete tail or EOF does not establish task completion.
`AgentPeerHTTP.send` owns one bounded live-update channel and forwarding task;
HTTP and gRPC yield into it, and settlement or cancellation closes both resources.
`AgentPeerDiscovery.authenticatedInterface` selects the first supported interface
through `AgentA2AWire` and authorizes it through `AgentPeerPolicy.peerAuthorizeInterface`,
including after an extended-card fetch. The card's origin is required, with one
exception: gRPC may use a sibling port on the same host and scheme.
A card cannot redirect credentials to another host or downgrade TLS.
Capability flags, task states and present provider-failure metadata use the
checked wire readers on every binding; malformed evidence reports its cause.
An eligible local webhook's configuration failure stops the send before it is
built. See [Agent conversations](agent-communication.md) for the failure contract.

## Schema and packages

`script/proto/a2a-v1.0.0/a2a.proto` and its Google annotation imports are the
inputs to `script/regenerate_a2a_grpc.sh`. Generated Swift is checked in under
`Modules/NativeAgentCore/Sources/AgentLinkTransport/Generated/`; normal app
builds do not run the generators.
Regeneration disables the unused generated client and trims the unused
simple-service API. Protobuf messages, method descriptors, `ServiceProtocol`
and its streaming adapters remain; the outbound adapter calls `GRPCClient`
directly.

Both package manifests pin:

| Package | Version | Selected product |
| --- | --- | --- |
| `grpc-swift-2` | 2.4.3 | `GRPCCore` |
| `grpc-swift-nio-transport` | 2.10.0 | `GRPCNIOTransportHTTP2TransportServices` |
| `grpc-swift-protobuf` | 2.4.1 | `GRPCProtobuf` |

The regeneration script declares its development prerequisites: `protoc`
33.4, `protoc-gen-swift` 1.38.1 and `protoc-gen-grpc-swift-2` from
grpc-swift-protobuf 2.4.1.
