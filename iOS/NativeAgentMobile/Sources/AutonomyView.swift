import SwiftUI

/// Self-improvement is managed on the Mac.
struct AutonomyView: View {
    var body: some View {
        AlivePage(title: "Self-Improvement", line: "Changes to how I work.") {
            AliveCalmState(
                title: "On your Mac",
                line: "Review self-improvement on your Mac. Dream and REM settings live in Trust."
            )
        }
    }
}
