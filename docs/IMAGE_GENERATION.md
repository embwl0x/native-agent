# Image generation

Agent makes images through the always-on `app` tool. `AppActionRegistry.swift`
registers `image.generate` on the Chat page. Discover it with
`app {"find":"image"}` or read `app {"page":"chat"}`.

## How Agent uses it

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
with a model-choice card. Request arguments cannot select a different provider
or image model; a conflicting `provider`, `backend`, or `model` is refused.
`codex_cli` is accepted as an alias when Work resolves to Codex.

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
identity and quality fulfillment as unknown when the built-in result does not
expose them. A controller model or requested quality is not image-model proof.

NativeAgent decodes the returned raster and reports actual dimensions, format
and alpha-channel presence. Alpha presence alone does not prove a transparent
background. Only files from that exact Codex thread's `generated_images`
directory are collected; outputs and receipts are kept under
`<dataRoot>/generated_images`.

Trust admission precedes execution and reference reads. Codex accepts up to
four local PNG/JPEG/WebP references, each at most 8 MiB and 40 megapixels,
20 MiB total. `n` is clamped to 1–4; `timeout_seconds` to 30–1800, default 600.
Masks, implicit prior-image references, compression and image reasoning-effort
controls are refused.

Implementation: `ChatToolRuntime/SwiftToolDispatcher+ImageGenerationTools.swift`
and `ChatToolRuntime/CodexImageGenerationControls.swift` under
`Modules/NativeAgentCore/Sources/`.
