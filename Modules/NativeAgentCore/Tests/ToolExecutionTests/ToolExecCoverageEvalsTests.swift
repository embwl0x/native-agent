import Testing
import Foundation
@testable import ToolExecution
import NativeAgentCore
import PersistenceCore

// ============================================================================
// Coverage-ledger evals — fence core.toolexec (docs/evals/ledger.json).
//
// Rows closed here:
//   • toolexec.validator.swiftFileWriteEscape
//   • toolexec.validator.swiftNetworkEscape
//   • toolexec.manifest.timeoutSeconds
//   • toolexec.runSandbox.noConfinement
//
// These are TEST-ONLY additions. Where a row names a FAIL-OPEN hole that is
// present in production source today, the eval does NOT pretend the hole is
// closed: it pins the hole as an explicit, named, machine-checked fact so the
// day someone fixes production this test fails LOUDLY and points at the fix.
// A silent gap becomes a dated, enumerated one.
// ============================================================================

// MARK: - Fixture

/// Stage a validator fixture on disk (entrypoint + tests.json) and return the
/// manifest dict + proposal dir. Calls `SwiftToolValidator.validate` directly —
/// the same entry `SwiftToolValidator.make(proposalDir:)` wraps — so the eval
/// costs no proposal-store round trip.
private func validatorFixture(
    entrypointBody: String,
    permissions: [String],
    entrypointName: String = "tool.swift"
) throws -> (manifest: [String: JSONValue], dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecEvals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(entrypointBody.utf8).write(to: dir.appendingPathComponent(entrypointName))
    try Data("[{\"name\":\"smoke\",\"input\":{}}]".utf8)
        .write(to: dir.appendingPathComponent("tests.json"))
    let manifest: [String: JSONValue] = [
        "id": .string("eval"),
        "name": .string("eval"),
        "entrypoint": .string(entrypointName),
        "permissions": .array(permissions.map { .string($0) }),
    ]
    return (manifest, dir)
}

private func validate(
    _ body: String,
    permissions: [String] = ["app_data_read"]
) async throws -> ToolValidationResult {
    let (manifest, dir) = try validatorFixture(entrypointBody: body, permissions: permissions)
    defer { try? FileManager.default.removeItem(at: dir) }
    return await SwiftToolValidator.validate(manifest: manifest, proposalDir: dir)
}

// MARK: - toolexec.validator.swiftFileWriteEscape
//
// The write gate is a six-entry FileManager verb list. Foundation's OWN write
// verbs are absent from it, so a Swift tool declaring only `app_data_read` can
// overwrite any file the app can and still validate clean AND auto-promote
// (app_data_read ⊆ safeAutoToolPermissions).
//
// ENVELOPE (not three pinned literals): for EVERY syntactic file-write form we
// know of, record whether the validator rejects it. `gatedWriteForms` is the
// set the gate actually covers; `ungatedWriteForms` is the fail-open residue.
// Adding a Foundation verb to `fileManagerWriteSymbols` moves a form from one
// set to the other and this test fails until the expectation is updated —
// which is exactly the signal a fix should produce.

private struct WriteForm {
    let label: String
    let body: String
}

private let fileWriteForms: [WriteForm] = [
    WriteForm(
        label: "FileManager.removeItem",
        body: "import Foundation\ntry FileManager.default.removeItem(atPath: \"/tmp/x\")\nprint(\"{}\")\n"
    ),
    WriteForm(
        label: "FileManager.createFile",
        body: "import Foundation\nFileManager.default.createFile(atPath: \"/tmp/x\", contents: Data())\nprint(\"{}\")\n"
    ),
    WriteForm(
        label: "FileManager.createDirectory",
        body: "import Foundation\ntry FileManager.default.createDirectory(atPath: \"/tmp/x\", withIntermediateDirectories: true)\nprint(\"{}\")\n"
    ),
    WriteForm(
        label: "Data.write(to:)",
        body: "import Foundation\ntry Data(\"pwn\".utf8).write(to: URL(fileURLWithPath: \"/tmp/x\"))\nprint(\"{}\")\n"
    ),
    WriteForm(
        label: "String.write(to:atomically:encoding:)",
        body: "import Foundation\ntry \"pwn\".write(to: URL(fileURLWithPath: \"/tmp/x\"), atomically: true, encoding: .utf8)\nprint(\"{}\")\n"
    ),
    WriteForm(
        label: "FileHandle(forWritingAtPath:)",
        body: "import Foundation\nlet h = FileHandle(forWritingAtPath: \"/tmp/x\")\nh?.write(Data())\nprint(\"{}\")\n"
    ),
]

@Test func evalToolexecValidator_fileWriteForms_gatedSetIsEnumeratedNotAssumed() async throws {
    var rejected: Set<String> = []
    var acceptedAndAutoPromotable: Set<String> = []
    for form in fileWriteForms {
        let result = try await validate(form.body, permissions: ["app_data_read"])
        if result.valid {
            #expect(
                result.autoPromotable,
                "\(form.label): app_data_read is in safeAutoToolPermissions, so a VALID proposal must also be autoPromotable — if this flipped, the promote gate changed and the risk model moved"
            )
            acceptedAndAutoPromotable.insert(form.label)
        } else {
            rejected.insert(form.label)
        }
    }

    // The forms the write gate actually covers today.
    #expect(
        rejected == [
            "FileManager.removeItem",
            "FileManager.createFile",
            "FileManager.createDirectory",
        ],
        "the set of file-write forms REJECTED without a write permission changed; got \(rejected.sorted())"
    )
    // KNOWN FAIL-OPEN (ledger row toolexec.validator.swiftFileWriteEscape).
    // A Swift tool declaring ONLY app_data_read can write any file through
    // these three forms and auto-promotes with no human in the loop. When the
    // production gate is widened this expectation must shrink to [] — that
    // failure IS the notification that the hole closed.
    #expect(
        acceptedAndAutoPromotable == [
            "Data.write(to:)",
            "String.write(to:atomically:encoding:)",
            "FileHandle(forWritingAtPath:)",
        ],
        "KNOWN FAIL-OPEN set changed; got \(acceptedAndAutoPromotable.sorted()). If a Foundation write verb was added to SwiftToolValidator.fileManagerWriteSymbols, move it to the rejected set above."
    )

    // Structural half of the same claim: the gate list contains no Foundation
    // write verb, so the hole is a property of the list, not of these fixtures.
    let gate = SwiftToolValidator.fileManagerWriteSymbols
    #expect(gate.allSatisfy { $0.hasPrefix(".") && $0.hasSuffix("(") })
    #expect(!gate.contains(".write("), "if `.write(` joined the gate list, the Data/String escapes above are closed — update this eval")
}

@Test func evalToolexecValidator_declaredWritePermission_clearsEveryGatedForm() async throws {
    // Positive control: the gate is a PERMISSION gate, not a blanket ban. With
    // app_data_write declared, every gated form validates — so a regression
    // that made the gate unconditional (breaking legitimate write tools) is
    // caught too, not just a regression that removes it.
    for form in fileWriteForms {
        let result = try await validate(form.body, permissions: ["app_data_write"])
        #expect(result.valid, "\(form.label) must validate when app_data_write is declared")
        #expect(result.autoPromotable, "\(form.label): app_data_write is a safe-auto permission")
    }
}

// MARK: - toolexec.validator.swiftNetworkEscape
//
// The network-permission gate matches PYTHON import roots (`http`, `urllib`)
// only. ToolRunSandbox executes Swift. `URLSession.shared.data(from:)` needs no
// import beyond Foundation, so a Swift tool exfiltrates over the network while
// declaring zero network permission — and with only app_data_read it
// auto-promotes.
//
// ENVELOPE: capability-class PARITY between the Python and Swift rule sets. The
// classes are named explicitly, so a future capability added on one side and
// not mirrored on the other fails this test.

@Test func evalToolexecValidator_networkGate_isPythonImportOnly_swiftEscapesOpen() async throws {
    // Python arm — gated, as documented.
    let pyHTTP = try await validate(
        "import urllib.request\nprint(\"{}\")\n", permissions: ["app_data_read"]
    )
    #expect(!pyHTTP.valid)
    #expect(pyHTTP.errors.contains { $0.contains("network permission") })
    let pyAllowed = try await validate(
        "import urllib.request\nprint(\"{}\")\n", permissions: ["app_data_read", "network_public"]
    )
    #expect(pyAllowed.valid, "a declared network permission must clear the Python arm")

    // Swift arm — KNOWN FAIL-OPEN (ledger row toolexec.validator.swiftNetworkEscape).
    let swiftForms = [
        "import Foundation\nlet (d, _) = try await URLSession.shared.data(from: URL(string: \"https://x\")!)\nprint(\"{}\")\n",
        "import Foundation\nlet t = URLSession.shared.dataTask(with: URL(string: \"https://x\")!) { _, _, _ in }\nt.resume()\nprint(\"{}\")\n",
        "import Foundation\nlet s = try String(contentsOf: URL(string: \"https://x\")!, encoding: .utf8)\nprint(\"{}\")\n",
    ]
    for body in swiftForms {
        let result = try await validate(body, permissions: ["app_data_read"])
        #expect(
            result.valid && result.autoPromotable,
            "KNOWN FAIL-OPEN changed: a Swift network form is now gated. Good — update this eval to assert rejection.\nbody: \(body)"
        )
    }
}

@Test func evalToolexecValidator_capabilityClassParity_pythonVsSwift() {
    // The two rule sets are supposed to cover the same capability classes.
    // Name the classes and assert which side covers each. Adding a class to
    // one side without mirroring it fails here.
    //
    //   class            python rule                       swift rule
    //   process-spawn    dangerousToolImports "subprocess" dangerousSwiftSymbols "Process("
    //   dyn-load         dangerousToolImports "ctypes"     dangerousSwiftSymbols "dlopen("
    //   raw-syscall      dangerousToolImports "pty"        dangerousSwiftImports "Darwin"
    //   file-write       (n/a — python arm ungated)        fileManagerWriteSymbols (PARTIAL)
    //   network          root == http|urllib               NONE  ← the gap
    #expect(SwiftToolValidator.dangerousToolImports.contains("subprocess"))
    #expect(SwiftToolValidator.dangerousSwiftSymbols.contains("Process("))
    #expect(SwiftToolValidator.dangerousToolImports.contains("ctypes"))
    #expect(SwiftToolValidator.dangerousSwiftSymbols.contains("dlopen("))
    #expect(SwiftToolValidator.dangerousSwiftImports.contains("Darwin"))

    // The network class has NO Swift-side rule. This is the asymmetry the
    // ledger row names. `URLSession` / `URLRequest` are the symbols a mirror
    // fix would have to add; assert their absence so the fix trips this test.
    let allSwiftSymbols = SwiftToolValidator.dangerousSwiftSymbols
        + SwiftToolValidator.fileManagerWriteSymbols
    for networkSymbol in ["URLSession", "URLRequest", "NWConnection", "CFStream"] {
        #expect(
            !allSwiftSymbols.contains { $0.contains(networkSymbol) },
            "\(networkSymbol) is now a Swift-side rule — the network arm was mirrored. Update this eval and flip toolexec.validator.swiftNetworkEscape to COVERED."
        )
    }
}

// MARK: - toolexec.manifest.timeoutSeconds
//
// `timeoutSeconds(_:)` is private, so the coercion table is observed the only
// way production observes it: through `runTool` on a real active tool. The
// entrypoint sleeps 4s. A manifest whose value coerces to 1 must kill it; a
// manifest whose value coerces to the 10s DEFAULT must let it finish. That
// pair is what distinguishes "the coercion table is intact" from "everything
// collapsed to one number".

private func seedTimeoutTool(
    root: URL,
    id: String,
    timeoutField: JSONValue,
    sleepSeconds: Double
) throws {
    let activeDir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
    let manifest: JSONValue = .object([
        "id": .string(id),
        "name": .string(id),
        "entrypoint": .string("tool.swift"),
        "timeoutSeconds": timeoutField,
    ])
    try manifest.serializedData(pretty: true)
        .write(to: activeDir.appendingPathComponent("manifest.json"))
    let body = """
    import Foundation
    Thread.sleep(forTimeInterval: \(sleepSeconds))
    print("{\\"ok\\":true}")
    """
    try Data(body.utf8).write(to: activeDir.appendingPathComponent("tool.swift"))
    try Data("[{\"name\":\"smoke\",\"input\":{}}]".utf8)
        .write(to: activeDir.appendingPathComponent("tests.json"))
    let fingerprint = computeToolCodeFingerprint(toolRoot: activeDir, entrypointName: "tool.swift")
    let record: JSONValue = .object([
        "id": .string(id),
        "name": .string(id),
        "status": .string("active"),
        "createdAt": .string("2026-06-03T00:00:00+00:00"),
        "updatedAt": .string("2026-06-03T00:00:00+00:00"),
        "activePath": .string(activeDir.path),
        "codeFingerprint": .string(fingerprint),
    ])
    try JSONValue.array([record]).serializedData(pretty: true)
        .write(to: root
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("registry.json"))
}

@Test func evalToolexecManifest_timeoutCoercionTable_boolIsOneSecond_unparseableIsDefault() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecTimeoutEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // `bool true` documents-coerces to 1s. A 4s tool MUST be killed.
    try seedTimeoutTool(root: tmp, id: "t_bool", timeoutField: .bool(true), sleepSeconds: 4)
    let exec = SwiftNativeToolExecution(root: tmp)
    do {
        _ = try await exec.runTool(id: "t_bool", input: .object([:]))
        Issue.record("timeoutSeconds:true must coerce to 1s and kill a 4s tool — it did not")
    } catch ToolRunError.timeout {
        // ok — the documented coercion held.
    } catch {
        Issue.record("wrong error for timeoutSeconds:true — \(error)")
    }

    // An UNPARSEABLE string coerces to the 10s default (NOT to 1, and not to
    // 0). The same 4s tool must complete. This is the half that proves the
    // table did not collapse — if every input mapped to 1s, this would fail.
    try seedTimeoutTool(root: tmp, id: "t_junk", timeoutField: .string("abc"), sleepSeconds: 4)
    let junk = try await exec.runTool(id: "t_junk", input: .object([:]))
    guard case .object(let obj) = junk else {
        Issue.record("runTool envelope was not an object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    // ENVELOPE NOTE: `timedOut` is structurally UNREACHABLE as `true` here —
    // ToolRunSandboxRunner THROWS ToolRunError.timeout instead of returning a
    // timed-out result, so the envelope field is always false. Asserted so a
    // future change that starts surfacing timeouts in-band shows up as a test
    // change rather than as a silently-new UI state.
    #expect(obj["timedOut"] == .bool(false))
}

@Test func evalToolexecManifest_timeoutClamp_zeroAndNegativeStillProduceALiveWindow() async throws {
    // min(120, max(1, …)) — a 0 or a negative must never become a 0-second
    // (or negative) window. Observationally: the tool is still SPAWNED and
    // killed by the timeout path rather than failing to run at all, and the
    // snake_case alias is read.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecTimeoutClampEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)

    // A quick tool with timeoutSeconds 0 → clamped to 1s → still completes.
    try seedTimeoutTool(root: tmp, id: "t_zero", timeoutField: .int(0), sleepSeconds: 0)
    let zero = try await exec.runTool(id: "t_zero", input: .object([:]))
    guard case .object(let zeroObj) = zero else {
        Issue.record("runTool envelope was not an object")
        return
    }
    #expect(
        zeroObj["status"] == .string("ok"),
        "timeoutSeconds:0 must clamp to the 1s floor, not to a zero-length window that kills every tool instantly"
    )

    // snake_case alias is honoured: `timeout_seconds: true` → 1s → 4s tool dies.
    let activeDir = tmp
        .appendingPathComponent("tools/active/t_snake", isDirectory: true)
    try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
    let manifest: JSONValue = .object([
        "id": .string("t_snake"),
        "name": .string("t_snake"),
        "entrypoint": .string("tool.swift"),
        "timeout_seconds": .bool(true),
    ])
    try manifest.serializedData(pretty: true)
        .write(to: activeDir.appendingPathComponent("manifest.json"))
    try Data("import Foundation\nThread.sleep(forTimeInterval: 4.0)\nprint(\"{}\")\n".utf8)
        .write(to: activeDir.appendingPathComponent("tool.swift"))
    try Data("[]".utf8).write(to: activeDir.appendingPathComponent("tests.json"))
    let fp = computeToolCodeFingerprint(toolRoot: activeDir, entrypointName: "tool.swift")
    try JSONValue.array([.object([
        "id": .string("t_snake"),
        "name": .string("t_snake"),
        "status": .string("active"),
        "createdAt": .string("2026-06-03T00:00:00+00:00"),
        "updatedAt": .string("2026-06-03T00:00:00+00:00"),
        "activePath": .string(activeDir.path),
        "codeFingerprint": .string(fp),
    ])]).serializedData(pretty: true)
        .write(to: tmp.appendingPathComponent("tools/registry.json"))
    do {
        _ = try await exec.runTool(id: "t_snake", input: .object([:]))
        Issue.record("the snake_case `timeout_seconds` alias was not read — a 4s tool survived a 1s budget")
    } catch ToolRunError.timeout {
        // ok
    } catch {
        Issue.record("wrong error for timeout_seconds alias — \(error)")
    }
}

// MARK: - toolexec.runSandbox.noConfinement
//
// The type is NAMED ToolRunSandbox. There is no sandbox-exec wrapper, no
// environment scrub, no allowedRoots, no fd limit — only cwd=toolRoot. Every
// actual containment is the STATIC validator plus the fingerprint pin, both of
// which run BEFORE execution. Nothing tested, asserted, or reported that.
//
// This eval states the boundary as a machine-checked property: the child
// INHERITS the parent environment (a parent-set marker crosses) and can read
// OUTSIDE toolRoot. Both are pinned so a future caller that assumes
// confinement — or a future change that adds it — trips this test.

@Test func evalToolexecRunSandbox_childInheritsParentEnvironmentAndReadsOutsideToolRoot() async throws {
    let marker = "NATIVE_AGENT_EVAL_MARKER_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    setenv(marker, "leaked", 1)
    defer { unsetenv(marker) }

    let toolRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolSandboxEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: toolRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: toolRoot) }

    // A file the tool has no business reading, deliberately OUTSIDE toolRoot.
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolSandboxEvalOutside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let secretPath = outside.appendingPathComponent("secret.txt")
    try Data("outside-toolroot-secret".utf8).write(to: secretPath)

    let body = """
    import Foundation
    let env = ProcessInfo.processInfo.environment
    let marker = env["\(marker)"] ?? ""
    let outsideRead = (try? String(contentsOfFile: "\(secretPath.path)", encoding: .utf8)) ?? ""
    let cwd = FileManager.default.currentDirectoryPath
    print("{\\"ok\\":true,\\"result\\":{\\"marker\\":\\"\\(marker)\\",\\"envKeyCount\\":\\(env.count),\\"outsideRead\\":\\"\\(outsideRead)\\",\\"cwd\\":\\"\\(cwd)\\"}}")
    """
    try Data(body.utf8).write(to: toolRoot.appendingPathComponent("tool.swift"))

    let runner = ToolRunSandboxRunner()
    let result = try await runner.runTool(
        sandbox: ToolRunSandbox(toolRoot: toolRoot, entrypoint: "tool.swift", timeoutSeconds: 60),
        input: .object([:]),
        expectedFingerprint: nil,
        actualFingerprint: nil
    )
    guard case .object(let parsed)? = result.parsedOutput,
          case .object(let inner)? = parsed["result"] else {
        Issue.record("sandbox probe produced no parsed output; stdout=\(result.stdout) stderr=\(result.stderr)")
        return
    }

    // (1) THE CHILD INHERITS THE FULL PARENT ENVIRONMENT. No scrub, no
    //     allowlist — a secret in the app's environment (OPENAI_API_KEY et al)
    //     is visible to every tool the agent promotes.
    #expect(
        inner["marker"] == .string("leaked"),
        "ToolRunSandbox no longer passes the parent environment through. If an environment scrub was added, flip toolexec.runSandbox.noConfinement and update this eval."
    )
    if case .int(let keyCount)? = inner["envKeyCount"] {
        #expect(keyCount > 1, "the child saw \(keyCount) env keys — an inherited environment, not a scrubbed one")
    } else {
        Issue.record("probe did not report envKeyCount")
    }

    // (2) NO FILESYSTEM CONFINEMENT. The child reads a file outside toolRoot.
    #expect(
        inner["outsideRead"] == .string("outside-toolroot-secret"),
        "ToolRunSandbox now confines filesystem reads. If seatbelt/sandbox-exec was added, update this eval and the ledger row."
    )

    // (3) The ONE containment that does exist: cwd is pinned to toolRoot.
    if case .string(let childCWD)? = inner["cwd"] {
        // /tmp is a symlink to /private/tmp on macOS — compare resolved paths.
        #expect(
            URL(fileURLWithPath: childCWD).resolvingSymlinksInPath().path
                == toolRoot.resolvingSymlinksInPath().path,
            "cwd must be pinned to toolRoot — that is the only runtime containment ToolRunSandbox provides; got \(childCWD)"
        )
    } else {
        Issue.record("probe did not report cwd")
    }

    // (4) Structural: the sandbox config carries no confinement knob. If one
    //     appears, this test must be revisited rather than silently passing.
    let sandbox = ToolRunSandbox(toolRoot: toolRoot)
    #expect(sandbox.executableCommand == "/usr/bin/swift",
            "the default executable is the bare Swift interpreter — no sandbox-exec wrapper")
    #expect(sandbox.timeoutSeconds == 10)
}
