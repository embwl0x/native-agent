import NativeAgentShared
import AppKit
import AppToolRuntime
import NativeAgentCore
import SwiftUI

// Blueprint: | `ShotgunPointer.swift` | `AgentPointerOverlay`: noninteractive pointer and fades; excluded from agent captures |

// Keep the agent pointer noninteractive and out of captures; AgentPointerHold restores the person's cursor.

@MainActor
final class AgentPointerOverlay {
    static let size = NSSize(width: 180, height: 44)
    static let lingers: Duration = .seconds(3)

    private var panel: NSPanel?
    private let model = AgentPointerModel()
    private var fadeTask: Task<Void, Never>?

    /// Use CGEvent space so the overlay lands on the same screen coordinates as the action.
    func show(at point: CGPoint, pressed: Bool, name: String) {
        let panel = makePanel()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Align the drawn tip with the event point at the panel's top-left.
        let origin = NSPoint(x: point.x - 2, y: primaryHeight - point.y - Self.size.height + 2)
        model.name = name
        if pressed { model.presses &+= 1 }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if panel.isVisible, panel.alphaValue > 0.01, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(origin)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrameOrigin(origin)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            PersonOnlyWindows.setOverlay(number: panel.windowNumber)
        }
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.lingers)
            guard !Task.isCancelled else { return }
            self?.fade()
        }
    }

    func fade() {
        fadeTask?.cancel()
        fadeTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: ShotgunController.animationCompletion {
            guard panel.alphaValue < 0.01 else { return }
            panel.orderOut(nil)
            PersonOnlyWindows.setOverlay(number: nil)
        })
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.sharingType = .readOnly  // Exclude by window number only from agent captures; preserve human recordings.
        panel.contentView = NSHostingView(rootView: AgentPointerView(model: model))
        self.panel = panel
        return panel
    }
}

@MainActor
@Observable
private final class AgentPointerModel {
    var name = ""
    var presses = 0
}

private struct AgentPointerView: View {
    let model: AgentPointerModel
    @AppStorage(HazeColor.storageKey) private var hazeRaw = HazeColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Restart the ring for each click even when the prior pulse has finished.
    @State private var pulse = true

    var body: some View {
        let haze = HazeColor(stored: hazeRaw)
        HStack(alignment: .top, spacing: 2) {
            ZStack(alignment: .topLeading) {
                Circle()
                    .stroke(haze.base.opacity(pulse ? 0 : 0.7), lineWidth: 2)
                    .frame(width: 26, height: 26)
                    .scaleEffect(pulse ? 1.4 : 0.3)
                    .offset(x: -11, y: -11)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(haze.base)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
            .frame(width: 18, height: 22, alignment: .topLeading)
            if !model.name.isEmpty {
                Text(model.name)
                    .font(ShellType.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(haze.base.opacity(0.85), in: Capsule())
                    .padding(.top, 14)
            }
        }
        .padding(.leading, 2)
        .padding(.top, 2)
        .frame(width: AgentPointerOverlay.size.width, height: AgentPointerOverlay.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: model.presses) { _, _ in
            guard !reduceMotion else { return }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { pulse = false }
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.45)) { pulse = true }
            }
        }
    }
}
