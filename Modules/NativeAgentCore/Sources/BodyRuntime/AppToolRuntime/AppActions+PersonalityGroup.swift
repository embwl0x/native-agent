import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+PersonalityGroup.swift` | Personality action declarations |

extension AppActions {
    static func personalityGroup() throws -> [AppAction] {
        try [
        .fold("get_persona_doc", "personality", read: true),
        .fold("persona_read", "personality", read: true, resultSchema: personaReadResultSchema),
        .fold("persona_write", "personality"),
        .fold("persona_append_section", "personality"),
        .fold("studio_journal", "personality"),
        .fold("studio_journal_amend", "personality"),
        .fold("studio_recall", "personality", "Recall studio journal entries and creative work; use memory.recall for saved facts and agreements", read: true),
        .fold("studio_consult", "personality"),
        .fold("studio_consult_read", "personality", read: true),
        .fold("studio_shelf_read", "personality", read: true),
        .fold("studio_shelf_set", "personality"),
        .fold("studio_canon", "personality", read: true),
        .fold("studio_canon_resolve", "personality"),
        .fold("dream_diary_read", "personality", read: true),
        ]
    }
}
