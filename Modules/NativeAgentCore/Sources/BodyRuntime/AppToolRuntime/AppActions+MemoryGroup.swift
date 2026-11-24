import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+MemoryGroup.swift` | Memory action declarations |

extension AppActions {
    static func memoryGroup() throws -> [AppAction] {
        try [
        .fold("recall_memory", "memories", "Recall saved facts, decisions and preferences; use studio.recall for journal entries",
              subject: ["memory_id"], read: true, advisory: true),
        // Version-exempt: it appends a new memory; supersedes demotes the ids it names, which a repeat leaves demoted.
        .fold("commit_memory", "memories", versionExempt: true),
        .fold("memory_proposals_pending", "memories", read: true),
        .fold("memory_proposal_review", "memories"),
        .fold("forget_memory", "memories", irreversible: true),
        .fold("search_kg", "memories", read: true),
        .fold("rebuild_knowledge_graph", "memories"),
        .fold("scratchpad_read", "chat", read: true),
        ]
    }
}
