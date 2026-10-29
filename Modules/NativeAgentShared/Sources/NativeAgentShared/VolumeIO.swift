import Foundation
// Blueprint: | `VolumeIO.swift` | The one owner of blocking file work that can touch a File Provider or network volume (iCloud Drive): one serial queue off the cooperative pool, awaited by its callers |

/// Blocking file work that can touch a File Provider or network volume:
/// iCloud Drive above all, where a dataless file or folder blocks its reader
/// until it downloads. It never runs on the cooperative pool, where a few
/// stuck reads starve every turn. One serial queue owns it, so it never fans
/// out either; the caller awaits and its pool thread is free meanwhile.
public enum VolumeIO {
    private static let queue = DispatchQueue(label: "NativeAgent.volume-io", qos: .utility)

    public static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    public static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
