import Foundation
import ApplicationServices
import MacNerves
import NativeAgentShared
import SenseCore
import AppKit
// Blueprint: | `DesktopComposer.swift` | The compiled desktop routes' shared step failure and exact composer read. |

/// The pieces the compiled desktop routes (`DesktopChatRoute`, the courier's fence, `DesktopRouteObservation`) share: a step's failure in the
/// person's words and the exact composer read.
enum DesktopComposer {
    struct Failure: Error, LocalizedError {
        let detail: String
        /// The observed step it stopped at, in the person's words, when a step gave up.
        let step: String?
        init(detail: String, step: String? = nil) { self.detail = detail; self.step = step }
        var errorDescription: String? { detail }
    }
    static func observationFailure(_ error: Error, operation: String) -> Failure {
        let reason = (error as? SenseFailure)?.message ?? error.localizedDescription
        let remedy = (error as? SenseFailure)?.code == "source_denied"
            ? "Allow NativeAgent Accessibility access in System Settings → Privacy & Security → Accessibility, then continue."
            : "Bring the app forward with its Accessibility tree available, then continue."
        return Failure(detail: "Accessibility observation \(operation): \(reason) \(remedy)")
    }
    nonisolated static func composerValue(mac: MacOperationContext, _ node: AXUIElement) throws -> String {
        guard let value = MacAXAttributeRead.copyRaw(node, kAXValueAttribute, context: mac) as? String else {
            throw Failure(detail: "The exact message box text could not be read through Accessibility. Its draft was left untouched; nothing was typed.")
        }
        return value
    }
}
