// PhoneConnection.swift — the one assessment of a phone's connection to its Mac.
import Foundation

// Blueprint: | `PhoneConnection.swift` | `NAPhoneConnection`: one shared assessment of pairing, transport and accepted exchange, naming the first unmet fact and its repair owner |

/// A phone and its Mac are connected when three facts hold: they share a
/// pairing, iCloud carries their records, and an exchange between them was
/// accepted. Each side builds this from its own evidence. Every surface that
/// says where the connection stands says it through this one value, so no
/// place shows the three as one: the first fact that does not hold is what
/// the person hears, with who can change it and the exact way.
public struct NAPhoneConnection: Equatable, Sendable {
    public enum State: String, Sendable {
        /// The fact is true.
        case holds
        /// Not a fault: something is pending on someone, or not known yet.
        case waiting
        /// The fact is false and nothing works until its owner acts.
        case broken
    }

    /// Who can make a fact hold.
    public enum Owner: String, Sendable {
        case nobody
        /// A choice or act on the Mac.
        case personOnMac
        /// A choice or act on the phone.
        case personOnPhone
        /// The Apple Account or iCloud settings on that device.
        case iCloudAccount
        /// That device's network.
        case network
        /// This build cannot do it; a different build can.
        case builder
    }

    public struct Fact: Equatable, Sendable {
        public var state: State
        /// What is true, one sentence.
        public var line: String
        public var owner: Owner
        /// The exact way to make it hold, when someone has to act.
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

    /// The three facts in the order a person reads them.
    public var facts: [(label: String, fact: Fact)] {
        [("Pairing", pairing), ("iCloud", transport), ("Last exchange", exchange)]
    }

    /// What the person hears first. A broken fact outranks a pending one;
    /// among broken, iCloud first (nothing crosses without it), among pending,
    /// pairing first (it is the next step a person takes). All holding: the
    /// exchange, the freshest proof.
    public var headline: Fact {
        [transport, pairing, exchange].first { $0.state == .broken }
            ?? [pairing, transport, exchange].first { $0.state == .waiting }
            ?? exchange
    }

    public var holds: Bool { headline.state == .holds }
}
