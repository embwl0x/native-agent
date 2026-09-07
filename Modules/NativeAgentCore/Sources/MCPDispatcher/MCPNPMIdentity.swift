import Foundation
import CryptoKit

/// Read-only evidence for npm launchers, never package resolution or installation.
enum MCPNPMIdentity {
    static func resolve(arguments: [String]) -> (versions: [String: String], unpinned: Bool)? {
        guard let executable = arguments.first else { return nil }
        let launcher = URL(fileURLWithPath: executable).lastPathComponent
        guard launcher == "npx" || launcher == "npm" else { return nil }
        var index = 1
        if launcher == "npm" {
            guard arguments.count > index, ["exec", "x"].contains(arguments[index]) else { return nil }
            index += 1
        }
        let environment = ProcessInfo.processInfo.environment
        var cache = environment["npm_config_cache"] ?? environment["NPM_CONFIG_CACHE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm").path
        var specs: [String] = []
        var understood = true
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                if specs.isEmpty, index < arguments.count { specs.append(arguments[index]) }
                break
            }
            if argument == "--package" || (launcher == "npx" && argument == "-p") || argument == "--cache" {
                guard index < arguments.count else { understood = false; break }
                if argument == "--cache" { cache = arguments[index] }
                else { specs.append(arguments[index]) }
                index += 1
            } else if argument.hasPrefix("--package=") {
                specs.append(String(argument.dropFirst("--package=".count)))
            } else if launcher == "npx", argument.hasPrefix("-p"), argument.count > 2 {
                specs.append(String(argument.dropFirst(2)))
            } else if argument.hasPrefix("--cache=") {
                cache = String(argument.dropFirst("--cache=".count))
            } else if ["-c", "--call"].contains(argument) || argument.hasPrefix("--call=") {
                break // Explicit --package operands are the evidence for a shell call.
            } else if ["-y", "--yes", "--no", "--no-install", "--offline", "--prefer-offline",
                       "--prefer-online", "--ignore-scripts", "--quiet", "-q"].contains(argument)
                        || argument.hasPrefix("--yes=") {
                continue
            } else if argument.hasPrefix("-") {
                // Unknown option arity cannot safely identify the next operand.
                understood = false
                break
            } else {
                if specs.isEmpty { specs.append(argument) }
                break // Everything after the command belongs to the launched tool.
            }
        }
        guard understood, !specs.isEmpty else { return ([:], true) }

        // npm's libnpmexec keys _npx by the sorted, verbatim package specs.
        // Select that entry rather than borrowing another tag/range's install.
        let sorted = specs.sorted {
            $0.compare($1, locale: Locale(identifier: "en")) == .orderedAscending
        }
        let hash = SHA512.hash(data: Data(sorted.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        let modules = URL(fileURLWithPath: cache).appendingPathComponent("_npx/\(hash)/node_modules")
        var versions: [String: String] = [:]
        for spec in specs {
            guard let package = registryPackage(spec) else { continue }
            if let version = package.version, isExactVersion(version) {
                versions[spec] = version
                continue
            }
            let manifest = modules.appendingPathComponent(package.name).appendingPathComponent("package.json")
            guard let bytes = try? Data(contentsOf: manifest),
                  let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  json["name"] as? String == package.name,
                  let version = json["version"] as? String, isExactVersion(version) else { continue }
            versions[spec] = version
        }
        // 2026-09-06: version labels do not authenticate executable package
        // bytes or dependencies. Reuse requires a verified execution snapshot,
        // which npm's mutable cache and exact-version operands do not provide.
        return (versions, true)
    }

    private static func registryPackage(_ spec: String) -> (name: String, version: String?)? {
        let start = spec.hasPrefix("@") ? spec.index(after: spec.startIndex) : spec.startIndex
        let separator = spec[start...].firstIndex(of: "@")
        let name = separator.map { String(spec[..<$0]) } ?? spec
        let pattern = #"^(?:@[a-z0-9._-]+/)?[a-z0-9._-]+$"#
        guard name.range(of: pattern, options: .regularExpression) != nil,
              name != ".", name != ".." else { return nil }
        return (name, separator.map { String(spec[spec.index(after: $0)...]) })
    }

    private static func isExactVersion(_ version: String) -> Bool {
        version.range(
            of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#,
            options: .regularExpression
        ) != nil
    }
}
