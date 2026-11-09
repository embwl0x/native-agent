import Foundation
// Blueprint: | `FaceValueRegistry.swift` | Stable wire names for every Shared face value; unknown or ambiguous names fail decoding |

public struct FaceValueRegistration: Sendable {
    public let name: String
    fileprivate let type: ObjectIdentifier
    fileprivate let encode: @Sendable (AnyFaceValue) throws -> Data
    fileprivate let decode: @Sendable (Data) throws -> AnyFaceValue

    public init<Value: FaceValue>(_ value: Value.Type, name: String) {
        self.name = name
        type = ObjectIdentifier(value)
        encode = { erased in
            guard let value = erased.base as? Value else { throw FaceWireError.valueType(name) }
            return try JSONEncoder().encode(value)
        }
        decode = { data in AnyFaceValue(try JSONDecoder().decode(Value.self, from: data)) }
    }
}

public struct FaceValueRegistry: Sendable {
    private let registrations: [FaceValueRegistration]

    public init(registrations: [FaceValueRegistration]) { self.registrations = registrations }

    public func registering<Value: FaceValue>(_ type: Value.Type, name: String) throws -> FaceValueRegistry {
        guard !registrations.contains(where: { $0.name == name || $0.type == ObjectIdentifier(type) }) else {
            throw FaceWireError.duplicateValue(name)
        }
        return FaceValueRegistry(registrations: registrations + [.init(type, name: name)])
    }

    fileprivate func encode(_ value: AnyFaceValue) throws -> (String, Data) {
        let matches = registrations.filter { $0.type == ObjectIdentifier(Swift.type(of: value.base)) }
        guard matches.count == 1, let entry = matches.first else {
            throw FaceWireError.valueType(String(describing: Swift.type(of: value.base)))
        }
        return (entry.name, try entry.encode(value))
    }

    fileprivate func decode(name: String, data: Data) throws -> AnyFaceValue {
        let matches = registrations.filter { $0.name == name }
        guard let entry = matches.first else { throw FaceWireError.unknownValue(name) }
        guard matches.count == 1 else { throw FaceWireError.duplicateValue(name) }
        return try entry.decode(data)
    }

    public static var standard: FaceValueRegistry {
        FaceValueRegistry(registrations: [
            .init(ApprovalsFace.self, name: "approvals-face.v1"),
            .init(TranscriptFace.self, name: "transcript-face.v1"),
            .init(SystemToast.self, name: "system-toast.v1"),
            .init(SessionRowFace.self, name: "session-row-face.v1"),
            .init(SessionListFace.self, name: "session-list-face.v1"),
            .init(SessionSearchFace.self, name: "session-search-face.v1"),
            .init(SessionPaletteFace.self, name: "session-palette-face.v1"),
            .init(SessionNavigationFace.self, name: "session-navigation-face.v1"),
            .init(CountReading.self, name: "count-reading.v1"),
            .init(InboxCountsFace.self, name: "inbox-counts-face.v1"),
            .init(CountsFace.self, name: "counts-face.v1"),
            .init(PartFaceSnapshot.self, name: "part-face-snapshot.v1"),
            .init(PartFaceCatalog.self, name: "part-face-catalog.v1"),
            .init(ProviderSettingsSnapshot.self, name: "provider-settings-snapshot.v1"),
            .init(ProviderHelperPresentation.self, name: "provider-helper-presentation.v1"),
            .init(ProviderModelPresentation.self, name: "provider-model-presentation.v1"),
            .init(ProviderComposerPresentation.self, name: "provider-composer-presentation.v1"),
            .init(ProviderSessionPresentation.self, name: "provider-session-presentation.v1"),
            .init(ProviderSettingsFace.self, name: "provider-settings-face.v1"),
            .init(PanelFreshnessFace.self, name: "panel-freshness-face.v1"),
            .init(SettingsFace.self, name: "settings-face.v1"),
            .init(SoftwareUpdateSettingsFace.self, name: "software-update-settings-face.v1"),
            .init(SoftwareUpdateSettingsFace.Unavailability.self, name: "software-update-settings-face/unavailability.v1"),
            .init(SoftwareUpdateSettingsFace.Source.self, name: "software-update-settings-face/source.v1"),
            .init(TrustSettingsFace.self, name: "trust-settings-face.v1"),
            .init(PersonaSettingsFace.self, name: "persona-settings-face.v1"),
            .init(ConnectorSettingsFace.self, name: "connector-settings-face.v1"),
            .init(ConnectorSettingsFace.Slack.self, name: "connector-settings-face/slack.v1"),
            .init(PermissionSettingsFace.self, name: "permission-settings-face.v1"),
            .init(PermissionSettingsFace.Dock.self, name: "permission-settings-face/dock.v1"),
            .init(TurnFace.self, name: "turn-face.v1"),
            .init(TurnSessionsFace.self, name: "turn-sessions-face.v1"),
            .init(CountStatusValues.self, name: "count-status-values.v1"),
            .init(ActivityCaptureFace.self, name: "activity-capture-face.v1"),
            .init(ActivityCaptureFace.Availability.self, name: "activity-capture-face/availability.v1"),
            .init(TransportStatusFace.self, name: "transport-status-face.v1"),
            .init(EmbeddingDownloadStatus.self, name: "embedding-download-status.v1"),
            .init(EmbeddingDownloadFace.self, name: "embedding-download-face.v1"),
            .init(RuntimeStatusFace.self, name: "runtime-status-face.v1"),
            .init(RuntimeStatusFace.Tone.self, name: "runtime-status-face/tone.v1"),
            .init(LayoutFace.self, name: "layout-face.v1"),
            .init(ConversationFace.self, name: "conversation-face.v1"),
            .init(DocumentFace.self, name: "document-face.v1"),
            .init(AgentScreenFace.self, name: "agent-screen-face.v1"),
            .init(PaletteFace.self, name: "palette-face.v1"),
            .init(DeskPaletteFace.self, name: "desk-palette-face.v1"),
            .init(DeskDiagnosticsFace.self, name: "desk-diagnostics-face.v1"),
            .init(WorkDetailFace.self, name: "work-detail-face.v1"),
            .init(ContactsFace.self, name: "contacts-face.v1"),
            .init(ContactThreadFace.self, name: "contact-thread-face.v1"),
            .init(HelpersFace.self, name: "helpers-face.v1"),
            .init(HelperRunsFace.self, name: "helper-runs-face.v1"),
            .init(MakeShelfFace.self, name: "make-shelf-face.v1"),
            .init(MakePreviewFace.self, name: "make-preview-face.v1"),
            .init(SenseViewFace.self, name: "sense-view-face.v1"),
            .init(MemoryDiagnosticsFace.self, name: "memory-diagnostics-face.v1"),
            .init(KnowledgeGraphFace.self, name: "knowledge-graph-face.v1"),
            .init(FaceGraphNeighborhood.self, name: "graph-neighborhood-face.v1"),
            .init(DreamDiaryFace.self, name: "dream-diary-face.v1"),
            .init(DreamEntryFace.self, name: "dream-entry-face.v1"),
            .init(CognitionFace.self, name: "cognition-face.v1"),
            .init(ContextFlowHealthFace.self, name: "context-flow-health-face.v1"),
            .init(MoodFace.self, name: "mood-face.v1"),
            .init(InspectorFace.self, name: "inspector-face.v1"),
            .init(RunsFace.self, name: "runs-face.v1"),
            .init(RunFace.self, name: "run-face.v1"),
            .init(OnboardingFace.self, name: "onboarding-face.v1"),
            .init(ContextReceiptFace.self, name: "context-receipt-face.v1"),
            .init(MacControlFace.self, name: "mac-control-face.v1"),
            .init(VoiceFace.self, name: "voice-face.v1"),
        ])
    }

    fileprivate static func configured(in info: [CodingUserInfoKey: Any]) throws -> FaceValueRegistry {
        guard let key = CodingUserInfoKey.faceValueRegistry else { throw FaceWireError.registryConfiguration }
        guard let value = info[key] else { return .standard }
        guard let registry = value as? FaceValueRegistry else { throw FaceWireError.registryConfiguration }
        return registry
    }
}

extension CodingUserInfoKey {
    public static var faceValueRegistry: CodingUserInfoKey? { CodingUserInfoKey(rawValue: "NativeAgent.FaceValueRegistry") }
}

extension AnyFaceValue: Codable {
    private enum CodingKeys: String, CodingKey { case name, payload }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self = try FaceValueRegistry.configured(in: decoder.userInfo).decode(
            name: fields.decode(String.self, forKey: .name), data: fields.decode(Data.self, forKey: .payload))
    }

    public func encode(to encoder: any Encoder) throws {
        let (name, data) = try FaceValueRegistry.configured(in: encoder.userInfo).encode(self)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(name, forKey: .name)
        try fields.encode(data, forKey: .payload)
    }
}

public enum FaceWireError: Error, Sendable, LocalizedError {
    case unknownValue(String), duplicateValue(String), valueType(String), registryConfiguration
    case invalidFrameLength(UInt64), truncatedFrame, invalidFeedOrder, disconnected, io(Int32)

    public var errorDescription: String? {
        switch self {
        case .unknownValue(let name): "I sent an unknown face value: \(name). Install the matching body and face."
        case .duplicateValue(let name): "The face value name is registered more than once: \(name)."
        case .valueType(let name): "The face value has no unique registration: \(name)."
        case .registryConfiguration: "The face value registry configuration is invalid."
        case .invalidFrameLength(let count): "My face frame has an invalid byte length: \(count)."
        case .truncatedFrame: "My face pipe closed during a frame."
        case .invalidFeedOrder: "My face feed has a missing snapshot, epoch or sequence."
        case .disconnected: "My connection closed. Open the window again to reconnect."
        case .io(let code): "My face pipe failed (POSIX \(code))."
        }
    }
}
