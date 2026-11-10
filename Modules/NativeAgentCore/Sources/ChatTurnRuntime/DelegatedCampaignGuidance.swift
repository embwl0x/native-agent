// Blueprint: | `DelegatedCampaignGuidance.swift` | `DelegatedCampaignGuidance`; Delegated campaign guidance; Trust retains authority |

/// Guidance applies only to already-delegated campaigns; Trust, approval, dispatch and domain verification remain authoritative.
enum DelegatedCampaignGuidance {
    static let acceptedFinding = """
        - DELEGATED CAMPAIGN: Reversible follow-through on outcomes you own or delegate is authorized until independently verified complete. File, \
        route, recover and advance accepted findings without asking whether to continue, dispatch or verify.
        """

    static let authorityCheckpoint = """
        - AUTHORITY: Decide and act; explain what and why. Ask through the canonical approval path only for the person's decision: higher Trust or \
        permissions, macOS security settings, credentials, physical presence, publication or release in their name, or irreversible loss of their \
        things.
        """

    static let deskConvergence = """
        - DESK: An exact item ends on the person's explicit instruction, which records that instruction without claiming the work happened, or when \
        fresh canonical evidence independently proves that exact outcome. Similar titles, completed execution or unattributed commits are \
        insufficient. Without exact mapping and independent proof, it stays open; name the missing evidence.
        """

    static let rendered = acceptedFinding + "\n" + deskConvergence + "\n" + authorityCheckpoint
}
