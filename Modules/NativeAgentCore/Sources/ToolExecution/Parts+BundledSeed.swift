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
// Blueprint: | `Parts+BundledSeed.swift` | Parts bundled seed admission from the shipped current part contract |

extension Parts {
    /// A current seed needs no admission work. Changed bundle bytes land kept and on.
    package func bundledSeed(_ seed: AbilityStore.File, invocation: Invocation) async throws -> AbilityStore.File? {
        let record = seed.record.filter { !["kind", "version"].contains($0.key) }
        guard case .string(let description)? = record["description"], !description.isEmpty else {
            throw PartError.invalid("Seed \(seed.id) needs a description in its record. Fix the bundled seed and relaunch.")
        }
        let actions = try Self.declaredStrings(record["actions"], name: "actions")
        let permissions = try Self.declaredStrings(Self.fields(seed.part["reach"] ?? .null)["capabilities"], name: "reach.capabilities")
        let schema = AbilityStore.answeredInputSchema(seed.part["answers"]) ?? record["inputSchema"] ?? .object(["type": .string("object")])
        let manifest = record.merging([
            "id": .string(seed.id), "name": record["name"] ?? .string(seed.id), "origin": .object(["by": .string("hers")]),
            "language": .string("javascript"), "inputSchema": schema, "actions": .array(actions.map(JSONValue.string)),
        ]) { _, value in value }.merging(seed.part) { _, value in value }
        let candidate = try OwnedProgramStore.Candidate(
            program: OwnedProgram(kind: .part, id: seed.id, version: "seed", source: seed.body, entry: .run,
                schema: schema, dependencies: actions, permissions: permissions, resident: seed.part["resident"] == .bool(true)),
            manifest: .object(manifest), fixtures: .array([]), dependencyShapes: try dependencyShapes(actions, invocation: invocation), prior: .null)
        let version: Int64 = if case .int(let value)? = seed.metadata["version"] { value } else { 1 }
        guard try !store.isCurrentSeed(candidate, version: version) else { return nil }
        try await checkDependencies(candidate, invocation: invocation)
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let key = try await signer.loadOrCreateSigningKey()
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

}
