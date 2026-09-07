import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore

// Training, promotion, and evaluation readers, their caller-facing gate
// predicates, and stored JSON field projections.
extension SwiftNativeSelfImprovement {

    // MARK: - Trust gates
    // NativeClient consults these gates before exposing training/promotion data.
    // A missing outer object or leaf preserves the default-true gate; a saved
    // leaf uses Python-compatible truthiness. Malformed outer objects deny.
    // Developer Mode is a separate explicit override after a successful read.

    /// Only a missing policy receives bootstrap defaults. Existing unreadable
    /// or malformed policy must not open default-true training gates.
    func readSavedTrustPolicy() async throws -> [String: JSONValue] {
        let url = trainingPromotionDataRoot()
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Data follows symlinks; a dangling policy is unreadable authority,
            // not a missing policy eligible for bootstrap defaults.
            var metadata = stat()
            if lstat(url.path, &metadata) != 0, errno == ENOENT { return [:] }
            throw error
        }
        let raw = try JSONValue.parse(data)
        guard case .object(let obj) = raw else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return obj
    }

    /// Python-compatible truthiness for saved policy leaves: absent, null,
    /// false, zero and empty strings/containers are false; other values are true.
    static func pythonBool(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .null:            return false
        case .bool(let b):     return b
        case .int(let i):      return i != 0
        case .double(let d):   return d != 0
        case .string(let s):   return !s.isEmpty
        case .array(let a):    return !a.isEmpty
        case .object(let o):   return !o.isEmpty
        }
    }

    /// Missing outer objects or leaves preserve the supplied default. A present
    /// non-object outer value denies; a present leaf uses stored truthiness.
    static func nestedGateTruthy(
        _ policy: [String: JSONValue],
        outer: String,
        inner: String,
        defaultWhenAbsent: Bool
    ) -> Bool {
        guard let outerVal = policy[outer] else {
            return defaultWhenAbsent
        }
        guard case .object(let nested) = outerVal else {
            return false
        }
        guard let leaf = nested[inner] else {
            return defaultWhenAbsent
        }
        return pythonBool(leaf)
    }

    /// Developer Mode is an explicit operator escalation, independent of the
    /// Full Mac permission preset. Honor its saved truthiness after a good read.
    private static func effectiveDeveloperMode(_ policy: [String: JSONValue]) -> Bool {
        return pythonBool(policy["developerMode"])
    }

    /// Read the live policy: deny on read failure, otherwise allow Developer
    /// Mode or the autonomous-training leaf (default true when absent).
    public func trainingAllowed() async -> Bool {
        guard let policy = try? await readSavedTrustPolicy() else { return false }
        if Self.effectiveDeveloperMode(policy) { return true }
        return Self.nestedGateTruthy(
            policy,
            outer: "trainingPolicy",
            inner: "autonomous_training",
            defaultWhenAbsent: true
        )
    }

    /// Read the live policy: deny on read failure, otherwise allow Developer
    /// Mode or the promotion-enabled leaf (default true when absent).
    public func promotionAllowed() async -> Bool {
        guard let policy = try? await readSavedTrustPolicy() else { return false }
        if Self.effectiveDeveloperMode(policy) { return true }
        return Self.nestedGateTruthy(
            policy,
            outer: "promotionPolicy",
            inner: "enabled",
            defaultWhenAbsent: true
        )
    }

    /// Shared training and promotion journal root.
    func trainingJournalDir() -> URL {
        trainingPromotionDataRoot().appendingPathComponent("training_journal", isDirectory: true)
    }

    /// Visible files matching the suffix, sorted by UTF-8 filename bytes.
    /// Reverse order is newest-first for timestamp-prefixed filenames.
    /// Missing or unreadable directories return an empty list.
    static func sortedJSONFiles(
        in dir: URL,
        suffix: String = ".json",
        reversedName: Bool
    ) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let matched = entries.filter { $0.lastPathComponent.hasSuffix(suffix) }
        // Sort by file NAME (UTF-8 byte order) to match Python's sorted(glob()).
        let sorted = matched.sorted { lhs, rhs in
            Array(lhs.lastPathComponent.utf8)
                .lexicographicallyPrecedes(Array(rhs.lastPathComponent.utf8))
        }
        return reversedName ? sorted.reversed() : sorted
    }

    /// Read an object, or nil for missing, malformed, or non-object JSON.
    func readJSONObject(_ url: URL) async -> [String: JSONValue]? {
        let raw = await trainingPromotionPersistence().readJSON(url, defaultValue: .null)
        guard case .object(let obj) = raw else { return nil }
        return obj
    }

    // MARK: GET /v1/training/runs

    /// Newest-first graded runs projected to the five summary fields below;
    /// absent fields are null.
    public func listTrainingRunsLocal() async -> JSONValue {
        let dir = trainingJournalDir().appendingPathComponent("drill_runs", isDirectory: true)
        let files = Self.sortedJSONFiles(in: dir, suffix: "-graded.json", reversedName: true)
        var out: [JSONValue] = []
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            out.append(.object([
                "run_id": obj["run_id"] ?? .null,
                "suite_name": obj["suite_name"] ?? .null,
                "graded_at": obj["graded_at"] ?? .null,
                "total_score": obj["total_score"] ?? .null,
                "max_score": obj["max_score"] ?? .null,
            ]))
        }
        return .array(out)
    }

    // MARK: GET /v1/training/runs/<id>  (detail sibling of list_runs)

    /// Return the full graded-run JSON, with nil for a missing file and an
    /// empty object for parse failure. Valid non-object JSON passes through.
    /// The run ID is appended verbatim; callers supply the stored run identifier.
    public func getTrainingRunLocal(runId: String) async -> JSONValue? {
        let dir = trainingJournalDir().appendingPathComponent("drill_runs", isDirectory: true)
        let f = dir.appendingPathComponent("\(runId)-graded.json")
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return await trainingPromotionPersistence().readJSON(f, defaultValue: .object([:]))
    }

    // MARK: GET /v1/training/proposals

    /// Full proposal objects in forward filename order; no field projection.
    public func listTrainingProposalsLocal() async -> JSONValue {
        let dir = trainingJournalDir().appendingPathComponent("proposals", isDirectory: true)
        let files = Self.sortedJSONFiles(in: dir, reversedName: false)
        var out: [JSONValue] = []
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            out.append(.object(obj))
        }
        return .array(out)
    }

    // MARK: GET /v1/promotion/candidates

    /// Newest-first candidates projected to the stored candidate field set.
    /// Extra fields are omitted and missing fields become null.
    public func listPromotionCandidatesLocal() async -> JSONValue {
        let dir = trainingJournalDir().appendingPathComponent("promotion_candidates", isDirectory: true)
        let files = Self.sortedJSONFiles(in: dir, reversedName: true)
        var out: [JSONValue] = []
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            out.append(Self.projectCandidateRun(obj))
        }
        return .array(out)
    }

    // MARK: GET /v1/promotion/pending

    /// Forward filename order, pending status only, projected to stage fields.
    public func listPromotionPendingLocal() async -> JSONValue {
        let dir = trainingJournalDir().appendingPathComponent("promotion_stages", isDirectory: true)
        let files = Self.sortedJSONFiles(in: dir, reversedName: false)
        var out: [JSONValue] = []
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            if case .string(let status)? = obj["status"], status == "pending" {
                out.append(Self.projectStage(obj))
            }
        }
        return .array(out)
    }

    // MARK: GET /v1/evals/runs

    /// Read the evaluations array and sort descending by `pythonStrOr(createdAt)`.
    /// Non-array storage returns empty. Preserve input order for equal keys by
    /// carrying the original index as the ascending tiebreaker.
    public func listEvalsLocal() async -> JSONValue {
        let url = trainingPromotionDataRoot()
            .appendingPathComponent("evals", isDirectory: true)
            .appendingPathComponent("runs.json")
        let raw = await trainingPromotionPersistence().readJSON(url, defaultValue: .array([]))
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

    /// Use the default only for an absent key. Present values use Python-style
    /// scalar strings (null becomes "None"); containers use JSON serialization.
    /// Defaulting a malformed change_type to "append" would authorize it.
    static func pythonStr(_ v: JSONValue?, defaultWhenAbsent: String) -> String {
        guard let v else { return defaultWhenAbsent }   // key absent → Python default
        switch v {
        case .null:            return "None"            // str(None) == "None"
        case .bool(let b):     return b ? "True" : "False"
        case .int(let i):      return String(i)
        case .double(let d):   return String(d)
        case .string(let s):   return s
        case .array(let a):    return (try? JSONValue.array(a).serialize(pretty: false)) ?? "[]"
        case .object(let o):   return (try? JSONValue.object(o).serialize(pretty: false)) ?? "{}"
        }
    }

    // MARK: - Dataclass field projection

    /// Stored candidate field order. Missing fields project as null.
    private static let candidateRunFields: [String] = [
        "candidate_id", "source", "tier", "patches", "status", "created_at",
        "finished_at", "harness", "decision", "decision_reason",
        "worktree_path", "branch_name", "merged_commit_sha", "error",
    ]

    private static func projectCandidateRun(_ obj: [String: JSONValue]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for k in candidateRunFields { out[k] = obj[k] ?? .null }
        return .object(out)
    }

    /// Stage dataclass fields in declaration order.
    private static let stageFields: [String] = [
        "candidate_id", "tier", "harness", "delta", "staged_at",
        "worktree_path", "branch_name", "status", "resolved_at",
        "resolution_reason",
    ]

    private static func projectStage(_ obj: [String: JSONValue]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for k in stageFields {
            // `status` defaults to "pending" on the dataclass; but we only
            // reach here for status=="pending" anyway, so the file always has it.
            out[k] = obj[k] ?? .null
        }
        return .object(out)
    }

}
