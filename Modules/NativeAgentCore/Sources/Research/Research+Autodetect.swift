import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Research+Autodetect.swift` | `SwiftNativeResearchClient`: `autodetectSearXNG`, `checkSearXNG`, `normalizedSearXNGBaseURL`, `saveSearXNGBaseURL` |

extension SwiftNativeResearchClient {
    // MARK: autodetect

    public func autodetectSearXNG() async throws -> SearXNGAutodetectResult {
        let expectedConfiguration = try await SwiftNativePersistenceCore.withFileLock(configPath) { [configPath] in
            try await SwiftNativePersistenceCore.readJSON(configPath, ifMissing: .object([:]))
        }
        // Probe common ports before paying for Docker enumeration.
        let candidates: [SearXNGCandidate] = [
            SearXNGCandidate(source: "common-port", baseURL: "http://127.0.0.1:8888"),
            SearXNGCandidate(source: "common-port", baseURL: "http://127.0.0.1:8080"),
            SearXNGCandidate(source: "common-port", baseURL: "http://localhost:8888"),
            SearXNGCandidate(source: "common-port", baseURL: "http://localhost:8080"),
        ]
        let seed = await withTaskGroup(of: (Int, Bool).self, returning: SearXNGCandidate?.self) { group in
            for (index, candidate) in candidates.prefix(4).enumerated() {
                group.addTask { (index, await self.checkSearXNG(base: candidate.baseURL)) }
            }
            var results = [Bool?](repeating: nil, count: 4)
            var preferred = 0
            for await (index, reachable) in group {
                results[index] = reachable
                while preferred < results.count, let result = results[preferred] {
                    if result {
                        group.cancelAll()
                        return candidates[preferred]
                    }
                    preferred += 1
                }
            }
            return nil
        }
        if let seed {
            try await persistSearXNGBaseURL(seed.baseURL, expectedConfiguration: expectedConfiguration)
            return SearXNGAutodetectResult(found: true, baseURL: seed.baseURL, source: seed.source, error: nil)
        }
        try Task.checkCancellation()
        let dockerCandidates = await dockerSearXNGCandidates()
        var seen = Set(candidates.map { trimTrailingSlash($0.baseURL) })
        for cand in dockerCandidates {
            try Task.checkCancellation()
            let base = trimTrailingSlash(cand.baseURL)
            guard seen.insert(base).inserted else { continue }
            if await checkSearXNG(base: base) {
                try await persistSearXNGBaseURL(base, expectedConfiguration: expectedConfiguration)
                return SearXNGAutodetectResult(found: true, baseURL: base, source: cand.source, error: nil)
            }
        }
        return SearXNGAutodetectResult(
            found: false, baseURL: nil, source: nil,
            error: "No reachable SearXNG instance found"
        )
    }

    /// Discovery admits a decoded instance; Doctor also requires answering engines.
    public func checkSearXNG(base: String, answering: Bool = false) async -> Bool {
        let trimmed = trimTrailingSlash(base)
        guard let url = makeURL(base: trimmed, path: "/search", query: [("q", "nativeagent"), ("format", "json")]) else {
            return false
        }
        do {
            // SearXNG itself may wait up to its max_request_timeout (15 s on a slow
            // network) before answering; a shorter probe reports a working instance as down.
            let response = try await http.getBounded(url: url, timeout: 16, maxBytes: 512_000)
            guard response.status == 200, !response.truncated else { return false }
            let decoded = try ResearchSearchResponse(data: response.body)
            return !answering || !decoded.enginesFailed
        } catch {
            return false
        }
    }

    /// Discover numeric loopback ports from Docker rows containing `searxng`
    /// in their lowercased Image, Names, Labels or Ports.
    func dockerSearXNGCandidates() async -> [SearXNGCandidate] {
        guard let stdout = await docker.runJSONLines() else { return [] }
        var out: [SearXNGCandidate] = []
        for line in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }
            guard let parsed = try? JSONValue.parse(Data(trimmedLine.utf8)),
                  case .object(let item) = parsed else { continue }
            let haystackParts: [String] = ["Image", "Names", "Labels", "Ports"].map { key in
                if case .string(let s) = item[key] ?? .null { return s }
                return ""
            }
            let haystack = haystackParts.joined(separator: " ").lowercased()
            if !haystack.contains("searxng") { continue }
            let ports: String
            if case .string(let s) = item["Ports"] ?? .null { ports = s } else { ports = "" }
            for rawPart in ports.split(separator: ",") {
                let part = rawPart.trimmingCharacters(in: .whitespaces)
                // Docker formats: 0.0.0.0:8888->8080/tcp, [::]:8888->8080/tcp
                if !part.contains("->") || !part.contains(":") { continue }
                let left = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    .first ?? Substring(part)
                // The host port follows the final colon, including in IPv6 bindings.
                guard let colonIdx = left.lastIndex(of: ":") else { continue }
                let portStr = String(left[left.index(after: colonIdx)...])
                if !portStr.isEmpty, portStr.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    out.append(SearXNGCandidate(source: "docker", baseURL: "http://127.0.0.1:\(portStr)"))
                }
            }
        }
        return out
    }

    /// A complete http or https SearXNG base URL with no query or fragment:
    /// scheme and host lowercased, no trailing slash.
    public static func normalizedSearXNGBaseURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            throw NSError(domain: "NativeAgent.Research", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Enter a complete http:// or https:// SearXNG base URL without a query or fragment."
            ])
        }

        var normalized = components
        normalized.scheme = scheme
        normalized.host = host.lowercased()
        let path = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        normalized.path = path.isEmpty ? "" : "/\(path)"
        let base = normalized.string.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? ""
        guard !base.isEmpty else {
            throw NSError(domain: "NativeAgent.Research", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Enter a complete http:// or https:// SearXNG base URL."
            ])
        }
        return base
    }

    /// Save a person-entered SearXNG base URL, normalized, under the same
    /// config lock autodetect writes through.
    @discardableResult
    public func saveSearXNGBaseURL(_ value: String) async throws -> String {
        let normalized = try Self.normalizedSearXNGBaseURL(value)
        try await persistSearXNGBaseURL(normalized)
        return normalized
    }

    /// Manual saves and discovery share the config lock. Discovery commits
    /// only while the configuration it probed from is still current.
    private func persistSearXNGBaseURL(_ base: String, expectedConfiguration: JSONValue? = nil) async throws {
        let work: @Sendable () async throws -> Void = { [configPath] in
            let raw = try await SwiftNativePersistenceCore.readJSON(configPath, ifMissing: .object([:]))
            if let expectedConfiguration, raw != expectedConfiguration {
                throw NSError(domain: "NativeAgent.Research", code: -409, userInfo: [
                    NSLocalizedDescriptionKey: "Search settings changed during discovery. Your saved settings were kept."
                ])
            }
            var obj: [String: JSONValue]
            if case .object(let existing) = raw {
                obj = existing
            } else {
                obj = [:]
            }
            obj["searxng_base_url"] = .string(base)
            try await SwiftNativePersistenceCore.writeJSON(.object(obj), to: configPath)
        }
        try await SwiftNativePersistenceCore.withFileLock(configPath, work)
    }

}
