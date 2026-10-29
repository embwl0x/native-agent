import AuthoredCapabilities
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
import ToolRegistry
import NativeAgentShared
import PersonaEngine
import Privacy
// Blueprint: | `Parts+Migration.swift` | Parts bundled seed admission and retained tool/skill conversion; IDs, code, versions, digests and provenance remain intact |

extension Parts {
    /// A bundled seed lands kept and on: its bytes are the app's own.
    package func bundledSeed(_ seed: AbilityStore.File) async throws -> AbilityStore.File {
        let record = seed.record.filter { !["kind", "version"].contains($0.key) }
        guard case .string(let description)? = record["description"], !description.isEmpty else {
            throw PartError.invalid("Seed \(seed.id) needs a description in its record. Fix the bundled seed and relaunch.")
        }
        let actions = try Self.declaredStrings(record["actions"], name: "actions")
        let permissions = try Self.declaredStrings(Self.fields(seed.part["reach"] ?? .null)["capabilities"], name: "reach.capabilities")
        let schema = record["inputSchema"] ?? .object(["type": .string("object")])
        let manifest = record.merging([
            "id": .string(seed.id), "name": record["name"] ?? .string(seed.id), "origin": .object(["by": .string("hers")]),
            "language": .string("javascript"), "inputSchema": schema, "actions": .array(actions.map(JSONValue.string)),
        ]) { _, value in value }.merging(seed.part) { _, value in value }
        let candidate = try OwnedProgramStore.Candidate(
            program: OwnedProgram(kind: .part, id: seed.id, version: "seed", source: seed.body, entry: .run,
                schema: schema, dependencies: actions, permissions: permissions, resident: seed.part["resident"] == .bool(true)),
            manifest: .object(manifest), fixtures: .array([]), dependencyShapes: try dependencyShapes(actions), prior: .null)
        try checkDependencies(candidate)
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let key = try await signer.loadOrCreateSigningKey()
        let version: Int64 = if case .int(let value)? = seed.metadata["version"] { value } else { 1 }
        var file = try store.bundledSeed(candidate, version: version, key: key)
        guard let proof = file.metadata["proof"] else { throw PartError.invalid("Bundled seed \(seed.id) has no admission proof.") }
        let admission = try await signer.sign(["id": .string(seed.id), "candidate": .string(candidate.digest), "proof": proof, "by": .string("user")])
        let stamp = Self.now()
        file.metadata["record"] = .object(manifest.merging([
            "status": .string("active"), "createdAt": .string(stamp), "updatedAt": .string(stamp),
            "codeFingerprint": .string(candidate.digest), "activePath": .string(try abilities.path(id: seed.id).path),
            "admission": .object(admission),
        ]) { _, value in value })
        return file
    }

    /// At launch every tool and skill file takes the one form, each slot, with no change in what runs: the same ids, code, versions and
    /// digests; a skill's admission is re-signed as the one admission when it was runnable, and anything that was not runnable waits as a
    /// draft. Idempotent: a record already in the one form is left as it is.
    public func migrate() async throws {
        var pending: [(AbilityStore.File, AbilityStore.Slot)] = []
        for (file, slot) in try abilities.retainedFiles() where file.kind == .part {
            if let row = file.metadata["record"].map(Self.fields), Self.legacy(row) { pending.append((file, slot)) }
        }
        guard !pending.isEmpty else { return }
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let key = try await signer.loadOrCreateSigningKey()
        for (file, slot) in pending {
            var row = Self.fields(file.metadata["record"] ?? .null)
            let descriptor = Self.fields(file.metadata["candidate"] ?? .null)
            let digest = Self.string(Self.fields(descriptor["program"] ?? .null), "version")
            let candidate = try digest.map { try store.load(id: file.id, digest: $0) }
            if row["status"] == .string("proposed") { row["status"] = .string("draft") }
            let recordedOrigin = row["origin"]
            if row["origin"] != nil { row["origin"] = Self.merged([row["origin"]]) }
            if row["status"] == .string("installed") { row["status"] = .string("active") }
            row.removeValue(forKey: "phase")
            if row["script"] != nil || row["actionPin"] != nil || row["scriptDigest"] != nil {
                // A skill: what ran, now declared as a part's record.
                let script = Self.fields(row.removeValue(forKey: "script") ?? .null)
                let pin = Self.fields(row["actionPin"] ?? .null)
                let admission = Self.fields(row["admission"] ?? .null)
                let selected = slot != .next ? Self.string(row, "codeFingerprint") : nil
                // The checks that made it runnable before stay what admits it now.
                var whole = script; whole["source"] = .string(file.body)
                let checksum = (try? JSONValue.object(whole).serializedData(pretty: false))
                    .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                let proof = candidate.flatMap { try? store.proof($0, key: key) }
                let notRunnable: String? = if selected == nil || selected != digest { "no selected version is this file's code" }
                    else if admission["candidate"] != .string(selected ?? "") { "no admission binds its exact version" }
                    else if Self.originKind(recordedOrigin) == nil { "its origin is missing or malformed" }
                    else if !(admission["by"] == .string("user") || admission["by"] == .string("agent") && Self.agentMayAdmit(recordedOrigin)) {
                        "its admission is not one its origin allows" }
                    else if script["entry"] != .string("run") { "its script has no run(input) entry" }
                    else if !Self.canonical(script, source: file.body) { "its script is not in its normal form" }
                    else if pin["interpreter"] != .int(2) { "its action pin is from another interpreter revision" }
                    else if checksum == nil || pin["digest"] != checksum.map(JSONValue.string) { "its script changed since its action pin" }
                    else if proof == nil { "its sealed proof is missing or stale" }
                    else { nil }
                let evidence = row.filter { ["admission", "actionPin", "scriptDigest", "suspended"].contains($0.key) }
                for key in ["scriptDigest", "signature", "actionPin", "suspended", "candidateOrigin", "admission", "kind"] { row.removeValue(forKey: key) }
                row["language"] = .string("javascript")
                if let params = script["params"], params != .object([:]) { row["params"] = params }
                if let candidate {
                    row["inputSchema"] = candidate.program.schema
                    row["actions"] = .array(candidate.program.dependencies.map(JSONValue.string))
                }
                if notRunnable == nil, let digest, let proof {
                    row["admission"] = .object(try await signer.sign(["id": .string(file.id), "candidate": .string(digest),
                        "proof": proof, "by": admission["by"] ?? .string("agent")]))
                    row["activePath"] = .string(try store.fileURL(id: file.id, digest: digest).path)
                } else if slot != .next {
                    // Not runnable before, so a draft now, with why and what it carried.
                    if row["status"] == .string("active") { row["status"] = .string("draft") }
                    row["migrationEvidence"] = .object(evidence.merging(["not_runnable": .string(notRunnable ?? "")]) { $1 })
                }
            }
            try AbilityStore.withLock {
                guard var current = try abilities.read(id: file.id, slot: slot), current == file else { return }
                current.metadata["record"] = .object(row)
                try abilities.write(current, slot: slot)
            }
        }
    }

    /// A skill's script as its save stored it, in its normal form: the old admission's own test, which migration keeps.
    static func canonical(_ script: [String: JSONValue], source: String) -> Bool {
        // The old normal form always carried params and actions, possibly empty.
        guard Set(script.keys).isSubset(of: ["params", "actions", "steps", "of", "entry"]),
              case .object(let params)? = script["params"], case .array? = script["actions"],
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf8.count <= AbilityStore.sourceLimit,
              case .int(let of)? = script["of"], (1...50).contains(of) else { return false }
        guard params.isEmpty || (try? Self.params(.object(params)))?.params == params else { return false }
        let actions = strings(script["actions"])
        guard script["actions"] == .array(actions.map(JSONValue.string)), actions.count <= 50,
              Set(actions).count == actions.count, actions.allSatisfy({ dependencyID($0) == $0 }) else { return false }
        guard let steps = script["steps"] else { return true }
        let labels = strings(steps)
        return steps == .array(labels.map(JSONValue.string)) && labels.count == Int(of) && labels.allSatisfy { !$0.isEmpty && $0.count <= 160 }
    }

    /// A record from before the one form: a skill's, or a tool's proposal.
    static func legacy(_ row: [String: JSONValue]) -> Bool {
        ["script", "actionPin", "scriptDigest", "phase"].contains { row[$0] != nil }
            || [.string("proposed"), .string("installed")].contains(row["status"] ?? .null)
    }
}
