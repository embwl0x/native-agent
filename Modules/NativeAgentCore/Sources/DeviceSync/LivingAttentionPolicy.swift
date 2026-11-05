import CognitiveSubstrate

// Blueprint: | `LivingAttentionPolicy.swift` | `LivingAttentionPolicy.organismNeedsAttention`; Desk owns needs-person attention. |

/// Body trouble is shared by both surfaces; Desk's WorkOverviewRead owns needs-person attention.
public enum LivingAttentionPolicy {
    public static func organismNeedsAttention(_ organism: OrganismSnapshot) -> Bool {
        guard organism.enabled else { return false }
        let body = organism.bodySchema
        return !body.providersHealthy
            || !body.toolHandsAvailable
            || body.notificationPathHealthy == false
            || !body.iPhoneReachable
            || !body.memoryHealthy
            || !body.dreamHealthy
            || !body.approvalChannelsOpen
    }
}
