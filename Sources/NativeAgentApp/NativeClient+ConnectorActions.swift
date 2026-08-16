import Foundation
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
import GitHubConnector
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

extension NativeClient {
    func runConnectorAction(
        id: String,
        dryRun: Bool,
        input: [String: JSONValue] = [:],
        externalSendIdempotencyKey: String? = nil,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws -> ConnectorActionReceipt {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let descriptor = connectorActionDescriptors().first(where: { $0.id == trimmed }) else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                NSLocalizedDescriptionKey: "Unknown connector action '\(trimmed)'."
            ])
        }

        return try await runConnectorAction(
            descriptor: descriptor,
            dryRun: dryRun,
            input: input,
            externalSendIdempotencyKey: externalSendIdempotencyKey,
            dataRoot: dataRoot
        )
    }

    func runConnectorAction(
        descriptor: ConnectorActionDescriptor,
        dryRun: Bool,
        input: [String: JSONValue] = [:],
        externalSendIdempotencyKey: String? = nil,
        approvedReplayApprovalID: String? = nil,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws -> ConnectorActionReceipt {
        if !dryRun,
           ExternalSendApprovalRequest.canonicalActionID(for: descriptor.id) != nil {
            let staged = try await ExternalSendApprovalLifecycle.stage(
                invokedAs: descriptor.id,
                input: input,
                surface: "connector_action",
                idempotencyKey: externalSendIdempotencyKey,
                dataRoot: dataRoot
            )
            return try await Self.appendConnectorActionReceipt(
                descriptor: descriptor,
                status: "pending_approval",
                dryRun: false,
                approvalId: staged.approval.id,
                output: staged.toolResult,
                dataRoot: dataRoot
            )
        }

        if descriptor.requiresApproval, !dryRun, approvedReplayApprovalID == nil {
            let approval = try await Self.createConnectorActionApproval(
                descriptor,
                input: input,
                dataRoot: dataRoot
            )
            return try await Self.appendConnectorActionReceipt(
                descriptor: descriptor,
                status: "pending_approval",
                dryRun: false,
                approvalId: approval.id,
                output: .object([
                    "actionId": .string(descriptor.id),
                    "connectorId": .string(descriptor.connectorId),
                    "status": .string("pending_approval"),
                    "approvalId": .string(approval.id),
                    "risk": .string(descriptor.risk),
                ]),
                dataRoot: dataRoot
            )
        }

        if !dryRun {
            if let approvalID = approvedReplayApprovalID {
                try await Self.validateApprovedConnectorReplay(
                    approvalID: approvalID,
                    descriptor: descriptor,
                    input: input,
                    dataRoot: dataRoot
                )
            }
            let output: JSONValue
            var receiptStatus = "completed"
            switch descriptor.id {
            case "codex.work_journal":
                output = try await Self.runCodexWorkJournal(input: input)
            case "codex.handoff":
                output = try Self.readCodexHandoff(input: input)
            case "mac.spotlight_search":
                output = try await runMacSpotlightSearch(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "mac.calendar_list_upcoming":
                output = try await MacPIMConnectorActions.calendarListUpcoming(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "mac.reminders_list_due_today":
                output = try await MacPIMConnectorActions.remindersListDueToday(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "mac.mail_list_recent":
                output = try await MacAppleScriptBridge.mailListRecent(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "mac.messages_list_recent":
                output = try await MacAppleScriptBridge.messagesRecentThreads(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "mac.notes_list_recent":
                output = try await MacAppleScriptBridge.notesListRecent(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "mac.notes_search":
                output = try await MacAppleScriptBridge.notesSearch(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "mac.contacts_search":
                output = try await MacContactsAdapter.search(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "mac.notify":
                output = try await Self.runMacNotify(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "mobile.notify":
                output = try await Self.runMobileNotify(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "mac_assistant.watch_templates":
                output = try await Self.runMacAssistantWatchTemplates()
            case "scheduler.schedule_job", "scheduler.create_job":
                output = try await Self.runSchedulerCreateJob(input: input)
            case "scheduler.list_jobs":
                output = try await Self.runSchedulerListJobs()
            case "scheduler.cancel_job":
                output = try await Self.runSchedulerCancelJob(input: input)
            case "markets.status":
                output = try await Self.runMarketTool("market_status", input: input)
            case "markets.watchlists":
                output = try await Self.runMarketTool("market_watchlists", input: input)
            case "markets.quote":
                output = try await Self.runMarketTool("market_quote", input: input)
            // 2026-06-06 x-connector port: route to Swift executor that
            // talks Twitter API v2 with bearer (OAuth 2.0, auto-refresh)
            // and OAuth 1.0a HMAC-SHA1 variants for the `_v1` actions.
            case "x.status":
                output = try await XConnectorActions.status(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "x.me":
                output = try await XConnectorActions.me(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "x.search_recent":
                output = try await XConnectorActions.searchRecent(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "x.post_tweet":
                output = try await XConnectorActions.postTweet(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "x.timeline_home":
                output = try await XConnectorActions.timelineHome(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "x.user_tweets":
                output = try await XConnectorActions.userTweets(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "x.timeline_home_v1":
                output = try await XConnectorActions.timelineHomeV1(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "x.user_tweets_v1":
                output = try await XConnectorActions.userTweetsV1(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.status":
                output = try await GitHubConnectorActions.status(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.list_repos", "gh.list_repos":
                output = try await GitHubConnectorActions.listRepos(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.list_issues", "gh.search_issues":
                output = try await GitHubConnectorActions.listIssues(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.search":
                output = try await GitHubConnectorActions.search(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.list_pull_requests":
                output = try await GitHubConnectorActions.listPullRequests(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.get_issue":
                output = try await GitHubConnectorActions.getIssue(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.get_pull_request":
                output = try await GitHubConnectorActions.getPullRequest(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.pull_request_files":
                output = try await GitHubConnectorActions.pullRequestFiles(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.pull_request_activity":
                output = try await GitHubConnectorActions.pullRequestActivity(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.discover_tracking":
                output = try await GitHubConnectorActions.discoverTracking(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.project_digest":
                output = try await GitHubConnectorActions.projectDigest(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "github.set_repo_visibility":
                output = try await GitHubConnectorActions.setRepoVisibility(input: input, dataRoot: dataRoot)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "slack.status":
                output = try await SlackConnectorActions.status(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "slack.list_channels":
                output = try await SlackConnectorActions.listChannels(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "slack.search_messages":
                output = try await SlackConnectorActions.searchMessages(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "slack.list_unreads":
                output = try await SlackConnectorActions.listUnreads(input: input)
                receiptStatus = Self.connectorOutputStatus(output) ?? receiptStatus
            case "slack.post_message", "agentmail.send":
                throw NSError(domain: "NativeAgentSwiftOnly", code: -403, userInfo: [
                    NSLocalizedDescriptionKey: "External send escaped mandatory approval staging."
                ])
            default:
                guard descriptor.id.hasSuffix(".status") else {
                    throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
                        NSLocalizedDescriptionKey: "Connector action \(descriptor.id) needs a live Swift provider executor. This action is registered but no Swift executor owns its effects yet."
                    ])
                }
                output = try await connectorStatusActionOutput(descriptor)
            }
            return try await Self.appendConnectorActionReceipt(
                descriptor: descriptor,
                status: receiptStatus,
                dryRun: false,
                approvalId: approvedReplayApprovalID,
                output: output,
                dataRoot: dataRoot
            )
        }

        let output: JSONValue = .object([
            "actionId": .string(descriptor.id),
            "connectorId": .string(descriptor.connectorId),
            "status": .string("dry_run"),
            "dryRun": .bool(true),
        ])
        return try await Self.appendConnectorActionReceipt(
            descriptor: descriptor,
            status: "dry_run",
            dryRun: true,
            approvalId: nil,
            output: output,
            dataRoot: dataRoot
        )
    }

    func runMacSpotlightSearch(input: [String: JSONValue]) async throws -> JSONValue {
        let query = Self.connectorInputString(input["query"] ?? input["q"]) ?? ""
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "mac.spotlight_search requires query"
            ])
        }
        let impl = makeMacControl(
            policyProvider: macControlPolicyProvider,
            auditAppendPath: macControlAuditPath
        )
        let result = try await impl.dispatch(action: "spotlight", body: input)
        var obj: [String: JSONValue] = [
            "status": .string(result.ok ? "completed" : "failed"),
            "action": .string(result.action),
            "ok": .bool(result.ok),
            "durationMs": .int(Int64(result.durationMs)),
            "viaSwift": .bool(result.viaSwift),
            "output": result.output,
        ]
        if let error = result.error {
            obj["error"] = .string(error)
        }
        if let httpStatus = result.httpStatus {
            obj["httpStatus"] = .int(Int64(httpStatus))
        }
        return NativeAppSecretRedactor.redactValue(.object(obj))
    }

    static func runMacNotify(input: [String: JSONValue]) async throws -> JSONValue {
        let title = NativeAgentNotificationDefaults.title(connectorInputString(input["title"]))
        let message = connectorInputString(input["message"]) ?? connectorInputString(input["body"]) ?? ""
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "mac.notify requires message"
            ])
        }
        let result = await NativeAgentNotifications.postAndReport(title: title, body: message)
        var obj = result.deliveryFields()
        obj.merge([
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(NativeAppSecretRedactor.redactText(String(message.prefix(200)))),
        ]) { _, new in new }
        return .object(obj)
    }

    static func runMobileNotify(input: [String: JSONValue]) async throws -> JSONValue {
        let title = NativeAgentNotificationDefaults.title(connectorInputString(input["title"]))
        let message = connectorInputString(input["message"]) ?? connectorInputString(input["body"]) ?? ""
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "mobile.notify requires message"
            ])
        }
        let receipt = try await MacSyncEngine.shared.sendNotificationToPairedDevices(
            title: title,
            body: message,
            userInfo: ["screen": "inbox", "source": connectorInputString(input["source"]) ?? "connector_action"]
        )
        var obj = receipt.deliveryFields()
        obj.merge([
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(NativeAppSecretRedactor.redactText(String(message.prefix(200)))),
        ]) { _, new in new }
        return .object(obj)
    }

    static func runMacAssistantWatchTemplates() async throws -> JSONValue {
        let impl = makeMacAssistantStatusClient(
            dispatcherTools: StaticDispatcherToolAvailabilityProvider(availableTools: [
                "calendar_list_upcoming",
                "reminders_list_due_today",
            ]),
            localPIM: NativeAppLocalPIMStatusProvider()
        )
        let status = try await impl.macAssistantStatus(lightweight: false)
        return status.toJSON()
    }

    // 2026-06-07 Phase 3: promoted from private to internal so
    // MacIntegrationBridgeImpl can call them — the scheduler chat tools
    // (scheduler_create_job / scheduler_list_jobs) reuse the same
    // SwiftNative TriggerScheduler path the connector-action route uses.
    static func runSchedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue {
        let writer = makeSchedulerJobWriter(connectorActionIDs: connectorActionIDSet())
        let job = try await writer.createJob(body: .object(input))
        return .object([
            "status": .string("completed"),
            "job": job,
        ])
    }

    static func runSchedulerListJobs() async throws -> JSONValue {
        let writer = makeSchedulerJobWriter(connectorActionIDs: connectorActionIDSet())
        let jobs = try await writer.listJobs()
        return .object([
            "status": .string("completed"),
            "count": .int(Int64(jobs.count)),
            "jobs": .array(jobs),
        ])
    }

    static func runSchedulerCancelJob(input: [String: JSONValue]) async throws -> JSONValue {
        let jobId = connectorInputString(input["jobId"] ?? input["job_id"] ?? input["id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let writer = makeSchedulerJobWriter(connectorActionIDs: connectorActionIDSet())
        let result = try await writer.cancelJob(jobId: jobId)
        if case .object(var obj) = result {
            obj["status"] = .string("completed")
            return .object(obj)
        }
        return .object([
            "status": .string("completed"),
            "result": result,
        ])
    }

    static func runMarketTool(_ tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        let dispatcher = SwiftToolDispatcher()
        let output = try await dispatcher.dispatch(tool: tool, input: input, surface: "connector_action")
        return NativeAppSecretRedactor.redactValue(output)
    }

    static func readCodexHandoff(input: [String: JSONValue]) throws -> JSONValue {
        let includeText = connectorInputBool(input["includeText"], default: false)
        let maxChars = max(500, min(connectorInputInt(input["maxChars"], default: 8_000), 50_000))
        let maxEntries = max(1, min(connectorInputInt(input["maxEntries"], default: 5), 25))
        let maxEntryChars = max(500, min(connectorInputInt(input["maxEntryChars"], default: 2_000), 10_000))
        let path = codexHandoffPath()
        let exists = FileManager.default.fileExists(atPath: path.path)
        let rawText = exists ? ((try? String(contentsOf: path, encoding: .utf8)) ?? "") : ""
        let redacted = NativeAppSecretRedactor.redactText(rawText)
        let entries = recentMarkdownEntries(redacted, maxEntries: maxEntries, maxEntryChars: maxEntryChars)
        var obj: [String: JSONValue] = [
            "status": .string(exists ? "available" : "missing"),
            "path": .string(path.path),
            "exists": .bool(exists),
            "updatedAt": .string(fileModifiedISO(path) ?? ""),
            "entryCount": .int(Int64(entries.count)),
            "entries": .array(entries.map { .string($0) }),
        ]
        if includeText {
            obj["text"] = .string(String(redacted.prefix(maxChars)))
        }
        return .object(obj)
    }

    static func runCodexWorkJournal(input: [String: JSONValue]) async throws -> JSONValue {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let days = max(1, min(connectorInputInt(input["days"], default: 1), 30))
        let persist = connectorInputBool(input["persist"], default: true)
        let maxProjects = max(1, min(connectorInputInt(input["maxProjects"], default: 40), 100))
        let maxCommits = max(1, min(connectorInputInt(input["maxCommitsPerProject"], default: 8), 25))
        let roots = await codexJournalRoots(input: input, maxProjects: maxProjects, dataRoot: dataRoot)

        var projectRows: [JSONValue] = []
        for root in roots.prefix(maxProjects) {
            if let row = try await codexJournalProject(root: root, days: days, maxCommits: maxCommits) {
                projectRows.append(row)
            }
        }

        let handoff = (try? readCodexHandoff(input: [
            "includeText": .bool(false),
            "maxEntries": .int(3),
            "maxEntryChars": .int(1200),
        ])) ?? .object(["status": .string("unavailable")])
        let generatedAt = SwiftNativeManifestSigner.isoTimestamp(Date())
        let snapshot = NativeAppSecretRedactor.redactValue(.object([
            "id": .string("codex-work-\(UUID().uuidString.lowercased())"),
            "status": .string("completed"),
            "generatedAt": .string(generatedAt),
            "days": .int(Int64(days)),
            "projectCount": .int(Int64(projectRows.count)),
            "projects": .array(projectRows),
            "handoff": handoff,
            "source": input["source"] ?? .string("connector_action"),
        ]))

        if persist {
            let journalDir = dataRoot.appendingPathComponent("work_journal", isDirectory: true)
            let journalPath = journalDir.appendingPathComponent("codex_daily.jsonl")
            let latestPath = journalDir.appendingPathComponent("latest.json")
            let persistence = SwiftNativePersistenceCore()
            try await persistence.withFileLock(journalPath) {
                try await persistence.appendJSONL(snapshot, to: journalPath)
                try await persistence.writeJSON(snapshot, to: latestPath)
            }
        }
        return snapshot
    }

    private static func codexHandoffPath() -> URL {
        let fm = FileManager.default
        if let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_CODEX_HANDOFF_PATH"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: raw)
        }
        let home = fm.homeDirectoryForCurrentUser
        let generic = home.appendingPathComponent("CODEX_HANDOFF.md")
        if fm.fileExists(atPath: generic.path) {
            return generic
        }
        if let entries = try? fm.contentsOfDirectory(atPath: home.path) {
            let candidates = entries
                .filter { $0.hasPrefix("CODEX_HANDOFF_FOR_") && $0.hasSuffix(".md") }
                .sorted()
            if let first = candidates.first {
                return home.appendingPathComponent(first)
            }
        }
        return generic
    }

    static func codexJournalRoots(
        input: [String: JSONValue],
        maxProjects: Int,
        dataRoot: URL
    ) async -> [URL] {
        var candidates: [URL] = []
        for path in connectorInputStringArray(input["roots"]) {
            candidates.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        }
        if connectorInputBool(input["includeSelfRepo"], default: true) {
            candidates.append(dataRoot.deletingLastPathComponent())
        }
        if connectorInputBool(input["includeRegisteredWorkspaces"], default: true) {
            candidates.append(contentsOf: await registeredWorkspaceRoots(dataRoot: dataRoot))
        }
        if connectorInputBool(input["includeProjectsDirectory"], default: true) {
            let projects = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Projects", isDirectory: true)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: projects,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path) {
                    candidates.append(child)
                }
            }
        }

        var out: [URL] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { continue }
            seen.insert(path)
            out.append(candidate.standardizedFileURL)
            if out.count >= maxProjects { break }
        }
        return out
    }

    static func registeredWorkspaceRoots(dataRoot: URL) async -> [URL] {
        let path = dataRoot.appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("workspaces.json")
        let raw = await SwiftNativePersistenceCore().readJSON(path, defaultValue: .array([]))
        guard case .array(let rows) = raw else { return [] }
        return rows.compactMap { row in
            guard case .object(let obj) = row,
                  let path = connectorInputString(obj["path"]) else { return nil }
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
    }

    static func codexJournalProject(root: URL, days: Int, maxCommits: Int) async throws -> JSONValue? {
        let topLevel = try await runGit(["rev-parse", "--show-toplevel"], repoRoot: root, timeout: 5)
        guard topLevel.status == 0 else { return nil }
        let repoPath = topLevel.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoPath.isEmpty else { return nil }
        let repoRoot = URL(fileURLWithPath: repoPath)

        async let branchResult = runGit(["rev-parse", "--abbrev-ref", "HEAD"], repoRoot: repoRoot, timeout: 5)
        async let headResult = runGit(["rev-parse", "--short", "HEAD"], repoRoot: repoRoot, timeout: 5)
        async let statusResult = runGit(["status", "--short"], repoRoot: repoRoot, timeout: 8)
        async let logResult = runGit([
            "log",
            "--since=\(days) days ago",
            "--max-count=\(maxCommits)",
            "--pretty=format:%H%x1f%h%x1f%ct%x1f%an%x1f%s",
        ], repoRoot: repoRoot, timeout: 10)

        let branchValue = try await branchResult
        let headValue = try await headResult
        let status = try await statusResult
        let log = try await logResult
        let branch = branchValue.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = headValue.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusLines = status.stdout
            .split(whereSeparator: \.isNewline)
            .map { NativeAppSecretRedactor.redactText(String($0)) }
        let commits = parseCodexJournalCommits(log.stdout)

        return .object([
            "name": .string(repoRoot.lastPathComponent),
            "path": .string(repoRoot.path),
            "branch": .string(branch),
            "head": .string(head),
            "dirty": .bool(!statusLines.isEmpty),
            "dirtyFiles": .int(Int64(statusLines.count)),
            "dirtySample": .array(statusLines.prefix(20).map { .string($0) }),
            "commitCount": .int(Int64(commits.count)),
            "commits": .array(commits),
        ])
    }

    static func parseCodexJournalCommits(_ raw: String) -> [JSONValue] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = String(line).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { return nil }
            let epoch = TimeInterval(parts[2]) ?? 0
            return .object([
                "sha": .string(parts[0]),
                "shortSha": .string(parts[1]),
                "date": .string(SwiftNativeManifestSigner.isoTimestamp(Date(timeIntervalSince1970: epoch))),
                "author": .string(NativeAppSecretRedactor.redactText(parts[3])),
                "subject": .string(NativeAppSecretRedactor.redactText(parts[4])),
            ])
        }
    }

    static func recentMarkdownEntries(_ text: String, maxEntries: Int, maxEntryChars: Int) -> [String] {
        let chunks = text
            .components(separatedBy: "\n## ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return chunks.suffix(maxEntries).map { chunk in
            let restored = chunk.hasPrefix("#") ? chunk : "## \(chunk)"
            return String(restored.prefix(maxEntryChars))
        }
    }

    static func fileModifiedISO(_ path: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return SwiftNativeManifestSigner.isoTimestamp(date)
    }

    static func connectorInputString(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    static func connectorInputBool(_ raw: JSONValue?, default defaultValue: Bool) -> Bool {
        switch raw {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s):
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(lower) { return true }
            if ["0", "false", "no", "off"].contains(lower) { return false }
            return defaultValue
        default:
            return defaultValue
        }
    }

    static func connectorInputInt(_ raw: JSONValue?, default defaultValue: Int) -> Int {
        switch raw {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        case .bool(let b): return b ? 1 : 0
        default: return defaultValue
        }
    }

    static func connectorInputStringArray(_ raw: JSONValue?) -> [String] {
        guard case .array(let arr)? = raw else { return [] }
        return arr.compactMap { connectorInputString($0) }
    }

    static func connectorOutputStatus(_ output: JSONValue) -> String? {
        guard case .object(let obj) = output,
              case .string(let status)? = obj["status"] else {
            return nil
        }
        return status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : status
    }

    func connectorStatusActionOutput(_ descriptor: ConnectorActionDescriptor) async throws -> JSONValue {
        let connectors = (try? await getConnectors()) ?? []
        let actions = Self.connectorActionRecords(connectors: connectors)
        let action = actions.first { $0.id == descriptor.id }
        return .object([
            "actionId": .string(descriptor.id),
            "connectorId": .string(descriptor.connectorId),
            "name": .string(descriptor.name ?? descriptor.id),
            "status": .string("completed"),
            "risk": .string(descriptor.risk),
            "connectorStatus": .string(action?.connectorStatus ?? "needs_setup"),
            "authState": .string(action?.authState ?? "not_connected"),
            "enabled": .bool(action?.enabled ?? false),
            "dryRunAvailable": .bool(descriptor.dryRunAvailable),
            "requiresApproval": .bool(descriptor.requiresApproval),
        ])
    }

    static func createConnectorActionApproval(
        _ descriptor: ConnectorActionDescriptor,
        input: [String: JSONValue],
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws -> ApprovalRecord {
        let payload: JSONValue = .object([
            "kind": .string("connector_action_v1"),
            "surface": .string("connector_action"),
            "actionId": .string(descriptor.id),
            "connectorId": .string(descriptor.connectorId),
            "name": .string(descriptor.name ?? descriptor.id),
            "risk": .string(descriptor.risk),
            "input": .object(input),
        ])
        let payloadBytes = try payload.serializedData(pretty: false)
        guard payloadBytes.count <= 65_536 else {
            throw NSError(domain: "NativeAgentConnectorApproval", code: 413, userInfo: [
                NSLocalizedDescriptionKey: "Connector approval input exceeds the 64 KiB replay limit."
            ])
        }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        return try await inbox.create(.object([
            "title": .string("Approve \(descriptor.name ?? descriptor.id)"),
            "action": .string("connector.action.\(descriptor.id)"),
            "risk": .string(descriptor.risk),
            "reason": .string("Connector action \(descriptor.id) requires approval before any external side effect can run."),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
            "payload": payload,
        ]))
    }

    struct ConnectorActionApprovalReplay: Sendable {
        let actionID: String
        let connectorID: String
        let surface: String
        let input: [String: JSONValue]
    }

    static func connectorActionApprovalReplay(from record: ApprovalRecord) -> ConnectorActionApprovalReplay? {
        guard record.action.hasPrefix("connector.action."),
              case .object(let payload) = record.payload,
              payload["kind"] == .string("connector_action_v1"),
              case .string(let actionID)? = payload["actionId"],
              record.action == "connector.action.\(actionID)",
              case .string(let connectorID)? = payload["connectorId"],
              case .string(let surface)? = payload["surface"],
              surface == "connector_action",
              case .object(let input)? = payload["input"] else {
            return nil
        }
        return ConnectorActionApprovalReplay(
            actionID: actionID,
            connectorID: connectorID,
            surface: surface,
            input: input
        )
    }

    static func validateApprovedConnectorReplay(
        approvalID: String,
        descriptor: ConnectorActionDescriptor,
        input: [String: JSONValue],
        dataRoot: URL
    ) async throws {
        let record = try await SwiftNativeApprovalInbox(root: dataRoot).get(approvalID)
        guard record.status == "resolved", record.decision == "approved",
              let replay = connectorActionApprovalReplay(from: record),
              replay.actionID == descriptor.id,
              replay.connectorID == descriptor.connectorId,
              replay.input == input else {
            throw NSError(domain: "NativeAgentConnectorApproval", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "Connector execution no longer matches the exact approved payload."
            ])
        }
    }

    static func appendConnectorActionReceipt(
        descriptor: ConnectorActionDescriptor,
        status: String,
        dryRun: Bool,
        approvalId: String?,
        output: JSONValue,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws -> ConnectorActionReceipt {
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let receipt = ConnectorActionReceipt(
            id: UUID().uuidString.lowercased(),
            actionId: descriptor.id,
            connectorId: descriptor.connectorId,
            name: descriptor.name,
            status: status,
            dryRun: dryRun,
            approvalId: approvalId,
            createdAt: nowISO
        )
        let record: JSONValue = .object([
            "id": .string(receipt.id),
            "actionId": .string(receipt.actionId),
            "connectorId": .string(descriptor.connectorId),
            "name": .string(descriptor.name ?? descriptor.id),
            "status": .string(receipt.status),
            "dryRun": .bool(dryRun),
            "approvalId": approvalId.map(JSONValue.string) ?? .null,
            "createdAt": .string(nowISO),
            "ok": .bool(status != "failed"),
            "output": output,
        ])
        let path = Self.externalSendReceiptsPath(dataRoot: dataRoot)
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            try await persistence.appendJSONL(record, to: path)
        }
        return receipt
    }


}
