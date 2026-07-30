import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

// PATCH-2026-05-07: ui-polish ChatHeaderView — gradient agent name + aurora background
// PATCH-2026-05-09: nextgen-surface — NextGen status pill on the right side of header
struct ChatHeaderView: View {
    @Environment(AppModel.self) private var appModel
    var session: ChatSession?
    var compiled: CompiledPersonality?
    var context: ContextReceipt?
    var nextGenSummary: NextGenSummary? = nil
    @Binding var showContext: Bool
    @Binding var showConversationControls: Bool
    var onRename: (String) -> Void = { _ in }
    @State private var isRenamingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    private var nextGenPillColor: Color {
        switch nextGenSummary?.readinessStatus.lowercased() {
        case "ready":       return .green
        case "in_progress": return .orange
        case "planning":    return .blue
        default:            return .purple
        }
    }

    private var sessionTitle: String {
        // Display-derived title (preview fallback for untitled sessions);
        // rename drafts elsewhere keep comparing against the raw `title`.
        let title = session?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Chat" : title
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                headerTitle
                HStack(spacing: 4) {
                    let mc = session?.messageCount ?? 0
                    Text("\(mc) message\(mc == 1 ? "" : "s")")
                    if let source = session?.source {
                        Text("·")
                        Text(source == "app" ? "Mac app" : source.capitalized)
                    }
                    if let compiled {
                        Text("·")
                        Text(appModel.agentDisplayName)
                            .help("Persona fingerprint \(compiled.fingerprint) · Surface \(compiled.surface)")
                    }
                    if let fingerprint = context?.fingerprint {
                        Text("· Context ready")
                            .help("Context fingerprint \(fingerprint)")
                    }
                }
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            // NextGen status pill — shown only when currentPhaseName is available
            if let summary = nextGenSummary, let phaseName = summary.currentPhaseName ?? summary.currentPhaseId {
                let ready = summary.readyPhaseCount ?? 0
                let total = summary.totalPhaseCount ?? 0
                let tooltipDetail = total > 0
                    ? "Phase \(ready) of \(total) \u{00B7} \(summary.readinessStatus)"
                    : "NextGen \u{00B7} \(summary.readinessStatus)"
                Button {
                    NotificationCenter.default.post(name: .openNextGenRequest, object: nil)
                } label: {
                    Text("Phase \(phaseName)")
                        .font(NativeAgentFont.tag)
                        .padding(.horizontal, NativeAgentSpacing.sm)
                        .padding(.vertical, NativeAgentSpacing.xs)
                        .background(nextGenPillColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(nextGenPillColor)
                        .overlay(Capsule().strokeBorder(nextGenPillColor.opacity(0.35), lineWidth: 0.7))
                }
                .buttonStyle(.borderless)
                .help(tooltipDetail)
                .accessibilityLabel("NextGen status: \(tooltipDetail)")
            }

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    showConversationControls.toggle()
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(showConversationControls ? NativeAgentBrand.accentDeep : Color.secondary)
            .help(showConversationControls ? "Hide conversation settings" : "Conversation settings")
            .accessibilityLabel(showConversationControls ? "Hide conversation settings" : "Conversation settings")

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    showContext.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(showContext ? NativeAgentBrand.accentDeep : Color.secondary)
            .disabled(context?.fingerprint == nil)
            .help(showContext ? "Hide context receipt" : "Show context receipt")
            .accessibilityLabel(showContext ? "Hide context receipt" : "Show context receipt")
        }
        .onAppear {
            titleDraft = sessionTitle
        }
        .onChange(of: session?.id) { _, _ in
            if !isRenamingTitle {
                titleDraft = sessionTitle
            }
        }
        .onChange(of: session?.title) { _, _ in
            if !isRenamingTitle {
                titleDraft = sessionTitle
            }
        }
    }

    @ViewBuilder
    private var headerTitle: some View {
        if isRenamingTitle {
            TextField("Session name", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
                .font(NativeAgentFont.section)
                .frame(maxWidth: 420, alignment: .leading)
                .focused($titleFocused)
                .onSubmit {
                    commitTitleRename()
                }
                .onExitCommand {
                    cancelTitleRename()
                }
                .onChange(of: titleFocused) { _, focused in
                    if !focused && isRenamingTitle {
                        commitTitleRename()
                    }
                }
                .onAppear {
                    titleDraft = sessionTitle
                    DispatchQueue.main.async {
                        titleFocused = true
                    }
                }
        } else {
            HStack(spacing: 6) {
                Text(sessionTitle)
                .font(NativeAgentFont.section)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    beginTitleRename()
                }

                Button {
                    beginTitleRename()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(session == nil)
                .help("Rename session")
            }
        }
    }

    private func beginTitleRename() {
        guard session != nil else { return }
        titleDraft = sessionTitle
        isRenamingTitle = true
    }

    private func cancelTitleRename() {
        titleDraft = sessionTitle
        isRenamingTitle = false
    }

    private func commitTitleRename() {
        let cleanTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            cancelTitleRename()
            return
        }
        isRenamingTitle = false
        if cleanTitle != sessionTitle {
            onRename(cleanTitle)
        }
    }
}
