import Foundation
import NativeAgentShared
import EngineRuntime
import DoctorChecks
// Blueprint: | `AppModel+HealthEmbeddings.swift` | `AppModel`, `loadHealthCard`, `setHealthCardIfMeaningfullyChanged`, `LatestRead`: Health publication |

@MainActor
extension AppModel {
    @MainActor
    func loadHealthCard() async {
        _ = await engine.doctor.healthCardRead.read({
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
            // The facade retains failure evidence for every approval surface.
            print("[NativeAgent] getApprovals failed: \(error)")
            setFailureStatus(error, action: "load approvals")
        }
    }

    /// Ignore the unrendered createdAt timestamp so unchanged health verdicts do not trigger full surface layouts.
    @MainActor
    func setHealthCardIfMeaningfullyChanged(_ next: HealthCard) {
        let current = engine.doctor.healthCard
        if current?.overall != next.overall || current?.subsystems != next.subsystems {
            engine.doctor.healthCard = next
        }
    }

}
