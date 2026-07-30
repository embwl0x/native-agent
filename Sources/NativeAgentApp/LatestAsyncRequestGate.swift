import Foundation

/// Main-actor callers use this to prevent an older suspended request from
/// replacing state produced by a newer user intent.
struct LatestAsyncRequestGate: Sendable, Equatable {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func accepts(_ token: UInt64) -> Bool {
        token == generation
    }
}
