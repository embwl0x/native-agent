import Foundation

/// Main-actor callers use this to prevent an older suspended request from
/// replacing state produced by a newer user intent.
public struct LatestAsyncRequestGate: Sendable, Equatable {
    public private(set) var generation: UInt64 = 0

    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func accepts(_ token: UInt64) -> Bool {
        token == generation
    }
    public init(generation: UInt64 = 0) {
        self.generation = generation
    }

}
