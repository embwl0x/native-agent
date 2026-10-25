import Foundation
import NativeAgentCore
import Observation
import Senses
// Blueprint: | `EngineSenses.swift` | One engine Senses projection for registry records, news and interactive views through `LatestRead`, committed switches through `write`; one window sampler while Senses or Work is visible |

/// The Work pane and Senses page read this engine projection. Its owners have
/// no complete push contract, so the window samples while either is visible.
@MainActor
@Observable
public final class SensesFacade {
    public private(set) var records: [SenseRecord] = []
    public private(set) var surfaceNames: [SenseCorner: String] = [:]
    public private(set) var news: [SenseNews] = []
    public private(set) var interactiveView: SenseInteractiveView?
    public private(set) var isWired = false
    public private(set) var loaded = false
    public private(set) var saving: Set<String> = []
    public private(set) var error: String?
    public private(set) var readError: String?
    @ObservationIgnored private lazy var latest = LatestRead()

    public nonisolated init() {}

    public func refresh() async {
        await latest.read({ await readPresentation() }, publish: { next in
            guard !Task.isCancelled else { return }
            if isWired != next.wired { isWired = next.wired }
            switch next.registry {
            case .success(let (sorted, names)):
                if records != sorted { records = sorted }
                if surfaceNames != names { surfaceNames = names }
                readError = nil
            case .failure(let error):
                readError = "Senses registry unavailable: \(error.localizedDescription)"
            }
            if news != next.news { news = next.news }
            let view = next.view.flatMap { $0.isCurrent(in: records) ? $0 : nil }
            if interactiveView != view { interactiveView = view }
            loaded = true
        })
    }

    private func readPresentation() async -> (wired: Bool, registry: Result<([SenseRecord], [SenseCorner: String]), Error>, news: [SenseNews], view: SenseInteractiveView?) {
        let hub = SensesHub.shared
        let wired = hub.registry != nil
        async let news = SenseNewsBoard.shared.latest(limit: SenseNewsBoard.capacity)
        async let view = SenseNewsBoard.shared.interactiveView()
        let registry: Result<([SenseRecord], [SenseCorner: String]), Error>
        do {
            registry = .success(try await hub.presentationRecords())
        } catch {
            registry = .failure(error)
        }
        return (wired, registry, Array((await news).prefix(12)), await view)
    }

    public func observe() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    public func setEnabled(_ enabled: Bool, record: SenseRecord) async {
        guard saving.insert(record.id).inserted else { return }
        defer { saving.remove(record.id) }
        guard let registry = SensesHub.shared.registry as? any SenseRegistryManaging else {
            error = "Senses are not connected yet."
            return
        }
        do {
            let saved = try await registry.setStatus(id: record.id, version: record.version, status: enabled ? .on : .off,
                                             preview: false, ownerAuthorized: true)
            latest.write {
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index] = saved
                }
                error = nil
            }
        } catch {
            self.error = "I couldn't save this switch: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// User's Share action supplies the native destination picker.
    public func export(_ record: SenseRecord, destination: () -> URL?) async {
        guard saving.insert(record.id).inserted else { return }
        defer { saving.remove(record.id) }
        guard let registry = SensesHub.shared.registry as? any SenseRegistryManaging else {
            error = "Senses are not connected yet."
            return
        }
        guard let destination = destination() else { return }
        do {
            _ = try await registry.exportBundle(id: record.id, to: destination, userApproved: true)
            error = nil
        } catch {
            self.error = "I couldn't share this sense: \(error.localizedDescription)"
        }
    }
}
