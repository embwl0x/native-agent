import Foundation
import CommandPalette
import MacAssistantStatus
import PersonaEngine
import ApprovalInbox
import TrustCenter
import SelfImprovement

extension RuntimeReadProjection {
    public static func makeCommandPaletteContext(
        macAssistantStatusClient: any MacAssistantStatusClient
    ) async -> CommandPaletteContext {
        // Persona name: read profile.json directly via the non-isolated static
        // so we don't need to spin up a PersonaCompiler actor + cross the
        // boundary just to grab one string.
        let personaName = PersonaCompiler.agentDisplayName()

        // Pending-approval count via SwiftNativeApprovalInbox. Keep this call
        // best-effort: a failure here just means the count badge defaults to 0.
        var approvalsCount = 0
        let inbox = makeApprovalInbox()
        do {
            let pending = try await inbox.list(filter: .pending)
            approvalsCount = pending.count
        } catch {
            NSLog("[CommandPalette] approval inbox count failed: \(error.localizedDescription) — defaulting to 0")
        }

        // enableAutonomy from SwiftNativeTrustCenter. Missing/corrupt authority
        // stays false so a status projection never depicts autonomy as ready
        // while the canonical policy is unavailable.
        var enableAutonomy = false
        // loadTrustPolicy is on the SwiftNative actor — instantiate directly
        // (its init uses PersistenceCore.defaultDataRoot()). We always want the
        // Swift loader here.
        let trust = SwiftNativeTrustCenter()
        let policy = await trust.loadTrustPolicy()
        if case .bool(let b) = policy["enableAutonomy"] {
            enableAutonomy = b
        }

        // improvementFailedCount via SwiftNativeSelfImprovement. The local
        // summary reads runs.json directly via PersistenceCore, so the
        // Best-effort: any failure leaves the count at 0 (the
        // self-improvement-scoreboard entry stays "ready").
        var improvementFailedCount = 0
        let selfImprov = SwiftNativeSelfImprovement()
        do {
            let summary = try await selfImprov.improvementSummaryLocal()
            improvementFailedCount = summary.failedCount ?? 0
        } catch {
            NSLog("[CommandPalette] self-improvement summary failed: \(error.localizedDescription) — defaulting to 0")
        }

        let macAssistant = macAssistantStatusClient
        let macAssistantProjection: (status: String, templateAttentionCount: Int)
        do {
            let result = try await macAssistant.macAssistantStatus(lightweight: true)
            let status = result.status.trimmingCharacters(in: .whitespacesAndNewlines)
            if status.isEmpty || result.templateAttentionCount < 0 {
                NSLog("[CommandPalette] mac assistant status was invalid — presenting unavailable")
                macAssistantProjection = ("unavailable", 0)
            } else {
                macAssistantProjection = (status, result.templateAttentionCount)
            }
        } catch {
            NSLog("[CommandPalette] mac assistant status failed: \(error.localizedDescription) — presenting unavailable")
            macAssistantProjection = ("unavailable", 0)
        }

        return CommandPaletteContext(
            personaName: personaName,
            telegramHealthStatus: "optional",
            connectorNeedsProof: false,
            macAssistantStatus: macAssistantProjection.status,
            macAssistantTemplateAttentionCount: macAssistantProjection.templateAttentionCount,
            foundryReviewCount: 0,
            // Mirror approvalsCount into the Python autonomy.counts.pendingApprovals
            // slot so the `approvals` entry's badge stays correct even without
            // an autonomy_command_center_summary port.
            pendingApprovalsCount: approvalsCount,
            skillDraftCount: 0,
            multimodalStatus: "ready",
            enableAutonomy: enableAutonomy,
            improvementFailedCount: improvementFailedCount
        )
    }
}
