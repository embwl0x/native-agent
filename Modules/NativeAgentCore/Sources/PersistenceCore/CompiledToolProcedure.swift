import Foundation

// MARK: - Procedural lane: a repeated tool sequence compiled (sweep item 38)
//
// The Wave-10 lane above compiles ONE reviewed artifact (`local_file_copy_v1`)
// from richly-instrumented Workshop/GitHub trajectories, and its compiler
// deliberately refuses to run before a reviewer decision exists. The
// procedural memory lane needs the mirror image: a compiled procedure minted
// BEFORE the card, because the card's whole content is that procedure plus a
// draft skill body. So it reuses the SHAPES here — the transition table, the
// input contract, the safety declaration, the opaque-identity digest — and
// mints its own artifact schema instead of forcing a second product role and
// two more oracle cases through `DeclarativeProcedureCompiler`.
//
// Everything here is payload-free by construction: a step carries a tool name
// and its ARGUMENT KEYS, never an argument value. Nothing in this type ever
// enters a prompt (NORTHSTAR clause 6); it is card content and, after the
// owner approves, a skill body on disk plus one recall pointer row.

/// Where one step of a repeated sequence came from.
public enum ProceduralStepOrigin: String, Codable, Sendable, Equatable {
    /// A tool dispatch that succeeded, as projected by the turn evidence lane.
    case tool
    /// A motor action that reached a verified terminal phase. Reserved for the
    /// `(bundle_id, verb, target_role, verification)` tuple — see
    /// `ProceduralMotorStep`.
    case motor
}

/// One step of a repeated procedure. Payload-free: the tool's identity and the
/// SHAPE of its arguments, never their values.
public struct ProceduralStepShape: Codable, Sendable, Equatable, Hashable {
    public let origin: ProceduralStepOrigin
    /// Tool name, or `"<bundle_id>:<verb>"` for a motor step.
    public let action: String
    /// Sorted argument keys (tool) or `[target_role]` (motor). Never values.
    public let argumentKeys: [String]
    /// How the step's success was established. `"tool_result_succeeded"` for
    /// the evidence lane; the motor read model's verification state for motor.
    public let verificationClass: String

    public init(
        origin: ProceduralStepOrigin,
        action: String,
        argumentKeys: [String],
        verificationClass: String
    ) {
        self.origin = origin
        self.action = action
        self.argumentKeys = argumentKeys.sorted()
        self.verificationClass = verificationClass
    }

    /// The step's contribution to the sequence identity. Two runs are "the
    /// same ordered sequence with compatible arg shapes" exactly when every
    /// step's `shapeMaterial` matches in order.
    public var shapeMaterial: String {
        [origin.rawValue, action, argumentKeys.joined(separator: "+"), verificationClass]
            .joined(separator: "|")
    }
}

/// A repeated, verified tool sequence compiled into a declarative procedure.
///
/// `id` is the dedupe key: identical sequence shape + identical evidence
/// aggregate ⇒ identical digest ⇒ the lane refuses to mint a second proposal.
public struct CompiledToolProcedure: Codable, Sendable, Equatable, Identifiable {
    public static let schema = "procedural-lane-tool-sequence.v1"

    public let schema: String
    public let id: String
    /// Digest of the ordered step shapes alone — stable across further
    /// repeats, which is what makes "≤ 1 proposal per n-gram" enforceable
    /// after the occurrence count has moved on.
    public let sequenceIdentity: String
    public let steps: [ProceduralStepShape]
    /// The Wave-10 transition-table shape, one rule per step.
    public let transitionTable: [ProcedureTransitionRule]
    public let inputContract: ProcedureInputContract
    public let safety: ProcedureSafetyDeclaration
    public let occurrenceCount: Int
    /// Distinct `yyyy-MM-dd` days (UTC) the sequence was observed on, sorted.
    public let observedDays: [String]
    public let verifiedSuccessCount: Int
    public let deterministicAbandonConditions: [String]
    /// Always false. This lane compiles a DESCRIPTION of a procedure for a
    /// human-approved skill body; it never emits executable code.
    public let generatedExecutableCode: Bool

    public var distinctDayCount: Int { observedDays.count }

    /// Deterministic, file-safe skill name. Derived from the first and last
    /// action plus a short digest so the same sequence always lands on the
    /// same body path (idempotent approval), and two different sequences over
    /// the same two tools never collide.
    public var suggestedSkillName: String {
        let parts = [steps.first?.action, steps.count > 1 ? steps.last?.action : nil]
            .compactMap { $0 }
            .map(Self.slug)
            .filter { !$0.isEmpty }
        let stem = parts.isEmpty ? "sequence" : parts.joined(separator: "-then-")
        return "learned-\(String(stem.prefix(48)))-\(String(sequenceIdentity.prefix(8)))"
    }

    static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// The human-readable draft the approval card shows verbatim and the
    /// approved card writes to disk. House style: heading + "Use when" hook +
    /// steps + verification + the evidence that earned it.
    ///
    /// Passes `SkillBodyHygiene` by construction (markdown heading first, at
    /// least one non-heading line, none of the banned legacy terms), because a
    /// body that fails hygiene gets no recall pointer — an approved card whose
    /// craft never arrives.
    public func draftSkillBody() -> String {
        let actions = steps.map(\.action)
        let opening = actions.count == 1
            ? "`\(actions[0])`"
            : actions.map { "`\($0)`" }.joined(separator: " → ")
        var lines: [String] = []
        lines.append("# \(suggestedSkillName)")
        lines.append("")
        lines.append(
            "Use when a request calls for the same run of work this sequence "
            + "keeps doing: \(opening)."
        )
        lines.append("")
        lines.append("## Steps")
        for (index, step) in steps.enumerated() {
            let arguments = step.argumentKeys.isEmpty
                ? "no recorded arguments"
                : "arguments: \(step.argumentKeys.joined(separator: ", "))"
            lines.append("\(index + 1). `\(step.action)` — \(arguments).")
        }
        lines.append("")
        lines.append("## Verification")
        lines.append(
            "Every recorded run of this sequence ended in a verified success; "
            + "treat a step that does not verify as a reason to stop and think "
            + "rather than to continue the sequence."
        )
        lines.append("")
        lines.append("## Why this is here")
        lines.append(
            "Observed \(occurrenceCount) times across \(distinctDayCount) days "
            + "(\(observedDays.joined(separator: ", "))). Recorded from what "
            + "already worked; it is a starting shape, not a rule."
        )
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum ProceduralProcedureCompiler {
    /// Conditions under which a run of this shape should be abandoned rather
    /// than pushed through. Mirrors the Wave-10 vocabulary minus the ones that
    /// only mean something to a canonical executor.
    public static let deterministicAbandonConditions = [
        "input_schema_novel",
        "precondition_failed",
        "step_verification_failed",
        "trust_center_denied",
    ]

    /// The identity of a sequence SHAPE, independent of how much evidence has
    /// accrued behind it. The one dedupe key: the lane's ledger, the durable
    /// already-proposed set, and the filed card all name a sequence with this
    /// string, so "≤ 1 proposal per n-gram" means the same thing in all three.
    ///
    /// Deliberately NOT `CompiledToolProcedure.id`, whose digest folds in
    /// `occurrenceCount` and `observedDays` — the same sequence seen once more,
    /// or on one more day, mints a different `id` and would dedupe against
    /// nothing.
    public static func sequenceIdentity(for steps: [ProceduralStepShape]) -> String {
        CausalTransitionEvidence.opaqueIdentity(
            CompiledToolProcedure.schema + "||"
                + steps.map(\.shapeMaterial).joined(separator: ">")
        )
    }

    /// Compile a repeated sequence. Pure and total: given the same steps and
    /// the same evidence aggregate it always returns the same digest.
    public static func compile(
        steps: [ProceduralStepShape],
        occurrenceCount: Int,
        observedDays: [String],
        verifiedSuccessCount: Int
    ) -> CompiledToolProcedure {
        let days = Array(Set(observedDays)).sorted()
        let sequenceIdentity = Self.sequenceIdentity(for: steps)
        let table = steps.enumerated().map { index, step in
            ProcedureTransitionRule(
                sequence: index,
                beforeState: index == 0 ? "start" : "step_\(index)",
                onTransitionKind: step.origin == .motor ? "motor_action" : "tool_dispatch",
                actionKind: step.action,
                requiredEvidenceKind: step.argumentKeys.isEmpty
                    ? "no_arguments"
                    : "argument_keys:\(step.argumentKeys.joined(separator: "+"))",
                expectedNextEvidence: index + 1 < steps.count
                    ? steps[index + 1].action
                    : "terminal",
                checkpointClass: nil,
                externalEffectClass: step.origin == .motor ? "motor_effect" : "tool_effect",
                afterState: index + 1 < steps.count ? "step_\(index + 1)" : "done",
                verificationClass: step.verificationClass,
                terminalClass: index + 1 == steps.count ? .verifiedSuccess : nil
            )
        }
        let contract = ProcedureInputContract(
            taskFamily: "repeated_tool_sequence",
            inputClass: "observed_turn_evidence",
            parameterSchemaClass: "argument_keys_only",
            acceptedParameterSchemaIdentities: [sequenceIdentity],
            allowedExternalEffectClasses: Array(
                Set(table.map(\.externalEffectClass))
            ).sorted()
        )
        // A skill body is a description, not an authority. Every flag that
        // could turn this into an actor is off, and stays off: approval mints
        // a body and a recall pointer, never an activation.
        let safety = ProcedureSafetyDeclaration(
            trustCenterCapability: "none",
            requiredPreconditions: ["owner_approved_skill_body"],
            recheckPoints: [.beforeInvocation],
            canonicalApprovalOwner: "approval_inbox",
            externalSendsEligible: false,
            permissionAuthority: false,
            automaticActivationAllowed: false
        )
        let evidenceMaterial = [
            sequenceIdentity,
            String(occurrenceCount),
            String(verifiedSuccessCount),
            days.joined(separator: ","),
        ].joined(separator: "||")
        return CompiledToolProcedure(
            schema: CompiledToolProcedure.schema,
            id: CausalTransitionEvidence.opaqueIdentity(evidenceMaterial),
            sequenceIdentity: sequenceIdentity,
            steps: steps,
            transitionTable: table,
            inputContract: contract,
            safety: safety,
            occurrenceCount: occurrenceCount,
            observedDays: days,
            verifiedSuccessCount: verifiedSuccessCount,
            deterministicAbandonConditions: deterministicAbandonConditions,
            generatedExecutableCode: false
        )
    }
}

extension CompiledToolProcedure {
    /// Public JSON round-trip. The synthesized `Codable` members are
    /// module-internal, so callers in other modules (the lane in MemoryV2, the
    /// approval executor in the app) go through these instead of reaching for
    /// a decoder they cannot reach.
    public var jsonValue: JSONValue {
        guard let data = try? JSONEncoder().encode(self),
              let value = try? JSONValue.parse(data) else {
            return .null
        }
        return value
    }

    public init?(jsonValue: JSONValue) {
        guard case .object = jsonValue,
              let data = try? jsonValue.serializedData(pretty: false),
              let decoded = try? JSONDecoder().decode(CompiledToolProcedure.self, from: data),
              decoded.schema == CompiledToolProcedure.schema else {
            return nil
        }
        self = decoded
    }
}
