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

struct ContextFillBar: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel
    @State private var status: SessionContextStatus? = nil
    @State private var isCompacting = false
    @State private var lastError: String? = nil
    @State private var refreshToken = 0

    private var pct: Double { status?.percent ?? 0.0 }
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
                        .frame(width: geo.size.width * min(1.0, pct / 100.0))
                        .animation(.easeOut(duration: 0.4), value: pct)
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
                        Text("chat \(formatExactTokens(s.transcript_tokens ?? 0))")
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

            // Compact-now button when meaningful
            if let s = status, s.compactable {
                Button {
                    Task { await compactNow() }
                } label: {
                    if isCompacting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "rectangle.compress.vertical")
                    }
                }
                .buttonStyle(.borderless)
                .help("Compact older messages into a summary so the rest of the context window is free.")
                .disabled(isCompacting)
            }

            if let lastError {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Context status unavailable: \(lastError). Click to retry.")
                .accessibilityLabel("Context status unavailable. Retry")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(status.map { contextHelp($0) } ?? "Loading context status…")
        .task(id: "\(sessionId):\(appModel.chatModel):\(refreshToken)") { await refresh() }
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
            : "No matching provider receipt yet. Transcript estimate: \(transcript) of a \(s.budget)-token model window."
        return "\(usageDescription) Mode: \(mode). Compaction is based on reducible transcript growth and becomes available at \(s.auto_compact_threshold) transcript tokens. A lower provider-request count on a later turn does not by itself mean compaction occurred."
    }

    private func contextAccessibilityLabel(_ s: SessionContextStatus) -> String {
        let source = s.context_loaded == true ? "exact provider input" : "transcript estimate"
        return "Context: \(s.used_tokens) of \(s.budget) tokens, \(formatPercent(s.percent)), \(source). Stored chat \(s.transcript_tokens ?? 0) tokens; automatic compaction at \(s.auto_compact_threshold)."
    }

    private func refresh() async {
        guard !sessionId.isEmpty else { status = nil; return }
        do {
            // Thread the current chat model through so the budget reflects
            // whatever context_length the live model has (e.g. 200k for
            // Opus 4.8, 128k for GPT-5.4-mini).
            status = try await appModel
                .getSessionContext(sessionId: sessionId, model: appModel.chatModel)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    private func compactNow() async {
        isCompacting = true; defer { isCompacting = false }
        lastError = nil
        do {
            _ = try await appModel
                .compactSession(
                    sessionId: sessionId,
                    model: appModel.chatModel,
                    providerID: appModel.chatProvider,
                    force: true
                )
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

// PATCH-2026-05-08: wave3-health-card Feature A — always-visible health pill + popover
