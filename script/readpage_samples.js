#!/usr/bin/env node
// Deliberate saved-HTML before/after demonstration requested by dfix-readpage.
// No app/test target, network, assertions or duplicate extractor implementation.
// Runs the actual old/new extraction functions with the Swift interpreter.
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");
const root = path.resolve(__dirname, "..");
const owner = "Modules/NativeAgentCore/Sources/Research/Research+SearchFetch.swift";
const before = execFileSync("git", ["show", "c9cffaabe:" + owner], { cwd: root, encoding: "utf8" });
const extractor = before.slice(before.indexOf("    private static func extractHTML("), before.indexOf("    /// Decode the HTML char-refs"))
    .replace("private static func extractHTML", "static func extractHTML");
const entities = before.slice(before.indexOf("    static func decodeHTMLEntities("), before.indexOf("    /// One result row."));
const after = fs.readFileSync(path.join(root, "Modules/NativeAgentCore/Sources/Research/ResearchHTMLExtraction.swift"), "utf8");
const swift = `import Foundation
enum Before {
${extractor}
${entities}
}
${after}
let samples = [
    ("readpage-hn-front.html", "https://news.ycombinator.com/"),
    ("readpage-hn-comments.html", "https://news.ycombinator.com/item?id=1"),
    ("readpage-article.html", "https://example.org/articles/reading"),
    ("readpage-forecast.html", "https://forecast.weather.gov/MapClick.php?lat=40.7&lon=-74"),
    ("readpage-saved-hn-front.html", "https://news.ycombinator.com/"),
    ("readpage-saved-hn-comments.html", "https://news.ycombinator.com/item?id=50271640")
]
for (file, address) in samples {
    let html = try String(contentsOfFile: CommandLine.arguments[1] + "/" + file, encoding: .utf8)
    let old = try Before.extractHTML(html)
    let new = try ResearchHTMLExtraction.extract(html, base: URL(string: address)!, decode: Before.decodeHTMLEntities)
    print("=== " + file + " ===")
    let limit = file.hasPrefix("readpage-saved-") ? 12 : Int.max
    let oldLines = old.text.split(separator: "\\n"), newLines = new.text.split(separator: "\\n")
    print("BEFORE (" + String(oldLines.count) + " lines, showing " + String(min(limit, oldLines.count)) + "):\\n" + oldLines.prefix(limit).joined(separator: "\\n"))
    print("AFTER (" + String(newLines.count) + " lines, showing " + String(min(limit, newLines.count)) + "):\\n" + newLines.prefix(limit).joined(separator: "\\n"))
}
`;
const result = spawnSync("swift", ["-", path.join(root, "script/manual-fixtures")], {
    cwd: root, input: swift, encoding: "utf8", timeout: 60000, maxBuffer: 1024 * 1024
});
process.stdout.write(result.stdout || "");
process.stderr.write(result.stderr || "");
if (result.error) throw result.error;
process.exit(result.status ?? 1);
