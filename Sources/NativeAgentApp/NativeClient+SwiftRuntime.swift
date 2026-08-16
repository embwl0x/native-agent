import Foundation
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser

// FIX: per-element wrapper used by NativeClient.getList for lossy array decode.
// Captures the decode result of a single array element so a malformed element
// is dropped (and logged) instead of throwing the whole array.
struct LossyElement<T: Decodable>: Decodable {
    let result: Result<T, Error>

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            result = .success(try container.decode(T.self))
        } catch {
            result = .failure(error)
        }
    }
}

extension NativeClient {
    // W-H ToolDispatch-band lift (move-only): fileprivate->internal.
    func _swiftDispatch(
        tool: String,
        input: [String: Any],
        sessionId: String?
    ) async throws -> DispatchResult {
        let raw = try JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed])
        let parsed = try JSONValue.parse(raw)
        guard case .object(let obj) = parsed else {
            var body: [String: Any] = [
                "tool": tool, "input": input, "surface": "chat", "dry_run": false,
            ]
            if let sid = sessionId { body["session_id"] = sid }
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            return try await _dispatchMissingNativeHandler(bodyData: bodyData)
        }
        // Build the Swift-native dispatcher registry. Unknown tools fail closed
        // inside SwiftNativeDispatcher with `native_handler_missing`; there is no
        // daemon or HTTP fallback.
        var flipHandlers: [String: ConnectorActionHandler] = [:]
        var flipSideEffecting: Set<String> = []
        var flipTrivialVerify: Set<String> = []
        // The action flips (persona_read, workspace_list, time_now,
        // persona_list_skills, read_file, file_excerpt, system_info) were once
        // each gated behind their own rollout flag. All seven shipped ON and the
        // flags were retired, so the registries now merge unconditionally. The
        // merge is a union: every registry is disjoint from the others, so
        // ordering is immaterial and nothing clobbers. `system_info` consumes no
        // file_access sandbox state (no path input, no allowedRoots check),
        // unlike the read_file / file_excerpt flips.
        func mergeFlipRegistry(_ reg: LocalConnectorActions) {
            for name in reg.toolNames {
                flipHandlers[name] = { input, ctx in reg.run(name, input: input, ctx: ctx) ?? .null }
                if reg.isSideEffecting(name) { flipSideEffecting.insert(name) }
                if reg.isTrivialVerify(name) { flipTrivialVerify.insert(name) }
            }
        }
        mergeFlipRegistry(LocalConnectorActions.personaReadOnly)
        mergeFlipRegistry(LocalConnectorActions.workspaceListReadOnly)
        mergeFlipRegistry(LocalConnectorActions.timeNowReadOnly)
        mergeFlipRegistry(LocalConnectorActions.personaListSkillsReadOnly)
        mergeFlipRegistry(LocalConnectorActions.readFileReadOnly)
        mergeFlipRegistry(LocalConnectorActions.fileExcerptReadOnly)
        mergeFlipRegistry(LocalConnectorActions.systemInfoReadOnly)
        let localActions: LocalConnectorActions? = flipHandlers.isEmpty
            ? nil
            : LocalConnectorActions(
                handlers: flipHandlers,
                sideEffecting: flipSideEffecting,
                trivialVerify: flipTrivialVerify)
        let dispatcher = makeDispatcher(localActions: localActions)
        // WAVE 41 W02 (§6.220-rd2 #2) — SECURITY WIRING fix for the read_file /
        // file_excerpt flips. The prior `DispatchContext.defaultForSurface("chat")`
        // shipped an EMPTY `repoRoot` and EMPTY `extra`, so when either flip was ON
        // `FileSystemActions.allowedRoots(ctx)` returned `[]` and the sandbox guard
        // (`!allowed.isEmpty && !isWithinRoots(...)` in FileSystemActions.readFile /
        // .fileExcerpt) was BYPASSED — an absolute path like `/etc/passwd` resolved,
        // skipped the empty-allowed-roots check, fell outside the data root so the
        // sensitive-path block didn't fire, and was READ. The seam was thus a
        // sandbox-escape the instant either flag flipped ON.
        //
        // The sandbox-engaging context uses a validated repo root and a READ-ONLY
        // `file_access` envelope so read tools never run against an empty or
        // overbroad allowed-root set.
        //
        // WAVE 42 W01 (§6.260) — REOPEN of §6.240-rd2 #1. The §6.220-rd2 #2 fix
        // computed the sandbox need as FLAG-SET-scoped (ON if EITHER file flag was
        // ON) and applied the resulting `ctx` to WHATEVER `tool` this call
        // dispatched. So a `persona_read` / `workspace_list` / `time_now` /
        // `persona_list_skills` / `system_info` dispatch got the sandbox-engaging
        // context whenever a file flag was ON — flipping the non-file actions'
        // persona root from `defaultPersonaRoot()` (`<repo>/persona`) to the
        // `<dataRoot>/memory` legacy fallback (they derive persona root from
        // `_na_data_root` only in test mode), a behavior change. Now ACTION-NAME-
        // scoped via `DispatchContext.fileSandboxContextForTool`: ONLY a `read_file`
        // / `file_excerpt` dispatch whose own flag is ON engages the sandbox
        // context; every other action keeps the normal chat context.
        // Swift-native cutover: removed a stale `let ctx = DispatchContext.fileSandboxContextForTool(...)`
        // block here — it predated the wave-42 W02 tightened-sandbox path below and
        // was left in by a partial merge, producing `invalid redeclaration of 'ctx'`.
        // The gated path below is the canonical one.
        // Scope: built ONLY for the file-system flips. The already-LIVE persona_read /
        // workspace_list / time_now / persona_list_skills flips resolve their own
        // roots (persona/workspace) independently of `repoRoot`/`file_access` and
        // derive persona root from `_na_data_root` ONLY in test mode — so threading a
        // prod `_na_data_root` here would flip their persona root from
        // `defaultPersonaRoot()` (stamped `<repo>/persona`) to the `<dataRoot>/memory`
        // legacy fallback, a behavior change. Those flips keep `defaultForSurface`;
        // ONLY read_file/file_excerpt get the sandbox-engaging context.
        let needsFileSandbox = (tool == "read_file")
            || (tool == "file_excerpt")
        let ctx: DispatchContext
        if needsFileSandbox {
            let dataRoot = PersistenceCore.defaultDataRoot()
            // WAVE 42 W02 (§6.260 — closes §6.240 round-2 reopen #2) — TIGHTEN the
            // sandbox repo root. The prior code used `dataRoot.deletingLastPath-
            // Component()` (the data root's PARENT) directly. That is correct ONLY
            // when the data root is `<repo>/data` (dev walkup / stamped-bundle
            // install — both have a VALIDATED repo as the parent). But
            // `defaultDataRoot`'s step-4 fallback returns `~/Library/Application
            // Support/NativeAgent` BARE (no `/data` suffix), whose parent is
            // `~/Library/Application Support` — the ENTIRE Application Support tree.
            // With the read sandbox engaged that parent became the sole allowed
            // root, so a read of any path under another app's Application Support
            // dir resolved INSIDE the sandbox (gpt-5.5 W02 FAIL). The env-var
            // data-root branch has the same exposure for an arbitrary parent.
            //
            // `resolveSandboxRepoRoot` returns a repo root only when the data
            // root's parent carries all required repo markers. On nil we refuse
            // locally; there is no HTTP recovery path.
            guard let repoRootURL = PersistenceCore.resolveSandboxRepoRoot(dataRoot: dataRoot) else {
                var body: [String: Any] = [
                    "tool": tool, "input": input, "surface": "chat", "dry_run": false,
                ]
                if let sid = sessionId { body["session_id"] = sid }
                let bodyData = try JSONSerialization.data(withJSONObject: body)
                return try await _dispatchMissingNativeHandler(bodyData: bodyData)
            }
            let repoRoot = repoRootURL.path
            var extra: [String: JSONValue] = [
                "file_access": .object([
                    "mode": .string("read_only"),
                    "sandbox": .string("read_only"),
                ]),
            ]
            // Thread the data root so `isSensitiveDataPath` blocks OAuth tokens /
            // pairing secrets / provider credentials even though they live UNDER the
            // repo root (which would otherwise be an allowed root). Empty-string
            // guarded — `fromDispatch` treats "" as falsy (Python `_resolve_na_data_root`).
            let dataRootPath = dataRoot.path
            if !dataRootPath.isEmpty {
                extra["_na_data_root"] = .string(dataRootPath)
            }
            ctx = DispatchContext(
                repoRoot: repoRoot,
                cwd: repoRoot,
                surface: "chat",
                sessionId: sessionId ?? "",
                persona: "",
                activeProvider: "",
                extra: extra
            )
        } else {
            ctx = DispatchContext.defaultForSurface("chat", sessionId: sessionId ?? "")
        }
        let result: Dispatcher.DispatchResult
        do {
            result = try await dispatcher.dispatch(tool: tool, input: obj, ctx: ctx, dryRun: false)
        } catch let err as DispatcherError {
            throw NSError(domain: "NativeAgentDispatcher", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: err.localizedDescription])
        }
        // WAVE 36 W11 — preserve the native handler's `output` payload (e.g.
        // persona_read's `content` / `path` / `size_bytes`) instead of dropping
        // it to nil. The HTTP `_dispatchRaw` path decodes the daemon receipt's
        // `output` into DispatchOutput.rawString; the in-process seam must mirror
        // that so receipt-rendering consumers see parity. Serialize the module
        // JSONValue compactly (matches the HTTP-path object shape).
        let mappedOutput: DispatchOutput? = result.output.map { mo in
            DispatchOutput(rawString: (try? mo.value.serialize(pretty: false)) ?? "{}")
        }
        return DispatchResult(
            ok: result.ok,
            tool: result.tool,
            status: result.status,
            output: mappedOutput,
            error: result.error.map { e in DispatchResult.DispatchToolError(code: e.code, message: e.message, tool: e.tool, recoverable: e.recoverable) },
            executed: result.executed,
            verifyPassed: result.verifyPassed,
            durationUs: result.durationUs,
            durationMs: result.durationMs,
            effectiveAutonomy: result.effectiveAutonomy,
            autonomySource: result.autonomySource,
            providerMatch: result.providerMatch,
            traceEventId: result.traceEventId,
            runId: result.runId,
            startedAt: result.startedAt
        )
    }

    func swiftListApprovals() async throws -> [ApprovalRequest] {
        let inbox = SwiftNativeApprovalInbox(root: SwiftNativeApprovalInbox.defaultDataRoot())
        let items = try await inbox.list(filter: .all)
        return items.map { rec in
            ApprovalRequest(
                id: rec.id,
                title: rec.title,
                action: rec.action,
                risk: rec.risk,
                reason: rec.reason,
                status: rec.status,
                createdAt: rec.createdAt,
                resolvedAt: rec.resolvedAt,
                decision: rec.decision,
                payloadPreview: rec.payloadPreview,
                localOnly: rec.localOnly,
                remoteResolvable: rec.remoteResolvable
            )
        }
    }

    func swiftListMCPConsents() async throws -> [MCPConsentRecord] {
        let disp = SwiftNativeMCPDispatcher(root: SwiftNativeMCPDispatcher.defaultDataRoot())
        let items = try await disp.listConsents()
        return items.map(NativeClient._mapMCPConsent)
    }

    /// Shared adapter: Core MCPConsent → app MCPConsentRecord. Field overlap is
    /// exact (id/serverId/toolName/scope/risk/status/argumentSummary/grantedAt/
    /// revokedAt/updatedAt); the module's `permissions`/`extras` have no app-side
    /// slot and are intentionally dropped (the HTTP path never surfaced them to
    /// MCPConsentRecord either — see Models.swift:1373).
    static func _mapMCPConsent(_ c: MCPConsent) -> MCPConsentRecord {
        MCPConsentRecord(
            id: c.id,
            serverId: c.serverId,
            toolName: c.toolName,
            scope: c.scope,
            risk: c.risk,
            status: c.status,
            argumentSummary: c.argumentSummary,
            grantedAt: c.grantedAt,
            revokedAt: c.revokedAt,
            updatedAt: c.updatedAt
        )
    }

    /// Wave 30 W09 — grant consent via the SwiftNative dispatcher. Mirrors the
    /// daemon's grant_mcp_consent default chain: scope defaults to "server_tool",
    /// risk falls back to the server's riskClass when the caller passes none
    /// (the daemon does the same at the retired daemon). Returns the persisted
    /// record adapted to the app shape.
    // W-H MCP-band lift (move-only): fileprivate→internal for NativeClient+MCP.swift.
    func swiftGrantMCPConsent(

        serverId: String,
        toolName: String,
        risk: String?
    ) async throws -> MCPConsentRecord {
        let disp = makeMCPDispatcher()
        // Resolve risk the same way the daemon does: explicit value wins, else
        // the server's riskClass, else the daemon's "app_data_read" default.
        var resolvedRisk = (risk?.isEmpty == false) ? risk! : ""
        if resolvedRisk.isEmpty {
            let servers = try? await disp.listServers()
            if let match = servers?.first(where: { $0.id == serverId }),
               !match.riskClass.isEmpty {
                resolvedRisk = match.riskClass
            }
        }
        if resolvedRisk.isEmpty { resolvedRisk = "app_data_read" }
        let grant = MCPConsentGrant(
            serverId: serverId,
            toolName: toolName,
            scope: "server_tool",
            risk: resolvedRisk
        )
        let rec = try await disp.grantConsent(grant)
        return NativeClient._mapMCPConsent(rec)
    }

    /// Wave 30 W09 — revoke consent via the SwiftNative dispatcher. The module
    /// flips status→"revoked" and stamps revokedAt/updatedAt, returning Void
    /// (it throws .consentNotFound when the row is absent — same failure the
    /// daemon's ValueError → 404 maps to, so the gate above is shape-faithful).
    /// The app contract returns the revoked record, so we re-read the ledger.
    /// We ONLY trust a re-read row whose status is actually "revoked": if a
    /// concurrent re-grant flipped it back to "granted" between our revoke and
    /// the re-read, returning that row would hand a future displaying caller a
    /// granted record from a revoke call (the daemon, by contrast, returns the
    /// row it mutated in-place). In that race — or if the row was pruned — we
    /// synthesize a minimal revoked record so the return ALWAYS reflects the
    /// revoke this call performed. (gpt-5.5 review MINOR, wave 30 W09.)
    // W-H MCP-band lift (move-only): fileprivate→internal for NativeClient+MCP.swift.
    func swiftRevokeMCPConsent(

        serverId: String,
        toolName: String
    ) async throws -> MCPConsentRecord {
        let disp = makeMCPDispatcher()
        try await disp.revokeConsent(serverId: serverId, toolName: toolName)
        let key = "\(serverId):\(toolName)"
        let consents = try await disp.listConsents()
        if let revoked = consents.first(where: { $0.id == key && $0.status == "revoked" }) {
            return NativeClient._mapMCPConsent(revoked)
        }
        // Revoke succeeded but the re-read row is gone (concurrent prune) or has
        // been re-granted out from under us. Return a minimal revoked record so
        // the return reflects THIS call's revoke — never a granted row.
        return MCPConsentRecord(
            id: key,
            serverId: serverId,
            toolName: toolName,
            scope: "server_tool",
            risk: nil,
            status: "revoked",
            argumentSummary: nil,
            grantedAt: nil,
            revokedAt: nil,
            updatedAt: nil
        )
    }

    // MARK: - Training / Promotion / Evals read-side helpers
    //
    // Each reads the SAME data files the daemon reads (co-located on the Mac)
    // and re-decodes the pass-through JSONValue into the identical UI model the
    // HTTP path decodes.
    //
    // wave 32 W05: the daemon's _training_allowed()/_promotion_allowed() 403 trust
    // gates ARE now mirrored. Each training/promotion routed helper consults the
    // Swift gate (SwiftNativeSelfImprovement.trainingAllowed / promotionAllowed,
    // which read the live <root>/trust/policy.json) and, when the gate is CLOSED,
    // throws the IDENTICAL 403 NSError the daemon's HTTP validate() would have
    // produced — so a flag-ON caller sees the same 403 as the HTTP path, not a
    // silently-allowed read. /v1/evals/runs is NOT gated (the retired daemon
    // serves it unconditionally), so swiftGetEvals has no gate, preserving daemon
    // parity. See CUTOVER_PLAN.md 6.76.
    // Each helper constructs the actor directly (the read methods live on the
    // concrete SwiftNativeSelfImprovement, not the protocol).

    static func _trainingPromotionActor() -> SwiftNativeSelfImprovement {
        // dataRoot defaults to defaultDataRoot(), which reads the live process
        // environment exactly as the daemon's _resolve_data_root() does, so the
        // Swift reader is co-located with the daemon's files on the Mac.
        SwiftNativeSelfImprovement()
    }

    /// The 403 NSError the daemon's HTTP path produces on a closed gate. The
    /// daemon sends `_send_json_status(403, {"error": "forbidden", "detail": …})`
    ///, and NativeClient.validate() rethrows
    /// any non-2xx as `NSError(domain:"NativeAgent", code:status,
    /// userInfo:[NSLocalizedDescriptionKey: <raw body string>])`. We reproduce
    /// that exact shape so flag-ON callers get byte-identical 403 behavior.
    static func _trustForbidden(detail: String) -> NSError {
        // json.dumps preserves insertion order: {"error": "forbidden", "detail": "…"}.
        let body = "{\"error\": \"forbidden\", \"detail\": \"\(detail)\"}"
        return NSError(
            domain: "NativeAgent",
            code: 403,
            userInfo: [NSLocalizedDescriptionKey: body]
        )
    }

    func swiftGetTrainingRuns() async throws -> [TrainingRunSummary] {
        let actor = NativeClient._trainingPromotionActor()
        guard await actor.trainingAllowed() else {
            throw NativeClient._trustForbidden(detail: "autonomous_training not enabled in trust policy")
        }
        let raw = await actor.listTrainingRunsLocal()
        let data = try raw.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode([TrainingRunSummary].self, from: data)
    }

    // wave 37 W10 (§6.159): GET /v1/training/runs/<id> routed helper. Consults
    // the SAME trainingAllowed() gate the list route uses (the daemon wraps the
    // detail route in the IDENTICAL _training_allowed() 403, the retired daemon
    // L51979) and throws the byte-identical 403 NSError when closed. A missing
    // run (module returns nil) maps to the daemon's 404 (the retired daemon
    // L51984-51985: `self.send_error(404, "run not found")`). The daemon's
    // send_error emits a plain-text/HTML body, NOT JSON; NativeClient.validate()
    // rethrows any non-2xx as NSError(code: 404, NSLocalizedDescriptionKey:
    // <raw body>), and AppModel callers (when a detail view is eventually wired)
    // already treat any throw as not-found. We reproduce the 404 code; the exact
    // body string is not load-bearing for any caller, so we use a descriptive
    // detail. The full run dict is returned verbatim (NOT the 5-field list
    // projection) — the daemon returns `_get_training().get_run(run_id)` whole.
    func swiftGetTrainingRun(id: String) async throws -> [String: Any] {
        let actor = NativeClient._trainingPromotionActor()
        guard await actor.trainingAllowed() else {
            throw NativeClient._trustForbidden(detail: "autonomous_training not enabled in trust policy")
        }
        guard let raw = await actor.getTrainingRunLocal(runId: id) else {
            // Daemon: f.exists() false → send_error(404, "run not found").
            throw NSError(
                domain: "NativeAgent",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "run not found"]
            )
        }
        // Full graded-run dict pass-through. A present-but-non-object file
        // (corrupt data) throws "Expected JSON object" here, symmetric with the
        // HTTP getDictionary fallback's identical guard.
        return try NativeClient._jsonValueToDictionary(raw)
    }

    func swiftGetTrainingProposals() async throws -> [TrainingProposalSummary] {
        let actor = NativeClient._trainingPromotionActor()
        guard await actor.trainingAllowed() else {
            throw NativeClient._trustForbidden(detail: "autonomous_training not enabled in trust policy")
        }
        let raw = await actor.listTrainingProposalsLocal()
        let data = try raw.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode([TrainingProposalSummary].self, from: data)
    }

    func swiftGetPromotionCandidates() async throws -> [PromotionCandidateSummary] {
        let actor = NativeClient._trainingPromotionActor()
        guard await actor.promotionAllowed() else {
            throw NativeClient._trustForbidden(detail: "promotionPolicy.enabled not set in trust policy")
        }
        let raw = await actor.listPromotionCandidatesLocal()
        let data = try raw.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode([PromotionCandidateSummary].self, from: data)
    }

    func swiftGetPromotionPending() async throws -> [PromotionCandidateSummary] {
        let actor = NativeClient._trainingPromotionActor()
        guard await actor.promotionAllowed() else {
            throw NativeClient._trustForbidden(detail: "promotionPolicy.enabled not set in trust policy")
        }
        let raw = await actor.listPromotionPendingLocal()
        let data = try raw.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode([PromotionCandidateSummary].self, from: data)
    }

    func swiftGetEvals() async throws -> [EvalRun] {
        let raw = await NativeClient._trainingPromotionActor().listEvalsLocal()
        let data = try raw.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode([EvalRun].self, from: data)
    }

    // wave 33 W09: GET /v1/improvements/runs/<id>/diff native read. The
    // SelfImprovement module's improvementDiffLocal(runId:) reads the run record
    // from improvements/runs.json (the file the daemon's _get_improvement reads)
    // then probes the run's worktree with read-only `git diff --cached` /
    // `--numstat` / `status --porcelain` via the same Process surface
    // SelfImprovementGitOps uses, and re-reads AUTONOMY_RECEIPT.md — matching
    // get_improvement_diff field-for-field. NO trust
    // gate on this route in the daemon. Mac-only consumer (ImprovementDiffSheet);
    // no iOS caller. A missing run raises ImprovementRunNotFound, which we map to
    // the SAME 404 NSError the daemon's KeyError→_send_json_status(404) produces,
    // so a flag-ON caller sees identical not-found behavior. See CUTOVER_PLAN §6.96.
    // W-H ImprovementOps-band lift (move-only): fileprivate->internal.
    func swiftImprovementDiff(runId: String) async throws -> ImprovementDiffPayload {
        let actor = NativeClient._trainingPromotionActor()
        do {
            // The module returns SelfImprovement.ImprovementDiffPayload; we
            // re-encode and decode into the app-side ImprovementDiffPayload
            // (Models.swift) the HTTP path already yields — same camelCase keys.
            let payload: SelfImprovement.ImprovementDiffPayload = try await actor.improvementDiffLocal(runId: runId)
            let data = try JSONEncoder().encode(payload)
            return try JSONDecoder.nativeAgent.decode(ImprovementDiffPayload.self, from: data)
        } catch is SelfImprovement.ImprovementRunNotFound {
            // Daemon: KeyError → 404 {"error":"not_found","detail":"run <id> not found"}.
            let body = "{\"error\": \"not_found\", \"detail\": \"run \(runId) not found\"}"
            throw NSError(domain: "NativeAgent", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: body])
        }
    }

    // wave 33 W09: GET /v1/improvements/gauntlet native read — wires the wave-32
    // W09 dormant module impl into the seam (closes §6.76 W09 retirement-path
    // step 1). improvement_gauntlet_status is an
    // unconditional pure file read (improvements/gauntlet/runs.json) + a static
    // promotion-class table — NO trust gate. The module's status field is
    // optional (Python `.get("status")` can return a stored null); the app's
    // ImprovementGauntletStatus.status is non-optional String, so we normalize a
    // null/absent status to "ready" at the seam (the daemon's own fallback for
    // the empty-runs case) before decoding into the app struct.
    func swiftImprovementGauntlet() async throws -> ImprovementGauntletStatus {
        let actor = NativeClient._trainingPromotionActor()
        let status = await actor.improvementGauntletStatusLocal()
        let data = try JSONEncoder().encode(status)
        // Normalize status: null/absent -> "ready" for the app's non-optional field.
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return try JSONDecoder.nativeAgent.decode(ImprovementGauntletStatus.self, from: data)
        }
        if obj["status"] == nil || obj["status"] is NSNull {
            obj["status"] = "ready"
        }
        let normalized = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder.nativeAgent.decode(ImprovementGauntletStatus.self, from: normalized)
    }

    // MARK: - Training-proposal mutation routes (gate: .selfImprovement)
    // wave 33 W10. Mirrors the wave-32 W05 read-side gate posture: consult
    // trainingAllowed() and throw the identical 403 NSError before mutating, so
    // a flag-ON Swift write is under the SAME _training_allowed() leash the HTTP
    // path enforces.

    /// Serialize a JSONValue object into the `[String: Any]` shape
    /// `postDictionary` returns, so the Swift and HTTP approve/reject paths hand
    /// the caller (AppModel) byte-identical dictionaries.
    static func _jsonValueToDictionary(_ value: JSONValue) throws -> [String: Any] {
        let data = try value.serializedData(pretty: false)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "NativeAgent",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "swift training-proposal result was not an object"]
            )
        }
        return dict
    }

    /// Returns the approve result dict. With `route_through_promotion` enabled,
    /// the actor stages a Swift-native promotion candidate instead of applying
    /// the personality-doc write immediately.
    func swiftApproveTrainingProposal(id: String) async throws -> [String: Any] {
        let actor = NativeClient._trainingPromotionActor()
        guard await actor.trainingAllowed() else {
            throw NativeClient._trustForbidden(detail: "autonomous_training not enabled in trust policy")
        }
        let raw = try await actor.approveTrainingProposalLocal(proposalId: id)
        return try NativeClient._jsonValueToDictionary(raw)
    }

    func swiftRejectTrainingProposal(id: String, reason: String) async throws -> [String: Any] {
        let actor = NativeClient._trainingPromotionActor()
        guard await actor.trainingAllowed() else {
            throw NativeClient._trustForbidden(detail: "autonomous_training not enabled in trust policy")
        }
        let raw = try await actor.rejectTrainingProposalLocal(proposalId: id, reason: reason)
        return try NativeClient._jsonValueToDictionary(raw)
    }

    // MARK: - ToolRegistry helpers

    /// Maps a Core ToolRegistry.ToolRecord into the app's ToolRecord. The app
    /// struct surfaces fields Core deliberately CARVES OUT (autoRun,
    /// validationStatus, quarantinePath, description, triggers, etc) and
    /// round-trips them through `extras`. We round-trip via JSON: take Core's
    /// `toJSON()` (typed fields + extras merged), serialize, then decode into
    /// the app's `ToolRecord`. JSONDecoder.nativeAgent's keyDecodingStrategy
    /// is default (NOT snake_case) so both Core's camelCase and the daemon's
    /// camelCase land the same way the HTTP path already does.
    static func _mapCoreToolRecord(_ rec: ToolRegistry.ToolRecord) throws -> ToolRecord {
        let json = rec.toJSON()
        let data = try json.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(ToolRecord.self, from: data)
    }

    func swiftListTools() async throws -> [ToolRecord] {
        let reg = makeToolRegistry()
        let coreRecords = try await reg.listTools(filter: .all)
        return try coreRecords.map { try NativeClient._mapCoreToolRecord($0) }
    }

    // MARK: - ToolExecution / ToolRegistry mutation routes
    // (gates: .toolRegistry — promote/quarantine share the same flag because
    // both write the same registry.json and either path may end up modifying
    // active/, quarantine/, or proposals/. Keeping them co-flagged avoids
    // half-flips where promote routes via Swift but the next quarantine on
    // the same registry returns to HTTP and loses Swift's mutations.)

    /// Promote a proposal via SwiftNativeToolExecution and adapt the resulting
    /// ProposalRecord (rich proposal-side fields) into the app's `ToolRecord`
    /// (tool-registry-side fields). ProposalRecord.toJSON() emits typed slots
    /// (id/name/status/createdAt) PLUS every extras key the promote engine
    /// merges in (activePath/manifestSignature/signedAt/codeFingerprint/
    /// phase/promotedAt/validationStatus/risk-ack fields), so ToolRecord's
    /// JSONDecoder.nativeAgent decode picks them up exactly like the HTTP
    /// path does. The app-side ToolRecord requires `description: String` and
    /// `triggers: [String]` non-optionally — the promote engine merges the
    /// full manifest (which the daemon's create_tool_proposal always populates
    /// with description/triggers) so those land in extras and survive decode.
    // W-H RegistryMutations-band lift (move-only): fileprivate->internal.
    func swiftPromoteTool(id: String, allowRisky: Bool) async throws -> ToolRecord {
        let exec = SwiftNativeToolExecution(root: PersistenceCore.defaultDataRoot())
        let proposal = try await exec.promote(id: id, allowRisky: allowRisky)
        let data = try proposal.toJSON().serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(ToolRecord.self, from: data)
    }

    /// Quarantine a tool via SwiftNativeToolRegistry. Returns a ToolRecord
    /// adapted from Core via the existing `_mapCoreToolRecord` (which mirrors
    /// the same JSON round-trip the HTTP path uses).
    // W-H RegistryMutations-band lift (move-only): fileprivate->internal.
    func swiftQuarantineTool(

        id: String,
        reason: String
    ) async throws -> ToolRecord {
        let reg = makeToolRegistry()
        let coreRec = try await reg.quarantine(id: id, reason: reason)
        return try NativeClient._mapCoreToolRecord(coreRec)
    }

    // MARK: - MCPDispatcher listServers (gate: .mcpDispatcher)

    /// Adapt Core MCPServer → app MCPServerRecord by JSON round-trip via
    /// MCPServer.toJSON() (presence-preserving). Every typed field the app
    /// struct exposes (id/name/transport/endpoint/command/status/healthStatus/
    /// toolCount/resourceCount/riskClass/updatedAt) is populated by Core's
    /// listServers (defaults merged in — nativeagent-internal + searxng-local).
    func swiftListMCPServers() async throws -> [MCPServerRecord] {
        let disp = makeMCPDispatcher()
        let servers = try await disp.listServers()
        return try servers.map { server in
            let data = try server.toJSON().serializedData(pretty: false)
            return try JSONDecoder.nativeAgent.decode(MCPServerRecord.self, from: data)
        }
    }

    /// Returns true iff the registered MCP server `serverId` has
    /// `transport == "stdio"`. Used by `getMCPTools` / `getMCPResources` to
    /// keep live tool/resource reads on servers the SwiftNative subprocess pool
    /// can actually serve (stdio specs).
    /// If the server id is unknown to the SwiftNative dispatcher (which
    /// merges saved + default rows), this returns `false`; callers surface the
    /// unsupported/unknown server through the Swift runtime path.
    func swiftMCPServerIsStdio(

        serverId: String
    ) async throws -> Bool {
        let disp = makeMCPDispatcher()
        let servers = try await disp.listServers()
        guard let match = servers.first(where: { $0.id == serverId }) else {
            return false
        }
        return match.transport == "stdio"
    }

    /// Live MCP session statuses — backed by SwiftNativeMCPDispatcher's
    /// `listSessions()` (subprocess pool + idle/warm/failed status per spec).
    // W-H MCP-band lift (move-only): fileprivate→internal for NativeClient+MCP.swift.
    func swiftListMCPSessions() async throws -> [MCPSessionStatus] {
        let disp = SwiftNativeMCPDispatcher(root: SwiftNativeMCPDispatcher.defaultDataRoot())
        let rows = try await disp.listSessions()
        return rows.map { row in
            MCPSessionStatus(
                id: row.id,
                serverId: row.serverId,
                serverName: row.serverName,
                transport: row.transport,
                status: row.status,
                healthStatus: row.healthStatus,
                toolCount: row.toolCount,
                resourceCount: row.resourceCount,
                lastWarmedAt: row.lastWarmedAt,
                lastError: row.lastError,
                updatedAt: nil
            )
        }
    }

    /// Live MCP tool list for a server — backed by SwiftNativeMCPDispatcher's
    /// `listToolsLive` (spawns the stdio child via the shared pool on demand,
    /// caches results for 60s mirroring the daemon's cache stamp).
    func swiftListMCPToolsLive(

        serverId: String
    ) async throws -> MCPToolsResponse {
        let disp = SwiftNativeMCPDispatcher(root: SwiftNativeMCPDispatcher.defaultDataRoot())
        let raw = try await disp.listToolsLive(forServer: serverId)
        var tools: [MCPToolRecord] = []
        for entry in raw {
            guard case .object(let obj) = entry else { continue }
            guard case .string(let name) = obj["name"] ?? .null else { continue }
            var desc: String? = nil
            if case .string(let s) = obj["description"] ?? .null { desc = s }
            // gpt-5.5 review: must thread inputSchema through the live path,
            // otherwise the new MCPInputSchemaForm always falls back to the raw
            // JSON editor for swift-native-served tools — feature is broken on
            // day one. The HTTP/Codable decode path gets inputSchema for free
            // via JSONDecoder.nativeAgent + default Codable derivation.
            var schema: JSONValue? = nil
            if let s = obj["inputSchema"], case .object = s { schema = s }
            tools.append(MCPToolRecord(name: name, description: desc, inputSchema: schema))
        }
        return MCPToolsResponse(serverId: serverId, tools: tools, createdAt: nil)
    }

    /// Live MCP resource list for a server — same caching contract as
    /// `swiftListMCPToolsLive`.
    func swiftListMCPResourcesLive(

        serverId: String
    ) async throws -> MCPResourcesResponse {
        let disp = SwiftNativeMCPDispatcher(root: SwiftNativeMCPDispatcher.defaultDataRoot())
        let raw = try await disp.listResourcesLive(forServer: serverId)
        var resources: [MCPResourceRecord] = []
        for entry in raw {
            guard case .object(let obj) = entry else { continue }
            guard case .string(let uri) = obj["uri"] ?? .null else { continue }
            var name: String? = nil
            if case .string(let s) = obj["name"] ?? .null { name = s }
            var mime: String? = nil
            if case .string(let s) = obj["mimeType"] ?? .null { mime = s }
            resources.append(MCPResourceRecord(uri: uri, name: name, mimeType: mime))
        }
        return MCPResourcesResponse(serverId: serverId, resources: resources, createdAt: nil)
    }

    // MARK: - Research routes (gate: .research)

    /// SearXNG autodetect — in-process Swift mirror of
    /// `Daemon.autodetect_searxng()`. Scans common ports + docker, persists
    /// `searxng_base_url` to `<dataRoot>/research/config.json` via
    /// PersistenceCore, returns the same {found, baseURL, source, error}
    /// shape the daemon returned. (Daemon-config path was retired
    /// 2026-06-06 — Swift now owns research config in its own file.)
    func swiftAutodetectSearXNG() async throws -> DetectSearXNGResponse {
        let client = makeResearchClient()
        let result = try await client.autodetectSearXNG()
        return DetectSearXNGResponse(
            found: result.found,
            baseURL: result.baseURL,
            source: result.source,
            error: result.error
        )
    }

    /// Research search — in-process Swift mirror of `Daemon.search(query)`.
    /// Hits the configured SearXNG /search endpoint, writes a receipt JSON
    /// to `data/research/<id>.json`, returns the same per-result
    /// {title, url, snippet, source} shape the daemon returns.
    func swiftResearchSearch(query: String) async throws -> [ResearchResult] {
        let client = makeResearchClient()
        let response = try await client.search(query: query)
        return response.results.map { row in
            ResearchResult(
                title: row.title,
                url: row.url,
                snippet: row.snippet,
                source: row.source
            )
        }
    }

    /// Map a Research module `ResearchSearchResult` into the app's
    /// `ResearchResult` model.
    private func mapResearchResult(_ row: Research.ResearchSearchResult) -> ResearchResult {
        ResearchResult(title: row.title, url: row.url, snippet: row.snippet, source: row.source)
    }

    /// Map a Research module `ResearchLabRun` into the app's `ResearchLabRun`
    /// model (Models.swift) — same field set 1:1.
    private func mapLabRun(_ run: Research.ResearchLabRun) -> ResearchLabRun {
        ResearchLabRun(
            id: run.id,
            objective: run.objective,
            status: run.status,
            query: run.query,
            sources: run.sources.map { mapResearchResult($0) },
            brief: run.brief,
            connector: run.connector,
            error: run.error,
            createdAt: run.createdAt
        )
    }

    /// Research lab runs — in-process Swift mirror of
    /// `Daemon.research_lab_runs()`. Reads data/research/lab/runs.json,
    /// decodes the stored run rows into the app model. (Gate: .research.)
    func swiftResearchLabRuns() async throws -> [ResearchLabRun] {
        let client = makeResearchClient()
        let rows = try await client.researchLabRuns()
        // The stored rows are raw JSON; decode each into the app model via the
        // shared JSONValue -> Codable bridge to honor missing-field defaults.
        return rows.compactMap { row -> ResearchLabRun? in
            guard let data = try? row.serializedData(pretty: false) else { return nil }
            return try? JSONDecoder().decode(ResearchLabRun.self, from: data)
        }
    }

    /// Research lab run — in-process Swift mirror of
    /// `Daemon.run_research_lab(body)`. Passes maxResults=5 to match the
    /// daemon caller's body. (Gate: .research.)
    func swiftRunResearchLab(objective: String) async throws -> ResearchLabRun {
        let client = makeResearchClient()
        let run = try await client.runResearchLab(objective: objective, maxResults: 5)
        return mapLabRun(run)
    }

    // MARK: - PersonaEngine routes (gate: .personaEngine)

    /// Build the app's `PersonalityProfile` from `PersonaCompiler.compileProfile()`
    /// which mirrors the daemon's `personality()` (default-seeded normalization
    /// of `<dataRoot>/memory/profile.json`). Every field the HTTP `/v1/personality`
    /// response carries is populated — Core's CompiledPersonalityProfile and
    /// the shared PersonalityProfile struct share the same field set 1:1.
    func swiftPersonality() async throws -> PersonalityProfile {
        let compiled = await PersonaCompiler().compileProfile(
            dataRoot: PersistenceCore.defaultDataRoot()
        )
        // Shared with the wave-33 W06 write-gate result mapping so the read and
        // write paths can't drift on the CompiledPersonalityProfile → app shape.
        return Self.adaptCompiledProfile(compiled)
    }

    /// Build the personality growth summary by compiling the chat-surface
    /// packet for fingerprint+activeKind and providing a feedback-memory count
    /// via SwiftNativeMemoryV2.listMemory(kind:nil) filtered by the
    /// `persona-feedback` tag (mirrors daemon's persona-feedback memory query).
    func swiftPersonalityGrowth() async throws -> PersonalityGrowthSummary {
        let compiler = PersonaCompiler()
        let feedbackProvider: @Sendable () async throws -> Int = {
            let mem = SwiftNativeMemoryV2.shared
            let records = try await mem.listMemory(kind: nil)
            return records.reduce(0) { acc, rec in
                let tags = rec.tags ?? []
                return acc + (tags.contains("persona-feedback") ? 1 : 0)
            }
        }
        let summary = try await compiler.growthSummary(
            feedbackMemoryProvider: feedbackProvider,
            now: Date.init
        )
        return PersonalityGrowthSummary(
            engineVersion: summary.engineVersion,
            activeKind: summary.activeKind,
            fingerprint: summary.fingerprint,
            growthEntries: summary.growthEntries,
            feedbackMemories: summary.feedbackMemories,
            nextActions: summary.nextActions,
            createdAt: summary.createdAt.isEmpty ? nil : summary.createdAt
        )
    }

    // MARK: - CompiledPersonality route (gate: .personaEngine)

    /// Build the `/v1/personality/compiled` response in Swift by calling
    /// `PersonaCompiler.compiledPacket(surface:)`, which mirrors the
    /// daemon's `compiled_personality_packet` (the retired daemon
    /// L35508-35553) and the route envelope at L51635-51638. The wire
    /// shape `{surface, fingerprint, compiled}` is byte-equivalent: the
    /// `fingerprint` hashes the FULL UNSLICED docs + full profile via the
    /// same canonical-JSON serializer the daemon uses, and `compiled` is
    /// rendered as `json.dumps(packet, indent=2)` (ensure_ascii=True,
    /// insertion-order keys) so the Personality tab text matches byte-
    /// for-byte.
    func swiftCompiledPersonality(surface: String) async throws -> CompiledPersonality {
        let wire = try await PersonaCompiler().compiledPacket(surface: surface)
        return CompiledPersonality(
            surface: wire.surface,
            fingerprint: wire.fingerprint,
            compiled: wire.compiled
        )
    }

    // MARK: - TrustCenter route (gate: .trustCenter)

    /// Decode the app-side `TrustPolicy` from `SwiftNativeTrustCenter.loadTrustPolicyJSON()`.
    /// The adapter encodes the in-Swift policy dict to the same compact wire
    /// shape the daemon's `/v1/trust` returns, so the app decoder sees the
    /// identical byte stream it does on the HTTP path. The fully-qualified
    /// `NativeAgentApp` lookup is implicit — module-local `TrustPolicy` wins
    /// over the imported `TrustCenter.TrustPolicy` for unqualified use.
    func swiftTrustPolicy() async throws -> TrustPolicy {
        let data = try await SwiftNativeTrustCenter().loadTrustPolicyJSON()
        return try JSONDecoder.nativeAgent.decode(TrustPolicy.self, from: data)
    }

    // MARK: - PersonalityDocs route (gate: .personaEngine)

    /// Field-for-field map from Core's `PersonaDocSpec` (wire-shape DTO
    /// produced by `SwiftNativePersonaEngine.listPersonaDocSpecs()`) to the
    /// app-side `NativeAgentShared.PersonalityDoc`. Core owns the listing
    /// + mapping logic; this adapter only crosses the module boundary.
    func swiftPersonalityDocs() async throws -> PersonalityDocsResponse {
        let listing = try await SwiftNativePersonaEngine().listPersonaDocSpecs()
        let docs: [PersonalityDoc] = listing.docs.map { spec in
            PersonalityDoc(
                id: spec.id,
                title: spec.title,
                filename: spec.filename,
                path: spec.path,
                content: spec.content,
                updatedAt: spec.updatedAt
            )
        }
        return PersonalityDocsResponse(docs: docs, updatedAt: listing.updatedAt)
    }

    // MARK: - TriggerScheduler routes (gate: .triggerScheduler)
    //
    // SUBSYSTEM #17 cluster C3 (2026-05-31). Covers list / enable / disable
    // / configure for BOTH schedules (proactive inbox + executions). fire_now is
    // native for supported inbox/execution cases and fails closed otherwise.

    /// Adapt Core TriggerConfig → app-side InboxTriggerConfig by JSON
    /// round-trip. Core writes the same daemon-byte shape, so InboxTriggerConfig's
    /// tolerant decoder handles the mixed-typed `config` dict unchanged.
    func swiftListInboxTriggers() async throws -> [InboxTriggerConfig] {
        let client = makeTriggerScheduler()
        let configs = try await client.listInboxTriggers()
        return try configs.map { cfg in
            let data = try cfg.toJSON().serializedData(pretty: false)
            return try JSONDecoder.nativeAgent.decode(InboxTriggerConfig.self, from: data)
        }
    }

    /// Adapt Core TriggerConfig → app-side TriggerRecord (Workshop executions schedule).
    /// TriggerRecord has typed (objective/title/trust_required) fields that
    /// live in extras on the Core side; round-trip via JSON preserves them.
    func swiftListWorkshopTriggers() async throws -> [TriggerRecord] {
        let client = makeTriggerScheduler()
        let configs = try await client.listWorkshopTriggers()
        return try configs.map { cfg in
            let data = try cfg.toJSON().serializedData(pretty: false)
            return try JSONDecoder.nativeAgent.decode(TriggerRecord.self, from: data)
        }
    }

    /// Flip enabled bit on an inbox trigger via the SwiftNative actor.
    /// HTTP-equivalent throws on not_found; mirror that so the UI behavior
    /// is unchanged.
    func swiftInboxTriggerEnable(

        name: String,
        enabled: Bool
    ) async throws {
        let client = makeTriggerScheduler()
        let status: TriggerStatus = try await (
            enabled
                ? client.enableInboxTrigger(name: name)
                : client.disableInboxTrigger(name: name)
        )
        if status.status == "not_found" {
            throw NSError(
                domain: "NativeAgent",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "trigger not found: \(name)"]
            )
        }
    }

    /// SwiftNative configure path for inbox triggers. Translates the app-side
    /// dict (which can contain arrays / strings / ints / bools) into a
    /// JSONValue.object and hands it to the actor, which merges shallow into
    /// the existing per-trigger config dict (matches daemon
    /// proactive_triggers.update_config semantics).
    func swiftInboxTriggerConfigure(

        name: String,
        body: [String: Any]
    ) async throws {
        let client = makeTriggerScheduler()
        // Re-serialize to JSON then parse into our JSONValue so any nested
        // arrays/dicts/numbers come out exactly the way the daemon would
        // have parsed them on the HTTP path. Avoids hand-walking [String: Any].
        let data = try JSONSerialization.data(withJSONObject: body)
        let jv = try JSONValue.parse(data)
        let status = try await client.configureInboxTrigger(name: name, config: jv)
        if status.status == "not_found" {
            throw NSError(
                domain: "NativeAgent",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "trigger not found: \(name)"]
            )
        }
    }

    /// Workshop-side enable/disable. Map TriggerStatus → WorkshopActionResult
    /// (status only — there is no mission_id for a config flip).
    func swiftWorkshopTriggerEnable(

        name: String,
        enabled: Bool
    ) async throws -> WorkshopActionResult {
        let client = makeTriggerScheduler()
        let status: TriggerStatus = try await (
            enabled
                ? client.enableWorkshopTrigger(name: name)
                : client.disableWorkshopTrigger(name: name)
        )
        if status.status == "not_found" {
            throw NSError(
                domain: "NativeAgent",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "trigger not found: \(name)"]
            )
        }
        return WorkshopActionResult(
            executionId: nil,
            status: status.status,
            title: nil,
            plan_steps: nil,
            id: nil
        )
    }
}
