import TrustCenter
import NativeAgentCore
import AppToolRuntime
import Foundation
import Observation
import ChatOrchestration
import PersistenceCore
import ToolRegistry
import ToolExecution
import MCPDispatcher
import Senses

/// `NativeAgentEngine.tools` (S10): the tool catalog and the authored-tool
/// registry for one data root, in core types. The Tools page renders
/// `catalog` (every tool, its load state and its trust here) and `authored`;
/// the reads are nonisolated so the phone snapshot and Doctor use the same
/// owner. Registry writes (auto-run, promote, quarantine) read back through
/// the same authored-field check.
@MainActor
@Observable
public final class ToolsFacade {
    public private(set) var slashCatalog: [ToolCapability] = []
    public private(set) var slashTools: [ToolCapability] = []
    public private(set) var slashCommandNames: Set<String> = []
    private var slashCatalogFetchedAt: Date?
    private var isFetchingSlashCatalog = false

    public func refreshSlashCatalog() async {
        if let last = slashCatalogFetchedAt, Date().timeIntervalSince(last) < 30 { return }
        guard !isFetchingSlashCatalog else { return }
        isFetchingSlashCatalog = true
        defer { isFetchingSlashCatalog = false }
        do {
            let envelope = try await loadManifest()
            let (sorted, eligible, names) = try await Task.detached(priority: .userInitiated) {
                let data = try envelope.serializedData(pretty: false)
                let manifest = try JSONDecoder().decode(ToolCapabilityManifest.self, from: data)
                let sorted = manifest.tools.sorted { $0.name < $1.name }
                let eligible = sorted.filter { !$0.sideEffects && $0.effectiveAutonomy == "auto" && $0.availableNow }
                return (sorted, eligible, Set(eligible.map(\.name)))
            }.value
            slashCatalog = sorted
            slashTools = eligible
            slashCommandNames = names
            slashCatalogFetchedAt = Date()
        } catch {
            slashCatalog = []
            slashTools = []
            slashCommandNames = []
            slashCatalogFetchedAt = nil
        }
    }
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

    /// The MCP registry, consent ledger and live sessions for this data root.
    public nonisolated var mcp: SwiftNativeMCPDispatcher { SwiftNativeMCPDispatcher(root: dataRoot) }

    /// Core session rows, including the subprocess pool's live state.
    public nonisolated func listMCPSessions() async throws -> [MCPSessionStatus] {
        try await mcp.listSessions()
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

    /// Every authored tool in the ability files; malformed files fail the read.
    public nonisolated func listAuthored() async throws -> [ToolRecord] {
        let records = try await SwiftNativeToolRegistry(root: dataRoot).listTools(filter: .all)
        for record in records {
            try Self.checkAuthored(record)
        }
        return records
    }

    public func refreshAuthored(confirming id: String, status: String) async throws -> Bool {
        let records = try await listAuthored()
        guard records.first(where: { $0.id == id })?.status == status else { return false }
        authored = records
        return true
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

    /// Promote a proposal. The promoted record carries the registry's typed
    /// slots plus every extras key the promote engine merges in, and reads
    /// back through the same authored-field check as the list.
    public nonisolated func promote(id: String, allowRisky: Bool, ownerAuthorized: Bool = false, digest: String? = nil) async throws -> ToolRecord {
        let host = AppToolExecutor.authoredProgramHost(dataRoot: dataRoot) { _, _ in
            .object(["status": .string("refused"), "effects": .string("none"), "reason": .string("door_unavailable")])
        }
        let proposal = try await OwnedProgramInvocation.$host.withValue(host) {
            try await SwiftNativeToolExecution(root: dataRoot).promote(id: id, allowRisky: allowRisky, ownerAuthorized: ownerAuthorized, digest: digest).toJSON()
        }
        if let field = ToolRecord.stringFieldProblem(in: proposal) {
            throw ToolRegistryError.registryUnreadable(reason: "promoted tool \(id) has no valid \(field)")
        }
        guard let record = ToolRecord(json: proposal) else {
            throw ToolRegistryError.registryUnreadable(reason: "promoted tool \(id) has no registry record")
        }
        try Self.checkAuthored(record)
        return record
    }

    public nonisolated func quarantine(id: String, reason: String, ownerAuthorized: Bool = false) async throws -> ToolRecord {
        let record = try await SwiftNativeToolRegistry(root: dataRoot).quarantine(id: id, reason: reason, ownerAuthorized: ownerAuthorized)
        try Self.checkAuthored(record)
        return record
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
extension ToolsFacade {
    /// Resolve how to dispatch `toolName` given raw free-text args from the slash command.
    /// Returns nil if no tool with that name exists.
    public func planDispatch(toolName: String, freeText: String) -> DispatchArgPlan? {
        guard let tool = slashCatalog.first(where: { $0.name == toolName }) else { return nil }

        let schema = tool.inputSchema
        let required = schema?.required ?? []
        let props = schema?.properties ?? [:]

        // Zero required args → fire immediately.
        if required.isEmpty {
            return DispatchArgPlan(tool: tool, mode: .zeroArgs, prefilled: [:])
        }

        // Single required field that is a string → shortcut.
        if required.count == 1,
           let fieldName = required.first,
           let prop = props[fieldName],
           (prop.type == "string" || prop.type == nil) {
            let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefilled: [String: Any] = trimmed.isEmpty ? [:] : [fieldName: trimmed]
            return DispatchArgPlan(tool: tool, mode: .singleStringArg(field: fieldName), prefilled: prefilled)
        }

        // Anything else → show a form.
        return DispatchArgPlan(tool: tool, mode: .formNeeded, prefilled: [:])
    }
}

private struct ToolCapabilityManifest: Decodable, Sendable {
    let tools: [ToolCapability]
}

extension ToolsFacade {
    public nonisolated convenience init(dataRoot: URL) {
        self.init(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot))
    }
}
