import SenseCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
// Blueprint: | `EngineSenses.swift` | `SensesFacade`: the work pane's sense view, current against the senses as last read, refreshed by their owners |

/// Refresh from owner changes only, ending observation when both panes unmount.
@MainActor
@Observable
public final class SensesFacade {
    /// The senses as last read; the interactive view is shown only while it belongs to one of them. An unreadable registry keeps the
    /// last records read.
    public private(set) var records: [SenseRecord] = []
    public private(set) var interactiveView: SenseInteractiveView?
    public private(set) var interactiveRevision: String?
    public private(set) var presentationLoaded = false
    public private(set) var presentationIssue: String?
    @ObservationIgnored private lazy var latest = LatestRead()

    public nonisolated init() {}

    public func refresh() async {
        await latest.read({ await readPresentation() }, publish: { next in
            guard !Task.isCancelled else { return }
            presentationLoaded = true
            switch next.registry {
            case .success(let (sorted, _)):
                if records != sorted { records = sorted }
                presentationIssue = nil
            case .failure(let error): presentationIssue = error.localizedDescription
            }
            let view = next.presentation.flatMap { $0.view.isCurrent(in: records) ? $0 : nil }
            if interactiveView != view?.view { interactiveView = view?.view }
            if interactiveRevision != view?.revision { interactiveRevision = view?.revision }
        })
    }

    private func readPresentation() async -> (registry: Result<([SenseRecord], [SenseCorner: String]), Error>,
                                             presentation: (view: SenseInteractiveView, revision: String)?) {
        async let view = SenseNewsBoard.shared.interactivePresentation()
        let registry: Result<([SenseRecord], [SenseCorner: String]), Error>
        do {
            registry = .success(try await SensesHub.shared.presentationRecords())
        } catch {
            registry = .failure(error)
        }
        return (registry, await view)
    }

    public func observe(dataRoot: URL) async {
        let root = AbilityStore(dataRoot: dataRoot).root
        await EventDeadlinePhysiology.refreshOnChanges(
            paths: [root, root.appendingPathComponent("state.json")],
            notifications: [AbilityStore.DidChange.name, SenseNewsBoard.PresentationDidChange.name],
            debounceDelay: .zero
        ) { await self.refresh() }
    }

}
