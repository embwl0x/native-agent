import AppKit
import Foundation
import NativeAgentShared
// Blueprint: | `FaceReports.swift` | Ordered scene and Inspector reports from renderer lifecycle events |

@MainActor
final class FaceReports {
    static let shared = FaceReports()
    private weak var client: PipeFaceClient?
    private var events: AsyncStream<FaceAct>.Continuation?
    private var publication: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var scene: SceneReport?
    private var inspector: RendererInspectorReport?
    var connectionID: UUID? { client?.connectionID }

    func connect(_ client: PipeFaceClient) {
        guard events == nil else { return }
        self.client = client
        let (stream, events) = AsyncStream<FaceAct>.makeStream()
        self.events = events
        publication = Task { [weak client] in
            for await event in stream {
                guard !Task.isCancelled, let client else { return }
                do { try await client.act(event).checkedAcknowledgement() }
                catch is CancellationError { return }
                catch { ApplicationLifetime.shared.appModel?.setFailureStatus(error, action: "report the window state") }
            }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in FaceReports.shared.sceneChanged() }
            })
        }
        sceneChanged()
    }
    func submit(_ act: FaceAct) {
        guard let events else { return }
        switch act {
        case .reportScene(let value):
            guard scene != value else { return }
            scene = value
        case .reportInspector(let value):
            guard inspector != value else { return }
            inspector = value
        default: break
        }
        events.yield(act)
    }
    func sceneChanged() {
        if let report = ApplicationLifetime.shared.scene { submit(.reportScene(report)) }
    }
    func disconnect() async {
        events?.finish(); events = nil
        let closing = publication
        closing?.cancel()
        await closing?.value
        publication = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        client = nil
        scene = nil; inspector = nil
    }
}
