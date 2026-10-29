import Context
import DreamREMCycle
import Foundation
import Senses
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import TurnTrace
import WorkshopExecution
import NativeAgentShared
// Blueprint: | `PersonaContextInvalidation.swift` | `DerivedPersonaPinInvalidationSink`, `ContextFlowInvalidationRelay` and `REMPinRebuildCoalescer`; persona invalidation reaches Context Flow and rebuilds REM pins even while it is off |

/// Persona invalidation rebuilds REM pins even when Context Flow is off or unavailable.
public struct DerivedPersonaPinInvalidationSink: DerivedStateInvalidationSink {
    let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public func sourceDidChange(_ changes: [DerivedSourceChange]) async {
        if let primary = await ContextFlowInvalidationRelay.shared.current() {
            await primary.sourceDidChange(changes)
        }
        // REM's proposal target accepts both writer filenames and scaffolder document IDs.
        guard changes.contains(where: {
            $0.namespace == "persona"
                && REMProposalStore.supportsProposalTarget($0.stableID)
        }) else { return }
        await REMPinRebuildCoalescer.shared.requestRebuild(dataRoot: dataRoot)
    }
}

/// Forwarding uses the returned sink outside the relay's isolation.
actor ContextFlowInvalidationRelay {
    static let shared = ContextFlowInvalidationRelay()

    private var coordinator: (any DerivedStateInvalidationSink)?

    func set(_ sink: (any DerivedStateInvalidationSink)?) {
        coordinator = sink
    }

    func current() -> (any DerivedStateInvalidationSink)? {
        coordinator
    }
}

/// Coalesce GROWTH.md writes without a timer; writes during rebuilding request another pass.
actor REMPinRebuildCoalescer {
    static let shared = REMPinRebuildCoalescer()

    private var rebuilding = false
    private var changedAgain = false

    func requestRebuild(dataRoot: URL) async {
        guard !rebuilding else {
            changedAgain = true
            return
        }
        rebuilding = true
        defer { rebuilding = false }
        repeat {
            changedAgain = false
            await Task.detached(priority: .utility) { [dataRoot] in
                do {
                    try REMConsolidator.emitREMPinsIndex(dataRoot: dataRoot)
                } catch {
                    nativeLog("[rem-pins] rebuild after a persona write failed: %@",
                          String(describing: error))
                }
            }.value
        } while changedAgain
    }
}
