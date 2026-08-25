import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger fence core.substrate.organism — organism.posture.toolResultJSON
//
// `OrganismBehaviorPosture.toolResultJSON(tool:surface:)` is the object the app
// dispatcher attaches under `organism_posture` on EVERY tool result. Two silent
// failures live here:
//
//  (a) DROPPED ROW — the key is additive, so if the shape changes (a renamed or
//      dropped key) tool results still succeed and nothing in this fence notices.
//      Fixed by asserting the key SET as a frozen contract in both directions.
//
//  (b) LEAK — the private posture text (`privateRuntimeContext`) is explicitly
//      "follow it silently; never quote these labels". The tool-result object is
//      model-visible. Directives, review signals, and reflex-bias PATTERNS must
//      cross as COUNTS only, and raw chemistry must not cross at all. Nothing
//      asserted that; a future edit that swaps `directive_count` for the
//      directives array would ship silently.

private let postureContractKeys: Set<String> = [
    "posture",
    "tool_claims",
    "tool_strategy",
    "loop_budget",
    "notification_requires_receipt",
    "tool",
    "surface",
    "directive_count",
    "review_signal_count",
    "review_required_reflex_count",
    "approved_low_risk_reflex_total_count",
    "approved_reflex_bias_sample_count",
    "approved_reflex_biases_are_sampled",
]

/// Sentinels planted in every free-text field. None of them may appear anywhere
/// in the serialized tool-result object.
private let directiveSentinel = "DIRECTIVE-SENTINEL-must-not-cross"
private let reviewSignalSentinel = "REVIEW-SIGNAL-SENTINEL-must-not-cross"
private let reflexBiasSentinel = "REFLEX-BIAS-SENTINEL-must-not-cross"

private func sentinelPosture() -> OrganismBehaviorPosture {
    OrganismBehaviorPosture(
        generatedAt: Date(timeIntervalSince1970: 1_766_000_000),
        enabled: true,
        posture: "careful",
        claimDiscipline: .verifyBeforeCompletion,
        toolStrategy: .preferKnownPath,
        loopBudget: .conserve,
        notificationRequiresReceipt: true,
        directives: ["\(directiveSentinel) one", "\(directiveSentinel) two"],
        reviewSignals: ["\(reviewSignalSentinel) alpha"],
        approvedReflexBiases: ["\(reflexBiasSentinel) pattern"],
        reviewRequiredReflexCount: 7,
        approvedLowRiskReflexTotalCount: 9
    )
}

@Test
func organismPostureToolResultCarriesExactlyTheContractualKeys() throws {
    let json = sentinelPosture().toolResultJSON(tool: "read_file", surface: "chat")
    guard case .object(let object) = json else {
        Issue.record("organism_posture payload is not a JSON object")
        return
    }
    let live = Set(object.keys)
    #expect(
        live == postureContractKeys,
        """
        organism_posture key set changed. \
        added: \(live.subtracting(postureContractKeys).sorted()); \
        removed: \(postureContractKeys.subtracting(live).sorted())
        """
    )
    // The dispatcher's own addressing must round-trip: a consumer keys off these.
    #expect(object["tool"] == .string("read_file"))
    #expect(object["surface"] == .string("chat"))
}

@Test
func organismPostureToolResultCrossesCountsNotPrivateText() throws {
    let posture = sentinelPosture()
    let json = posture.toolResultJSON(tool: "read_file", surface: "chat")

    // Serialize the WHOLE object and grep it — this catches a leak at any depth,
    // not just at the keys the contract test enumerates.
    let text = try json.serialize(pretty: false)
    #expect(!text.contains(directiveSentinel), "a directive's raw text crossed into the tool result")
    #expect(!text.contains(reviewSignalSentinel), "a review signal's raw text crossed into the tool result")
    #expect(!text.contains(reflexBiasSentinel), "a reflex bias pattern crossed into the tool result")

    // Non-vacuous: the private context DOES carry that same text, so the
    // sentinels are genuinely present in the posture and the greps above are
    // testing a real separation rather than empty fields.
    let priv = posture.privateRuntimeContext(
        runId: "run-1", sessionId: "session-1", surface: "chat", fileAccess: "read"
    )
    #expect(priv.contains(directiveSentinel))
    #expect(priv.contains(reviewSignalSentinel))
    #expect(priv.contains(reflexBiasSentinel))

    // The counts that replace the text are the real counts, not zeros.
    guard case .object(let object) = json else {
        Issue.record("organism_posture payload is not a JSON object")
        return
    }
    #expect(object["directive_count"] == .int(Int64(posture.directives.count)))
    #expect(object["review_signal_count"] == .int(Int64(posture.reviewSignals.count)))
    #expect(object["approved_reflex_bias_sample_count"] == .int(Int64(posture.approvedReflexBiases.count)))
    #expect(object["directive_count"] != .int(0))
}

@Test
func organismPostureToolResultNeverLeaksRawChemistryNumbers() throws {
    // A posture derived from a real, strongly-coloured snapshot: if any chemistry
    // axis leaked, the axis NAME would have to appear as a key.
    let snapshot = postureProbeSnapshot()
    let posture = try #require(OrganismBehaviorPosture.from(snapshot: snapshot))
    guard case .object(let object) = posture.toolResultJSON(tool: "run_shell", surface: "telegram") else {
        Issue.record("organism_posture payload is not a JSON object")
        return
    }
    let forbidden = [
        "warmth", "vigilance", "curiosity", "fatigue", "coherence",
        "agency", "tenderness", "confidence", "novelty", "urgency",
        "chemistry", "chemicalState",
    ]
    for name in forbidden {
        #expect(
            object[name] == nil,
            "raw chemistry axis `\(name)` crossed into the model-visible tool result"
        )
    }
    // Still the same frozen shape when built from a real snapshot, not just from
    // the hand-made fixture above.
    #expect(Set(object.keys) == postureContractKeys)
    // The summary is not a constant: a body under critical resource pressure
    // with high fatigue must NOT report a normal loop budget, and a neutral body
    // must — otherwise every tool result carries the same reassuring string.
    #expect(object["loop_budget"] != .string(OrganismLoopBudget.normal.rawValue))
    var calm = postureProbeSnapshot()
    calm.chemicalState = .neutral
    calm.bodySchema = .neutral
    let calmPosture = try #require(OrganismBehaviorPosture.from(snapshot: calm))
    guard case .object(let calmObject) = calmPosture.toolResultJSON(tool: "run_shell", surface: "telegram") else {
        Issue.record("organism_posture payload is not a JSON object")
        return
    }
    #expect(calmObject["loop_budget"] == .string(OrganismLoopBudget.normal.rawValue))
    #expect(calmObject["posture"] != object["posture"], "a stressed and a calm body render the same posture word")
}

/// A disabled body has NO posture at all — `from(snapshot:)` returns nil rather
/// than a calm-looking default. That distinction is what keeps an absent body
/// from reading as a normal one downstream.
@Test
func disabledOrganismYieldsNoPostureRatherThanACalmLookingOne() {
    var snapshot = postureProbeSnapshot()
    snapshot.enabled = false
    #expect(OrganismBehaviorPosture.from(snapshot: snapshot) == nil)
    #expect(OrganismBehaviorPosture.from(snapshot: postureProbeSnapshot()) != nil)
}

private func postureProbeSnapshot() -> OrganismSnapshot {
    var chemistry = ChemicalState.neutral
    chemistry.fatigue = 0.8       // ⇒ conserving posture + conserve loop budget
    chemistry.vigilance = 0.7
    var body = BodySchema.neutral
    body.resourcePressure = .critical
    return OrganismSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_766_000_000),
        enabled: true,
        chemicalState: chemistry,
        bodySchema: body,
        signalCount: 1_234,
        lastSignalAt: Date(timeIntervalSince1970: 1_766_000_000)
    )
}
