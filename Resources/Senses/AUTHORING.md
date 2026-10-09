# Write a sense

Return one self-contained ES2020 JavaScript file. No imports, host IO or
network. Start with frame.js; copy only the shared helpers your reader needs.
The builtin entries are complete worked examples. The examples/ files are
their small format entry points; lib/ holds the shared readers. assemble.sh
concatenates these authoring sources into the runnable builtin/ entries.

Define read(request). Read real material with sense.source.read(address?).
File material has kind, path, bytes and data (Uint8Array). Accessibility
material has kind and tree. Publish exactly one page with sense.publish:
address, title, text, things, folded and optional more. Each thing has name,
kind, address, optional detail and verbs. The runtime supplies the corner.

NativeKit builds addresses and things and folds pages to 40,000 UTF-8 bytes
(NativePage.maximumTextBytes). Keep a document's identities in its addresses:
sheet ID, table UUID, cell A1; slide number and shape order; paragraph ID;
EPUB spine item ID. Normalize CR, CRLF, line separator and paragraph separator
as paragraph breaks. Object replacement characters are not readable text.
Read the returned more address to continue, or any thing address to focus.
File material includes its SHA-256 version. File more addresses retain that
version; a changed file requires reading from the start. Preserve the full cursor.
Use NativeKit.sourceAddress to recover the source file from those addresses.
Do not pass a synthetic cell or page cursor to the raw source provider.

Use readable roles from the format and ordinal text names in reading order;
archive identifiers belong in addresses, never labels. A NativeKit item with
`aggregate: true` keeps its content as detail while its descendants print it
once. An item with `addressedOnly: true` stays in things and prints only on a
direct read of its address. DOCX uses this for table rows and cells. PPTX
shapes own separate paragraph things. Numbers reports the populated data
extent and omits empty cells, rather than presenting the allocated grid as data.

Read and publish only. Offer a verb only when you can translate it to a real
door request. Define act(request) and call sense.act(existingActionID, address, args)
only during that request. Never act in read, watch or changed. Acts
return the door's actual receipt; an authored act return value cannot replace
it, and an act that makes no door request has no success receipt.
Live senses may define watch() using sense.source.watch(), and changed(material) using
sense.notify({address, summary}); keep notebook state small and nonsecret.
Before composing news, call `sense.redactText(text)` on each original source
fragment, including addresses, URLs, titles, summaries, navigation endpoints,
names, values and nested strings, before prefixes, whitespace folding,
clipping, percent encoding or JSON encoding. Apply it again to the final composed
news line and use the returned text. The shared Swift policy repeats decoding
and URL extraction to a fixpoint, applies the existing turn redactor to whole
text and query assignments (`name=value`), and redacts URL userinfo. Redacted
fragments return decoded; safe fragments retain their original spelling. Never
add a separate secret detector to a reader.

Throw on corrupt, unsupported or ambiguous material. Do not replace failures
with a guessed view. Mark stored formula values as cached; do not invent
cell coordinates, text order, canvas objects, or verbs from pixels. AX paths
are stable while the tree shape stays the same; say when an address relies
on one. Preserve source redaction. Keep extraction and expansion bounded.

## Live sites

Site material is `{kind:"page", snapshot}` from Agent's existing Chrome
tab. `snapshot.summary.text` is the independent text view. Preserve it;
derive things and verbs from `snapshot.nodes`, never from guessed controls.
`builtin/site.js` is the worked live site example. Its addresses encode the
page URL and Chrome's structural `elementPath`; preserve that convention in
grown site senses. Paths include the live frame, DOM ancestry and shadow
boundaries and remain stable while that structure stays the same. Resolve
focus and folded cursors against the current snapshot of that same URL.
`more` anchors the next element path and text offset, never a snapshot ID or
row number. If the path disappears or the URL changes, fail explicitly.

Only source actions authorize site verbs: `click` maps to `chrome.click`,
`fill` to `chrome.fill` with `{value}`, and `select` to `chrome.select` with
`{values}`. `open link` maps to `chrome.click` only on a real link with a URL
and the click action. These app IDs use the existing `browser.chrome_*`
actions under Trust. The runtime supplies the captured tab, snapshot,
user sequence and node proof; do not override them. Do not acquire a tab,
navigate to a supplied URL, open a tab, or reach desktop actions.

A site sense uses live mode. Subscribe in `watch()` with
`sense.source.watch()`. DOM change events arrive in `changed(material)`;
publish that material, compare its actual text and control state with the
read baseline, and notify its page address and actual text only for a
material change. Ignore snapshot IDs and capture times in this comparison;
use Chrome's stable element identities. Initial or identical snapshots are
not news. Never poll or act in `watch` or `changed`, and never notify during `read`.

Compare only the same reading scope, node/text limits and transport coverage.
`snapshot.reading` carries these bounds. If the view configuration changes,
or its transport bound changes while `encoded_size_limit` is present in
`summary.truncationReasons`, establish a new baseline without news. A
different capture window is not evidence that the site changed.
