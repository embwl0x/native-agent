# NativeAgent user and agent guide

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

Start with a conversation. Connect services and grant access as the work needs
them.

## First setup

1. On macOS 26 or newer, download the DMG from the
   [releases page](https://github.com/embwl0x/native-agent/releases), drag
   NativeAgent to Applications, and open it.
2. Enter your name and the agent's name.
3. Connect an AI account or add an API key. You can skip this step and connect
   later in **Providers**, but chat needs a connected account.

First-run setup opens only after a successful eligibility read. A read failure
shows its cause and a **Retry** action; it does not automatically retry or
assume that setup is needed.
Setup reports a missing app model instead of aborting. Name suggestions do not
depend on narrowing the system clock to an integer. An empty tour has no current
stop and completes without indexing a missing step.

### Simple, Advanced and Agent

- **Simple** presents chat, the agent's contacts and its helpers. Ask the agent
  to configure the app. The panel's gear offers appearance controls and
  **More settings…**, which opens Settings in Advanced.
- **Advanced** exposes the pages below.
- **Agent** shows the agent's own desktop read-only.

An absent view preference starts in Simple, independently of saved chats.
A saved supported choice is preserved. Page names in this guide refer to Advanced.
The shell restores its current page and each rail page's current tab directly;
startup does not translate the retired Skills & Tools scene section.
Command search opens the exact selected helper reply, dream date or memory.
Unavailable selected content reports that state rather than opening a different item.
The `simple_settings_menu` page screenshot draws the same Settings items
above the sidebar's gear; offscreen capture does not open a native menu window.
Rail screenshots derive their tab selection without changing remembered tabs;
hidden-tab reconciliation and the legacy Trust tab migration run on live pages.
Screenshot height rejects nonfinite or invalid input before rendering. Status
uptime and contact elapsed time say unavailable when their values cannot be
represented; an invalid toast duration leaves a visible auto-dismiss error.

Providers is one shared face: **Chat**, **Work**, **Mind**, **Accounts**, and **Catalog**.
Each group's **Model** offers an **Account · Model** choice from eligible accounts.
Choosing one uses that model's declared thinking default and turns Fast off;
then **Thinking** and **Fast** appear only where that model supports them.
The page's sentence names Chat's model and account and the groups that differ.
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
and the daily hour. Changing its model keeps the group's Think level. An
unsupported Think level or Fast choice is reported so you can choose a supported
control; the app does not silently change either setting.
Changing its provider leaves **Choose model** until you select a model. An
account sheet also leaves an absent default unresolved instead of selecting the
first model. A missing or unoffered saved sign-in method requires an explicit
current method before Save; it is never replaced automatically by the picker.

ChatGPT, Codex, Moonshot and OpenRouter use their own fetched model catalogs.
A missing, unreadable, out-of-date or failed refresh leaves a fetched catalog unavailable with its cause and a refresh
instruction. It supplies no shipped replacement models, windows or capabilities.
ChatGPT and Codex read the catalog beside their selected sign-in; they do not
borrow the independent CLI's catalog. Provider configuration and picker files
use the current object fields and surface names only. API-key and xAI token
metadata use Keychain references; a credential read failure stays unavailable
and names the storage repair instead of claiming the account was signed out.
This includes an adopted Codex CLI credential: unreadable or malformed saved
credentials name their file and repair; only a confirmed missing file means sign in.
Fetched API-key model lists belong to the credential that fetched them; changing
the credential requires a matching refresh before those rows can be used.
Moonshot models whose reasoning contract is unknown say so on their row and
cannot be selected until NativeAgent has a declared adapter contract.
credentials name their file and repair. A valid CLI API-key file without a ChatGPT
access token offers no ChatGPT session to adopt. Credential files may be symlinks;
renewal updates their target and retains the link. A failed shared CLI inspection
after sign-out is reported separately from the completed app credential removal.
**Test the connection** checks saved ChatGPT, Anthropic direct and xAI sign-ins
through their native routes. Methods without a native probe explicitly say
they were not checked. A saved check belongs to the credential actually sent;
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
Accounts shows each connection's authentication words, checked status and **Test the connection**
and **Disconnect** actions. An unconnected account's **Add key** or **Sign in** raises its
protected conversation card; Anthropic's card also accepts a setup token. No secret is entered
on the face. The Codex CLI offer keeps **Use it**, **Ignore**, and confirmed consent repair.
**Catalog → Models → Refresh** shows whether the model lists are fresh, cached, partial or unavailable.
Connection checks and catalog refreshes show that they are running and publish their result when they end.
An unavailable account or catalog reports its cause on that account; other accounts remain usable.
The onboarding connection sheet and its sign-in controls remain available.
OpenRouter's thinking choices come from its model metadata, including mandatory
reasoning and models with no effort selector. Provider default omits the optional
reasoning control; it does not guess an effort. Refresh Models reads that metadata;
helpers and saved choices use the same catalog.

## Settings

Ask your agent for any setting in plain words: “use the dark appearance”,
“change the Shotgun shortcut”, “turn on meaning-based memory”, or “make my
iPhone appearance light”. The agent reads `setting.get` for the current
value, kind and accepted choices, then uses `setting.set`, quoting your request
in `because`. `app {page:"settings"}` lists Mac controls; provider defaults
are on `providers`. Credentials and sign-ins stay in their secure Settings
sheets: `setting.get` on `providers.credentials` or `telegram.credentials`
names the page, never a secret.

The Mac Settings page, its setup sheets and the agent's page reading now share
one face built from that registry. Switches and choices save through the same
setting owner as `setting.set`; an unreadable row keeps its cause while the
other controls remain available. Runtime status, update checks, the tour,
data limits and build identity remain on the page. The reflection allowance
is shown as a value that opens its existing Cognition editor. The shared face
has no text or numeric entry field; `setting.set` remains available for those
values. A meaning-based memory change still rebuilds the index; its switch
does not have a separate confirmation sheet in the shared face.

If a setting's owner cannot be read, that setting reports unavailable with
the cause and repair. An unreadable provider configuration is never an empty
saved default model; an unreadable embeddings configuration is never an on/off
answer. Other readable settings remain available. Only genuinely unset
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
choose Off or Active explicitly to replace an invalid value. An invalid
`NATIVE_AGENT_CONTEXT_FLOW_MODE` override likewise reports its error.
An explicit `page.show` from Simple or Agent
view settles its destination in Advanced view. Ordinary chat entry through the
global hotkey or a message notification keeps the person's saved view.
Today and the sidebar badge share one ordered freshness receipt for approvals,
inbox and memory proposals; an older completed refresh cannot replace a newer
published result. Duplicate launches report whether macOS accepted activation,
refused it, or did not return within 2.5 seconds. If the resident exited during
that wait and no other instance remains, the new launch continues. An unavailable
activation result does not diagnose a system wedge.
Quiet Today reads and offscreen Trust rendering do not publish work
notifications or synchronize preferences. Today reads use the existing
projection without refreshing live approval/inbox owners. Trust policy reads
do not run the effects reserved for committed policy changes, even when the
visible Trust page is also open.
Backup and restore replies carry the command's own result, independently of
the app's activity status line.

For phone-local preferences, open NativeAgent on the paired phone. Read
`setting.get` with `setting:"phone.settings"` for its current directory, then
use the returned ids with the same `setting.get` / `setting.set` actions.
Every request to the phone, including settings reads and changes, requires
**Trust → Mac → Apps and features → iPhone Notifications → Write**. Turning
that switch off blocks these requests even under Full Mac.
Appearance, haze, Live Activities, each phone sense and saved place switches
use their phone owners. Enabling sharing or Lock Screen task names asks on
the phone's approval sheet; iOS permission prompts still need your answer.
Reads wait up to 20 seconds and changes up to 60 seconds. A timeout leaves the
outcome unconfirmed: reopen the phone app and read before repeating a change.
Requested inspection includes saved place names and switches, including disabled
places; coordinates remain on the phone. The request channel requires exactly one paired phone; it cannot select among
several phones. Saving a new current location and deleting saved places still
use **iPhone Settings → Places**, where coordinates remain local. Pairing and
connection repair also remain device setup actions.

Trust raises, app Write switches, macOS privacy grants and admission to Full
Mac retain their existing approval controls. Ask the agent to help with those;
the person's approval remains the step that grants access. Lowering keeps the
existing lower-only rules.

### Optional background and memory settings

In **Settings**, **An inner life** controls the inner-life master setting,
and **Memory in every reply** selects Active or Off for Fluid Context.
The memory controls also cover dreams and meaning-based recall.
Use **Diagnostics → Cognition** to inspect the current state.

If the requested semantic model cannot load, Settings reports semantic recall
as unavailable with the embedding owner's cause and Doctor remedy. It does
not promise a word-search replacement for failed semantic recall.

Memories shows one shared face: pinned and recent saved memories, proposals
waiting for review, and read-only rejected history. Each saved row opens its
full text and offers pinning or forgetting; forgetting asks once. The full-text
sheet can prepare a correction draft in Chat. **Knowledge graph** opens the
native Mac canvas from a row rather than a page tab.

Search from `/memory [thing]` (at least three characters), or use command search
to open a saved memory. The page has no inline search field. A failed
meaning-based query shows its owner's cause; retained results identify the
query that produced them. Store changes refresh the results even when the page
is closed; **Check again** retries the query. **Show all memories** clears it.
Knowledge graph time filters refresh at their next entity expiry while mounted,
and re-evaluate when the system clock, time zone or calendar changes.

The **Memory status and Spotlight** row opens the existing Mac upkeep panel,
including the search model, Spotlight reindexing and **Check again**. The bulk
**Consolidate now** and **Run hygiene** controls and their report are retired.
Old memories fade from recall through disuse. Records can also be removed when
you ask to forget them or when the store exceeds its capacity (2,000 rows by
default): lower-value records go first, then the least recently used; pinned
and identity records go last. See [Data bounds](data-bounds.md).

Remembered context and inner state do not grant action authority. Trust remains
the owner of permissions.

While a tint-enabled window is visible, mood input follows cognition changes.
The room keeps its four-hour damping; five-minute display steps advance that
damping without rereading cognition. Hiding the last consumer stops both.

## Turn on Mac computer control and the activity watcher

For screen control, grant NativeAgent macOS **Accessibility** and, for pixel
perception, **Screen Recording**, then choose the appropriate **Trust** mode.
The agent reaches the Mac through `app` actions such as `mac.look`,
`mac.act`, `mac.go` and `mac.wait`. Available evidence and permissions
determine what it can do; a successful input is not by itself proof of the
intended result.

`mac.act` can run up to 12 ordered `steps`. Each object step can carry
`holding` (keys/modifiers held around physical input) and `button`
(`auto`, `left`, or `right`), including points addressed with `at`/`from`
and `frame_id`/`image`. These use the same gesture checks as a single act:
explicit mouse buttons require a click, open, drag or pointer hold; real
input requires the app in front. A failed step stops the batch. Optional
targets and retries retain the gesture options, and changing them prevents
reusing that step's landed receipt when continuing a stopped batch.
The app and every step field are part of that identity; a changed step
cannot reuse a prior landed receipt.

Steps also accept `{verb,handle,frame_id}` (the frame may be inherited from
the call). Each step resolves that recorded control identity in the live
window; a missing, changed, expired or ambiguous identity stops at that step.
Earlier landed steps remain in the receipt. Each step's effect is judged
against its own fresh before-read; a declared-effect mismatch stops later steps.
Editing a field's contents preserves its handle when the control identity is
unchanged. Handles grant no authority.

`type` with `at:{x,y}` clicks that image point, then types into the editor
that takes focus. A targetless `type` uses the focused editor, including when
the call carries `frame_id` without a handle. AX editability is required;
unreadable contents do not block keys, but return unverified with a pixel look
offered. Unknown, noneditable or secure focus still stops typing. Append
still requires a named, readable editor and a verified insertion point.
Key chords post keys directly, so duplicate menu titles cannot make ⌘W
ambiguous. A scroll without a target chooses the window's largest visible
scrollable content region, or its observed content area when AX supplies no
scroll region. `app` selects that app's window under the usual foreground rules.
When resolving an application name, an exact bundle filename wins over a
shared display name: `Numbers.app` wins over `Numbers Creator Studio.app`
for `Numbers`. Two installed bundles with the winning filename require a path.

When work encounters a missing macOS grant, its permission remedy puts the
permission card up automatically. An existing open card for that capability
is reused, and access already allowed needs no card. Tap **Allow** on the Mac
to open the system prompt or Settings pane; the agent's call itself never
opens a system prompt. The result keeps the blocked work's actual outcome
and tells the agent which card is up for you.
Permission acquisition waits up to three seconds for NativeAgent to become
active. If macOS declines activation, no grant is requested; Settings shows
the failure and asks you to bring NativeAgent forward and try again.
Looking at a named app that is stopped returns a successful observation with
`status:"ok"`, `app:<name>`, `running:false`. A running app with no readable
window returns `running:true`, `windows:0`, and its menu-bar titles when cheaply
readable. Looking launches nothing and creates no window; an act still checks
that its target is available.
The live Accessibility source prepares renderer modes before interactive AX
reads and actions, using settable capabilities rather than app names. It requests
`AXManualAccessibility` only after a complete bounded topology probe finds an
empty renderer (or only an empty window shell), and requests
`AXEnhancedUserInterface` when it reads false or a web area needs an unconfirmed
mode. Enhanced readback must be true, even when its setter returns an AX error;
its two-second settle is shared by PID and launch identity. Manual's accepted
write can still read false: the receipt reports that uncertainty, and only the
subsequent tree and action effect establish what is usable. Incomplete probes
never establish emptiness. The diagnostic `renderer_activation` in a raw look's
detail carries bounded before/after element counts, role lists and completeness,
plus attempted writes' AX status and Boolean readback.
Ordinary looks suspend during the cold settle; a direct synchronous main-lane
call reports still settling and emits no action rather than blocking the UI.

An element whose optional Accessibility attribute answers AX error `-25200`
remains in the observation with every attribute that did read. Its typed
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
Pixel masking requires every value and all name/role/frame evidence used to
detect or place secrets, including static text and enclosing captions. A failed
read withholds the image and names the element and attribute in the refusal;
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

Taking control returns the stopped action's refusal to the agent immediately,
so they can answer and decide what to do next. It does not park their turn until
you hand back. Under Full Mac their next action can reacquire control; otherwise
use the composer's **Let [agent name] use the Mac** control. Shotgun **Resume**
hands back and asks their to continue from the recorded results in that same
conversation, through its normal Send/queue path, even if their turn has ended.
A timed-out Mac call says completion is unverified and earlier effects may have
landed; inspect the affected app before another action.
For stopped calls, follow the [interruption receipt contract](TOOL_LOADING.md):
inspect retained receipts and affected state before repeating an attempted call.

The Mac control badge and selected preset show effective Trust authority.
Category switches enable actions; your access mode decides when I ask.
While Full Mac is active, Advanced switches edit saved restricted-mode settings;
they do not turn Full Mac off. Change the access mode to leave Full Mac.
If a permission button cannot open System Settings, the Mac control pane shows
the handoff failure. Permission cards and Settings also retain authorization
request errors with the privacy pane to use next. Bluetooth waits at most
30 seconds for an answer; cancellation or an unanswered prompt ends the wait
and releases the request without declaring access granted or denied.
When requesting several permissions, an individual request error is retained
while unrelated permissions continue. The final error names each failed
request and its remedy. Cancellation or a failure to activate NativeAgent
stops the remaining requests.
The iPhone notification setup button follows the readiness item's identity and
status, so changing recovery wording does not remove the route.

When a default `mac.look` finds NativeAgent in front, `behind` names the
person's app behind their when one is visible, so they can address it directly;
that app has not been read yet. After an act, an unchanged target surface
without press evidence is unobserved (`acted_unobserved`); a destination that
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
a command identifier or key equivalent; an enabled copy wins. Unpublished
duplicates require a choice unless only one is enabled or a supplied chord
selects one. Use the shown chord when available, otherwise the displayed path
with `[first]` or `[second]` (later occurrences use `[third]` through `[tenth]`,
then `[item 11]`, etc.). These select the current menu order. Different paths
still require a choice.
Presses read the exact named branch and its siblings, so unrelated submenus or
listing caps do not refuse a readable command. Duplicate selection still needs
complete evidence within that branch under the shared AX budget. Menu-bar
optional failures appear as `attribute_gaps`; unreadable names leave coverage
partial rather than naming a different command.

Chrome uses the optional bundled extension. Open its setup from **Trust** and
follow the [extension guide](../Extensions/NativeAgentChrome/README.md).
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
arrival from Chrome's completed tab and landed URL, independently of DOM access;
unsupported schemes such as `javascript:` and `data:` refuse before any tab moves.
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

The activity watcher has its own **Record which apps you use** control in
Trust. Recording is off by default. It records app names and durations;
redacted window titles require separate opt-in. It does not record screenshots
or typed content. Full Mac permits recorded-activity answers in trusted chats;
narrower modes require **Let me answer from activity history**. Answers reach
the selected provider.

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

Unreadable saved activity policy pauses recording and settings changes while
preserving the last checked choices separately from policy availability.
**Delete all recorded activity** remains available, with confirmation, even
while the policy is unreadable; deleting history does not require that policy.
Settings shows the unavailable policy, and agent settings reads return its
failure. Only a genuinely missing policy uses fresh-install defaults. A
readable repair is handled through the existing tightening-only file update
rules; enabling recording still requires the person's settings decision.
Unreadable retention cadence stops each cleanup attempt before pruning or
replacing its bytes. A failed pass retains its notice and retries in six hours
through the same checked policy, cadence and store path. Exact policy/cadence
file changes can rearm cleanup sooner after repair; without repair, unreadable
cadence continues to block pruning. A missing cadence is a first run. Deleting
expired rows also durably records compaction owed since that deletion; cleanup
retries it even when no further rows expire or recording is off, including after
an app restart. Only successful deletion and its physical compaction record the
completed-run stamp.

## Main Mac pages

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
Audio attachments show a waveform, duration, play/pause and a two-line
transcript that expands on tap. See [Voice notes](mobile_companion.md#voice-notes)
for iPhone composer voice input, recognition, limits and transport.

For local read-aloud, `chat.voice_name` takes an installed Apple voice
identifier, or empty for the Mac's system default. An unavailable identifier
is reported without choosing another voice. Cloud playback records an
unsuccessful finish or decode failure against its speech owner and clears the
active speech owner on completion. Starting read-aloud does not confirm its
completion.

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

In the main chat, type `/` for the command menu or `/help` for the complete
list. Simple and Advanced share the same commands. These shortcuts open
existing controls in a floating panel over chat; Close or Escape returns to
the conversation without switching view modes:

| Command | Opens or does |
|---|---|
| `/settings` | Settings. |
| `/connect [service]` | Connectors, or the existing setup for the canonical service IDs `slack`, `telegram`, `iphone` and `chrome`. Other service names report that setup is unavailable through this command; bare `/connect` opens the connections page. |
| `/helpers` | The shared Helpers face, with Run once, Paused and links to indexed conversations. |
| `/agents` | The Agents tab in Connectors. |
| `/today` | Today. |
| `/desk` | Desk, starting at its root. |
| `/memory [thing]` | The shared Memories face, with optional search text of at least three characters. A page screenshot leaves the open search unchanged. |
| `/forget` | Saved memories, where **Forget this…** asks for confirmation on the chosen row. Opening the command forgets nothing. |
| `/voice` | Starts or stops the same voice input as the microphone button, with the same permissions and errors. |
| `/context` | The composer's last-turn context receipt, including its loading, no-turn and unreadable-trace states. |

Arguments in brackets are optional. The other new shortcuts take no arguments.
Commands preserve pending attachments. Unknown command words such as
`/setings` report the typo and keep the draft; paths such as `/tmp/file` remain
ordinary chat text. Detached chat windows report that commands work in the
main window. A hidden Connectors tab or unavailable composer receipt is
reported explicitly. Links inside an opened control keep that control's
existing navigation behavior, which may open an Advanced page.

| Place | Use it for |
|---|---|
| **Chat** | Conversations, sessions, attachments, voice and turn progress. |
| **Today** | Notifications, approvals, proposals, recent work and items waiting for you. |
| **Memories** | Saved facts, pending proposals, rejected history and a row opening the native **Knowledge graph** canvas. |
| **Desk** | Projects, dependencies, schedules, pursuits, progress and outcomes. |
| **Notifications** | Proactive inbox, triggers, watched folders and history. |
| **Helpers** | Standing bots, their briefs, schedules or event triggers, and replies. |
| **Personality** | One face for identity, voice, becoming, minds, dreams and self-improvement proposals; links open editing and review. |
| **Providers** | AI accounts and the model choices for Chat, Work, and Memory and mind. |
| **Trust** | Standing, feature and Mac permissions, connected agents, security receipts, activity privacy, inventory and backups. |
| **Personality** | Identity, expression, about-you, growth and working guidelines; **My minds** and **Dreams** tabs. |
| **Providers** | One shared face for Chat, Work and Mind choices, account connection cards and checks, and model catalog freshness. |
| **Trust** | Access presets, feature permissions and approvals; **Mac integration** for individual Mac services. |
| **Connectors** | Service setup and the **Agents**, **Telegram** and **iPhone** tabs. |
| **Capabilities** | Review, inventory, workflows, catalog trust, guardrails, actions and checks in one face; a **Senses** tab. |
| **Diagnostics** | Health checks, Status, Run history, Cognition, Chat turn details, Skills and Tools. **Expansion** lists, for each mind using the app, the turn-start reads and follow-up reads its own practice predicts across model changes, and each one's record: tries, hits, its bar and standing, and how often the app ran, prepared or held one back. |
| **Capabilities** | Capability inventory and **Show all actions**. |
| **Diagnostics** | Health, living status, activity and runs in one reading; Cognition, Chat turn details, Skills and Tools tabs. |
| **Settings** | Appearance, shortcuts, updates, inner life and memory settings. |

Capabilities uses the same face on the Mac and in the agent's page reading;
the phone receives that face in its snapshot. **What I can do** includes the
former installed list. Rows offer
Check trust, Mac Dry run / Run, connector Dry run, improvement checks,
a browser preview, cancellation of a live browser run, Export and Support bundle.
Missing reads stay waiting or show their failure; a missing workflow status
stays unavailable. Page search, catalog-entry forms, the memory graph,
research lab and Your spaces are removed from this page; ask in Chat for
searches, catalog changes and research, and use Personality for your spaces.
Context receipts leave unmeasured sizes and totals unavailable; token shares
are calculated only from a complete assembled size.

Today recognizes collaboration from recorded peer-bridge provenance, with
contact names resolved by the connected-agent directory. Unreadable contact
evidence is reported as unavailable. Approval requester names use the same
directory, including saved legacy bridge routes; route names do not override
the person's contact names.

Today's editable `today-readout` part draws one face: **What I did** is a timed
timeline, **Ahead** is a flow of pills, and **Earlier** shows note counts and
their newest dates, plus any named source gaps. Kept moments appear beneath
their row. Dream and conversation rows open their recorded destinations;
waiting requests open their Activity details. The Mac and `app {page:"today"}`
read the same face through the shared visual and text renderers. A failed
projection shows its cause instead of an empty day. Existing Activity queues
remain reachable from the face.

Activity's Inbox and Approvals open the same Inbox face, also read by
`app {page:"inbox"}`. Requests appear in **Waiting for the person**, followed
by **Went wrong**, then **News** with unread matters first. Rows retain the
recorded time, symbol, destination and choices. Approval buttons say
**Approve** and **Deny**; interaction requests keep their choices,
**Open request** and **Not now**. Other notes offer **Mark read**, **Archive**
and **Dismiss**. Deny, Not now, Archive and Dismiss ask for confirmation.
Putting a note away removes the note from the active face. **Earlier** counts
archived matters in the last day and opens notification history on the Mac.
Notifications continues to hold notification preferences and trigger switches.
The separate Inbox category picker, archived toggle and approval history panel
are removed. The chat header's note detail and notification preferences history
remain available. Shared face rows currently show only four lines of detail;
the full approval preview is still available in the conversation's approval card.

### The agent reading and setting these pages, quietly

Notification trigger switches show a pending choice only while saving. When
the write ends, they show the inbox owner's current setting, including changes
made from another surface during the save.
The Inbox face reads the in-memory experience owner and updates from that
owner's change stream, including while no view is open. Interaction choices
and **Not now** resolve the original transcript's card; **Open request** opens
that conversation for setup controls and typed input. A lookup or write failure
shows the owner's cause. `interaction_session_id` identifies the origin;
`chat_session_id` identifies its separate mirror destination.
The agent's row actions retain the existing Inbox tool checks and invoking turn;
archive, dismiss and mark-read still require a reason. Paired-phone approval
decisions continue through signed approval cards; the face actor alone does not
carry the authenticated device identity needed for approval provenance.
**Mark all read** keeps failed updates and their causes in the open list, with
**Retry failed**; successful writes alone dismiss the list.

In **Diagnostics → Chat turn details → Replay**, a failed date read ends
loading and shows its cause. Any earlier cards remain labeled with the date
they actually came from.

NativeAgent is the agent's one always-on tool, `app`. A normal page read or
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

Home is one shared face: Notable, Changed, what waits on you, My queue,
Working, Open, People, Helpers, My senses, Elsewhere, Places and Mac follow
your layout. The Agent view draws the same rows the door reads, with links
to work, conversations, approvals and cards. Queue steps offer Done and
Drop; claimed arrivals offer Accept; a working job offers Read job.
Opening the face does not mark anything seen. Only their own Home look keeps
the CHANGED comparison, presence and current Mac front/session state,
this conversation's windows and browser tabs, and the two-minute SAME
collapse. A source that is not read or cannot be read
leaves its section incomplete and says why; the other sections remain visible.

Discovery ranks the registry's action descriptions and schemas with semantic
and lexical evidence; an exact action ID takes priority. A named page or Mac
integration puts its own actions next, in page order, and its page first in
the matching pages, using registered page IDs, titles, door aliases and
integration IDs (see [discovery](TOOL_LOADING.md)).
For example, `find:"Notes actions"` starts with Notes' search, create, update
and delete actions. The remaining matches keep their semantic and lexical
ranking; there are no feature-specific keyword routes.
For an action, `preview:true` reports what it would do without doing it.
`expected_version` refuses the action if the current page version differs
from the read.

Scripts can use `app.read`, `app.find`, `app.log` and the registry's
actions, such as `app.inbox.archive(args)`. They have no direct file or
network access. Each call is checked separately. A call that raises a card
waits for your answer; a blocked action stops the script; earlier completed
calls stay done.

Page reads are available in Safe. Ordinary setting changes require Work mode,
Builder or Full Mac. The returned page states which controls the agent may
change. Selecting Full Mac and granting macOS privacy access remain owner
decisions. See [Trust modes and approvals](#trust-modes-and-approvals).

## Memory, personality, and context

Panel refresh notices publish through a per-panel `LatestRead`: an older read
cannot clear a newer completed read's failure, and a canceled read publishes
no freshness or status claim. Each caller still receives its own read outcome.

**MemoryV2** stores durable memories. **Personality** holds identity and voice
documents. The generated about-you document is a projection of memory; edit
the facts through **Memories**. The knowledge graph is an index over memory,
and Fluid Context prepares bounded material for a turn from the underlying
stores.

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

The Personality page reads one shared face from launch and whenever its saved
inputs change, whether or not the page is open. It shows the saved name,
each document's title and first line with its update time, their self-reading,
Memory and mind's model choice, recent dreams and waiting self-improvement
approval cards. A failed read stays visible in its own section. Open a document
or **Read or edit my identity** to use the existing name/document editor and
starter form; unsaved drafts and the read-only about-you document keep their
existing rules. **My minds** opens the provider/model picker and **Dream diary**
opens Dreams with its Dream/REM controls. A proposal opens its existing approval
card. **Reset identity…** opens the existing reset view; its confirmation and
backup behavior are unchanged.

Persona replacement, section append and editor saves require the existing
document to read successfully under its write lock before backup or mutation.
A missing or unreadable document reports its full path and asks for repair or
restoration; an ordinary edit never recreates it. Explicit setup and the
compiler's missing-only genesis described above own creation.
Document saves return the saved bytes and modification time; if
readback fails after saving, the failure says the edit already landed and to
read before repeating it. Committed content invalidates derived context before
readback; an activity-feed failure owes a separate repair and does not fail the
saved edit or invite repeating an append. Recovery-copy pruning must succeed
before a pending persona edit can run. The checkout installer creates template
files only at absent paths; existing empty or unreadable files are preserved
and reported for repair, and unavailable required templates fail setup.

Slack uses the same installation persona selection as Chat; a display name is
never a persona directory ID. The first greeting reads the person's name before
claiming or sending it; an unreadable profile leaves the greeting pending and
reports how to repair it. Setup checks the complete current profile through
PersonaEngine before treating an existing identity as usable. Completion and
missing-profile repair both require the person's explicit name and a specific
agent name. The Personality starter marks your name required and keeps Create
disabled while either name is blank, including whitespace-only input.
Completion, repair and later profile/name saves use the shared
identity validator: generic labels (Agent, Custom, AI, Male, Female), control
characters and names over 80 Unicode code points are refused before publication.

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

Privacy inventory names incomplete file counts and sizes when access fails.
Evidence readers refuse malformed JSONL rather than presenting a shorter clean
history; callers that deliberately show partial history retain its integrity
receipt. Appending refuses an unreadable existing tail. Feed health reports a
failed size read as unavailable, while a proven absent feed starts at zero.
JSON values receive a digest only after checked serialization; invalid values
cannot identify recipes, layout versions, strict read receipts or watch rows.

Pinning or deleting a memory refreshes the Memories face and reports the
committed mutation's result; it does not wait for a global app refresh.

The composer context readout formats percentages without integer narrowing
and signed token changes without taking an absolute value. Large recorded
counts remain visible, including usage above the selected window.

Each conversation keeps its verbatim recent tail in the powering model's full
default window. At the bound, one block of oldest whole turns leaves the replay
in half-budget jumps derived from the transcript; those turns remain in the saved transcript
and can be read or recalled. A long running turn replaces its oldest tool-result
bodies with pointers to their full saved results. It never writes a summary to
stand in for what was said. There is no manual compact control or custom context
window. The composer ring shows the last observed provider input against the
model window; unknown measurements remain unavailable.

What you tell the agent about yourself, and what a trusted agent or the agent itself says,
is kept as a fact at once with where and when it was said; correct or forget it when it is wrong.
Facts from an agent you have not trusted wait in Today or Memories for review. Skills are built-in guidance;
dreams and REM consolidate experience. A dream never makes a statement a canonical fact.

To run one mind process now, discover it with `app {find:"mind"}`. `mind.dream`
runs the real dream pass, and the clock-owner actions can satisfy their own
wait while keeping readiness, Trust and person-facing gates. Each new clock
action reports its actual decision and why. The [run-now table](SUBCONSCIOUS.md#run-a-clock-owner-now)
lists the actions and the waits they satisfy.

Use `app {action:"mind.dream", preview:true}` to generate a dream and inspect its
proposed care judgments without applying them or writing a diary. It spends a
real provider call. The other nine clock-owner actions currently refuse preview
with a specific reason; removing `preview` runs them for real, including priming
and news release for `mind.cross`. The run-now table documents that boundary.

Cognition's reflection records show an unavailable token total if the recorded
components overflow, retaining the individual prompt and result counts.

## Skills, tools, and connectors

Everything the agent calls goes through `app`. Pages and `find` expose
actions when needed, without adding more tool schemas to each request.
The old catalog, loading and per-area tool calls are refused with a translated
`app` call. Work previously opened through the workspace tool is now in home.

- Skills are built-in guidance: `ability.list` and `ability.read` find and read
  them.
- To author a capability, the agent grows an ability with `ability.save`. Under
  Full Mac their ordinary own save is kept and on at once;
  [practice-compiled abilities and their revisions](skill_manifest_spec.md#compiled-from-practice)
  must replay their recorded examples before anyone can keep them. Otherwise
  `ability.enable` asks you with a card (or keep it on the Tools page). A kept ability appears as
  `authored.<id>`; `ability.disable` and `ability.drop` manage it; revisions fix it forward.
  Abilities grant no new authority. See the [manifest spec](skill_manifest_spec.md).
  Keeping follows the current
  [Trust and peer-turn rules](#trust-modes-and-approvals), including the
  exemption for agents enabled in Trust.
- An MCP server is an ability the agent grows, a resident one keeping the
  server running; NativeAgent has no MCP page of its own.
- `web.search` searches SearXNG and returns its results or an explicit failure with setup or repair guidance. A malformed result or `unresponsive_engines` entry is skipped with a named `gaps` entry; valid siblings still return, and an empty result with gaps cannot establish no matches. Required response/envelope failures still fail the search. Research's results view and Lab evidence retain these gaps. Without configured SearXNG, search is unavailable; it does not select a browser route. The requested time range travels with the SearXNG search.
  In Research's search service settings, Find and Save run one at a time.
  Editing the URL while either runs preserves that edit; its earlier result
  cannot clear the new draft or replace its feedback.
- Service connections live in **Connectors**: the Slack and Telegram doors
  are set up there. Any other service is an ability the agent grows; its secret is
  granted once on a card the agent raises and kept in the keyring.
  The Connectors tab and the agent's page reading share one face, also sent in
  phone snapshots: **Accounts** shows status, available switches, setup cards, browser
  access and disconnection. Telegram's row opens its own tab. **Kept secrets**
  lists each secret's name, destinations, account and grant time; **Forget**
  asks for confirmation before deleting it. **Folders I may open** shows each
  shared folder's path and read or read/write access. Unread or unavailable
  sections say so, and owner changes update the face even while the tab is closed.
  Authentication and service permissions still apply when an action is available.

In **Connectors → Folders I may open**, choose **Share a folder** on your Mac.
The folder picker accepts an optional name and **Let me write to it**; **Share
Folder** saves the selection. Cancelling shares nothing. Ask the agent in chat
to search your shared folders.

The [app tool contract](TOOL_LOADING.md) defines this interface. For file work,
the default folder on an app-only install is:

```text
~/Library/Application Support/NativeAgent/workspace
```

Source-backed installs use the checkout's `workspace/`. Every surface uses
the same resolver. Full Mac can authorize work in an explicitly selected
project elsewhere; Apple's privacy permissions still apply to protected
locations.

Make's HTML previews stay offline and script-free within the selected
artifact's folder. File, revision and read folder publish together through
`LatestRead`; changing selection or closing the preview cancels pending WebKit
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

## Trust modes and approvals

Trust on the Mac is one face: standing, guardrails, feature permissions,
connected agents, Mac access, security receipts, activity privacy, the storage
inventory and backups. The agent reads that same face as text. Each switch saves
immediately; granting more access asks for confirmation. Full Mac's effective
permissions are distinguished from the saved choices for narrower modes.
The storage inventory shows when it was read; Refresh reads it again.

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

**Trust → Mac → Apps and features** owns each integration's Read and Write
switches. Write off, whether chosen or shipped that way, means “look, don't
act” in that integration's app too, including under Full Mac: clicks, typing,
shortcuts, menu commands, drags, Accessibility actions and modifying app events
are refused before approval and again at emission. The same switch governs
that integration's own tools (sending mail or messages, creating contacts,
events, reminders or notes): Full Mac never widens a switch.
Mail, Messages, Notes, Contacts, Calendar, Reminders and Music each declare
their own app ownership. Only the owner can enable Write. Looking, scrolling
to read, waiting, zooming and opening the app stay available; Write does not
gate them. Holding a key chord while scrolling still checks Write for the
app receiving those keys, including a named app brought forward for the act;
modifier-only scrolling stays available. Read off gates integration
content tools, Full Mac included; it does not change
screen or Accessibility reads. Shell commands retain their existing Trust
authority; under Full Mac a shell can still run `osascript` at these apps.
App-script calls must declare `bundle_id`; their script body is confined to
that app and each modifying event checks Write. GUI scripting through System
Events is refused when its affected app cannot be established; use native
hands on the observed app. System media toggles and track keys resolve the
live Now Playing process and obey its app's Write switch; Music Write off
does not disable another player's controls. If the player cannot be
established, no media key is sent; use the named player's action. Discovery
failures retain their cause and bounded process evidence in `target_discovery`
(launch, channel, timeout, exit, truncation or invalid PID), with
a repair direction. A successful empty Now Playing read returns `no_player`
and sends no key. Stop remains cancellation, including during admission.

`mac.apps` reads the resident Spotlight app inventory. A readable app bundle
that declares no platform is a Mac app; installation classification uses its
location and Launch Services evidence. Unavailable
classification appears with its path and causes in `classification_unavailable`;
the reply is `partial`, and those rows stay out of the installed projection.
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

Saved app permissions have one checked reader for both display and edits.
Each saved integration entry must contain every axis it supports; changing
one axis preserves the other. Missing integrations use the shipped defaults.
Unreadable or incomplete saved authority is reported as unavailable with its
repair direction, and its bytes remain untouched; it is never presented as
an owner choice to turn access off.

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
add nothing. Valid entries extend existing values; omitted name/organization
fields preserve them. No partial malformed field is saved.

Calendar event updates require strings for supplied title, notes and location.
Omitting a field preserves it; an empty notes or location string clears that
field. Malformed text fields are refused before reading or changing the event.
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

**Resetting macOS privacy permissions always asks the owner first**, including
under Full Mac.

**Agents enabled in Trust → Connected agents carry the owner's authority on
authenticated turns.** They do not receive extra peer approval requirements;
ordinary Trust, domain, service and macOS permission checks still apply.

**An agent you have not trusted gets one card per command.** A turn such an
agent starts with its message files one card on its first effect, quoting what
it asked; your answer covers the rest of that turn. Reading any agent's words
steers nothing, and conversing with agents or telling them what to do asks
nothing. More restrictive Trust modes can require their own approvals.

Resolve requested approvals in Today. An approval authorizes a step; the
action's receipt and the service that owns the effect establish what actually
happened. Chat receipts show the outcome, with evidence under **Details**.
Chat approval buttons and recipient scope come from the filed action and its
arguments. **Not now** declines that request; it promises neither a saved draft
nor that unrelated work has stopped. Missing approval records remain unavailable.

## Desk, background work, and lines

Use **Desk** for durable multi-step work: dependencies, schedules, checkpoints,
approval pauses and outcomes stay with the task. A **held** row has a blocker,
defer or held ancestor; its reason explains what needs to change. A task you
start from the Mac's new-task sheet, the phone or Shortcuts becomes a Desk item
that a [line of theirs](#lines-of-their-own) carries; they settles it when the line
ends.
The [Desk vocabulary](DESK.md) describes its actions, person waits, paged reads
and the separate shared task ledger.

Desk has one face for its board, other work, attention, timers and reminders.
Items are grouped as Now, Waiting, Queued, Watching, Parked, Done today and
Finished history. Open an item to read its details first, including its notes,
dependencies and pursuit accounting. Close, Defer, Note and Veto use the same
work owners as before; Close and Veto ask for confirmation. New task and Note
open retained draft editors on the Mac. The command palette still finds items.
The agent's page reading comes from this same face. Older phones keep their
existing Desk reading until the companion switches to the shared face renderer.

Background work is owned by the core's `BackgroundLoopLifetimes`.
Senses registration does not hold background work at launch: messaging,
reply delivery and Desk notifications start independently. A sense read or
file subscription reports its own unavailability while Doctor's **Senses
installation** reading names the registration failure and repair. After repair,
file subscriptions resume on successful registration; a read that returned
unavailable can be requested again. See [Senses](SENSES.md).
Parallel work is several [lines of their own](#lines-of-their-own) at once:
`agent.job` with `agent: "self"`, each with its own brief and, when they writes
them, `instructions` for who that line is. Each line uses their Trust and
workspace gates; delegating work does not grant new authority. Home's
**WORKING** block shows their jobs and lines at work; the **crews** room lists
their own lines.

Model controls read the selected account's catalog. OpenRouter's catalog carries
its per-model reasoning efforts and default from OpenRouter metadata, including
through the saved cache. Missing capability metadata offers no invented Think
levels. Helpers and phone edits use that same declaration; an unavailable
catalog on one account leaves other accounts' choices available. An unreadable
Trust policy is reported as unavailable before a Trust control is read.

## Helpers: standing bots

A helper has a name, optional personality and brief; its conversation is saved
when it first opens or runs. The brief is its complete job, including any
desired output form. Tools and the phone save that same field; helper
create/update arguments have no separate `output_format` field.

The Mac's **Helpers** page and `/helpers` show the same face the agent reads through
`app {"page":"bots"}`. Each helper shows its status, model choice and timing,
Run once, a Paused switch when it has scheduled or event work, its brief,
missed runs and its five newest runs with their outcome, duration and recorded
model. A running helper carries its recorded start time. Open an indexed
conversation from its helper or run row; a helper without one says
“No conversation yet — Run once, or tell me in chat.” A blocked model choice
shows its reason. An unreadable or not-yet-read conversation index says so
instead of claiming that a conversation does not exist. Palette replies open
their saved conversation. Full replies, artifacts and earlier runs live in chat.
To make a helper or change one, tell the agent in chat; the Mac editor is gone.
The phone's existing helpers snapshot and editing actions remain available to
older phone builds while its Helpers page moves to the shared face.
By default it **follows Providers**: every turn uses Chat's current provider,
model, Think and Fast, without saving a per-helper choice. A missing legacy
`modelPinned` flag means the same as false. **Pin a model** gives the helper
its own saved choice. Its turn runner uses that selection and the live Trust
policy. It can talk to the resident by name through `agent.message`, receiving
the reply in that call. An unavailable or invalid selection prevents a run.
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

Use **Run once** for an explicit request, or configure a schedule or a supported
Slack event. A run requested from a conversation returns there as one line:
the helper's name, actual success/failure/waiting status and
the exact saved reply to open with `bot.reply`. It uses the same durable
reply-delivery and arrival path as a peer answer, without another model turn
to summarize it. An interrupted execution keeps its exact shelf record. A
request refused before execution keeps the queue owner's exact refusal, with
its request ID and cause, instead of inventing an interrupted run. Missing
result and refusal evidence leaves the outcome unavailable and asks for repair;
it never creates run history. No request is repeated to obtain a result. If
saving the asking conversation fails, the reply preserves the underlying
outcome, conversation/operation identity and persistence cause. A run requested
from the helper's own page stays in that helper's conversation. If refused
before execution, its cause is written there as an app receipt before the
request is marked delivered; no helper reply or interrupted run is invented.

Malformed conditioned results keep their prose as partial evidence and report a
failed verdict. Helper-definition, event and approval reads stay checked; a failed
reconciliation is unavailable rather than “No event yet” or an ordinary waiting
row. The Desk labels retained helper schedule rows stale when their source fails.
An invalid saved minimum cadence asks for a value from 1 to 15 minutes in Helpers
settings; it never silently chooses a cadence.
Every shelf entry read, including the unlocked home glance, consults canonical
approval state after reading the entry. Missing or unreadable approval evidence
stays unavailable; it cannot mean decided. Locked entry/history reads retain a
positively observed decision; the unlocked glance only projects it. Approving
a helper's tool call continues through that helper's own runner and transcript,
with the approval's origin and file-access restriction. The person's approval
continues even if the helper's unattended schedule is paused.

**Tell me if** asks the helper to judge that standing run's result. A true
verdict notifies; false stays quiet. If a settled run cannot supply a valid
verdict, including a failed or stopped run, the notification says it couldn't
tell and directs you to the saved run. The result and verdict are saved
together; notification acceptance acknowledges that exact result. Ordinary
messages to the helper do not judge its standing notification condition.

`bot.list`, `bot.run_once`, `bot.pause`, `bot.delete`, `bot.update` and `bot.ask`
use `id` for a helper's UUID or exact name. For example,
`app {"action":"bot.run_once","args":{"id":"Research helper"}}`.
Returned `read_with` calls name the registered `bot.reply` action.
**Pause** stops scheduled or event-woken work; a manual helper has no schedule
to pause or resume and refuses with `effects: none`. Run once and manual
messages remain available. Refusals before any write report `effects: none`.
A brief does not change permissions.
Deleting a helper excludes it from new runs and listings while retaining its
definition and audit so an already running job can save its result.

Scheduled and event-triggered helpers use **Trust → Self-Improvement → Let me
work unattended**. Turn it off to stop unattended runs outside Full Mac. Under
Full Mac, change the access mode instead. **Run once** remains available.

The helper's page shows run summaries; open chat for full replies and session
activity. Durations use the recorded seconds; invalid saved durations fail the
checked shelf read.
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
For `bot.reply` with `save_to`, `saved` contains a batch `status` and `files`.
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
An indexed helper row opens its conversation with its own model choice. See
[Automated systems](AUTOMATED_SYSTEMS.md) for background ownership.

## iPhone and iPad

1. Keep NativeAgent open on the Mac and use the same Apple Account on both
   devices.
2. On the Mac, open **Connectors → iPhone**.
3. On the phone, tap **Check for Mac** if pairing details have not arrived,
   then **Connect**. If a phone code is shown, match it on the Mac and choose
   **Pair**, then connect again.

The phone reaches the same Mac runtime through signed iCloud transport.
Its bottom row is Chat, Activity, Desk, Settings and More. Settings opens with
System/Light/Dark appearance; Memories is in More. Skills & Tools opens on Tools,
with their authored abilities alongside native tools; Skills is built-in guidance.
Agent snippets in Chat open their conversations, just as on the Mac. Connection
diagnostics are tucked into conversation details and the power-user Status page.
Keep the Mac awake for replies. Your agent can ask you to share location, choose a
photo or take one while the phone app is active. Native Shortcuts offer Ask,
Remember, Approve, Status, Quick Ask and Talk. See [Mobile companion](mobile_companion.md),
[Siri actions](siri-notification-actions.md#iphone-and-ipad) and
[iPhone approval pairing](ios-device-pairing.md) for details.

In phone **Settings → Places** and **Phone senses**, enable only the evidence
you want to share. Every switch explains its summary and its use by the Mac's
selected AI provider. Your agent can guide setup by reading
`app {page:"pairing",item:"phone-senses"}`: the last reported on/off state,
iOS permissions and missing steps, including **no place added yet**. Silent or
stale senses do not establish your whereabouts. See
[phone senses and their limits](mobile_companion.md#where-the-person-is).

## Telegram, Slack, and local bridges

Once Slack setup commits, its save settles the worker replacement and connector
refresh even if the setup sheet is dismissed. Cancellation suppresses later
wizard updates without skipping reconciliation of the saved configuration.

Configure messaging services under **Connectors**. Each surface keeps its
conversation origin while sharing the engine's context, provider and action
policy.
Telegram's **Check sender** reports the sanitized configuration or transport
failure returned by its owner, so a failure is not always described as a bad token.

Telegram's message and replay metadata readers reject malformed present values;
unavailable transcript/diagnostic reads report their source instead of zero history.
Disconnect preserves the checked allowlists, mention and voice settings even if
the saved Keychain credential is unavailable. Status reports that credential
cause separately from readable settings; a routing failure is unavailable rather
than an inferred Chat default. `/restart` requires the configured single owner's
authenticated private-chat sender. Image-only answers use the same durable
delivery journal as prose; failure notices are retained there too, and an unknown
send requires explicit `/retry resend` consent before another send.
Telegram OGG/Opus and WebM audio uses ffmpeg selected before conversion; install
ffmpeg if that format cannot be prepared. Apple Speech runs one recognition
policy without an on-device retry branch. Already-readable system audio goes
directly to recognition; unsupported declared formats report their cause.
Its model controls use the selected provider's catalog; unavailable capabilities
stay unavailable. OpenRouter's model metadata owns its supported Think levels
for pickers, saved selections and helpers; unavailable metadata requires
a catalog refresh. Each provider's catalog failure remains on that provider's
row and does not remove healthy providers. An unreadable Trust policy reports
unavailable when authorizing remote Mac work; it is never
described as a disabled setting. A queue-card removal failure is reported without editing the card
through a second operation. Slack receives through Socket Mode only and reports
socket failure without switching to history polling.

The bundled `nativeagent-link` helper and HTTP agent clients read the agent
bridge's descriptor under `~/.config/nativeagent-link/` for the current
loopback URL; each contact sends its own credential. The older Claude/Codex
lane keeps `~/.config/claude-bridge/bridge.json`. Do not hardcode a port. See
[Agent conversations](agent-communication.md) for connected peers.

### Codex and Claude Code as specialist builders

The agent can hand a bounded job to a local coding session through `app`:
`agent.job` to the Codex or Claude Code contact, with `where` naming the
repository when the job should come back as a diff in its own worktree.
Install and sign into the corresponding coding product on the Mac. The job
should name the requested outcome and, through `done`, the check that proves it.
See [Jobs](agent-communication.md#jobs).

The result returns to the originating conversation. A builder's reply is
evidence to assess, not proof of completion by itself. Check the resulting
files, receipts and any external service involved before claiming success.

### Lines of their own

The same `agent.job` with `agent: "self"` gives a piece of work to a line of
the agent themselves: a turn of theirs in its own work conversation, with their
tools, Trust and present, which the chat list does not show. Optional
`instructions` make the line someone they writes (a researcher, a critic, a
specialist) in place of their persona. Several lines can run at once; each one
ends as news in the conversation that started it, with its answer.
`agent.jobs` lists them and `agent.read` or `agent.cancel` with the job id
reads or stops one. See [Jobs](agent-communication.md#jobs).

## What the configured agent should do

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

## Health and troubleshooting

- **Diagnostics → Diagnostics** shows health checks, issues and safe repairs,
  background work, this Mac, living status, the newest eight activity events
  and fifteen runs. Run checks, repair safe issues or prepare a support report
  from the health row. A running check shows when it started; unreadable sources
  keep their availability notice beside any retained reading.
- Open a run row for its full prompt, output and saved facts. **Chat turn details**
  and **Cognition** keep their detailed turn and inner-state instruments;
  **Skills** and **Tools** keep their own tabs.
- **Today** shows approvals and work waiting on the user.
- **Settings** contains update controls.

For installation, permissions, provider and data-removal help, see
[Support](../SUPPORT.md). Keep credentials, pairing keys and private content
out of public reports.

## Honest boundaries

NativeAgent's provider requests and configured services can send selected data
off the Mac. A capability still needs its permissions and a working connection.
The [capability map](CAPABILITIES.md) names the source owners and limits;
[Project Status](../PROJECT_STATUS.md) describes this checkout.
