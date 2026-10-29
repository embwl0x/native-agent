import Foundation
import ChatTurnContracts
import DoctorChecks
import ProviderRouting
import NativeAgentShared
// Blueprint: | `DoctorProviderPathReading.swift` | Doctor captures checked routing before one catalog read; returns path diagnosis and the same provider rows for coverage, preserving pending-selection faults |

public enum DoctorProviderPathReading {
    public static func read(dataRoot: URL) async throws -> (runtime: DoctorProviderRuntimeReading, providers: [ProviderInfo]) {
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        // Capture routing faults before catalog discovery can recover a pending selection.
        let routingRead: Result<ProviderRoutingSnapshot, Error>
        do { routingRead = .success(try await router.checkedRoutingSnapshotReadOnly()) }
        catch { routingRead = .failure(error) }
        let providers = try await ProvidersFacade.connections(from: router.checkedProviderSnapshot())
        let surface = ChatTurnRuntimeContext.current?.surface ?? "chat"
        let routing: ProviderRoutingSnapshot
        do {
            routing = try routingRead.get()
        } catch {
            return (.unhealthy("Provider routing can't be read (\(error.localizedDescription)); the saved provider selection is unavailable."), providers)
        }
        // Live OAuth confirmation supersedes the saved needs_oauth state.
        let needsSignIn = Set(routing.activeProviders.values.filter { id in
            let state = providers.first { $0.provider_id == id }?.auth_status.state.lowercased()
            guard ["needs_oauth", "needs_key", "needs_credentials", "rejected"].contains(state ?? "") else { return false }
            return !(state == "needs_oauth" && NativeOAuthFlow.signInStatus(providerID: id, dataRoot: dataRoot).isSignedIn)
        }).sorted()
        if !needsSignIn.isEmpty {
            let controls = providers.filter { needsSignIn.contains($0.provider_id) }.map {
                "Providers → \($0.display_name) → " + ($0.auth_modes.contains("api_key") ? "API key" : "Sign in")
            }.sorted()
            return (.configurationIssue(CheckResult(source: "Providers accounts: " + needsSignIn.joined(separator: ", "),
                id: "live.providers", title: "Providers and OAuth", status: "warn",
                detail: "Saved provider configuration retained; credentials unavailable",
                harm: "She cannot answer through the affected saved provider configuration.",
                human_action: controls.joined(separator: "; "), ask: .signIn
            )), providers)
        }
        if let notice = routing.unusablePickNotice(for: surface) {
            return (.unhealthy(notice), providers)
        }
        guard let providerID = ChatTurnRuntimeContext.current?.providerID
                ?? ProviderRoutingSurfaceLookup.value(routing.activeProviders, surface) else {
            return (.unhealthy("No usable provider is configured for the active path."), providers)
        }
        guard let provider = providers.first(where: { $0.provider_id == providerID }) else {
            return (.unavailable, providers)
        }
        guard provider.auth_status.eligible else {
            return (.unhealthy("The active provider \(providerID) is not ready."), providers)
        }
        let probe: DoctorProviderProbeReading
        switch LLMProviderStatusFeed.read(providerID: providerID, dataRoot: dataRoot) {
        case .current: probe = .current
        case .stale(let record): probe = .stale(record.providerID)
        case .unavailable(let detail): probe = .unavailable(detail)
        case .failed(let detail): probe = .failed(detail)
        }
        return (.healthy(probe), providers)
    }
}
