import Testing
import Foundation
@testable import ChatOrchestration
import PersistenceCore

// Regression cover for the builder shell sandbox TIER TABLE and for the
// SwiftPM nesting shim.
//
// What makes these worth keeping over the config-level cover in
// BuilderSandboxTests: these observe the REAL spawned process, not the
// resolver's intent. A tier that resolves correctly but wraps (or fails to
// wrap) the actual child is a bug these catch and a config assertion cannot.
//
// NOTE ON ENV: none of these call `setenv`. Process env is global and
// swift-testing runs the suite in parallel in a single process, so mutating it
// silently corrupts unrelated sibling tests. The break-glass is exercised by
// passing `environment:` into the resolver instead.

private func tierTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SbxTier-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writePolicy(_ obj: [String: JSONValue], to root: URL) async throws {
    try await SwiftNativePersistenceCore().writeJSON(
        .object(obj),
        to: root.appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    )
}

// TIER 1 — yolo: no sandbox-exec wrapper on the actual spawned process.
//
// Proven by observation, not by config: nesting a `sandbox-exec` inside the
// spawn only succeeds if our process is not already wrapped. macOS refuses to
// nest profiles, so this is a direct read of the child's real confinement.
@Test func BuilderTier_yolo_has_no_wrapper_on_spawned_process() async throws {
    let root = try tierTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await writePolicy([
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        // legacy flag explicitly ON — yolo must still win.
        "securityPolicy": .object(["shellSandboxEnabled": .bool(true)]),
    ], to: root)

    let mode = await SwiftToolDispatcher.builderShellSandboxMode(dataRoot: root)
    #expect(mode == .off, "yolo must resolve to .off, got \(mode.rawValue)")

    let ws = try NativeAgentWorkspaceRoot.prepare(dataRoot: root, environment: [:])
    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "bash", executable: "/bin/bash",
        args: ["-c", #"/usr/bin/sandbox-exec -p "(version 1)(allow default)" /bin/echo NEST_OK"#],
        cwd: ws.path, timeoutSeconds: 30, dataRoot: root
    )
    guard case .object(let o) = result else { Issue.record("no envelope"); return }
    #expect(o["sandboxed"] == .bool(false))
    #expect(o["sandbox_mode"] == .string("off"))
    #expect(o["status"] == .string("completed"), "spawn failed: \(o["stdout"] ?? .null)")
    if case .string(let out)? = o["stdout"] {
        #expect(out.contains("NEST_OK"), "nested sandbox-exec failed => a wrapper IS present: \(out)")
    }
}

// TIER 2 — the whole policy in one assertion: confinement is not execution
// denial. `swift run` must succeed INSIDE the wrap (the SwiftPM nesting shim
// doing its job) while an out-of-workspace write in the same spawn is denied.
@Test func BuilderTier_workspace_runs_swiftpm_and_still_confines() async throws {
    let root = try tierTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // no policy -> workspaceWrite
    let mode = await SwiftToolDispatcher.builderShellSandboxMode(dataRoot: root)
    #expect(mode == .workspaceWrite, "expected workspaceWrite, got \(mode.rawValue)")

    let ws = try NativeAgentWorkspaceRoot.prepare(dataRoot: root, environment: [:])
    let pkg = ws.appendingPathComponent("probe", isDirectory: true)
    try FileManager.default.createDirectory(
        at: pkg.appendingPathComponent("Sources/probe", isDirectory: true),
        withIntermediateDirectories: true)
    try """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "probe", targets: [.executableTarget(name: "probe", path: "Sources/probe")])
    """.write(to: pkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try #"print("PROBE_RAN")"#.write(
        to: pkg.appendingPathComponent("Sources/probe/main.swift"),
        atomically: true, encoding: .utf8)

    let escape = NSHomeDirectory() + "/sbxtier_escape_\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: escape) }

    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "bash", executable: "/bin/bash",
        args: ["-c", "swift run probe; echo leak > '\(escape)' 2>/dev/null; true"],
        cwd: pkg.path, timeoutSeconds: 600, dataRoot: root
    )
    guard case .object(let o) = result else { Issue.record("no envelope"); return }
    #expect(o["sandboxed"] == .bool(true), "this test is meaningless unwrapped")
    if case .string(let out)? = o["stdout"] {
        #expect(out.contains("PROBE_RAN"), "swift run must succeed under the wrap. out=\(out)")
    } else { Issue.record("no stdout") }
    #expect(FileManager.default.fileExists(atPath: escape) == false,
            "confinement must still bite: $HOME write should be denied")
}

// xcodebuild is REFUSED from a sandboxed posture, with a reason the operator
// can act on — not left to die as exit 74 with `sandbox_apply` buried in
// stderr, and not handed a lift, because an .xcodeproj can declare a Run
// Script phase and would then execute arbitrary shell outside the profile.
//
// FALSE-PASS GUARD: "xcodebuild is sandboxed now" would pass on a build where
// xcodebuild is unreachable for any reason at all. So this proves the REFUSAL
// FIRES — a specific reason code and a message naming Full Mac — and the
// companion test below proves the refusal is conditional on the posture rather
// than a blanket rejection, which is the only way to know the gate is the
// sandbox and not something incidental.
@Test func BuilderTier_xcodebuild_is_refused_with_a_legible_reason() async throws {
    let root = try tierTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try NativeAgentWorkspaceRoot.prepare(dataRoot: root, environment: [:])
    let mode = await SwiftToolDispatcher.builderShellSandboxMode(dataRoot: root)
    #expect(mode == .workspaceWrite, "precondition: sandboxed posture, got \(mode.rawValue)")

    for tool in ["bash", "shell"] {
        let result = tool == "bash"
            ? await SwiftToolDispatcher.impl_bash(
                input: ["cmd": .string("xcodebuild -project App.xcodeproj -scheme App build")],
                dataRoot: root)
            : await SwiftToolDispatcher.impl_shell(
                input: ["cmd": .string("xcodebuild -project App.xcodeproj -scheme App build")],
                dataRoot: root)
        guard case .object(let o) = result else { Issue.record("no envelope from \(tool)"); return }
        #expect(o["status"] == .string("failed"), "\(tool): expected refusal, got \(o["status"] ?? .null)")
        #expect(o["reason"] == .string("xcodebuild_requires_full_mac_posture"),
                "\(tool): wrong reason \(o["reason"] ?? .null)")
        guard case .string(let message)? = o["error"] else {
            Issue.record("\(tool): refusal carried no error message"); return
        }
        // The operator has to learn what to do FROM THE MESSAGE.
        #expect(message.contains("Full Mac"), "\(tool): message never names the posture: \(message)")
        #expect(message.contains("exit 74"), "\(tool): message drops the measured evidence: \(message)")
        #expect(message.contains("swift build"), "\(tool): message never says SwiftPM still works: \(message)")
        // And it must not have spawned anything.
        #expect(o["exit_code"] == nil, "\(tool): refusal should be pre-flight, not a spawn result")
    }
}

// The control that makes the test above mean something: raise the posture and
// the very same command is NOT refused — it reaches a real spawn. Without this,
// a refusal that fired unconditionally (or a detector matching everything)
// would look identical to a working gate.
@Test func BuilderTier_xcodebuild_is_allowed_once_the_posture_is_full_mac() async throws {
    let root = try tierTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await writePolicy([
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
    ], to: root)
    let ws = try NativeAgentWorkspaceRoot.prepare(dataRoot: root, environment: [:])
    #expect(await SwiftToolDispatcher.builderShellSandboxMode(dataRoot: root) == .off,
            "precondition: Full Mac posture")

    let result = await SwiftToolDispatcher.impl_bash(
        input: ["cmd": .string("xcodebuild -version"), "cwd": .string(ws.path)],
        dataRoot: root
    )
    guard case .object(let o) = result else { Issue.record("no envelope"); return }
    #expect(o["reason"] != .string("xcodebuild_requires_full_mac_posture"),
            "Full Mac must not be refused")
    #expect(o["status"] == .string("completed"),
            "xcodebuild should actually run under Full Mac: \(o["stderr"] ?? .null)")
    if case .string(let out)? = o["stdout"] {
        #expect(out.contains("Xcode"), "expected real xcodebuild output, got: \(out)")
    }
}

// SwiftPM is the other half of the contract: the refusal above must be specific
// to xcodebuild, not a general "builds are blocked now".
@Test func BuilderTier_swiftpm_is_not_caught_by_the_xcodebuild_refusal() {
    let hit = SwiftToolDispatcher.builderCommandInvokesXcodebuild
    #expect(!hit("swift build"))
    #expect(!hit("swift test --filter FooTests"))
    #expect(!hit("echo hi"))
    // …while every spelling that would actually launch xcodebuild is caught,
    // including ones the old narrow lift detector deliberately ignored.
    #expect(hit("xcodebuild -list"))
    #expect(hit("/usr/bin/xcodebuild -list"))
    #expect(hit("./xcodebuild -list"))
    #expect(hit("cd ios && xcodebuild build | tee out.txt"))
    #expect(hit("swift build && xcodebuild -list"))
    #expect(hit("echo $(xcodebuild -version)"))
}

// TIER 3 — strict is hard: neither off-ramp can talk it into opening.
// The env break-glass is injected as a parameter, NOT via setenv.
@Test func BuilderTier_strict_ignores_both_offramps() async throws {
    let root = try tierTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await writePolicy([
        "permissionLevel": .string("strict"),
        "developerMode": .bool(true),
        "securityPolicy": .object(["shellSandboxEnabled": .bool(false)]),
    ], to: root)
    let mode = await SwiftToolDispatcher.builderShellSandboxMode(
        dataRoot: root,
        environment: ["NATIVE_AGENT_SHELL_SANDBOX": "0"]
    )
    #expect(mode == .lockedDown, "strict must stay hard-sandboxed, got \(mode.rawValue)")
}

// The env break-glass must still work where it IS allowed — otherwise the test
// above could pass for the wrong reason (a seam that never reads the env).
@Test func BuilderTier_env_breakglass_opens_a_non_strict_lane() async throws {
    let root = try tierTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mode = await SwiftToolDispatcher.builderShellSandboxMode(
        dataRoot: root,
        environment: ["NATIVE_AGENT_SHELL_SANDBOX": "0"]
    )
    #expect(mode == .off, "break-glass must open a balanced lane, got \(mode.rawValue)")
}

// An expired Full Mac window must NOT silently leave the lane unwrapped —
// a lapsed session degrades to a profile instead of staying open.
@Test func BuilderTier_expired_yolo_falls_back_to_a_profile() async throws {
    let root = try tierTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await writePolicy([
        "permissionLevel": .string("full_mac_os"),
        "fullMacConfirmedAt": .string("2020-01-01T00:00:00+00:00"),
        "fullMacMaxDurationHours": .double(4),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
    ], to: root)
    let mode = await SwiftToolDispatcher.builderShellSandboxMode(dataRoot: root)
    #expect(mode != .off, "expired Full Mac window must not resolve to .off")
}

// End-to-end through the real shell lane: a SwiftPM command sent to the `bash`
// tool used to lift the outer wrapper (a model could escape confinement just by
// typing `swift build`). It must now stay wrapped AND still reach exit 0 —
// asserting the flag alone would pass on a spawn that died at manifest compile.
@Test func BuilderTier_shell_lane_swiftpm_is_confined_and_still_builds() async throws {
    let root = try tierTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ws = try NativeAgentWorkspaceRoot.prepare(dataRoot: root, environment: [:])
    let pkg = ws.appendingPathComponent("laneprobe", isDirectory: true)
    try FileManager.default.createDirectory(
        at: pkg.appendingPathComponent("Sources/laneprobe", isDirectory: true),
        withIntermediateDirectories: true)
    try """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "laneprobe", targets: [.executableTarget(name: "laneprobe", path: "Sources/laneprobe")])
    """.write(to: pkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try #"print("LANE_OK")"#.write(
        to: pkg.appendingPathComponent("Sources/laneprobe/main.swift"),
        atomically: true, encoding: .utf8)

    let result = await SwiftToolDispatcher.impl_bash(
        input: [
            "cmd": .string("swift build"),
            "cwd": .string(pkg.path),
            "timeout": .int(600),
        ],
        dataRoot: root
    )
    guard case .object(let o) = result else { Issue.record("no envelope"); return }
    #expect(o["sandboxed"] == .bool(true),
            "`swift build` via the bash tool must no longer lift the wrapper")
    #expect(o["outer_sandbox_policy"] == .string("policy"),
            "expected policy, got \(o["outer_sandbox_policy"] ?? .null)")
    #expect(o["status"] == .string("completed"),
            "build did not survive confinement: \(o["stderr"] ?? .null)")
    if case .string(let err)? = o["stderr"] {
        #expect(!err.contains("sandbox_apply"), "still nesting: \(err)")
    }

}

// DELIBERATELY NOT HERE: the `script/task_ledger.sh` case (a `swift run` buried
// in a shell script). It shells into `swift run --package-path <NativeAgentCore>`
// — the same package this suite holds the SwiftPM build lock on — and
// self-deadlocks. It cannot be tested from inside `swift test` on this package
// and lives as a standalone fixture instead.
