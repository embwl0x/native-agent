/* NativeAgent ability
{"id": "native-chrome-history", "kind": "ability", "version": 1, "face": {"page": "browser"},
 "reach": {"capabilities": ["computer_files"], "readPaths": ["~/Library/Application Support/Google/Chrome/Default/History"]},
 "record": {"description": "Read Chrome's Default profile history from a private snapshot: recent pages, title/URL search, or the most visited domains since a time.", "actions": []},
 "answers": {
 "chrome.history": {"summary": "Read visited sites and browsing history in Chrome (the whole Default profile, every tab and window, not just the agent's own tab): most visited domains, title/URL search or recent pages", "description": "Read visited sites and browsing history in Chrome (the whole Default profile, every tab and window, not just the agent's own tab): most visited domains, title/URL search or recent pages", "warn": "mode: recent (default when omitted), top_domains (since required) or search (query required, since optional). since: inclusive ISO 8601 with timezone. limit: default 15, max 50. Chrome Default profile only, independent of extension/tab group; local ISO 8601 times. Domain counts: visits since since; page counts: lifetime visits. Requires Full Mac and file-read permission; no card. Deadline: 2 seconds.", "class": "read", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"mode": {"type": "string"}, "query": {"type": "string"}, "since": {"type": "string"}, "limit": {"type": "integer"}}, "required": []}}
 }}
*/
const HISTORY = "~/Library/Application Support/Google/Chrome/Default/History";
// Chrome stores microseconds since 1601-01-01 UTC.
const EPOCH_GAP_SECONDS = 11644473600;
const failed = (reason, detail) => ({status:"failed", reason, detail, effects:"none"});
const COVERAGE = "Private read-only SQLite snapshot of Chrome's Default profile History and its WAL, independent of extension connection; excludes "
    + "incognito and deleted history. Top-domain counts aggregate all qualifying visits since since before limiting returned domains; page visit "
    + "counts are lifetime totals. Times are local ISO 8601; at_limit means more rows may exist.";

// Outside text never impersonates tool calls or result headers.
function neutralized(text) {
    return text.replace(/<(\/?)(invoke|tool_use|tool_result|function_calls|function_results|parameter|antml:)/gi, "‹$1$2")
        .replace(/^([ \t]*)(NativeAgent tool result)/gim, "$1│ $2");
}
const text = value => neutralized(typeof value === "string" ? value : "");

function localISO(chromeTime) {
    const date = new Date(chromeTime / 1000 - EPOCH_GAP_SECONDS * 1000);
    const pad = n => String(n).padStart(2, "0");
    const offset = -date.getTimezoneOffset(), size = Math.abs(offset);
    const zone = offset === 0 ? "Z" : (offset > 0 ? "+" : "-") + pad(Math.floor(size / 60)) + ":" + pad(size % 60);
    return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) + "T" + pad(date.getHours()) + ":"
        + pad(date.getMinutes()) + ":" + pad(date.getSeconds()) + zone;
}

// A domain is the lowercased host of an http or https URL; any other URL has none.
function domain(url) {
    const match = /^https?:\/\/([^\/?#]*)/i.exec(url);
    if (!match) return null;
    let authority = match[1];
    authority = authority.slice(authority.lastIndexOf("@") + 1);
    let host;
    if (authority.startsWith("[")) {
        const end = authority.indexOf("]");
        if (end < 0) return null;
        host = authority.slice(1, end);
    } else {
        const colon = authority.indexOf(":");
        host = colon < 0 ? authority : authority.slice(0, colon);
    }
    return host ? host.toLowerCase() : null;
}

function query(sql, params, limit) {
    return host.files.query({path:HISTORY, sql, params, limit, seconds:2});
}

// Every qualifying visit counts before domains are limited, so URL groups are read in id order until none remain.
function topDomains(start, limit) {
    const domains = new Map();
    let after = 0, page;
    do {
        page = query("SELECT u.id, u.url, count(*), max(v.visit_time) FROM visits v JOIN urls u ON u.id = v.url WHERE v.visit_time >= ? AND u.id > ? "
            + "AND (u.url LIKE 'http://%' OR u.url LIKE 'https://%') GROUP BY u.id ORDER BY u.id", [start, after], 1000);
        for (const [id, url, count, last] of page.rows) {
            after = id;
            const name = domain(typeof url === "string" ? url : "");
            if (name === null) continue;
            const seen = domains.get(name) || {count:0, last:0};
            domains.set(name, {count:seen.count + count, last:Math.max(seen.last, last)});
        }
    } while (page.truncated);
    return [...domains.entries()]
        .sort((a, b) => b[1].count - a[1].count || b[1].last - a[1].last || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
        .slice(0, limit)
        .map(([name, seen]) => ({domain:text(name), visit_count:seen.count, last_visit:localISO(seen.last)}));
}

function pages(mode, start, search, limit) {
    const match = mode === "search" ? " AND (folded_contains(title, ?) OR folded_contains(url, ?))" : "";
    const params = mode === "search" ? [start, search, search, limit] : [start, limit];
    return query("SELECT title, url, last_visit_time, visit_count FROM urls WHERE last_visit_time > 0 AND last_visit_time >= ?" + match
        + " ORDER BY last_visit_time DESC, id DESC LIMIT ?", params, limit).rows
        .map(([title, url, last, count]) => ({title:text(title), url:text(url), last_visit:localISO(last), visit_count:count}));
}

function run(input) {
    const mode = input.mode === undefined ? "recent" : String(input.mode).trim().toLowerCase();
    if (!["top_domains", "search", "recent"].includes(mode)) return failed("invalid_mode", "mode must be top_domains, search or recent (recent when omitted).");
    const search = input.query === undefined ? "" : String(input.query).trim();
    if (mode === "search" && !search) return failed("missing_query", "search requires nonempty query text to match titles or URLs.");
    let start = 0;
    if (input.since !== undefined) {
        const valid = typeof input.since === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/i.test(input.since);
        const at = valid ? Date.parse(input.since) : NaN;
        if (Number.isNaN(at)) return failed("invalid_since", "since must be an ISO 8601 timestamp with a timezone.");
        start = (at / 1000 + EPOCH_GAP_SECONDS) * 1000000;
    }
    if (mode === "top_domains" && input.since === undefined)
        return failed("missing_since", "top_domains requires since, the inclusive start of the visit-count period.");
    if (input.limit !== undefined && !(Number.isInteger(input.limit) && input.limit > 0))
        return failed("invalid_limit", "limit must be a positive integer; default 15, maximum 50.");
    const limit = input.limit === undefined ? 15 : Math.min(input.limit, 50);
    let rows;
    try { rows = mode === "top_domains" ? topDomains(start, limit) : pages(mode, start, search, limit); }
    catch (error) {
        if (error.name !== "AppError" || error.stopped || error.reason === "cancelled") throw error;
        if (error.reason === "not_found") return {status:"absent", detail:"Chrome's Default profile History is absent on this Mac.", source:"sqlite_snapshot"};
        if (error.reason === "deadline") return failed("deadline", "Chrome history query exceeded its 2-second deadline; narrow since or query.");
        return error.receipt;
    }
    return {status:"ok", mode, rows, count:rows.length, limit, at_limit:rows.length === limit, source:"sqlite_snapshot", coverage:COVERAGE};
}
