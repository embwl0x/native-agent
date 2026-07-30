// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

extension CognitionObservatoryView {

    /// Read-only felt-MODE chip (U3, 2026-07-09): the aboutness beneath the fingerprint's
    /// words — what her current felt state is ABOUT, not how strong it is. Derived from the
    /// same signals the fingerprint reads; shown only when a mode is genuinely dominant, so
    /// an absent chip means "no single aboutness," never "broken." Purely observational —
    /// it changes no capsule text and drives nothing.
    @ViewBuilder
    private func feltModeChip(_ mode: CognitiveSubstrate.FeltMode) -> some View {
        // Name the thing on screen: a bare "seeking" beside a capsule reads as a label
        // for the capsule. "Felt mode · seeking" says whose state this is and what kind.
        Label("Felt mode · \(mode.rawValue) — \(Self.feltModeGloss(mode))", systemImage: "scope")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, NativeAgentSpacing.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .accessibilityLabel("Felt mode: \(mode.rawValue), \(Self.feltModeGloss(mode))")
    }

    /// Plain-language gloss per mode — the chip has to mean something to a reader who
    /// has never opened CognitiveSubstrate+FeltFingerprint.swift.
    private static func feltModeGloss(_ mode: CognitiveSubstrate.FeltMode) -> String {
        switch mode {
        case .seeking:     return "reaching toward something"
        case .care:        return "tending to someone"
        case .play:        return "loose and enjoying it"
        case .repair:      return "trying to put something right"
        case .bracing:     return "braced for what's coming"
        case .grief:       return "carrying a loss"
        case .frustration: return "blocked, and it stings"
        }
    }

    func capsule(
        _ capsule: CognitiveCapsule?,
        info: CapsulePreviewInfo?,
        feltMode: CognitiveSubstrate.FeltMode?
    ) -> some View {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                if let feltMode { feltModeChip(feltMode) }
                // Provenance: is this the capsule Agent actually received last turn,
                // or a synthetic stand-in shown before any chat injection? Without
                // this caption the panel reads as frozen when chat is quiet.
                if let info {
                    switch info.source {
                    case .liveInjected:
                        Text(liveInjectedCaption(info))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    case .synthetic:
                        Label("No live chat injection yet this session — synthetic preview.", systemImage: "wand.and.stars")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let capsule {
                    Text(capsule.combined)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("No capsule preview.")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private func liveInjectedCaption(_ info: CapsulePreviewInfo) -> String {
        var caption = "Last injected to chat"
        if let at = info.at {
            caption += " · \(at.formatted(date: .omitted, time: .shortened))"
        }
        if let message = info.userMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            let snippet = message.truncated(to: 60)
            caption += " · for: “\(snippet)”"
        }
        return caption
    }

    @ViewBuilder
    func reflections(_ reflections: [CognitiveReflectionReceipt]) -> some View {
            if reflections.isEmpty {
                Text("No reflection receipts.")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    ForEach(Array(reflections.prefix(6)), id: \.id) { receipt in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(receipt.request.reason)
                                .font(.caption.weight(.semibold))
                            Text(receipt.resultSummary)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text("\(receipt.request.model) via \(receipt.provider)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("tokens \(receipt.estimatedPromptTokens + receipt.estimatedResultTokens), cost units \(String(format: "%.2f", receipt.estimatedCostUnits)), proposals \(receipt.proposalIds.count), yield \(String(format: "%.2f", receipt.proposalYieldScore))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
    }
}
