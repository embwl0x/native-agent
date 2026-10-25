import Foundation
import PersistenceCore
// Blueprint: | `BrowserRouteModels.swift` | `BrowserRun`, `NativeActionReceipt`; failed navigation receipts expose the retained openError as detail |

public struct BrowserRun: Identifiable, Codable, Hashable {
    public var id: String
    public var url: String?
    public var domain: String?
    public var status: String
    public var dryRun: Bool?
    public var visible: Bool?
    public var opened: Bool?
    public var approvalId: String?
    public var createdAt: String?
    public var sourceReceipt: JSONValue?
    public var screenshotReceipt: JSONValue?
    public init(id: String, url: String? = nil, domain: String? = nil, status: String, dryRun: Bool? = nil, visible: Bool? = nil, opened: Bool? = nil, approvalId: String? = nil, createdAt: String? = nil, sourceReceipt: JSONValue? = nil, screenshotReceipt: JSONValue? = nil) {
        self.id = id
        self.url = url
        self.domain = domain
        self.status = status
        self.dryRun = dryRun
        self.visible = visible
        self.opened = opened
        self.approvalId = approvalId
        self.createdAt = createdAt
        self.sourceReceipt = sourceReceipt
        self.screenshotReceipt = screenshotReceipt
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension BrowserRun {
    /// The browser writer's run envelope, as the record the app renders.
    init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), url: try row.optionalString("url"), domain: try row.optionalString("domain"),
            status: try row.string("status"), dryRun: try row.optionalBool("dryRun"),
            visible: try row.optionalBool("visible"), opened: try row.optionalBool("opened"),
            approvalId: try row.optionalString("approvalId"), createdAt: try row.optionalString("createdAt"),
            sourceReceipt: row.optionalValue("sourceReceipt"), screenshotReceipt: row.optionalValue("screenshotReceipt"))
    }
}

public struct NativeActionReceipt: Identifiable, Codable, Hashable {
    public var id: String
    public var actionId: String
    public var name: String?
    public var kind: String?
    public var status: String
    public var detail: String?
    public var dryRun: Bool?
    public var approvalId: String?
    public var createdAt: String?
    public var url: String?
    public var textPath: String?
    public var textPreview: String?
    public var textChars: Int64?
    public var linksPath: String?
    public var pngPath: String?
    public var linkCount: Int64?
    public var linksPreview: [BrowserLink]?
    public var sourceReceipt: JSONValue?
    public var screenshotReceipt: JSONValue?
    public init(id: String, actionId: String, name: String? = nil, kind: String? = nil, status: String, dryRun: Bool? = nil, approvalId: String? = nil, createdAt: String? = nil, url: String? = nil, textPath: String? = nil, textPreview: String? = nil, textChars: Int64? = nil, linksPath: String? = nil, pngPath: String? = nil, linkCount: Int64? = nil, linksPreview: [BrowserLink]? = nil, sourceReceipt: JSONValue? = nil, screenshotReceipt: JSONValue? = nil) {
        self.id = id
        self.actionId = actionId
        self.name = name
        self.kind = kind
        self.status = status
        self.dryRun = dryRun
        self.approvalId = approvalId
        self.createdAt = createdAt
        self.url = url
        self.textPath = textPath
        self.textPreview = textPreview
        self.textChars = textChars
        self.linksPath = linksPath
        self.pngPath = pngPath
        self.linkCount = linkCount
        self.linksPreview = linksPreview
        self.sourceReceipt = sourceReceipt
        self.screenshotReceipt = screenshotReceipt
        if status == "failed", case .object(let source)? = sourceReceipt,
           case .string(let cause)? = source["openError"] { self.detail = cause }
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
