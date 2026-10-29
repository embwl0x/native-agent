import SwiftUI
import AppKit
import CoreGraphics
import ScreenVision
import UniformTypeIdentifiers
import NativeAgentShared
import ChatSessionWork
import MemoryV2
import PersistenceCore
import ProviderRouting

// Blueprint: | `ChatContextFillBar.swift` | `ContextFillPresentation` and context strip/ring: measured usage, model window and compaction controls; missing figures stay visibly unavailable |

/// Values shown in the context strip. The strip is a readout, so an absent
/// provider figure must stay visibly absent instead of becoming a confident
/// zero. Keeping this at the rendering seam lets the UI and accessibility
/// label share that truth.
enum ContextFillPresentation {
    struct Usage: Equatable {
        let percent: Double
        let fillFraction: Double
    }

    /// The window's size; 0 is a window no catalog row states, never a size.
    static func window(_ budget: Int) -> String? {
        budget > 0 ? NumberFormatter.localizedString(from: NSNumber(value: budget), number: .decimal) : nil
    }

    static func transcriptTokens(_ value: Int?) -> String {
        guard let value else { return "unknown" }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    static func roundedPercent(_ value: Double) -> String {
        guard value.isFinite else { return "unavailable" }
        return String(format: "%.0f%%", value.rounded())
    }

    /// The status's own percent, which holds a previous model's receipt at
    /// 100% on the smaller window just switched to instead of reading 250%.
    static func usage(_ status: SessionContextStatus) -> Usage {
        let percent = status.budget > 0 ? status.percent : 0
        return Usage(
            percent: percent,
            fillFraction: min(1, max(0, percent / 100))
        )
    }
}

enum ContextFillCompactionPresentation {
    enum ButtonState: Equatable {
        case hidden
        case ready
        case compacting
    }

    static func buttonState(
        status: SessionContextStatus?,
        isCompacting: Bool
    ) -> ButtonState {
        guard status?.compactable == true else { return .hidden }
        return isCompacting ? .compacting : .ready
    }

    static func failureMessage(for result: ChatSessionCompactionOutcome) -> String? {
        guard !result.compacted else { return nil }
        let detail = result.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? nil : detail
        return suffix.map { "Context compaction did not run: \($0)" }
            ?? "Context compaction did not run. Try again after the next context refresh."
    }
}

struct ContextFillBar: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel
    private var status: SessionContextStatus? { appModel.engine.providers.sessions[sessionId]?.context }
    @State private var isCompacting = false
    @State private var compactionError: String? = nil
    private var lastError: String? { compactionError ?? appModel.engine.providers.sessions[sessionId]?.error }

    private var usage: ContextFillPresentation.Usage {
        guard let status else { return .init(percent: 0, fillFraction: 0) }
        return ContextFillPresentation.usage(status)
    }
    private var pct: Double { usage.percent }
    private var compactButtonState: ContextFillCompactionPresentation.ButtonState {
        ContextFillCompactionPresentation.buttonState(status: status, isCompacting: isCompacting)
    }
    private var fillColor: Color {
        if pct >= 80 { return .red }
        if pct >= 60 { return .orange }
        if pct >= 40 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Bar — capsule with proportional fill
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fillColor.opacity(0.85))
                        .frame(width: geo.size.width * usage.fillFraction)
                        .animation(NativeAgentMotion.standard, value: pct)
                }
            }
            .frame(height: 6)

            if let s = status {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(formatExactTokens(s.used_tokens)) / \(ContextFillPresentation.window(s.budget) ?? "window unknown")")
                        .font(ShellType.captionCodeSemibold)
                        .foregroundStyle(s.context_loaded == true ? .primary : .secondary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        if s.budget > 0 {
                            Text(s.context_loaded == true ? formatPercent(pct) : "estimate")
                                .foregroundStyle(
                                    s.context_loaded == true
                                        ? fillColor
                                        : NativeAgentShell.secondary
                                )
                        }
                        Text("chat \(ContextFillPresentation.transcriptTokens(s.transcript_tokens))")
                            .foregroundStyle(NativeAgentShell.secondary)
                        Image(systemName: "rectangle.compress.vertical")
                            .font(ShellType.captionSemibold)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .accessibilityHidden(true)
                        Text(formatExactTokens(s.auto_compact_threshold))
                            .foregroundStyle(NativeAgentShell.secondary)
                        if let delta = s.turn_delta_tokens {
                            Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(ShellType.captionSemibold)
                            Text(formatSignedTokens(delta))
                        }
                    }
                    .font(ShellType.captionCode)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 280, alignment: .trailing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(contextAccessibilityLabel(s))
            } else {
                Text("—").font(ShellType.captionCode).foregroundStyle(.tertiary).frame(width: 280)
            }

            // Compact-now button when the runtime says transcript reduction is
            // meaningful. Its accessibility identity stays stable while its
            // visible state explains whether a request is in flight.
            if compactButtonState != .hidden {
                Button {
                    Task { await compactNow() }
                } label: {
                    if compactButtonState == .compacting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "rectangle.compress.vertical")
                    }
                }
                .buttonStyle(.borderless)
                .help(
                    compactButtonState == .compacting
                        ? "Compacting older messages into a summary…"
                        : "Compact older messages into a summary so the rest of the context window is free."
                )
                .disabled(compactButtonState == .compacting)
                .accessibilityIdentifier("chat.context-fill.compact-button")
                .accessibilityLabel(
                    compactButtonState == .compacting ? "Compacting context" : "Compact context now"
                )
                .accessibilityValue(
                    compactButtonState == .compacting ? "In progress" : "Available"
                )
            }

            if let lastError {
                let retryCompaction = compactionError != nil
                let retryLabel = retryCompaction
                    ? "Compaction failed. Retry"
                    : "Context status unavailable. Retry"
                Button {
                    Task {
                        if retryCompaction {
                            await compactNow()
                        } else {
                            await refresh()
                        }
                    }
                } label: {
                    Label(
                        retryCompaction ? "Compaction failed" : "Context unavailable",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .disabled(isCompacting)
                .help("\(retryLabel): \(lastError)")
                .accessibilityIdentifier("chat.context-fill.retry-button")
                .accessibilityLabel(retryLabel)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(status.map { contextHelp($0) } ?? "Loading context status…")
        .modifier(ComposerSessionRefresh(sessionID: sessionId))
    }

    private func formatExactTokens(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    private func formatSignedTokens(_ n: Int) -> String {
        (n >= 0 ? "+" : "") + formatExactTokens(n)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: value < 10 ? "%.2f%%" : "%.1f%%", value)
    }

    private func contextHelp(_ s: SessionContextStatus) -> String {
        let mode = s.context_mode ?? "none"
        let prompt = s.prompt_tokens ?? 0
        let transcript = s.transcript_tokens ?? 0
        let deltaDescription = s.turn_delta_tokens.map {
            " Change from the preceding turn's final provider request: \(formatSignedTokens($0)) tokens."
        } ?? ""
        let window = s.budget > 0 ? "your \(s.budget)-token window" : "a window no catalog states for this model"
        let usageDescription = s.context_loaded == true
            ? "Exact last provider request: \(s.used_tokens) input tokens of \(window). Stored transcript estimate: \(transcript); remainder after that estimate: \(prompt).\(deltaDescription)"
            : "No matching provider receipt yet. Transcript estimate: \(transcript) tokens of \(window)."
        return "\(usageDescription) Mode: \(mode). Compaction is based on reducible transcript growth and becomes available at \(s.auto_compact_threshold) transcript tokens. A lower provider-request count on a later turn does not by itself mean compaction occurred."
    }

    private func contextAccessibilityLabel(_ s: SessionContextStatus) -> String {
        let source = s.context_loaded == true ? "exact provider input" : "transcript estimate"
        let fill = s.budget > 0 ? "of \(s.budget) tokens, \(formatPercent(s.percent))" : "tokens, window unknown"
        return "Context: \(s.used_tokens) \(fill), \(source). Stored chat \(ContextFillPresentation.transcriptTokens(s.transcript_tokens)) tokens; automatic compaction at \(s.auto_compact_threshold)."
    }

    @MainActor
    private func refresh() async {
        await appModel.engine.providers.refreshSession(sessionId)
    }

    @MainActor
    private func compactNow() async {
        guard !isCompacting else { return }
        isCompacting = true; defer { isCompacting = false }
        compactionError = nil
        do {
            let result = try await appModel.compactSession(
                sessionId: sessionId,
                model: status?.model,
                providerID: appModel.engine.providers.sessions[sessionId]?.choice?.provider,
                force: true
            )
            if let failure = ContextFillCompactionPresentation.failureMessage(for: result) {
                compactionError = failure
                return
            }
            await refresh()
        } catch {
            compactionError = UserFacingError.cause(error, action: "compact this chat")
        }
    }
}

/// Read-only context ring over the same engine-owned session context as ContextFillBar.
struct ComposerContextRing: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel
    private var status: SessionContextStatus? { appModel.engine.providers.sessions[sessionId]?.context }

    private var usage: ContextFillPresentation.Usage {
        guard let status else { return .init(percent: 0, fillFraction: 0) }
        return ContextFillPresentation.usage(status)
    }

    private var ringColor: Color {
        let pct = usage.percent
        if pct >= 80 { return .red.opacity(0.85) }
        if pct >= 60 { return .orange.opacity(0.85) }
        return NativeAgentShell.secondary
    }

    private var helpText: String {
        guard let status else { return "Context used this conversation" }
        let used = NumberFormatter.localizedString(from: NSNumber(value: status.used_tokens), number: .decimal)
        guard let window = ContextFillPresentation.window(status.budget) else { return "Context: \(used) tokens; window unknown" }
        return "Context: \(used) of \(window) tokens (\(ContextFillPresentation.roundedPercent(usage.percent)))"
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(NativeAgentShell.hairline, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: usage.fillFraction)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(NativeAgentMotion.standard, value: usage.fillFraction)
            }
            .frame(width: 11, height: 11)
            if let status, status.budget > 0 {
                Text(ContextFillPresentation.roundedPercent(usage.percent))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .monospacedDigit()
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }
}
