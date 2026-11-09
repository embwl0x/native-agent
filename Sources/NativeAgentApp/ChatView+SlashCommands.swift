import EngineRuntime
import Foundation
import ToolRegistry
import SwiftUI
import NativeAgentShared
import ChatSessionWork
import PersistenceCore
import Dispatcher
import AppToolRuntime
import Connectors
import ChatToolRuntime
// Blueprint: | `ChatView+SlashCommands.swift` | Body-owned slash command commits for provider choice, memory, notes and scratch |

extension AppModel: ChatSlashCommandHost {
    var chatSlashReasoningEfforts: [String] {
        QuietComposerCommands.Routing(appModel: self).efforts.map(\.id)
    }
    func stageChatSlashBrain() { _ = enqueueChatBrainDefaultsSave() }
    func saveChatSlashBrain() async -> String { await saveChatBrainDefaults().userMessage }
    func rememberChatSlashFact(_ text: String) async -> (succeeded: Bool, message: String) {
        let result = await addMemoryFact(text)
        return (result.succeeded, result.userMessage)
    }
    func commitChatSlashNote(_ text: String) async -> (succeeded: Bool, message: String) {
        let result = await addNote(text)
        return (result.succeeded, result.userMessage)
    }
    func writeChatSlashScratch(key: String, value: String, sessionId: String) async -> (succeeded: Bool, message: String) {
        let result = await writeScratch(key: key, value: value, sessionId: sessionId)
        return (result.succeeded, result.userMessage)
    }
}
