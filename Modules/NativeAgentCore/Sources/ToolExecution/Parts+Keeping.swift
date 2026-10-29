import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import ToolRegistry
import TrustCenter
import CryptoKit
import NativeAgentShared
import PersonaEngine
import Privacy
// Blueprint: | `Parts+Keeping.swift` | Parts keep eligibility and lifecycle mutations; one prepareKeep decision, sealed admission, owner-off authority, enable/disable/drop/rollback and locked registry mutation |

extension Parts {
    /// One part's record, changed under the store's lock.
    func mutate(_ id: String, ownerAuthorized: Bool = false, enabling: Bool = false,
                _ change: ([String: JSONValue]?) throws -> [String: JSONValue]) throws {
        try AbilityStore.withLock {
            var rows = try self.rows()
            let index = rows.firstIndex { $0["id"] == .string(id) }
            let row = try change(index.map { rows[$0] })
            if let index { rows[index] = row } else { rows.append(row) }
            try abilities.saveRegistry(.array(rows.map(JSONValue.object)), kind: .part, ownerAuthorized: ownerAuthorized, enabling: enabling)
        }
    }

    /// Who keeps a version: nil when it is hers to keep now, else why it is the owner's. Her own work is hers under Full Mac; a version
    /// from untrusted agents or a pack, and anything below Full Mac, are the owner's. A turn an untrusted agent started asks its one
    /// command card at the gate, and the store refuses its writes until that is answered.
    public static func keepRefusal(origin: JSONValue?, name: String, fullMac: Bool) -> String? {
        let fields = fields(origin ?? .null)
        switch originKind(origin) {
        case "peer"?: return "\(name) came from untrusted agents \(strings(fields["peers"]).joined(separator: ", ")), so keeping it is the owner's card for this exact version"
        case "pack"?: return "\(name) came with the \(string(fields, "pack") ?? "") pack, so keeping it is the owner's"
        case nil: return "\(name) has no attested origin, so keeping it is the owner's"
        default: break
        }
        return fullMac ? nil : "Below Full Mac, keeping an ability is the owner's"
    }

    /// Admits one version: signs its sealed proof (rehearsed, kept or a seed's) and selects it, on. `by` is who kept it, user or agent.
    func admit(id: String, digest: String, by: String, ownerAuthorized: Bool = false) async throws {
        let candidate = try store.load(id: id, digest: digest)
        try checkDependencies(candidate)
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let key = try await signer.loadOrCreateSigningKey()
        let proof = try store.proof(candidate, key: key)
        let admission = try await signer.sign(["id": .string(id), "candidate": .string(digest), "proof": proof, "by": .string(by)])
        let path = try abilities.path(id: id).path, stamp = Self.now()
        try await store.keep(candidate, key: key, ownerAuthorized: ownerAuthorized) { value in
            guard case .array(var rows) = value, let index = rows.firstIndex(where: { Self.fields($0)["id"] == .string(id) }),
                  case .object(var row) = rows[index],
                  row["candidateDigest"] == .string(digest) || row["candidateDigest"] == nil && row["codeFingerprint"] == .string(digest) else {
                throw PartError.invalid("\(id)'s waiting version is no longer \(digest.prefix(12)); read it and keep the one it shows.")
            }
            // Its record is what this version declares; a skill's older version declared its params inside its script. The origin only
            // ratchets. Its id stays the owner's: a migrated version declares the id it was sealed under.
            var declared = Self.fields(candidate.manifest).filter { $0.value != .null }
            declared["id"] = .string(candidate.id)
            if case .object(let script)? = declared.removeValue(forKey: "script"), declared["params"] == nil { declared["params"] = script["params"] }
            let origin = Self.merged([declared["origin"]] + Self.recorded(row))
            // Its params are this version's: one it declares none for takes none.
            row.removeValue(forKey: "params")
            row.merge(declared) { $1 }
            row["origin"] = origin; row["language"] = .string("javascript"); row["inputSchema"] = candidate.program.schema
            row["actions"] = .array(candidate.program.dependencies.map(JSONValue.string))
            // Turned back on by hand: a retired seed's fade leaves it on.
            if row["status"] == .string("disabled") { row["enabledAt"] = .string(stamp) }
            row["status"] = .string("active"); row["codeFingerprint"] = .string(digest); row["activePath"] = .string(path)
            row["admission"] = .object(admission)
            for key in ["disabledBy", "disabledReason", "phase"] { row.removeValue(forKey: key) }
            row["promotedAt"] = .string(stamp); row["updatedAt"] = .string(stamp)
            rows[index] = .object(row); value = .array(rows)
        }
    }

    private enum KeepPlan {
        case stopped(Outcome)
        case guidance(String, String, [String: JSONValue])
        case code(String, String, String, OwnedProgramStore.Candidate, Bool, [String: JSONValue])

        func preview(ownerAuthorized: Bool) -> Outcome {
            switch self {
            case .stopped(let outcome): return outcome
            case .guidance(_, let name, let fields):
                return (true, "Would turn \(name) back on.", fields.merging(["would_status": .string("active")]) { $1 })
            case .code(_, let name, _, _, let proved, let fields):
                return (true, "Would keep \(name) and turn it on" + (proved ? "." : ", sealed as kept: its first real run is its proof."),
                        fields.merging(["would_status": .string("active"), "would_admit": .string(ownerAuthorized ? "owners" : "hers")]) { $1 })
            }
        }
    }

    /// One read-only keep decision, including the exact candidate's sealed proof.
    private func prepareKeep(_ named: String, row: [String: JSONValue]?, version: String?, fullMac: Bool, ownerAuthorized: Bool) throws -> KeepPlan {
        guard let row, let id = Self.string(row, "id") else { return .stopped(try unknown(named)) }
        let name = Self.string(row, "name") ?? id, status = Self.string(row, "status") ?? ""
        var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "state_before": .string(status)]
        guard let digest = Self.string(row, "candidateDigest") ?? Self.string(row, "codeFingerprint") else {
            // Guidance (a Markdown ability) has no code: back on is its status alone, by the same authority (the store keeps the owner's
            // off his).
            guard version == nil, status == "disabled", try abilities.read(id: id)?.pathExtension == "md" else {
                let failure = Self.revisionFailure("no_ability_code", "\(id) has no code to keep. Save synchronous JavaScript defining run(input) with ability.save.", id: id)
                return .stopped((false, failure.message, fields.merging(["reason": .string(failure.code), "effects": .string("none"), "remedy": failure.remedy ?? .null]) { $1 }))
            }
            if !ownerAuthorized, let why = CapabilityLifecycle.requiresOwnerToEnable(row) ? "The owner switched \(name) off, so turning it back on is theirs"
                : Self.keepRefusal(origin: Self.merged([row["origin"]]), name: name, fullMac: fullMac) {
                return .stopped((false, why + ". Nothing changed.", fields.merging(["reason": .string("owners_call")]) { $1 }))
            }
            return .guidance(id, name, fields)
        }
        if version != digest {
            return .stopped((false, "version must be \(name)'s waiting version (ability.read shows it). Nothing changed.",
                    fields.merging(["reason": .string("bad_input"), "next_call": .object(["action": .string("ability.read"),
                        "args": .object(["id": .string(id)])])]) { $1 }))
        }
        if status == "active", row["candidateDigest"] == nil {
            return .stopped((true, "\(name) is already on.", fields.merging(["changed": .bool(false)]) { $1 }))
        }
        // The guard reads the off's actor (an unreadable one is refused and named); the owner's off is his to lift, hers to ask, on his
        // card.
        let ownersOff = !ownerAuthorized && CapabilityLifecycle.requiresOwnerToEnable(row)
        do { _ = try CapabilityLifecycle.preservingOwnerOff(row, before: row, ownerAuthorized: ownerAuthorized || ownersOff, enabling: true, preview: true) }
        catch let error as ToolFailureError {
            return .stopped((false, error.localizedDescription, fields.merging(["reason": .string("owners_call"), "remedy": error.remedy()]) { $1 }))
        }
        let candidate = try store.load(id: id, digest: digest)
        if let why = OwnedProgram.asyncRefusal(candidate.program.source) {
            return .stopped((false, why + " ability.save it so, then enable it. Nothing changed.", fields))
        }
        let key: Data?
        do { key = try SwiftNativeManifestSigner(dataRoot: root).existingSigningKey() }
        catch { throw ManifestSigningError.keyUnavailable(error.localizedDescription) }
        let proof = key.flatMap { try? store.proof(candidate, key: $0) }
        let proved = proof != nil
        let origin = Self.merged([Self.fields(candidate.manifest)["origin"]] + Self.recorded(row))
        fields["candidate_digest"] = .string(digest)
        // Compiled from recorded practice: kept by anyone only once its tape replayed.
        if Self.fields(candidate.manifest)["compiled"] != nil, proof.map({ Self.fields($0)["tape"] == nil }) ?? true {
            return .stopped((false, "\(name) was compiled from recorded practice, so it is kept only once ability.validate has replayed its examples from the tape. Nothing changed.",
                    fields.merging(["reason": .string("not_replayed"), "effects": .string("none"),
                                    "next_call": .object(["action": .string("ability.validate"), "args": .object(["id": .string(id)])])]) { $1 }))
        }
        if !ownerAuthorized, let why = ownersOff ? "The owner switched \(name) off, so turning it back on is theirs"
            : Self.keepRefusal(origin: origin, name: name, fullMac: fullMac) {
            guard proved else {
                return .stopped((false, "Rehearse \(name)'s waiting version with ability.validate before it goes to the owner. Nothing changed.",
                        fields.merging(["next_call": .object(["action": .string("ability.validate"), "args": .object(["id": .string(id)])])]) { $1 }))
            }
            // The complete version is for the owner's card; the door strips it.
            return .stopped((false, why + ": they read it and keep it. Nothing changed.",
                    fields.merging(["needs_owner": .bool(true), "reason": .string("owners_call"),
                                    "review": .object(["version": .string(digest), "code": .string(candidate.program.source),
                                        "manifest": candidate.manifest, "fixtures": candidate.fixtures,
                                        "dependencyShapes": candidate.dependencyShapes, "prior": candidate.prior]),
                                    "would_status": .string("active"), "would_admit": .string("owners_card")]) { $1 }))
        }
        guard proved || !ownerAuthorized else {
            return .stopped((false, "Rehearse \(name)'s waiting version before keeping it.", fields))
        }
        return .code(id, name, digest, candidate, proved, fields)
    }

    public func keepEligibility(_ record: ToolRecord, fullMac: Bool, ownerAuthorized: Bool) -> Outcome {
        do { return try AbilityStore.withLock {
            try prepareKeep(record.id, row: row(record.id), version: record.reviewedKeepDigest,
                            fullMac: fullMac, ownerAuthorized: ownerAuthorized).preview(ownerAuthorized: ownerAuthorized)
        } }
        catch {
            var fields = Self.fields(ToolHost.failure(error, effects: "none", execution: "not_run"))
            let detail = "Keeping \(record.id) could not be assessed: \(error.localizedDescription)"
            fields["detail"] = .string(detail)
            if fields["reason"] == .string("world_error") {
                fields["reason"] = .string("keep_eligibility_unavailable"); fields["failure_code"] = fields["reason"]
            }
            if fields["remedy"] == nil || fields["remedy"] == .null {
                fields["remedy"] = Repair.reconcile(instruction: "Read this ability and resolve the reported cause before assessing whether to keep it.", nextCall: Self.readCall(record.id))
            }
            return (false, detail, fields)
        }
    }

    /// Keep the checked candidate: hers under Full Mac for her own work, otherwise the owner's exact card. Code requires its full digest;
    /// nil restores guidance only. Preview uses the same read-only decision.
    public func enable(_ named: String, version: String?, fullMac: Bool,
                       ownerAuthorized: Bool, preview: Bool = false) async -> Outcome {
        var attempted = false
        do {
            // Guidance selection and restoration are one store transaction, so staging code cannot change what a nil-version restore
            // authorizes.
            let plan = try AbilityStore.withLock {
                let plan = try prepareKeep(named, row: try row(named), version: version, fullMac: fullMac, ownerAuthorized: ownerAuthorized)
                if !preview, case .guidance(let id, let name, _) = plan {
                    attempted = true
                    try mutate(id, ownerAuthorized: ownerAuthorized, enabling: true) { current in
                        guard var row = current, row["status"] == .string("disabled") else { throw PartError.invalid("\(name) changed meanwhile; read it again.") }
                        row["status"] = .string("active"); row["enabledAt"] = .string(Self.now()); row["updatedAt"] = row["enabledAt"]
                        for key in ["disabledBy", "disabledReason"] { row.removeValue(forKey: key) }
                        return row
                    }
                }
                return plan
            }
            if preview { return plan.preview(ownerAuthorized: ownerAuthorized) }
            switch plan {
            case .stopped(let outcome): return outcome
            case .guidance(_, let name, let fields):
                return (true, "\(name) is on: it is guidance, read with ability.read.", fields)
            case .code(let id, let name, let digest, let candidate, let proved, let fields):
                attempted = true
                if !proved { try store.kept(candidate, key: try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey()) }
                try await admit(id: id, digest: digest, by: ownerAuthorized ? "user" : "agent", ownerAuthorized: ownerAuthorized)
                guard try self.row(id)?["status"] == .string("active") else {
                    return (false, "Keeping \(name) could not be confirmed after reading it again.", fields.merging([
                        "reason": .string("keep_unconfirmed"), "effects": .string("unknown"),
                        "remedy": Repair.reconcile(instruction: "Read the selected status and version before another change.", nextCall: Self.readCall(id))]) { $1 })
                }
                return (true, "\(name) is on: run it as authored.\(id).", fields.merging(["run": .string("authored." + id)]) { $1 })
            }
        } catch { return Self.mutationFailure(error, named: named, operation: "enable", attempted: attempted) }
    }

    /// `ability.disable`: off, all its versions kept; ability.enable turns it back on. `disabledBy` is who did it: the owner only on his
    /// own surface (`ownerAuthorized`), an untrusted agent that steered the turn, else hers (a trusted agent that started the turn is
    /// provenance, as in authorship).
    public func disable(_ named: String, reason: String?, steer: [String] = [], fullMac: Bool, ownerAuthorized: Bool) -> Outcome {
        var attempted = false
        do {
            guard let row = try row(named), let id = Self.string(row, "id") else { return try unknown(named) }
            let name = Self.string(row, "name") ?? id
            let fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "state_before": row["status"] ?? .null]
            if let refusal = Self.overrideRefusal(row, name: name, fullMac: fullMac, ownerAuthorized: ownerAuthorized) { return (false, refusal, fields) }
            let untrusted = steer.filter { !CapabilityLifecycle.ownerTrusts($0) }
            let by = ownerAuthorized ? "owner" : untrusted.isEmpty ? "hers" : "peer"
            // His switch on what is already off makes it his; nothing else changes an off.
            guard row["status"] != .string("disabled") || by == "owner" && row["disabledBy"] != .string("owner") else {
                return (true, "\(name) is already off.", fields.merging(["changed": .bool(false)]) { $1 })
            }
            attempted = true
            try mutate(id, ownerAuthorized: ownerAuthorized) { current in
                guard var row = current else { throw PartError.notFound(named) }
                row["status"] = .string("disabled"); row.removeValue(forKey: "phase")
                let who = by == "owner" ? "the owner" : by == "hers" ? "her" : untrusted.joined(separator: ", ")
                row["disabledBy"] = .string(by)
                row["disabledReason"] = .string("Switched off by \(who)" + (reason.map { ": " + $0 } ?? "."))
                row["updatedAt"] = .string(Self.now())
                return row
            }
            return (true, by == "owner" ? "\(name) is off; the owner turns it back on." : "\(name) is off; ability.enable turns it back on.",
                    fields.merging(["disabled_by": .string(by)]) { $1 })
        } catch { return Self.mutationFailure(error, named: named, operation: "disable", attempted: attempted) }
    }

    /// `ability.drop`: deletes the part, its versions and its run state, for good; `pending` discards only its waiting version.
    public func drop(_ named: String, pending: Bool, fullMac: Bool, ownerAuthorized: Bool, preview: Bool) -> Outcome {
        var attempted = false
        do {
            guard let row = try row(named), let id = Self.string(row, "id") else { return try unknown(named) }
            let name = Self.string(row, "name") ?? id
            let fields: [String: JSONValue] = ["id": .string(id), "name": .string(name)]
            if pending {
                guard try abilities.read(id: id, slot: .next) != nil else {
                    return (false, "\(name) has no waiting version; nothing changed.", fields.merging([
                        "reason": .string("no_waiting_version"), "effects": .string("none"),
                        "remedy": Repair.terminal(instruction: "There is no draft to discard; no further drop call is needed.")]) { $1 })
                }
                if preview { return (true, "Would discard \(name)'s waiting version.", fields) }
                attempted = true
                try AbilityStore.withLock {
                    if try abilities.read(id: id) == nil { try abilities.remove(id: id) } else { try abilities.remove(id: id, slot: .next) }
                }
                return (true, "\(name)'s waiting version was discarded.", fields)
            }
            if let refusal = Self.overrideRefusal(row, name: name, fullMac: fullMac, ownerAuthorized: ownerAuthorized) { return (false, refusal, fields) }
            attempted = !preview
            try abilities.remove(id: id, ownerAuthorized: ownerAuthorized, preview: preview)
            return (true, preview ? "Would delete \(name), its versions and its run state permanently."
                : "Dropped \(name) permanently: its ability files and run state are removed.", fields)
        } catch { return Self.mutationFailure(error, named: named, operation: "drop", attempted: attempted) }
    }

    /// `ability.rollback`: swaps its current and previous versions. A version whose admission still verifies keeps the status; one without
    /// waits as a draft.
    public func rollback(_ named: String, version: String?, fullMac: Bool, ownerAuthorized: Bool, preview: Bool) async -> Outcome {
        var attempted = false
        do {
            let selection = try AbilityStore.withLock { () -> ([String: JSONValue], AbilityStore.File?)? in
                guard let row = try row(named), let id = Self.string(row, "id") else { return nil }
                return (row, try abilities.read(id: id))
            }
            guard let (row, current) = selection, let id = Self.string(row, "id") else { return try unknown(named) }
            let name = Self.string(row, "name") ?? id
            var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name)]
            if let refusal = Self.overrideRefusal(row, name: name, fullMac: fullMac, ownerAuthorized: ownerAuthorized) { return (false, refusal, fields) }
            guard let previous = try abilities.read(id: id, slot: .previous) else {
                return (false, "\(name) has no earlier version to select; nothing changed.", fields.merging([
                    "reason": .string("no_previous_version"), "effects": .string("none"),
                    "remedy": Repair.terminal(instruction: "No retained prior version exists; revise with ability.save if a change is needed.")]) { $1 })
            }
            var selected = previous.record
            guard let digest = Self.string(selected, "codeFingerprint") ?? Self.string(Self.fields(Self.fields(previous.metadata["candidate"] ?? .null)["program"] ?? .null), "version") else {
                let source = try abilities.path(id: id, slot: .previous, pathExtension: previous.pathExtension)
                let failure = abilities.repairFailure(source: source, detail: "The retained prior version has no code digest.")
                return (false, failure.message, fields.merging(["reason": .string("prior_version_unreadable"), "effects": .string("none"),
                    "remedy": failure.remedy()]) { $1 })
            }
            guard version == nil || version == digest else { return (false, "Only \(id)'s previous version, \(digest), can be selected.", fields.merging([
                "reason": .string("wrong_previous_version"), "effects": .string("none"),
                "remedy": Repair.reconcile(instruction: "Read the retained versions before selecting the exact previous digest.", nextCall: Self.readCall(id))]) { $1 }) }
            let target = try store.load(id: id, digest: digest)
            selected["activePath"] = .string(try store.fileURL(id: id, digest: digest).path)
            let admitted: Bool
            do { try await checkAdmission(target, row: selected); admitted = true }
            catch let failure as SenseFailure where failure.code == "integrity" { admitted = false }
            let status = Self.string(row, "status") == "disabled" ? "disabled" : admitted ? Self.string(row, "status") ?? "draft" : "draft"
            fields["would_land_on"] = .string(String(digest.prefix(12))); fields["would_status"] = .string(status)
            if preview {
                return (true, "Would swap \(name)'s current and previous versions, selecting \(digest.prefix(12)); it would be \(status)"
                    + (status == "draft" ? ": ability.enable keeps it." : "."), fields)
            }
            try AbilityStore.withLock {
                guard try abilities.read(id: id, slot: .previous) == previous, try abilities.read(id: id) == current else {
                    throw PartError.invalid("\(name) changed during rollback; read it again.")
                }
                for key in ["status", "disabledBy", "disabledReason"] { selected[key] = row[key] }
                selected["status"] = .string(status)
                // Selected, it lives in the current file.
                if admitted { selected["activePath"] = .string(try abilities.path(id: id).path) }
                else { for key in ["admission", "activePath"] { selected.removeValue(forKey: key) } }
                for key in ["phase", "manifestSignature", "signedAt", "signatureVersion"] { selected.removeValue(forKey: key) }
                // What restricts it survives the swap: an untrusted agent's or a pack's origin ratchets, and a built-in's own version stays
                // one.
                selected["origin"] = Self.merged(Self.recorded(selected) + Self.recorded(row))
                if row["overrides"] == .string("built_in") { selected["overrides"] = .string("built_in") }
                selected["updatedAt"] = .string(Self.now())
                attempted = true
                try abilities.swap(id: id, record: selected)
            }
            return (true, "Rolled \(name) back to its previous version (\(digest.prefix(12))). "
                + (status == "draft" ? "It is a draft: ability.enable keeps it." : status == "disabled" ? "It stays off." : "It is on under its admission."),
                fields.merging(["state": .string(status)]) { $1 })
        } catch { return Self.mutationFailure(error, named: named, operation: "rollback", attempted: attempted) }
    }

    static func mutationFailure(_ error: Error, named: String, operation: String, attempted: Bool) -> Outcome {
        let cause = ToolHost.failure(error, effects: attempted ? "unknown" : "none", execution: attempted ? "attempted" : "not_run")
        var fields = Self.fields(cause)
        let detail = "ability.\(operation) for \(named) did not complete: \(error.localizedDescription)"
        fields["detail"] = .string(detail)
        fields["effects"] = .string(attempted ? "unknown" : "none")
        if fields["reason"] == .string("world_error") {
            fields["reason"] = .string("ability_\(operation)_failed"); fields["failure_code"] = fields["reason"]
        }
        if attempted {
            fields["result"] = cause
            fields["remedy"] = Repair.reconcile(instruction: "A write was attempted; its final state is unconfirmed. Read \(named)'s status and retained versions before another change, then address the reported cause.", nextCall: readCall(named))
        } else if fields["remedy"] == nil || fields["remedy"] == .null {
            fields["remedy"] = Repair.reconcile(instruction: "No mutation was attempted. Read this ability and address the reported cause before changing it.", nextCall: readCall(named))
        }
        return (false, detail, fields)
    }

    /// A built-in skill's own version: switching it off, dropping it or changing its version is the owner's below Full Mac.
    static func overrideRefusal(_ row: [String: JSONValue], name: String, fullMac: Bool, ownerAuthorized: Bool) -> String? {
        guard row["overrides"] == .string("built_in"), !fullMac, !ownerAuthorized else { return nil }
        return "\(name) is your version of a built-in skill, so switching it off, dropping it or changing its version is the owner's. Ask them."
    }
}
