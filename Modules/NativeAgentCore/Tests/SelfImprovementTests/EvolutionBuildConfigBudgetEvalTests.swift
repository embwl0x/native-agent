import Testing
import Foundation
@testable import SelfImprovement

// MARK: - core.loops eval wave — si.evolution.buildConfig.timeouts
//
// `EvolutionBuildConfig`'s three timeouts are a WRONG-VALUE-IN-THE-SILENT-
// DIRECTION surface, unpinned until now:
//
//   - SHRINK buildTimeout below a real cold-root-build time and EVERY candidate
//     comes back `.timedOut`; the proposal transitions to candidate_failed, the
//     pipeline looks busy, and no code change ever passes. (The daemon-era 180s
//     cap was already known-insufficient — that is why these are 1800.)
//   - GROW them past the driving caller's tick budget and the build is
//     cancelled mid-flight, leaving a claimed runId plus a half-populated
//     worktree.
//
// So the numbers only mean something RELATIVE to a tick budget. The scheduler's
// default per-tick budget is 300s (BackgroundLoopsManager.swift: `runner
// .tickTimeoutOverride ?? 300`), which the full build+test+git budget here
// exceeds by design — any future loop that drives `build()` MUST carry an
// override, the way WeeklySelfImprovementLoop carries 3600.
//
// NOTE for whoever wires this: as of this eval `EvolutionCandidateBuilder
// .build(_:)` has NO production caller (`EvolutionCandidateRequest(` appears
// only under Tests/), so no loop budget can be checked against it yet. That is
// reported as a production seam, not asserted here.

/// The scheduler's default per-tick budget, mirrored from
/// Modules/NativeAgentCore/Sources/BackgroundLoops/BackgroundLoopsManager.swift
/// (`runner.tickTimeoutOverride ?? 300`). BackgroundLoops is not a dependency
/// of this test target, so the relationship is asserted against the named
/// constant rather than imported.
private let schedulerDefaultTickBudget: TimeInterval = 300

@Suite("core.loops · evolution build budget")
struct EvolutionBuildConfigBudgetEvalTests {

    @Test func defaultTimeoutsArePinnedInBothDirections() {
        let config = EvolutionBuildConfig()

        #expect(config.buildTimeout == 1800,
                "shrinking the cold-root-build budget makes every candidate time out and the pipeline fail silently; growing it past the caller's tick budget cancels builds mid-flight")
        #expect(config.testTimeout == 1800)
        #expect(config.gitTimeout == 120)

        #expect(config.buildTimeout >= 1800,
                "the daemon-era 180s cap is known-insufficient for a cold root build")
        #expect(config.gitTimeout < config.buildTimeout,
                "git plumbing must never be budgeted like a compile")
    }

    /// The relationship that actually matters: the worst-case single build
    /// exceeds the scheduler's DEFAULT tick budget, so a driving loop is
    /// required to supply `tickTimeoutOverride`. If someone ever shrinks these
    /// under 300s this assertion flips and the requirement quietly disappears.
    @Test func fullBudgetExceedsTheDefaultTickBudget_soADriverMustOverrideIt() {
        let config = EvolutionBuildConfig()
        let worstCase = config.buildTimeout + config.testTimeout + config.gitTimeout
        #expect(worstCase == 3720)
        #expect(
            worstCase > schedulerDefaultTickBudget,
            "a loop driving build() on the default 300s tick budget would cancel the build mid-flight and strand a claimed runId + half-populated worktree"
        )
        // WeeklySelfImprovementLoop's 3600s override — the largest in the fence
        // — is still SHORTER than the worst case, so even the most generous
        // existing budget cannot host a full build+test+git run untouched.
        #expect(worstCase > 3600,
                "no existing loop override is large enough to host the worst-case build; a driver needs its own budget, not a borrowed one")
    }

    /// Cleanup posture is part of the same envelope: a failed candidate must
    /// not leave worktrees behind by default (the disk-hygiene mode).
    @Test func failedCandidatesDoNotKeepTheirWorktreeByDefault() {
        let config = EvolutionBuildConfig()
        #expect(config.keepWorktreeOnFailure == false)
        #expect(config.testPackageSubpath == "Modules/NativeAgentCore")
        #expect(config.environmentOverride == nil,
                "the live path must use the scrubbed environment, not a test override")
    }
}
