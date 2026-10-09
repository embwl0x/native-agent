import TrustCenter
import NativeAgentCore
import AppToolRuntime
import Foundation
import Observation
import ChatOrchestration
import PersistenceCore
import ToolRegistry
import MCPDispatcher

/// `NativeAgentEngine.tools` (S10): the tool catalog and the authored-tool
/// registry for one data root, in core types. The Tools page renders
/// `catalog` (every tool, its load state and its trust here) and `authored`;
/// the reads are nonisolated so the phone snapshot and Doctor use the same
/// owner. Registry writes (auto-run, promote, quarantine) still run through
/// the tool executors on `NativeClient`.
@MainActor
@Observable
public final class ToolsFacade {
    public nonisolated let dataRoot: URL
    nonisolated private let ports: NativeAgentEnginePorts

    /// The full catalog as of the last successful read.
    public var catalog: ChatToolCatalogSnapshot?
    /// Why the last catalog read failed; nil after a successful one. A failed
    /// read keeps the previous `catalog` so the page can say it is stale.
    public var catalogLoadError: String?
    /// The tools she wrote, as of the last read.
    public var authored: [ToolRecord] = []
    public var mcpSessions: [MCPSessionStatus] = []

    public nonisolated init(dataRoot: URL, ports: NativeAgentEnginePorts) {
        self.dataRoot = dataRoot
        self.ports = ports
    }

    /// Core session rows, including the subprocess pool's live state.
    public nonisolated func listMCPSessions() async throws -> [MCPSessionStatus] {
        try await SwiftNativeMCPDispatcher(root: dataRoot).listSessions()
    }

    /// The trust-aware tool manifest, through the same dispatcher composition
    /// ordinary app chat uses, Mac Integration included.
    public nonisolated func loadManifest(detail: String? = nil) async throws -> JSONValue {
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        let inner = SwiftToolDispatcher(
            dataRoot: dataRoot,
            macIntegrationBridge: ports.macIntegration,
            appTools: ports.appTools(securityCenter, true),
            agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        )
        let dispatcher = AppChatToolDispatcher(inner: inner, securityCenter: securityCenter,
            interactions: ports.interactions, platform: ports.chatPlatform)
        return try await dispatcher.toolManifest(detail: detail)
    }

    /// The full manifest, typed for the Tools page.
    public nonisolated func loadCatalog() async throws -> ChatToolCatalogSnapshot {
        let envelope = try await loadManifest(detail: "full")
        guard let snapshot = ChatToolCatalogSnapshot(envelope: envelope) else {
            throw NSError(
                domain: "NativeAgent.ChatToolCatalog",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Tool manifest returned an invalid envelope."]
            )
        }
        return snapshot
    }

    /// Every authored tool in `tools/registry.json`. An absent registry is
    /// empty; bytes that are not a JSON array are unreadable, not empty.
    public nonisolated func listAuthored() async throws -> [ToolRecord] {
        let registryPath = dataRoot.appendingPathComponent("tools/registry.json")
        if FileManager.default.fileExists(atPath: registryPath.path) {
            let parsed = try JSONValue.parse(Data(contentsOf: registryPath))
            guard case .array = parsed else {
                throw ToolRegistryError.registryUnreadable(
                    reason: "tools registry must be a JSON array"
                )
            }
        }
        let records = try await SwiftNativeToolRegistry(root: dataRoot).listTools(filter: .all)
        for record in records {
            try Self.checkAuthored(record)
        }
        return records
    }

    /// A record whose authored fields do not read fails the whole read, so a
    /// damaged registry is never rendered (or reported by Doctor) as sound.
    public nonisolated static func checkAuthored(_ record: ToolRecord) throws {
        if let field = record.authoredFieldProblem {
            throw ToolRegistryError.registryUnreadable(
                reason: "tool \(record.id) has no valid \(field)"
            )
        }
    }

    /// Loads the catalog into `catalog`, recording a failure instead of
    /// clearing what the page already shows.
    @discardableResult
    public func refreshCatalog() async -> Bool {
        catalogLoadError = nil
        do {
            catalog = try await loadCatalog()
            return true
        } catch {
            nativeLog("[ChatToolCatalog] dispatch failed: \(error.localizedDescription)")
            catalogLoadError = error.localizedDescription
            return false
        }
    }
}
