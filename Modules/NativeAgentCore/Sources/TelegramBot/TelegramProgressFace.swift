import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `TelegramProgressFace.swift` | Per-card source epoch and L0 PartFaces cache over sanitized canonical phase and timing; native availability/failure and output redaction; Telegram progress/status voice comes from telegram-progress.js, entered through the originating app door |

/// A card owns one cache. Frozen native facts change its source epoch;
/// LatestRead owns publication when projections overlap. No view runs code.
@MainActor
final class TelegramProgressFace {
    private let faces: PartFaces
    private var source: JSONValue?
    private var epoch: UInt64 = 0

    init(dataRoot: URL, call: @escaping PartFaces.Call) {
        faces = PartFaces(dataRoot: dataRoot, call: call)
    }

    func text(input: JSONValue, row: String) async -> String {
        if source != input { source = input; epoch += 1 }
        let snapshot = await faces.sourceChanged(id: "telegram-progress", epoch: epoch, input: input)
        switch snapshot.status {
        case .ready:
            if let text = snapshot.face?.sections.flatMap(\.rows).first(where: { $0.id == row })?.title,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TurnTraceRedactor.redactText(String(text.prefix(3_500)))
            }
            return "Telegram progress part failed: missing \(row) row."
        case .unavailable, .failed:
            return "Telegram progress part \(snapshot.status.rawValue): \(TurnTraceRedactor.redactText(snapshot.error?.message ?? snapshot.status.rawValue))"
        }
    }

    func close() async { await faces.close() }

    nonisolated static func input(_ state: TelegramTurnPresentationState, at now: Date,
        replyTextSettled: Bool) -> JSONValue {
        let sinceMovement = max(0, now.timeIntervalSince(state.lastMovementAt))
        let phase = TurnPresentationReducer.effectivePhase(state,
            secondsSinceMovement: sinceMovement, stalledAfter: TurnPresentationReducer.defaultStalledAfter)
        return .object([
            "kind": .string("progress"), "phase": .string(phase.rawValue),
            "terminal": .bool(phase.isTerminal), "replyTextSettled": .bool(replyTextSettled),
            "action": state.currentAction.map(JSONValue.string) ?? .null,
            "delegate": state.delegateName.map(JSONValue.string) ?? .null,
            "elapsed": .double(max(0, (state.endedAt ?? max(now, state.startedAt)).timeIntervalSince(state.startedAt))),
            "sinceMovement": .double(sinceMovement)
        ])
    }
}
