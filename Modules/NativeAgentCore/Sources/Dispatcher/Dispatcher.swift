import Experiences
import Foundation
import NativeAgentShared
import ChatToolParsing
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `Dispatcher.swift` | `DispatchResult`, `SwiftNativeDispatcher`: read-only admission; `ChatToolOutcome` owns verification |

// MARK: - Native dispatcher infrastructure
// Missing handlers fail closed with a receipt in the life record.

// MARK: - Dispatch context

public struct DispatchContext: Sendable {
    public var turn: Turn?
    public var deadlines: OperationDeadlines
    public var fileReadOptions: FileReadOptions
    public var repoRoot: URL?
    public var surface: String
    public var persona: String
    public var dataRoot: URL?
    public var workspaceRoot: URL?
    public var extraAllowedRoots: [URL]
    public var extra: [String: JSONValue]

    public init(
        repoRoot: URL?,
        surface: String,
        persona: String,
        extra: [String: JSONValue] = [:],
        dataRoot: URL? = nil,
        workspaceRoot: URL? = nil,
        extraAllowedRoots: [URL] = [],
        turn: Turn?, deadlines: OperationDeadlines, fileReadOptions: FileReadOptions = .init()
    ) {
        self.turn = turn; self.deadlines = deadlines; self.fileReadOptions = fileReadOptions
        self.repoRoot = repoRoot
        self.surface = surface
        self.persona = persona
        self.extra = extra
        self.dataRoot = dataRoot
        self.workspaceRoot = workspaceRoot
        self.extraAllowedRoots = extraAllowedRoots
    }

    public static func defaultForSurface(_ surface: String, turn: Turn?, deadlines: OperationDeadlines) -> DispatchContext {
        DispatchContext(repoRoot: nil, surface: surface, persona: "", turn: turn, deadlines: deadlines)
    }

}

public struct DispatchError: Sendable, Equatable {
    public var code: String
    public var message: String
    public var tool: String?
    public var argsHash: String?
    public var recoverable: Bool

    public init(code: String, message: String, tool: String?, argsHash: String?, recoverable: Bool) {
        self.code = code
        self.message = message
        self.tool = tool
        self.argsHash = argsHash
        self.recoverable = recoverable
    }
}

public struct DispatchResult: Sendable, Equatable {
    public var ok: Bool
    public var tool: String
    public var status: String
    public var output: JSONValue?
    public var error: DispatchError?
    public var executed: Bool
    public var verifyPassed: Bool?
    public var durationUs: Int
    public var durationMs: Int { Int((Double(durationUs) / 1000.0).rounded()) }
    public var argsHash: String
    public var effectiveAutonomy: String
    public var autonomySource: String
    public var providerMatch: Bool
    public var runId: String
    public var startedAt: String

    public init(
        ok: Bool,
        tool: String,
        status: String,
        output: JSONValue?,
        error: DispatchError?,
        executed: Bool,
        verifyPassed: Bool?,
        durationUs: Int,
        argsHash: String,
        effectiveAutonomy: String,
        autonomySource: String,
        providerMatch: Bool,
        runId: String,
        startedAt: String
    ) {
        self.ok = ok
        self.tool = tool
        self.status = status
        self.output = output
        self.error = error
        self.executed = executed
        self.verifyPassed = verifyPassed
        self.durationUs = durationUs
        self.argsHash = argsHash
        self.effectiveAutonomy = effectiveAutonomy
        self.autonomySource = autonomySource
        self.providerMatch = providerMatch
        self.runId = runId
        self.startedAt = startedAt
    }
}

// MARK: - Errors

public enum DispatcherError: Error, LocalizedError, Equatable {
    case missingTool
    case ledgerFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingTool: return "An action name is required."
        case .ledgerFailure(let m): return "dispatcher: ledger write failed: \(m)"
        }
    }
}

// Stable error paths distinguish malformed input; extra-context input takes precedence.
private func validateDispatchValues(_ value: JSONValue, path: String = "") throws {
    switch value {
    case .double(let number) where !number.isFinite:
        throw PersistenceCoreError.nonFiniteFloat(number, path: path)
    case .array(let values):
        for (index, value) in values.enumerated() {
            try validateDispatchValues(value, path: "\(path)[\(index)]")
        }
    case .object(let fields):
        for (key, value) in fields.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
            try validateDispatchValues(value, path: path.isEmpty ? key : "\(path).\(key)")
        }
    default: break
    }
}

// MARK: - Helpers

public func dispatcherArgsHash(_ input: [String: JSONValue]) -> String {
    let canonical: String
    do {
        canonical = try JSONValue.object(input).serialize(pretty: false)
    } catch {
        canonical = "{}"
    }
    let bytes = Array(canonical.utf8)
    let hex = _sha256Hex(bytes)
    return String(hex.prefix(16))
}

private func _sha256Hex(_ bytes: [UInt8]) -> String {
    let digest = SHA256.hash(data: Data(bytes))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Use monotonic duration so wall-clock changes cannot distort native action timing.
enum DispatchClockMonotonic {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func elapsedMicros(since start: UInt64) -> Int {
        let endNs = DispatchTime.now().uptimeNanoseconds
        guard endNs > start else { return 0 }
        return Int((endNs - start) / 1000)
    }
}

// MARK: - SwiftNativeDispatcher

/// A read-only dispatcher; writable registrations fail closed before execution.
public actor SwiftNativeDispatcher {
    private let dataRoot: URL
    /// Missing handlers fail closed; production uses the read-only NativeActionDispatch registry.
    private let localActions: LocalConnectorActions?
    private let timeout: TimeInterval

    public init(
        timeout: TimeInterval = 60,
        dataRoot: URL = defaultDataRoot(),
        localActions: LocalConnectorActions? = nil
    ) {
        self.timeout = timeout
        self.dataRoot = dataRoot
        self.localActions = localActions
    }

    public func dispatch(
        tool: String,
        input: [String: JSONValue],
        ctx: DispatchContext,
        dryRun: Bool
    ) async throws -> DispatchResult {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Record malformed input before returning so rejected dispatch attempts remain visible.
            let result = DispatchResult(
                ok: false, tool: trimmed, status: "failed", output: nil,
                error: DispatchError(
                    code: "invalid_input",
                    message: "An action name is required.",
                    tool: nil,
                    argsHash: dispatcherArgsHash(input),
                    recoverable: false
                ),
                executed: false, verifyPassed: nil, durationUs: 0,
                argsHash: dispatcherArgsHash(input), effectiveAutonomy: "", autonomySource: "",
                providerMatch: true, runId: UUID().uuidString.lowercased(),
                startedAt: NativeTimestampFormat.flooredOptionalMicrosecondUTCOffset(Date())
            )
            await tryWriteLedger(result, ctx: ctx, input: input)
            throw DispatcherError.missingTool
        }

        let runId = UUID().uuidString.lowercased()
        let startedAt = NativeTimestampFormat.flooredOptionalMicrosecondUTCOffset(Date())
        do {
            var values = ctx.extra
            if values["input"] == nil { values["input"] = .object(input) }
            try validateDispatchValues(.object(values))
        } catch {
            let result = DispatchResult(
                ok: false, tool: trimmed, status: "failed", output: nil,
                error: DispatchError(
                    code: "invalid_input",
                    message: error.localizedDescription,
                    tool: trimmed,
                    argsHash: dispatcherArgsHash(input),
                    recoverable: false
                ),
                executed: false, verifyPassed: nil, durationUs: 0,
                argsHash: dispatcherArgsHash(input), effectiveAutonomy: "", autonomySource: "",
                providerMatch: true, runId: runId, startedAt: startedAt
            )
            await tryWriteLedger(result, ctx: ctx, input: input)
            throw error
        }

        // Direct construction must obey the same writable-handler refusal as production dispatch.
        if let actions = localActions, actions.canHandle(trimmed), !actions.isSideEffecting(trimmed) {
            return await runNativeAction(
                actions: actions,
                tool: trimmed,
                input: input,
                ctx: ctx,
                dryRun: dryRun,
                runId: runId,
                startedAt: startedAt
            )
        }

        let argsHash = dispatcherArgsHash(input)
        let err = DispatchError(
            code: "native_handler_missing",
            message: "No handler for action '\(trimmed)'",
            tool: trimmed,
            argsHash: argsHash,
            recoverable: false
        )
        let result = DispatchResult(
            ok: false,
            tool: trimmed,
            status: "failed",
            output: nil,
            error: err,
            executed: false,
            verifyPassed: nil,
            durationUs: 0,
            argsHash: argsHash,
            effectiveAutonomy: "never",
            autonomySource: "native_handler_missing",
            providerMatch: false,
            runId: runId,
            startedAt: startedAt
        )
        await tryWriteLedger(result, ctx: ctx, input: input)
        return result
    }

    private func runNativeAction(
        actions: LocalConnectorActions,
        tool: String,
        input: [String: JSONValue],
        ctx: DispatchContext,
        dryRun: Bool,
        runId: String,
        startedAt: String
    ) async -> DispatchResult {
        let connectorCtx = ConnectorActionContext.fromDispatch(ctx)
        let argsHash = dispatcherArgsHash(input)

        let effective = "auto"
        let autonomySource = "native"

        // A preview cannot execute even a read-only handler.
        if dryRun {
            let result = DispatchResult(
                ok: true, tool: tool, status: "dry_run", output: nil, error: nil,
                executed: false, verifyPassed: nil, durationUs: 0,
                argsHash: argsHash, effectiveAutonomy: effective, autonomySource: autonomySource,
                providerMatch: true, runId: runId, startedAt: startedAt
            )
            await tryWriteLedger(result, ctx: ctx, input: input)
            return result
        }

        let t0 = DispatchClockMonotonic.now()
        let raw: JSONValue
        if ["read_file", "file_excerpt", "list_dir", "file_info"].contains(tool) {
            // Folder prompts and unavailable volumes can block metadata syscalls; run off-executor so BoundedWait can stop waiting.
            do {
                raw = try await BoundedWait.run(seconds: timeout, reason: "file read", deadlines: ctx.deadlines) { _ in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: actions.run(tool, input: input, ctx: connectorCtx) ?? .object([
                                "ok": .bool(false), "error": .string("native handler returned nil"),
                            ]))
                        }
                    }
                }
            } catch {
                raw = .object([
                    "ok": .bool(false),
                    "error_code": .string(error is CancellationError ? "cancelled" : "timeout"),
                    "error": .string(error is CancellationError
                        ? "I stopped waiting for the files."
                        : "I couldn’t read the files in time. Check folder access and whether the drive is available."),
                ])
            }
        } else {
            raw = actions.run(tool, input: input, ctx: connectorCtx) ?? .object([
                "ok": .bool(false), "error": .string("native handler returned nil"),
            ])
        }
        let elapsedUs = DispatchClockMonotonic.elapsedMicros(since: t0)

        // Chat's terminal outcome also governs dispatch verification.
        let reply = ToolResult(raw)
        let outcome = reply.outcome
        let isPartial = ChatToolOutcome.displayOutcome(result: reply.payload, ok: nil, hasResult: true) == .partial
        var errorCode: String? = nil
        var errorMessage = ""
        if case .object(let obj) = reply.payload {
            if case .string(let s)? = obj["error_code"], !s.isEmpty { errorCode = s }
            if case .string(let s)? = obj["error"] { errorMessage = s }
        }

        // A failed result cannot erase execution or its output; only pre-execution refusals are unexecuted.
        let status: String
        let dispatchError: DispatchError?
        let executed = true
        // Successful trivial reads need no effect proof; partial or failed results cannot verify.
        let verifyPassed: Bool?
        if isPartial {
            // Partial output remains useful to slash receipts without inventing a whole-call failure.
            status = "partial"
            dispatchError = nil
            verifyPassed = nil
        } else if outcome == .succeeded {
            status = "ok"
            dispatchError = nil
            verifyPassed = actions.isTrivialVerify(tool) ? true : nil
        } else {
            status = outcome.rawValue
            verifyPassed = nil
            dispatchError = DispatchError(
                code: errorCode ?? "handler_raised",
                message: errorMessage.isEmpty ? "native action failed" : errorMessage,
                tool: tool,
                argsHash: argsHash,
                recoverable: true
            )
        }

        let result = DispatchResult(
            ok: outcome == .succeeded || isPartial,
            tool: tool,
            status: status,
            output: reply.payload,
            error: dispatchError,
            executed: executed,
            verifyPassed: verifyPassed,
            durationUs: elapsedUs,
            argsHash: argsHash,
            effectiveAutonomy: effective,
            autonomySource: autonomySource,
            providerMatch: true,
            runId: runId,
            startedAt: startedAt
        )
        await tryWriteLedger(result, ctx: ctx, input: input)
        return result
    }

    /// Ledger failure owes repair without changing the call's actual outcome.
    private func tryWriteLedger(
        _ result: DispatchResult,
        ctx: DispatchContext,
        input: [String: JSONValue]
    ) async {
        do {
            var payload: [String: JSONValue] = [
                "id":                 .string(UUID().uuidString.lowercased()),
                "kind":               .string("dispatch"),
                "tool":               .string(result.tool),
                "surface":            .string(ctx.surface),
                "persona":            .string(ctx.persona),
                "run_id":             .string(result.runId),
                "input_summary":      .string(truncateForTrace(.object(input))),
                "args_hash":          .string(result.argsHash),
                "status":             .string(result.status),
                "verify_passed":      result.verifyPassed.map { JSONValue.bool($0) } ?? .null,
                "duration_ms":        .int(Int64(result.durationMs)),
                "duration_us":        .int(Int64(result.durationUs)),
                "effective_autonomy": result.effectiveAutonomy.isEmpty ? .null : .string(result.effectiveAutonomy),
                "autonomy_source":    result.autonomySource.isEmpty ? .null : .string(result.autonomySource),
                "provider_match":     .bool(result.providerMatch),
                "error":              .null,
                "createdAt":          .string(result.startedAt),
                // Receipt provenance identifies this dispatcher independently of shared run IDs.
                "emitted_by":         .string("swift_dispatcher"),
            ]
            if let err = result.error {
                payload["error"] = .object([
                    "code":        .string(err.code),
                    "message":     .string(err.message),
                    "tool":        .string(err.tool ?? result.tool),
                    "args_hash":   .string(err.argsHash ?? result.argsHash),
                    "recoverable": .bool(err.recoverable),
                ])
            }
            payload["executed"] = .bool(result.executed)
            let id = UUID().uuidString.lowercased()
            let event = TurnTraceEvent(
                kind: "dispatch",
                title: "tool:\(result.tool)",
                status: result.status,
                payload: .object(payload),
                id: id,
                createdAt: result.startedAt, turn: ctx.turn
            )
            try await TurnTracePersistLane(dataRootOverride: dataRoot).appendChecked(event)
            RepairOwed.settle(dataRoot, operation: "dispatch.ledger", evidence: .init(source: "detail", id: id))
        } catch {
            // The call keeps its own outcome; the lost row is owed, not hidden.
            let path = dataRoot.appendingPathComponent("experiences/experiences.sqlite")
            let failure = DispatcherError.ledgerFailure(error.localizedDescription)
            RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "dispatch.ledger",
                           owner: path.path, words: """
                               \(path.path) did not record \(result.tool)'s \(result.status) row (\(failure.localizedDescription)); the call itself kept \
                               its outcome.
                               """)
        }
    }
}

private func truncateForTrace(_ value: JSONValue, maxChars: Int = 200) -> String {
    let s: String
    do { s = try value.serialize(pretty: false) }
    catch { return "[trace serialization unavailable: \(error.localizedDescription)]" }
    if s.count <= maxChars { return s }
    return String(s.prefix(maxChars)) + "...(truncated)"
}
