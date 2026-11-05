import Foundation
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import TurnTrace
import ProviderRouting
// Blueprint: | `EngineDoctor+FirstTurnRefresh.swift` | `DoctorFacade`; One launch refresh after durable terminal evidence |

/// Trigger once after a durable terminal trace, never early provider or UI events, preserving the configured Doctor gate.
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
        // Settle off-path traces before Doctor reads their files.
        await TurnTraceBus.shared.drainForProcessExit()
        guard !Task.isCancelled else { return }
        // Use fresh measurements so checks observe this turn rather than the launch memo.
        let outcome = await run()
        guard !Task.isCancelled else { return }
        if case .failed(let error) = outcome {
            FileHandle.standardError.write(
                Data("DoctorFirstTurnRefresh: refresh failed: \(error)\n".utf8)
            )
        }
    }
}
