import NativeAgentShared
import Cognition
import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

// Blueprint: | `CognitionObservatoryView+Capsule.swift` | Read-only capsule, reflection and felt-mode presentation |

extension CognitionObservatoryView {

    /// Absence of a dominant mode proves no single aboutness, not a missing capsule.
    @ViewBuilder
    private func feltModeChip(_ mode: CognitiveSubstrate.FeltMode) -> some View {
        // Qualify the mode label so readers cannot mistake it for the capsule's title.
        Label("Felt mode · \(mode.rawValue) — \(Self.feltModeGloss(mode))", systemImage: "scope")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, NativeAgentSpacing.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .accessibilityLabel("Felt mode: \(mode.rawValue), \(Self.feltModeGloss(mode))")
    }

    /// Explain felt modes without requiring knowledge of the substrate implementation.
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
                // Distinguish the last injected capsule from a pre-injection projection so quiet chat cannot appear frozen.
                if let info {
                    switch info.source {
                    case .liveInjected:
                        Text(liveInjectedCaption(info))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    case .synthetic:
                        Label("The agent has not been given a summary yet this session — this is an example.", systemImage: "wand.and.stars")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let capsule {
                    Text(capsule.combined)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("No thought summary yet.")
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
                Text("No reflections recorded yet.")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    ForEach(Array(reflections.prefix(6)), id: \.id) { receipt in
                        let total = receipt.estimatedPromptTokens.addingReportingOverflow(receipt.estimatedResultTokens)
                        let tokens = total.overflow
                            ? """
                                total unavailable (prompt \(receipt.estimatedPromptTokens), result \(receipt.estimatedResultTokens); total exceeds integer \
                                range)
                                """
                            : String(total.partialValue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(receipt.request.reason)
                                .font(.caption.weight(.semibold))
                            Text(receipt.resultSummary)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text("\(receipt.request.model) via \(receipt.provider)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("""
                                estimated tokens \(tokens), estimated cost units \(String(format: "%.2f", receipt.estimatedCostUnits)), cares affected \
                                \(receipt.affectedCareIDs.count)
                                """)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
    }
}
