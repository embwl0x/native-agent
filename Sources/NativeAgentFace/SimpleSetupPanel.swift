import AppKit
import Foundation
import SwiftUI
import NativeAgentShared

// Blueprint: | `SimpleSetupPanel.swift` | Setup hosts hold conversation-bound return verification, cancellation and dismissible feedback |

// A setup page opens in place in Simple and Advanced alike; Simple hosts the connector wizard over chat, Advanced in a sheet.

extension View {
    func inlineCardSetup(_ cards: CardControls, sessionID: String, active: Bool = true) -> some View {
        modifier(InlineCardSetupPresentation(cards: cards, sessionID: sessionID, active: active))
    }
}

struct InlineCardSetupPresentation: ViewModifier {
    let cards: CardControls
    let sessionID: String
    let active: Bool
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @State private var requests: [Verification] = []
    @State private var operation: Task<Void, Never>?
    @State private var issues: [Issue] = []
    @State private var windowProbe = NSView()

    private struct Scope: Equatable {
        let session: String
        let active: Bool
    }
    private struct Verification: Identifiable {
        let id = UUID()
        let identity: CardIdentity
    }
    private struct Issue: Identifiable {
        let id = UUID()
        let message: String
    }
    private var scope: Scope { .init(session: sessionID, active: active && !quietOffscreenRead && !sessionID.isEmpty) }

    func body(content: Content) -> some View {
        let simple = appModel.face.slot(.settings).select("viewMode.simple", as: SettingsFace.self) {
            $0?.preferences[SimpleViewMode.key] == .string(SimpleViewMode.simple)
        }
        let panelOpen = simple && cards.connectorSheet != nil
        content
            .disabled(panelOpen)
            .overlay {
                if panelOpen, let request = cards.connectorSheet {
                    SimpleSetupPanel(showsClose: false) {
                        closeConnector()
                    } content: {
                        ConnectorWizardView(provider: request.provider) {
                            closeConnector()
                        }
                    }
                    .onChange(of: appModel.face.slot(.settings).value(as: SettingsFace.self)) {
                        requestVerification()
                    }
                }
            }
            .sheet(item: Binding(
                get: { simple ? nil : cards.connectorSheet },
                set: { if $0 == nil { closeConnector() } }
            )) { request in
                ConnectorWizardView(provider: request.provider) {
                    closeConnector()
                }
                .environment(appModel)
            }
            .overlay(alignment: .top) { verificationFeedback }
            .background(CardReturnWindow(view: windowProbe).frame(width: 0, height: 0))
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard let window = note.object as? NSWindow, window === windowProbe.window else { return }
                requestVerification()
            }
            .onChange(of: scope, initial: true) {
                endVerification()
                requestVerification()
            }
            .onDisappear { endVerification() }
            .task(id: requests.first?.id) {
                guard let request = requests.first else { return }
                // Join a departed request before assigning the next host operation.
                await operation?.value
                guard !Task.isCancelled, scope.active, requests.first?.id == request.id else { return }
                let running = Task { await verify(request) }
                operation = running
                defer {
                    if requests.first?.id == request.id { requests.removeFirst(); operation = nil }
                }
                await withTaskCancellationHandler { await running.value } onCancel: { running.cancel() }
            }
    }

    @ViewBuilder
    private var verificationFeedback: some View {
        if scope.active, !requests.isEmpty || !issues.isEmpty {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                if !requests.isEmpty {
                    HStack {
                        Text("Checking setup…").font(ShellType.label)
                        Button("Cancel", role: .cancel) { cancelVerification() }
                    }
                }
                ForEach(issues) { issue in
                    Text(issue.message).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble).textSelection(.enabled)
                        .accessibilityIdentifier("chat.card.verification-failure")
                    Button("Dismiss") { issues.removeAll { $0.id == issue.id } }
                }
            }
            .padding()
            .background(NativeAgentShell.room, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
    }

    private func requestVerification() {
        guard scope.active else { return }
        let identities = cards.pendingReturn(in: sessionID)
        requests.append(contentsOf: identities.map { Verification(identity: $0) })
    }
    private func verify(_ request: Verification) async {
        do { try await cards.verify(request.identity, appModel: appModel) }
        catch {
            guard !Task.isCancelled, requests.first?.id == request.id else { return }
            issues.append(.init(message: "Couldn't verify this setup. " + TurnSecretRedactor.redactText(error.localizedDescription)))
        }
    }
    private func cancelVerification() {
        operation?.cancel()
        requests.removeAll()
    }
    private func endVerification() {
        cancelVerification()
        issues.removeAll()
    }
    private func closeConnector() {
        cards.connectorSheetClosed()
        requestVerification()
    }
}

private struct CardReturnWindow: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SimpleSetupPanel<Content: View>: View {
    var showsClose = true
    let close: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static var radius: CGFloat { 22 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        ZStack {
            // Disable background chat and dim it 35% so text behind glass cannot compete with the panel.
            Color.black.opacity(0.35).ignoresSafeArea()
            content
                .frame(maxWidth: 760)
                .clipShape(shape)
                .overlay(alignment: .topTrailing) {
                    if showsClose {
                        Button(action: close) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .sheetCloseButton()
                        .padding(12)
                    }
                }
                // Full pages need an opaque room fill so chat text cannot show through their content.
                .background { shape.fill(NativeAgentShell.room) }
                .glassEffect(reduceTransparency ? .identity : HouseGlass.plate, in: shape)
                .padding(32)
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
