#!/usr/bin/env swift
// release_notes_html.swift — markdown release notes -> styled HTML fragment
// for the Sparkle update dialog (update-dialog-polish, 2026-08-20).
//
// Reads markdown on stdin, writes a self-contained <div> fragment on stdout:
// headings, bullet lists (with two-space continuation lines), paragraphs,
// **bold**, and `code`, plus a <style> block that follows the system
// appearance (light/dark) inside Sparkle's WKWebView. HTML is escaped FIRST,
// so notes content can never smuggle markup; every tag in the output is
// emitted by this script.
//
// Called by script/generate_appcast.sh for markdown notes. It exits non-zero
// on empty input; the caller treats any failure as fatal (no silent <pre>
// fallback — a converter bug should stop the release, not quietly ship).

import Foundation

func escape(_ s: String) -> String {
    // The \u{01}/\u{02} bytes are reserved as code-span placeholders in
    // inline(); dropping them here is what makes that reservation safe.
    s.replacingOccurrences(of: "\u{01}", with: "")
        .replacingOccurrences(of: "\u{02}", with: "")
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

// Inline transforms run on ESCAPED text: **bold** and `code`. Pairs only —
// an unmatched marker stays literal. Code spans are lifted out FIRST via
// placeholders so the bold pass can never match into a code span (or vice
// versa) and emit crossed tags like <strong>a <code>b</strong> c</code>
// (gpt-5.5 review MEDIUM). The placeholder bytes are control characters that
// escape() strips from input, so input text can never collide with them.
func inline(_ s: String) -> String {
    var out = s
    var codeSpans: [String] = []
    let codeRE = try! NSRegularExpression(pattern: "`([^`]+)`")
    while let m = codeRE.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
          let whole = Range(m.range, in: out), let body = Range(m.range(at: 1), in: out) {
        codeSpans.append(String(out[body]))
        out.replaceSubrange(whole, with: "\u{01}\(codeSpans.count - 1)\u{02}")
    }
    let boldRE = try! NSRegularExpression(pattern: "\\*\\*([^*]+)\\*\\*")
    out = boldRE.stringByReplacingMatches(
        in: out, range: NSRange(out.startIndex..., in: out),
        withTemplate: "<strong>$1</strong>")
    for (i, body) in codeSpans.enumerated() {
        out = out.replacingOccurrences(of: "\u{01}\(i)\u{02}", with: "<code>\(body)</code>")
    }
    return out
}

let style = """
<style>
  :root { color-scheme: light dark; }
  .release-notes {
    font-family: -apple-system, "SF Pro Text", Helvetica, sans-serif;
    font-size: 13px; line-height: 1.5; margin: 12px 14px;
    color: #1d1d1f; background: transparent;
  }
  .release-notes h1 { font-size: 17px; margin: 0 0 10px; }
  .release-notes h2 { font-size: 14px; margin: 16px 0 6px; }
  .release-notes h3 { font-size: 13px; margin: 12px 0 4px; }
  .release-notes ul { margin: 6px 0; padding-left: 22px; }
  .release-notes li { margin: 4px 0; }
  .release-notes code {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 12px; padding: 0 3px; border-radius: 3px;
    background: rgba(0, 0, 0, 0.06);
  }
  @media (prefers-color-scheme: dark) {
    .release-notes { color: #e8e8ed; }
    .release-notes code { background: rgba(255, 255, 255, 0.12); }
  }
</style>
"""

let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    FileHandle.standardError.write(Data("release_notes_html: empty input\n".utf8))
    exit(1)
}

var html: [String] = ["<div class=\"release-notes\">", style]
var listOpen = false
var itemLines: [String] = []
var paragraphLines: [String] = []

func flushItem() {
    guard !itemLines.isEmpty else { return }
    html.append("<li>\(inline(itemLines.joined(separator: " ")))</li>")
    itemLines = []
}
func flushList() {
    flushItem()
    if listOpen { html.append("</ul>"); listOpen = false }
}
func flushParagraph() {
    guard !paragraphLines.isEmpty else { return }
    html.append("<p>\(inline(paragraphLines.joined(separator: " ")))</p>")
    paragraphLines = []
}

for rawLine in input.components(separatedBy: "\n") {
    let line = escape(rawLine)
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
        flushList(); flushParagraph()
    } else if line.hasPrefix("### ") {
        flushList(); flushParagraph()
        html.append("<h3>\(inline(String(line.dropFirst(4))))</h3>")
    } else if line.hasPrefix("## ") {
        flushList(); flushParagraph()
        html.append("<h2>\(inline(String(line.dropFirst(3))))</h2>")
    } else if line.hasPrefix("# ") {
        flushList(); flushParagraph()
        html.append("<h1>\(inline(String(line.dropFirst(2))))</h1>")
    } else if line.hasPrefix("- ") {
        flushParagraph()
        if !listOpen { html.append("<ul>"); listOpen = true }
        flushItem()
        itemLines.append(String(line.dropFirst(2)))
    } else if listOpen && line.hasPrefix("  ") {
        // Continuation of the current bullet (our notes wrap list items with
        // a two-space indent).
        itemLines.append(trimmed)
    } else {
        flushList()
        paragraphLines.append(trimmed)
    }
}
flushList()
flushParagraph()
html.append("</div>")
print(html.joined(separator: "\n"))
