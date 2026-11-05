# NativeAgent mobile companion

The iPhone/iPad app is a surface of the Mac-owned agent. Keep the Mac awake
with NativeAgent open to process new work. The runtime is in
`EngineRuntime` and `ChatTurnRuntime`; mobile sync does not create another
brain. Agent's tool interface remains the single `app` tool:
`app {}` opens their home, while `page`, `item`, `find`, `action` and
`script` reach its contents and actions.

## What the mobile app exposes

The main tabs are **Chat**, **Today**, **Desk**, **Settings**, and **More**.
A page the Mac publishes as a face (`faces.json`, read with every snapshot ping) is
drawn by the shared `FaceView`: Today, the Desk, their home, Memories, Personality,
Trust, Providers, Connectors, Capabilities, Helpers, Diagnostics and the Mac's settings
under Settings. A row's link opens its place on the phone (a faced page or a
saved run in the same stack; Chat, Today's queues, a card, the Desk or the browser
through the shell), or says the place opens on the Mac; a row's action goes to the
page's owner on the Mac as the signed `faceAction`, and its answer or refusal shows
where the reader is, as the app's toast.
Settings opens with a System/Light/Dark switch; this iPhone's own settings (appearance,
connection, Places, senses, Live Activities) remain on that page beside the Mac's settings
face. Memories is behind More; memory proposals are Today's "Memories to keep".
More follows the phone's surface layout: Rooms holds their home, Memories, Scheduler, Helpers, Agents,
Capabilities, Skills & Tools, Personality, Connectors and Trust; Setup opens Settings;
Power user holds deeper views. Settings nests Telegram and Providers.
More uses only the Mac's accepted layout. A missing or unreadable refresh retains
that layout; an unreadable refresh reports its cause. Before the first usable delivery, More
shows layout unavailable with connection recovery. The phone neither seeds nor
repairs a Mac layout. Approvals and notes are one Inbox, the Mac's Inbox face:
Today's queues, approval and card links, notifications and a note's card in chat
all open it, and its rows answer through the page's owner on the Mac (an
approval with this phone's verified identity). Earlier's history opens on the
Mac. Memory proposals show an empty verdict only after their own snapshot has
been read successfully; a late or missing first snapshot remains unavailable,
with a reconnect/refresh remedy.
Providers carries no secret: adding a key or signing in raises the Mac's card.

Self-Improvement points to the Mac; the phone has no training-proposal queue.
Memory reviews and approval decisions remain on the phone, and Trust owns dream
and REM settings. The Mac still publishes an empty training-proposal tombstone
for older phones.

Chat supports sessions, streaming replies, queued sends and attachments.
Its shared sync transcript projection owns versioned snapshots, history pages
and live bridge updates by row/run identity. Version checks read retained index
rows without preparing conversation titles or navigation. Admitted live and phone replies
share terminal and delta mutations; only visible replies produce UI effects.
Snapshots and history use one concrete shared transport row, metadata and
attachment values. In the snapshot's last 80 person-visible rows, each row also
carries the Mac's reading of its seat, provenance, tool outcome, receipt or owed
decision. Tool runs carry the presentation part's prepared headline on their
first fold row and any prepared detail words on their rows. Missing or failed
headline preparation leaves it absent for this snapshot and is retried on the
next; an unchanged cached preparation failure is logged once. This additive
face preserves older phones' tool events and interaction fields, and remains
subject to the existing 2 MiB chat group budget. The phone draws its
conversation from these rows, tool runs and asks included, through the same
`TranscriptBuilder` as the Mac; a row without a face, and the phone's own sends
and streaming reply, read plainly. Mac transcript metadata and
phone projections use the shared checked `ChatMessageMetadata` codec. Its
canonical tool keys are `tool_name`, `input`, `result_summary`, `result_status`
and `approval_id`; retained Mac
receipts with camel-case keys remain readable there until their records and
writer move together. Invalid metadata makes that transcript read unavailable;
unreadable origin/envelope values retain an explicit attribution gap.
Every new session creator writes transcript generation zero for its initially
empty transcript; later transcript writes and clears advance that same index
counter. A missing generation never authorizes clearing phone history.
The phone persists unfinished
requests and attachment bytes in `ChatPendingExchange.request`; signed expiry
retains that request for “Send now”. The saved form requires that request and
the delivery flags; expiry-only historical decoding is removed. Queue entries
require their acceptance pairing and explicit replacement-intent flag; optional
envelopes, placeholders and assistant replacement IDs represent actual unsent
or ordinary-message states. Present unreadable saved values stay unavailable
and byte-preserved: neither new sends, shared-item imports nor later persistence
may replace a failed chat owner. Missing values are first use, not a failed read.
It does not cache settled transcripts.
Saved replies, including failures, settle the matching pending run. Regeneration
keeps the previous answer visible until the Mac publishes its replacement.
The shared ChatStore owns reply/rejection/resync observation, independently of
the mounted ChatView or talk cover. The bridge owns foreground/talk message
fetching and event-driven catch-up; push, explicit refresh and bounded App Intent
waits also request reads. ChatStore's ten-second task only updates waiting text;
it does not fetch messages or run a background catch-up loop. Silence deadlines
stay per exchange and release the composer while retaining reply observation.
Session changes retire visible callbacks and waits without deleting durable exchanges or signed sends.
Stop derives its named runs from the selected conversation's exchange, queue
and visible transcript provenance. It releases the local composer immediately
and pauses that conversation's queue, retaining the original signed send,
exchange and delivery evidence until a signed refusal/cancel/terminal receipt
or saved terminal transcript settles it. Missing acknowledgment never proves
nonreceipt. A failed Stop wait says it is unconfirmed; late replies still land.
Closing a pinned tab submits unpin once. An unconfirmed wait stays visible as
uncertain while the retained action and published navigation remain authoritative;
it never automatically submits a second unpin.
Returned Steers keep their original run identity. The Mac's locked transcript
append admits exactly one matching session/run/content user row for resident
and helper chat; it reuses that row's origin instead of appending it again.
Unreadable, conflicting or repeated saved input prevents admission. Assistant
regeneration replacement remains separate; `rowWritten` is no longer published
or consumed as a phone admission instruction.
A matched full message stays full when a snapshot's truncation prefix agrees,
independently of history membership and unrelated transcript generation changes.
Approval, inbox and memory readbacks stay in the shared projection until a
Mac snapshot revision acknowledges them. Mac capture revisions order those
reads and removals; phone request or arrival order does not. Model choices use
the checked routing owner's committed revision across catalog, snapshot and
action delivery; an acknowledgment never creates a second pending fence.
The selection command validates the response and adopts the shared selection directly.
Skills & Tools opens on Tools and reads Mac-published snapshots through one refresh
shared by both pages. `tools_snapshot.json` includes the checked all-kind
`Parts.rows(kind: nil)` inventory (abilities, senses and turns), separately from
native tools; `skills_snapshot.json` remains built-in persona guidance and may
legitimately be empty. Neither page loads tools into the agent's context. A failed
catalog read retains prior rows with its refresh warning, rather than claiming
the abilities are gone.

Guidance rows show their current name, description and built-in source, plus a
body revision when supplied. Skills has no executable lifecycle filters,
run counts or restore controls.
The canonical Mac profile owner rejects nonfinite values and
values outside 0...1. Memory's account remedy reads the bridge's checked account
failure; it does not run a second account query. Mac Memory/graph diagnostics
call an optional diagnostic account probe; when disabled they say the account
was not checked and make no claim about database, KVS or phone sync activity.

Agents rows show a plain state and the latest known exchange/activity time;
missing state in an older snapshot says it was not reported. Raw status and last
exchange diagnostics are behind Connection details in the conversation. Reading
a conversation uses the existing bounded signed action request; only an active
request shows progress. An absent thread after failure says it has not reached
this phone and offers pull-to-refresh, never an endless loading label. An
unpaired phone asks to pair. Agent snippets stay in Chat, from the same
`OtherRoomExchange` records and compact title/reply preview view as the Mac;
tapping opens the contact conversation in a sheet.

Settings shows the release version without the internal `-dev.<revision>.dirty`
suffix. More → Power user → Diagnostics draws the Mac's diagnostics face, then this
iPhone's recent push receipts, unverified Mac records and connection. A run row opens
its saved detail, whose raw prompts/requests remain behind disclosures. Turn Inspector reads
only timing/count summaries and carries no prompts.
The [Share extension](ios-sharing.md) adds items from other apps to Chat.
Native Shortcuts offer Ask, Remember, Approve, Status, Quick Ask and Talk; see
[Siri and notification actions](siri-notification-actions.md#iphone-and-ipad).

Mac Tools offers notifications, Spotlight search and output-volume targets.
`PhoneMacControlAction` owns executable method/path support for the phone and
Mac dispatcher. Volume keeps the signed `system`/`volume`/`value` envelope and
dispatches to MacControl's `volume` executor with a numeric `level`. Run Shortcut,
Lock screen and Sleep display have no native executors and are removed, along
with their send helpers and retry cards. Existing Trust and Full Mac gates remain
with their owners; the policy snapshot is not evidence of route support.
Connector rows own toggle eligibility: local files or a supported setup wizard,
excluding browser and Telegram. Mac controls and phone readbacks use that fact.

## Voice notes

Tap the composer mic to dictate into the draft; tap it again to stop. Hold
the same mic for 0.3 seconds to record a voice note, then release to send.
Slide left 70 points to cancel, or up 65 points to lock and keep recording
hands-free; tap Send when finished. The recording pill contains the live
transcript and elapsed time. It never floats over the conversation. Start,
lock and send give a light haptic; ordinary send/reply haptics are suppressed
while the microphone is recording. Playback stops before capture begins.
VoiceOver offers named record, lock and cancel actions.

Composer voice input sends only recognized text: it creates no audio file for
export, upload or playback. Held notes send their words independently of text/photos
already in the draft; if sending is unavailable, the words stay in the draft.
Dictation appends recognized words to that draft. Session changes and
backgrounding cancel capture and prevent late recognition from writing into
another conversation. A capture stops at
three minutes and keeps its recognized words in the draft for review.
Startup times out at 45 seconds and final recognition gets three seconds to
settle. If final recognition never arrives, the last recognized wording remains
evidence; no recognized
words means an explicit error and no send.

On supported iOS 26 devices/locales, SpeechAnalyzer/SpeechTranscriber recognizes
on-device with confidence/timing evidence and contextual strings for the
agent's name and the person's onboarding name from the canonical personality
profile. Missing names simply supply no hint. Speech assets install before
capture. An unsupported device/locale (including a simulator without that
engine) reports recognition unavailable and asks for a supported device/language.
Recognition errors are reported by that same owner. Microphone
and Speech permissions remain explicit.

Separately delivered audio attachments retain their audio face: speaker label,
actual-audio waveform, duration and play/pause, with two transcript lines that expand on
tap. A missing/unreadable file says **Audio unavailable** and leaves the
transcript readable; it never substitutes another recording. A phone can
replay an existing local audio attachment after Mac snapshot refresh; audio
originating elsewhere requires delivered bytes or an existing local copy. This lane does not add
audio downloads to transcript snapshots. These attachment capabilities do not
create recordings from composer voice input. Hands-free talk is described below.

## Talk mode

Tap the phone button beside the composer mic to talk hands-free in the current
chat. The mic keeps tap for dictation and hold for voice notes. Siri/Shortcuts
offers **Talk to <agent name>** (also selectable for the Action Button); the
existing Control Center control now opens straight into talk. Quick Ask remains
a separate shortcut for typing. Talk entry opens the app and requests microphone
and Speech permission. It requires on-device SpeechAnalyzer support for the
device/language; it never switches to server recognition.

The call face shows the agent's name, elapsed time, captions for both sides,
mute and end. Its small living circle follows microphone level and speech word
callbacks; Reduce Motion keeps it still. After speech, **1.0 second of silence**
reaches the turn endpoint. The recognizer settles its own words; talk never forces
finalization. Settled words send immediately; still-volatile words send when their
final arrives or as heard after two more seconds. Recognition stays open, and later
results keep only words after those already sent. A short soft sound confirms
the phone saved the message to ordinary chat, before the Mac's answer.
Empty recognition sends nothing. Each turn uses
the same session, durable queue, signed transport and transcript as text chat.
Talk has no separate conversation or message schema.

Admitted, sequenced cumulative reply deltas feed speech as complete sentences
arrive; a final receipt flushes the remaining words. Working comments remain
part of the reply. Final paragraph spacing changes keep queued speech intact
and do not replay sentences; changed non-whitespace characters in an already
queued prefix stop speech with a visible explanation. The phone uses native
Apple speech in the Mac's resolved voice identity from `voice_preference.json`
in the existing core snapshot, including the Mac's system default when no name
was chosen. The Mac's `VoicePreference` owns both resolution and quiet mode.
On the Mac's local route, `chat.voice_name` saves a checked installed Apple
voice identifier, or empty for the system default. A configured identifier is
resolved once; unavailable identifiers report an error rather than being
reinterpreted as display names or languages. The snapshot carries that same
checked identity, with absent native fields when it is unavailable.
Matching the same voice name and language permits platform-specific identifiers;
a missing installed voice asks for its download, never substitutes a different
speaker. Missing/unreadable snapshots retain the last accepted preference;
before any preference arrives, talk reports that sync is needed. Quiet mode
keeps talk's captions and listening but suppresses all audio output, including
the acknowledgment cue; syncing quiet on also stops current speech.

The active call owns one `.playAndRecord` / `.voiceChat` session and enables
voice-processing I/O for echo cancellation. Recognition stays open during speech.
Detected new speech stops playback immediately and suppresses further speech
from interrupted runs; a signed cancellation targets only unfinished talk runs.
Old detection timestamps and cancelled replies cannot interrupt a newer answer.
Mute feeds silence to recognition while keeping the active call's audio route.
Only call start/end haptics run, before opening and after closing capture.

An active talk session may keep its audio, existing receive loop and signed
contact beat running after leaving the app or locking the phone. A Live Activity
and Dynamic Island show elapsed time, mute and end; their intents reach the
current call ID in the app process. Audio frames renew the activity's freshness
every 30 seconds; after 60 seconds without renewal it asks to open the app to
check, rather than asserting that talk is still active. A cold launch retires
orphaned talk activities. Live Activities can be disabled by the person; talk
still works without one. Ordinary dictation/voice notes cancel on backgrounding,
and ordinary read-aloud and note playback stop there; the audio background mode
serves the active talk session only.

Start preparation stops after 45 seconds with a visible cause. Interrupted audio,
a disconnected route, a recognition error or a changed pairing/session ends the
call visibly. Unsent recognition captions remain selectable on that ended face;
copy them before returning to Chat. A Mac that has not replied after 30 seconds
says it is still waiting and leaves listening and End available; silence never
settles or resends the ordinary message. End releases capture, speech and the
activity exactly once and returns to chat, where accepted talk messages already
live. Ending the call does not cancel the person's accepted work on the Mac.

## Where the person is

The agent lives on the Mac. The phone is a sense organ: Settings → Places and
the adjacent **Phone senses** section share evidence through the paired,
signed CloudKit bridge. Places are individually enabled; Motion, Focus,
Sleep clues, Battery, Headphones, Connection, Apple Music and Photos today
each start off. Their descriptions explicitly permit the selected summary
to reach the Mac and its selected AI provider. Setup state (switch, required
permission, current iOS permission and missing steps) travels through the same
owner even when the observation switch is off. Disabling a phone sense saves the opt-out
and retires its unsent observations before reading pairing authority, even if pairing
is unavailable. Same-key recovery keeps that sense off until the person enables it
again; disabled/setup evidence travels only through checked pairing delivery. A checked pairing
removal or a committed different Keychain key turns phone senses off and retires
the previous pairing's pending sends. Unreadable or not-yet-restored pairing
authority does not itself change switches, readings, places or pending sends; it pauses
new sense admission and delivery until authority can be checked. The person's explicit
switch-off still saves and retires that sense's queued readings. Previously accepted
evidence remains historical, never proof of current state. Pending delivery
runs before new wake readings and still runs if new-reading admission refuses
at the outbox limit; receipts free capacity and continue the drain.

Places share names and arrival/departure times, plus an initial **at**
observation when the phone is first seen inside a place. A first outside fix
does not invent a departure. Coordinates stay on the phone for these senses.
The separate, person-approved `phone.location` request still shares the
location the person explicitly accepts.

Motion uses `CMMotionActivityManager` history during an app wake, sharing
stationary, walking, running, cycling, automotive (rendered driving) and unknown
flags, including overlaps, with confidence and the activity's start time.
Low confidence remains visible as an estimate, never enough for presence or
sleep inference. Missing history, API errors and no activity flags stay unknown.
Previously low confidence was collapsed to unknown and running to walking;
those conversions are removed. It requests Motion &
Fitness only when enabled. Focus requests `INFocusStatusCenter` authorization
only when enabled and shares on/off/unknown. The public iOS API shares an
optional Boolean, **no Focus kind**: Sleep, Driving and Work are never guessed.
The app already declares Communication Notifications; `NSMotionUsageDescription`
and `NSFocusStatusUsageDescription` live in both the project spec and Info.plist.
See Apple's [Focus status](https://developer.apple.com/documentation/intents/infocusstatus)
and [Focus authorization/communication capability guidance](https://developer.apple.com/documentation/usernotifications/handling-communication-notifications-and-focus-status-updates).

Sleep clues share charging state and a phone-local night flag (22:00–07:00).
With fresh stationary motion and no positive Mac-here evidence, the Mac can
say **probably asleep**, explicitly an inference. Charging alone or Focus
alone cannot establish sleep or absence.

Battery shares only the current percentage (`UIDevice`). Headphones shares
this app's `AVAudioSession.currentRoute` category, never names: wired
headphones, Bluetooth, another route or unknown. Bluetooth may mean a car or
speaker; another route does not prove no headphones are connected. It never
activates audio to sense. Connection samples `NWPathMonitor` once per wake:
Wi-Fi/cellular/wired/other, explicitly unavailable, or unknown when no callback
arrives in five seconds. A satisfied path does not establish Internet access.
These three need no additional iOS permission.

Apple Music requests `MusicAuthorization` only on enable and reads
`MPMusicPlayerController.systemMusicPlayer` state and available title/artist.
No playback control, artwork, audio or listening history is read/shared; no
metadata means unavailable metadata, never proof of silence. Other music apps
are outside this API. `NSAppleMusicUsageDescription` is declared in both the
project spec and plist.

Photos today requests PhotoKit read access only on enable. Limited Access
is sufficient. A PhotoKit change observer invalidates the count while iOS lets
the app run; a wake queries only the count of non-hidden image assets whose
creation date is today, plus the phone-local date/time zone. Synced/imported
images may be included: this is **photos dated today**, not proof of pictures
taken on this phone. A limited-library count is explicitly partial, including
zero. No images, filenames, identifiers, locations or per-asset dates leave the
phone. The fetch runs off the main actor; after five seconds the observation
is unknown and a late callback cannot replace that query's outcome. Permission
is checked again before publishing. No automatic limited-library upgrade
prompt is shown; selection is edited in iPhone Settings. The Photos usage
string describes both attachments and this opt-in count.

Any agent reads **Phone senses** with `app {page:"pairing",item:"phone-senses"}`
(also `page:"phone senses"`). The existing pairing page and find index expose
this item. It reads setup and observations directly from `PhoneSenseHistory`,
with exact per-sense Settings paths and toggle names. Places derives its setup
from its own saved places and location manager: Always/while-in-use/denied,
Precise on/off, global Location Services and saved/enabled counts. No place
added says **no place added yet**; neither Home nor the person's whereabouts
is assumed. Setup that never arrived says to open the paired phone app, not
permission denied. Unreadable evidence is a read failure, never all-off.

Candidate exclusions: CMPedometer daily fitness totals and HealthKit
sleep/workouts are not offered over this CloudKit-to-model path. A summary
alone has not established a compliant boundary for health/fitness information
under [App Store 5.1.3](https://developer.apple.com/app-store/review/guidelines/#health-and-health-research),
including its iCloud restriction. WeatherKit is not offered: the current app
has no WeatherKit signing entitlement or required Apple Weather attribution
surface ([WeatherKit requirements](https://developer.apple.com/weatherkit/)).
There are no inert switches for these sources.

Readings happen at launch/foreground, a Places event, a significant-location
change (only with an existing Always grant), or the existing background push
refresh. They never start continuous location or motion updates and add no
periodic background job or audio assertion. Battery, audio-route, Music and
PhotoKit notifications can also invalidate a reading while the process is
running; they do not keep it running. iOS controls wake delivery. Motion queries have a
five-second deadline; missing/denied/unavailable readings report unknown.
Signed pending changes remain on disk until Mac acceptance and use the
bridge's existing delivery nudges. An unavailable Mac never means delivered.
Unreadable phone pairing material preserves the pairing-scoped unaccepted
chat/action/place/sense nudges and does not cancel their recovery deadline.
If that deadline expires while the key is unreadable, its completed handle is
released; a checked read of the same key rearms recovery. Only confirmed
removal or a checked different key retires the old pairing's delivery nudges as a whole;
explicit switch-off still retires the disabled sense's queued delivery nudges.

`MacControl/PersonPresence.swift` derives one line for Home, MY SENSES and the
frozen turn capsule from Mac input, `mobile/place-events.json` and
`mobile/sense-events.json`. Setup and observations occupy separate slots in
that same bounded history; each source's latest setup and observation survive
the cap. Each observation names its time and source.
After 15 minutes, phone observations are historical and current phone state
is unknown since the last observation; a phone that never reported says so.
Unchanged motion is not a heartbeat, so it cannot keep old evidence fresh.
Unreadable evidence stays unknown and the bytes are preserved. Fresh walking,
running, cycling or driving with medium/high confidence (or legacy evidence
without confidence) can establish inferred computer absence when newer than physical
Mac input; physical input later than it wins. Place names do not establish
where the Mac is. Queue `when_user_here` / `when_user_away` uses this same
transition, newer than filing. A silent phone leaves Mac-only readiness intact.
Mac hardware safety continues to read Mac input directly.
Walking → driving and the later Mac idle deadline retain that absence's first
movement time, rather than inventing another departure. Motion observation
time is the query's end time, independently of a delayed save or delivery.
Phone departure arms the Mac input owner's next physical return, even within
the five-minute Mac idle window. That first input settles the arrival time;
continued input does not advance it. Presence signals remember their last
delivery, so a delayed phone departure can refine the same absence's time
without waking subscribed abilities again. Unknown evidence never resets
that delivery receipt or invents a return.

## Pairing and setup

Use the same Apple Account on the Mac and phone:

1. Open the Mac pairing page, available under **Connectors → iPhone** in the
   Mac rail, and **Pair with Mac** on the phone.
2. Wait for the pairing key to arrive through iCloud. Tap **Check for Mac** if
   it has not arrived; tap **Connect** when available.
3. Match **This phone’s code** to the waiting device on the Mac and choose
   **Pair** there. Then tap **Connect** on the phone again.
4. Keep both apps open until the Mac confirms the connection.

`PairingSecret` owns the shared secret; `PairedPhoneStore` owns the
Mac's device records. The phone also has a signing identity for device approval
decisions. See [iPhone approval pairing](ios-device-pairing.md).

An initial Mac claim creates only an absent CloudKit pairing record, with the
server's change-tag conflict check. A concurrent claim conflict reads the
actual owner; it never overwrites that owner. Deliberate **Use my iPhone with
this Mac** and this Mac's owed key rotation use explicit replacement.
An unreadable or timed-out claim remains unknown and is checked at the next
sync. The phone still reads the same `pairing.mac` record and fields.

Pairing delivery stays with iCloud. **Check iCloud delivery** on the Mac asks
the existing pairing owner to reconcile the current key and claim; the
Connection facts expose its actual waiting/error state and remedy. After
repairing the reported cause, use **Check for Mac** on the phone. There is no
manual key reveal/copy/paste recovery route.

If Keychain accepts a regenerated key but its readback fails, the Mac keeps
the publication owed across relaunch and reports pairing unavailable. The
engine's cached signing path stays closed until the exact existing item is read;
that read never generates a replacement. The next sync (or **Use my iPhone with this
Mac**) attempts reconciliation and publishes the verified key. An unreadable,
missing or invalid item keeps pairing unavailable; repair its Keychain access
before syncing again. A rejected rotation does not erase an earlier publication
obligation. Only successful CloudKit pairing publication settles that obligation.

Each device projects its evidence directly into `NAPhoneConnection`: pairing,
transport and accepted exchange. Phone headers, connection details and
accessibility read that assessment's facts and headline. Send eligibility uses
pairing, transport and network evidence independently of Mac silence.

For source builds, generate `iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj`
from `iOS/NativeAgentMobile/project.yml` with XcodeGen, then build and install
the app with compatible signing and container configuration. The Release
configuration requests production CloudKit and APNS. Public Mac release
configuration is covered in [Release setup](release_setup.md).

## Transport architecture

The shared `CloudKitDeviceTransport` owns CloudKit private-database transport;
the bridges retain old Drive readers only for unresolved saved data. Selection
requires `NATIVE_AGENT_DEVICE_SYNC=cloudkit`, or the build's
`NativeAgentDeviceSync=cloudkit` Info.plist value when no override is supplied.
Missing, misspelled or retired selections fail explicitly. A failed CloudKit
entitlement/container preflight reports its construction cause and refuses setup; it never starts the
retained Drive transport. The shared factory alone constructs a CloudKit transport, after
`DeviceCloudKitPreflight` admits the service and exact container entitlements.

The signed bundle supplies `NativeAgentICloudContainerID` and
`NativeAgentMobileSourceKey`; the Mac also supplies
`NativeAgentBackgroundTaskIDPrefix`. The shared identity reader rejects missing,
non-string, unresolved or malformed values. These identities have no process
environment override or hardcoded runtime default; source-build defaults live in
the xcconfig files. Invalid configuration refuses transport, message metadata or
background registration at its caller and reports the build repair. Doctor
reports an invalid container as a builder-owned failure before checking transport
health. KVS carries current progress/notices and delivery nudges; it is not a
selectable message/action transport. Retained Drive readers are not a supported
alternate selection.

CloudKit pulls keep traversal cursors only within the current paginated call,
stopping at the durable server-date watermark. Mac-only retention queries one
oldest page per record family and advances through confirmed deletion; it keeps
no server sweep cursor.

`BridgeMessage` carries message/session identity, text, attachments, metadata
and an HMAC signature. CloudKit uses inline `payloadJSON` within the 800 KiB
record-value budget. Larger qualifying attachment envelopes use pairing-encrypted
`payloadAsset`; audio envelopes always use it (48 MiB encoded payload, 10,000,000 bytes per file; scalar fields
still fit inline). Asset messages have one encrypted payload and no older-phone
preview payload. The bridges handle signed chat and
delivery; `MacSyncEngine` handles snapshots and remote actions.

The send follows server evidence. `CloudKitDeviceTransport` owns the send budget:
the upload resource limit is `min(120, 15 + ceil(encryptedAssetBytes / 50_000))`
seconds, including encoded-envelope expansion and encryption. Inline messages
use zero asset bytes. The caller waits that budget plus ten seconds (25 seconds
inline, up to 130 seconds for assets). Expiry ends the caller's wait with an
unknown outcome; it does not cancel the upload. CloudKit's own resource limit
ends the upload and reports its real result.

An unknown save remains “Still sending…” while the phone checks the exact
server record for up to 60 more seconds, with 1/2/4/8-second backoff (then
eight seconds) and each read bounded by five seconds or the remaining window.
A verified Mac event for the exact message/action correlation also proves
arrival, including “Mac received it”, text deltas and terminal replies; the
receipt listener is installed before dispatch, so a reply preceding the save's
return counts. Server acceptance marks the request sent and leaves it waiting
for the Mac; it does not claim execution or a finished reply.

If neither proof arrives before the window ends, the banner and bubble say
“Couldn't confirm it arrived — Retry”. The bubble is unconfirmed, not failed;
the pending exchange keeps observing late replies and retains the exact signed
envelope for Retry. A late verified receipt clears the unconfirmed presentation.
Successful inbox reads and network recovery cannot retry an unconfirmed send;
only an explicit Retry/Send on that saved message replays it. Talk keeps the run
open for late speech instead of treating delivery uncertainty as a terminal error.
Retry uses the original message ID, timestamp, signature and CloudKit record
name. A conflict counts only after exact payload/direction equality; it
re-signals that record instead of creating another message. Remote actions
keep their retained action identity and `outcome_unknown` transaction while
waiting for the original response.

Before chat dispatch, its pending exchange checkpoints an absolute restoration
deadline: the transport's send wait defined above plus five seconds for its initial
proof read and the 60-second confirmation window. Relaunch resumes observation
of the retained envelope within that deadline, without another upload or a fresh window. A missing local
envelope cannot prove failure or authorize a replacement send: the bounded
wait and late-reply observation remain, with “Couldn't confirm it arrived.
Still watching for a reply.” when the signed retry envelope is unavailable.
A different pairing keeps the original
request held. An absent confirmation deadline means no bounded transport
observation was saved; the request's reply observation still remains open.
Missing evidence never asserts transport acceptance.
Switching conversations can cancel the visible send task but rearms confirmation
after that task releases its in-flight ownership, using the same saved deadline.
A different pairing cannot read the original peer's server record and still
reaches the bounded unconfirmed state. Regenerate retains its signed envelope
and replacement intent in the same durable queue, including before preparation;
its Retry preserves the original record and answer-to-replace identity without
appending another user message. A recovered terminal transcript reply settles
delivery through the same acceptance owner and clears the unconfirmed banner.

Mac routing and the phone Providers page share `ProviderSurfaceGroups` in
NativeAgentShared for the three model choices, membership, labels and captions;
`ProviderSurfaceLabel` classifies known, unrecognized and malformed surface keys.
The shared reasoning options table has one row per effort id. Model rows carry
optional `controlsNote` in `NAProviderCatalogModel`, projected as `controls_note`
in `ProviderModelInfo`; the phone shows that limitation beside the same model
and disables choices with unknown reasoning controls. Missing notes do not
establish capabilities. Work and Memory and mind tier-only choices inherit Chat's
other fields; partial or conflicting overrides remain unavailable on the Mac
with the repair cause rather than executing Chat's tuple.

The Drive inbox authenticates envelopes before claiming their filenames. An
existing processing claim is preserved: identical authenticated bytes coalesce;
conflicting or invalid incoming bytes are preserved under their digest in
`processed`, with conflicts reported. A queued handler keeps its claimed path.

The phone dispatches Drive and CloudKit messages through one verification and
consumer boundary. Accepted phone requests, action responses, notifications and chat
share one seen-ID/archive settlement tail. Notifications schedule and actions persist
before consumption; chat callbacks follow archival and the lifecycle check. CloudKit
consumption and Drive archival are separate receipts; foreign Drive files stay put.

CloudKit status uses pairing-scoped record names derived with the
`NativeAgent.status.identity.v1` HMAC domain. On both Mac and iPhone, every
status writer saves only that scoped name. A missing scoped record stays missing;
a failed or malformed read stays unavailable and catch-up incomplete.
Scoped records belonging to another pairing are never fetched.
The phone checks the originating pairing before applying a catalog or selecting
its snapshot cache, and again before acknowledgement; a snapshot write
interrupted by a pairing change stays in the
old pairing's cache. Acknowledgements and publication deduplication distinguish
the pairing and scoped record, so a previous pairing cannot suppress delivery.

CloudKit launch and foreground activation share one catch-up: wait for message
and status consumers, renew subscriptions, pull pairing before incoming
messages, re-read observed status records, then read Mac presence. The setup
incoming drain retains its elapsed-time log, and the independent foreground
receive loop starts without waiting for full catch-up. An already
paired phone still pulls on activation because iOS can drop background pushes.
Catch-up has two facts: incomplete work stays owed; a completed failed incoming
or status read raises the catch-up warning. A skipped/coalesced or still-running
read alone raises no warning. Only after both the incoming query and the entire
observed status pull succeed does a successful lightweight cache refresh clear
the owed work and any catch-up warning.
Each observed status must be readable and accepted, or already applied at that
server revision. Missing values, timeouts, rejected handlers and skipped drains
leave catch-up incomplete; a successful sibling handler or local cache read
cannot clear a warning from a failed catch-up read. Snapshot status acceptance
also requires the group's refresh to succeed. Damaged snapshots retain their diagnostics. The typed status
result distinguishes completion from its count of accepted values: zero alone
proves nothing, and a complete pull does not prove the Mac published every update.
Overlapping drains coalesce without losing a paired phone's requested cache
refresh: the incomplete condition is retained before coalescing. Any successful
active or later drain, including a push or queued rerun, finishes that outstanding
catch-up through the same remote-pull and cache-refresh checks. When the fast
foreground receive completes successfully with catch-up still pending and no
full bridge drain running, it hands that actual incoming result to a separate
catch-up task for status and cache refresh. Chat keeps receiving independently;
the task does not race a second incoming pull. The result remains bound to its
pairing and account-failure generation. Failures or a busy cache leave it pending
for the next successful foreground receive, activation, push or recovery event,
without adding another timer. A failed-read warning remains until
catch-up completes or the connection is reset.

Durable delivery receipts cover terminal replies, actions and notifications.
Ephemeral text deltas, progress, notices and tool presentation do not append or
rewrite that journal; existing receipt bytes and confirmation semantics remain.
Notification event receipts confirm those events only. Chat completion routes
still exclude iOS from durable acceptance: the phone needs an authenticated
receipt tied to the exact reply after durable chat storage, and the Mac's
completion owner must consume that receipt before settling delivery. CloudKit
acceptance and phone seen-ID bookkeeping do not establish that end-to-end fact.

Reply dispatch reservation, unknown submission and CloudKit acceptance are
separate receipt states. Only observed acceptance suppresses another send or
retires a reply checkpoint. The existing chat ledger retains the exact signed
publication before sending; reconciliation reuses its timestamp, signature and
record identity by reading the producer's envelope from that ledger, even when
its receipt was not saved. Ambiguous older receipts without that envelope remain unknown
until server/phone evidence resolves them. A missing saved reply and checkpoint
never manufactures a failed assistant reply. Required receipt writes are checked;
their failure retains the original request/publication for reconciliation.
The stale pending-command sweep also requires both the response-delivery and
inbound-action receipts before recording the command as processed or archiving it.
Action responses use a stable identity derived from their correlation and signed
response bytes, so an unknown response and its later terminal response remain
distinct outcomes. Every arriving action response, including an ordinary Mac
Tools result after its waiter ended, passes the inner signature and transaction
checks before its terminal receipt retires the pending envelope.

Steering read/return outcomes retain one signed identity in the same publication
ledger. Failed delivery remains owed and is re-signalled on existing receive or
repair events, one retained outcome per metadata drain. Without another event it
stays owed. A read steering offer whose notification fails is never returned as
an unread message for a duplicate turn, and that notification failure does not
abort the answer that read it. Authenticated foreground phone presence
feeds the bridge's contact owner with the verified date.

The resident DeviceSync owner is bound by construction to the canonical app data
root. Snapshot integrity reconciles on exact file changes and explicit
launch/repair events. Forced republish invalidates both local file digests and
the bridge publication owner's accepted-byte cache. An unreadable digest cache
blocks sync startup with its repair reason and preserves its bytes; a missing
cache starts empty. Failure-history read gaps mark every filename stem from the
shared snapshot manifest stale. Cancelled memory/graph reads stay unavailable
without a second read; a failed transcript generation recheck publishes explicit
unavailable transcript rows, retaining the phone's accepted history.

Memory snapshots and mutation readbacks project canonical layer, importance,
confidence, pin and tag values without invented defaults. Unavailable optional
values remain absent. Memory proposals carry only their canonical `createdAt`;
the synthetic `first_seen`, `last_seen`, `staged_at` and unused `resolved_at`
fields are removed. These shared wire changes ship with the companion TestFlight
and rebuilt Mac projections in the same release.

Each phone action returns its own verified response or throws its own typed
failure. `responseUnconfirmed` distinguishes response and transaction deadlines.
The shared sync banner is presentation only; overlapping actions never recover
their error from it. Signature verification keeps its bounded wait/recovery path,
and canonical readbacks precede rejection presentation.

A Desk item that waits on them is an ask addressed to them (`needs_user:<handle>:<digest>`), told once with their
doors; when the item stops waiting or its question changes, its owner settles that ask.

The text coalescer accumulates deltas and emits full-text replacements; final answers take precedence.
The first nonempty delta is eligible immediately; later snapshots retain the
one-second/120-character batching. While the phone app or an audio talk session is active, its bridge
fetches incoming CloudKit messages with a 750 ms pause between completed reads,
alongside push delivery. It applies fetched chat before reading notification
records, and advances the shared cursor only after both families have been read.
The foreground fetch does not wait for pairing/catalog/snapshot refreshes.
When a drain is already running, the foreground poll skips that tick without
queuing another pass or a control read, so slow reads can finish and release
setup and refresh callers. Push and explicit recovery retain their queued rerun.
A completed successful foreground read clears an older iCloud account warning
only if no newer account failure arrived during the read; skipped or failed
reads leave the warning intact.

Foreground or active-talk phone contact renews a signed `phone.foreground` status singleton
every 30 seconds over the existing `NAStatus` transport and silent subscription.
The existing presence beat is Mac-to-phone; this phone status supplies the
other direction without creating a chat turn or a new transport. The Mac receives
on push, launch, network/KVS wakes and explicit refresh. Lost push availability
reports its cause and does not activate a timed drain.
Pairing/status reads run in one retained task beside Mac chat fetching, at most
once per 30 seconds unless a status push asks sooner. Phone receive/contact work
cancels on inactivity without an active talk session, or bridge teardown. A missing, invalid, late or unreadable
beat never declares a peer offline or a delivery complete; it simply cannot
renew that window. CloudKit latency, throttling and the first foreground wake
remain measurable limits, not a delivery guarantee.

The Mac records payload-free `phone.pickup` (signed-envelope send time, Mac
forwarder arrival and correlation) and `phone.deltaAccepted` (sequence accepted
by CloudKit) as details in the record. The phone logs `[phone-pipe]` with the
same correlation/sequence and write/receive times. These distinguish pickup,
provider time and delivery for a real exchange; missing evidence remains
unmeasured. Cross-device differences depend on clock alignment; envelopes
currently encode send time to whole seconds. Transport acceptance is not phone
delivery. Terminal delivery still uses the existing receipt journal.
Every nonempty text delta immediately produces a full-text replacement. There
is no time or character threshold before publication; the transport mailbox
conflates unsent snapshots. This applies to resident and helper phone turns
and to the anchored conversation relayed from other doors. Final replies keep
the words already streamed before tool calls and take precedence over pending
snapshots. See the [turn timeline](ANATOMY_OF_A_TURN.md#5-the-model-answers-or-requests-a-tool).
The session delivery owner attaches the forwarder's mounted stream without a
caller-supplied sink. Approval and other continuations resolve the saved phone
route through that same owner; their snapshots and terminal reply both carry
`live=true` and the new turn's run id as correlation, so the phone settles the
bubble that streamed. The original request correlation remains for recovery of
that original run. Unavailable live delivery never discards the saved transcript.
Every recovered reply serializes its canonical ending, including on the
original correlation: failure, Stop and waiting/interruption use `error`,
`cancelled` and `incomplete`; completed replies explicitly use `final`.
An absent canonical ending is `incomplete`, never success. The phone decoder
keeps `incomplete` on original correlations too, and an omitted kind cannot
complete a bubble (requires the next TestFlight). Send admission and the retained receipt reader
share the same canonical-reply classification.
Siri/Shortcuts and Chat share the phone terminal classifier: only explicit
`reply`/`final` succeeds, `error`/`cancelled` fails, and `incomplete` or missing
kind ends the wait with the actual words and unconfirmed status. Nonterminal
activity keeps the bounded intent wait open. Signed rejections fail the intent
through their existing refusal path.

Phone-request persistence reads only its current `History` object (`pending`
and `replay`). The old array reader and retired `sent` flag are removed after
read-only inspection of the installed phone's empty current history. Existing
unreadable history is reported and never rewritten or executed as an empty queue.

A named phone Stop is saved in the existing `icloud/chat_transactions` admission
row before the Mac acknowledges holding it. The old five-minute, 64-entry
process-local Stop map is removed. Stop-only rows survive restart and are not
terminal-retention candidates; absent requests leave their Stop evidence held.
Admission checks that exact message/session before dispatch, and the forwarder
checks it again before starting its task's work. Late arrival receives a
`cancelled` reply without executing the request. Unreadable evidence blocks
admission; a failed Stop write is reported as an action error, never acceptance.

Incoming turns publish snapshots, progress, tool presentation and notices
through one retained sender, conflated by channel. Stream
consumption never waits on those sends. Before a terminal reply, the sender
discards unsent optional values. Its admitted send settles alongside terminal
delivery and is joined before the forwarder exits, so its network round trip
does not hold the final reply. The phone ignores optional events for a resolved
correlation. Transport wake nudges use the same retained, conflated mechanism outside the send's return
path; text deltas never schedule the Drive retry-nudge plan.

## Remote actions and snapshots

The phone sends signed `NativeAgentShared.InboxAction` envelopes and waits for Mac responses.
Current action payloads use `sessionId`, `runId`, `eventId`, `direction`,
`deviceId` and `bundleId` where those fields apply. A Desk task is
`submitDeskTask`, which starts a line of theirs that carries it ([Desk](DESK.md)).
Memory, approval and inbox actions name `memoryId`, `approvalId`, `itemId` and
`actionId` respectively. Dispatch does not translate older action/key spellings
or substitute another object's ID. Notification receipts require their explicit
direction; Stop refuses unsupported payload fields before resolving any target.

`faceAction` sends `{page, row, action, value?}` in that same signed envelope.
The Mac passes the exact page and row ids, action id and optional string value
through `DeviceSyncHost` to `engine.pages.act`; the page's owner answers it.
A successful answer returns `status:ok`, `ok:true` and its words as `message`
when it has any. A part refusal returns `status:error`, `ok:false` and the
owner's `code` and `message`; a page without an action owner says it has
"nothing a row can do". Missing or empty page, row or action fields are refused
before dispatch. Buttons submit their action id; controls submit `action:set`,
with `value:on` or `off` for a toggle, or the selected option id for a choice.
Phones before faces never send this action.

`MobileHelperEdit.fastIsSet` is a required Boolean in edits and receipts.
The current phone writes true only when its pinned Fast control was submitted;
false leaves that control unsubmitted. Missing intent fails decoding before a
helper mutation. Helper drafts/details are in-memory projections, not another
persisted edit format. Mac and iPhone ship this contract together.

The signed response carries the approval owner's `result_class` through string serialization; Mac and iPhone transaction settlement share `InboxAction.responseTransactionState`, preserving approval waits and unknown execution independently of decision acceptance.
Remote cognition consumes that same verdict for provider-failure observations.
The Mac's ledger-replay `code: unknown_outcome` is also an unknown verdict,
including when the signed reply has `status: error` and no `result_class`.
The Mac ledger boundary requires its transaction identity, `ios_to_mac`
direction, canonical `msgId` and 64-character lowercase SHA-256 `actionDigest`.
Replay compares both bindings and the action name. Unbound or unreadable rows
remain intact and unavailable: they cannot authorize execution, supply a replay
result, be overwritten by a new reservation, or establish terminal retention.
Both transports use the same replay response owner when an already-dispatched
action has no recoverable signed result. Stale pending Drive recovery uses that
owner too; missing results carry `unknown_outcome`, never a confirmed failure.
The phone saves that response as `outcome_unknown`, retains the original pending
signed envelope until terminal settlement, and presents it as **not confirmed**.
The phone requires the signed response's current `msgId`, `transactionId` and
`action`, checks them against the mailbox and any retained request, renders that verdict, and checks
applied state and exact selection tuples separately. Transport success proves no completion. An `outcome_unknown` ledger row has already dispatched; redelivery replays its retained signed response without executing the action again.
`iCloudSyncEngine+Actions.swift` owns submission and verified response waiting;
`Transactions` owns pending envelopes, pairing reconciliation and verified persistence.
`Commands` sends subject commands. `MacSyncEngine+Security.swift` verifies signatures
before dispatch. Pairing does not replace action-specific authority checks.
`sendActionAndWait` observes the original request only. Signature, expiry and other
refusals never create a replacement action; a new submission requires the person.
Pre-dispatch errors retain their own cause. Once dispatched, missing confirmation
or a failed local receipt is `responseUnconfirmed`, shown as **not confirmed** in
Mac Tools; a confirmed Mac refusal remains `macRejected`. Settings likewise say
an unconfirmed save could not be confirmed, never that it was not changed.
Absent response files remain optional; present unreadable, malformed, unverifiable
or uncorrelated evidence raises a checked error and remains retained. Previous-pairing
settlement must save its orphan receipt or report that failure. Malformed KVS progress
reports its key and decode failure through the bridge's existing sync status.
Response arrivals settle their exact mailbox identity. Launch recovery belongs to
the action mailbox, with a five-second inherited wait ceiling and at most 64 ledger
entries decoded. A damaged entry reports its own gap while siblings proceed; excess
entries remain retained with an incomplete-recovery message. Lightweight snapshot
refresh never runs action recovery. Daily retention removes an old response only
with a retained terminal response receipt, and keeps that receipt while the response
survives. Missing or unreadable ledger evidence cannot prove consumption.

Phone-local preferences also use the Mac's `setting.get` / `setting.set` door.
These requests share `phone.request`'s **iPhone Notifications → Write** switch
in **Trust → Mac → Apps and features**. Off blocks reads and changes even under
Full Mac.
With NativeAgent open on the phone, `setting.get {setting:"phone.settings"}`
returns the phone's own directory; its returned ids reach the same owners as
the native controls. Signed `PhoneRequest` kinds `settings.read` and
`settings.write` carry these operations. Enabling senses, saved place sharing
or Lock Screen task names uses the existing phone request sheet for consent;
appearance and lowering do not. Requested inspection includes disabled saved
place names and switches, but never their coordinates. No value is copied into Mac defaults. Read and
change waits are bounded at 20 and 60 seconds, and an unanswered or expired
request confirms no outcome. Exactly one paired phone is required. New place
capture, place deletion and pairing/repair remain phone setup actions. See
[Settings](USER_GUIDE.md#settings) for the user and agent contract.

The agent can ask the paired phone through `app` action `phone.request` for
`location.current`, `photo.pick` or `photo.capture`; `phone.location` asks only
for location. Keep NativeAgent active on the phone and choose **Share location**,
**Choose photo** or **Open camera**, or cancel. Location and camera permissions
apply. Requests use CloudKit, one at a time, and expire after
`wait_seconds` (1–120, default 60; `phone.location` uses 20). A Mac timeout ends
its wait; it does not prove the request was undelivered or undo a phone action.

The Mac publishes separate snapshots for sessions, trust/providers, approvals,
memory, skills, tools and other mobile views.
Each snapshot uses one whole-document decoder. Malformed rows, oversized data or
failed acquisition report their exact source in snapshot health and retain the
previous accepted data as unavailable; no survivor list becomes the snapshot.
Phone Refresh rereads received snapshots; it does not request a new Mac publication.
For a damaged projection, ask the agent on the Mac to run
`app {"action":"doctor.repair","args":{"check_id":"icloud_bridge_state"}}`.
That existing repair reaches `MacSyncEngine.repairPhoneSync`, rebuilds and republishes
phone views, and requires a later healthy reading to prove recovery.
Each Mac snapshot publication pass also reads `engine.pages.snapshots` on the main
actor and stages `faces.json`: a dictionary from page id to the shared
`PartFaceSnapshot`, retaining its source epoch, availability, face, error and
owed state. No second page model or epoch is kept by sync. An empty owner read
stays an empty dictionary; it says nothing about removal or readiness.
Failed or unavailable faces retain the owner's status and error.
The file publishes alone in the `faces` group, CloudKit status
`mobile_snapshot_faces_v1`. The Mac never names this group in the KVS ping:
phones before faces ignore the new group and keep reading the existing files
with their existing shapes. Phones that support faces fetch that group with
each ping and observe its record.

The off-main `MobileSnapshotBuilder` admits whole faces in page-id order against
the shared codec's 800 KiB status and 8 MiB uncompressed envelope limits. A face
that would exceed either bound is left out of `faces.json`; its page id and
budget reason are named under `faces` in `icloud/snapshot_skips.json` and
`snapshot_staleness.json`. The bounded file still publishes, including `{}`
when every candidate is omitted. Omission never means the page was removed.
A later pass with no omissions clears that skip; an encoding, write or
publication failure retains its own cause through the same skip accounting.

An oversized outgoing group fails that group without shedding files; faces
are bounded individually before the group is published, as described above. Unreadable
staleness bookkeeping stays preserved and unavailable. Chat replies use the
bridge/transcript owners across lifecycle changes without a per-chat transport
nudge or transcript backstop read.
All snapshot scopes hold one writer through publication and staleness bookkeeping.
Publication carries committed wire bytes and reads only unchanged files; scope selects payloads.
Drive initializes through `setup(docsURL:)`; CloudKit initializes its local
snapshot and mailbox directories through `enableCloudKitSnapshotCache()`.
Drive setup, outbox/archive batches, response reads and retained action files run
through Shared `VolumeIO`; `PhoneSigningIdentity` owns asynchronous signing.
VolumeIO admits only resident regular files before reading bytes. Dataless
placeholders report unavailable acquisition, never empty or damaged content.
Its shared continuation releases a waiting caller on Stop or the inherited
deadline (30 seconds when none was supplied). Queued work that has not started
is skipped after cancellation; issued filesystem operations retain their own
completion and cleanup. A write whose wait ended has an unverified commit,
never proof of non-dispatch. Drive reply receipts keep `commit_unverified`
until the actual queued file or transport acceptance is observed; replay
reconciles those receipts before sending. Off-disk copies retain their staged
source until physical completion, even after their caller stops waiting.
`iCloudSyncEngine+Snapshots.swift` composes refresh through Shared's `LatestRead`;
`SnapshotReading` owns replica/byte decoding and `Transcripts` owns reconciliation/history:
lightweight and targeted readers share each snapshot's owner. The unreachable
full-refresh branch and its exclusive bundle/loader and delivery flags are removed.
Activity publishes Inbox and work overview
once through the Inbox owner before queuing Memory reads; push recovery records
Inbox acceptance immediately. A narrow read cannot retire another snapshot's pending
read. Every Trust reader (lightweight, Settings, provider controls and direct Trust)
uses `trustRead`; confirmed Trust receipts and pairing invalidation publish through
its `write`, so a pre-save read cannot replace the saved policy. Missing or damaged
Trust reads preserve the accepted policy and report unavailable evidence. Mac app-setting
rows separately share `appSettingsRead`; admitted saves invalidate pending reads
and successful row readbacks publish through `write`. Publication advances only;
each read returns its own result. Lifecycle guards protect transport/root replacement.
Snapshot loaders return value and health together; only accepted publication updates
the engine's diagnostics. Refresh outcomes carry the diagnostic text from that acceptance.
The phone displays Mac-owned state without separate tool or policy authority.
Desk kinds and statuses live in Shared. The phone derives status choices from
that vocabulary, keeping an existing blocked value visible without offering it as a destination.

## Notifications

The approval tracker observes successful snapshot availability as well as row
changes: a first empty delivery seeds its baseline, so the next pending approval
can notify without an intervening manual refresh. Before that first successful
delivery, missing or unreadable snapshots do not seed a baseline.
Local approval and Desk completion trackers suppress the initial baseline and
retain an arrival as handled only after notification acceptance (or an already
pending/delivered matching event). Failures remain eligible for the next snapshot
refresh and report their actual cause through the approval banner or sync error
and the device log. A denied authorization is an error, not a posted alert.
The APNS registration cache distinguishes absence from a malformed present
record: unreadable bytes are retained and the failure is reported, without
re-registering over that evidence. Phone announcement failures report through
the connection/sync state and device log.

Ordinary notifications use the keyless `NANotification.visible` CloudKit query
subscription, with title/body built from the record even when iOS cannot run
the app. No Apple developer account or provider key is required on the person's
Mac. Their signed records are acknowledged without a second local alert.
Every unpinned matter for them reaches their phone, its originating Telegram or
Slack thread when present, and the Mac only while they are at it. Importance
governs quiet-hours holding, not destination choice. The router retains a due
informational notice or approval through quiet hours and releases it when they
end; adverse notices bypass that hold. Delivery readouts name each destination,
so a Mac banner or thread acceptance never proves phone receipt. Explicit
phone-pinned calls still go only to the phone.
Recovered interaction cards use that same phone-pinned ledger path. Approval
alerts keep the chat-tool or live ACP origin, so Slack receives them in the
asking thread. In Telegram the thread door is the filer's single approval
prompt, settled from its saved per-chat receipt. The prompt in an asking
Telegram turn goes immediately because they are already talking to them; its
phone alert still follows the router's quiet-hours policy. A failed approval
inbox-card write owes repair without withholding the approval's alert.
The visible subscription requires the already-indexed `direction == mac2ios`,
excluding presence records, which have no direction or alert envelope.
Pairing/access pages and notification readiness use checked pairing authority:
a paired installation is ready through iCloud without direct APNS configuration.
Readiness does not prove delivery or display; unreadable pairing stays unavailable.
Requested results travel as `NAChatMessage` records and keep their existing
signed bridge reader and local renderer. Chat, pairing and status subscriptions
remain silent. If a Mac has optional provider credentials, direct APNS only
wakes sync with `nativeAgentWake: notification`, for both event kinds; no config
is normal and is not an error. Event kind selects the renderer before transport.
An APNS or subscription failure never selects another visible mechanism.
Chat and visible-alert registrations are independent and name their own failures;
incoming chat readiness reports only chat registration. Ordinary alerts carry no
urgency from the router and use the system interruption level; adverse
importance bypasses the Mac's quiet-hours hold, while iPhone Focus still applies.
Requested results retain their signed reader's urgency handling.
The Mac retains each immutable publication before sending, so retries preserve
its original signed timestamp and content; unreadable or conflicting publication
state surfaces a repair failure with its bytes preserved. A retry sends the
retained publication itself; the incoming attempt must match its words. A send
whose server acceptance is unknown leaves the delivery prediction open; it is
never reported as a failed delivery.
Delivery receipts name the published record and optional wake; a signed phone
receipt confirms record receipt, not a banner. Without CloudKit, ordinary alert
publication refuses rather than claiming that a Drive record will render it.
The body's delivery belief uses the live kernel's publication-failure and signed
receipt prediction; optional APNS history cannot judge keyless notification health.
Unknown evidence clears the optional `notificationPathHealthy` projection to
unknown; peer reachability cannot establish notification health. The shared
living-status body now omits that Boolean when unknown, so coordinate this Mac
and phone update (the iOS snapshot reader decodes `OrganismLivingBodyFile`).
See [phone alerts](apns-push.md) for the subscription contract, optional private
APNS configuration and required coordinated Mac/TestFlight 38 install. Build 37
would locally render the same ordinary record as the visible subscription and
can repair the shared subscription to silent, so it must be retired first.

In the foreground, a reply for the conversation currently visible in Chat
suppresses its system banner and sound even if its chat record has not arrived
yet. Replies to other conversations keep their alerts. A notification must name
its session; a first reply may additionally match its exact pending correlation
while the visible conversation awaits its new session. Missing session identity
does not suppress an alert. Voice-note progress
says “Listening to your voice note”; only image attachments say “Reading
attached photos”. Other attachment kinds add no photo/audio progress label.

Notification taps persist one destination with its screen and applicable chat,
Desk or directed-task identity. ContentView consumes it once and hands the
identity to the destination view, including on cold launch.

Mac and phone notices use NativeAgentShared's `SystemToastCenter`, with separate
queue instances and platform rendering. Replacing an ID cancels its prior timer;
invalid durations replace the Mac notice with a sticky error and leave the phone
notice sticky. Severity defaults are 3/5/8/3 seconds.

## Source map

| Area | Owner |
|---|---|
| Shared transport and wire format | `Modules/NativeAgentShared/Sources/NativeAgentShared/DeviceSyncTransport.swift` |
| CloudKit transport/preflight | `CloudKitDeviceTransport.swift`, `DeviceCloudKitPreflight.swift` in the same shared directory |
| Mac chat bridge | `Modules/NativeAgentCore/Sources/DeviceSync/iCloudBridge.swift` |
| Mac pairing, snapshots and actions | `Modules/NativeAgentCore/Sources/DeviceSync/` |
| iOS admission/delivery, CloudKit and Drive | `iOS/NativeAgentMobile/Sources/iCloudBridge.swift`, `iCloudBridge+CloudKit.swift`, `iCloudBridge+Drive.swift` |
| iOS snapshot/action engine | `iOS/NativeAgentMobile/Sources/iCloudSyncEngine+*.swift` |
| iOS chat and share import | `iOS/NativeAgentMobile/Sources/ChatStore+*.swift` |
| Voice-note capture and recognition | `VoiceInputController.swift`, `MobileSpeechAnalyzer.swift`, `ComposerVoiceMicrophone.swift` in iOS Sources |
| Hands-free talk and voice | `TalkModeController.swift`, `MobileTalkAudio.swift`, `TalkModeView.swift`, `ChatStore+ReplyObservation.swift`; `LiveActivityShared/PhoneTalkAttributes.swift`, `LiveActivity/PhoneTalkWidget.swift`, `ControlSupport/MobileTalkRoute.swift` under iOS; `MultimodalTTS/MultimodalTTS+VoiceSelection.swift` owns Mac voice identity |
| Shared voice-note presentation | `Modules/NativeAgentShared/Sources/NativeAgentShared/VoiceNoteBubble.swift`; phone `MobileTranscriptAttachments.swift`, Mac `MessageBubble.swift` |
| Phone senses, setup and preferences | `iOS/NativeAgentMobile/Sources/PhonePlaces.swift`, `PhoneSenses.swift`, `PhoneBodyReadings.swift`; shared `PhonePlaceEvent.swift`, `PhoneSenseEvent.swift`; `AppToolRuntime/PhoneSensesGuide.swift` reads setup and exact steps on the pairing page |
| Mac person presence and evidence | `MacControl/PersonPresence.swift`; `PersistenceCore/PhoneSenseHistory.swift`, `PhonePlaceHistory` in `PersistenceCore.swift`; admission in `DeviceSync/ICloudReceiving.swift` |
