import AppKit
import Foundation
import ApplicationServices
import MacControl
import NativeAgentShared
import Senses
import Synchronization
// Blueprint: | `DesktopComposer.swift` | The compiled desktop routes' shared step failure, exact composer read and kept clipboard. |

/// The pieces the compiled desktop routes (`DesktopChatRoute`, the courier's fence, `DesktopRouteObservation`) share: a step's failure in the
/// person's words, the exact composer read, and the clipboard kept across a paste.
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
    static func copyPasteboard(_ pasteboard: NSPasteboard) throws -> [[(type: String, data: Data)]] {
        try (pasteboard.pasteboardItems ?? []).map { item in
            let checked = NSPasteboardItem()
            var copy: [(type: String, data: Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type), checked.setData(data, forType: type) else {
                    throw Failure(detail: "NativeAgent could not preserve the clipboard. Check the clipboard before continuing; nothing was submitted.")
                }
                copy.append((type.rawValue, data))
            }
            return copy
        }
    }
    /// Carry clipboard bytes across settlement, not AppKit objects shared between executors.
    static func restorePasteboard(_ saved: [[(type: String, data: Data)]], to pasteboard: NSPasteboard) -> Bool {
        var items: [NSPasteboardItem] = []
        for contents in saved {
            let item = NSPasteboardItem()
            for (type, data) in contents {
                guard item.setData(data, forType: NSPasteboard.PasteboardType(type)) else { return false }
            }
            items.append(item)
        }
        return pasteboard.writeObjects(items)
    }
}

/// Copy/import and desktop sends share the pasteboard until their own cleanup completes.
final class DesktopClipboard: Sendable {
    static let shared = DesktopClipboard()

    private struct State: Sendable {
        var held = false
        var waiters: [(UUID, ScopedWaiter)] = []
    }
    private let state = Mutex(State())

    @concurrent func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        let waiter = ScopedWaiter()
        let queued = state.withLock {
            if !$0.held { $0.held = true; return false }
            $0.waiters.append((id, waiter))
            return true
        }
        if queued { await waiter.park() }
        if Task.isCancelled {
            let next = state.withLock { state -> ScopedWaiter? in
                if let index = state.waiters.firstIndex(where: { $0.0 == id }) {
                    state.waiters.remove(at: index)
                    return nil
                }
                // A cancelled recipient passes on a slot already transferred to it.
                return Self.release(&state)
            }
            next?.resume()
            throw CancellationError()
        }
    }

    func release() {
        let next = state.withLock { Self.release(&$0) }
        next?.resume()
    }

    private static func release(_ state: inout State) -> ScopedWaiter? {
        guard !state.waiters.isEmpty else { state.held = false; return nil }
        return state.waiters.removeFirst().1
    }
}
