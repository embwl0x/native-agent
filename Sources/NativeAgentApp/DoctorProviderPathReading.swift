import Foundation
import ChatOrchestration
import DoctorChecks
import EngineRuntime
import ProviderRouting

enum DoctorProviderPathReading {
    static func read(dataRoot: URL) async -> DoctorProviderRuntimeReading {
        let surface = ChatTurnRuntimeContext.current?.surface ?? "chat"
        let routing: ProviderRoutingSnapshot
        do {
            routing = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedRoutingSnapshotReadOnly()
        } catch {
            // A pending selection or unreadable routing state is itself the fault.
            return .unhealthy("Provider routing can't be read (\(error.localizedDescription)). Open Settings → Providers and choose the active model again.")
        }
        if let notice = routing.unusablePickNotice(for: surface) {
            return .unhealthy(notice)
        }
        guard let providerID = ChatTurnRuntimeContext.current?.providerID
                ?? ProviderRoutingSurfaceLookup.value(routing.activeProviders, surface) else {
            return .unhealthy("No usable provider is configured for the active path.")
        }
        guard let providers = try? await ProvidersFacade(dataRoot: dataRoot).list(),
              let provider = providers.first(where: { $0.provider_id == providerID }) else {
            return .unavailable
        }
        guard provider.auth_status.state.lowercased() == "ready" else {
            return .unhealthy("The active provider \(providerID) is not ready.")
        }
        return .healthy
    }
}
