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

struct AttachmentChip: View {
    var attachment: MultimodalAttachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.type == "image" ? "photo" : "doc")
                .font(.caption2)
            Text(attachment.name ?? (attachment.type == "image" ? "image" : "file"))
                .font(.caption2)
                .lineLimit(1)
            if attachment.byteSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button { onRemove() } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// PATCH-2026-05-09: chat-ux-polish — Chat empty state with persona name + suggestion chips
struct ChatEmptyState: View {
    var personaName: String
    var onSuggestion: (String) -> Void

    private let suggestions = ["Plan my morning", "What's stuck?", "Run the audit"]

    var body: some View {
        VStack(spacing: NativeAgentSpacing.xl) {
            NativeEmptyState(
                title: "Say something to \(personaName)",
                detail: "Start with a goal, a question, or a task. Each session is kept separate and restored after restart.",
                systemImage: "bubble.left.and.bubble.right"
            )

            HStack(spacing: NativeAgentSpacing.sm) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onSuggestion(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(NativeAgentFont.label)
                            .padding(.horizontal, NativeAgentSpacing.md)
                            .padding(.vertical, NativeAgentSpacing.sm)
                            .glassEffect(.regular.interactive(), in: Capsule())  // Liquid Feel W2
                            .overlay(Capsule().strokeBorder(NativeAgentBrand.accent.opacity(0.25), lineWidth: 0.8))
                    }
                    .buttonStyle(.borderless)
                    .help("Pre-fill: \(suggestion)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One compact, shared composer action hierarchy for main and detached chat.
/// Voice, screen capture, and attachments remain first-class actions (and keep
/// their command-menu shortcuts), but no longer occupy three permanent buttons
/// beside every draft. Stop and Send stay immediately visible because they are
/// the live-turn controls whose timing matters.
struct MacChatComposerControlStrip<InputContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isListening: Bool
    let screenCaptureAllowed: Bool
    let screenCaptureDisabled: Bool
    let pendingAttachmentCount: Int
    let isRunning: Bool
    let canSend: Bool
    let onToggleVoice: () -> Void
    let onCaptureScreen: () -> Void
    let onAttach: () -> Void
    let onStop: () -> Void
    let onSend: () -> Void
    let inputContent: InputContent

    init(
        isListening: Bool,
        screenCaptureAllowed: Bool,
        screenCaptureDisabled: Bool,
        pendingAttachmentCount: Int,
        isRunning: Bool,
        canSend: Bool,
        onToggleVoice: @escaping () -> Void,
        onCaptureScreen: @escaping () -> Void,
        onAttach: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onSend: @escaping () -> Void,
        @ViewBuilder inputContent: () -> InputContent
    ) {
        self.isListening = isListening
        self.screenCaptureAllowed = screenCaptureAllowed
        self.screenCaptureDisabled = screenCaptureDisabled
        self.pendingAttachmentCount = pendingAttachmentCount
        self.isRunning = isRunning
        self.canSend = canSend
        self.onToggleVoice = onToggleVoice
        self.onCaptureScreen = onCaptureScreen
        self.onAttach = onAttach
        self.onStop = onStop
        self.onSend = onSend
        self.inputContent = inputContent()
    }

    private var optionsAccessibilityLabel: String {
        var parts = ["Message options"]
        if isListening { parts.append("voice input active") }
        if pendingAttachmentCount > 0 {
            parts.append("\(pendingAttachmentCount) attachment\(pendingAttachmentCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        GlassCard(tint: NativeAgentBrand.accent.opacity(0.2)) {
            HStack(alignment: .bottom, spacing: NativeAgentSpacing.sm) {
                Menu {
                    Button(action: onToggleVoice) {
                        Label(
                            isListening ? "Stop Listening" : "Voice Input",
                            systemImage: isListening ? "mic.fill" : "mic"
                        )
                    }

                    Button(action: onCaptureScreen) {
                        Label(
                            screenCaptureAllowed ? "Show Agent My Screen" : "Enable Screen Capture in Trust",
                            systemImage: "camera.viewfinder"
                        )
                    }
                    .disabled(screenCaptureDisabled)

                    Button(action: onAttach) {
                        Label("Attach Image or File…", systemImage: "paperclip")
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: isListening ? "mic.fill" : "plus.circle")
                            .foregroundStyle(isListening ? Color.red : Color.primary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())

                        if pendingAttachmentCount > 0 {
                            Text("\(pendingAttachmentCount)")
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(NativeAgentBrand.accent, in: Circle())
                                .offset(x: 6, y: -6)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Voice, screen capture, and attachments")
                .accessibilityLabel(optionsAccessibilityLabel)

                inputContent

                if isRunning {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(
                                Color.red.opacity(0.85),
                                in: RoundedRectangle(cornerRadius: NativeAgentRadius.control)
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop generation")
                    .accessibilityLabel("Stop generation")
                }

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(
                            canSend ? NativeAgentBrand.accentDeep : Color.secondary.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: NativeAgentRadius.control)
                        )
                        .foregroundStyle(canSend ? .white : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .animation(
                    NativeAgentMotion.respecting(NativeAgentMotion.snappy, reduceMotion: reduceMotion),
                    value: canSend
                )
                .help(isRunning ? "Queue message to send next" : "Send message")
                .accessibilityLabel(isRunning ? "Queue message to send next" : "Send message")
            }
        }
    }
}

// PATCH-2026-05-09: nextgen-surface — Horizontal row of suggested NextGen action chips above composer
struct NextGenActionChipsRow: View {
    var appModel: AppModel

    // Per-chip running state (actionId -> true while running)
    @State private var runningIds: Set<String> = []
    // Per-chip completed state (actionId -> timestamp) for checkmark flash
    @State private var completedIds: Set<String> = []

    private static let maxVisible = 4

    private var eligibleActions: [NextGenAction] {
        let all = appModel.nextGenSummary?.actions ?? []
        return all.filter {
            $0.dryRunAvailable == true && $0.status?.lowercased() != "completed"
                // W6 fix-round (gpt-5.5 BLOCKING): no chips for ids with no
                // executor — same rule the Capabilities panel now applies.
                && NativeClient.isNextGenActionBacked($0.id)
        }
    }

    private var visibleActions: [NextGenAction] {
        Array(eligibleActions.prefix(Self.maxVisible))
    }

    private var hasMore: Bool {
        eligibleActions.count > Self.maxVisible
    }

    var body: some View {
        let visible = visibleActions
        guard !visible.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NativeAgentSpacing.sm) {
                    ForEach(visible) { action in
                        NextGenChip(
                            action: action,
                            isRunning: runningIds.contains(action.id),
                            isCompleted: completedIds.contains(action.id)
                        ) {
                            guard !runningIds.contains(action.id) else { return }
                            runningIds.insert(action.id)
                            Task {
                                let succeeded = await appModel.runNextGenAction(id: action.id, dryRun: true)
                                await MainActor.run {
                                    runningIds.remove(action.id)
                                    if succeeded {
                                        completedIds.insert(action.id)
                                        // Flash checkmark for 2s then clear.
                                        Task {
                                            try? await Task.sleep(for: .seconds(2))
                                            completedIds.remove(action.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if hasMore {
                        Button {
                            NotificationCenter.default.post(name: .openNextGenRequest, object: nil)
                        } label: {
                            Text("More\u{2026}")
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, NativeAgentSpacing.sm)
                                .padding(.vertical, NativeAgentSpacing.xs)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.borderless)
                        .help("View all NextGen actions in Capabilities")
                    }
                }
            }
            .animation(NativeAgentMotion.gentle, value: visible.map { $0.id })
        )
    }
}

struct NextGenChip: View {
    var action: NextGenAction
    var isRunning: Bool
    var isCompleted: Bool
    var onTap: () -> Void

    private var chipIcon: String {
        switch action.kind?.lowercased() {
        case let k where k?.contains("build") == true || k?.contains("repair") == true:
            return "wrench.and.screwdriver"
        case let k where k?.contains("audit") == true || k?.contains("check") == true:
            return "doc.text.magnifyingglass"
        case let k where k?.contains("generate") == true || k?.contains("gen") == true:
            return "sparkles"
        default:
            return "play.fill"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: NativeAgentSpacing.xs) {
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else if isRunning {
                    PulsingDot(color: NativeAgentBrand.accent, size: 6, animates: true)
                } else {
                    Image(systemName: chipIcon)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                }
                Text(action.displayName.prefix(30))
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(isCompleted ? .green : .primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, NativeAgentSpacing.sm)
            .padding(.vertical, NativeAgentSpacing.xs)
            .glassEffect(.regular.interactive(), in: Capsule())  // Liquid Feel W2
            .overlay(
                Capsule()
                    .strokeBorder(
                        isCompleted ? Color.green.opacity(0.45) :
                        isRunning   ? NativeAgentBrand.accent.opacity(0.45) :
                                      Color.primary.opacity(0.10),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: isCompleted ? .green.opacity(0.15) : .clear, radius: 4)
        }
        .buttonStyle(.borderless)
        .disabled(isRunning || isCompleted)
        .help(action.displayDetail)
        .animation(NativeAgentMotion.snappy, value: isRunning)
        .animation(NativeAgentMotion.snappy, value: isCompleted)
    }
}

// PATCH-2026-05-06: multimodal-ui Sprint 3.4/3.5 — macOS NSView drop zone overlay for drag-drop
