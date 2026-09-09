import Foundation
import BackgroundLoops
import GitHubConnector
import NativeAgentShared
import SlackConnector
import TelegramBot
import Testing
import TrustCenter
@testable import NativeAgentApp

/// Wave 9 takes settings rows through the app actions that their mounted
/// controls invoke. Every persistent dependency is rooted in a fresh
/// directory; the network-facing Telegram send is injected at its transport
/// boundary, while its no-configuration failure is exercised with the real
/// runtime client.
@Suite("app.settings · reports-only wave 9 actions", .serialized)
struct SettingsReportsOnlyWave9ActionTests {
    private func tempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-wave9-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func appendFixtureLine(_ line: String, to url: URL) throws {
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url)
        }
    }

    // ui.ConnectorWizard.githubAndNotionTokenFields — mounted copy derives
    // from the same registered descriptor that dispatches the visibility write.
    @Test func githubPermissionCopyTracksTheRegisteredVisibilityCapability() {
        let actions = connectorActionDescriptors()
        let visibility = actions.first { $0.id == "github.set_repo_visibility" }
        #expect(visibility?.connectorId == "github")
        #expect(visibility?.risk == "external_write")
        #expect(visibility?.requiresApproval == true)
        let copy = GitHubPermissionPresentation.lines(actions: actions)
        #expect(copy.contains { $0.contains("github.set_repo_visibility") })
        #expect(copy.contains { $0.contains("Administration: write") })
    }

    // ui.Connectors.addWorkspaceForm
    @Test @MainActor func workspaceActionPersistsOnlyDistinctRealDirectories() async throws {
        let root = try tempRoot("workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let added = await app.addWorkspace(name: "Product notes", path: workspace.path, writable: true)
        #expect(added)
        #expect(app.workspaces.first?.path == workspace.standardizedFileURL.path)
        #expect(app.workspaces.first?.permissions == ["read", "write"])

        let duplicate = await app.addWorkspace(name: "Duplicate", path: workspace.path, writable: false)
        #expect(!duplicate)
        #expect(app.statusText.contains("already registered"))
        let child = workspace.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let nested = await app.addWorkspace(name: "Nested", path: child.path, writable: false)
        #expect(!nested)
        #expect(app.statusText.contains("cannot overlap"))

        let missing = await app.addWorkspace(name: "Missing", path: root.appendingPathComponent("missing").path, writable: false)
        #expect(!missing)
        #expect(app.statusText.contains("existing folder"))
        let link = root.appendingPathComponent("workspace-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspace)
        let symlink = await app.addWorkspace(name: "Symlink", path: link.path, writable: false)
        #expect(!symlink)
        #expect(app.statusText.contains("cannot use symlinks"))
    }

    // ui.Connectors.workspaceSearch
    @Test @MainActor func workspaceSearchActionReturnsTheRuntimeCapAfterAColdActionReload() async throws {
        #if DEBUG
        if let output = ProcessInfo.processInfo.environment["CONNECTORS_SNAPSHOT_DIR"] {
            try ConnectorsView.renderSharedFolderSnapshots(to: URL(fileURLWithPath: output))
        }
        #endif
        let root = try tempRoot("workspace-search")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("searchable", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for index in 0..<55 {
            try Data("needle \(index)".utf8)
                .write(to: workspace.appendingPathComponent("note-\(index).txt"))
        }

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let registered = await app.addWorkspace(name: "Searchable", path: workspace.path, writable: false)
        #expect(registered)
        await app.searchWorkspace(" NEEDLE ")
        #expect(app.workspaceSearchResults.count == 50)
        let mounted = WorkspaceSearchPresentation.make(results: app.workspaceSearchResults)
        #expect(mounted.visible.count == 8)
        #expect(mounted.remainingCount == 42)
        await app.searchWorkspace("   ")
        #expect(app.workspaceSearchResults.isEmpty)
    }

    // ui.ConnectorWizard.slackTokenForm
    @Test func slackFormActionRoundTripsItsIngressPolicyAndRejectedEditKeepsItLive() async throws {
        let root = try tempRoot("slack")
        defer { try? FileManager.default.removeItem(at: root) }
        let token = "xoxb-1111111111-2222222222-abcdefghijklmnopqrst" // gitleaks:allow test credential
        let appToken = "xapp-1-A01234567-1234567890123-abcdefabcdefabcdef" // gitleaks:allow test credential

        let emptyAllowlist = await NativeOAuthFlow.saveSlackToken(
            token, appToken: appToken, allowedChannelIds: [], allowedUserIds: [],
            validateWithSlack: false, dataRoot: root
        )
        #expect(!emptyAllowlist.ok)
        #expect(emptyAllowlist.error?.contains("allowed Slack channel or user") == true)
        #expect(SlackSocketModeConfig.load(dataRoot: root) == nil)

        let saved = await NativeOAuthFlow.saveSlackToken(
            token,
            appToken: appToken,
            allowedChannelIds: ["C-allowed"],
            allowedUserIds: ["U-allowed"],
            requireMention: true,
            validateWithSlack: false,
            dataRoot: root
        )
        #expect(saved.ok)
        let runtime = try #require(SlackSocketModeConfig.load(dataRoot: root))
        #expect(runtime.enabled)
        #expect(runtime.requireMention)
        #expect(runtime.allowedChannelIds == ["C-allowed"])
        #expect(runtime.allowedUserIds == ["U-allowed"])

        let refused = await NativeOAuthFlow.saveSlackToken(
            token, appToken: "not-a-socket-token", validateWithSlack: false, dataRoot: root
        )
        #expect(!refused.ok)
        let afterRefusal = try #require(SlackSocketModeConfig.load(dataRoot: root))
        #expect(afterRefusal.botToken == token)
        #expect(afterRefusal.appToken == appToken)
    }

    // ui.ConnectorWizard.githubAndNotionTokenFields
    @Test func githubAndNotionFormActionsPreserveOnlyValidatedLocalCredentialState() async throws {
        let root = try tempRoot("connector-credentials")
        defer { try? FileManager.default.removeItem(at: root) }
        let githubToken = "ghp_abcdefghijklmnopqrstuvwxyz1234567890"
        let vault = Wave9GitHubCredentialVault()
        let store = GitHubCredentialStore(vault: vault)

        let github = await NativeOAuthFlow.saveGitHubToken(
            githubToken, validateWithGitHub: false, dataRoot: root, credentialStore: store
        )
        #expect(github.ok)
        let loadedGitHub = try await NativeOAuthFlow.loadGitHubToken(dataRoot: root, credentialStore: store)
        #expect(loadedGitHub == githubToken)
        let githubRow = try #require(try await NativeClient.readConnectorRegistryEntry(root: root, provider: "github"))
        #expect(githubRow["connected"] == .bool(true))

        let badGitHub = await NativeOAuthFlow.saveGitHubToken(
            "not-a-token", validateWithGitHub: false, dataRoot: root, credentialStore: store
        )
        #expect(!badGitHub.ok)
        let afterRefusedGitHub = try await NativeOAuthFlow.loadGitHubToken(dataRoot: root, credentialStore: store)
        #expect(afterRefusedGitHub == githubToken)

        let remoteRejected = await NativeOAuthFlow.saveGitHubToken(
            "ghp_abcdefghijklmnopqrstuvwxyz9876543210",
            dataRoot: root,
            credentialStore: store,
            validation: { _ in throw URLError(.userAuthenticationRequired) }
        )
        #expect(!remoteRejected.ok)
        let afterRemoteReject = try await NativeOAuthFlow.loadGitHubToken(dataRoot: root, credentialStore: store)
        #expect(afterRemoteReject == githubToken)

        let notionToken = "secret_" + String(repeating: "a", count: 32)
        let notion = await NativeOAuthFlow.saveNotionToken(notionToken, validate: false, dataRoot: root)
        #expect(notion.ok)
        // saveNotionToken owns the credential file, not the connector catalog.
        // Start presentation from the catalog's canonical Notion descriptor and
        // let its runtime overlay read that durable authority.
        let notionInput = try #require(
            NativeClient.defaultConnectorCatalog().first { $0["id"] == .string("notion") }
        )
        #expect(NativeClient.oauthConnectorTokenExists(oauthId: "notion", root: root))
        let notionRow = NativeClient.connectorRowWithRuntimeOverlay(notionInput, root: root)
        #expect(notionRow["enabled"] == .bool(true))
        #expect(notionRow["authState"] == .string("connected"))
        #expect(notionRow["healthStatus"] == .string("ok"))
        let credentialPath = root
            .appendingPathComponent("connectors/notion/auth.json")
        let savedCredential = try Data(contentsOf: credentialPath)

        let badNotion = await NativeOAuthFlow.saveNotionToken("short", validate: false, dataRoot: root)
        #expect(!badNotion.ok)
        #expect(try Data(contentsOf: credentialPath) == savedCredential)
        #expect(NativeClient.oauthConnectorTokenExists(oauthId: "notion", root: root))
        #expect(NativeClient.connectorRowWithRuntimeOverlay(notionInput, root: root)["authState"] == .string("connected"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Wave9RejectedCredentialProtocol.self]
        let remoteNotionReject = await NativeOAuthFlow.saveNotionToken(
            "secret_" + String(repeating: "b", count: 32),
            validate: true,
            dataRoot: root,
            session: URLSession(configuration: configuration)
        )
        #expect(!remoteNotionReject.ok)
        #expect(try Data(contentsOf: credentialPath) == savedCredential)
        #expect(NativeClient.oauthConnectorTokenExists(oauthId: "notion", root: root))
        let reloadedOverlay = NativeClient.connectorRowWithRuntimeOverlay(notionInput, root: root)
        #expect(reloadedOverlay["enabled"] == .bool(true))
        #expect(reloadedOverlay["authState"] == .string("connected"))
    }

    // ui.Telegram.disconnectButton
    @Test @MainActor func disconnectActionRemovesTheTokenAndDisablesTheFreshRuntime() async throws {
        let root = try tempRoot("telegram-disconnect")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BackgroundLoopsManager(
            coreManager: BackgroundLoops.BackgroundLoopsManager(),
            assembleLoops: { [Wave9TelegramPollLoop()] },
            replacementLoop: { id in
                guard id == "telegram_poll",
                      TelegramBot.TelegramConfig.loadFromDisk(dataRoot: root)?.enabled == true else { return nil }
                return Wave9TelegramPollLoop()
            },
            runAutoDoctorAtLaunch: { false },
            runHeartbeatAtLaunch: { false }
        )
        let app = AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            backgroundLoopsManager: manager
        )
        await manager.start(loops: [Wave9TelegramPollLoop()])
        app.telegramToken = "123:valid"
        app.telegramAllowedChats = "42"
        app.telegramEnabled = true
        await app.saveTelegram()
        await app.refreshTelegram()
        #expect(app.telegramStatus?.enabled == true)
        #expect(app.telegramStatus?.tokenConfigured == true)

        await app.clearTelegramToken()
        await app.refreshTelegram()
        #expect(app.telegramStatus?.enabled == false)
        #expect(app.telegramStatus?.tokenConfigured == false)
        #expect(app.telegramStatus?.pollerEnabled == false)
        #expect(TelegramBot.TelegramConfig.loadFromDisk(dataRoot: root) == nil)
    }

    // ui.Telegram.testReplyButton
    @Test func testReplyActionUsesTheMountedTargetAndFailsClosedWithoutSavedAuthority() async throws {
        let root = try tempRoot("telegram-test")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        await #expect(throws: (any Error).self) { _ = try await client.testTelegram(chatId: nil, dataRoot: root) }
        let noCredentials = try await client.getTelegramStatus()
        #expect(noCredentials.lastError?.contains("saved, enabled") == true)
        try await client.configureTelegram(
            token: "malformed", allowedChatIds: ["42"], allowedUserIds: [], requireMention: true,
            model: "", reasoningEffort: "", enabled: true, dataRoot: root, restartPollLoop: false
        )
        await #expect(throws: (any Error).self) { _ = try await client.testTelegram(chatId: "42", dataRoot: root) }
        let malformed = try await client.getTelegramStatus()
        #expect(malformed.lastError?.contains("malformed") == true)
        try await client.configureTelegram(
            token: "123:valid", allowedChatIds: [], allowedUserIds: [], requireMention: true,
            model: "", reasoningEffort: "", enabled: true, dataRoot: root, restartPollLoop: false
        )
        await #expect(throws: (any Error).self) { _ = try await client.testTelegram(chatId: "42", dataRoot: root) }
        let noAllowlist = try await client.getTelegramStatus()
        #expect(noAllowlist.lastError?.contains("allowed chat or user") == true)
        try await client.configureTelegram(
            token: "123:valid", allowedChatIds: ["42"], allowedUserIds: [], requireMention: true,
            model: "", reasoningEffort: "", enabled: true, dataRoot: root, restartPollLoop: false
        )
        await #expect(throws: (any Error).self) { _ = try await client.testTelegram(chatId: "99", dataRoot: root) }
        let rejectedTarget = try await client.getTelegramStatus()
        #expect(rejectedTarget.lastError?.contains("not in the saved allowlist") == true)
        let transport = Wave9TelegramTransport()
        let sent = try await client.testTelegram(chatId: "42", dataRoot: root, telegramBot: transport)
        #expect(sent.ok)
        #expect(sent.chatId == "42")
        #expect(sent.messageId == 7)
        let requestedChatID = await transport.requestedChatID()
        let requestedMessage = await transport.requestedMessage()
        #expect(requestedChatID == "42")
        #expect(requestedMessage == "NativeAgent Telegram test reply: online.")
        let successStatus = try await NativeClient(baseURL: "", dataRootOverride: root).getTelegramStatus()
        #expect(successStatus.lastReplyAt != nil)
        #expect(successStatus.lastError == nil)
    }

    // ui.Telegram.clearLogsButton + ui.Telegram.receiptsAndBlockedPanels
    @Test @MainActor func clearDiagnosticsActionEmptiesEveryPanelOnTheNextStatusRead() async throws {
        let root = try tempRoot("telegram-clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let telegram = root.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: telegram, withIntermediateDirectories: true)
        try Data("not a JSONL receipt\n".utf8).write(to: telegram.appendingPathComponent("receipts.jsonl"))
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.refreshTelegram()
        #expect(app.telegramStatus?.receiptsIssue?.contains("unreadable") == true)

        for name in ["blocked.jsonl", "errors.jsonl", "logs.jsonl"] {
            try Data("{\"at\":\"2026-08-24T00:00:00Z\",\"id\":\"fixture\"}\n".utf8)
                .write(to: telegram.appendingPathComponent(name))
        }

        await app.clearTelegramLogs()
        #expect(app.telegramStatus?.receipts.isEmpty == true)
        #expect(app.telegramStatus?.blocked.isEmpty == true)
        #expect(app.telegramStatus?.errors.isEmpty == true)
        #expect(app.telegramStatus?.receiptsIssue == nil)
        let clearOutcome = try #require(app.telegramClearLogsOutcome)
        guard case .completed(let receipt) = clearOutcome else {
            Issue.record("The clear action must retain its completed receipt.")
            return
        }
        #expect(receipt.removedFileCount == 4)
        #expect(receipt.removedRowCount == 4)
        #expect(TelegramClearLogsPresentation.summary(for: receipt)
            == "Cleared 4 diagnostic files containing 4 rows.")
        #expect(receipt.status.receipts.isEmpty)
        #expect(receipt.status.blocked.isEmpty)
        #expect(receipt.status.errors.isEmpty)
        let marker = try #require(app.telegramStatus?.lastDiagnosticsClearedAt)
        let reloaded = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await reloaded.refreshTelegram()
        #expect(reloaded.telegramStatus?.lastDiagnosticsClearedAt == marker)
        for name in ["receipts.jsonl", "blocked.jsonl", "errors.jsonl", "logs.jsonl"] {
            #expect(!FileManager.default.fileExists(atPath: telegram.appendingPathComponent(name).path))
        }
    }

    @Test @MainActor func telegramPanelsKeepEmptyUnreadableAndHiddenCountsDistinctAfterReload() async throws {
        let root = try tempRoot("telegram-panels")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await empty.refreshTelegram()
        #expect(empty.telegramStatus?.receipts.isEmpty == true)
        #expect(empty.telegramStatus?.blocked.isEmpty == true)

        let directory = root.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<7 {
            let at = "2026-08-24T00:00:0\(index)Z"
            try appendFixtureLine("{\"id\":\"r\(index)\",\"at\":\"\(at)\"}\n", to: directory.appendingPathComponent("receipts.jsonl"))
            try appendFixtureLine("{\"id\":\"b\(index)\",\"at\":\"\(at)\"}\n", to: directory.appendingPathComponent("blocked.jsonl"))
        }
        for index in 0..<5 {
            try appendFixtureLine("{\"id\":\"e\(index)\",\"at\":\"2026-08-24T00:00:00Z\",\"error\":\"fixture\"}\n", to: directory.appendingPathComponent("errors.jsonl"))
        }
        let reloaded = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await reloaded.refreshTelegram()
        #expect(reloaded.telegramStatus?.receipts.count == 7)
        #expect(reloaded.telegramStatus?.blocked.count == 7)
        #expect(reloaded.telegramStatus?.errors.count == 5)
        #expect(TelegramPanelPresentation.hiddenCount(total: reloaded.telegramStatus?.receipts.count ?? 0, visibleLimit: 6) == 1)
        #expect(TelegramPanelPresentation.hiddenCount(total: reloaded.telegramStatus?.blocked.count ?? 0, visibleLimit: 6) == 1)
        #expect(TelegramPanelPresentation.hiddenCount(total: reloaded.telegramStatus?.errors.count ?? 0, visibleLimit: 4) == 1)
    }
}

private final class Wave9GitHubCredentialVault: GitHubCredentialVault, @unchecked Sendable {
    private var tokens: [String: String] = [:]
    private let lock = NSLock()

    func read(service: String, account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens["\(service)|\(account)"]
    }

    func write(_ token: String, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        tokens["\(service)|\(account)"] = token
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        tokens.removeValue(forKey: "\(service)|\(account)")
    }
}

private actor Wave9TelegramTransport: TelegramBotProtocol {
    private var chatID: String?
    private var message: String?

    func getStatus() async throws -> TelegramBot.TelegramStatus { .init() }
    func clearLogs() async throws {}

    func sendTestMessage(message: String?, chatId: String?) async throws -> TelegramTestResult {
        self.message = message
        self.chatID = chatId
        return TelegramTestResult(rawResponse: .object([
            "ok": .bool(true),
            "chatId": .string("42"),
            "messageId": .int(7),
        ]))
    }

    func requestedChatID() -> String? { chatID }
    func requestedMessage() -> String? { message }
}

private struct Wave9TelegramPollLoop: LoopRunner {
    let loopId = "telegram_poll"
    let interval: TimeInterval = 3_600
    func tickOutcome() async -> LoopTickOutcome { .completed(result: "wave9") }
}

private final class Wave9RejectedCredentialProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":"rejected"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
