import Foundation
import NativeAgentShared
import EngineRuntime
import DoctorChecks
// Blueprint: | `AppModel+HealthEmbeddings.swift` | `AppModel`: `loadHealthCard`, `setHealthCardIfMeaningfullyChanged`; the Doctor owner's `LatestRead` orders health-card publication |

@MainActor
extension AppModel {
    @MainActor
    func loadHealthCard() async {
        _ = await engine.doctor.healthCardRead.read({
        // Failed health reads publish their error as the health verdict.
        let nextHealthCard: HealthCard
        do {
            nextHealthCard = try await AppDoctorPort(dataRoot: engine.dataRoot, backgroundLoopsManager: backgroundLoopsManager).runtime.getHealthCard()
        } catch {
            print("[NativeAgent] loadHealthCard failed: \(error)")
            nextHealthCard = HealthCard(
                overall: "error",
                subsystems: [
                    HealthCardSubsystem(
                        id: "runtime",
                        label: "Runtime",
                        status: "error",
                        detail: UserFacingError.message(error, action: "run the health check"),
                        fixAction: "doctor"
                    )
                ],
                createdAt: nil
            )
        }
        return nextHealthCard
        }, publish: { setHealthCardIfMeaningfullyChanged($0) })
        guard !Task.isCancelled else { return }
        do {
            _ = try await engine.approvals.list()
        } catch {
            guard !Task.isCancelled else { return }
            // The facade keeps the last read and exposes its failure to
            // every approval surface.
            print("[NativeAgent] getApprovals failed: \(error)")
            setFailureStatus(error, action: "load approvals")
        }
    }

    /// The live health poll intentionally runs while chat is visible, but its
    /// `createdAt` timestamp is not rendered anywhere. Treating that timestamp
    /// as UI state forced a complete health-surface layout every 15 seconds even
    /// when every visible verdict was identical.
    @MainActor
    func setHealthCardIfMeaningfullyChanged(_ next: HealthCard) {
        let current = engine.doctor.healthCard
        if current?.overall != next.overall || current?.subsystems != next.subsystems {
            engine.doctor.healthCard = next
        }
    }

}
