import Browser
import EngineRuntime
import Foundation
import NativeAgentShared
import Research
import SystemOps
// Blueprint: | `AppModel+GraphCapabilityActions.swift` | Research search and shared browser/export adapters retained for other pages and the tool door |

enum ResearchSearchFailure: Error, Equatable {
    case blankQuery
    case requestFailed(String)

    var message: String {
        switch self {
        case .blankQuery: return "Enter a research query."
        case .requestFailed(let message): return message
        }
    }
}

enum ProductionExportCreationOutcome: Equatable {
    case verified(ProductionExport)
    case failed(support: Bool, detail: String)
}

@MainActor
extension AppModel {
    func search(_ query: String) async -> Result<ResearchSearchResponse, ResearchSearchFailure> {
        let research = SwiftNativeResearchClient(dataRoot: engine.dataRoot)
        return await search(query) { trimmed in
            try await research.search(query: trimmed)
        }
    }

    func search(
        _ query: String,
        using operation: (String) async throws -> ResearchSearchResponse
    ) async -> Result<ResearchSearchResponse, ResearchSearchFailure> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.blankQuery) }
        do {
            return .success(try await operation(trimmed))
        } catch {
            setFailureStatus(error, action: "run that research")
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    @MainActor
    func showVisibleBrowser() async {
        BrowserWindowController.shared.showWindow()
        _ = await engine.tools.refreshNativePower()
        statusText = "Visible Browser opened."
    }

    func createProductionExport(support: Bool = false) async -> ProductionExportCreationOutcome {
        do {
            let export = try await engine.doctor.createProductionExport(support: support)
            statusText = "Created and verified: \(export.path)"
            return .verified(export)
        } catch {
            let detail = UserFacingError.cause(error, action: "create the export")
            statusText = detail
            return .failed(support: support, detail: detail)
        }
    }
}
