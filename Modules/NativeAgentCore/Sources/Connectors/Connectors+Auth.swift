import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Subsystem #26b wave 35 W06 (2026-06-02) — Connector OAuth "clear"
//                (REVOKE) LOCAL state mutation — SwiftNative WRITE port
//
// CLOSES CUTOVER_PLAN.md §6.116 follow-up #7 (the wave-34 W18 reopen). W18 only
// landed the cross-process flock PREREQ on the daemon side (every Python writer
// of `connectors/registry.json` now runs under `with file_lock(self.connectors_path)`
// — §6.97 wave-34 W18); it left the LOCAL state mutation KEPT_NO_NATIVE_IMPL.
// This wave ports the one request-path LOCAL mutation that is actually reachable
// from the co-located Mac app process: `POST /v1/connectors/<provider>/revoke`
// (`Runtime.connector_revoke`, the retired daemon).
//
// WHAT THE DAEMON DOES (connector_revoke):
//   1. self._oauth.revoke_token(provider)  — unlink `<root>/oauth_tokens/<provider>.json`
//      + pop the in-memory `_user_cache[provider]`.
//   2. registry record write-back under `with file_lock(self.connectors_path)`:
//      read via `_list_connectors_locked()`, set the matching record's
//      `enabled=False, authState="not_connected", healthStatus="planned"`,
//      `_atomic_write_text(... json.dumps(indent=2))`.
//   3. return {"ok": True, "provider": provider, "revoked": True}.
//
// WHY THE TOKEN UNLINK IS REACHABLE FROM SWIFT (the W18 blocker (1) re-audited):
// the OAuth token store is `OAuthManager(root)` →
// `app_support_root / "oauth_tokens"` where `app_support_root == root` (the
// daemon DATA root). So the token files live at `<dataRoot>/oauth_tokens/<provider>.json`,
// CO-LOCATED with the Mac app process — NOT under `~/Library/Application Support`
// (the L17429 comment is stale/legacy). The Swift app reads the same data root
// (`PersistenceCore.defaultDataRoot()`), so the unlink is a plain local
// `FileManager.removeItem` on a path this process owns.
//
// WHY THE REGISTRY WRITE IS NOT STALE (the W18 blocker (2) re-audited):
// `_list_connectors_locked`'s defaults-merge
// EXCLUDES `healthStatus`/`authState`/`lastCheckedAt`/`proof`/`proofRequired`/
// `realReady` from the saved-override set (L27497) — those fields ALWAYS come
// from `default_connectors`, which re-derives `enabled/authState/healthStatus`
// from `bool(self._oauth.load_token(provider))` + proofs. So the very next
// daemon `list_connectors()` (which the Mac UI calls on every refresh) IGNORES
// the saved `authState`/`healthStatus` and re-derives them from the (now-DELETED)
// token file → `not_connected`. The native write therefore does NOT need to
// reproduce the readiness derivation: it scopes the write to the registry RECORD
// ONLY (the §6.97 W18 retirement_path option "scope the native write to the
// registry record only and let the daemon's next list_connectors re-derive").
// The one field the merge DOES preserve from the saved override is `enabled`
// (NOT in the exclude set), so writing `enabled=false` is the load-bearing
// registry mutation; `authState`/`healthStatus` are written for cosmetic parity
// with the daemon's own revoke (and for any consumer that reads the raw registry
// before the next merge).
//
// Connector authentication writes remain a distinct trust surface from connector
// reads. NativeClient routes revoke through this canonical Swift owner; local
// token and registry state are updated together.
//
// ── wave 36 W03 (2026-06-02) — the CONNECT-SUCCESS half ─────────────────────
// CLOSES CUTOVER_PLAN.md §6.137 follow-up #3 (the wave-35 W06 reopen): "W06
// connector OAuth save_token not ported — revoke native, save remains daemon.
// That was true for the daemon device-flow era. The current Mac UI drives
// supported connector OAuth (x/gmail/calendar) through NativeOAuthFlow's
// ASWebAuthenticationSession/PKCE path and writes connector auth tokens in
// Swift. This module still owns the local registry mutation helpers.
//
// §6.116 #7's full ask is "port the local-state mutations (token revoke/SAVE,
// registry updates)". Wave-35 W06 ported the CLEAR (revoke) local mutation. The
// later zero-Python cutover moved supported Mac connector OAuth token writes to
// NativeOAuthFlow, so the old daemon device-flow poll tail is no longer the Mac
// app path.
//
// WHAT *IS* PORTABLE — the connect-success REGISTRY mutation. The daemon's
// connect-success tail does, in BOTH sites (the retired daemon
// `handle_authcode_callback` and L20378-20389 the github device-flow poll
// thread), the EXACT MIRROR-IMAGE of the revoke registry write:
//   read `_list_connectors_locked()` under `with file_lock(self.connectors_path)`,
//   for the matching record set `enabled=True, authState="connected",
//   healthStatus="ok"`, `_atomic_write_text(json.dumps(indent=2))`.
// This is a pure LOCAL state mutation — no network, co-located data root, same
// flock W18 wrapped — identical in shape to `revokeConnector`'s already-ported
// registry write (just the opposite field values). Porting it here as
// `connectConnector(provider:)` closes the SYMMETRIC half of §6.116 #7 and gives
// the future full-OAuth-flow port a ready local-mutation seam (the engine ports
// the token exchange; the registry tail is already native — same incremental
// shape as workflows cancel/rollback landing PORTED-DORMANT ahead of the engine).
//
// Current Mac UI flow: ConnectorWizardView and SkillLifecycleView call
// NativeOAuthFlow.startConnectorOAuthFlow(...) directly for supported
// connectors. This actor remains the local revoke/connect registry mutation
// owner used by NativeClient seams and future connector auth callers; it is not
// a daemon fallback.
//
// `_user_cache` / `default_connectors` re-derivation: SAME analysis as revoke —
// `_list_connectors_locked`'s merge (L27506) EXCLUDES authState/healthStatus from
// the saved-override set, so the next `list_connectors()` re-derives both from
// `bool(self._oauth.load_token(provider))` (the now-PRESENT token) → "connected".
// The load-bearing override field is `enabled` (preserved by the merge); the
// `authState="connected"`/`healthStatus="ok"` writes are cosmetic parity for
// raw-registry consumers, exactly as on the revoke side.
//
// ── wave 37 W02 (2026-06-02) — connect-success FAKE-SUCCESS / PARITY FIX ─────
// CLOSES CUTOVER_PLAN.md §6.159 (the §6.158 #2 PREREQ: "W03 connectConnector
// fake-success bug"). The wave-36 W03 port above wrote the connected registry
// triple + returned the "connected successfully" envelope UNCONDITIONALLY — for
// ANY provider string (including unknown ones) and WITHOUT any token behind it.
// That does NOT match the daemon: in BOTH daemon connect-success sites the
// registry write is the STRUCTURAL TAIL of a successful `save_token`, and is
// unreachable for an unknown provider:
//
//   • `handle_authcode_callback`: for an unknown
//     provider it `raise ValueError("handle_authcode_callback: unknown provider")`
//     BEFORE any write; the registry write runs only AFTER
//     `complete_(pkce_)authorization_code_flow` returns — which itself calls
//     `save_token`/persists `oauth_tokens/<provider>.json` (L17761+, L17659+).
//   • the github device-flow poll thread: the
//     registry write is INSIDE `if result["ok"]:` AFTER `self._oauth.save_token(...)`
//     ran and `state["access_token_saved"] = True` (L20407-20415). `start_connector_connect`
//     `raise ValueError("OAuth device flow not yet implemented...")` for any
//     provider outside `{github,email,calendar,notion,slack,x}` (L20364-20371).
//
// So the daemon NEVER writes `connected` (a) for an unknown provider, or (b)
// without a saved token. The unconditional Swift write created two real defects
// when the flag flips: a FAKE-SUCCESS envelope reporting a connect that never
// happened, and a registry HALF-STATE — the daemon's defaults-merge PRESERVES the
// saved `enabled=true` override (NOT in the exclude set) while re-deriving
// `authState`/`healthStatus` from the ABSENT token → `not_connected`. The record
// is left `enabled=true, authState=not_connected` with no token: a connector that
// claims to be enabled but cannot authenticate.
//
// THE FIX (both guards run BEFORE the registry write, mirroring the daemon's
// pre-write `raise`s):
//   1. UNKNOWN-PROVIDER REJECT — validate `provider` against `knownProviders`
//      (`{github,email,calendar,notion,slack,x}`, the daemon's connect-supported
//      set). Unknown → throw `ConnectorAuthError.unknownProvider` (the daemon's
//      `ValueError` parity). No registry mutation, no fake-success.
//   2. SAVE-TOKEN GATE — require `oauth_tokens/<provider>.json` to EXIST (the
//      local proxy for "save_token persisted the access token"; this Swift seam
//      does NOT run the OAuth network exchange, so token-file presence is the
//      observable that `save_token` already succeeded out-of-band). Absent →
//      throw `ConnectorAuthError.tokenNotSaved`. No registry mutation, no
//      fake-success — exactly as the daemon never reaches the write without
//      `save_token`. The future Swift-native OAuth flow persists the token (its
//      own `save_token` port) BEFORE routing its connect-success tail here, so
//      the gate is satisfied on the real path and only rejects the
//      no-token-behind-it fake-connect this fix forbids.
// The registry RMW + return envelope are otherwise unchanged (the connected
// triple write under flock + the handle_authcode_callback body); the
// `try/except: pass` swallow on the RMW stays (daemon parity). The guards THROW
// (they are NOT swallowed) — the daemon's unknown-provider/no-token cases are
// pre-write `raise`s OUTSIDE the `try/except`, so a Swift throw is the faithful
// mirror, and a thrown connect propagates to the seam's caller exactly as the
// daemon's raise would surface as a non-2xx. DEFAULT-OFF / PORTED-DORMANT status
// is unchanged.

// MARK: - Auth-write client protocol

public protocol ConnectorAuthClient: Sendable {
    /// POST /v1/connectors/<provider>/revoke — the OAuth "clear" LOCAL mutation:
    /// unlink `<root>/oauth_tokens/<provider>.json` + write the registry record
    /// to `enabled=false, authState=not_connected, healthStatus=planned`, all
    /// under ONE cross-process flock on `connectors/registry.json` (matching the
    /// daemon's `with file_lock(self.connectors_path)`). The token unlink touches
    /// a DIFFERENT file (`oauth_tokens/<provider>.json`) and — like the daemon
    /// — is NOT
    /// taken under the registry lock. Mirrors connector_revoke's return body.
    func revokeConnector(provider: String) async throws -> JSONValue

    /// The connect-success REGISTRY mutation (wave 36 W03 — §6.137 #3): write the
    /// matching registry record to `enabled=true, authState="connected",
    /// healthStatus="ok"` under the SAME cross-process flock on
    /// `connectors/registry.json` the daemon's connect-success tail holds
    /// (`handle_authcode_callback` L20294 + the github device-flow poll thread
    /// L20380). This is the LOCAL half ONLY: the `save_token` access-token write
    /// is the daemon-internal tail of the OAuth NETWORK exchange and is NOT
    /// reproduced here (see module header — it ports with a future Swift OAuth
    /// flow). Record-only write; the daemon's next `list_connectors()` re-derives
    /// authState/healthStatus from the present token. Returns a body faithful to
    /// `handle_authcode_callback`.
    ///
    /// wave 37 W02 (§6.159): THROWS instead of writing/returning fake-success when
    /// the daemon itself would never reach the connect-success write — an unknown
    /// provider (`ConnectorAuthError.unknownProvider`, the daemon's pre-write
    /// `ValueError` parity) or no saved token at `oauth_tokens/<provider>.json`
    /// (`ConnectorAuthError.tokenNotSaved`, the daemon's `save_token`-precedes-write
    /// structural invariant). See the module header for the full daemon mapping.
    func connectConnector(provider: String) async throws -> JSONValue
}

// MARK: - SwiftNative impl

public final class SwiftNativeConnectorAuthClient: ConnectorAuthClient {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore

    public init(
        root: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) {
        self.root = root
        self.persistence = persistence
    }

    /// Mirror `Daemon.connectors_path`:
    /// <root>/connectors/registry.json.
    private var connectorsPath: URL {
        root.appendingPathComponent("connectors/registry.json")
    }

    /// Mirror `OAuthManager._token_path` with
    /// `app_support_root == root` (L2612): <root>/oauth_tokens/<provider>.json.
    private func tokenPath(_ provider: String) -> URL {
        root.appendingPathComponent("oauth_tokens").appendingPathComponent("\(provider).json")
    }

    private func tokenPaths(_ provider: String) -> [URL] {
        let canonical: String = switch provider.lowercased() {
        case "email", "gmail": "gmail"
        case "calendar", "gcal", "google_calendar": "calendar"
        case "twitter": "x"
        default: provider.lowercased()
        }
        return [
            tokenPath(provider),
            tokenPath(canonical),
            root.appendingPathComponent("connectors", isDirectory: true)
                .appendingPathComponent(canonical, isDirectory: true)
                .appendingPathComponent("auth.json"),
        ]
    }

    private func hasUsableToken(_ provider: String) -> Bool {
        tokenPaths(provider).contains { path in
            guard let data = try? Data(contentsOf: path),
                  case .object(let object) = try? JSONValue.parse(data) else {
                return false
            }
            return ["access_token", "oauth_token", "token"].contains { key in
                guard case .string(let value)? = object[key] else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    /// The providers the daemon's connect path actually supports. Mirrors the
    /// daemon's pre-write provider gates: `start_connector_connect` routes
    /// `{email,calendar,notion,slack,x}` to `start_authcode_connector_connect`
    /// and only `github` to the device flow, and
    /// `handle_authcode_callback` `raise ValueError` for anything outside the
    /// authcode set (L20335). Any provider NOT in this set is one the daemon would
    /// `raise ValueError` on BEFORE writing the registry — so connectConnector
    /// rejects it rather than fabricating a connected record. wave 37 W02 §6.159.
    private static let knownProviders: Set<String> = [
        "github", "email", "gmail", "calendar", "gcal", "google_calendar",
        "notion", "slack", "x", "twitter",
    ]

    public func revokeConnector(provider: String) async throws -> JSONValue {
        // Step 1 — token unlink (OAuthManager.revoke_token, the file half).
        // Daemon: `if path.exists(): path.unlink()`. Unconditional-safe: a
        // missing token file is a no-op (matches `path.exists()` guard). This is
        // OUTSIDE the registry flock exactly as the daemon's `revoke_token` runs
        // BEFORE acquiring `file_lock(self.connectors_path)` and touches a
        // different file. The in-memory `_user_cache` pop has no Swift analogue
        // (documented KNOWN RESIDUAL — benign-stale).
        // The daemon's `revoke_token` does `if path.exists(): path.unlink()` and
        // does NOT swallow an unlink error (only the registry write is in
        // `try/except: pass`). We match that: a missing token is a no-op; a real
        // unlink failure THROWS (propagates to the UI's `try?` revoke call, which
        // swallows it exactly as it swallows an HTTP failure today — no
        // fake-success and no half-state where the registry says not_connected
        // while a live token remains).
        for tok in Set(tokenPaths(provider)) where
            FileManager.default.fileExists(atPath: tok.path) {
            try FileManager.default.removeItem(at: tok)
        }

        // Step 2 — registry record write-back under ONE cross-process flock
        // acquisition on connectors/registry.json (matches the daemon's
        // `with file_lock(self.connectors_path)`). RECORD-ONLY write: read the
        // SAVED registry, update the matching record's three fields, write back.
        // We do NOT re-derive defaults (the daemon's next `list_connectors()`
        // re-merges + re-derives `authState`/`healthStatus` from the now-deleted
        // token — see module header). The daemon's revoke wraps the SAME flock;
        // its inner `_list_connectors_locked` re-sorts via write_json(sort_keys),
        // and our `writeJSON` is also sort_keys-equivalent, so concurrent
        // interleaving cannot corrupt the file and the canonical sorted form is
        // preserved.
        //
        // FAILURE PARITY (gpt-5.5 review #1): the daemon wraps the ENTIRE
        // registry update in `try/except: pass` — a
        // lock/read/write failure HERE is swallowed and the method STILL returns
        // `{ok, provider, revoked}` (the token is already gone — the revoke
        // succeeded from the caller's view; the not_connected record is re-derived
        // by the next `list_connectors()` from the absent token regardless). We
        // mirror that: swallow any error from the locked RMW so a transient lock
        // contention / disk error does NOT turn a successful token-unlink into a
        // thrown revoke. The token unlink above is NOT wrapped (matches the
        // daemon, whose `revoke_token` unlink is outside the try/except).
        do {
            try await persistence.withFileLock(connectorsPath) { [persistence, connectorsPath] in
                let raw = await persistence.readJSON(connectorsPath, defaultValue: .array([]))
                var connectors: [JSONValue]
                if case .array(let arr) = raw { connectors = arr } else { connectors = [] }
                for (idx, entry) in connectors.enumerated() {
                    guard case .object(var obj) = entry else { continue }
                    // Daemon: `if str(c.get("id")) == provider`.
                    if Self.providerID(Self.idString(obj["id"]))
                        == Self.providerID(provider) {
                        obj["enabled"] = .bool(false)
                        obj["authState"] = .string("not_connected")
                        obj["healthStatus"] = .string("planned")
                        connectors[idx] = .object(obj)
                    }
                }
                try await persistence.writeJSON(.array(connectors), to: connectorsPath)
            }
        } catch {
            // Daemon `try/except: pass` parity — see above. The revoke still
            // succeeded (token unlinked); the registry record self-heals on the
            // next daemon read.
        }

        // Step 3 — return body byte-faithful to connector_revoke
        //: {"ok": True, "provider": provider, "revoked": True}.
        return .object([
            "ok": .bool(true),
            "provider": .string(provider),
            "revoked": .bool(true),
        ])
    }

    public func connectConnector(provider: String) async throws -> JSONValue {
        // The connect-success REGISTRY record write-back — the LOCAL half of the
        // daemon's connect tail (see module header). NO token write here: the
        // `save_token` access-token persist is the daemon-internal tail of the
        // OAuth NETWORK exchange (device-flow poll thread / handle_authcode_callback
        // after the external token endpoint returns). This method ports ONLY the
        // record-only registry mutation, the exact MIRROR-IMAGE of revoke's
        // registry write (enabled/authState/healthStatus flipped to the connected
        // values), under the SAME cross-process flock on connectors/registry.json
        // that the daemon's connect-success tail holds
        // (`with file_lock(self.connectors_path)`, the retired daemon/L20380).
        //
        // wave 37 W02 §6.159 — GUARD 1: UNKNOWN-PROVIDER REJECT. The daemon's
        // connect path `raise ValueError` for any provider outside
        // `{github,email,calendar,notion,slack,x}` BEFORE any registry write
        // (start_connector_connect L20364, handle_authcode_callback L20335). Mirror
        // that pre-write raise so an unknown provider never fabricates a connected
        // record / fake-success envelope. THROWS (not swallowed): the daemon's
        // raise is outside its `try/except: pass`.
        guard Self.knownProviders.contains(provider) else {
            throw ConnectorAuthError.unknownProvider(provider)
        }

        // wave 37 W02 §6.159 — GUARD 2: SAVE-TOKEN GATE. In BOTH daemon sites the
        // connect-success registry write is the STRUCTURAL TAIL of a successful
        // `save_token` (handle_authcode_callback only writes after
        // complete_(pkce_)authorization_code_flow persisted the token; the github
        // poll thread writes inside `if result["ok"]:` after `save_token(...)` +
        // `access_token_saved=True`). This seam does NOT run the OAuth network
        // exchange, so the presence of `oauth_tokens/<provider>.json` is the local
        // observable that `save_token` already succeeded out-of-band. Absent token
        // → THROW (the daemon never reaches the write without a saved token); no
        // registry mutation, no fake-success. The future Swift-native OAuth flow
        // persists the token via its own save_token port BEFORE routing its
        // connect-success tail here, so the real path satisfies this gate.
        guard hasUsableToken(provider) else {
            throw ConnectorAuthError.tokenNotSaved(provider)
        }

        // FAILURE PARITY: the daemon wraps BOTH connect-success registry writes in
        // `try/except: pass` and
        // the connect path STILL reports success (the token is already saved; the
        // next `list_connectors()` re-derives "connected" from the present token
        // regardless of whether the override write landed). We mirror that: swallow
        // any error from the locked RMW so a transient lock contention / disk error
        // does NOT turn a successful connect into a thrown call. (Symmetric to
        // revokeConnector's swallow.)
        do {
            try await persistence.withFileLock(connectorsPath) { [persistence, connectorsPath] in
                let raw = await persistence.readJSON(connectorsPath, defaultValue: .array([]))
                var connectors: [JSONValue]
                if case .array(let arr) = raw { connectors = arr } else { connectors = [] }
                for (idx, entry) in connectors.enumerated() {
                    guard case .object(var obj) = entry else { continue }
                    // Daemon: `if str(c.get("id")) == provider`.
                    if Self.providerID(Self.idString(obj["id"]))
                        == Self.providerID(provider) {
                        obj["enabled"] = .bool(true)
                        obj["authState"] = .string("connected")
                        obj["healthStatus"] = .string("ok")
                        connectors[idx] = .object(obj)
                    }
                }
                try await persistence.writeJSON(.array(connectors), to: connectorsPath)
            }
        } catch {
            // Daemon `try/except: pass` parity — the connect still succeeded
            // (token saved by the daemon's network tail); the registry record
            // self-heals on the next daemon read.
        }

        // Return body faithful to handle_authcode_callback (the retired daemon
        // L20305): {"provider": provider, "authorized": True,
        // "message": "<provider> connected successfully."}. The github device-flow
        // poll thread has no synchronous return (it only sets in-thread state), so
        // the authcode-callback success body is the one request-path return that
        // follows a connect-success registry write — we mirror it.
        return .object([
            "provider": .string(provider),
            "authorized": .bool(true),
            "message": .string("\(provider) connected successfully."),
        ])
    }

    /// Mirror Python `str(c.get("id"))`: the daemon compares the registry record
    /// id stringified. We mirror only the cases the registry actually stores
    /// (string ids); a non-string/absent id stringifies to a value that never
    /// equals a real provider token, so it is correctly skipped.
    private static func idString(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "True" : "False"
        case .null: return "None"
        default: return ""
        }
    }

    private static func providerID(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "email", "gmail": "gmail"
        case "calendar", "gcal", "google_calendar": "calendar"
        case "twitter": "x"
        default: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

public enum ConnectorAuthError: Error, Sendable, Equatable {
    /// Connector auth was explicitly disabled by policy.
    case flagDisabled
    /// wave 37 W02 §6.159 — `connectConnector` was called with a provider the
    /// daemon's connect path does not support (outside
    /// `{github,email,calendar,notion,slack,x}`). The daemon `raise ValueError`
    /// for the same case before any registry write; we mirror that rather than
    /// fabricating a connected record.
    case unknownProvider(String)
    /// wave 37 W02 §6.159 — `connectConnector` was called with no saved token at
    /// `oauth_tokens/<provider>.json`. The daemon's connect-success registry
    /// write is the structural tail of a successful `save_token`, so a connect
    /// with no token behind it is a fake-success the daemon never produces.
    case tokenNotSaved(String)
}

// MARK: - Factory

/// Returns the SwiftNative connector-auth WRITE client. `root` is the data root
/// (the dir that contains `connectors/` and `oauth_tokens/`); injectable for
/// tests.
public func makeConnectorAuthClient(
    root: URL
) -> any ConnectorAuthClient {
    return SwiftNativeConnectorAuthClient(root: root)
}
