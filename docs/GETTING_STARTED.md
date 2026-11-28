# Getting started with NativeAgent

## Install on your Mac

You need an Apple silicon Mac running macOS 26 or newer.

1. Open the NativeAgent DMG you downloaded from the [releases page](https://github.com/embwl0x/native-agent/releases).
2. Drag **NativeAgent** onto **Applications** in the window that opens.
3. Open **NativeAgent** from **Applications**.

## Set up your names and connect a provider

Enter **Your name** so your agent knows what to call you. Keep the suggested
**Agent name** or type your own. The names are saved on your Mac. You can open
**What the agent can help with** for a preview. Click **Continue**.

A provider is the service that runs the model and returns replies. Choose a
connection on **Connect an AI account**, or click **Skip for now** while no
account is ready. If an account is connected, choose a usable Chat model to
continue. To connect later, open **Control → Providers → Accounts** on your
Mac. Expand **Add a provider** to see accounts you can add.

| Connection | What to do |
|---|---|
| ChatGPT sign-in | Click **Sign in with ChatGPT** and finish the browser sign-in. From **Providers**, open the ChatGPT account with **Sign in** first. |
| Claude sign-in | Click **Sign in with Claude** and finish the browser sign-in. The Anthropic sign-in entry in **Providers** has the same button. If you already use the Claude CLI, you can run `claude setup-token` in Terminal. Paste the result under **Or use a setup token** and click **Save token**. |
| API key | Open **Or use an API key** in setup or **Add a provider** in **Providers**. Click **Add key** beside the provider that issued your key. Choose **A key** if the entry offers more than one method. Paste the key into **Key** and click **Save**. **Test connection** or **Test API key** checks the key with the provider. |
| Existing Codex CLI sign-in | If NativeAgent finds an eligible ChatGPT sign-in from Codex CLI on this Mac, click **Use it** below the ChatGPT button or under **Providers → Accounts → Codex CLI sign-in**. This gives NativeAgent permission to use the existing sign-in. The **Codex CLI** model route also requires the Codex command-line program on this Mac. |
| xAI Grok sign-in | Click **Sign in with xAI Grok** and finish the browser sign-in. From **Providers**, open the xAI sign-in entry first. |

Enter keys and tokens only in the protected entry on the Mac. Save stores a
key on this Mac. Testing checks whether the provider accepts the connection.
For what goes to a provider, see [Privacy](../PRIVACY.md).

## Choose the model Chat uses

In setup, select a **Chat model** from a connected account and click **Use
this model**. Then click **Continue**. If there are no models to choose yet,
use **Read accounts again** and read the account’s status message.

To change the choice later, open **Control → Providers → Chat → Model**.
Each choice names both the account and the model. This is your saved Chat
choice on the Mac. Work and Mind use the Chat account and model unless you
give those groups their own choices.

You can also use **Default model for Chat** on the account’s sign-in card.
It shows that account’s live model list. Choosing a model there immediately
saves it as the Chat default. That choice also appears in **Chat → Model**.

## Start a conversation

Setup opens **Chat**. Your agent can greet you there once Chat has a usable
provider. If your agent asks what kind of help you want, tell your agent
what you’d like help with. Type in the box at the bottom and press Return. Try
“What can I ask you to do?” You can type and get replies without giving
NativeAgent access to other Mac apps.

## Choose what your agent can do

Open **Control → Trust** and find **Standing** under **What I may do**.
You can change this as your needs change. **Full Mac** asks you to confirm.

| Standing | What it allows |
|---|---|
| **Safe** | Your agent can read allowed files, look things up, and work with saved notes. Changes to your files and apps, sending on your behalf, shell commands, and Git are blocked. |
| **Work mode** | Your agent can edit in approved workspaces. Your agent asks before taking the initiative to send messages or change things on your side. File writes outside the workspace are blocked. Shell, Git, and full computer control require Full Mac. |
| **Builder** | Your agent can edit in approved workspaces and ask before writing elsewhere. Sends still ask first when your agent starts them. Shell, Git, and full computer control require Full Mac. |
| **Full Mac** | Your agent can work with files across the Mac, use shell and system control, and move items to the Trash. Permanent deletion on your side can still ask you first. App switches, macOS grants, and connection checks still apply. |

## Grant macOS access when you need it

Your agent’s welcome can show a card for missing grants. On the Mac, choose
the card’s **Allow** button, labeled for the grant or **Allow all**, to
start the macOS prompts. You choose which grants to give. You can also
open **Control → Trust → macOS grants** and use **Ask
macOS** or **Open System Settings** on a particular row. For app access, check
the **Read** and **Write** switches under **Trust → Apps and features**.

| macOS grant | What you can use it for |
|---|---|
| **Accessibility** | Let your agent read app controls, click, type, or move windows when allowed. macOS may call this **Device Control**. |
| **Screen Recording** | Let your agent see the screen as an image. |
| **Input Monitoring** | Help NativeAgent tell when you are at the Mac and distinguish your typing from input it sends. |
| **Full Disk Access** | Read protected data such as Messages history and the Mail index, subject to Trust. Restart NativeAgent after granting it. Use **Restart NativeAgent** if the card offers it. |
| **Automation** | Let NativeAgent work with the specific app named in the macOS prompt. Each app has its own grant. |
| **Calendar, Reminders, Contacts** | Read the information or make changes the particular grant and Trust setting allow. |
| **Microphone, Speech Recognition** | Use voice input and turn speech into text. |
| **Notifications** | Show NativeAgent alerts on the Mac. |

You can leave any of these off and still use ordinary text Chat. Leave
microphone and speech access off if you type. Leave notifications off to
read updates inside NativeAgent. macOS may also require you to reopen the app
after granting **Screen Recording** or **Input Monitoring**.

## If something doesn’t work

| What you see | What to do |
|---|---|
| Chat asks you to connect an account | Click **Open Providers** in Chat or open **Control → Providers**. Connect an account under **Accounts**. |
| No model is selected, or there is no model to choose | In setup, click **Read accounts again**. In **Providers**, open **Catalog → Models** and click **Refresh**. Read the account’s message if its list is still empty. Once a model is offered, set it under **Chat → Model**, or use **Use this model** if you are still in setup. |
| An action needs a permission | Read the card or error for the named grant. Use **Trust → macOS grants** on the Mac, then check the feature’s **Read** or **Write** switch if the action needs one. Restart the app if the grant requires it. |
| Your sign-in expired or was rejected | Go to the account in **Providers → Accounts**. Use **Sign in** or open its sign-in entry and choose **Re-authenticate** if shown. For an adopted Codex CLI sign-in, renew it in Codex or sign in to ChatGPT in NativeAgent. For a rejected key, use **Add key** to enter a valid one. |
| Chat or sign-in cannot reach the provider | Reconnect your Mac to the internet. If sign-in is still waiting, click **Cancel** and start it again. For a failed Chat turn, read the failure before retrying. When Chat says nothing ran, you can try the message again. |

If first launch shows **Couldn’t read setup**, read the error and click
**Retry**. For other problems, see [Health and troubleshooting](USER_GUIDE.md#health-and-troubleshooting).

To use your phone, follow [Pair your iPhone or iPad](USER_GUIDE.md#iphone-and-ipad).

Open **Control → Settings** or press Command-comma to change your preferences.
See [SETTINGS.md](SETTINGS.md) for every setting and its click path and
[WHERE_THINGS_ARE.md](WHERE_THINGS_ARE.md) for the page map.
