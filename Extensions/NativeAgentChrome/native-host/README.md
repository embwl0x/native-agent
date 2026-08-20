# NativeAgent Chrome native host

The pinned development extension id is
`egdbijiogeeggnmjheomgnnkhmlepfcn`. It is derived from the public RSA key in
the extension manifest. The native-host template permits that exact origin;
it never uses a wildcard.

`com.nativeagent.chrome.json.in` is a source template because Chrome requires
`path` to be an absolute path on the installed Mac. The installer resolves the
actual relay and atomically writes:

```text
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.nativeagent.chrome.json
```

After the relay is bundled, manual development registration is:

```bash
./script/install_chrome_native_host.sh
```

An alternate signed relay can be selected explicitly:

```bash
./script/install_chrome_native_host.sh \
  --relay /absolute/path/to/NativeAgentChromeRelay
```

Future production distribution must add its exact Chrome Web Store extension
id with `--extension-id`; it must not replace the pinned development id with a
wildcard. Trust Center's later on/off unit will own calling install/uninstall.
This unit does not register the host automatically.

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
