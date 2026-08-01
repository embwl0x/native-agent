import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeResearchClient {
    // MARK: autodetect

    public func autodetectSearXNG() async throws -> SearXNGAutodetectResult {
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
        for cand in candidates {
            let base = trimTrailingSlash(cand.baseURL)
            if seen.contains(base) { continue }
            seen.insert(base)
            if await checkSearXNG(base: base) {
                try await persistSearXNGBaseURL(base)
                return SearXNGAutodetectResult(found: true, baseURL: base, source: cand.source, error: nil)
            }
        }
        return SearXNGAutodetectResult(
            found: false, baseURL: nil, source: nil,
            error: "No reachable SearXNG instance found"
        )
    }

    /// Probe one candidate via the same query the daemon uses
    /// (`q=nativeagent&format=json`, 6s timeout, expect 200 + a JSON
    /// object containing a `results` key). Mirrors
    /// `Daemon.check_searxng`.
    public func checkSearXNG(base: String) async -> Bool {
        let trimmed = trimTrailingSlash(base)
        guard let url = makeURL(base: trimmed, path: "/search", query: [("q", "nativeagent"), ("format", "json")]) else {
            return false
        }
        do {
            let (status, body, _) = try await http.get(url: url, timeout: 6)
            if status != 200 { return false }
            // Python reads up to 512_000 bytes then json.loads — Swift parses the whole body
            // (the test stub honors a small-body contract; production responses are bounded
            // by URLSession's transport buffer + SearXNG's own response size).
            let parsed = try JSONValue.parse(body)
            guard case .object(let obj) = parsed else { return false }
            return obj["results"] != nil
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

    /// Read `data/research/config.json`, overwrite `searxng_base_url`, write
    /// atomically. Mirrors Python: `self.config[...] = base; self.save_config()`.
    ///
    /// Wave-3 (2026-05-31) — wrapped in `withFileLock(configPath)` so the
    /// R-M-W is serialized against the daemon's `save_config()`
    ///. Both sides share the `.lock`
    /// sibling convention from PersistenceCore+FileLock.swift.
    private func persistSearXNGBaseURL(_ base: String) async throws {
        let work: @Sendable () async throws -> Void = { [persistence, configPath] in
            let raw = await persistence.readJSON(configPath, defaultValue: .object([:]))
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
