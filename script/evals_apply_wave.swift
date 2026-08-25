#!/usr/bin/env swift
// Integrate a phase-3 build wave: for each fence whose verifier came back green,
// apply its patch, re-run the fence's test target HERE, and commit one commit per
// fence. Fences that fail to apply or fail tests are left UNAPPLIED and listed.
//
// usage: swift script/evals_apply_wave.swift <wave-output.json> [--dry-run] [--only fence,fence]
// wave-output.json = the Workflow task output file (wrapper with "result": [...]) or the bare array.
//
// Direct port of script/evals_apply_wave.py (retired 2026-08-23, zero-Python canon).
// Semantics are identical: wrapper-or-bare input, the finish-shape verified[]
// reader (patchFile + .meta.json fallback), the fence→test-command table, the
// production-source guard, scoped cleanup, per-fence `git commit -q -F -`, and
// the APPLIED/HELD output format.

import Foundation

// MARK: - Python-compatible helpers

func pyTruthy(_ v: Any?) -> Bool {
    guard let v = v, !(v is NSNull) else { return false }
    if let n = v as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return n.doubleValue != 0
    }
    if let s = v as? String { return !s.isEmpty }
    if let a = v as? [Any] { return !a.isEmpty }
    if let d = v as? [String: Any] { return !d.isEmpty }
    return true
}

func pyStr(_ v: Any?) -> String {
    guard let v = v, !(v is NSNull) else { return "None" }
    if let n = v as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "True" : "False" }
        if CFNumberIsFloatType(n) { return "\(n.doubleValue)" }
        return "\(n.int64Value)"
    }
    if let s = v as? String { return s }
    return "\(v)"
}

/// Python s[:n] — slice by code points.
func pyPrefix(_ s: String, _ n: Int) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(n))) }
/// Python s[-n:] — slice by code points.
func pySuffix(_ s: String, _ n: Int) -> String { String(String.UnicodeScalarView(s.unicodeScalars.suffix(n))) }

/// Python str.splitlines() — splits on \n, \r\n, \r; no trailing empty element.
func pySplitlines(_ s: String) -> [String] {
    var lines: [String] = [], current = ""
    var i = s.startIndex
    while i < s.endIndex {
        let ch = s[i]
        if ch == "\n" {
            lines.append(current); current = ""; i = s.index(after: i)
        } else if ch == "\r" {
            lines.append(current); current = ""
            i = s.index(after: i)
            if i < s.endIndex, s[i] == "\n" { i = s.index(after: i) }
        } else {
            current.append(ch); i = s.index(after: i)
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

struct ShellResult { let returncode: Int32; let stdout: String; let stderr: String }

let REPO = FileManager.default.currentDirectoryPath

/// subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=REPO)
func sh(_ cmd: String) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = URL(fileURLWithPath: REPO)
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    do { try p.run() } catch {
        return ShellResult(returncode: 127, stdout: "", stderr: "\(error)")
    }
    p.waitUntilExit()
    group.wait()
    return ShellResult(returncode: p.terminationStatus,
                       stdout: String(data: outData, encoding: .utf8) ?? "",
                       stderr: String(data: errData, encoding: .utf8) ?? "")
}

// MARK: - Args + input

let argv = CommandLine.arguments
guard argv.count > 1 else {
    FileHandle.standardError.write("usage: swift script/evals_apply_wave.swift <wave-output.json> [--dry-run] [--only fence,fence]\n".data(using: .utf8)!)
    exit(1)
}
let src = argv[1]
let dry = argv.contains("--dry-run")
var only: Set<String>? = nil
if let i = argv.firstIndex(of: "--only"), i + 1 < argv.count {
    only = Set(argv[i + 1].split(separator: ",", omittingEmptySubsequences: false).map(String.init))
}

guard let raw = FileManager.default.contents(atPath: src),
      let parsed = try? JSONSerialization.jsonObject(with: raw) else {
    FileHandle.standardError.write("cannot load JSON from \(src)\n".data(using: .utf8)!)
    exit(1)
}
var res: Any? = (parsed as? [String: Any]).map { $0["result"] as Any } ?? parsed
// finish-workflow shape: {built:[...], verified:[{fence, build, patchFile, verify}]} — patches may live on disk
if let rd = res as? [String: Any], rd["verified"] != nil {
    var rows: [[String: Any]] = []
    for case let e as [String: Any] in (rd["verified"] as? [Any]) ?? [] {
        var b = (pyTruthy(e["build"]) ? e["build"] as? [String: Any] : [:]) ?? [:]
        let patchEmpty = pyStr(pyTruthy(b["patch"]) ? b["patch"] : "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pyTruthy(b["patch"])
        if patchEmpty, let pf = e["patchFile"] as? String, pyTruthy(pf), FileManager.default.fileExists(atPath: pf) {
            b["patch"] = (try? String(contentsOfFile: pf, encoding: .utf8)) ?? ""
            let meta = pf.replacingOccurrences(of: ".patch", with: ".meta.json")
            if FileManager.default.fileExists(atPath: meta),
               let mraw = FileManager.default.contents(atPath: meta),
               let m = (try? JSONSerialization.jsonObject(with: mraw)) as? [String: Any] {
                if b["covered"] == nil { b["covered"] = m["covered"] ?? NSNull() }
                if b["testsRun"] == nil { b["testsRun"] = m["testsRun"] ?? NSNull() }
            }
        }
        rows.append(["fence": e["fence"] ?? NSNull(), "build": b, "verify": e["verify"] ?? NSNull()])
    }
    res = rows
}
guard let entries = res as? [Any] else {
    FileHandle.standardError.write("wave output has no result array\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - fence → test command (module package vs root)

let CORE = "swift test --package-path Modules/NativeAgentCore --filter "
let ROOT = "swift test --filter "
var FILTER: [String: String] = [
    "core.chat.engine": CORE + "ChatOrchestrationTests", "core.chat.tools": CORE + "ChatOrchestrationTests", "core.chat.persistence": CORE + "ChatOrchestrationTests",
    "core.substrate.affect": CORE + "CognitiveSubstrateTests", "core.substrate.field": CORE + "CognitiveSubstrateTests", "core.substrate.organism": CORE + "\"CognitiveSubstrateTests|DreamREMCycleTests\"",
    "core.persistence": CORE + "PersistenceCoreTests", "core.providers": CORE + "ProviderRoutingTests", "core.memory": CORE + "\"MemoryV2Tests|KnowledgeGraphTests\"",
    "core.context": CORE + "ContextTests", "core.trust": CORE + "TrustCenterTests", "core.telegram": CORE + "TelegramBotTests",
    "core.maccontrol": CORE + "\"MacControlTests|VisionPerceptionTests\" --no-parallel", "core.workshop": CORE + "\"WorkshopExecutionTests|WorkflowOrchestrationTests|TriggerSchedulerTests\"",
    "core.loops": CORE + "\"BackgroundLoopsTests|SelfImprovementTests\"", "core.activity": CORE + "ActivityWatchTests",
    "core.connectors": CORE + "\"GitHubConnectorTests|XConnectorTests|SlackConnectorTests|ConnectorsTests|ResearchTests|BrowserTests\"",
    "core.toolexec": CORE + "\"MCPDispatcherTests|ToolExecutionTests|ToolRegistryTests|DispatcherTests|SkillsTests|OnboardingTests|MultimodalTTSTests|SwarmRunsTests\"",
    "core.misc": CORE + "\"NativeAgentCoreTests|ApprovalInboxTests|NotificationInboxTests|SystemOpsTests|DoctorChecksTests|PersonaEngineTests\"",
    "relay": ROOT + "NativeAgentChromeRelayTests", "feeds": "bash tests/scripts/agent_instrument_test.sh", "scripts": "bash tests/scripts/agent_instrument_test.sh",
]
for k in ["app.chat", "app.desk", "app.mind", "app.settings", "app.mac", "app.runtimes", "app.bridges", "app.background", "ios.screens", "ios.sync", "turn.contract"] {
    FILTER[k] = ROOT + "NativeAgentAppTests"
}

// MARK: - Apply loop (port of lines 44-73 of the .py)

let prodRegex = try! NSRegularExpression(pattern: "(Modules/NativeAgentCore/Sources|Sources/NativeAgentApp|iOS/NativeAgentMobile/(?!.*Tests))")
let exclRegex = try! NSRegularExpression(pattern: "Tests|script/agent_instrument")
func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

var applied: [(String, String)] = [], held: [(String, String)] = []
for case let e as [String: Any] in entries {
    let f = pyStr(e["fence"])
    let b = (pyTruthy(e["build"]) ? e["build"] as? [String: Any] : [:]) ?? [:]
    let v = (pyTruthy(e["verify"]) ? e["verify"] as? [String: Any] : [:]) ?? [:]
    if let only = only, !only.contains(f) { continue }
    let patch = pyStr(pyTruthy(b["patch"]) ? b["patch"] : "").trimmingCharacters(in: .whitespacesAndNewlines)
    if patch.isEmpty { held.append((f, "no patch")); continue }
    if !pyTruthy(v["green"]) { held.append((f, "verifier not green: " + pyPrefix(pyStr(v["output"]), 160))); continue }
    if !sh("git status --porcelain -- Modules Sources tests iOS script").stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        held.append((f, "tree dirty before apply — resolve first")); break
    }
    let pth = NSTemporaryDirectory() + "evals_apply_wave_\(UUID().uuidString).patch"
    let body = patch + (patch.hasSuffix("\n") ? "" : "\n")
    try! body.write(toFile: pth, atomically: true, encoding: .utf8)
    let chk = sh("git apply --3way --check \(pth)")
    if chk.returncode != 0 {
        held.append((f, "patch does not apply: " + pyPrefix(chk.stderr.trimmingCharacters(in: .whitespacesAndNewlines), 200))); continue
    }
    if dry { applied.append((f, "would apply")); continue }
    _ = sh("git apply --3way \(pth)")
    let touched = sh("git status --porcelain").stdout
    let prod = pySplitlines(touched).filter { l in matches(prodRegex, l) && !matches(exclRegex, l) }
    if !prod.isEmpty {
        _ = sh("git reset -q -- Modules Sources tests iOS script && git checkout -q -- Modules Sources tests iOS script && git clean -fdq -- Modules Sources tests iOS script")
        held.append((f, "patch touches production sources: " + pyPrefix(prod.joined(separator: " "), 200))); continue
    }
    let t = sh(FILTER[f] ?? ROOT + "NativeAgentAppTests")
    let ok = t.returncode == 0
    let tail = pySplitlines(t.stdout).suffix(30)
    let summary = pySuffix(tail.filter { $0.contains("Test run with") || $0.contains("assertions") || $0.contains("failed") }.joined(), 300)
    if !ok {
        _ = sh("git reset -q -- Modules Sources tests iOS script && git checkout -q -- Modules Sources tests iOS script && git clean -fdq -- Modules Sources tests iOS script")
        held.append((f, "tests failed here: " + summary)); continue
    }
    let coveredList = (pyTruthy(b["covered"]) ? b["covered"] as? [Any] : []) ?? []
    let cov = coveredList.prefix(12).map { pyStr(($0 as? [String: Any])?["id"]) }.joined(separator: ", ")
    let msg = "evals(\(f)): \(coveredList.count) surface(s) now asserted\n\nLedger ids: \(cov)\(coveredList.count > 12 ? " …" : "")\nVerifier: \(pyPrefix(pyStr(v["output"]), 300))\nMutation: \(pyPrefix(pyStr(v["mutationChecked"]), 200))\n"
    _ = sh("git add -A Modules/NativeAgentCore/Tests tests iOS script/agent_instrument.swift tests/scripts 2>/dev/null")
    let c = sh("git commit -q -F - <<\"EOF\"\n\(msg)\nEOF")
    if c.returncode != 0 {
        _ = sh("git reset -q && git reset -q -- Modules Sources tests iOS script && git checkout -q -- Modules Sources tests iOS script && git clean -fdq -- Modules Sources tests iOS script")
        held.append((f, "commit BLOCKED (hook): " + pySuffix((c.stdout + c.stderr).trimmingCharacters(in: .whitespacesAndNewlines), 200))); continue
    }
    applied.append((f, summary.isEmpty ? "green" : summary))
}
print("APPLIED:")
for (f, s) in applied { print(" ", f, "—", s) }
print("HELD:")
for (f, s) in held { print(" ", f, "—", s) }
