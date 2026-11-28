# Desk vocabulary

The Desk holds the agent's durable work.

The Desk journal commits one or more operations under the store's lock.
Operations receive ordered timestamps and are appended together to
`desk/desk_ops.jsonl` as one payload with a full flush. A queue filing commits
creation, status and step together. Validation that depends on an earlier
operation reads the staged prefix before any journal write. A torn tail
from storage failure or power loss still follows the journal's existing
integrity handling.

The Desk packet names failed contact and Inbox-answer reads as
`unavailable.contacts` and `unavailable.inbox`; its face shows those causes
under **Unavailable readings**. Needs you requests keep their open links and
say when their answers could not be read. A failed read proves no empty list.

What they means to do later lives here as a MY QUEUE intention, filed with
`queue.add {text, when, until?, say?, action?}`. Its `DeskStep` owns the words,
moment or rhythm, ending, fixed words, habit and origin. Promise capture also
attaches a step to the existing agent-assigned
row when it restates that work; it uses the same readiness and settlement as
MY QUEUE. Its canonical `promiseCaptures` identities survive refiling, closure
and archive so unfinished reflection cannot create the same source again.
A reference refresh containing only other evidence retains the captured step.
Attaching a captured step commits the row's title update with the step, using
the same words and peer provenance as a newly filed step and its approval
follow-up.
`queue.update` changes
named fields; `queue.done` and `queue.drop` settle it by hand, by its exact handle
or number. The after-turn judgment can also close a step with quoted evidence
of its deed, including in their own stream and lines
([Intentions](INTENTIONS.md#promises-they-makes)).
Words never select a different step. A committed closure keeps its
receipt if checkpoint cleanup fails, with the cleanup cause in
`settlement_failures`. Queue closure first lands any saved habit or speech
settlement for that step. When the checkpoint itself completes a once habit,
the call reports `done` with `effects: occurred`, including when the requested
action was `queue.drop`.
Repeating `queue.done` on a done step, or `queue.drop`
on a dropped one, is granted as `no_change` with its saved completion time and
evidence. Any other call against a terminal step is refused as `already_done`
or `already_dropped` with the same evidence, without changing it. Live steps supply
their outcome, notes and refs; archived steps, looked up by exact handle,
supply their outcome, carried deed notes, retained refs, decisions and
artifacts. The archive omits visible numbers and ordinary notes. An unknown id
remains `not_found`;
absence is not completion evidence. An unreadable required archive remains a
storage failure, never `not_found`.
Each ordinary step's time is a `moment:<handle>` time on the one
clock; what comes due is posted once as a `moment` happening, never a second queue
of reminders or turns. The [intention contract](INTENTIONS.md) owns the form,
readiness and delivery. A step imported from a scheduler job keeps its job identity
(`scheduledJobID`), so the same job never files a second step. A stopped import names the
evidence to reconcile before refiling it.

An open agent pursuit or carried work step can declare a typed `wait_for`
through `queue.update`. Its Desk step keeps the declaration across restarts.
The named cause offers work through the existing clock, Attention or Desk
observation. This path uses causal offers instead of work reservations.
See [Declared pursuit waits](INTENTIONS.md#declared-pursuit-waits).

Each item's `workAttempts` ledger holds both pursuit and owner-cadence work.
Only current attempt records enter that ledger; retired reservation formats
require explicit retained-data conversion before admission. Pursuit daily and
lifetime accounting, retained goal evidence, and receipt handoff keep their
existing limits. Today's pursuit count is projected for the Mac's current
calendar day from the canonical accounting and pursuit-lane attempts; it is
never a persisted display counter.

The journal admits every retained line or reports the named unavailable
record with its cause and repair. It never skips a create, alias, finding or
blocker. Every append validates the complete current serialized operation
before writing. Materialized state requires version 2 and its actual work-slot
ledger. Current origin values are `owner`, `agent` and `system`.
`findingKey` alone owns a system finding's identity; notes remain ordinary
text. Each note carries who wrote it: `owner`, `agent` or `system`.
Care evidence uses current `care` citations, with no retired
standing-view or open-question bridge. Saved policies, conditions and
provenance decode completely; invalid saved values never become new defaults,
empty peers, or next-turn readiness.

An item's name is `handle`. A stable handle, its permanent visible number,
`desk.<number>`, `#<number>`, the number followed by its title, or its exact
title addresses it, read by one resolver (`DeskState.matching`) for every Desk
action, `page.show`, `page.screenshot` and the window's own Desk commands. On `desk.add_ref`, an `id` supplied beside `handle` identifies
the linked approval or trace. `page.show {page:"desk", item}` opens an item by
either name, and `page.screenshot {page:"desk", item}` opens it the same way
before drawing: the opened item is the Desk's own selection, so the picture
shows it open and the window stays on its page. `page.show` answers with the
Desk as it now reads, its "Open now" line naming the item.

`desk.add` takes `project` optionally. Left out, an item goes under its
parent's project, and with no parent under `Tasks` (`DeskItem.tasksProject`),
where a task the person starts is filed. `desk.add` takes `kind` optionally
too; left out, it is `project` (`DeskItem.tasksKind`), the kind of that same task.

**The table** is the Desk's one standing board. On the board view it follows
Waiting and Needs you, with any **On the table** pieces listed just above it.
In an opened item it comes last, after its pieces. The table is present even
before its first change. **Pop out the table**, among the Desk's tools, opens it
in its own window with its frame remembered.
The table fills the pop-out's available space and resizes with the window, without a page scroller;
in the Desk tab, a pristine and idle table (no elements, no note being made, and not loading)
sits at 220 points and expands to 560 points as soon as anything is created.
The Desk tab and the window are two readers of one board; closing or hiding the
main window leaves the table window reading and acting; opening a piece from it
uses the Work pane, which is in the main window. The agent opens it with
`pane.show {view:"table"}`; `pane.hide` leaves it open. It is the existing `.board`
format in Make under the reserved ref `table`, with no second store. The
phrase **On the table** below still names pieces laid on open Desk items;
those pieces and the standing board are distinct.
The standing board belongs only to the Desk, outside Make's shelf and
`page:make`. `make.read {ref:"table"}` still reads its versions. The Desk waits for
the Make shelf's first reading, then reads the standing board directly by ref
and joins piece cards from the same shelf metadata as the picker and opened items.
A standing board read failure supplies the table's own reason. A picture of the
unstarted table draws an empty board.
Both table readings summarize each stroke by id, author, bounding box in board points, `closed` and enclosed ids in `around`;
an open stroke lists shape, text and container ids whose frames contain a point or intersect a segment in `touches`.
Signed frame dimensions use the intervals between the two ends on each axis.
Raw points stay in the file reached by `make.read {ref:"table"}`.
In `app {page:"desk"}` and on pages with a table slice, the same spatial
reading groups elements under their enclosing containers and orders each group
by row band and horizontal position. It gives each element's id, words, live
facts and measured geometry, with `inside`, `beside`, `under`, arrow and ink
relations derived from the current board.

**THE STORE ANSWERS; NO HAND GUESSES.**
`table.put` with `type` adds a whole element under a supplied free `id` or mints `e` followed by twelve lowercase hexadecimal digits.
An occupied supplied id is `exists`.
Without `type`, it changes only supplied fields of an existing `id`: absent is `not_found`, omitted is `invalid_input`.
An existing text edit can pass `if_text` to require the exact opening text. The locked write refuses a mismatch with `table_text_changed`.
Refusals write nothing. An edit keeps the element's type and requires its id.
An id must contain 1–40 letters, digits or hyphens, otherwise `invalid_input`.
A typeless put carrying `item` or `piece` is `invalid_input`, with nothing written: the pointer is set only at creation.
Only Agent or the person can promote a job artifact. Placement verifies the Make
version's job and peer IDs against the job's registered ref and version. The table
read shows its `made_by` and `made_version` beside the card signer as `promoted_by`.
Later card edits keep the original placement and credit. Older Make versions
with display credit alone still open, and require attestation for new promotion.
Opening a document, board or sheet on the Desk carries the exact version's peer
source into the Ask when its contents are read.
Every coordinate, size, width and stroke point is a finite number within a million points of the table's origin; anything else is
`invalid_input`. A card's target is checked when the card is put, not again as the write lands, so a card can point at an item that
closed in that instant; it then reads as closed. A contact's change that landed is reported as landed even when its lever or grant is
turned off right after; only refusals are withheld from a contact that has left the table.
A new absolute shape or container requires `w` and `h`.
A new shape, container or text with absolute placement needs both `x` and `y`.
A new arrow requires `from` and `to`. A new stroke requires `x`, `y` and `points`
(the points run from x,y). Refusals for missing fields name them as `invalid_input`.
In `app`, give one anchor in place of `x` and `y` when adding or moving a shape,
text element or container. Contact writes use explicit positions.

- `beside` names an element id and starts to its right, aligned at the top.
- `after` and `under` name an element id and start below it, aligned at the left.
- `inside` names a container id. It takes the first free whole-point position
  from top to bottom, then left to right, with 16 points of padding and room
  for the title at the current text size (44 points at standard size).
  An agent placement may grow the right or bottom of a full container created
  by the agent and still signed by the agent. A full container in any other
  hand returns `container_full`.
- `cluster` names an array of 1–32 element ids. A shape or text starts below
  their combined frame. A container wraps the combined frame with 24 points
  on each side and below, and 44 points above. Its dimensions come from the
  cluster and it takes fixed padding.

For `beside`, `after`, `under` and placement below a cluster, `gap` is
0–400 points and defaults to 24. A new anchored shape defaults to 220 points
wide and at least 88 points high, growing to fit its measured words. A new
anchored container outside a cluster defaults to 420 × 280. Text measures
its own frame.
Placement on the Mac uses the same text size and frames as the Mac canvas,
including wrapped notes and the bounds of the painted pen curves. If the aligned position is blocked, side placement
checks 24-point steps and takes the nearest free slot on the requested side.
Linked anchors, cluster members and linked cards being placed use the current title while the
board change is locked. A plain note beside a plain note needs no Desk or peer
read. If an unrelated Desk card's unmeasured title could cover the selected
slot, placement returns `card_frame_unavailable` with no write.
Unknown anchor ids return `not_found` before any write. Combining either
coordinate with an anchor, combining anchors, using an invalid anchor type or
resolving geometry outside the coordinate limit returns `invalid_input`.
The local put receipt for a shape, container or text gives the resolved rectangle as
`geometry` with `x`, `y`, `w` and `h` for both absolute and anchored placement.
When the put grows a container, the receipt gives its `id` and new `geometry`
in `grown_container` and describes the growth in `detail`. A committed local
arrow put reports each `from` and `to` endpoint in `detail` as its valid element
ID, `unset` for an absent or empty end, or `invalid endpoint ID` for a malformed end.
Placement stores whole points for new positions and sizes. The placed element
and an eligible container's growth commit in the same board version. Existing cards retain their position
and size as a side effect of placement, including all cards placed by hand.

Fields include an arrow's `fromSide` and `toSide` (left, right, top or
bottom). `item` resolves through `DeskState.matching` and keeps the stable
handle. `piece` is a `make:<ref>` address holding a version of an ordinary Make piece. Cards keep their
position, pointer and signatures as type `shape`, never a copied title or state. The Desk joins live item
title, number, status (which says what an open item waits on) and closure, or piece title, kind and newest
version at read time. With no shelf version, a piece card draws **Piece gone** after a fault-free
shelf read, or **Piece unavailable** when the shelf reports a fault. The unavailable card's facts
carry the shelf diagnostic. Retained shelf versions still supply card facts when the shelf reports a fault.
`table.cross {id}` closes an item card through the
same `desk.close`, with reason `Crossed off on the table`, without a board
write. Closing that item anywhere crosses its card without changing the
table's version. Only a contact's cross stores `crossed` on an item card:
the card reads as crossed by that name while the item's own state stays open.
A contact takes back a cross on an item card by crossing again only when `crossedBy`
is the contact's own identity; another hand's cross returns `not_yours` with no effects.
Taking back clears `crossed` and `crossedBy`; a closed item still reads closed and crossed.
An open uncrossed card reads open; a closed item's card reads closed and crossed.
A piece card or mark keeps its own crossing, toggled by
`table.cross`. `table.remove {id}` removes the element and its arrows.
Cross and remove also refuse an id absent from the table as `not_found`,
naming the id with no effects. An unchanged put on an existing element returns
`no_change`.
Remove wins over an edit of the removed element, and a card's arrows go with the card, on every board.

Every board change reads the newest version under Make's existing lock and
uses [Make's version append](CAPABILITIES.md#memory-knowledge-and-learning), which
clears an interrupted copy at the next version's path. A no-op lays no version.
The table keeps only its newest 200 versions and removes older files in that same locked write.
After metadata commits, a pruned-file removal failure is logged without
turning the committed version into a failed change.
New elements carry `by`, changed elements `changedBy`: `owner` for a person's
tap, otherwise `agent`; a contact's hand signs with the stable identity `peer:<contact id>`,
including `crossedBy` for an item-card cross. The face and table reading show the current
saved name: marks follow a renamed contact, and a removed contact's marks read as
"a contact no longer saved". Contact principals in any of `by`, `changedBy` or `crossedBy`
carry exact peer provenance in the table reading. The Desk's text starts with
a source notice when the board includes contact content, before the reading is cut.
Both table doors require strings for `text`, `color`, `kind`, `size`, `from`, `to`,
`fromSide`, `toSide`, `label`, `type`, `id`, `item` and `piece`, each at most 2,000 characters;
ids also keep the 1–40 letters, digits or hyphens rule. `x`, `y`, `w`, `h` and `width` are
numbers. `points` is an even array of at most 1,000 numbers. A put carrying both `item`
and `piece` is refused up front as `invalid_input`. Invalid fields are named, with no effects.
A document is at most 2 MB; `board_too_large` is a refusal with no effects before append.
Validating a card's target uses the Desk's ordinary reader, which may repair a damaged
journal tail as any Desk read does. Recording a contact's act writes the contact record,
which refreshes contact health as recording a read does.

In the window, the table's floating glass toolbar offers **Select**, **Note**, **Card**, **Pen**, **Connect**,
then **Zoom out**, the percentage, **Zoom in** and **Fit**, each button named and illustrated.
One tool is active, shown with a neutral fill, and Select is the default. The pop-out keeps the toolbar on one row.
In a narrow Desk tab, the camera controls sit below the tools in the same bar.
The Table tools and Make board zoom controls group glass locally on the board.
Reduce Transparency gives those controls the opaque house fill.
**Note** opens a new note's in-place editor centred on the board click, and Select resumes. The editor fills the card with wrapping, top-leading words;
clicks inside the card keep editing. Shift+Return inserts a line break; Return or clicking outside commits words; Escape also commits a new note's words,
while Escape on an existing note restores the previous words. An empty new note disappears immediately, puts nothing and holds nothing.
The first commit sends the new note only when words are present. New notes start at 200 × 110 board points;
every paint draws a card at the larger of its stored height and the space its
words or linked title and caption need at the current text size. The same frame
serves selection, handles, arrows, placement and Fit. Word commits save the
words and resizing saves the dimensions. Changing Text Size writes no version.
`NativeAgentShared` owns board geometry, SwiftUI painting, and pointer, touch
and Pencil gestures. The Mac supplies its palette, wheel navigation, context
menu and inline editor. The iPhone supplies touch-sized tools and a note editor
sheet. On either platform, the measured frames give VoiceOver and the keyboard
the same top-to-bottom, left-to-right order. VoiceOver announces element names,
spatial relations and contact provenance where present. It uses each element's
center to identify the smallest section containing it. It offers Open, Cross off
and Remove where available. With the board focused, Tab and Shift+Tab cycle
elements. Arrow keys nudge by 8 board points, or 24 with Shift. Return opens a
linked Desk item or the note editor, and opens a linked Make piece on the Mac.
Delete removes the selected element. Escape clears selection and lets Tab or
Shift+Tab leave the canvas. Command+0 resumes fitting the board as it changes.
Table body text starts at 22 board points and follows macOS Text
Size or iOS Dynamic Type before applying the camera scale.
Clearing an existing note edits the words and keeps the note in place.
Double-clicking empty space with Select also adds a note. **Card** opens a searchable list of open Desk items by title and number,
and ready pieces on open items by title and kind. Choosing one places a live pointer card; no handle entry is needed.
Double-click notes also centre on the click; pointer cards start at the visible centre. An occupied landing steps outward on a small grid,
avoiding existing frames and staying visible when space permits. The Card picker opens below the Card button with normal list text and roomy rows.
Table cards use opaque palette fills over a lower board ground and a hairline in both appearances; content cards never use glass.
An item card draws the live title above a caption with the Desk number and state; a piece card draws the live title above the kind.
Only the title is crossed when done or crossed; captions remain uncrossed. These readings are not stored on the card.
The Desk page supplies these choices beside the table's card facts, capped at 200.
**Connect** takes a start card, marked **Start**, then a destination card and returns to Select after placing an arrow.
Escape or clicking empty space cancels the start. With Select, hovering a card shows a dot on the nearest edge;
dragging that visible dot to another card joins them. Dragging elsewhere on a card only moves it, including onto another card.
The chosen element has an outline and, for a card or section, four corner resize handles. A small bar sits above the element when clear of the toolbar
and other elements, otherwise below when clear, otherwise above; the bar never covers the chosen element:
**Cross off**, **Connect** for a card, **Delete** to remove the element and its arrows, and **Open** for a piece's Make view.
Card colour swatches on that bar send `table.put {id, color}` through the same commit chain.
The author line appears only while an element is hovered or chosen. Each tool has a cursor and a plain-sentence help label.
**Pen**, only on the standing table, stays on until toggled off or Escape; the live line uses the same points as the saved stroke.
A Pen drag draws ink instead of moving, sizing, joining or panning; points are kept at least 2 board points apart, up to 500 points.
Every board paints saved and live strokes as smooth curves with round caps and joins; two points draw a straight line. Stored points stay unchanged.
Release sends one stroke put; reaching 500 points sends the stroke immediately and ignores the rest of the press.
A press moving less than 3 view points from the start selects the element underneath and draws nothing, including with Pen on.
Pointer hits follow drawing order. A stroke is hit where its ink is: within six view points of the line as painted.
A single-point stroke uses that point. Clicks through the empty middle of a loop reach the element underneath or the board.
A double-click on an arrow or a stroke writes nothing and adds nothing.
Toolbar writes call the door through `ToolsFacade.personTap` and draw when read.
Moving, sizing, writing, adding, drawing, joining and Delete also call that same door when the gesture ends:
an absolute `table.put` addressed by id, or `table.remove {id}`. A new card, arrow or stroke carries a hand-minted id.
On the table, an item or piece card cannot be written on by hand; other boards still open the editor.
Moving a section sends one independent put for each carried element. A join targets the element under the release point in the picture then drawn.
On Mac, the picture is the last board read with the union of fields held by hand laid over it, newest per field; a held removal hides the element.
Each gesture sends its whole absolute call, including every geometry field painted at release, without merging or subtracting fields between calls.
Calls for one element run in order, each after the previous call returns; different elements proceed independently.
The hold drops only when that element's chain is empty and a read reaches its last returned version.
The element bar's Cross off and Delete go through the same chain. A call that fails also lets go of a gesture the hand still holds on
that element, including a join from that element; the rest of that press does nothing until release.
A held removal hides the element even under a drag.
A no-change put contributes no version; with no returned version to await, an empty chain drops its hold at once.
A refusal or failure drops the element's hold, cancels the remaining calls for that element and shows the returned words,
including an ordinary `not_found` when another hand removed the element. The read shows what is.
Once an add's own returned version has been read, that hold no longer appends a missing element, even while later calls remain in flight.
Nothing queues whole boards or rebases the table. Pan, zoom and Fit remain available.
On iPhone, each element edit is signed and sent through the existing paired-phone
request channel. The Mac runs the same Table actions through the person's door.
The phone draws the committed revision from the signed Desk face. During a
gesture the phone shows a preview. The next edit waits for the Mac's reply and,
when it returns a board version, for the drawing at that version or later.
**Cancel waiting** pauses the wait. **Resume waiting** listens for the same
signed request's reply, including after reopening the Table. If the Mac replies
with an unknown outcome, **Check table** compares the requested change with
the committed element. Other elements remain editable while that change is unresolved.
A section move continues past an element the Mac refuses and names failed and unsubmitted IDs
if a reply is uncertain. A note draft stays open through Save and remains
available after a refusal, including when the Mac's stored words differ from
the text shown on iPhone.
The Desk tab, the Mac table window and the iPhone Table mount these controls.
Other pages draw read-only slices.
A Desk item with a card on the standing table can show **This item on the table**. It is a live, read-only slice of the current table,
with directly connected neighbours, enclosing regions and arrows between the included elements. It appears when the item and its
neighbours fit the slice's ID limit and the page has a free section.
A page can name exact element IDs, including a region to show what it contains, or omit IDs for an overview. Click a populated slice
to open the Mac table window fitted to those elements, or tap it to open the fitted table on iPhone. An empty table or a slice with no
matching elements displays a plain note.
At the text door, including Home, the Body joins current card facts and puts any peer provenance,
including signatures on attached arrows, before the page headings and outside
line clipping. If the Desk journal is unreadable, board marks and signatures
remain readable and linked items show that their facts are unavailable.
The leaf retains its `alt` words for unavailable board readings and older clients.
A successful table act clears the board's feedback line; a failure shows one plain sentence until the next successful act.
The agent places and moves elements with `table.put`. `make.add {ref:"table"}` is refused with the table actions named.
Ordinary board pieces keep their whole-document saves and rebasing below.
A contact admitted to read the Desk also reads the standing board with
`agent_desk {piece:"table"}`. It returns the same spatial `reading` alongside
the paged document in `text` and live card facts.
Each stroke's read-time facts include `around` alongside the stored `by`; `around` is never stored on the board.
`around` lists shape, text and container ids whose frame centers lie inside or on the stroke's bounding box:
the box is at least 24 board points wide and high, and the final point is within 24 board points of the first.
The box uses x, y plus the relative point pairs; a frame uses x, y, w, h, with text lacking w or h counted at x, y.
Open, small or incomplete strokes read `around:[]`. Arrows and strokes are excluded.
The Desk page and contact reading join the same card fields. The contact read gets piece metadata directly from Make by ref.

A piece is something the agent made, laid on an item:
`desk.add_ref {handle, ref_kind:"url", url:"make:<ref>", title?}` with the Make
ref `make.add` returned. It is stored as an ordinary url reference, so every
build reads it. `desk.add_ref` refuses `make:table` and `make:` addresses with no
version. `desk.read` returns it as that url reference, and the Desk's text
projection (`DeskPage.render`) lists it as `piece make:<ref>`. The Desk page draws
pieces under **On the table**, after what waits, and, in the opened item, shows the
newest version of each in the order it was laid. Mockups, pages and pictures stand
side by side as one canvas (sections `piece:<refId>` sharing `beside:"pieces"`;
narrow windows stack them); a document's words, a table and a whiteboard keep
the full width under them. `make.read {ref}` gives its versions and file paths and
`make.add {path, ref}` (or `{content, name, ref}` for words already in hand) lays a
new version, which the page shows without another Desk write.

A sheet (also called a table piece) is a CSV or TSV piece (`SheetTable`),
distinct from **the table**, the standing board. The window draws it as a table,
on the Desk and in Make alike, up to 100 rows by 20 columns; past that it says
how many rows and columns it leaves out and the table is changed only as a file.
A table file over 2 MB (`MakePreviewFace.wordsLimit`, the one limit make.add
uses) is not read at all and says so. **Find** marks the rows that hold the
words; **Copy** takes the table's text as it is in the file. A click on a cell
edits it in place: Return saves the whole table as the next Make version, Escape
leaves it; **Add a row** at its foot and the add-a-column button at its right
edge each save one version. Only what changed is written anew: every other field
keeps its bytes as written and every row its own line break, and an added row
ends with the file's own line break. A save is the person's own tap of
`make.add {ref, name, content}` (`ToolsFacade.personTap`, through the body's
`save_piece`), recorded on the new version as `person_edit_of`, the version it
was changed from. The body takes it only when the changed version of that ref is
a table or a whiteboard, the name is a file of the same type, the words are
within the limit and a whiteboard's words read as one; Make appends it only
while that version is still the newest, and otherwise refuses it in plain words
with nothing written. What a save said stays above the version drawn next (the
one just laid, or the newer one a refusal was for) until the person changes
something or leaves. The agent's reading of the opened item gives a table's rows
and columns and its first rows as text. A plan or project row with steps draws
a bar of its closed steps out of all of them (`meter`) beside its words.

A whiteboard is a `.board` piece (`BoardDocument`): one JSON document,
`{"board": 1, "elements": [...]}`, each element an object with a unique `id`
and a `type`: `shape` (a card: x, y, w, h, text, color, kind rounded, pill or
rect), `text` (x, y, text, size title, large, body or small), `container` (a
section: x, y, w, h, its title as text, color), `arrow` (from and to element
ids, an optional label, fromSide and toSide) and `stroke` (a pen line: x, y,
points from x and y, color, width). Colours are green, yellow, purple, blue,
peach, white and ink. The agent lays and changes a whiteboard as any piece, the
whole document each version (`make.add {content, name:"<name>.board", ref}`);
the opened item gives the agent its document as text. The window draws it as a
board, on the Desk and in Make alike (`MakeBoardView`). Ordinary board pieces keep this face: drag a card to move it
(a section carries what lies in it), its corner to size it, its edge onto
another card to join them with an arrow; double-click to write on it, or on the
empty board to add a card there, or add one in a colour from **Add a card**;
Delete takes the chosen one off, with its arrows; drag the empty board to look
around; in the pop-out, two-finger scroll or a mouse wheel also pans (in the Desk tab the same scroll moves the page). Pinch or the zoom buttons zoom from 25% to 200%, with the percentage between the buttons.
Every board opens with the same camera as **Fit**: content centered both ways with a margin, at 60% or larger, up to 100%.
If the content cannot fit at 60%, Fit centers the document's newest element at 60%.
An empty board opens at 100% with board point (0,0) at the view's center. An untouched board keeps following that fit as its
content and window change; the first press, pan or zoom holds the camera where it is, and **Fit** lets it follow again.
Ordinary toolbar cards land at the visible centre in board coordinates; table notes and pointer cards use the unoccupied placement described above.
Each change
is laid when the hand lets go, one version a change, and the fields it did not
change keep what was written, the ones the window does not draw included. The
whiteboard on the Desk holds across its versions: a newer version is drawn once
it is read, and a drag under way keeps the board it began on until the hand lets
go; the change is then made on the newest version read, and the board says when
that is a newer version than the one it was made on. A change made while
another save runs waits for it. A save Make refuses because a newer version
exists (`version_superseded`, named by the body from Make's record, nothing
written) waits for that version to be read and is made again on it; any other
failure is said as it was said and never made again, since it may have landed,
and what landed is drawn once it is read. A card or arrow added by hand gets an
id of its own (`p` and a whole UUID), so no version laid meanwhile holds it
and what the person chose or is writing on stays theirs. The Make pane draws a
whiteboard the same way, one page across its versions.

A plan is a board. An opened item with steps under it (items whose `parent` is
its handle) draws them as columns side by side, one per state and only when it
holds a step: Now, Next, Waiting, Done (sections `steps:<state>` sharing
`beside:"steps"`; narrow windows stack them). Each card is a step's title, one
line of detail and its number; its row `step:<handle>` opens the step and offers
the moves its column makes, through the Desk's own calls: **Start** is
`desk.set_status {handle, status:"now"}` (a Next or Waiting step), **Done** is
the row's `desk.close`. An open item that holds steps, or is a plan or project,
also offers **Add a step**, a form whose one field is the title of
`desk.add {parent, kind:"plan", project}`. Done shows the eight steps closed
most recently and the open columns their first 64, each footer counting the
rest, which `desk.read` lists.

An agent reads an item two ways, and neither changes the window's selection.
`desk.read {handle}` gives the item's record, its steps and what is on the
table. `app {page:"desk", item}` gives the Desk page as it draws with that item
open: its rows and actions, its board, its pieces and tables as text
(`deskItemFace`, `BodyRuntime/EngineRuntime/DeskFace.swift`). Name the item by its stable
handle, visible number (`2.1`, `desk.2.1` or `#2.1`), or exact title.
The resolver checks the full title before interpreting a number followed by
words. That numbered label resolves only if its words match the numbered
item's title, with any whitespace allowed between the number and title.
Steps move by `desk.set_status` and `desk.close`.

The agent's own upkeep (items of the `body` project, the packet's `upkeep`)
stands apart from the work. What closed today sits under **Done today**,
gathered under one **My own upkeep** row with its count; everything else is one
folded section at the end of the page, **My own upkeep**, its line counting
what is open and naming the one under way: what is open first, then what
closed on earlier days, by day. An upkeep item that waits on the person, is
flagged or blocked, or whose activity is stale or blocked stands with the work
instead. MY QUEUE items carrying a step are not board items and are not on this
page. A queue item whose step is missing stays on the board as a plain item;
the agent's board row and item header say its step is missing and to finish or
cancel it. Nothing repairs or closes it automatically.
Any saved contact with a table door reads the standing table; a contact at the table (brought there by the person, or trusted)
reads this same Desk, and the
source of any piece laid on it, through its MCP `agent_desk` tool. A trusted contact
at the table also puts signed notes and marks there, edits or removes its own
elements and crosses things off; no contact changes the Desk items themselves.
[The table](agent-communication.md#the-table) owns the gates and last-act record.
A piece is on the table while it is laid on a
board item that is not finished (`DeskPiece.onTable`). The Desk page itself shows
nothing of it.

`desk.read` lists all live board items, including parts and recently closed
items, with `limit` (default 25, 1–100), `offset` (default zero), `total`,
`count`, and `has_more`. Copy `next_read` to continue. `query` searches the
full live store. `handle` opens one exact record with paged notes and refs.
It includes list fields for parts when the item has them, and no board counts
(those come with a board read). Complete record text
uses `detail_offset` and `detail_version`.
`sort:"recent"` is the default; `sort:"stale"` orders oldest first. Sorting
changes neither the matching items nor the fields each row returns: handle,
status, summary when present, notes, refs, dates and sequencing evidence.
Rooms use the canonical returned `display_status` and continuations.

A committed mutation whose confirmation read fails reports the Desk read's
cause with `effects:occurred`; read its handle before repeating the mutation.
Equivalent creation matches kind, parent, lane, assignee, project and title
in the locked store transaction.
`desk.blocked_on` requires its `blocked_on` string and `desk.defer` its `until`
string; an explicit empty string clears, while absence or an invalid type
refuses before mutation. Direct tools, the app door and part/ability calls
judge the caller's original value; numeric values are never converted into
valid blocker or defer strings.
`desk.work_log` selects a pursuit receipt or an ordinary item's note under the
Desk store's own lock, without retrying through another tool after a failure.

The default `desk.read` includes board rows and open MY QUEUE intentions in one
paged list; `place` keeps the two distinguishable. Board counts and the open
intention count remain separate. The agent's Desk page shows the same queue
with each intention's name, words, filing time and outstanding waits.
[Intentions](INTENTIONS.md#their-words-for-it) owns that readout.

With `include_archived:true`, `archives` contains its own paged `items`,
`limit`, `offset`, `total`, `count`, and `has_more`. Its initial offset is the
ordinary `offset`. Use `next_archive_read` to continue with the separate
`archived_offset`. Archive reads decode every record and link or report why
the history is unavailable and how to repair it.

The snooze choices are **Defer to tomorrow** and **Defer a week**. Deferring a
one-time MY QUEUE step (`at`) without a habit moves its scheduled moment and
clears any prior hold. Rhythms and other conditions are held until the defer ends.
A bare defer day means the start of that local day. A full timestamp keeps its
exact instant, including fractional seconds. **Unpark** clears a hold with an
empty `until` and leaves the scheduled moment where it is.

`desk.add` takes an optional `summary`. `desk.close` takes `reason`, the same word
`queue.done` and `queue.drop` take. For `desk.close`, reason names the owner's
explicit instruction or the fresh canonical commit/receipt/observed result
proving the tracked outcome; the instruction alone suffices without claiming
the underlying work happened. Closing an item that is already closed changes
nothing: it answers ok with `already` naming its status, its recorded outcome
stands, and a batch goes on. `queue.done` uses reason for why the step is done.
The shared door records any unique declared interpretation of another supplied
name. Wait explanations use `note`.
Desk actions keep `handle`, queue actions keep `id`, and page reads keep `item`;
the shared door binds a single alternative address word to the schema's sole
declared one when that declared field is absent, before validation and Trust.

`desk.wait {handle, on:"owner", note?}` puts an item in **waiting on owner** in
one call. Exact supported owner names (`"owner"`, `"user"`, `"human"`, or the
owner's configured exact full or first name from `memory/profile.json`) resolve
to canonical `"owner"` at the write boundary. `on` given as a descriptive
sentence (what has to happen, in the agent's words — including sentences that
begin with the owner's name) is kept as written: **waiting on <those words>**
and does not enter owner attention; only one unbroken unknown token that is not
a plain name is refused, as an identifier that names nothing. Passive presence
and message triggers (`when_user_away`, `when_user_here`, `when_user_messages`)
are typed `MyQueue.When` steps via `queue.add` and do not enter owner attention.
`desk.set_status {handle, status:"waiting on owner"}` (and exact supported owner
names) reaches the same writer.
Waiting status updates apply `remaining_work`, `progress`, `assignee`, and
`lane_of` through the ordinary status path before confirming. Supply the
coordinating item's stable handle or visible alias for `lane_of`. Invalid
fields are refused by name. An explicit `waiting_on` must agree with the status
text.
The existing persisted blocked status and `waitingOn` field hold this state;
readers present it as `waiting on <person>`. No stored items are rewritten;
`OwnerAttentionPolicy.waitsOnOwner` matches canonical `"owner"` and existing
persisted exact owner-name waits (whole trimmed string, never a first-word
prefix) to contribute to the page's waiting-on-owner count. Changing the status
clears that person wait.

Desk stores eight states: `watch`, `flag`, `now`, `next`, `todo`, `done`, `blocked`
and `canceled`. Only `done` and `canceled` are terminal.
Every newly created item starts at `watch` (displayed as "watching"), including
one whose `kind` is `plan`; kind and work state are separate. The store's
`createItem` reduction owns that default. The textual board uses the kind as
the status token for a top-level item still at `watch`, so a new plan reads
`plan` there while its structured status remains `watch`.

`on` also accepts an observed Desk handle/number or experience id (a card,
including the `approval:<id>` its Home row shows, message, reply delivery or repair), or a nonempty list of those dependency
ids. These waits retain automatic release when the named conditions settle.
A parent can wait for several descendants. Each named descendant, the work
beneath it and the work it waits on can proceed according to their own
dependencies. Unrelated descendant work waits for the parent to clear. An item
needs its waits and its unfinished children, so a wait that closes a cycle in
what items need (a descendant waiting on its own ancestor) is refused. The parent's waits outside its subtree still hold all
descendants, as do its explicit blocks, person waits and deferrals.
A send to a contact that still awaits its answer returns that condition as
`thread.wait_on`: waiting on it holds the item until the contact answers (or the
send fails or expires), which is the way to be told when someone replies. A send
held for a contact that collects its messages returns no `wait_on`: its answer
comes as a message of its own, which nothing yet ties to the send.
The wait action has its own typed guide. Unknown identifier-shaped conditions
are refused; a single person's name is a person wait. `note` explains either
kind of wait.

A single conversation id also names a wait, whether it belongs to a saved chat
session or an agent conversation. `desk.wait` uses the same exact agent-conversation
resolver as `agent.read` (record id, protocol conversation id or contact-session id)
and conversation page item reads. It checks chat identities in the session
index rather than guessing from a transcript filename. An unavailable identity owner is reported unless the other
owner positively resolves that conversation. This is a durable waiting status,
not a blocking tool call: if no message comes, the item stays waiting until its
status is changed.

The **Replies owed** finding counts the completion delivery owner's `owed` and
`sent_unconfirmed` records. Its `reply_delivery` refs name the exact ids accepted
by `repair.let_go {id, reason}`. Release consults that delivery owner under its
lock, even before the advisory experience projection arrives; the finding's
next reconciliation reads the saved release and removes that reply from its count.
Marking the finding done or canceled changes only its Desk status; it does not
let go of a reply. A done or canceled item's room header adds one `still owed`
clause from the open experience projection when an obligation names its handle as repair
owner, carries `desk` evidence for that handle, or matches a `reply_delivery`
ref. The clause clips one experience's words (and recorded obligation names and
destinations), with `+N more` for other experiences. Nonterminal items and items
without matching open obligations get no clause. An unreadable projection
shows a gap, never an empty obligation verdict. A loop finding with replies still
owed or failed before an answer reopens as Watching on refile, with its owed or
failed summary and refs.
An ordinary step's `promiseCaptures` identify captured promises and its
`replyRoute` preserves origin; neither identifies an outstanding reply delivery.

The Desk page lists each item under one heading. It reads top to bottom: Desk tools;
Waiting and Needs you; On the table; the standing table when it has elements; Now, Watching, Queued;
an empty standing table folded below live work; Parked; then the readings, Done today, recent work, lines, Finished history,
the timers and the night; and last My own upkeep. `desk.wait` puts an item under Waiting.
Input mistakes, including unknown handles, return `invalid_input`,
the argument path, and `effects:"none"` rather than a blocked dispatch error.

For a four-call work record (using the handle returned by the first call):

1. `desk.add {kind:"plan", project:"Example", title:"Review the draft", summary:"Two review steps"}`
2. `desk.note {handle, text:"1. Read the draft.\n2. Record the requested changes."}`
3. `desk.wait {handle, on:"User", note:"Awaiting the decision"}`
4. `desk.close {handle, reason:"User asked to close this record"}`

These are action argument shapes for `app {action:"desk.…", args:{…}}`.
Recorded notes and summaries are records, not proof of external work.

On Mac, **New task** or the Shortcuts intent creates a Desk item and starts
a [line of theirs](agent-communication.md#jobs) with `desk:` set to that item
(`NativeAgentEngine.submitDeskTask`, `BodyRuntime/EngineRuntime/EngineDesk.swift`). The
line's ending is a `returned` happening with no conversation route, so it opens a
thought in the agent's mind stream, where the agent settles the item
(`AgentJobStem.swift`). On iPhone, ask for a Desk task in Chat.
A job that carries a Desk item is that item's movement: Desk activity, the live
strip, the widget's **Working on…** line and the phone's `desk.json` evidence
come from their jobs (`DeskMovementPresentation.evidence`,
`BodyRuntime/EngineRuntime/DeskActivityPresentation.swift`), and the Work overview's
execution rows are their jobs.
The widget's working line carries only the redacted job name, capped at 240
characters, rather than its brief. Every Work overview row redacts title,
summary, detail, state and location before display bounds are applied; the
phone receives these same redacted rows.
