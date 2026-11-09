import AppKit
import Foundation
import NativeAgentShared
// Blueprint: | `FaceCallRouter.swift` | Renderer reverse calls: cancellable sheets, owner presentations and the applied-frame page capture callback |

@MainActor
final class FaceCallRouter {
    typealias Handler = @MainActor (FaceCall) async throws -> FaceReply?
    typealias PageImage = @MainActor (PageRenderRequest) async throws -> PageRenderResult

    private let client: PipeFaceClient
    private let pageImage: PageImage
    private let showWindow: @MainActor (FaceDestination?) async throws -> FaceReply
    private var handlers: [Handler] = []
    private var disconnectHandlers: [@MainActor () -> Void] = []
    private var connected = true
    private struct AlertPresentation {
        let alert: NSAlert
        let host: NSWindow?
        let continuation: CheckedContinuation<NSApplication.ModalResponse, Error>
    }
    private var alerts: [UUID: AlertPresentation] = [:]

    init(client: PipeFaceClient, pageImage: @escaping PageImage,
         showWindow: @escaping @MainActor (FaceDestination?) async throws -> FaceReply) {
        self.client = client; self.pageImage = pageImage; self.showWindow = showWindow
    }

    /// Each presentation owner registers its calls and releases its local resources on disconnection.
    func register(_ handler: @escaping Handler, disconnect: @escaping @MainActor () -> Void) {
        handlers.append(handler)
        disconnectHandlers.append(disconnect)
    }

    func reply(to call: FaceCall) async -> FaceReply {
        do {
            try Task.checkCancellation()
            guard connected else { throw FaceWireError.disconnected }
            switch call {
            case .showMainWindow(let destination): return try await showWindow(destination)
            case .renderPage(let request):
                try client.requireApplied(request)
                return .rendered(try await pageImage(request))
            case .presentFailure(let title, let detail):
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = title
                alert.informativeText = detail
                _ = try await present(alert)
                return .acknowledged
            case .confirmMissingRoots(let paths):
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "NativeAgent cannot find its data."
                alert.informativeText = paths.joined(separator: "\n\n")
                    + "\n\nContinuing starts with what is named above, and anything missing is created empty."
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Continue Anyway")
                return .confirmed(try await present(alert) == .alertSecondButtonReturn)
            case .closeRenderer:
                // Application termination follows the reply's pipe write, owned by PipeFaceClient.
                return .acknowledged
            default:
                for handler in handlers {
                    if let reply = try await handler(call) { return reply }
                }
                return .refused(.init(code: "face_call_unmounted", message: "This window has no mounted owner for the requested presentation.",
                                      cause: nil, effects: .none))
            }
        } catch is CancellationError { return .cancelled }
        catch let failure as WireFailure { return .failed(failure) }
        catch {
            return .failed(.init(code: "face_call_failed", message: "The window could not complete the requested presentation.",
                                 cause: error.localizedDescription, effects: .unknown))
        }
    }

    func disconnect() {
        guard connected else { return }
        connected = false
        for id in Array(alerts.keys) { dismiss(id) }
        for release in disconnectHandlers { release() }
        handlers.removeAll(); disconnectHandlers.removeAll()
    }

    private func present(_ alert: NSAlert) async throws -> NSApplication.ModalResponse {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard connected else { throw FaceWireError.disconnected }
            return try await withCheckedThrowingContinuation { continuation in
                let parent: NSWindow
                let host: NSWindow?
                if let window = NSApp.keyWindow { parent = window; host = nil }
                else {
                    parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
                        styleMask: [.titled], backing: .buffered, defer: false)
                    parent.isReleasedWhenClosed = false
                    parent.title = "NativeAgent"
                    parent.center()
                    parent.makeKeyAndOrderFront(nil)
                    host = parent
                }
                alerts[id] = AlertPresentation(alert: alert, host: host, continuation: continuation)
                alert.beginSheetModal(for: parent) { [weak self] response in
                    guard let shown = self?.alerts.removeValue(forKey: id) else { return }
                    shown.host?.close()
                    shown.continuation.resume(returning: response)
                }
            }
        } onCancel: { Task { @MainActor in self.dismiss(id) } }
    }

    private func dismiss(_ id: UUID) {
        guard let shown = alerts.removeValue(forKey: id) else { return }
        if let parent = shown.alert.window.sheetParent { parent.endSheet(shown.alert.window, returnCode: .cancel) }
        shown.alert.window.orderOut(nil)
        shown.host?.close()
        shown.continuation.resume(throwing: CancellationError())
    }
}
