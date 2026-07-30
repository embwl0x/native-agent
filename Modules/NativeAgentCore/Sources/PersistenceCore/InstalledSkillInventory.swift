import Foundation
import NativeAgentCore

/// One bounded, read-only inventory for the installed skill surface.
///
/// The chat `list_skills` tool and capability gauges must consume this same
/// projection. A registry-only count is incomplete because committed persona
/// skill bodies are installed skills even when they have no runtime registry
/// row.
public enum InstalledSkillInventory {
    public static func list(
        dataRoot: URL,
        sourceRoot: URL? = nil,
        personaRoot: URL? = nil
    ) -> [JSONValue] {
        let sourceRoot = (sourceRoot ?? dataRoot.deletingLastPathComponent()).standardizedFileURL
        let personaRoot = (personaRoot ?? defaultPersonaRoot(dataRoot: dataRoot)).standardizedFileURL
        var rows: [JSONValue] = []
        var seen: Set<String> = []

        let registryURL = dataRoot
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("registry.json")
        if let data = try? Data(contentsOf: registryURL),
           let parsed = try? JSONValue.parse(data) {
            let skills: [JSONValue]
            switch parsed {
            case .array(let values):
                skills = values
            case .object(let object):
                if case .array(let values)? = object["skills"] {
                    skills = values
                } else {
                    skills = []
                }
            default:
                skills = []
            }
            for item in skills {
                guard case .object(let skill) = item,
                      registryBodyIsClean(skill, dataRoot: dataRoot, sourceRoot: sourceRoot)
                else { continue }
                var output: [String: JSONValue] = [:]
                if let value = skill["id"] { output["id"] = value }
                if let value = skill["name"] { output["name"] = value }
                if let value = skill["description"] { output["description"] = value }
                if let value = skill["triggers"] { output["triggers"] = value }
                if let value = skill["status"] { output["status"] = value }
                output["source"] = .string("runtime_registry")
                if let name = string(output["name"]) {
                    seen.insert(name)
                }
                rows.append(.object(output))
            }
        }

        let bodySources: [(URL, String)] = [
            (dataRoot.appendingPathComponent("skills/bodies", isDirectory: true), "runtime_body"),
            (personaRoot.appendingPathComponent("skills/bodies", isDirectory: true), "persona_body"),
        ]
        for (directory, source) in bodySources {
            for row in scanBodies(directory: directory, source: source) {
                guard case .object(let object) = row,
                      let name = string(object["name"]),
                      !seen.contains(name)
                else { continue }
                seen.insert(name)
                rows.append(row)
            }
        }

        return rows.sorted { lhs, rhs in
            guard case .object(let left) = lhs,
                  case .object(let right) = rhs else { return false }
            return (string(left["name"]) ?? "") < (string(right["name"]) ?? "")
        }
    }

    private static func scanBodies(directory: URL, source: String) -> [JSONValue] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                guard SkillBodyHygiene.violations(in: body).isEmpty else { return nil }
                let description = SkillBodyHygiene.firstUsefulLine(in: body) ?? "Skill body."
                return .object([
                    "name": .string(url.deletingPathExtension().lastPathComponent),
                    "description": .string(String(description.prefix(240))),
                    "source": .string(source),
                    "status": .string("installed"),
                ])
            }
    }

    private static func registryBodyIsClean(
        _ skill: [String: JSONValue],
        dataRoot: URL,
        sourceRoot: URL
    ) -> Bool {
        var candidates: [URL] = []
        if let raw = string(skill["bodyPath"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if raw.hasPrefix("/") || raw.hasPrefix("~") {
                candidates.append(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
            } else {
                candidates.append(sourceRoot.appendingPathComponent(raw).standardizedFileURL)
            }
        }
        if let id = string(skill["id"]), !id.isEmpty {
            candidates.append(dataRoot.appendingPathComponent("skills/bodies/\(id).md"))
        }

        var visited: Set<String> = []
        for url in candidates where visited.insert(url.path).inserted {
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return SkillBodyHygiene.violations(in: body).isEmpty
        }
        return true
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }
}
