# Image generation

The agent makes images through its one always-on door, `app`. `AppActions+Declarations.swift`
registers `image.generate` on the Chat page. Discover it with
`app {"find":"image"}` or read `app {"page":"chat"}`.

## How the agent uses it

Pass the image request inside `args`:

```json
{"action":"image.generate","args":{"prompt":"A polished brass telescope on a teal base, plaque reading AGENT; isolated cutout","background":"transparent"}}
```

For an edit on the Codex route, inspect the reference first, then supply its
local path and describe exactly what changes:

```json
{"action":"image.generate","args":{"prompt":"Change only the base to violet; preserve the telescope and AGENT plaque","action":"edit","referenced_image_paths":["/absolute/path/from/previous/result.png"]}}
```

Reuse the latest returned image path for another edit. Independent calls have
no implicit shared image history. Reference order is preserved.

## Provider selection

The checked **Work** provider route selects the backend. In
`FirstPartyModelCatalog.imageRoute(forProviderID:)`, OpenAI maps to `openai_api`;
Codex and `openai_oauth_direct` map to `codex`. An unsupported Work route stops
with a model-choice card only after a successful routing read establishes its
capability. A failed routing read returns its cause without asking for a model
choice. Work owns provider and image model. The retired `provider`, `backend`,
`model`, `description`, `format` and `count` arguments are refused, including
matching provider/model names. Use `prompt`, `output_format` and `n`.
Recovery cards retain that request's checked route and routing snapshot; a
resumed request reads routing again and applies its one-request model choice.

The Codex path runs `codex exec --enable image_generation --json` and requests
the built-in `image_gen.imagegen` tool. It uses the app's resolved Codex auth
home and the Work controller model. The worker has an empty per-run directory,
a read-only sandbox, an allowlisted environment, ignored user config/rules,
and disabled non-image tool families. It is still a general Codex worker,
not a dedicated image API. Failure does not switch providers.

The OpenAI API path requires its configured API key and supports generation;
the edit/reference/background controls above are not implemented on that path.

## Results and execution boundaries

On the Codex route, quality, size/aspect, format and background are prompt
preferences. The receipt reports `transport=codex_builtin`,
`sourceTool=image_gen.imagegen`, and `codexThreadId`. It records image-model
identity and quality fulfillment as unknown: the built-in result exposes neither.
A controller model or requested quality is not image-model proof. Aggregate
control warnings reduce only the inspected per-image size and format evidence.

NativeAgent decodes the returned raster and reports actual dimensions, format
and alpha-channel presence. Alpha presence alone does not prove a transparent
background. Only files from that exact Codex thread's `generated_images`
directory are collected; outputs and receipts are kept under
`<dataRoot>/generated_images`.

The final-message file is the sole Codex reply source. Its missing, empty or
unreadable contents are retained as `finalReplyError` in the run output and
as `finalReplyAvailability:unavailable` with the cause in each image's evidence.
Verified image artifacts retain their own result; process stdout stays separate
from the assistant reply.

`output_format` defaults to PNG only when omitted. Supplied values must be
`png`, `jpeg` (also `jpg`) or `webp`, ignoring case and surrounding whitespace;
empty, null, non-string and unsupported values fail before routing or provider
execution. Codex quality accepts only `low`, `medium`, `high` or `auto`;
image-model names are not quality selectors.

Successful results from either backend return `status: ok` and pass through
`make-generated` to register their images in Make. Try again uses the same
path with the existing Make reference, adding a version. A stopped result
keeps `status: stopped` and its produced images without registering success.
Both backends settle produced output before returning, including after Stop.
Each committed file stays in `images`, identified by run ID, index and path,
with byte size and inspected format, dimensions and alpha evidence. Extensions
follow actual bytes; requested format remains separate. A file failure adds
its index, attempted path (or retained Codex source path) and cause to `failures`;
sibling files still proceed. Any item failure returns `status: partial`.
OpenAI decodes each response item independently: an undecodable item adds its
original `index`, `stage: decode` and cause to `failures`, while decoded siblings
continue to persistence. A missing or empty response data array remains a
response failure; a nonempty batch of invalid items retains each named failure.
Codex collects produced files before reporting a nonzero worker exit, keeping
the committed images and `stage: worker` failure with its `exitCode` in the
same partial receipt. Raster inspection failures are scoped to the source file
with `stage: inspect`, its original index and source path; siblings continue.
The terminal receipt is written once from those rows. `receiptPersistence`
is `committed` with `receiptPath`, or `failed` with `receiptWriteFailure` and
`status: partial`; committed image rows remain in the response either way.
Partial results still supply thumbnails and reply attachments; they do not
register a completed generation in Make. Inspect their retained paths rather
than generating the batch again. `generationStopped` retains Codex Stop evidence
even when persistence also fails. Existing redacted prompt-preview bounds remain.

Mac chat's screenshot attachment requires the primary display's physical pixel
geometry and a capture matching it. It scales once to at most 1600 pixels on
the longest edge, then encodes JPEG at quality 0.78, with a 6 MiB byte bound.
Geometry, resize and encoding failures are distinct; only encoded bytes over
the bound report too large. It never substitutes point geometry, the unscaled
image, another quality or PNG. Main and detached composers use this same owner.
Clipboard image conversion failures show the decoder's refusal and stop;
they do not open the file picker.

Saved Trust authority gates routing, execution and reference reads; damaged
policy fails with repair evidence. Codex accepts up to four local PNG/JPEG/WebP
references, each at most 8 MiB and 40 megapixels, 20 MiB total. `n` is clamped
to 1–4; `timeout_seconds` to 30–1800, default 600. Masks, implicit prior-image
references, compression and image reasoning-effort controls are refused.

Implementation under `Modules/NativeAgentCore/Sources/ChatToolRuntime/`: routing,
display and receipts in `SwiftToolDispatcher+ImageGenerationTools.swift`; transports
in `SwiftCodexImageGenerationClient.swift` and `SwiftOpenAIImageGenerationClient.swift`;
reference admission and controls in `CodexImageGenerationControls.swift`.
