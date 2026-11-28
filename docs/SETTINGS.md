# NativeAgent settings

On your Mac, choose **Control → Settings**, or press **⌘,**. **Control** also holds **Providers**, **Trust**, and **Connectors**. The same pages are available in Simple and Advanced. On your iPhone, tap **Control** in the bottom bar. For the rest of the window and the menus, see [Where things are](WHERE_THINGS_ARE.md).

Defaults below describe a fresh setup. Your saved choices, account, or system permissions can change what you see.

## First-run Mac setup

1. On **Let's start with names.**, fill in **Your name** and **Agent name**. Expand **What the agent can help with** to see the overview. Select **Continue**.
2. On **Connect an AI account.**, sign in or expand **Or use an API key** and choose **Add key** for your provider. **Read accounts again** refreshes account status. When models are available, choose a **Chat model** and select **Use this model**. Use **Back** to return to names or **Skip for now** to connect later in **Control → Providers**.
3. **Cancel setup** stops setup while it is running. Choose **Start** when setup finishes. If setup needs repair, follow the available control. **Try again** rereads or retries setup. **Start setup over** appears when a reset is available. The name repair screen offers **Save names** and **Check again**.

## Mac · Control → Settings

### Preferences → Where I reach you

| Control | Default | What it does |
| --- | --- | --- |
| **Deliver to the phone** | On | Allows eligible alerts and the morning brief to reach a paired phone. Turn it off to stop using this channel for those alerts. Pairing and notification delivery must be working. |
| **Deliver to Telegram** | On | Allows alerts through Telegram when that was where you last talked. Requires a connected bot and an allowed destination. |
| **Deliver as a Mac notification** | On | Allows Mac banners. The app still keeps eligible Inbox and activity records with banners off. Enable macOS notifications to see banners. |
| **Delivery receipts recorded** | Read-only | Shows what each channel can prove. The paired phone can send a delivery receipt. Telegram records the send, and the Mac records whether the banner posted. |

### Preferences → What I can read

| Control | Default | What it does |
| --- | --- | --- |
| **Image understanding** | On | Permits vision API calls. The selected provider and model must support image input. |
| **Read PDFs** | On | Permits PDF ingestion. Turn it off to block that kind of file reading. |

### Preferences → Memory

| Control | Default | What it does |
| --- | --- | --- |
| **Knowledge graph** | On | Allows graph memory. Open your agent’s named place → **Memories → Knowledge graph** to inspect it. |
| **Remember across conversations** | On | Lets relevant memories from other conversations inform your next conversation. |
| **Recurring memories are proposed as facts** | On | Lets recurring memories become proposals. You can review the proposals in **Memories → Waiting for you**. |
| **Meaning-based memory** | On | Uses a model on your Mac to match meaning. Off uses word matching. Either change asks for confirmation and reindexes saved memory. **Right now → Memory lookup now** updates with the active backend and any model load error. |
| **Memory in every reply** | `active` | Brings relevant memory into replies from the next turn onward. Choose `off` to stop this preparation. Setup or a safety condition can hold the change off. |

### Preferences → Inner life

| Control | Default | What it does |
| --- | --- | --- |
| **An inner life** | On | Starts or stops the inner-life runtime. **Right now → Inner life now** reports whether it actually started. |
| **Keep thinking in the background** | On | Allows small background thinking cycles while the inner life is running. Off stops those cycles. |
| **Reflection between conversations** | Off | Allows model-based reflection between conversations. Needs the inner life, an eligible model, and room in the reflection budget. |
| **Moods, energy, and a clock of my own** | Off | Enables the body-signal system for mood, energy, and daily rhythm. Needs the inner life. |
| **My hour** | On | Lets your agent take an hour of self-directed activity when you step away. Needs the inner life. |
| **Give me a thought summary** | On | Allows the inner life to supply a short summary to turns. Off removes that input. |
| **Dreams at night** | On | Allows scheduled nightly dreams. The switch reports whether the dream cycle can run. |
| **Weekly dream consolidation** | On | Allows the weekly REM cycle when dreams and its schedule are enabled. You still decide whether to keep staged memory changes. |
| **Overnight revision** | On | Allows the overnight revision process to try changes to parts that repeatedly fail. The process records the trial and outcome. |

### Preferences → How I look

| Control | Default | What it does |
| --- | --- | --- |
| **Dark appearance** | On | Uses the Mac app’s dark appearance. Turn it off for light appearance. |
| **Haze colour** | `teal` | Changes the light behind the window. Choices are `teal`, `blue`, `violet`, `rose`, `amber`, `forest`, and `graphite`. |
| **View** | `simple` | Choose `simple`, `advanced`, or `agent`. You can also use **Simple**, **Advanced**, and **Agent** at the top of the window. |
| **The window follows me** | On | Lets the open window follow the current work without bringing itself forward. When you choose a page or start typing, your choice takes priority. Off leaves navigation to you and to explicit requests to show a page. |

### Preferences → Shortcuts

| Control | Default | What it does |
| --- | --- | --- |
| **Global hotkey** | On | Registers **⌘⇧J**. Tap it to open the window. Hold it for voice capture and release to finish. Voice needs microphone and speech recognition access. |
| **Shotgun shortcut** | `option-space` | Choose `option-space`, `control-option-space`, `shift-command-space`, or `off`. The choice takes effect immediately if macOS can register it. A conflict appears under **Updates and help**. |

### Preferences → Other

- **Show the tour** defaults off. Turn it on to replay the window tour. The switch returns to off after the tour is dismissed.

### Preferences → Advanced

- **Reflections in 24 hours** shows the budget. The default is **2**. Open the row or choose **Advanced → Diagnostics → Cognition** to set **0–8**. Zero allows no budgeted waking reflections.
- **Search service** starts empty. Enter a SearXNG address or choose **Find** to look for a service on this Mac and save its address. The service must be reachable.

### Notifications

- **Raise things unasked** defaults on. It allows unsolicited observations, file notices, finished-task notices, and check-ins. Turn it off to stop those unsolicited notices.
- **Notification history** opens the Inbox. Expand **Earlier** for archived and dismissed notes.
- Quiet hours are read from `user_prefs.json` in the data folder. With no `quiet_hours` entry there is no window. To set one, put `"quiet_hours": {"start": 22, "end": 7}` in the top-level JSON object, keeping any other entries. Use distinct whole hours from **0** to **23** in local time. An end hour earlier than the start crosses midnight. Remove the entry to clear the window. Eligible notices wait until the end. Failures and a response you explicitly asked to receive through a particular channel can surface during the window.

### Right now

Read **Inner life now**, **Use my Mac**, **Memory lookup now**, and **Memory suggestions**. The rows can open the applicable page. **Enable again** appears when the saved inner-life choice needs to be applied again.

### Updates and help

- **Updates** shows the installed updater’s state. Use **Check for Updates…** or **Update Available — [version]…**. A build without the update feed can show **About Software Updates…**. Automatic checks default on for builds with a published update feed. The row reports the current state.
- **Data limits → Show data limits** opens the bundled reference for what the app keeps and for how long.
- **About → Copy build identity** copies the version and available build information.
- **App status** shows the current runtime reading. **Shotgun shortcut unavailable** appears if the selected shortcut conflicts.

### Launch at login

An installed copy under `/Applications` or `~/Applications` normally registers for login when it starts. Manage the registration in macOS **System Settings → General → Login Items & Extensions**. The app does not have a login switch, and an eligible copy can attempt registration again on a later launch.

## Mac · Control → Providers

### Chat, Work, Mind

| Section | What it covers | Default |
| --- | --- | --- |
| **Chat** | Mac Chat, iPhone, Telegram, and Slack. | No fixed model ships for Chat. Choose one in setup or here. You can also pick it from **Default model for Chat** on an account’s sign-in card. |
| **Work** | Desk, task execution, independent tasks, skill practice, and Diagnostics. | Follows Chat unless you set a separate route. |
| **Mind** | Memory, dreams, REM, reflection, learning, and creative exploration. | Follows Chat unless you set a separate route. |

Each group offers **Model**, with **Thinking** and **Fast** when supported. Changing the model resets those two controls to that model’s settings. **Fast** requests priority service. **Same as Chat** in **Work** and **Mind** removes those groups’ model overrides when on. Turn it off to keep a separate choice. If the group shows mixed choices, selecting a model here applies it to all of that group’s activities.

### Accounts

Expand an account or **Add a provider**. Use **Sign in** for account authentication or **Add key** for API-key accounts. Use the protected setup sheet for credentials.

| Account type | Account rows |
| --- | --- |
| Account sign-in | **ChatGPT (OAuth)**, **Codex CLI**, **Anthropic (OAuth / Setup-Token)**, **xAI Grok (OAuth)** |
| API key | **Anthropic (API key)**, **OpenAI (API key)**, **Kimi Code**, **Meta**, **Moonshot AI (Kimi)**, **OpenRouter** |

Connected accounts appear first. **Add a provider** collects accounts that still need setup. Your Mac can also have registered providers of its own. Model choices come from the catalog for the account you selected.

- **How to sign in** offers **A key** or **A sign-in** as supported. **Key** can be blank to keep the saved key. **Default model for Chat** lists the models this account offers now and saves your pick as the Chat model at once, the same choice as **Control → Providers → Chat → Model**. It needs a connected account.
- **Save** stores the form. **Test connection**, **Test API key**, or **Test Claude sign-in** checks the applicable credential. **Read account again** reloads the saved information. **Remove sign-in** clears the credential. The account row may also offer **Test the connection** and **Disconnect**.
- The setup can show **Sign in with ChatGPT**, **Sign in with Claude**, and **Sign in with xAI Grok** according to the available routes. Complete the sign-in flow and return to the app. Where Claude setup offers **Or use a setup token**, enter the token in **Setup token** and choose **Save token**.
- **Codex CLI sign-in → Use it** adopts an eligible sign-in found on your Mac with your consent. **Ignore** declines the offer. **Back up and reset consent** appears if the consent record needs repair.

### Catalog

Open **Models → Refresh** to reread account model catalogs. Use **Cancel** while the refresh is running. **Saved routing needs repair** appears before Accounts if a saved activity cannot be recognized. Follow the repair instruction in that row.

### Other places you can choose a model

| Where | Scope and defaults |
| --- | --- |
| **First-run setup → Connect an AI account. → Chat model → Use this model** | Sets the initial Chat choice once an eligible account exists. **Skip for now** leaves provider setup for later. |
| **Mac Chat → model name beneath the composer** | Changes the saved Chat route. The menu groups models by eligible account and includes **Fast** when offered. **More models…** opens Providers. Use the nearby thinking control for supported effort. |
| **iPhone Chat → Chat actions (•••) → Chat options → Model / Thinking / Speed** | Reads and changes the iPhone route on the paired Mac. The iPhone route starts by following Chat. **Speed** offers **Normal** and, when supported, **Fast**. Confirm with **Set model**, **Set thinking**, or **Set speed**. The adjacent **File access → Set file access** saves the phone’s own choice. It starts at **Auto** and offers **Read only**, **Workspace**, and **Full Mac**, subject to Trust. Use **Refresh Models** to reload choices. |
| **Connectors → Where I reach → Telegram → Model** | Shows the Telegram route. Set the shared default in **Providers → Chat**. In Telegram, use **/model**, **/think**, or **/fast** for the supported Telegram choices. **/brain** shows the current route. |
| **Desk → Helpers → helper**, then ask in **Chat** | A following helper uses Chat’s provider and model. Ask in Chat to pin a helper to a separate model or change that choice. The Helpers page shows the saved route. |

## Mac · Control → Trust

Trust applies to actions. A system grant, connected account, or app-specific switch may also be required. Sections that need attention move up and open automatically.

### What I may do

**Standing** offers **Safe**, **Work mode**, **Builder**, and **Full Mac**. A fresh policy starts with workspace autonomy and unattended work enabled, denies writes outside approved folders, and requires file-write backups. The saved posture can also be custom.

| Standing | What changes |
| --- | --- |
| **Safe** | Reads within the permitted reach and blocks writes, shell, and Git. |
| **Work mode** | Can edit approved workspaces. Asks before protected effects, such as sending on your behalf. |
| **Builder** | Can work in workspaces and ask before writing elsewhere. |
| **Full Mac** | Allows broad Mac control, file access, and unattended work until you change the standing. Explicit blocks, authenticated origins, system grants, and required confirmations still apply. Deleting a contact, event, or reminder still asks. |

Use the nested rows under **Standing** to see actual file reach and backup policy. If **Repair saved authority** appears, **Authorize Safe** preserves the damaged policy and writes the Safe policy.

### Features

- **Allow screen capture** defaults off. Allows Chat’s camera button with the macOS Screen Recording grant.
- **Allow image generation** defaults off. Requires a Work route with a supported image backend.
- **Read replies aloud automatically** defaults off. Uses the saved voice settings. Cloud speech has a separate permission.
- **Let me work unattended** controls scheduled helpers and background improvement in narrower standings. It starts on with a fresh policy. Under Full Mac the standing supplies this grant. **Run once** is an explicit request and can still be available with unattended work off.

### Chrome control

**Chrome control** defaults off for narrower standings. **Full Mac** supplies the effective grant while selected. **Chrome extension → Set up Chrome on this Mac** starts setup on the Mac. Check the connection state here before using the browser controls. Your agent can use inactive tabs in the assigned group. Selecting a tab returns control of the tab to you.

### Mac access and control

**Mac control preset** offers **Off**, **Watch**, **Assistant**, and **Full Mac**. **Mac access setup → Set up Mac access** moves Off or Watch to Assistant. **Check Calendar on this Mac** and **Check Reminders on this Mac** read those apps and can prompt for permission. **Mac notifications → Send a notification on this Mac** exercises the notification route.

| Saved switch | Default | What it gates |
| --- | --- | --- |
| **Mac control** | Off | The narrower standing’s Mac-control master switch. |
| **Notifications** | On | Mac-control notification actions. The macOS grant still applies. |
| **Spotlight search** | On | Mac-control search through Spotlight. |
| **File operations** | Off | Mac-control file operations, subject to file rules. |
| **Clicking, typing and reading apps** | Off | Desktop interaction. Requires Accessibility, with Screen Recording for screen images. |
| **AppleScript** | Off | AppleScript. App-specific Automation permission may also be required. |
| **JavaScript for Automation** | Off | JavaScript for Automation. App-specific Automation permission may also be required. |
| **Shell commands** | Off | Shell through Mac control, subject to Trust and the action’s gate. |
| **iPhone remote control** | Off | Requests to control the Mac from a paired iPhone, subject to the effective policy. |

Under Full Mac these switches show the saved choices for narrower modes. **Mac control workbench → Open workbench on this Mac** opens the native command workbench.

### Security, Connected agents, Apps and features

- **Security** shows **Mode** and the read-only **Developer mode** status, which defaults off. **Pause everything** defaults off. Turn it on to block actions until you turn it off. Review decisions in **Recent security log**.
- **Connected agents** has a switch for each eligible contact. It starts off for a new connection. Turn it on to let requests authenticated with that contact’s key carry your existing authority. Turn it off to withdraw that authority.
- Under **Apps and features**, **Calendar**, **Reminders**, **Contacts**, **Mail**, **Messages**, **Notes**, and **Music** have **Read** on and **Write** off by default. **Mac Notifications**, **iPhone Notifications**, and **Scheduler** have **Write** on by default. **Spotlight Search** has **Read** on by default. Turning an axis off blocks that access even in Full Mac.
- Security readings and the **Mac control audit** show decisions and receipts. Expand a row to see details.

### macOS grants

On the Mac, use **Trust → macOS grants**. Use **Ask macOS** where offered and answer the system prompt. **Open System Settings** opens the matching pane. **Ask for each one** requests the supported prompts still waiting for an answer. Enable **NativeAgent** in the pane shown below. For a permission that accepts an app file, you can drag the NativeAgent icon from the guidance card into the list. Restart if the grant row says the change is pending.

| Grant | Where to enable it | Used for |
| --- | --- | --- |
| **Notifications** | **System Settings → Notifications → NativeAgent** | Mac banners and alerts. |
| **Calendar**, **Reminders**, **Contacts** | **System Settings → Privacy & Security → Calendar**, **Reminders**, or **Contacts** | Access to that app’s data. Use full Calendar access to read events. macOS write-only access can satisfy a Calendar write request. |
| **Microphone**, **Speech Recognition** | **System Settings → Privacy & Security → Microphone** or **Speech Recognition** | Capturing voice and turning it into text. |
| **Accessibility** | **System Settings → Privacy & Security → Accessibility** | Clicking, typing, and interacting with apps. |
| **Screen Recording** | **System Settings → Privacy & Security**, then the screen recording pane | Capturing screen images. |
| **Input Monitoring** | **System Settings → Privacy & Security → Input Monitoring** | Recognizing local input activity. |
| **Full Disk Access** | **System Settings → Privacy & Security → Full Disk Access** | Reading protected local files such as the Messages history database. |
| **Automation for Mail**, **Messages**, **Notes**, **Music** | **System Settings → Privacy & Security → Automation**, under **NativeAgent** | Allow the target app individually. Use the app’s permission request to create the entry when needed. |

For basic text chat you need a connected model account. macOS grants depend on what you ask your agent to do.

### Background watches, Activity capture, Privacy map, Backups

- **Background watches** shows watch templates and access readiness. Ask your agent to schedule the watch you want.
- **Record which apps you use** defaults off. Turn it on to record app names and durations. **Window titles** defaults to **App names only**, with **Window titles** and **Window and browser titles** available. **Let me answer from activity history** defaults off and needs recording enabled in narrower standings. **Keep history for** offers **7**, **14**, **30**, or **90 days**, default **30**. **Exclude an app → Choose an app on this Mac** adds an exclusion. **Delete all recorded activity → Delete everything** clears the local activity history.
- **Privacy map** lists data categories, paths, and export status. **Read Trust again → Refresh** rereads the inventory.
- **Backups → App backup → Back up now** makes a local app-data restore point. Expand **Restore points**, select a point, and choose **Restore backup**. A safety backup must finish before replacement begins. Restored work stays stopped until you resume it.

## Mac · Control → Connectors

### Where I reach

- **iPhone** starts unpaired. Open the row, keep NativeAgent open on your Mac, and use the same Apple Account on the Mac and phone. On the phone, open **Control → Connection → Pair with Mac** and tap **Connect** when the key arrives. Match **This phone’s code** on the Mac and choose **Pair**. **Remove** revokes the selected device’s approval pairing. **Check iCloud delivery** checks the pairing route. **Use my iPhone with this Mac** appears when a different Mac owns the pairing. **Regenerate** replaces the pairing key. Keep both apps open so iCloud can deliver the new key. The row also shows iCloud, notification, and phone-sense evidence. Phone sync requires a build configured for its iCloud container.
- **Telegram** starts off, without a token or allowed senders. Use **Enter bot token** or **Replace bot token**, then enter your BotFather token in the secure card in Chat. **Telegram is on** controls polling and needs a saved token. Enter comma-separated numeric IDs in **Allowed chat IDs** and **Allowed user IDs**. Everyone in an allowed group can reach the bot. With Telegram off and the token saved, send the bot a message, then use **Find your chat ID → Check sender**. Review **Blocked and ignored on Telegram** before using **Allow chat ID [ID]**. **Only answer when mentioned in a group** defaults off. **Refresh** reads status. **Send a test reply** needs a configured, enabled bot and an allowed destination. **Disconnect Telegram** removes the token and turns Telegram off. Under **Voice**, use **Set up Telegram voice** if offered. Transcribing a Telegram voice message needs Speech Recognition on the Mac. **Telegram diagnostics → Clear logs** clears Telegram’s recorded diagnostics.
- **Slack → Connect** opens **Connect Slack**. Use **Open Slack apps** for the app portal. Enter **Bot token**, **App token**, **Allowed channel IDs**, and **Allowed user IDs**. Set **Only answer channel messages when @mentioned**, then select **Save**. Socket Mode needs the bot and app tokens. At least one channel or user must be allowed for incoming work. Direct messages do not require a mention. **Read setup again** rereads the settings, and **Close** dismisses the form. **Reconnect** and **Disconnect** appear according to the saved connection.
- Other connector rows appear when the registry reports them. Use **Connect**, **Reconnect**, or **Disconnect** where offered. **Show browser** opens the app browser. Use **Look for agents** to refresh discovery. Connected agent contacts can have **Send a test message**, **Disconnect agent**, and **Reads my Desk**. A Grok Bot contact can ask for **Paste credentials securely → Save to Keychain** and **Bot name → Use this Bot**. Connection setup and the Trust authority switch are separate decisions.

### Kept secrets, Folders I may open

Use **Forget** on a named kept secret to remove it from the app’s secret store. To share a folder, select **Share a folder** and choose one local folder. Enter a name in **Folder name (leave blank to use its name)** if you want a different label. **Let me write to it** starts off. Turn it on to request a read and write grant, subject to Trust. Choose **Share Folder** and review the path and access on the row. Empty or unavailable rows can appear under **Secrets and folders**.

## Other Mac controls

- **Your agent’s named place → Personality → Read or edit identity** has **Name → Save name** and the identity document editors with **Save document**. Use **Read documents again** to reload. **Use saved version** discards your conflicting draft for that document.
- **Desk → Desk** holds reminder controls. **Nag me** defaults off. Turn it on to enable eligible task reminders. Use **Snooze** to mute them temporarily or indefinitely and **Wake up** to end a snooze. Project switches and **Just this item** set narrower reminder rules.
- **Your agent’s named place → Memories** has **Keep** and **Don't keep** for waiting suggestions and **Forget this…** for a saved memory. Open a memory for **Correct this** or **Forget…**. **Search what I've kept** starts empty and needs at least three letters. **Show all memories** clears the search. Under **Upkeep and details → Memory status and Spotlight**, use **Check again** or **Reindex Spotlight**.
- **Your agent’s named place → Memories → Knowledge graph → View** has **Drawing**, **Time**, and kind switches. **Drawing** defaults to **List** and can be saved as **Graph**. **Time** starts at **All time** and offers **Last day**, **Last week**, and **Last month**. With no kinds selected, all kinds can appear. Time and kind filters are local to the current view.
- **Your agent’s named place → Capabilities** lists abilities, senses, guidance, tools, and checks. Expand an eligible item for **Approve**, **Turn on**, **Turn off**, or **Share sense** as offered. **Checks → Export** and **Checks → Support bundle** create local artifacts. See [Where is my data?](#where-is-my-data).
- **Advanced → Diagnostics → Diagnostics → Health checks** has **Run checks**, **Repair safe issues**, and **Support report**. Use **Repair** on an individual row when offered. Read the result under **Needs attention**.
- **Advanced → Diagnostics → Cognition** has **Think now → Run**, **Reflect → Run**, **Clear thinking → Clear**, **Settle body → Settle**, and **Reset body → Reset**. The inner life, reflection budget, and body settings determine availability. Below those actions are **Give me a thought summary**, **Keep thinking in the background**, **Reflections in 24 hours**, and **Include workspace**. The latter defaults on and includes workspace evidence in cognition.
- **Advanced → Diagnostics → Chat turn details** opens in **Live** mode. **Mode** also offers **Replay**. **Clear** clears the displayed live list. **Replay date** starts at today and selects a day to read. These choices are local to the app session.
- **View → Warmth in the glass** defaults on and appears in dark appearance. Turn it off to remove the mood tint. Chat’s **Shotgun** switch defaults on. Turn it off to disable that chat feature.

## iPhone · Control

### Appearance and Live Activities

- **iPhone color scheme** defaults to **System**. Pick **Light** or **Dark** to override the phone’s appearance in this app.
- **iPhone haze** defaults to **Teal**. Choose **Teal**, **Blue**, **Violet**, **Rose**, **Amber**, **Forest**, or **Graphite**. It changes the phone app’s background light independently of the Mac.
- **Show task names on the iPhone Lock Screen** defaults off. Turn it on to allow Live Activities with task names. iOS must permit Live Activities. A Mac push key allows remote starts and updates. Otherwise activity can start when this app opens or wakes.

### Mac and Connection

- **Mac** shows health, app, version, and uptime from the Mac. **Mac last seen** and the other rows under **Connection** show the pairing and sync reading.
- **Check for Mac updates** fetches pairing information and current Mac reports from iCloud. Use the Mac’s updater to look for a new app version.
- **Pair with Mac** opens the pairing screen. Tap **Check for Mac** if the key has yet to arrive. **Cancel waiting** stops the current wait. **Skip** closes the setup. **Repair connection** clears local pairing and connection delivery history and opens setup again.
- **Control** offers **Trust**, **Providers**, and **Connectors** and shows available settings from the paired Mac. A Mac-only action needs the Mac window. Open **Advanced** for Diagnostics and Mac Tools.

### Places

**Save this location → Place name → Save this location** saves the current location under the name you enter. The form starts with **Home** and a newly saved place starts off. The place’s switch controls whether your phone shares named arrivals and departures. Enabled places need **Always** location access. Use **Open iPhone Settings** if asked. Use **Delete** to remove a saved place.

### Phone senses

Each switch defaults off. Turning it on allows that reading to reach the paired Mac and the selected AI provider. The app samples on wakes. Turning a switch off stops sharing that reading.

| Switch | What is shared and what it needs |
| --- | --- |
| **iPhone Location** | Shares the last available latitude, longitude, and accuracy in meters. The switch asks for **Always** location access for background updates. The app can also read an authorized fix while in use. |
| **iPhone Motion** | Activity estimate and confidence. Needs **Motion & Fitness** access. |
| **iPhone Focus** | Whether Focus is on, off, or unknown. Needs **Focus Status** access. |
| **iPhone Sleep clues** | Charging and whether it is night. |
| **iPhone Battery** | Current battery percentage. |
| **iPhone Headphones** | The app’s audio route, without device names. |
| **iPhone Connection** | Network type or unavailability, without names or addresses. |
| **iPhone Apple Music** | Playback state, title, and artist. Needs **Media & Apple Music** access. |
| **iPhone Photos today** | Today’s visible photo count. Needs Photos access. Limited Access counts the selection you made. |

### About

Use **Privacy Policy** and **Support** when the build supplies links. **Version** shows the phone app’s version.

### iPhone Chat

**Chat actions (•••) → Speak replies** starts off. Turn it on to hear replies on this phone. The Mac’s quiet voice preference can also stop speech. For **Model**, **Thinking**, **Speed**, and **File access**, see [Other places you can choose a model](#other-places-you-can-choose-a-model).

## Where is my data?

The default Mac folder is `~/Library/Application Support/NativeAgent`. To find the active folder, open **Advanced → Diagnostics → This Mac → Data folder** or **Control → Trust → Privacy map**. Development and alternate installs can use another location.

| Inside the data folder | What you’ll find |
| --- | --- |
| `chat/`, `memory/`, `cognition/`, `desk/` | Conversations, saved memory including `memory/memory.sqlite`, cognition including `cognition/cognition.sqlite` and `cognition/organism_state.json`, and Desk records. |
| `persona/`, `abilities/`, `senses/`, `bots/`, `make/` | Identity documents, abilities, sense state, helpers, and made things. |
| `providers/`, `connectors/`, `telegram/`, `slack/`, `icloud/`, `paired_phones.json` | Local setup, connection records, and phone pairings. Credentials can also live in the Mac Keychain. |
| `trust/policy.json`, `activity_watch/`, `ui/layout.json`, `user_prefs.json` | Trust rules, local activity records, layout, and quiet-hours preferences. |
| `backups/`, `production/`, `doctor/`, `logs/` | Restore points, exported artifacts, health reports, and logs. |

**Back up now** copies selected app-owned settings, memory, chat, abilities, connector state, and jobs into `backups/<id>/data/`. The neighboring `manifest.json` lists what was copied. Your personal files and recorded app usage are outside that backup. **Capabilities → Checks → Export** creates a separate bundle with a different scope. Use the **Privacy map** and the artifact’s manifest to see what your copy includes.

To move the local files for an alternate launch, quit NativeAgent and copy the active data folder. Keep its directory structure. An alternate launch configured with `NATIVE_AGENT_DATA_ROOT` uses the exact absolute path you give it. Verify **This Mac → Data folder** and check your data before removing the original. A checkout can store `persona/` next to its data folder, and credentials in Keychain travel separately.

To erase a memory, use **Memories → Forget this…**. To clear a conversation’s messages, enter **/clear** in the main Mac chat and confirm. **Archive** moves a conversation out of the active list and retains the archived data. To keep a Markdown copy of the current chat, enter **/export**. The file goes to Downloads. Past exports, backups, provider logs, and delivered messages can still exist. For a full local removal, quit NativeAgent, remove the app, and delete its active data folder and any workspace files you want to remove. Remove relevant iCloud data and revoke credentials separately. Deleting the iPhone app removes the local container. Use your Apple Account or backup controls to remove copies retained there. See the [Privacy Policy](../PRIVACY.md).
