import AppToolRuntime
import Cognition
import Foundation
import MacIntegration
import MemoryV2
import NativeAgentShared
// Blueprint: | `SettingsFace+Status.swift` | Settings runtime evidence and remedies read cognition, Trust, Mac permissions and memory owners |

extension NativeAgentEngine {
    @MainActor
    func settingsFaceStatus() async throws -> [PartFace.Section] {
        var rows: [PartFace.Row] = []
        do { _ = try await trust.load() }
        catch is CancellationError { throw CancellationError() }
        catch {
            rows.append(.init(id: "trust-status", title: "Trust settings unavailable", detail: error.localizedDescription,
                              tone: .failed, open: "page:trust"))
        }
        await cognitionView.refreshVitals()
        try Task.checkCancellation()
        let status = SettingsInnerLifeStatus.state(runtime: cognitionView.subconsciousRuntime, reflectionRoute: cognitionView.reflectionRoute)
        let tone: PartFace.Tone
        switch status.tone {
        case .neutral: tone = .quiet
        case .healthy: tone = .live
        case .warning: tone = .attention
        case .unavailable: tone = .failed
        }
        let open: String?
        let actions: [PartFace.Action]?
        switch status.recovery {
        case .configureProvider: (open, actions) = ("page:providers", nil)
        case .selectModel: (open, actions) = ("page:personality/minds", nil)
        case .reapply: (open, actions) = (nil, [.init(id: "enable-inner-life", label: "Enable again")])
        case nil: (open, actions) = (nil, nil)
        }
        rows.append(.init(id: "inner-life-status", title: "Inner life now", detail: status.detail,
                          value: status.text, tone: tone, open: open, actions: actions))
        await macIntegration.refresh()
        try Task.checkCancellation()
        let macDetail: String
        if let problem = macIntegration.permissionLoadError { macDetail = problem }
        else if macIntegration.permissions.isEmpty { macDetail = "Mac access has not been read." }
        else if macIntegration.permissions.values.contains(where: { $0.read || $0.write }) {
            macDetail = "On — macOS still asks for each app."
        } else { macDetail = "Off. Choose what I may reach." }
        rows.append(.init(id: "mac-access", title: "Use my Mac", detail: macDetail,
                          tone: macIntegration.permissionLoadError == nil ? .plain : .failed, open: "page:mac_integration"))
        // The switch reports the request; this row reports the serving backend and its actual load failure.
        if let snapshot = memory.embeddingSnapshot {
            let meaning: String
            switch snapshot.effectiveBackend {
            case ManagedEmbeddingProvider.coreMLBackend: meaning = "On — I find memories by what they mean."
            case ManagedEmbeddingProvider.mockBackend: meaning = "Off — I find memories by matching words."
            case ManagedEmbeddingProvider.failClosedBackend: meaning = "Semantic recall is unavailable."
            default: meaning = "The memory lookup model is unavailable. Open Doctor for its reported cause."
            }
            rows.append(.init(id: "semantic-status", title: "Memory lookup now", detail: snapshot.lastLoadError,
                              value: meaning,
                              tone: snapshot.effectiveBackend == ManagedEmbeddingProvider.failClosedBackend ? .failed : .plain,
                              open: "page:memories"))
        } else {
            rows.append(.init(id: "semantic-status", title: "Memory lookup unavailable",
                              detail: memory.embeddingsError ?? "The embedding runtime has not loaded.", tone: .failed, open: "page:memories"))
        }
        do {
            let proposals = try await memory.proposals(status: "pending")
            rows.append(.init(id: "memory-proposals", title: "Memory suggestions", value: String(proposals.count), open: "page:memory_proposals"))
        } catch is CancellationError { throw CancellationError() }
        catch {
            rows.append(.init(id: "memory-proposals", title: "Memory suggestions unavailable",
                              detail: error.localizedDescription, tone: .failed, open: "page:memories"))
        }
        return [.init(id: "runtime", title: "Right now", style: .list, rows: rows)]
    }
}
