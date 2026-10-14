import Foundation
import ChatOrchestration
import DoctorChecks
import ProviderRouting

public enum DoctorProviderPathReading {
    public static func read(dataRoot: URL) async -> DoctorProviderRuntimeReading {
        let surface = ChatTurnRuntimeContext.current?.surface ?? "chat"
        let routing: ProviderRoutingSnapshot
        do {
            routing = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedRoutingSnapshotReadOnly()
        } catch {
            // A pending selection or unreadable routing state is itself the fault.
            return .unhealthy("Provider routing can't be read (\(error.localizedDescription)). Open Settings → Providers and choose the active model again.")
        }
        guard let providers = try? await ProvidersFacade(dataRoot: dataRoot).list() else {
            return .unavailable
        }
        if routing.activeProviders.values.contains(where: { id in
            let state = providers.first { $0.provider_id == id }?.auth_status.state.lowercased()
            return ["needs_oauth", "needs_key", "needs_credentials"].contains(state ?? "")
        }) {
            return .configurationIssue(CheckResult(
                id: "live.providers", title: "Providers and OAuth", status: "warn",
                detail: "Saved provider configuration retained; credentials unavailable",
                harm: "She cannot answer through the affected saved provider configuration.",
                human_action: "Sign in again", ask: .signIn
            ))
        }
        if let notice = routing.unusablePickNotice(for: surface) {
            return .unhealthy(notice)
        }
        guard let providerID = ChatTurnRuntimeContext.current?.providerID
                ?? ProviderRoutingSurfaceLookup.value(routing.activeProviders, surface) else {
            return .unhealthy("No usable provider is configured for the active path.")
        }
        guard let provider = providers.first(where: { $0.provider_id == providerID }) else {
            return .unavailable
        }
        guard provider.auth_status.state.lowercased() == "ready" else {
            return .unhealthy("The active provider \(providerID) is not ready.")
        }
        let probe: DoctorProviderProbeReading
        switch LLMProviderStatusFeed.read(providerID: providerID, dataRoot: dataRoot) {
        case .current: probe = .current
        case .stale(let record): probe = .stale(record.providerID)
        case .unavailable(let detail): probe = .unavailable(detail)
        case .failed(let detail): probe = .failed(detail)
        }
        return .healthy(probe)
    }
}
