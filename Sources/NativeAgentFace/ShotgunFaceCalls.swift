import AppKit
import NativeAgentShared
// Blueprint: | `ShotgunFaceCalls.swift` | Reverse-call owners for renderer step-aside, driving feedback and operation-held pointer passage |

@MainActor
extension ShotgunController {
    func installCalls(on router: FaceCallRouter, client: PipeFaceClient) {
        connect(client: client)
        router.register({ [weak self] call in
            guard let self else { throw FaceWireError.disconnected }
            switch call {
            case .stepAside(let driver):
                try await self.stepAsideForScreen(driver: driver)
            case .toggleShotgun:
                self.toggle()
            case .agentHandsMoved(let driver):
                try await self.handsMoved(driver)
            case .agentPointerMoved(let presentation):
                try await self.showPointer(presentation)
            case .passPointerThrough(let operation, let x, let y, let driver):
                try self.preparePointer(operation: operation, at: CGPoint(x: x, y: y), driver: driver)
            case .restorePointerInteraction(let operation):
                try RendererProtection.shared.restorePointer(operation: operation)
            case .waitForKeyboard:
                try await RendererProtection.shared.waitForKeyboard()
            default: return nil
            }
            return .acknowledged
        }, disconnect: { [weak self] in self?.disconnect() })
    }
}
