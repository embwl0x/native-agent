import Foundation
import Synchronization
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon) && os(macOS)
import Carbon
#endif

// Blueprint: | `MacPointer.swift` | `MacMouseEvent`, `MacScrollEvent`, `AgentPointerHold`: Input-owned pointer holds restore the person's cursor |

public enum MacMouseButton: String, Sendable, Equatable {
    case left
    case right
}

public enum MacMousePhase: String, Sendable, Equatable {
    case move
    case down
    case up
    case drag
}

public struct MacMouseEvent: Sendable, Equatable {
    public let phase: MacMousePhase
    public let button: MacMouseButton
    public let x: Double
    public let y: Double
    public let clickCount: Int
    public let modifiers: MacKeyModifiers

    public init(phase: MacMousePhase, button: MacMouseButton, x: Double, y: Double, clickCount: Int = 1, modifiers: MacKeyModifiers = []) {
        self.phase = phase
        self.button = button
        self.x = x
        self.y = y
        self.clickCount = clickCount
        self.modifiers = modifiers
    }
}

public enum MacScrollUnit: String, Sendable, Equatable {
    case line
    case pixel
}

public struct MacScrollEvent: Sendable, Equatable {
    public let deltaX: Int32
    public let deltaY: Int32
    public let unit: MacScrollUnit
    public let modifiers: MacKeyModifiers

    public init(deltaX: Int32, deltaY: Int32, unit: MacScrollUnit, modifiers: MacKeyModifiers = []) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.unit = unit
        self.modifiers = modifiers
    }
}

#if canImport(CoreGraphics) && os(macOS)

/// The emitted gesture holds the cursor until its buttons are released; move and scroll release when their post ends.
enum AgentPointerHold {
    private struct State {
        var held = false
        var personPoint = CGPoint.zero
        var agentPoint: CGPoint?
        var buttonsDown: Set<MacMouseButton> = []
    }
    private static let state = Mutex(State())

    static var lastAgentPoint: CGPoint? { state.withLock { $0.agentPoint } }

    @discardableResult
    static func begin(warpTo point: CGPoint?) -> CGPoint? {
        state.withLock {
            if $0.held { return $0.agentPoint }
            guard let current = CGEvent(source: nil)?.location else { return nil }
            $0.held = true
            $0.personPoint = current
            CGAssociateMouseAndMouseCursorPosition(0)
            if let point { CGWarpMouseCursorPosition(point) }
            return point ?? current
        }
    }

    static func posted(phase: MacMousePhase?, button: MacMouseButton? = nil, at point: CGPoint, emitted: Bool) {
        state.withLock {
            if emitted { $0.agentPoint = point }
            if emitted, let button {
                if phase == .down { $0.buttonsDown.insert(button) }
                if phase == .up { $0.buttonsDown.remove(button) }
            }
            guard $0.held, $0.buttonsDown.isEmpty else { return }
            $0.held = false
            CGWarpMouseCursorPosition($0.personPoint)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if emitted { PersonOnlyWindows.noteAgentPointer(at: point, pressed: phase == .down) }
    }
}

#endif
