import Testing
@testable import SlackConnector

@Test func slackConnectorActionsCompileSmoke() {
    #expect(String(describing: SlackConnectorActions.self).contains("SlackConnectorActions"))
}

@Test func jsonRequestsDeclareUTF8ToAvoidSlackCharsetWarnings() {
    #expect(SlackConnectorActions.jsonContentType == "application/json; charset=utf-8")
}
