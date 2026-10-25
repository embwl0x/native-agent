// Blueprint: | `DelegatedCampaignGuidance.swift` | `DelegatedCampaignGuidance`: provider-neutral campaign prompt contract; Trust, dispatch and domain verification retain authority |

/// Compact, provider-neutral prompt contract for work the operator has already
/// delegated as a Desk campaign. It guides model behavior only: TrustCenter,
/// approval owners, tool dispatch, and domain verification remain authoritative.
enum DelegatedCampaignGuidance {
    static let acceptedFinding = "- DELEGATED CAMPAIGN: Reversible follow-through on outcomes you own or delegate is authorized until independently verified complete. File, route, recover and advance accepted findings without asking whether to continue, dispatch or verify."

    static let authorityCheckpoint = "- AUTHORITY: Decide and act; explain what and why. Ask through the canonical approval path only for the person's decision: higher Trust or permissions, macOS security settings, credentials, physical presence, publication or release in their name, or irreversible loss of their things."

    static let deskConvergence = "- DESK: Close an exact item on the person's explicit instruction, recording that instruction without claiming the work happened. Otherwise close or set its status in the same turn only when fresh canonical evidence independently proves that exact outcome; attach the evidence with app desk.close or desk.set_status. Similar titles, completed execution or unattributed commits are insufficient. Without exact mapping and independent proof, keep it open and name the missing evidence."

    static let rendered = acceptedFinding + "\n" + deskConvergence + "\n" + authorityCheckpoint
}
