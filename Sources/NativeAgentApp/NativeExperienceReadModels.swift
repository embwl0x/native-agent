import Foundation
import PersistenceCore

enum NativeExperienceReadModels {
    static func projectSpaces(
        workspaces: [WorkspaceRecord],
        sessions: [ExperienceSessionBranch],
        executions: [WorkshopExecutionRecord]
    ) async -> [ExperienceProjectSpace] {
        var result: [ExperienceProjectSpace] = []
        for workspace in workspaces {
            let root = URL(fileURLWithPath: workspace.path).standardizedFileURL
            let exists = FileManager.default.fileExists(atPath: root.path)
            var branch: String?
            var head: String?
            var dirtyCount: Int?
            var gitAvailable = false
            var readError: String?
            if exists {
                do {
                    let top = try await NativeClient.runGit(
                        ["rev-parse", "--show-toplevel"],
                        repoRoot: root,
                        timeout: 5
                    )
                    if top.status == 0 {
                        gitAvailable = true
                        async let branchResult = NativeClient.runGit(
                            ["rev-parse", "--abbrev-ref", "HEAD"],
                            repoRoot: root,
                            timeout: 5
                        )
                        async let headResult = NativeClient.runGit(
                            ["rev-parse", "--short", "HEAD"],
                            repoRoot: root,
                            timeout: 5
                        )
                        async let statusResult = NativeClient.runGit(
                            ["status", "--short"],
                            repoRoot: root,
                            timeout: 8
                        )
                        let values = try await (branchResult, headResult, statusResult)
                        branch = values.0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        head = values.1.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        dirtyCount = values.2.stdout.split(whereSeparator: \.isNewline).count
                    }
                } catch {
                    readError = error.localizedDescription
                }
            } else {
                readError = "The saved folder is no longer available."
            }
            result.append(ExperienceProjectSpace(
                id: workspace.id,
                name: workspace.name,
                path: root.path,
                permissions: workspace.permissions,
                branch: branch,
                head: head,
                dirtyFileCount: dirtyCount,
                gitAvailable: gitAvailable,
                sessions: sessions.filter { $0.projectSpaceId == workspace.id },
                workshopExecutions: executions
                    .filter { $0.projectSpaceId == workspace.id }
                    .map(\.id),
                lastUsedAt: workspace.lastUsedAt,
                readError: readError
            ))
        }
        return result.sorted {
            let lhs = $0.lastUsedAt ?? ""
            let rhs = $1.lastUsedAt ?? ""
            if lhs != rhs { return lhs > rhs }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func recentTurnEvents(
        root: URL = PersistenceCore.defaultDataRoot(),
        now: Date = Date()
    ) -> [TurnTraceEvent] {
        TurnSummarySource.loadEvents(root: root, now: now, includeYesterday: true)
    }

    static func diagnosticEvents(from events: [TurnTraceEvent], limit: Int = 300) -> [ExperienceDiagnosticEvent] {
        events.enumerated().map { index, event in
            ExperienceDiagnosticEvent.project(event, ordinal: index)
        }
        .sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id > $1.id
        }
        .prefix(max(1, limit))
        .map { $0 }
    }

    static func readiness(
        providers: [ProviderInfo],
        connectors: [ConnectorRecord],
        tools: [ToolRecord],
        health: HealthCard?
    ) -> [ExperienceReadinessItem] {
        var rows: [ExperienceReadinessItem] = []
        rows += providers.map { provider in
            let state = providerState(provider.auth_status.state)
            return ExperienceReadinessItem(
                id: "provider:\(provider.provider_id)",
                name: provider.display_name,
                category: "Provider",
                state: state,
                reason: provider.auth_status.detail.isEmpty
                    ? defaultReason(for: state, noun: "provider")
                    : provider.auth_status.detail,
                fixDestination: .providers,
                checkedAt: provider.auth_status.last_checked_at
            )
        }
        rows += connectors.map { connector in
            let auth = (connector.authState ?? "").lowercased()
            let healthState = (connector.healthStatus ?? "").lowercased()
            let state: ExperienceReadinessState
            if !connector.enabled || auth == "not_connected" || auth == "missing" {
                state = .needsSetup
            } else if auth.contains("trust") || auth.contains("permission") {
                state = .awaitingTrust
            } else if ["error", "failed", "degraded", "warn"].contains(healthState) {
                state = .degraded
            } else if ["connected", "ready", "authenticated", "ok"].contains(auth)
                        || ["ready", "healthy", "ok"].contains(healthState) {
                state = .ready
            } else {
                state = .unavailable
            }
            return ExperienceReadinessItem(
                id: "connector:\(connector.id)",
                name: connector.name.isEmpty ? connector.id : connector.name,
                category: "Connector",
                state: state,
                reason: connectorReason(connector, state: state),
                fixDestination: .connectors,
                checkedAt: connector.lastCheckedAt ?? connector.updatedAt
            )
        }
        rows += tools.map { tool in
            let raw = (tool.status ?? tool.validationStatus ?? "").lowercased()
            let state: ExperienceReadinessState
            if tool.validationErrors?.isEmpty == false || raw == "failed" || raw == "invalid" {
                state = .degraded
            } else if raw == "disabled" || raw == "draft" || raw == "proposed" {
                state = .needsSetup
            } else if raw.contains("approval") || raw.contains("trust") {
                state = .awaitingTrust
            } else if ["active", "ready", "available", "valid"].contains(raw) || raw.isEmpty {
                state = .ready
            } else {
                state = .unavailable
            }
            return ExperienceReadinessItem(
                id: "tool:\(tool.id)",
                name: tool.name,
                category: "Tool",
                state: state,
                reason: tool.validationErrors?.first
                    ?? defaultReason(for: state, noun: "tool"),
                fixDestination: .skills,
                checkedAt: tool.updatedAt ?? tool.lastUsedAt
            )
        }
        rows += (health?.subsystems ?? []).map { subsystem in
            let state: ExperienceReadinessState
            switch subsystem.status.lowercased() {
            case "ok", "ready", "healthy": state = .ready
            case "warn", "degraded", "partial": state = .degraded
            default: state = subsystem.fixAction == nil ? .unavailable : .needsSetup
            }
            return ExperienceReadinessItem(
                id: "runtime:\(subsystem.id)",
                name: subsystem.label,
                category: "Runtime",
                state: state,
                reason: subsystem.detail,
                fixDestination: .diagnostics,
                checkedAt: health?.createdAt
            )
        }
        return rows.sorted {
            if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func providerState(_ raw: String) -> ExperienceReadinessState {
        switch raw.lowercased() {
        case "ready", "ok", "connected", "authenticated", "active": .ready
        case "missing", "signed_out", "not_configured", "needs_setup": .needsSetup
        case "awaiting_trust", "permission_required", "approval_required": .awaitingTrust
        case "degraded", "warn", "error", "failed", "corrupt": .degraded
        default: .unavailable
        }
    }

    private static func connectorReason(_ connector: ConnectorRecord, state: ExperienceReadinessState) -> String {
        let components = [connector.authState, connector.healthStatus]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return components.isEmpty
            ? defaultReason(for: state, noun: "connector")
            : components.joined(separator: " · ")
    }

    private static func defaultReason(for state: ExperienceReadinessState, noun: String) -> String {
        switch state {
        case .unavailable: "The \(noun) is not available in the current runtime."
        case .needsSetup: "The \(noun) needs configuration or credentials."
        case .awaitingTrust: "The \(noun) is configured but still needs permission or trust."
        case .ready: "The \(noun) is ready under its current permissions."
        case .degraded: "The \(noun) is available but its latest health check is degraded."
        }
    }
}
