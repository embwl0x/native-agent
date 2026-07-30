import Foundation
import Testing
@testable import Dispatcher

// MARK: - Wave 31 W17: dynamic persona-write guard parity tests
//
// Pins the Swift PersonaWriteGuard predicate to the Python dispatcher guard at
// the retired daemon. Each case below maps to a branch of that
// block. The guard is a one-way AUTO→CONFIRM ratchet that only fires when the
// caller passed no explicit autonomy override.

@Suite("PersonaWriteGuard parity with daemon/dispatcher.py:1098-1111")
struct PersonaWriteGuardTests {

    // MARK: persona_write — the 4 guarded kinds upgrade

    @Test("persona_write soul/voice/agents/skill upgrade AUTO→CONFIRM")
    func personaWriteGuardedKindsUpgrade() {
        for kind in ["soul", "voice", "agents", "skill"] {
            #expect(
                PersonaWriteGuard.shouldUpgradeToConfirm(
                    tool: "persona_write",
                    kind: kind,
                    resolvedAutonomy: "auto",
                    hasExplicitAutonomyOverride: false
                ),
                "persona_write{\(kind)} must upgrade"
            )
        }
    }

    @Test("persona_write kind is case-insensitive (Python .lower())")
    func personaWriteCaseInsensitive() {
        #expect(PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: "persona_write", kind: "SOUL",
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false))
        #expect(PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: "persona_write", kind: "Voice",
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false))
    }

    // MARK: W32 W06 — whitespace-padded kinds must NOT bypass the guard
    //
    // The pre-fix guard canonicalized with lower-only (no strip), while the
    // Python executors (_exec_persona_write / _exec_persona_append_section)
    // canonicalize with strip+lower. That divergence let a kind like " soul"
    // slip past the guard (the lower-only form " soul" is not in the guarded
    // set) while the executor's strip still resolved it to SOUL.md — a silent
    // AUTO write of the core identity doc. These cases pin the strip so the
    // exploit can never regress on the Swift side.

    @Test("persona_write whitespace-padded guarded kinds STILL upgrade (exploit closed)")
    func personaWriteWhitespacePaddedStillUpgrades() {
        // Each of these would have BYPASSED the pre-W32-W06 lower-only guard.
        let exploitInputs = [
            " soul",        // leading space
            "soul ",        // trailing space
            " soul ",       // both
            "\tsoul",       // leading tab
            "soul\n",       // trailing newline
            "  Voice  ",    // mixed case + padding
            "\tAGENTS\t",   // tab-padded uppercase
            " skill ",      // padded skill
        ]
        for kind in exploitInputs {
            #expect(
                PersonaWriteGuard.shouldUpgradeToConfirm(
                    tool: "persona_write",
                    kind: kind,
                    resolvedAutonomy: "auto",
                    hasExplicitAutonomyOverride: false
                ),
                "persona_write{\(kind.debugDescription)} (whitespace-padded) MUST upgrade — exploit input"
            )
        }
    }

    @Test("persona_append_section whitespace-padded guarded kinds STILL upgrade")
    func personaAppendWhitespacePaddedStillUpgrades() {
        for kind in [" soul", "voice ", " AGENTS ", "\tvoice\n"] {
            #expect(
                PersonaWriteGuard.shouldUpgradeToConfirm(
                    tool: "persona_append_section",
                    kind: kind,
                    resolvedAutonomy: "auto",
                    hasExplicitAutonomyOverride: false
                ),
                "persona_append_section{\(kind.debugDescription)} MUST upgrade — exploit input"
            )
        }
    }

    @Test("all-whitespace kind never matches (canonicalizes to empty)")
    func allWhitespaceKindNeverMatches() {
        for kind in ["   ", "\t", "\n", " \t\n "] {
            #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
                tool: "persona_write", kind: kind,
                resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false),
                "all-whitespace kind \(kind.debugDescription) must canonicalize to empty and not match")
        }
    }

    @Test("persona_append_section whitespace-padded skill STILL excluded (parity)")
    func personaAppendWhitespacePaddedSkillNotGuarded() {
        // strip must not accidentally promote " skill " into the append set —
        // skill is excluded for append regardless of padding.
        for kind in [" skill", "skill ", " skill ", "\tSKILL\t"] {
            #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
                tool: "persona_append_section", kind: kind,
                resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false),
                "persona_append_section{\(kind.debugDescription)} must NOT upgrade (skill excluded)")
        }
    }

    // MARK: W33 W06 — NFKC normalization (Unicode confusables must not bypass)
    //
    // The pre-W33 guard canonicalized with `.strip().lower()` only. `.lower()`
    // does NOT fold Unicode compatibility forms, so the fullwidth confusable
    // "ＳＯＵＬ" (U+FF33 U+FF2F U+FF35 U+FF2C) lower-cased to the still-fullwidth
    // "ｓｏｕｌ" — which is NOT in the guarded set. The W33 fix prepends an NFKC
    // normalization (Python `unicodedata.normalize("NFKC", ...)`, Swift
    // `precomposedStringWithCompatibilityMapping`) so fullwidth folds to ASCII
    // "soul" and the guard fires. This table pins the exact inputs from the
    // worker brief and is the cross-language parity contract: the same table is
    // exercised against the real Python guard + executors (see daemon side).

    @Test("NFKC table: confusable + whitespace kinds all canonicalize to soul and upgrade")
    func nfkcTableUpgrades() {
        // (label, raw kind) — every one of these MUST canonicalize to "soul"
        // under NFKC+strip+lower and therefore upgrade AUTO→CONFIRM.
        let table: [(label: String, kind: String)] = [
            ("ascii leading-space ' soul'", " soul"),
            ("ascii upper 'SOUL'",          "SOUL"),
            ("NBSP-padded soul",            "\u{00A0}soul\u{00A0}"),       // no-break space
            ("ideographic-space soul",      "\u{3000}soul\u{3000}"),       // ideographic space (U+3000)
            ("narrow-NBSP soul",            "\u{202F}soul"),               // narrow no-break space
            ("fullwidth ＳＯＵＬ",            "\u{FF33}\u{FF2F}\u{FF35}\u{FF2C}"),  // fullwidth SOUL
            ("fullwidth + padding",         "\u{3000}\u{FF33}\u{FF2F}\u{FF35}\u{FF2C}\u{00A0}"),
            ("NFKC ligature-free mixed",    " ＳoＵl "),                    // mixed fullwidth/ascii
        ]
        for row in table {
            #expect(
                PersonaWriteGuard.shouldUpgradeToConfirm(
                    tool: "persona_write",
                    kind: row.kind,
                    resolvedAutonomy: "auto",
                    hasExplicitAutonomyOverride: false
                ),
                "persona_write NFKC case '\(row.label)' (\(row.kind.debugDescription)) MUST upgrade"
            )
            // Same fullwidth/whitespace handling for the append tool.
            #expect(
                PersonaWriteGuard.shouldUpgradeToConfirm(
                    tool: "persona_append_section",
                    kind: row.kind,
                    resolvedAutonomy: "auto",
                    hasExplicitAutonomyOverride: false
                ),
                "persona_append_section NFKC case '\(row.label)' (\(row.kind.debugDescription)) MUST upgrade"
            )
        }
    }

    @Test("NFKC: fullwidth ＶＯＩＣＥ / ＡＧＥＮＴＳ / ＳＫＩＬＬ fold and upgrade")
    func nfkcOtherGuardedKinds() {
        // persona_write guards {soul, voice, agents, skill}.
        let writeCases: [(String, String)] = [
            ("ＶＯＩＣＥ", "\u{FF36}\u{FF2F}\u{FF29}\u{FF23}\u{FF25}"),     // VOICE
            ("ＡＧＥＮＴＳ", "\u{FF21}\u{FF27}\u{FF25}\u{FF2E}\u{FF34}\u{FF33}"), // AGENTS
            ("ＳＫＩＬＬ", "\u{FF33}\u{FF2B}\u{FF29}\u{FF2C}\u{FF2C}"),     // SKILL
        ]
        for (label, kind) in writeCases {
            #expect(PersonaWriteGuard.shouldUpgradeToConfirm(
                tool: "persona_write", kind: kind,
                resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false),
                "persona_write fullwidth \(label) MUST upgrade")
        }
        // persona_append_section guards {soul, voice, agents} — NOT skill.
        // Fullwidth SKILL must STILL be excluded for append (parity).
        #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: "persona_append_section",
            kind: "\u{FF33}\u{FF2B}\u{FF29}\u{FF2C}\u{FF2C}", // ＳＫＩＬＬ
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false),
            "persona_append_section fullwidth ＳＫＩＬＬ must NOT upgrade (skill excluded even after NFKC)")
    }

    @Test("NFKC: fullwidth ＵＳＥＲ stays unguarded because USER writes are rejected elsewhere")
    func nfkcUnguardedFullwidthUser() {
        // USER folds to "user", which is not a confirm-upgrade case. The
        // persona writer rejects USER.md outright because MemoryV2 owns that
        // generated projection.
        #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: "persona_write",
            kind: "\u{FF35}\u{FF33}\u{FF25}\u{FF32}", // ＵＳＥＲ
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false),
            "fullwidth ＵＳＥＲ folds to 'user' and must not be converted into an approval path")
    }

    @Test("persona_write USER does NOT upgrade because USER writes are rejected elsewhere")
    func personaWriteUnguardedKind() {
        // USER.md is generated by MemoryV2; the persona writer rejects it
        // instead of staging a confirmable persona-file write.
        #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: "persona_write", kind: "user",
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false))
        #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: "persona_write", kind: "growth",
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false))
    }

    // MARK: persona_append_section — 3 kinds, NO skill

    @Test("persona_append_section soul/voice/agents upgrade")
    func personaAppendGuardedKindsUpgrade() {
        for kind in ["soul", "voice", "agents"] {
            #expect(
                PersonaWriteGuard.shouldUpgradeToConfirm(
                    tool: "persona_append_section",
                    kind: kind,
                    resolvedAutonomy: "auto",
                    hasExplicitAutonomyOverride: false
                ),
                "persona_append_section{\(kind)} must upgrade"
            )
        }
    }

    @Test("persona_append_section skill does NOT upgrade (parity: no skill)")
    func personaAppendSkillNotGuarded() {
        // the retired daemon — persona_append_section guards only
        // {soul, voice, agents}; "skill" is excluded (the append tool refuses
        // skill bodies). This is the easiest parity bug to introduce by
        // copy-pasting the persona_write set, so pin it explicitly.
        #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: "persona_append_section", kind: "skill",
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false))
    }

    // MARK: ratchet conditions

    @Test("non-auto resolved autonomy passes through untouched")
    func nonAutoNotUpgraded() {
        // The guard only tightens AUTO; "confirm"/"block" pass through.
        for incoming in ["confirm", "block", "ask", ""] {
            #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
                tool: "persona_write", kind: "soul",
                resolvedAutonomy: incoming, hasExplicitAutonomyOverride: false),
                "incoming=\(incoming) must not be touched")
        }
    }

    @Test("explicit autonomy override suppresses the guard")
    func explicitOverrideSuppresses() {
        // Mirror `autonomy_override is None` — when the operator passed an
        // explicit per-call override, the guard does not second-guess it.
        #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: "persona_write", kind: "soul",
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: true))
    }

    @Test("nil / empty kind never matches")
    func nilOrEmptyKind() {
        #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: "persona_write", kind: nil,
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false))
        #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: "persona_write", kind: "",
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false))
    }

    @Test("unrelated tools never upgrade")
    func unrelatedToolsNotGuarded() {
        for tool in ["write_file", "bash", "code_edit", "ln"] {
            #expect(!PersonaWriteGuard.shouldUpgradeToConfirm(
                tool: tool, kind: "soul",
                resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false),
                "tool=\(tool) must not be guarded")
        }
    }

    // MARK: apply() helper

    @Test("apply() upgrades and stamps the source tag")
    func applyUpgradesAndStampsSource() {
        let (autonomy, source) = PersonaWriteGuard.apply(
            tool: "persona_write", kind: "soul",
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false)
        #expect(autonomy == "confirm")
        #expect(source == "dynamic_persona_guard")
        #expect(source == PersonaWriteGuard.autonomySource)
    }

    @Test("apply() leaves source nil when it does not fire")
    func applyNoChangeKeepsSourceNil() {
        let (autonomy, source) = PersonaWriteGuard.apply(
            tool: "persona_write", kind: "user",
            resolvedAutonomy: "auto", hasExplicitAutonomyOverride: false)
        #expect(autonomy == "auto")
        #expect(source == nil)
    }

    @Test("constants match the daemon's string values")
    func constantsParity() {
        #expect(PersonaWriteGuard.autonomySource == "dynamic_persona_guard")
        #expect(PersonaWriteGuard.triggeringAutonomy == "auto")
        #expect(PersonaWriteGuard.upgradedAutonomy == "confirm")
        #expect(PersonaWriteGuard.personaWriteGuardedKinds == ["soul", "voice", "agents", "skill"])
        #expect(PersonaWriteGuard.personaAppendGuardedKinds == ["soul", "voice", "agents"])
    }
}
