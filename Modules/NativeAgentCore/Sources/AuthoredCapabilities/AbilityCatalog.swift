import CryptoKit
import Experiences
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AbilityCatalog.swift` | Checked inventory and redacted catalog projections |
extension AbilityStore {
    /// Presentation adapters share one checked inventory and accounting read.
    public func catalog() throws -> (files: [File], retained: [Slot: [String: File]], states: [String: JSONValue]) {
        try Self.withLock {
            let inventory = try retainedFiles()
            let retained = Dictionary(grouping: inventory, by: \.slot).mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0.file.id, $0.file) }) }
            return (selectedFiles(inventory, kind: nil), retained, try readState())
        }
    }
    /// Domain records are projections of these files, never another persisted catalog.
    public func registry(kind: Kind? = nil) throws -> JSONValue {
        try Self.withLock { try registry(catalog(), kind: kind) }
    }
    private func registry(_ catalog: (files: [File], retained: [Slot: [String: File]], states: [String: JSONValue]), kind: Kind?) throws -> JSONValue {
        let bytes = try JSONValue.object(catalog.states).serializedData(pretty: false)
        let stats: [String: JSONValue]
        if let cached = Self.redactedAccounting, cached.bytes == bytes { stats = cached.rows }
        else {
            guard case .object(let redacted) = Self.redactedEvidence(.object(catalog.states)) else {
                throw Self.failure("Redacted ability accounting must remain an object.")
            }
            stats = redacted
            Self.redactedAccounting = (bytes, stats)
        }
        // Typed registries retain their published-record selection; the
        // all-kind read also exposes unkept files, never as active records.
        let selected = catalog.files.filter { (kind == nil || $0.kind == kind) && (kind == nil || $0.kind == .turn || $0.metadata["record"]?.objectValue != nil) }
        return .array(try selected.map { file in
            var row = try record(file, redactedStatistics: stats[file.id])
            var versions: [JSONValue] = []
            if let previous = catalog.retained[.previous]?[file.id], let digest = identity(previous) {
                row["previousVersion"] = .string(digest); versions.append(.string(digest))
            }
            if let digest = identity(file) { versions.append(.string(digest)) }
            row["versions"] = .array(versions)
            if file.kind != .part { return .object(row) }
            row.removeValue(forKey: "candidateReview")
            row.removeValue(forKey: "keepReview")
            var reviewFile = file
            if let next = catalog.retained[.next]?[file.id], let digest = identity(next) {
                reviewFile = next
                row.merge((next.metadata["record"]?.objectValue ?? [:]).filter { Self.pending.contains($0.key) || $0.key == "updatedAt" }) { _, new in new }
                row["candidateDigest"] = .string(digest)
                row["candidate_validation_evidence"] = Self.validationEvidence(next.metadata["proof"], fixtures: next.metadata["candidate"]?.objectValue?["fixtures"])
                if let status = Self.validationStatus(next.metadata["proof"]) { row["candidateValidation"] = .string(status) }
            } else {
                for key in Self.pending { row.removeValue(forKey: key) }
                if let status = Self.validationStatus(file.metadata["proof"]) { row["candidateValidation"] = .string(status) }
            }
            if kind == .part {
                // Capture the code and its digest in this locked catalog read,
                // for both a waiting candidate and a selected version turned off.
                if reviewFile.pathExtension == "js", let digest = identity(reviewFile),
                   let candidate = reviewFile.metadata["candidate"]?.objectValue,
                   let manifest = candidate["manifest"]?.objectValue {
                    row["keepReview"] = .object(["version": .string(digest),
                        "description": manifest["description"] ?? .null,
                        "reach": reviewFile.part["reach"] ?? .null, "code": .string(reviewFile.body),
                        "manifest": .object(manifest), "program": candidate["program"] ?? .null,
                        "fixtures": candidate["fixtures"] ?? .array([]),
                        "dependencyShapes": candidate["dependencyShapes"] ?? .null,
                        "prior": candidate["prior"] ?? .null])
                }
                if catalog.retained[.current]?[file.id] != nil {
                    row["activePath"] = .string(try path(id: file.id, pathExtension: file.pathExtension).path)
                }
                if let next = catalog.retained[.next]?[file.id] {
                    row["proposalPath"] = .string(try path(id: file.id, slot: .next, pathExtension: next.pathExtension).path)
                }
            }
            return .object(row)
        })
    }
    public func saveRegistry(_ value: JSONValue, kind: Kind, ownerAuthorized: Bool = false, enabling: Bool = false) throws {
        try Self.withLock {
            let catalog = try catalog()
            let checked = try CapabilityLifecycle.preservingOwnerOff(value, before: registry(catalog, kind: kind), ownerAuthorized: ownerAuthorized, enabling: enabling, senseRecords: kind == .sense)
            guard let values = checked.arrayValue, values.allSatisfy({ $0.objectValue != nil }) else { throw Self.failure("Invalid ability records.") }
            let publications = try values.compactMap(\.objectValue).map { input in
                guard let id = input["id"]?.stringValue else { throw Self.failure("An ability record has no id.") }
                _ = try path(id: id)
                let current = catalog.retained[.current]?[id], next = catalog.retained[.next]?[id]
                let target = kind == .sense ? input["candidateDigest"]?.stringValue : input["codeFingerprint"]?.stringValue
                return (input: input, id: id, current: current, next: next, promote: target != nil && target == next.flatMap(identity) ? next : nil)
            }
            // Admit the complete publication before displacing any selected version.
            if enabling || publications.contains(where: { $0.promote != nil }) {
                try CapabilityLifecycle.requireKeep(ownerAuthorized: ownerAuthorized || CapabilityLifecycle.keepAuthority(dataRoot))
            }
            var stats = catalog.states
            let ids = Set(publications.map(\.id))
            for file in catalog.files where file.kind == kind && !ids.contains(file.id) { try remove(id: file.id, ownerAuthorized: ownerAuthorized); stats.removeValue(forKey: file.id) }
            for (input, id, current, next, promote) in publications {
                // SenseRecord owns these four fields, not the stem's run evidence.
                let accounting = kind == .sense ? (stats[id]?.objectValue ?? [:]).filter {
                    !["uses", "corrections", "lastUsedAt", "unavailableReason"].contains($0.key)
                } : [:]
                stats[id] = .object(accounting.merging(input.filter { Self.statistics.contains($0.key) }) { _, new in new })
                if input["bundledDefault"] == .bool(true) { continue }
                var slot: Slot = .current
                var file: File
                if let promote {
                    if let current { try writeFile(current, slot: .previous) }
                    file = promote
                } else if let current { file = current }
                else if let next { file = next; slot = .next }
                else {
                    let script = input["script"]?.objectValue
                    file = try File(id: id, kind: kind, metadata: ["record": .object(input)], body: script?["source"]?.stringValue ?? input["body"]?.stringValue ?? "",
                                pathExtension: "js")
                }
                var row = Self.storedRecord(input, kind: kind)
                if kind == .sense, row["status"] == .string("unavailable"),
                   let saved = current?.metadata["record"]?.objectValue, saved["status"] == .string("on") {
                    row["status"] = .string("on"); row["disabledBy"] = saved["disabledBy"]
                }
                if kind != .sense, promote == nil, let current, var proposal = next {
                    let priorProposal = proposal.metadata["record"]?.objectValue ?? [:]
                    let changed = row.filter { Self.pending.contains($0.key) } != priorProposal.filter { Self.pending.contains($0.key) }
                    proposal.metadata["record"] = .object(row)
                    if proposal != next { try write(proposal, slot: .next) }
                    if changed, let selected = current.metadata["record"]?.objectValue { row = selected }
                    else if row["updatedAt"] == priorProposal["updatedAt"] { row["updatedAt"] = current.metadata["record"]?.objectValue?["updatedAt"] }
                    for key in Self.pending { row.removeValue(forKey: key) }
                }
                if kind != .sense, slot == .current { for key in Self.pending { row.removeValue(forKey: key) } }
                file.metadata["record"] = .object(row)
                if (slot == .current ? current : next) != file { try write(file, slot: slot) }
                if promote != nil { try remove(id: id, slot: .next) }
                if let keeping = Self.keeping, try Slot.allCases.map({ try readFile(id: id, slot: $0) }) != Slot.allCases.map({ catalog.retained[$0]?[id] }) {
                    var fields = stats[id]?.objectValue ?? [:]
                    fields["keptAfter"] = .object(["turn": .string(keeping.turn), "at": .string(NativeTimestampFormat.plainZulu(keeping.at))])
                    stats[id] = .object(fields)
                }
            }
            try writeState(stats)
        }
    }
    static func storedRecord(_ input: [String: JSONValue], kind: Kind) -> [String: JSONValue] {
        var row = input.filter { !statistics.contains($0.key) && !obsolete.contains($0.key)
            && !partKeys.contains($0.key) && !["kind", "permissions", "bundledDefault", "body"].contains($0.key)
            && (kind == .sense || $0.key != "version") }
        if var script = row["script"]?.objectValue { script.removeValue(forKey: "source"); row["script"] = .object(script) }
        return row
    }
    /// Retained and bundled senses share the record's numeric Codable date projection.
    public static func senseRecord(_ input: [String: JSONValue]) throws -> [String: JSONValue] {
        var row = input
        if case .string(let at)? = row["lastUsedAt"] {
            row["lastUsedAt"] = .double(try Date(at, strategy: .iso8601).timeIntervalSinceReferenceDate)
        }
        return row
    }
    public func record(_ file: File, statistics: JSONValue?) throws -> [String: JSONValue] {
        try record(file, redactedStatistics: Self.redactedEvidence(statistics ?? .null))
    }
    func record(_ file: File, redactedStatistics: JSONValue?) throws -> [String: JSONValue] {
        var row = file.record
        row.merge(redactedStatistics?.objectValue ?? [:]) { _, new in new }
        row["validation_evidence"] = Self.validationEvidence(file.metadata["proof"], fixtures: file.metadata["candidate"]?.objectValue?["fixtures"])
        if let status = Self.validationStatus(file.metadata["proof"]) { row["validationStatus"] = .string(status) }
        let version = (identity(file) ?? file.bodyDigest) + "@" + String(file.metadata["version"]?.integer ?? 1)
        let use = row["runs"]?.objectValue?["versions"]?.objectValue?[version]?.objectValue ?? [:]
        row["learned"] = .object(["declared": file.metadata["learned"] ?? .null,
            "use": .object(["version": .string(identity(file) ?? file.bodyDigest), "basis": .string("gated_execution"),
                "scope_limit": .int(Int64(CapabilityLifecycle.inputLimit)),
                "run_totals": .object(use.filter { ["count", "ok", "error", "refused", "cut", "network"].contains($0.key) }),
                "operations": use["operations"] ?? .object([:]),
                "rounds_per_use": row["runs"]?.objectValue?["rounds"] ?? .array([])])])
        if file.kind == .sense {
            row["uses"] = row["uses"] ?? .int(0); row["corrections"] = row["corrections"] ?? .int(0)
            if row["status"] == .string("on"), row["unavailableReason"] != nil { row["status"] = .string("unavailable") }
            row = try Self.senseRecord(row)
        }
        if var script = row["script"]?.objectValue { script["source"] = .string(file.body); row["script"] = .object(script) }
        return row
    }
    /// Reapply today's content policy to retained evidence without rewriting
    /// its accounting or truncating the reached-call labels.
    static func redactedEvidence(_ value: JSONValue) -> JSONValue {
        var strings: [Data: String] = [:]
        return value.mapStrings { text in
            let bytes = Data(text.utf8)
            if let cached = strings[bytes] { return cached }
            let redacted = ContextSecretContentPolicy.redactedFragment(text)
            strings[bytes] = redacted
            return redacted
        }
    }
    static func inputDescription(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields): return .object(Dictionary(uniqueKeysWithValues: fields.map { key, value in
            (key, TurnSecretRedactor.isCredentialName(key) ? .string("[redacted]") : inputDescription(value))
        }))
        case .array(let values): return .array(values.prefix(CapabilityLifecycle.inputLimit).map(inputDescription))
        case .string(let text): return .string(String(ContextSecretContentPolicy.redactedFragment(text).prefix(128)))
        default: return value
        }
    }
    private static func validationStatus(_ value: JSONValue?) -> String? {
        guard let proof = value?.objectValue else { return nil }
        if proof["domain"] == .string("owned-program-seed") { return "bundled" }
        if proof["domain"] == .string("owned-program-kept") { return "kept" }
        // Recorded practice replayed exactly from its tape: verified, still no live competence.
        if proof["domain"] == .string("owned-program-validation"), proof["receipts"]?.arrayValue?.isEmpty == false {
            return proof["tape"] != nil ? "replayed" : "rehearsed"
        }
        return "unvalidated"
    }
    public static func validationEvidence(_ value: JSONValue?, fixtures: JSONValue?) -> JSONValue {
        let proof = value?.objectValue ?? [:]
        let fixtures = (proof["capturedFixtures"] ?? fixtures)?.arrayValue ?? []
        let status = validationStatus(value)
        let kind: String = status == "rehearsed" ? "rehearsal" : status == "replayed" ? "tape_replay" : status ?? "unvalidated"
        let tape: JSONValue = proof["tape"] ?? .null
        return .object(["kind": .string(kind),
            "behavioral": .bool(false), "candidate": proof["candidate"] ?? .null, "tape": tape,
            // Inputs leave the store only as their redacted description, like learned previews.
            "inputs": .array(proof.isEmpty ? [] : fixtures.compactMap { $0.objectValue?["input"] }.map(inputDescription)),
            "runs": .array((proof["receipts"]?.arrayValue ?? []).map { receipt in
                let fields = receipt.objectValue ?? [:]
                return .object(["input": inputDescription(fields["input"] ?? (fixtures.count == 1 ? fixtures[0].objectValue?["input"] ?? .null : .null)),
                    "status": fields["status"] ?? .null,
                    "calls": .array((fields["calls"]?.arrayValue ?? []).map {
                        // A call's label can carry its input ("find " + query): redacted like the inputs.
                        .object(($0.objectValue ?? [:]).filter { ["call", "line", "status"].contains($0.key) }
                            .mapValues { if case .string(let text) = $0 { .string(ContextSecretContentPolicy.redactedFragment(text)) } else { $0 } }) })])
            })])
    }
}
