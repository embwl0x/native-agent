import Foundation
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

// Blueprint: | `MacPointer.swift` | `MacMouseEvent`, `MacScrollEvent` and `AgentPointerHold`: pointer/scroll event values and bounded ownership restoring the person's cursor after agent input |

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

/// Unhook the person's mouse during agent pointer actions, then restore its cursor; held buttons defer release only up to `cap`.
enum AgentPointerHold {
    /// Idle time after her last pointer event that ends the action.
    static let settle: TimeInterval = 1.0
    /// The longest the person's mouse is ever unhooked for one action.
    static let cap: TimeInterval = 15

    private static let lock = NSLock()
    private nonisolated(unsafe) static var held = false
    private nonisolated(unsafe) static var generation = 0
    private nonisolated(unsafe) static var personPoint = CGPoint.zero
    private nonisolated(unsafe) static var agentPoint: CGPoint?
    private nonisolated(unsafe) static var buttonsDown = 0
    private nonisolated(unsafe) static var startedAt = 0.0
    private nonisolated(unsafe) static var lastPost = 0.0
    private nonisolated(unsafe) static var releaseTimer: DispatchSourceTimer?

    static var lastAgentPoint: CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        return agentPoint
    }

    /// Before her pointer event. Starting an action notes the person's cursor
    /// and unhooks their mouse; `warpTo` then puts the cursor on her point
    /// (a scroll is routed by where the cursor is). Returns where the cursor
    /// now is for her.
    @discardableResult
    static func begin(warpTo point: CGPoint?) -> CGPoint? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastPost = now
        guard !held else {
            scheduleReleaseLocked()
            let current = agentPoint
            lock.unlock()
            return current
        }
        guard let current = CGEvent(source: nil)?.location else { lock.unlock(); return nil }
        held = true
        generation &+= 1
        personPoint = current
        startedAt = now
        CGAssociateMouseAndMouseCursorPosition(0)
        if let point { CGWarpMouseCursorPosition(point) }
        let chain = generation
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.setEventHandler { releaseIfIdle(chain: chain) }
        releaseTimer = timer
        scheduleReleaseLocked()
        timer.resume()
        lock.unlock()
        return point ?? current
    }

    /// After her event: where her pointer is, and whether a button is down.
    /// Her pointer is shown there (Shotgun's overlay).
    static func posted(phase: MacMousePhase?, at point: CGPoint) {
        lock.lock()
        lastPost = ProcessInfo.processInfo.systemUptime
        agentPoint = point
        if phase == .down { buttonsDown += 1 }
        if phase == .up { buttonsDown = max(0, buttonsDown - 1) }
        scheduleReleaseLocked()
        lock.unlock()
        PersonOnlyWindows.noteAgentPointer(at: point, pressed: phase == .down)
    }

    /// Posts move the one deadline. A held button waits for its up event or
    /// the original cap; it never asks a timer whether the button is still down.
    private static func scheduleReleaseLocked() {
        guard held else { return }
        let due = buttonsDown > 0 ? startedAt + cap : min(startedAt + cap, lastPost + settle)
        releaseTimer?.schedule(deadline: .now() + max(0, due - ProcessInfo.processInfo.systemUptime))
    }

    /// The action is over: the person's cursor goes back and their mouse is
    /// hooked up again. A callback queued before a post re-arms only to the
    /// new exact deadline, never a sampling interval.
    private static func releaseIfIdle(chain: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard held, chain == generation else { lock.unlock(); return }
        let idle = now - lastPost
        if now - startedAt < cap, buttonsDown > 0 || idle < settle {
            scheduleReleaseLocked()
            lock.unlock()
            return
        }
        // Under the lock: a new action of hers can't begin between the
        // person's cursor going back and their mouse being hooked up again.
        held = false
        releaseTimer?.cancel()
        releaseTimer = nil
        buttonsDown = 0
        CGWarpMouseCursorPosition(personPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
        lock.unlock()
    }
}

#endif
