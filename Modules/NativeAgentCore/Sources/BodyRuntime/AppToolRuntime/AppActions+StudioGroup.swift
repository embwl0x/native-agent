import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+StudioGroup.swift` | Studio action declarations |

extension AppActions {
    static func studioGroup() -> [AppAction] {
        [
        AppAction("make.add", "make", """
            Add a file (path), or words I already hold (content with a file name such as board.html), to Make as a new version of ref (a new \
            ref when left out); returns the ref
            """,
                  [.optional("path"), .optional("content"), .optional("name"), .optional("ref"), .optional("prompt"), .optional("model")], warn: """
                      A whiteboard is name.board, the whole document each version: {board:1,elements:[{id,type,…}]}; shape x,y,w,h,text,color,\
                      kind:rounded|pill|rect; text x,y,text,size:title|large|body|small; container (a section) x,y,w,h,text,color; arrow from,to \
                      (ids),label?; stroke x,y,points:[x0,y0,…] from x,y,color,width; colors green|yellow|purple|blue|peach|white|ink
                      """,
                  tool: "make_studio", input: verb("add"), versionExempt: true),
        AppAction("table.put", "desk", """
            Put something on the table: with type, add (occupied id: exists); missing id mints e plus twelve lowercase hex digits. Without type, \
            edit by id (absent: not_found). A new shape or container needs x,y,w,h; text x,y; arrow from,to; stroke x,y and points (the points run from x,y). \
            Colors: green|yellow|purple|blue|peach|white|ink
            """,
                  [.optional("id"), .optional("type", .options("shape", "text", "container", "arrow", "stroke")), .optional("x", .number), .optional("y", .number), .optional("w", .number), .optional("h", .number), .optional("text"), .optional("color"),
                   .optional("kind"), .optional("size"), .optional("from"), .optional("to"), .optional("fromSide"), .optional("toSide"), .optional("label"), .optional("points", .numbers), .optional("width", .number), .optional("item"), .optional("piece")],
                  tool: "table_change", input: verb("put"), versionExempt: true),
        AppAction("table.cross", "desk", "Cross a Desk card off through desk.close, or toggle a mark's crossing", [.required("id")],
                  tool: "table_change", input: verb("cross"), versionExempt: true),
        AppAction("table.remove", "desk", "Remove an element and its arrows from the table", [.required("id")],
                  tool: "table_change", input: verb("remove"), versionExempt: true),
        AppAction("make.read", "make", "A Make ref's versions: n, path, prompt, created (newest ref when left out). Read page:make for the paged shelf.",
                  [.optional("ref")],tool: "make_studio", input: verb("read"), read: true),
        AppAction("studio.intake.read", "personality", """
            Read neutral consult or corrected complete-history facts for unanswered-work intake; carry snapshot through every page
            """,
                  [.required("kind", .options("history", "consults")), .optional("offset", .number), .optional("snapshot")], capabilities: [.appDataRead], tool: "studio_intake_read", read: true),
        // The reply face carries attachments to every delivery door.
        AppAction("reply.attach", "chat", """
            Attach an image to the reply you are writing now; it goes with your answer wherever this conversation is answered (the Mac chat, Telegram)
            """,
                  [.required("path")], warn: """
                      One image per call, by its own path: jpg, png, gif, webp, bmp or heic, inside your Trust workspace unless this Mac is in Full Mac.
                      """,
                  tool: "read_file", read: true),
        AppAction("sense.make", "chat", """
            Learn to read a Mac app, live Chrome site, or foreign file format (including binary) from captured material. Plain text uses files.read; a web \
            page is read with read_page (app web.read), not sense.make. Folder watches are not sense.make corners: to act when a file or folder changes, save \
            an ability whose header wakes on file.changed:<path> (ability.save). Read with mac.look, chrome.snapshot or files.read first. code: complete \
            sense.js; kit: Contents/Resources/Senses (AUTHORING.md, sense.js, builtin/app.js, builtin/site.js). Runs on the last-read place or explicit \
            place; returns page, trial_id/digest and timing. Keep the exact trial with {trial_id,digest,keep:true}, no code. {code,keep:true} runs and keeps \
            immediately. {show:\"material\"} returns captured material
            """,
                  [.optional("code"), .optional("trial_id"), .optional("digest"), .optional("keep", .boolean), .optional("place"), .optional("why"), .optional("show"), .optional("apps", .list), .optional("reach", .fromOwner), .optional("wake", .list), .optional("face", .fromOwner),
                      .optional("resident", .boolean), .optional("learned", .any), .optional("choices", .any)],
                  capabilities: [.appDataWrite, .safeRead, .toolCall], warn: """
                      apps declares bundle ids for sense.apps.read({bundle_id,dictionary:true}) or read-only Apple Events using event_class, event_id and \
                      parameters. Standard core getd/cnte/doex events are reads; other events are writes and need a write declaration.
                      """, tool: "sense_make",
                  readWhen: ["show": .string("material"), "trial_id": .null, "digest": .null], lifecycle: .change,
                  schema: arguments("sense_make", AbilityStore.partArgumentSchemas.merging(["code": ToolSchema.strSchema(), "trial_id": ToolSchema.strSchema(),
                      "digest": ToolSchema.strSchema(),
                      "apps": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "keep": .object(["type": .string("boolean")]), "place": ToolSchema.strSchema(), "why": ToolSchema.strSchema(), "show": ToolSchema.strSchema(
                        )]) { owned, _ in owned })),
        AppAction("sense.versions", "senses", "Read a sense's current and retained versions", [.required("sense_id")], subject: ["sense_id"],tool: "sense_lifecycle",
            input: ["verb": .string("versions")], read: true),
        AppAction("sense.quarantine", "chat", "Turn a sense off while retaining its current and previous versions", [.required("sense_id"), .required("version", .integer)],
            subject: ["sense_id"], tool: "sense_lifecycle", input: ["verb": .string("quarantine")], revision: 2, lifecycle: .change),
        AppAction("sense.restore", "chat", "Turn the selected sense version back on", [.required("sense_id")], subject: ["sense_id"], tool: "sense_lifecycle",
            input: ["verb": .string("restore")], revision: 2, lifecycle: .restore),
        AppAction("sense.drop", "chat", "Delete a sense and its run statistics permanently", [.required("sense_id")], subject: ["sense_id"], irreversible: true,
            capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "sense_lifecycle", input: ["verb": .string("drop")], revision: 2,
            lifecycle: .drop),
        ]
    }
}
