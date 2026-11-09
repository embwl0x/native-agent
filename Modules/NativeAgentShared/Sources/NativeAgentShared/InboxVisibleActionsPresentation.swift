import Foundation
// Blueprint: | `InboxVisibleActionsPresentation.swift` | Canonical native Inbox action filtering for finished body and renderer presentations |

public enum InboxVisibleActionsPresentation {
    private static let hiddenActionIDs: Set<String> = ["view", "read", "reply"]

    public static func actions(for item: InboxItemRecord) -> [InboxActionRecord] {
        guard !["archived", "dismissed"].contains(item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { return [] }
        var seen = Set<String>()
        return InboxActionVocabulary.actions(declared: item.actions, approvalLinked: item.related_approval_id?.isEmpty == false).compactMap { action in
            let id = InboxActionVocabulary.normalizedAction(action.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard InboxActionVocabulary.nativeActionIDs.contains(id), !hiddenActionIDs.contains(id),
                  !label.isEmpty, seen.insert(id).inserted else { return nil }
            return InboxActionRecord(id: id, label: label, description: action.description)
        }
    }
}
