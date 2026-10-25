import Foundation
// Blueprint: | `PartFace.swift` | Shared Codable/Sendable PartCallResult and PartCallError, typed PartFace sections/rows, and PartFaceSnapshot with native ready/unavailable/failed/error/owed fields for Mac and iPhone |

/// A decision, never authority to commit it. Shared by native and JS callers.
public enum PartCallResult<Value: Codable & Sendable>: Codable, Sendable {
    case success(Value)
    case failure(PartCallError)
    private enum CodingKeys: String, CodingKey { case ok, value, error }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if try fields.decode(Bool.self, forKey: .ok) {
            self = .success(try fields.decode(Value.self, forKey: .value))
        } else { self = .failure(try fields.decode(PartCallError.self, forKey: .error)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let value):
            try fields.encode(true, forKey: .ok); try fields.encode(value, forKey: .value)
        case .failure(let error):
            try fields.encode(false, forKey: .ok); try fields.encode(error, forKey: .error)
        }
    }
}

public struct PartCallError: Error, Codable, Sendable, Equatable, LocalizedError {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// One authored projection for the agent, Mac and iPhone. Native availability,
/// failure and repair obligations accompany it in PartFaceSnapshot.
public struct PartFace: Codable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String?
        public let value: String?
        public init(id: String, title: String, detail: String? = nil, value: String? = nil) {
            self.id = id; self.title = title; self.detail = detail; self.value = value
        }
    }
    public struct Section: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String?
        public let rows: [Row]
        public init(id: String, title: String? = nil, rows: [Row]) { self.id = id; self.title = title; self.rows = rows }
    }
    public let sections: [Section]
    public init(sections: [Section]) { self.sections = sections }
}

/// Only native source/obligation owners supply status and owed. Both platforms
/// render these beside, rather than from within, the part's editable prose.
public struct PartFaceSnapshot: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ready, unavailable, failed }
    public let part: String
    public let version: String?
    public let sourceEpoch: UInt64
    public let status: Status
    public let face: PartFace?
    public let error: PartCallError?
    public let owed: Bool
    public init(part: String, version: String?, sourceEpoch: UInt64, status: Status,
                face: PartFace?, error: PartCallError?, owed: Bool) {
        self.part = part; self.version = version; self.sourceEpoch = sourceEpoch
        self.status = status; self.face = face; self.error = error; self.owed = owed
    }
}
