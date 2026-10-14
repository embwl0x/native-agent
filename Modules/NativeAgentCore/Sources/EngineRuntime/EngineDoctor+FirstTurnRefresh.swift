import Foundation
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import TurnTrace
import ProviderRouting

/// Refresh once per launch after a real terminal trace is persisted. Provider
/// receipts and UI refresh notifications can arrive before a turn finishes;
/// this trigger preserves the configured Doctor gate and completed-turn proof.
@MainActor
extension DoctorFacade {
    private static var firstTurnObserver: NSObjectProtocol?
    private static var didRunFirstTurnRefresh = false

    public static func armFirstTurnRefresh(run: @escaping @Sendable () async -> LoopTickOutcome) {
        guard firstTurnObserver == nil, !didRunFirstTurnRefresh else { return }
        firstTurnObserver = NotificationCenter.default.addObserver(
            forName: .turnTraceTerminalPersisted,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { fireFirstTurnRefresh(run: run) }
        }
    }

    private static func fireFirstTurnRefresh(run: @escaping @Sendable () async -> LoopTickOutcome) {
        guard !didRunFirstTurnRefresh else { return }
        didRunFirstTurnRefresh = true
        if let firstTurnObserver { NotificationCenter.default.removeObserver(firstTurnObserver) }
        firstTurnObserver = nil
        Task.detached(priority: .utility) {
            // The completed turn's trace rows are persisted off the turn path;
            // Doctor reads those files, so settle them first.
            await TurnTraceBus.shared.drainForProcessExit()
            // The assembled runner uses freshMeasurement so behavioural checks
            // read this turn instead of replaying their launch memo.
            let outcome = await run()
            if case .failed(let error) = outcome {
                FileHandle.standardError.write(
                    Data("DoctorFirstTurnRefresh: refresh failed: \(error)\n".utf8)
                )
            }
        }
    }
}
