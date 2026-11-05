import Privacy
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Connectors.swift` | Checked workspace search and identity; capped or unvisited scope remains explicit |

// Search files before subdirectories so a workspace's own files get the bounded search budget first.

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
        // Unexamined scope cannot prove that a match is absent.
        var unexamined: [String] = []
        let workspaces = try await listWorkspaces()

        for workspace in workspaces {
            guard case .object(let ws) = workspace, let wsRoot = Self.workspaceURL(ws["path"]) else {
                unexamined.append("a workspace entry has no path")
                continue
            }
            if results.count >= maxResults {
                unexamined.append("\(wsRoot.path): workspace was not searched because the overall \(maxResults)-result limit was reached")
                continue
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: wsRoot.path, isDirectory: &isDir), isDir.boolValue else {
                unexamined.append("\(wsRoot.path): workspace folder is missing or not a folder")
                continue
            }

            var scanned = 0
            // A per-workspace scan cap does not prevent searching the next one.
            switch walkDirectory(wsRoot, root: wsRoot, ws: ws, query: query,
                                 results: &results, scanned: &scanned, unexamined: &unexamined) {
            case .finished:
                break
            case .resultLimit:
                unexamined.append("\(wsRoot.path): the rest of this workspace was not searched because the overall \(maxResults)-result limit was reached")
            case .scanLimit:
                unexamined.append("\(wsRoot.path): stopped after \(maxScanned) files; the rest of this workspace was not searched")
            }
        }

        try await recordSearchActivity(query: query, resultCount: results.count, unexamined: unexamined)

        return WorkspaceSearchResponse(query: query, results: try results.map { try $0.get() },
                                       unexamined: unexamined.isEmpty ? nil : unexamined)
    }


    // MARK: - Activity receipt

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

    nonisolated static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
    }

    /// A finished traversal may still have I/O gaps recorded in `unexamined`.
    private enum WalkOutcome {
        case finished
        case resultLimit
        case scanLimit
    }

    /// Stops at either bound, preserving its reason through recursion.
    private func walkDirectory(
        _ dir: URL,
        root: URL,
        ws: [String: JSONValue],
        query: String,
        results: inout [Result<WorkspaceSearchResult, Error>],
        scanned: inout Int,
        unexamined: inout [String]
    ) -> WalkOutcome {
        if results.count >= maxResults { return .resultLimit }
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
            return .finished
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
                if !skipDirs.contains(entry.lastPathComponent) {
                    subdirs.append(entry)
                }
            } else if rv.isRegularFile == true {
                files.append(entry)
            }
        }

        for file in files {
            if results.count >= maxResults { return .resultLimit }
            if scanned >= maxScanned { return .scanLimit }
            scanned += 1

            let filename = file.lastPathComponent
            let rel = Self.relativePath(of: file, under: root)
            var matchReason = ""
            let lowerName = filename.lowercased()
            let lowerRel = rel.lowercased()
            if lowerName.contains(query) || lowerRel.contains(query) {
                matchReason = "filename"
            } else {
                // Oversized files remain name-searchable without reading their contents.
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if let size, size <= maxContentBytes {
                    // Content matches require a supported text encoding.
                    do {
                        let data = try Data(contentsOf: file)
                        guard let text = String(data: data, encoding: .utf8) else {
                            unexamined.append("\(file.path): contents are not UTF-8; encoding is unavailable, so contents were not searched")
                            continue
                        }
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
            let outcome = walkDirectory(sub, root: root, ws: ws, query: query,
                                        results: &results, scanned: &scanned, unexamined: &unexamined)
            switch outcome {
            case .finished:
                continue
            case .resultLimit, .scanLimit:
                return outcome
            }
        }
        return .finished
    }

    // MARK: - helpers

    static func workspaceURL(_ value: JSONValue?) -> URL? {
        let path = value?.stringValue ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: NativeAgentWorkspaceRoot.fileSpelling(path))
    }

    private static func relativePath(of file: URL, under root: URL) -> String {
        NativeAgentWorkspaceRoot.relativePath(file.standardizedFileURL.path, under: root.standardizedFileURL.path)
            ?? file.lastPathComponent
    }
}

typealias SecretRedactor = NativeAgentSecretRedactor
