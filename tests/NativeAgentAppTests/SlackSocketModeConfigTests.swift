import Foundation
import Testing
@testable import NativeAgentApp

private func makeSlackConfigRoot(_ values: [String: Any]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SlackSocketModeConfigTests-\(UUID().uuidString)", isDirectory: true)
    let directory = root
        .appendingPathComponent("connectors", isDirectory: true)
        .appendingPathComponent("slack", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    try data.write(to: directory.appendingPathComponent("auth.json"), options: .atomic)
    return root
}

@Test
func slackSocketModeConfig_enablesHistoryFallbackWhenSettingIsAbsent() throws {
    let root = try makeSlackConfigRoot([
        "access_token": "xoxb-test",
        "socket_mode_app_token": "xapp-test",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let config = try #require(SlackSocketModeConfig.load(dataRoot: root))
    #expect(config.historyPollEnabled)
    #expect(config.historyPollInterval == 60)
}

@Test
func slackSocketModeConfig_respectsExplicitHistoryFallbackDisable() throws {
    let root = try makeSlackConfigRoot([
        "access_token": "xoxb-test",
        "socket_mode_app_token": "xapp-test",
        "history_poll_enabled": false,
        "history_poll_interval": 5,
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let config = try #require(SlackSocketModeConfig.load(dataRoot: root))
    #expect(config.historyPollEnabled == false)
    #expect(config.historyPollInterval == 30)
}

// MARK: - A4.8(a): session recycle must beat the watchdog

@Test
func slackSocketModeLoop_sessionRecycleStaysBelowTickWatchdog() {
    // The tick IS one long-lived socket session. The planned recycle has to
    // fire BEFORE the manager's tick watchdog, or every healthy hour-long
    // session gets booked as "timeout after 3900s" again (the hourly
    // failure-push incident this guards against).
    let loop = SlackSocketModeLoop(
        config: SlackSocketModeConfig(
            botToken: "xoxb-test",
            appToken: "xapp-test",
            botUserId: nil,
            teamId: nil,
            enabled: true,
            historyPollEnabled: false,
            historyPollInterval: 60,
            historyConversationRefreshInterval: 600,
            allowedChannelIds: [],
            allowedUserIds: []
        ),
        chatHandler: { _ in SlackSocketModeReply(text: "") }
    )
    let watchdog = loop.tickTimeoutOverride ?? 0
    #expect(watchdog == 3_900)
    #expect(loop.sessionRecycleInterval == 3_600)
    #expect(loop.sessionRecycleInterval < watchdog)
}
