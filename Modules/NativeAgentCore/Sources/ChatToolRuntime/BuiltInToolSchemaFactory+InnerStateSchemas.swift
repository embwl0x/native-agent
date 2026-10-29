import Foundation
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import AgentWorkspace
import MemoryV2
import ProviderRouting
import ToolRegistry
import NativeAgentShared
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Dispatcher
import MacControl
import Senses
import StandingBots
// Blueprint: | `BuiltInToolSchemaFactory+InnerStateSchemas.swift` | `BuiltInToolSchemaFactory`: `innerStateSchemas` |

extension BuiltInToolSchemaFactory {
    func innerStateSchemas() -> [LLMToolSchema?] {
        [
            // Inner-state reads expose only a bounded window and detail level.
            requestedSchema(name: "inner_state", toolClass: .read, capabilities: ["tool_call"],
                description: Self.innerStateToolDescription,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("window_hours", numSchema(
                            "How many hours of felt moments to include. 1–168; out-of-range values clamp, and the result says so: window_hours_requested, window_hours_applied and a note naming the cap. Default 6."
                        )),
                        ("detail", ToolSchema.enumStringSchema(
                            ["compact", "full"],
                            "compact (default) is the short read: the fingerprint, mood, disposition, body words, and the strongest few of each list. full returns every bounded list at its cap."
                        )),
                    ],
                    required: []
                )
            ),
        ]
    }
}
