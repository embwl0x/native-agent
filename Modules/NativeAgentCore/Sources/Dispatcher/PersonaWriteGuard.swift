import Foundation

// MARK: - Dynamic persona-write guard (W3 dispatcher pre-flip prereq #12)
//
// Wave 31 W17. Standalone Swift mirror of the dynamic persona-write guard
// the Python dispatcher applies in `Dispatcher.run` at
// the retired daemon (W32 W06 + W33 W06 canonicalization fixes):
//
//     if autonomy_override is None and resolved.autonomy == AutonomyLevel.AUTO:
//         persona_kind = unicodedata.normalize("NFKC", str(input_dict.get("kind") or "")).strip().lower()
//         if (
//             (tool_name == "persona_write" and persona_kind in {"soul", "voice", "agents", "skill"})
//             or (tool_name == "persona_append_section" and persona_kind in {"soul", "voice", "agents"})
//         ):
//             resolved = ResolvedPolicy(
//                 ...,
//                 autonomy=AutonomyLevel.CONFIRM,
//                 autonomy_source="dynamic_persona_guard",
//             )
//
// WHY THIS IS A SEPARATE LAYER (CUTOVER_PLAN.md §6.30 prereq #12):
// The generic unified-policy resolver (`resolve_effective_policy`) decides
// autonomy per-TOOL. It does NOT inspect the *kind* argument, so under a
// permissive trust policy a `persona_write{kind:"soul"}` could resolve to
// AUTO and silently rewrite the persona's core identity documents without a
// confirm step. This guard re-reads the input `kind` AFTER policy resolution
// and forces CONFIRM for the identity-bearing persona surfaces, regardless of
// what the per-tool policy said. It is a one-way RATCHET: it only ever tightens
// AUTO→CONFIRM, never loosens, and only fires when the caller did NOT pass an
// explicit per-call `autonomy_override` (an explicit override is the operator
// already speaking; the guard does not second-guess it).
//
// SCOPE / DORMANCY: the Swift `Dispatcher` module is still a DORMANT-PROXY for
// execution (see Dispatcher.swift header + CUTOVER_PLAN.md §6.11/§6.30) — the
// native unified-policy resolver (`resolve_effective_policy`) is NOT yet ported
// (that is prereqs #1-#11 in the §6.30 list). This file ports ONLY the guard
// predicate, as a pure function with no side effects, so it is ready to slot
// into the native resolver the moment that lands. It mutates nothing and is
// not yet wired into the proxy run() path (where autonomy is decided by the
// daemon's authoritative receipt). Its presence + tests close prereq #12's
// "confirm Swift mirrors it before any persona-touching tool goes native".
//
// PARITY NOTES (must stay byte-equivalent to the Python set above):
//   * `persona_write` guards {soul, voice, agents, skill}  (4 kinds).
//   * `persona_append_section` guards {soul, voice, agents} (3 kinds —
//     deliberately NO "skill"; the daemon's append tool refuses skill bodies,
//     see the retired daemon persona_append_section doc).
//   * `kind` is NFKC-normalized, THEN stripped, THEN lower-cased before
//     comparison (Python `normalize("NFKC", ...).strip().lower()`, W32 W06 +
//     W33 W06); a nil/empty (or all-whitespace) kind never matches. The strip
//     is load-bearing (the executors strip too, so " soul" must NOT bypass the
//     guard) and so is NFKC (the executors NFKC-fold too, so the fullwidth
//     confusable "ＳＯＵＬ" must NOT bypass the guard while still resolving to a
//     protected doc).
//   * The guard ONLY applies when the *incoming* resolved autonomy is exactly
//     "auto". Anything else (already "confirm"/"block"/etc.) passes through
//     untouched — the ratchet never downgrades.

/// Pure decision function: given the tool, the input `kind` argument, the
/// already-resolved autonomy string ("auto"/"confirm"/"block"/...), and
/// whether the caller passed an explicit per-call autonomy override, decide
/// whether the dynamic persona-write guard upgrades the autonomy to "confirm".
///
/// Returns `true` only in the exact cases the Python dispatcher upgrades.
/// Callers that get `true` MUST set the resolved autonomy to "confirm" and the
/// autonomy source to `PersonaWriteGuard.autonomySource`.
public enum PersonaWriteGuard {

    /// The `autonomy_source` tag the Python dispatcher stamps on an upgraded
    /// policy. Mirror it exactly so downstream
    /// receipts / trace observers see the identical provenance string.
    public static let autonomySource: String = "dynamic_persona_guard"

    /// The autonomy level the guard upgrades *from*. Mirrors
    /// `AutonomyLevel.AUTO.value` ("auto").
    public static let triggeringAutonomy: String = "auto"

    /// The autonomy level the guard upgrades *to*. Mirrors
    /// `AutonomyLevel.CONFIRM.value` ("confirm").
    public static let upgradedAutonomy: String = "confirm"

    /// Persona `kind` values guarded for the `persona_write` tool.
    /// Parity: the retired daemon — {"soul", "voice", "agents", "skill"}.
    public static let personaWriteGuardedKinds: Set<String> = ["soul", "voice", "agents", "skill"]

    /// Persona `kind` values guarded for the `persona_append_section` tool.
    /// Parity: the retired daemon — {"soul", "voice", "agents"} (NO "skill").
    public static let personaAppendGuardedKinds: Set<String> = ["soul", "voice", "agents"]

    /// True when the guard should upgrade the resolved autonomy to "confirm".
    ///
    /// - Parameters:
    ///   - tool: the dispatch tool name (e.g. "persona_write").
    ///   - kind: the input `kind` argument, raw (may be nil / mixed-case).
    ///   - resolvedAutonomy: the autonomy string the unified policy resolver
    ///     produced for this tool (e.g. "auto").
    ///   - hasExplicitAutonomyOverride: whether the caller passed an explicit
    ///     per-call autonomy override. When true the guard NEVER fires
    ///     (mirrors `autonomy_override is None` in Python).
    /// - Returns: `true` iff the guard upgrades AUTO→CONFIRM.
    public static func shouldUpgradeToConfirm(
        tool: String,
        kind: String?,
        resolvedAutonomy: String,
        hasExplicitAutonomyOverride: Bool
    ) -> Bool {
        // Mirror: `autonomy_override is None and resolved.autonomy == AUTO`.
        guard !hasExplicitAutonomyOverride else { return false }
        guard resolvedAutonomy == triggeringAutonomy else { return false }

        // W32 W06 (prereq #12 re-close) / W33 W06: canonicalize IDENTICALLY to
        // the Python dispatcher guard's `unicodedata.normalize("NFKC", kind)
        // .strip().lower()` and the executors' matching
        // NFKC+strip+lower acceptance test.
        //
        // W32 closed the whitespace divergence (" soul" must not bypass). W33
        // adds NFKC: `.lowercased()` does NOT fold Unicode compatibility forms,
        // so the fullwidth confusable "ＳＯＵＬ" (U+FF33…) would lower-case to the
        // still-fullwidth "ｓｏｕｌ" — missing the guarded set on both sides. NFKC
        // folds fullwidth → ASCII so it canonicalizes to "soul", staying in
        // lock-step with the Python guard + executors.
        //
        // IMPORTANT: use `precomposedStringWithCompatibilityMapping` (= NFKC),
        // NOT `precomposedStringWithCanonicalMapping` (= NFC). NFC does NOT fold
        // fullwidth/compatibility codepoints (verified empirically: NFC leaves
        // "ＳＯＵＬ" → "ｓｏｕｌ"), so only the compatibility mapping matches Python's
        // `normalize("NFKC", ...)`. `.whitespacesAndNewlines` already trims
        // NBSP / ideographic / narrow-NBSP (matches Python str.strip()), so the
        // trim side is unchanged.
        let normalizedKind = (kind ?? "")
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedKind.isEmpty else { return false }

        switch tool {
        case "persona_write":
            return personaWriteGuardedKinds.contains(normalizedKind)
        case "persona_append_section":
            return personaAppendGuardedKinds.contains(normalizedKind)
        default:
            return false
        }
    }

    /// Convenience that applies the guard to an already-resolved autonomy
    /// string, returning the (possibly upgraded) autonomy plus the source tag
    /// to stamp. When the guard does not fire, returns the inputs unchanged.
    ///
    /// - Returns: a tuple of the effective autonomy string and the autonomy
    ///   source. When upgraded, source == `autonomySource`; otherwise the
    ///   caller's existing source should be preserved (this helper returns
    ///   `nil` for source when it did not upgrade, so the caller keeps its own).
    public static func apply(
        tool: String,
        kind: String?,
        resolvedAutonomy: String,
        hasExplicitAutonomyOverride: Bool
    ) -> (autonomy: String, source: String?) {
        if shouldUpgradeToConfirm(
            tool: tool,
            kind: kind,
            resolvedAutonomy: resolvedAutonomy,
            hasExplicitAutonomyOverride: hasExplicitAutonomyOverride
        ) {
            return (upgradedAutonomy, autonomySource)
        }
        return (resolvedAutonomy, nil)
    }
}
