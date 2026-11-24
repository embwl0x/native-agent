import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+HomeGroup.swift` | Home action declarations |

extension AppActions {
    static func homeGroup() -> [AppAction] {
        [
        AppAction("find", "*", "Discover actions, pages and skills by intent", [.required("what|query")],
                  warn: "The same discovery as app {find:\"words\"}. Pass what or query inside args.",
                  tool: "app_find", read: true),
        AppAction("photos.count", "files", "Count how many photos, pictures or recorded videos are in Photos by creation date and media type",
                  [.optional("start"), .optional("end"), .optional("media_type")],
                  warn: """
                      start/end: ISO 8601 with timezone, start inclusive/end exclusive. media_type: all (default), image or video. Missing macOS Photos \
                      access raises a permission card; only the person taps Allow. Limited access counts only shared assets.
                      """,
                  tool: "photos_read", input: verb("count"), read: true),
        AppAction("photos.recent", "files", """
            Read recent photos, pictures and recorded videos in Photos: creation date, media type, dimensions, favorite and stored location coordinates
            """,
                  [.optional("limit", .integer), .optional("start"), .optional("end"), .optional("media_type")],
                  warn: """
                      limit: 1–100, default 10, newest creation first. start/end: ISO 8601 with timezone, start inclusive/end exclusive. media_type: all \
                      (default), image or video. Metadata only; missing macOS Photos access raises a permission card for the person's Allow tap.
                      """,
                  tool: "photos_read", input: verb("recent"), read: true),
        // Inbox action ids must match the button ids published by each note read.
        AppAction("inbox.archive", "inbox", "Archive", [.required("ids|id"), .required("reason")], tool: "inbox", input: verb("archive")),
        AppAction("inbox.acknowledge", "inbox", "Archive", [.required("ids|id"), .required("reason")], tool: "inbox", input: verb("archive")),
        AppAction("inbox.dismiss", "inbox", "Dismiss", [.required("ids|id"), .required("reason")], tool: "inbox", input: verb("dismiss")),
        AppAction("inbox.mark_read", "inbox", "Mark read (opening a note does this)", [.required("ids|id"), .required("reason")],
                  tool: "inbox", input: verb("mark_read")),
        AppAction("inbox.repair", "inbox", "Repair", [.required("id")], subject: ["id"], tool: "inbox", input: verb("repair")),
        AppAction("inbox.act", "inbox", "Act", [.required("id"), .optional("action")], subject: ["id"], irreversible: true, capabilities: [.appDataWrite, .safeRead,
            .toolCall], tool: "inbox", input: verb("act")),
        AppAction("inbox.clean_up", "inbox", "Clean Up", [.required("id")], subject: ["id"], tool: "inbox", input: press("act")),
        AppAction("inbox.open_approvals", "inbox", "Open Approvals", [.required("id")], subject: ["id"], tool: "inbox", input: press("open_approvals")),
        AppAction("inbox.not_now", "inbox", "Not now", [.required("id"), .optional("reason")], subject: ["id"], irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall], warn: """
                      declines the card. The owner's own Not now wakes the conversation that raised it; yours does not:\u{20}
                      """
                      + "the card retires and that request does not run again",
                  tool: "inbox", input: verb("not_now")),
        AppAction("inbox.withdraw", "inbox", "Withdraw my own pending approval", [.required("id"), .optional("reason")], subject: ["id"], irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "inbox", input: verb("withdraw")),
        AppAction("inbox.open_on_mac", "inbox", "Open on Mac", [.required("id")], subject: ["id"], owner: .person("it opens the card for the owner at the Mac",
                  instead: "inbox.not_now declines it; inbox.archive retires a stale one", asks: false,
                      name: "Opening an approval on the Mac"), tool: "inbox", input: press("act")),
        AppAction("inbox.approve", "inbox", "Approve", [.required("id")], subject: ["id"], irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "inbox", input: press("approve"), scope: """
                  Approve this exact waiting card when the person tells you in their own Mac chat, paired-phone or allowlisted Telegram message. \
                  Read the Inbox card first: any other call in this turn requires a fresh message or their tap. \
                  A message joining a running turn needs a fresh message after that turn ends so the decision can name its authorizing message. \
                  Peer-steered turns, helpers and wakes cannot decide it; permanent deletion needs their tap
                  """),
        AppAction("inbox.deny", "inbox", "Deny", [.required("id")], subject: ["id"], irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "inbox", input: press("reject"), scope: """
                  Deny this exact waiting card on the person's own authenticated message, under the same authority as inbox.approve
                  """),
        ]
    }
}
