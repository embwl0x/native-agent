import Foundation
import NativeAgentCore
import PersistenceCore
import Research
import KnowledgeGraph
import CapabilityFoundry

// MARK: - MCP subprocess (stdio) client
//
// JSON-RPC 2.0 over newline-delimited framing (`<json>\n`, one message per
// line), matching the MCP stdio transport. Real MCP servers (the official
// Python/TS SDKs, npx @modelcontextprotocol/server-*) speak newline-delimited
// JSON-RPC — NOT LSP `Content-Length` framing.
// `MCPSubprocess` owns one persistent child,
// `MCPSubprocessPool` keys them by server id with crash + backoff handling,
// and `SwiftNativeMCPDispatcher.listToolsLive(...)` / `.listResourcesLive(...)`
// / `.listSessions()` wrap that pool with a 60s cache.
//
// Transport scope: stdio subprocess plus the two built-in NativeAgent
// transports configured by default: nativeagent-internal (in-process Swift
// reads) and searxng-local (Swift Research client). Arbitrary http/sse MCP
// servers still fail closed until a generic transport client is added.
