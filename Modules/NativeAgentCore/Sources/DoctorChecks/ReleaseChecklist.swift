import Foundation

public struct ReleaseChecklistItem: Identifiable, Codable, Hashable {
    public var id: String
    public var title: String = ""
    public var status: String = ""
    public var detail: String = ""

    // FIX-2026-05-28: see EvalCheck. id required; everything else lenient.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

public struct ReleaseChecklist: Codable, Hashable {
    public var status: String = ""
    public var items: [ReleaseChecklistItem] = []
    public var createdAt: String = ""

    // FIX-2026-05-28: no id — every field tolerates a missing key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        self.items = try c.decodeIfPresent([ReleaseChecklistItem].self, forKey: .items) ?? []
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}
