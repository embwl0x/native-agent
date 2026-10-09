#!/bin/sh
# Compose the shared sources into the single ES2020 file the plug accepts.
# Authoring/build operation only; does not execute senses or contact the app.
set -eu
cd "$(dirname "$0")"
mkdir -p builtin
for kind in docx xlsx pptx epub; do
    cat frame.js lib/zip.js lib/xml.js lib/documents.js "examples/$kind.js" > "builtin/$kind.js"
done
for kind in pages numbers key; do
    cat frame.js lib/zip.js lib/iwork.js "examples/$kind.js" > "builtin/$kind.js"
done
for kind in rtf rtfd; do
    cat frame.js lib/zip.js lib/rtf.js "examples/$kind.js" > "builtin/$kind.js"
done
cat frame.js examples/canvas-accessibility.js > builtin/canvas-accessibility.js
