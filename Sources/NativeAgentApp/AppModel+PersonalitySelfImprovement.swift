import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import EngineRuntime
import PersonaEngine
import DoctorChecks
import DreamREMCycle
import Cognition
// Blueprint: | `AppModel+PersonalitySelfImprovement.swift` | `engine.persona`: Profile/document writes through the persona owner; support and proposals |

/// Derive the live identity outcome from the persisted profile returned by the writer, never the submitted name.
enum PersonalityNameSaveOutcome: Equatable {
    case saved(PersonalityProfile)
    case refused(String)
    case failed(String)
}

/// Replace documents only after a successful canonical read; retain the last set and report failed refreshes.
enum PersonalityDocumentsReloadOutcome: Equatable {
    case loaded(documentCount: Int)
    case failed(detail: String, retainedDocumentCount: Int)
}

@MainActor
extension AppModel {
    func readPersonaFormState(documents: Bool) async throws -> PersonaSettingsFace {
        var state = PersonaSettingsFace()
        if documents { state.documents = try await engine.persona.loadDocuments() }
        else { state.profile = try await engine.persona.loadProfile() }
        return state
    }

    func savePersonaFormName(_ name: String) async throws -> PersonalityProfile {
        let previousName = engine.persona.profile?.name
        let saved = try await engine.persona.saveName(name)
        teachMemoryHygieneName(previousName: previousName)
        return saved
    }

    func savePersonaFormDocument(id: String, content: String, expectedContent: String) async throws -> PersonaDocSpec {
        try await engine.persona.saveDocument(id: id, content: content, appending: false, expectedContent: expectedContent)
    }

    /// Preserve persistence errors in the save result.
    @MainActor
    func savePersonalityChecked(_ profile: PersonalityProfile) async throws {
        do {
            let previousName = engine.persona.profile?.name
            try await engine.persona.saveProfile(profile)
            teachMemoryHygieneName(previousName: previousName)
            statusText = "Personality saved"
            await refreshAll()
        } catch {
            setFailureStatus(error, action: "save the personality")
            throw error
        }
    }

    @discardableResult
    func savePersonalityName(_ rawName: String) async -> PersonalityNameSaveOutcome {
        do {
            let previousName = engine.persona.profile?.name
            let saved = try await engine.persona.saveName(rawName)
            teachMemoryHygieneName(previousName: previousName)
            statusText = "Name saved as \(saved.name)"
            return .saved(saved)
        } catch PersonaWriteError.invalidInput(let detail) {
            statusText = "Name save refused: \(detail)"
            return .refused(detail)
        } catch {
            let detail = UserFacingError.cause(error, action: "save the name")
            setFailureStatus("Couldn't save the name. " + detail, cause: error)
            return .failed(detail)
        }
    }

    enum SupportDiagnosticsLoadOutcome: Equatable {
        case unavailable(String)
        case loaded(SupportDiagnostics, reusedDoctorReport: Bool)
    }

    @MainActor
    @discardableResult
    func loadSupportDiagnostics() async -> SupportDiagnosticsLoadOutcome {
        guard !supportDiagnosticsLoading else {
            return .unavailable("A Support Snapshot is already being prepared.")
        }
        guard !engine.doctor.isRunning else {
            return .unavailable("Doctor is currently running. Wait for it to finish before preparing a Support Snapshot.")
        }
        supportDiagnosticsLoading = true
        defer { supportDiagnosticsLoading = false }
        // Reuse a completed Doctor report while fresh to avoid duplicate work.
        let reuse = EngineDoctorRuntime<AppDoctorPort>.reusableSupportReport(
            report: engine.doctor.report, completedAt: engine.doctor.reportCompletedAt
        )
        let diagnostics = await SupportDiagnostics.read(reusingChecks: reuse?.checks)
        supportDiagnostics = diagnostics
        statusText = reuse != nil
            ? "Support diagnostics refreshed (reused recent Doctor result)"
            : "Support diagnostics refreshed"
        return .loaded(diagnostics, reusedDoctorReport: reuse != nil)
    }

    @MainActor
    @discardableResult
    func loadPersonalityDocs() async -> Bool {
        if case .loaded = await reloadPersonalityDocuments() { return true }
        return false
    }

    @MainActor
    @discardableResult
    func reloadPersonalityDocuments() async -> PersonalityDocumentsReloadOutcome {
        do {
            let documents = try await engine.persona.loadDocuments()
            statusText = "Personality documents reloaded"
            return .loaded(documentCount: documents.count)
        } catch {
            let detail = UserFacingError.cause(error, action: "load the personality docs")
            setFailureStatus("Couldn't load the personality docs. " + detail, cause: error)
            return .failed(detail: detail, retainedDocumentCount: engine.persona.documents.count)
        }
    }

    @MainActor
    @discardableResult
    func savePersonalityDoc(id: String, content: String, appending: Bool = false) async -> Bool {
        do {
            let saved = try await engine.persona.saveDocument(id: id, content: content, appending: appending)
            statusText = "\(saved.filename) saved"
            return true
        } catch {
            setFailureStatus(error, action: "save that personality doc")
            return false
        }
    }

    // MemoryFacade owns pending rows and their publication.
    @MainActor
    func loadMemoryProposals() async {
        _ = await decodeLogged("getMemoryProposals") {
            try await engine.memory.proposals(status: "pending", publish: { change in
                change()
            })
        }
    }

    @MainActor
    func approveMemoryProposal(id: String) async throws {
        _ = try await engine.memory.accept(proposalID: id, publish: { change in
            change()
        })
        await loadMemoryProposals()
        await engine.approvals.refresh()
    }

    @MainActor
    func rejectMemoryProposal(id: String, reason: String = "") async throws {
        try await engine.memory.reject(proposalID: id, reason: reason, publish: { change in
            change()
        })
        await loadMemoryProposals()
        await engine.approvals.refresh()
    }

    @MainActor
    func fetchDreamEntry(date: String) async -> DreamEntry? {
        dreamError = nil
        do {
            return try await engine.cognitionView.dreamEntry(date: date)
        } catch {
            dreamError = UserFacingError.message(error, action: "load the entry for \(date)")
            return nil
        }
    }

    /// Use the native completion record so zero proposals cannot conceal an incomplete or failed REM run.
    @MainActor
    func runRemPass() async -> (isSuccess: Bool, message: String) {
        dreamError = nil
        do {
            let response = try await NativeAgentEngine.runRem(dataRoot: engine.dataRoot)
            let completion = try REMRunReportPayload.validatedManualCompletion(response: response).get()
            let message: String
            if completion.nothingToConsolidate {
                message = "REM consolidation completed — nothing to consolidate yet."
            } else {
                let proposals = completion.proposals == 1 ? "1 proposal" : "\(completion.proposals) proposals"
                let archived = completion.archivedEntries == 1 ? "1 diary entry archived" : "\(completion.archivedEntries) diary entries archived"
                message = "REM consolidation completed — \(proposals), \(archived)."
            }
            statusText = message
            return (true, message)
        } catch {
            let message = UserFacingError.message(error, action: "run the REM cycle")
            dreamError = message
            statusText = "REM cycle failed"
            return (false, message)
        }
    }

    @MainActor
    func setDreamCycleEnabled(_ enabled: Bool) async -> Bool {
        dreamError = nil
        do {
            let saved = try await engine.cognitionView.setDreamCycleEnabled(enabled)
            engine.trust.publishPolicy(saved)
            statusText = enabled ? "Dream cycle enabled" : "Dream cycle disabled"
            return true
        } catch {
            dreamError = UserFacingError.message(error, action: "save the dream cycle setting")
            return false
        }
    }

    @MainActor
    func setRemCycleEnabled(_ enabled: Bool) async -> Bool {
        dreamError = nil
        do {
            let saved = try await engine.cognitionView.setRemCycleEnabled(enabled)
            engine.trust.publishPolicy(saved)
            statusText = enabled ? "REM cycle enabled" : "REM cycle disabled"
            return true
        } catch {
            dreamError = UserFacingError.message(error, action: "save the REM cycle setting")
            return false
        }
    }

    /// The inner-life master owns the hour's lifetime; enable Fluid Context's Active default only if no choice exists.
    /// Return the runtime's state and cause when it cannot run as requested.
    @MainActor
    func setInnerLifeEnabled(_ enabled: Bool) async -> (state: NativeSubconsciousRuntimeState, problem: String?) {
        let (state, contextFlowReady) = await engine.cognitionView.setInnerLifeEnabled(
            enabled,
            runtime: NativeAgentEngine.liveCognition,
            contextFlow: NativeAgentEngine.live.contextFlow
        )

        var problem: String?
        if enabled && !contextFlowReady {
            problem = "Some of my inner life is held off by setup, safety, or provider health."
        }
        if enabled && !state.enabled {
            let voice = AgentVoice(name: agentDisplayName)
            problem = "Connect a provider, or choose my reflection mind under Personality ▸ \(voice.possessive) minds, before turning this on."
        }
        statusText = state.enabled
            ? "I have an inner life again"
            : "My inner life is off"
        return (state, problem)
    }

    /// Keep dream-run errors on the Dreams tab and reload only after success so failures remain visible. busy names effects kept owed
    /// because a shared slot was held: the run succeeded, and those wait for the next one.
    @MainActor
    func runDreamPassForDreams(parent: Turn? = nil) async -> (ok: Bool, busy: [String]) {
        dreamError = nil
        do {
            let result = try await NativeAgentEngine.runDream(dataRoot: engine.dataRoot, trigger: .manual, parent: parent)
            if let detail = DreamReport.completionFailure(result) {
                dreamError = "Dream cycle failed: \(detail)"
                statusText = "Dream cycle failed"
                return (false, [])
            }
            statusText = DreamReport.statusText(result)
            return (true, result["busy"] as? [String] ?? [])
        } catch {
            dreamError = UserFacingError.message(error, action: "run the dream cycle")
            statusText = "Dream cycle failed"
            return (false, [])
        }
    }

}
