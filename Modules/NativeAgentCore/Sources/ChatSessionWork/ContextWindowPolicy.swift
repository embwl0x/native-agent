import Foundation
import NativeAgentCore
import ProviderRouting
import PersistenceCore
// Blueprint: | `ContextWindowPolicy.swift` | Context-window readout from the powering model's verified default. |

public enum ContextWindowPolicy {
    public static func readout(forModel model: String, providerID: String?, dataRoot: URL, call: LLMCall) async throws -> [String: JSONValue] {
        guard let window = ProviderRouting.verifiedContextLength(forModel: model, providerID: providerID, dataRoot: dataRoot), window > 0 else {
            throw ProviderRoutingError.configurationFailed("The selected model's context window is unavailable. Refresh its catalog in Providers.")
        }
        let output = try await SessionContextMeasurement.outputAllowance(model: model, providerID: providerID, dataRoot: dataRoot, call: call)
        return [
            "model": .string(model), "effective_tokens": .int(Int64(window)), "native_window_tokens": .int(Int64(window)),
            "native_window_source": .string("ProviderRouting verified model catalog for the selected provider/model"),
            "request_output_allowance_tokens": .int(Int64(output)),
            "meaning": .string("The model's default window holds the verbatim tail; at its bound, oldest whole turns drop to about half the input room."),
            "summary": .string("Context window for \(model): \(window) tokens (model default), with \(output) tokens reserved for its response.")
        ]
    }
}
