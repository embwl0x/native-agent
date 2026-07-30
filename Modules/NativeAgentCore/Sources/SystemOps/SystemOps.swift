import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Subsystem #17 wave 7 (cluster: 4 LIVE UI routes) — SystemOps.
//
// Ports four daemon routes to in-process Swift:
//
//   • POST /v1/router/plan           → NativeAgentRuntime.route_intent
//: keyword-token-driven 13-way classifier →
//     {goalType, recommendedSurface, contextMode, risk, requiresApproval,
//      matchedCapabilities, nextActions, id, createdAt, message}.
//
//   • POST /v1/system/rebuild        → NativeAgentRuntime.system_rebuild
//: subprocess.Popen of
//     <repo_root>/script/install_app.sh detached so it can kill+respawn
//     the daemon. Returns {ok, message}.
//
//   • POST /v1/git/stash_recover     → NativeAgentRuntime.git_stash_recover
//: `git stash list` → first line containing
//     label → `git stash pop <ref>`. Returns {ok, stashRef, output}.
//
//   • POST /v1/system/crash_report   → NativeAgentRuntime.receive_crash_report
//: redacts user-paths/tokens/long-strings,
//     writes crash-<ts>-<suffix>.json + last.json atomically, prunes to 50.
//     Returns {stored, path, improvementSpawned}.
//
// RESIDUAL CAVEATS — read before flipping any flag:
//
//   .routerPlan          — PORTED-FLIPPABLE-FOR-NARROWED-INPUT-SET (wave 11
//                          closed the matchedCapabilities prereq for the two
//                          Swift-native record sources). The 13-way classifier
//                          is byte-accurate (wave 7). Wave 11 wires
//                          `matchedCapabilities` against
//                          `featureSurfaceRecords` (19 entries) +
//                          `connectorActionDescriptors` (84 entries) only —
//                          103 records total. Python's `capability_records()`
//                          additionally includes skill, tool, manifest-skill,
//                          workflow, and MCP-server records; those record
//                          sources are NOT Swift-native and are NOT
//                          re-implemented here. Connector-action status is
//                          derived from a STATIC native_connector set
//                          (matches Python's cold-bootstrap default when the
//                          connectors map is empty); runtime healthStatus /
//                          authState layering (Python loop at
//                          the retired daemon) is NOT Swift-native.
//                          A `policy_simulate()`
//                          proper port is still missing — Swift hard-codes the
//                          conservative defaults documented below
//                          (tool_creation matches Python's
//                          `permissions:["shell"]` → risk=high,
//                          requires_approval=true). Flipping means
//                          matchedCapabilities reflects the 19+84-entry
//                          static manifest only, not runtime-registered
//                          skills/tools/workflows/MCP-servers. See
//                          CUTOVER_PLAN.md §6.14.
//
//   .systemRebuild       — PORTED-FLIPPABLE (wave 8 closed the gate prereq).
//                          The Swift impl now runs the trust+autonomy gate
//                          (`checkTrustPolicyForAction(.systemRebuild, ...)`)
//                          and the cross-process `RebuildLock` flock BEFORE
//                          subprocess.Popen of `script/install_app.sh`. The
//                          reconcile/improvements-lock check is intentionally
//                          not part of this Swift helper; callers should run
//                          the self-improvement status checks separately when
//                          needed. See CUTOVER_PLAN.md §6.13.
//
//   .gitStashRecover     — PORTED-FLIPPABLE (wave 8 closed the gate prereq).
//                          Same disposition as .systemRebuild — Swift now
//                          enforces the global+per-action autonomy gate via
//                          `checkTrustPolicyForAction(.gitStashRecover, ...)`.
//                          No rebuild lock (stash recovery is idempotent +
//                          fast). The flag is STILL OFF in launchctl by
//                          default. See CUTOVER_PLAN.md §6.13.
//
//   .crashReport         — PORTED-FLIPPABLE (full). Storage + redaction + prune
//                          are byte-accurate against the Python path. The
//                          autonomous start_improvement(...) spawn at the tail
//                          is now wired via an injectable `improvementSpawner`
//                          closure (default: fail closed unless the app injects
//                          a Swift self-improvement spawner). Gates:
//                          masterAutonomyEnabled
//                          + autonomyGate (trust_policy.enableAutonomy) +
//                          300s throttle, advanced before the spawn call to
//                          mirror Python fix-9 anti-storm semantics. Default
//                          factory wiring leaves masterAutonomyEnabled=false
//                          (no auto-spawn) until AppDelegate/DaemonSupervisor
//                          wires the live closure — flipping .crashReport
//                          alone STILL produces improvementSpawned=false.
//                          DEVIATION FROM BRIEF: brief asked for an injected
//                          `SelfImprovementProtocol` reference; we use a
//                          closure seam instead because SystemOps does not
//                          depend on the SelfImprovement subsystem module and
//                          adding the dep would require Package.swift edits
//                          (out of wave-9 scope). The closure can be wired to
//                          SwiftNativeSelfImprovement.startImprovement(...)
//                          at the AppDelegate composition layer.
//                          See CUTOVER_PLAN.md §6.10.
