#!/usr/bin/env swift

import Foundation

struct Policy: Decodable {
    let forbiddenFiles: [String]
    let rules: [Rule]
}

struct Rule: Decodable {
    let id: String
    let files: [String]?
    let optionalFiles: [String]?
    let roots: [String]?
    let required: [String]?
    let forbidden: [String]?
    let forbiddenPatterns: [String]?
    let caseInsensitive: Bool?
    let requiredAnyImports: [String]?
    let forbiddenImports: [String]?
    let allowlist: [String: String]?
    let message: String?
}

struct Options {
    var repo: URL
}

func parseOptions() -> Options {
    var repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--repo":
            guard !args.isEmpty else {
                fatalError("--repo requires a path")
            }
            repo = URL(fileURLWithPath: args.removeFirst())
        case "--help", "-h":
            print("""
            Architecture blueprint drift check

            Usage:
              script/check_architecture_blueprint.swift [--repo PATH]

            Checks complete source-owned Swift/ability headers and generated
            tables, plus architecture policy and active operational instructions.
            """)
            exit(0)
        default:
            fatalError("unknown argument: \(arg)")
        }
    }
    return Options(repo: repo)
}

func swiftFiles(under root: URL) throws -> [URL] {
    var enumerationError: Error?
    guard FileManager.default.fileExists(atPath: root.path),
          let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
          ) else {
        throw NSError(domain: "blueprint", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "cannot enumerate source root: \(root.path)"
        ])
    }
    let files: [URL] = enumerator.compactMap { value in
        guard let url = value as? URL else { return nil }
        if [".build", "Tests", "tests"].contains(url.lastPathComponent) { enumerator.skipDescendants(); return nil }
        guard url.pathExtension == "swift" else { return nil }
        return url.resolvingSymlinksInPath()
    }
    if let enumerationError { throw enumerationError }
    return files
}

func matches(_ pattern: String, in text: String, caseInsensitive: Bool = false) throws -> Bool {
    let regex = try NSRegularExpression(
        pattern: pattern,
        options: caseInsensitive ? [.caseInsensitive, .anchorsMatchLines] : [.anchorsMatchLines]
    )
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

func imports(_ module: String, in source: String) throws -> Bool {
    try matches(
        #"^\h*(?:@\w+\h+)*(?:(?:public|internal|private|package)\h+)?import\h+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\h+)?"#
            + NSRegularExpression.escapedPattern(for: module) + #"\b"#,
        in: source
    )
}

func check(_ rule: Rule, repo: URL, errors: inout [String]) throws {
    let fm = FileManager.default
    var paths = Set(rule.files ?? [])
    paths.formUnion((rule.optionalFiles ?? []).filter { fm.fileExists(atPath: repo.appendingPathComponent($0).path) })
    for root in rule.roots ?? [] {
        for url in try swiftFiles(under: repo.appendingPathComponent(root)) {
            paths.insert(String(url.path.dropFirst(repo.path.count + 1)))
        }
    }
    for (path, owner) in rule.allowlist ?? [:] {
        if !paths.contains(path) { errors.append("[\(rule.id)] obsolete allowlist path: \(path)") }
        if owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("[\(rule.id)] allowlist path has no owning area: \(path)")
        }
    }
    for path in paths.sorted() {
        let url = repo.appendingPathComponent(path)
        guard fm.fileExists(atPath: url.path) else {
            errors.append("[\(rule.id)] required file missing: \(path)")
            continue
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let context = "[\(rule.id)] \(path)"
        for marker in rule.required ?? [] where !source.contains(marker) {
            errors.append("\(context): missing required marker: \(marker)")
        }
        for marker in rule.forbidden ?? [] where source.contains(marker) {
            errors.append("\(context): forbidden marker: \(marker)")
        }
        for pattern in rule.forbiddenPatterns ?? [] {
            for (offset, line) in source.components(separatedBy: "\n").enumerated() {
                if try matches(pattern, in: line, caseInsensitive: rule.caseInsensitive ?? false) {
                    errors.append("\(context):\(offset + 1): forbidden pattern \(pattern). \(rule.message ?? "")")
                }
            }
        }
        for module in rule.forbiddenImports ?? [] where try imports(module, in: source) {
            errors.append("\(context): forbidden import: \(module)")
        }
        if let modules = rule.requiredAnyImports {
            let hasImport = try modules.contains { try imports($0, in: source) }
            if hasImport, rule.allowlist?[path] != nil {
                errors.append("\(context): remove satisfied temporary allowlist entry")
            } else if !hasImport, rule.allowlist?[path] == nil {
                errors.append("\(context): must import one of \(modules.joined(separator: ", ")). \(rule.message ?? "")")
            }
        }
    }
}

let repo = parseOptions().repo.resolvingSymlinksInPath()
let generator = Process()
generator.executableURL = URL(fileURLWithPath: "/usr/bin/env")
generator.arguments = ["swift", repo.appendingPathComponent("script/generate_architecture_blueprint.swift").path, "--check", "--repo", repo.path]
try generator.run()
generator.waitUntilExit()
guard generator.terminationStatus == 0 else { exit(generator.terminationStatus) }
let blueprint = repo.appendingPathComponent("docs/ARCHITECTURE_BLUEPRINT.md")
let text = try String(contentsOf: blueprint, encoding: .utf8)
let policySections = text.components(separatedBy: "```json architecture-policy\n")
guard policySections.count == 2,
      let policyJSON = policySections[1].components(separatedBy: "\n```").first,
      policySections[1].contains("\n```") else {
    fatalError("blueprint must contain exactly one closed architecture-policy JSON block")
}
let policy = try JSONDecoder().decode(Policy.self, from: Data(policyJSON.utf8))
var errors: [String] = []

for path in policy.forbiddenFiles where FileManager.default.fileExists(atPath: repo.appendingPathComponent(path).path) {
    errors.append("forbidden architecture file exists: \(path)")
}
for rule in policy.rules {
    try check(rule, repo: repo, errors: &errors)
}

if errors.isEmpty {
    print("[blueprint] complete source-owned tables and \(policy.rules.count) policy rules checked; behavioral prose is not type-checked")
} else {
    fputs("[blueprint] ERROR: architecture blueprint or active-instruction drift detected\n", stderr)
    for error in errors.sorted() { fputs("  - \(error)\n", stderr) }
    exit(1)
}
