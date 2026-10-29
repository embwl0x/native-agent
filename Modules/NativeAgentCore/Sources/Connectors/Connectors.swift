import Privacy
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Connectors.swift` | Canonical workspace-array read and tilde-expanded string paths for search and journal roots; typed workspace search results and checked identity metadata; empty queries echo their original input |

// Searches saved workspaces with a 2,000-file limit per workspace and 50 results overall.
// Each directory's files are searched before descending into its subdirectories.

public final class SwiftNativeConnectorsClient: Sendable {
    private let root: URL
    private let maxResults = 50
    private let maxScanned = 2000
    private let maxContentBytes = 512_000

    public init(root: URL) {
        self.root = root
    }

    private var workspacesPath: URL {
        root.appendingPathComponent("connectors/workspaces.json")
    }

    /// <root>/activity/events.jsonl.
    private var activityPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
    }

    public func listWorkspaces() async throws -> [JSONValue] {
        let raw = try await SwiftNativePersistenceCore.readJSON(workspacesPath, ifMissing: .array([]))
        guard case .array(let arr) = raw else {
            throw PersistenceCoreError.ioFailure("\(workspacesPath.path) is not a list of workspaces; repair it before searching")
        }
        return arr
    }

    public func searchWorkspaces(query rawQuery: String) async throws -> WorkspaceSearchResponse {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return WorkspaceSearchResponse(query: rawQuery, results: [], unexamined: nil) }

        var results: [Result<WorkspaceSearchResult, Error>] = []
        // Scope the search could not examine, "path: why": a miss there is
        // not a searched-and-absent miss.
        var unexamined: [String] = []
        let workspaces = try await listWorkspaces()

        for workspace in workspaces {
            guard case .object(let ws) = workspace, let wsRoot = Self.workspaceURL(ws["path"]) else {
                unexamined.append("a workspace entry has no path")
                continue
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: wsRoot.path, isDirectory: &isDir), isDir.boolValue else {
                unexamined.append("\(wsRoot.path): workspace folder is missing or not a folder")
                continue
            }

            var scanned = 0
            // A capped workspace does not prevent searching the next one.
            if !walkDirectory(wsRoot, root: wsRoot, ws: ws, query: query,
                              results: &results, scanned: &scanned, unexamined: &unexamined),
               results.count < maxResults {
                unexamined.append("\(wsRoot.path): stopped after \(maxScanned) files; the rest of this workspace was not searched")
            }

            if results.count >= maxResults { break }
        }

        try await recordSearchActivity(query: query, resultCount: results.count, unexamined: unexamined)

        return WorkspaceSearchResponse(query: query, results: try results.map { try $0.get() },
                                       unexamined: unexamined.isEmpty ? nil : unexamined)
    }


    // MARK: - Activity receipt

    /// Appends the finalized outcome with redacted query/payload and unexamined scope.
    private func recordSearchActivity(query: String, resultCount: Int, unexamined: [String]) async throws {
        let event = SwiftNativePersistenceCore.activityEvent(
            id: UUID().uuidString.lowercased(),
            kind: "connector",
            title: SecretRedactor.redactText("Workspace search"),
            detail: SecretRedactor.redactText(query),
            status: unexamined.isEmpty ? "ok" : "partial",
            executionId: nil,
            payload: SecretRedactor.redactValue(.object([
                "resultCount": .int(Int64(resultCount)),
                "unexamined": .array(unexamined.map(JSONValue.string)),
            ])),
            createdAt: Self.isoTimestamp(Date())
        )
        try await SwiftNativePersistenceCore.appendActivityEvent(
            event,
            to: activityPath,
            logLabel: "Connectors"
        )
    }

    /// ISO-8601 UTC with fractional seconds and a `+00:00` offset.
    nonisolated static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
    }

    /// Stops at either bound; recursion shares the workspace's scan count.
    private func walkDirectory(
        _ dir: URL,
        root: URL,
        ws: [String: JSONValue],
        query: String,
        results: inout [Result<WorkspaceSearchResult, Error>],
        scanned: inout Int,
        unexamined: inout [String]
    ) -> Bool {
        let skipDirs: Set<String> = [".git", ".build", "node_modules", "__pycache__"]

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                options: []
            )
        } catch {
            unexamined.append("\(dir.path): folder could not be listed: \(error.localizedDescription)")
            return true
        }

        var files: [URL] = []
        var subdirs: [URL] = []
        for entry in entries {
            let rv: URLResourceValues
            do { rv = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) } catch {
                unexamined.append("\(entry.path): could not be inspected: \(error.localizedDescription)")
                continue
            }
            if rv.isDirectory == true {
                // Exclusions match directory names only.
                if !skipDirs.contains(entry.lastPathComponent) {
                    subdirs.append(entry)
                }
            } else if rv.isRegularFile == true {
                files.append(entry)
            }
        }

        for file in files {
            if results.count >= maxResults { return false }
            scanned += 1
            if scanned > maxScanned { return false }

            let filename = file.lastPathComponent
            let rel = Self.relativePath(of: file, under: root)
            var matchReason = ""
            let lowerName = filename.lowercased()
            let lowerRel = rel.lowercased()
            if lowerName.contains(query) || lowerRel.contains(query) {
                matchReason = "filename"
            } else {
                // Sizes came with the listing; a file too large to read is
                // searched by name only, which is its ordinary scope.
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if let size, size <= maxContentBytes {
                    // Text decoding tolerates non-UTF8 bytes.
                    do {
                        let data = try Data(contentsOf: file)
                        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                        if text.lowercased().contains(query) { matchReason = "content" }
                    } catch {
                        unexamined.append("\(file.path): contents could not be read: \(error.localizedDescription)")
                    }
                } else if size == nil {
                    unexamined.append("\(file.path): size could not be read, so its contents were not searched")
                }
            }
            if !matchReason.isEmpty {
                // Retain identity failures until after the finalized activity receipt.
                results.append(Result {
                    let row = try JSONRow(.object(ws))
                    return WorkspaceSearchResult(workspaceId: try row.optionalString("id"),
                        workspaceName: try row.optionalString("name"), path: file.path,
                        relativePath: rel, reason: matchReason)
                })
            }
        }

        // Sorted subdirectories keep cap truncation reproducible.
        for sub in subdirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if !walkDirectory(sub, root: root, ws: ws, query: query,
                              results: &results, scanned: &scanned, unexamined: &unexamined) {
                return false
            }
        }
        return true
    }

    // MARK: - helpers

    static func workspaceURL(_ value: JSONValue?) -> URL? {
        let path = value?.stringValue ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: NativeAgentWorkspaceRoot.fileSpelling(path))
    }

    /// POSIX relative path of standardized file URLs.
    private static func relativePath(of file: URL, under root: URL) -> String {
        NativeAgentWorkspaceRoot.relativePath(file.standardizedFileURL.path, under: root.standardizedFileURL.path)
            ?? file.lastPathComponent
    }
}

// Connector redaction uses NativeAgentCore's canonical contract.
typealias SecretRedactor = NativeAgentSecretRedactor
