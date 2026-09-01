#!/usr/bin/env swift
// Merge eval-coverage ledger fragments (docs/evals/ledger.schema.json shape) into
// docs/evals/ledger.json and render docs/evals/COVERAGE.md.
//
// usage: swift script/evals_ledger_merge.swift <fragments.json> [--out docs/evals]
//        [--overrides docs/evals/coverage-overrides.json]
//        [--campaigns docs/evals/coverage-campaigns.json]
//        swift script/evals_ledger_merge.swift changed-plan --repo ROOT
//        --ledger FILE --sha SHA --selections FILE --mappings FILE
//        --unmapped FILE --changed-files FILE
//        swift script/evals_ledger_merge.swift validate-overrides --repo ROOT
//        --overrides FILE
// fragments.json = the phase-1 workflow return: [{fence, fragment, critic}, ...]
// Critic 'missed' surfaces are merged in (tagged source=critic); 'disputed' ids are
// annotated, never dropped — the ledger shows the dispute.
//
// Direct port of script/evals_ledger_merge.py (retired 2026-08-23, zero-Python canon).
// Behavior is byte-identical: dedupe keeps the FIRST row and unions coverage;
// Coverage entries without an explicit `strength` are incidental, never
// asserting. Optional overrides are keyed by (fence,id) and are the durable
// source for post-inventory eval work; generated ledger files are never the
// source of truth.

import Foundation
import Darwin

// MARK: - Changed-commit execution plan

private struct ChangedLedger: Decodable {
    let surfaces: [ChangedSurface]
}

private struct ChangedSurface: Decodable {
    let fence: String
    let id: String
    let whereText: String
    let coverage: [ChangedCoverage]

    private enum CodingKeys: String, CodingKey {
        case fence, id, coverage
        case whereText = "where"
    }
}

private struct ChangedCoverage: Decodable {
    let ref: String
    let tier: String
}

private struct ChangedSelectionKey: Hashable {
    let packageLabel: String
    let packagePath: String
    let filter: String
}

private struct ChangedSurfaceIdentity: Hashable {
    let fence: String
    let id: String
    let whereText: String
}

private struct ChangedArguments {
    let repo: String
    let ledger: String
    let sha: String
    let selections: String
    let mappings: String
    let unmapped: String
    let changedFiles: String
}

private func changedFail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("evals --changed: \(message)\n".utf8))
    exit(2)
}

private func parseChangedArguments(_ arguments: [String]) -> ChangedArguments {
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let name = arguments[index]
        guard name.hasPrefix("--"), index + 1 < arguments.count else {
            changedFail("expected --name value arguments")
        }
        values[name] = arguments[index + 1]
        index += 2
    }
    func required(_ name: String) -> String {
        guard let value = values[name], !value.isEmpty else { changedFail("missing \(name)") }
        return value
    }
    return ChangedArguments(
        repo: required("--repo"), ledger: required("--ledger"), sha: required("--sha"),
        selections: required("--selections"), mappings: required("--mappings"),
        unmapped: required("--unmapped"), changedFiles: required("--changed-files")
    )
}

private struct ChangedCommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func changedRunGit(_ arguments: [String]) -> ChangedCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
        try process.run()
    } catch {
        changedFail("could not launch git: \(error)")
    }
    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ChangedCommandResult(
        status: process.terminationStatus,
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self)
    )
}

private func changedSanitizeTSV(_ value: String) -> String {
    value.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

private func changedWriteLines(_ lines: [String], to path: String) {
    let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        changedFail("could not write plan output \(path): \(error)")
    }
}

// The lookbehind anchors the match at a path-token boundary: without it,
// `iOS/NativeAgentMobile/Tests/Foo.swift` substring-matched at `Tests/` and
// got planned into the root package. iOS evidence is a first-class changed
// selection now and runs through the simulator runner, never SwiftPM.
private let changedExecutableTestPathPattern = try! NSRegularExpression(
    pattern: #"(?<![\w/-])(?:iOS/NativeAgentMobile/Tests|Modules/NativeAgentCore/Tests|Modules/NativeAgentShared/Tests|tests|Tests)/[^\s:()—]+\.swift"#
)

private let changedExecutableSmokePathPattern = try! NSRegularExpression(
    pattern: #"executable:\s+((?:script|tests/scripts)/[^\s:()—]+)"#
)

private func changedExecutableTestPaths(in ref: String) -> [String] {
    let range = NSRange(ref.startIndex..<ref.endIndex, in: ref)
    return changedExecutableTestPathPattern.matches(in: ref, range: range).compactMap { match in
        Range(match.range, in: ref).map { String(ref[$0]) }
    }
}

private func changedExecutableSmokePaths(in ref: String) -> [String] {
    let range = NSRange(ref.startIndex..<ref.endIndex, in: ref)
    return changedExecutableSmokePathPattern.matches(in: ref, range: range).compactMap { match in
        guard match.numberOfRanges == 2, let pathRange = Range(match.range(at: 1), in: ref) else {
            return nil
        }
        return String(ref[pathRange])
    }
}

private func changedExpandTestGlob(_ path: String, repo: String) -> [String] {
    let directory = (path as NSString).deletingLastPathComponent
    let pattern = (path as NSString).lastPathComponent
    guard !directory.contains("*") && !directory.contains("?") && !directory.contains("[") else {
        return []
    }
    let directoryURL = URL(fileURLWithPath: repo).appendingPathComponent(directory)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
        return []
    }
    return names.filter { fnmatch(pattern, $0, 0) == 0 }
        .map { directory.isEmpty ? $0 : "\(directory)/\($0)" }
        .sorted()
}

private func changedPotentialTestPaths(for path: String, repo: String) -> [String] {
    let hasGlob = path.contains("*") || path.contains("?") || path.contains("[")
    if path.hasPrefix("iOS/NativeAgentMobile/Tests/")
        || path.hasPrefix("Modules/NativeAgentCore/Tests/")
        || path.hasPrefix("Modules/NativeAgentShared/Tests/")
        || path.hasPrefix("tests/") {
        // An explicit package path is unambiguous even after deletion. Keep it
        // in the affected set so removing a test still selects (and likely
        // fails) the ledger surface that claimed it as evidence.
        return hasGlob ? changedExpandTestGlob(path, repo: repo) : [path]
    }
    guard path.hasPrefix("Tests/") else { return [] }
    // Some package ledgers use SwiftPM package-relative test paths. Resolve
    // those against every package root instead of silently treating them as
    // root tests. Missing or duplicate matches are intentionally unresolved so
    // changed-mode fails closed rather than running the wrong package.
    let candidates = [
        path,
        "Modules/NativeAgentCore/\(path)",
        "Modules/NativeAgentShared/\(path)",
    ]
    let matchesByPackage = candidates.map { candidate -> [String] in
        if hasGlob { return changedExpandTestGlob(candidate, repo: repo) }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: repo)
            .appendingPathComponent(candidate).path) ? [candidate] : []
    }
    return matchesByPackage.flatMap { $0 }
}

private func changedResolvedTestPaths(for path: String, repo: String) -> [String] {
    let matches = changedPotentialTestPaths(for: path, repo: repo)
    guard path.hasPrefix("Tests/") else { return matches }
    let packageLabels = Set(matches.map { match -> String in
        if match.hasPrefix("Modules/NativeAgentCore/") { return "core" }
        if match.hasPrefix("Modules/NativeAgentShared/") { return "shared" }
        return "root"
    })
    guard packageLabels.count == 1 else { return [] }
    return matches
}

private func changedSelection(forCanonicalPath path: String) -> ChangedSelectionKey? {
    let packageLabel: String
    let packagePath: String
    if path.hasPrefix("Modules/NativeAgentCore/Tests/") {
        packageLabel = "NativeAgentCore"
        packagePath = "Modules/NativeAgentCore"
    } else if path.hasPrefix("Modules/NativeAgentShared/Tests/") {
        packageLabel = "NativeAgentShared"
        packagePath = "Modules/NativeAgentShared"
    } else if path.hasPrefix("tests/") || path.hasPrefix("Tests/") {
        packageLabel = "root"
        packagePath = "."
    } else if path.hasPrefix("iOS/NativeAgentMobile/Tests/") {
        packageLabel = "ios"
        packagePath = "iOS/NativeAgentMobile"
    } else {
        return nil
    }
    let filter = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard !filter.isEmpty else { return nil }
    return ChangedSelectionKey(packageLabel: packageLabel, packagePath: packagePath, filter: filter)
}

private func changedSelections(for path: String, repo: String) -> [ChangedSelectionKey] {
    changedResolvedTestPaths(for: path, repo: repo).compactMap(changedSelection(forCanonicalPath:))
}

private func changedCoverageSelections(for ref: String, repo: String) -> [ChangedSelectionKey] {
    let paths = changedExecutableTestPaths(in: ref)
    if ref.contains("[xcode-filter:") {
        let pattern = try! NSRegularExpression(pattern: #"\[xcode-filter: ([A-Za-z_][A-Za-z0-9_]*)\]"#)
        let matches = pattern.matches(in: ref, range: NSRange(ref.startIndex..., in: ref))
        guard paths.count == 1, matches.count == 1,
              ref.components(separatedBy: "[xcode-filter:").count == 2,
              paths[0].hasPrefix("iOS/NativeAgentMobile/Tests/"),
              let suiteRange = Range(matches[0].range(at: 1), in: ref),
              let source = try? String(contentsOf: URL(fileURLWithPath: repo).appendingPathComponent(paths[0]), encoding: .utf8) else { return [] }
        let suite = String(ref[suiteRange])
        let declaration = #"\b(?:struct|class|enum)\s+"# + NSRegularExpression.escapedPattern(for: suite) + #"\b"#
        guard source.range(of: declaration, options: .regularExpression) != nil else { return [] }
        return [ChangedSelectionKey(packageLabel: "ios", packagePath: "iOS/NativeAgentMobile", filter: suite)]
    }
    guard ref.contains("[swift-filter:") else {
        return paths.flatMap { changedSelections(for: $0, repo: repo) }
    }
    // An explicit suite is attached to exactly one fully-qualified, existing
    // test file. Never interpret metadata as a shell command or free-form regex.
    let pattern = try! NSRegularExpression(pattern: #"\[swift-filter: ([A-Za-z_][A-Za-z0-9_]*)\]"#)
    let matches = pattern.matches(in: ref, range: NSRange(ref.startIndex..., in: ref))
    guard paths.count == 1, matches.count == 1,
          ref.components(separatedBy: "[swift-filter:").count == 2,
          let suiteRange = Range(matches[0].range(at: 1), in: ref) else { return [] }
    let path = paths[0]
    guard !path.hasPrefix("Tests/"),
          !path.contains(".."), !path.contains("*"), !path.contains("?"), !path.contains("["),
          let selection = changedSelection(forCanonicalPath: path) else { return [] }
    let root = URL(fileURLWithPath: repo)
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(selection.packagePath)
        .appendingPathComponent("Package.swift").path),
          let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { return [] }
    let suite = String(ref[suiteRange])
    let declaration = #"\b(?:struct|class|enum)\s+"# + NSRegularExpression.escapedPattern(for: suite) + #"\b"#
    guard source.range(of: declaration, options: .regularExpression) != nil else { return [] }
    let components = path.split(separator: "/").map(String.init)
    guard let testsIndex = components.firstIndex(where: { $0 == "Tests" || $0 == "tests" }),
          components.count > testsIndex + 2 else { return [] }
    let target = components[testsIndex + 1]
    guard target.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { return [] }
    return [ChangedSelectionKey(packageLabel: selection.packageLabel, packagePath: selection.packagePath,
        filter: "^" + NSRegularExpression.escapedPattern(for: target) + "\\."
            + NSRegularExpression.escapedPattern(for: suite) + "[./]")]
}

private func changedTestReference(_ path: String, matches changedPath: String) -> Bool {
    let patterns: [String]
    if path.hasPrefix("Tests/") {
        patterns = [
            path,
            "Modules/NativeAgentCore/\(path)",
            "Modules/NativeAgentShared/\(path)",
        ]
    } else {
        patterns = [path]
    }
    return patterns.contains { fnmatch($0, changedPath, FNM_PATHNAME) == 0 }
}

private func validateOverrideReferences(_ rawArguments: [String]) {
    var values: [String: String] = [:]
    var index = 0
    while index < rawArguments.count {
        guard rawArguments[index].hasPrefix("--"), index + 1 < rawArguments.count else {
            changedFail("validate-overrides expects --repo ROOT --overrides FILE")
        }
        values[rawArguments[index]] = rawArguments[index + 1]
        index += 2
    }
    guard let repo = values["--repo"], !repo.isEmpty,
          let path = values["--overrides"], !path.isEmpty,
          let data = FileManager.default.contents(atPath: path),
          let patches = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        changedFail("validate-overrides could not read its repo/overrides inputs")
    }

    var failures: [String] = []
    for patch in patches {
        let identity = "\(patch["fence"] as? String ?? "?").\(patch["id"] as? String ?? "?")"
        for case let coverage as [String: Any] in patch["coverage"] as? [Any] ?? [] {
            guard coverage["tier"] as? String == "test",
                  let ref = coverage["ref"] as? String else { continue }
            for testPath in changedExecutableTestPaths(in: ref) {
                let resolved = changedResolvedTestPaths(for: testPath, repo: repo)
                if resolved.isEmpty {
                    failures.append("\(identity): unresolved test path \(testPath)")
                    continue
                }
                let escaped = NSRegularExpression.escapedPattern(for: testPath)
                let linePattern = try! NSRegularExpression(pattern: escaped + #":([0-9]+)"#)
                let refRange = NSRange(ref.startIndex..<ref.endIndex, in: ref)
                let lineNumbers = linePattern.matches(in: ref, range: refRange).compactMap { match -> Int? in
                    guard let range = Range(match.range(at: 1), in: ref) else { return nil }
                    return Int(ref[range])
                }
                for resolvedPath in resolved {
                    let url = URL(fileURLWithPath: repo).appendingPathComponent(resolvedPath)
                    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                        failures.append("\(identity): unreadable test path \(resolvedPath)")
                        continue
                    }
                    let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
                    for line in lineNumbers where line > lineCount {
                        failures.append("\(identity): stale line \(testPath):\(line) (file has \(lineCount))")
                    }
                }
            }
            if (ref.contains("[swift-filter:") || ref.contains("[xcode-filter:")),
               changedCoverageSelections(for: ref, repo: repo).isEmpty {
                failures.append("\(identity): stale or ambiguous swift-filter reference")
            }
        }
    }
    guard failures.isEmpty else {
        changedFail("override reference integrity failed:\n  " + failures.sorted().joined(separator: "\n  "))
    }
    print("eval override references resolve")
}


private func changedSmokeSelection(for path: String) -> ChangedSelectionKey? {
    guard (path.hasPrefix("script/") || path.hasPrefix("tests/scripts/")),
          !path.contains("..") else { return nil }
    return ChangedSelectionKey(packageLabel: "script", packagePath: ".", filter: path)
}

private func changedRequiresProductionMapping(_ path: String) -> Bool {
    if path == "Package.swift" { return true }
    if path.hasPrefix("Sources/") || path.hasPrefix("Shared/")
        || path.hasPrefix("NativeAgentChromeRelay/") { return true }
    if path.hasPrefix("Modules/") {
        return path.contains("/Sources/") || path.hasSuffix("/Package.swift")
    }
    if path.hasPrefix("iOS/") {
        let components = path.split(separator: "/")
        return path.hasSuffix(".swift") && !components.contains("Tests")
    }
    return false
}

private func runChangedPlan(_ rawArguments: [String]) {
    let arguments = parseChangedArguments(rawArguments)
    guard arguments.sha.range(of: #"^[0-9a-fA-F]{7,64}$"#, options: .regularExpression) != nil else {
        changedFail("malformed commit SHA '\(arguments.sha)'")
    }
    let verified = changedRunGit([
        "-C", arguments.repo, "rev-parse", "--verify", "--quiet", "\(arguments.sha)^{commit}",
    ])
    guard verified.status == 0 else {
        let detail = verified.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        changedFail("unknown or malformed commit '\(arguments.sha)'\(detail.isEmpty ? "" : ": \(detail)")")
    }
    let canonicalSHA = verified.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canonicalSHA.range(of: #"^[0-9a-fA-F]{7,64}$"#, options: .regularExpression) != nil else {
        changedFail("git returned an invalid object id for '\(arguments.sha)'")
    }

    let diff = changedRunGit([
        "-C", arguments.repo, "diff-tree", "--root", "--no-commit-id", "--name-only", "-r",
        "--diff-filter=ACDMRTUXB", canonicalSHA,
    ])
    guard diff.status == 0 else {
        let detail = diff.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        changedFail("could not read changed files for \(canonicalSHA)\(detail.isEmpty ? "" : ": \(detail)")")
    }
    let changed = Array(Set(diff.stdout.split(whereSeparator: \.isNewline).map(String.init))).sorted()
    changedWriteLines(changed, to: arguments.changedFiles)

    let ledger: ChangedLedger
    do {
        ledger = try JSONDecoder().decode(
            ChangedLedger.self, from: Data(contentsOf: URL(fileURLWithPath: arguments.ledger)))
    } catch {
        changedFail("could not decode \(arguments.ledger): \(error)")
    }

    var mapped: [ChangedSelectionKey: Set<ChangedSurfaceIdentity>] = [:]
    var unresolved: Set<ChangedSurfaceIdentity> = []
    var attributedPaths: Set<String> = []
    for surface in ledger.surfaces {
        let testReferencePaths = surface.coverage.flatMap {
            changedExecutableTestPaths(in: $0.ref)
        }
        let coveragePaths = testReferencePaths.flatMap {
            changedPotentialTestPaths(for: $0, repo: arguments.repo)
        } + surface.coverage.flatMap { changedExecutableSmokePaths(in: $0.ref) }
        let affectedPaths = changed.filter { path in
            surface.whereText.contains(path)
                || coveragePaths.contains(path)
                || testReferencePaths.contains { changedTestReference($0, matches: path) }
        }
        guard !affectedPaths.isEmpty else { continue }
        attributedPaths.formUnion(affectedPaths)

        let identity = ChangedSurfaceIdentity(
            fence: surface.fence, id: surface.id, whereText: surface.whereText)
        let selections = Set(surface.coverage.flatMap { coverage -> [ChangedSelectionKey] in
            var result: [ChangedSelectionKey] = []
            if ["test", "smoke", "bench", "turn-replay"].contains(coverage.tier) {
                result += changedCoverageSelections(for: coverage.ref, repo: arguments.repo)
            }
            if coverage.tier == "smoke" {
                result += changedExecutableSmokePaths(in: coverage.ref).compactMap(changedSmokeSelection(for:))
            }
            return result
        })
        if selections.isEmpty {
            unresolved.insert(identity)
        } else {
            for key in selections { mapped[key, default: []].insert(identity) }
        }
    }

    // A mapped sibling must not hide a newly added or otherwise unrepresented
    // production owner. The keeper enumerates modules/screens/tools, not every
    // source file; its passing receipt cannot establish coverage for this path.
    for path in changed where changedRequiresProductionMapping(path) && !attributedPaths.contains(path) {
        unresolved.insert(ChangedSurfaceIdentity(
            fence: "changed-production", id: "unmapped-production:\(path)",
            whereText: "\(path) — no ledger owner; add an executable coverage mapping or use the full gate"))
    }

    let orderedSelections = mapped.keys.sorted {
        ($0.packageLabel, $0.filter, $0.packagePath) < ($1.packageLabel, $1.filter, $1.packagePath)
    }
    changedWriteLines(orderedSelections.map {
        [changedSanitizeTSV($0.packageLabel), changedSanitizeTSV($0.packagePath),
         changedSanitizeTSV($0.filter)].joined(separator: "\t")
    }, to: arguments.selections)

    var mappingLines: [String] = []
    for key in orderedSelections {
        let surfaces = (mapped[key] ?? []).sorted { ($0.id, $0.whereText) < ($1.id, $1.whereText) }
        for surface in surfaces {
            mappingLines.append([
                changedSanitizeTSV(key.packageLabel), changedSanitizeTSV(key.filter),
                changedSanitizeTSV(surface.id), changedSanitizeTSV(surface.whereText),
                changedSanitizeTSV(surface.fence),
            ].joined(separator: "\t"))
        }
    }
    changedWriteLines(mappingLines, to: arguments.mappings)

    let unresolvedLines = unresolved.sorted {
        ($0.id, $0.whereText) < ($1.id, $1.whereText)
    }.map {
        [changedSanitizeTSV($0.id), changedSanitizeTSV($0.whereText),
         changedSanitizeTSV($0.fence)].joined(separator: "\t")
    }
    changedWriteLines(unresolvedLines, to: arguments.unmapped)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "validate-overrides" {
    validateOverrideReferences(Array(CommandLine.arguments.dropFirst(2)))
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "changed-plan" {
    runChangedPlan(Array(CommandLine.arguments.dropFirst(2)))
    exit(0)
}

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

/// Python code-point string comparison (sorted(), sort_keys use this).
func pyLess(_ a: String, _ b: String) -> Bool {
    var ai = a.unicodeScalars.makeIterator(), bi = b.unicodeScalars.makeIterator()
    while true {
        switch (ai.next(), bi.next()) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?):
            if x.value != y.value { return x.value < y.value }
        }
    }
}

/// json.dumps string escaping with ensure_ascii=True.
func pyJSONString(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{09}": out += "\\t"
        case "\u{0A}": out += "\\n"
        case "\u{0C}": out += "\\f"
        case "\u{0D}": out += "\\r"
        default:
            if u.value < 0x20 {
                out += String(format: "\\u%04x", u.value)
            } else if u.value < 0x7F {
                out.unicodeScalars.append(u)
            } else if u.value <= 0xFFFF {
                out += String(format: "\\u%04x", u.value)
            } else {
                let v = u.value - 0x10000
                out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
            }
        }
    }
    return out + "\""
}

/// json.dump(obj, indent=1, sort_keys=True, ensure_ascii=True) — exact format.
func pyJSON(_ v: Any?, _ level: Int) -> String {
    let pad = String(repeating: " ", count: level + 1)
    let close = String(repeating: " ", count: level)
    guard let v = v, !(v is NSNull) else { return "null" }
    if let n = v as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        if CFNumberIsFloatType(n) { return "\(n.doubleValue)" }
        return "\(n.int64Value)"
    }
    if let s = v as? String { return pyJSONString(s) }
    if let a = v as? [Any] {
        if a.isEmpty { return "[]" }
        let items = a.map { pad + pyJSON($0, level + 1) }
        return "[\n" + items.joined(separator: ",\n") + "\n" + close + "]"
    }
    if let d = v as? [String: Any] {
        if d.isEmpty { return "{}" }
        let keys = d.keys.sorted(by: pyLess)
        let items = keys.map { pad + pyJSONString($0) + ": " + pyJSON(d[$0], level + 1) }
        return "{\n" + items.joined(separator: ",\n") + "\n" + close + "}"
    }
    fatalError("unserializable value: \(v)")
}

/// Counter with Python insertion-order semantics.
struct PyCounter {
    private(set) var counts: [String: Int] = [:]
    private(set) var order: [String] = []
    mutating func add(_ k: String) {
        if counts[k] == nil { order.append(k) }
        counts[k, default: 0] += 1
    }
    subscript(k: String) -> Int { counts[k] ?? 0 }
    /// most_common(): count desc, ties in insertion order (Python's stable sort).
    func mostCommon() -> [(String, Int)] {
        return order.enumerated()
            .sorted { l, r in
                let cl = counts[l.element]!, cr = counts[r.element]!
                if cl != cr { return cl > cr }
                return l.offset < r.offset
            }
            .map { ($0.element, counts[$0.element]!) }
    }
    /// dict(counter) repr — insertion order, Python literal style.
    func dictRepr() -> String {
        if order.isEmpty { return "{}" }
        return "{" + order.map { "'\($0)': \(counts[$0]!)" }.joined(separator: ", ") + "}"
    }
}

// MARK: - Args + load

let argv = CommandLine.arguments
guard argv.count > 1 else {
    FileHandle.standardError.write("usage: swift script/evals_ledger_merge.swift <fragments.json> [--out docs/evals] [--overrides FILE]\n".data(using: .utf8)!)
    exit(1)
}
let src = argv[1]
var out = "docs/evals"
if let i = argv.firstIndex(of: "--out"), i + 1 < argv.count { out = argv[i + 1] }
var overridesPath: String? = nil
if let i = argv.firstIndex(of: "--overrides"), i + 1 < argv.count {
    overridesPath = argv[i + 1]
} else {
    let candidate = URL(fileURLWithPath: src).deletingLastPathComponent()
        .appendingPathComponent("coverage-overrides.json").path
    if FileManager.default.fileExists(atPath: candidate) { overridesPath = candidate }
}
var campaignsPath: String? = nil
if let i = argv.firstIndex(of: "--campaigns"), i + 1 < argv.count {
    campaignsPath = argv[i + 1]
} else {
    let candidate = URL(fileURLWithPath: src).deletingLastPathComponent()
        .appendingPathComponent("coverage-campaigns.json").path
    if FileManager.default.fileExists(atPath: candidate) { campaignsPath = candidate }
}

guard let raw = FileManager.default.contents(atPath: src),
      let data = (try? JSONSerialization.jsonObject(with: raw)) as? [Any] else {
    FileHandle.standardError.write("cannot load fragments array from \(src)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Merge (port of lines 14-38 of the .py)

struct FenceID: Hashable { let fence: String?; let id: String? }

var rows: [[String: Any]] = []
var disputes: [FenceID: Any?] = [:]
var ran: [String: Any] = [:]
var ranOrderMatters = false  // ran/uncertain serialize sorted; order irrelevant
_ = ranOrderMatters
var uncertain: [String: Any] = [:]

let allowedKinds: Set<String> = [
    "public-api", "setting", "ui-control", "ui-summary", "store-write",
    "feed", "loop", "tool", "route", "env", "cli", "telemetry",
    "turn-ingredient", "speed-stage", "other",
]
let allowedTiers: Set<String> = ["instrument", "bench", "test", "smoke", "ui-walk", "turn-replay"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("eval ledger: " + message + "\n").data(using: .utf8)!)
    exit(2)
}

func validateSurface(_ surface: [String: Any], fence: String?) {
    guard let fence, !fence.isEmpty else { fail("surface has no fence") }
    guard let id = str(surface["id"]), !id.isEmpty else { fail("\(fence): surface has no id") }
    guard let kind = str(surface["kind"]), allowedKinds.contains(kind) else {
        fail("\(fence).\(id): unknown or missing kind '\(pyStr(surface["kind"]))'")
    }
    guard let whereText = str(surface["where"]), !whereText.isEmpty else {
        fail("\(fence).\(id): missing where")
    }
    guard let coverageItems = surface["coverage"] as? [Any] else {
        fail("\(fence).\(id): coverage must be an array")
    }
    for (index, item) in coverageItems.enumerated() {
        guard let coverage = item as? [String: Any] else {
            fail("\(fence).\(id): coverage[\(index)] must be an object")
        }
        guard let tier = str(coverage["tier"]), allowedTiers.contains(tier) else {
            fail("\(fence).\(id): invalid coverage tier '\(pyStr(coverage["tier"]))'")
        }
        guard let ref = str(coverage["ref"]), !ref.isEmpty else { fail("\(fence).\(id): coverage ref is empty") }
        if let strength = str(coverage["strength"]), !["asserts", "reports-only", "incidental"].contains(strength) {
            fail("\(fence).\(id): invalid coverage strength '\(strength)'")
        }
        // These exhaustive probes prove only that a registered name reaches a
        // known dispatch boundary. Empty arguments may still be rejected, or
        // the implementation behind that boundary may be behaviorally broken.
        // Never let route reachability alone certify a tool as COVERED.
        let routeOnlyProofs = [
            "everyRegisteredAppToolReachesItsAppOwnedDispatchBoundary",
            "everyCataloguedToolDispatchesWithoutUnknownOrLazyGateDrift",
        ]
        if str(coverage["strength"]) == "asserts",
           routeOnlyProofs.contains(where: ref.contains) {
            fail("\(fence).\(id): route-only coverage must be reports-only, not asserts")
        }
    }
}

func str(_ v: Any?) -> String? { (v is NSNull) ? nil : v as? String }

for (entryIndex, item) in data.enumerated() {
    guard let entry = item as? [String: Any] else {
        fail("fragment[\(entryIndex)] must be an object")
    }
    let fRaw = entry["fence"]
    let f = str(fRaw)
    guard let f, !f.isEmpty else { fail("fragment[\(entryIndex)] has no fence") }
    guard let frag = entry["fragment"] as? [String: Any] else {
        fail("\(f): fragment must be an object")
    }
    guard let crit = entry["critic"] as? [String: Any] else {
        fail("\(f): critic must be an object")
    }
    guard let inventorySurfaces = frag["surfaces"] as? [Any] else {
        fail("\(f): fragment.surfaces must be an array")
    }
    guard let missedSurfaces = crit["missed"] as? [Any] else {
        fail("\(f): critic.missed must be an array")
    }
    guard let disputedSurfaces = crit["disputed"] as? [Any] else {
        fail("\(f): critic.disputed must be an array")
    }
    guard let ranRun = str(frag["ranRun"]), !ranRun.isEmpty else {
        fail("\(f): fragment.ranRun must be a non-empty string")
    }
    guard let uncertainItems = frag["uncertain"] as? [Any] else {
        fail("\(f): fragment.uncertain must be an array")
    }
    ran[f] = ranRun
    uncertain[f] = uncertainItems
    for (surfaceIndex, surface) in inventorySurfaces.enumerated() {
        guard var s = surface as? [String: Any] else {
            fail("\(f): fragment.surfaces[\(surfaceIndex)] must be an object")
        }
        validateSurface(s, fence: f)
        s["fence"] = fRaw ?? NSNull(); s["source"] = "inventory"; rows.append(s)
    }
    for (surfaceIndex, surface) in missedSurfaces.enumerated() {
        guard var s = surface as? [String: Any] else {
            fail("\(f): critic.missed[\(surfaceIndex)] must be an object")
        }
        validateSurface(s, fence: f)
        s["fence"] = fRaw ?? NSNull(); s["source"] = "critic"; rows.append(s)
    }
    for (surfaceIndex, surface) in disputedSurfaces.enumerated() {
        guard let d = surface as? [String: Any] else {
            fail("\(f): critic.disputed[\(surfaceIndex)] must be an object")
        }
        guard let id = str(d["id"]), !id.isEmpty else {
            fail("\(f): critic.disputed[\(surfaceIndex)] has no id")
        }
        guard let why = str(d["why"]), !why.isEmpty else {
            fail("\(f).\(id): disputed reason must be a non-empty string")
        }
        let key = FenceID(fence: f, id: id)
        guard disputes[key] == nil else { fail("duplicate dispute for \(f).\(id)") }
        disputes[key] = why
    }
}

// dedupe by (fence,id): keep the first, union coverage
var seenIndex: [FenceID: Int] = [:]
var deduped: [[String: Any]] = []
for s in rows {
    let k = FenceID(fence: str(s["fence"]), id: str(s["id"]))
    if let i = seenIndex[k] {
        let old = (pyTruthy(deduped[i]["coverage"]) ? deduped[i]["coverage"] as? [Any] : []) ?? []
        let new = (pyTruthy(s["coverage"]) ? s["coverage"] as? [Any] : []) ?? []
        deduped[i]["coverage"] = old + new
        let oldWhere = pyStr(deduped[i]["where"])
        let newWhere = pyStr(s["where"])
        if oldWhere != newWhere {
            deduped[i]["where"] = oldWhere + "; duplicate inventory site: " + newWhere
        }
        continue
    }
    seenIndex[k] = deduped.count
    deduped.append(s)
}
rows = deduped

// Post-inventory work is captured here, not by editing generated ledger.json.
// Each row is a partial surface object keyed by fence + id. Unknown ids are a
// hard error so a rename cannot silently discard hundreds of hours of evals.
if let overridesPath {
    guard let overrideData = FileManager.default.contents(atPath: overridesPath),
          let overrides = try? JSONSerialization.jsonObject(with: overrideData) as? [[String: Any]] else {
        fail("cannot load overrides array from \(overridesPath)")
    }
    var overrideKeys: Set<FenceID> = []
    for patch in overrides {
        let key = FenceID(fence: str(patch["fence"]), id: str(patch["id"]))
        guard overrideKeys.insert(key).inserted else {
            fail("duplicate override for \(pyStr(patch["fence"])).\(pyStr(patch["id"]))")
        }
        if let index = seenIndex[key] {
            for (field, value) in patch where field != "fence" && field != "id" {
                rows[index][field] = value
            }
            validateSurface(rows[index], fence: key.fence)
        } else {
            var added = patch
            added["source"] = added["source"] ?? "override"
            validateSurface(added, fence: key.fence)
            seenIndex[key] = rows.count
            rows.append(added)
        }
    }
}

// A campaign is a frozen, reviewed set of existing surface IDs sharing one
// cross-cutting evaluator. It keeps a 641-row coverage closure reproducible
// without duplicating the same ref 641 times in coverage-overrides.json.
if let campaignsPath {
    guard let campaignData = FileManager.default.contents(atPath: campaignsPath),
          let campaigns = try? JSONSerialization.jsonObject(with: campaignData) as? [[String: Any]] else {
        fail("cannot load campaigns array from \(campaignsPath)")
    }
    let campaignDirectory = URL(fileURLWithPath: campaignsPath).deletingLastPathComponent()
    var names: Set<String> = []
    for campaign in campaigns {
        guard let name = str(campaign["name"]), !name.isEmpty, names.insert(name).inserted else {
            fail("campaign has missing or duplicate name")
        }
        guard let idsFile = str(campaign["surfaceIDsFile"]), !idsFile.isEmpty else {
            fail("campaign \(name) has no surfaceIDsFile")
        }
        let idsURL = campaignDirectory.appendingPathComponent(idsFile)
        guard let idsData = FileManager.default.contents(atPath: idsURL.path),
              let idsObject = try? JSONSerialization.jsonObject(with: idsData) as? [String: Any],
              let surfaces = idsObject["surfaces"] as? [[String: Any]] else {
            fail("campaign \(name) cannot load surfaces from \(idsURL.path)")
        }
        let keys = surfaces.map { FenceID(fence: str($0["fence"]), id: str($0["id"])) }
        guard Set(keys).count == keys.count else { fail("campaign \(name) contains duplicate fence/ID keys") }
        let excludedEntries = (campaign["excludeSurfaceIDs"] as? [[String: Any]]) ?? []
        let excludedKeys = Set(excludedEntries.map { FenceID(fence: str($0["fence"]), id: str($0["id"])) })
        guard excludedKeys.count == excludedEntries.count else {
            fail("campaign \(name) contains duplicate excludeSurfaceIDs keys")
        }
        guard excludedKeys.allSatisfy({ key in
            guard let fence = key.fence, let id = key.id, !fence.isEmpty, !id.isEmpty else { return false }
            return keys.contains(key)
        }) else {
            fail("campaign \(name) has an invalid excludeSurfaceIDs key")
        }
        guard let campaignCoverage = campaign["coverage"] as? [[String: Any]], !campaignCoverage.isEmpty else {
            fail("campaign \(name) has no coverage")
        }
        for key in keys {
            guard !excludedKeys.contains(key) else { continue }
            guard let index = seenIndex[key] else {
                fail("campaign \(name) surface is missing: \(pyStr(key.fence)).\(pyStr(key.id))")
            }
            let existing = (rows[index]["coverage"] as? [Any]) ?? []
            rows[index]["coverage"] = existing + campaignCoverage
            validateSurface(rows[index], fence: key.fence)
        }
    }
}

for i in rows.indices {
    let cov = (pyTruthy(rows[i]["coverage"]) ? rows[i]["coverage"] as? [Any] : []) ?? []
    let asserts = cov.contains { c in
        let cd = c as? [String: Any] ?? [:]
        let strength = cd["strength"].flatMap { $0 is NSNull ? nil : $0 as? String } ?? "incidental"
        return strength == "asserts"
    }
    rows[i]["status"] = asserts ? "COVERED" : (cov.isEmpty ? "UNCOVERED" : "REPORTS-ONLY")
    let k = FenceID(fence: str(rows[i]["fence"]), id: str(rows[i]["id"]))
    if let why = disputes[k] { rows[i]["disputed"] = why ?? NSNull() }
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// Generated output is a pure projection of canonical inputs. A wall-clock
// timestamp made an unchanged merge dirty, so the optional generatedAt field
// is deliberately omitted.
let ledgerObj: [String: Any] = ["surfaces": rows, "ranRun": ran, "uncertain": uncertain]
try! pyJSON(ledgerObj, 0).write(toFile: "\(out)/ledger.json", atomically: true, encoding: .utf8)

// MARK: - Render (port of lines 43-69 of the .py)

var byFenceOrder: [String] = []
var byFence: [String: [[String: Any]]] = [:]
for s in rows {
    let f = pyStr(s["fence"])  // dict key: None would break sorted() in Python too; data always has fences
    if byFence[f] == nil { byFenceOrder.append(f) }
    byFence[f, default: []].append(s)
}
var tot = PyCounter()
for s in rows { tot.add(pyStr(s["status"])) }

var L: [String] = ["# Eval coverage — NativeAgent", "",
                   "_generated deterministically from phase-1 fragments, overrides, and campaigns; \(rows.count) surfaces across \(byFence.count) fences._", "",
                   "**COVERED \(tot["COVERED"]) · REPORTS-ONLY \(tot["REPORTS-ONLY"]) · UNCOVERED \(tot["UNCOVERED"])**", "",
                   "**Behaviorally open in the inventory: \(tot["REPORTS-ONLY"] + tot["UNCOVERED"])**. `COVERED` means a recorded coverage reference has `strength: asserts`; rendering this report does not execute that evaluator or verify its current result.", "",
                   "This is an inventory, not a current test receipt. Run notes, line references, failure hypotheses, and proposed evals preserve their original audit context; later coverage mappings do not rewrite those historical observations. Use current source and a revision-specific execution log for present behavior and pass/fail claims. See [the eval guide](README.md).", "",
                   "## Uncovered by silent-failure class (keyword-classified; refine in phase 2)", ""]
var cls = PyCounter()
for s in rows {
    if pyStr(s["status"]) != "COVERED" {
        let m = (pyTruthy(s["silentFailureMode"]) ? pyStr(s["silentFailureMode"]) : "unstated").lowercased()
        let keys = ["lifecycle", "leak", "silent zero", "zero", "dead", "slow", "wrong", "stale", "drop"]
        cls.add(keys.first { m.contains($0) } ?? "other")
    }
}
L += cls.mostCommon().map { "- \($0.0): \($0.1)" } + [""]

for f in byFence.keys.sorted(by: pyLess) {
    let ss = byFence[f]!
    var cc = PyCounter()
    for s in ss { cc.add(pyStr(s["status"])) }
    L += ["## \(f)  — COVERED \(cc["COVERED"]) · REPORTS-ONLY \(cc["REPORTS-ONLY"]) · UNCOVERED \(cc["UNCOVERED"])", "",
          "_recorded audit run (historical): \(pyTruthy(ran[f]) ? pyStr(ran[f]) : "—")_", "",
          "| surface | kind | status | coverage | silent failure | proposed eval |", "|---|---|---|---|---|---|"]
    let sortedSS = ss.enumerated().sorted { l, r in
        let ls = pyStr(l.element["status"]), rs = pyStr(r.element["status"])
        let lk = (ls != "UNCOVERED" ? 1 : 0, ls != "REPORTS-ONLY" ? 1 : 0)
        let rk = (rs != "UNCOVERED" ? 1 : 0, rs != "REPORTS-ONLY" ? 1 : 0)
        if lk != rk { return lk < rk }
        let li = pyStr(l.element["id"]), ri = pyStr(r.element["id"])
        if li != ri { return pyLess(li, ri) }
        return l.offset < r.offset
    }.map { $0.element }
    for s in sortedSS {
        let covList = (pyTruthy(s["coverage"]) ? s["coverage"] as? [Any] : []) ?? []
        let covParts = covList.map { c -> String in
            let cd = c as? [String: Any] ?? [:]
            return "\(pyStr(cd["tier"])):\(pyStr(cd["ref"]))"
        }
        let cov = covParts.isEmpty ? "—" : covParts.joined(separator: "; ")
        let peAny = pyTruthy(s["proposedEval"]) ? s["proposedEval"] : nil
        let pe = peAny as? [String: Any] ?? [:]
        let pes = pe.isEmpty ? "—" : "\(pyStr(pe["tier"])) — reads \(pyStr(pe["reads"])); asserts \(pyStr(pe["asserts"]))"
        let flag = pyTruthy(s["disputed"]) ? " ⚠disputed" : ""
        L.append("| `\(pyStr(s["id"]))`\(flag) | \(pyStr(s["kind"])) | \(pyStr(s["status"])) | \(cov) | \(pyTruthy(s["silentFailureMode"]) ? pyStr(s["silentFailureMode"]) : "—") | \(pes) |")
    }
    if pyTruthy(uncertain[f]) {
        let u = (uncertain[f] as? [Any] ?? []).map { pyStr($0) }
        L += ["", "uncertain: " + u.joined(separator: "; ")]
    }
    L.append("")
}
while L.last == "" { L.removeLast() }
try! (L.joined(separator: "\n") + "\n").write(toFile: "\(out)/COVERAGE.md", atomically: true, encoding: .utf8)
print("ledger: \(rows.count) surfaces → \(out)/ledger.json, \(out)/COVERAGE.md; \(tot.dictRepr())")
