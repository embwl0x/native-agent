import Foundation
import AppToolRuntime
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Transcripts
import TrustCenter

extension NativeClient {
    // PATCH-Phase7b: Sendable-safe variant — caller pre-serializes input to Data on its actor.
    // This avoids passing [String: Any] (non-Sendable) across concurrency boundaries.
    func dispatchToolData(tool: String, inputData: Data, sessionId: String?) async throws -> DispatchResult {
        // Re-parse the pre-serialized input data and wrap it in the full body dict.
        guard let inputObj = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else {
            throw NSError(domain: "NativeAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not deserialize inputData"])
        }
        return try await _swiftDispatch(tool: tool, input: inputObj, sessionId: sessionId)
    }

    // Swift-only failed dispatch envelope when the input cannot be represented
    // as a native object or the file sandbox cannot resolve a validated repo.
    // There is no HTTP retry path.
    func _dispatchMissingNativeHandler(bodyData: Data) async throws -> DispatchResult {
        NativeDispatchFailure.missingHandler(
            bodyData: bodyData,
            makeError: DispatchResult.DispatchToolError.init,
            makeResult: DispatchResult.init
        )
    }

    static func fileSafeTimestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
