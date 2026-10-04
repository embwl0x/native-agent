import FeedPolicy
import Privacy
import Foundation
import NativeAgentCore
import PersistenceCore

// Connectors runs in the app process. Swift owners manage the registry,
// credentials, provider actions and receipts. This client reads saved workspaces,
// searches their local files and records redacted search activity under the
// configured data root.

// MARK: - Client protocol

public protocol ConnectorsClient: Sendable {
    /// The saved workspace rows (default []).
    /// Returns the array as-stored (passthrough, no field reshaping).
    func listWorkspaces() async throws -> [JSONValue]

    /// Returns {"query": <normalized>, "results": [...]} for a local search,
    /// or nil when the query is empty.
    func searchWorkspaces(query: String) async throws -> JSONValue?
}

// MARK: - SwiftNative impl

public final class SwiftNativeConnectorsClient: ConnectorsClient {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore
    /// Caps mirror the daemon (search_workspaces L27982/L27985).
    private let maxResults: Int
    private let maxScanned: Int
    private let maxContentBytes: Int
    /// Test seams for the activity-event append (mirror Research's `now` /
    /// `receiptIDFactory`). Default to wall clock + uuid4, matching the daemon.
    private let now: @Sendable () -> Date
    private let activityIDFactory: @Sendable () -> String

    public init(
        root: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        maxResults: Int = 50,
        maxScanned: Int = 2000,
        maxContentBytes: Int = 512_000,
        now: @escaping @Sendable () -> Date = { Date() },
        activityIDFactory: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.root = root
        self.persistence = persistence
        self.maxResults = maxResults
        self.maxScanned = maxScanned
        self.maxContentBytes = maxContentBytes
        self.now = now
        self.activityIDFactory = activityIDFactory
    }

    private var workspacesPath: URL {
        root.appendingPathComponent("connectors/workspaces.json")
    }

    /// Mirror `Daemon.activity_path`:
    /// <root>/activity/events.jsonl.
    private var activityPath: URL {
        root.appendingPathComponent("activity/events.jsonl")
    }

    public func listWorkspaces() async throws -> [JSONValue] {
        // Python: read_json(workspaces_path, []); if not list -> [].
        let raw = try await persistence.readJSON(workspacesPath, ifMissing: .array([]))
        if case .array(let arr) = raw { return arr }
        return []
    }

    public func searchWorkspaces(query rawQuery: String) async throws -> JSONValue? {
        // Python: query = str(body.get("query")).strip().lower(); if not query: raise.
        // We mirror strip().lower(); an empty result returns nil so the caller
        // falls through to HTTP where the daemon raises the real ValueError.
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return nil }

        var results: [JSONValue] = []
        let workspaces = try await listWorkspaces()

        for workspace in workspaces {
            guard case .object(let ws) = workspace else { continue }
            let rootStr = Self.stringField(ws["path"])
            if rootStr.isEmpty { continue }
            let wsRoot = URL(fileURLWithPath: rootStr)
            // Python: if not root.exists(): continue. (os.walk over a file path
            // yields nothing, so requiring a directory matches Python behavior.)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: wsRoot.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            // `scanned` RESETS per workspace (gpt-5.5 review #1, 2026-06-01):
            // the daemon's `scanned>2000` only breaks the CURRENT workspace's
            // os.walk, never the outer `for workspace` loop. Only the global
            // `len(results)>=50` cap effectively halts everything.
            var scanned = 0
            // walkDir returns false when the WORKSPACE walk must stop (either
            // cap hit). Whether to continue to the NEXT workspace is decided by
            // the global results cap below, mirroring Python.
            _ = walkDirectory(wsRoot, root: wsRoot, ws: ws, query: query,
                              results: &results, scanned: &scanned)

            // Python outer loop: `if len(results) >= 50 or scanned > 2000: break`.
            // scanned>2000 here would NOT actually skip later workspaces in
            // Python because scanned resets — but the outer break IS hit, then
            // the next `for workspace` iteration resets scanned and proceeds.
            // The only cross-workspace-terminating condition is results>=50.
            if results.count >= maxResults { break }
        }

        // Daemon parity: append the SAME redacted
        // activity row the daemon writes at the END of search_workspaces, AFTER
        // the result set is finalized. `query` is already strip().lower()'d
        // above (matches the daemon, which passes its lowercased `query`).
        try await recordSearchActivity(query: query, resultCount: results.count)

        return .object([
            "query": .string(query),
            "results": .array(results),
        ])
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
    ///   {id, kind, title, detail, status, missionId, payload, createdAt}.
    /// - title  = redact("Workspace search")  (no secrets → unchanged)
    /// - detail = redact(query)               (user free text → may be redacted)
    /// - payload = redact({"resultCount": <int>}) (int → unchanged)
    /// - missionId = null (record_activity default mission_id=None)
    /// - status = "ok"
    private func recordSearchActivity(query: String, resultCount: Int) async throws {
        let event: JSONValue = .object([
            "id": .string(activityIDFactory()),
            "kind": .string("connector"),
            "title": .string(SecretRedactor.redactText("Workspace search")),
            "detail": .string(SecretRedactor.redactText(query)),
            "status": .string("ok"),
            "executionId": .null,
            "payload": SecretRedactor.redactValue(.object([
                "resultCount": .int(Int64(resultCount)),
            ])),
            "createdAt": .string(Self.isoTimestamp(now())),
        ])
        // The shared owner takes the one-sided Swift flock and amortizes the
        // newest-5000 trim behind the activity feed's byte trigger. Do not
        // reintroduce an exact full-file count on every workspace search.
        try await appendJSONLCapped(
            event,
            to: activityPath,
            using: persistence,
            maxLines: JSONLLineCaps.activityEvents,
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
        scanned: inout Int
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
            // os.walk silently skips dirs it can't list (onerror=None default).
            return true
        }

        var files: [URL] = []
        var subdirs: [URL] = []
        for entry in entries {
            let rv = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if rv?.isDirectory == true {
                // os.walk prunes by DIRECTORY NAME only (the `dirs[:]` filter),
                // not by absolute path — so a workspace nested under an ancestor
                // literally named `node_modules` is NOT skipped, and a regular
                // FILE named `.git` is NOT skipped (gpt-5.5 review #3).
                if !skipDirs.contains(entry.lastPathComponent) {
                    subdirs.append(entry)
                }
            } else if rv?.isRegularFile == true {
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
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
                if size <= maxContentBytes {
                    // file_path.read_text(errors="ignore"): best-effort lossy
                    // decode; isoLatin1 never fails so it mirrors errors="ignore"
                    // tolerance for non-UTF8 bytes.
                    if let data = try? Data(contentsOf: file),
                       let text = String(data: data, encoding: .utf8)
                            ?? String(data: data, encoding: .isoLatin1) {
                        if text.lowercased().contains(query) {
                            matchReason = "content"
                        }
                    }
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
                              results: &results, scanned: &scanned) {
                return false
            }
        }
        return true
    }

    // MARK: - helpers

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

// MARK: - Factory

/// Returns the SwiftNative client. `root` is the data root (the dir that
/// contains `connectors/`); injectable for tests.
public func makeConnectorsClient(
    root: URL
) -> any ConnectorsClient {
    return SwiftNativeConnectorsClient(root: root)
}
