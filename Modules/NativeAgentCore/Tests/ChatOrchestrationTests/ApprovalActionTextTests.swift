import Foundation
import Testing
@testable import ChatOrchestration
import StandingBots

@Test func approvalActionTextKeepsSpecificReasonsAndHidesInternalFields() {
    #expect(ApprovalActionText.reason("autonomy=send_approval", tool: "calendar_event_create") == "Allow me to use calendar event create?")
    #expect(ApprovalActionText.reason("Possible hidden instructions were found.", tool: "shell") == "Possible hidden instructions were found.")
    for key in ["__session_id", "session_id", "id", "ids", "bot_id", "sessionId"] {
        #expect(ApprovalActionText.isInternalField(key))
    }
    #expect(!ApprovalActionText.isInternalField("name"))
}

@Test func approvalBotDeletionNamesTheStoredBot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotDefinitionStore(dataRoot: root)
    let bot = try store.create(BotDefinition(name: "Pulse", brief: "Read notes", cadence: .manual,
                                            budget: BotBudget(tokens: 500, seconds: 30)))
    let text = await SwiftToolDispatcher(dataRoot: root).approvalCardReason(
        tool: "bot_delete", input: ["id": .string(bot.id.uuidString)], surface: "chat")
    #expect(text == "Delete the bot Pulse? Its saved notes stay.")
    #expect(try store.get(bot.id).name == "Pulse")
}
