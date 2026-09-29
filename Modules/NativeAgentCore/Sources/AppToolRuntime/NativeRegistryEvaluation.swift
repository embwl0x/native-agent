import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

public enum NativeRegistryEvaluation {
    public typealias ProcessPort = (String, [String], URL, TimeInterval) async throws -> (status: Int32, detail: String)

    public static func runEval(name: String, process: ProcessPort) async throws -> JSONValue {
        // DAEMON-DEAD PORT (2026-06-03): manual eval runs a bounded Swift-native
        // harness and persists the result to evals/runs.json.
        let started = Date()
        let repoRoot = PersistenceCore.defaultDataRoot().deletingLastPathComponent()
        let smokeScript = repoRoot
            .appendingPathComponent("script", isDirectory: true)
            .appendingPathComponent("smoke_all.sh")
        let checks: [JSONValue] = [
            try await Self.evalProcessCheck(
                id: "swift_build",
                title: "Swift package builds",
                executable: "/usr/bin/swift",
                arguments: ["build"],
                currentDirectory: repoRoot,
                timeout: 180, process: process
            ),
            try await Self.evalProcessCheck(
                id: "native_smoke",
                title: "Native smoke sweep passes",
                executable: "/bin/zsh",
                arguments: [smokeScript.path],
                currentDirectory: repoRoot,
                timeout: 240, process: process
            ),
        ]
        let passed = checks.allSatisfy { check in
            guard case .object(let obj) = check, case .bool(let ok)? = obj["passed"] else { return false }
            return ok
        }
        let duration = Date().timeIntervalSince(started)
        let row: JSONValue = .object([
            "id": .string("eval-\(UUID().uuidString.lowercased())"),
            "name": .string(name),
            "status": .string(passed ? "passed" : "failed"),
            "checks": .array(checks),
            "createdAt": .string(SwiftNativeManifestSigner.isoTimestamp(started)),
            "durationSeconds": .double(duration),
        ])
        try await Self.appendEvalRun(row)
        return row
    }

    private static func evalProcessCheck(
        id: String,
        title: String,
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval,
        process: ProcessPort
    ) async throws -> JSONValue {
        let result = try await process(executable, arguments, currentDirectory, timeout)
        return .object([
            "id": .string(id),
            "title": .string(title),
            "passed": .bool(result.status == 0),
            "detail": .string(result.detail),
        ])
    }

    private static func appendEvalRun(_ row: JSONValue) async throws {
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("evals", isDirectory: true)
            .appendingPathComponent("runs.json")
        try await appendBoundedRun(row, to: path)
    }

    public static func appendBoundedRun(_ row: JSONValue, to path: URL) async throws {
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let raw = try await persistence.readJSON(path, ifMissing: .array([]))
            var rows: [JSONValue]
            if case .array(let existing) = raw {
                rows = existing
            } else {
                rows = []
            }
            rows.append(row)
            if rows.count > 200 {
                rows = Array(rows.suffix(200))
            }
            try await persistence.writeJSON(.array(rows), to: path)
        }
    }

}
