import Foundation
import NativeAgentCore
import PersistenceCore
import MindCore
import ProviderRouting
import DeskCore
import NativeAgentShared
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MacNerves
import SenseCore
// Blueprint: | `DeskActions+Collaboration.swift` | collaboration action contracts and execution |

enum DeskActions {}

extension DeskActions {
    static let collaborationActions: [ActionDescriptor] = [
        // Status reads must not spawn work or contact a peer.
        ActionDescriptor(DelegationStatusArgs.self, name: "delegation_status",
            run: { context, input in
                try await context.client.impl_delegation_status(invocation: context.invocation, input: input)
            }, toolClass: .read,
            description: """
                Your jobs (work you gave other agents and your own lines with agent.job, newest first) and retained reply deliveries \
                (answers owed to, delivered to or let go for the chats and contacts that asked). agent.read {job} opens one job; agent.read \
                opens a conversation. Discarded text is not recoverable.
                """
        ),
    ]
}

struct DelegationStatusArgs: DoorArgs {
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.intSchema("Deliveries per page: default 8, max 12."), required: false)
    static let offsetField = DoorFieldDescriptor("offset", ToolSchema.intSchema("Delivery offset. Follow next_offset; omit on first page."), required: false)
    static let agentField = DoorFieldDescriptor.string("agent", """
        Optional saved contact whose jobs and deliveries to list, or self for your own lines. Omit for everything.
        """)
    static let detailField = DoorFieldDescriptor.string("detail", "Delivery compact (default) or full lifecycle metadata.")
    static let doorFields = [limitField, offsetField, agentField, detailField]

    let limit: Int?
    let offset: Int?
    let agent: String?
    let detail: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        limit = try door.int(Self.limitField)
        offset = try door.int(Self.offsetField)
        agent = try door.string(Self.agentField)
        detail = try door.string(Self.detailField)
    }
}
