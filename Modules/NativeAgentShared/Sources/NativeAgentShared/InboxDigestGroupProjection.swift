import Foundation

// Blueprint: | `InboxDigestGroupProjection.swift` | `InboxDigestGroups`: read-only structured inbox groups; historical prose remains text |

public enum InboxDigestGroups {
    public static func groups(item: InboxItemRecord, allItems: [InboxItemRecord]) -> [InboxRelatedGroup] {
        item.related_groups ?? []
    }
}

