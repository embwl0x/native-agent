import Testing
import Foundation
@testable import Dispatcher
import NativeAgentCore
import PersistenceCore

// ============================================================================
// Coverage-ledger evals — fence core.toolexec (docs/evals/ledger.json).
//
// Row closed here:
//   • dispatcher.decodeDispatchResult
//
// SILENT DECAY: `decodeDispatchResult` has ZERO callers anywhere — it
// hand-decodes a snake_case receipt shape that no live producer emits. It can
// drift arbitrarily from DispatchResult with nothing detecting it, and the next
// person who needs a decoder will trust it.
//
// The envelope asserted here is FIELD PARITY, not a handful of literals: every
// stored property of DispatchResult is round-tripped, and the property COUNT is
// pinned, so adding a 17th field to DispatchResult fails this test until the
// decoder handles it.
// ============================================================================

/// The full snake_case receipt shape, with a distinct non-default value in
/// every field so a dropped field cannot pass by coincidence.
private let fullReceiptJSON = """
{
  "ok": true,
  "tool": "workspace.list",
  "status": "ok",
  "executed": true,
  "verify_passed": true,
  "duration_us": 12345,
  "duration_ms": 12,
  "args_hash": "abc123",
  "effective_autonomy": "auto",
  "autonomy_source": "trust_policy",
  "provider_match": false,
  "trace_event_id": "evt-9",
  "run_id": "run-9",
  "started_at": "2026-08-23T00:00:00Z",
  "output": {"files": ["a.txt"]},
  "error": null
}
"""

@Test func evalDispatcherDecodeResult_roundTripsEveryFieldOfTheDeclaredShape() throws {
    let decoded = try decodeDispatchResult(from: Data(fullReceiptJSON.utf8))

    #expect(decoded.ok)
    #expect(decoded.tool == "workspace.list")
    #expect(decoded.status == "ok")
    #expect(decoded.executed)
    #expect(decoded.verifyPassed == true)
    #expect(decoded.durationUs == 12345)
    #expect(decoded.durationMs == 12)
    #expect(decoded.argsHash == "abc123")
    #expect(decoded.effectiveAutonomy == "auto")
    #expect(decoded.autonomySource == "trust_policy")
    #expect(decoded.providerMatch == false, "provider_match must be read, not defaulted to true")
    #expect(decoded.traceEventId == "evt-9")
    #expect(decoded.runId == "run-9")
    #expect(decoded.startedAt == "2026-08-23T00:00:00Z")
    #expect(decoded.error == nil, "an explicit null error must decode to nil, not to an empty DispatchError")
    guard case .object(let output)? = decoded.output?.value,
          case .array(let files)? = output["files"] else {
        Issue.record("output payload did not survive the decode")
        return
    }
    #expect(files == [.string("a.txt")])

    // FIELD PARITY: the decoder must cover every stored property. A new field
    // on DispatchResult that the decoder ignores fails HERE rather than
    // silently arriving as a zero value at a future call site.
    let mirrored = Mirror(reflecting: decoded).children.compactMap(\.label)
    #expect(
        Set(mirrored) == [
            "ok", "tool", "status", "output", "error", "executed", "verifyPassed",
            "durationUs", "durationMs", "argsHash", "effectiveAutonomy",
            "autonomySource", "providerMatch", "traceEventId", "runId", "startedAt",
        ],
        "DispatchResult's field set changed to \(mirrored.sorted()) — decodeDispatchResult must be extended (or retired) to match."
    )
    #expect(mirrored.count == 16)
}

@Test func evalDispatcherDecodeResult_requiredFieldsFailLoud_optionalsCarryDocumentedDefaults() throws {
    // REQUIRED: tool + status. A receipt missing either is a decode FAILURE,
    // never a silently-empty result.
    for missing in ["tool", "status"] {
        var obj = try JSONSerialization.jsonObject(
            with: Data(fullReceiptJSON.utf8)
        ) as? [String: Any] ?? [:]
        obj.removeValue(forKey: missing)
        let data = try JSONSerialization.data(withJSONObject: obj)
        do {
            _ = try decodeDispatchResult(from: data)
            Issue.record("a receipt with no '\(missing)' must fail to decode")
        } catch DispatcherError.decodeFailure(let detail) {
            #expect(detail.contains(missing), "the failure must NAME the missing field; got \(detail)")
        } catch {
            Issue.record("wrong error for missing \(missing): \(error)")
        }
    }

    // Not-JSON and non-object roots are named failures too.
    for bad in ["not json at all", "[]", "\"a string\"", "42"] {
        do {
            _ = try decodeDispatchResult(from: Data(bad.utf8))
            Issue.record("'\(bad)' must not decode as a dispatch receipt")
        } catch DispatcherError.decodeFailure {
            // ok
        } catch {
            Issue.record("wrong error for \(bad): \(error)")
        }
    }

    // MINIMAL receipt — the documented defaults, pinned. `provider_match`
    // defaults to TRUE (absence is not a mismatch) while `ok`/`executed`
    // default to FALSE; that asymmetry is deliberate and easy to invert.
    let minimal = try decodeDispatchResult(from: Data("{\"tool\":\"t\",\"status\":\"failed\"}".utf8))
    #expect(minimal.ok == false)
    #expect(minimal.executed == false)
    #expect(minimal.providerMatch == true, "an ABSENT provider_match must default to true, not false")
    #expect(minimal.verifyPassed == nil, "absent verify_passed is nil — tri-state, not false")
    #expect(minimal.durationUs == 0)
    #expect(minimal.argsHash == "")
    #expect(minimal.output == nil)
    #expect(minimal.error == nil)

    // duration_us accepts an int OR a double (the retired producer emitted both).
    let asDouble = try decodeDispatchResult(
        from: Data("{\"tool\":\"t\",\"status\":\"ok\",\"duration_us\":1500.9}".utf8)
    )
    #expect(asDouble.durationUs == 1500)

    // ERROR OBJECT: every field of the nested error shape is decoded.
    let withError = try decodeDispatchResult(from: Data("""
    {"tool":"t","status":"blocked","error":{"code":"denied","message":"no",
     "tool":"t","args_hash":"h","recoverable":true}}
    """.utf8))
    #expect(withError.error?.code == "denied")
    #expect(withError.error?.message == "no")
    #expect(withError.error?.tool == "t")
    #expect(withError.error?.argsHash == "h")
    #expect(withError.error?.recoverable == true)

    // A non-object `error` must not fabricate a DispatchError.
    let junkError = try decodeDispatchResult(
        from: Data("{\"tool\":\"t\",\"status\":\"ok\",\"error\":\"boom\"}".utf8)
    )
    #expect(junkError.error == nil)
}

@Test func evalDispatcherDecodeResult_hasNoProducerInTheTree() throws {
    // The row's real finding: this decoder is UNREACHABLE. Nothing calls it and
    // nothing emits `_receipt_to_response_dict`'s shape any more. Asserted so a
    // future caller — or the symbol's retirement — is a deliberate test change
    // rather than a quiet resurrection of an untested path.
    guard let repoRoot = dispatcherEvalRepositoryRoot() else {
        Issue.record("could not locate the repository root from #filePath")
        return
    }
    var callSites: [String] = []
    var filesScanned = 0
    for name in ["Sources", "Modules", "iOS", "tests"] {
        let base = repoRoot.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path),
              let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            filesScanned += 1
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                guard line.contains("decodeDispatchResult") else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if trimmed.contains("public func decodeDispatchResult") { continue }
                // This eval file is itself the only intentional caller.
                if url.lastPathComponent == "DispatchResultDecoderEvalsTests.swift" { continue }
                callSites.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
    }
    #expect(filesScanned > 100, "the source scan walked only \(filesScanned) files — it is not reaching the tree")
    #expect(
        callSites.isEmpty,
        "decodeDispatchResult gained a caller: \(callSites). It is no longer decay-only — flip the ledger row and pin the PRODUCER's bytes, not a hand-written fixture."
    )
}

/// Walks up from this source file to the repository root.
func dispatcherEvalRepositoryRoot() -> URL? {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        let manifest = directory.appendingPathComponent("Package.swift")
        let modules = directory.appendingPathComponent("Modules", isDirectory: true)
        if FileManager.default.fileExists(atPath: manifest.path),
           FileManager.default.fileExists(atPath: modules.path) {
            return directory
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { return nil }
        directory = parent
    }
    return nil
}
