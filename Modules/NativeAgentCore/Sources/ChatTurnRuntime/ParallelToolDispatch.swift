import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import TrustCenter
// Blueprint: | `ParallelToolDispatch.swift` | `ParallelToolDispatch` enum; `isSerialFallbackForced`, `isParallelSafe` reads the declared class and the catalog bucket (reads of their own data and files run side by side; their devices, the app door and the unplaced run one at a time); keyword scheduling inference removed |

// MARK: - Parallel dispatch of independent tool calls
//
// Safe calls run under maxConcurrentPerIteration; results preserve original slot order and tool-use id pairing.
// Declared read class and catalog bucket determine safety; Mac Integration and effect-time gates still apply.
// Consecutive safe calls form concurrent groups; unsafe calls run alone, with groups executed in original order.
// NATIVE_AGENT_SERIAL_TOOL_DISPATCH=1/true/yes/on forces serial dispatch; otherwise parallel dispatch is enabled.
// Each child reports its own errors without cancelling siblings; turn cancellation cancels all children.
// One user message holds each iteration's results; clearing counts messages rather than result blocks.
public enum ParallelToolDispatch {
    /// Concurrency cap per iteration. Anything beyond this queues behind the
    /// window (completion-ordered refill).
    static let maxConcurrentPerIteration = 4

    /// Serial-dispatch override, checked once per process.
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
        // Working-tree git diff may rewrite .git/index, so it runs alone.
        if canonical == "git_diff" { return false }
        return [.core, .fileOps].contains(AppActionBinding.declaredBucket(canonical) ?? .unclassified)
    }

    /// invoke_codex calls may run concurrently only when every cwd names a distinct, non-overlapping checkout.
    ///
    /// Returns one entry per call: `true` to force parallel-safe, `nil` to
    /// keep the declared-class verdict.
    static func fleetParallelOverrides(
        names: [String], inputs: [[String: JSONValue]]
    ) -> [Bool?] {
        let none: [Bool?] = Array(repeating: nil, count: names.count)
        let codexIdx = names.indices.filter { names[$0] == "invoke_codex" }
        guard codexIdx.count >= 2 else { return none }
        // Require existing, non-overlapping checkout roots with unique (device, inode) identities, resolving path aliases.
        var identities: Set<FleetCwdIdentity> = []
        var roots: [String] = []
        for i in codexIdx {
            guard case .string(let c)? = inputs[i]["cwd"],
                  !c.trimmingCharacters(in: .whitespaces).isEmpty,
                  let root = Self.fleetCheckoutRoot(path: c),
                  !roots.contains(where: {
                      NativeAgentWorkspaceRoot.relativePath(root, under: $0) != nil
                          || NativeAgentWorkspaceRoot.relativePath($0, under: root) != nil
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
