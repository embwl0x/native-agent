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
// Blueprint: | `StudioActions+Dream.swift` | dream action contracts and execution |

enum StudioActions {}

extension StudioActions {
    static let dreamActions: [ActionDescriptor] = {
        [
            ActionDescriptor(DreamDiaryReadArgs.self, name: "dream_diary_read",
                run: { context, input in
                    try await context.client.impl_dream_diary_read(input: input)
                }, toolClass: .read,
                description: """
        Read your dream diary on demand. No arguments: weekly index with dates, \
        latest dream, all runs in `dreams`, and archive status. `date` \
        (YYYY-MM-DD) reads one night, including archives. `query` finds text \
        matches, newest first. Each entry is capped at 20,000 characters with \
        truncation reported. Index/search scan at most 365 entries; weeks/limit \
        bound returned rows. Read-only; storage/partial fields distinguish \
        unreadable entries from an empty result. No automatic reads.
        """
            ),
        ]
    }()
}

struct DreamDiaryReadArgs: DoorArgs {
    static let dateField = DoorFieldDescriptor.string("date", """
        One night, YYYY-MM-DD, including archives. Entry text is capped at 20,000 characters; reports truncation. Omit for the \
        index.
        """)
    static let queryField = DoorFieldDescriptor.string("query", """
        Case-insensitive text search of up to 365 entries, newest matches first. Each returned entry is capped at 20,000 \
        characters; reports truncation. Omit for the index.
        """)
    static let weeksField = DoorFieldDescriptor("weeks", ToolSchema.intSchema("Index only: how many weeks back to list. Default 8, max 52."), required: false)
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.intSchema("Query only: how many matching nights to return. Default 10, max 25."), required: false)
    static let doorFields = [dateField, queryField, weeksField, limitField]

    let date: String?
    let query: String?
    let weeks: Int?
    let limit: Int?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        date = try door.string(Self.dateField)
        query = try door.string(Self.queryField)
        weeks = try door.int(Self.weeksField)
        limit = try door.int(Self.limitField)
    }
}
