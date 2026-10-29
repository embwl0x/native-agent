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
// Blueprint: | `BuiltInToolSchemaFactory+DreamSchemas.swift` | `BuiltInToolSchemaFactory`: `dreamSchemas` |

extension BuiltInToolSchemaFactory {
    func dreamSchemas() -> [LLMToolSchema?] {
        [
            // Bounded diary reads: weekly index, one night by date, or matching nights by query.
            requestedSchema(name: "dream_diary_read", toolClass: .read,
                description: Self.dreamDiaryReadToolDescription,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("date", ToolSchema.strSchema("One night, YYYY-MM-DD, including archives. Entry text is capped at 20,000 characters; reports truncation. Omit for the index.")),
                        ("query", ToolSchema.strSchema("Case-insensitive text search of up to 365 entries, newest matches first. Each returned entry is capped at 20,000 characters; reports truncation. Omit for the index.")),
                        ("weeks", ToolSchema.intSchema("Index only: how many weeks back to list. Default 8, max 52.")),
                        ("limit", ToolSchema.intSchema("Query only: how many matching nights to return. Default 10, max 25.")),
                    ],
                    required: []
                )
            ),
        ]
    }
}
