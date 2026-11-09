import ChatSessionWork
import ChatTurnRuntime
import Foundation
import NativeAgentShared
import PersistenceCore
import Privacy
import ProviderRouting
// Blueprint: | `EngineFaceContextProjection.swift` | Connection-held context summary rows; saved disclosure belongs to the document demand |

enum EngineFaceContextProjection {
    @concurrent static func observe(_ session: String, engine: NativeAgentEngine) async {
        await post(session, rows: [], state: .waiting(on: "the last turn's context"), engine: engine)
        guard let disclosure = ContextFedRecord.url(sessionId: session, dataRoot: engine.dataRoot) else {
            await post(session, rows: [], state: .unavailable(failure("context_session_invalid", "Choose a valid conversation.")), engine: engine)
            return
        }
        let paths = [disclosure]
            + ["providers/surfaces.json", "providers/active.json", "providers", "bots/definitions"]
                .map { engine.dataRoot.appendingPathComponent($0) }
        let changes = FileChangeEvents(paths: paths, emitInitial: false)
        let (signals, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let notifications = ObservationNotifications(names: [.chatTurnCompleted, .nativeAgentSessionProviderUsageDidChange]) { wake.yield(()) }
        defer { notifications.cancel(); wake.finish() }
        await withTaskCancellationHandler {
            guard await changes.waitUntilArmed(), !Task.isCancelled else {
                if !Task.isCancelled { await unavailable(session, engine: engine) }
                return
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in changes.stream { wake.yield(()) }
                    if !Task.isCancelled { wake.yield(()) }
                }
                wake.yield(())
                for await _ in signals {
                    guard !Task.isCancelled else { break }
                    guard changes.isArmed else { await unavailable(session, engine: engine); break }
                    await refresh(session, engine: engine)
                }
                group.cancelAll()
            }
        } onCancel: { changes.cancel(); wake.finish() }
        changes.cancel()
    }

    @concurrent private static func refresh(_ session: String, engine: NativeAgentEngine) async {
        let choice = await engine.providers.refreshSession(session)
        if let issue = choice.error {
            await post(session, rows: [], state: .unavailable(failure("context_model_unavailable", issue)), engine: engine)
            return
        }
        let reading = await ContextReceipts.read(sessionId: session, selectedModel: choice.choice?.model ?? "", dataRoot: engine.dataRoot)
        let state: FaceReadState
        switch reading {
        case .loading: state = .waiting(on: "the last turn's context")
        case .unavailable(let cause): state = .unavailable(failure("context_receipt_unavailable", cause))
        case .noTurn, .outsideSearch, .receipt: state = .ready
        }
        let rows = ComposerContextReceiptPresentation.lines(reading).map { EngineFaceMindProjection.row($0.id, $0.label, nil) }
        let turnId: String?
        if case .receipt(let receipt) = reading { turnId = receipt.turnId }
        else { turnId = nil }
        await post(session, rows: rows, state: state, turnId: turnId, engine: engine)
    }

    @concurrent private static func unavailable(_ session: String, engine: NativeAgentEngine) async {
        await post(session, rows: [], state: .unavailable(failure("context_observation_unavailable",
            "Context changes could not be observed. Reopen the Context card.")), engine: engine)
    }

    @concurrent private static func post(_ session: String, rows: [PartFace.Row],
        state: FaceReadState, turnId: String? = nil, engine: NativeAgentEngine) async {
        guard !Task.isCancelled else { return }
        await engine.face.post(ContextReceiptFace(session: session, turnId: turnId, rows: rows, state: state),
            at: .contextReceipt(session: session))
    }

    private static func failure(_ code: String, _ cause: String) -> WireFailure {
        EngineFaceActs.failure(code, NativeAppSecretRedactor.redactText(cause))
    }
}
