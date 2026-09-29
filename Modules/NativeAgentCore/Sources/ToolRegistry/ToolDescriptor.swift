import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Tool descriptors (S9, 2026-09-26)

/// Stable, runtime-owned categories for the Tools catalog. The catalog is the
/// authority for the mounted tool set; this registry is the authority for the
/// names implemented by the Swift dispatcher. Keeping both facts together
/// means a new dispatcher case cannot quietly fall into a presentation
/// catch-all without its category being reviewed.
public enum ChatToolCatalogBucket: String, CaseIterable, Sendable {
    case mcp
    case shell
    case system
    case macControl = "mac-control"
    case macIntegration = "mac-integration"
    case fileOps = "file-ops"
    case alwaysOn = "always-on"
    case browser
    case core
    case unclassified

    public var title: String {
        switch self {
        case .mcp: return "MCP (External Servers)"
        case .shell: return "Shell / Build"
        case .system: return "System"
        case .macControl: return "Mac Control"
        case .macIntegration: return "Mac Integration"
        case .fileOps: return "File Ops"
        case .alwaysOn: return "Always-on"
        case .browser: return "Browser"
        case .core: return "Core & Connectors"
        case .unclassified: return "Unclassified Runtime Tools"
        }
    }

    public var systemImage: String {
        switch self {
        case .mcp: return "link"
        case .shell: return "terminal"
        case .system: return "cpu"
        case .macControl: return "macwindow"
        case .macIntegration: return "app.badge"
        case .fileOps: return "doc.text"
        case .alwaysOn: return "bolt.circle"
        case .browser: return "safari"
        case .core: return "bolt.circle"
        case .unclassified: return "exclamationmark.triangle"
        }
    }
}

/// One tool as the router and the catalog know it: the schema the model is
/// offered (name, description, parameters — byte for byte) and the Tools-page
/// bucket it is filed under. Trust stays keyed on the canonical name in the
/// Trust Center's profiles; a descriptor adds no authority.
public struct ToolDescriptor: Sendable {
    public let schema: LLMToolSchema
    public let bucket: ChatToolCatalogBucket

    public init(schema: LLMToolSchema, bucket: ChatToolCatalogBucket) {
        self.schema = schema
        self.bucket = bucket
    }

    public var name: String { schema.name }
}

/// A `tool_load` / `tool_catalog` category: the words that name it and the
/// tools one load of it brings. A family may include tools another owner
/// registers (the research family brings web search with the browser).
public struct ToolFamily: Sendable {
    public let group: String
    public let aliases: Set<String>
    public let tools: Set<String>

    public init(group: String, aliases: Set<String>, tools: Set<String>) {
        self.group = group
        self.aliases = aliases
        self.tools = tools
    }

    /// True when `category` (trimmed, lowercased) names this family.
    public func named(_ category: String) -> Bool {
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key == group || aliases.contains(key)
    }
}

/// Tools an owner outside Core contributes to the one catalog (the app's
/// browser, its own pages, health reads, reflex review). Core registers the
/// descriptors, answers catalog and load for them, runs its lazy-load gate,
/// and hands each call here. `host` is the router that called, for an
/// executor that has to load its own family (a page opened brings its hands).
public protocol ToolExecutor: Sendable {
    var descriptors: [ToolDescriptor] { get }
    var families: [ToolFamily] { get }
    /// Core tools this owner runs in place of Core's own case on the bodies
    /// that carry it, with Core's schema: one owner per body. (The app's
    /// notify reaches its live senders and gates them this way.)
    var replacesCoreTools: Set<String> { get }
    /// Trust decides discovery for its tools: one the Trust Center blocks here
    /// is neither ranked nor loaded by a catalog search.
    func blockedHere(_ tool: String, surface: String) async -> Bool
    func execute(
        tool: String, input: [String: JSONValue], surface: String, host: any ToolLoading
    ) async throws -> JSONValue
}

/// The one thing an executor may ask of the router that called it.
public protocol ToolLoading: Sendable {
    func loadTools(_ names: [String], sessionId: String, surface: String) async
}
