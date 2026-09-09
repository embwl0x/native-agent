# Images through the actual Codex tool

User's requested route is Codex's built-in `image_gen.imagegen`, not a custom
NativeAgent HTTP image integration. `image_generate` defaults to that route:
it runs `codex exec --enable image_generation --json` in a private run directory,
with instructions to use only the built-in tool. `codex_cli` is an alias.
No direct HTTP image client or platform API fallback runs on this path.
The existing paid provider remains explicit and is never selected automatically.

## Proven path and model visibility

The 2026-09-08 local Codex proof called the real built-in tool, generated a
brass telescope with an AGENT plaque, and verified its PNG alpha channel.
Its Codex task was `01a08302-8f19-75e2-a939-50b640449b5d`; the persisted tool
call and artifact corroborate execution. The built-in result exposed no model
identifier. Neither the image's appearance nor an accepted model name proves
Images 2.5. [Codex documentation](https://learn.chatgpt.com/docs/image-generation)
still names gpt-image-2, while API documentation has separate 2.5 controls.
Do not substitute API support claims for the actual Codex tool surface.

## How Agent uses it

Find image_generate with tool_catalog and retrieve its help with tool_load.
For generation, describe the subject, composition, lighting, exact quoted text
and desired finish. Request a transparent cutout in the prompt or with the
background preference. For editing, inspect references first and supply
referenced_image_paths; state precisely what changes and what stays.

```json
{"prompt":"A polished brass telescope on a teal base, plaque reading AGENT; isolated cutout","background":"transparent"}
```

```json
{"prompt":"Change only the base to violet; preserve the telescope and AGENT plaque","action":"edit","referenced_image_paths":["/absolute/path/from/previous/result.png"]}
```

References are authorized through existing file gates, copied into the private
run directory and attached to Codex. Their order is preserved. Use image 1 for
layout and image 2 for colors, for example. Continue by supplying the latest
returned result path. Separate calls have no implicit shared image history.

The actual built-in callable accepts a prompt and reference inputs. It does
not expose a model selector or explicit quality field. NativeAgent's quality,
size/aspect, format and background fields are therefore **prompt preferences**.
High detail may be requested, but executed high quality is not inferred.
NativeAgent does not choose Sunburst/Flare or claim an exact Images version.
Masks, compression controls and image reasoning effort are not exposed.

## Results and execution boundaries

`transport=codex_builtin`, `sourceTool=image_gen.imagegen` and `codexThreadId`
identify the execution route. Model identity remains unknown when Codex does
not expose it. `qualityRequestForwarding=prompt_preference` and unknown quality
fulfillment make that limitation explicit. Decoded raster dimensions and format
are reported separately from requested preferences; alpha metadata describes
channel presence, not a guarantee every background pixel is clear.

Only images inside the exact Codex task's generated_images directory can be
collected. Other concurrent Codex images are excluded. Complete raster decoding
is required; corrupt/missing files fail instead of becoming success artifacts.
Outputs and receipts remain private in NativeAgent data/generated_images.

Trust Center precedes reference reads and process launch. Four references at
most, 8 MiB each, 20 MiB total, 40 MP each. n requests 1–4 images. The whole
Codex run has a 30–1800 second timeout (default 600). Cancellation uses the
existing process-tree owner. Failures never switch to an API or automatically
retry. Build the integrated app, run focused image tests, then directly verify
the installed NativeAgent tool with a real Codex generation/edit.
