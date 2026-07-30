import Testing
import Foundation
@testable import ChatOrchestration
import PersistenceCore

// =============================================================================
// U4 Wave B — Seatbelt/sandbox-exec wrapping for shell-class builder tools
// =============================================================================
//
// runShellLikeProcess wraps shell-class builder Processes (shell/bash/git/
// apply_patch/run_tests) in a macOS sandbox profile scoped to the NativeAgent workspace:
// reads + exec + network stay open; file-WRITES are confined to the repo + build
// caches; sensitive writes (~/.ssh, Keychains, <repo>/data/trust) are denied.
// Ships ON by default (pure hardening); off-ramps are the env break-glass and a
// Trust Center policy flag, both fail-SAFE to ON.
//
// The standalone sandbox-exec profile was validated empirically 2026-06-11; these
// tests pin (a) the profile content, (b) the kill-switch resolution, and (c) the
// REAL runShellLikeProcess path actually denying an out-of-workspace write.
// =============================================================================

private func sbTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("BuilderSandbox-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Profile content

@Test func BuilderSandbox_profile_scopes_to_workspace_and_denies_trust() {
    let profile = SwiftToolDispatcher.builderSandboxProfile()
    let ws = URL(fileURLWithPath: SwiftToolDispatcher.nativeAgentRepoRoot)
        .resolvingSymlinksInPath().path
    #expect(profile.contains("(version 1)"))
    #expect(profile.contains("(allow default)"))
    #expect(profile.contains("(deny file-write*)"))
    // workspace is allowed for write…
    #expect(profile.contains("(subpath \"\(ws)\")"))
    // …but the trust policy dir inside it is denied (last-rule-wins).
    #expect(profile.contains("(deny file-write* (subpath \"\(ws)/data/trust\")"))
    // build caches present so swift build / package resolution still write.
    #expect(profile.contains("/Library/Developer"))
    #expect(profile.contains("/private/var/folders"))
}

@Test func BuilderSandbox_publicWorkspaceIsAnExecutableConfinedRoot() async throws {
    let dataRoot = try sbTempRoot()
        .appendingPathComponent("NativeAgent", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
    let workspace = try NativeAgentWorkspaceRoot.prepare(
        dataRoot: dataRoot,
        environment: [:]
    )
    let probe = workspace.appendingPathComponent("builder-workspace-probe.txt")

    #expect(
        SwiftToolDispatcher.builderNormalizeCwd(
            workspace.path,
            dataRoot: dataRoot
        ) == workspace.resolvingSymlinksInPath().path
    )
    #expect(
        SwiftToolDispatcher.builderNormalizeCwd(
            FileManager.default.temporaryDirectory.path,
            dataRoot: dataRoot
        ) == nil
    )

    let profile = SwiftToolDispatcher.builderSandboxProfile(dataRoot: dataRoot)
    #expect(profile.contains(#"(subpath "\#(workspace.path)")"#))
    #expect(profile.contains(#"(deny file-write* (subpath "\#(dataRoot.appendingPathComponent("trust").path)")"#))

    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "bash",
        executable: "/bin/bash",
        args: ["-c", "printf workspace-ok > builder-workspace-probe.txt"],
        cwd: workspace.path,
        timeoutSeconds: 10,
        dataRoot: dataRoot
    )
    guard case .object(let object) = result else {
        Issue.record("expected builder result object")
        return
    }
    #expect(object["status"] == .string("completed"))
    #expect(try String(contentsOf: probe, encoding: .utf8) == "workspace-ok")
}

@Test func BuilderSandbox_relativeCwdResolvesInsidePublicWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("builder-relative-workspace-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("workspace/project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let result = await SwiftToolDispatcher.impl_bash(
        input: [
            "cmd": .string("pwd"),
            "cwd": .string("project"),
        ],
        dataRoot: root
    )
    guard case .object(let object) = result else {
        Issue.record("expected builder envelope")
        return
    }
    #expect(object["status"] == .string("completed"))
    #expect(object["cwd"] == .string(project.path))
}

// MARK: - Kill-switch resolution (fail-safe to ON)

@Test func BuilderSandbox_enabled_defaults_true_no_policy() async throws {
    let root = try sbTempRoot()  // no policy.json
    let enabled = await SwiftToolDispatcher.builderShellSandboxEnabled(dataRoot: root)
    #expect(enabled, "no policy → sandbox defaults ON (fail-safe)")
}

@Test func BuilderSandbox_policy_flag_false_disables() async throws {
    let root = try sbTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object(["securityPolicy": .object(["shellSandboxEnabled": .bool(false)])]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let enabled = await SwiftToolDispatcher.builderShellSandboxEnabled(dataRoot: root)
    #expect(enabled == false, "securityPolicy.shellSandboxEnabled=false → sandbox OFF")
}

@Test func BuilderSandbox_developerMode_disables_even_with_legacy_flag_enabled() async throws {
    let root = try sbTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "developerMode": .bool(true),
            "securityPolicy": .object(["shellSandboxEnabled": .bool(true)]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let mode = await SwiftToolDispatcher.builderShellSandboxMode(dataRoot: root)
    #expect(mode == .developerFullMac, "Developer Mode must lift workspace-only shell confinement")
}

// MARK: - Real runShellLikeProcess path (guarded on the repo existing — the
// builder tools are inherently repo-rooted; on a non-dev machine this skips).

@Test func BuilderSandbox_sandboxed_run_denies_out_of_workspace_write() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }  // dev-machine only
    let root = try sbTempRoot()  // no policy → sandbox ON
    let uuid = UUID().uuidString
    let tmpProbe = "/tmp/u4b_ws_\(uuid)"
    let homeProbe = NSHomeDirectory() + "/u4b_home_\(uuid)"  // $HOME root: NOT an allowed write subpath
    defer {
        try? FileManager.default.removeItem(atPath: tmpProbe)
        try? FileManager.default.removeItem(atPath: homeProbe)
    }
    // /tmp write is allowed by the profile; the $HOME-root write must be denied.
    let cmd = "echo ok > '\(tmpProbe)'; echo leak > '\(homeProbe)' 2>/dev/null; true"
    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "shell", executable: "/bin/sh", args: ["-c", cmd],
        cwd: repo, timeoutSeconds: 30, dataRoot: root
    )
    // honest receipt: the envelope reports it ran sandboxed.
    if case .object(let o) = result, case .bool(let sb)? = o["sandboxed"] {
        #expect(sb, "envelope must report sandboxed=true")
    } else {
        Issue.record("envelope missing sandboxed flag: \(result)")
    }
    #expect(FileManager.default.fileExists(atPath: tmpProbe),
            "sandbox must ALLOW the /tmp write (capability preserved)")
    #expect(FileManager.default.fileExists(atPath: homeProbe) == false,
            "sandbox must DENY the out-of-workspace $HOME write (security bites)")
}

@Test func BuilderSandbox_killswitch_off_reports_unsandboxed() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object(["securityPolicy": .object(["shellSandboxEnabled": .bool(false)])]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "shell", executable: "/bin/sh", args: ["-c", "true"],
        cwd: repo, timeoutSeconds: 30, dataRoot: root
    )
    if case .object(let o) = result, case .bool(let sb)? = o["sandboxed"] {
        #expect(sb == false, "kill switch off → envelope reports sandboxed=false")
    } else {
        Issue.record("envelope missing sandboxed flag: \(result)")
    }
}

@Test func BuilderSandbox_developerMode_run_can_write_outside_workspace() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object(["developerMode": .bool(true)]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let homeProbe = NSHomeDirectory() + "/nativeagent_developer_mode_probe_\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: homeProbe) }
    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "shell", executable: "/bin/sh",
        args: ["-c", "printf dev-mode-ok > '\(homeProbe)'"],
        cwd: repo, timeoutSeconds: 30, dataRoot: root
    )
    guard case .object(let object) = result else {
        Issue.record("expected builder result object")
        return
    }
    #expect(object["status"] == .string("completed"))
    #expect(object["sandboxed"] == .bool(true))
    #expect(object["sandbox_mode"] == .string("developer_full_mac"))
    #expect(try String(contentsOfFile: homeProbe, encoding: .utf8) == "dev-mode-ok")
}

@Test func BuilderSandbox_developerMode_keeps_system_and_authority_floor() async throws {
    let root = try sbTempRoot()
    let profile = SwiftToolDispatcher.builderDeveloperSandboxProfile(dataRoot: root)
    #expect(profile.contains(#"(deny file-write* (subpath "/System"))"#))
    #expect(profile.contains(#"(deny file-write* (subpath "/Applications"))"#))
    #expect(profile.contains(#"/.ssh"#))
    #expect(profile.contains(#"/Library/Keychains"#))
    #expect(profile.contains(#"(deny file-write* (subpath "\#(root.path)"))"#))
    #expect(profile.contains(#"(allow file-write* (subpath "\#(SwiftToolDispatcher.builderWorkspaceRoot(dataRoot: root).path)"))"#))
}

@Test func BuilderSandbox_developerMode_real_run_denies_app_authority_state() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object(["developerMode": .bool(true)]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let authorityProbe = root.appendingPathComponent("providers/authority-probe")
    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "shell", executable: "/bin/sh",
        args: ["-c", "printf forbidden > '\(authorityProbe.path)' 2>/dev/null; true"],
        cwd: repo, timeoutSeconds: 30, dataRoot: root
    )
    guard case .object(let object) = result else {
        Issue.record("expected builder result object")
        return
    }
    #expect(object["sandbox_mode"] == .string("developer_full_mac"))
    #expect(FileManager.default.fileExists(atPath: authorityProbe.path) == false)
}

/// run_tests IS sandboxed (gpt-5.5 review: excluding it was a confused-deputy
/// hole — a sandboxed shell could poison a workspace test/source file then run
/// it unsandboxed via run_tests). It dodges the SwiftPM nesting break via
/// --disable-sandbox (env-threaded into script/test.sh), not by skipping the
/// outer sandbox. Pin: a run_tests invocation reports sandboxed=true.
@Test func BuilderSandbox_run_tests_is_sandboxed() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()  // no policy → sandbox ON
    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "run_tests", executable: "/bin/sh", args: ["-c", "true"],
        cwd: repo, timeoutSeconds: 30, dataRoot: root
    )
    if case .object(let o) = result, case .bool(let sb)? = o["sandboxed"] {
        #expect(sb, "run_tests must be sandboxed (the escape-hatch hole is closed)")
    } else {
        Issue.record("envelope missing sandboxed flag: \(result)")
    }
}

/// swift_build no longer lifts the outer wrapper. The escape hatch it used to
/// need is gone: the PATH shim injects `--disable-sandbox`, removing SwiftPM's
/// INNER sandbox — the only thing that could not nest — so the tool runs
/// CONFINED and still works.
///
/// FALSE-PASS GUARD: asserting `sandboxed == true` alone would pass on a
/// totally broken shim, because a spawn that dies at manifest compile is still
/// a sandboxed spawn. So this drives a REAL `swift build` of a real package and
/// requires it to reach exit 0. Flag plus outcome, never flag alone.
@Test func BuilderSandbox_swiftpm_build_runs_confined_and_succeeds() async throws {
    let root = try sbTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ws = try NativeAgentWorkspaceRoot.prepare(dataRoot: root, environment: [:])

    let pkg = ws.appendingPathComponent("hatchprobe", isDirectory: true)
    try FileManager.default.createDirectory(
        at: pkg.appendingPathComponent("Sources/hatchprobe", isDirectory: true),
        withIntermediateDirectories: true)
    try """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "hatchprobe", targets: [.executableTarget(name: "hatchprobe", path: "Sources/hatchprobe")])
    """.write(to: pkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try #"print("HATCH_OK")"#.write(
        to: pkg.appendingPathComponent("Sources/hatchprobe/main.swift"),
        atomically: true, encoding: .utf8)

    let result = await SwiftToolDispatcher.impl_swift_build(
        input: ["package_path": .string(pkg.path), "timeout": .int(600)],
        dataRoot: root
    )
    guard case .object(let o) = result else {
        Issue.record("no envelope: \(result)"); return
    }
    #expect(o["sandboxed"] == .bool(true), "swift_build must no longer lift the outer wrapper")
    #expect(o["sandbox_mode"] == .string("workspace_write"),
            "expected workspace_write, got \(o["sandbox_mode"] ?? .null)")
    #expect(o["outer_sandbox_policy"] == .string("policy"),
            "expected outer_sandbox_policy=policy, got \(o["outer_sandbox_policy"] ?? .null)")

    // The guard: execution had to SURVIVE the confinement, not merely be
    // wrapped by it. A nested-sandbox regression fails right here.
    #expect(o["status"] == .string("completed"),
            "build did not survive confinement: \(o["stderr"] ?? .null)")
    #expect(o["exit_code"] == .int(0),
            "expected exit 0, got \(o["exit_code"] ?? .null); stderr=\(o["stderr"] ?? .null)")
    if case .string(let err)? = o["stderr"] {
        #expect(!err.contains("sandbox_apply"),
                "SwiftPM is still self-sandboxing inside our wrap: \(err)")
    }
    #expect(FileManager.default.fileExists(
        atPath: pkg.appendingPathComponent(".build").path),
        "no .build artifacts — the build did not actually run")

    // And confinement still bites on the same lane it used to be lifted from.
    let escape = NSHomeDirectory() + "/sbxhatch_escape_\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: escape) }
    _ = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "bash", executable: "/bin/bash",
        args: ["-c", "echo leak > '\(escape)' 2>/dev/null; true"],
        cwd: pkg.path, timeoutSeconds: 60, dataRoot: root
    )
    #expect(FileManager.default.fileExists(atPath: escape) == false,
            "confinement must still bite after the lift was retired")
}

/// The trust policy dir is workspace-internal but must NEVER be writable from a
/// sandboxed builder tool (a shell rewriting data/trust/policy.json could
/// self-grant autonomy). Real dispatcher test of the trailing SBPL deny.
@Test func BuilderSandbox_sandboxed_run_denies_data_trust_write() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()
    let uuid = UUID().uuidString
    let trustProbe = repo + "/data/trust/u4b_probe_\(uuid)"
    defer { try? FileManager.default.removeItem(atPath: trustProbe) }
    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "shell", executable: "/bin/sh",
        args: ["-c", "echo pwn > '\(trustProbe)' 2>/dev/null; true"],
        cwd: repo, timeoutSeconds: 30, dataRoot: root
    )
    if case .object(let o) = result, case .string(let mode)? = o["sandbox_mode"] {
        #expect(mode == "workspace_write", "expected sandbox_mode=workspace_write, got \(mode)")
    }
    #expect(FileManager.default.fileExists(atPath: trustProbe) == false,
            "sandbox must DENY writes to <repo>/data/trust (self-grant guard)")
}

@Test func BuilderTools_masked_EXIT_line_marks_envelope_failed() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()
    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "bash",
        executable: "/bin/bash",
        args: ["-c", #"printf 'ok\n=== EXIT: 1 ===\n'; exit 0"#],
        cwd: repo,
        timeoutSeconds: 30,
        dataRoot: root
    )
    guard case .object(let obj) = result else {
        Issue.record("expected object envelope: \(result)")
        return
    }
    #expect(obj["status"] == .string("failed"))
    #expect(obj["reason"] == .string("masked_subcommand_exit"))
    #expect(obj["exit_code"] == .int(1))
    #expect(obj["process_exit_code"] == .int(0))
    #expect(obj["masked_exit_detected"] == .bool(true))
}

@Test func BuilderTools_bash_rewrites_macos_incompatible_cat_A() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()
    let result = await SwiftToolDispatcher.impl_bash(
        input: ["cmd": .string(#"printf 'a\tb\n' | cat -A"#)],
        dataRoot: root
    )
    guard case .object(let obj) = result else {
        Issue.record("expected object envelope: \(result)")
        return
    }
    #expect(obj["status"] == .string("completed"))
    #expect(obj["exit_code"] == .int(0))
    if case .array(let rewrites)? = obj["compat_rewrites"] {
        #expect(rewrites.contains(.string("cat -A -> cat -vet")))
    } else {
        Issue.record("expected cat -A compat rewrite in envelope")
    }
}

@Test func BuilderTools_freshMac_suppressesInteractiveDeveloperToolsPrompt() {
    let guarded = SwiftToolDispatcher.builderEnvironmentSuppressingDeveloperToolsPrompt(
        environment: ["PATH": "/usr/bin:/bin"],
        selectedDeveloperDirectory: nil
    )
    #expect(guarded.suppressed)
    #expect(guarded.environment["DEVELOPER_DIR"] == "/.nativeagent-no-developer-tools")
}

@Test func BuilderTools_selectedOrExplicitDeveloperDirectory_isPreserved() {
    let selected = SwiftToolDispatcher.builderEnvironmentSuppressingDeveloperToolsPrompt(
        environment: ["PATH": "/usr/bin:/bin"],
        selectedDeveloperDirectory: "/Library/Developer/CommandLineTools"
    )
    #expect(!selected.suppressed)
    #expect(selected.environment["DEVELOPER_DIR"] == nil)

    let explicit = SwiftToolDispatcher.builderEnvironmentSuppressingDeveloperToolsPrompt(
        environment: [
            "PATH": "/usr/bin:/bin",
            "DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer",
        ],
        selectedDeveloperDirectory: nil
    )
    #expect(!explicit.suppressed)
    #expect(
        explicit.environment["DEVELOPER_DIR"]
            == "/Applications/Xcode-beta.app/Contents/Developer"
    )
}

@Test func BuilderTools_bash_large_output_drains_without_deadlock() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()
    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "bash",
        executable: "/bin/bash",
        args: ["-c", "yes builder-drain | head -n 200000"],
        cwd: repo,
        timeoutSeconds: 10,
        dataRoot: root
    )
    guard case .object(let obj) = result else {
        Issue.record("expected object envelope: \(result)")
        return
    }
    #expect(obj["status"] == .string("completed"))
    #expect(obj["exit_code"] == .int(0))
    #expect(obj["_truncated"] == .bool(true))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NATIVE_AGENT_RUN_BUILDER_TIMEOUT_TEST"] == "1"))
func BuilderTools_bash_timeout_kills_process_group() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()
    let started = Date()
    let result = await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "bash",
        executable: "/bin/bash",
        args: ["-c", "trap '' TERM; sleep 20 & wait"],
        cwd: repo,
        timeoutSeconds: 1,
        dataRoot: root
    )
    let elapsed = Date().timeIntervalSince(started)
    guard case .object(let obj) = result else {
        Issue.record("expected object envelope: \(result)")
        return
    }
    #expect(obj["status"] == .string("failed"))
    #expect(elapsed < 25)
}

@Test func BuilderTools_git_accepts_args_as_shell_string() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()
    let result = await SwiftToolDispatcher.impl_git(
        input: ["args": .string("status --short")],
        dataRoot: root
    )
    guard case .object(let obj) = result else {
        Issue.record("expected object envelope: \(result)")
        return
    }
    #expect(obj["status"] == .string("completed"))
    #expect(obj["exit_code"] == .int(0))
}

@Test func BuilderTools_apply_patch_accepts_range_less_context_diff() async throws {
    let repo = SwiftToolDispatcher.nativeAgentRepoRoot
    guard FileManager.default.fileExists(atPath: repo) else { return }
    let root = try sbTempRoot()
    let filename = "workspace/builder-context-patch-\(UUID().uuidString).txt"
    let fileURL = URL(fileURLWithPath: repo).appendingPathComponent(filename)
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "alpha\nbeta\ngamma\n".write(to: fileURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let patch = """
    --- a/\(filename)
    +++ b/\(filename)
    @@
    alpha
    -beta
    +delta
    gamma
    """
    let result = await SwiftToolDispatcher.impl_apply_patch(
        input: ["patch": .string(patch)],
        dataRoot: root
    )
    guard case .object(let obj) = result else {
        Issue.record("expected object envelope: \(result)")
        return
    }
    #expect(obj["status"] == .string("completed"))
    #expect(obj["patch_format"] == .string("range_less_unified_context"))
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == "alpha\ndelta\ngamma\n")
}

@Test func BuilderTools_apply_patch_rejects_codex_patch_format_with_fix_hint() async throws {
    let root = try sbTempRoot()
    let result = await SwiftToolDispatcher.impl_apply_patch(
        input: ["patch": .string("""
        *** Begin Patch
        *** Update File: workspace/example.txt
        @@
        -old
        +new
        *** End Patch
        """)],
        dataRoot: root
    )
    guard case .object(let obj) = result else {
        Issue.record("expected object envelope: \(result)")
        return
    }
    #expect(obj["status"] == .string("failed"))
    #expect(obj["reason"] == .string("codex_apply_patch_format_not_supported"))
    #expect(obj["fix"] != nil)
}
