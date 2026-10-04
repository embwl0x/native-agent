import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Server listing for the capability records
//
// TrustCenter's source #6 (list_mcp_servers), owned here and handed to
// `capabilityRecordsFull` / `SwiftNativeCapabilityTrust` by the caller.
// Port of the retired daemon — defers to SwiftNativeMCPDispatcher
// which already implements the byte-identical merge logic at
// MCPDispatcher.swift:518. We re-shape its [MCPServer] output into the
// dict-bag form the aggregator consumes.
//
// Read uses the cache; the dispatcher's actor TTL keeps subsequent reads
// from re-hitting disk if multiple aggregator calls land in a 60-second
// window.
public func listMCPServersAsDicts(
    dataRoot: URL,
    dispatcher: SwiftNativeMCPDispatcher? = nil,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
) async throws -> [[String: JSONValue]] {
    let disp = dispatcher ?? SwiftNativeMCPDispatcher(
        root: dataRoot, persistence: persistence
    )
    let servers = try await disp.listServers()
    return servers.compactMap {
        if case .object(let dict) = $0.toJSON() { return dict }
        return nil
    }
}
