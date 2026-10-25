import Privacy
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Connectors.swift` | Canonical workspace-array read and tilde-expanded string paths for search and journal roots; empty search queries return nil for the action's empty envelope |

// Connectors runs in the app process. Swift owners manage the registry,
// credentials, provider actions and receipts. This client reads saved workspaces,
// searches their local files and records redacted search activity under the
// configured data root.

public final class SwiftNativeConnectorsClient: Sendable {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore
    private let maxResults = 50
    private let maxScanned = 2000
    private let maxContentBytes = 512_000

    public init(root: URL) {
        self.root = root
        self.persistence = SwiftNativePersistenceCore()
    }

    private var workspacesPath: URL {
        root.appendingPathComponent("connectors/workspaces.json")
    }

    /// Mirror `Daemon.activity_path`:
    /// <root>/activity/events.jsonl.
    private var activityPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
    }

    public func listWorkspaces() async throws -> [JSONValue] {
        let raw = try await persistence.readJSON(workspacesPath, ifMissing: .array([]))
        guard case .array(let arr) = raw else {
            throw PersistenceCoreError.ioFailure("\(workspacesPath.path) is not a list of workspaces; repair it before searching")
        }
        return arr
    }

    public func searchWorkspaces(query rawQuery: String) async throws -> JSONValue? {
        // Empty queries return nil; ConnectorRegistryActions projects an empty result.
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return nil }

        var results: [JSONValue] = []
        // Scope the search could not examine, "path: why": a miss there is
        // not a searched-and-absent miss.
        var unexamined: [JSONValue] = []
        let workspaces = try await listWorkspaces()

        for workspace in workspaces {
            guard case .object(let ws) = workspace, let wsRoot = Self.workspaceURL(ws["path"]) else {
                unexamined.append(.string("a workspace entry has no path"))
                continue
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: wsRoot.path, isDirectory: &isDir), isDir.boolValue else {
                unexamined.append(.string("\(wsRoot.path): workspace folder is missing or not a folder"))
                continue
            }

            // The scan cap is per workspace; the result cap spans all workspaces.
            var scanned = 0
            // A capped workspace does not prevent searching the next one.
            if !walkDirectory(wsRoot, root: wsRoot, ws: ws, query: query,
                              results: &results, scanned: &scanned, unexamined: &unexamined),
               results.count < maxResults {
                unexamined.append(.string("\(wsRoot.path): stopped after \(maxScanned) files; the rest of this workspace was not searched"))
            }

            if results.count >= maxResults { break }
        }

        // Daemon parity: append the SAME redacted
        // activity row the daemon writes at the END of search_workspaces, AFTER
        // the result set is finalized. `query` is already strip().lower()'d
        // above (matches the daemon, which passes its lowercased `query`).
        try await recordSearchActivity(query: query, resultCount: results.count, unexamined: unexamined)

        var envelope: [String: JSONValue] = ["query": .string(query), "results": .array(results)]
        if !unexamined.isEmpty { envelope["unexamined"] = .array(unexamined) }
        return .object(envelope)
    }


    // MARK: - Activity event parity (FLIP PREREQ — wave 32 W20)

    /// Mirror the daemon's
    ///   record_activity("connector", "Workspace search", query, "ok",
    ///                   payload={"resultCount": len(results)})
    /// at the tail of `search_workspaces`, via
    /// `Daemon.record_activity` (L5222). Envelope keys + redaction match
    /// byte-for-byte (append_jsonl uses json.dumps(sort_keys=True), which
    /// `appendJSONL`/`serialize(pretty:false)` reproduce) — EXCEPT the
    /// `createdAt` precision (Swift millis vs Python micros; see isoTimestamp):
    ///   {id, kind, title, detail, status, executionId, payload, createdAt}.
    /// - title  = redact("Workspace search")  (no secrets → unchanged)
    /// - detail = redact(query)               (user free text → may be redacted)
    /// - payload = redact({"resultCount": <int>}) (int → unchanged)
    /// - executionId = null (record_activity default mission_id=None)
    /// Unexamined scope remains part of the activity receipt.
    private func recordSearchActivity(query: String, resultCount: Int, unexamined: [JSONValue]) async throws {
        let event = SwiftNativePersistenceCore.activityEvent(
            id: UUID().uuidString.lowercased(),
            kind: "connector",
            title: SecretRedactor.redactText("Workspace search"),
            detail: SecretRedactor.redactText(query),
            status: unexamined.isEmpty ? "ok" : "partial",
            executionId: nil,
            payload: SecretRedactor.redactValue(.object([
                "resultCount": .int(Int64(resultCount)),
                "unexamined": .array(unexamined),
            ])),
            createdAt: Self.isoTimestamp(Date())
        )
        try await SwiftNativePersistenceCore.appendActivityEvent(
            event,
            to: activityPath,
            using: persistence,
            logLabel: "Connectors"
        )
    }

    /// ISO-8601 UTC with fractional seconds and a `+00:00` offset, mirroring the
    /// wave-31 W03 convention (`SwiftNativeResearchClient.isoTimestamp`). Python's
    /// `now_iso()` emits microsecond precision; this emits millisecond precision
    /// — an accepted, already-shipped cutover divergence on the informational
    /// `createdAt` field (sortable, never byte-compared by consumers).
    nonisolated static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
    }

    /// Faithful os.walk(top-down) port for ONE directory level: process this
    /// directory's regular files FIRST (matching `for filename in files`), then
    /// recurse into its non-skipped subdirectories (matching the pruned
    /// `dirs[:]`). Returns false when a cap forces the workspace walk to stop.
    /// `scanned` is the per-workspace counter (shared across the recursion).
    private func walkDirectory(
        _ dir: URL,
        root: URL,
        ws: [String: JSONValue],
        query: String,
        results: inout [JSONValue],
        scanned: inout Int,
        unexamined: inout [JSONValue]
    ) -> Bool {
        let skipDirs: Set<String> = [".git", ".build", "node_modules", "__pycache__"]
        let wsId = ws["id"]
        let wsName = ws["name"]

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                options: []
            )
        } catch {
            unexamined.append(.string("\(dir.path): folder could not be listed: \(error.localizedDescription)"))
            return true
        }

        var files: [URL] = []
        var subdirs: [URL] = []
        for entry in entries {
            let rv: URLResourceValues
            do { rv = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) } catch {
                unexamined.append(.string("\(entry.path): could not be inspected: \(error.localizedDescription)"))
                continue
            }
            if rv.isDirectory == true {
                // os.walk prunes by DIRECTORY NAME only (the `dirs[:]` filter),
                // not by absolute path — so a workspace nested under an ancestor
                // literally named `node_modules` is NOT skipped, and a regular
                // FILE named `.git` is NOT skipped (gpt-5.5 review #3).
                if !skipDirs.contains(entry.lastPathComponent) {
                    subdirs.append(entry)
                }
            } else if rv.isRegularFile == true {
                files.append(entry)
            }
        }

        // Process this directory's files before descending (os.walk top-down).
        for file in files {
            // Python: results>=50 break BEFORE incrementing scanned for the file.
            if results.count >= maxResults { return false }
            scanned += 1
            // Then scanned>2000 break AFTER the increment.
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
                    // file_path.read_text(errors="ignore"): best-effort lossy
                    // decode; isoLatin1 never fails so it mirrors errors="ignore"
                    // tolerance for non-UTF8 bytes.
                    do {
                        let data = try Data(contentsOf: file)
                        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                        if text.lowercased().contains(query) { matchReason = "content" }
                    } catch {
                        unexamined.append(.string("\(file.path): contents could not be read: \(error.localizedDescription)"))
                    }
                } else if size == nil {
                    unexamined.append(.string("\(file.path): size could not be read, so its contents were not searched"))
                }
            }
            if !matchReason.isEmpty {
                results.append(.object([
                    "workspaceId": wsId ?? .null,
                    "workspaceName": wsName ?? .null,
                    "path": .string(file.path),
                    "relativePath": .string(rel),
                    "reason": .string(matchReason),
                ]))
            }
        }

        // Recurse into subdirs (sorted for deterministic order; os.walk order is
        // OS-dependent, but a stable order keeps the cap-truncation reproducible).
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
        let path = stringField(value)
        return path.isEmpty ? nil : URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    private static func stringField(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        if case .string(let s) = v { return s }
        return ""
    }

    /// `file.relative_to(root)` — POSIX relative path of `file` under `root`.
    /// Both are already standardized fileURLs; strip the root prefix.
    private static func relativePath(of file: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return file.lastPathComponent
    }
}

// Keep the historical module-local spelling while the canonical eight-pattern
// contract lives in NativeAgentCore.
typealias SecretRedactor = NativeAgentSecretRedactor
