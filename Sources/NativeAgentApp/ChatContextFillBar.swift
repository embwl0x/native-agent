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
import ProviderRouting
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

/// Values shown in the context strip. The strip is a readout, so an absent
/// provider figure must stay visibly absent instead of becoming a confident
/// zero. Keeping this at the rendering seam lets the UI and accessibility
/// label share that truth.
enum ContextFillPresentation {
    struct Usage: Equatable {
        let percent: Double
        let fillFraction: Double
        let isOverBudget: Bool
    }

    static func transcriptTokens(_ value: Int?) -> String {
        guard let value else { return "unknown" }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    static func usage(usedTokens: Int, budget: Int) -> Usage {
        let percent = budget > 0 ? (Double(usedTokens) / Double(budget)) * 100 : 0
        return Usage(
            percent: percent,
            fillFraction: min(1, max(0, percent / 100)),
            isOverBudget: budget > 0 && usedTokens > budget
        )
    }

    /// The status's own percent, which holds a previous model's receipt at
    /// 100% on the smaller window just switched to instead of reading 250%.
    static func usage(_ status: SessionContextStatus) -> Usage {
        let percent = status.budget > 0 ? status.percent : 0
        return Usage(
            percent: percent,
            fillFraction: min(1, max(0, percent / 100)),
            isOverBudget: percent > 100
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

    static func failureMessage(for result: CompactionResult) -> String? {
        guard !result.compacted else { return nil }
        let detail = result.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? result.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.flatMap { $0.isEmpty ? nil : $0 }
        return suffix.map { "Context compaction did not run: \($0)" }
            ?? "Context compaction did not run. Try again after the next context refresh."
    }
}

struct ContextFillBar: View {
    let sessionId: String
    typealias StatusLoader = @MainActor (String, String) async throws -> SessionContextStatus
    typealias CompactAction = @MainActor (String, String, String, Bool) async throws -> CompactionResult

    private let statusLoader: StatusLoader?
    private let compactAction: CompactAction?
    @Environment(AppModel.self) private var appModel
    @State private var status: SessionContextStatus? = nil
    @State private var isCompacting = false
    @State private var lastError: String? = nil
    @State private var lastErrorWasCompaction = false
    @State private var refreshToken = 0
    // Settings › Context window: a change re-sizes the window at once.
    @AppStorage("nativeagent.contextWindowMode") private var windowMode = ""
    @AppStorage("nativeagent.compactionThresholdTokens") private var windowSize = 0

    init(
        sessionId: String,
        statusLoader: StatusLoader? = nil,
        compactAction: CompactAction? = nil
    ) {
        self.sessionId = sessionId
        self.statusLoader = statusLoader
        self.compactAction = compactAction
    }

    private var usage: ContextFillPresentation.Usage {
        guard let status else { return .init(percent: 0, fillFraction: 0, isOverBudget: false) }
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
                    Text("\(formatExactTokens(s.used_tokens)) / \(formatExactTokens(s.budget))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(s.context_loaded == true ? .primary : .secondary)

                    HStack(spacing: 5) {
                        Text(s.context_loaded == true ? formatPercent(pct) : "estimate")
                            .foregroundStyle(
                                s.context_loaded == true
                                    ? fillColor
                                    : Color.secondary.opacity(0.55)
                            )
                        Text("chat \(ContextFillPresentation.transcriptTokens(s.transcript_tokens))")
                            .foregroundStyle(.tertiary)
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(formatExactTokens(s.auto_compact_threshold))
                            .foregroundStyle(.tertiary)
                        if let delta = s.turn_delta_tokens {
                            Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 7, weight: .bold))
                            Text(formatSignedTokens(delta))
                        }
                    }
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 220, alignment: .trailing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(contextAccessibilityLabel(s))
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary).frame(width: 220)
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
                let retryLabel = lastErrorWasCompaction
                    ? "Compaction failed. Retry"
                    : "Context status unavailable. Retry"
                Button {
                    Task { await refresh() }
                } label: {
                    Label(
                        lastErrorWasCompaction ? "Compaction failed" : "Context unavailable",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("\(retryLabel): \(lastError)")
                .accessibilityIdentifier("chat.context-fill.retry-button")
                .accessibilityLabel(retryLabel)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(status.map { contextHelp($0) } ?? "Loading context status…")
        .task(id: "\(sessionId):\(appModel.chatModel):\(refreshToken):\(windowMode):\(windowSize)") { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .chatTurnCompleted)) { note in
            if let completedSessionId = note.object as? String, completedSessionId != sessionId {
                return
            }
            refreshToken += 1
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .nativeAgentSessionProviderUsageDidChange)
        ) { note in
            guard let updatedSessionId = note.object as? String,
                  updatedSessionId == sessionId else {
                return
            }
            refreshToken += 1
        }
    }

    private func formatExactTokens(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    private func formatSignedTokens(_ n: Int) -> String {
        let sign = n >= 0 ? "+" : "-"
        return sign + formatExactTokens(abs(n))
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
        let usageDescription = s.context_loaded == true
            ? "Exact last provider request: \(s.used_tokens) of \(s.budget) input tokens. Stored transcript estimate: \(transcript); remainder after that estimate: \(prompt).\(deltaDescription)"
            : "No matching provider receipt yet. Transcript estimate: \(transcript) of your \(s.budget)-token window."
        return "\(usageDescription) Mode: \(mode). Compaction is based on reducible transcript growth and becomes available at \(s.auto_compact_threshold) transcript tokens. A lower provider-request count on a later turn does not by itself mean compaction occurred."
    }

    private func contextAccessibilityLabel(_ s: SessionContextStatus) -> String {
        let source = s.context_loaded == true ? "exact provider input" : "transcript estimate"
        return "Context: \(s.used_tokens) of \(s.budget) tokens, \(formatPercent(s.percent)), \(source). Stored chat \(ContextFillPresentation.transcriptTokens(s.transcript_tokens)) tokens; automatic compaction at \(s.auto_compact_threshold)."
    }

    @MainActor
    private func refresh() async {
        guard !sessionId.isEmpty else { status = nil; return }
        do {
            // Thread the current chat model through so the budget reflects
            // whatever context_length the live model has (e.g. 200k for
            // Opus 4.8, 128k for GPT-5.4-mini).
            let loaded: SessionContextStatus
            if let statusLoader {
                loaded = try await statusLoader(sessionId, appModel.chatModel)
            } else {
                loaded = try await appModel
                    .getSessionContext(sessionId: sessionId, model: appModel.chatModel)
            }
            // A conversation switched mid-read keeps the newer one's numbers.
            guard !Task.isCancelled else { return }
            status = loaded
            lastError = nil
            lastErrorWasCompaction = false
        } catch {
            lastError = error.localizedDescription
            lastErrorWasCompaction = false
        }
    }

    @MainActor
    private func compactNow() async {
        isCompacting = true; defer { isCompacting = false }
        lastError = nil
        lastErrorWasCompaction = false
        do {
            let result: CompactionResult
            if let compactAction {
                result = try await compactAction(
                    sessionId, appModel.chatModel, appModel.chatProvider, true
                )
            } else {
                result = try await appModel
                    .compactSession(
                        sessionId: sessionId,
                        model: appModel.chatModel,
                        providerID: appModel.chatProvider,
                        force: true
                    )
            }
            if let failure = ContextFillCompactionPresentation.failureMessage(for: result) {
                lastError = failure
                lastErrorWasCompaction = true
                return
            }
            await refresh()
        } catch {
            lastError = error.localizedDescription
            lastErrorWasCompaction = true
        }
    }
}

// PATCH-2026-05-08: wave3-health-card Feature A — always-visible health pill + popover

/// The small context readout on the composer row (User, 2026-09-16: "something
/// small that shows how much context is used"). A ring that fills as the
/// session's context fills, the percent beside it, exact tokens on hover.
/// Same status and the same refresh triggers as `ContextFillBar`; no
/// compaction control here — the row stays quiet.
struct ComposerContextRing: View {
    let sessionId: String
    /// A bot conversation's own model; nil is the chat model.
    var model: String? = nil
    private var windowModel: String { model ?? appModel.chatModel }
    @Environment(AppModel.self) private var appModel
    @State private var status: SessionContextStatus? = nil
    @State private var refreshToken = 0
    // Settings › Context window: a change re-sizes the window at once.
    @AppStorage("nativeagent.contextWindowMode") private var windowMode = ""
    @AppStorage("nativeagent.compactionThresholdTokens") private var windowSize = 0

    private var usage: ContextFillPresentation.Usage {
        guard let status else { return .init(percent: 0, fillFraction: 0, isOverBudget: false) }
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
        let budget = NumberFormatter.localizedString(from: NSNumber(value: status.budget), number: .decimal)
        return "Context: \(used) of \(budget) tokens (\(Int(usage.percent.rounded()))%)"
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
            if status != nil {
                Text("\(Int(usage.percent.rounded()))%")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .monospacedDigit()
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
        .task(id: "\(sessionId):\(windowModel):\(refreshToken):\(windowMode):\(windowSize)") { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .chatTurnCompleted)) { note in
            if let completed = note.object as? String, completed != sessionId { return }
            refreshToken += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeAgentSessionProviderUsageDidChange)) { note in
            guard let updated = note.object as? String, updated == sessionId else { return }
            refreshToken += 1
        }
    }

    private func refresh() async {
        guard !sessionId.isEmpty else { status = nil; return }
        let refreshed = try? await appModel.getSessionContext(sessionId: sessionId, model: windowModel)
        guard !Task.isCancelled else { return }
        status = refreshed
    }
}
