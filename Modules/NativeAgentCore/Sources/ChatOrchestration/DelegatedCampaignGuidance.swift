/// Compact, provider-neutral prompt contract for work the operator has already
/// delegated as a Desk campaign. It guides model behavior only: TrustCenter,
/// approval owners, tool dispatch, and domain verification remain authoritative.
enum DelegatedCampaignGuidance {
    static let acceptedFinding = "- DELEGATED CAMPAIGN: Once the user delegates an outcome through Desk, Claude, or Codex, reversible follow-through is authorized end-to-end. Treat an accepted campaign finding as work to file, route, recover, verify, and advance until independently verified done — never pause to ask whether to file it, keep going, dispatch the next step, or verify it."

    static let authorityCheckpoint = "- AUTHORITY CHECKPOINT: Stop and escalate only for a genuine operator-only boundary: an approval; an irreversible, destructive, or consequential external action; credentials, TCC, or physical presence; spending or a public commitment; or a real taste/scope decision after reversible work is exhausted. Use the canonical approval path when available, preserve every safety gate, and ask only for the missing authority or decision."

    static let rendered = acceptedFinding + "\n" + authorityCheckpoint
}
