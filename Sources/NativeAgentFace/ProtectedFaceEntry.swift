import AppKit
import SwiftUI
import Observation
import NativeAgentShared
// Blueprint: | `ProtectedFaceEntry.swift` | Credential-sheet content appears only after its actual window is excluded by the body |

struct ProtectedFaceEntry<Content: View>: View {
    private final class WindowRef { weak var window: NSWindow? }
    private let content: () -> Content
    @State private var ready = false
    @State private var failure: String?
    @State private var admission: Task<Void, Never>?
    @State private var entryID = UUID()
    @State private var host = WindowRef()

    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        ZStack {
            if ready, RendererProtection.shared.isConnected { content() }
            else if let failure { Text(failure).padding(24).textSelection(.enabled) }
            else { ProgressView("Protecting credential entry…").padding(24) }
        }
        .macFaceStyle()
        .background(ProtectedEntryWindow { window in protect(window) })
        .onChange(of: RendererProtection.shared.isConnected) {
            if RendererProtection.shared.isConnected { protect(host.window) }
            else { admission?.cancel(); ready = false }
        }
        .onDisappear {
            admission?.cancel(); admission = nil; ready = false
            RendererProtection.shared.releaseEntry(entryID)
            host.window = nil
        }
    }

    private func protect(_ window: NSWindow?) {
        host.window = window
        admission?.cancel()
        RendererProtection.shared.releaseEntry(entryID)
        let entryID = UUID()
        self.entryID = entryID
        ready = false
        failure = nil
        guard let window else { admission = nil; return }
        admission = Task { @MainActor in
            do {
                try await RendererProtection.shared.holdEntry(window: window, id: entryID)
                try Task.checkCancellation()
                ready = true
            } catch is CancellationError { return }
            catch { failure = "Credential entry could not be protected. " + error.localizedDescription }
        }
    }
}

extension AppModel {
    func protectedFormAct(_ act: FaceAct) async throws -> FaceActReply {
        let reply = try await client.protectedAct(act)
        switch reply {
        case .failed(let failure), .refused(let failure): throw failure
        default: return reply
        }
    }
}

private struct ProtectedEntryWindow: NSViewRepresentable {
    let changed: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: Host, context: Context) { view.changed = changed }

    final class Host: NSView {
        var changed: (@MainActor (NSWindow?) -> Void)?
        private weak var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard observedWindow !== window else { return }
            observedWindow = window
            let changed = changed, window = window
            Task { @MainActor in changed?(window) }
        }
    }
}

/// Authored pages can name only their Keychain receiver; no page call carries the secret.
private struct AuthoredSecretForm: View {
    let block: PartFace.Block
    @Environment(AppModel.self) private var appModel
    @State private var session = FacePageSession()
    var body: some View {
        if let receiver = block.receiver, receiver.hasPrefix("keyring:") {
            ProtectedFaceEntry {
                FaceProtectedForm(face: PartFace(sections: [.init(id: block.key, rows: [], block: block)]),
                    receiver: .keyring(String(receiver.dropFirst("keyring:".count))), session: session) { input in
                    do {
                        guard let ownedPage = block.secretPage, let field = block.fields?.first, let secret = input.secrets[field.id] else {
                            throw WireFailure(code: "secret_unconfirmed", message: "Read this page's saved secret status before another submission.",
                                cause: nil, effects: input.submission.checking ? .unknown : .none)
                        }
                        let submission = input.submission
                        let request = PageActRequest(page: ownedPage, row: block.key, action: submission.action, value: nil,
                            expectedRevision: submission.formRevision, expectedCall: submission.expectedCall, operation: submission.id)
                        if submission.checking {
                            return try FaceActOutcome.reply(await appModel.protectedFormAct(.readCredential(.keyring(request, secret: secret))))
                        }
                        let reply = try await appModel.protectedFormAct(.savePageSecret(request, secret: secret))
                        return try FaceActOutcome.reply(reply)
                    } catch { return .interrupted(error) }
                }
            }
        } else { Text("This form has no keyring receiver.").foregroundStyle(.secondary) }
    }
}

extension View {
    func authoredSecretEntry(page: String) -> some View {
        environment(\.faceProtectedEntry, { block in AnyView(AuthoredSecretForm(block: block).id(page + "/" + block.key)) })
    }
}
