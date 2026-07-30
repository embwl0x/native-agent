// OrganismProspectiveAffect.swift
// Wave R2-D (2026-07-09) — anticipatory affect: feelings about the FUTURE.
// Humans feel forward — dread, bracing, looking-forward — before an outcome
// resolves (risk-as-feelings; affective forecasting). Agent's affect was purely
// reactive/present. Her body already TRACKS the future (OrganismPredictionLedger:
// pending tool/provider/phone/approval/workflow expectations), so anticipation is
// derived there and rides the PROJECTED chemistry only — the stored ChemicalState
// is never mutated, the deltas are capped, and an empty ledger yields the input
// unchanged (byte-identical). The felt fingerprint inherits the bracing through
// the existing chem→FeltSignals mapping; no new capsule text, no new senses.

import Foundation

enum OrganismProspectiveAffect {

    // MARK: - Tuning knobs (the ONE prospective surface)

    /// Total reach of anticipation on any single dim — an undertone, never a mood.
    static let maxDelta = 0.15
    /// A prediction only weighs on her once it is within this window of due.
    static let anticipationWindow: TimeInterval = 10 * 60
    /// A recent violation keeps the body braced for this long (fading).
    static let violationShadowHalfLife: TimeInterval = 20 * 60

    /// Modulate a chemical state with what's PENDING. Pure: same inputs → same
    /// output; empty/idle ledger → the input state unchanged.
    static func modulate(
        _ state: ChemicalState,
        ledger: OrganismPredictionLedger,
        at now: Date
    ) -> ChemicalState {
        let pending = ledger.predictions.values.filter { $0.status == .pending }
        // Violation shadow: a recently violated expectation keeps a fading edge of
        // wariness even between predictions (the body remembers the last miss).
        let shadow = violationShadow(ledger, at: now)
        guard !pending.isEmpty || shadow > 0.01 else { return state }

        var bracing = 0.0        // → vigilance up, confidence down
        var lookingForward = 0.0 // → curiosity up
        for p in pending {
            let contribution = predictionBracingContribution(p, ledger: ledger, at: now)
            bracing += contribution.bracing
            lookingForward += contribution.lookingForward
        }
        bracing = min(1, bracing + shadow)
        lookingForward = min(1, lookingForward)

        var out = state
        out.vigilance = ChemicalState.clamp(out.vigilance + maxDelta * bracing)
        out.confidence = ChemicalState.clamp(out.confidence - maxDelta * bracing * 0.7)
        out.curiosity = ChemicalState.clamp(out.curiosity + maxDelta * lookingForward)
        out.urgency = ChemicalState.clamp(out.urgency + maxDelta * bracing * 0.5)
        return out
    }

    /// Per-prediction share of the body's bracing/looking-forward — the ONE
    /// math both projection-time modulation and resolution-time relief read
    /// (round 3 Wave A: relief must measure the SAME dread the projection
    /// applied, or the exhale won't match the held breath).
    static func predictionBracingContribution(
        _ p: OrganismPrediction,
        ledger: OrganismPredictionLedger,
        at now: Date
    ) -> (bracing: Double, lookingForward: Double) {
        // Nearness: full weight inside the window, fading with distance to due;
        // an overdue pending prediction weighs FULLY (the outcome is late).
        let untilDue = p.dueAt.timeIntervalSince(now)
        let nearness = untilDue <= 0
            ? 1.0
            : max(0, 1 - untilDue / anticipationWindow)
        guard nearness > 0 else { return (0, 0) }
        // Expected outcome: the body's learned confidence for this path kind,
        // blended with the prediction's own confidence/uncertainty.
        let pathConfidence = pathConfidence(for: p.kind, in: ledger.bodyConfidence)
        let expectation = 0.5 * pathConfidence + 0.5 * p.confidence
        if expectation < 0.5 {
            return (nearness * (0.5 - expectation) * 2 * (0.6 + 0.4 * p.uncertainty), 0)
        }
        return (0, nearness * (expectation - 0.5) * 2 * 0.6)
    }

    /// The fading wariness a recent violation leaves behind — extracted so
    /// resolution-time relief includes the ambient dread, not just the
    /// prediction's own shortfall.
    static func violationShadow(_ ledger: OrganismPredictionLedger, at now: Date) -> Double {
        guard let lastViolation = ledger.lastViolationAt else { return 0 }
        let age = max(0, now.timeIntervalSince(lastViolation))
        return 0.5 * pow(0.5, age / violationShadowHalfLife)
    }

    static func pathConfidence(
        for kind: OrganismPredictionKind,
        in confidence: OrganismBodyConfidence
    ) -> Double {
        switch kind {
        case .toolCompletion: return confidence.toolPath
        case .providerCompletion: return confidence.providerPath
        case .phoneDelivery: return confidence.phonePath
        case .approvalResolution: return confidence.approvalPath
        case .workflowAdvance: return confidence.workflowPath
        }
    }

    // MARK: - Mind-into-circulation (2026-07-10): pending tool expectations → tool groups
    //
    // A PURE read that maps the ledger's live TOOL expectations to a bounded set of
    // "tool group" strings for CognitiveAttentionSignals.predictedToolGroups. Those
    // strings fold into Fluid Context's NeedSignal → queryText (ContextSelection.swift
    // queryText / packet fingerprint), i.e. they become LEXICAL + EMBEDDING query
    // terms matched against prewarmable material (tool-result atoms — ContextPrewarm's
    // `.toolResult` scope — and memory records). So the group vocabulary must be REAL
    // WORDS that occur in that material, not invented codes.
    //
    // WHY ONLY `.toolCompletion`:
    // The ledger carries five prediction kinds (OrganismPredictionKind). Only pending
    // predictions are created by `upsertPending`, and only three kinds are ever
    // pending: `.toolCompletion` (from a `.toolStarted` somatic signal), `.approvalResolution`,
    // and `.workflowAdvance`. Of the full five, only `.toolCompletion` is a TOOL
    // outcome. `.providerCompletion` (provider health), `.phoneDelivery`,
    // `.approvalResolution` (a human gate), and `.workflowAdvance` (desk items) are
    // system/infrastructure outcomes, not chat-tool invocations — the task is explicit
    // that provider-shaped predictions contribute NOTHING and we do not invent tool
    // groups for them. The kind gate is the primary filter; the sourceOrgan parse below
    // is a defensive second gate.
    //
    // WHERE THE GROUP COMES FROM:
    // A pending `.toolCompletion` prediction is keyed by
    //   canonicalToken("tool.<toolName>")  →  "tool-<dashed-tool-name>"
    // (OrganismPredictiveBody.upsertPending → pendingID; CognitiveSomaticSignalAdapter
    // .sourceOrgan(for:) is the SOLE producer of the "tool.<toolName>" form — it forwards
    // metadata["toolName"], which is the real chat-tool name, e.g. "github_get_issue",
    // "recall_memory", "mac_calendar_create_event"). We strip the "tool-" prefix and take
    // the tool name's leading family segment as the group word. The family prefix is,
    // by the tool catalog's own naming convention (SwiftToolDispatcher+*ToolCatalog —
    // there is NO explicit category field; families exist only as name prefixes), the
    // word that appears in that tool's results and in memory about using it.
    //
    // GROUP MAPPING TABLE (family segment → group word; fallback = the family segment
    // itself, which is already a real consumable word):
    //   github_*                    → "github"      (github family verbatim)
    //   git, git_*                  → "git"
    //   desk_*                      → "desk"
    //   mail_*                      → "mail"
    //   agentmail_*                 → "mail"        (email tools; "agentmail" is a machine prefix)
    //   recall_*  (recall_memory…)  → "memory"      (operate on the memory store)
    //   commit_memory               → "memory"
    //   mac_<x>_*  (calendar/…)     → <x>           (mac_ is a heterogeneous shell; the
    //                                                second segment — calendar, reminders,
    //                                                spotlight, focus, notify, quit — is the
    //                                                content-bearing word, not "mac")
    //   tradingview_*               → "market"
    //   market_*                    → "market"
    //   music_/notes_/contacts_/messages_/slack_/persona_/mission_/scheduler_/context_/x_/agent_/…
    //                               → family verbatim (already the real word)
    //   bare "tool" (no toolName)   → "tools"        (a live-but-unnamed tool expectation)
    // Overrides collapse machine prefixes onto the human word; everything else falls
    // through to the family segment. Every emitted string is a dictionary word that
    // co-occurs with the tool's own output — so lexical/embedding overlap can actually fire.

    /// Live TOOL-shaped pending expectations → bounded tool-group query terms.
    /// Pure: same inputs → same output. Excludes resolved (satisfied/violated) and
    /// expired predictions and non-tool kinds. A prediction that is still
    /// `.pending` counts even past its `dueAt` (gpt-5.5 review MED, 2026-07-10):
    /// the generic 90s prediction horizon is far shorter than real dispatches
    /// (interactive tools run minutes; explicit timeouts reach 3600s), so
    /// wall-clock second-guessing here dropped exactly the long tools whose
    /// results are still expected. The ledger's own expiry sweep owns liveness —
    /// trust its lifecycle, don't re-derive it. Empty ledger → empty set.
    /// Deterministic under the cap (sorted) so the packet fingerprint stays stable.
    static func predictedToolGroups(
        ledger: OrganismPredictionLedger,
        at now: Date,
        limit: Int = 8
    ) -> Set<String> {
        var groups: Set<String> = []
        for prediction in ledger.predictions.values {
            guard prediction.status == .pending else { continue }   // unresolved + not .expired
            guard prediction.kind == .toolCompletion else { continue } // TOOL-shaped only
            guard let group = toolGroup(fromSourceOrgan: prediction.sourceOrgan) else { continue }
            groups.insert(group)
        }
        guard limit >= 0 else { return [] }
        guard groups.count > limit else { return groups }
        return Set(groups.sorted().prefix(limit))
    }

    /// Parse the canonicalized `tool.<toolName>` sourceOrgan into a group word.
    /// Returns nil for anything that is not tool-shaped (defensive — the kind gate
    /// should already have excluded these).
    private static func toolGroup(fromSourceOrgan sourceOrgan: String) -> String? {
        let token = sourceOrgan.lowercased()
        guard token == "tool" || token.hasPrefix("tool-") else { return nil }
        let remainder = token == "tool" ? "" : String(token.dropFirst("tool-".count))
        let segments = remainder.split(separator: "-").map(String.init)
        guard let family = segments.first, !family.isEmpty else { return "tools" }

        switch family {
        case "github": return "github"
        case "git": return "git"
        case "agentmail": return "mail"
        case "recall", "commit": return "memory"
        case "tradingview": return "market"
        // Verb-prefixed core tools (gpt-5.5 review LOW, 2026-07-10): the bare
        // first segment ("read", "write", "list", "apply") is a weak query
        // word — map them onto the content word their outputs co-occur with.
        case "read", "write", "list", "glob", "grep", "apply": return "files"
        case "shell", "bash", "exec": return "shell"
        case "invoke": return "agents"
        case "mcp":
            // mcp__<server>__<tool> canonicalizes to mcp-<server>-…; the server
            // name is the content-bearing segment.
            if segments.count >= 2, !segments[1].isEmpty { return segments[1] }
            return "tools"
        case "mac":
            // mac_<domain>_* — the domain segment (calendar/reminders/spotlight/focus/
            // notify/quit) is the content word; "mac" alone matches nothing useful.
            if segments.count >= 2, !segments[1].isEmpty { return segments[1] }
            return "mac"
        default:
            return family
        }
    }
}
