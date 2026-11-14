import Foundation

// Blueprint: | `PhoneConnection.swift` | `NAPhoneConnection`: pairing/transport/exchange assessment; `NAPhoneStanding`: connected and can-approve |

/// The Mac's acceptance of a phone, owed to that phone until it answers. The Mac sends it as a signed message naming the device; the phone takes it
/// whenever it arrives, waiting or not, and answers with the acknowledgement action. Both are idempotent.
public enum NAPairingConfirmation {
    public static let messageKind = "pairing_confirmed"
    public static let deviceField = "deviceId"
    /// One acceptance's identity: the confirmation carries it and the acknowledgement echoes it, so an answer to an earlier pairing never
    /// settles a later one.
    public static let acceptanceField = "acceptance"
    public static let acknowledgement = "pairingConfirmed"
}

/// Pairing, transport and accepted exchange are independent facts. All surfaces use this assessment to name the first unmet fact and its repair owner.
public struct NAPhoneConnection: Equatable, Sendable, Codable {
    public enum State: String, Sendable, Codable {
        case holds
        /// Not a fault: something is pending on someone, or not known yet.
        case waiting
        /// The fact is false and nothing works until its owner acts.
        case broken
    }

    public enum Owner: String, Sendable, Codable {
        case nobody
        case personOnMac
        case personOnPhone
        case iCloudAccount
        case network
        /// This build cannot do it; a different build can.
        case builder
    }

    public struct Fact: Equatable, Sendable, Codable {
        public var state: State
        public var line: String
        public var owner: Owner
        public var lever: String?

        public init(_ state: State, _ line: String, owner: Owner = .nobody, lever: String? = nil) {
            self.state = state
            self.line = line
            self.owner = owner
            self.lever = lever
        }
    }

    public var pairing: Fact
    public var transport: Fact
    public var exchange: Fact

    public init(pairing: Fact, transport: Fact, exchange: Fact) {
        self.pairing = pairing
        self.transport = transport
        self.exchange = exchange
    }

    public var facts: [(label: String, fact: Fact)] {
        [("Pairing", pairing), ("iCloud", transport), ("Last exchange", exchange)]
    }

    /// What the person hears first. A broken fact outranks a pending one; among broken, iCloud first (nothing crosses without it), among pending, pairing
    /// first (it is the next step a person takes). All holding: the exchange, the freshest proof.
    public var headline: Fact {
        [transport, pairing, exchange].first { $0.state == .broken }
            ?? [pairing, transport, exchange].first { $0.state == .waiting }
            ?? exchange
    }

    public var holds: Bool { headline.state == .holds }
}

/// What the phone is to the Mac, said once for every surface. The shared iCloud key admits a phone's chat, so a phone is **connected** once it has spoken
/// over it; it can **approve** only once its own device key is paired on the Mac with the Pair button.
public struct NAPhoneStanding: Equatable, Sendable, Codable {
    /// Nil when verified contact evidence is unavailable: unknown, never "not connected".
    public var connected: Bool?
    /// Phones that asked to pair and wait for the Pair button.
    public var waiting: Int
    /// Phones whose device key is paired and that confirmed hearing it: the ones that can approve.
    public var approvers: Int
    /// Phones paired here that have not yet confirmed hearing it; the Mac resends its acceptance until they do.
    public var confirming: Int

    public init(connected: Bool?, waiting: Int, approvers: Int, confirming: Int = 0) {
        self.connected = connected
        self.waiting = waiting
        self.approvers = approvers
        self.confirming = confirming
    }

    private enum CodingKeys: String, CodingKey { case connected, waiting, approvers, confirming }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        connected = try values.decodeIfPresent(Bool.self, forKey: .connected)
        waiting = try values.decode(Int.self, forKey: .waiting)
        approvers = try values.decode(Int.self, forKey: .approvers)
        confirming = try values.decodeIfPresent(Int.self, forKey: .confirming) ?? 0
    }

    public var canApprove: Bool { approvers > 0 }

    /// What waits on the person's Pair button; nil when nothing does.
    public var waitingLine: String? {
        waiting == 0 ? nil : waiting == 1 ? "An iPhone is waiting for you to choose Pair." : "\(waiting) iPhones are waiting for you to choose Pair."
    }

    /// What waits on a paired phone confirming it heard this Mac; nil when nothing does.
    public var confirmingLine: String? {
        confirming == 0 ? nil : confirming == 1 ? "An iPhone is paired on this Mac; waiting for the iPhone to confirm."
            : "\(confirming) iPhones are paired on this Mac; waiting for them to confirm."
    }

    /// One true sentence; the step that follows is the pairing fact's lever. Chatting over the shared iCloud key is not pairing.
    public var line: String {
        let pending = [confirmingLine, waitingLine].compactMap { $0 }
        if approvers > 0 {
            let paired = approvers == 1 ? "Your iPhone is paired: it can chat and approve actions."
                : "\(approvers) iPhones are paired: they can chat and approve actions."
            return ([paired] + pending).joined(separator: " ")
        }
        if !pending.isEmpty { return pending.joined(separator: " ") }
        switch connected {
        case true?: return "Your iPhone chats here through this Apple Account, but it isn't paired, so it can't approve actions."
        case false?: return "No iPhone is paired with this Mac."
        case nil: return "No iPhone is paired with this Mac; whether one chats here is not known."
        }
    }
}
