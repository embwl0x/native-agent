import Foundation
import TrustCenter

public enum NativeDispatchFailure {
    public static func missingHandler<Result, Output, Failure>(
        bodyData: Data,
        makeError: (String, String, String?, Bool) -> Failure,
        makeResult: (Bool, String, String, Output?, Failure?, Bool, Bool?, Int, Int, String, String, Bool, String?, String, String) -> Result
    ) -> Result {
        let parsed = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
        let toolName = (parsed?["tool"] as? String) ?? ""
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let runId = UUID().uuidString.lowercased()
        NSLog("[NativeClient] dispatch missing native handler for tool=\(toolName)")
        return makeResult(
            false,
            toolName,
            "failed",
            nil,
            makeError(
                "native_handler_missing",
                "No Swift-native handler is available for tool '\(toolName)'",
                toolName.isEmpty ? nil : toolName,
                false
            ),
            false,
            nil,
            0,
            0,
            "",
            "",
            false,
            nil,
            runId,
            nowISO
        )
    }

}
