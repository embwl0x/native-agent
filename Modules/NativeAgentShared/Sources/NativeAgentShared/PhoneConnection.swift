import Foundation

// Blueprint: | `PhoneConnection.swift` | `NAPhoneConnection`: pairing/transport/exchange assessment; `NAPhoneStanding`: connected and can-approve |

/// Pairing, transport and accepted exchange are independent facts. All surfaces use this assessment to name the first unmet fact and its repair owner.
public struct NAPhoneConnection: Equatable, Sendable {
    public enum State: String, Sendable {
        case holds
        /// Not a fault: something is pending on someone, or not known yet.
        case waiting
        /// The fact is false and nothing works until its owner acts.
        case broken
    }

    public enum Owner: String, Sendable {
        case nobody
        case personOnMac
        case personOnPhone
        case iCloudAccount
        case network
        /// This build cannot do it; a different build can.
        case builder
    }

    public struct Fact: Equatable, Sendable {
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
public struct NAPhoneStanding: Equatable, Sendable {
    /// Nil when the saved contact evidence can't be read: unknown, never "not connected".
    public var connected: Bool?
    /// Phones that asked to pair and wait for the Pair button.
    public var waiting: Int
    /// Phones whose device key is paired: the ones that can approve.
    public var approvers: Int

    public init(connected: Bool?, waiting: Int, approvers: Int) {
        self.connected = connected
        self.waiting = waiting
        self.approvers = approvers
    }

    public var canApprove: Bool { approvers > 0 }

    /// What waits on the person's Pair button; nil when nothing does.
    public var waitingLine: String? {
        waiting == 0 ? nil : waiting == 1 ? "An iPhone is waiting for you to choose Pair." : "\(waiting) iPhones are waiting for you to choose Pair."
    }

    public var line: String {
        let contact: String
        switch connected {
        case true?: contact = "Your iPhone is connected over iCloud."
        case false?: contact = "No iPhone has connected over iCloud yet."
        case nil: contact = "Whether your iPhone has connected can't be read right now."
        }
        var approval: [String] = []
        if approvers > 0 { approval.append(approvers == 1 ? "1 phone can approve actions." : "\(approvers) phones can approve actions.") }
        if let waitingLine { approval.append(waitingLine) }
        if approval.isEmpty { approval.append("No phone can approve actions until you pair it.") }
        return ([contact] + approval).joined(separator: " ")
    }
}
