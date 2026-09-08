# Second-note design gate — 2026-09-07

All `f1c-` PNGs are R26-iPhone / iOS 26.5 simulator captures (1206×2622), made
with `simctl io screenshot`. Earlier PNGs without this prefix are historical.

| Capture | What it demonstrates |
| --- | --- |
| [Light chat](f1c-chat-light-keyboard.png) | Populated thread, software keyboard, full final user bubble, long provider name |
| [Dark chat](f1c-chat-dark-keyboard.png) | Same composition in dark mode |
| [Light long model](f1c-chat-light-long-model.png) | Chip strip initially scrolled to the full long model name |
| [Dark long model](f1c-chat-dark-long-model.png) | Same long-model composition in dark mode |
| [Light AX2](f1c-chat-light-ax2-contrast-opaque.png) | Keyboard, AX2, Reduce Transparency and Increase Contrast together |
| [Dark AX2](f1c-chat-dark-ax2-contrast-opaque.png) | Same settings; opaque composer and single stronger hairline |
| [Growing composer](f1c-chat-light-growing-composer.png) | Four-line draft with keyboard; final user bubble stays above the composer |
| [Light empty](f1c-chat-light-empty.png) | Modest unadorned symbol, connection setup action, neutral placeholder |
| [Dark empty](f1c-chat-dark-empty.png) | Same empty state in dark mode |
| [Light Memories](f1c-memories-light.png) | Three populated sample rows, neutral metadata and tags |
| [Dark Memories](f1c-memories-dark.png) | Same populated secondary screen in dark mode |
| [Light Memories AX2](f1c-memories-light-ax2-contrast-opaque.png) | AX2, Reduce Transparency, Increase Contrast; full first memory text |
| [Dark Memories AX2](f1c-memories-dark-ax2-contrast-opaque.png) | Same settings in dark mode; cloud status no longer clipped |

## Reproduction and limits

Build the NativeAgentMobile scheme with automatic package resolution disabled,
install the Debug simulator app, then launch `io.github.embwl0x.nativeagent.ios`
with `-NativeAgentMobile.pairingSkipped YES -initialTab chat -chatSample
-chatSampleKeyboard`. Add `-chatSampleModel` to position the chip strip at the
long model; add `-chatSampleDraft <multiline text>` for composer growth.
For Memories use `-initialTab memories -memorySample` instead.

The samples are DEBUG-only, process-local view projections. No sample is
written into history, memory, snapshots, or the Mac. Sample chat submission and
memory deletion are disabled. Connection and freshness warnings are the real
simulator state; this is composition/scroll-layout evidence, not live iCloud
delivery evidence. The existing scheduler also follows real stored messages.

AX2 is `simctl ui booted content_size accessibility-large`. Contrast is
`simctl ui booted increase_contrast enabled`. Reduce Transparency uses
`simctl spawn booted defaults write com.apple.Accessibility
EnhancedBackgroundContrastEnabled -bool YES`, followed by app relaunch. The
opaque custom composer and stronger single border visibly confirm the fallback.
Settings were restored to large text, light appearance, normal contrast and
transparency afterward. The software keyboard was already enabled.

The last sample bubble is fully visible at standard size and AX2 with the
keyboard up. Messages taller than the available viewport remain scrollable;
no font shrinking is used. The chip strip preserves full labels and exposes
overflow with a trailing chevron; the model captures show its scrolled state.

## Composited contrast

WCAG sRGB luminance: `(lighter + 0.05) / (darker + 0.05)`. PNGs were decoded
through ImageIO/CoreGraphics into an sRGB RGBA buffer. Samples at normalized
coordinates (0.756, 0.096) and (0.790, 0.096) select the solid plus stroke and
adjacent navigation plate, avoiding antialiased edges. That control uses the
same opaque `accentText` token as interactive text. Ratios below use actual
composited plate pixels, not a claim that the proposed swatches alone pass.

| Capture | Accent text token | Composited plate | Ratio |
| --- | --- | --- | --- |
| Light chat | #006B73 | #FCFAF8 | **6.02:1** |
| Dark chat | #65CCD2 | #1E1C1B | **8.99:1** |
| Light AX2 / contrast / opaque | #006B73 | #F4F4F3 | **5.69:1** |
| Dark AX2 / contrast / opaque | #65CCD2 | #0E0D0C | **10.28:1** |
| Light “Set up connection” text | #006B73 | #F6F4F1 | **5.71:1** |
| Dark “Set up connection” text | #65CCD2 | #211F1D | **8.70:1** |

The last two rows sample actual text: the modal teal interior pixel in the
empty-state action region (x 0.32–0.68, y 0.59–0.62), against the adjacent
backdrop at (0.30, 0.604).

Opaque token references: light canvas 5.71:1, light content 6.27:1; dark canvas
8.70:1, dark content 7.88:1. All exceed 4.5:1 for normal text and 3:1 for
meaningful controls in these compositions. Native glass varies with its scene;
these numbers do not certify every possible backdrop. Decorative teal is not
used for text. Body/secondary text uses semantic system ink.

## Scope and validation

Final simulator `xcodebuild build` passed. The existing
`ChatScrollSchedulerEvalTests` suite passed once: 2 tests, zero failures.
Architecture blueprint and timer inventory scripts passed; `git diff --check`
passed. No Mac target was built because no Mac code changed.

Production edits are confined to `NativeAgentMobileTheme.swift`, `ChatView.swift`
and `MemoryView.swift`; the architecture family narrative documents their wiring.
There are no new Swift files, timers, transport, resilience or memory ownership
changes, so timer/resilience/memory maps retain their existing contracts.

Native TabView and its app-wide icon/accent choices remain owned by ContentView
outside this area. Activity retains its name and semantics. The shared freshness
banner still uses its existing rounded type and takes substantial vertical space
at AX2; it remains truthful and was not restyled across unrelated screens.
