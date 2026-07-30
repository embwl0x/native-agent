import Testing
@testable import SlackConnector

@Test func slackConnectorActionsCompileSmoke() {
    #expect(String(describing: SlackConnectorActions.self).contains("SlackConnectorActions"))
}
