import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import TrustCenter
// Blueprint: | `ParallelToolDispatch.swift` | `ParallelToolDispatch` enum; `isSerialFallbackForced`, `isParallelSafe` reads the declared class and the catalog bucket (reads of them own data and files run side by side; their devices, the app door and the unplaced run one at a time); keyword scheduling inference removed |

// MARK: - Parallel dispatch of independent tool calls (U1 step 6, 2026-06-10)
//
// The OpenAI adapter requests parallel_tool_calls:true and Anthropic batches
// tool_use blocks freely — the model routinely emits 2+ calls per iteration,
// which this loop used to execute strictly one-by-one. When an iteration
// carries multiple SIDE-EFFECT-SAFE calls, they now run concurrently in a
// task group (cap: maxConcurrentPerIteration) and the results are
// reassembled in ORIGINAL INDEX ORDER, so the provider-visible wire shape —
// one assistant message with N tool_use blocks, then ONE user message with N
// tool_result blocks paired by id in the same order — is byte-identical to
// the serial path. (Pairing convention verified in both OAuth adapters:
// tool_result.tool_use_id / function_call_output.call_id echo; blocks are
// encoded in message order, so slot order == tool_use order is the contract.)
//
// A tool's declared read class is its parallel-safety contract. The Mac
// Integration declaration still vetoes write-mode calls. Effect-time gates
// continue to judge every call.
//
// MIXED BATCHES: consecutive parallel-safe calls coalesce into one
// concurrent group; every unsafe call is its own serial group. Groups
// execute strictly in original order (a write at index k never overlaps
// reads at indices <k or >k), so any execution is observationally
// equivalent to the serial order for side-effect-bearing tools.
//
// ROLLBACK LEVER: set env NATIVE_AGENT_SERIAL_TOOL_DISPATCH=1 (or
// true/yes/on) to force the old strictly-serial path. Default is parallel
// ON.
//
// FAILURE ISOLATION: each concurrent child catches its own error — a
// throwing tool becomes that slot's `{"error": ...}` result exactly as the
// serial path produces, and never cancels siblings. Turn cancellation
// cancels all children via structured concurrency (task-group teardown);
// the parallel set is read-only by construction, so there are no orphan
// writes to clean up.
//
// STEP-5 INTERACTION: results are still appended as ONE user message per
// iteration, so IntraTurnToolResultClearing ages a parallel batch exactly
// like a serial one (the sweep counts tool-result MESSAGES, not blocks).
public enum ParallelToolDispatch {
    /// Concurrency cap per iteration. Anything beyond this queues behind the
    /// window (completion-ordered refill).
    static let maxConcurrentPerIteration = 4

    /// Rollback lever (documented above). Checked once per process.
    static let serialFallbackEnvVar = "NATIVE_AGENT_SERIAL_TOOL_DISPATCH"

    /// Pure, injectable parser for the env flag (unit-testable without
    /// mutating process state).
    static func isSerialFallbackForced(env: [String: String]) -> Bool {
        guard let raw = env[serialFallbackEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    static let effectiveForceSerial =
        isSerialFallbackForced(env: ProcessInfo.processInfo.environment)

    /// Scheduling reads the same declaration as authorization, plus where the call lands.
    /// Reads of her own data and files run side by side. A read through one of his devices
    /// (his browser, his Mac's apps, Mac control, the system, a shell) or through
    /// the app door takes her one pair of hands, one at a time; so does anything the catalog
    /// does not place. A write never runs beside another call.
    public static func isParallelSafe(internalToolName name: String, input: [String: JSONValue] = [:]) -> Bool {
        guard PermissionLaw.toolClass(name, input: input) == .read else { return false }
        let canonical = ToolNameAliases.canonical(name)
        // `git diff` of the working tree rewrites .git/index (git applies GIT_OPTIONAL_LOCKS=0 to
        // every other read; verified on git 2.50.1, 2026-09-01), so it runs alone.
        if canonical == "git_diff" { return false }
        return [.core, .fileOps].contains(AppActionBinding.declaredBucket(canonical) ?? .unclassified)
    }

    /// Fleet-dispatch exception (User, 2026-08-27): `invoke_codex` declares a write because two spawns sharing a checkout stash
    /// each other's edits. But when EVERY invoke_codex call in the iteration
    /// carries an explicit cwd in a distinct, non-overlapping checkout (per-lane
    /// worktrees), the spawns may run concurrently —
    /// that is exactly Agent's lane-burn shape. Any missing, blank, or
    /// duplicate cwd disables the override for the whole iteration (fail
    /// closed, back to serial).
    ///
    /// Returns one entry per call: `true` to force parallel-safe, `nil` to
    /// keep the declared-class verdict.
    static func fleetParallelOverrides(
        names: [String], inputs: [[String: JSONValue]]
    ) -> [Bool?] {
        let none: [Bool?] = Array(repeating: nil, count: names.count)
        let codexIdx = names.indices.filter { names[$0] == "invoke_codex" }
        guard codexIdx.count >= 2 else { return none }
        // Distinctness must be FILESYSTEM identity, not string identity:
        // symlinked or case-aliased paths on APFS can name the same checkout
        // (gpt-5.5 review BLOCKING, 2026-08-27). Each cwd must exist and
        // resolve to a unique checkout (device, inode), with no overlapping
        // writable roots; subdirectories of one checkout are not isolated.
        var identities: Set<FleetCwdIdentity> = []
        var roots: [String] = []
        for i in codexIdx {
            guard case .string(let c)? = inputs[i]["cwd"],
                  !c.trimmingCharacters(in: .whitespaces).isEmpty,
                  let root = Self.fleetCheckoutRoot(path: c),
                  !roots.contains(where: {
                      root == $0 || root.hasPrefix($0 + "/") || $0.hasPrefix(root + "/")
                  }),
                  let identity = Self.fleetCwdIdentity(path: root),
                  identities.insert(identity).inserted else {
                return none
            }
            roots.append(root)
        }
        var out = none
        for i in codexIdx { out[i] = true }
        return out
    }

    struct FleetCwdIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// Locate the checkout containing cwd, including linked Git worktrees.
    /// Canonical roots also expose overlaps between nested checkouts.
    static func fleetCheckoutRoot(path: String) -> String? {
        guard NSString(string: path).isAbsolutePath else { return nil }
        let files = FileManager.default
        var directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard let attrs = try? files.attributesOfItem(atPath: directory.path),
              attrs[.type] as? FileAttributeType == .typeDirectory else { return nil }
        while directory.path != "/" {
            let marker = directory.appendingPathComponent(".git")
            if let attrs = try? files.attributesOfItem(atPath: marker.path) {
                if attrs[.type] as? FileAttributeType == .typeDirectory { return directory.path }
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      let text = try? String(contentsOf: marker, encoding: .utf8),
                      text.hasPrefix("gitdir: ") else { return nil }
                let gitPath = String(text.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !gitPath.isEmpty else { return nil }
                let gitDirectory = URL(fileURLWithPath: gitPath, relativeTo: directory)
                    .resolvingSymlinksInPath()
                guard let gitAttrs = try? files.attributesOfItem(atPath: gitDirectory.path),
                      gitAttrs[.type] as? FileAttributeType == .typeDirectory else { return nil }
                return directory.path
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// (device, inode) of the resolved directory — nil when it does not
    /// exist. Symlinks are resolved before stat so aliases collapse.
    static func fleetCwdIdentity(path: String) -> FleetCwdIdentity? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              attrs[.type] as? FileAttributeType == .typeDirectory,
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return FleetCwdIdentity(device: device, inode: inode)
    }

    // MARK: Iteration planning

    /// One iteration's execution plan: consecutive parallel-safe indices
    /// coalesce into a `.concurrent` group (only when 2+ — a lone safe call
    /// runs serially so single-call iterations keep the exact serial event
    /// order); everything else is its own `.sequential` slot. Groups run in
    /// order; results always reassemble by original index.
    enum ExecutionGroup: Equatable {
        case concurrent([Int])
        case sequential(Int)
    }

    static func plan(parallelSafe: [Bool], forceSerial: Bool) -> [ExecutionGroup] {
        guard !forceSerial else {
            return parallelSafe.indices.map { .sequential($0) }
        }
        var groups: [ExecutionGroup] = []
        var run: [Int] = []
        func flushRun() {
            if run.count >= 2 {
                groups.append(.concurrent(run))
            } else {
                for idx in run { groups.append(.sequential(idx)) }
            }
            run = []
        }
        for (idx, safe) in parallelSafe.enumerated() {
            if safe {
                run.append(idx)
            } else {
                flushRun()
                groups.append(.sequential(idx))
            }
        }
        flushRun()
        return groups
    }
}
