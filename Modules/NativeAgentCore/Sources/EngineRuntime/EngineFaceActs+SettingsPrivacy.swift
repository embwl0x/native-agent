import Foundation
import NativeAgentShared
import Privacy
// Blueprint: | `EngineFaceActs+SettingsPrivacy.swift` | Typed credential redaction for body failures and probe replies before either face transport |

extension EngineFaceActs {
    static func redactedValue(_ value: PartFace.Value, act: FaceAct) -> PartFace.Value {
        switch value {
        case .string(let text):
            return .string(redacted(.init(code: "credential_text", message: text, cause: nil, effects: .none), act: act).message)
        case .array(let values): return .array(values.map { redactedValue($0, act: act) })
        case .object(let fields): return .object(fields.mapValues { redactedValue($0, act: act) })
        case .int, .double, .bool, .null: return value
        }
    }
    static func redacted(_ failure: WireFailure, act: FaceAct) -> WireFailure {
        let secrets: [Data]
        switch act {
        case .savePageSecret(_, let secret): secrets = [secret]
        case .readCredential(let request): secrets = request.secrets
        case .saveProviderConnection(let request): secrets = request.secret.map { [$0] } ?? []
        case .testProvider(let request): secrets = request.secret.map { [$0] } ?? []
        case .saveAnthropicSetupToken(let secret): secrets = [secret]
        case .answerCard(let answer): secrets = Array(answer.secrets.values)
        case .saveConnectorCredentials(let request): secrets = Array(request.fields.values)
        case .configureTelegram(let request): secrets = request.token.map { [$0] } ?? []
        case .saveSlackIngress(let request): secrets = request.token.map { [$0] } ?? []
        case .importGrokCredentials(let request): secrets = [request.secret]
        // These open value maps can carry submitted text; their owners decide its meaning.
        case .pageAct(let request):
            secrets = request.value.map(secretText) ?? []
        case .inboxAction(_, _, let value): secrets = value.map(secretText) ?? []
        case .saveMemoryPolicy(let request): secrets = request.fields.values.flatMap(secretText)
        case .saveMultimodalPolicy(let request): secrets = request.fields.values.flatMap(secretText)
        case .runMacControl(let request): secrets = request.arguments.values.flatMap(secretText)
        case .setActivityPolicy(let request): secrets = request.fields.values.flatMap(secretText)
        case .deskCommand(let request): secrets = request.arguments.values.flatMap(secretText)
        case .senseViewEvent(_, _, let value): secrets = secretText(value)
        // Protocol, observation, navigation and transcript receipts carry identities, queries and geometry.
        case .attach, .observe, .unobserve, .refresh, .frameApplied, .cancelRequest,
             .restoreConversation, .createConversation, .selectConversation, .markConversationRead,
             .archiveConversation, .clearConversation, .pinConversation, .unpinConversation,
             .stop, .regenerate, .prepareRetryDraft, .exportConversation, .appendSlashHelp,
             .requestDocument, .readRun, .requestCopy, .setSurfaceExpanded, .openTranscriptReader,
             .resizeTranscriptReader, .releaseTranscriptReader, .transcriptReceipt, .setTranscriptFold,
             .firstVisibleReply, .declarePreferences:
            secrets = []
        // Account operations carry ids, consent or choices; credentials use the typed cases above.
        case .readProviderAccount, .saveChatChoice, .disconnectProvider, .beginOAuth, .signOutProvider, .decideCodexCLIConsent,
             .repairCodexCLIConsent, .verifyCardOnReturn, .setConnectorEnabled, .disconnectConnector,
             .testTelegram, .clearTelegramLogs, .repairTelegram, .removePhonePairing, .setUpChrome:
            secrets = []
        // Named app preferences, policy and maintenance carry decisions, identifiers, counts and declared modes.
        case .setPreference, .resolveApproval, .applyTrustPreset, .setAutonomyEnabled, .setChromeControlEnabled, .setKillSwitchEnabled,
             .saveMacIntegrationPreset, .saveMacControlPolicy, .authorizeSafePolicy, .refreshPrivacyInventory,
             .checkMail, .requestMacOSAccess, .openMacOSSettings, .excludeActivityApp, .removeActivityExclusion,
             .wipeActivity, .setInboxTrigger, .createBackup, .restoreBackup, .createProductionExport, .runDoctor,
             .requestSupportSnapshot, .setEmbeddingDownload, .setEmbeddingsEnabled, .reindexSpotlight,
             .requestUpdate, .updateInteraction, .pinMemory, .forgetMemory, .resolveMemoryProposal,
             .cognition, .runDream, .runREM,
             .setDreamCycleEnabled, .setREMCycleEnabled, .setInnerLifeEnabled, .setContextFlowMode:
            secrets = []
        // Authored conversation, memory, persona and work content has no credential field.
        case .renameConversation, .send, .notify, .remember, .commitNote, .writeScratch, .searchMemories,
             .readPersona, .savePersonaProfile, .savePersonaName, .savePersonaDocument, .createStarterPersona, .onboarding,
             .createDeskTask, .addDeskNote, .research, .exportMake, .sendContactMessage, .stopContactMessage,
             .resendContactMessage, .withdrawContactMessage, .ingestAttachment, .captureScreen, .openBrowser, .voice:
            secrets = []
        // Renderer reports and notification responses carry presentation facts and ordinary message text.
        case .handBackMacControl, .reportScene, .reportProtectedWindows, .reportOverlayWindow, .reportInspector,
             .reportRendererDiagnostic, .notificationResponse, .quitBody, .restartBody:
            secrets = []
        }
        func scrub(_ value: String) -> String {
            NativeAppSecretRedactor.redactText(FaceSecretRedaction.text(value, secrets: secrets))
        }
        var clean = failure
        clean.message = scrub(failure.message)
        clean.cause = failure.cause.map(scrub)
        clean.fields = failure.fields?.mapValues(scrub)
        clean.committed = failure.committed?.map { field in
            if case .saveProviderConnection = act, ["authMode", "model"].contains(field.id) {
                return FaceCommittedField(id: field.id, value: field.value.map { redactedValue($0, act: act) })
            }
            return FaceCommittedField(id: field.id)
        }
        return clean
    }

    private static func secretText(_ value: PartFace.Value) -> [Data] {
        switch value {
        case .string(let text): return [Data(text.utf8)]
        case .array(let values): return values.flatMap(secretText)
        case .object(let fields): return fields.values.flatMap(secretText)
        case .int, .double, .bool, .null: return []
        }
    }
}
