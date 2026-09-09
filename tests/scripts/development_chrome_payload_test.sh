#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-dev-chrome.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE/script" "$FIXTURE/Extensions" "$TMP/bin" "$TMP/products"
cp "$ROOT/script/build_and_run.sh" "$FIXTURE/script/"
cp -R "$ROOT/script/lib" "$FIXTURE/script/lib"
cp -R "$ROOT/Extensions/NativeAgentChrome" "$FIXTURE/Extensions/"
printf '// fixture\n' > "$FIXTURE/Package.swift"
printf '{}\n' > "$FIXTURE/Package.resolved"
printf '0.0.0\n' > "$FIXTURE/VERSION"
for product in NativeAgentApp NativeAgentChromeRelay; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/products/$product"
  chmod +x "$TMP/products/$product"
done
# Run the actual build-only workflow; replace compilation and signing so this
# fixture never touches the running app, credentials, or network.
cat > "$TMP/bin/swift" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" --show-bin-path "*) printf '%s\n' "$CHROME_TEST_PRODUCTS";; esac
exit 0
STUB
chmod +x "$TMP/bin/swift"
cat > "$FIXTURE/script/lib/development_bundle_signing.sh" <<'STUB'
nativeagent_sign_development_bundle() { :; }
STUB
PATH="$TMP/bin:$PATH" CHROME_TEST_PRODUCTS="$TMP/products" \
  NATIVEAGENT_SKIP_EMBEDDING_FETCH=1 \
  bash "$FIXTURE/script/build_and_run.sh" --build-only > "$TMP/build.log" 2>&1 \
  || { cat "$TMP/build.log" >&2; exit 1; }
BUNDLE="$FIXTURE/dist/NativeAgent.app"
[[ -x "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay" ]] \
  && cmp -s "$TMP/products/NativeAgentChromeRelay" "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay" \
  && cmp -s "$ROOT/Extensions/NativeAgentChrome/manifest.json" "$BUNDLE/Contents/Resources/NativeAgentChrome/manifest.json" \
  && diff -r "$ROOT/Extensions/NativeAgentChrome/src" "$BUNDLE/Contents/Resources/NativeAgentChrome/src" \
  && [[ ! -e "$BUNDLE/Contents/Resources/NativeAgentChrome/tests" ]] \
  || { echo 'FAIL: dev-built bundle is missing the release Chrome payload' >&2; exit 1; }
echo 'PASS: dev-built bundle contains the Chrome relay and extension'
