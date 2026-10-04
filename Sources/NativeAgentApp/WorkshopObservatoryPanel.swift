import Foundation
import OSLog
import PersistenceCore
import Desk
import SwiftUI
import WorkshopExecution

// MARK: - Workshop Observatory
//
// Displays pursuit and session counts, owner cadence items, and recent workshop
// receipts from EngineWorkshopObservatory snapshots. Pursuit controls live in
// DeskPageView; EngineWorkshopObservatory owns the data shaping.
//
// Unavailable state stays distinct from a healthy zero: a read that could not
// complete never renders as "0 sessions" or "no pursuits".

/// The receipt feed is intentionally read as open vocabulary: legacy rows can
/// outlive the current `WorkshopSessionStatus` enum. Unknown states therefore
/// warn rather than falling back to neutral chrome beside a successful row.
enum WorkshopReceiptStatusPresentation {
    enum Tint: Sendable, Equatable {
        case success
        case warning
        case failure
    }

    static func status(for row: WorkshopReceiptRow) -> String {
        guard row.isDirectedTask,
              ["completed", "done", "succeeded"].contains(
                row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return row.status
        }
        switch row.verificationStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "satisfied": return row.status
        case "failed": return "verification failed"
        default: return "unverified"
        }
    }

    static func tint(for rawStatus: String) -> Tint {
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed":
            return .success
        case "blocked", "cancelled", "canceled":
            return .warning
        case "refused", "failed", "error", "errored", "verification failed":
            return .failure
        default:
            // A new producer status is not proof of success. Keep it visibly
            // distinct until the producer and status vocabulary are reconciled.
            return .warning
        }
    }
}

/// The owner-facing mutation behind the Observatory's Veto button. A repeated
/// button event is held while the first durable operation is in flight; once
/// settled, the store's idempotent veto makes retries safe across relaunches.
actor WorkshopObservatoryVetoHandler {
    enum Outcome: Equatable, Sendable {
        case completed
        case alreadyVetoed
        case inFlight
        case failed(String)
    }

    static let rationale = "Vetoed by the user from the Desk observatory."
    private static let logger = Logger(subsystem: "com.nativeagent.app", category: "workshop-veto")

    private let store: SwiftNativeDeskStore
    private var inFlightHandles: Set<String> = []

    init(dataRoot: URL) {
        self.store = SwiftNativeDeskStore(dataRoot: dataRoot)
    }

    init(store: SwiftNativeDeskStore) {
        self.store = store
    }

    func veto(_ handle: String) async -> Outcome {
        guard inFlightHandles.insert(handle).inserted else { return .inFlight }
        defer { inFlightHandles.remove(handle) }
        do {
            return try await store.vetoPursuit(handle, note: Self.rationale) == nil
                ? .alreadyVetoed
                : .completed
        } catch {
            Self.logger.error("Veto failed: \(String(describing: error), privacy: .public)")
            switch error {
            case DeskError.unknownHandle:
                return .failed("This item could not be found on the Desk.")
            case DeskError.notAPursuit:
                return .failed("This item is not a pursuit.")
            case DeskError.vetoRefusedTerminal:
                return .failed("This pursuit is already closed.")
            case DeskError.terminalStatusRefusedNonTerminalChild:
                return .failed("This pursuit has unfinished child items. Close them before vetoing it.")
            case DeskError.pursuitFieldMissing:
                return .failed("The veto reason is missing.")
            case DeskError.compactionBaseCorrupt, DeskError.compactionBaseUnreadable:
                return .failed("Saved Desk data could not be read. The pursuit was not changed.")
            default:
                return .failed("The veto could not be saved. Try again.")
            }
        }
    }
}

/// Presentation-side sequencing for the mounted Veto control. The store still
/// owns durability and cross-process idempotency; this owner prevents a second
/// click from launching a stale refresh while the first operation is pending.
enum WorkshopObservatoryVetoPresentation {
    static func shouldRefresh(after outcome: WorkshopObservatoryVetoHandler.Outcome) -> Bool {
        switch outcome {
        case .completed, .alreadyVetoed:
            return true
        case .inFlight, .failed:
            return false
        }
    }
}

// MARK: - The panel

struct WorkshopObservatoryPanel: View {
    let snapshot: WorkshopObservatorySnapshot?

    init(snapshot: WorkshopObservatorySnapshot?) {
        self.snapshot = snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            if let snapshot {
                content(snapshot)
            } else {
                loadingRow
            }
        }
    }

    private var loadingRow: some View {
        Text("Loading workshop state.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func content(_ snapshot: WorkshopObservatorySnapshot) -> some View {
        header(snapshot)

        if let deskUnavailable = snapshot.deskUnavailable {
            noticeRow(
                icon: "questionmark.circle", tint: .orange,
                title: "Desk state unavailable",
                detail: deskUnavailable)
        } else if let model = snapshot.model {
            cadenceSection(model)
        }

        Divider()
        receiptsSection(snapshot.receipts)
    }

    // MARK: header

    @ViewBuilder
    private func header(_ snapshot: WorkshopObservatorySnapshot) -> some View {
        if let model = snapshot.model {
            HStack(spacing: NativeAgentSpacing.sm) {
                metricChip(
                    "\(model.openPursuitCount)/\(model.maxOpenPursuits)",
                    label: "open pursuits", tint: .purple)
                metricChip(
                    "\(model.sessionsToday)/\(model.globalCap)",
                    label: "sessions today", tint: .teal)
                Spacer()
            }
        } else {
            // Never render counts as 0 when the read failed.
            Text("Counts unavailable — Desk state could not be read.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func metricChip(_ value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: pursuits
    //
    // The per-pursuit list, its score/budget readout and its Veto button used
    // to live here — a second pursuit list behind the
    // developer gate (Diagnostics ▸ Cognition ▸ Desk). Item 36 moved the owner
    // control onto the Desk row User already reads and deleted the duplicate;
    // what remains here is the COUNT in the header, which is what an
    // observatory is for. The pure fold (`WorkshopObservatoryModel.openPursuits`
    // → `WorkshopPursuitRow.from`) is unchanged and now feeds the Desk row.

    // MARK: cadence

    @ViewBuilder
    private func cadenceSection(_ model: WorkshopObservatoryModel) -> some View {
        if !model.cadenceItems.isEmpty {
            Divider()
            Text("Owner cadence items")
                .font(NativeAgentFont.section)
            ForEach(model.cadenceItems) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.caption)
                        Text(item.cadenceMode)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.nextDue)
                        .font(.caption2)
                        .foregroundStyle(item.isDue ? .teal : .secondary)
                }
            }
        }
    }

    // MARK: receipts

    @ViewBuilder
    private func receiptsSection(_ state: WorkshopReceiptsState) -> some View {
        Text("Recent workshop sessions")
            .font(NativeAgentFont.section)
        switch state {
        case .unavailable(let reason):
            noticeRow(
                icon: "questionmark.circle", tint: .orange,
                title: "Session receipts unavailable", detail: reason)
        case .rows(let rows):
            if rows.isEmpty {
                Text("No workshop sessions have run yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    let status = WorkshopReceiptStatusPresentation.status(for: row)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(status)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(statusTint(status))
                            Spacer()
                            Text(receiptTimeText(row.ts))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(row.summary.isEmpty ? "(no summary)" : row.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text("\(row.model ?? "model unavailable") · \(row.artifactCount) artifact\(row.artifactCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Divider()
                }
            }
        }
    }

    // MARK: helpers

    private func receiptTimeText(_ raw: String) -> String {
        guard !raw.isEmpty else { return "—" }
        if let date = DeskClock.parseISO(raw) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return raw
    }

    private func statusTint(_ status: String) -> Color {
        switch WorkshopReceiptStatusPresentation.tint(for: status) {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    /// Thin wrapper over the shared `ObservatoryNoticeRow` (C10 dedup); call
    /// sites in this panel are unchanged.
    private func noticeRow(icon: String, tint: Color, title: String, detail: String?) -> some View {
        ObservatoryNoticeRow(icon: icon, tint: tint, title: title, detail: detail)
    }
}
