#!/usr/bin/env bash
# Fetch the large embedding model into extras/embedding/ (gitignored) from the
# repository's standalone model release, verify it, and unpack it. The model is
# too big for git; release DMGs carry it inside the app, and source builds get
# it from here. Idempotent: an already-complete folder is left alone.
#
# Env: NATIVEAGENT_EMBEDDING_MODEL_DIR (default <repo>/extras/embedding),
#      NATIVEAGENT_EMBEDDING_MODEL_TAG (default embedding-model-bge-large-en-v1.5).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${NATIVEAGENT_EMBEDDING_MODEL_DIR:-$ROOT/extras/embedding}"
TAG="${NATIVEAGENT_EMBEDDING_MODEL_TAG:-embedding-model-bge-large-en-v1.5}"
# The public repository hosts the asset for anonymous downloads; the private
# development repository carries the same release for the maintainers' builds.
PUBLIC_REPO="${NATIVEAGENT_EMBEDDING_MODEL_REPO:-embwl0x/native-agent}"
PRIVATE_REPO="embwl0x/NativeAgent"
ASSET="bge-large-en-v1.5-coreml.zip"
BASE_URL="https://github.com/$PUBLIC_REPO/releases/download/$TAG"

if [[ -f "$DEST/embedding.json" && -d "$DEST/embedding.mlpackage" && -f "$DEST/vocab.txt" ]]; then
  echo "[embedding] already present at $DEST"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-embedding.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
echo "[embedding] downloading $ASSET from $TAG (about 600 MB)…"
# Parallel ranged download. Many links cap a single stream far below the
# pipe (measured 37 KB/s per connection on hotel Wi-Fi with 1 MB/s available),
# so the asset is pulled as PARTS concurrent byte ranges, each retried and
# resumable on its own, then joined. HTTP/1.1 because a reset HTTP/2 stream
# cannot be resumed the way a ranged retry can.
PARTS="${NATIVEAGENT_EMBEDDING_FETCH_PARALLEL:-24}"
fetch_small() { curl -fsL --http1.1 --retry 8 --retry-delay 3 --retry-all-errors -o "$2" "$1"; }
fetch_parallel() { # $1 = url, $2 = destination
  local url="$1" dest="$2" final size chunk i start end n=0
  local pids=()
  final="$(curl -sIL --http1.1 -o /dev/null -w '%{url_effective}' "$url")"
  size="$(curl -sI --http1.1 "$final" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)"
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || { echo "[embedding] could not read the asset size" >&2; return 1; }
  chunk=$(( (size + PARTS - 1) / PARTS ))
  mkdir -p "$dest.parts"
  for ((i = 0; i < PARTS; i++)); do
    start=$(( i * chunk )); end=$(( start + chunk - 1 )); (( end >= size )) && end=$(( size - 1 ))
    (( start > end )) && break
    (
      part="$dest.parts/$i"; want=$(( end - start + 1 ))
      for attempt in 1 2 3 4 5 6; do
        have=0; [[ -f "$part" ]] && have="$(stat -f %z "$part" 2>/dev/null || stat -c %s "$part")"
        (( have == want )) && exit 0
        (( have > want )) && rm -f "$part" && have=0
        curl -fsL --http1.1 --retry 3 --retry-delay 2 --retry-all-errors \
          -r "$(( start + have ))-$end" -o "$part.tmp" "$final" && cat "$part.tmp" >> "$part" && rm -f "$part.tmp" && continue
        sleep $(( attempt * 3 ))
      done
      have=0; [[ -f "$part" ]] && have="$(stat -f %z "$part" 2>/dev/null || stat -c %s "$part")"
      (( have == want ))
    ) &
    pids[n]=$!; n=$(( n + 1 ))
  done
  # macOS ships bash 3.2: no `wait -n`, so wait on each pid in turn.
  local fail=0 pid
  for pid in "${pids[@]}"; do wait "$pid" || fail=1; done
  (( fail == 0 )) || { echo "[embedding] a part failed after retries" >&2; return 1; }
  : > "$dest"
  for ((i = 0; i < PARTS; i++)); do [[ -f "$dest.parts/$i" ]] && cat "$dest.parts/$i" >> "$dest"; done
  rm -rf "$dest.parts"
  local got; got="$(stat -f %z "$dest" 2>/dev/null || stat -c %s "$dest")"
  (( got == size )) || { echo "[embedding] joined size $got != $size" >&2; return 1; }
}
if ! fetch_parallel "$BASE_URL/$ASSET" "$WORK/$ASSET" \
   || ! fetch_small "$BASE_URL/$ASSET.sha256" "$WORK/$ASSET.sha256"; then
  # Not reachable anonymously (or not published yet): an authenticated gh
  # can pull the same release from either repository.
  command -v gh >/dev/null || { echo "[embedding] download failed and gh is not installed" >&2; exit 1; }
  rm -rf "$WORK/$ASSET" "$WORK/$ASSET.parts" "$WORK/$ASSET.sha256"
  gh release download "$TAG" --repo "$PUBLIC_REPO" --dir "$WORK" --pattern "$ASSET*" 2>/dev/null \
    || gh release download "$TAG" --repo "$PRIVATE_REPO" --dir "$WORK" --pattern "$ASSET*"
fi
( cd "$WORK" && shasum -a 256 -c "$ASSET.sha256" )
mkdir -p "$(dirname "$DEST")"
rm -rf "$WORK/unpacked" && mkdir -p "$WORK/unpacked"
unzip -q "$WORK/$ASSET" -d "$WORK/unpacked"
rm -rf "$DEST"
mv "$WORK/unpacked/embedding" "$DEST"
echo "[embedding] installed $(du -sh "$DEST" | cut -f1) at $DEST"
