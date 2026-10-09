# Bundled authoring kit

`project.yml` copies this folder intact to `Contents/Resources/Senses/`.
`builtin.json` is a package manifest, not a serialized SenseRecord: parse
`corner` with SenseCorner(key:), then construct a JavaScript, on_call,
built_in record at version 1, on, with empty reach and the listed verbs.
Registry/assembly owners import each entry's bytes into its version folder
and register through SensesHub. Do not overwrite an existing grown sense.
Each entry is already self-contained; no dependency loader is needed.
The SDK's local `sense.redactText(text)` uses the shared Swift policy before
source fragments are composed into news. It sends no plug messages and grants
no progress credit. P1's sense.js is separately owned and may occupy this folder.
P6 reads AUTHORING.md, frame.js, and the relevant builtin entry lazily.

The host must supply file data bytes (as the documented Uint8Array), derive
the published page's corner from its SenseRecord, and accept the documented
synchronous source.read/publish calls. `file:<encoded path>#document/...`
addresses are sense-owned; frame.js sends the decoded source path back to
source.read. The door must preserve the full thing/more address on reads.
Directory-style iWork and RTFD packages need ZIP material from the source
owner; filesystem access is deliberately absent in the kit.

## Supported boundaries

- OOXML: DOCX paragraphs, controls, tables, headers, footers and notes;
  XLSX worksheet cells, shared/inline strings, formulas and named table
  ranges; PPTX slides in presentation order, shape text, tables and notes.
  Styles, rendered pictures/charts and recalculation are not provided.
  XLSX numbers are explicitly stored numbers, including date serials.
- iWork 2013+: ZIP or nested Index.zip, Apple-framed raw Snappy, bounded
  protobuf, TSWP text, Numbers sheets/tables/v5 BNC cell tiles, Pages body
  and drawable text/tables, Keynote slide tree and drawable text/tables.
  Plain strings, rich text references, decimal128, double, boolean, date
  and duration cells are decoded. Formula evaluation, visual layout,
  legacy pre-BNC cells and incremental/diff archives are unsupported.
  Cell errors are explicitly marked; their detailed error codes are not
  decoded. Table styling, merged-cell display and chart rendering are not
  interpreted. Pages drawable order is archive order, not rendered pages.
- EPUB: OPF spine order and XHTML blocks. External resources, DRM and
  non-XHTML spine items are unsupported. No network or script execution.
- DOCX, PPTX, EPUB and RTF tables publish table, row and cell things;
  table text joins cells with ` | ` and rows with newlines. Pages, Numbers
  and XLSX retain their existing table/sheet and coordinate-addressed cells.
  DOCX prints the table once; row/cell text is available on direct addressed
  reads. PPTX shape labels use declared placeholder roles or ordered Text
  names, with separate paragraph things. Keynote labels use slide/placeholder
  roles or ordered Text names; Pages and Numbers text labels also avoid archive
  IDs. Numbers table dimensions describe the populated data extent, and empty
  cells are omitted from both text and things.
- RTF: version 1, Unicode escapes and Windows-1252, paragraphs and table
  rows/cells. Nested tables and other legacy code pages fail explicitly.
  RTFD reads TXT.rtf from ZIP material and names attachments without rendering
  their bytes.
- Figma canvas: named AX nodes/targets only; no pixel interpretation or
  mutation verbs. Identifiers win over AX paths. Paths are explicitly
  described as dependent on tree layout. Thin/empty AX is a visible failure.
- ZIP64, encryption, unknown compression, oversized entries, invalid
  checksums and ambiguous identities fail explicitly. ZIP member limit:
  8,000; entry expansion: 32 MiB; total expansion/file input: 128 MiB.

## Bounded check after integration and install

1. Confirm the installed bundle contains Senses/builtin.json, frame.js,
   AUTHORING.md and each of the ten manifest entry paths. Confirm the
   registry has those corners and provenance identifies their IDs at v1.
2. Through the existing files.read/mac.read door, read one existing small
   document of each supported kind, using its real path. Confirm a known
   paragraph, worksheet A1, named Numbers table/cell, slide and EPUB
   chapter match the source. Use a real Numbers document with at least
   one plain string, number and date, and check the shown coordinates.
3. Read a returned thing address and a returned more address (use an
   existing long document for more). Confirm focused content and next
   text appear, text stays at or below 40,000 UTF-8 bytes and thing
   addresses are identical across repeated reads of unchanged material.
4. With Figma already open, read its canvas once through mac.look; match
   one named AX layer against its existing layer list. Check that no
   mutation verbs are advertised. Do not open apps to perform this check.
5. On an existing unsupported/corrupt sample, confirm the sense reports
   failure and the raw route stays available. Do not generate workloads,
   run suites, or claim Swift compilation proves the JS document views.

P7 does not launch, quit or install the app. Installed behavior and manifest
registration are checked by the integration owner after the packages merge.
