import Darwin
import Foundation
// Blueprint: | `VolumeIO.swift` | Serial off-pool filesystem work; bounded waits never cancel issued writes |

public enum VolumeIO {
    private static let queue = DispatchQueue(label: "NativeAgent.volume-io", qos: .utility)

    /// The deadline ends the wait, not an issued write. A late operation owns its physical completion; callers must reconcile effects before replay.
    public static func run<T: Sendable>(
        budget: OperationWaitBudget = .init(),
        onFinish: @escaping @Sendable () -> Void = {},
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let budget = budget.deadline == nil ? budget.capped(seconds: 30) : budget
        let result = ContinuationOnce<Result<T, Error>>()
        if Task.isCancelled || budget.expired {
            result.resume(.failure(budget.cancellationError))
        }
        queue.async {
            defer { onFinish() }
            guard result.isPending else { return }
            let outcome = Result { try body() }
            if !result.resume(outcome) {
                let state = switch outcome { case .success: "completed"; case .failure: "failed" }
                NSLog("[VolumeIO] issued filesystem operation %@ after its caller stopped waiting; reconcile its destination before replay", state)
            }
        }
        return try await result.wait(budget: budget, cancellingWith: .failure(budget.cancellationError)).get()
    }

    public static func result<T: Sendable>(budget: OperationWaitBudget = .init(), _ body: @escaping @Sendable () throws -> T) async -> Result<T, Error> {
        do { return .success(try await run(budget: budget, body)) }
        catch { return .failure(error) }
    }

    /// Metadata admission never downloads bytes. A cloud placeholder remains unavailable until its owning sync mechanism has made it resident.
    public static func requireReadyForReading(_ url: URL) throws {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                "\(url.lastPathComponent) has not downloaded. Its bytes were not read; allow its sync owner to finish before reading again."])
        }
    }

    public static func contents(of url: URL, options: Data.ReadingOptions = []) throws -> Data {
        try requireReadyForReading(url)
        return try Data(contentsOf: url, options: options)
    }
}
