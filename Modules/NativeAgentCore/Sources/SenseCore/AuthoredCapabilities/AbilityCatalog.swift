import CryptoKit
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AbilityCatalog.swift` | Checked inventory and redacted identity-matched accounting projections |
extension AbilityStore {
    typealias Catalog = (files: [File], retained: [Slot: [String: File]], states: [String: JSONValue])
    typealias RecordProjection = (file: File, fields: [String: JSONValue], paths: [URL])
    typealias Registry = (rows: [RecordProjection], paths: [URL])
    package struct CatalogSnapshot: Sendable {
        let files: Stamped<[EntryStamp], FileSnapshot>
        var source: FileSnapshot { files.value }
        package var guidanceExclusions: Set<String> { source.guidanceExclusions }
        let accounting: Accounting
        var catalog: Catalog { (source.selected, source.retained, accounting.rows) }
    }
    package func withCatalog<Value>(_ body: (CatalogSnapshot) throws -> Value) throws -> Value {
        while true {
            try Task.checkCancellation()
            let files = try fileSnapshot()
            let value = Result { try body(CatalogSnapshot(files: files, accounting: accountingSnapshot().value)) }
            if try folderRevision() == files.revision { return try value.get() }
        }
    }
    /// Presentation adapters share one checked inventory and accounting read.
    public func catalog() throws -> (files: [File], retained: [Slot: [String: File]], states: [String: JSONValue]) {
        try withCatalog { $0.catalog }
    }
    /// Domain records are projections of these files, never another persisted catalog.
    public func registry(kind: Kind? = nil) throws -> JSONValue {
        try withCatalog { try registry($0, kind: kind) }
    }
    package func selectedPart(_ id: String) throws -> (row: [String: JSONValue], file: File?, revision: [String])? {
        try withCatalog { try selectedPart(id, in: $0) }
    }
    private func selectedPart(_ id: String, in snapshot: CatalogSnapshot) throws -> (row: [String: JSONValue], file: File?, revision: [String])? {
        if let damage = snapshot.source.inventory.damaged.first(where: { $0.id == id && $0.slot == .current }) { throw damage.failure }
        guard let projection = snapshot.source.partRows[id] else { return nil }
        let current = try snapshot.source.file(id: id, slot: .current, in: self)
        guard let file = current ?? snapshot.source.retained[.next]?[id] else { return nil }
        let part = try projection.read { try projectedRecord(file, source: snapshot.source, kind: .part) }
        try checkPaths(part.paths)
        var row = try overlay(snapshot.accounting.redactedRows()[id], on: part.fields, file: file,
            previous: snapshot.source.retained[.previous]?[id])
        guard row["id"] == .string(id) else { return nil }
        if let name = row["name"], name.stringValue == nil {
            row["name"] = .string("\(id) (name unavailable)")
            row["status"] = .string("unavailable")
            row["unavailableReason"] = .string("Part \(id) has an invalid name field; expected a string. Repair name in its retained header.")
        }
        let revision = try snapshot.files.revision.map { try $0.key() }
        return (row, current, revision)
    }
    private func registry(_ snapshot: CatalogSnapshot, kind: Kind?) throws -> JSONValue {
        guard let registry = snapshot.source.registries[kind] else { throw Self.failure("Missing ability registry projection.") }
        let result = try registry.read {
            let selected = snapshot.source.selected.filter { kind == nil || ($0.kind == kind && Self.isPublished($0)) }
            let records = try selected.map { file in
                if kind == .part, let part = snapshot.source.partRows[file.id] {
                    return try part.read { try projectedRecord(file, source: snapshot.source, kind: kind) }
                }
                return try projectedRecord(file, source: snapshot.source, kind: kind)
            }
            return (records, records.flatMap(\.paths))
        }
        try checkPaths(result.paths)
        let stats = try snapshot.accounting.redactedRows()
        return .array(try result.rows.map { record in
            .object(try overlay(stats[record.file.id], on: record.fields, file: record.file,
                previous: snapshot.source.retained[.previous]?[record.file.id]))
        })
    }
    private func projectedRecord(_ file: File, source: FileSnapshot, kind: Kind?) throws -> RecordProjection {
        var paths: [URL] = []
        var row = baseRecord(file)
        var versions: [JSONValue] = []
        if let previous = source.retained[.previous]?[file.id], let digest = identity(previous) {
            row["previousVersion"] = .string(digest); versions.append(.string(digest))
        }
        if let digest = identity(file) { versions.append(.string(digest)) }
        row["versions"] = .array(versions)
        if file.kind != .part { return (file, row, paths) }
        if file.pathExtension == "md" { row["callable"] = .bool(false) }
        else if let entry = file.metadata["candidate"]?.objectValue?["program"]?.objectValue?["entry"]?.stringValue,
              let selectedEntry = OwnedProgram.Entry(rawValue: entry) {
            row["callable"] = .bool(selectedEntry.callable)
        } else {
            row["status"] = .string("unavailable")
            row["unavailableReason"] = .string("Part \(file.id) has no sealed entry.")
            return (file, row, paths)
        }
        row.removeValue(forKey: "keepReview")
        var reviewFile = file
        if let next = source.retained[.next]?[file.id], let digest = identity(next) {
            reviewFile = next
            row.merge((next.metadata["record"]?.objectValue ?? [:]).filter { Self.pending.contains($0.key) || $0.key == "updatedAt" }) { _, new in new }
            row["candidateDigest"] = .string(digest)
            row["candidate_validation_evidence"] = Self.validationEvidence(next.metadata["proof"], fixtures: next
                .metadata["candidate"]?.objectValue?["fixtures"])
            if let status = Self.validationStatus(next.metadata["proof"]) { row["candidateValidation"] = .string(status) }
        } else {
            for key in Self.pending { row.removeValue(forKey: key) }
            if let status = Self.validationStatus(file.metadata["proof"]) { row["candidateValidation"] = .string(status) }
        }
        if kind == .part {
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
            if source.retained[.current]?[file.id] != nil {
                let url = root.appendingPathComponent(try Self.fileName(id: file.id, slot: .current, pathExtension: file.pathExtension))
                paths.append(url)
                row["activePath"] = .string(url.path)
            }
            if let next = source.retained[.next]?[file.id] {
                let url = root.appendingPathComponent(try Self.fileName(id: file.id, slot: .next, pathExtension: next.pathExtension))
                paths.append(url)
                row["proposalPath"] = .string(url.path)
            }
        }
        return (file, row, paths)
    }
    static func isPublished(_ file: File) -> Bool {
        file.kind == .turn || file.metadata["record"]?.objectValue != nil
    }

    public func saveRegistry(_ value: JSONValue, kind: Kind, ownerAuthorized: Bool = false, enabling: Bool = false, turn: Turn?) throws {
        try Self.withLock {
            let (catalog, before) = try withCatalog { ($0.catalog, try registry($0, kind: kind)) }
            let checked = try CapabilityLifecycle.preservingOwnerOff(value, before: before, ownerAuthorized: ownerAuthorized,
                enabling: enabling, senseRecords: kind == .sense, turn: turn)
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
            for file in catalog.files where file.kind == kind && Self.isPublished(file) && !ids.contains(file.id) {
                try remove(id: file.id, ownerAuthorized: ownerAuthorized, turn: turn)
                stats.removeValue(forKey: file.id)
            }
            for (input, id, current, next, promote) in publications {
                // Lifecycle projections may be redacted. Canonical run/trial evidence never comes back from that presentation.
                // SenseRecord owns only these four accounting fields; all other accounting stays with catalog.states.
                if kind == .sense {
                    var accounting = stats[id]?.objectValue ?? [:]
                    for key in ["uses", "corrections", "lastUsedAt", "unavailableReason"] { accounting[key] = input[key] }
                    if stats[id] != nil || !accounting.isEmpty { stats[id] = .object(accounting) }
                }
                if input["bundledDefault"] == .bool(true) { continue }
                var slot: Slot = .current
                var file: File
                if let promote {
                    if let current { try writeFile(current, slot: .previous) }
                    file = promote
                } else if let current { file = current }
                else if let next { file = next; slot = .next }
                else {
                    file = try File(id: id, kind: kind, metadata: ["record": .object(input)], body: input["body"]?.stringValue ?? "",
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
                    if proposal != next { try write(proposal, slot: .next, turn: turn) }
                    if changed, let selected = current.metadata["record"]?.objectValue { row = selected }
                    else if row["updatedAt"] == priorProposal["updatedAt"] { row["updatedAt"] = current.metadata["record"]?.objectValue?["updatedAt"] }
                    for key in Self.pending { row.removeValue(forKey: key) }
                }
                if kind != .sense, slot == .current { for key in Self.pending { row.removeValue(forKey: key) } }
                file.metadata["record"] = .object(row)
                if (slot == .current ? current : next) != file { try write(file, slot: slot, turn: turn) }
                if promote != nil { try remove(id: id, slot: .next, turn: turn) }
            }
            try writeState(stats)
        }
    }
    /// Proof-derived status is projected on read; it is not authored record identity.
    static func storedRecord(_ input: [String: JSONValue], kind: Kind) -> [String: JSONValue] {
        input.filter { !statistics.contains($0.key) && !projections.contains($0.key)
            && !partKeys.contains($0.key)
            && !["kind", "permissions", "bundledDefault", "body", "run_counts", "callable", "validationStatus"].contains($0.key)
            && (kind == .sense || $0.key != "version") }
    }
    /// Retained and bundled senses share SenseRecord's numeric Codable date projection.
    public static func senseRecord(_ input: [String: JSONValue]) throws -> [String: JSONValue] {
        var row = input
        if case .string(let at)? = row["lastUsedAt"] {
            row["lastUsedAt"] = .double(try Date(at, strategy: .iso8601).timeIntervalSinceReferenceDate)
        }
        return row
    }
    /// A sense's record: its current version only, so a sense read never depends on its retained previous file.
    public func record(_ file: File, statistics: JSONValue?) throws -> [String: JSONValue] {
        try overlay(statistics.map { Self.publishedStatistics(Self.redactedEvidence($0)) }, on: baseRecord(file), file: file, previous: nil)
    }
    private func baseRecord(_ file: File) -> [String: JSONValue] {
        var row = file.record
        row["validation_evidence"] = Self.validationEvidence(file.metadata["proof"], fixtures: file.metadata["candidate"]?.objectValue?["fixtures"])
        if let status = Self.validationStatus(file.metadata["proof"]) { row["validationStatus"] = .string(status) }
        return row
    }
    static func publishedStatistics(_ value: JSONValue) -> JSONValue {
        var statistics = (value.objectValue ?? [:]).filter { Self.statistics.contains($0.key) }
        // A run accounted before receipts kept only metadata still holds its calls' raw results; they leave as metadata.
        if case .object(var last)? = statistics["lastRun"], case .array(let calls)? = last["calls"] {
            last["calls"] = .array(calls.map(CallLedger.published))
            statistics["lastRun"] = .object(last)
        }
        return .object(statistics)
    }
    private func overlay(_ statistics: JSONValue?, on fields: [String: JSONValue], file: File, previous: File?) throws -> [String: JSONValue] {
        var row = fields
        if let statistics = statistics?.objectValue {
            row.merge(statistics) { _, new in new }
            if file.kind == .part, fields["status"] == .string("unavailable"), let reason = fields["unavailableReason"] {
                row["unavailableReason"] = reason
            }
        }
        let evidence = row["runs"]?.objectValue?["versions"]?.objectValue ?? [:]
        let use = evidence[versionKey(file)]?.objectValue ?? [:]
        let currentRuns = use["count"] ?? .int(0)
        var runTotals = use.filter { ["count", "ok", "error", "refused", "cut", "network"].contains($0.key) }
        runTotals["count"] = currentRuns
        // Lifetime accounting survives retired versions; selected-version evidence belongs only to this exact file identity.
        row["run_counts"] = .object(["all_versions": row["useCount"] ?? .int(0), "current_version": currentRuns])
        // Each retained version with a run record, current first; failed is its error and cut runs beside the surprise the stem attributed.
        var versions: [JSONValue] = []
        for (retained, slot) in [(file, "current")] + (previous.map { [($0, "previous")] } ?? []) {
            let key = versionKey(retained)
            guard let ran = evidence[key]?.objectValue, !versions.contains(where: { $0.objectValue?["version"] == .string(key) }) else { continue }
            let failed = try Self.outcomeCount(ran, at: "learned.versions.\(key)", names: ["error", "cut"])
            versions.append(.object(["version": .string(key), "slot": .string(slot), "uses": ran["count"] ?? .int(0), "ok": ran["ok"] ?? .int(0),
                "surprise": .object((ran["surprise"]?.objectValue ?? [:]).merging(["failed": .int(failed)]) { _, new in new }),
                "rounds": ran["rounds"] ?? .object([:])]))
        }
        row["learned"] = .object(["declared": file.metadata["learned"] ?? .null,
            "use": .object(["version": .string(identity(file) ?? file.bodyDigest), "scope": .string("current_version"),
                "basis": .string("gated_execution"),
                "scope_limit": .int(Int64(CapabilityLifecycle.inputLimit)),
                "run_totals": .object(runTotals),
                "operations": use["operations"] ?? .object([:]),
                "rounds_per_use": use["rounds"] ?? .object([:])]),
            "versions": .array(versions), "trial": row["trial"] ?? .null, "trials": row["trials"] ?? .array([])])
        if file.kind == .sense {
            row["uses"] = row["uses"] ?? .int(0); row["corrections"] = row["corrections"] ?? .int(0)
            if row["status"] == .string("on"), row["unavailableReason"] != nil { row["status"] = .string("unavailable") }
            row = try Self.senseRecord(row)
        }
        return row
    }
    /// Reapply today's content policy to retained evidence without rewriting its accounting or truncating the reached-call labels.
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
