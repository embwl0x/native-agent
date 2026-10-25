import CognitiveSubstrate

// Blueprint: | `LivingAttentionPolicy.swift` | `LivingAttentionPolicy.organismNeedsAttention`: shared body-attention projection for Mac and phone; Desk owns needs-person attention |

/// "Is her body in trouble?", as the Mac's living status panel and the
/// phone's living-status snapshot both read it. "Does she need User?" is the
/// Desk overview's Needs you (OwnerAttentionPolicy through WorkOverviewRead).
public enum LivingAttentionPolicy {
    public static func organismNeedsAttention(_ organism: OrganismSnapshot) -> Bool {
        guard organism.enabled else { return false }
        let body = organism.bodySchema
        return !body.providersHealthy
            || !body.toolHandsAvailable
            || !body.notificationPathHealthy
            || !body.iPhoneReachable
            || !body.memoryHealthy
            || !body.dreamHealthy
            || !body.approvalChannelsOpen
    }
}
