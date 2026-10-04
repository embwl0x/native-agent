import Context
import ContextFlow
import Foundation
import SwiftUI

/// The Context Flow health projection deliberately keeps "no health was
/// readable", "configured off", and "reported an error" separate. The
/// Observatory must not turn any of those into the same reassuring zero-value
/// table.
struct ContextFlowHealthRowsPresentation: Equatable {
    struct Row: Identifiable, Equatable {
        let label: String
        let value: String

        var id: String { label }
    }

    enum State: Equatable {
        case unavailable
        case off
        case stopped
        case attention
        case running
    }

    let state: State
    let rows: [Row]
    let errorDetail: String?

    init(healthState: ContextFlowObservatoryHealthState) {
        switch healthState {
        case .unavailable:
            self.init(health: nil)
        case .off:
            self.init(
                state: .off,
                rows: [Row(label: "Mode", value: ContextFlowMode.off.rawValue)],
                errorDetail: nil
            )
        case .health(let health):
            self.init(health: health)
        }
    }

    private init(state: State, rows: [Row], errorDetail: String?) {
        self.state = state
        self.rows = rows
        self.errorDetail = errorDetail
    }

    init(health: ContextFlowCoordinatorHealth?) {
        guard let health else {
            self.state = .unavailable
            self.rows = []
            self.errorDetail = nil
            return
        }

        self.rows = Self.rows(for: health)
        if let error = health.lastError {
            self.state = .attention
            let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
            self.errorDetail = trimmed.isEmpty
                ? "Context Flow reported an unspecified error."
                : trimmed
        } else {
            self.errorDetail = nil
            if health.mode == .off {
                self.state = .off
            } else if !health.started {
                self.state = .stopped
            } else {
                self.state = .running
            }
        }
    }

    var statusText: String? {
        return switch state {
        case .unavailable: "Context Flow health is unavailable."
        case .off: "Context Flow is off."
        case .stopped: "Context Flow has not started."
        case .attention: "Context Flow needs attention."
        case .running: nil
        }
    }

    static func generationText(_ generation: Int64?) -> String {
        generation.map(String.init) ?? "none"
    }

    private static func rows(for health: ContextFlowCoordinatorHealth) -> [Row] {
        var rows = [
            Row(label: "Mode", value: health.mode.rawValue),
            Row(label: "Store generation", value: generationText(health.activeStoreGenerationID)),
            Row(label: "RAM generation", value: generationText(health.activeArenaGenerationID)),
            Row(label: "Registered sources", value: String(health.registeredSourceCount)),
            Row(label: "Degraded sources", value: String(health.degradedSourceCount)),
            Row(
                label: "Arena",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(health.arenaMetrics.residentLogicalBytes),
                    countStyle: .memory
                )
            ),
            Row(label: "Pressure", value: health.arenaMetrics.pressure.rawValue),
            Row(label: "Active leases", value: String(health.arenaMetrics.activeLeaseCount)),
            Row(label: "Prewarm queue", value: String(health.pendingPrewarmHints)),
            Row(label: "Prewarm receipts", value: String(health.prewarmUsefulnessReceipts)),
        ]
        if let reconciled = health.lastReconciledAt {
            rows.append(Row(
                label: "Reconciled",
                value: reconciled.formatted(date: .omitted, time: .standard)
            ))
        }
        return rows
    }
}

struct ContextFlowObservatoryPanel: View {
    let healthState: ContextFlowObservatoryHealthState

    var body: some View {
        let presentation = ContextFlowHealthRowsPresentation(healthState: healthState)
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            if let statusText = presentation.statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(presentation.state == .attention ? .orange : .secondary)
            }
            ForEach(presentation.rows) { healthRow in
                row(healthRow.label, healthRow.value)
            }
            if let error = presentation.errorDetail {
                Divider()
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
