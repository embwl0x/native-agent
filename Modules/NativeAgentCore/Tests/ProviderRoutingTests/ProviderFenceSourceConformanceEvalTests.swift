import Foundation
import Testing
import NativeAgentTestSupport
@testable import ProviderRouting

// MARK: - Source-conformance evals for the core.providers fence
//
// Three ledger rows here are WIRING facts, not runtime values: whether a guard
// sits on every dispatch path, whether every adapter emits telemetry, whether
// every construction site hands the vitals organ its observer. A hermetic
// runtime test can only ever exercise the site it was written against — the
// silent failure is a NEW site joining the ungated set. So these scan the
// source tree and assert a SUBSET relation against a dated known-gap list:
// closing a gap keeps them green (the set shrinks), opening a new one fails.
//
// Rows:
//   llm.router.nativeToolsGate.nonStreamingPaths   (UNCOVERED)
//   telemetry.llmCallRow.missingFromOpenRouterAndCodexAdapters (UNCOVERED)
//   vitals.lifecycleObserverWiring                 (REPORTS-ONLY)
//   env.NATIVE_AGENT_LLM_BODY_DUMP_DIR             (UNCOVERED)

private enum FenceSource {
    static func repoRoot() throws -> URL { try SourceTreeRepoRoot.locate() }

    static func read(_ root: URL, _ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Every `*.swift` under the production source trees (never Tests/).
    static func productionSwiftFiles(_ root: URL) -> [URL] {
        var out: [URL] = []
        var roots: [URL] = [root.appendingPathComponent("Sources", isDirectory: true)]
        let modules = root.appendingPathComponent("Modules", isDirectory: true)
        let moduleDirs = (try? FileManager.default.contentsOfDirectory(
            at: modules, includingPropertiesForKeys: nil)) ?? []
        for module in moduleDirs {
            roots.append(module.appendingPathComponent("Sources", isDirectory: true))
        }
        for base in roots {
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if url.path.contains("/.build/") { continue }
                out.append(url)
            }
        }
        return out
    }

    /// Balanced-paren argument list for each `needle(` occurrence in `source`.
    static func callArgumentLists(_ source: String, needle: String) -> [(line: Int, args: String)] {
        var out: [(Int, String)] = []
        let chars = Array(source)
        var search = source.startIndex
        while let found = source.range(of: needle + "(", range: search..<source.endIndex) {
            let openOffset = source.distance(from: source.startIndex, to: found.upperBound)
            var depth = 1
            var i = openOffset
            while i < chars.count, depth > 0 {
                if chars[i] == "(" { depth += 1 }
                else if chars[i] == ")" { depth -= 1 }
                i += 1
            }
            let args = String(chars[openOffset..<max(openOffset, i - 1)])
            let line = source[source.startIndex..<found.lowerBound].filter { $0 == "\n" }.count + 1
            out.append((line, args))
            search = source.index(source.startIndex, offsetBy: min(i, chars.count))
        }
        return out
    }
}

// `.serialized`: the body-dump runtime test mutates the PROCESS environment.
@Suite("core.providers source conformance", .serialized)
struct ProviderFenceSourceConformanceEvalTests {

    // MARK: llm.router.nativeToolsGate.nonStreamingPaths

    /// The F1-M1 guard ("native tools[] bound to a non-native Anthropic-family
    /// adapter") protects the documented invariant that a Claude subscription
    /// connection is NEVER handed a provider-native tools array. It lives in
    /// exactly one of the router's three tools-carrying `.anthropic` dispatch
    /// blocks.
    ///
    /// Envelope: the set of tools-forwarding `.anthropic` dispatch blocks that
    /// carry NO `NativeToolCapability` check is a SUBSET of the dated known-gap
    /// list below. Adding the guard to `complete`/`completeMessages` shrinks
    /// the set and keeps this green; adding a FOURTH ungated tools-forwarding
    /// path fails it by name.
    ///
    /// KNOWN GAPS (2026-08-23, ledger row llm.router.nativeToolsGate.
    /// nonStreamingPaths): `complete(prompt:system:model:surface:tools:)` and
    /// `completeMessages(...tools:)` pass `tools:` straight into
    /// `anthropicAdapter(for:)`. Production seam required to close them.
    @Test func everyToolsForwardingAnthropicDispatch_isGated_orIsAKnownGap() throws {
        let root = try FenceSource.repoRoot()
        let relative = "Modules/NativeAgentCore/Sources/ProviderRouting/LLMClient+Real.swift"
        let lines = try FenceSource.read(root, relative).components(separatedBy: "\n")

        var toolsForwarding: [(function: String, line: Int, gated: Bool)] = []
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "case .anthropic:" {
            let indent = line.prefix { $0 == " " }.count
            var block: [String] = []
            var cursor = index + 1
            while cursor < lines.count {
                let candidate = lines[cursor]
                let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                let candidateIndent = candidate.prefix { $0 == " " }.count
                if trimmed.hasPrefix("case "), candidateIndent <= indent { break }
                if trimmed.hasPrefix("}"), candidateIndent < indent { break }
                block.append(candidate)
                cursor += 1
            }
            // CODE only. The gate is a live `if`, not the paragraph of comment
            // above it — a mutation that deletes the check but leaves the
            // comment must still fail here (proven by mutation, 2026-08-23).
            let code = block
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let body = block.joined(separator: "\n")
            guard body.contains("tools: tools") else { continue }

            // Enclosing type-level method: the nearest preceding 4-space `func`.
            var function = "<unknown>"
            var back = index
            while back >= 0 {
                let candidate = lines[back]
                if candidate.hasPrefix("    func ") || candidate.hasPrefix("    public func ")
                    || candidate.hasPrefix("    private func ") || candidate.hasPrefix("    internal func ") {
                    if let open = candidate.firstIndex(of: "("),
                       let funcRange = candidate.range(of: "func ") {
                        function = String(candidate[funcRange.upperBound..<open])
                    }
                    break
                }
                back -= 1
            }
            toolsForwarding.append((function, index + 1, code.contains("NativeToolCapability")))
        }

        #expect(
            toolsForwarding.count >= 3,
            "expected the three tools-carrying .anthropic dispatch blocks; found \(toolsForwarding.count) — the scan lost its anchor and would pass vacuously"
        )
        #expect(
            toolsForwarding.contains { $0.gated },
            "at least one dispatch path must still carry the F1-M1 gate"
        )

        let knownGaps: Set<String> = ["complete", "completeMessages"]
        let ungated = Set(toolsForwarding.filter { !$0.gated }.map { $0.function })
        let newlyUngated = ungated.subtracting(knownGaps).sorted()
        #expect(
            newlyUngated.isEmpty,
            "new tools-forwarding .anthropic dispatch path(s) with no NativeToolCapability gate: \(newlyUngated) in \(relative). Provider-native tools[] must never reach a Claude-subscription adapter."
        )
    }

    // MARK: telemetry.llmCallRow.missingFromOpenRouterAndCodexAdapters

    /// SILENT ZERO, live-confirmed: two of the eight adapters emit no
    /// `llm.call` row at all, so every OpenRouter turn and every Codex-CLI
    /// turn costs money and leaves no token count, latency, or cache number —
    /// and the instrument's in-window call count reads healthy while
    /// under-reporting by exactly that traffic.
    ///
    /// Envelope: the set of router-dispatchable adapters with no
    /// `LLMCallTraceRecorder` call is a SUBSET of the dated known-gap list.
    /// Wiring telemetry into either adapter shrinks it (stays green); a NEW
    /// adapter shipped without telemetry fails by filename.
    ///
    /// KNOWN GAPS (2026-08-23): OpenRouter and Codex.
    @Test func everyProviderAdapter_emitsAnLLMCallRow_orIsAKnownGap() throws {
        let root = try FenceSource.repoRoot()
        let dir = root.appendingPathComponent(
            "Modules/NativeAgentCore/Sources/ProviderRouting", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("LLMClient+")
                   && $0.lastPathComponent.hasSuffix("Adapter.swift") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(files.count >= 8, "expected the full adapter set, found \(files.count) — a scan that finds nothing passes vacuously")

        var silent: [String] = []
        var instrumented: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("LLMCallTraceRecorder"), source.contains(".record(") {
                instrumented.append(file.lastPathComponent)
            } else {
                silent.append(file.lastPathComponent)
            }
        }

        #expect(instrumented.count >= 6, "most adapters must be instrumented; got \(instrumented)")
        let knownGaps: Set<String> = [
            "LLMClient+OpenRouterAdapter.swift",
            "LLMClient+CodexAdapter.swift",
        ]
        let newlySilent = Set(silent).subtracting(knownGaps).sorted()
        #expect(
            newlySilent.isEmpty,
            "adapter(s) dispatch provider calls but emit no llm.call telemetry row: \(newlySilent). Every provider call must be countable, or the model-time roll-up silently under-reports."
        )
    }

    // MARK: vitals.lifecycleObserverWiring

    /// The provider vitals organ is fed by a SINGLE optional constructor
    /// argument that defaults to nil — not a registry. Every construction site
    /// that omits it makes that whole lane invisible to vitals with no compile
    /// error and no log line.
    ///
    /// Envelope: EVERY production construction of `SwiftNativeLLMClient`
    /// passes a `lifecycleObserver:` argument. This is green today across all
    /// seven sites; a new site that forgets fails by file and line.
    @Test func everyProductionLLMClientConstruction_bindsTheLifecycleObserver() throws {
        let root = try FenceSource.repoRoot()
        var unobserved: [String] = []
        var total = 0
        for file in FenceSource.productionSwiftFiles(root) {
            guard let source = try? String(contentsOf: file, encoding: .utf8),
                  source.contains("SwiftNativeLLMClient(") else { continue }
            for call in FenceSource.callArgumentLists(source, needle: "SwiftNativeLLMClient") {
                total += 1
                if !call.args.contains("lifecycleObserver") {
                    let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                    unobserved.append("\(relative):\(call.line)")
                }
            }
        }

        #expect(total >= 7, "expected at least the seven known construction sites, found \(total) — the scan lost its anchor")
        #expect(
            unobserved.isEmpty,
            "SwiftNativeLLMClient construction site(s) with no lifecycleObserver — that lane is invisible to the provider vitals organ: \(unobserved.sorted())"
        )
    }

    // MARK: env.NATIVE_AGENT_LLM_BODY_DUMP_DIR

    /// A debug lever that dumps FULL request bodies — system prompt, persona,
    /// memory recall, conversation — to an arbitrary directory, written with
    /// `try?` so failures are invisible.
    ///
    /// Envelope: every production reader of the variable sits inside a
    /// `#if DEBUG` region (so no shipped build can be switched on by a stray
    /// environment entry), and nothing under `script/` or any bundled plist
    /// sets it.
    @Test func bodyDumpLever_isCompiledOutOfReleaseBuilds_andNeverSetByAShippedArtifact() throws {
        let root = try FenceSource.repoRoot()
        let variable = "NATIVE_AGENT_LLM_BODY_DUMP_DIR"

        var readerFiles: [String] = []
        var readersOutsideDebug: [String] = []
        for file in FenceSource.productionSwiftFiles(root) {
            guard let source = try? String(contentsOf: file, encoding: .utf8),
                  source.contains(variable) else { continue }
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            readerFiles.append(relative)
            var debugDepth = 0
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if DEBUG") { debugDepth += 1 }
                else if trimmed.hasPrefix("#endif") { debugDepth = max(0, debugDepth - 1) }
                guard line.contains(variable) else { continue }
                // Documentation mentions are not readers.
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") { continue }
                if debugDepth == 0 {
                    readersOutsideDebug.append("\(relative):\(index + 1)")
                }
            }
        }

        #expect(!readerFiles.isEmpty, "the lever must still exist for this guard to mean anything")
        #expect(
            readersOutsideDebug.isEmpty,
            "\(variable) is read outside #if DEBUG — a release build could dump full request bodies to disk: \(readersOutsideDebug)"
        )

        // Nothing that ships (or launches the app) may SET it.
        var setters: [String] = []
        let scriptDir = root.appendingPathComponent("script", isDirectory: true)
        if let walker = FileManager.default.enumerator(at: scriptDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                guard ["sh", "swift", "py", "plist"].contains(url.pathExtension) else { continue }
                guard let source = try? String(contentsOf: url, encoding: .utf8),
                      source.contains(variable) else { continue }
                setters.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        if let walker = FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources", isDirectory: true),
            includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "plist" {
                guard let source = try? String(contentsOf: url, encoding: .utf8),
                      source.contains(variable) else { continue }
                setters.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        #expect(
            setters.isEmpty,
            "\(variable) is referenced by a shipped/launch artifact: \(setters). Full prompt bodies would land on disk silently."
        )
    }

    /// Runtime half of the same row: with the variable UNSET the dumper writes
    /// nothing at all. The positive control fires it deliberately first, so a
    /// dumper that had been silently no-op'd could not make the "off by
    /// default" assertion pass vacuously.
    @Test func bodyDump_writesNothingWhenTheLeverIsUnset() throws {
        let variable = "NATIVE_AGENT_LLM_BODY_DUMP_DIR"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("body-dump-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            unsetenv(variable)
            try? FileManager.default.removeItem(at: dir)
        }
        let body: [String: Any] = ["model": "claude-opus-4-8", "messages": []]

        // Negative control FIRST: unset → nothing written anywhere.
        unsetenv(variable)
        AnthropicOAuthDirectAdapter.dumpBodyIfEnabled(body, call: "evalOff")
        var files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.isEmpty, "the body dumper must be OFF unless the lever is set, found \(files)")

        // Positive control: prove the dumper is reachable at all, so the
        // assertion above is a real guard and not a dead call.
        setenv(variable, dir.path, 1)
        AnthropicOAuthDirectAdapter.dumpBodyIfEnabled(body, call: "evalOn")
        files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1, "positive control: the dumper must write exactly one file when enabled, found \(files)")
        #expect(files.first?.contains("evalOn") == true)

        // And back off again.
        unsetenv(variable)
        AnthropicOAuthDirectAdapter.dumpBodyIfEnabled(body, call: "evalOffAgain")
        files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1, "clearing the lever must stop the dump, found \(files)")
    }
}
