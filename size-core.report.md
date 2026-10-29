CORE-10 — done

- Lines: −689/+606 for source and blueprint (net −83, including relocation); onboarding source alone is down 85 lines. Onboarding.swift: 430 → 128 lines.
- HEAD had already separated starter setup and reset execution in 0a80b9428; finished the remaining completion, repair, reset-recovery and tour boundaries.
- One mechanism: SwiftNativeOnboardingClient retains its existing locks, shared transaction encoder and byte writer. Completion intent/recovery lives in OnboardingCompletion.swift; reset intent/backups/recovery in OnboardingReset.swift; missing-only repair in OnboardingProfileRepair.swift; MainActor replay in OnboardingTourReplay.swift. StarterPersona.swift already owns MainActor setup and starter-note recovery.
- Changed Onboarding.swift, OnboardingIdentity.swift and OnboardingValues.swift; deleted OnboardingManifests.swift after moving its declarations to completion/reset. No types or forwarding added.
- Callers updated: none needed; signatures and actor isolation are unchanged. Only profileJSONPath changed from private to internal for cross-file extensions; no public mutation surface added. Every origin import is retained.
- Persisted JSON fields, reset phase cases, pending-completion.json/pending-reset.json, .onboarded, profile.json, backup filenames, hash checks, sentinel-last completion and exact-byte backups are unchanged.
- Docs touched: source Blueprint rows and regenerated docs/ARCHITECTURE_BLUEPRINT.md. Repeated/historical comments shortened while retaining their laws.
- Validation: source/caller readback; non-comment source-line comparison found only relocation and the required access change; import comparison passed; git diff --cached --check passed. Timer inventory passed: 174 sites, 137 ownership rules, no ERROR; no timers moved. Blueprint generation passed; full policy check has the unrelated failures listed below.
- Commit: CORE-10: Split onboarding by completion, reset, repair and tour on wA/s4-size-core. No merge, rebase or push; no remaining dirt at closeout.

Callers checked

- All onboarding declarations, PersonaTemplates.swift and StarterPersona.swift; Modules/NativeAgentCore/Package.swift and root Package.swift source discovery/dependencies.
- EngineRuntime/NativeAgentResidentRefresh.swift and NativeAgentApp/AppModel+Onboarding.swift.
- NativeAgentApp/OnboardingWizard.swift, OnboardingRecovery.swift, OnboardingProfileRepair.swift, OnboardingWizardState.swift and ResetPersonaView.swift.
- NativeAgentApp/PersonalityView.swift, ContentView.swift and SetupRestRows.swift.
- Symbol/path searches across Modules, Sources, iOS, Extensions, Resources and script; no additional call sites requiring changes.

Not done

- Build, tests, install and runtime checks: prohibited for this lane; main owns the compile and installed proof.
- Full architecture policy check remains failing on eight pre-existing findings in untouched files: app-is-a-platform-door requires SwiftUI/AppKit imports in AppModel+ChatActions.swift, AppModel+ChatSessions.swift, AppModel+GraphCapabilityActions.swift, AppModel+HealthEmbeddings.swift, AppModel+MemoryActions.swift, AppModel+Refresh.swift and AppModel+RoutingWorkflowMCP.swift; resident-mind-convergence requires checkedRouteAdmission in ChatTurnRuntime/ChatOrchestrationClient+StreamFacade.swift. Left outside CORE-10 scope.
