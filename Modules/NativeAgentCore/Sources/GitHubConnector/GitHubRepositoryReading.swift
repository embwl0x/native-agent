import Foundation
import NativeAgentCore
import PersistenceCore

/// Bounded, provider-facing repository reads. These stay on GitHub's native
/// API path so a repository URL does not require a browser round-trip merely
/// to learn its README, root layout, or recent history.
public extension GitHubConnectorActions {
    static func listNotifications(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> JSONValue {
        let limit = clamp(
            int(input["limit"] ?? input["per_page"], default: 20),
            min: 1,
            max: GitHubToolProjection.collectionLimit
        )
        let page = clamp(int(input["page"], default: 1), min: 1, max: 1_000)
        var params = [
            "per_page": String(limit),
            "page": String(page),
            "all": String(bool(input["all"]) ?? false),
            "participating": String(bool(input["participating"]) ?? false),
        ]
        for key in ["since", "before"] {
            if let value = normalized(input[key]) {
                guard value.count <= 64 else {
                    throw GitHubConnectorError.invalidInput("GitHub notification \(key) is too long.")
                }
                params[key] = value
            }
        }

        let repository = normalized(input["repo"] ?? input["repository"] ?? input["url"])
        let path: String
        var repositoryName: String?
        if repository != nil || normalized(input["owner"]) != nil {
            let identity = try repositoryIdentity(input)
            repositoryName = identity.fullName
            path = "repos/\(identity.fullName)/notifications"
        } else {
            path = "notifications"
        }
        let raw = try await call(path: path, params: params, dataRoot: dataRoot)
        let projection = notificationRows(raw, limit: limit)
        return GitHubConnectorSecretRedactor.redactValue(.object([
            "actionId": .string("github.list_notifications"),
            "connectorId": .string("github"),
            "ok": .bool(true),
            "status": .string("completed"),
            "repository": repositoryName.map(JSONValue.string) ?? .null,
            "page": .int(Int64(page)),
            "count": .int(Int64(projection.rows.count)),
            "sourcePageCount": .int(Int64(projection.sourceCount)),
            "resultsTruncated": .bool(projection.truncated),
            "notifications": JSONValue(fromFoundation: projection.rows),
        ]))
    }

    static func getRepository(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> JSONValue {
        let repository = try repositoryIdentity(input)
        let overview = try await call(
            path: "repos/\(repository.fullName)",
            dataRoot: dataRoot
        )
        let root = try await optionalRepositoryCall(
            path: "repos/\(repository.fullName)/contents",
            dataRoot: dataRoot
        )
        let readme = try await optionalRepositoryCall(
            path: "repos/\(repository.fullName)/readme",
            dataRoot: dataRoot
        )

        let rootProjection = repositoryEntries(root, limit: 100)
        var payload: [String: JSONValue] = [
            "actionId": .string("github.get_repository"),
            "connectorId": .string("github"),
            "ok": .bool(true),
            "status": .string("completed"),
            "repository": .string(repository.fullName),
            "overview": JSONValue(fromFoundation: GitHubToolProjection.repository(
                overview as? [String: Any] ?? [:]
            )),
            "rootEntries": JSONValue(fromFoundation: rootProjection.rows),
            "rootEntryCount": .int(Int64(rootProjection.sourceCount)),
            "rootEntriesTruncated": .bool(rootProjection.truncated),
        ]
        if let readmeObject = readme as? [String: Any] {
            payload["readme"] = JSONValue(fromFoundation: repositoryContent(
                readmeObject,
                maxCharacters: 24_000
            ))
        } else {
            payload["readme"] = .null
        }
        return GitHubConnectorSecretRedactor.redactValue(.object(payload))
    }

    static func readRepositoryContent(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> JSONValue {
        let repository = try repositoryIdentity(input)
        let path = try repositoryContentPath(input["path"])
        let maxCharacters = clamp(
            int(input["max_characters"], default: 30_000),
            min: 1_000,
            max: 100_000
        )
        var params: [String: String] = [:]
        if let ref = try repositoryRef(input["ref"]) {
            params["ref"] = ref
        }
        let suffix = path.isEmpty ? "" : "/\(path)"
        let raw = try await call(
            path: "repos/\(repository.fullName)/contents\(suffix)",
            params: params,
            dataRoot: dataRoot
        )

        var payload: [String: JSONValue] = [
            "actionId": .string("github.read_repository_content"),
            "connectorId": .string("github"),
            "ok": .bool(true),
            "status": .string("completed"),
            "repository": .string(repository.fullName),
            "path": .string(path),
            "ref": params["ref"].map(JSONValue.string) ?? .null,
        ]
        if let file = raw as? [String: Any] {
            payload["kind"] = .string("file")
            payload["file"] = JSONValue(fromFoundation: repositoryContent(
                file,
                maxCharacters: maxCharacters
            ))
        } else {
            let entries = repositoryEntries(raw, limit: 100)
            payload["kind"] = .string("directory")
            payload["entries"] = JSONValue(fromFoundation: entries.rows)
            payload["entryCount"] = .int(Int64(entries.sourceCount))
            payload["entriesTruncated"] = .bool(entries.truncated)
        }
        return GitHubConnectorSecretRedactor.redactValue(.object(payload))
    }

    static func listCommits(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> JSONValue {
        let repository = try repositoryIdentity(input)
        let limit = clamp(
            int(input["limit"] ?? input["per_page"], default: 10),
            min: 1,
            max: GitHubToolProjection.collectionLimit
        )
        let page = clamp(int(input["page"], default: 1), min: 1, max: 1_000)
        var params = ["per_page": String(limit), "page": String(page)]
        if let ref = try repositoryRef(input["ref"] ?? input["sha"]) {
            params["sha"] = ref
        }
        if let path = try optionalRepositoryContentPath(input["path"]) {
            params["path"] = path
        }
        for key in ["since", "until"] {
            if let value = normalized(input[key]) {
                guard value.count <= 64 else {
                    throw GitHubConnectorError.invalidInput("GitHub \(key) is too long.")
                }
                params[key] = value
            }
        }
        let raw = try await call(
            path: "repos/\(repository.fullName)/commits",
            params: params,
            dataRoot: dataRoot
        )
        let projection = GitHubToolProjection.commits(raw, limit: limit)
        return GitHubConnectorSecretRedactor.redactValue(.object([
            "actionId": .string("github.list_commits"),
            "connectorId": .string("github"),
            "ok": .bool(true),
            "status": .string("completed"),
            "repository": .string(repository.fullName),
            "page": .int(Int64(page)),
            "count": .int(Int64(projection.rows.count)),
            "sourcePageCount": .int(Int64(projection.sourceCount)),
            "resultsTruncated": .bool(projection.truncated),
            "commits": JSONValue(fromFoundation: projection.rows),
        ]))
    }
}

extension GitHubConnectorActions {
    struct RepositoryIdentity: Equatable {
        let owner: String
        let name: String

        var fullName: String { "\(owner)/\(name)" }
    }

    struct RepositoryEntryCollection {
        let rows: [[String: Any]]
        let sourceCount: Int

        var truncated: Bool { sourceCount > rows.count }
    }

    static func notificationRows(_ raw: Any?, limit: Int) -> RepositoryEntryCollection {
        let source = raw as? [[String: Any]] ?? []
        let cap = max(1, min(GitHubToolProjection.collectionLimit, limit))
        let rows: [[String: Any]] = source.prefix(cap).map { notification in
            var row: [String: Any] = [:]
            for key in ["id", "reason", "unread", "updated_at", "last_read_at", "url"] {
                if let value = notification[key], value is String || value is NSNumber || value is Bool {
                    row[key] = value
                }
            }
            if let subject = notification["subject"] as? [String: Any] {
                var compact: [String: Any] = [:]
                for key in ["title", "type", "url", "latest_comment_url"] {
                    if let value = subject[key] as? String { compact[key] = value }
                }
                row["subject"] = compact
            }
            if let repository = notification["repository"] as? [String: Any] {
                var compact: [String: Any] = [:]
                for key in ["id", "name", "full_name", "html_url", "private"] {
                    if let value = repository[key], value is String || value is NSNumber || value is Bool {
                        compact[key] = value
                    }
                }
                row["repository"] = compact
            }
            return row
        }
        return RepositoryEntryCollection(rows: rows, sourceCount: source.count)
    }

    static func repositoryIdentity(_ input: [String: JSONValue]) throws -> RepositoryIdentity {
        let owner = normalized(input["owner"])
        guard var raw = normalized(
            input["repo"] ?? input["repository"] ?? input["full_name"] ?? input["url"]
        ) else {
            throw GitHubConnectorError.invalidInput(
                "GitHub repository read requires repo as owner/name, a github.com repository URL, or owner plus repo."
            )
        }

        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            guard let url = URL(string: raw),
                  let host = url.host?.lowercased(),
                  host == "github.com" || host == "www.github.com" else {
                throw GitHubConnectorError.invalidInput("Repository URL must use github.com.")
            }
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2 else {
                throw GitHubConnectorError.invalidInput("GitHub repository URL must include owner and repository.")
            }
            raw = "\(parts[0])/\(parts[1])"
        }
        if raw.hasSuffix(".git") { raw.removeLast(4) }

        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let resolved: RepositoryIdentity
        if parts.count == 2 {
            resolved = RepositoryIdentity(owner: parts[0], name: parts[1])
        } else if parts.count == 1, let owner {
            resolved = RepositoryIdentity(owner: owner, name: parts[0])
        } else {
            throw GitHubConnectorError.invalidInput("GitHub repository must be owner/name.")
        }
        guard validRepositoryComponent(resolved.owner),
              validRepositoryComponent(resolved.name) else {
            throw GitHubConnectorError.invalidInput("GitHub repository owner/name contains unsupported characters.")
        }
        return resolved
    }

    static func repositoryContentPath(_ raw: JSONValue?) throws -> String {
        try optionalRepositoryContentPath(raw) ?? ""
    }

    static func optionalRepositoryContentPath(_ raw: JSONValue?) throws -> String? {
        guard let raw = normalized(raw) else { return nil }
        let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.count <= 1_000,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                  $0 == "." || $0 == ".." || $0.isEmpty
              }) else {
            throw GitHubConnectorError.invalidInput("GitHub repository path is invalid.")
        }
        return path
    }

    static func repositoryRef(_ raw: JSONValue?) throws -> String? {
        guard let value = normalized(raw) else { return nil }
        guard value.count <= 250,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains(".."),
              !value.contains("\\"),
              !value.contains("~"),
              !value.contains("^") else {
            throw GitHubConnectorError.invalidInput("GitHub repository ref is invalid.")
        }
        return value
    }

    static func repositoryEntries(_ raw: Any?, limit: Int) -> RepositoryEntryCollection {
        let source = raw as? [[String: Any]] ?? []
        let cap = max(1, min(100, limit))
        let rows = source.prefix(cap).map { entry in
            var row: [String: Any] = [:]
            for key in ["name", "path", "sha", "size", "type", "html_url"] {
                if let value = entry[key], value is String || value is NSNumber || value is Bool {
                    row[key] = value
                }
            }
            return row
        }
        return RepositoryEntryCollection(rows: rows, sourceCount: source.count)
    }

    static func repositoryContent(
        _ object: [String: Any],
        maxCharacters: Int
    ) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in ["name", "path", "sha", "size", "type", "encoding", "html_url"] {
            if let value = object[key], value is String || value is NSNumber || value is Bool {
                out[key] = value
            }
        }
        guard object["encoding"] as? String == "base64",
              let encoded = object["content"] as? String,
              encoded.count <= 2_800_000,
              let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              !bytes.contains(0),
              let text = String(data: bytes, encoding: .utf8) else {
            out["contentAvailable"] = false
            out["contentKind"] = "binary_or_oversized"
            return out
        }
        let cap = max(1, min(100_000, maxCharacters))
        out["contentAvailable"] = true
        out["contentKind"] = "text"
        out["content"] = String(text.prefix(cap))
        out["contentCharacters"] = text.count
        out["contentTruncated"] = text.count > cap
        return out
    }

    private static func optionalRepositoryCall(
        path: String,
        dataRoot: URL
    ) async throws -> Any? {
        do {
            return try await call(path: path, dataRoot: dataRoot)
        } catch GitHubConnectorError.http(let status, _, _, _) where status == 404 || status == 409 {
            return nil
        }
    }

    private static func validRepositoryComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}
