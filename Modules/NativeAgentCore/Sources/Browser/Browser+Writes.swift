// SwiftNative WRITE port for the browser-orchestration surface (Subsystem #27 —
// wave 34 W17). Companion to Browser.swift (the wave-33 STATUS read port).
//
// SCOPE OF THIS PORT (audit-first, method-level):
//
//   POST /v1/browser/cancel  (cancel_browser_run)        -> PORTED (full)
//   POST /v1/browser/run     (run_browser_action)        -> PORTED (dry-run-only path)
//
// `cancel_browser_run` is a self-contained flock'd read-find-mutate-write of
// native_power/browser/runs.json + one receipts.jsonl append. Zero external
// deps. Fully ported, byte-for-byte.
//
// `run_browser_action` has TWO behaviours split by dependency boundary:
//   (a) the DRY-RUN / no-fetch / no-IPC / no-screenshot path — build a `run`
//       dict (status="dry_run"), flock'd runs.json R-M-W, two receipt appends,
//       record_trace, return. This is the ONLY path any real caller invokes:
//         • Mac UI runBrowser(...) posts {dryRun:true, readOnly:true, captureSource:false}
//         • smoke_all.sh / test.sh post {dryRun:true, readOnly:true}
//           (and `dry_run and read_only` forces capture_source=False anyway).
//       PORTED through the canonical Browser operation store.
//   (b) the EXECUTE path — non-dry-run visible navigation. Pulls in
//       create_approval_request + _pending_actions + PendingApprovalError (the
//       202 approval lifecycle), fetch_url (HTTP + HTML TextExtractor),
//       self._browser_client (the WKWebView IPC bridge on port 8766:
//       navigate/screenshot), and base64 screenshot capture. The app target now
//       owns approval-gated visible navigation through BrowserWindowController
//       because WebKit/AppKit are not Core dependencies. Core still owns the
//       running/terminal/cancel/deadline/recovery lifecycle; this legacy writer
//       returns nil so the app can perform only the effect through that command
//       boundary.
//
// PARITY NOTES (verified against the retired daemon primary source, NOT assumed):
//   • runs.json write: daemon write_json = json.dumps(indent=2, sort_keys=True)
//     + chmod 0o600. Swift writeJSON = serializedData(pretty:true) (indent=2 +
//     sort_keys via UTF-8-byte key sort) + atomicWrite + chmod 0o600. Match.
//   • receipts.jsonl appends: THIS daemon's append_jsonl = json.dumps(sort_keys
//     =True) + chmod 0o600 (verified at the retired daemon — NOT the unsorted
//     mac_control_audit path). Swift appendJSONL = serialize(pretty:false)
//     (sort_keys) + chmod 0o600. Match. (So we use plain appendJSONL here, NOT
//     appendAuditLineRaw — that variant is for the daemon's UNSORTED writers.)
//   • runs cap: write_json(self.browser_runs_path, runs[-200:]) on the RUN path;
//     cancel writes the WHOLE list back (no slice). Mirrored exactly.
//   • record_trace: kind="browser.action", title=domain, payload={url,status,
//     dryRun}. Envelope {id,kind,title,status,payload,createdAt} where status =
//     str(payload.get("status") or "ok"). Flock'd on traces/events.jsonl (Wave 33
//     W01 made traces/events.jsonl a co-written file; we take the same advisory
//     lock the daemon and the other Swift trace emitters take).
//   • now_iso() shape mirrors Browser.swift's nowISO (microseconds + +00:00).
//   • FLOCK: the whole runs.json R-M-W runs inside withFileLock(runsPath) — the
//     cross-process advisory lock the daemon's run/cancel R-M-W also takes
//     (wave 33 W17). Receipt + trace appends are OUTSIDE that lock (different
//     files; O_APPEND-atomic), matching the daemon's lock-only-the-R-M-W shape.

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Write protocol

public protocol BrowserWriter: Sendable {
    /// POST /v1/browser/run. Returns the run envelope, or `nil` when the app
    /// target must handle the body (non-dry-run / fetch / screenshot) before any
    /// side effect. THROWS if a
    /// native write/append/trace fails AFTER the runs.json mutation has begun —
    /// the caller must NOT replay it through another transport (that would
    /// double-write the run). Mirrors the sibling write ports.
    func runBrowserAction(body: JSONValue) async throws -> JSONValue?
    /// POST /v1/browser/cancel. Returns the cancel result envelope (handled
    /// natively when the flag is ON — pure runs.json R-M-W), or `nil` only when
    /// the body shape is not an object (pre-side-effect decline). THROWS on any
    /// IO failure (the daemon must NOT re-run a cancel that already persisted).
    func cancelBrowserRun(body: JSONValue) async throws -> JSONValue?
}

// MARK: - SwiftNative write impl

extension SwiftNativeBrowserClient: BrowserWriter {

    /// Port of `NativeAgentRuntime.run_browser_action`
    /// — DRY-RUN path only. Returns nil for any body that would reach the
    /// execute/approval/fetch/screenshot machinery, decided BEFORE any side
    /// effect. THROWS once the runs.json write begins so callers cannot replay
    /// the request and duplicate a partial native write.
    public func runBrowserAction(body: JSONValue) async throws -> JSONValue? {
        guard case .object(let b) = body else { return nil }

        // url = str(body.get("url") or payload.get("url") or "").strip()
        // (Python `or` chain → first TRUTHY term; see pyOr — `??` would be wrong.)
        let payload: [String: JSONValue]
        if case .object(let p)? = b["input"] { payload = p } else { payload = [:] }
        let url = (Self.pyOr(b["url"], payload["url"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return nil }  // caller owns the exact error shape.

        // urlparse + scheme/host validation. Decline malformed bodies before
        // side effects so the app caller owns the exact error shape.
        guard let comps = URLComponents(string: url),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else {
            return nil
        }
        // domain = (parsed.hostname or "").lower()
        // (host is already lowercased by .lower() below; URLComponents.host is
        // case-preserving so lowercase explicitly.)
        _ = host.lowercased()  // domain — not needed on the dry-run path beyond presence.

        // dry_run = bool(body.get("dryRun", body.get("dry_run", True)))
        let dryRun = Self.pyBool(b["dryRun"] ?? b["dry_run"], default: true)
        // EXECUTE path is app-target owned. Anything non-dry-run is declined
        // before side effects so NativeClient can use the WKWebView executor.
        if !dryRun { return nil }

        let visible = Self.pyBool(b["visible"], default: true)
        var captureSource = Self.pyBool(b["captureSource"] ?? b["capture_source"], default: true)
        var captureScreenshot = Self.pyBool(b["captureScreenshot"] ?? b["capture_screenshot"], default: false)
        // if dry_run and read_only: capture_source = False; capture_screenshot = False
        let readOnly = Self.pyBool(b["readOnly"] ?? b["read_only"], default: false)
        if dryRun && readOnly {
            captureSource = false
            captureScreenshot = false
        }
        // The dry-run path only avoids fetch_url / IPC / screenshot when BOTH
        // captures are off. If a caller asks a DRY-RUN to capture source
        // (fetch_url) or a screenshot, that pulls in fetch_url / IPC which are
        // not owned by this Core writer; decline before side effects.
        if captureSource || captureScreenshot { return nil }

        let start = BrowserOperationStart(
            id: UUID().uuidString,
            url: url,
            domain: host.lowercased(),
            initialState: .dryRun,
            visible: visible
        )
        return try await executeBrowserOperation(.start(start)).run
    }

    /// Port of `NativeAgentRuntime.cancel_browser_run`.
    /// Pure flock'd runs.json read-find-mutate-write + one receipt append.
    /// THROWS on any IO failure: a cancel that has already persisted to runs.json
    /// must NOT fall back to an HTTP re-POST (the daemon would re-scan and could
    /// flip a DIFFERENT run, or no-op into not_found, diverging from the real
    /// result). The receipt append also propagates — Python's append_jsonl does
    /// not swallow write failures.
    public func cancelBrowserRun(body: JSONValue) async throws -> JSONValue? {
        guard case .object(let b) = body else { return nil }
        // run_id = str(body.get("id") or body.get("runId") or "")
        // (Python `or` chain → first TRUTHY term; `??` would keep an explicit
        //  empty-string `id` instead of falling through to `runId`.)
        let runID = Self.pyOr(b["id"], b["runId"]) ?? ""

        return try await executeBrowserOperation(
            .cancel(id: runID.isEmpty ? nil : runID)
        ).run
    }

    // MARK: - Python-coercion helpers

    /// Python `str(x)`-equivalent extraction used for url/id reads:
    /// returns the string for a JSON string/number/bool, nil for null/missing/
    /// container (so `.get(...) or fallback` semantics hold — a None/missing
    /// value is falsy and falls through to the next `or`).
    static func pyStr(_ v: JSONValue?) -> String? {
        switch v {
        case .some(.string(let s)): return s
        case .some(.int(let n)): return String(n)
        case .some(.double(let d)): return String(d)
        case .some(.bool(let b)): return b ? "True" : "False"
        case .some(.null), .none, .some(.object), .some(.array): return nil
        }
    }

    /// Python `a or b or ...` over JSON values, stringified.
    ///
    /// R-W17 (gpt-5.5 review wave 34): `pyStr(x) ?? pyStr(y)` is WRONG for the
    /// `body.get("url") or payload.get("url")` / `body.get("id") or body.get("runId")`
    /// chains — `??` only falls through on `nil`, but Python's `or` falls through
    /// on any FALSY value. An explicit empty string (`""`), `0`, `0.0`, `False`,
    /// `[]`, `{}` are all falsy in Python and must fall through to the next term.
    /// e.g. `{"url": "", "input": {"url": "https://x"}}` → Python picks
    /// `"https://x"`; `pyStr ?? pyStr` would wrongly pick `""`. This helper walks
    /// the terms in order and returns the first PYTHON-TRUTHY value rendered via
    /// `str(...)`, or nil if every term is falsy/missing (→ the trailing `or ""`).
    static func pyOr(_ terms: JSONValue?...) -> String? {
        for t in terms {
            switch t {
            case .none, .some(.null):
                continue
            case .some(.bool(let b)):
                if b { return "True" }       // True is truthy; False falls through
            case .some(.int(let n)):
                if n != 0 { return String(n) }
            case .some(.double(let d)):
                if d != 0 { return String(d) }
            case .some(.string(let s)):
                if !s.isEmpty { return s }    // "" is falsy → fall through
            case .some(.array(let a)):
                // A non-empty list is TRUTHY in Python, so it does NOT fall
                // through — Python would `str([...])` it. A url/id is never a
                // list in practice; emit a non-empty sentinel so we neither
                // wrongly fall through nor silently return nil from a truthy
                // term. (Downstream urlparse/empty checks reject it cleanly.)
                if !a.isEmpty { return "[list]" }
            case .some(.object(let o)):
                if !o.isEmpty { return "{dict}" } // ditto — truthy, no fall-through
            }
        }
        return nil
    }

    /// Python `bool(body.get(k, default))` — only the explicit JSON booleans and
    /// the documented falsy scalars matter for these flags (callers send real
    /// booleans). A missing key uses `default`; an explicit `false`/0/""/null is
    /// falsy; everything else truthy, matching retired truthiness for the values
    /// these flags ever hold.
    static func pyBool(_ v: JSONValue?, default def: Bool) -> Bool {
        switch v {
        case .none: return def
        case .some(.bool(let b)): return b
        case .some(.null): return false
        case .some(.int(let n)): return n != 0
        case .some(.double(let d)): return d != 0
        case .some(.string(let s)): return !s.isEmpty
        case .some(.object(let o)): return !o.isEmpty
        case .some(.array(let a)): return !a.isEmpty
        }
    }
}

// MARK: - Path + persistence accessors

extension SwiftNativeBrowserClient {
    /// Absolute path to `<dataRoot>/native_power/actions/receipts.jsonl`
    /// (the retired daemon — the cross-action native-actions receipt log the
    /// browser run also appends to).
    public var nativeActionsReceiptsPath: URL {
        runsPath
            .deletingLastPathComponent()          // .../native_power/browser
            .deletingLastPathComponent()          // .../native_power
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
    }

    /// Absolute path to `<dataRoot>/traces/events.jsonl`.
    public var tracesPath: URL {
        // runsPath = <root>/native_power/browser/runs.json → climb 3 to <root>.
        runsPath
            .deletingLastPathComponent()          // .../native_power/browser
            .deletingLastPathComponent()          // .../native_power
            .deletingLastPathComponent()          // <root>
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    /// The injected persistence core (Browser.swift's `persistence` is now
    /// `internal`, so we read it directly under a clearer alias here).
    var persistenceCore: any PersistenceCoreProtocol { persistence }
}
