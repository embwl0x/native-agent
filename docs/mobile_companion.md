# NativeAgent mobile companion

The iPhone/iPad app is a surface of the Mac-owned agent. Keep the Mac awake
with NativeAgent open to process new work. The runtime is in
`EngineRuntime` and `ChatTurnRuntime`; mobile sync does not create another
brain. Agent's tool interface remains the single `app` tool:
`app {}` opens their home, while `page`, `item`, `find`, `action` and
`script` reach its contents and actions.

## What the mobile app exposes

The main tabs are **Chat**, **Today**, **Desk**, **Settings**, and **More**.
A page the Mac publishes as a face (`faces.json`, delivered in its CloudKit status group) is
drawn by the shared `FaceView`: Today, the Desk, their home, Memories, Personality,
Trust, Providers, Connectors, Capabilities, Helpers, Diagnostics and the Mac's settings
under Settings. A row's link opens its place on the phone (a faced page or a
saved run in the same stack; Chat, Today's queues, a card, the Desk or the browser
through the shell), or says the place opens on the Mac; a row's action goes to the
page's owner on the Mac as the signed `faceAction`, and its answer or refusal shows
where the reader is, as the app's toast.
Each face section is a native section and each row a native row in the inset grouped
list, with a 44-point minimum. Swipe or long press a row for its actions; destructive
actions ask once. Search filters the rows already received. Draft field text and open
folds belong to the page session, so scrolling cells away and back does not discard them.
At narrow widths the value or control sits below the title and detail, and actions
beyond two move into a menu. Embedded conversation cards use the same row without
creating another list.
Settings opens with a System/Light/Dark switch; this iPhone's own settings (appearance,
connection, Places, senses, Live Activities) remain on that page beside the Mac's settings
face. Memories is behind More; memory proposals are Today's "Memories to keep".
More follows the phone's surface layout: Rooms holds the agent's home, Memories, Helpers, Agents,
Capabilities, Skills & Tools, Personality, Connectors and Trust; Setup opens Settings;
Power user holds deeper views. Settings nests Telegram and Providers.
More uses only the Mac's accepted layout. A missing or unreadable refresh retains
that layout; an unreadable refresh reports its cause. Before the first usable delivery, More
shows layout unavailable with connection recovery. The phone neither seeds nor
repairs a Mac layout. Approvals and notes are one Inbox, the Mac's Inbox face:
Today's queues, approval and card links, notifications and a note's card in chat
all open it, and its rows answer through the page's owner on the Mac (an
approval with this phone's verified identity). **Earlier** folds settled matters;
decided cards lead with the saved outcome and its cause or result, before the
original request, in both Inbox and conversation cards. The Mac supplies the same
row in `faces.json` after relaunch; unavailable saved approval results say
**Unknown** with their cause. See the [card history contract](approval-schema.md).
Memory proposals show an empty verdict only after their own snapshot has
been read successfully; a late or missing first snapshot remains unavailable,
with a reconnect/refresh remedy.
Providers carries no secret: keys and sign-ins are entered only in protected entry
on the Mac. Provider request rows say **Enter on Mac**; their setup action is
available only at that door. Tapping or opening a request never verifies the
account; its saved provider auth status must be verified **Ready** to settle it.

The phone has no training-proposal queue.
Memory reviews and approval decisions remain on the phone, and Trust owns dream
and REM settings. The Mac still publishes an empty training-proposal tombstone
for older phones.

Chat supports sessions, streaming replies, queued sends and attachments.
The text composer sends on Return after text composition has finished; Return
while the keyboard holds marked text belongs to the input method.
Composer height measurements belong to the text and its current UIKit font;
changing Dynamic Type discards measurements made with the previous font.
Its shared sync transcript projection owns versioned snapshots, history pages
and live bridge updates by row/run identity. Version checks read retained index
rows without preparing conversation titles or navigation. Admitted live and phone replies
share terminal and delta mutations; only visible replies produce UI effects.
Snapshots and history use one concrete shared transport row, metadata and
attachment values. Every projected row, including history beyond the snapshot's
last 80 person-visible rows, also
carries the Mac's reading of its seat, provenance, tool outcome, receipt or owed
decision. Tool runs carry the presentation part's prepared headline on every
fold row, so a page beginning inside a run has its headline, and any prepared
detail words on their rows. Missing preparation remains pending; failed headline
or detail preparation carries the owner's diagnostic in that face rather than
appearing as an indefinite waiting line. A failed headline is retried on the
next snapshot; an unchanged cached failure is logged once. This additive
face preserves older phones' tool events and interaction fields. Interaction
rows publish `interactionJSON`, `interactionDescriptorJSON` and
`interactionSessionID` together from the same prepared card while builds 61/63
consume them; the continuation and credential values never enter that payload.
The phone projection applies Shared's canonical `TurnSecretRedactor` to complete
transcript words, display metadata, faces, tool events, card/descriptor strings,
attachment labels/recognition text and other-room reading copies before bounding
or serialization. Tool-input JSON uses the same recognizer with secret-named
argument values withheld while preserving JSON syntax. Unreadable input is a
named gap on that row, not a failure of its siblings. Row, session and run
identities remain unchanged. This is a projection: saved Mac transcripts are
never rewritten. Outgoing replies, cumulative deltas and KVS notices use the
same text policy before signing (and before notice clipping). Existing retained
signed publications whose bytes would change remain unresolved through the
publication owner's conflict result; they are never silently repaired or resent
with their original secret-bearing body.
It remains subject to the existing 2 MiB chat group budget. The phone draws its
conversation from these rows, tool runs and asks included, through the same
`TranscriptBuilder` as the Mac. The phone's own sends and streaming replies have
local presentation. A Mac-owned row without its face shows its missing presentation
evidence; missing card or attachment references remain visible. Envelope blocks
render their carried words and trouble blocks show an attention message. Mac transcript metadata and
phone projections use the shared checked `ChatMessageMetadata` codec. Its
canonical tool keys are `tool_name`, `input`, `result_summary`, `result_status`
and `approval_id`; retained Mac
receipts with camel-case keys remain readable there until their records and
writer move together. Invalid metadata makes that transcript read unavailable;
unreadable origin/envelope values retain an explicit attribution gap.
Every new session creator writes transcript generation zero for its initially
empty transcript; later transcript writes and clears advance that same index
counter. A missing generation never authorizes clearing phone history.
History pages merge both raw records and projected messages in the Mac's order,
by row identity. The historical membership includes tool records, so overlapping
later snapshots retain their tool rows and any Mac-provided face/provenance.
A snapshot with no overlapping records, or an authoritative empty transcript,
does not retain that historical page.
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
the mounted ChatView or talk cover. Push, activation, network/account changes,
explicit refresh and App Intents request reads. Pending exchanges show waiting
status immediately and remain observable until signed progress, rejection,
cancellation or a terminal reply supplies evidence. Silence changes no outcome.

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
Dictation appends recognized words to that draft. Send after dictation submits
in the same main-actor callback that checks the recording's conversation and
appends its final words, before a session change can replace the draft. Session changes and
backgrounding cancel capture and prevent late recognition from writing into
another conversation. Capture ends on the person's Stop/Send/Cancel or an audio
failure. Startup waits for permission, assets and audio readiness. After Stop,
final recognition supplies the wording; while it is pending the capture shows
“Waiting for final recognition · Cancel to discard”. No clock submits partial words.

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
callbacks; Reduce Motion keeps it still. The speech detector's endpoint and the
recognizer's final regions determine submission. An endpoint with volatile words
shows “Waiting for final recognition · End to cancel”; final results submit the
observed words. Recognition stays open, and later results keep only words after
those already sent. A short soft sound confirms that the phone saved the message
to ordinary chat, before the Mac's answer.

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

Startup remains visibly pending until permission, assets and audio readiness
complete or End cancels. Interrupted audio, a disconnected route, a recognition
error or a changed pairing/session ends the call visibly. Unsent recognition
captions remain selectable on that ended face. An accepted message says it is
waiting for the agent; silence neither settles nor resends it. End releases
capture, speech and the activity exactly once and returns to chat, where accepted
messages already live. Ending the call does not cancel accepted work on the Mac.

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
Each serialized Places mutation compares its typed before/after state;
an unchanged reconciliation skips its checkpoint and observable state publication.
Pending signed envelopes participate in that equality, so a changed delivery
state still saves even when the visible place list is unchanged.

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
Wi-Fi/cellular/wired/other or explicitly unavailable. A pending callback stays
visible as waiting; switching the sense off cancels observation. A satisfied path does not establish Internet access.
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
phone. The fetch runs off the main actor and its completion owns the result.
While pending it remains visible, with the sense switch as cancellation. Permission
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

Readings happen at launch/foreground, each message sent from the phone, a Places
event, a significant-location change (only with an existing Always grant), or the
existing background push refresh. A wake re-reports an unchanged reading older than
ten minutes, so unchanged does not read as unknown on the Mac. A message from the
phone tells the agent the person is on the phone and carries the fresh readings of
the senses that are on. They never start continuous location or motion updates and add no
periodic background job or audio assertion. Battery, audio-route, Music and
PhotoKit notifications can also invalidate a reading while the process is
running; they do not keep it running. iOS controls wake delivery. Motion queries
wait for Core Motion's callback or switch-off; a pending reading is visible rather
than becoming unknown after a deadline. Signed pending changes remain on disk
until a correlated Mac receipt, explicit cancellation or checked pairing retirement.
Unreadable pairing material preserves the original pending identities. Neither
silence nor elapsed time authorizes a resend or declares delivery.

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
An unreadable claim retains its actual cause. CloudKit completion decides the
claim; later pairing/account/network or explicit refresh events can reconcile it. The phone still reads the same `pairing.mac` record and fields.

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

The shared `CloudKitDeviceTransport` owns CloudKit private-database transport.
The Mac retains Drive readers for unresolved saved data. The phone uses only
CloudKit; its unreachable Drive setup, query, reply archive, snapshot reader
entry and action-file publisher are removed. Saved Drive files stay untouched
and are not recovered at launch. Selection
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

The send follows the original CloudKit operation's completion or error. There
is no app clock racing a save or limiting its SDK resource duration. Server
acceptance means stored bytes, never a Mac read or completed work. A signed Mac
event for the exact correlation proves arrival even when it precedes save return.
A real transport error with unknown acceptance remains unconfirmed and retains
the original signed envelope and request identity. No confirmation polling or
silence-triggered re-signal runs. Explicit Retry remains the person's decision;
an ambiguous save or stable-ID conflict reads that exact CloudKit record. Matching
record type, direction and signed payload prove acceptance without another write.
Different bytes remain a conflict; a missing or unreadable record retains both the
save and read causes as unconfirmed. A missing reply never proves completion.

Unfinished exchanges restore the request and delivery evidence. The phone does
not restore a confirmation deadline, start a replacement upload, or turn a missing
local envelope into failure. Signed progress/rejection/terminal replies,
cancellation and checked pairing retirement decide their state.

Switching conversations can cancel visible observation without deleting the
durable exchange or signed request. The same correlation remains available for
late replies.

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

The Mac's Drive inbox authenticates envelopes before claiming their filenames. An
existing processing claim is preserved: identical authenticated bytes coalesce;
conflicting or invalid incoming bytes are preserved under their digest in
`processed`, with conflicts reported. A queued handler keeps its claimed path.

The phone's CloudKit ingress uses one verification and consumer boundary.
Accepted phone requests, action responses, notifications and chat
share one handled-record receipt. Notifications schedule and actions persist
before consumption; chat callbacks follow verification and the lifecycle check.
The phone has no Drive archive callback or alternate file-consumption path.

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
pairing-key read retains a verified mismatch across a failed read. Without a
current successful key read, connection assessment carries the read cause or
waits for evidence; it cannot call the pairing healthy.
The setup
incoming drain retains its elapsed-time log. Pushes are hints Apple may drop and
CloudKit has no stream, so reading never rests on a push alone: an open phone reads
every 0.75 s, reads signed Mac presence and renews its own presence every 30 s.
The Mac's transport owns an independent 20-second receive beat, and reads at the
phone's 0.75 s pace while the phone has spoken in the last
60 s. A turn holding the chat drain leaves that pace reading controls, so Stop still
lands. Each side keeps one dirty follow-up behind an active drain.
Catch-up has two facts: incomplete work stays owed; a completed failed incoming
or status read raises the catch-up warning. A skipped/coalesced or still-running
read alone raises no warning. Only after both the incoming query and the entire
observed status pull succeed does a successful lightweight cache refresh clear
the owed work and any catch-up warning.
Each observed status must be readable and accepted, or already applied at that
server revision. Missing values, rejected handlers and skipped drains
leave catch-up incomplete; a successful sibling handler or local cache read
cannot clear a warning from a failed catch-up read. Snapshot status acceptance
also requires the group's refresh to succeed. Damaged snapshots retain their diagnostics. The typed status
result distinguishes completion from its count of accepted values: zero alone
proves nothing, and a complete pull does not prove the Mac published every update.
Overlapping drains coalesce without losing a paired phone's requested cache
refresh: the incomplete condition is retained before coalescing. Any successful
active or later drain, including a push or queued rerun, finishes that outstanding
catch-up through the same remote-pull and cache-refresh checks. When the fast
foreground receive completes, it does no status or cache catch-up. The open
phone's existing 30-second presence beat admits at most one catch-up through
the full bridge drain, only while catch-up is owed. A busy drain is left to its
owner without requesting a rerun; a failed read or busy cache waits for the
next presence beat or an activation, push or recovery event. Nothing owed means
no beat-driven catch-up. One retained catch-up task keeps chat and presence
renewal independent of status latency, holding its slot until its actual exit.
The drain remains bound to its pairing and account-failure generation. Leaving
the foreground or ending background talk cancels the presence and catch-up tasks.
The actual failed incoming/status read cause stays in the sync warning alongside
any snapshot error until catch-up completes or the connection is reset. Failure
does not change either receive or presence cadence.

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
An accepted no-text publication completes its retained ledger row before recovery
announces completion. Later drains skip that settled row; repeated settlement
does not rewrite it.
The stale pending-command sweep also requires both the response-delivery and
inbound-action receipts before recording the command as processed or archiving it.
Action responses use a stable identity derived from their correlation and signed
response bytes, so an unknown response and its later terminal response remain
distinct outcomes. Every arriving action response, including an ordinary Mac
Tools result after its waiter ended, passes the inner signature and transaction
checks before its terminal receipt retires the pending envelope.
Notification, volume and Spotlight controls retain their observation tasks and
show Cancel on the initiating control while waiting. Cancel or leaving Mac Tools
ends observation and re-enables the control; the original signed action stays
available for its eventual response. Policy changes cannot disable that Cancel.
Cancellation changes only a cancellation error's presentation; a concurrent Mac
failure retains its cause. A Retry while that control is busy reports the open
wait and its Cancel lever instead of silently dropping the tap.

Work snapshots carry the producer's latest 64 activity rows. A held phone or OS
activity omitted from that window is reconciled by exact experience identity
through the signed action owner, including after suspension. The response uses
the same canonical activity projection; only its real terminal state ends the
activity. The Mac's push sender uses that exact lookup for registered activities
outside the snapshot window, even when no prior pushed content was retained.
Open work receives its actual update; terminal work receives an end. Missing or
unreadable evidence leaves that activity unresolved with its cause while other
activities proceed. Reconciliation
is event-driven and pairing-bound, including while Lock Screen Live Activities
are off: the conversation's working indicator still reads these rows. Work content
carries the experience store's last event `sequence` (zero at birth); snapshots,
reconciliation and local Live Activity updates reject older sequences instead of
ordering by ISO-second timestamps. A missing sequence is unresolved with its cause.
The optional numeric field leaves builds 61/63 decoding the same content fields.

Steering read/return outcomes and no-text terminal replies
retain one signed identity per offer attempt in the same publication ledger.
Admission failure sends the existing nonterminal signed `notice` kind with its
steering correlation and cause, so builds 61/63 do not settle away queued input. The
phone pauses that conversation's queue, retains the input and failure together,
and shows the cause beside the queue control until the person acts. Snapshot
success cannot clear that cause. The initial action acknowledges the offer;
settlement runs independently of control traversal so Stop can reach its owner. A
no-text terminal uses `no-post-<digest of correlation>` and keeps `live`, `silence`
or `readBy` in its signed final envelope; failed delivery stays `publication_owed`.
Completion notification follows observed transport acceptance. Failed delivery remains owed and is re-signalled on existing receive or
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

Each phone action waits on its correlated response, explicit cancellation or
owner closure and returns its own verified response or typed failure. Siri uses
the same retained request and event source. The shared sync banner is presentation
only; overlapping actions never recover their error from it. Signature validation
and canonical readbacks precede rejection presentation.

A Desk item that waits on them is an ask addressed to them (`needs_user:<handle>:<digest>`), told once with their
doors; when the item stops waiting or its question changes, its owner settles that ask.

Receive drains run on CloudKit push, lifecycle/account/network recovery and
explicit refresh. One active drain retains a requested follow-up rather than
polling or dropping it. The foreground/talk phone's 30-second contact loop reads
Mac presence independently of message reads. The Mac's separate metadata drain follows
receive/status events and completion, without a 30-second throttle.
A missing or unreadable peer message establishes no disconnection and completes
no delivery. KVS wake hints are sent once after transport acceptance or a durable
Drive commit; the one worker awaits each real synchronize return, with no delayed
1/3-second nudges. Local synchronization never proves recipient acceptance.

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
Resident turns begun on the Mac also carry their existing writing movement
through `ChatLiveTap` and the live relay as `kind: writing`, correlated by run.
Each changed writing line takes a fresh message id for its immutable CloudKit
record; consecutive equal lines coalesce in the relay's per-run state. A line
repeated after different movement also has a fresh id, so phone message-id
deduplication cannot discard it. Run correlation keeps them on the same bubble.
It uses the phone's existing working line and cannot settle the bubble; only an
explicit ending does that. Unsent movement coalesces and an ending takes its place.
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
`actionId` respectively. The deployed builds 61/63 still send `approveApproval`,
`rejectApproval`, `cancelApproval`, `inboxAction` and sealed `interaction_action`.
The Mac translates those envelopes to its current approval transaction or Inbox
row, preserving verified paired-device provenance and their readback fields.
There is no second card executor, no credential admission from these forms, and
no substitution of another object's ID. Failed readback preserves the completed
decision and names the missing read; it never publishes a fabricated absent row.
Notification receipts require their explicit
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

`faceRead` is a signed read, outside the cognitive `observed` path. Its payload is
`{request:<encoded DocumentRequest>,cursor:<scalar offset>,revision?:<digest>}`. The Mac
passes the verified device separately to the owner; payload fields cannot claim an identity.
The reply's `page` encodes `FaceReadPage {id,cursor,text,next?,revision,face?}`. Each chunk has
at most 4,096 Unicode scalars. Only the first carries the passive document projection,
limited to 16 KiB; the complete signed CloudKit record is checked against the history
reply's 256 KiB budget. Continuations reread the canonical owner and require the same text
digest. A changed document, invalid cursor or mismatched reply fails with its cause and
never joins revisions or retries. No document item is added to `faces.json`.
The phone retains the demand above list cells and uses the shared TextKit view to select,
find and copy. With no Mac reply it shows **Waiting on your Mac** with **Cancel**; the
response event, connection lifecycle or explicit cancellation settles the waiter, never
a clock. Cancel stops the phone's waiter; it neither claims that the Mac ran nor retracts
the already signed read. The saved context disclosure remains Mac-only. Memory document
reads apply the memory owner's iOS disclosure policy.

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
place names and switches, but never their coordinates. No value is copied into Mac defaults. The current phone waits for the person
or owned action completion, with cancellation; no local expiry infers its outcome.
The Mac call still receives the enclosing operation's deadline from its action
owner, so that outer wait remains a separate limit. Exactly one paired phone is required. New place
capture, place deletion and pairing/repair remain phone setup actions. See
[Settings](USER_GUIDE.md#settings) for the user and agent contract.

The agent can ask the paired phone through `app` action `phone.request` for
`location.current`, `photo.pick` or `photo.capture`; `phone.location` asks only
for location. Keep NativeAgent active on the phone and choose **Share location**,
**Choose photo** or **Open camera**, or cancel. Location and camera permissions
apply. Requests use CloudKit, one at a time. `wait_seconds` still supplies the
required `expiresAt` wire field decoded by deployed phones (1–120, default 60;
`phone.location` uses 20). The current phone and Mac request channel do not use
that field to expire execution. The enclosing Mac operation deadline still ends
its caller's observation; it proves no phone outcome and undoes no action.

The Mac publishes separate snapshots for sessions, trust/providers, approvals,
memory, skills, tools and other mobile views.
Each snapshot uses one whole-document decoder. Malformed rows, oversized data or
failed acquisition report their exact source in snapshot health and retain the
previous accepted data as unavailable; no survivor list becomes the snapshot.
Unknown face seats, styles, tones and action roles are decoding failures; a
malformed optional face or experience element cannot silently become absence.
Phone Refresh rereads received snapshots; it does not request a new Mac publication.
Snapshot payloads are state. Required installed-phone fields keep their names,
types and bare-object shape. Overview and organism hold their last payload and change time through
`MobileSnapshotBuilder.state`: equal non-clock state returns the committed file's
payload, including its clocks, across launches. Comparison uses the file's encoded
date precision; unreadable saved copies report their file's build failure.
Integrity repair explicitly reconstructs the affected derived files from their canonical
producers, including failed files whose cached digest is absent. An unreadable
byte comparison is logged and the producer's coordinated replacement proceeds;
only a completed write establishes its digest and publication bytes. Replacement
failure remains a named failure for that file.
Health carries the engine's `launchedAt`; the phone derives uptime from it when drawing.
Every encoding writes that field. Existing snapshots without it decode their `startedAt` launch;
a present but unreadable `launchedAt` fails decoding.
Equal health facts reuse the committed bytes, including the encoding-time uptime sample
required by installed phone builds 61/63. Telegram preserves
the actual successful-poll evidence while retaining `observedAt` for equal state. The first state is dated
at its launch read; a changed state advances time by at least one encoded unit
(milliseconds for overview, seconds for organism's Date codec), even across a clock correction.
The writer compares the complete canonical sorted-key payload bytes; it has no
clock-exclusion map. An unchanged payload writes no snapshot, digest metadata or
transport notice during an ordinary pass; integrity repair and requested
republication keep their explicit demand. Valid committed state retains its producer clocks;
repair reads the stored change clock independently of the full payload. An equal
decodable state retains its clocks; a changed or damaged payload advances from
the newest of that stored clock and the reconstruction time, even after a backward
clock correction. Damage to another field cannot discard an intact `capturedAt`
or `generatedAt`. Reconstruction without a readable prior clock dates the copy at that event.

| Bare payload | Installed builds 61 and 63 decode | Meaning |
| --- | --- | --- |
| Health | `uptimeSeconds: Double`, `startedAt: Date` | Encoding-time elapsed sample and engine launch, required by builds 61/63. |
| Telegram | `observedAt: Double`, `lastSuccessfulPollAt: String?` | Change time in Unix seconds and the owner's actual successful-poll evidence. A newer poll is published. |
| Organism | `generatedAt: Date` | Change time of the final mobile state, after Desk attention/availability is included; the existing ISO 8601 string codec. |
| Work overview | `capturedAt: String` | Change time as fractional ISO 8601; installed phones' display and disk-cache guards accept newer and refuse older/equal state. |

All other fields retain the same types and optionality as shipped in build 61
(`750c8054b1`) and build 63 (`b70c348b52`); these four Shared DTO definitions match
between those phone commits. Work overview still encodes its enum-keyed owner
counts as alternating kind/count pairs sorted by kind, preserving their array
format. Its phone readers and CloudKit cache use `capturedAt`; Telegram uses
`observedAt`, organism uses `generatedAt`, and the status shortcut dates that
organism state. An unreadable derived overview cache is preserved beside it as
`.json.unavailable` and repaired from a checked Mac publication. No alternate
payload decoder is added. Trust carries a date only when saved in policy.
Mac last-seen continues to use transport confirmation and
the pairing heartbeat, independently of unchanged snapshot age. Settings Connection
reads `MacBridgeClient.lastSeenAt` with `NAMacPresence.phoneWindow` (300 seconds),
and calls it **Mac last seen**, rather than dating the most recent snapshot.
`lastSeenAt` reads the bridge's single authenticated contact timestamp. Connection
facts use that same window and change to waiting when contact expires, even if a
CloudKit read stays open. Silence cannot declare the Mac stopped or settle a send.
The open phone reads signed Mac presence on its contact loop. A missing or failed
read retains its cause and prior contact; it cannot renew availability.
Snapshot delivery age is descriptive, with no 30-second stale verdict. A reported
group rebuild failure still marks that group's rows stale, and missing deliveries
and clock mismatch remain visible.
An unavailable work source carries its reason without a dated synthetic activity; the phone
retains current activities until canonical terminal evidence, explicit opt-out
or ActivityKit ended/dismissed events arrive; missing rows and age do not end work.
Faces keep their epoch while their content is unchanged. Diagnostics carries
the health owner's start time; Privacy omits its inventory read clock. Telegram's
face omits the idle poll clock and formats reply/diagnostic dates absolutely,
so rereading the same status does not change its words.
Today's Thinking counts carry no event time: they describe day/week totals.
Its undated row follows dated timeline rows, and rereading unchanged counts
does not change the face's time or epoch.

The Mac presence owner publishes on launch, app activation/deactivation, Mac wake,
network regain and completed conversation edges. Its single deadline renews
presence 240 seconds after a publication completes, within `phoneWindow` (300 seconds).
The remaining minute covers acceptance and the phone's next contact read; an
unanswered or failed CloudKit operation does not prove availability. The independent
20-second receive lifetime starts with transport setup and ends on teardown;
presence failure, ineligibility or an open publication cannot hold it. A held chat
drain keeps its one queued follow-up and reads controls meanwhile. Presence
publication writes only canonical presence; it never advances an unchanged
faces record's `updatedAt` to satisfy an older freshness display. Builds 61/63
still decode the unchanged payload shapes, but their fixed freshness labels can
age without a new state publication.

L7 release order: ship and install the phone reader above before installing the
Mac's slower presence renewal. Phone builds 64–67 still decode the same records,
but their fixed delivery-age labels can warn after 30 seconds and their cached
connection fact does not expire while open. They need the phone reader update
for truthful idle/quit presentation; a Mac-only release cannot change those readers.
No payload renewal or second wire shape is used to satisfy an old display.
Idle renewal is 15 presence writes per hour, plus actual activity edges and explicit
repair/reclaim writes. `Mac presence accepted` in the DeviceSync log counts accepted
writes, not attempts or phone receipts. Installed measurement is required; the
source rate is not an observed result.

Snapshot, catalog and presence publication read the existing pairing key through
`DeviceSyncStorage`, off the main actor, and recheck lifecycle eligibility before
sending. A missing or unreadable key remains a publication failure and never
creates replacement authority.
Mac sense/place ingress and cancelled/interrupted chat recovery perform checked
history and ledger reads/writes through `DeviceSyncStorage`. Acceptance follows
completed persistence. Phone setup restores signed contact evidence through that
same off-main storage owner, publishing through `LatestRead` under its setup
lifecycle fence. A newer authenticated contact takes precedence over an older
restore; missing evidence leaves contact unobserved, and unreadable evidence stays unknown.
Phone connection standing reads the bridge's existing contact owner. A retained
read failure outranks a held successful contact; missing contact stays unknown.
Request silence has no local expiry verdict.

Push-proof restoration and writes use the same off-main
storage boundary, serialize in arrival order, and publish through `LatestRead`.
Push timestamps record event arrival rather than time spent awaiting storage;
retired lifecycles cannot publish their results. Issued writes finish even if
the caller is cancelled; failure keeps the prior evidence and reports its cause.
On the phone, receive-ledger restoration, encoding and file writes use serial
`VolumeIO`. Ingress and held-record replay wait for checked restoration; an
unreadable ledger is preserved and blocks admission with a storage repair message.
The separate verification-history defaults record uses `MobileLocalStorage` for
off-main restoration and encoding; its own read failure preserves that record
without treating diagnostic history as authority over other messages.
An unhandled Mac record retains its failure and keeps the transport cursor
unacknowledged. Refusal count and age cannot mark it handled. Pairing-material
changes can reconsider the specific admission cause; there is no generic launch
replay or one-day expiry. Every seen receipt awaits persistence before transport
acceptance. Chat replies dispatch to listeners before recording the seen receipt;
failed saves leave the original record eligible for delivery. Equal ledger bytes
are not rewritten. Issued I/O owns its physical completion; the former built-in
30-second wait cap is removed. Explicit inherited budgets elsewhere remain
separate caller policy.

Builds 61/63 retain their own fixed freshness displays and local cache-write
behavior. The current phone skips byte-identical cache writes. A missed update
is not proof that the Mac disconnected.

Builds 61/63 continue to decode Health, Telegram, organism and overview through
their existing bare-object readers and clock fields above. Their page faces,
including Today, also retain their format. The Mac does not require a phone
upgrade to read these payloads; connection presence remains independent of state age.

For a damaged projection, ask the agent on the Mac to run
`app {"action":"doctor.repair","args":{"check_id":"icloud_bridge_state"}}`.
That existing repair reaches `MacSyncEngine.repairPhoneSync`, rebuilds and republishes
phone views, and requires a later healthy reading to prove recovery.
Each Mac snapshot publication pass awaits the page owner's snapshots through
`sync.host.pageFaces()` and stages `faces.json`: a dictionary from page id to the shared
`PartFaceSnapshot`, retaining its source epoch, availability, face, error and
owed state. No second page model or epoch is kept by sync. An empty owner read
stays an empty dictionary; it says nothing about removal or readiness.
Failed or unavailable faces retain the owner's status and error.
The current phone decodes each dictionary entry independently off main. A malformed
entry draws its own `bad_face` failure while readable siblings remain. Its local failure
uses the dictionary's page id and no decoded version or source epoch (`sourceEpoch: 0`);
it does not assert an owner revision or repair obligation. Missing or unreadable files
retain the accepted pages and the file's existing read-health explanation. An empty
dictionary contains no pages; it proves no removal. Additive unknown fields are ignored.
`PartFace.Style`, `Tone`, `Action.Role` and `PartFaceSnapshot.Status` are frozen wire
enums; future kind tags are open strings, introduced with their elements.
Document sections carry the open `block.kind` and one compatibility note in `rows`:
**Update NativeAgent on this iPhone to see this.** Current doors draw the block instead;
installed phones draw the note and retain the page's other sections. Helpers' briefs use
this shape. Unknown kinds draw the same note without losing their page.
Pairing invalidation clears the phone's in-memory faces with its other
projections. The new pairing supplies its own faces; a missing delivery never
authorizes showing the previous pairing's pages.
The file publishes alone in the `faces` group, CloudKit status
`mobile_snapshot_faces_v1`. The Mac never names this group in the KVS ping:
phones before faces ignore the new group. Phones that support faces fetch that group with
each ping and observe its record.
Face publication notifications enter the existing work-activity coalescer even
while a snapshot writer is occupied, so a change after face capture queues a
trailing pass rather than waiting for unrelated work.

The off-main `MobileSnapshotBuilder` encodes pages independently and assembles the
same dictionary in page-id order. Above the deployed phone's 4 MiB `faces.json`
ceiling, the largest encoded pages become `unavailable` until the file fits
(equal sizes use page-id order). Each keeps its id, part, version, source epoch and
owed state, with `face_budget_exceeded` explaining its size, the shared budget and
how to read or reduce it. Its content and levers do not enter that phone copy.
Other pages keep their encoded values. The existing unavailable/error shape is
readable by installed phones; no enum value or required field is added.
If even these unavailable entries cannot fit, the file fails with its actual size.
The shared codec still checks its 800 KiB status and 8 MiB uncompressed envelope
limits. An encoding, envelope, write or publication failure retains its own cause
through the existing skip accounting.
Unchanged unresolved failure maps preserve `snapshot_skips.json` and its
`_observedAt`; only a changed failure or proven recovery changes that file.

An oversized outgoing transport group fails that group without shedding files;
the page-file budget above is applied before that transport check. Unreadable
staleness bookkeeping stays preserved and unavailable. Chat replies use the
bridge/transcript owners across lifecycle changes without a per-chat transport
nudge or transcript backstop read.
All snapshot scopes hold one writer through publication and staleness bookkeeping.
Publication carries committed wire bytes and reads only unchanged files; scope selects payloads.
CloudKit initializes the phone's local
snapshot and mailbox directories through `enableCloudKitSnapshotCache()`.
Response reads and retained action files run through Shared `VolumeIO`;
`PhoneSigningIdentity` owns asynchronous signing. The phone's removed Drive
chain includes its injected container lookup, metadata query, scan state,
archive retention, setup waits and staged action-file writer. Snapshot pairing
changes address the sole CloudKit cache root; connection repair reconciles only
its local responses and transaction ledger.
Mailbox response reads decode their outer string dictionary and canonicalize
and verify its signature inside that same off-main operation. The main actor
checks lifecycle, repair state and the captured pairing key before adopting
the decoded value and verification result; missing responses stay unresolved and
unreadable responses retain their existing error path.
VolumeIO admits only resident regular files before reading bytes. Dataless
placeholders report unavailable acquisition, never empty or damaged content.
Its shared continuation releases a waiting caller on Stop or an explicitly
inherited deadline; it adds no default deadline. Queued work that has not started
is skipped after cancellation; issued filesystem operations retain their own
completion and cleanup. A write whose wait ended has an unverified commit,
never proof of non-dispatch. Mac Drive reply receipts keep `commit_unverified`
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

Live Activity registration cleanup writes `notifications/push_tokens.json`
only when retirement changes the checked registration, including when the
person has disabled Live Activities.

The Mac's notification router owns approval, Inbox and Desk alerts. The phone
renders their snapshots and reports snapshot health; it does not create local
approval or Desk alerts, seed notification baselines, or retry alerts on snapshot
refresh. `InboxStore` owns refresh and the request for notification permission;
`ApprovalsStore` exposes the approval snapshot's health. Permission failure is
reported by the request, never treated as a posted alert.
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
end; adverse notices bypass that hold. A held phone call succeeds as recorded
work without claiming a phone publication or display. Its receipt names the
policy's quiet end and warns against a duplicate send;
[held delivery](INTERNAL_WORKINGS.md) owns the result and restart contract.
Delivery readouts name each destination, so a Mac banner or thread acceptance
never proves phone receipt. Explicit
phone-pinned calls still go only to the phone. Their quiet-hours exception
requires the person's own Mac act with positive local provenance, or an actual
nonempty current request in a verified direct person conversation with owner
ingress proof; a peer call or missing proof keeps the hold
([reaching them](INTERNAL_WORKINGS.md)).
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
| iOS admission/delivery and CloudKit | `iOS/NativeAgentMobile/Sources/iCloudBridge.swift`, `iCloudBridge+CloudKit.swift` |
| iOS snapshot/action engine | `iOS/NativeAgentMobile/Sources/iCloudSyncEngine+*.swift` |
| iOS chat and share import | `iOS/NativeAgentMobile/Sources/ChatStore+*.swift` |
| Voice-note capture and recognition | `VoiceInputController.swift`, `MobileSpeechAnalyzer.swift`, `ComposerVoiceMicrophone.swift` in iOS Sources |
| Hands-free talk and voice | `TalkModeController.swift`, `MobileTalkAudio.swift`, `TalkModeView.swift`, `ChatStore+ReplyObservation.swift`; `LiveActivityShared/PhoneTalkAttributes.swift`, `LiveActivity/PhoneTalkWidget.swift`, `ControlSupport/MobileTalkRoute.swift` under iOS; `MultimodalTTS/MultimodalTTS+VoiceSelection.swift` owns Mac voice identity |
| Shared voice-note presentation | `Modules/NativeAgentShared/Sources/NativeAgentShared/VoiceNoteBubble.swift`; phone `MobileTranscriptAttachments.swift`, Mac `MessageBubble.swift` |
| Phone senses, setup and preferences | `iOS/NativeAgentMobile/Sources/PhonePlaces.swift`, `PhoneSenses.swift`, `PhoneBodyReadings.swift`; shared `PhonePlaceEvent.swift`, `PhoneSenseEvent.swift`; `AppToolRuntime/PhoneSensesGuide.swift` reads setup and exact steps on the pairing page |
| Mac person presence and evidence | `MacControl/PersonPresence.swift`; `PersistenceCore/PhoneSenseHistory.swift`, `PhonePlaceHistory` in `PersistenceCore.swift`; admission in `DeviceSync/ICloudReceiving.swift` |
