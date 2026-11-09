import Foundation
import Observation
import SwiftUI
// Blueprint: | `FaceProtectedForm.swift` | Transient secret fields use named native receivers outside page edits and retained operations |

/// This value is never encoded or retained by a page session.
public struct FaceProtectedSubmission {
    public let submission: FaceActSubmission
    public let secrets: [String: Data]
}

public enum FaceSecretRedaction {
    public static func text(_ value: String, secrets: [Data]) -> String {
        var result = value
        for bytes in secrets {
            let raw = String(decoding: bytes, as: UTF8.self)
            let candidates = [raw, raw.trimmingCharacters(in: .whitespacesAndNewlines), raw.filter { !$0.isWhitespace }]
            for secret in candidates where !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "[redacted]") }
            // A routine's URL and key are secret independently of their JSON envelope.
            if raw.first(where: { !$0.isWhitespace }) == "{" {
                do {
                    let fields = try JSONDecoder().decode([String: String].self, from: bytes)
                    for field in ["url", "key"] {
                        if let secret = fields[field], !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "[redacted]") }
                    }
                } catch {
                    // Partial scrubbing cannot protect fields inside an unreadable envelope.
                    // Withhold the whole feedback; decoder diagnostics may contain the entry too.
                    return "Protected feedback is unavailable because the credential envelope could not be decoded."
                }
            }
        }
        return TurnSecretRedactor.redactText(result)
    }
}

public enum FaceCredentialRead: Codable, Sendable {
    case provider(ProviderConnectionWrite)
    case providerRemoval(String)
    case anthropic(Data)
    case slack(ConnectorCredentialWrite)
    case grok(GrokCredentialWrite)
    case keyring(PageActRequest, secret: Data)

    public var secrets: [Data] {
        switch self {
        case .provider(let request): request.secret.map { [$0] } ?? []
        case .providerRemoval: []
        case .anthropic(let secret), .keyring(_, let secret): [secret]
        case .slack(let request): Array(request.fields.values)
        case .grok(let request): [request.secret]
        }
    }
}

extension FaceActOutcome {
    public static func protectedCommit(_ reply: FaceActReply, words: String, fields: [FaceCommittedField]) throws -> Self {
        guard case .committed(let result) = reply else {
            throw WireFailure(code: "credential_unconfirmed", message: "The credential owner did not confirm the save.",
                cause: nil, effects: .unknown)
        }
        if var issue = result.publicationFailure {
            issue.committed = fields
            throw issue
        }
        return .init(words: words, effects: result.effects, accepted: true, committed: fields)
    }
}

public enum FaceSecretReceiver: Equatable, Sendable {
    case saveProviderConnection, saveConnectorCredentials, importGrokCredentials, saveAnthropicSetupToken
    case answerCard
    case keyring(String)

    public var name: String {
        switch self {
        case .saveProviderConnection: "saveProviderConnection"
        case .saveConnectorCredentials: "saveConnectorCredentials"
        case .importGrokCredentials: "importGrokCredentials"
        case .saveAnthropicSetupToken: "saveAnthropicSetupToken"
        case .answerCard: "answerCard"
        case .keyring(let name): "keyring:" + name
        }
    }
}

@MainActor @Observable final class FaceSecretEntry {
    var values: [String: Data] = [:]
    var revisions: [String: UUID] = [:]
    var generation = UUID()
    var reads: [UUID: (FaceActSubmission) async -> FaceActOutcome] = [:]
    var mounted = true
    var lifetime = UUID()

    func binding(_ field: String) -> Binding<String> {
        Binding(get: { String(decoding: self.values[field] ?? Data(), as: UTF8.self) }, set: {
            self.values[field] = Data($0.utf8)
            self.revisions[field] = UUID()
            self.generation = UUID()
        })
    }
    func clear() { values.removeAll(); revisions.removeAll(); reads.removeAll(); generation = UUID(); lifetime = UUID() }
}

@MainActor struct FaceSecretFormContext {
    let receiver: FaceSecretReceiver
    let entry: FaceSecretEntry
    let perform: (FaceProtectedSubmission) async -> FaceActOutcome
    let validationFree: Set<String>

    func admits(_ block: PartFace.Block) -> Bool {
        block.protected == true && block.receiver == receiver.name && block.doors == ["mac"]
            && block.fields?.allSatisfy { $0.kind != "secret" || $0.value == nil } == true
    }

    func submit(_ block: PartFace.Block, section: String, action: PartFace.Action, session: FacePageSession) {
        let plain = block.withoutSecrets
        let values = session.formValues(plain, section: section)
        let validating = !validationFree.contains(action.id)
        var errors = validating ? plain.formIssues(values: values) : [:]
        for field in block.fields ?? [] where validating && field.kind == "secret" && field.required == true {
            if entry.values[field.id]?.isEmpty != false { errors[field.id] = field.label + " is required." }
        }
        session.formErrors[block.key] = errors
        guard errors.isEmpty else { return }
        let secrets = entry.values, revisions = entry.revisions, generation = entry.generation, lifetime = entry.lifetime
        func clearCommitted(_ outcome: FaceActOutcome) {
            guard entry.mounted, entry.lifetime == lifetime else { return }
            for field in outcome.committed ?? [] where secrets[field.id] != nil && entry.revisions[field.id] == revisions[field.id] {
                entry.values[field.id] = nil
                entry.revisions[field.id] = nil
            }
        }
        let door = ClosureFaceDoor(open: { _ in }, waitingOn: "the credential owner") { submission in
            let outcome = await perform(.init(submission: submission, secrets: secrets))
            var clean = Self.scrub(outcome, secrets: secrets)
            if clean.unresolved, entry.mounted, entry.lifetime == lifetime {
                entry.reads[submission.id] = { check in
                    let outcome = Self.scrub(await perform(.init(submission: check, secrets: secrets)), secrets: secrets)
                    clearCommitted(outcome)
                    return outcome
                }
            } else { entry.reads[submission.id] = nil }
            // A check describes only the displayed input, never a later edit.
            if receiver == .saveProviderConnection, action.id == "test",
               entry.generation != generation || session.formValues(plain, section: section) != values {
                clean.words = nil
            }
            clearCommitted(clean)
            return clean
        }
        session.submitForm(plain, section: section, action: action, door: door, validating: validating)
    }

    static func scrub(_ outcome: FaceActOutcome, secrets: [String: Data]) -> FaceActOutcome {
        func text(_ value: String) -> String {
            FaceSecretRedaction.text(value, secrets: Array(secrets.values))
        }
        func scrubValue(_ input: PartFace.Value) -> PartFace.Value {
            switch input {
            case .string(let words): .string(text(words))
            case .array(let values): .array(values.map { scrubValue($0) })
            case .object(let fields): .object(fields.mapValues { scrubValue($0) })
            case .int, .double, .bool, .null: input
            }
        }
        var result = outcome
        result.words = result.words.map(text)
        if var failure = result.failure {
            failure.message = text(failure.message)
            failure.cause = failure.cause.map(text)
            failure.fields = failure.fields?.mapValues(text)
            failure.committed = failure.committed?.map { .init(id: $0.id) }
            result.failure = failure
        }
        result.committed = result.committed?.map { field in
            secrets[field.id] == nil ? .init(id: field.id, value: field.value.map { scrubValue($0) }) : .init(id: field.id)
        }
        result.undo = nil
        return result
    }
}

private struct FaceSecretFormKey: EnvironmentKey {
    static let defaultValue: FaceSecretFormContext? = nil
}
private struct FaceProtectedPresentationKey: EnvironmentKey {
    static let defaultValue: (@MainActor (PartFace.Block) -> AnyView)? = nil
}
extension EnvironmentValues {
    public var faceProtectedEntry: (@MainActor (PartFace.Block) -> AnyView)? {
        get { self[FaceProtectedPresentationKey.self] }
        set { self[FaceProtectedPresentationKey.self] = newValue }
    }
    var faceSecretForm: FaceSecretFormContext? {
        get { self[FaceSecretFormKey.self] }
        set { self[FaceSecretFormKey.self] = newValue }
    }
}

/// Mount only inside the platform's acknowledged protected-window leaf.
public struct FaceProtectedForm: View {
    private let face: PartFace
    private let receiver: FaceSecretReceiver
    private let session: FacePageSession
    private let perform: (FaceProtectedSubmission) async -> FaceActOutcome
    private let validationFree: Set<String>
    private let opening: (String) -> Void
    private let closing: (() -> Void)?
    @State private var entry = FaceSecretEntry()
    @State private var discarding = false

    public init(face: PartFace, receiver: FaceSecretReceiver, session: FacePageSession,
                validationFree: Set<String> = [], close: (() -> Void)? = nil, open: @escaping (String) -> Void = { _ in },
                perform: @escaping (FaceProtectedSubmission) async -> FaceActOutcome) {
        self.face = face; self.receiver = receiver; self.session = session; self.validationFree = validationFree; self.perform = perform
        opening = open
        closing = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FaceView(face: face, door: readingDoor, session: session)
            if let closing {
                Button("Done") {
                    if hasSecret { discarding = true } else { closing() }
                }.disabled(pending)
            }
        }
            .environment(\.faceSecretForm, FaceSecretFormContext(receiver: receiver, entry: entry, perform: perform, validationFree: validationFree))
            .interactiveDismissDisabled(closing != nil && (hasSecret || pending))
            .confirmationDialog("Close without saving the entry?", isPresented: $discarding, titleVisibility: .visible) {
                Button("Discard entry", role: .destructive) { closing?() }
                Button("Keep editing", role: .cancel) {}
            }
            .onAppear { entry.mounted = true }
            .onDisappear {
                for block in face.sections.compactMap(\.block) { session.cancel(.init(section: "face:" + block.key, row: block.key)) }
                entry.mounted = false; entry.clear()
            }
            .onChange(of: face.sections.compactMap { $0.block?.key }) { old, _ in
                for key in old { session.cancel(.init(section: "face:" + key, row: key)) }
                entry.clear()
            }
            .onChange(of: face.sections.flatMap { ($0.block?.fields ?? []).filter { $0.kind == "secret" }.map(\.id) }) { entry.clear() }
    }
    private var hasSecret: Bool { entry.values.values.contains { !$0.isEmpty } }
    private var pending: Bool { session.operations.values.contains { $0.outcome == nil || $0.checking } }
    private var readingDoor: ClosureFaceDoor {
        ClosureFaceDoor(open: opening, waitingOn: "the credential owner") { submission in
            guard submission.checking, let read = entry.reads[submission.id] else {
                return .init(words: "The protected entry has closed. Reopen setup to read its saved status.", effects: .unknown)
            }
            let outcome = await read(submission)
            if !outcome.unresolved { entry.reads[submission.id] = nil }
            return outcome
        }
    }
}

extension PartFace.Block {
    var withoutSecrets: Self {
        .init(kind: kind, key: key, revision: revision, fields: fields?.filter { $0.kind != "secret" }, submit: submit, doors: doors)
    }
}
