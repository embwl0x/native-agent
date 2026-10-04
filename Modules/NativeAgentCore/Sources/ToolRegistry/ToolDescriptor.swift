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

/// Tools an owner outside Core contributes to the one catalog (the app's
/// browser, its own pages, health reads). Core registers the
/// descriptors, lists them in the Tools page's manifest, and hands each
/// call here.
public protocol ToolExecutor: Sendable {
    var descriptors: [ToolDescriptor] { get }
    /// Core tools this owner runs in place of Core's own case on the bodies
    /// that carry it, with Core's schema: one owner per body. (The app's
    /// notify reaches its live senders and gates them this way.)
    var replacesCoreTools: Set<String> { get }
    func execute(
        tool: String, input: [String: JSONValue], surface: String
    ) async throws -> JSONValue
}
