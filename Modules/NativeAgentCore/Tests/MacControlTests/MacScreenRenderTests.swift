import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

@Test func unknownSemanticOmissionsDoNotInventActionableControls() {
    let percept = MacLookPercept(app: nil, windowTitle: "Partial capture", focus: nil,
        modal: nil, landmarks: [], affordances: [], unlabeledByRole: [:], affordancesOmitted: 14,
        interactiveCount: 14, labeledCount: 14, truncated: false, truncationReasons: [], skippedAtLeast: 0)
    let screen = MacScreenRender.screen(from: percept)
    let rendering = MacScreenRender.rendering(screen)
    #expect(screen.totalControls == 0)
    #expect(screen.contents.isEmpty)
    #expect(rendering.controlsDropped == 0 && rendering.rowsDropped == 0)
    #expect(rendering.text.contains("Semantic read omitted 14 AX targets"))
    #expect(!rendering.text.contains("14 actionable"))
}

// MARK: - MacScreenRender — ONE STRUCTURE, EVERY SCREEN
//
// docs/build_plans/native-screen.md. These tests exist to prove ONE claim: the
// same renderer, called the same way, turns an AX-rich app, an AX-blind
// pixels-only app, and a fused screen into the SAME sections in the SAME order,
// differing only in per-row provenance and confidence.
//
// Two fixtures carry that weight and are deliberately maximally unlike each
// other:
//
//   (a) an AX-rich list app — built by running the REAL `MacPerceptionCompiler`
//       over a synthetic AX tree, so the redaction channels the renderer prints
//       are the production ones and not a fixture's idea of them
//       (feedback_replay_the_real_store_before_fixtures: a fixture that
//       hand-writes `labelJSON` tests my assumption against itself).
//   (b) an AX-BLIND canvas+grid app — vision rows, mixed confidence, abstains,
//       a CANVAS carrying its pixel size.
//
// Both go through `MacScreenRender.render` — the IDENTICAL call, no source
// argument, no mode. If a future change makes the vision path need its own
// entry point, these tests are what breaks.

// MARK: - Synthetic AX tree helpers

private func node(
    _ path: [Int],
    _ role: String,
    subrole: String? = nil,
    title: String? = nil,
    value: String? = nil,
    enabled: Bool = true,
    frame: MacAXFrame? = nil,
    actions: [String] = []
) -> MacAXNode {
    MacAXNode(
        attributes: MacAXAttributes(
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            enabled: enabled,
            frame: frame,
            actions: actions
        ),
        path: path
    )
}

private func snapshot(_ nodes: [MacAXNode]) -> MacAXTreeSnapshot {
    MacAXTreeSnapshot(nodes: nodes, truncated: false, truncationReasons: [], skippedAtLeast: 0)
}

/// FIXTURE (a) — an AX-rich list app: a toolbar of controls, a scrollable list
/// of seven rows, a status readout. Shape only; nothing here names an app.
private func listAppPercept() -> MacLookPercept {
    var nodes: [MacAXNode] = [
        node([], "AXWindow", subrole: "AXStandardWindow", title: "Documents"),
        node([0], "AXToolbar"),
        node([0, 0], "AXButton", title: "Back", actions: ["AXPress"]),
        node([0, 1], "AXButton", title: "Forward", actions: ["AXPress"]),
        node([0, 2], "AXPopUpButton", title: "View", value: "List", actions: ["AXPress"]),
        node([0, 3], "AXTextField", title: "Search"),
        node([0, 4], "AXButton", title: "New Folder", enabled: false, actions: ["AXPress"]),
        node([0, 5], "AXButton", actions: ["AXPress"]),
        node([0, 6], "AXButton", actions: ["AXPress"]),
        node([1], "AXScrollArea"),
    ]
    let rows = [
        "report.pdf", "notes.md", "Screenshots", "budget.xlsx",
        "archive", "draft.txt", "receipts",
    ]
    for (index, name) in rows.enumerated() {
        nodes.append(node([1, index], "AXTextField", title: name))
    }
    nodes.append(node([2], "AXStaticText", value: "12 items, 4.2 GB available"))

    return MacPerceptionCompiler.compile(
        snapshot: snapshot(nodes),
        app: MacAXAppInfo(name: "Files", bundleIdentifier: "example.files", processIdentifier: 501),
        windowTitle: "Documents",
        focusPath: [1, 0]
    )
}

// MARK: - Vision-shaped fixture helpers
//
// The vision ADAPTER lives in VisionPerception (which depends on MacControl,
// never the reverse), so these rows are built directly against the neutral
// model — exactly what that adapter will fill. The point of the fixture is that
// the renderer needs no knowledge of where the rows came from.

private func visionText(_ text: String) -> MacScreenText {
    MacScreenText(text, redacted: .string(text))
}

/// FIXTURE (b) — an AX-BLIND app perceived from pixels only: a grid of cells
/// with mixed per-row confidence, two rows that ABSTAIN, a CANVAS region that
/// is genuinely not interpretable as controls, and vision-provenance controls.
private func canvasAppScreen() -> MacScreenRender.Screen {
    MacScreenRender.Screen(
        appName: "Unnamed Fullscreen App",
        windowTitle: visionText("Unnamed Fullscreen App"),
        isFront: true,
        otherWindows: 0,
        provenance: .vision(0.98),
        whereSteps: [
            MacScreenRender.WhereStep(label: visionText("Market"), provenance: .vision(0.71)),
            MacScreenRender.WhereStep(
                label: visionText("Browse"), note: "selected", provenance: .vision(0.68)
            ),
        ],
        contents: [
            MacScreenRender.Content(
                kind: .grid,
                rows: [
                    MacScreenRender.Row(
                        label: visionText("Linen Cloth"),
                        detail: [visionText("x20"), visionText("12g 40s")],
                        provenance: .vision(0.83)
                    ),
                    MacScreenRender.Row(
                        label: visionText("Copper Ore"),
                        detail: [visionText("x12"), visionText("8g 05s")],
                        provenance: .vision(0.79)
                    ),
                    MacScreenRender.Row(
                        label: nil,
                        detail: [visionText("x4"), visionText("2g 11s")],
                        provenance: .vision(0.41),
                        abstain: "overlapping targets"
                    ),
                    MacScreenRender.Row(
                        label: visionText("Silverleaf"),
                        detail: [visionText("x1"), visionText("55s")],
                        provenance: .vision(0.62)
                    ),
                ],
                totalRows: 28,
                scrollable: true
            ),
            MacScreenRender.Content(
                kind: .canvas,
                canvas: MacScreenRender.Canvas(
                    description: "world view",
                    width: 1512,
                    height: 760,
                    provenance: .vision(0.94)
                )
            ),
        ],
        controls: [
            MacScreenRender.Control(
                label: visionText("Browse"), kind: "tab", states: ["selected"],
                provenance: .vision(0.74)
            ),
            MacScreenRender.Control(
                label: visionText("Sell"), kind: "tab", provenance: .vision(0.72)
            ),
            MacScreenRender.Control(
                label: visionText("Search"), kind: "text", states: ["empty"],
                provenance: .vision(0.66)
            ),
            MacScreenRender.Control(
                label: visionText("Buyout"), kind: "button", provenance: .vision(0.44),
                abstain: "two identical buttons at this size"
            ),
        ],
        totalControls: 4,
        unlabeledControls: ["unknown": 9],
        values: [
            MacScreenRender.Value(text: visionText("Gold: 1,204g 88s 12c"), provenance: .vision(0.91)),
        ]
    )
}

/// FIXTURE (c) — a FUSED screen: an app with a native menu bar (AX) drawing its
/// own content (pixels). Both provenances live in ONE DO section, as rows of
/// differing evidence — never "AX mode" beside "vision mode".
private func fusedScreen() -> MacScreenRender.Screen {
    MacScreenRender.Screen(
        appName: "Hybrid",
        windowTitle: MacScreenText("Board", redacted: .string("Board")),
        isFront: true,
        otherWindows: 1,
        provenance: .ax,
        contents: [
            MacScreenRender.Content(
                kind: .list,
                rows: [
                    MacScreenRender.Row(
                        label: MacScreenText("Inbox", redacted: .string("Inbox")),
                        detail: [MacScreenText("row", redacted: .string("row"))],
                        provenance: .ax
                    ),
                    MacScreenRender.Row(
                        label: visionText("Archive"),
                        detail: [visionText("row")],
                        provenance: .vision(0.77)
                    ),
                ],
                totalRows: 2
            ),
        ],
        controls: [
            MacScreenRender.Control(
                label: MacScreenText("File", redacted: .string("File")),
                kind: "menu", provenance: .ax
            ),
            MacScreenRender.Control(
                label: MacScreenText("Edit", redacted: .string("Edit")),
                kind: "menu", provenance: .ax
            ),
            MacScreenRender.Control(
                label: visionText("New Card"), kind: "button", provenance: .vision(0.81)
            ),
            MacScreenRender.Control(
                label: visionText("Delete"), kind: "button", states: ["disabled"],
                provenance: .vision(0.58),
                abstain: "greyed fill could be the theme"
            ),
        ],
        totalControls: 4,
        values: [
            MacScreenRender.Value(
                text: MacScreenText("3 cards", redacted: .string("3 cards")), provenance: .ax
            ),
        ]
    )
}

// MARK: - Golden outputs
//
// Pasted verbatim from a run. They are here to be READ, not just matched: this
// is the surface an LLM consumes every turn, and a diff a human cannot read at
// a glance is a diff nobody reviews.

private let listAppGolden = """
SCREEN  Files · window "Documents" · FRONT · 2 other windows
WHERE   scrollarea > report.pdf (focused)
LIST    7 items, showing 5
  1   report.pdf              text                    ax
  2   notes.md                text                    ax
  3   Screenshots             text                    ax
  4   budget.xlsx             text                    ax
  5   archive                 text                    ax
  … 2 more below (scrollable)
DO      7 actionable
      Back                    button                  ax
      Forward                 button                  ax
      View                    popup = List            ax
      Search                  text (empty)            ax
      New Folder              button (disabled)       ax
button 1 ⟨unlabeled⟩          button                  ax
button 2 ⟨unlabeled⟩          button                  ax
SAYS    1 value
      "12 items, 4.2 GB available"                    ax

"""

private let canvasAppGolden = """
SCREEN  Unnamed Fullscreen App · window "Unnamed Fullscreen App" · FRONT  vision 0.98
WHERE   Market > Browse (selected)  vision 0.68
GRID    28 cells, showing 4
  1   Linen Cloth             x20  12g 40s            vision 0.83
  2   Copper Ore              x12  8g 05s             vision 0.79
  3   ⟨unlabeled⟩             x4  2g 11s              vision 0.41  ABSTAINED: overlapping targets
  4   Silverleaf              x1  55s                 vision 0.62
  … 24 more below (scrollable)
CANVAS  world view, 1512x760 — not interpreted, act physically  vision 0.94
DO      4 actionable, 1 ABSTAINED
      Browse                  tab (selected)          vision 0.74
      Sell                    tab                     vision 0.72
      Search                  text (empty)            vision 0.66
      Buyout                  button                  vision 0.44  ABSTAINED: two identical buttons at this size
  … 9 unlabeled (unknown 9) — not addressable by name, point by region
SAYS    1 value
      "Gold: 1,204g 88s 12c"                          vision 0.91

"""

private let fusedGolden = """
SCREEN  Hybrid · window "Board" · FRONT · 1 other window
LIST    2 items
  1   Inbox                   row                     ax
  2   Archive                 row                     vision 0.77
DO      4 actionable, 1 ABSTAINED
      File                    menu                    ax
      Edit                    menu                    ax
      New Card                button                  vision 0.81
      Delete                  button (disabled)       vision 0.58  ABSTAINED: greyed fill could be the theme
SAYS    1 value
      "3 cards"                                       ax

"""

// MARK: - The three fixtures, ONE call

@Suite("MacScreenRender — one structure, every screen")
struct MacScreenRenderTests {

    @Test("(a) an AX-rich list app renders the canonical structure")
    func axRichListApp() {
        let text = MacScreenRender.render(
            MacScreenRender.screen(from: listAppPercept(), isFront: true, otherWindows: 2),
            options: MacScreenRender.Options(maxRows: 5)
        )
        #expect(text == listAppGolden)
    }

    @Test("(b) an AX-blind canvas+grid app renders the SAME sections from vision rows")
    func axBlindCanvasApp() {
        let text = MacScreenRender.render(canvasAppScreen())
        #expect(text == canvasAppGolden)
    }

    @Test("(c) a fused screen carries both provenances in ONE DO section")
    func fusedProvenances() {
        let text = MacScreenRender.render(fusedScreen())
        #expect(text == fusedGolden)
        // Both evidence kinds, one section, one shape.
        let doBlock = section("DO", of: text)
        #expect(doBlock.contains("  ax"))
        #expect(doBlock.contains("vision 0.81"))
        // …and never a second section for the other source.
        #expect(text.components(separatedBy: "\nDO      ").count == 2)
    }

    // MARK: Source-agnosticism, stated as an invariant

    @Test("every fixture emits the fixed sections in the fixed order")
    func sectionOrderIsFixed() {
        let order = ["SCREEN", "WHERE", "MODAL", "LIST", "GRID", "TEXT", "CANVAS", "DO", "SAYS"]
        // LIVE renders, never the golden constants: a golden compared against
        // itself proves the string is a string. A reorder inside the renderer
        // has to fail HERE, not only in a byte-diff.
        let rendered = [
            MacScreenRender.render(
                MacScreenRender.screen(from: listAppPercept(), isFront: true, otherWindows: 2),
                options: MacScreenRender.Options(maxRows: 5)
            ),
            MacScreenRender.render(canvasAppScreen()),
            MacScreenRender.render(fusedScreen()),
        ]
        for text in rendered {
            let present = text.split(separator: "\n").compactMap { line -> String? in
                // Unlabeled controls now retain role addresses (`button 1`),
                // which deliberately start in column zero. Sections remain
                // uppercase; lowercase role addresses are child rows, not
                // unknown section keywords.
                guard let first = line.first, first.isUppercase else { return nil }
                return String(line.prefix(while: { $0 != " " }))
            }
            // Every emitted keyword is in the vocabulary…
            for keyword in present { #expect(order.contains(keyword), "unknown section \(keyword)") }
            // …and they appear in the canonical order, with absences simply absent.
            let indices = present.compactMap { order.firstIndex(of: $0) }
            #expect(indices == indices.sorted())
        }
    }

    @Test("a section an app lacks is ABSENT, never renamed or emptied")
    func absentSectionsAreAbsent() {
        let fusedGolden = MacScreenRender.render(fusedScreen())
        // No focus ⇒ no navigation position to state.
        #expect(!fusedGolden.contains("WHERE"))
        // No modal, no canvas on this screen.
        #expect(!fusedGolden.contains("MODAL"))
        #expect(!fusedGolden.contains("CANVAS"))
        // And nothing invented in their place: the keyword vocabulary is closed.
        #expect(!fusedGolden.contains("NAV"))
        #expect(!fusedGolden.contains("(none)"))
    }

    // MARK: Determinism

    @Test("same input twice ⇒ byte-identical output")
    func determinism() {
        let percept = listAppPercept()
        let options = MacScreenRender.Options(maxRows: 5)
        let first = MacScreenRender.render(
            MacScreenRender.screen(from: percept, isFront: true, otherWindows: 2), options: options
        )
        let second = MacScreenRender.render(
            MacScreenRender.screen(from: percept, isFront: true, otherWindows: 2), options: options
        )
        #expect(Array(first.utf8) == Array(second.utf8))

        // The unlabeled census is a DICTIONARY upstream — the classic
        // nondeterminism. Render a screen with several unlabeled kinds many
        // times and demand one answer.
        let screen = MacScreenRender.Screen(
            appName: "Any",
            controls: [],
            unlabeledControls: ["button": 3, "image": 2, "row": 7, "unknown": 1, "slider": 4]
        )
        let renders = Set((0..<25).map { _ in MacScreenRender.render(screen) })
        #expect(renders.count == 1)
        #expect(MacScreenRender.render(screen).contains(
            "17 unlabeled (button 3, image 2, row 7, slider 4, unknown 1)"
        ))

        // Vision confidence formatting must not follow a locale.
        #expect(MacScreenRender.Provenance.vision(0.8).text == "vision 0.80")
        // 0.835 is not representable in binary; %.2f rounds it down. Pinned as-is
        // so a future formatter swap that changes the bytes is caught.
        #expect(MacScreenRender.Provenance.vision(0.835).text == "vision 0.83")
    }

    // MARK: Ordinals are addresses

    @Test("ordinals are 1-based, contiguous, and stable across renders")
    func ordinalsAreAddresses() {
        let text = MacScreenRender.render(canvasAppScreen())
        let ordinals = text.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("   ") || line.hasPrefix("  ") else { return nil }
            let token = line.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })
            return token.isEmpty ? nil : Int(token)
        }
        #expect(ordinals == [1, 2, 3, 4])

        // An abstaining row keeps its ordinal — dropping it would silently
        // renumber every row beneath it, which is the addressing bug the whole
        // ordinal scheme exists to avoid.
        #expect(text.contains("  3   ⟨unlabeled⟩"))

        // Re-render: the same rows keep the same numbers.
        #expect(MacScreenRender.render(canvasAppScreen()) == text)
    }

    // MARK: Elision is spoken, in place

    @Test("a cap that bites says its count and its recourse")
    func elisionIsSpoken() {
        let percept = listAppPercept()
        let screen = MacScreenRender.screen(from: percept, isFront: true, otherWindows: 2)

        let capped = MacScreenRender.rendering(screen, options: MacScreenRender.Options(maxRows: 3))
        #expect(capped.text.contains("LIST    7 items, showing 3"))
        #expect(capped.text.contains("… 4 more below (scrollable)"))
        #expect(capped.rowsDropped == 4)

        // Uncapped: no elision line at all, and no "showing" qualifier either.
        let full = MacScreenRender.rendering(screen, options: MacScreenRender.Options(maxRows: 50))
        #expect(full.text.contains("LIST    7 items\n"))
        #expect(!full.text.contains("more below"))
        #expect(full.rowsDropped == 0)

        // Controls and values carry the same discipline, each naming its own knob.
        let controlCapped = MacScreenRender.rendering(
            screen, options: MacScreenRender.Options(maxRows: 50, maxControls: 2)
        )
        // The two unlabeled toolbar buttons are retained as `button 1` and
        // `button 2`, so they count toward the action surface and its cap.
        #expect(controlCapped.text.contains("DO      7 actionable, showing 2"))
        #expect(controlCapped.text.contains("… 5 observed controls not shown (screen part: controls, or name a control)"))
        #expect(controlCapped.controlsDropped == 5)

        // A non-scrollable content section says the honest recourse instead of
        // promising a scroll that does not exist.
        let fixed = MacScreenRender.Screen(
            appName: "Any",
            contents: [MacScreenRender.Content(
                kind: .list,
                rows: (1...4).map {
                    MacScreenRender.Row(label: visionText("row \($0)"), provenance: .ax)
                },
                totalRows: 4,
                scrollable: false
            )]
        )
        #expect(MacScreenRender.render(fixed, options: MacScreenRender.Options(maxRows: 2))
            .contains("… 2 more below (raise maxRows)"))
    }

    @Test("an upstream cap is spoken here too, not silently absorbed")
    func upstreamOmissionsAreSpoken() {
        // The compiler dropped rows before this renderer ever saw them. A
        // renderer that counted only its OWN drops would report a complete list.
        let screen = MacScreenRender.Screen(
            appName: "Any",
            contents: [MacScreenRender.Content(
                kind: .list,
                rows: [MacScreenRender.Row(label: visionText("only row"), provenance: .ax)],
                totalRows: 40,
                scrollable: true
            )]
        )
        let text = MacScreenRender.render(screen)
        #expect(text.contains("LIST    40 items, showing 1"))
        #expect(text.contains("… 39 more below (scrollable)"))
    }

    // MARK: Abstains are visible

    @Test("physical-only evidence is distinct from a refused target or an unparsed canvas")
    func physicalOnlyEvidenceIsNotARefusal() {
        let screen = MacScreenRender.Screen(
            appName: "Visual Fixture",
            contents: [
                MacScreenRender.Content(kind: .grid, rows: [
                    MacScreenRender.Row(label: visionText("yellow object"), provenance: .vision(0.8), physicalOnly: true),
                    MacScreenRender.Row(label: visionText("covered object"), provenance: .vision(0.8),
                        abstain: "covered by foreground window", physicalOnly: true),
                ]),
                MacScreenRender.Content(kind: .canvas, canvas: MacScreenRender.Canvas(
                    description: "visual surface", width: 900, height: 600,
                    provenance: .vision(1), hasPerceptualEvidence: true, hasRegionTarget: true
                )),
            ]
        )
        let rendering = MacScreenRender.rendering(screen)
        #expect(rendering.text.contains("PHYSICAL ONLY: role uncertain"))
        #expect(rendering.text.contains("ABSTAINED: covered by foreground window"))
        #expect(rendering.abstained == 1)
        #expect(rendering.text.contains("900x600 — partial vision; use listed targets, roles may be uncertain"))
        #expect(!rendering.text.contains("not interpreted"))
        #expect(rendering.text.contains("Target: canvas"))
        #expect(rendering.text.contains("'left side of canvas' / 'right side of canvas'"))
        #expect(!MacScreenRender.render(canvasAppScreen()).contains("Target: canvas"),
            "a canvas extent alone must not invent a physical target")
        #expect(MacScreenRender.render(canvasAppScreen()).contains("not interpreted, act physically"))
    }

    @Test("an abstaining row is reported with its reason, never dropped or guessed")
    func abstainsAreVisible() {
        let rendering = MacScreenRender.rendering(canvasAppScreen())
        #expect(rendering.abstained == 2)
        #expect(rendering.text.contains("ABSTAINED: overlapping targets"))
        #expect(rendering.text.contains("ABSTAINED: two identical buttons at this size"))
        // Counted in the section header, so a reader sees the refusal rate
        // without scanning the rows.
        #expect(rendering.text.contains("DO      4 actionable, 1 ABSTAINED"))
        // The abstaining control is still listed, with its low confidence.
        #expect(rendering.text.contains("Buyout"))
        #expect(rendering.text.contains("vision 0.44"))
    }

    // MARK: Redaction

    @Test("a secret never appears — the shared redactor decides, not this file")
    func redactionHolds() {
        // The FULL-context path: a value the compiler redacted under its own
        // caption. The renderer prints the compiler's verdict verbatim.
        let percept = MacPerceptionCompiler.compile(
            snapshot: snapshot([
                node([], "AXWindow", title: "Checkout"),
                node([0], "AXTextField", title: "CVV", value: "4485", actions: ["AXPress"]),
                node([1], "AXStaticText", value: "sk-live-9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c"),
                node([2], "AXButton", title: "Pay", actions: ["AXPress"]),
            ]),
            app: MacAXAppInfo(name: "Any", bundleIdentifier: nil, processIdentifier: 7),
            windowTitle: "Checkout"
        )
        let text = MacScreenRender.render(
            MacScreenRender.screen(from: percept, isFront: true)
        )
        #expect(!text.contains("4485"))
        #expect(!text.contains("sk-live-9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c"))
        #expect(!text.contains("9f8a7b6c"))
        // Withheld, not vanished: the reader can tell redaction from blindness.
        #expect(text.contains(MacScreenRender.redactedMarker))
        // The non-secret parts still render.
        #expect(text.contains("CVV"))
        #expect(text.contains("Pay"))

        // The FALLBACK path: a hand-built value with no compiler verdict still
        // meets the shared standalone shape test rather than printing raw.
        let handBuilt = MacScreenRender.Screen(
            appName: "Any",
            values: [
                MacScreenRender.Value(
                    text: MacScreenText("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
                    provenance: .vision(0.9)
                ),
                MacScreenRender.Value(text: MacScreenText("4 unread"), provenance: .ax),
            ]
        )
        let handText = MacScreenRender.render(handBuilt)
        #expect(!handText.contains("ghp_"))
        #expect(handText.contains(MacScreenRender.redactedMarker))
        #expect(handText.contains("4 unread"))
    }

    // MARK: No handle tokens

    @Test("no handle token reaches the rendered screen")
    func noHandleTokens() {
        let percept = listAppPercept()
        let text = MacScreenRender.render(
            MacScreenRender.screen(from: percept, isFront: true, otherWindows: 2),
            options: MacScreenRender.Options(maxRows: 50)
        )
        let handles = Set(percept.affordances.map(\.handle) + percept.readouts.compactMap(\.handle))
        #expect(!handles.isEmpty)
        for handle in handles {
            #expect(!text.contains(handle), "handle \(handle) leaked into the render")
        }
    }

    // MARK: Budget

    @Test("a typical screen renders small, and the accounting matches the text")
    func budgetIsBounded() {
        let rendering = MacScreenRender.rendering(
            MacScreenRender.screen(from: listAppPercept(), isFront: true, otherWindows: 2),
            options: MacScreenRender.Options(maxRows: 5)
        )
        #expect(rendering.bytes == rendering.text.utf8.count)
        #expect(rendering.bytes < 2048)
        // The struct's counts and the spoken text agree — one of them alone
        // would be a claim.
        #expect(rendering.rowsDropped == 2)
        #expect(rendering.text.contains("… 2 more below"))
    }

    // MARK: The kind vocabulary

    @Test("kinds come from one map for both lanes; an unknown role degrades honestly")
    func kindVocabularyIsShared() {
        #expect(MacScreenRender.kindName(role: "AXButton") == "button")
        #expect(MacScreenRender.kindName(role: "AXSecureTextField") == "secure text")
        // The vision lane emits AXUnknown by contract rather than a confident guess.
        #expect(MacScreenRender.kindName(role: "AXUnknown") == "unknown")
        // An unmapped role keeps its own name instead of being guessed into one.
        #expect(MacScreenRender.kindName(role: "AXRuler") == "ruler")
    }
}

// MARK: - helpers

private func section(_ keyword: String, of text: String) -> String {
    var lines: [String] = []
    var inside = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix(keyword + " ") { inside = true; lines.append(String(line)); continue }
        if inside {
            if let first = line.first, first != " " { break }
            lines.append(String(line))
        }
    }
    return lines.joined(separator: "\n")
}
