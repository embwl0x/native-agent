# NativeAgent user and agent guide

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

Start with a conversation. Connect services and grant access as the work needs
them.

## Find your way around

Install NativeAgent on an Apple silicon Mac running macOS 26 or newer. Open
the DMG from [Releases](https://github.com/embwl0x/native-agent/releases),
drag NativeAgent to Applications, then open it. Enter your name and your
agent's name. Connect an AI account or add an API key. **Skip for now**
lets you finish without a ready account once account loading has stopped.
A connected account needs a usable Chat model before you can continue.
You can connect later under **Control → Providers**. See
[Getting started](GETTING_STARTED.md) for each setup step.

First-run setup opens only after a successful eligibility read. A read failure
shows its cause and a **Retry** action; it does not automatically retry or
assume that setup is needed.

### Simple, Advanced and Agent

Use the view switch at the top right of the Mac window.

- **Simple** presents chat beside the agent's card, its places and two folded
  lists. Open **Together**, **Table**, the place named for your agent
  (**Agent** before naming), or **Control**. These places share their pages,
  rows, waiting dots and remembered tabs with Advanced. **Together** returns you
  to the conversation. Open **Control → Settings** or press Command-comma.
  Expand **Agents** or **Helpers** using their chevrons. Each list opens folded
  and shows a count. A folded list has a dot when an agent waits for you to
  approve its program or a helper waits for your answer, approval or model choice.
- **Advanced** calls the first two places **Chat** and **Desk** and adds the conversation list, the Work pane in Chat and
  **Diagnostics** at the foot of the rail. **Desk** holds **Today**, **Desk**,
  **Notifications** and **Helpers**. The place named for your agent holds
  **Memories**, **Personality**, **Capabilities** and any page of its own.
  **Control** holds **Providers**, **Trust**, **Connectors** and **Settings**.
  The layout decides which pages show and their order. A place with no visible
  pages leaves the rail. Places with multiple pages have tabs across the top.
  Choosing a place returns you to its last tab in this window. On the first
  visit, **Desk** opens the board, the agent's place opens **Memories**, and
  **Control** opens **Trust**. A request waiting on you puts a dot on **Desk**
  and **Today**. Menus, links and command search select the destination tab.
  Command-K accepts either place name in both modes and can find Diagnostics
  and pages the agent has published. Opening Diagnostics from Simple stays in
  Simple.
- **Agent** shows the agent's read-only Home and rooms. A conversation opened there shows in Simple.

An absent view preference starts in Simple, independently of saved chats.
A saved supported choice is preserved. Page names in this guide refer to Advanced.
The app restores the current page, each rail page's last tab, and the window's
placement, zoom and full-screen state.

Command search opens the exact selected helper reply, dream date or memory.
Unavailable selected content reports that state rather than opening a different item.

### Use page controls

Cards have compact rows. The title and detail use one line each, with status
and time at the trailing edge. On the Mac, hover over a row or give it keyboard
focus to reveal its actions. Command
rows and pills keep their actions visible. Hover over a pill to read its detail.
Up and Down move between rows. Tab reaches controls. Return opens the row,
runs its main action or submits a field. Space changes a switch. Right-click
for actions and **Copy**, press ⌘C to copy the row, or press ⌘F for the local
filter. Narrow pages place values and controls below the text. Destructive
actions ask once. A request's filled button answers it. **Not now** sits beside
it. **Mark read**, **Archive** and **Dismiss** are in its ⋯ menu. On the
phone, swipe a row or press and hold it for actions.

Page actions show their waiting state and any refusal beside the row. A second tap
while that row is waiting sends no new action. Text entered after submitting an edit
stays when its reply arrives. Leaving the page keeps accepted work running and keeps
its reply off the next page. Cancel on the Mac asks its owner to stop; Cancel waiting
on the phone stops waiting for the signed Mac action. An unknown effect stays unknown;
**Read current state** reads without repeating it. Only evidence that establishes the
edit releases its held submit. Undo appears only when the owner supplies an inverse.

## Chat

Type in the box at the bottom and press Return or click **Send message**.
Use the attachment button to add a file or the microphone to dictate.
macOS can ask for microphone and speech recognition access. In Advanced,
use the conversation list to switch sessions and the Work pane to follow
turn progress.

While a turn uses tools, its recent steps appear above the Mac composer. Hover
or focus a row to keep the panel visible when the turn ends. Selecting text
or opening a row's **Copy** menu also holds the panel. Choose **Keep open**
to freeze the reading. **Dismiss** closes a held reading after the turn. To
redirect a running turn, send your update through the composer.

The main conversation shows its transcript owner's read failure even before any
messages have loaded. **Try reading again** awaits one fresh read's completion,
error or cancellation; silence does not diagnose missing messages.
In the copied window, selecting a chat opens its ending messages first. Earlier
messages load when you scroll toward their beginning, use Find or Select All,
copy a whole message, or send. They also load when the ending messages fit within
the reading area, including when tool rows are folded. You stay at the end while
following it; after scrolling away, you keep the same paragraph and offset as
the scrollbar grows. A full-document command waits visibly for the earlier
messages; closing the conversation cancels that wait. Search, exports, the
agent's history and phone sync always read complete messages.
When the agent starts a call in another conversation, one quiet moving line
above your composer shows that work. Select it to open that conversation; its
Stop control requests cancellation there. A count menu opens additional working
conversations. The line ends when the turn settles. Thoughts without calls stay
quiet. Main and detached Mac chats, full Shotgun and the phone share this row;
the phone shows the Mac's last synced movement. It carries call names and
movement, without the other conversation's words or call arguments.

Mac chat, contact and helper text and iPhone chat use the shared inline
Markdown parser and link policy (http, https and mailto). A formatting failure
shows **Message formatting could not be read:** with its cause and the labeled
original text; it never silently becomes an ordinary plain-text reply. Mac
Copy carries that notice too. Thread text awaiting preparation says
**Formatting message…** until its current text is ready. Chat's fenced-code
blocks remain literal by design.

A row's images, voice notes and files appear above its words in Mac chat.
An image with neither a local path nor a prepared preview, or with an unreadable
prepared preview, shows **Image unavailable**.

Holding ⌘⇧J starts push-to-talk after its hold delay. Releasing an active
recording ends capture even if the Mac's clock changed during the hold.
Mac composers show **Waiting for transcript** until recognition supplies its final result or error.
**Discard voice input** cancels capture and any pending stop, restoring the draft from before dictation unless the person edited it.
Audio attachments show a waveform, duration, play/pause and a two-line
transcript that expands on tap. See [Voice notes](mobile_companion.md#voice-notes)
for iPhone composer voice input, recognition, limits and transport.

For local read-aloud, choose an installed Apple voice or use the Mac's
system default. If the selected voice is unavailable, Chat reports it.
Cloud playback records unsuccessful finishes and decode failures. Check
the playback result to see how it finished.

### Send from another page

- **The ask bar.** Every page but Chat, in Simple and Advanced, has one line
  under it: "Tell <agent name> what to change here". Return sends your words to
  the active conversation as your own message, led by the page you are on and
  what it has open when the page says so (`About Desk (page:desk): move step
  three to the top`, or `About Desk · Board proof (page:desk/desk.335): …`),
  and you stay on the page. "Let me take over" and the other control phrases
  go exactly as you typed them. An empty bar sends nothing, and a second Return
  while your words are on their way does nothing. A refused send puts your
  words back in the bar and says why. Above the bar one quiet line then says
  only what it knows: that the agent needs your OK when an approval waits, what
  the agent is doing now while a turn runs (the Steps line's words), otherwise
  "Sent."; it does not report how a turn ended. **Open chat** opens the
  conversation. If the agent is already working there, your words reach it
  while it works, as they do from the composer, and the line says so. The page
  redraws by itself when the agent changes it. Pictures of a page do not show
  the bar.

### Slash commands

In the main chat, type `/` for the command menu or `/help` for the complete
list. Simple and Advanced share the same commands. Close or Escape dismisses
a floating control and returns you to the conversation in the same view.

| Command | Opens or does |
|---|---|
| `/settings` | Settings. |
| `/connect [service]` | Open **Connectors**. `/connect slack` opens Slack setup directly. `/connect telegram` and `/connect iphone` open Connectors, where you can open that service's row. For Chrome setup, use **Trust → Chrome control**. |
| `/helpers` | The shared Helpers face, with Run once, Paused and links to indexed conversations. |
| `/agents` | Open **Connectors**. Find agent contacts under **Where I reach** and their threads under **Agent conversations**. |
| `/today` | Today. |
| `/desk` | Desk, starting at its root. |
| `/memory [thing]` | The shared Memories face, with optional search text of at least three characters. A page screenshot leaves the open search unchanged. |
| `/forget` | Saved memories, where **Forget this…** asks for confirmation on the chosen row. Opening the command forgets nothing. |
| `/voice` | Starts or stops the same voice input as the microphone button, with the same permissions and errors. |
| `/context` | The composer's last-turn context receipt, including its loading, no-turn and unreadable-trace states. |
| `/tools` | Open **Capabilities** in the main window. |
| `/new` | Start a new conversation. |
| `/clear` | Ask before clearing the current conversation. |
| `/export` | Export the conversation to Downloads as Markdown. |
| `/model <id>`, `/think <level>`, `/fast <on\|off>` | Change the Chat model, reasoning effort or Fast processing. Available values depend on the selected account and model. |
| `/persona <name>` | Select a persona by name. |
| `/remember <fact>`, `/note <text>` | Commit something to memory. |
| `/scratch <key> <value>` | Write a temporary scratchpad entry for the session. |
| `/help` | Show the full command list in Chat. |

Arguments in square brackets are optional. **Settings**, **Helpers**,
**Agents**, **Today**, **Desk**, **Forget**, **Voice** and **Context** take
no arguments. Commands preserve pending attachments. A typo such as
`/setings` reports the unknown command and keeps your draft. Absolute paths
such as `/tmp/file` go through as chat text. Run slash commands in the main
window. Detached chat directs you there. A hidden Connectors page or unavailable
composer receipt is reported explicitly. Unsupported service names with
`/connect` report that setup is unavailable through the command. Links inside
floating controls keep their usual destinations and can open an Advanced page.

### Read the context for a reply

Context receipts leave unmeasured sizes and totals unavailable; token shares
are calculated only from a complete assembled size. The composer's Context
popover shows the last provider request total against the selected model's
window, a segmented bar and matching rows with aligned token counts and
shares of the request. Opening-request parts are estimated by byte size with
integer shares that add to the opening provider count; measured growth through
tool rounds completes the final total. Images, incomplete sizes or a smaller
final request leave the affected part counts unknown; a known provider total
still draws the overall usage without inventing a split. Memory recall has
its own injected-memory count, separate from token shares. The footer names
the model that ran and when. **Show what I was given** opens the saved context.

The composer context readout formats percentages without integer narrowing
and signed token changes without taking an absolute value. Large recorded
counts remain visible, including usage above the selected window.

The agent holds your conversation word for word, each message with the time it
was said; going quiet never ends what it holds. Anything that has left the
replay stays in the saved transcript: when your
words touch an earlier message, the agent gets a short pointer to it, and it can
open earlier messages itself or recall them. What it was given to think with in
a moment (the time, what came to mind, recent receipts) is sent once, with that
message, and not again. If a conversation runs long enough to
reach the powering model's input budget, its oldest whole turns leave the replay in
half-budget jumps and stay in the saved transcript. A long running turn replaces
its oldest tool-result bodies with pointers to their full saved results. It
never writes a summary to stand in for what was said. There is no manual compact
control or custom context window. The composer ring shows the last observed
provider input against the model window, usually a small share of it;
unknown measurements remain unavailable.

## Home

Choose **Agent** at the top of the Mac window. Home shows what matters to your
agent now, what's changed, and work in progress or waiting for you. Open a row
to see its details. Opening a conversation here takes you to **Simple**.

Home follows your layout. Its sections include **Notable**, **Changed**,
what waits on you, **My queue**, **Working**, **Open**, **People**, **Helpers**,
**My senses**, **Elsewhere**, **Places** and **Mac**. Rows link to work,
conversations, approvals and cards. In Mac Agent view, Home is read-only and
its links open the corresponding destination. Opening Home leaves its read
state alone.

A section that couldn't be read shows its cause while other sections remain visible.
Home also shows the five newest retained refused ability runs, including scheduled
runs, with the cause and the time of that attempt. Open a row to read the ability;
its retained run and dispatch receipt carry the owner's remedy. An unreadable run
record is shown as unavailable, and a cause absent from an older record stays unknown.

## Desk and Today

### Work on the Desk

Use **Desk → Desk** for work that needs several steps or will be picked up
later. Dependencies, schedules, checkpoints, approval pauses and outcomes
stay with the task. A **held** row explains its blocker, defer or held parent.
On the Mac, click **New task**, enter a **Title** and optional **Objective**,
then choose **Create Task**. The Shortcuts intent can create the same item.
Ask from Chat on iPhone. A [line of your agent's own](#lines-of-their-own) can
carry the task to completion. See [Desk vocabulary](DESK.md) for its actions,
waits on people and paged reads.

Desk has one face for its board, other work, attention, timers and reminders.
The Desk tools sit at the top. What waits comes first, open: Waiting and Needs
you; then **On the table**; then the work under way: Now, Watching and Queued,
other work now and Parked. Below them come Done today, recent work and lines,
and Finished history, folded, with its items under the day each closed. The
agent's own upkeep (items of the `body` project) stands apart: what it finished
today under one **My own upkeep** row in Done today, the rest at the very end
in one folded **My own upkeep** section whose line counts what is open and
names the one under way. An upkeep item that waits on you, is flagged or
blocked, or whose activity is stale or blocked stands with the work instead.
Open an item to read its details first, including its notes, dependencies and
pursuit accounting. An item with steps under it opens as a board: its steps in
columns side by side (Now, Next, Waiting, Done), each card offering **Start**
or **Done**, and **Add a step** under them; Done shows the latest eight, and a
column's footer counts what it does not show. Close, Defer, Note and Veto use the same
work owners as before; Close and Veto ask for confirmation. New task and Note
open retained draft editors on the Mac. The command palette still finds items.

Open an item to follow its progress, check its schedule or dependencies,
and see the outcome. Open **On the table** to find [work your agent has
made](#make).

### See what happened and what needs you

Open **Desk → Today** for recent work, approvals, proposals, notifications
and what's ahead. Open a request to read what your agent needs from you.

Today recognizes collaboration from recorded peer-bridge provenance, with
contact names resolved by the connected-agent directory. Unreadable contact
evidence is reported as unavailable. Approval requester names use the same
directory, including saved legacy bridge routes; route names do not override
the person's contact names.

**What I did** is a timeline. **Ahead** lists upcoming intentions and the
next night check when available. **Earlier** shows notes with their newest
dates. Any missing source has its own notice. In **What I did** and
**Earlier**, decisions of the same kind
sit under a row with the first decision and a count such as “3 decisions.”
Expand its chevron for each decision. A single plain note has no count.
An intention row shows its words or title and, when it falls on another day,
the date. Kept moments sit under their rows. Dream and conversation rows open
their recorded destinations, and waiting requests open their Activity details.

Opening Today uses the posted face. **Reading Today…** appears before the
first result. Source changes update the sections they feed, and a failure
shows its cause. Today updates the dream schedule when its time changes and
**Ahead** when the next intention occurrence passes. Trial rows follow the
agent's saved name. Approval rows on Home and Today use the approval's
privacy-filtered wording before shortening it, on Mac and phone alike.

### Inbox and notifications

Open **Desk → Notifications** for the Inbox. From Today, **Approvals and past
decisions** and **Every note I've left you** open the same Inbox. Use
**Control → Settings → Notifications** for notification preferences and history.

Requests appear in **Waiting for you**, followed
by **Went wrong**, then **News** with unread matters first. Rows retain the
recorded time, symbol, destination and choices. Approval buttons say
**Approve** and **Decline**, or **Just this**, **For this task** and **Decline** for an untrusted agent; requests keep their choices,
**Open request** and **Not now**. Other notes offer **Mark read**, **Archive**
and **Dismiss**. Decline, Not now, Archive and Dismiss ask for confirmation.
Putting a note away removes it from the active list. Open **What I decided on
my own** to see decisions your agent made. Decisions of one kind, such as
keeping abilities, share a row with the first decision and counts for the
rest and for unread decisions. Expand it to read each decision, newest first.
The grouped row offers **Mark all read** and **Archive all**. A kind with one
decision has a plain row. **Earlier** folds archived and dismissed matters
under their counts. Expand a grouped history row for its individual notes
and available actions. Decided cards lead with **Declined**, **Not now**,
**Failed**, **Unknown** or **Done** and the saved result; the original request follows.
Mac and phone keep the same outcome after relaunch. An earlier **Not now** keeps
its recorded consequence even if setup later becomes ready. An unavailable saved
approval result says **Unknown** with its cause.

The notifications master controls whether your agent can raise things
unasked. Ask in Chat for a morning brief. Its only triggers are a direct
call to its part and a step in your agent's own queue.

The separate Inbox category picker, archived toggle and approval history panel
are removed. The chat header's note detail and notification preferences history
remain available. Shared face rows currently show only four lines of detail;
the full approval preview is still available in the conversation's approval card.

The chat header's updates and note detail use the shared rows and document
reader. If Inbox changes while you confirm a note action on the Mac, the
action asks you to read the current note before trying again. **Mark all read**
keeps each unconfirmed update and its cause in
**Read outcomes**; successful writes alone dismiss the list. An unknown
outcome holds that operation and offers a check without repeating its writes.
Read the Inbox to inspect the owner's current state before another action.

## Make

Open a Desk item under **On the table** to see the document, picture,
mockup or sheet your agent put there. In **Advanced**, open Chat's Work pane
with ⌥⌘0 and choose **Make**. **Open in Make** on a Desk piece takes you
straight to it. Pick a version to preview and choose **Use this** to save a copy.

What the agent makes and lays on an item (a mockup, a sheet, a document) sits
under **On the table**, after what waits on you, newest first; each
opens its item, whose own row says how many things it holds. In the opened
item the mockups, pages and pictures stand side by side, each as Make's preview
of its newest version, and documents and tables follow at full width: a
document shows its words, and a table (CSV or TSV) is a real table whose cells
you change by clicking one, typing and pressing Return (Escape leaves it), with
**Find** and **Copy** above it. Each change, row or column you add is saved as a
new version marked as yours, with every cell you did not touch kept exactly as
it was; if the agent laid a newer version meanwhile, nothing is saved and the
newest is shown under the words that say so. A plan with steps shows a bar of
its closed steps on its row.
**Open in Make** opens it in the Work pane, where its versions are and the same
table is drawn. A new version shows on the Desk as soon as Make has it.

Make's HTML previews stay offline and script-free within the selected
artifact's folder. Changing selection or closing the preview cancels pending
preparation, so an earlier load cannot replace the current artifact.
Quick Look construction failure is shown as an unavailable preview.
If the offline rule list cannot be prepared, Make keeps the artifact closed
and displays the sanitized WebKit cause.
Image formats use AppKit's image decoder; missing, unreadable or undecodable
bytes display an explicit image-preview error. Quick Look handles formats
assigned to it, with no renderer switch after an image decode failure.

Make export prepares the work and prompt bytes before replacing either file,
then reports each output's outcome separately. The two replacements are not a
transaction: if the prompt write fails after the work was saved, the saved work
and the prompt's unconfirmed outcome both remain visible. Inspect an
unconfirmed output before repeating the export. Neither output may overwrite
the studio source, including through a hard link or symlink.

## Memories and personality

Open the place named for your agent and choose **Memories** or **Personality**.

**MemoryV2** stores durable memories. **Personality** holds identity and voice
documents. The generated about-you document is a projection of memory; edit
the facts through **Memories**. The knowledge graph is an index over memory,
and Fluid Context prepares bounded material for a turn from the underlying
stores.

### Find and edit a memory

Open a proposed memory to choose **Keep** or **Don't keep**. A saved memory
opens its full text. Use **Forget this…** and confirm to remove it.

Memories shows pinned and recent saved memories, proposals
waiting for review, and read-only rejected history. Each saved row opens its
full text and offers pinning or forgetting; forgetting asks once. The body's
forget receipt identifies the deleted memory; the window accepts only a committed
result before dismissing the document or reporting deletion. The full-text
sheet can prepare a correction draft in Chat. Open **Knowledge graph** from
its row or tab to see the native Mac canvas.

The phone uses the same page design over memories and proposals permitted on
`ios`; a chat-only memory stays on the Mac. Native memory/proposal labels hide
credential text.
**Memory upkeep** draws the memory owner's diagnostics and its Reindex
Spotlight and Check again commands through the shared page. Unreadable
diagnostics keep their cause beside retained readings; missing evidence never
proves that there are no memories. The search-model download keeps its own
system progress and Pause / Check or resume controls.

Search in Memories under **Search what I've kept** or use `/memory [thing]`
(at least three characters). Command search can open a saved memory. A failed
meaning-based query shows its owner's cause; retained results identify the
query that produced them. Store changes refresh the results even when the page
is closed; **Check again** retries the query. **Show all memories** clears it.
Knowledge graph time filters refresh at their next entity expiry while mounted,
and re-evaluate when the system clock, time zone or calendar changes.
While open, the graph observes canonical SQLite and WAL changes and refreshes
its shared snapshot and selected neighborhood. Observation starts independently
of the first policy read, so recovering an unreadable policy with Retry keeps live
graph updates without reopening. Failed reads retain the prior snapshot with their
cause; a failed live subscription reports that updates are unavailable and asks
you to reopen the graph.

The **Memory status and Spotlight** row opens the existing Mac upkeep panel,
including the search model, Spotlight reindexing and **Check again**. The bulk
**Consolidate now** and **Run hygiene** controls and their report are retired.
Old memories fade from recall through disuse. Asking to forget removes records.
Capacity overflow (2,000 active rows by default) archives active records with
reason `capacity`. Lower-value records go first, then the least recently used.
Pinned, identity and correction records go last. See [Data bounds](data-bounds.md).

Pinning or deleting a memory refreshes the Memories face and reports the
committed mutation's result; it does not wait for a global app refresh.

What you tell the agent about yourself, and what a trusted agent or the agent itself says,
is kept as a fact at once with where and when it was said; correct or forget it when it is wrong.
Facts from an agent you have not trusted wait in Today or Memories for review. Skills are built-in guidance;
dreams and REM consolidate experience. A dream never makes a statement a canonical fact.

### Identity, voice and dreams

Use **Personality** to read or edit your agent's name, voice and identity,
review how it's changing, choose a model under **My minds**, or open **Dream diary**.

The Personality page reads one shared face from launch and whenever its saved
inputs change, whether or not the page is open. It shows the saved name,
each document's title and first line with its update time, their self-reading,
Memory and mind's model choice and recent dreams. A failed read stays visible in its own section. Open a document
or **Read or edit my identity** to use the existing name/document editor and
starter form; unsaved drafts and the read-only about-you document keep their
existing rules. **My minds** opens the provider/model picker and **Dream diary**
opens Dreams with its Dream/REM controls. A proposal opens its existing approval
card. **Reset identity…** opens the existing reset view; its confirmation and
backup behavior are unchanged.

Persona replacement, section append and editor saves require the existing
document to read successfully under its write lock before backup or mutation.
Replacement retains the complete supplied text; editor/setup append refuses a combined document above 30,000 code points before writing.
A missing or unreadable document reports its full path and asks for repair or
restoration; an ordinary edit never recreates it. Explicit setup and the
compiler's [missing-document creation](#identity-and-provider-internals) own creation.
Document saves return the saved bytes and modification time; if
readback fails after saving, the failure says the edit already landed and to
read before repeating it.

Initial setup and missing-profile repair require both your name and a specific
agent name. The Personality starter marks your name required and keeps Create
disabled while either name is blank, including whitespace-only input.
Completion, repair and later profile/name saves use the shared
identity validator: generic labels (Agent, Custom, AI, Male, Female), control
characters and names over 80 Unicode code points are refused before publication.

## Capabilities

Open the place named for your agent and choose **Capabilities**, or type
`/tools` in Chat. To ask for an ability, describe the repeated job in Chat.
Open an ability here to read its details, version and evidence. Choose
**Approve** when it needs your review, **Turn off** to switch it off, and
**Turn on** to admit it again when offered. An ability uses your existing
Trust settings. See [Ability format and lifecycle](skill_manifest_spec.md).

Capabilities uses the same face on the Mac and in the agent's page reading;
the phone receives that face in its snapshot. What waits on you or is not
ready (waiting for review or approval, failing) comes first, ungrouped; what is
only switched off sits under **Switched off**, folded, at the end.
**My abilities** follows, one row per purpose (the page an ability is placed on,
the subject of what it answers or calls, the app it reaches, else its name's
first word) that opens to the abilities and counts them; **Built in** lists
the app's own features, guidance and connector actions. A sense carries no
switch: it is on unless switched off, its row says its state, and Turn off /
Turn on and Share sense are actions on it; the agent turns a sense off on its
own, and turning one on asks you. Rows offer
Check trust, Mac Dry run / Run, connector Dry run, improvement checks,
a browser preview, cancellation of a live browser run, Export and Support bundle.
Latest check names the capability its Check trust action checks; without an
evaluation it says No check in this session and offers no Check trust action.
Connector actions without recorded health say Not set up. On Connectors,
set-up routes whose health is missing or unknown say Set up · Not checked;
Connected and Ready require measured health, as the
[status contract](ONE_DOOR.md#authority-and-receipts) describes.
Missing reads stay waiting or show their failure. Page search, catalog-entry forms, the memory graph,
research lab and Your spaces are removed from this page; ask in Chat for
searches, catalog changes and research, and use Personality for your spaces.

**Built in** includes guidance your agent can read when relevant. An MCP
server your agent needs is an ability it can create and keep running.
Review authored abilities here in Capabilities.

### Search, connectors and shared folders

Web search uses the SearXNG service configured under **Settings → Advanced**.
Open the search service settings in Research to find or save an endpoint. A
search reports its setup problem or any gaps it found in the results.

In Research's search service settings, **Find** and **Save** run one at a time.
You can keep editing the URL while either runs. The result leaves your new
draft and its feedback in place.

Open **Control → Connectors** to manage service accounts, your iPhone and
agent contacts. Open a row to reach its own settings.

- Set up Slack and Telegram in **Connectors**. For a service without a built-in
  route, your agent can grow an ability. The agent asks you to grant its secret
  once in protected entry, and the keyring keeps it.
  The Connectors tab and the agent's page reading share one face, also sent in
  phone snapshots. **Where I reach** comes first: every account (with its status,
  available switch, setup card, browser access and disconnection), the iPhone and
  each agent contact, one row each with its state as the row's value. A row's own
  settings open from its chevron: Telegram's switches, bot token, allowlists,
  mention, model and voice; the iPhone's pairing facts, paired devices (Pair,
  Remove), delivery check, notifications, key rotation and phone senses; an agent's
  unfinished Grok Bot setup. **Agent conversations** lists saved threads. **Kept secrets**
  lists each secret's name, destinations, account and grant time; **Forget**
  asks for confirmation before deleting it. **Folders I may open** shows each
  shared folder's path and read or read/write access. With nothing kept or shared
  yet, **Secrets and folders** says so in one line each, the folder line carrying
  **Share a folder**. **Telegram diagnostics** (Clear logs) and Telegram's recent
  replies, blocked messages and errors come last, folded. Unread or unavailable
  sections say so, and owner changes update the face even while the tab is closed.
  A failed Telegram read shows its cause and Read again action behind Telegram's row;
  it does not expose controls from an earlier reading. Other connectors remain readable.
  Authentication and service permissions still apply when an action is available.

In **Connectors**, choose **Share a folder** on your Mac (under **Folders I may
open**, or on **No folder is shared yet** before the first one).
The folder picker accepts an optional name and **Let me write to it**; **Share
Folder** saves the selection. Cancelling shares nothing. Ask the agent in chat
to search your shared folders.

The [one-door contract](ONE_DOOR.md) defines this interface. For file work,
the default folder on an app-only install is:

```text
~/Library/Application Support/NativeAgent/workspace
```

Source-backed installs use the checkout's `workspace/`. Every surface uses
the same resolver. Full Mac can authorize work in an explicitly selected
project elsewhere; Apple's privacy permissions still apply to protected
locations.

## Helpers: standing bots

Open **Desk → Helpers**, expand **Helpers** in Simple, or type `/helpers`
in Chat. Open a helper to read the brief, check the run history and see
whether it follows Chat's provider or uses its own model.

A helper has a name, optional personality and brief; its conversation is saved
when it first opens or runs. The brief is its complete job, including any
desired output form. To create or change one, say what you want in Chat.

Each helper shows its status, model choice and timing,
**Run once**, a **Paused** switch when it has scheduled or event work, its brief,
missed runs and its five newest runs with their outcome, duration and recorded
model. A running helper carries its recorded start time. Open an indexed
conversation from its helper or run row; a helper without one says
“No conversation yet — Run once, or tell me in chat.” A blocked model choice
shows its reason. An unreadable or not-yet-read conversation index says so
instead of claiming that a conversation does not exist. Palette replies open
their saved conversation. Full replies, artifacts and earlier runs live in chat.
On iPhone, open **Table → Helpers** to see runs and open their conversations.

By default a helper follows Chat's current provider, model, Think and Fast.
Ask your agent in Chat to pin a model for a helper to give it its own saved
choice or to switch it back to following Chat. The helper runs under the
current Trust policy. An unavailable or invalid selection prevents a run.

Use **Run once** for an explicit request, or configure a schedule or a supported
Slack event. An optional Slack keyword matches the message text, ignoring case.
A run requested from a conversation returns one line there with the helper's
name, its success, failure or waiting status, and a link to open its saved reply.
A run requested from the helper's own page stays in that helper's conversation. If refused
before execution, its cause is written there as an app receipt before the
request is marked delivered; no helper reply or interrupted run is invented.

Malformed conditioned results keep their prose as partial evidence and report a
failed verdict. Helper-definition, event and approval reads stay checked; a failed
reconciliation is unavailable rather than “No event yet” or an ordinary waiting
row. The Desk labels retained helper schedule rows stale when their source fails.
An invalid saved minimum cadence asks for a value from 1 to 15 minutes in Helpers
settings; it never silently chooses a cadence.

Approving a helper's tool call continues through that helper's own runner and transcript,
with the approval's origin and file-access restriction. The person's approval
continues even if the helper's unattended schedule is paused.

**Tell me if** asks the helper to judge that standing run's result. A true
verdict notifies; false stays quiet. If a settled run cannot supply a valid
verdict, including a failed or stopped run, the notification says it couldn't
tell and directs you to the saved run. The result and verdict are saved
together; notification acceptance acknowledges that exact result. Ordinary
messages to the helper do not judge its standing notification condition.

Use **Paused** to stop scheduled or event-driven work. **Run once** and
manual messages stay available. A helper with no schedule has nothing to pause.
A brief leaves permissions as set in Trust. Deleting a helper removes it from
listings and prevents new runs. An already running job can still save its result.

Scheduled and event-triggered helpers use **Trust → Features → Let me work
unattended**. Turn it off to stop unattended runs outside Full Mac. Full Mac
shows it as On under **Trust → Standing**. Choose a narrower standing to
change it. **Run once** remains available.

The helper's page shows run summaries; open chat for full replies and session
activity. Durations use the recorded seconds; invalid saved durations fail the
checked shelf read.

An indexed helper row opens its conversation with its own model choice. See
[Automated systems](AUTOMATED_SYSTEMS.md) for background ownership.

## Other agents

Open **Control → Connectors** or use `/agents` in Chat. Use **Look for
agents** to discover supported agents on this Mac. It can run a discovered
program's help or initialization. Open a contact and choose **Connect** when
offered. That opens a Mac conversation for the setup. You can open a
connected agent's conversation or use its **Message** field when offered.
In Simple, expand **Agents** to open a contact.

Review **Trust → Connected agents** to decide which contacts can act with your
authority on authenticated requests. See [Agent conversations](agent-communication.md).

### Codex and Claude Code as specialist builders

Connect the builder from **Connectors** after installing and signing in on
the Mac. In Chat, describe the requested outcome, name the repository and
tell your agent what would show the work is done.

The result returns to the originating conversation. A builder's reply is
evidence to assess, not proof of completion by itself. Check the resulting
files, receipts and any external service involved before claiming success.

### Lines of their own

Ask your agent to send a bounded piece of work to a line of its own. Each
line has a separate work conversation, outside the ordinary Chat list, and
uses the same tools, Trust and workspace gates. Your agent can give a line
instructions for a role such as researcher, critic or specialist. Several
lines can run at once. Check **Working** on Home and your agent's **Crews**
room. The answer returns as news to the conversation that started the work.

## Providers

Open **Control → Providers** to choose the account and model for **Chat**,
**Work** or **Mind**, add accounts, test a connection or refresh model lists.

### Chat, Work and Mind

Providers is one shared face: **Chat**, **Work**, **Mind**, **Accounts**, and **Catalog**.
Each group's **Model** offers an **Account · Model** choice from eligible accounts.
Choosing one uses that model's declared thinking default and turns Fast off;
then **Thinking** and **Fast** appear only where that model supports them.
The page's sentence names Chat's model and account and the groups that differ, each model by
its catalog name (its id only where the account's catalog has no row for it).
Work and Mind inherit Chat unless you turn **Same as Chat** off or choose their own model.
Turning **Same as Chat** on clears the group's overrides; turning it off pins Chat's
current model, account and controls. Unusable and retired saved picks stay visible with their cause.
Thinking and Fast can be set independently while the group keeps following Chat's
model and account.
Partial or conflicting saved group choices stop that group with the saved keys
and a repair instruction. Choose a complete group choice or turn **Same as Chat** on.
If saving fails after intent was recorded, the exact forward choice remains for
reconciliation; the error names committed, pending and unknown files. Previous
choices are not restored automatically.
**Personality → My minds** edits the same Memory and mind group for reflection
and their own hour, offered when you step away during your active hours and weighed by their attention.
Changing its model keeps the group's Think level. An
unsupported Think level or Fast choice is reported so you can choose a supported
control; the app does not silently change either setting.
Changing its provider leaves **Choose model** until you select a model.

### Add and test accounts

**Add key** or **Sign in** opens the account's advertised method. Onboarding
or an entry offering several methods asks you to choose. If the saved method
is no longer offered, select a current one before saving. Follow the
[account setup steps](GETTING_STARTED.md#set-up-your-names-and-connect-a-provider)
for each sign-in or key.

A valid CLI API-key file without a ChatGPT
access token offers no ChatGPT session to adopt. Credential files may be symlinks;
renewal updates their target and retains the link. A failed shared CLI inspection
after sign-out is reported separately from the completed app credential removal.
**Test the connection** checks saved ChatGPT, Anthropic direct and xAI sign-ins
through their native routes. Methods without a native probe explicitly say
they were not checked and leave the account's last check in place; the Codex
CLI account is checked by the calls it answers. A saved check belongs to the
credential actually sent;
an older or unbound check cannot verify a replacement sign-in. A malformed
sign-in or renewal response is reported before any credential update. ChatGPT,
Anthropic and xAI initial sign-ins require valid access and refresh tokens for
their ongoing sessions. Keyring sign-ins allow a sign-in without renewal when
the service provides no refresh token. Renewal keeps the saved refresh token
when the service omits or returns null for a replacement; a supplied empty or whitespace token is
malformed. Optional expiry and metadata follow the
[token-response contract](INTERNAL_WORKINGS.md#oauth-token-response-contract).
Malformed responses ask you to try again and leave the saved
grant unchanged. xAI save failures
retain the observed metadata and Keychain items for repair rather than restoring
earlier credentials.
A failed connection check shows its cause, including a failure before any request
could be sent. A successful check whose saved credential changed says it is not
verified and asks for another connection check.
Unreadable saved checks keep their bytes and report the damaged envelope or
provider row; checking another account cannot erase that evidence. Checks
without the exact credential fingerprint remain unverified. Anthropic setup
offers direct OAuth and API keys; the retired Claude MCP process panel is gone.
Accounts lists connected accounts first, one row each: the connection's authentication words,
its state, the day and time of its last check, and **Test the connection** and **Disconnect** actions.
A model call the provider answers is a check of the credential it sent, as **Test the connection** is:
it saves the same check, renewed at most once an hour while the account is in use, and a call the
provider refuses as unauthorized marks that credential rejected as a failed test would.
Accounts still waiting for a key or sign-in sit under one **Add a provider** row that says how many
are available and opens from its chevron. On the Mac, an unconnected account's **Add key** or **Sign in**
opens its protected entry directly, without filing a conversation or Inbox request.
The agent's Providers page lists models only for connected accounts.
Anthropic offers an API key and the same Claude sign-in/setup-token controls as onboarding;
ChatGPT, Codex and Grok offer their browser sign-in. A provider secret is entered only
in protected Mac entry, never on a card, face, in chat, on the phone or in Telegram.
If Providers cannot refresh after saving a Claude setup token, the open form
clears the saved entry if it still matches the submission. The message confirms
the save and explains why Providers could not refresh.
Codex's protected entry verifies its saved ChatGPT sign-in through ChatGPT's
native connection probe.
When the agent asks to connect a provider, its Inbox row has one **Enter on Mac** setup
action and says where to enter it on every door. It opens the same protected entry.
Opening or closing it settles nothing: the saved connection must reach verified **Ready**
status. Save alone leaves the request waiting; use **Test the connection** (or Anthropic's
**Test connection** / **Test Claude connection**) to verify it.
Repeated asks reuse the open request in that conversation; a new conversation supersedes
the provider's previous ask and its continuation. Unreadable requests retain a named repair,
with their identity unknown, while readable siblings proceed.
The Codex CLI offer keeps **Use it**, **Ignore**, and confirmed consent repair; until you answer it,
its row is marked as waiting on you.

A ChatGPT model-list request shared with another reader continues while that reader still needs it.
An unavailable account or catalog reports its cause on that account; other accounts remain usable.
The onboarding connection sheet and its sign-in controls remain available.
An open protected entry reads its saved account baseline from Providers after a
save. Submitted nonsecret fields are accepted separately, preserving edits made
while saving. If the committed account cannot be read back, the drafts remain
and the result names that read failure. Protected setup uses the same quiet form drawing as other pages. Key fields appear
only after window protection is acknowledged, and their bytes stay outside saved
drafts. **Test connection** checks the displayed key without saving it; changing
that input removes its result. Save compares the configuration drawn when editing began under its writer's lock;
a changed account, including a replacement key, refuses the save and keeps the entry. **Read account again**
refreshes that baseline while keeping edits. A save whose effect is unconfirmed
holds its form and offers **Read current state** to check the credential owner
without repeating the save or calling the provider. Closing entry clears the
temporary secret.

On the account's protected sign-in card, **Default model for Chat** shows
the account's live model list, shared with the Chat model picker. Choose a
model there to save that account and model as the Chat default immediately.
**Chat → Model** shows the same choice. If the list is empty, read the
account's status and use **Catalog → Models → Refresh**. Selecting a model
uses its default Think level and turns Fast off.

### Where the model list comes from

What an account offers you to choose from is what its provider listed, and nothing else
([model lists](INTERNAL_WORKINGS.md#model-lists)). Anthropic (API key and Claude sign-in),
OpenAI, xAI and Meta ask their provider for the list the saved key or sign-in may use; a model
NativeAgent does not know yet runs on the controls of its nearest known sibling, or on the
provider's defaults, and its row says so. A model whose context window neither NativeAgent nor
the provider states is not offered, and the account says how many were left out. A saved model
stays yours under whichever spelling the provider lists it, and runs under the spelling you chose
when the provider lists that one; a model listed under two spellings appears once, with your saved
spelling shown when it is the dated one. A failed refresh keeps the last full list and says when it was
fetched. When the account has no full list from its provider (not asked yet, it could not be
reached, an incomplete answer, or a Claude sign-in that is not allowed to list models), it offers
nothing to choose and says why, for example "No models to choose yet: Anthropic could not be
reached: … Refresh to try again." A model you already chose keeps running and keeps its Think and
Fast; it shows as "Saved. Anthropic has not listed it yet." Only choosing a different model waits
for the list. At launch, on entering Providers and on setup's "Read accounts again", NativeAgent
asks such an account, and one whose list is a day old, once and says "Asking Anthropic for its
models…" meanwhile. A model the
provider retired leaves once a complete list says so. A ChatGPT
sign-in adopted from the Codex command-line tool keeps that tool's list, and its refresh says to
sign in with ChatGPT in the app for a list the app can refresh. Kimi Code has no list to ask: the
models this build knows are its only list.
ChatGPT, Codex, Moonshot and OpenRouter use their own fetched model catalogs.
A missing or unreadable catalog leaves its account's list unavailable with its cause and a refresh
instruction. Credential-bound saved rows remain available until a successful refresh or credential change.
When settings are read, ChatGPT sign-ins made in the app ask again if the saved list is missing,
belongs to another account, or is a day old. **Refresh** asks for the full account list regardless of age.
A model newer than the app's checked ChatGPT wire can be selected with the Think levels the account lists.
Its first turn checks the wire. For image input, the route must carry images and the model must list
image input if it states which inputs it accepts. If ChatGPT refuses the full list, the app asks once more
for the checked version's list. Providers shows that version and the reason. When the refresh fails,
the previous list stays available. ChatGPT and Codex draw models, windows and Think levels from their account catalog.
ChatGPT and Codex read the catalog beside their selected sign-in; they do not
borrow the independent CLI's catalog. Provider configuration and picker files
use the current object fields and surface names only. API-key and xAI token
metadata use Keychain references; a credential read failure stays unavailable
and names the storage repair instead of claiming the account was signed out.
This includes an adopted Codex CLI credential: unreadable or malformed saved
credentials name their file and repair; only a confirmed missing file means sign in.
Fetched API-key model lists belong to the credential that fetched them; changing
the credential requires a matching refresh before those rows can be used.
New Kimi models from Moonshot use the Think levels of the nearest declared Moonshot
model in the same line and variant at or below their version. A model without a
matching contract says Think controls are unknown on its row and cannot be selected.
New models on a refreshed ChatGPT, Anthropic, OpenAI API, xAI, Meta or Moonshot list
become news the agent can notice once the same credential has an earlier list.

**Catalog → Models → Refresh** asks every connected account's provider again and shows whether the model lists are
fresh, cached, partial or unavailable, naming each list it could not fetch. Entering Providers asks connected
accounts whose current key or sign-in has no complete list from the last day. Saving a key or signing in asks at once,
and a connection check saves the list it fetched.
Connection checks and catalog refreshes show that they are running and publish their result when they end.
While a catalog refresh waits for a response or connectivity, its Models row offers **Cancel**.
Providers owns and joins that refresh task; cancelling releases the refresh slot so **Refresh** is available again.

OpenRouter's thinking choices come from its model metadata, including mandatory
reasoning and models with no effort selector. Provider default omits the optional
reasoning control; it does not guess an effort. Refresh Models reads that metadata;
helpers and saved choices use the same catalog.

Model controls read the selected account's catalog. OpenRouter's catalog carries
its per-model reasoning efforts and default from OpenRouter metadata, including
through the saved cache. Missing capability metadata offers no invented Think
levels. Helpers and phone edits use that same declaration; an unavailable
catalog on one account leaves other accounts' choices available. An unreadable
Trust policy is reported as unavailable before a Trust control is read.

### Meta Model API

**Meta** takes a pay-as-you-go Model API key from the
[Meta dashboard](https://dev.meta.ai/). In Providers, choose **Accounts → Add
a provider → Meta → Add key**. Paste the `LLM_` key into protected entry on
the Mac and click **Save**. Use **Test the connection**, then choose a model
from Meta's live list on the account card. The probe reads Meta's authenticated models
endpoint; it checks the key without generating an answer. The key stays in
this Mac's Keychain. The iPhone's Providers page and model picker use the
same Mac-owned catalog; protected key entry opens on the Mac.
Onboarding offers Meta through that same account setup.

A model request can return HTTP 403 when it refuses access to a model or
feature. Check that account's access in the provider dashboard. When billing
is missing or the provider reports a billing error, check allowance and billing
at Meta. Those refusals alone leave the key's authentication status open.

Meta's list for the key owns which Muse models appear. The models this build
knows are **Muse Wonder 1.0** (`muse-wonder-1.0`), **Muse Ember 1.0**
(`muse-ember-1.0`) and **Muse Spark 1.3, 1.2 and 1.1** (`muse-spark-1.3`,
`-1.2`, `-1.1`), each with a 1,048,576-token window, images, streaming and
native tools. They offer the Messages wire's Think **low, medium, high, xhigh**,
with high as NativeAgent's initial effort; Meta lists minimal through max for
Ember, of which this build maps those four.
Models on this account offer the listed Think levels. Fast is unavailable.
Stop uses the same request cancellation and settlement as the other providers.
Prompt caching is automatic; system cache markers use Meta's five-minute TTL.
Cache-read counts appear only when Meta reports them; an absent count is unknown.
See Meta's [Messages contract](https://dev.meta.ai/docs/protocols/messages)
and [cache-marker schema](https://dev.meta.ai/docs/api-reference/messages/schemas).

Only Standard models are offered. Contributor variants permit training use
and require a separate choice; Muse Wonder Full has no API. NativeAgent never
reads or uses a Muse Code subscription credential.

Standard pricing documented in November 2026 was $4 input / $0.20 cached /
$20 output per million tokens for Wonder, and $1.25 / $0.15 / $4.25 for Spark.
Check the current [Meta pricing](https://dev.meta.ai/docs/pricing-rate-limits).

## Trust modes and approvals

Open **Control → Trust** to choose a standing, review app **Read** and
**Write** switches, see your **macOS grants** and manage backups. Find
requests in Chat, Today or the Inbox.

Trust on the Mac is one face. It leads with one card, **What I may do**. Its
first row is the standing, the one real choice; what the standing reaches
(files, the backup before a file write, Mac control, and under Full Mac
unattended work) opens from that row. Then comes a row with a small lock for
each thing the agent must ask you about first at the saved settings, each
saying “I ask you first”, and last one folded row, “Nothing else asks you first”,
that opens to what the agent does without asking (“I don't ask first”) and, with
no lock, “Only you can do these”. The card says who decides, not whether a thing
can be done at all: an app's own Write switch and what the standing reaches say that.

| Kind of act | Safe | Work mode | Builder | Full Mac |
|---|---|---|---|---|
| Sending things to other people | Not available | Asks first | Asks first | On |
| Deleting for good | Not available | Asks first | Asks first | Asks first |
| Changing things on your side | Not available | Asks first | Asks first | On |
| Changing what is yours to decide | Not available | Asks first | Asks first | On |
| Working in my own space | On | On | On | On |
| Reading and looking things up | On | On | On | On |

Under Full Mac a lever a card can carry is theirs, unless an untrusted voice steers the turn.
Their ordinary class and reach apply, so destructive acts still ask. Below Full Mac it stays your card, and Safe refuses.
“Changing what is yours to decide” lists the levers a card can carry,
each by the name its action declares. Where the standing asks, it adds: “When you ask me for
one of these, I do it. When it's my own idea, I ask you first.” Your own ask
decides one of these as your tap and your card do: in a turn you started, at your
Mac, your paired phone or your own Telegram, every one of these the agent does
for it is made as yours, with no card and nothing to quote; any card still
waiting for that same change is withdrawn as decided by your ask, its receipt
carries your message, and the consent record keeps it. A turn another agent you
have not trusted steered asks you on a card instead; below Full Mac, so does one the agent started on its own thought.
Words from a tool result, a web page, a file,
another agent, a helper or the agent itself never count. Under Safe nothing asks,
so nothing runs on your word either. “Only you can do these” lists the levers
no card can carry: typing or reading a secret, matching a pairing code, choosing
in a system panel, words sent as yours, an
approval's own action opened on the Mac, recovering a damaged Trust policy, and
resetting who the agent is; the agent's call to one is refused, at every
standing, and your word cannot do it for you. Raising macOS's own permission
prompts is not among them: under the same lever law the agent puts them in
front of you, and you answer each one yourself. A lever added to the app appears
in one of them without touching the card.
Some things ask case by case, decided from the request itself rather than the
standing, so they carry no lock; the fold says so in one sentence: a request
from another device, chat or agent (who sent it, whether it is signed and
trusted, or an untrusted agent steering the turn); a change that widens the
agent's own limits (a setting raise, such as turning an app's Read or Write
switch on, or an allow-list addition), below Full Mac or under an untrusted voice unless you asked for it; and keeping an
ability, the turn program included (by where the ability came from, the
standing, and whether the person had turned it off).

Work mode and Builder are one posture to the law; they differ in what files
the agent can reach, not in what asks first. Under Safe the posture's kinds
are left out and sit in the fold as “Not available”, so the fold reads
“Everything else” rather than claiming everything is on. Under Full Mac a turn that an agent you have not trusted
steers is held to Work mode, as the standing's own row says. A switch that is
off (a Mac control category, an app's Write switch, a request's file access)
refuses instead of asking, whatever the card says about the kind. The agent
reads the same rows, the lock said in words. Every other block is one line until you open it: Features,
Chrome control, Mac access and control, Security, Connected agents, Apps and
features, macOS grants, Background watches, Activity capture and the Privacy
map. A block with something that needs you (a grant not yet given, a reading
that failed) stays open and comes first. Backups stays open, its restore
points under one row; the recent security log and the Mac control audit
come last, folded. The agent reads that same face as text; a folded block keeps
its rows that carry a control or an action, by name, state and call, and counts the
rest, and its item reads it whole. Every switch on it stays in the page's settings
list, by id, value and choices; its item reads its note. Each switch saves immediately; granting more access asks for
confirmation. Full Mac's effective permissions are distinguished from the saved
choices for narrower modes. The storage inventory shows when it was read;
Refresh reads it again.

Integration access values include only the axes that integration supports:
notifications and scheduler have Write only; Spotlight has Read only. The
same supported-axis value determines whether a proposed setting gains access.
The Chrome setting is the saved switch for narrower modes; under Full Mac,
its row shows effective access and names that saved choice separately.

Security shows whether remote command signing is required and whether verified
trusted origins have a signature waiver. Security log shows the recording
setting, the number of entries and any read or decoding failure. A damaged receipt
keeps its own named gap beside the readable receipts. Mac control audit reads
retained refusal receipts in the experience record; the Mac Control inventory
counts operation files, including their lock, rather than those receipts.
“If I get something wrong”, under the standing, is the file-write backup
policy; the Backups list holds separately created app-data restore points. An empty list does not change that
policy.

macOS privacy grants remain foreground decisions on the Mac. The face opens
the existing permission controls without requesting a grant. The freeform Mac
workbench and the app picker for activity exclusions also stay native. A
phone request for one of those controls explains that it needs the Mac.

| Preset | Access |
|---|---|
| **Safe** | Read files; change nothing on your side; no shell or git. |
| **Work mode** | Edit approved workspaces; ask before sends or changes on your side; Mac control, shell and git need Full Mac. |
| **Builder** | Edit workspaces and ask before writing elsewhere; Mac control, shell and git need Full Mac. |
| **Full Mac** | Files anywhere, shell, system control, move or trash; deleting a contact, event or reminder still asks you. |

Choosing Full Mac asks for confirmation. It stays on until the mode changes;
there is no timer. For admitted turns, Full Mac grants the agent autonomy
without routine per-action approval. Explicit blocks, origin checks, service
authentication and macOS permissions remain in force.

### App permissions and approvals

**Trust → Apps and features** has one row per integration with its supported
**Read** and **Write** switches. Write off means “look, don't act,” even
under Full Mac. It blocks clicks, typing, shortcuts, menu commands, drags,
Accessibility actions and modifying app events before approval and at
execution. The same switch applies to integration tools for mail, messages,
notes, contacts, calendar, reminders and music. The owner controls Write.
Looking, scrolling to read, waiting, zooming and opening the app remain
available. A held key chord during scrolling checks Write for the app
receiving the keys, including a named app brought forward for the act.
Modifier-only scrolling remains available. Read off blocks content tools
for that app, even under Full Mac. Screen and Accessibility reads follow
their own permissions.

Shell commands retain their ordinary Trust authority, so a Full Mac shell
can still run `osascript`. App-script actions check Write for their target.

Saved app permissions have one checked reader for both display and edits.
Each saved integration entry must contain every axis it supports; changing
one axis preserves the other. Missing integrations use the shipped defaults.
Unreadable or incomplete saved authority is reported as unavailable with its
repair direction, and its bytes remain untouched; it is never presented as
an owner choice to turn access off.

**Resetting macOS privacy permissions always asks the owner first**, including
under Full Mac.

**Agents enabled in Trust → Connected agents carry the owner's authority on
authenticated turns.** They do not receive extra peer approval requirements;
ordinary Trust, domain, service and macOS permission checks still apply.

**Just this** runs one call. **For this task** also elevates the card's peers
while the same request is live and has taken no new arrivals. A resumed run
asks again for any additional authority it needs.
Approve alone means Just this. Ordinary Trust still applies. Reading an
untrusted agent's job report adds that agent to the current request's steering
sources. Protected actions then account for every agent whose job report they read.

Resolve requested approvals in Today. An approval authorizes a step; the
action's receipt and the service that owns the effect establish what actually
happened. Chat receipts show the outcome, with evidence under **Details**.
Chat approval buttons and recipient scope come from the filed action and its
arguments. **Not now** declines that request; it promises neither a saved draft
nor that unrelated work has stopped. Missing approval records remain unavailable.

### Turn on Mac computer control and the activity watcher

For clicks and typing, check **Trust → Mac access and control**. Under
**Trust → macOS grants**, give **Accessibility** to let the agent read or
use controls, and **Screen Recording** to let it see the window as an
image. The current standing, feature switches, window evidence and macOS
grants determine which actions can run. Check the result in the affected
app after input. See [Getting started](GETTING_STARTED.md#grant-macos-access-when-you-need-it)
for the other macOS grants.

When work encounters a missing macOS grant, its permission remedy puts the
permission card up automatically. An existing open card for that capability
is reused, and access already allowed needs no card. Tap **Allow** on the Mac
to open the system prompt or Settings pane; the agent's call itself never
opens a system prompt. The result keeps the blocked work's actual outcome
and tells the agent which card is up for you.
One tap walks every grant on the card: first macOS asks in place for each one it
can, then the panes open one at a time for the grants only System Settings turns
on (or that you declined). Coming back to NativeAgent's window goes on to the
next pane. The card keeps a **Continue** button until every grant is on or you
choose Not now; at the end it offers one restart, for grants that take effect at
launch, beside **Go through again**. Trust's "Ask for every prompt not yet
answered" walks the same card. No grant is requested while NativeAgent's window
is not in front.
Settings reports unresolved acquisition as a failure.

Taking control returns the stopped action's refusal to the agent immediately,
so they can answer and decide what to do next. It does not park their turn until
you hand back. Under Full Mac their next action can reacquire control; otherwise
use the composer's **Let [agent name] use the Mac** control. Shotgun **Resume**
hands back and asks their to continue from the recorded results in that same
conversation, through its normal Send/queue path, even if their turn has ended.
A timed-out Mac call says completion is unverified and earlier effects may have
landed; inspect the affected app before another action.

The Mac control badge and selected preset show effective Trust authority.
Category switches enable actions; your access mode decides when I ask.
While Full Mac is active, Advanced switches edit saved restricted-mode settings;
they do not turn Full Mac off. Change the access mode to leave Full Mac.
If a permission button cannot open System Settings, the Mac control pane shows
the handoff failure. Permission cards and Settings also retain authorization
request errors with the privacy pane to use next. Bluetooth awaits macOS's
authorization event or cancellation and then releases its manager. An unanswered
prompt remains waiting; silence declares neither access granted nor denied.
When requesting several permissions, an individual request error is retained
while unrelated permissions continue. The final error names each failed
request and its remedy. Cancellation or a failure to activate NativeAgent
stops the remaining requests.
The iPhone notification setup button follows the readiness item's identity and
status, so changing recovery wording does not remove the route.

Chrome uses the optional bundled extension. Open setup from **Trust →
Chrome control** and follow the [extension guide](../Extensions/NativeAgentChrome/README.md).
In Advanced Chat, **Work → Screen** shows the tab's site, title and activity.
A background read previews the first screenful of its text and structure.
The tab renders for your agent while it works, so Chrome can show a debugging
bar until a minute after the last act. Cancel that bar to stop the attachment.
Text and images replace each other in the preview. A read with no available
content clears the old preview and explains why, and a closed tab shows its
close result. Preview images mask secure fields, stay in memory and stay on
the Mac. If the app cannot establish safe masking geometry, Screen shows a
caption only. See the [Screen preview contract](../Extensions/NativeAgentChrome/protocol/PROTOCOL.md#local-screen-preview).

Under **Trust → Activity capture**, choose **Record which apps you use**.
Recording is off by default. It records app names and durations;
redacted window titles require separate opt-in. It does not record screenshots
or typed content. Full Mac permits recorded-activity answers in trusted chats;
narrower modes require **Let me answer from activity history**. Answers reach
the selected provider.

Unreadable saved activity policy pauses recording and settings changes while
preserving the last checked choices separately from policy availability.
**Delete all recorded activity** remains available, with confirmation, even
while the policy is unreadable; deleting history does not require that policy.
Settings shows the unavailable policy, and agent settings reads return its
failure. Only a genuinely missing policy uses fresh-install defaults.

## Settings

Open **Control → Settings** or press Command-comma. On iPhone, **Control**
includes this device's controls and the Mac settings available to the paired
phone. For each setting and its click path and for the page map, see
[SETTINGS.md](SETTINGS.md) and [WHERE_THINGS_ARE.md](WHERE_THINGS_ARE.md).

Ask your agent in plain words to change a setting. For example, try “use
the dark appearance,” “change the Shotgun shortcut,” “turn on meaning-based
memory” or “make my iPhone appearance light.” Use **Providers** for
provider defaults and protected sign-in. Enter Telegram credentials through
**Connectors** on the Mac. An account offers only the key or sign-in methods
it supports.

The Mac Settings page, its setup sheets and the agent's page reading now share
one face built from that registry. **Preferences** is a few groups, each one
row that opens from its chevron and says its state in a few words ("All on",
"2 of 5 on", a choice's selection): **Where I reach you**, **What I can read**,
**Memory**, **Inner life**, **How I look**, **Shortcuts**, **Other** (any setting
no group names) and, last, **Advanced** with Reflections
in 24 hours and the search service. A group with a setting that cannot be read
is marked failed, so a closed group never hides it. Switches and choices save through the same
setting owner as `setting.set`; an unreadable row keeps its cause while the
other controls remain available. Notifications and Right now follow; **Updates
and help** (update checks, data limits, build identity and app status) is
folded until opened, unless one of its rows needs attention or failed. The
tour switch is under **Other**. **Reflections in 24 hours** opens Cognition's
shared number control. Allow zero to eight waking reflections per rolling
24-hour window. A positive limit exempts dream reflection. Zero turns all
reflection off. Changing meaning-based memory asks you before rebuilding the
index.

Settings' Mac access summary and Trust's app switches read the checked permission
store directly. Reading those rows does not probe macOS grants or refresh Mac watches;
grant badges and watch readiness remain with their own permission and watch owners.
Returning from another app to NativeAgent's body or window, or explicitly refreshing
Trust, reads the grant owner's nonprompting probes once off the main actor and
publishes through its checked snapshot. The pass covers per-app Automation, Speech
Recognition, Microphone, Calendar, Reminders, Contacts, Accessibility, Screen Recording
and Full Disk Access. It starts no timer or watch refresh. Trust's Refresh also reads
the privacy inventory again. Screen Recording and Input Monitoring reach the app only
at launch, so one switched on later reads off inside it: a fresh process of the app
reads them as the next launch will, and every place that shows them says "Granted,
takes effect after one restart".

If a setting's owner cannot be read, that setting reports the cause and
repair. Other readable settings remain available. A connected provider has
a default-model setting. A disconnected or broken account shows its status,
catalog note and repair in **Providers → Accounts**. An unreadable provider
or embedding configuration reports its failure. Only genuinely unset
preferences use their owner's shipped defaults.

Missing Telegram configuration is unavailable, rather than an off switch or
empty allowlist. Trust-backed memory and dream controls require a loaded
policy on every page. Settings keeps Trust's load failure and points to Trust
for repair. A missing or failed personality profile likewise makes the name
unavailable for both reading and changing, including a retained profile after
a failed reload; the failure keeps its cause. Preset readback uses the same
complete policy matcher as the Trust picker, including effective access mode.

Unsupported saved view, context mode, Shotgun shortcut and haze choices require
an explicit replacement. An invalid shortcut is not registered, and an invalid
haze does not select a default hue. An invalid saved context mode stays
unavailable: context startup and replies report the error, and enabling Inner
Life preserves it. Only an absent context mode uses the initial Active choice;
choose Off or Active explicitly to replace an invalid value.

### Settings on your phone

Open NativeAgent on the paired phone to read or change phone-local preferences.
On a paired phone, appearance, haze, Live Activities, senses and saved-place
switches use the phone's own settings. A request to enable sharing or work
Live Activities asks on the phone, and iOS permission prompts still need
your answer. If the Mac stops waiting for the result, read the current setting
before repeating a change. Saved-place names and switches, including disabled
ones, can be read with permission. Coordinates stay on the phone. Use
**iPhone Control → Places** to save the current location or delete a place.
Pairing and connection repair have their own device setup controls.

Your approval grants access when a Trust raise, an app Write switch, a macOS
grant or admission to Full Mac asks for it. Ask your agent to help you find
the control. Lowering access follows the standing's rules.

### Optional background and memory settings

In **Settings**, **An inner life** controls the inner-life master setting,
and **Memory in every reply** selects Active or Off for Fluid Context.
The memory controls also cover dreams and meaning-based recall.
Use **Diagnostics → Cognition** to inspect the current state.
Cognition's reading, evidence and controls use the shared page renderer. The
resident mind owns Think now, Reflect, Clear thinking, Settle body and Reset
body; a pending command keeps its own outcome when the page closes. A partial
save keeps its cause and known effects beside the command. **Include
workspace** controls whether the workspace contributes to the mind's
reading. Context health keeps its own reading.
Long evidence opens in a held document with selection and Copy. The native
list keeps the full row count available to VoiceOver as collections grow.

If the requested semantic model cannot load, Settings reports semantic recall
as unavailable with the embedding owner's cause and Doctor remedy. It does
not promise a word-search replacement for failed semantic recall.

Remembered context and inner state do not grant action authority. Trust remains
the owner of permissions.

While a tint-enabled window is visible, mood input follows cognition changes.
The room keeps its four-hour damping. Five-minute display steps advance that
damping without rereading cognition. The display timer parks when the level
equals its target, and unchanged levels are neither published nor saved.
Cognition observation stays armed to restart movement. Hiding the last consumer
stops both.

## iPhone and iPad

### Pair with your Mac

You need iOS or iPadOS 26 or newer and a Mac build that supports iCloud pairing.
Install NativeAgent from the App Store on your phone or iPad. Use the same
Apple Account with iCloud enabled on both devices. Keep the Mac awake with
NativeAgent open.

1. On the Mac, open **Control → Connectors → iPhone**.
2. On the phone, open NativeAgent and choose **Pair with Mac**. Tap **Check
   for Mac** if the details haven't arrived. Tap **Connect** when available.
3. Match both four-character groups under **This phone's code** to the **Code**
   on the waiting device on the Mac, then click **Pair** on that row.
4. Keep both apps open for the Mac's confirmation. If the phone asks you to
   connect again, tap **Connect**.

If the phone can't find the Mac, read **Connection** on the Mac's iPhone
page. Fix the iCloud or Keychain problem it shows, use **Check iCloud
delivery** on the Mac, then **Check for Mac** on the phone.

### Use the companion

The phone reaches the same Mac runtime through signed iCloud transport.
Its tabs are **Together**, **Table**, your agent's name (**Agent** before
naming), and **Control**.

- **Together** sends messages and reads replies. Agent snippets open their
  conversations. Use another app's Share menu to send a photo or file into
  Chat. See [Sharing from iPhone](ios-sharing.md).
- **Table** opens the synced work board and gives access to **Helpers**. Drag
  elements with touch or Pencil, use a selected card's corners to resize it,
  and use the Table tools to add a note or ink, cross off, or remove an element.
  **Today** shows the Mac's posted timeline and what's ahead. Open a waiting
  request to see its details. Use **Approvals and past decisions** and
  **Every note I've left you** for the Inbox. Open waiting memory proposals
  for review. Pending matters can add a badge to Table.
- The named agent tab holds **Home**, **Memories**, **Knowledge Graph**,
  **Personality**, **Dreams**, **Capabilities**, and published pages received
  from the Mac.
- **Control** includes **Trust**, **Providers**, **Connectors**, phone settings,
  the Mac connection, and shared Mac settings. **Advanced** follows the paired
  Mac's layout and keeps its Rooms, Setup, and Power user sections. **Power user**
  includes **Turn Inspector**, **Mac Tools**, and **Diagnostics**. Mac Tools can
  run specific actions on the Mac when Trust allows them.

Your Mac runs the model and tools. If it is asleep, offline or NativeAgent is
closed, requests can wait until it returns. Enter provider keys and answer
Mac privacy prompts on the Mac. Your agent can ask you to share your location,
choose a photo or take one while the phone app is active. Shortcuts offers
**Ask**, **Remember**, **Approve**, **Status**, **Quick Ask** and **Talk**.
See [Mobile companion](mobile_companion.md), [Siri actions](siri-notification-actions.md#iphone-and-ipad)
and [iPhone approval pairing](ios-device-pairing.md).

### Notifications

Allow notifications when iOS asks after pairing. If you declined, turn them
on for NativeAgent in iOS Settings. The Mac sends alerts for approvals, inbox
items and Desk work. Tap an alert to open its request or conversation.
Mac quiet hours and phone Focus can affect when alerts appear. If an expected
alert is missing, open **Control → Advanced → Power user → Diagnostics → Recent pushes**.

### Talk and share senses

For a hands-free conversation on iPhone, tap the phone button next to the mic,
use **Talk to <agent name>** from Siri/Shortcuts or the Action Button, or use the
Talk Control in Control Center. The [Talk mode endpoint contract](mobile_companion.md#talk-mode)
describes when spoken words are sent. Hear each reply sentence as it arrives in
the Mac's chosen Apple voice. Start speaking to interrupt.
The call shows live captions, mute and end; its Live Activity keeps those controls
nearby when you leave the app or lock the phone. End returns to the same chat with
your messages already there. Quiet mode uses captions. On-device speech support
and the named Apple voice must be available on the phone; setup problems are
shown directly. See [Talk mode](mobile_companion.md#talk-mode).

In phone **Control → Places** and **Phone senses**, enable only the evidence
you want to share. Every switch explains its summary and its use by the Mac's
selected AI provider. Ask your agent to guide setup. The guide can show
the last reported switches, iOS permissions and missing steps, including
**no place added yet**. Silent or
stale senses do not establish your whereabouts. See
[phone senses and their limits](mobile_companion.md#where-the-person-is).

## Telegram, Slack, and local bridges

On the Mac, open **Control → Connectors** or type `/connect` in Chat.
Each service keeps its conversation origin and uses the Mac's engine, context,
provider choices and action policy. Use protected Mac entry for credentials.

- **Telegram.** Open **Telegram → Bot token** and choose **Enter bot token**.
  Use the protected entry. With Telegram off, send your bot a message and
  click **Check sender** to find your chat ID. Review **Allowed chat IDs** and
  **Allowed user IDs**, then turn Telegram on.
- **Slack.** Open **Slack → Connect** or type `/connect slack`. Enter **Bot
  token** and **App token** in protected setup. Enter at least one allowed
  channel or user ID. Use **Only answer channel messages when @mentioned** to
  require a mention in channels. Direct messages need no mention. Click
  **Save**. Slack connects through Socket Mode.

Once Slack setup commits, its save settles the worker replacement and connector
refresh even if the setup sheet is dismissed. Cancellation suppresses later
wizard updates without skipping reconciliation of the saved configuration.
If the connector refresh fails while setup remains open, the form clears the
saved token entries that still match the submission and shows the refresh failure.

Telegram's **Check sender** reports the sanitized configuration or transport
failure returned by its owner, so a failure is not always described as a bad token.
Bot API requests use Telegram's HTTPS endpoint; environment variables cannot redirect the bot credential to a local listener.
In an allowlisted Telegram group, messages remain admitted, but turn controls and
acting bot commands require the sender's user id on the user allowlist. A refused
control answers that it belongs to the owner. Admitted private chats retain control
when the chat id equals the sender's user id. Help, conversation lists and the
provider, brain, tools and argument-free persona readouts remain available to
admitted group members.

Disconnect preserves the checked allowlists, mention and voice settings even if
the saved Keychain credential is unavailable. Status reports that credential
cause separately from readable settings; a routing failure is unavailable rather
than an inferred Chat default. `/restart` requires the configured single owner's
authenticated private-chat sender. Image-only answers use the same durable
delivery journal as prose; failure notices are retained there too, and an unknown
send requires explicit `/retry resend` consent before another send. A turn that
reads an arrival, or ends silently, completes without a post; Telegram records
that no independent answer is owed so the claim follows ordinary retention,
including when delivery had reserved a preview before the turn chose silence.
Telegram OGG/Opus voice notes are decoded by the Mac's own audio reader, with
nothing to install (this replaces the ffmpeg conversion). A format the Mac cannot
read, WebM audio included, is refused by name. Apple Speech requires on-device
recognition; an unsupported locale reports its cause without sending audio to Apple.
Already-readable system audio goes
directly to recognition; unsupported declared formats report their cause.
Its model controls require the configured single owner's verified sender and
use the same `provider.choose` call as Providers for the Chat group. Model picks
use the selected model's declared thinking default and turn Fast off; Think and
Fast change only their own controls. Other allowed group members cannot change
these shared choices. `/remember` and `/note` preserve those senders' principals
and telling; only the owner speaks as the person. Missing sender or unreadable
configuration refuses these model and memory writes.
If Telegram cannot update the menu after saving a model, the callback reports
the saved selection and the menu failure.
The controls use the selected provider's catalog; unavailable capabilities
stay unavailable. OpenRouter's model metadata owns its supported Think levels
for pickers, saved selections and helpers; unavailable metadata requires
a catalog refresh. Each provider's catalog failure remains on that provider's
row and does not remove healthy providers. An unreadable Trust policy reports
unavailable when authorizing remote Mac work; it is never
described as a disabled setting. A queue-card removal failure is reported without editing the card
through a second operation. Slack receives through Socket Mode only and reports
socket failure without switching to history polling.

Slack file downloads attach the bot token only to HTTPS addresses on
`files.slack.com` or its subdomains, without embedded credentials or a
nonstandard port. Other addresses produce an `attachment_untrusted_url`
notice asking for a direct Slack upload. File uploads require an upload URL and
file ID before sending bytes, use the same address rule, and confirm only after
Slack accepts completion.

Readable captions, text and successfully downloaded attachments reach the turn
even when another attachment fails; a named missing-media fact accompanies them.
Telegram's first delivery and `/retry` use the same media preparation, including
that caption and missing-media fact when the attachment cannot be read.
To run a message again with `/retry`, stay in the conversation that received it.
An attachment-only failure reports the unavailable media explicitly.

Slack `/retry resend` continues the saved
answer after its confirmed text and images. Confirmed files need no local copy
for the remaining images to send. Its journal retains turns completed without
a post. A truncation warning means complete delivery is unverified.
Saved replies still need the current Slack workspace and allowlists to
permit their destination. A Slack settings save restarts the socket worker
immediately, while accepted message handlers keep running under the journal.

Telegram notification failures after an accepted part and Slack's potentially
partially successful API failures remain uncertain, so they cannot automatically
replay the whole notification.

Read [Agent conversations](agent-communication.md) to connect another local
agent through the bridge.

## Health and troubleshooting

Choose **Advanced → Diagnostics**. It has three tabs, in the order set by
your layout.

- **Diagnostics** shows Doctor checks, living status, this Mac, background work,
  recent activity and run history.
- **Cognition** shows inner-life readings and evidence, with controls such as
  **Think now**, **Reflect**, **Clear thinking**, **Settle body** and **Reset body**.
- **Chat turn details** opens the turn Inspector. Use **Replay** to read a
  dated trace, follow calls, or open the evidence for a step.

For skills and tools, open [Capabilities](#capabilities) or type `/tools` in Chat.

Use **Run checks**, **Repair safe issues** or **Support report** from the
health row in **Diagnostics → Diagnostics**. Findings that need attention
come first. Healthy check groups and healthy background work fold under
**Nothing else needs attention**, with a count. A running check shows when
it started. A failed read puts its availability notice beside any retained
reading. A repair requested during an active repair reports that it could
not run. Each attempted repair's report carries its result and rechecked
status. The report is the repair receipt.

Diagnostics shows the newest eight activity events and fifteen runs. Open a
run for its full prompt, output and saved facts. Use **Today** for approvals
and work waiting on you, and **Settings** for updates.

Diagnostics shows the conversation count only after a successful index read;
until then Sessions says **Being read**, or **Unavailable** with the read's cause.
Index publication refreshes that row. Telegram health checks open **Connectors**.

In **Diagnostics → Chat turn details → Replay**, a failed date read ends
loading and shows its cause. Any earlier cards remain labeled with the date
they actually came from. The Mac's Inspector uses the shared rows for its
mode, date and bounded event collections. Each turn leads with one row: when
it started, its whole time and call count, and its slowest call. Each call is
one row in the step box's words, with the engine's name beside it and its
duration; its start and end are in its expansion. A call's bar shows how long it ran and where in the turn it ran. Expanding an event opens its
selectable document with Find and Copy; its live trace subscription stays
with the Inspector owner.

For first-run help, see [If something doesn't work](GETTING_STARTED.md#if-something-doesnt-work).

For installation, permissions, provider and data-removal help, see
[Support](../SUPPORT.md). Keep credentials, pairing keys and private content
out of public reports.

Provider requests and configured services can send selected data off the Mac.
A capability needs the relevant permissions and a working connection. See
[Privacy](../PRIVACY.md), [Security](../SECURITY.md), the [capability map](CAPABILITIES.md)
and [Project Status](../PROJECT_STATUS.md).

## For your agent and for builders

### Use the app door

NativeAgent is the agent's one always-on door, `app`. A normal page read or
setting change runs in process without bringing the window forward. Actions
that move the screen or make sound are marked `screen`.

| Call | Meaning |
|---|---|
| `app {}` | Home: where I left off, open work, what waits and what arrived, followed by the page index. |
| `app {"page":"desk"}` | Read a page, its version and available actions. |
| `app {"item":"…"}` | Open or act on an exact name or reference returned by home. |
| `app {"find":"disconnect telegram"}` | Find matching pages and actions by intent. |
| `app {"action":"find","args":{"query":"disconnect telegram"}}` | The same discovery; `what` also names the query. |
| `app {"action":"…","args":{…}}` | Run an advertised action with its named arguments. |
| `app {"script":"return app.read('desk');"}` | Run bounded JavaScriptCore code using the app API. |

Home items can perform actions; follow the item's returned instructions.

The agent can read their own record with
`app {action:"record.read", args:{of:"experiences", id_prefix:"happening:person."}}`,
or attention details with `args:{of:"details", source:"attention"}`. Filters,
whole JSON rows and explicit page counts are described in
[Reading their own record](EXPERIENCE.md#reading-their-own-record). The read leaves
experience and obligations as they were.

Discovery ranks the registry's action descriptions and schemas with semantic
and lexical evidence; an exact action ID takes priority. A named page or Mac
integration puts its own actions next, in page order, and its page first in
the matching pages, using registered page IDs, titles, door aliases and
integration IDs (see [discovery](ONE_DOOR.md)).
For example, `find:"Notes actions"` starts with Notes' search, create, update
and delete actions. The remaining matches keep their semantic and lexical
ranking; there are no feature-specific keyword routes.
For an action, `preview:true` reports what it would do without doing it.
`expected_version` refuses the action if the current page version differs
from the read.

Scripts can use `app.read`, `app.find`, `app.log` and the registry's
actions, such as `app.inbox.archive(args)`. They have no direct file or
network access. Each call is checked separately. A call that raises a card
waits for your answer. A blocked action stops the script unless the script
catches it and goes on; earlier completed calls stay done.

Page reads are available in Safe. Ordinary setting changes require Work mode,
Builder or Full Mac. The returned page states which controls the agent may
change. Selecting Full Mac and granting macOS privacy access remain owner
decisions. See [Trust modes and approvals](#trust-modes-and-approvals).

Everything the agent calls goes through `app`. Pages and `find` expose
actions when needed, without adding more tool schemas to each request.
The old catalog, loading and per-area tool calls are refused with a translated
`app` call. Home and the glance name items opened with `app {item:"<name>"}`.

1. Start at `app {}` when resuming work; use returned names and references.
2. Call an action you know; the door returns its schema for a missing or invalid argument.
   Read pages or use `find` to discover actions; an exact action ID returns its
   arguments. Do not load tools or crawl private registries.
3. Use `memory.commit` for durable facts and `ability.read` for relevant
   procedures. Expand only the context pointers offered for the current turn.
4. Put work products in the canonical workspace and durable work on Desk.
5. Follow the originating session's Trust, approval and service checks.
6. Verify the outcome through the owner of the effect; do not equate a queued
   request, approval click or protocol response with completion.

For complete argument forms, authority and receipts, see [One door, every action](ONE_DOOR.md#one-door-every-action),
[Scripts](ONE_DOOR.md#scripts) and [Authority and receipts](ONE_DOOR.md#authority-and-receipts).

### Read and show pages

`page.show` accepts a page or a place by the word in the rail, such as
Control or your agent's current name. A place resolves to its initial page.
`page.show`, menus, links and search select the page's tab. The receipt's
`showing_page` names the resolved page. Its `showing` field reads the page as
`app {page}` does, including the title, an “Open now” line for an open item,
and the rows. It cuts at 4,000 characters and adds a “+N more characters”
line. A read failure appears beside the confirmed presentation.

Startup restores the current page and tab directly and leaves the retired
Skills & Tools scene section out of that restore.

The main window's frame keeper restores its saved placement, zoom and full screen.
SwiftUI scene restoration is disabled so it does not restore a separate placement.

Saved search inputs refresh on demand through the transcript owner; no separate
saved-search watcher or shell-specific trailing-failure verdict runs.

The `simple_settings_menu` page screenshot draws the Simple shell on Control's
Settings tab, where Simple's settings live, without changing the active selection.
Rail screenshots derive their tab selection without changing remembered tabs;
an unavailable saved tab stays selected with an explanation until you choose a visible tab.
Screenshot height rejects nonfinite or invalid input before rendering. Status
uptime and contact elapsed time say unavailable when their values cannot be
represented; an invalid toast duration leaves a visible auto-dismiss error.

An explicit `page.show` or a notification pointing to a page opens it in
place in Simple and Advanced. From Agent view it opens in Advanced. Ordinary
chat entry through the global hotkey or a message notification keeps the
person's saved view.

Opening Today displays the latest posted data. An explicit Activity refresh
reads approvals, inbox items and memory proposals, then publishes work status.

Duplicate launches use macOS's activation result. If the
resident exits during activation and no other instance remains, the new launch
continues; a refused activation reports the live process identities.
Quiet Today reads and offscreen Trust rendering do not publish work
notifications or synchronize preferences. Today reads use the existing
projection without refreshing live approval/inbox owners. Trust policy reads
do not run the effects reserved for committed policy changes, even when the
visible Trust page is also open.
Backup and restore replies carry the command's own result, independently of
the app's activity status line.

The Inbox face reads the in-memory experience owner and updates from that
owner's change stream, including while no view is open. Interaction choices
and **Not now** resolve the original transcript's card; **Open request** opens
that conversation for setup controls. Provider requests instead offer **Enter on Mac**
and open protected entry directly; they collect no secret on their row. A lookup or write failure
shows the owner's cause. `interaction_session_id` identifies the origin;
`chat_session_id` identifies its separate mirror destination.
The agent's row actions retain the existing Inbox tool checks and invoking turn;
archive, dismiss and mark-read still require a reason. Paired-phone approval
decisions from the Inbox face carry the verified paired device from the sync
router, resolving with signed iOS provenance just as signed approval cards do;
when verified device identity is absent, the approval is refused and no
identity is synthesized.

The agent's own Home look keeps the CHANGED comparison, presence and current Mac front/session state,
this conversation's windows and browser tabs, and the two-minute SAME
collapse. CHANGED tells each change that needs their on its own line, newest
first (five at most, then how many more and, when they fit, the rooms to read
them in), and counts the rest in one line per room, such as `desk: 9 done,
2 new`, or by the room's total when those counts do not fit; their own queue
steps are not news to them, and a step the person closes from Home or the Desk
is. A change is only what its line tells: a contact's reply is news once, and
a record rewritten with nothing new is no change. Their look acknowledges every change it told,
shown or counted, except one drawn from a source it could not read; a change
that needs their and was only counted stays news. The turn glance tells changes
the same way, three at most, and acknowledges nothing. An unread or unavailable
source leaves its own section incomplete.

The shared visual and text renderers read the same posted `today-readout`
face on the Mac and through `app {page:"today"}`. A burst of source changes is
read from the latest state after the current read finishes. The Inbox is
also available through `app {page:"inbox"}`.

Desk reads from the agent's door use the same face as the current Mac and
phone. Companion versions before the shared renderer had their own reading.

In Connectors, reading a listed row by its exact ID, including a nested row,
returns its current status and controls. The phone sense guide and agent
threads open their own documents. The face reports a missing row, a failed
section or an unavailable reading with its own status.

Panel refresh notices publish through a per-panel `LatestRead`: an older read
cannot clear a newer completed read's failure, and a canceled read publishes
no freshness or status claim. Each caller still receives its own read outcome.
Throwing panel and sidebar endpoint reads retain their redacted failure cause
beside the endpoint name in that receipt; other endpoints finish independently.

Privacy inventory names incomplete file counts and sizes when access fails.
Evidence readers refuse malformed JSONL rather than presenting a shorter clean
history; callers that deliberately show partial history retain its integrity
receipt. Appending refuses an unreadable existing tail. Feed health reports a
failed size read as unavailable, while a proven absent feed starts at zero.
JSON values receive a digest only after checked serialization; invalid values
cannot identify recipes, layout versions, strict read receipts or watch rows.

### Settings and permission readings

Read `setting.get` for the setting's current value, kind and accepted choices.
Use `setting.set` to change it, quoting the person's request in `because`.
This includes text and numeric values. `app {page:"settings"}` lists the Mac
controls and `providers` lists provider defaults. A read of
`providers.credentials` or `telegram.credentials` returns the protected
entry's location.

An invalid `NATIVE_AGENT_CONTEXT_FLOW_MODE` override reports its error.
In Cognition, **Include workspace** has the same owner as
`mind.workspace {value:true|false}`. Reading Context health leaves the
Cognition detail reading to its own owner.

For local read-aloud, `chat.voice_name` takes an installed Apple voice
identifier. An empty value uses the system default. Mac cloud playback
reads its route, Trust flag and credentials from the requesting engine's data
root. Its owner records playback or decode failure and clears active speech
ownership on completion.

Connectors, Settings and Trust read their independent sections concurrently
and assemble them in page order once their owners return.

To inspect remote settings, use `setting.get` with `setting:"phone.settings"`,
then use the returned IDs with `setting.get` or `setting.set`. All requests to the
phone, including reads, require **Trust → Apps and features → iPhone
Notifications → Write**, even under Full Mac. Exactly one paired phone is
required. The phone awaits its owner or action result with cancellation.
Wire expiry leaves the execution decision to the request owner. The enclosing
Mac deadline can leave the outcome unconfirmed. Read before repeating a change.

Trust's locks come from `PermissionLaw.verdict` and the action's declared
approval controls. In text reads, a folded Trust block keeps its controls by
name, state and call and counts the other rows. Read the block item for the
full list. Switches keep their ID, value and choices in the settings list.

`app {page:"pairing",item:"phone-senses"}` reads the phone sense guide with
the last reported switch states, permissions and missing steps.

Background watch recipes use the access reading for their scheduled source
action. Checked integration switches, Mail's account coverage and Calendar's
and Reminders' EventKit grants determine both the recipe and its access row;
a separate Mac-control probe does not determine those reads. A recipe with no
recognized source action says readiness is unavailable and explains why. A failed refresh labels
the retained reading with its cause. Reading these recipes creates no schedules.

App-script calls must declare `bundle_id`; their script body is confined to
that app and each modifying event checks Write. GUI scripting through System
Events is refused when its affected app cannot be established; use native
hands on the observed app.

### Mac control and Accessibility

The agent reaches the Mac through `app` actions such as `mac.look`,
`mac.act`, `mac.go` and `mac.wait`. Available evidence and permissions
determine what it can do; a successful input is not by itself proof of the
intended result.

`mac.act` can run up to 12 ordered `steps`. Name and point steps can carry
`holding` (keys/modifiers held around physical input) and `button`
(`auto`, `left`, or `right`), including points addressed with `at`/`from`
and `frame_id`/`image`. These use the same gesture checks as a single act:
explicit mouse buttons require a click, open, drag or pointer hold. Real input
requires the app in front. When an act temporarily brings another app forward,
the receipt names the previous app and says whether restoration was requested.
The request returns before macOS confirms the foreground change. A batch without `app` binds to the process in
front when it starts. During a pending takeover, it binds to the app captured
when the request arrived. The process can change windows between steps. A
failed step stops the batch. Optional targets and retries retain the gesture
options. The app and every step field are part of the receipt identity for
continuing a stopped batch. A resumed
batch keeps matching landed steps and steps whose input may have reached the
app, and reports how many of the kept steps were unverified. A refusal that
confirmed no input was sent leaves the step eligible to run on resume.

Steps also accept `{verb,handle,frame_id}` (the frame may be inherited from
the call). Each step resolves that recorded control identity in the live
window; a missing, changed, expired or ambiguous identity stops at that step.
Each step's effect is judged against its own fresh before-read; a
declared-effect mismatch stops later steps.
An explicit `app` also constrains a single exact selection to that app.
Editing a field's contents preserves its handle when the control identity is
unchanged. Handles grant no authority.
A scroll by handle or by name can specify `direction` and `scroll_amount`
in a single act or a step. A handle step can use `to` as an alias for
`direction`. A step with `verb:"scroll", direction:"up", scroll_amount:3`
scrolls its target up three wheel lines. Scroll target resolution skips the
AX enabled-state read.

`type` with `at:{x,y}` clicks that image point, then types into the editor
that takes focus. A targetless `type` sends literal text, such as indentation,
to the focused editor. This also works when the call carries `frame_id`
without a handle. AX editability is required. Unreadable contents do not
block keys, but return unverified with a pixel look
offered. Unknown, noneditable or secure focus still stops typing. Append
still requires a named, readable editor and a verified insertion point.

Key chords post keys directly, so duplicate menu titles cannot make ⌘W
ambiguous. A scroll without a target chooses the window's largest visible
scrollable content region, or its observed content area when AX supplies no
scroll region. `app` selects that app's window under the usual foreground rules.
When resolving an application name, an exact bundle filename wins over a
shared display name: `Numbers.app` wins over `Numbers Creator Studio.app`
for `Numbers`. Two installed bundles with the winning filename require a path.
The Screen preview reflects the result of `mac.go`. A background request for
an already-running app reports that the app is already running.
An app quit reports `terminated:true` only after the resolved processes exit.
Accepting a quit request does not prove termination. Quit uses the shared
navigation settlement patience (1.5 seconds), waking on the app's termination
notification and judging its actual termination state. If it is still running
at patience, the call returns with its PID and explains that quit was requested
but the app may be waiting for a person at a save sheet or may have declined.
Each accepted quit's settlement writes a `mac.settled` row with `what:"quit"`
and its end cause. Cancellation ends observation; it does not force the app to quit.

Looking at a named app that is stopped returns a successful observation with
`status:"ok"`, `app:<name>`, `running:false`. A running app with no readable
window returns `running:true`, `windows:0`, and its menu-bar titles when cheaply
readable. Looking launches nothing and creates no window; an act still checks
that its target is available.
Running identity includes both Dock and accessory apps, including an app whose
last window closed. Exact names and bundle identifiers prefer a Dock app over
a same-named helper. Partial names and running-app suggestions include Dock
apps only.
The live Accessibility source prepares renderer modes before interactive AX
reads and actions, using settable capabilities rather than app names. It requests
`AXManualAccessibility` only after a complete bounded topology probe finds an
empty renderer (or only an empty window shell), and requests
`AXEnhancedUserInterface` when it reads false or a web area needs an unconfirmed
mode. Enhanced readback must be true, even when its setter returns an AX error;
its cold admission is shared by PID and the kernel's process start time.
An unreadable kernel identity reports its cause and remedy; it never becomes
empty activation evidence or a claim that the process changed. Metadata for
other processes is retired only on the kernel's explicit no-process result.
Manual's accepted
write can still read false: the receipt reports that uncertainty, and only the
subsequent tree and action effect establish what is usable. Incomplete probes
never establish emptiness. The diagnostic `renderer_activation` in a raw look's
detail carries bounded before/after element counts, role lists and `probe_complete`
(the probe's own walk, not the look's `partial`),
plus attempted writes' AX status and Boolean readback.
Async admission arms descendant observation before activation, then suspends
outside the AX lane while the content judge waits. Every descendant notification,
including value, layout and creation changes, wakes that judge; only exposed
content establishes readiness. Content already exposed needs no wait.
If descendant observation cannot be installed, activation still proceeds and
this settle judges content within the same patience;
`settle_observation` records `unavailable`, the cause, and `content_or_patience`.
Two seconds is patience, bounded by the caller's budget;
silence records `settle_unobserved` and permits a read of what is present, without
claiming content is ready. `settle_ended_by` names content or patience.
A synchronous caller never sleeps: it reads the topology and, if cold admission
is still owed, reports still settling and emits no action. Passive reads do not
activate renderer modes or wait for them.

A window walk reads each element’s role, subrole, labels, frame and control
states together. A second read requests its value and, for editable roles,
its selection range. If the subrole read fails on a text role, the walk skips
its value and still reads any applicable selection range. Once a title supplies
both names, later label slots are ignored. Each optional attribute the walk
uses that answers AX error `-25200` keeps its
attribute name and code alongside the slots that succeeded. The element’s
`attributeGaps` are exposed on raw nodes, menu-bar paths, transient menu items and numbered
marks as `attribute_gaps`, for example `["AXSubrole: AX error -25200"]`:
the subrole is unknown, not absent. This applies to optional string, Boolean,
raw-value and frame reads without a per-attribute exception list. The gap
does not block acting; each act still requires its own live evidence.
Act-time name reads use the same element scope, so an optional subrole or help
failure does not refuse the action. Reads of a separate caption or sibling
have their own scope: a failed caption read leaves one `caption read:` gap on
the control and `label_source:"unreadable"`, without attributing the sibling's
attributes to that control or substituting a hint or inferred name.
A failed own-name read (including `AXTitle`) likewise marks the label unreadable;
another label attribute, caption or hint cannot replace it. Unsupported or
no-value name attributes remain absent, so another published name may be read.

Action-name error `-25200` stays separate: `actions_unreadable` carries the
original error instead of an `actions` list. An AX action, including one
addressed by a numbered mark, re-reads the live action names and refuses if
they remain unreadable; it never guesses an action or switches to input.
Explicit pointer and keyboard routes are unchanged.

Looks report `attribute_gaps_count`, `attribute_gaps_first_error`,
`actions_unreadable_count` and `actions_unreadable_first_error` in their
diagnostic `seam`, and name gaps in the screen reply; raw tree/find and
numbered views report those summary fields directly. Attribute counts count
named gaps; action counts count affected elements. Numbered views include
the bounded transient-menu reads, including structural nodes, and count an
element seen in both walks once by native identity, using the later menu
observation for an overlap. Counts describe only observed elements, even
when traversal is cut; zero never establishes that
unseen attributes were readable. Unsupported/no-value answers stay absent.
Under Full Mac, the agent's own looks are not masked: they sees the screen as
the person does, keys included, because a picture goes only to that turn's model
request and is never saved; the text of a look and every saved receipt keep their
redaction. Other agents' looks and every other posture keep the masking below.
Pixel masking covers what it could not read. A text element (a field, a text
area, a combo box, static text, a heading) whose value, caption or subrole read
failed is masked over its entire finite frame, and so is everything its words
could have named: what it holds, a row or cell named by what it holds, and what
sits where it would be the label. An unread title covers the same way on any
element. An unread description is a caption only for a value that could be a
secret it names, one unbroken run of characters: over read prose (words with
spaces, such as a document's text) it covers nothing and withholds no words, so
an app that fails its text area's description (TextEdit does) still shows its
page. The rest of the picture is released. Any other failed read on another
element (apps answer failure for a window's value, an image's description, a
button's subrole) is reported as a gap and covers nothing.
An element with no role, a missing or nonfinite frame on such an element, or a
walk that was cut still withholds the image and names the cause in
`image_withheld_reason`; the look retains its text, controls and reported gaps,
including when pixels were requested explicitly or selected automatically. A value-bearing text
role, including an editable field, with an unreadable subrole contributes no
value to any text look, including when another control uses that element as
its caption. All AX value reads share this subrole check; a failed caption
subrole read leaves the control's caption unreadable.
Window text recognition uses caption redaction and the union of the complete
pre-capture and post-capture masks, including when no picture is requested.
Whole OCR rows intersecting a mask are omitted. Incomplete coverage, unproven
capture geometry or unproven OCR positions withhold recognized text for that
capture. The AX look remains available with its reported gaps.
Both pre-capture and post-capture inspections enforce these rules;
desktop composition masks that window in full and reports its inspection error
in `masking_failures`. An unread value never vouches for safe pixels.
Required reads (including role, window identity and act-required geometry),
transport errors such as `-25204`, invalid elements, disabled Accessibility,
renderer preparation, cancellation and read-budget exhaustion retain their
checked failure paths. No other reader retries a failed attribute.
App change watches keep supported subscriptions through element failures and
bounded traversal, reporting partial coverage and named gaps as described in
[Senses](SENSES.md). An observer/channel failure still ends the watch.
Fused window images use the same two-point origin/size tolerance as window
selection across AX, ScreenCaptureKit and window-server frames. They still
require the retained native window and complete secret inspections.

Preparation emits no input, launches nothing, and writes only to the app being
read or acted on. System UI, apps under `/System`, non-regular background helpers
and Apple's assistive-technology apps are excluded. Passive observation never
writes these flags. Flags stay with the process rather than being cleared when
the agent looks elsewhere; another assistive client may rely on them. Enhanced
mode can affect AppKit window movement/resize animation in a targeted app. Driver,
posture, macOS grants and action-effect verification still govern all actions.
When Shotgun steps the main window aside for a screen operation, that operation
awaits the fade's completion directly. Bringing the window back during the fade
keeps it visible and still releases the waiting operation. Stop or the Mac call's
deadline also releases that wait; a missing fade callback cannot hang the call.

For stopped calls, follow the [interruption receipt contract](ONE_DOOR.md):
inspect retained receipts and affected state before repeating an attempted call.

When a default `mac.look` finds NativeAgent in front, `behind` names the
person's app behind their when one is visible, so they can address it directly;
`behind_app` carries its structured name. If the in-process page look fails
because no window is connected, `next_call` and `remedy.next_call` address
`app {action:"mac.look",args:{app:<behind_app>}}`. That app has not been read yet.
After an act, an unchanged target surface
without press evidence is unobserved (`acted_unobserved`); when readouts
elsewhere in the window changed after the press, its reason is
`changed_elsewhere` and `readouts_changed` lists them; a destination that
contradicts the intended one is a mismatch (`acted_mismatch`). Typed text that
moved the field off its pre-typing value but reads back differently (an app that
capitalizes or curls quotes) is `acted_changed`: the reply quotes what the field
now says, and they reads it before typing again. A field that still reads its old
value, or whose old value was unreadable, stays `acted_unobserved` with a look.
An acknowledged accessibility text write returns its readback without a
keyboard retry. If the value reads unchanged, the write remains unverified;
inspect it before writing again. You can explicitly request keystrokes.
Handles support double-click, right-click, hover and accessibility focus on the
selected element. `focus` is offered only when `AXFocused` is settable, and its
receipt verifies focus. Screen offers and action schemas share the hand's verbs.
Identical full menu paths count as one command when every duplicate publishes
the same command identifier or key equivalent; an enabled copy wins. Unpublished
duplicates require a choice unless only one is enabled or a supplied chord
selects one. Use the shown chord when available, otherwise the displayed path
with `[first]` or `[second]` (later occurrences use `[third]` through `[tenth]`,
then `[item 11]`, etc.). These select the current menu order. Different paths
still require a choice.
Presses read sibling names and the exact named branch; unrelated siblings'
children stay unread, so their child-read failures or listing caps do not refuse
a readable command. Duplicate selection still needs complete evidence within
that branch under the shared AX budget. Missing-path replies list up to ten
child paths in the deepest matched submenu, in the app's order, skipping
separators and empty titles. If the found item is a leaf, the reply says it has
no submenu and lists its containing menu's children. If those items cannot be
read, the reply says the read failed or coverage is incomplete rather than
claiming an empty menu.
A press answers the same way whether it comes as a menu path in `mac.act` or as
`mac.menu_press` (`pressedMenu`): the sentence, then the screen after it: the
pressed app's window, or the front screen only when no app was specified for
readback. If that read fails (including Quit or the last window closing), the
sentence says why, and `screen_after` carries that read's error, message and
remedy beside the press receipt (under `detail` for an act's menu path); no other
app is read in its place. The
direct press keeps its receipt fields (`output.pressed`, `status`,
`verification`) and carries that answer in `text`; it needs no `mac.menu` read
first, since the press reads the menu bar itself.
An explicit menu path with `app` uses that app's native menu press in the
background, including when it has no window. It does not bring the app forward
as a prerequisite; the command itself may open or close a window.
If the selected path's AX address cannot be revalidated before pressing, the
reply reports unavailable; its current items remain unknown.
Menu-bar optional failures appear as `attribute_gaps`; unreadable names leave coverage
partial rather than naming a different command.

The watcher reconciles lock state in both directions before opening a span;
its 60-second observation tick remains armed across a lock or unavailable AX
attachment. AX creation/registration failures leave capture degraded, turn off
the running indicator and retain a notice. The same lifecycle rechecks the
current foreground app on the next activation or observation tick; if AX never
recovers, capture stays degraded without recording unsupported duration. Lost
required observation closes a span at its last observed time with
`observationUnavailable`; an attachment error is recorded as quit only when
the target app's termination is confirmed. Lifecycle shutdown also closes as quit.
Unsupported individual notifications are named while supported subscriptions
remain active; an app supporting none leaves capture degraded.

With title capture opted in, the initial successful title read settles the
current span in place. A later changed title, or a policy change removing a
recorded title, closes it as `windowChange`. An AX no-value result means no
focused window/title; an unsupported title attribute means no title. A failed
read or wrong result type retains the previous title evidence and a notice,
without inventing a window change. Every new span records the local UTC offset
for its actual start timestamp, including after a time-zone or DST change.

readable repair is handled through the existing tightening-only file update
rules; enabling recording still requires the person's settings decision.
Unreadable retention cadence stops each cleanup attempt before pruning or
replacing its bytes. A failed pass retains its notice and retries in six hours
through the same checked policy, cadence and store path. Exact policy/cadence
file changes can rearm cleanup sooner after repair; without repair, unreadable
cadence continues to block pruning. A missing cadence is a first run. Deleting
rows by pruning, a full wipe, or an app purge durably records compaction owed.
Cleanup retries it even when no further rows expire or recording is off,
including after an app restart. The retention pass records its completed-run
stamp after cleanup succeeds.

`mac.apps` reads the resident Spotlight app inventory. A readable app bundle
that declares no platform is a Mac app. Installation classification uses its
location and Launch Services evidence. Ancestor package exclusion uses the
filesystem's package flag, so a dotted folder name alone leaves the app
eligible. Unavailable classification appears with its path and causes in
`classification_unavailable`. The reply is `partial`, and those rows stay out
of the installed projection.
`all:true` includes them with their unavailable fields. Named-app resolution
reports matching classification gaps instead of inventing an installed app or
treating that row as absent; known copies and iOS builds do not block a separate
Mac target. An unreadable bundle's scriptability is `null`.
An unreadable ancestor directory names its failed reads by path in `directory_gaps`, makes
the inventory partial, and leaves readable descendant apps classified by their
own facts. These gaps and app rows come from the same snapshot.
A synchronous inventory consumer reports not ready
while Spotlight gathers; an asynchronous request waits at most four seconds,
or the shorter inherited call deadline, without stopping the resident query.
Resident app-arrival observation stays attached until gathering completes or
its owner stops it. The engine retires the index after its consumers stop at quit.

### Chrome and web reads

Explicit looks and PDF picture reads deliver Chrome's original image to the
agent. The extension supplies only paint-out geometry beside that image; the Mac
paints and downscales its own copy for Screen. Unavailable geometry means a
caption alone, without taking another picture or changing the agent's read.
A closed tab clears its old picture and shows the close result.
Read previews hide password/autocomplete-password/cc values at the same source
as the model's read. They remain in memory and are never sent to the phone.

Chrome tab actions and NativeAgent's built-in browser are available through
the Browser page of `app`. `chrome.snapshot` reads a NativeAgent group tab's
text, or returns its picture with an explicit note when Chrome provides no DOM
access (including the PDF viewer). Internal pages (`chrome://`, `about:`) return
one line with the title, URL and "Chrome allows no reader on its internal pages"
(`read_mode: "none"`) from both snapshot and look, without a picture attempt.
For PDFs, the snapshot keeps Chrome's verified picture and reports that text
is unavailable from its picture reader. It makes no independent HTTP request;
an explicit web read returns a separate source with its own receipt.
`chrome.navigate` verifies
resource completion from Chrome's completed tab and landed URL;
unsupported schemes such as `javascript:` and `data:` refuse before any tab moves.
Without `tab_id`, navigation reuses this conversation's tab only while it remains
in the accepted group inventory. A closed or released remembered tab is forgotten,
so the next destination opens a new inactive grouped tab. An explicit lost `tab_id`
still refuses. `chrome.status` compares its printed running and folder code
digests directly; its shipped version comes from the app bundle's manifest and
may differ from a separately updated extension folder. A browser signature or
extension origin refusal remains current across a NativeAgent restart while the
same Chrome process is alive and no newer relay greeting has succeeded.
Use `new_tab:true` with a destination and no `tab_id` to open another background
tab in the NativeAgent group. Navigation and reads proceed when the document's
main/feed/article content arrives. Resource completions cannot admit an unreadable
shell. The document retains its content evidence and original event time across
worker restarts. HTTP(S) PDFs and images arrive when Chrome commits their
document; its MIME selects the picture reader even after extension restart.
Passive news uses the same DOM arrival evidence. History and fragment navigation
reset content evidence to the current route. Route content must be
text added or changed after that navigation; unchanged prose cannot admit it. There is
no navigation or read deadline; Stop cancels a wait, and Chrome's navigation
errors, tab removal, takeover and connection loss keep their causes.
Status and verification still report resource completion separately.
Navigation receipts show dispatch, commit, content arrival and read
return in milliseconds; a stage not observed stays null. Observed stages remain
in a receipt after later errors or cancellation. Snapshots read the
DOM once with the existing node, text and transport budgets. A long page has
`has_more` and an exact `next` continuation; pagination is a successful window.
Only an unread part with a named cause is `partial`. Empty windows state only
what was observed. Missing or malformed gap metadata preserves the captured
content and states unknown coverage. There is no settled/unsettled read label. `capturedAt`
dates the content and `rendering.loaded` separately reports resource completion.
Only an explicit page wait observes a requested quiet interval. When the wait
ends (matched, settled or timed out), `chrome.wait` returns the tab's fresh page
in `page`, read after the wait as a click's is (a matched wait also carries
`readback_note`); a refused wait or a lost tab returns without one.
Rotating iframes invalidate their own action routes and preserve sibling content;
an unavailable optional frame appears as a named gap in the page read.
Side-by-side columns read one at a time, the column with the most readable prose
first, even when feed and sidebar share one main region. `more` finishes that
column before moving on. Outside column sets, main content precedes navigation;
every frame's content precedes labelled
overlays, which spend only the budget left over, without dismissing consent.
The header names a blocking dialog from its name, heading or visible prose;
clicking a row behind it reports that same dialog. Disabled, invisible and
nonactionable rows explain their cause; an unobserved row is scoped to the read.
Later identical
text blocks reference their first row, keeping each control's identity and states.
Defaults are 400 rows and 32,000 text characters within the existing
transport bound; `more` names its own tab and document and follows its unchanged
content when the layout moves, without needing another `tab_id`.
`find:"text"` starts at the first observed
matching element. Images/charts carry names and sizes, with `chrome.look` offered
for their pixels. A successful thin `web.read` uses this Chrome door in another
background tab and says `used_browser:true`, retaining its HTTP evidence under
`http_read`. `text_reader` names `browser` only when Chrome's served text has more
non-whitespace characters than the selected HTTP text, counting both returned
strings the same way, including a site's authored view; otherwise HTTP text stays at
the top with partial status and the browser result and cause in `browser_read`.
`used_browser` describes the attempt. Chrome may use the signed-in session.
HTTP failures remain explicit.
`chrome.look` shows the picture Chrome renders now, including image
documents with no text. Omit `tab_id` for the conversation's remembered tab.
Looking never activates or moves the tab; pictures use the same model-turn
image slot as `files.read`, bounded to 2048 pixels with source dimensions kept.
Without a model-turn image slot, both readers return verified dimensions, byte
size and encoded type with `image_pixels:false`, and say how to view the pixels
from a turn. This is a successful metadata read, never a claim to have seen the
image. An ability's receipt keeps the effects of all its calls, including writes
before a later failure, and its own execution verdict.
`guide:chrome.look` on the Browser page describes the action. Chrome's temporary
debugging infobar is visible during capture; an unpainted hidden tab is refused.
`chrome.status` also lists the last eight tabs released in this app run, with
the reason and time they stopped being theirs. Ownership refusals say whether
the person selected the tab, it left the group, or it no longer exists.

For the SearXNG result fields, gaps and time-range contract, see
[Extending their reach](ONE_DOOR.md#extending-their-reach).

### Local integration arguments

Local Contacts uses one argument contract for agent calls and forms.
`contacts.search` needs at least one nonblank string: `identifier`, `name`,
`phone`, `email` or `query`. If several are supplied, that is their selection
order. `query` selects email when it contains `@`, phone when it contains at
least three digits and only phone punctuation, otherwise name. The selected
lookup runs once, including on a miss or error; successful results name
`lookup`. An identifier is always an exact Contacts identifier, including for
`contacts.save` and `contacts.delete`; names in that field are never retried
as name searches. Store errors report their cause, not a claim that a card
was deleted. Search `limit` is a whole number 1–100 (20 when omitted).

`contacts.save` needs an identifier to update, or `given_name`/`family_name`
for a new card. Without an identifier it updates the single exact full-name
match, creates if none exists, or creates with an explicit ambiguity message
if several exist. Optional `phones` and `emails` are arrays of
`{"label":"home","value":"…"}` entries, with both strings nonblank.
The entire raw request is validated before Contacts is read or saved;
nulls, scalar strings, string arrays, numeric field values and malformed
entries are refused rather than dropped or coerced. Omitted arrays and `[]`
add nothing. A save keeps existing values and the first entry for each new number
(by digits) or address (case-insensitive). Omitted name and organization fields keep their values.

Calendar event updates require strings for supplied title, notes and location.
Omitting a field preserves it; an empty notes or location string clears that
field. Malformed text fields are refused before reading or changing the event.
Recurring event edits require the observed `startAt` from `calendar.upcoming`
as `expected_start`, alongside `id`. Calendar and Reminders deletes take the
returned, redacted `title` as `expected_title` and compare it in that same form;
creation replies use that title form too. Edits and deletes match that occurrence's
id and start before changing only it; an unavailable or moved occurrence is
refused with a request to refresh. Deletes also check the observed title.
Calendar day reads cover local midnight through the next local midnight as an
exclusive end, including the final second of the requested day. EventKit full
access permits reads and writes; write-only access permits Calendar creation
but does not establish read access. A failed permission request preserves its
error and the System Settings remedy rather than claiming a completed request.
If saving a reminder list throws, the result retains unknown effects, its
`list_id`, requested name and previous name when renaming. Read the lists and
reconcile that identity before repeating the write.

Reminder queries require booleans for supplied `undated_only` and
`include_completed` fields; only omitted fields default to false. Invalid
values return an argument error naming the field before requesting access or
reading reminders.

### Abilities, Make and mind processes

- Skills are built-in guidance: `ability.list` and `ability.read` find and read
  them.
- To author a capability, the agent grows an ability with `ability.save`. Under
  Full Mac their ordinary own save is kept and on at once;
  [abilities with tape fixtures](skill_manifest_spec.md#tape-fixtures)
  must replay their recorded examples before anyone can keep them. Otherwise
  `ability.enable` asks with a card. You can also keep it in Capabilities. A kept ability appears as
  `authored.<id>`; `ability.disable` and `ability.drop` manage it; revisions fix it forward.
  Abilities grant no new authority. See the [manifest spec](skill_manifest_spec.md).
  Keeping follows the current
  [Trust and peer-turn rules](#trust-modes-and-approvals), including the
  exemption for agents enabled in Trust.

The agent reads Make's shelf with `app {page:"make"}`: every retained ref,
newest first, with `next_call` for more. Opening a row with
`app {page:"make", item:"<ref>"}` reads its versions, paths, prompts and
provenance. Missing or unreadable metadata remains visible as an unavailable
row. `make.read` reads one ref (the newest when omitted) and points unknown
refs to the shelf.

Make publishes preview file, revision and read folder together through
`LatestRead`. Changing selection or closing the preview cancels pending
WebKit preparation.

To run one mind process now, discover it with `app {find:"mind"}`. `mind.dream`
runs the real dream pass, and the clock-owner actions can satisfy their own
wait while keeping readiness, Trust and person-facing gates. Each new clock
action reports its actual decision and why. The [run-now table](SUBCONSCIOUS.md#run-a-clock-owner-now)
lists the actions and the waits they satisfy.

Use `app {action:"mind.dream", preview:true}` to generate a dream and inspect its
proposed care judgments without applying them or writing a diary. It spends a
real provider call. The five clock-owner actions (`mind.canon`, `mind.horizon`,
`mind.rhythm`, `mind.maintenance`, `mind.residual_repair`) refuse preview with
a specific reason; removing `preview` runs them for real. The run-now table
documents that boundary.

Cognition's reflection records show an unavailable token total if the recorded
components overflow, retaining the individual prompt and result counts.

Background work is owned by the core's `BackgroundLoopLifetimes`.
Senses registration does not hold background work at launch: messaging,
reply delivery and Desk notifications start independently. A sense read or
file subscription reports its own unavailability while Doctor's **Senses
installation** reading names the registration failure and repair. After repair,
file subscriptions resume on successful registration; a read that returned
unavailable can be requested again. See [Senses](SENSES.md).

### Identity and provider internals

Setup reports a missing app model instead of aborting. Name suggestions do not
depend on narrowing the system clock to an integer. An empty tour has no current
stop and completes without indexing a missing step.

Every personality compilation requires the saved identity. An existing
`memory/profile.json` must contain the complete current profile with typed,
finite traits and its real update time; damaged fields block dependent reads
and edits with their field paths and repair instructions. A missing profile is
unavailable too; only explicit setup or missing-profile repair with supplied
names creates an identity. Name-only display surfaces stay blank until a
checked identity is available; loading and failure messages never become the
agent's name. The Personality page keeps the read failure separately. An
explicit persona selection must resolve exactly; `canonical` selects the root,
and a missing custom directory never chooses another persona. With no saved selection the root is
selected through `PersonaSelection`; there is no file selector. SOUL, VOICE,
USER, GROWTH and AGENTS must read successfully, with explicitly absent custom
overrides inheriting their canonical document. Only absent MEMORY and surface
guidance are optional. Document listing is read-only. Turn and context preparation
create only checked-missing required canonical documents through PersonaEngine's
genesis owner; existing unreadable documents require repair. Explicit first creation seeds all five documents
before publishing the completion sentinel; pending completion/reset blocks
completion across setup, resident admission and USER generation.
The completion marker travels with identity data in local/off-disk backup and
production export, so restoring that evidence preserves completion. Restore
replaces only captured paths: a backup without the marker leaves any live
marker unchanged and never invents completion. On a completed install, compilation
creates any checked-missing SOUL, VOICE, USER, GROWTH or AGENTS document from its
shared onboarding template and checked saved profile, under the completion and
document locks. No Repair press is needed. USER.md uses the saved person's name
when supplied, otherwise its blank User header; an invalid saved userName reports
the field to repair. Existing files and dangling links are preserved. A missing
document whose genesis preconditions are unmet, or an unreadable document, reports
its own path and remedy.

Personality instructions live in those documents. The profile's former essence,
voice, directive, instinct/boundary/style lists and surface instruction fields
are no longer controls or runtime projections. Existing saved values remain
opaque preserved keys; they are not injected or copied into their documents.

Committed content invalidates derived context before readback. An activity-feed
failure owes a separate repair and does not fail the
saved edit or invite repeating an append. Recovery-copy pruning must succeed
before a pending persona edit can run. The checkout installer creates template
files only at absent paths; existing empty or unreadable files are preserved
and reported for repair, and unavailable required templates fail setup.

Slack uses the same installation persona selection as Chat; a display name is
never a persona directory ID. The first greeting reads the person's name before
claiming or sending it; an unreadable profile leaves the greeting pending and
reports how to repair it. Setup checks the complete current profile through
PersonaEngine before treating an existing identity as usable.

A completed first greeting retains its exact session/title receipt, verifies
its progression token and next-turn directive, writes the met marker, and only
then retires its in-flight claim. A bookkeeping failure reports the saved step
that needs repair; rechecking finishes that receipt without sending another
greeting. Without a completed receipt, an in-flight delivery remains unknown.
The progression owner supplies section identities and role/voice instructions
to every stage. Ordinary Trust authorizes persona writes; only a successful
matching append spends progression and commits the voice step. Failed
progression settlement leaves a named repair owed alongside the successful
append, so the section is never repeated to repair bookkeeping.

After-turn memory interpretation also reports that
profile failure and keeps the turn owed rather than judging with a guessed name.

Slack setup, routine credentials, Claude setup tokens and request
cards use the same protected entry. These controls perform sign-in storage,
sign-out and CLI consent operations off the UI actor. Their Providers refresh
also builds credential status, CLI consent and cached model availability off the
UI actor for every caller, including committed routing updates. Committed routing
invalidates pre-write reads before rebuilding; newer published settings cannot
be replaced by an older rebuild. Browser presentation still runs on the UI actor.

An HTTP 403 from a model request retains its reported refusal; it does not
declare the saved key expired without authentication evidence. Check the
account's access to the requested model or feature in the provider dashboard.
A `billing_not_configured` refusal says billing is not set up for this account
and directs setup at the provider. Other HTTP 402 and explicit billing-error
codes direct attention to its allowance and billing. Neither declares the key expired.

The shared credential redactor recognizes Meta's `LLM_<numeric-id>_<secret>`
format in diagnostic, receipt and feedback text, including a bare key without
an Authorization header or credential label.

Meta uses the shared Anthropic-format Messages adapter
at `https://api.meta.ai/v1/messages` with Bearer auth and client-side history.
Meta's returned thinking blocks, including opaque reasoning, replay across
tool rounds through the shared in-memory tool-call ledger, for as long as the
conversation before them is unchanged. They are not saved in conversation
history. After a change to the model, system, tools or earlier messages,
eviction or app restart, ordinary text, tool calls and results remain.
Kimi Code does not enable thinking replay.

### Helper calls and builder jobs

Tools and the phone save the brief in the same field. Helper create/update
arguments have no separate `output_format`.

The Mac's Helpers page and `/helpers` use the same face as
`app {"page":"bots"}`. A missing legacy `modelPinned` flag means false. A
helper can talk to the resident by name with `agent.message` and receive the
reply in the same call.

An unreadable saved ChatGPT-account or Moonshot model list reports its fault
before checking a helper's choice. It offers no replacement shipped choices
and never changes the helper's saved model. `bot.list` with
`include_models: true` includes the catalog's fault beside its empty model choices. A confirmed
absent cache remains distinct from a list that cannot be read; neither supplies
replacement models. Refresh the account's catalog before selecting a model.

For `bot.create` and `bot.update`, `provider`, `reasoning_effort` and `fast`
apply only to a pinned model. An explicit `model` pins it unless
`model_pinned:false` is also supplied. A following helper refuses each submitted
value that conflicts with Chat's, naming the actual argument (for example,
`$.fields.fast`), the rule, and how to pin a model. Matching inherited values
are accepted as no-ops with a note; they save no per-helper setting. The same
rule applies when unpinning in the same call and when saving from the phone:
no submitted choice is silently erased. Set `model_pinned:false` alone to
clear the saved choice and follow Providers.
The phone's Follow Providers form leaves its inactive per-helper controls
unset; explicit settings submitted by phone clients follow the same rule.

A conversation's one-line result opens the exact saved answer with
`bot.reply`. It uses the same durable
reply-delivery and arrival path as a peer answer, without another model turn
to summarize it. An interrupted execution keeps its exact shelf record. The
queue records a refusal with the request ID and cause when it denies a request
before execution or recovers an interrupted claim that never admitted execution.
If there is no evidence to settle the request, its outcome remains unavailable
and asks for repair. No request is repeated to obtain a result. If
saving the asking conversation fails, the reply preserves the underlying
outcome, conversation and operation identities, and persistence cause.

Every shelf entry read, including the unlocked home glance, consults canonical
approval state after reading the entry. Missing or unreadable approval evidence
stays unavailable; it cannot mean decided. Locked entry/history reads retain a
positively observed decision. The unlocked glance projects it.

`bot.list`, `bot.run_once`, `bot.pause`, `bot.delete`, `bot.update` and `bot.ask`
use `id` for a helper's UUID or exact name. For example,
`app {"action":"bot.run_once","args":{"id":"Research helper"}}`.
Returned `read_with` calls name the registered `bot.reply` action.
If a helper selector names a saved agent contact, the refusal explains the
distinction and supplies `agent.read` with that contact's saved address.
For `bot.ask`, it instead proposes `agent.message` with that address and the
original question as `text`; nothing is sent by the refused call.

Pausing or resuming a manual helper is refused with `effects: none`. Other
refusals before a write carry the same receipt. Deleting a helper retains
its definition and audit for an already running job.

`bot.replies {}` lists saved replies newest first, including already read
replies. Choose `sort: "oldest_first"` for ascending history, or
`sort: "oldest_unread"` for unread replies oldest first. `include_read: false`
selects unread replies in the chosen order. Reads acknowledge only when
`mark_read: true`; headlines stop at a whole word. Page with a zero-based
`offset` and returned `next_offset`, or a query-bound `cursor` and returned
`nextCursor`, keeping the same filters and sort. Use one paging form at a
time; changing unread state or new arrivals can change offset positions.
Helper-history reads and their continuation calls select a helper with `id`.
Helper references use only `id`, and ordering uses only `sort`. A shelf entry's
separate `bot_id` names its expected owner or selects that helper's latest reply.
`bot.reply` returns the full text in `answer`. With `save_to`, `saved` contains
a batch `status` and `files`.
Each file has its artifact index and name, and its saved/existing path or a
specific unavailable, access or write failure. A later failure keeps earlier
saved rows; independent files still proceed. An incomplete export returns
`status: partial` on the reply and the batch. If marking the reply read fails,
`acknowledgeError` accompanies the retained export rows. Existing files are
never replaced. Each access refusal identifies its card with `card_id` in the
file row and keeps the complete file-access envelope in the reply's top-level
`needs` list. The existing card owner files each envelope in the conversation;
allowing access continues the conversation without replaying the partial export.
`needCards` records each filing's card ID and conversation, or its unavailable
cause if a card could not be filed; saved-file evidence stays in either case.
An artifact already naming a path returns `referenced`; this export does not
re-read those bytes or certify that the referenced file still exists.

The agent can hand a bounded job to a local coding session through `app`:
`agent.job` to the Codex or Claude Code contact, with `where` naming the
repository when the job should come back as a diff in its own worktree.
Install and sign into the corresponding coding product on the Mac. The job
should name the requested outcome and, through `done`, the check that proves it.
See [Jobs](agent-communication.md#jobs).

For a line of their own, use `agent.job` with `agent: "self"`. Give each line
its own brief. Optional `instructions` give it a role in place of their persona.
`agent.jobs` lists the lines, and `agent.read` or `agent.cancel` with the
job ID reads or stops one. See [Jobs](agent-communication.md#jobs).

### Telegram, Slack and bridge transport

The bundled `nativeagent-link` helper and HTTP agent clients read the agent
bridge's descriptor under `~/.config/nativeagent-link/` for the current
loopback URL. Each contact sends its own credential. The older builder bridge
keeps `~/.config/claude-bridge/bridge.json`. Use the port from the descriptor.
See [Agent conversations](agent-communication.md).

Telegram's message and replay metadata readers reject malformed present values;
unavailable transcript/diagnostic reads report their source instead of zero history.
Unsupported slash-command stderr diagnostics identify the update without copying its message text.
In an admitted private Telegram chat, slash text and captions enter the conversation unless their first word names a registered bot command.
Only registered private-chat commands interpret an `@botname` suffix as a bot address.
A command refused admission during shutdown stays pending for the next loop; it is not recorded as interrupted work that ran.
Blocked-message, reply and voice-receipt write failures name their source in Telegram's
error log and status; a failed reply receipt does not clear that status as a successful receipt.
Malformed successful API results report their decoding cause; rejected API envelopes
retain Telegram's refusal and pacing hints without requiring a success result.

A Slack helper-wake failure retains its repair obligation and records a
`bot_event_intake` error; the independent chat turn still answers the message.
The journal's fan-out claim prevents a reconnect from waking those helpers again.

Telegram approval text uses bounded UTF-16 consent parts, with answer buttons on the last
part. Its progress ledger writes only changed durable card facts, and group
previews edit only packets whose accepted rendering changed.

Slack redacts reply text before preparation and fingerprinting and again at the
send boundary, including saved replies and notices. Final replies retain
confirmed progress per bounded text part before images. Settings acquire one
asynchronous checked Slack policy for the three settings rows. A settings
save restarts the socket worker immediately. The journal keeps accepted
handlers, and Slack uses no deferred settings queue.
