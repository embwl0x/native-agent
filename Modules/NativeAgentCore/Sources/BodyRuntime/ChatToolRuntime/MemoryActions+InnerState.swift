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
// Blueprint: | `MemoryActions+InnerState.swift` | innerState action contracts and execution |

enum MemoryActions {}

struct InnerStateArgs: DoorArgs {
    static let windowHoursField = DoorFieldDescriptor.number("window_hours",
            """
                How many hours of felt moments to include. 1–168; out-of-range values clamp, and the result says so: \
                window_hours_requested, window_hours_applied and a note naming the cap. Default 6.
                """
        )
    static let detailField = DoorFieldDescriptor.choice("detail",
            ["compact", "full"],
            """
                compact (default) is the short read: the fingerprint, mood, disposition, body words, and the strongest few of each \
                list. full returns every bounded list at its cap.
                """
        )
    static let doorFields: [DoorFieldDescriptor] = [windowHoursField, detailField]
    let windowHours: Double?
    let detail: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        windowHours = try door.number(Self.windowHoursField)
        detail = try door.string(Self.detailField)
    }
}

extension MemoryActions {
    static let innerStateActions: [ActionDescriptor] = {
        [
            ActionDescriptor(InnerStateArgs.self, name: "inner_state",
                run: { context, input in
                    await context.client.impl_inner_state(input: input, surface: context.surface, turn: context.turn)
                }, toolClass: .read, capabilities: [.toolCall],
                description: """
        Read your recorded inner state before describing how you feel. Returns \
        fingerprint/subject; mood integral and disposition in words/numbers; \
        recent felt moments (time, subject, valence/arousal/warmth); body words \
        and reported fatigue/time-of-day; dream residue (mood/date), and cares \
        with their stances and open questions. No conversation text \
        or quotes. Read-only; empty sections mean absent state, not read failure.
        """
            ),
        ]
    }()
}
