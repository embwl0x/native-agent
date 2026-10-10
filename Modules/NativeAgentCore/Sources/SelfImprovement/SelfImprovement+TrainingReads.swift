import Foundation
import NativeAgentCore
import PersistenceCore

// Evaluation reads remain independent of the weekly runtime improvement pass.
extension SwiftNativeSelfImprovement {
    // MARK: GET /v1/evals/runs

    /// Read the evaluations array and sort descending by `pythonStrOr(createdAt)`.
    /// Non-array storage returns empty. Preserve input order for equal keys by
    /// carrying the original index as the ascending tiebreaker.
    public func listEvalsLocal() async throws -> JSONValue {
        let url = dataRoot
            .appendingPathComponent("evals", isDirectory: true)
            .appendingPathComponent("runs.json")
        let raw = try await persistence.readJSON(url, ifMissing: .array([]))
        guard case .array(let arr) = raw else { return .array([]) }
        let keyed: [(key: String, idx: Int, value: JSONValue)] = arr.enumerated().map { (i, item) in
            var key = ""
            if case .object(let obj) = item {
                key = Self.pythonStrOr(obj["createdAt"])
            }
            // Non-object elements are retained with an empty sort key.
            return (key, i, item)
        }
        let sorted = keyed.sorted { a, b in
            if a.key != b.key { return a.key > b.key }   // DESC by key
            return a.idx < b.idx                          // tie → original order
        }.map { $0.value }
        return .array(sorted)
    }

    /// Reproduce Python `str(value or "")` for the JSON types `createdAt` can
    /// hold. Falsy (null/missing, false, 0, 0.0, "", empty array/object) → "".
    /// Truthy: string → itself; bool true → "True"; int → base-10; double →
    /// Python-ish repr (whole doubles render without a trailing ".0" only in
    /// rare cases — `createdAt` is always an ISO string in practice, so this
    /// branch is a defensive parity fallback, not a hot path).
    static func pythonStrOr(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        switch v {
        case .null:
            return ""
        case .bool(let b):
            return b ? "True" : ""           // Python: str(True)=="True"; False is falsy → ""
        case .int(let i):
            return i == 0 ? "" : String(i)
        case .double(let d):
            return d == 0 ? "" : String(d)
        case .string(let s):
            return s                          // "" stays "" (falsy → "")
        case .array(let a):
            return a.isEmpty ? "" : (try? JSONValue.array(a).serialize(pretty: false)) ?? ""
        case .object(let o):
            return o.isEmpty ? "" : (try? JSONValue.object(o).serialize(pretty: false)) ?? ""
        }
    }

    public func evals() async throws -> [EvalRun] {
        try JSONDecoder().decode([EvalRun].self, from: try await listEvalsLocal().serializedData(pretty: false))
    }
}

// FIX: only `id` truly required; non-identifying fields defaulted so one
// omitted key doesn't throw the whole endpoint decode.
public struct EvalCheck: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String = ""
    public var passed: Bool = false
    public var detail: String = ""

    // FIX-2026-05-28: synthesized Decodable throws keyNotFound on missing non-
    // optional keys despite Swift defaults; decodeIfPresent ?? default fixes it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.passed = try c.decodeIfPresent(Bool.self, forKey: .passed) ?? false
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

public struct EvalRun: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String = ""
    public var status: String = ""
    public var checks: [EvalCheck] = []
    public var createdAt: String = ""
    public var durationSeconds: Double?

    // FIX-2026-05-28: see EvalCheck. id required; everything else lenient.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        self.checks = try c.decodeIfPresent([EvalCheck].self, forKey: .checks) ?? []
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
    }
}
