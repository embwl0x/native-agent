import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Research+Autodetect.swift` | `SwiftNativeResearchClient`: `autodetectSearXNG`, `checkSearXNG`, `normalizedSearXNGBaseURL`, `saveSearXNGBaseURL` |

extension SwiftNativeResearchClient {
    // MARK: autodetect

    public func autodetectSearXNG() async throws -> SearXNGAutodetectResult {
        let expectedConfiguration = try await persistence.withFileLock(configPath) { [persistence, configPath] in
            try await persistence.readJSON(configPath, ifMissing: .object([:]))
        }
        // Mirror Python: deterministic seed list, then docker candidates,
        // then dedup-by-rstripped-baseURL preserving first-seen order.
        var candidates: [SearXNGCandidate] = [
            SearXNGCandidate(source: "common-port", baseURL: "http://127.0.0.1:8888"),
            SearXNGCandidate(source: "common-port", baseURL: "http://127.0.0.1:8080"),
            SearXNGCandidate(source: "common-port", baseURL: "http://localhost:8888"),
            SearXNGCandidate(source: "common-port", baseURL: "http://localhost:8080"),
        ]
        let dockerCandidates = await dockerSearXNGCandidates()
        candidates.append(contentsOf: dockerCandidates)

        var seen: Set<String> = []
        candidates = candidates.filter { seen.insert(trimTrailingSlash($0.baseURL)).inserted }
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
        for cand in candidates.dropFirst(4) {
            let base = trimTrailingSlash(cand.baseURL)
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

    /// Probe one candidate via the same query the daemon uses
    /// (`q=nativeagent&format=json`, 16s timeout, expect 200 + a JSON
    /// object containing a `results` key). Mirrors
    /// `Daemon.check_searxng`. `answering` (Doctor) also fails a reply whose
    /// engines all failed, the same reply web.search reports as a failure.
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
            let parsed = try JSONValue.parse(response.body)
            guard case .object(let obj) = parsed, case .array(let results)? = obj["results"] else { return false }
            guard answering, results.isEmpty, case .array(let failed)? = obj["unresponsive_engines"] else { return true }
            return failed.isEmpty
        } catch {
            return false
        }
    }

    /// Mirror `Daemon.docker_searxng_candidates`:
    /// shell out to `docker ps --format '{{json .}}'`, parse each line,
    /// require "searxng" in the lowercased haystack
    /// (Image+Names+Labels+Ports), then walk Ports for `<addr>:<host_port>-><container_port>/...`
    /// fragments and pull `host_port` if it's numeric.
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
                // `left` is like "0.0.0.0:8888" or "[::]:8888"; take the
                // segment after the FINAL ":" — matches Python's
                // `left.rsplit(":", 1)[-1]`.
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
        let work: @Sendable () async throws -> Void = { [persistence, configPath] in
            let raw = try await persistence.readJSON(configPath, ifMissing: .object([:]))
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
            try await persistence.writeJSON(.object(obj), to: configPath)
        }
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        try await persistence.withFileLock(configPath, work)
    }

}
