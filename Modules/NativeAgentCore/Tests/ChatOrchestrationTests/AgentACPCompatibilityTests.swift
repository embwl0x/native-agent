import Testing
import NativeAgentCore

@Suite struct AgentACPCompatibilityTests {
    @Test(arguments: ["0.46.0", "v0.46.0", "0.46.0\n"])
    func knownGeminiSandboxStdinBugIsActionableBeforeLaunch(version: String) throws {
        let line = try #require(AgentHostACP.byHostID["gemini-cli"])
        let reason = try #require(line.startupBlocker(installedVersion: version))
        #expect(reason.contains("#23959"))
        #expect(reason.contains("Nothing ran"))
        #expect(reason.contains("reconnect"))
        #expect(line.arguments.contains("--sandbox"))
        #expect(line.environment["SANDBOX"] == nil)
    }

    @Test func unknownVersionsAndOtherAgentsAreNotGuessedIncompatible() throws {
        let gemini = try #require(AgentHostACP.byHostID["gemini-cli"])
        for version in [nil, "", "0.46.1", "0.60.0", "0.46.0-custom"] as [String?] {
            #expect(gemini.startupBlocker(installedVersion: version) == nil)
        }
        for id in ["hermes", "goose", "cursor-cli"] {
            let line = try #require(AgentHostACP.byHostID[id])
            #expect(line.startupBlocker(installedVersion: "0.46.0") == nil)
        }
    }
}
