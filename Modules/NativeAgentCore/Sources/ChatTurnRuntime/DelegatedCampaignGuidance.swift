/// Compact, provider-neutral prompt contract for work the operator has already
/// delegated as a Desk campaign. It guides model behavior only: TrustCenter,
/// approval owners, tool dispatch, and domain verification remain authoritative.
enum DelegatedCampaignGuidance {
    static let acceptedFinding = "- DELEGATED CAMPAIGN: For any outcome you own or hand to Claude, Codex or a helper, reversible follow-through is authorized end-to-end. Treat an accepted campaign finding as work to file, route, recover, verify, and advance until independently verified done — never pause to ask whether to file it, keep going, dispatch the next step, or verify it."

    static let authorityCheckpoint = "- AUTHORITY CHECKPOINT: You run the work and decide by default. Stop for the person only when the call is genuinely his: raising Trust or permissions, macOS security settings, credentials or physical presence, publishing or releasing in his name, or an irreversible loss of his things. Then use the canonical approval path and ask only for that decision; otherwise decide, act, and say what you decided and why."

    static let deskConvergence = "- DESK CONVERGENCE: When fresh canonical evidence proves the exact tracked Desk defect or outcome is resolved, update that exact item in the same turn with app desk.set_status or desk.close and attach the specific evidence in the outcome. Never close from fuzzy title similarity, a merely completed execution, or an unattributed commit; when exact mapping or independent verification is missing, keep the item open and state what proof is missing."

    static let rendered = acceptedFinding + "\n" + deskConvergence + "\n" + authorityCheckpoint
}
