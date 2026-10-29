import AuthoredCapabilities
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgramStore.swift` | exact authenticated rehearsal reuse with capture-input checks, without treating keep or seed seals as rehearsals; Retained ability file URLs, candidate identity, sealed rehearsal and publication through AbilityStore headers; rehearsal scopes supplied inputs and reached calls, never behavioral proof from intercepted replies; trusted bundled-seed proofs seal exact bytes without validation receipts or staging; kept proofs seal their Full Mac keeps without rehearsal; source-bound sense reads bind captured-material proof; OwnedProgramFixtures reads live and intercepts tool/routine effects and decisions; fixtures written from recorded practice (`tape: true` on every case) replay their calls alone, never captured afresh, each call matched and answered from the tape with complete consumption, and seal their `tape` coverage |

/// Executable metadata and source share the ability's current, previous or next file.
public struct OwnedProgramStore: Sendable {
    public static let hostRevision = "owned-program-1"
    public let root: URL

    public init(root: URL) {
        let folder = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = folder.lastPathComponent == "abilities" ? folder : folder.deletingLastPathComponent().appendingPathComponent("abilities")
    }

    private var abilities: AbilityStore { AbilityStore(dataRoot: root.deletingLastPathComponent()) }

    public static func conversionSources(_ value: JSONValue?) throws -> JSONValue {
        guard case .array(let sources) = value ?? .array([]), sources.allSatisfy({
            guard case .string(let digest) = $0 else { return false }
            return digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }) else { throw SenseFailure(code: "bad_input", message: "converts lists original source SHA-256 digests from the conversion census.") }
        return .array(sources)
    }

    public struct Candidate: Sendable, Equatable {
        /// File ownership is independent of the original sealed program identity.
        public internal(set) var id: String
        public let program: OwnedProgram
        public let manifest: JSONValue
        public let fixtures: JSONValue
        public let dependencyShapes: JSONValue
        public let prior: JSONValue
        /// Candidate identity, sealing all authored inputs, not just source.
        public var digest: String { program.version }
        /// The program as it runs: under the ability that owns its file. A
        /// migrated version may be sealed under another ability's id; its bytes keep it.
        public var owned: OwnedProgram {
            OwnedProgram(kind: program.kind, id: id, version: program.version, source: program.source,
                entry: program.entry, schema: program.schema, dependencies: program.dependencies,
                permissions: program.permissions, reach: program.reach, seconds: program.seconds, resident: program.isResident)
        }

        public init(program: OwnedProgram, manifest: JSONValue, fixtures: JSONValue,
                    dependencyShapes: JSONValue, prior: JSONValue) throws {
            self.id = program.id
            self.manifest = manifest; self.fixtures = fixtures
            self.dependencyShapes = dependencyShapes; self.prior = prior
            let identity = try OwnedProgramStore.digest(program: program, manifest: manifest,
                fixtures: fixtures, dependencyShapes: dependencyShapes, prior: prior)
            self.program = OwnedProgram(kind: program.kind, id: program.id, version: identity,
                source: program.source, entry: program.entry, schema: program.schema,
                dependencies: program.dependencies, permissions: program.permissions,
                reach: program.reach, seconds: program.seconds, resident: program.isResident)
        }
    }

    public func fileURL(id: String, digest: String) throws -> URL {
        guard Self.component(id), digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw SenseFailure(code: "bad_input", message: "Invalid owned program identity.")
        }
        guard let retained = try retained(id: id, matching: { $0.digest == digest }) else {
            throw SenseFailure(code: "integrity", message: "The ability version is no longer retained.")
        }
        return try abilities.path(id: id, slot: retained.slot, pathExtension: retained.file.pathExtension)
    }

    /// `writing` runs at the write boundary: a refusal before it wrote nothing.
    public func stage(_ candidate: Candidate, writing: () -> Void = {}) throws {
        try CapabilityLifecycle.requireWrite()
        try check(candidate)
        try AbilityStore.withLock {
            if try retained(id: candidate.id, matching: { $0 == candidate }) != nil { return }
            guard let kind = candidate.program.storeKind else {
                throw SenseFailure(code: "bad_input", message: "This program is not an ability.")
            }
            let id = candidate.id
            let versions = try [AbilityStore.Slot.current, .previous].compactMap { slot -> Int64? in
                guard let file = try abilities.read(id: id, slot: slot), case .int(let version)? = file.metadata["version"] else { return nil }
                return version
            }
            guard (versions.max() ?? 0) < Int64.max else { throw SenseFailure(code: "bad_input", message: "Ability version overflow.") }
            try abilities.write(file(candidate, kind: kind, version: (versions.max() ?? 0) + 1), slot: .next, writing: writing)
        }
    }

    private func file(_ candidate: Candidate, kind: AbilityStore.Kind, version: Int64) throws -> AbilityStore.File {
        let id = candidate.id
        if kind != .sense, try BuiltInSenses.defaults().contains(where: { $0.record.id.caseInsensitiveCompare(id) == .orderedSame }) {
            throw SenseFailure(code: "bad_input", message: "Ability id collision: \(id) is a bundled sense.")
        }
        guard var descriptor = try value(candidate).objectValue, var program = descriptor["program"]?.objectValue else {
            throw SenseFailure(code: "integrity", message: "Candidate descriptor has no program object.")
        }
        program.removeValue(forKey: "source")
        descriptor["program"] = .object(program)
        if var manifest = descriptor["manifest"]?.objectValue, var script = manifest["script"]?.objectValue {
            script.removeValue(forKey: "source"); manifest["script"] = .object(script)
            descriptor["manifest"] = .object(manifest)
        }
        return try AbilityStore.File(id: candidate.id, kind: kind,
            metadata: ["candidate": .object(descriptor), "version": .int(version)], body: candidate.program.source, pathExtension: "js")
    }

    /// Bundle bytes are trusted at installation; no validation run took place.
    package func bundledSeed(_ candidate: Candidate, version: Int64, key: Data) throws -> AbilityStore.File {
        try check(candidate)
        guard let kind = candidate.program.storeKind else {
            throw SenseFailure(code: "bad_input", message: "This program is not an ability.")
        }
        var file = try file(candidate, kind: kind, version: version)
        file.metadata["proof"] = try sealedProof(candidate, evidence: ["domain": .string("owned-program-seed")], key: key)
        return file
    }

    public func load(id: String, digest: String) throws -> Candidate {
        guard let retained = try retained(id: id, matching: { $0.digest == digest }) else {
            throw SenseFailure(code: "integrity", message: "The ability version is no longer retained.")
        }
        return retained.candidate
    }

    private func decode(_ file: AbilityStore.File) throws -> Candidate {
        guard var fields = file.metadata["candidate"]?.objectValue,
              var programFields = fields["program"]?.objectValue else {
            throw SenseFailure(code: "integrity", message: "The candidate descriptor is incomplete.")
        }
        programFields["source"] = .string(file.body); fields["program"] = .object(programFields)
        if var manifest = fields["manifest"]?.objectValue, var script = manifest["script"]?.objectValue {
            script["source"] = .string(file.body); manifest["script"] = .object(script)
            fields["manifest"] = .object(manifest)
        }
        guard
              let programValue = fields["program"], case .object(let descriptor) = programValue,
              let schema = descriptor["schema"], let manifest = fields["manifest"], let fixtures = fields["fixtures"],
              let dependencies = fields["dependencyShapes"], let prior = fields["prior"] else {
            throw SenseFailure(code: "integrity", message: "The candidate descriptor is incomplete.")
        }
        let decoded = try JSONDecoder().decode(OwnedProgram.self, from: programValue.serializedData(pretty: false))
        try decoded.validate()
        let program = OwnedProgram(kind: decoded.kind, id: decoded.id, version: decoded.version,
            source: decoded.source, entry: decoded.entry, schema: schema, dependencies: decoded.dependencies,
            permissions: decoded.permissions, reach: decoded.reach, seconds: decoded.seconds, resident: decoded.isResident)
        let expected = try AbilityStore.File(id: file.id, kind: file.kind, metadata: ["candidate": .object(fields)], body: file.body, pathExtension: file.pathExtension)
        guard file.part == expected.part else { throw SenseFailure(code: "integrity", message: "Part header differs from its exact candidate. Propose it again.") }
        var candidate = try Candidate(program: program, manifest: manifest, fixtures: fixtures,
                                      dependencyShapes: dependencies, prior: prior)
        candidate.id = file.id
        guard decoded.version == candidate.digest else {
            throw SenseFailure(code: "integrity", message: "Candidate source, manifest or fixtures changed. Propose it again.")
        }
        return candidate
    }

    public func conversions(id: String) throws -> [Candidate] {
        guard Self.component(id) else { throw SenseFailure(code: "bad_input", message: "Invalid owned program identity.") }
        return try [AbilityStore.Slot.current, .previous, .next]
            .compactMap { try abilities.read(id: id, slot: $0) }
            .filter { $0.metadata["candidate"] != nil }.map(decode)
            .filter { $0.manifest.objectValue?["converts"]?.arrayValue?.isEmpty == false }
            .sorted { $0.digest < $1.digest }
    }

    /// Rehearsal receipts are from the shipped executor with an intercepting host, never behavioral proof.
    /// A seal binds the exact artifact, fixtures, host API and dependency shapes.
    public func bind(_ candidate: Candidate, receipts: [JSONValue], key: Data,
                     captured: JSONValue? = nil) throws -> JSONValue {
        try CapabilityLifecycle.requireWrite()
        guard try load(id: candidate.id, digest: candidate.digest) == candidate else {
            throw SenseFailure(code: "integrity", message: "Candidate changed during validation.")
        }
        var evidence: [String: JSONValue] = ["domain": .string("owned-program-validation"), "receipts": .array(receipts),
            "capture": .string("Rehearsed supplied fixtures. Intercepted replies are not behavioral evidence; no other input or branch is proven.")]
        if let captured {
            evidence["capturedFixtures"] = captured
            evidence["capture"] = .string(OwnedProgramFixtures.summary(captured))
        }
        // Recorded practice replayed: its coverage is the seal's own claim.
        if let tape = Self.tape(candidate.fixtures) {
            let calls = tape.reduce(0) { $0 + ($1.objectValue?["calls"]?.arrayValue?.count ?? 0) }
            evidence["tape"] = .object(["examples": .int(Int64(tape.count)), "calls": .int(Int64(calls)),
                                        "consumed": .string("complete"), "effects": .string("none")])
            evidence["capture"] = .string("Replayed \(tape.count) recorded examples (\(calls) calls): every call intercepted, matched exactly and answered from the tape, all of it consumed, no effect run. It proves those examples; no other input or branch is proven.")
        }
        return try seal(candidate, evidence: evidence, key: key)
    }

    /// Fixtures written from recorded practice (`tape: true` on every case):
    /// each case's calls are what went and came back, and its returned value
    /// is the candidate's own, so a replay checks the calls alone. Nil when
    /// they are hand-written; a mix is refused at validation.
    public static func tape(_ fixtures: JSONValue) -> [JSONValue]? {
        guard let cases = fixtures.arrayValue, !cases.isEmpty,
              cases.allSatisfy({ $0.objectValue?["tape"] == .bool(true) }) else { return nil }
        return cases
    }

    /// Kept by her under Full Mac, with no rehearsal: a rehearsal
    /// proves no live behavior, so its first real run is its proof, and a
    /// failing run owes repair as any part's does.
    public func kept(_ candidate: Candidate, key: Data) throws {
        try CapabilityLifecycle.requireWrite()
        _ = try seal(candidate, evidence: ["domain": .string("owned-program-kept")], key: key)
    }

    private func seal(_ candidate: Candidate, evidence: [String: JSONValue], key: Data) throws -> JSONValue {
        let proof = try sealedProof(candidate, evidence: evidence, key: key)
        try AbilityStore.withLock {
            guard let retained = try retained(id: candidate.id, matching: { $0 == candidate }) else {
                throw SenseFailure(code: "integrity", message: "The ability version is no longer retained.")
            }
            var file = retained.file
            file.metadata["proof"] = proof
            try abilities.write(file, slot: retained.slot)
        }
        return proof
    }

    private func sealedProof(_ candidate: Candidate, evidence: [String: JSONValue], key: Data) throws -> JSONValue {
        var fields = evidence.merging([
            "candidate": .string(candidate.digest), "fixtures": .string(try Self.hash(candidate.fixtures)),
            "entry": .string(candidate.program.entry.rawValue), "hostRevision": .string(Self.hostRevision),
            "dependencies": candidate.dependencyShapes,
        ]) { _, value in value }
        fields["seal"] = .string(try Self.seal(.object(fields), key: key))
        return .object(fields)
    }

    /// Recording and replay use the same intercepting host and shipped runner.
    /// Once sealed, a capture cannot be refreshed underneath this candidate.
    public func validate(_ candidate: Candidate, key: Data, capture: Bool = false, input: JSONValue? = nil,
                         runner: any OwnedProgramRunning, host: @Sendable () -> any OwnedProgramHostProfile,
                         checkInput: @Sendable (JSONValue) throws -> Void) async throws -> JSONValue {
        try CapabilityLifecycle.requireWrite()
        try Task.checkCancellation()
        var captured: JSONValue?
        guard let retained = try retained(id: candidate.id, matching: { $0 == candidate }) else {
            throw SenseFailure(code: "integrity", message: "The ability version is no longer retained.")
        }
        if retained.file.metadata["proof"] != nil {
            let saved = try proof(candidate, key: key)
            if let fixtures = saved.objectValue?["capturedFixtures"] {
                captured = fixtures
                if let input, captured?.arrayValue?.first?.objectValue?["input"] != input {
                    throw SenseFailure(code: "stale_validation", message: "This candidate already has a sealed capture with another input. Save a new candidate to capture different input.")
                }
            }
            // Only a sealed rehearsal is reusable as a rehearsal. A keep or
            // seed seal makes no claim that these fixtures have been run.
            // proof() checks the exact candidate, fixtures, host and shapes.
            if (captured != nil || !capture && input == nil),
               saved.objectValue?["domain"] == .string("owned-program-validation"),
               saved.objectValue?["receipts"]?.arrayValue?.isEmpty == false {
                return saved
            }
        }
        // Recorded practice is replayed from its tape, never captured afresh.
        let replaying = Self.tape(candidate.fixtures) != nil
        if !replaying, candidate.fixtures.arrayValue?.contains(where: { $0.objectValue?["tape"] != nil }) == true {
            throw SenseFailure(code: "bad_input", message: "Fixtures are all recorded tape or all hand-written; this candidate mixes them. Save it again.")
        }
        let recording = !replaying && captured == nil && (capture || candidate.fixtures.arrayValue?.isEmpty == true)
        let fixtures = recording ? [.object(["input": input ?? .object([:])])] : (captured ?? candidate.fixtures).arrayValue ?? []
        guard !fixtures.isEmpty else { throw SenseFailure(code: "bad_input", message: "Supply fixtures or capture input for validation.") }
        var receipts: [JSONValue] = []
        for (index, value) in fixtures.enumerated() {
            try Task.checkCancellation()
            let fields = value.objectValue ?? [:]
            guard let input = fields["input"], recording || replaying || fields["expected"] != nil else {
                throw SenseFailure(code: "bad_input", message: "Fixture \(index + 1) requires input and expected returned JSON.")
            }
            try checkInput(input)
            let interceptor = OwnedProgramFixtures(base: host(), calls: recording ? nil : fields["calls"]?.arrayValue ?? [],
                                                   decisions: recording || captured != nil)
            let answers = fields["answers"]?.arrayValue ?? []
            guard answers.count <= OwnedProgramRunner.stepLimit else {
                throw SenseFailure(code: "bad_input", message: "A fixture has more than 50 decision answers.")
            }
            var replay: OwnedProgramRunner.Replay?
            var final: [String: JSONValue] = [:]
            for pass in 0...answers.count {
                let receipt = await SkillRunContext.$handsBack.withValue(true) {
                    await runner.run(candidate.owned, input: input, preview: false, replay: replay, host: interceptor)
                }
                final = receipt.objectValue ?? [:]
                receipts.append(.object(final.merging(["input": input]) { _, input in input }))
                if final["status"] == .string("ok") { break }
                guard !recording, pass < answers.count, final["status"] == .string("stopped"),
                      ["decide", "irreversible", "users_step", "would_card"].contains(final["reason"]?.stringValue ?? ""),
                      let journal = final["journal"]?.arrayValue else {
                    let failure = (final["stopped"] ?? final["error"])?.objectValue ?? [:]
                    throw SenseFailure(code: "validation_failed", message: "Fixture \(index + 1) stopped: \(failure["reason"]?.stringValue ?? "runtime") — \(failure["detail"]?.stringValue ?? failure["message"]?.stringValue ?? "Fix the candidate or supply exact fixtures.")")
                }
                replay = OwnedProgramRunner.Replay(journal: journal, answer: answers[pass], recheckReads: false)
            }
            guard final["status"] == .string("ok"), await interceptor.finished,
                  try (recording || replaying || JSONValue.fromEncodable(final["returned"] ?? .null)
                      == JSONValue.fromEncodable(fields["expected"] ?? .null)) else {
                throw SenseFailure(code: "fixture_mismatch", message: replaying
                    ? "Its calls differ from recorded example \(index + 1): a call the tape does not hold, in another order or with other arguments, or one it holds left unmade. No effect ran."
                    : "Returned JSON or intercepted calls differ from fixture \(index + 1). No effect ran.")
            }
            if recording {
                let fixture: JSONValue = .array([.object(["input": input, "calls": .array(await interceptor.recorded),
                                                         "expected": final["returned"] ?? .null])])
                guard try fixture.serializedData(pretty: false).count <= candidate.program.returnLimit else {
                    throw SenseFailure(code: "output_limit", message: "The captured fixture exceeds the candidate's material limit. Supply smaller input or explicit fixtures.")
                }
                captured = fixture
            }
        }
        return try bind(candidate, receipts: receipts, key: key, captured: captured)
    }

    public func discard(_ candidate: Candidate) throws {
        try AbilityStore.withLock {
            if let file = try abilities.read(id: candidate.id, slot: .next), file.metadata["candidate"] != nil,
               try decode(file) == candidate {
                if try abilities.read(id: candidate.id, slot: .current) == nil {
                    try abilities.remove(id: candidate.id)
                } else { try abilities.remove(id: candidate.id, slot: .next) }
            }
        }
    }

    public func proof(_ candidate: Candidate, key: Data) throws -> JSONValue {
        guard let retained = try retained(id: candidate.id, matching: { $0 == candidate }) else {
            throw SenseFailure(code: "integrity", message: "The ability version is no longer retained.")
        }
        guard case .object(var fields)? = retained.file.metadata["proof"],
              case .string(let saved)? = fields.removeValue(forKey: "seal"),
              [JSONValue.string("owned-program-validation"), .string("owned-program-seed"), .string("owned-program-kept")].contains(fields["domain"] ?? .null),
              fields["candidate"] == .string(candidate.digest),
              fields["fixtures"] == .string(try Self.hash(candidate.fixtures)),
              fields["entry"] == .string(candidate.program.entry.rawValue),
              fields["hostRevision"] == .string(Self.hostRevision),
              fields["dependencies"] == candidate.dependencyShapes,
              bytesEqual(Data(saved.utf8), Data(try Self.seal(.object(fields), key: key).utf8)) else {
            throw SenseFailure(code: "stale_validation", message: "Validation proof is missing or stale. Validate this exact candidate again.")
        }
        fields["seal"] = .string(saved)
        return .object(fields)
    }

    /// Domain adapters check their prior selection before publishing the next file.
    public func keep(_ candidate: Candidate, key: Data, ownerAuthorized: Bool = false,
                     select: @escaping @Sendable (inout JSONValue) throws -> Void) async throws {
        try CapabilityLifecycle.requireWrite()
        try AbilityStore.withLock {
            guard try load(id: candidate.id, digest: candidate.digest) == candidate else {
                throw SenseFailure(code: "integrity", message: "Candidate changed before publication.")
            }
            guard let kind = candidate.program.storeKind else {
                throw SenseFailure(code: "bad_input", message: "This program is not an ability.")
            }
            _ = try proof(candidate, key: key)
            var rows = try abilities.registry(kind: kind)
            try select(&rows)
            try abilities.saveRegistry(rows, kind: kind, ownerAuthorized: ownerAuthorized, enabling: true)
        }
    }

    public static func selection(_ row: JSONValue?) -> JSONValue {
        guard case .object(let fields)? = row else { return .null }
        return .object(fields.filter { ["status", "disabledBy", "codeFingerprint", "candidateDigest", "updatedAt"].contains($0.key) })
    }

    public static func hash(_ value: JSONValue) throws -> String {
        SHA256.hash(data: try value.serializedData(pretty: false)).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(program: OwnedProgram, manifest: JSONValue, fixtures: JSONValue,
                               dependencyShapes: JSONValue, prior: JSONValue) throws -> String {
        guard case .object(var fields) = try programValue(program) else { throw CancellationError() }
        fields.removeValue(forKey: "version")
        return try hash(.object(["program": .object(fields), "manifest": manifest, "fixtures": fixtures,
                                 "dependencies": dependencyShapes, "prior": prior]))
    }

    private static func programValue(_ program: OwnedProgram) throws -> JSONValue {
        guard case .object(var fields) = try JSONValue.fromEncodable(program) else { throw CancellationError() }
        fields["schema"] = program.schema
        return .object(fields)
    }

    private func value(_ candidate: Candidate) throws -> JSONValue {
        .object(["program": try Self.programValue(candidate.program), "manifest": candidate.manifest,
                 "fixtures": candidate.fixtures, "dependencyShapes": candidate.dependencyShapes, "prior": candidate.prior])
    }

    private func check(_ candidate: Candidate) throws {
        try candidate.program.validate()
        guard candidate.digest == (try Self.digest(program: candidate.program, manifest: candidate.manifest,
                fixtures: candidate.fixtures, dependencyShapes: candidate.dependencyShapes, prior: candidate.prior)) else {
            throw SenseFailure(code: "integrity", message: "Candidate identity does not match its bytes.")
        }
    }

    private func retained(id: String, matching: (Candidate) -> Bool) throws
        -> (slot: AbilityStore.Slot, file: AbilityStore.File, candidate: Candidate)? {
        for slot in [AbilityStore.Slot.current, .previous, .next] {
            if let file = try abilities.read(id: id, slot: slot), file.metadata["candidate"] != nil {
                let candidate = try decode(file)
                if matching(candidate) { return (slot, file, candidate) }
            }
        }
        return nil
    }

    private static func seal(_ value: JSONValue, key: Data) throws -> String {
        HMAC<SHA256>.authenticationCode(for: try value.serializedData(pretty: false), using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func bytesEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func component(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix(".") && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }
}

/// A thought's output and nested effect evidence, even when it failed or stopped.
public struct OwnedProgramThought: Sendable {
    public let output: Result<String, any Error>
    public let effects: String
    public init(output: Result<String, any Error>, effects: String) {
        self.output = output; self.effects = effects
    }
}

/// The originating app door contributes metadata and the existing Trust gate.
/// A declaration identifies a dependency; it never admits its execution.
public protocol OwnedProgramToolHost: OwnedProgramHostProfile {
    func dependencyRevision(_ dependencies: [String]) throws -> [String]
    func performReach(_ operation: String, arguments: JSONValue) async throws -> JSONValue
    func dependencyShape(_ id: String) -> JSONValue?
    func dependencyPin(_ id: String) -> String?
    func dependencyMatches(_ id: String, _ saved: JSONValue?) -> Bool
    func admitTool(_ id: String, input: [String: JSONValue]) async -> JSONValue?
    /// The canonical tool-turn owner, with the part's restricted effect host.
    func think(messages: [LLMMessage], tools: [String], surface: String?, host: any OwnedProgramHostProfile) async -> OwnedProgramThought
}

public extension OwnedProgramToolHost {
    func think(messages: [LLMMessage], tools: [String], surface: String?, host: any OwnedProgramHostProfile) async -> OwnedProgramThought {
        .init(output: .failure(SenseFailure(code: "unavailable", message: "This host has no canonical tool-turn owner.")), effects: "none")
    }
    func dependencyPin(_ id: String) -> String? {
        dependencyShape(id).flatMap { try? OwnedProgramStore.hash($0) }
    }
    func dependencyMatches(_ id: String, _ saved: JSONValue?) -> Bool {
        guard let saved, let current = dependencyShape(id) else { return false }
        return saved == current || dependencyPin(id).map(JSONValue.string) == saved
    }
}

/// Captured host replies are explicit fixtures, never a route to a live effect.
public actor OwnedProgramFixtures: OwnedProgramHostProfile {
    private nonisolated let base: any OwnedProgramHostProfile
    private let calls: [JSONValue]?
    private let decisions: Bool
    public private(set) var recorded: [JSONValue] = []
    private var next = 0
    private var faulted = false
    public init(base: any OwnedProgramHostProfile, calls: [JSONValue]?, decisions: Bool = false) {
        self.base = base; self.calls = calls; self.decisions = decisions
    }
    public var finished: Bool { !faulted && (calls == nil || next == calls?.count) }
    public var captured: Bool { decisions }
    public nonisolated var actionIDs: [String] { base.actionIDs }
    public nonisolated var floorReasons: Set<String> { base.floorReasons }
    public nonisolated var scriptKey: String { base.scriptKey }
    public nonisolated func action(_ id: String) -> OwnedProgramAction? { base.action(id) }
    public nonisolated func canonicalAction(_ id: String) -> String { base.canonicalAction(id) }
    public nonisolated func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], OwnedProgramRunner.ScriptError> {
        base.doorInput(id: id, given: given)
    }
    public nonisolated func opensHomeItem(_ input: [String: JSONValue]) -> Bool { base.opensHomeItem(input) }
    public nonisolated func secretLine(_ text: String) -> Bool { base.secretLine(text) }
    public nonisolated func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence { base.evidence(receipt) }
    public nonisolated func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? { base.receiptField(key, in: receipt) }
    public nonisolated func answer(_ receipt: JSONValue) -> JSONValue { base.answer(receipt) }
    public nonisolated func primitiveAction(_ operation: String) -> OwnedProgramAction? { base.primitiveAction(operation) }

    public func perform(_ input: [String: JSONValue]) async -> JSONValue {
        await base.validationPerform(input, fixture: self)
    }

    /// A recording reads what the program reads, through the door, and keeps
    /// each answer; an effect is intercepted and answered with its placeholder.
    /// A replay answers every call from the sealed capture.
    public func reply(_ input: [String: JSONValue]) async -> JSONValue {
        let id = input["action"]?.stringValue
        let operation = id.map { "app." + $0 } ?? (input["find"] == nil ? "read" : "find")
        let args = id == nil ? JSONValue.object(input.filter { !$0.key.hasPrefix("__") && !["preview", "expected_version"].contains($0.key) }) : input["args"] ?? .object([:])
        let options = JSONValue.object(input.filter { ["preview", "expected_version"].contains($0.key) })
        do {
            if calls != nil { return try consume(operation, arguments: args, options: options) }
            let result = reads(input) ? await base.perform(input) : Self.placeholder(operation)
            record(operation, arguments: args, result: result, options: options)
            return result
        } catch {
            return .object(["status": .string("failed"), "reason": .string("fixture_mismatch"),
                            "detail": .string(error.localizedDescription), "effects": .string("none")])
        }
    }

    public func primitive(_ operation: String, arguments: JSONValue, preview: Bool) async throws -> JSONValue {
        if let refused = await base.checkPrimitive(operation, arguments: arguments) { return refused }
        let result: JSONValue
        if calls != nil {
            let call = try consumeCall(operation, arguments: arguments)
            if let receipt = call["receipt"] { return receipt }
            result = call["result"] ?? .null
        }
        else {
            result = Self.placeholder(operation).objectValue?["result"] ?? .null
            record(operation, arguments: arguments, result: result)
        }
        return .object(["status": .string("ok"), "effects": .string("none"), "result": result,
                        "captured": .bool(result.objectValue?["captured"] == .bool(true))])
    }

    public func decide(_ question: String, data: JSONValue) throws -> JSONValue? {
        guard decisions else { return nil }
        let args: JSONValue = .object(["question": .string(question), "data": data])
        if calls != nil { return try consume("app.decide", arguments: args) }
        let answer: JSONValue = .object(["captured": .bool(true), "operation": .string("app.decide"), "answer": .null])
        record("app.decide", arguments: args, result: answer)
        return answer
    }

    private func record(_ operation: String, arguments: JSONValue, result: JSONValue, options: JSONValue = .object([:])) {
        recorded.append(.object(["operation": .string(operation), "args": arguments, "options": options, "result": result]))
    }

    /// A page read or find, or a native action whose arguments the host judges
    /// read-only, the runner's own test. A program she wrote is a run with
    /// effects of its own, never a read: a recording runs one program, the candidate.
    private nonisolated func reads(_ input: [String: JSONValue]) -> Bool {
        guard let id = input["action"]?.stringValue else { return true }
        guard let action = base.action(id), !action.program else { return false }
        return action.readOnly(input["args"]?.objectValue ?? [:])
    }

    public static func placeholder(_ operation: String) -> JSONValue {
        let result: [String: JSONValue] = ["captured": .bool(true), "operation": .string(operation)]
        return .object(["status": .string("ok"), "effects": .string("none"), "captured": .bool(true), "result": .object(result)])
    }

    public static func summary(_ fixtures: JSONValue) -> String {
        let calls = fixtures.arrayValue?.flatMap { $0.objectValue?["calls"]?.arrayValue ?? [] } ?? []
        let intercepted = calls.filter {
            let result = $0.objectValue?["result"]?.objectValue ?? [:]
            return result["captured"] == .bool(true) || result["result"]?.objectValue?["captured"] == .bool(true)
        }
        return "Rehearsed supplied input: \(calls.count - intercepted.count) data reads; \(intercepted.count) intercepted. Intercepted replies are not behavioral evidence; no other input or branch is proven."
    }

    private func consume(_ operation: String, arguments: JSONValue, options: JSONValue = .object([:])) throws -> JSONValue {
        try consumeCall(operation, arguments: arguments, options: options)["result"] ?? .null
    }

    private func consumeCall(_ operation: String, arguments: JSONValue, options: JSONValue = .object([:])) throws -> [String: JSONValue] {
        guard let calls, calls.indices.contains(next), case .object(let call) = calls[next],
              call["operation"] == .string(operation), call["args"] == arguments, call["result"] != nil else {
            faulted = true
            throw SenseFailure(code: "fixture_mismatch", message: "Declare the exact intercepted call and result for \(operation). No effect ran.")
        }
        guard (call["options"] ?? .object([:])) == options else {
            faulted = true
            throw SenseFailure(code: "fixture_mismatch", message: "The operational options for \(operation) differ from its recorded call. No effect ran.")
        }
        next += 1
        return call
    }
}

public enum OwnedProgramInvocation {
    @TaskLocal public static var host: (any OwnedProgramToolHost)?
    /// A value call pins before it waits at any gate. Presentation must retain
    /// its runner envelope, and dispatch must execute this version or refuse.
    @TaskLocal public static var valueCall: (id: String, version: String)?
}
