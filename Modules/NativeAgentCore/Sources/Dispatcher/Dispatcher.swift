import Experiences
import Foundation
import NativeAgentShared
import ChatToolParsing
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `Dispatcher.swift` | `DispatchResult`, read-only `SwiftNativeDispatcher` with a fail-closed writable-handler boundary and direct trace receipts; dispatch status and read verification derive from `ChatToolOutcome` exact/display classes; partial reads retain visible output without a fabricated error or verification claim |

// MARK: - Native dispatcher infrastructure
//
// Shapes requests and receipts, applies autonomy decisions and writes the
// flock-protected dispatch ledger at <dataRoot>/traces/events.jsonl.
// NativeActionDispatch supplies the shipped read-only connector handlers.
// Missing handlers fail closed with a Swift receipt.

// MARK: - Dispatch context

/// File policy and receipt context for native dispatch.
public struct DispatchContext: Sendable {
    public var repoRoot: URL?
    public var surface: String
    public var persona: String
    public var dataRoot: URL?
    public var workspaceRoot: URL?
    public var extraAllowedRoots: [URL]
    /// File-access policy and request values.
    public var extra: [String: JSONValue]

    public init(
        repoRoot: URL?,
        surface: String,
        persona: String,
        extra: [String: JSONValue] = [:],
        dataRoot: URL? = nil,
        workspaceRoot: URL? = nil,
        extraAllowedRoots: [URL] = []
    ) {
        self.repoRoot = repoRoot
        self.surface = surface
        self.persona = persona
        self.extra = extra
        self.dataRoot = dataRoot
        self.workspaceRoot = workspaceRoot
        self.extraAllowedRoots = extraAllowedRoots
    }

    /// Convenience constructor with sensible Mac-app defaults.
    public static func defaultForSurface(_ surface: String) -> DispatchContext {
        DispatchContext(repoRoot: nil, surface: surface, persona: "")
    }

}

/// Structured error carried by a DispatchResult and its ledger payload.
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

/// Native dispatch receipt.
public struct DispatchResult: Sendable, Equatable {
    public var ok: Bool
    public var tool: String
    public var status: String          // "ok"|"partial"|"failed"|"blocked"|"pending_approval"|"dry_run"
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
        case .missingTool: return "dispatcher: tool name is required"
        case .ledgerFailure(let m): return "dispatcher: ledger write failed: \(m)"
        }
    }
}

// Validate input and extra context with stable field paths; extra-context input takes precedence.
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

/// First 16 hex digits of SHA-256 over canonical, sorted-key JSON input.
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

/// Native action durations use DispatchTime, independent of wall-clock changes.
enum DispatchClockMonotonic {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func elapsedMicros(since start: UInt64) -> Int {
        let endNs = DispatchTime.now().uptimeNanoseconds
        guard endNs > start else { return 0 }
        return Int((endNs - start) / 1000)
    }
}

// MARK: - SwiftNativeDispatcher
//
// Owns request and receipt shaping, run IDs, native execution and ledger writes; missing handlers fail closed.

/// A read-only dispatcher; writable registrations fail closed before execution.
public actor SwiftNativeDispatcher {
    private let ledgerPath: URL
    /// Runs registered connector actions in-process. Nil or missing handlers
    /// fail closed; production callers supply NativeActionDispatch's registry.
    private let localActions: LocalConnectorActions?
    private let timeout: TimeInterval

    public init(
        timeout: TimeInterval = 60,
        ledgerPath: URL = defaultDataRoot().appendingPathComponent("traces/events.jsonl"),
        localActions: LocalConnectorActions? = nil
    ) {
        self.timeout = timeout
        self.ledgerPath = ledgerPath
        self.localActions = localActions
    }

    public func dispatch(
        tool: String,
        input: [String: JSONValue],
        ctx: DispatchContext,
        dryRun: Bool
    ) async throws -> DispatchResult {
        // Reject malformed input before native execution.
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Write a failed ledger entry first so the dispatch attempt is
            // visible even when the input is malformed.
            let result = DispatchResult(
                ok: false, tool: trimmed, status: "failed", output: nil,
                error: DispatchError(
                    code: "invalid_input",
                    message: "tool name is required",
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

        // Writable registrations use the same fail-closed receipt as absent
        // handlers, including when callers construct the dispatcher directly.
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
            message: "No Swift-native handler for tool '\(trimmed)'",
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

        // Dry runs leave even read-only handlers unexecuted.
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
            let imageSink = LocalToolImage.sink
            // Folder permission prompts and unavailable volumes can block even
            // metadata reads. Keep them off the caller's executor; BoundedWait
            // can abandon a read without waiting for that syscall to return.
            do {
                raw = try await BoundedWait.run(seconds: timeout, reason: "file read") {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            LocalToolImage.$sink.withValue(imageSink) {
                                continuation.resume(returning: actions.run(tool, input: input, ctx: connectorCtx) ?? .object([
                                    "ok": .bool(false), "error": .string("native handler returned nil"),
                                ]))
                            }
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

        // Use the same terminal outcome as chat before assigning verification.
        let outcome = ChatToolOutcome.exactResultClass(raw)
        let isPartial = ChatToolOutcome.displayOutcome(result: raw, ok: nil, hasResult: true) == .partial
        var errorCode: String? = nil
        var errorMessage = ""
        if case .object(let obj) = raw {
            // Missing or empty handler error codes use the dispatch default.
            if case .string(let s)? = obj["error_code"], !s.isEmpty { errorCode = s }
            if case .string(let s)? = obj["error"] { errorMessage = s }
        }

        // A handler that ran remains executed even when its own validation failed;
        // retain its raw output. Only pre-execution rejects are executed=false.
        let status: String
        let dispatchError: DispatchError?
        let executed = true
        // Successful read-only handlers marked trivialVerify need no separate
        // effect verification. Partial and failed results leave verification unset.
        let verifyPassed: Bool?
        if isPartial {
            // A partial read has useful output without a confirmed full result.
            // Keep it visible to slash receipts without inventing a failure.
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
            // Executed failures remain recoverable and keep the handler's own
            // error code, with the established handler_raised default.
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
            // Always retain raw handler output, including failure details.
            output: raw,
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

    /// Build + write a ledger entry. A failed write never changes the call's
    /// outcome; it owes its repair, so the missing row is known.
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
                createdAt: result.startedAt
            )
            try await TurnTracePersistLane(standalonePath: ledgerPath).appendChecked(event)
            RepairOwed.settle(ledgerPath.deletingLastPathComponent().deletingLastPathComponent(), operation: "dispatch.ledger",
                              evidence: .init(source: ledgerPath.path, id: id))
        } catch {
            // The call keeps its own outcome; the lost row is owed, not hidden.
            let path = ledgerPath
            let failure = DispatcherError.ledgerFailure(error.localizedDescription)
            RepairOwed.owe(path.deletingLastPathComponent().deletingLastPathComponent(), id: UUID().uuidString, kind: .act, operation: "dispatch.ledger",
                           owner: path.path, words: "\(path.path) did not record \(result.tool)'s \(result.status) row (\(failure.localizedDescription)); the call itself kept its outcome.")
        }
    }
}

/// Compact JSON trace summary, capped by grapheme count before appending the truncation marker.
private func truncateForTrace(_ value: JSONValue, maxChars: Int = 200) -> String {
    let s = (try? value.serialize(pretty: false)) ?? "{}"
    if s.count <= maxChars { return s }
    return String(s.prefix(maxChars)) + "...(truncated)"
}
