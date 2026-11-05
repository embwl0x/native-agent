import Foundation
import NativeAgentCore
// Blueprint: | `RepairDebt.swift` | `RepairDebt`: typed repair owed by an experience, with one codec to persisted claim lines |

/// The repair one experience owes. Its persisted form is the experience's claim
/// lines (`owner: …`, `operation: …`, `lever: …`, `next_call: …`, `tap: …`),
/// read and written only here; each value is kept verbatim, never split.
public struct RepairDebt: Sendable, Equatable {
    /// Who can repair it.
    public var owner: String?
    /// The operation that failed; its success settles the debt.
    public var operation: String?
    /// What to pull to repair it: an operation id, or the owner's instruction.
    public var lever: String?
    /// The exact call that repairs it, as written.
    public var nextCall: String?
    /// The person's control that decides it.
    public var tap: String?

    public init(owner: String?, operation: String?, lever: String? = nil, nextCall: String? = nil, tap: String? = nil) {
        self.owner = owner
        self.operation = operation
        self.lever = lever
        self.nextCall = nextCall
        self.tap = tap
    }

    /// The debt an experience's claims record; a missing line stays absent.
    public init(_ experience: Experience) { self.init(claims: experience.claims) }

    public init(claims: [Experience.Claim]) {
        func line(_ key: String) -> String? {
            claims.first { $0.claim.hasPrefix(key + ": ") }.map { String($0.claim.dropFirst(key.count + 2)) }
        }
        self.init(owner: line("owner"), operation: line("operation"), lever: line("lever"),
                  nextCall: line("next_call"), tap: line("tap"))
    }

    /// The persisted claim lines, in their recorded order.
    public var claims: [Experience.Claim] {
        [("owner", owner), ("operation", operation), ("lever", lever), ("next_call", nextCall), ("tap", tap)]
            .compactMap { key, value in value.map { Experience.Claim(claim: key + ": " + $0, evidence: []) } }
    }

    /// The same open debt: one operation met again by the same owner.
    public func matches(operation: String, owner: String) -> Bool { self.operation == operation && self.owner == owner }

    /// A success of `operation` settles this debt when it is the failed operation or its lever.
    public func isSettled(by operation: String) -> Bool { self.operation == operation || lever == operation }
}
