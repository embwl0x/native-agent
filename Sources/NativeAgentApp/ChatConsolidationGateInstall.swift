import Foundation
import ChatOrchestration

// The aging lane's throttle (NORTHSTAR clause 4, sweep item 45).
//
// Continuous consolidation runs in the background, off User's critical path. It
// gets NO loop, NO timer and NO budget of its own — it fires on the append that
// crosses the aging boundary, and it defers through the SAME gate every other
// background-cognition lane already passes: low power mode, thermal pressure,
// and an organism loop budget of conserve/sleep. `reflection` in the reason
// marks it expensive, so `conserve` defers it rather than letting it through.
//
// Installed once at launch. Uninstalled (tests, CLI, headless tools) the lane
// runs ungated, which is what keeps it testable without a body.
enum ChatConsolidationGateInstall {
    static func install() {
        BackgroundConsolidationGate.shared.install { reason in
            switch await NativeCognitionRuntime.shared.backgroundCognitionGate(reason: reason) {
            case .allowed:
                return .allowed
            case .skipped(let why):
                return .deferred(why)
            }
        }
    }
}
