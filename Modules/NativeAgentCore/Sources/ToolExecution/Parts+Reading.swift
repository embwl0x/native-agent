import AuthoredCapabilities
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import PersonaEngine
import Senses
import ToolRegistry
import CryptoKit
import TrustCenter
import Privacy
// Blueprint: | `Parts+Reading.swift` | Parts identity and row lookup, selected-version reads and bounded all-kind lists; built-in guidance and nearest-three unknown-id receipts |

extension Parts {
    /// Execution records by default; nil includes every stored kind for reads.
    public func rows(kind: AbilityStore.Kind? = .part) throws -> [[String: JSONValue]] {
        guard case .array(let rows) = try abilities.registry(kind: kind) else {
            throw ToolFailureError("The ability registry did not return rows.", effects: .none, owner: abilities.root.path,
                nextCall: ToolFailureError.call("app", ["action": .string("files.list"), "args": .object(["path": .string(abilities.root.path)])]),
                code: "ability_registry_shape", instruction: "Inspect the ability sources and repair the reported malformed header from retained evidence; preserve versions and authority.", recovery: .inspect)
        }
        return rows.map(Self.fields)
    }

    /// One reference spelling for every ability verb, including save's new id. Action names come from the registry; they name the same
    /// ability.
    public static func referenceID(_ given: String) -> String {
        ToolNameAliases.authoredTool(given) ?? given.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The part a name names: its bare/action id, else its name, either case.
    public func row(_ named: String, kind: AbilityStore.Kind? = .part) throws -> [String: JSONValue]? {
        let name = Self.referenceID(named)
        let all = try rows(kind: kind)
        return all.first { Self.string($0, "id")?.caseInsensitiveCompare(name) == .orderedSame }
            ?? all.first { Self.string($0, "name")?.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The id rule: lowercase letters, digits, - and _, a letter first, 2 to 64 long. "Days left" is days-left.
    public static func id(_ given: String) -> String {
        AbilityStore.normalizedID(referenceID(given))
    }

    /// Its latest version: the one waiting, else the selected one.
    public func latest(_ row: [String: JSONValue]) throws -> OwnedProgramStore.Candidate? {
        guard let id = Self.string(row, "id"),
              let digest = Self.string(row, "candidateDigest") ?? Self.string(row, "codeFingerprint") else { return nil }
        return try store.load(id: id, digest: digest)
    }

    public func unknown(_ named: String, kind: AbilityStore.Kind? = .part, guidanceIDs: [String] = []) throws -> Outcome {
        let requested = Array(Self.referenceID(named).lowercased())
        // Edit distance ranks suggestions only; it never selects a mutation target.
        let ids = Set(try rows(kind: kind).compactMap { Self.string($0, "id") } + guidanceIDs)
        let distances: [(id: String, distance: Int)] = ids.map { (id: $0, distance: characterEditDistance(Array($0.lowercased()), requested)) }
        let ordered = distances.sorted { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.id < rhs.id
        }
        let nearest: [String] = ordered.prefix(3).map { $0.id }
        let detail = "No ability of yours is called \(named.isEmpty ? "(none passed)" : named). "
            + (nearest.isEmpty ? "No ability ids are available." : "Nearest ids: \(nearest.joined(separator: ", ")).")
            + " ability.list shows them."
        return (false, detail,
         ["reason": .string("unknown_part"), "effects": .string("none"), "detail": .string(detail),
          "nearest_ids": .array(nearest.map(JSONValue.string)),
          "remedy": Repair.remedy(owner: "abilities", nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("ability.list")])]), tap: nil,
                                  instruction: "Choose an exact id from ability.list, or save a new ability.")])
    }

    static func readCall(_ id: String) -> JSONValue {
        .object(["tool": .string("app"), "input": .object(["action": .string("ability.read"), "args": .object(["id": .string(id)])])])
    }

    static func missing(_ named: String) -> ToolFailureError {
        ToolFailureError(PartError.notFound(named).localizedDescription, effects: .none, owner: "abilities",
            nextCall: ToolFailureError.call("app", ["action": .string("ability.list")]), code: "unknown_part", status: .refused,
            instruction: "Choose an exact id from ability.list, or save a new ability.", recovery: .inspect)
    }

    /// `ability.read`: selected declarations/status plus the latest code (waiting before selected), labeled by source.version; guidance
    /// reads too.
    public func read(_ named: String, offset: Int = 0, step: Int? = nil) throws -> JSONValue {
        guard let row = try row(named, kind: nil), let id = Self.string(row, "id") else {
            let entries = try InstalledSkillInventory.entries(dataRoot: root)
            guard let guidance = InstalledSkillInventory.match(Self.referenceID(named), in: entries) else {
                return .object(try unknown(named, kind: nil, guidanceIDs: entries.map(\.id)).fields
                    .merging(["status": .string("not_found")]) { $1 })
            }
            return .object(["status": .string("ok"), "id": .string(guidance.id), "built_in": .bool(true),
                            "guidance": .string(guidance.body ?? ""),
                            "note": .string("Built-in guidance from the persona: read it; it is not an ability and does not run.")])
        }
        var read = row.filter { ["id", "kind", "version", "name", "description", "status", "triggers", "origin", "overrides", "disabledBy", "disabledReason",
                                 "validation_evidence", "candidate_validation_evidence", "learned"].contains($0.key) }
        read["status"] = .string("ok"); read["ability_status"] = row["status"] ?? .null
        var declares: [String: JSONValue] = [:]
        for (key, field) in [("params", "params"), ("input_schema", "inputSchema"), ("actions", "actions"), ("reach", "reach"),
                             ("wake", "wake"), ("face", "face"), ("resident", "resident")] { declares[key] = row[field] ?? .null }
        if row["kind"] == .string("sense") {
            declares.removeValue(forKey: "wake"); declares.removeValue(forKey: "resident"); declares["mode"] = row["mode"]
        }
        read["declares"] = .object(declares)
        var versions: [String: JSONValue] = [:]
        for (key, field) in [("current", "codeFingerprint"), ("waiting", "candidateDigest"), ("previous", "previousVersion"),
                             ("last_clean", "lastCleanVersion")] { versions[key] = row[field] ?? .null }
        if row["candidateDigest"] != nil { versions["waiting_validation"] = row["candidateValidation"] ?? .null }
        if row["kind"] != .string("ability") {
            versions = ["current": row["version"] ?? .null, "previous": row["previousVersion"] ?? .null]
        }
        read["versions"] = .object(versions)
        if Self.runs(row) { read["run"] = .object(["action": .string("authored." + id), "args": .object([:])]) }
        read["converted_versions"] = .array(try (row["kind"] == .string("ability") ? store.conversions(id: id) : []).map { candidate in
            .object(["version": .string(candidate.digest), "converts": Self.fields(candidate.manifest)["converts"] ?? .array([]),
                     "rollback_call": .object(["action": .string("ability.rollback"), "args": .object(["id": .string(id), "version": .string(candidate.digest)])])])
        })
        let latest = row["kind"] == .string("ability") ? try latest(row) : nil
        // Compiled from recorded practice: where its lifecycle stands. Standing is never granted here; its live runs (learned) earn it.
        if let latest, case .object(var compiled)? = Self.fields(latest.manifest)["compiled"] {
            let waiting = row["candidateDigest"] != nil
            compiled["lifecycle"] = .string(waiting ? (row["candidateValidation"] == .string("replayed") ? "verified" : "staged")
                : row["status"] == .string("active") ? "admitted" : "off")
            compiled["standing"] = .string("no autonomous standing transition; learned.use records live execution evidence, replay earns none")
            read["compiled"] = .object(compiled)
        }
        let file = latest == nil ? try abilities.files().first(where: { $0.id == id }) : nil
        if let source = latest?.program.source ?? file?.body {
            if latest != nil || file?.pathExtension == "js" {
                let version = try latest?.digest ?? (file?.record["version"] ?? .null).serialize(pretty: false)
                read["source"] = AbilityStore.sourcePage(source, version: version, offset: offset) {
                    .object(["tool": .string("app"), "input": .object(["action": .string("ability.read"),
                        "args": .object(["id": .string(id), "offset": .int(Int64($0))])])])
                }
                if let step { read["step"] = Self.step(source, step) }
            } else { read["guidance"] = .string(source) }
        }
        return .object(read)
    }

    /// One `app.step` of its code: its label and guidance as written, and its lines when each step starts a line of its own.
    static func step(_ source: String, _ n: Int) -> JSONValue {
        let lines = source.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].contains("app.step(") }
        guard n >= 1, n <= starts.count else {
            let instruction = starts.isEmpty ? "This code declares no app.step calls; omit step to read its source."
                : "Set step to an integer from 1 to \(starts.count), or omit it to read the source."
            return .object(["status": .string("refused"), "reason": .string("invalid_ability_step"), "effects": .string("none"),
                "argument_path": .string("step"), "accepted": .string(starts.isEmpty ? "omit step; no steps exist" : "an integer from 1 to \(starts.count)"),
                "detail": .string("The code declares \(starts.count) app.step calls; step \(n) does not select one."),
                "remedy": .object(["kind": .string("correct_arguments"), "instruction": .string(instruction), "next_call": .null])])
        }
        let at = n - 1
        var out: [String: JSONValue] = ["step": .string("\(n) of \(starts.count)")]
        let literal = #"app\.step\(\s*(["'`])((?:\\.|(?!\1).)*)\1(?:\s*,\s*(["'`])((?:\\.|(?!\3).)*)\3)?"#
        let line = lines[starts[at]]
        if let regex = try? NSRegularExpression(pattern: literal), let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            for (index, key) in [(2, "label"), (4, "guidance")] {
                if let range = Range(match.range(at: index), in: line), !line[range].isEmpty { out[key] = .string(String(line[range])) }
            }
        }
        let end = at + 1 < starts.count ? starts[at + 1] : lines.count
        out["lines"] = .string("\(starts[at] + 1)-\(end)")
        out["source"] = .string(lines[starts[at]..<end].joined(separator: "\n"))
        return .object(out)
    }

    /// `ability.list`: every part, one row each, and the built-in guidance to read.
    public func list(offset: Int = 0) throws -> JSONValue {
        let rows = try rows(kind: nil).sorted { (Self.string($0, "id") ?? "") < (Self.string($1, "id") ?? "") }
        let start = min(max(0, offset), rows.count)
        let guidance = try InstalledSkillInventory.entries(dataRoot: root).map(\.id).sorted()
        var parts: [JSONValue] = []
        var bytes = try JSONValue.array(guidance.map(JSONValue.string)).serializedData(pretty: false).count
        for row in rows.dropFirst(start).prefix(40) {
            let id = Self.string(row, "id") ?? ""
            var item = row.filter { ["id", "kind", "version", "name", "description", "status"].contains($0.key) }
            item["runs"] = row["useCount"] ?? .int(0)
            let last = row["lastUsedAt"]
            if case .double(let stamp)? = last {
                item["last_run_at"] = .string(NativeTimestampFormat.plainZulu(Date(timeIntervalSinceReferenceDate: stamp)))
            } else { item["last_run_at"] = last ?? .null }
            // Her own curve: the model rounds each recent use of it took.
            if case .array(let rounds)? = row["learned"]?.objectValue?["use"]?.objectValue?["rounds_per_use"], !rounds.isEmpty {
                item["rounds_per_use"] = .array(rounds)
            }
            item["next_call"] = .object(Self.runs(row)
                ? ["action": .string("authored." + id), "args": .object([:])]
                : ["action": .string("ability.read"), "args": .object(["id": .string(id)])])
            let value = JSONValue.object(item)
            let size = try value.serializedData(pretty: false).count
            if !parts.isEmpty, bytes + size > 24_000 { break }
            parts.append(value); bytes += size
        }
        let end = start + parts.count
        return .object(["status": .string("ok"), "abilities": .array(parts), "built_in_guidance": .array(guidance.map(JSONValue.string)),
            "count": .int(Int64(parts.count)), "total": .int(Int64(rows.count)), "offset": .int(Int64(start)),
            "has_more": .bool(end < rows.count), "next_offset": end < rows.count ? .int(Int64(end)) : .null,
            "next_call": end < rows.count ? .object(["action": .string("ability.list"), "args": .object(["offset": .int(Int64(end))])]) : .null])
    }
}
