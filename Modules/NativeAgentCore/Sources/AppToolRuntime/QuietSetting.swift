import Foundation
import PersistenceCore
import AgentConversations
import AuthoredCapabilities
import ChatToolRuntime
import MacIntegration
import NativeAgentCore
import PersonaEngine
import Senses
import ToolRegistry
import MultimodalTTS
import ChatSessionWork
import Cognition
import Context
import AttentionRouting
import NativeAgentShared
import ProviderRouting
import DeviceSync
import TrustCenter
import AgentWorkspace
import ChatTurnContracts
import ChromeControl
import MemoryV2
import StandingBots
import TurnTrace
import Studio
import DreamREMCycle
// Blueprint: | `QuietSetting.swift` | Throwing read/choice contract, explicit turn-bound writes, checked Trust and MainActor receipt detail |

public typealias QuietSettingsHostProvider = @MainActor @Sendable () -> (any QuietSettingsHost)?

public enum QuietSettingError: Error, LocalizedError {
    /// A rejected value, before any mutation. Failed saves are unavailable.
    case badValue(String)
    case unavailable(String)
    /// Trust raises are the user's decision and refuse as owners_call.
    case users(String)

    public var errorDescription: String? {
        switch self {
        case .badValue(let detail): return detail
        case .unavailable(let detail): return detail
        case .users(let detail): return detail
        }
    }
}

/// Multi-surface writes record their actual reach in the transcript receipt, not a second ledger.
/// Main-actor detail is taken exactly once per call so concurrent writes cannot borrow each other's evidence.
@MainActor
public final class QuietWriteDetail {
    private var pending: [String: JSONValue] = [:]

    public init() {}

    public func record(_ key: String, _ value: JSONValue) { pending[key] = value }

    public func take() -> [String: JSONValue] {
        defer { pending = [:] }
        return pending
    }
}

/// One setting mutation holds its admitted turn and its own receipt accumulator.
public struct QuietSettingWrite: Sendable {
    public let turn: Turn
    public let detail: QuietWriteDetail

    public init(turn: Turn, detail: QuietWriteDetail) {
        self.turn = turn
        self.detail = detail
    }
}

/// Register each control once with its page-owned read/write; absent controls must never be guessed or reflected into writes.
public struct QuietSetting: Sendable {
    public enum Kind: String, Sendable {
        case boolean, text, choice, number
        /// List writes replace the desired list; both arrays and newline-separated text share that operation.
        case list
    }

    public let id: String
    public let page: String
    /// nil selects the first tab; stored tab keys keep navigation aligned with the page.
    public private(set) var tab: String?
    public let label: String
    public let kind: Kind
    /// Publish nonempty choice values so callers need not discover them through refused writes.
    public let choices: [String]
    /// Catalog and validation share one runtime choice owner so separate lists cannot drift.
    public let liveChoices: (@MainActor @Sendable (@escaping QuietSettingsHostProvider) async throws -> [String])?
    public let note: String
    /// User-owned posture rows stay readable but reject agent writes so self-administration cannot widen its own authority.
    public let ownerOnly: Bool
    /// The agent's own thought and memory controls do not ask for a person's request or Trust posture.
    public private(set) var mindOwned = false
    /// The preference owner this row reads; page invalidation watches only its declared keys.
    public private(set) var defaultsKey: String?
    /// Page reads list remote settings without waiting on another device; setting.get performs that read.
    public let readsAnotherDevice: Bool
    public let read: @MainActor @Sendable (any QuietSettingsHost) async throws -> JSONValue
    /// File-backed reads name their owner without retaining the mounted host.
    public private(set) var storedRead: StoredRead?
    public let write: (@MainActor @Sendable (any QuietSettingsHost, JSONValue, QuietSettingWrite) async throws -> Void)?
    /// Preview shares the read-only direction/value rule that write checks before mutation.
    public let check: (@MainActor @Sendable (any QuietSettingsHost, JSONValue, Turn) async -> QuietSettingError?)?

    public init(
        id: String,
        page: String,
        label: String,
        kind: Kind,
        choices: [String] = [],
        liveChoices: (@MainActor @Sendable (@escaping QuietSettingsHostProvider) async throws -> [String])? = nil,
        note: String = "",
        ownerOnly: Bool = false,
        readsAnotherDevice: Bool = false,
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async throws -> JSONValue,
        write: (@MainActor @Sendable (any QuietSettingsHost, JSONValue, QuietSettingWrite) async throws -> Void)? = nil,
        check: (@MainActor @Sendable (any QuietSettingsHost, JSONValue, Turn) async -> QuietSettingError?)? = nil
    ) {
        self.id = id
        self.page = page
        self.label = label
        self.kind = kind
        self.choices = choices
        self.storedRead = nil
        self.liveChoices = liveChoices
        self.note = note
        self.ownerOnly = ownerOnly
        self.readsAnotherDevice = readsAnotherDevice
        self.read = { host in
            if page == "trust", host.trustPolicy == nil {
                throw QuietSettingError.unavailable("Trust policy is unavailable. Read Trust and repair its reported policy error before reading this control.")
            }
            return try await read(host)
        }
        self.check = check
        if let write {
            self.write = { @MainActor @Sendable host, value, context in
                if page == "trust", host.trustPolicy == nil {
                    throw QuietSettingError.unavailable("""
                        Trust policy is unavailable. Read Trust and repair its reported policy error before changing this control.
                        """)
                }
                if let refused = await check?(host, value, context.turn) { throw refused }
                try await write(host, value, context)
            }
        } else {
            self.write = nil
        }
    }

    public init(
        id: String, page: String, label: String, kind: Kind,
        note: String = "", read: StoredRead,
        write: (@MainActor @Sendable (any QuietSettingsHost, JSONValue, QuietSettingWrite) async throws -> Void)? = nil
    ) {
        self.init(id: id, page: page, label: label, kind: kind, note: note,
                  read: { host in try await read.value(dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot()) },
                  write: write)
        self.storedRead = read
    }

    /// Only values cross into a page builder; registry closures (including platform writers) stay with the host.
    public struct Descriptor: Sendable {
        public let id: String
        public let label: String
        public let kind: Kind
        public let note: String
        public let editable: Bool
    }

    public var descriptor: Descriptor {
        Descriptor(id: id, label: label, kind: kind, note: note, editable: write != nil && !readsAnotherDevice)
    }

    public struct ReadSnapshot: Sendable {
        public enum Reading: Sendable {
            case value(JSONValue)
            case stored(StoredRead)
            case unavailable(String)
        }
        public let setting: Descriptor
        public let choices: [String]?
        public let reading: Reading

        public func value(dataRoot: URL) async throws -> JSONValue {
            switch reading {
            case .value(let value): return value
            case .stored(let read): return try await read.value(dataRoot: dataRoot)
            case .unavailable(let problem): throw QuietSettingError.unavailable(problem)
            }
        }
    }

    /// In-memory reads and choices are copied together in the face's one host hop. No file reader runs here.
    @MainActor
    public func snapshot(host: any QuietSettingsHost) async throws -> ReadSnapshot {
        var offered: [String]?
        let reading: ReadSnapshot.Reading
        do {
            if kind == .choice { offered = try await liveChoices?({ host }) ?? choices }
            if let storedRead { reading = .stored(storedRead) }
            else { reading = .value(try await read(host)) }
        } catch is CancellationError { throw CancellationError() }
        catch { reading = .unavailable(error.localizedDescription) }
        return ReadSnapshot(setting: descriptor, choices: offered, reading: reading)
    }

    /// The same typed reader serves setting.get/write readback and the host-free Settings face.
    public enum StoredRead: Sendable {
        case multimodal(KeyPath<TrustMultimodalPolicy, Bool> & Sendable)
        case memory(KeyPath<TrustMemoryPolicy, Bool> & Sendable)
        case dreams
        case remCycle
        case meaningBasedMemory

        @concurrent public func value(dataRoot: URL) async throws -> JSONValue {
            try Task.checkCancellation()
            switch self {
            case .multimodal(let key):
                let policy = try await QuietSettings.readMindPolicy(root: dataRoot)
                return .bool((policy.multimodalPolicy ?? TrustMultimodalPolicy())[keyPath: key])
            case .memory(let key):
                let policy = try await QuietSettings.readMindPolicy(root: dataRoot)
                return .bool((policy.memoryPolicy ?? TrustMemoryPolicy())[keyPath: key])
            case .dreams:
                let policy = try SwiftNativeTrustCenter(dataRoot: dataRoot).loadSavedPolicyChecked()
                return .bool(try DreamREMGatePolicy(policy: policy).dreamEnabled)
            case .remCycle:
                let policy = try await QuietSettings.readMindPolicy(root: dataRoot)
                return .bool(policy.trainingPolicy?.rem_cycle_enabled ?? true)
            case .meaningBasedMemory:
                let owner = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
                let runtime: ManagedEmbeddingProvider
                do { runtime = try await owner.managedEmbeddingRuntime() }
                catch is CancellationError { throw CancellationError() }
                catch {
                    throw QuietSettingError.unavailable(error.localizedDescription
                        + " Open Memories and repair its reported storage problem before reading this setting.")
                }
                let snapshot = runtime.snapshot()
                guard snapshot.requestedBackend != ManagedEmbeddingProvider.failClosedBackend else {
                    throw QuietSettingError.unavailable((snapshot.lastLoadError ?? "The saved embeddings configuration could not be read.")
                        + " Repair config/embeddings.json in the app data folder before reading or changing meaning-based memory.")
                }
                return .bool(snapshot.requestedBackend != ManagedEmbeddingProvider.mockBackend)
            }
        }
    }

    public func onTab(_ tab: String) -> QuietSetting {
        var row = self
        row.tab = tab
        return row
    }

    public func watchingDefaults(_ key: String) -> QuietSetting {
        var row = self
        row.defaultsKey = key
        return row
    }

    public func ownedByMind() -> QuietSetting {
        var row = self
        row.mindOwned = true
        return row
    }

    /// The agent may write a row that is not the person's alone; which direction a write goes is the row's own check, at any posture.
    public var writable: Bool { !ownerOnly && write != nil }

    public func catalogRow(host: @escaping QuietSettingsHostProvider) async throws -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id),
            "page": .string(page),
            "label": .string(label),
            "type": .string(kind.rawValue),
            "writable": .bool(writable),
        ]
        let offered = try await (liveChoices?(host) ?? choices)
        if !offered.isEmpty { row["choices"] = .array(offered.map { .string($0) }) }
        let guidance = mindOwned ? "Yours to set in either direction; no request needed." : ""
        let notes = [guidance, note].filter { !$0.isEmpty }
        if !notes.isEmpty { row["note"] = .string(notes.joined(separator: " ")) }
        if ownerOnly {
            row["owner_only"] = .bool(true)
            row["refusal"] = .string(QuietSettings.ownerOnlyRefusal)
        }
        return .object(row)
    }
}
