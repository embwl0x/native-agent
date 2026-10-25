import Foundation
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import TurnTrace
import ProviderRouting
// Blueprint: | `EngineDoctor+FirstTurnRefresh.swift` | `DoctorFacade`: one launch refresh after a persisted terminal turn trace; retains its task and disarms both observation and refresh on launch stop |

/// Refresh once per launch after a real terminal trace is persisted. Provider
/// receipts and UI refresh notifications can arrive before a turn finishes;
/// this trigger preserves the configured Doctor gate and completed-turn proof.
@MainActor
extension DoctorFacade {
    private static var firstTurnObserver: NSObjectProtocol?
    private static var didRunFirstTurnRefresh = false
    private static var firstTurnRefreshTask: Task<Void, Never>?
    private static var firstTurnDisarmed = false

    public static func armFirstTurnRefresh(run: @escaping @Sendable () async -> LoopTickOutcome) {
        guard firstTurnObserver == nil, !didRunFirstTurnRefresh, !firstTurnDisarmed else { return }
        firstTurnObserver = NotificationCenter.default.addObserver(
            forName: .turnTraceTerminalPersisted,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { fireFirstTurnRefresh(run: run) }
        }
    }

    public static func disarmFirstTurnRefresh() {
        firstTurnDisarmed = true
        if let firstTurnObserver { NotificationCenter.default.removeObserver(firstTurnObserver) }
        firstTurnObserver = nil
        firstTurnRefreshTask?.cancel()
    }

    private static func fireFirstTurnRefresh(run: @escaping @Sendable () async -> LoopTickOutcome) {
        guard !didRunFirstTurnRefresh, !firstTurnDisarmed else { return }
        didRunFirstTurnRefresh = true
        if let firstTurnObserver { NotificationCenter.default.removeObserver(firstTurnObserver) }
        firstTurnObserver = nil
        firstTurnRefreshTask = Task.detached(priority: .utility) {
            await refreshFirstTurn(run: run)
            await retireFirstTurnRefresh()
        }
    }

    private static func retireFirstTurnRefresh() { firstTurnRefreshTask = nil }

    nonisolated private static func refreshFirstTurn(run: @escaping @Sendable () async -> LoopTickOutcome) async {
        guard !Task.isCancelled else { return }
        // The completed turn's trace rows are persisted off the turn path;
        // Doctor reads those files, so settle them first.
        await TurnTraceBus.shared.drainForProcessExit()
        guard !Task.isCancelled else { return }
        // The assembled runner uses freshMeasurement so behavioural checks
        // read this turn instead of replaying their launch memo.
        let outcome = await run()
        guard !Task.isCancelled else { return }
        if case .failed(let error) = outcome {
            FileHandle.standardError.write(
                Data("DoctorFirstTurnRefresh: refresh failed: \(error)\n".utf8)
            )
        }
    }
}
