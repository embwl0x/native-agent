import Foundation
import DeskCore
import MindCore
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import SenseCore
// Blueprint: | `DreamPart.swift` | Night-owned dream and REM policy calls; redacted evidence and checked returns before run accounting |

actor DreamPart {
    enum Key: NativeAgentCore.TurnPart { static let unset: DreamPart? = nil }
    enum Mode: String, Sendable { case dream, rem }
    enum Reading: Sendable {
        case dreamDrops(DreamPayload.Drops)
        case dream(DreamPayload, prose: String)
        case rem(REMConsolidator.Distillation)
    }

    static let id = "native-dream-cycle"
    let input: JSONValue
    let preview: Bool
    private let mode: Mode
    private let required: [String]
    private let remEntries: String?
    private let model: @Sendable (String) async throws -> (JSONValue, Reading?)
    private let validate: @Sendable (JSONValue, Reading?) throws -> Reading
    private var started = false
    private var answered = false
    private var modelFailure: (any Error)?
    private var modelReading: Reading?
    private(set) var reading: Reading?

    var rejectedModelResult: Bool {
        guard let failure = modelFailure else { return false }
        if failure is DecodingError || failure is PartCallError { return true }
        if case .remDecodeFailure? = failure as? DreamREMCycleError { return true }
        return false
    }

    init(mode: Mode, evidence: [String: String], required: [String], remEntries: String? = nil, preview: Bool = false,
         model: @escaping @Sendable (String) async throws -> (JSONValue, Reading?),
         validate: @escaping @Sendable (JSONValue, Reading?) throws -> Reading) {
        self.mode = mode
        self.preview = preview
        self.required = required.compactMap { evidence[$0] }
        self.remEntries = remEntries
        self.input = .object(["mode": .string(mode.rawValue), "evidence": .object(evidence.mapValues(JSONValue.string))])
        self.model = model
        self.validate = validate
    }

    static func redact(_ text: String) -> String {
        let redacted = TurnSecretRedactor.redactText(text)
        return NativeAgentSecretRedactor.containsAuditSecret(redacted) ? "[REDACTED]" : redacted
    }

    static func redactOutput(_ value: JSONValue) -> JSONValue {
        MemoryManagerAct.redactDigestEvidence(value).mapStrings(Self.redact)
    }

    func read(root: URL, parent: Turn? = nil) async throws -> Reading {
        let surface = mode.rawValue
        let envelope = parent?.envelope ?? TurnEnvelope.native("background:" + surface, surface: surface)
        var turn = parent ?? Turn(dataRoot: root, session: surface)
        let engine = NativeAgentEngine.forRoot(root)
        if turn[AppActionBinding.Parts.self] == nil {
            turn[AppActionBinding.Parts.self] = engine.partBinding
        }
        turn[Key.self] = self
        let input = self.input
        let result = try await engine.withPartDoor(
            envelope: envelope, fileAccess: turn.fileAccess ?? "auto", turn: turn
        ) { door in
            await Parts(root: root).call(id: Self.id, input: input,
                within: .init(actions: [], capabilities: [.model]), invocation: door.invocation, as: JSONValue.self)
        }
        switch result {
        case .success:
            guard let reading else {
                throw PartCallError(code: "bad_dream_policy", message: "The dream cycle did not settle a verified result.")
            }
            return reading
        case .failure(let error) where error.code == "cancelled":
            if let reading { return reading }
            throw CancellationError()
        case .failure(let error):
            if let modelFailure { throw modelFailure }
            throw error
        }
    }

    func judge(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        guard !started, arguments["purpose"] == .string(mode.rawValue),
              let prompt = arguments["prompt"]?.stringValue,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              required.allSatisfy({ $0.isEmpty || prompt.contains($0) }) else {
            throw PartCallError(code: "bad_dream_policy", message: "The dream cycle may call its model once with its mode and the required evidence intact.")
        }
        let modelPrompt: String
        switch mode {
        case .dream:
            guard arguments.count == 2 else {
                throw PartCallError(code: "bad_dream_policy", message: "Dream model input takes purpose and prompt.")
            }
            modelPrompt = prompt
        case .rem:
            guard arguments.count == 3, let beforeEntries = arguments["beforeEntries"]?.stringValue, let remEntries else {
                throw PartCallError(code: "bad_dream_policy", message: "REM model input takes purpose, beforeEntries and prompt.")
            }
            modelPrompt = beforeEntries + remEntries + prompt
        }
        guard NativeAgentSecretRedactor.secretPath(.string(modelPrompt)) == nil else {
            throw PartCallError(code: "secret_in_input", message: "The composed dream prompt carries a credential.")
        }
        started = true
        do {
            let (reply, reading) = try await model(modelPrompt)
            let value = Self.redactOutput(reply)
            guard NativeAgentSecretRedactor.secretPath(value) == nil else {
                throw PartCallError(code: "secret_in_output", message: "The model answer carries a credential.")
            }
            answered = true
            modelReading = reading
            return value
        } catch {
            modelFailure = error
            throw error
        }
    }

    func verify(_ value: JSONValue) throws -> Reading {
        guard answered, value.objectValue?["status"] != .string("refused"),
              NativeAgentSecretRedactor.secretPath(value) == nil else {
            throw PartCallError(code: "bad_dream_policy", message: "The dream cycle must return a safe result after an accepted model answer.")
        }
        return try validate(value, modelReading)
    }

    func keep(_ reading: Reading) { self.reading = reading }
}
