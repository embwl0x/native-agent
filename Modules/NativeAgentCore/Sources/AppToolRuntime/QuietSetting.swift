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
// Blueprint: | `QuietSetting.swift` | QuietSetting value and read/write contract, setting errors, host provider and MainActor write receipt detail |

public typealias QuietSettingsHostProvider = @MainActor @Sendable () -> (any QuietSettingsHost)?

public enum QuietSettingError: Error, LocalizedError {
    /// A rejected value, before any mutation. Failed saves are unavailable.
    case badValue(String)
    case unavailable(String)
    /// The value would raise Trust: User's call, refused as `owners_call`.
    case users(String)

    public var errorDescription: String? {
        switch self {
        case .badValue(let detail): return detail
        case .unavailable(let detail): return detail
        case .users(let detail): return detail
        }
    }
}

/// Extra lines a write leaves for its own receipt.
///
/// A setting that covers several surfaces changes more than its own row, and `app_setting_set` cannot see that from the lead value it reads
/// back. The write records what it actually touched here, and the tool folds it into the receipt — the same trail, no second ledger.
/// Main-actor only, and taken exactly once per call, so two writes cannot read each other's detail.
@MainActor
public final class QuietWriteDetail {
    @TaskLocal public static var current: QuietWriteDetail?
    private var pending: [String: JSONValue] = [:]

    public init() {}

    public static func record(_ key: String, _ value: JSONValue) { current?.pending[key] = value }

    public func take() -> [String: JSONValue] {
        defer { pending = [:] }
        return pending
    }
}

/// One control on one page, named so the model never has to guess.
///
/// A setting is registered ONCE, with the read that answers what the page shows and the write that the page's own control calls. There is
/// no reflection and no key-guessing: `app_settings_list` returns exactly this registry, so a control that is not here is honestly reported
/// as absent rather than silently attempted.
public struct QuietSetting: Sendable {
    public enum Kind: String, Sendable {
        case boolean, text, choice, number
        /// An ordered list of lines. Read back as an array; written as an array, or as one string of newline-separated lines. Add and
        /// remove are the same operation — send the list you want.
        case list
    }

    public let id: String
    public let page: String
    /// The page's tab the control is on, by the key the page stores; nil is the page's first tab. ⌘K opens the control there.
    public private(set) var tab: String?
    public let label: String
    public let kind: Kind
    /// Non-empty for `.choice`. Stated in the catalog so a set never has to discover the allowed values by being refused.
    public let choices: [String]
    /// Choices that only exist at run time — the accounts this Mac has actually connected. The catalog reports exactly what the write
    /// enforces, out of one closure, so a set can never be refused for a value `app_settings_list` had just offered.
    public let liveChoices: (@MainActor @Sendable (@escaping QuietSettingsHostProvider) async -> [String])?
    public let note: String
    /// The person's own posture. These READ like any other setting and refuse to be written, saying why — the agent widening its own
    /// authority is the one thing self-administration must not be able to do.
    public let ownerOnly: Bool
    /// Writable only in Full Mac, with receipts; raising to Full Mac remains the owner's call.
    public let fullMacOnly: Bool
    public let read: @MainActor @Sendable (any QuietSettingsHost) async -> JSONValue
    public let write: (@MainActor @Sendable (any QuietSettingsHost, JSONValue) async throws -> Void)?
    /// The rule a value must pass before it is written (which way a lower-only switch may move, what a narrow-only list may gain), read
    /// only. `write` asks it first, and the door's preview asks it alone, so a preview refuses what the write would.
    public let check: (@MainActor @Sendable (any QuietSettingsHost, JSONValue) async -> QuietSettingError?)?

    public init(
        id: String,
        page: String,
        label: String,
        kind: Kind,
        choices: [String] = [],
        liveChoices: (@MainActor @Sendable (@escaping QuietSettingsHostProvider) async -> [String])? = nil,
        note: String = "",
        ownerOnly: Bool = false,
        fullMacOnly: Bool = false,
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async -> JSONValue,
        write: (@MainActor @Sendable (any QuietSettingsHost, JSONValue) async throws -> Void)? = nil,
        check: (@MainActor @Sendable (any QuietSettingsHost, JSONValue) async -> QuietSettingError?)? = nil
    ) {
        self.id = id
        self.page = page
        self.label = label
        self.kind = kind
        self.choices = choices
        self.liveChoices = liveChoices
        self.note = note
        self.ownerOnly = ownerOnly
        self.fullMacOnly = fullMacOnly
        self.read = read
        self.check = check
        if let write {
            self.write = { @MainActor @Sendable host, value in
                if let refused = await check?(host, value) { throw refused }
                try await write(host, value)
            }
        } else {
            self.write = nil
        }
    }

    /// The same control, on `tab` of its page.
    public func onTab(_ tab: String) -> QuietSetting {
        var row = self
        row.tab = tab
        return row
    }

    /// Whether a set would be accepted RIGHT NOW. `fullMac` is the posture read fresh off the saved policy, so the catalog's `writable` and
    /// the answer `app_setting_set` gives are one answer.
    public func writable(fullMac: Bool) -> Bool {
        guard !ownerOnly, write != nil else { return false }
        return fullMac || !fullMacOnly
    }

    public func catalogRow(fullMac: Bool, host: @escaping QuietSettingsHostProvider) async -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id),
            "page": .string(page),
            "label": .string(label),
            "type": .string(kind.rawValue),
            "writable": .bool(writable(fullMac: fullMac)),
        ]
        let offered = await (liveChoices?(host) ?? choices)
        if !offered.isEmpty { row["choices"] = .array(offered.map { .string($0) }) }
        if !note.isEmpty { row["note"] = .string(note) }
        if ownerOnly {
            row["owner_only"] = .bool(true)
            row["refusal"] = .string(QuietSettings.ownerOnlyRefusal)
        }
        if fullMacOnly {
            row["full_mac_only"] = .bool(true)
            if !fullMac { row["refusal"] = .string(QuietSettings.belowFullMacRefusal) }
        }
        return .object(row)
    }
}
