import Foundation
import PersistenceCore


extension NativeClient {
    static func normalizedSearXNGBaseURL(_ value: String) throws -> String {
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

    static func searxngBaseURLValidationMessage(_ value: String) -> String? {
        do {
            _ = try normalizedSearXNGBaseURL(value)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func configureSearXNG(baseURL: String) async throws {
        // 2026-06-06 daemon-config retirement: write the user-supplied
        // searxng_base_url into the Swift-native `<dataRoot>/research/config.json`.
        // Previously a no-op stub (daemon owned the writer); now Swift owns it
        // under the same file lock the picker/autodetect helpers use.
        let normalized = try Self.normalizedSearXNGBaseURL(baseURL)
        let path = (dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = await persistence.readJSON(path, defaultValue: .object([:]))
            var root: [String: JSONValue]
            if case .object(let obj) = current { root = obj } else { root = [:] }
            root["searxng_base_url"] = .string(normalized)
            try await persistence.writeJSON(.object(root), to: path)
        }
    }

    func autodetectSearXNG() async throws -> DetectSearXNGResponse {
        // Subsystem #17 (cluster C7): when .research is on, the in-process
        // SwiftNativeResearchClient runs the same docker-ps + common-port
        // scan, persists `searxng_base_url` via PersistenceCore, and skips
        // the retired route entirely.
        return try await swiftAutodetectSearXNG()
    }

    func search(query: String) async throws -> [ResearchResult] {
        // Subsystem #17 (cluster C7): when .research is on, the in-process
        // SwiftNativeResearchClient queries SearXNG directly using the same
        // /search?format=json call the daemon uses, writes a receipt JSON
        // to data/research/<id>.json, and returns the same [{title,url,
        // snippet,source}] shape the daemon does.
        return try await swiftResearchSearch(query: query)
    }
}
