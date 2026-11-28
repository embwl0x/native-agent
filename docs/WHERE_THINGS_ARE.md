# Where things are in NativeAgent

On the Mac, use the switch at the top of the window. **Simple** starts with one chat and the left sidebar. **Advanced** adds the conversation column, the Work pane, and Diagnostics. **Agent** opens your agent’s **Home** screen. Use **⌘K** in the Mac window to search destinations and commands, or open **Navigate** from the menu bar. Tabs and custom pages can vary with the saved layout.

## The Mac window

### Chat

Open **Together** in Simple or **Chat** in Advanced to talk to your agent. In Advanced, the conversation column holds your chats and can show folded **Briefs** and **Working** conversations. Use the plus button for **New chat**. **Archive** moves the active chat out of the list. Right-click a conversation for **Pin as Tab**, **Unpin Tab**, **Rename Chat**, or **Open in Detached Window**, as available. In Simple, the sidebar also gives you separate **Agents** and **Helpers** threads when available.

| Composer control | What you can do |
| --- | --- |
| Text field and **Send message** | Write and send a message. A send control offered during a reply can steer that reply at its next step. The little ask bar under other pages takes you back to Chat with your request. |
| **Stop generation** | Use the square button to stop the current generation. Already completed effects and saved output can remain. |
| **Screen capture and attachments** | Open the plus menu and choose **Attach Image or File…**. You can also paste or drop supported attachments. **Show Agent My Screen** captures the screen and sends it into the conversation. It needs Trust’s **Allow screen capture** and the macOS grant. **Enable Screen Capture in Trust** opens the Trust page when the app grant is off. |
| **Voice input**, **Stop listening**, **Discard voice input** | Dictate into the composer. The Mac needs microphone and speech recognition access. |
| Model name, thinking control, **Fast** | Pick an eligible account and model, choose supported thinking effort, and select priority speed when offered. **More models…** opens Providers. The Mac’s model choice is the saved Chat default. |
| Trust chip | Choose the saved standing used throughout the app. This is the same standing as **Control → Trust → What I may do**. |
| Context and **Shotgun** | Open the context reading or enable Shotgun. |
| **Let [agent name] use the Mac** | Hands back desktop control after you take it back with your mouse or keyboard. This appears when a hand-back is available. |

Use **Chat → Find in Conversation…** to search the open transcript. Reply actions can copy text or retry an eligible failed exchange. Open an attachment or preview from the transcript to inspect it.

On Mac, **System Settings → Accessibility → Display → Text Size** changes transcript text size. **⌘+** and **⌘−** adjust the transcript further.

Type **/** in the main Mac composer to browse commands. **/help** lists them. **/new**, **/clear**, and **/export** act on conversations. **/model**, **/think**, **/fast**, and **/persona** set chat choices. **/remember**, **/note**, and **/scratch** save a fact, commit a note, or write temporary session scratch data. **/settings**, **/connect**, **/helpers**, **/agents**, **/today**, **/desk**, **/tools**, **/memory**, and **/forget** open their pages or flows. **/voice** toggles dictation. **/context** opens the last turn’s context reading.

### Desk

Open **Table** in Simple or **Desk** in Advanced and choose a tab across the top.

| Tab | What you can do |
| --- | --- |
| **Today** | Read **Waiting for you**, **What I did**, **Ahead**, and **Earlier** when they contain records. Open rows for the source task or conversation. At the bottom, **Approvals and past decisions**, **Every note I've left you**, and **Growth proposals** open the review queues. |
| **Desk** | Browse **Now**, **Next**, **Waiting**, and **Done**. Open a task for its notes, references, and available actions. Use **New task** to open **New Desk Task**, enter a **Title** and optional **Objective**, then **Create Task**. Use **Find item** to search and **Reminders** to change **Nag me** or **Snooze**. Open **On a timer** to see timed work and **The table** to see arranged items. |
| **Notifications** | Opens the **Inbox**. Review **Waiting for you**, **Went wrong**, **News**, and earlier decisions. Open a note to act on it or use the read, archive, or dismiss actions the note offers. |
| **Helpers**, when shown | Open a helper to read the brief and latest runs, or select **Run once**. Ask your agent in Chat to create or change a helper. |

### Your agent’s named place

| Tab | What you can do |
| --- | --- |
| **Memories** | Read what your agent has kept. Use **Keep** or **Don't keep** on suggestions in **Waiting for you**. Search saved memories, pin a memory, or open a memory to correct or forget it. Use **Knowledge graph** to browse connected records in **List** or **Graph**. |
| **Personality** | Read the profile and inner-life material your app shows. **Read or edit identity** opens the name and document editors when available. **Dreams** shows your agent’s dream records. |
| **Capabilities** | Inspect abilities, senses, Chat tools, guidance, Mac actions, connector actions, and checks. Open entries for the choices they offer, including review, enabling or disabling, a dry run, or a support export. |
| A published page from your agent | Open the tab by its name when it appears. The page supplies its own rows and available controls. |

### Control

Open **Providers** for accounts and models, **Trust** for authority and macOS grants, **Connectors** for services and pairing, and **Settings** for preferences, notifications, and updates. See [NativeAgent settings](SETTINGS.md).

### Diagnostics

Open **Diagnostics** at the bottom of the Advanced rail or find it with **⌘K** in Simple.

| Tab | What you can do |
| --- | --- |
| **Diagnostics** | Under **Health checks**, choose **Run checks**, **Repair safe issues**, or **Support report**. Read **Needs attention**, **Background work**, and **Checks**. Open a run to see its detail. **This Mac** shows the version and data folder. |
| **Cognition** | Read body signals, loop activity, the thought summary, and growth. Use **Think now**, **Reflect**, or other available controls. Set the reflection budget here. |
| **Chat turn details** | Inspect a live or saved turn’s records. Open a row for details. Choose **Mode** and, for replay, a **Replay date**. |

### Home, Work pane, and other windows

- **Agent → Home** is your view of your agent’s own screen. It can show notable and changed items, what waits on you, your agent’s queue and current work, contacts, helpers, senses, and links to other places.
- **Advanced → Chat → Work pane** opens from **View → Show Work Pane** or its window button. **Steps** shows the current work’s steps. **Screen** shows the screen view for the current work. **Make** shows made things and versions. **Sense** shows what the current work observed. The content depends on the selected conversation and available readings.
- In **Make**, open a thing to view its version or preview. If the thing is a board, use **Add a card**, the zoom controls, or **Fit**. If it is a sheet, use **Find**, **Copy**, and available row or column controls.
- **Shotgun** is the separate window that follows your agent’s work. Use **View → Show Shotgun** or the configured shortcut. Use **Hide Shotgun** to close that window.
- **Window → Browser** opens the app’s browser window. You can also open it from the native menu-bar icon or the connector’s **Show browser** action. Chrome control has its own setup under Trust.

### Cards and approvals

Read the action and its details before choosing. An ordinary approval can offer **Approve** and **Decline**. A card for an untrusted agent can offer **Just this** for one call or **For this task** to lift that agent’s special restriction while the same request is live and has taken no new arrivals. Ordinary Trust and action permissions still apply. Cards can also offer setup, a field to fill, a result to open, or a link to the place that needs attention. Open **Desk → Notifications** or **Navigate → Approvals** to find waiting decisions again.

## Mac menus and shortcuts

The brain icon in the macOS menu bar opens **Open NativeAgent**, **Refresh status**, **Run health checks**, **Show browser window**, and **Restart app**, with the current status below. The menu also shows the Desk waiting total, for example **1 waiting on you**, when the count is available and above zero. During activity capture, the recording icon has **Stop recording** and **Activity settings…**.

| Shortcut | Menu or use |
| --- | --- |
| **⌘,** | **NativeAgent → Settings…** |
| **⌘R** | **NativeAgent → Refresh status**. The same app menu also has **Check for Updates…**. |
| **⌘Q** | **NativeAgent → Quit NativeAgent** |
| **⌘⌥B** | **Window → Browser** |
| **⌘K** | **Navigate → Command palette…** |
| **⌘1–⌘9** | First nine available built-in pages in the **Navigate** menu’s layout order. Read the menu for the current assignments. It also lists **Knowledge graph**, **Approvals**, and **Inbox**. |
| **⌘⇧A**, **⌘⇧I** | **Navigate → Approvals**, **Navigate → Inbox** |
| **⌘Return**, **⌘I**, **⌘⇧M**, **⌘L** | **Chat → Send Message**, **Add Attachment…**, **Toggle Voice Input**, **Focus Composer** |
| **⌘F**, **⌘G**, **⌘⇧G** | **Chat → Find in Conversation…**, **Find Next**, **Find Previous** |
| **⌘0**, **⌘⌥0** | **View → Hide Sidebar / Show Sidebar**, **Hide Work Pane / Show Work Pane** |
| **⌥Space** by default | **View → Show Shotgun / Hide Shotgun**. Change the shortcut in Settings. View also holds **Warmth in the glass**. |
| **⌘⇧J** | Global hotkey. Tap to open NativeAgent. Hold for voice input and release to finish. |

## iPhone and iPad

Keep your paired Mac online and NativeAgent running. The tabs are **Together**, **Table**, your agent's name (**Agent** before naming), and **Control**.

| Screen | What you can do |
| --- | --- |
| **Together** | Read and switch conversations, send text, add **Photos** or **Files**, dictate, or stop a response. Open **Chat actions (•••)** for **New chat**, **Answer again**, **Speak replies**, and **Chat options**. The Talk button opens a voice conversation with **Mute** and **End**. You can share supported attachments from the iOS Share sheet. |
| **Table** | Read the synced work board, open **Helpers**, or tap **Today** for **Waiting for you**, recent activity, approvals, the Inbox, and growth proposals. |
| **Agent** (or the agent's name) | Open **Home**, **Memories**, **Knowledge Graph**, **Personality**, **Dreams**, **Capabilities**, and published pages received from the Mac. |
| **Control** | Open **Trust**, **Providers**, or **Connectors**. Change the phone's appearance, places, senses, and Lock Screen task display, or repair the Mac connection. |
| **Control → Advanced** | The paired Mac's layout supplies Rooms, Setup, and Power user. Power user includes **Knowledge Graph**, **Turn Inspector**, **Mac Tools**, and **Diagnostics**. Diagnostics shows Mac health and runs, the connection, and recent push receipts. Mac Tools uses the paired Mac under the existing Trust, macOS and approval rules. |
| **Pair with Mac** | Use the same Apple Account, tap **Check for Mac** or **Connect**, then confirm the matching phone code on the Mac. |

The phone can also open a request sheet when your agent asks for a phone action. Read the request before choosing an option. **Talk to Your Agent** is available as a phone control where the build supplies it. The iPhone Shortcuts include **Ask Your Agent**, **Remember**, **Approve**, **Status**, **Quick Ask**, and **Talk**.

## I want to… → go to…

| I want to… | Go to… |
| --- | --- |
| 1. Open the app from anywhere | **⌘⇧J** or the brain icon → **Open NativeAgent** |
| 2. Find a page by name | **Navigate → Command palette…** |
| 3. Start a fresh conversation | **Chat → New chat** |
| 4. Archive the active chat | **Advanced → Chat → Archive** |
| 5. Find text in a conversation | **Chat → Find in Conversation…** |
| 6. Attach a file | **Chat → Add Attachment…** |
| 7. Dictate a message | **Chat → Voice input** |
| 8. Stop the current reply | **Chat → Stop generation** |
| 9. Connect a model account | **Control → Providers → Accounts → Add a provider** |
| 10. Change Chat’s default model | **Control → Providers → Chat → Model** |
| 11. Use a different model for work | **Control → Providers → Work → Model** |
| 12. Change what your agent can do | **Control → Trust → What I may do → Standing** |
| 13. Enable a macOS permission | **Control → Trust → macOS grants** |
| 14. Approve a waiting request | **Desk → Today → Approvals and past decisions** |
| 15. Find a past notification | **Desk → Notifications → Earlier** |
| 16. Stop unsolicited notifications | **Control → Settings → Notifications → Raise things unasked** |
| 17. Stop background thinking | **Control → Settings → Preferences → Inner life** |
| 18. Set up your iPhone | **Mac Control → Connectors → iPhone**, then **iPhone Control → Connection → Pair with Mac** |
| 19. Fix iPhone sync | **iPhone Control → Connection → Repair connection** |
| 20. Connect Telegram | **Control → Connectors → Telegram** |
| 21. Connect Slack | **Control → Connectors → Slack → Connect** |
| 22. See what is due or waiting | **Desk → Today** |
| 23. Create a task | **Desk → Desk → New task** |
| 24. Run a helper now | **Desk → Helpers → helper → Run once** |
| 25. Correct or forget a memory | **Your agent’s named place → Memories → saved memory** |
| 26. Open something your agent made | **Advanced → Chat → Work pane → Make** |
| 27. Run health checks | **Advanced → Diagnostics → Health checks → Run checks** |
| 28. Back up your app data | **Control → Trust → Backups → Back up now** |
| 29. Find the data folder | **Advanced → Diagnostics → This Mac → Data folder** |
| 30. Check for a new Mac app version | **NativeAgent → Check for Updates…** |
