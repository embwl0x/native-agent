import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Research+Autodetect.swift` | Explicit setup discovery retains candidate-local probe gaps while siblings proceed; refused listeners alone mean absence; Docker inventory and config reads are required; config saves fence concurrent edits; configured-server checks never select another endpoint, and answering checks cannot certify readiness from only parse gaps and no usable results |

extension SwiftNativeResearchClient {
    // MARK: autodetect

    public func autodetectSearXNG() async throws -> SearXNGAutodetectResult {
        let expectedConfiguration = try await SwiftNativePersistenceCore.withFileLock(configPath) { [configPath] in
            JSONValue.object(try Self.checkedSearchConfiguration(try await SwiftNativePersistenceCore.readJSON(configPath, ifMissing: .object([:]))))
        }
        // Probe common ports before paying for Docker enumeration.
        let candidates: [SearXNGCandidate] = [
            SearXNGCandidate(source: "common-port", baseURL: "http://127.0.0.1:8888"),
            SearXNGCandidate(source: "common-port", baseURL: "http://127.0.0.1:8080"),
            SearXNGCandidate(source: "common-port", baseURL: "http://localhost:8888"),
            SearXNGCandidate(source: "common-port", baseURL: "http://localhost:8080"),
        ]
        let probes = try await withThrowingTaskGroup(of: (Int, DiscoveryProbe).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask { (index, try await self.discoveryProbe(candidate)) }
            }
            var results: [(Int, DiscoveryProbe)] = []
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        var seed: SearXNGCandidate?
        var gaps: [String] = []
        for (index, probe) in probes {
            switch probe {
            case .reachable: if seed == nil { seed = candidates[index] }
            case .absent: break
            case .failed(let detail): gaps.append(detail)
            }
        }
        if let seed {
            try await persistSearXNGBaseURL(seed.baseURL, expectedConfiguration: expectedConfiguration)
            return SearXNGAutodetectResult(found: true, baseURL: seed.baseURL, source: seed.source, error: nil, gaps: gaps)
        }
        try Task.checkCancellation()
        let dockerCandidates = try await dockerSearXNGCandidates()
        var seen = Set(candidates.map { trimTrailingSlash($0.baseURL) })
        for cand in dockerCandidates {
            try Task.checkCancellation()
            let base = trimTrailingSlash(cand.baseURL)
            guard seen.insert(base).inserted else { continue }
            switch try await discoveryProbe(cand) {
            case .reachable:
                try Task.checkCancellation()
                try await persistSearXNGBaseURL(base, expectedConfiguration: expectedConfiguration)
                return SearXNGAutodetectResult(found: true, baseURL: base, source: cand.source, error: nil, gaps: gaps)
            case .absent: break
            case .failed(let detail): gaps.append(detail)
            }
        }
        try Task.checkCancellation()
        return SearXNGAutodetectResult(
            found: false, baseURL: nil, source: nil,
            error: gaps.isEmpty ? "No reachable SearXNG instance found" : "Search discovery has unavailable candidates", gaps: gaps
        )
    }

    private enum DiscoveryProbe: Sendable {
        case reachable
        case absent
        case failed(String)
    }

    /// A failed candidate cannot cancel another candidate or become absence.
    /// Cancellation still ends the operation; each HTTP read has its own timeout.
    private func discoveryProbe(_ candidate: SearXNGCandidate) async throws -> DiscoveryProbe {
        do {
            return try await checkSearXNG(base: candidate.baseURL) ? .reachable : .absent
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed("\(candidate.baseURL): \(error.localizedDescription)")
        }
    }

    /// False means a refused connection (no listener). Every unavailable probe
    /// keeps its cause; discovery must not turn it into an absent installation.
    public func checkSearXNG(base: String, answering: Bool = false, timeout: TimeInterval = 16) async throws -> Bool {
        let trimmed = try Self.normalizedSearXNGBaseURL(base)
        guard let url = makeURL(base: trimmed, path: "/search", query: [("q", "nativeagent"), ("format", "json")]) else {
            throw ResearchClientError.malformedResponse("Invalid SearXNG probe address: \(base)")
        }
        do {
            // SearXNG itself may wait up to its max_request_timeout (15 s on a slow
            // network) before answering; a shorter probe reports a working instance as down.
            let response = try await http.getBounded(url: url, timeout: timeout, maxBytes: 512_000)
            guard response.status == 200 else { throw ResearchClientError.httpStatus(response.status) }
            guard !response.truncated else { throw ResearchClientError.malformedResponse("SearXNG probe exceeds 512,000 bytes") }
            let decoded = try ResearchSearchResponse(data: response.body)
            if answering && decoded.enginesFailed {
                throw ResearchClientError.malformedResponse("SearXNG engines failed: " + decoded.unresponsiveEngines.joined(separator: "; "))
            }
            if answering && decoded.results.isEmpty && !decoded.gaps.isEmpty {
                throw ResearchClientError.malformedResponse("SearXNG readiness is unknown: no usable results; " + decoded.gaps.joined(separator: "; "))
            }
            return true
        } catch where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        } catch {
            let failure = ResearchClientError.transportFailure(error, url: url)
            if case .connectionRefused = failure { return false }
            throw failure
        }
    }

    /// Discover numeric loopback ports from Docker rows containing `searxng`
    /// in their lowercased Image, Names, Labels or Ports.
    func dockerSearXNGCandidates() async throws -> [SearXNGCandidate] {
        // A missing executable is known absence of this discovery source.
        guard let stdout = try await docker.runJSONLines() else { return [] }
        var out: [SearXNGCandidate] = []
        for line in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }
            let parsed = try JSONValue.parse(Data(trimmedLine.utf8))
            guard case .object(let item) = parsed else {
                throw ResearchClientError.malformedResponse("Docker inventory row is not an object")
            }
            let haystackParts: [String] = try ["Image", "Names", "Labels", "Ports"].map { key in
                guard case .string(let value)? = item[key] else {
                    throw ResearchClientError.malformedResponse("Docker inventory row has no string \(key)")
                }
                return value
            }
            let haystack = haystackParts.joined(separator: " ").lowercased()
            if !haystack.contains("searxng") { continue }
            let ports = haystackParts[3]
            for rawPart in ports.split(separator: ",") {
                let part = rawPart.trimmingCharacters(in: .whitespaces)
                // Docker formats: 0.0.0.0:8888->8080/tcp, [::]:8888->8080/tcp
                if !part.contains("->") { continue } // Exposed, unpublished container port.
                let binding = part.components(separatedBy: "->")
                guard binding.count == 2, let left = binding.first,
                      let colonIdx = left.lastIndex(of: ":") else {
                    throw ResearchClientError.malformedResponse("Docker returned an unreadable SearXNG port binding: \(part)")
                }
                guard binding[1] == "8080/tcp" else { continue }
                // The host port follows the final colon, including in IPv6 bindings.
                let portStr = String(left[left.index(after: colonIdx)...])
                guard !portStr.isEmpty, portStr.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let port = Int(portStr), (1...65535).contains(port) else {
                    throw ResearchClientError.malformedResponse("Docker returned an invalid SearXNG host port: \(part)")
                }
                out.append(SearXNGCandidate(source: "docker", baseURL: "http://127.0.0.1:\(port)"))
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
            var obj = try Self.checkedSearchConfiguration(raw)
            obj["searxng_base_url"] = .string(base)
            try await SwiftNativePersistenceCore.writeJSON(.object(obj), to: configPath)
        }
        try await SwiftNativePersistenceCore.withFileLock(configPath, work)
    }

    nonisolated static func checkedSearchConfiguration(_ raw: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let object) = raw,
              object["searxng_base_url"] == nil || object["searxng_base_url"]?.stringValue != nil else {
            throw ResearchClientError.malformedResponse("research/config.json must be an object with a string searxng_base_url when present. Original contents have been preserved; repair that file before saving an address.")
        }
        return object
    }

}
