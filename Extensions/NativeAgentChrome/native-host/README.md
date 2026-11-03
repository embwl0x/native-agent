# NativeAgent Chrome native host

The pinned development extension id is
`egdbijiogeeggnmjheomgnnkhmlepfcn`. It is derived from the public RSA key in
the extension manifest. The native-host template permits that exact origin;
it never uses a wildcard.

`com.nativeagent.chrome.json.in` is a source template because Chrome requires
`path` to be an absolute path on the installed Mac. NativeAgent.app registers
its bundled relay while **Chrome control** is enabled in Trust Center and
removes the registration when disabled. The app atomically writes:

```text
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.nativeagent.chrome.json
```

The installed app accepts only its own bundled relay executable, with its
signed identity and browser-launch proof checked for every connection. Disabling
native-host registration administration for a secondary install does not
disable peer authentication. A missing bundled relay prevents listener startup.
No manual registration is needed for normal use; policy reconciliation can
replace a registration explicitly owned by this app. The manifest's
`nativeagent_bundle_id` is the sole ownership field; a missing owner, relay path
spelling or unreadable former bundle cannot authorize adoption or removal.
Current and secondary bundle variants retain separate sockets. Connection
history is stored only in the socket's `.connection-facts.json`; its observed
`extensionSeenAt` supplies historical connection evidence. The redundant
`.extension-connected` marker is no longer read or written. Missing facts mean
no confirmed history; unreadable facts retain `diagnostic_storage_error`.
Neither is a verdict about whether Chrome has ever connected.

The handshake uses the throwing socket-peer and running-browser signing checks.
A refusal preserves the failing API/check and its OSStatus or POSIX errno in
`chrome.status.last_handshake_reason`, rather than diagnosing a signature
mismatch from an unreadable identity. A reparented relay still needs its
authenticated launch-time browser evidence; it has no current browser PID for
reload proof. The accepted handshake's checked PID is passed to the runtime,
without a second lossy identity lookup.

The manual [installer](../../../script/install_chrome_native_host.sh) replaces
the same user-wide Chrome registration shown above; `--uninstall` removes it.
Its default relay is
`~/Applications/NativeAgent.app/Contents/MacOS/NativeAgentChromeRelay`;
`--relay` selects another executable for that shared manifest, but the running
app still accepts only its own bundled relay and may replace the registration.
The installer reads the relay app's actual `CFBundleIdentifier` and writes
`nativeagent_bundle_id`; a missing/unreadable app identity stops installation.
The source template requires both the absolute relay path and this explicit
bundle identifier to be filled before installation.
Development verification follows [AGENTS.md](../../../AGENTS.md).

Stop and the app's request deadline send the same request-scoped cancellation
event for every action. The extension checks it before effects after suspension
and wakes pending waits. A dispatched request keeps its app waiter for the
extension's settlement reply, including partial typing evidence; the original
deadline still reports an unknown outcome if no effect reply arrives. Debugger
detach and other resource release complete even after cancellation.

Back and Forward use Chrome's debugger to reach the exact neighboring history
entry. Attach failure refuses that operation; Chrome's skipping tab-history APIs
never run. Current navigation, custody and cancellation are checked after every
suspension before the navigation effect. Owned PDFs need no page agent.

Text editing and keypresses share one trusted debugger input session per action,
with hidden-tab focus emulation. DOM reads never attach. Detachment runs once in
settlement; `cleanupError` remains beside the effect or picture, and alongside
an operation failure. Picture-result reconstruction in Swift preserves it.

The installer's `--extension-id` option adds an exact origin to that shared
manifest; the pinned development id is always included. A different extension
identity also requires coordinated app and
relay identity changes; a manifest edit alone does not change their pinned
identity. Never replace exact origins with a wildcard.

Both relay directions and the app currently cap each JSON payload at
1,048,576 UTF-8 bytes. A picture must fit that bound as a complete response,
including base64 data and metadata; an oversized response returns
`picture_too_large` before transport instead of disconnecting the relay.

## Development-key generation

The committed manifest contains only the public key. To reproduce the process
for an intentional identity rotation, generate and protect a private key
outside the repository:

```bash
key_dir="$HOME/Library/Application Support/NativeAgent/ChromeExtension"
umask 077
mkdir -p "$key_dir"
openssl genrsa -out "$key_dir/development-extension.pem" 2048
openssl rsa -in "$key_dir/development-extension.pem" \
  -pubout -outform DER | openssl base64 -A
```

Put the resulting base64 DER public key in `manifest.json` as `key`. Derive
Chrome's id from the first 16 SHA-256 bytes, mapping hex digits `0...f` to
letters `a...p`:

```bash
openssl rsa -in "$key_dir/development-extension.pem" \
  -pubout -outform DER 2>/dev/null \
  | openssl dgst -sha256 -binary \
  | xxd -p -c 256 \
  | cut -c1-32 \
  | tr '0123456789abcdef' 'abcdefghijklmnop'
```

Rotating this key changes the extension id and therefore requires an atomic
update to every exact `allowed_origins` registration.
