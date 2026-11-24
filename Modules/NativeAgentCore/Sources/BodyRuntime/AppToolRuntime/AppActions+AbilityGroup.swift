import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+AbilityGroup.swift` | Ability action declarations |

extension AppActions {
    static func abilityGroup() throws -> [AppAction] {
        try [
        // Every part shares one lifecycle and declared reach regardless of its authoring door (docs/AGENT_IS_THE_APP.md).
        AppAction("ability.save", "tools", """
            Grow an ability beyond existing actions: apps through AppleScript/Apple Events, programs, servers or services; or keep a route that worked by \
            hand. Resident abilities hold programs/connections until turned off or app quit; reopening at launch requires wake [\"resumed\"] and reopening \
            code
            """,
                  ToolSignature.doorArgs(abilitySaveSchema.parametersJSON).map(DoorActionArguments.Field.init(admitted:)),
                  warn: """
                      description: one line; save keeps its first line within 500 characters and says so; details in params. code: JavaScript function \
                      run(input) (or async function run(input); app and host calls answer at once and may be awaited) returning JSON (to decline on purpose, \
                      return {status:\"refused\",reason:\"revision_required\",detail:\"This ability does not support that \
                      input.\",effects:\"none\",remedy:{instruction:\"Read this ability, then revise it for the \
                      input.\",next_call:{tool:\"app\",input:{action:\"ability.read\",args:{id:\"your_ability_id\"}}}}}; use the actual cause, detail, \
                      effects and id. A person-owned decision uses remedy {instruction,tap}; a terminal refusal uses remedy \
                      {kind:\"terminal\",instruction:\"why no further action is appropriate\",next_call:null}. A decline is an answer, not a fault; a throw \
                      or {ok:false} reads as broken and owes a repair). app.<page>.<action>(args), or the door's own form app({action,args}) / \
                      app({actions:[…]}), runs any action under ordinary gates; calls are derived from code. app.step(label,guidance), \
                      app.decide(question,data), app.expect(ok,what), app.expect_fail(code,fn) make a strict journal; decide hands back its question for \
                      ability.resume {run_id,answer}. Calls return action data plus call (action id) and effects (none,occurred,partial,unknown); failures \
                      throw catchable AppError with e.reason,e.effects,e.call,e.receipt. host.state.get() and host.state.set(value) persist this ability's \
                      JSON. host.files: read/list/info/excerpt/grep/spotlight/write/copy/move/trash/patch. host.network: \
                      connect/listen/accept/send/receive/close; connect takes {host,port,tls?,transport?} or {path} for a Mac socket (localhost). \
                      host.program.start({command,args?,env?,cwd?}) runs a path or a name on the login PATH, returning {id}. host.program.send and \
                      host.network.send take {id,text} or {id,base64}, each through Trust as an effect. host.program.receive({id})/host.network.receive({id}) \
                      return the next {text} or non-UTF-8 {base64,binary:true}, with eof and, for programs, stream/exit_code. receive/accept wait up to wait \
                      seconds (default 30), then {pending:true}; fetch waits up to wait seconds (default 120) for its whole answer. send waits up to wait \
                      seconds (default 30) for acceptance, else ends that program/connection. Over 4 MiB unread program output ends it. \
                      host.program.close({id}) ends it and its children; detached sessions can outlive it, as in the shell. Declare shell: requires Full Mac \
                      with file operations on, the same shell sandbox, and cwd inside the workspace (default) unless Full Mac lifts the sandbox. \
                      host.call(id,args) reaches exactly app.<id>(args) or the named primitive (host.call(\"network.send\",…) is host.network.send(…)), \
                      under \
                      the same declarations/gates.\u{20}
                      """
                      + "A habit that gathers and wants your judgment returns needs_me: \"<why>\"; otherwise it finishes the job itself. "
                      + """
                          host.model.call({purpose,prompt|messages,schema?}) uses your current chat model, without persona, returning text or checked JSON; \
                          declare model. messages: {role,content} strings.\u{20}
                          """
                      + """
                          host.fetch({url,method?,headers?,body?}) returns {status,headers,body}, body as UTF-8. Keyless calls require network_public, or \
                          network_localhost for loopback. Returns redirects without following.\u{20}
                          """
                      + """
                          Use {{secret:<name>}} in fetch url/headers/body, network.send text or program args/env/stdin; declare secret:<name>. Values go only \
                          to their granted host (https, established TLS, or Mac loopback; never udp) or program, and read back as [secret:<name>]. An absent \
                          secret refuses with card.request to ask once. Secret-bearing GET/HEAD with no body is a read; every other secret-bearing call \
                          passes Trust as an effect. host.measurementSystem: us, metric or other. app.mac.system_info({person:true}) returns \
                          {here,idle_seconds} from the person's input only (never yours), away after 300 seconds idle. Use it: ioreg/event-source idle clocks \
                          count your input.\u{20}
                          """
                      + """
                          host.calendar.upcoming/create/modify/delete, host.reminders.query/create/update/delete and host.contacts.search/save use each \
                          current app action's named arguments. calendar/reminders/contacts declarations include their app action dependencies; file reach \
                          includes reads, write reach mutations. reach: {capabilities,readPaths?,hosts?,apps?}. Every effect passes Trust.\u{20}
                          """
                      + """
                          host.apps.call({bundle_id,dictionary:true}) reads sdef; events take {bundle_id,event_class,event_id,parameters}. Declare \
                          app_read:<bundle_id> or app_write:<bundle_id> in reach.capabilities. Standard core getd/cnte/doex events are reads; \
                          modifying/unclassified events require write. Calls never prompt: request permission with target applescript:<bundle_id> for the \
                          owner's macOS grant.\u{20}
                          """
                      + """
                          host.apps.call({bundle_id,script}) runs AppleScript in that app's tell context; always requires app_write:<bundle_id>. No scripting \
                          additions, resource imports, script objects or self references; every event targets that exact process. app_write grants the app's \
                          broad reach: Finder, for example, can open files/URLs in other apps.\u{20}
                          """
                      + """
                          Event parameters use four-character keys and JSON descriptors: primitives, lists, {type}, {enum}, {ordinal}, {record}, or \
                          {object:{want,form,seld,from}}. {ordinal:\"all \"} selects every element with form:\"indx\"; the other absolute ordinals are \
                          \"firs\", \"last\", \"midd\" and \"any \" (spaces matter).\u{20}
                          """
                      + """
                          Omitted/null from targets the application: \
                          host.apps.call({bundle_id:\"com.apple.Keynote\",event_class:\"core\",event_id:\"getd\",parameters:{\"----\":{object:{want:\"prop\",form:\"prop\",seld:{type:\"pnam\"},from:null}}}}) \
                          reads its name.\u{20}
                          """
                      + """
                          screen.watch({app,fps?,seconds?,region?}) watches that app's front window for the run; fps up to 30 (default 10), seconds up to 600 \
                          (default 60); declare screen.watch.\u{20}
                          """
                      + """
                          screen.next(timeout?) skips older frames and returns the newest unseen {watch,seq,at,width,height,screen,read}; {timedOut:true} \
                          after timeout seconds without a new frame. Returns null when the watch ends: window gone, duration spent, Stop, screen control off, \
                          or person input with hands. Without hands, person input never ends it.\u{20}
                          """
                      + """
                          f.read([...]) batches queries in frame pixels until the next frame: {at:[x,y]} → {r,g,b}; {mean:[x,y,w,h]} → {r,g,b,l}; \
                          {changed:[x,y,w,h]} → share changed since the prior frame; {text:[x,y,w,h]} → redacted on-device text.\u{20}
                          """
                      + """
                          Declare hands for hand.click/double_click/right_click/move(x,y), hand.drag(x,y,toX,toY), hand.key(\"cmd+s\"), \
                          hand.hold(\"w\",seconds), hand.down(\"w\"), hand.up(\"w\"): frame-speed actions on that window in frame pixels, no model call; code \
                          is the reflex, args the intent. Keys held by down release on up, run end or person input.\u{20}
                          """
                      + """
                          const eyes = screen.watch({app:\"Safari\",fps:10,seconds:60}); while (true) { const f = screen.next(); if (!f) break; const [c] = \
                          f.read([{at:[120,80]}]); if (c.r > 200 && c.g < 60) hand.click(120,80) }\u{20}
                          """
                      + """
                          host.paths.home: absolute user home; resolve ~ in tool inputs. host.paths.workspace: your file folder; save there unless the person \
                          names another place. Files use app action arguments/results: host.files.write({path:\"workspace/note.txt\",content:\"hello\"}).\u{20}
                          """
                      + """
                          actions declares indirect app calls through host.call, app.call, app.read(actionID) and part.call, literal or computed; direct app \
                          dot/bracket members and reach derive the other dependencies. Save checks literal names and missing declarations before staging; \
                          computed names keep runtime checks and appear in receipt warnings. app(…) takes the door's own request forms ({action, args}, \
                          {actions:[…]}, {find}, {page, item}); other impossible prelude shapes refuse save with the supported form. Declarations grant no \
                          authority. params: input name → string/int/number/bool/list/object (optional with ?), {type,description?}, or a JSON Schema \
                          object. \
                          Revisions inherit code and unstated declarations (description,params,actions,reach,wake,face,resident,learned,choices) from the \
                          latest version; restating replaces, []/{} clears. ability.read {id} reads its code. Use edits:[{old,new}] instead of code: each old \
                          must occur exactly once; replacements apply in order and save as a revision. ability.validate intercepts calls: omit fixtures or \
                          use capture:true for one input run (default {}):\u{20}
                          """
                      + """
                          reads run live and answers are sealed; effects, nested tools and decisions return visible placeholders. Later validation replays \
                          that capture, covering only supplied inputs/reached calls; intercepted replies prove no live behavior.\u{20}
                          """
                      + "Or supply {input,expected,calls?:[{operation,args,result}]} fixtures to intercept every host call, "
                      + """
                          including app.<action> dependencies as operation app.<action>. reach.capabilities from app_data_read, app_data_write, \
                          network_localhost,\u{20}
                          """
                      + """
                          network, network_public, computer_files, arbitrary_file_write, shell, model, calendar, reminders, contacts, screen.watch, hands, \
                          secret:<name>, app_read:<bundle_id> or app_write:<bundle_id>.\u{20}
                          """
                      + """
                          Read-only code declares each primitive's reach; active abilities are callable from scripts under the same gates. Under Full Mac, \
                          your own save is kept and on immediately unless the owner turned it off; only the owner can lift that off. Active code runs as \
                          authored.<id>;\u{20}
                          """
                      + """
                          below Full Mac or on a turn started by an untrusted agent, it remains unkept; ability.enable files the owner's card. wake defaults \
                          []; face {page?,action?,projection?} places the action and may name an unclaimed app action id. projection:true declares \
                          face(input) → {title?,line?,opened?:{link,title},detail?:{of:sectionId},sections:[{id,title?,\
                          style?:list|values|timeline|flow|note|waiting,footer?,folded?,filter?:label,revision?:string,\
                          more?:{next:cursor,total?,revision?},rows?:[{id,title,detail?,value?,at?:ISO,symbol?:SF Symbol,\
                          tone?:plain|quiet|attention|failed|done|live,\
                          open?:chat:|page:|approval:|card:|dream:|url:,actions?:[{id,label,role?,unavailable?:reason}],control?:{on}|{options,selected}|\
                          {text,placeholder?}|{number:{value,min?,max?,step?}}|{date:ISO},rows?:[rows],expands?:true,\
                          meter?:{value,max,start?}}],\
                          block?:{kind:"document",key,text?,format?:plain|markdown|code,language?,copy?}|\
                          {kind:"leaf",key,leaf,ref,alt,revision?,cards?,choices?}|\
                          {kind:"form",key,fields:[{id,label,kind:line|lines|choice|switch|number|date|secret,value?,placeholder?,required?,\
                          options?:[{id,label}],min?,max?,step?}],submit:[{id,label,role?,unavailable?}],revision?,protected?,receiver?,doors?}}]} \
                          from a frozen packet, with no host effects. A section has rows or block, never both. On leaf:board ref:table, choices \
                          holds at most 200 {id,label,detail,item|piece} entries with unique nonempty ids, nonempty labels, string details and \
                          one nonempty item or make:<ref> piece address. cards holds live facts keyed by element id. A count is a row's value; progress \
                          is its meter, a bar of value out of max (max above 0, value and start from 0 to max; the words stay in value); a chart \
                          or picture is a piece: an SVG, HTML and CSS with no script (previews run none) or a picture, make.add it, then lay \
                          {kind:"leaf",key:"piece:<id>",leaf:"web"|"image",ref,revision:<its version as a string>,alt:<what it shows>}. \
                          Inline document text is at most 16 KiB; longer text is read on demand. A document key declares read:{action,args?}; \
                          the action must declare itself read-only. Its frozen result enters face(input) as input.read; return the requested \
                          document block with its text. \
                          Collections use their section id's read, with args.cursor, revision and anchor from the held demand. Inline nested rows \
                          share the section's 256-row bound and nest at most four deep; expands names that row's read for deeper evidence. \
                          opened says what the page has open now: a page link, as page:<page>/<item>, and a one-line title, for the ask bar and page reads. \
                          A selected row links page:<page>/<item>; detail.of names the list section. Each held item read returns its face, \
                          outside the top-level phone snapshot. A filter searches retained rows; an owner query travels with its held result. \
                          A row that opens, acts or holds a control has an id its packet's keys declare, with only that key's open and actions; \
                          a key {open?,actions?:[{id,role?,doors?,unavailable?:reason,call:{action,args?}|open}],set?:{action,args?},read?:{action,args?},\
                          submit?:{<id>:{action,args?}}} \
                          says what each action calls \
                          (an app call, the same one you make) and what a control's change calls with its value as args.value. A form's key \
                          owns each submit call; its public fields enter args and the key's fixed args win. A protected authored form has \
                          protected:true, receiver:"keyring:<name>", doors:["mac"] and exactly one secret field without value; its submit \
                          calls that exact receiver without args. Native protected entry stores its transient bytes in Keychain, never in \
                          form args, drafts, records or feedback; you read only set/not set. Other secret receivers belong to native owners. A person's tap \
                          runs a row's call through their door; on a page of your own it is your call, asked of them. With \
                          projection, a new page:"<id>" makes the part a page of your own, drawn from its host.state notebook (declare keys there), \
                          placed by layout.write as page:<id> on rail or more. native-desk, native-memories, native-personality and \
                          native-diagnostics draw those pages; native-document draws passive document packets. The person's levers \
                          (consent, models, forgetting, reset, approvals) are the app's: \
                          a page's drawn first, a key's actions after yours on each row with that id. \
                          part.call(id,input) calls a declared authored.<id> → {ok:true,value} or {ok:false,error:{code,message}}; input: frozen JSON \
                          object, \
                          max 4 MiB. host.model.call may pass tools:[\"app\"] and a routing surface, limited by this ability's reach and caller. params \
                          {type:\"object\",properties,readOnly:true} declares a read contract; effects still pass Trust. resident defaults false; true \
                          retains JS across successful runs and holds opened programs/connections until code closes them, the ability is turned off or \
                          replaced, or the app quits. Nonresident held resources end with the run; detached program sessions may outlive it. wake [\"held\"] \
                          delivers input.wake {id,kind} for arriving data; read via receive/accept, wait 0 for only available data. wake [\"resumed\"] \
                          delivers input.wake at launch; code must reopen resources using saved state. Without it, no launch wake. wake \
                          [\"person.away\"]/[\"person.here\"] delivers input.wake {idle_seconds} once per presence change: away at 300 seconds idle, back on \
                          person input (never yours). learned.use reports exact-input/reached-call outcomes of ordinary gated runs of the selected version: \
                          execution, not proof of a larger task. Intercepted executions, previews and replays earn no competence. choices: reserved JSON. \
                          Source max: 524288 bytes. converts: optional original source SHA-256 digests from Tools census, binding conversion counterparts to \
                          this exact version.
                          """,
                  tool: "ability_manage", input: verb("save"), lifecycle: .change, schema: abilitySaveSchema),
        AppAction("ability.read", "tools", """
            One ability of yours: what it declares, its status and versions, and its code in pages; a built-in skill's guidance reads too
            """,
                  [.required("id"), .optional("offset", .integer), .optional("step", .integer)], subject: ["id"], tool: "ability_manage", input: verb("read"), read: true),
        AppAction("ability.list", "tools", "Your abilities with run_counts (all_versions, current_version) and last_run_at; follow next_call when has_more",
            [.optional("offset", .integer)], tool: "ability_manage",
            input: verb("list"), read: true),
        AppAction("ability.validate", "tools", "Validate an unkept version on supplied input or one captured run; intercepted replies prove no live behavior",
                  [.required("id"), .optional("input", .openObject), .optional("capture", .boolean)], subject: ["id"], tool: "ability_manage", input: verb("validate"), read: true,
                  schema: arguments("ability_manage", ["id": ToolSchema.strSchema(), "capture": .object(["type": .string("boolean")]),
                      "input": .object(["type": .string("object"), "additionalProperties": .bool(true),
                    "description": .string("""
                        Input for the selected ability version; its params/input schema from ability.read determines the fields and types. Omit for {} or \
                        saved fixtures.
                        """)])], read: true)),
        AppAction("ability.enable", "tools", """
            Keep an unkept version and turn it on: your work under Full Mac unless the owner turned it off, else the owner's card. Code needs its full \
            version digest; omit version only to restore Markdown guidance
            """,
                  [.required("id"), .optional("version")], subject: ["id"], tool: "ability_manage", input: verb("enable"), lifecycle: .enable),
        AppAction("ability.restore", "tools", """
            Turn an ability back on via ability.enable; code needs its full version digest; omit version only to restore Markdown guidance
            """, [.required("id"), .optional("version")], subject: ["id"],
                  tool: "ability_manage", input: verb("restore"), revision: 3, lifecycle: .restore),
        AppAction("ability.disable", "tools", "Turn an ability off, keeping its current and previous versions", [.required("id"), .optional("reason")], subject: ["id"],
                  tool: "ability_manage", input: verb("disable"), revision: 2, lifecycle: .change),
        AppAction("ability.drop", "tools", """
            Delete an ability, its versions and its run state permanently; pending:true discards only its unkept version
            """, [.required("id"), .optional("pending", .boolean), .optional("reason")], subject: ["id"],
                  irreversible: true, capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "ability_manage", input: verb("drop"), revision: 2,
                      lifecycle: .drop),
        AppAction("ability.resume", "tools", "Resume a run stopped at a decision or card preview only if its journal contains no primitive call",
                  [.required("run_id"), .optional("id"), .optional("answer", .any)], subject: ["run_id"], warn: """
                      Optional id binds the run to its ability (bare id or authored.<id>); a mismatch claims nothing. The stopped step returns answer. Any \
                      journal call beginning with primitive blocks resume. Before starting a fresh run, inspect prior calls and effects: a fresh run executes \
                      from the beginning and may repeat effects; pass the answer as input and account for completed work.
                      """,
                  tool: "ability_manage", input: verb("resume"), schema: arguments("ability_manage", ["run_id": ToolSchema.strSchema(), "id": ToolSchema
                      .strSchema(), "answer": .object([
                    "description": .string("""
                        Any JSON returned to the stopped app.decide step; its recorded question determines the answer's meaning. Inspect that run's question \
                        before answering.
                        """)])]), part: ""),
        ]
    }
}
