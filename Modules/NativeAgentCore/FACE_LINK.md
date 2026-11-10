# Body face boundary

`NativeAgentEngine.faceActs` is the root's `FaceActHandler`. `EngineFaceActs`
dispatches Core commands to their owners. `BodyChatCommands` supplies the Mac
turn port without a window model. Decisions and readbacks use owner results;
the dispatcher never reads a `FaceSlot`.

The body app supplies its platform adapter with `installPlatform`. That adapter
implements `FaceActHandler` and executes app-owned services, including transcript
reader assembly, protected entry, OAuth, permissions, speech and process lifetime.
An absent adapter throws `body_adapter_unavailable`; there is no in-process
window route behind that failure.

`restoreConversation` joins the body's existing startup selection transaction,
then admits its selected conversation through `BodyChatCommands`. The copied
window commits that returned identity only while its initial selection is still
current. It does not observe an empty conversation id. Composer demands hold
`ProvidersFacade.observeSession` independently for each mounted composer;
unobserve and disconnect cancel and join that reader. Generic settings reads
do not substitute for the per-session routing/context presentation.

Conversation selection reuses the transcript owner's current rows unless an
import changed them. The platform retains one store watcher per visited session
for the connection, so closing a press reader does not leave its cached rows
unwatched. Observation and reader opening also reuse current rows; the opening
viewport reaches the press before Inbox and attachment projection. Disconnect
cancels and joins the store watchers independently of mounted readers.

The connection owner creates a sink with `engine.face.attachSink()`, then passes
its epoch and correlated call closure to `attachRenderer(sink:call:)`.
`frameApplied` must name that sink. `detachRenderer()` detaches the feed first,
cancels and joins presentation subscriptions, and reports release failures. It
does not stop a turn. The connection owns cancellation of pending `FaceCall`
requests; the engine holds only the typed call closure.

Failed acts, including applied-frame validation, return their correlated failure
without closing the link. Act cancellation stops execution; its terminal reply
runs through `settle` with unknown effects preserved. EOF, malformed framing or
envelope correlation, pipe failure and owner shutdown end the connection.
The body and face share `diagnostics/FaceLink.log`, with PID and role on each
line. The record is the recent past: the write that takes it past 32 MiB copies it
to `diagnostics/FaceLink.previous.log` (replacing the earlier one) and truncates it,
under a lock every write shares, so no line is lost or lands in the copy. Body
failures retain code, message and cause; disconnect records precede cleanup.
Frame receipts name epoch, sequence and barriers, and cancellation records name
their target request. Failure details are credential-redacted.
The face draws failed automatic receipts in its inline window status without tearing
down its feed. Refresh and observation cancellation caused by a departing view
settles without status or toast feedback. Active observation failures appear in
that view. Refresh toasts belong only to explicit person requests held by a
mounted view task; arrival refreshes draw active failures in inline window
status, cleared by navigation or the person's dismissal.
Browser, update, Settings navigation and shared preference edits run in arrival
order in the main scene task. Each active failure has its own dismissible inline
explanation; closing that scene cancels the held command and releases queued
requests silently. The command owner and its feedback sit outside preference
availability, so an invalid root setting cannot prevent its Use default command
or hide its failure. Preference writes and Settings navigation require the
committed reply, including any independent publication failure. Other receipt
consumers retain committed effects separately from publication.
Window commands open the main window, including from a remaining detached
conversation. Preference edits open it only when its navigation is unmounted;
an existing scene handles them without taking focus. Each scene task captures
its own request before scheduling and consumes only that id.
The tour uses Advanced locally while its overlay exists; it neither writes nor
restores the person's saved view mode on teardown. Simple's More settings uses
the checked Settings navigation command.

Native composer model, thinking, Fast, Trust and hand-back requests run in arrival
order in their visible conversation's view task. Leaving the conversation or its
page, or closing the view, clears queued controls and confirmation, cancels held
work and suppresses departed-view feedback. Active failures keep individual
dismissible explanations. Model choices use a freshly checked baseline, skip an
unchanged choice and hold Send from local admission through settlement. Full Mac
confirmation retains its opening conversation. Hand-back checks the driver's
acknowledgement rather than expecting a stored mutation receipt.

Panel refresh acts use the sidebar's canonical panel names. Providers and
Connectors call their checked owners directly; failures retain that operation's
cause. Other panel receipts name their own failed endpoints, never another
operation's mutable window status. A successful receipt is acknowledged.

Each Core presentation key has one producer task shared by its observation ids.
The last `unobserve` cancels and joins that producer. New subscribers cannot join
a producer still releasing its final reader. Platform observation setup is held
as a task before suspension, so disconnect joins setup before releasing it.
There is no timeout, polling or automatic replay.

`EngineFaceProjection` supplies layout, graph, dream diary/entry, mood, run
history/detail, contacts and helpers. It copies owner state on
the owner's actor and assembles Shared values off main. Graph neighborhoods have
entity-keyed slots derived from the canonical graph snapshot; whole-graph updates
cannot replace a detail slot. Missing entities and failed storage stay explicit.
Inspector Live and Replay observations hold readers on the engine's existing
`TurnInspectorFeed`. The last observation releases its reader without stopping
the shared trace owner. Replay readers do not publish Live slots. Cards carry
the owner's actual vnode-observation health, independently of act admission.
Both Mac windows draw the controls and cards through `FaceView`. Each card
retains its selected feed value; its event collection reads at most 256 rows
per continuation, and expanding an event holds its shared document demand.
Long evidence uses the shared TextKit reader rather than a row's text label.
These demands read the held Inspector value and start no trace subscription.
The renderer serializes selection, reverse rearm and closure through one held
view lifetime, joining release before admitting a new reader. Reverse
health/rearm calls describe the held view, mounted subscription and supplied
source health. A failed subscription remains a mounted, failed view. Offscreen
Inspector drawing starts no reader. `BodyFaceDoctor` measures the original
Inspector and the attached renderer through `AppDoctorPort`, including Doctor
page-row actions. It checks the canonical trace observer independently of the
renderer report. Read failures remain failed health, never a closed Inspector.
Repair makes one attempt to re-arm the shared engine file observer, then checks
each window independently. An inactive observer stops that repair before
subscription replacement. A later subscription-call failure retains the known
source and main-window receipts. Repair names the exact renderer connection,
view and subscription. Changed selections refuse; a replacement subscription
without confirmed source health remains unverified. Disconnect removes that
connection's Doctor target without closing the body's Inspector.
Agent-view room observations use `TurnsFacade.readAgentScreen` with room/session
keys. Workspace, ability and source-file events refresh redacted read-only text;
watch failure stays unavailable. Home keeps its existing page face.
Waiting and unavailable states are explicit. `EngineFaceMindProjection` holds
independent cognition and context-health producers and supplies memory
diagnostics. Cognition events refresh frozen detail. `NativeContextFlowRuntime`
owns one payload-free health event source shared with its coordinator, source
registry and arena; it survives coordinator replacement. Lifecycle, source count,
reconciliation, feedback, generation, pressure and lease edges refresh health
through `CognitionViewFacade`'s existing `LatestRead`. Arena signals follow lock
release. Subscription precedes the initial read, and final release cancels and
joins the producer. Explicit refresh and context-mode readbacks use the same
health owner. Context events do not read cognition. Memory counts follow
SQLite/WAL events, and embedding state follows the managed runtime;
source-opening errors remain visible.
`EngineFaceContextProjection` supplies the composer's Context receipt through
the existing trace and provider readers. Turn-completion, provider-usage,
disclosure-file and routing events refresh the mounted session; the last reader cancels and
joins observation. Receipt rows retain measured shares, provenance and unknown
coverage. The saved disclosure is credential-redacted; its missing or unreadable
source has its own visible row and cannot become disclosed context.
The disclosure control also opens that source's missing/unavailable explanation.
Streaming trace writes do not reread the receipt. Source-watch failure publishes
Inspector health immediately, independently of a pending evidence read.
Onboarding's `start` act supplies its finished overview alongside the durable
disposition. The wizard needs no presentation subscription or observation-triggered
setup reconciliation. The identity editor reads that same finished disposition;
opening its sheet starts no onboarding observation or setup reconciliation.
The Inspector uses the existing cutoff/day keys; there is
no separate query demand or query control.
`EngineFaceWorkProjection` reads Desk diagnostics and work detail from the retained
Desk revision, preserving each source's read failure. Make membership and version
selection use the engine's existing shelf; version previews use checked metadata,
read-only resource grants, file events and the shelf's canonical title projection.
The Sense presentation follows its existing registry/news owner and carries an
identity for the exact current view. Events recheck that identity and enabled
version before reaching the Sense runner. Registry failure withholds the view.
Desk search uses the canonical parser and fuzzy ranking against active items in
the retained revision. Its query stays bound to the view's observation. Close
carries the shown update stamp through the gated compare-and-set tool; note and
park commands use the face's own presentation. Failed tool outcomes keep note
drafts open and cannot become committed changes.
Click and Return carry the rendered row's command snapshot, so a feed update
cannot retarget an already displayed Close.
Run detail reads the complete canonical ledger; the history
list's 200-row limit cannot prove a requested run absent. Run contents pass
through the credential redactor before entering `RunFace`.

Checked command results retain their scope:

- Layout folding returns the writer's result. An identical fold makes no disk
  write; an invalid block or write failure returns its cause.
- Stop cancels through the Mac turn owner and replies after that owner's marker
  write completes or fails. A saved Stop request is not a terminal turn claim.
- Retry returns refusal or its exact admitted identity and observed phase;
  missing terminal evidence remains unknown.
- Memory search returns its own `LatestRead` result, independently of later
  searches. A short query returns no performed search, not an empty result set.
- Persona profile save returns the committed profile and any independent
  document-refresh issue. It does not reread another save's profile.
- Shared conversation-anchor failure accompanies the accepted conversation in
  `CommittedResult.publicationFailure`.
- Session selection keeps the existing `activeChatSessionId` key; an empty
  selection removes that key.

This source unit is not the completed stage-(c) process split. The app's
`AppQuietSettingsHost`, `AppQuietToolHost`, composer/session presentation ports
and several app-specific services still depend on the mounted `AppModel`.
`NativeAgentApp.prepare` installs `BodySettingsActHandler` before mounting its
existing window. `BodyFaceTranscripts`, `BodyFaceVoice` and `BodyFaceServices`
supply transcript readers, speech/capture, resource grants, contacts, graph
sweeps, image regeneration through Desk's gated tool router and selected Desk operations.
Search and Agent-room projections use their canonical owners. The copied Chat
capsule's `inboxAction` uses reverse calls for its navigation and draft effects,
through the existing Inbox transaction. `prepareChatDraft` awaits creation when
there is no selected conversation and returns an applied composer edit; existing
text refuses the edit and all attachments are retained. Desk reply drafts use
that same renderer operation. Refusal, conflict and cancellation leave the Inbox
read marker to its transaction, which writes it only after presentation succeeds.
The duplicate body-window presenter is absent; the original window keeps its
own Inbox effects. Generic quiet commands bind scene, detached conversations,
composer reads and edit receipts to the originating connection. Their shared
session fences consume that window's selection without changing the body's
selection. Model and session writes keep their existing canonical owners.
Work pane closure checks carry the caller's turn rather than the selected
conversation's turn. Copied pane visibility lives in that window's UI defaults;
show/hide receipts read it without changing the body's visibility preference.
Connector folder grants are checked before the workspace transaction; setup
cards retain the copied conversation. Sparkle's body updater sends its user-driver
events to the requesting face, whose native driver returns operation-bound
actions. A disconnected window cannot retarget that interaction.
The Settings data-limits action opens the reference at the renderer bundle's
resource root. A missing reference or refused macOS open returns its own failure.

Cross-process pointer input holds acknowledged preparation, routing and release
through the connection-bound motor owner; installed proof remains owed.

`EngineFaceMacControlProjection` observes the canonical driver and Trust owners.
Every physical takeover advances and publishes the driver generation, including
input while the person already holds control, so the drawn hand-back remains current.
Mac-control read failures stay unavailable in the value. Composer and Shotgun
hand-back controls require a person-origin activation using the same Shared event
classifier as body input. They capture the delivered driver generation at that tap;
`handBackMacControl` acknowledges only a matching generation actually granted by
`MacAttentionSessionStore`. Changed authority and unavailable observation refuse.
These controls do not emit pointer input or change Trust.
The visible Shotgun panel holds its own Mac-control observation independently of
the main Chat page; hiding it releases that reader.

Transcript dimensions and visible paragraph membership are separate events.
`resizeTranscriptReader` carries changed width, height or scale; a viewport receipt
updates paragraph priority without pretending the window resized. Both stay on
the reader's ordered command chain. Link records name reader, script and base
identities, and the settings frame's mounted composer identities, without words
or provider credentials.

Offscreen native captures prepare page, graph, dream, cognition and Inspector
values through their canonical readers before flushing the connection's frame.
Capture does not depend on a mounted view starting observations. Diagnostic run
navigation validates and redacts the canonical ledger record before exposing its
native detail destination. Work pane capture carries the selected pane and
version-bound Make/Sense values. Native preview completion supplies the bitmap;
changed selections refuse, waiting stays waiting and Sense events perform no
action during a capture. Scoped resources and native readers settle on every
exit. Installed comparison remains required.

`BodyFacePalette` holds connection-owned search observations. The canonical
inventory, conversation ranks, transcript index and saved-result readers supply
finished rows with typed navigation targets and individual source failures.
Unreadable transcripts keep their causes instead of becoming empty documents.
Settings navigation reads helper and connected-agent identities off main, then
uses the same row factories as the settings registry. The copied renderer holds
no search index, settings loader or matching cache. Query replacement joins
release before admission; Return waits for its typed query and a click retains
the target drawn with its row. Generic copied observation lifetimes also join
release, including when admission fails or the view closes during setup.
Chat, detached conversations, Shotgun, context receipts and dictation use that
same mounted lifetime. Changing session joins release before another admission;
offscreen drawing starts no observation. The composer waits for a chosen
conversation before observing its provider presentation. Failed startup selection
draws its cause and an explicit reopen control. Active admission or release
failures draw in their mounted view; a departing view's cancellation stays silent.
The body registers conversation observation before starting its transcript read.
The held reader publishes a failed initial read through the conversation slot
and keeps observing the canonical source for an explicit reread.
Personality's own Name/document and Dream diary links select the copied native
editor or diary destination. They do not request a page-item document body.
The conversation column uses the canonical view-keyed session search instead
of global palette results. Its title/preview matching, section membership and
navigation failures keep their existing owners; cancellation joins reader removal.

Make export checks the originating conversation and selected shelf version.
It uses the canonical project destination/name policy before asking the face
for SavePanel selection. An existing work/prompt file requires confirmation.
A chosen export supplies a writable parent-directory grant and one filename;
the body preserves separate work/prompt outcomes. No export runs after a failed
index or metadata read.

Contact and helper thread slots read the canonical contact owner's published
history and live flights. Finished rows retain source failures, partial replies,
delivery receipts, restrictions and record-bound Stop/resend commands. Contact
documents use transient system messages through the existing press; copy, Find,
speech and message data do not read a synthetic chat file. These rows never
claim a first-visible resident reply. Contact states publish through the shared
per-session `LatestRead` and outbox; message actions preserve source failures.
Helper history reads the contact owner's checked result snapshot, excluding
results already represented in the thread. The helper detail
reader publishes its full saved reply and returns bot/session identities for
acknowledged conversation selection. Last-reader release cancels and joins the
connection's observations and press work; sends remain with their real owners.

Observatory commands reach the resident cognition runtime. Manual work returns
its completed, skipped or failed outcome; a partial Clear or continuity save
failure retains its known effects. Configuration controls avoid identical
writes. Body rows preserve off, stale, invalid and absent evidence and project
the live provider belief explicitly. The persistence encoder does not define
the presentation. Rejected memory documents read rejected proposals by id;
active memories and proposal documents use their canonical readers. Document
text is credential-redacted before either feed or act publication.

Transcript geometry carries the laid-out viewport ids through subsequent press
updates. The body checks each applied script receipt; a first-visible reply
additionally names its reader, conversation, message and turn. Only an actual
draw in a visible active face reports it, and the body correlates its current
reply with the single-claim turn-render registry. Reader admission is reserved
before store reads and cannot outlive cancelled setup. Inbox publications update
attachment cards independently of streamed text; secure entry mounts only
after the window-protection receipt.
Protected card answers remain held by the mounted entry view through their checked
reply or caller cancellation. Active failures draw dismissible feedback there, with
submitted secrets and credentials redacted. Explicit Cancel retains the admission
hold until the client request settles. Entry closure or card/session replacement
cancels work and suppresses departed-view feedback. A revision published for the
same card does not cancel its answer. Setup return verification is held by the
mounted main, detached or Shotgun host and checks only that conversation's pending
controls. Page return, that host becoming key, setup dismissal and Simple setup
settings changes enqueue checked requests in arrival order. Active failures draw
credential-redacted, dismissible feedback in that host. Cancel, departure or a
different conversation cancels held work and clears queued verification; the next
request joins the previous operation before admission. Departed-host feedback is
discarded. A reverse control close does not hide the verification's correlated
failure or admit a replacement control. The body retains answer admission,
verification and verified-control settlement.
Per-session `LatestRead` and an ordered outbox serialize conversation
publications, including failures, across concurrent readers and resource reads.

The immutable slash registry and recognition live in NativeAgentShared, with
body-window execution in Dispatcher. The copied window presents locally and
sends typed conversation, provider, memory, note and scratch acts. Its persona
preference adapter notifies ContextFlow. `openBrowser` reaches the body's
existing browser window and WebKit owner.
Think and Fast carry an explicit field edit; their routing transactions do not
pin an inherited model or account or write the other control.

The renderer process mounts its views and reverse-call hosts from
`Sources/NativeAgentFace`, and it is the only window. Attachment installs the call closure before admission; disconnect joins
renderer-owned readers and captures while leaving turns alone. Capture and
keyboard protection aggregate local windows with per-epoch renderer groups;
credential entry awaits the body's exclusion receipt before drawing secrets.
The body keeps its existing in-process window and owners throughout assembly.

No saved format, phone packet or ability argument changes. There is no one-time
data move. The release lead performs the single build, installation and bounded
installed checks for the assembled phase.


Copied page taps carry their renderer connection on `FacePresentationPart` of
the admitted turn. Copied chat sends carry the same part into their tool calls.
`AppToolExecutor` binds an invocation's quiet host and presentation port without
replacing catalog, authority or receipt owners. `BodyFacePresentation` checks
that exact connection for reverse calls. Page images await its applied-frame
barrier, draw in the face and save through the body's artifact owner off main.
Scene reports supply the copied selection and mounted composer; Inspector
reports feed Doctor's connection-bound health owner. Native notification
responses retain the originating renderer and use the canonical engine action
owner. Original-window calls retain their in-process bindings.

Quiet composer/session presentation and connector hosts use the originating
connection; the original window retains its in-process hosts. The face links
Sparkle for its native user driver, while the body alone owns the updater,
download, verification and installation. Native callbacks name their exact
operation and cannot answer a replacement interaction. Installed checks remain
required for presentation acceptance.

Offscreen transcripts consume the capture caller's prepared reader. They open
no live reader and send no applied, painted or interaction receipts; the body
capture owner releases that reader through settlement. A changed conversation
without the prepared reader refuses capture before drawing. A turn's renderer
binding does not require a live window for domain-only tools; connection checks
belong to the requested presentation.
