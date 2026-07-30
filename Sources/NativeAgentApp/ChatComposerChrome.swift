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
                            .background(.ultraThinMaterial, in: Capsule())
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

// PATCH-2026-05-09: chat-ux-polish — Thinking indicator shown in composer area while waiting
struct ChatThinkingRow: View {
    var personaName: String
    var onStop: () -> Void

    var body: some View {
        GlassCard(tint: NativeAgentBrand.accent) {
            HStack(spacing: NativeAgentSpacing.sm) {
                PulsingDot(color: NativeAgentBrand.accent, size: 7, animates: true)
                Text("\(personaName) is thinking\u{2026}")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onStop()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel generation")
            }
        }
    }
}

// PATCH-2026-05-09: chat-ux-polish — Compact meta row above composer: persona / model / reasoning
struct ComposerMetaRow: View {
    var appModel: AppModel

    var body: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            Image(systemName: "person.crop.circle")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.tertiary)
            Text(appModel.agentDisplayName)
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)

            Text("\u{2022}")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.quaternary)

            Image(systemName: "cpu")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.tertiary)
            Text(modelDisplayName(appModel.chatModel))
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !appModel.chatReasoningEffort.isEmpty {
                Text("\u{2022}")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.quaternary)
                Text(effortDisplayName(appModel.chatReasoningEffort))
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    /// Prefer the provider catalog's display name ("Claude Fable 5") over
    /// the raw id; fall back to prefix-trimming for models the catalog
    /// doesn't know.
    private func modelDisplayName(_ id: String) -> String {
        for provider in appModel.providersList {
            if let model = provider.models.first(where: { $0.id == id }) {
                let name = model.name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return shortModelName(id)
    }

    /// "xhigh" → "XHigh" (matches the Brain bar's tier labels); other tiers
    /// plain-capitalize.
    private func effortDisplayName(_ raw: String) -> String {
        raw.lowercased() == "xhigh" ? "XHigh" : raw.capitalized
    }

    private func shortModelName(_ model: String) -> String {
        // Trim common long prefixes for display compactness
        let replacements: [(String, String)] = [
            ("gpt-", "GPT-"),
            ("claude-", "Claude "),
            ("openai/", ""),
            ("anthropic/", ""),
        ]
        var result = model
        for (prefix, replacement) in replacements {
            if result.hasPrefix(prefix) {
                result = replacement + result.dropFirst(prefix.count)
                break
            }
        }
        return result
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
            .background(.ultraThinMaterial, in: Capsule())
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
