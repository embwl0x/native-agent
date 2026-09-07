import Foundation
import NativeAgentShared
import PersistenceCore
import DoctorChecks
import SystemOps
import MacControl


extension NativeClient {
    func runDoctor(repair: Bool) async throws -> DoctorReport {
        // DAEMON-DEAD PORT P4: route through Modules/.../DoctorChecks.
        // Core owns offline integrity checks. The app adds bounded live-owner
        // coverage for the systems named by Doctor's UI; these are local state
        // reads only and never call a provider, Telegram, search, or a tool.
        let impl = makeDoctorChecks()
        let initialResults = try await impl.runAll(repair: false, checkLLM: true)
        let initialChecks = initialResults.map {
            DoctorCheck(id: $0.id, title: $0.title, status: $0.status, detail: $0.detail, repair: $0.repair)
        }
        var repairReceipts: [DoctorCheck] = []
        if repair {
            // Never call `runAll(repair: true)`: that invokes every repairable
            // check, including maintenance with no reported issue. This path
            // executes only rows that offered an explicit app-owned safe repair
            // in the fresh preflight report.
            for id in DoctorSafeRepairIssuesPresentation.plan(for: initialChecks).checkIDs {
                if let receipt = try await impl.runCheck(id: id, repair: true) {
                    repairReceipts.append(DoctorCheck(
                        id: receipt.id,
                        title: receipt.title,
                        status: receipt.status,
                        detail: receipt.detail,
                        repair: receipt.repair
                    ))
                }
            }
        }
        let results: [CheckResult]
        if repair {
            results = try await impl.runAll(repair: false, checkLLM: true)
        } else {
            results = initialResults
        }
        let coreChecks = results.map {
            DoctorCheck(id: $0.id, title: $0.title, status: $0.status, detail: $0.detail, repair: $0.repair)
        }
        let checks = coreChecks + (await liveDoctorCoverageChecks())
        let rollup = Self.doctorRollup(checks.map(\.status))
        let repaired = repair && DoctorSafeRepairIssuesPresentation.appliedRepairCount(in: repairReceipts) > 0
        return DoctorReport(status: rollup, repaired: repaired, checks: checks)
    }

    func liveDoctorCoverageChecks() async -> [DoctorCheck] {
        async let providers = providerDoctorCoverageCheck()
        async let telegram = telegramDoctorCoverageCheck()
        async let search = searchDoctorCoverageCheck()
        async let tools = toolsDoctorCoverageCheck()
        async let autonomy = autonomyDoctorCoverageCheck()
        // FIX-4 (2026-09-01): DoctorLoopHealth's verdicts had no route into
        // `doctorReport.checks`, so the toolbar pill could not see them. This
        // is the same read-only evaluation the Doctor loops section renders,
        // rolled into one row — and it rides the live-coverage lane, so
        // `refreshLiveDoctorCoverage()` keeps it current too.
        async let loops = backgroundLoopsDoctorCoverageCheck()
        return await [providers, telegram, search, tools, autonomy, loops]
    }

    private func backgroundLoopsDoctorCoverageCheck() async -> DoctorCheck {
        await DoctorLoopHealth.doctorCheck(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    private func providerDoctorCoverageCheck() async -> DoctorCheck {
        do {
            let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let providers = try await listProviders(
                dataRoot: dataRoot,
                authEnvironment: ProcessInfo.processInfo.environment
            )
            let registryCheck = Self.providerDoctorCoverageCheck(providers)
            switch ProviderRuntimeHealthFeed.read(dataRoot: dataRoot) {
            case .healthy:
                guard registryCheck.status == "ok" else { return registryCheck }
                return DoctorCheck(
                    id: registryCheck.id,
                    title: registryCheck.title,
                    status: "ok",
                    detail: "\(registryCheck.detail) Recent provider calls are healthy.",
                    repair: nil
                )
            case .unhealthy(_, let detail):
                return DoctorCheck(
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: "warn",
                    detail: "\(registryCheck.detail) \(Self.safeDoctorDetail(detail))",
                    repair: "Open Providers and inspect the active path before running another agent turn."
                )
            case .unavailable:
                break
            }
            switch LLMProviderStatusFeed.read(dataRoot: dataRoot) {
            case .current:
                return registryCheck
            case .stale(let record):
                return DoctorCheck(
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: "warn",
                    detail: "\(registryCheck.detail) Last native provider check for \(record.providerID ?? "an unknown provider") is stale.",
                    repair: "Open Providers and run Test Connection."
                )
            case .unavailable(let detail):
                return DoctorCheck(
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: "warn",
                    detail: "\(registryCheck.detail) Reachability is unmeasured: \(Self.safeDoctorDetail(detail))",
                    repair: "Open Providers and run Test Connection when a native probe is available."
                )
            case .failed(let detail):
                return DoctorCheck(
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: "fail",
                    detail: "The last native provider check failed: \(Self.safeDoctorDetail(detail))",
                    repair: "Open Providers, repair authentication or connectivity, then run Test Connection."
                )
            }
        } catch {
            return DoctorCheck(
                id: "live.providers", title: "Providers and OAuth", status: "fail",
                detail: "Provider registry could not be read: \(Self.safeDoctorDetail(error.localizedDescription))", repair: nil
            )
        }
    }

    private func telegramDoctorCoverageCheck() async -> DoctorCheck {
        do {
            let status = try await getTelegramStatus()
            return Self.telegramDoctorCoverageCheck(status)
        } catch {
            return DoctorCheck(
                id: "live.telegram", title: "Telegram", status: "fail",
                detail: "Telegram status could not be read: \(Self.safeDoctorDetail(error.localizedDescription))", repair: nil
            )
        }
    }

    private func searchDoctorCoverageCheck() async -> DoctorCheck {
        do {
            let raw = (try await getConfig()).searxngBaseURL?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Self.searchDoctorCoverageCheck(raw)
        } catch {
            return DoctorCheck(
                id: "live.search", title: "Search", status: "fail",
                detail: "Search configuration could not be read: \(Self.safeDoctorDetail(error.localizedDescription))", repair: nil
            )
        }
    }

    private func toolsDoctorCoverageCheck() async -> DoctorCheck {
        do {
            let tools = try await getTools()
            return Self.toolsDoctorCoverageCheck(tools)
        } catch {
            return DoctorCheck(
                id: "live.tools", title: "Tool Registry", status: "fail",
                detail: "Tool registry could not be read: \(Self.safeDoctorDetail(error.localizedDescription))", repair: nil
            )
        }
    }

    private func autonomyDoctorCoverageCheck() async -> DoctorCheck {
        do {
            let autonomy = try await getAutonomyKernel()
            return Self.autonomyDoctorCoverageCheck(autonomy)
        } catch {
            return DoctorCheck(
                id: "live.autonomy", title: "Autonomy", status: "fail",
                detail: "Autonomy state could not be read: \(Self.safeDoctorDetail(error.localizedDescription))", repair: nil
            )
        }
    }

    private static func boundedDoctorDetail(_ value: String, limit: Int = 240) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }

    static func safeDoctorDetail(_ value: String) -> String {
        boundedDoctorDetail(NativeAppSecretRedactor.redactText(value))
    }

    static func doctorRollup(_ statuses: [String]) -> String {
        if statuses.contains(where: { ["fail", "error"].contains($0.lowercased()) }) { return "fail" }
        if statuses.contains(where: { $0.lowercased() == "warn" }) { return "warn" }
        return "ok"
    }

    static func providerDoctorCoverageCheck(_ providers: [ProviderInfo]) -> DoctorCheck {
        let ready = providers.filter { $0.auth_status.state.lowercased() == "ready" }
        if ready.isEmpty {
            return DoctorCheck(
                id: "live.providers", title: "Providers and OAuth", status: "warn",
                detail: "Provider registry is readable, but no provider currently reports ready authentication.",
                repair: "Open the Providers tab in the sidebar and authenticate one provider."
            )
        }
        return DoctorCheck(
            id: "live.providers", title: "Providers and OAuth", status: "ok",
            detail: "\(ready.count) of \(providers.count) provider paths report ready authentication.", repair: nil
        )
    }

    static func telegramDoctorCoverageCheck(_ status: TelegramStatus) -> DoctorCheck {
        guard status.enabled else {
            return DoctorCheck(
                id: "live.telegram", title: "Telegram", status: "ok",
                detail: "Telegram is disabled by configuration.", repair: nil
            )
        }
        guard status.tokenConfigured else {
            return DoctorCheck(
                id: "live.telegram", title: "Telegram", status: "fail",
                detail: "Telegram is enabled but no bot token is configured.",
                repair: "Open Settings → Telegram and configure the bot token."
            )
        }
        if status.isTransientPollInterruption {
            return DoctorCheck(
                id: "live.telegram", title: "Telegram", status: "ok",
                detail: "Telegram's poller is active and retrying after a transient poll interruption.",
                repair: nil
            )
        }
        if let lastError = status.actionableError {
            return DoctorCheck(
                id: "live.telegram", title: "Telegram", status: "warn",
                detail: "Telegram's last recorded error is: \(safeDoctorDetail(lastError))", repair: nil
            )
        }
        guard status.pollerEnabled else {
            return DoctorCheck(
                id: "live.telegram", title: "Telegram", status: "warn",
                detail: "Telegram is configured, but its poller is not active.", repair: nil
            )
        }
        return DoctorCheck(
            id: "live.telegram", title: "Telegram", status: "ok",
            detail: "Telegram is configured and its poller is active.", repair: nil
        )
    }

    static func mergeDoctorReport(_ current: DoctorReport, liveChecks: [DoctorCheck]) -> DoctorReport {
        let liveIDs = Set(liveChecks.map(\.id))
        let checks = current.checks.filter { !liveIDs.contains($0.id) } + liveChecks
        return DoctorReport(
            status: doctorRollup(checks.map(\.status)),
            repaired: current.repaired,
            checks: checks
        )
    }

    static func searchDoctorCoverageCheck(_ raw: String) -> DoctorCheck {
        guard !raw.isEmpty else {
            return DoctorCheck(
                id: "live.search", title: "Search", status: "ok",
                detail: "External SearXNG search is not configured.", repair: nil
            )
        }
        guard let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else {
            return DoctorCheck(
                id: "live.search", title: "Search", status: "fail",
                detail: "The configured SearXNG URL is invalid.",
                repair: "Open Settings and enter a valid HTTP(S) SearXNG URL."
            )
        }
        // FIX-5c (2026-09-01): this row is a URL-SYNTAX check wearing the name
        // "Search". Doctor makes no request here (runDoctor's live coverage is
        // local reads only), so a configured endpoint that is down, wrong, or
        // unreachable renders exactly like a working one. Green is reserved
        // for what was actually verified; an unprobed endpoint reads as
        // unverified, not healthy.
        return DoctorCheck(
            id: "live.search", title: "Search", status: "warn",
            detail: "SearXNG is configured and its URL is a valid HTTP(S) shape — syntax only, no request made."
                + " Doctor cannot tell you whether the endpoint answers.",
            repair: "Run a search from chat to prove the endpoint, or clear the SearXNG URL if it is no longer used."
        )
    }

    /// FIX-5c (2026-09-01): every non-throwing path returned "ok", so a
    /// registry holding QUARANTINED tools reported the same green as a clean
    /// one. Two changes, both honesty: the detail now states the row's actual
    /// scope on every path (the registry file was read; no tool was invoked),
    /// and a quarantined tool is a finding. `proposed` is deliberately NOT a
    /// finding — an unapproved proposal is the self-building lane working.
    static func toolsDoctorCoverageCheck(_ tools: [ToolRecord]) -> DoctorCheck {
        let quarantined = tools.filter { ($0.status ?? "active").lowercased() == "quarantined" }
        let active = tools.filter { ($0.status ?? "active").lowercased() == "active" }.count
        let scope = " Registry read only: Doctor invoked no tool, so this says nothing about whether one runs."
        // Taste pass 2026-07-24: this registry holds SELF-BUILT (promoted)
        // tools only — built-in chat tools never appear here, so an empty
        // registry is the normal state and "0 active, 0 total" read like the
        // agent had no tools at all.
        if tools.isEmpty {
            return DoctorCheck(
                id: "live.tools", title: "Tool Registry", status: "ok",
                detail: "Self-built tool registry is readable; no promoted tools yet."
                    + " Built-in tools don't live here." + scope,
                repair: nil
            )
        }
        let census = "Self-built tool registry is readable (\(active) active, \(tools.count) total)."
        if !quarantined.isEmpty {
            let named = quarantined.prefix(3).map(\.name).joined(separator: ", ")
            let more = quarantined.count > 3 ? ", …" : ""
            return DoctorCheck(
                id: "live.tools", title: "Tool Registry", status: "warn",
                detail: census + " \(quarantined.count) quarantined: \(named)\(more)." + scope,
                repair: "Open Tools and restore or remove the quarantined tools."
            )
        }
        return DoctorCheck(
            id: "live.tools", title: "Tool Registry", status: "ok",
            detail: census + scope,
            repair: nil
        )
    }

    static func autonomyDoctorCoverageCheck(_ autonomy: AutonomyKernelSummary) -> DoctorCheck {
        if autonomy.enabled == nil {
            return DoctorCheck(
                id: "live.autonomy", title: "Autonomy", status: "warn",
                detail: "Autonomy state is readable, but its enabled posture is unknown.", repair: nil
            )
        }
        guard autonomy.enabled == true else {
            return DoctorCheck(
                id: "live.autonomy", title: "Autonomy", status: "ok",
                detail: autonomy.disabledReason ?? "Autonomy is disabled by policy.", repair: nil
            )
        }
        let state = autonomy.status.lowercased()
        return DoctorCheck(
            id: "live.autonomy", title: "Autonomy",
            status: ["fail", "error", "degraded"].contains(state) ? "warn" : "ok",
            detail: "Autonomy is enabled in \(autonomy.mode ?? "supervised") mode; \(autonomy.runningImprovements ?? 0) improvements are active.",
            repair: nil
        )
    }

    func systemRebuild() async throws -> SystemRebuildResult {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        let impl = makeSystemRebuildClient()
        let r = try await impl.systemRebuild()
        return SystemRebuildResult(ok: r.ok, message: r.message, error: r.error)
    }

    func gitPush() async throws -> GitPushResult {
        let repoRoot = PersistenceCore.defaultDataRoot().deletingLastPathComponent()
        let branchResult = try await Self.runGit(["rev-parse", "--abbrev-ref", "HEAD"], repoRoot: repoRoot, timeout: 10)
        let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteResult = try await Self.runGit(["remote"], repoRoot: repoRoot, timeout: 10)
        let remotes = remoteResult.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !remotes.isEmpty else {
            return GitPushResult(ok: false, branch: branch.isEmpty ? nil : branch, output: nil, error: "No GitHub remote configured")
        }
        let pushResult = try await Self.runGit(["push"], repoRoot: repoRoot, timeout: 120)
        let output = [pushResult.stdout, pushResult.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return GitPushResult(
            ok: pushResult.status == 0,
            branch: branch.isEmpty ? nil : branch,
            output: output.isEmpty ? nil : output,
            error: pushResult.status == 0 ? nil : (output.isEmpty ? "git push failed" : output)
        )
    }

    static func runGit(
        _ arguments: [String],
        repoRoot: URL,
        timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await runProcess(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: repoRoot,
            timeout: timeout
        )
    }

    static func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let result = try await SystemProcessAdapter().run(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: nil,
            standardInput: nil,
            timeoutSeconds: timeout
        )
        if result.timedOut {
            let stderr = result.stderr.isEmpty
                ? "\(URL(fileURLWithPath: executable).lastPathComponent) command timed out"
                : result.stderr
            return (124, result.stdout, stderr)
        }
        return (result.exitCode, result.stdout, result.stderr)
    }

    static func processDetail(_ result: (status: Int32, stdout: String, stderr: String)) -> String {
        let output = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !output.isEmpty else {
            return "exit \(result.status)"
        }
        let tail = output
            .split(whereSeparator: \.isNewline)
            .suffix(6)
            .joined(separator: " ")
        let clipped = String(tail.prefix(500))
        return "exit \(result.status): \(clipped)"
    }

    func gitStashRecover(label: String) async throws -> GitStashRecoverResult {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        let impl = makeGitStashRecoverClient()
        let r = try await impl.gitStashRecover(label: label)
        return GitStashRecoverResult(ok: r.ok, stashRef: r.stashRef, output: r.output, error: r.error)
    }
}
