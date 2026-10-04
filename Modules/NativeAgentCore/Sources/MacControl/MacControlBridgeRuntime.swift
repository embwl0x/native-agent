import Foundation
import CoreFoundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

/// Physical subprocess effects supplied by the Mac app. Policy, admission,
/// durable operation transitions and response interpretation belong to Core.
public protocol MacControlBridgeProcessPort: Sendable {
    /// Project the result before releasing the process registration, preserving
    /// cancellation acknowledgement ordering through response interpretation.
    func runProcess(argv: [String], stdin: String?, timeout: Double, operationId: String,
                    project: (MacControlBridgeProcessResult) -> [String: Any]) -> [String: Any]
    func requestCancellation(operationId: String) -> Bool
    func consumeCancellation(operationId: String) -> (requested: Bool, signalled: Bool)
    func stopAllProcesses() -> Int
}

public enum MacControlBridgeProcessResult: Sendable {
    case spawnFailed(String)
    case exited(stdout: Data, stderr: Data, exit: Int, timedOut: Bool,
                stdoutTruncated: Bool, stderrTruncated: Bool)
}

/// Transport-independent owner of the existing Mac Control bridge protocol.
public final class MacControlBridgeRuntime: @unchecked Sendable {
    private let dataRoot: URL
    private let processes: any MacControlBridgeProcessPort
    private let operationStore: MacControlOperationStore

    public init(dataRoot: URL, processes: any MacControlBridgeProcessPort) {
        self.dataRoot = dataRoot
        self.processes = processes
        self.operationStore = MacControlOperationStore(dataRoot: dataRoot)
    }

    public func recoverInterruptedOperations() async throws {
        _ = try await operationStore.recoverInterruptedOperations(action: "bridge_exec")
    }

    private static let execLimit = 2

    /// Resolves the info endpoint from the listener state that the route reads
    /// at response time. A request that races bridge teardown must fail closed
    /// instead of publishing `ok: true` with the sentinel port zero.
    func infoRouteResponse(method: String, activePort: UInt16) -> MacControlBridgeInfoRouteResponse {
        guard method == "GET" else {
            return MacControlBridgeInfoRouteResponse(state: .methodNotAllowed, port: nil)
        }
        guard activePort != 0 else {
            return MacControlBridgeInfoRouteResponse(state: .unavailable, port: nil)
        }
        return MacControlBridgeInfoRouteResponse(state: .ready, port: activePort)
    }
    private final class ExecResultBox: @unchecked Sendable {
        var value: [String: Any]
        init(_ value: [String: Any]) { self.value = value }
    }
    // fix-audit-append-race: serialize appendExecAudit. Multiple exec background
    // threads (plus route/accept threads) call it concurrently; each does
    // FileHandle open → seekToEnd → write. Without serialization two writers can
    // seek to the same end offset and clobber/interleave each other's JSONL line.
    private let auditAppendLock = NSLock()

    /// The exec concurrency gate. The count lives INSIDE `ScopedSlotCounter`
    /// and is private to it, so there is no way to admit an exec without
    /// holding a `ScopedSlot` handle, and no way to release except by letting
    /// that handle die (`deinit` is the only release path).
    ///
    /// fix-exec-slot-leak (2026-08-02): the handler used to acquire a raw
    /// counter increment and rely solely on the `defer` inside the background
    /// dispatch block. Any throw between the acquire and that block (the
    /// durable `.started` transition throws on flock contention or a full disk)
    /// unwound straight to the request's outer catch WITHOUT entering the block,
    /// leaking the slot permanently. `execLimit` is 2, so two such throws pinned
    /// the count at the limit and every subsequent `/macctl/exec` returned 429
    /// until the app was restarted — `stopAllProcesses` deliberately refuses to
    /// zero the count, so emergency_stop could not recover it either.
    /// With the handle idiom the throw unwinds THROUGH the handle, whose deinit
    /// releases; the background block owns the release only because it captures
    /// the handle explicitly.
    let execSlots = ScopedSlotCounter(name: "macctl-exec", limit: MacControlBridgeRuntime.execLimit)

    private func currentExecCount() -> Int { execSlots.activeCount }

    /// Production health route owner. The caller supplies the live policy
    /// decision while this method reads the actual bounded exec counter, so the
    /// reported capacity cannot drift from admission control.
    func healthRouteResponse(
        method: String,
        startGateAllowed: Bool
    ) -> MacControlBridgeHealthRouteResponse {
        healthRouteResponse(
            method: method,
            startGateAllowed: startGateAllowed,
            execSlotLimit: execSlots.limit,
            activeExecSlots: execSlots.activeCount
        )
    }

    /// Pure response builder for route-level evaluation. It remains behind the
    /// production method above, which supplies the real `execSlots` values.
    func healthRouteResponse(
        method: String,
        startGateAllowed: Bool,
        execSlotLimit: Int,
        activeExecSlots: Int
    ) -> MacControlBridgeHealthRouteResponse {
        let limit = max(0, execSlotLimit)
        let active = max(0, activeExecSlots)
        let free = max(0, limit - active)
        let state: MacControlBridgeHealthRouteResponse.State
        if method != "GET" {
            state = .methodNotAllowed
        } else if !startGateAllowed {
            state = .policyDisabled
        } else if free == 0 {
            state = .execSaturated
        } else {
            state = .ready
        }
        return MacControlBridgeHealthRouteResponse(
            state: state,
            startGateAllowed: startGateAllowed,
            execSlotLimit: limit,
            activeExecSlots: active,
            freeExecSlots: free
        )
    }

    func execTerminalState(
        exit: Int,
        timedOut: Bool,
        cancellationSignalled: Bool
    ) -> MacControlOperationState {
        if timedOut { return .timedOut }
        if cancellationSignalled, exit != 0 { return .cancelAcknowledged }
        return exit == 0 ? .completed : .failed
    }

    @discardableResult
    public func stopAllProcesses(reason: String) -> (stopped: Int, audit: MacControlBridgeAuditAppendReceipt) {
        let stopped = processes.stopAllProcesses()
        let audit = appendExecAudit(
            argv: ["emergency_stop"],
            status: "cancel_requested",
            reason: "\(reason): \(stopped)"
        )
        return (stopped, audit)
    }

    /// A1.3 (prerelease-upgrade-campaign): don't bind 8770 or mint a bearer
    /// token until Mac Control is actually switched on. Reads the SAME live
    /// policy file + key `bridgePolicyAllows` already uses
    /// (`<dataRoot>/trust/policy.json` → `macControlPolicy.enabled`), so there
    /// is one policy source for this bridge, not two. Absent/unparseable file
    /// or absent key ⇒ false ⇒ no listener.
    ///
    /// Verified safe to gate (consumer sweep 2026-08-02): the 8770 listener has
    /// ZERO in-repo clients — the in-app Mac Control tool lane runs in-process
    /// through `MacControlGate` + `SystemProcessAdapter`, and iOS remote Mac
    /// actions go over iCloud sync / `NativeClient /v1/mac_control/*`, never
    /// this socket. And with `enabled == false` every `/macctl/exec` was
    /// already rejected 403 `exec_blocked` by `bridgePolicyAllows`, so the bind
    /// produced nothing but an occupied port and an on-disk descriptor
    /// advertising a live token.
    public func startGateAllows() -> Bool {
        startGateAllows(policyJSON: currentTrustPolicy())
    }

    /// Pure decision seam for `startGateAllows()` — same semantics, no I/O.
    /// `policyJSON == nil` models a missing/unparseable policy file.
    func startGateAllows(policyJSON: [String: Any]?) -> Bool {
        guard let macPolicy = policyJSON?["macControlPolicy"] as? [String: Any] else {
            return false
        }
        // STRICT — see BridgeCore.strictBool: a numeric `1` must NOT open a
        // gate that binds a port and mints a bearer token.
        guard let number = macPolicy["enabled"] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    public static func requiresAuthorization(path: String) -> Bool {
        path != "/macctl/health"
    }

    public func route(method: String, path: String, body: Data,
                      bundleId: String, activePort: () -> UInt16, buildPayload: () -> [String: Any],
                      reply: @escaping @Sendable (Int, [String: Any]) -> Void) {
        switch path {
        case "/macctl/health":
            let health = self.healthRouteResponse(method: method, startGateAllowed: self.startGateAllows())
            var payload = health.responseObject(bundleId: bundleId)
            payload.merge(buildPayload()) { _, new in new }
            reply(health.statusCode, payload)
        case "/macctl/info":
            let info = self.infoRouteResponse(method: method, activePort: activePort())
            var payload = info.responseObject(bundleId: bundleId)
            if info.ok {
                payload.merge(buildPayload()) { _, new in new }
            }
            reply(info.statusCode, payload)
        case "/macctl/emergency_stop":
            guard method == "POST" || method == "GET" else {
                reply(405, ["error": "method_not_allowed"])
                return
            }
            let stop = self.stopAllProcesses(reason: "operator requested emergency stop")
            reply(200, [
                "ok": true,
                "stopped": stop.stopped,
                "active": self.currentExecCount(),
                "via": "macctl-bridge",
                "audit": stop.audit.responseObject(),
            ])
        case "/macctl/exec":
            guard method == "POST" else {
                reply(405, ["error": "method_not_allowed"])
                return
            }
            execHandler(reply: reply, body: body)
        case "/macctl/cancel":
            guard method == "POST" else {
                reply(405, ["error": "method_not_allowed"])
                return
            }
            cancelHandler(reply: reply, body: body)
        default:
            reply(404, ["error": "unknown_path", "path": path])
        }
    }

    // MARK: - Exec handler — runs subprocess UNDER NativeAgent.app

    private func cancelHandler(reply: @escaping @Sendable (Int, [String: Any]) -> Void, body: Data) {
        let json = body.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        guard let operationId = json["operationId"] as? String,
              MacControlOperationStore.validOperationId(operationId) else {
            reply(400, ["error": "invalid_operation_id"])
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let current = try await self.operationStore.record(operationId: operationId) else {
                    reply(404, [
                        "error": "operation_not_found",
                        "operationId": operationId,
                    ])
                    return
                }
                if current.state.isTerminal {
                    reply(200, [
                        "ok": current.state == .cancelAcknowledged,
                        "operationId": operationId,
                        "operationState": current.state.rawValue,
                        "cancelAcknowledged": current.state == .cancelAcknowledged,
                    ])
                    return
                }
                if current.state != .cancelRequested {
                    _ = try await self.operationStore.transition(
                        operationId: operationId,
                        to: .cancelRequested,
                        verification: .pending,
                        expectedNextEvidence: "Process-group death acknowledgement",
                        outcomeCode: "cancel_requested"
                    )
                }
                _ = self.processes.requestCancellation(operationId: operationId)
                // The exec task may acknowledge cancellation before this task
                // registers it with the process owner. Clear that late request too.
                if let latest = try await self.operationStore.record(operationId: operationId), latest.state.isTerminal {
                    _ = self.processes.consumeCancellation(operationId: operationId)
                    reply(200, [
                        "ok": latest.state == .cancelAcknowledged,
                        "operationId": operationId,
                        "operationState": latest.state.rawValue,
                        "cancelAcknowledged": latest.state == .cancelAcknowledged,
                    ])
                    return
                }
                let audit = self.appendExecAudit(
                    argv: ["cancel"],
                    status: "cancel_requested",
                    reason: nil,
                    operationId: operationId
                )
                reply(202, [
                    "ok": true,
                    "operationId": operationId,
                    "operationState": MacControlOperationState.cancelRequested.rawValue,
                    "cancelAcknowledged": false,
                    "audit": audit.responseObject(),
                ])
            } catch {
                reply(409, [
                    "error": "cancel_transition_failed",
                    "detail": error.localizedDescription,
                    "operationId": operationId,
                ])
            }
        }
    }

    private func bridgePolicyAllows(executable exe: String, argv: [String] = []) -> Bool {
        guard let json = currentTrustPolicy(),
              let policy = json["macControlPolicy"] as? [String: Any],
              bridgeAuthorityFlagAllowed(policy, "enabled")
        else {
            return false
        }
        switch exe {
        case "sh", "bash", "zsh":
            return false
        case "osascript":
            let wantsJXA = osascriptUsesJavaScript(argv)
            if wantsJXA {
                return bridgeAuthorityFlagAllowed(policy, "jxa_allowed")
            }
            return bridgeAuthorityFlagAllowed(policy, "applescript_allowed")
        case "shortcuts":
            // User, 2026-09-13: the bridge and the in-process gate must read the
            // same default; both ship allowed once Mac Control is on.
            return bridgeFlagAllowedWhenAbsent(policy, "shortcuts_allowed")
        case "pmset":
            return bridgeAuthorityFlagAllowed(policy, "system_control_allowed")
                && bridgeDestructiveActionsAllowed(json)
        case "mdfind":
            return bridgeFlagAllowedWhenAbsent(policy, "spotlight_allowed")
        case "ls":
            return bridgeAuthorityFlagAllowed(policy, "file_ops_allowed") && bridgeFullMacAccessIsActive(json)
        case "mv":
            return bridgeAuthorityFlagAllowed(policy, "file_ops_allowed")
                && bridgeDestructiveActionsAllowed(json)
                && bridgeFullMacAccessIsActive(json)
        default:
            return false
        }
    }

    private func osascriptUsesJavaScript(_ argv: [String]) -> Bool {
        for (idx, arg) in argv.enumerated() {
            let lower = arg.lowercased()
            if lower == "-l", idx + 1 < argv.count, argv[idx + 1].lowercased() == "javascript" {
                return true
            }
            if lower == "-ljavascript" || lower == "-l javascript" {
                return true
            }
        }
        return false
    }

    private func bridgeFullMacAccessIsActive(_ policy: [String: Any]) -> Bool {
        let permissionLevel = (policy["permissionLevel"] as? String) ?? ""
        let filePolicy = policy["filePolicy"] as? [String: Any]
        let outsideDefault = (filePolicy?["outsideWorkspaceDefault"] as? String) ?? "deny"
        // 2026-09-10: Full Mac has no timer. The saved policy is the grant;
        // any expiry stamps an older install left behind are ignored.
        return outsideDefault == "allow"
            || permissionLevel == "wide_open_receipts"
            || permissionLevel == "full_mac_os"
    }

    private func bridgeDestructiveActionsAllowed(_ policy: [String: Any]) -> Bool {
        bridgeAuthorityFlagAllowed(policy, "developerMode")
    }

    private let allowedExecutablePaths: [String: String] = [
        "osascript": "/usr/bin/osascript",
        "shortcuts": "/usr/bin/shortcuts",
        "pmset": "/usr/bin/pmset",
        "mdfind": "/usr/bin/mdfind",
        "ls": "/bin/ls",
        "mv": "/bin/mv",
    ]

    private func canonicalArgv(_ argv: [String]) -> [String]? {
        guard let first = argv.first, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let exe = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        guard let canonical = allowedExecutablePaths[exe] else {
            return nil
        }
        if first.contains("/") {
            let supplied = URL(fileURLWithPath: first).standardizedFileURL.path
            guard supplied == canonical else {
                return nil
            }
        }
        var out = argv
        out[0] = canonical
        return out
    }

    private func validateExecArgv(_ argv: [String]) -> String? {
        guard let canonical = canonicalArgv(argv), let first = canonical.first else {
            let exe = argv.first.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() } ?? ""
            return exe.isEmpty ? "missing executable" : "executable_not_allowed: \(exe)"
        }
        let exe = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        if !bridgePolicyAllows(executable: exe, argv: argv) {
            return "mac_control_policy_denied: \(exe)"
        }
        if let reason = bridgeProtectedMutationReason(canonical: canonical, executable: exe) {
            return reason
        }
        if exe == "osascript" {
            // Scan the SCRIPT ARGS (canonical argv minus the executable element).
            // Normalize ALL whitespace runs to a single space and also build a fully
            // whitespace-stripped form, so `do shell script` can't be evaded with
            // tabs/newlines/comments (the previous code only de-spaced for the single
            // `doshellscript` recheck). We drop argv[0]: the canonical exe path ends in
            // "osascript", so including it would make the "osascript -e" marker self-match
            // EVERY legitimate top-level `osascript -e …` call and break non-full-mac
            // osascript control. A nested osascript call inside the script body is still
            // caught — it lives in the args we do scan. This is a soft gate — full-mac
            // access bypasses it — so over-blocking benign scripts that merely contain
            // these tokens is the safer failure direction.
            // fix-osascript-continuation: strip the AppleScript line-continuation
            // char "¬" (U+00AC) BEFORE scanning. Otherwise a script can split a
            // high-risk phrase across continued lines (e.g. `do shell ¬\n-e\nscript`)
            // so the marker reconstructs at runtime but slips past a whitespace-only
            // normalization. Removing it lets the existing whitespace-collapse /
            // compact forms re-join the pieces and catch the marker.
            let rawScript = canonical.dropFirst().joined(separator: "\n")
                .replacingOccurrences(of: "\u{00AC}", with: "")
                .lowercased()
            let script = rawScript
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let compactScript = script.replacingOccurrences(of: " ", with: "")
            if !bridgeFullMacAccessIsActive(currentTrustPolicy() ?? [:]) {
                let deniedMarkers = ["do shell script", "do script", "quoted form of", "open for access", "write ", "delete file", "rm ", "curl ", "python", "osascript -e"]
                // fix-osascript-file-bypass: in non-full-mac mode a file-path
                // invocation (e.g. `osascript /tmp/x.applescript`) carries no inline
                // `-e` source, so the dropFirst args-only scan above only sees the
                // PATH, never the dangerous script body — a total bypass. Resolve
                // the referenced script file(s): allow ONLY inline `-e` source, OR a
                // readable .applescript/.scptd-free TEXT file whose contents we scan
                // with the same markers. Deny opaque/compiled .scpt or unreadable
                // script files (fail closed).
                if let reason = self.osascriptFileScanReason(canonical, deniedMarkers: deniedMarkers) {
                    return reason
                }
                // Apply each marker against both the whitespace-collapsed form and the
                // fully whitespace-stripped form so neither extra spacing nor removed
                // spacing can slip a marker past the scan.
                for marker in deniedMarkers {
                    // Always match the whitespace-collapsed form, which preserves word
                    // boundaries (single spaces) — so trailing-space tokens like "rm "
                    // keep their boundary and don't false-match "Terminal"/"confirm".
                    if script.contains(marker) {
                        return "osascript_high_risk_marker"
                    }
                    // Compact (all-whitespace-stripped) match ONLY for multi-word phrase
                    // markers, where whitespace can be injected between words to evade
                    // (e.g. "do\tshell\tscript" → "doshellscript"). Single-token markers
                    // have no internal space, so compact-matching them only loses their
                    // boundary and over-blocks benign substrings.
                    if marker.trimmingCharacters(in: .whitespaces).contains(" ") {
                        let compactMarker = marker.replacingOccurrences(of: " ", with: "")
                        if !compactMarker.isEmpty && compactScript.contains(compactMarker) {
                            return "osascript_high_risk_marker"
                        }
                    }
                }
            }
        }
        return nil
    }

    private func bridgeProtectedMutationReason(
        canonical: [String],
        executable exe: String
    ) -> String? {
        let args = Array(canonical.dropFirst())
        if exe == "mv" {
            var optionsEnded = false
            var preserveDestinationSymlink = false
            let operands = args.filter { arg in
                if !optionsEnded, arg == "--" { optionsEnded = true; return false }
                if !optionsEnded, arg.hasPrefix("-") {
                    if arg.dropFirst().contains("h") { preserveDestinationSymlink = true }
                    return false
                }
                return optionsEnded || !arg.hasPrefix("-")
            }
            var mutationPaths = operands
            if operands.count >= 2, let destination = operands.last {
                let destinationURL = URL(fileURLWithPath: destination)
                var isDirectory: ObjCBool = false
                let replacesSymlink = preserveDestinationSymlink
                    && (try? FileManager.default.destinationOfSymbolicLink(atPath: destinationURL.path)) != nil
                if !replacesSymlink,
                   FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    // mv mutates each child destination, not its containing directory.
                    let sources = Array(operands.dropLast())
                    mutationPaths = sources + sources.map {
                        destinationURL.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent).path
                    }
                }
            }
            for operand in mutationPaths {
                if let reason = MacControlSensitivePathFence.mutationReason(forPath: operand) {
                    return reason
                }
                if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: operand) {
                    return reason
                }
            }
        }
        if exe == "sh" || exe == "bash" || exe == "zsh" {
            let commandText = args.joined(separator: " ").lowercased()
            for prefix in MacControlSensitivePathFence.protectedSystemMutationPrefixes {
                let lowerPrefix = prefix.lowercased()
                if commandText.contains(lowerPrefix + "/") || commandText.contains(lowerPrefix + " ")
                    || commandText.hasSuffix(lowerPrefix) {
                    return "protected_system_path_denied: \(prefix)"
                }
            }
        }
        return nil
    }

    // fix-osascript-file-bypass: resolve the script source for a non-full-mac
    // osascript invocation and fail CLOSED on anything we cannot inspect as
    // inline text. `canonical` is the full validated argv (argv[0] = osascript
    // path). Returns a deny reason string, or nil if the call is safe to let
    // the inline marker scan handle (inline `-e` source, or a clean text file).
    private func osascriptFileScanReason(_ canonical: [String], deniedMarkers: [String]) -> String? {
        let args = Array(canonical.dropFirst())
        // Flags that consume the following token as their value.
        let valueFlags: Set<String> = ["-e", "-l", "-s"]
        var hasInlineSource = false
        var scriptFile: String? = nil
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg.hasPrefix("-"), arg != "-" {
                for flag in arg.dropFirst() {
                    if flag == "i" { return "osascript_stdin_script_denied" }
                    if "els".contains(flag) { break }
                }
            }
            if arg == "-e" {
                hasInlineSource = true
                idx += 2          // skip the statement value
                continue
            }
            if valueFlags.contains(arg) {
                idx += 2          // flag + its value
                continue
            }
            if arg.hasPrefix("-"), arg != "-" {
                idx += 1          // valueless flag (e.g. -i, -ss)
                continue
            }
            // First bare (non-flag) token is the script file; trailing bare
            // tokens are arguments TO the script, not additional files.
            scriptFile = arg
            break
        }
        // Inline `-e` source is authoritative; the outer marker scan over the
        // args already covers it. No file to resolve.
        if hasInlineSource {
            return nil
        }
        guard let path = scriptFile, path != "-" else {
            // With no source operand, osascript reads a script from stdin.
            return "osascript_stdin_script_denied"
        }
        let lowerPath = path.lowercased()
        // Opaque/compiled script bundles can't be scanned as text — fail closed.
        if lowerPath.hasSuffix(".scpt") || lowerPath.hasSuffix(".scptd") {
            return "osascript_compiled_script_denied"
        }
        // Read the referenced script file as text and scan its CONTENTS with the
        // same marker set. Unreadable / non-UTF8 → fail closed.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else {
            return "osascript_script_unreadable"
        }
        let raw = text
            .replacingOccurrences(of: "\u{00AC}", with: "")
            .lowercased()
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let compact = collapsed.replacingOccurrences(of: " ", with: "")
        for marker in deniedMarkers {
            if collapsed.contains(marker) {
                return "osascript_high_risk_marker"
            }
            if marker.trimmingCharacters(in: .whitespaces).contains(" ") {
                let compactMarker = marker.replacingOccurrences(of: " ", with: "")
                if !compactMarker.isEmpty && compact.contains(compactMarker) {
                    return "osascript_high_risk_marker"
                }
            }
        }
        return nil
    }

    private func currentTrustPolicy() -> [String: Any]? {
        guard case .present(let policy) = SavedTrustPolicyAuthority.read(dataRoot: dataRoot),
              let data = try? JSONEncoder().encode(policy),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    /// Appends the audit evidence for every terminal Mac-control outcome. The
    /// optional root is an evaluation seam; production always uses the canonical
    /// data root and retains the existing serialized append behavior.
    @discardableResult
    public func appendExecAudit(
        argv: [String],
        status: String,
        reason: String? = nil,
        operationId: String? = nil,
        dataRoot: URL? = nil
    ) -> MacControlBridgeAuditAppendReceipt {
        // fix-audit-append-race: serialize the open→seek→write so concurrent
        // writers can't seek to the same end offset and clobber/interleave a
        // JSONL line. The store returns retention/write failure explicitly;
        // callers with an HTTP response can expose it rather than making a
        // missing audit row look like a successful receipt.
        auditAppendLock.lock()
        defer { auditAppendLock.unlock() }
        return MacControlBridgeAuditStore.append(
            argv: argv,
            status: status,
            reason: reason,
            operationId: operationId,
            dataRoot: dataRoot ?? self.dataRoot
        )
    }

    /// The route's preflight exits are terminal outcomes too. Keep their audit
    /// construction at the production owner so malformed requests cannot evade
    /// the same evidence feed used by policy refusals and completed processes.
    @discardableResult
    func auditExecValidationRejection(
        argv: [String],
        reason: String,
        operationId: String? = nil,
        dataRoot: URL? = nil
    ) -> MacControlBridgeAuditAppendReceipt {
        appendExecAudit(
            argv: argv,
            status: "validation_rejected",
            reason: reason,
            operationId: operationId,
            dataRoot: dataRoot
        )
    }

    private func replyToPreStartCancellation(
        _ record: MacControlOperationRecord,
        argv: [String],
        protocolVersion: Int,
        reply: @Sendable (Int, [String: Any]) -> Void
    ) -> Bool {
        guard record.state == .cancelAcknowledged, record.startedAt == nil else { return false }
        _ = processes.consumeCancellation(operationId: record.operationId)
        let audit = appendExecAudit(
            argv: argv, status: record.state.rawValue,
            reason: "cancelled_before_start", operationId: record.operationId
        )
        reply(200, [
            "ok": false,
            "protocolVersion": protocolVersion,
            "operationId": record.operationId,
            "operationState": record.state.rawValue,
            "verification": record.verification.rawValue,
            "cancelAcknowledged": true,
            "audit": audit.responseObject(),
        ])
        return true
    }

    private func execHandler(reply: @escaping @Sendable (Int, [String: Any]) -> Void, body: Data) {
        let json = body.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        guard let argv = json["argv"] as? [String], !argv.isEmpty else {
            let suppliedOperationID = json["operationId"] as? String
            _ = self.auditExecValidationRejection(
                argv: [], reason: "missing_argv", operationId: suppliedOperationID
            )
            reply(400, ["error": "missing_argv"])
            return
        }
        let operationId = (json["operationId"] as? String) ?? UUID().uuidString
        guard MacControlOperationStore.validOperationId(operationId) else {
            _ = self.auditExecValidationRejection(
                argv: argv, reason: "invalid_operation_id", operationId: operationId
            )
            reply(400, ["error": "invalid_operation_id"])
            return
        }
        let protocolVersion = (json["protocolVersion"] as? Int) ?? 1
        let stdinStr = json["stdin"] as? String
        let rawTimeout = (json["timeout"] as? Double) ?? 30.0
        let timeout = min(max(rawTimeout.isFinite ? rawTimeout : 30.0, 1.0), 120.0)
        Task { [weak self] in
            guard let self else { return }
            do {
                let requestDigest = try MacControlOperationStore.requestDigest(
                    action: "bridge_exec",
                    body: [
                        "argv": .array(argv.map(JSONValue.string)),
                        "stdin": stdinStr.map(JSONValue.string) ?? .null,
                        "timeout": .double(timeout),
                    ]
                )
                let begin = try await self.operationStore.begin(
                    operationId: operationId,
                    action: "bridge_exec",
                    requestDigest: requestDigest,
                    deadlineSeconds: Int(timeout.rounded(.up))
                )
                switch begin {
                case .replay(let record):
                    reply(200, [
                        "ok": record.state == .completed,
                        "status": "idempotent_replay",
                        "operationId": operationId,
                        "operationState": record.state.rawValue,
                        "verification": record.verification.rawValue,
                        "protocolVersion": protocolVersion,
                    ])
                    return
                case .duplicateActive(let record):
                    reply(409, [
                        "error": "duplicate_active_operation",
                        "operationId": operationId,
                        "operationState": record.state.rawValue,
                        "protocolVersion": protocolVersion,
                    ])
                    return
                case .accepted:
                    break
                }
                if let reason = self.validateExecArgv(argv) {
                    let record = try await self.operationStore.transition(
                        operationId: operationId,
                        to: .blocked,
                        verification: .notRequired,
                        expectedNextEvidence: nil,
                        outcomeCode: "bridge_policy_blocked",
                        acknowledgePreStartCancellation: true
                    )
                    if self.replyToPreStartCancellation(record, argv: argv, protocolVersion: protocolVersion, reply: reply) { return }
                    let audit = self.appendExecAudit(
                        argv: argv,
                        status: "blocked",
                        reason: reason,
                        operationId: operationId
                    )
                    reply(403, [
                        "error": "exec_blocked",
                        "detail": reason,
                        "via": "macctl-bridge",
                        "protocolVersion": protocolVersion,
                        "operationId": operationId,
                        "operationState": MacControlOperationState.blocked.rawValue,
                        "audit": audit.responseObject(),
                    ])
                    return
                }
                // fix-exec-slot-leak (2026-08-02): the slot is a `ScopedSlot`
                // handle. Every exit from here — including a throw out of the
                // `.started` transition below — unwinds through `execSlot`,
                // whose deinit is the ONLY release path. Previously the only
                // release was the background block's `defer`; a throwing
                // transition (flock contention, disk full) unwound to the outer
                // catch without ever entering that block, permanently burning a
                // slot. Two of them pinned the active count at execLimit forever
                // — every /macctl/exec returned 429 and emergency_stop
                // deliberately refuses to zero the count, so only an app restart
                // recovered it.
                guard let execSlot = self.execSlots.acquire() else {
                    let record = try await self.operationStore.transition(
                        operationId: operationId,
                        to: .blocked,
                        verification: .notRequired,
                        expectedNextEvidence: nil,
                        outcomeCode: "exec_queue_saturated",
                        acknowledgePreStartCancellation: true
                    )
                    if self.replyToPreStartCancellation(record, argv: argv, protocolVersion: protocolVersion, reply: reply) { return }
                    let audit = self.appendExecAudit(
                        argv: argv,
                        status: "blocked",
                        reason: "exec_queue_saturated",
                        operationId: operationId
                    )
                    reply(429, [
                        "error": "exec_queue_saturated",
                        "detail": "Too many Mac Control exec jobs are already running.",
                        "active": self.currentExecCount(),
                        "limit": Self.execLimit,
                        "protocolVersion": protocolVersion,
                        "operationId": operationId,
                        "operationState": MacControlOperationState.blocked.rawValue,
                        "audit": audit.responseObject(),
                    ])
                    return
                }
                do {
                    let record = try await self.operationStore.transition(
                        operationId: operationId,
                        to: .started,
                        verification: .pending,
                        expectedNextEvidence: "Process exit and bounded output",
                        acknowledgePreStartCancellation: true
                    )
                    if self.replyToPreStartCancellation(record, argv: argv, protocolVersion: protocolVersion, reply: reply) { return }

                    // Process.waitUntilExit is intentionally kept off Swift's
                    // cooperative executor. The completion returns to a Task only
                    // after the child and process group are gone.
                    // `[execSlot]`: capturing the handle IS the ownership
                    // transfer — the slot stays held until this block's context
                    // is torn down, i.e. after the child and its process group
                    // are gone. No `defer` to forget.
                    DispatchQueue.global(qos: .userInitiated).async { [self, execSlot] in
                        // Holding the handle IS the release contract: it dies
                        // with this block's context, exactly once.
                        defer { withExtendedLifetime(execSlot) {} }
                        let resultBox = ExecResultBox(self.runProcess(
                            argv: argv,
                            stdin: stdinStr,
                            timeout: timeout,
                            operationId: operationId
                        ))
                        let result = resultBox.value
                        let cancellation = self.processes.consumeCancellation(operationId: operationId)
                        let timedOut = result["timed_out"] as? Bool ?? false
                        let exit = result["exit"] as? Int ?? -1
                        // A request racing with natural exit is not an
                        // acknowledgement, and a real exit-0 remains completed
                        // even if a cancellation signal was attempted too late to
                        // prevent the successful terminal result.
                        let terminal = self.execTerminalState(
                            exit: exit,
                            timedOut: timedOut,
                            cancellationSignalled: cancellation.signalled
                        )
                        let cancellationAcknowledged = terminal == .cancelAcknowledged
                        let verification: MotorVerificationState = terminal == .completed ? .unverified : .failed
                        Task { [weak self] in
                            guard let self else { return }
                            do {
                                let record = try await self.operationStore.transition(
                                    operationId: operationId,
                                    to: terminal,
                                    verification: verification,
                                    expectedNextEvidence: terminal == .completed ? "Separate observation of intended effect" : nil,
                                    outcomeCode: cancellationAcknowledged
                                        ? "cancelled_after_process_exit"
                                        : (timedOut ? "timeout" : "exit_\(exit)")
                                )
                                resultBox.value["protocolVersion"] = protocolVersion
                                resultBox.value["operationId"] = operationId
                                resultBox.value["operationState"] = record.state.rawValue
                                resultBox.value["verification"] = record.verification.rawValue
                                resultBox.value["cancelAcknowledged"] = record.state == .cancelAcknowledged
                                let audit = self.appendExecAudit(
                                    argv: argv,
                                    status: record.state.rawValue,
                                    reason: "exit_\(exit)",
                                    operationId: operationId
                                )
                                resultBox.value["audit"] = audit.responseObject()
                                reply(200, resultBox.value)
                            } catch {
                                reply(500, [
                                    "error": "terminal_transition_failed",
                                    "detail": error.localizedDescription,
                                    "operationId": operationId,
                                ])
                            }
                        }
                    }
                    // The background block owns the release from here on: it
                    // captured the handle, so the slot is freed exactly once,
                    // after the child process and its process group are gone.
                }
            } catch {
                reply(409, [
                    "error": "operation_transition_failed",
                    "detail": error.localizedDescription,
                    "operationId": operationId,
                ])
            }
        }
    }

    private func runProcess(argv: [String], stdin: String?, timeout: Double, operationId: String) -> [String: Any] {
        let t0 = Date()
        guard let argv = canonicalArgv(argv) else {
            return [
                "exit": 127,
                "stdout": "",
                "stderr": "executable_not_allowed",
                "duration_ms": Int(Date().timeIntervalSince(t0) * 1000),
                "via": "macctl-bridge",
            ]
        }
        return processes.runProcess(argv: argv, stdin: stdin, timeout: timeout, operationId: operationId) { result in
            switch result {
            case .spawnFailed(let error):
                return [
                    "exit": 127,
                    "stdout": "",
                    "stderr": "spawn_failed: \(error)",
                    "duration_ms": Int(Date().timeIntervalSince(t0) * 1000),
                    "via": "macctl-bridge",
                ]
            case let .exited(outData, errData, exit, isTimeout, stdoutTruncated, stderrTruncated):
                // Use String(decoding:as:) so non-UTF8 bytes become replacement chars (U+FFFD)
                // rather than being silently dropped by String(data:encoding:)'s nil return.
                let stdoutRaw = String(decoding: outData, as: UTF8.self)
                let stderr = String(decoding: errData, as: UTF8.self)
                let durationMs = Int(Date().timeIntervalSince(t0) * 1000)

                let exitCode = isTimeout ? 124 : exit

                // Detect binary output: if >10% of bytes are non-printable (excluding tab/LF/CR),
                // replace with a placeholder so raw binary is never surfaced as text.
                let nonPrintableCount = outData.filter { $0 < 0x20 && $0 != 0x09 && $0 != 0x0a && $0 != 0x0d }.count
                let isBinary = !outData.isEmpty && nonPrintableCount * 10 > outData.count
                let stdout: Any = isBinary
                    ? "<\(outData.count) bytes of non-text output>"
                    : stdoutRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let outputKind: String = isBinary ? "binary_data" : "text"

                return [
                    "exit": exitCode,
                    "stdout": stdout,
                    "stderr": isTimeout ? (stderr + "\ntimed_out_after_\(timeout)s") : stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    "duration_ms": durationMs,
                    "via": "macctl-bridge",
                    "timed_out": isTimeout,
                    "output_kind": outputKind,
                    "stdout_truncated": stdoutTruncated,
                    "stderr_truncated": stderrTruncated,
                ]
            }
        }
    }
}

/// A default-allowed Mac-control flag read from raw policy JSON: absent means
/// allowed (the shipped default, matching MacControlGate); a present value that
/// is not a Bool is damaged authority and denies.
private func bridgeFlagAllowedWhenAbsent(_ policy: [String: Any], _ key: String) -> Bool {
    guard policy[key] != nil else { return true }
    return bridgeAuthorityFlagAllowed(policy, key)
}

private func bridgeAuthorityFlagAllowed(_ policy: [String: Any], _ key: String) -> Bool {
    if let number = policy[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
    return false
}
