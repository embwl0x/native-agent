import Foundation
import Testing
@testable import NativeAgentCore

/// P2-3/P2-4/P2-5 seam tests.
///
/// EVERY case here pairs MISMATCHED live-shaped values on purpose: a 0.3.x
/// value read by the new code, or a new value read by an old-shaped filter. A
/// test that mints both sides from one literal proves only that the literal
/// equals itself — it cannot catch the vocabularies drifting apart, which is
/// the entire failure mode these bridges exist to prevent.
@Suite("Workshop wire vocabulary bridges")
struct WorkshopWireVocabularyTests {

    // MARK: P2-3 surface

    @Test func legacySurfaceFoldsOntoCanonical() {
        #expect(WorkshopSurfaceVocabulary.canonicalSurface("missions") == "workshop")
        #expect(WorkshopSurfaceVocabulary.canonicalSurface("workshop") == "workshop")
        // Live values arrive with stray case/space from configs and URLs.
        #expect(WorkshopSurfaceVocabulary.canonicalSurface("  Missions ") == "workshop")
        // Unrelated surfaces pass through normalized, never folded.
        #expect(WorkshopSurfaceVocabulary.canonicalSurface("Telegram") == "telegram")
        #expect(WorkshopSurfaceVocabulary.canonicalSurface("chat") == "chat")
    }

    @Test func bothSpellingsAnswerTheWorkshopPredicate() {
        #expect(WorkshopSurfaceVocabulary.isWorkshopSurface("missions"))
        #expect(WorkshopSurfaceVocabulary.isWorkshopSurface("workshop"))
        #expect(!WorkshopSurfaceVocabulary.isWorkshopSurface("chat"))
        #expect(!WorkshopSurfaceVocabulary.isWorkshopSurface(""))
    }

    /// A live 0.3.x `surfaces.json`: only the legacy key exists.
    @Test func legacyOnlyConfigMapMigratesToCanonicalKey() {
        let onDisk = ["chat": "gpt-5.6-sol", "missions": "claude-opus-4-8"]
        let folded = WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(onDisk)
        #expect(folded["workshop"] == "claude-opus-4-8")
        #expect(folded["missions"] == nil)
        #expect(folded["chat"] == "gpt-5.6-sol")
    }

    /// An older build wrote `missions` after a newer build wrote `workshop`.
    /// The canonical key must win deterministically — a coin flip here is a
    /// silently wrong model on every Workshop run.
    @Test func canonicalKeyWinsWhenBothSpellingsArePresent() {
        let conflicted = ["missions": "stale", "workshop": "fresh"]
        let folded = WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(conflicted)
        #expect(folded["workshop"] == "fresh")
        #expect(folded["missions"] == nil)
        #expect(folded.count == 1)
    }

    @Test func foldingAConfigMapWithoutTheLegacyKeyIsIdentity() {
        let clean = ["chat": "a", "workshop": "b"]
        #expect(WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(clean) == clean)
    }

    // MARK: P2-4 event kinds

    @Test func legacyEventKindsFoldOntoCanonical() {
        #expect(ExecutionEventVocabulary.canonicalKind("mission.step") == "execution.step")
        #expect(ExecutionEventVocabulary.canonicalKind("mission_complete") == "execution_complete")
        #expect(ExecutionEventVocabulary.canonicalKind("mission_followup") == "execution_followup")
        #expect(ExecutionEventVocabulary.canonicalKind("mission_cancelled") == "execution_cancelled")
        // Already canonical → unchanged (idempotent, so double-folding a value
        // that passed through two seams is safe).
        #expect(ExecutionEventVocabulary.canonicalKind("execution.step") == "execution.step")
        // Unrelated kinds are never touched.
        #expect(ExecutionEventVocabulary.canonicalKind("rem.proposal") == "rem.proposal")
        #expect(ExecutionEventVocabulary.canonicalKind("memory.repair") == "memory.repair")
    }

    /// Inbox card sources are `<kind>:<id>`, and the ids are live execution ids.
    @Test func prefixedSourcesFoldWhilePreservingTheirIdentifier() {
        #expect(
            ExecutionEventVocabulary.canonicalKind("mission_complete:exec-9f2c")
                == "execution_complete:exec-9f2c"
        )
        #expect(ExecutionEventVocabulary.canonicalKind("mission_complete:stub")
            == "execution_complete:stub")
        // A kind that merely STARTS with the legacy token but is a different
        // kind must not be rewritten — only an exact token or `token:` prefix.
        #expect(ExecutionEventVocabulary.canonicalKind("mission_completeness")
            == "mission_completeness")
    }

    /// Both directions of the mismatch, which is the whole point: an old record
    /// answering a new filter, and a new record answering an old filter.
    @Test func matchesIsSymmetricAcrossVocabularies() {
        #expect(ExecutionEventVocabulary.matches("mission.step", "execution.step"))
        #expect(ExecutionEventVocabulary.matches("execution.step", "mission.step"))
        #expect(ExecutionEventVocabulary.matches("mission.step", "mission.step"))
        #expect(!ExecutionEventVocabulary.matches("execution.step", "rem.proposal"))
        #expect(!ExecutionEventVocabulary.matches("mission.step", nil))
        #expect(ExecutionEventVocabulary.matches(nil, nil))
    }

    @Test func kindPrefixMatchingCrossesVocabularies() {
        // Old card, new expectation.
        #expect(ExecutionEventVocabulary.hasKindPrefix("mission_complete:abc", "execution_complete"))
        // New card, old expectation — the shape an un-updated reader uses.
        #expect(ExecutionEventVocabulary.hasKindPrefix("execution_complete:abc", "mission_complete"))
        #expect(!ExecutionEventVocabulary.hasKindPrefix("trigger:morning_brief", "execution_complete"))
    }

    // MARK: P2-5 environment

    @Test func canonicalEnvNameIsReadWhenOnlyItIsSet() {
        let value = ExecutionEnvVocabulary.value(
            legacy: "NATIVE_AGENT_MAX_ACTIVE_MISSIONS",
            canonical: "NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS",
            environment: ["NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS": "7"]
        )
        #expect(value == "7")
    }

    @Test func deprecatedEnvNameStillWorks() {
        let value = ExecutionEnvVocabulary.value(
            legacy: "NATIVE_AGENT_MAX_ACTIVE_MISSIONS",
            canonical: "NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS",
            environment: ["NATIVE_AGENT_MAX_ACTIVE_MISSIONS": "5"]
        )
        #expect(value == "5")
    }

    /// Back-compat precedence: an existing launch agent pinning the old name
    /// must not be silently overridden by a new name exported later.
    @Test func deprecatedEnvNameWinsWhenBothAreSet() {
        let value = ExecutionEnvVocabulary.value(
            legacy: "NATIVE_AGENT_MAX_ACTIVE_MISSIONS",
            canonical: "NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS",
            environment: [
                "NATIVE_AGENT_MAX_ACTIVE_MISSIONS": "5",
                "NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS": "9",
            ]
        )
        #expect(value == "5")
    }

    /// An exported-but-empty variable is not a setting. Returning "" here would
    /// make `Int("")` fail and silently reinstate the default, hiding the fact
    /// that the operator set something malformed.
    @Test func emptyValuesFallThroughToTheOtherSpellingThenNil() {
        #expect(
            ExecutionEnvVocabulary.value(
                legacy: "NATIVE_AGENT_MAX_ACTIVE_MISSIONS",
                canonical: "NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS",
                environment: [
                    "NATIVE_AGENT_MAX_ACTIVE_MISSIONS": "   ",
                    "NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS": "4",
                ]
            ) == "4"
        )
        #expect(
            ExecutionEnvVocabulary.value(
                legacy: "NATIVE_AGENT_MAX_ACTIVE_MISSIONS",
                canonical: "NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS",
                environment: [:]
            ) == nil
        )
    }

    /// Every documented sibling variable is wired, both directions. A missing
    /// row here is an env var that silently stopped being honored.
    @Test func everyRenamedEnvVarResolvesFromEitherSpelling() {
        for pair in ExecutionEnvVocabulary.renames {
            #expect(
                ExecutionEnvVocabulary.value(
                    canonical: pair.canonical,
                    environment: [pair.legacy: "1"]
                ) == "1",
                "legacy spelling not honored for \(pair.canonical)"
            )
            #expect(
                ExecutionEnvVocabulary.value(
                    canonical: pair.canonical,
                    environment: [pair.canonical: "2"]
                ) == "2",
                "canonical spelling not honored for \(pair.canonical)"
            )
        }
    }

    @Test func unknownEnvNameIsReadDirectlyWithoutAnAlias() {
        #expect(
            ExecutionEnvVocabulary.value(
                canonical: "NATIVE_AGENT_SOMETHING_ELSE",
                environment: ["NATIVE_AGENT_SOMETHING_ELSE": "x"]
            ) == "x"
        )
        #expect(
            ExecutionEnvVocabulary.value(
                canonical: "NATIVE_AGENT_SOMETHING_ELSE",
                environment: [:]
            ) == nil
        )
    }
}

/// Guards for the surface-keyed sets that live OUTSIDE the vocabulary bridge —
/// security gates and tool-loop budgets that switch on the surface string
/// directly. They are the sites a rename sweep misses, because dropping the
/// Workshop surface from them fails SAFE (deny / short budget) and so produces
/// no error, no log, and no failing test — just Workshop turns that quietly
/// stop being trusted or stop getting enough iterations.
///
/// These read the sets out of source rather than importing them, because the
/// declaring types are internal to their subsystems.
@Suite("Workshop surface literal guards")
struct WorkshopSurfaceLiteralGuardTests {

    private func coreSource(_ relativePath: String) throws -> String {
        // #filePath → .../Modules/NativeAgentCore/Tests/NativeAgentCoreTests/ThisFile.swift
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NativeAgentCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // NativeAgentCore/
        return try String(
            contentsOf: core.appendingPathComponent("Sources").appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// Every surface switch/set that already names `missions` must also name
    /// `workshop`, or the canonical surface silently misses the case.
    @Test func surfaceLiteralSitesNameBothSpellings() throws {
        let sites = [
            "ChatOrchestration/ChatOrchestration+ToolLoop.swift",
            "ChatOrchestration/ChatOrchestration+AutonomyGate.swift",
            "TrustCenter/SecurityCenter+FullMacPolicy.swift",
            "TrustCenter/TrustCenter+Defaults.swift",
        ]
        for site in sites {
            let src = try coreSource(site)
            guard src.contains("\"missions\"") else { continue }
            #expect(
                src.contains("\"workshop\""),
                "\(site) still switches on \"missions\" without \"workshop\" — the canonical Workshop surface misses that case"
            )
        }
    }
}
