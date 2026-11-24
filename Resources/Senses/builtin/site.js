var SiteKit = (() => {
    const {maximumItems, maximumTextBytes, fail, utf8Length, prefix} = NativeKit;
    function siteThing(name, kind, address, text = "", verbs = []) {
        return {name: String(name), kind, address, text: String(text), verbs};
    }
    function publishRows(corner, base, title, items, request = {}, stableCursors = false, separator = "/") {
        if (items.length > maximumItems) fail("Document exceeds the 100,000 thing limit");
        const identities = new Set();
        for (const item of items) {
            if (!item.address.startsWith(base + separator) || identities.has(item.address)) fail("Duplicate or foreign thing address: " + item.address);
            identities.add(item.address);
        }
        const requested = request.address;
        const asked = !requested || requested.startsWith("/") || requested.startsWith("~") ? base : requested;
        const match = /[?&]part=(\d+),(\d+)$/.exec(asked);
        const cursor = stableCursors ? /\?at=([^&]+)&offset=(\d+)$/.exec(asked) : null;
        const selected = cursor ? asked.slice(0, cursor.index) : match ? asked.slice(0, match.index) : asked;
        if (selected !== base && !selected.startsWith(base + separator)) fail("Address belongs to another document");
        const rows = selected === base ? items : items.filter(t => t.address === selected || t.address.startsWith(selected + "/"));
        if (selected !== base && !rows.length) fail("Address is no longer present: " + selected);
        let i = match ? Number(match[1]) : 0, offset = match ? Number(match[2]) : 0;
        if (cursor) {
            const anchor = decodeURIComponent(cursor[1]);
            i = rows.findIndex(row => row.address === anchor);
            if (i < 0) fail("Address is no longer present: " + anchor);
            offset = Number(cursor[2]);
        }
        if (i > rows.length || (i === rows.length && offset) || (rows[i] && offset > rows[i].text.length)) fail("Invalid page cursor");
        let text = "", budget = maximumTextBytes; const things = [], folded = [];
        while (i < rows.length && things.length < 160) {
            const row = rows[i], heading = prefix(row.name, 400) + "\n";
            if (budget < utf8Length(heading) + 8) break;
            const body = prefix(row.text.slice(offset), budget - utf8Length(heading) - 2);
            text += heading + body + "\n\n"; budget -= utf8Length(heading + body + "\n\n");
            things.push({ name: prefix(row.name, 400), kind: row.kind, address: row.address,
                detail: prefix(row.text.replace(/\s+/g, " "), 240), verbs: row.verbs });
            offset += body.length;
            if (offset < row.text.length) break;
            i++; offset = 0;
        }
        if (i < rows.length) {
            for (let j = i; j < Math.min(rows.length, i + 12); j++) folded.push(prefix(rows[j].name, 160)
                + (stableCursors ? " [" + rows[j].address + "]" : ""));
            if (rows.length - i > 12) folded.push(String(rows.length - i - 12) + " further things");
        }
        const page = { address: asked, title: prefix(title, 600), text, things, folded };
        if (i < rows.length) page.more = stableCursors
            ? selected + "?at=" + encodeURIComponent(rows[i].address) + "&offset=" + offset
            : selected + "?part=" + i + "," + offset;
        // sense.publish supplies the record's corner; the JS page contract does
        // not encode Swift's associated-value SenseCorner enum.
        sense.publish(page);
    }

    let baseline, baselineView, baselinePage;
    function fetched(page) { return !!page.coverage && typeof page.text === "string"; }
    function visible(page) { return ["browser.text", "browser.links"].includes(page.source_action) && typeof page.text === "string"; }
    function document(page) { return fetched(page) || visible(page); }
    function snapshot(material) {
        if (!material || material.kind !== "page" || !material.snapshot) NativeKit.fail("Site sense needs a captured page document");
        const page = material.snapshot;
        if (fetched(page)) {
            if (typeof page.url !== "string" || !page.url) NativeKit.fail("Fetched page has no requested URL");
            return page;
        }
        if (visible(page)) {
            if (typeof page.url !== "string" || !page.url || !page.source_receipt) NativeKit.fail("Visible browser document is incomplete");
            return page;
        }
        if (typeof page.snapshotId !== "string" || !page.snapshotId
            || typeof page.url !== "string" || !page.url || !Array.isArray(page.nodes)
            || !page.summary || typeof page.summary.text !== "string") NativeKit.fail("Chrome page snapshot is incomplete");
        return page;
    }
    function base(page, news = false) {
        const url = fetched(page) && typeof page.coverage.final_url === "string" ? page.coverage.final_url : page.url;
        const match = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]+)/i.exec(url);
        if (!match) NativeKit.fail("Chrome page URL has no host");
        // The runtime validates the actual URL host; this is only an address.
        const host = match[1].slice(match[1].lastIndexOf("@") + 1).replace(/:\d+$/, "");
        const safeURL = news ? sense.redactText(url) : url;
        const path = safeURL.replace(/^[a-z][a-z0-9+.-]*:\/\/[^/?#]+/i, "").split("#")[0];
        return "site:" + (news ? sense.redactText(host.toLowerCase()) : host.toLowerCase()) + (path || "/");
    }
    function address(page, node) {
        if (typeof node.addressFragment !== "string" || !node.addressFragment) NativeKit.fail("Chrome node has no readable place; reload the updated Chrome extension and read the site again");
        return base(page) + "#" + node.addressFragment;
    }
    function verbs(node) {
        if (!Array.isArray(node.actions)) return [];
        const states = node.states || {};
        if (states.disabled === true || states.blockedByModal === true) return [];
        const out = [];
        if (node.actions.includes("click")) {
            out.push("click");
            if (node.role === "link" && typeof node.url === "string" && node.url) out.push("open link");
        }
        if (node.actions.includes("fill")) out.push("fill");
        if (node.actions.includes("select")) out.push("select");
        return out;
    }
    function signature(page) {
        return JSON.stringify({url: page.url, title: page.title, text: page.summary.text,
            truncated: page.summary.truncated, truncationReasons: page.summary.truncationReasons,
            nodes: page.nodes.map(node => ({elementIdentity: node.elementIdentity,
                role: node.role, name: node.name, text: node.text, value: node.value,
                url: node.url, actions: node.actions, states: node.states, select: node.select}))});
    }
    function view(page) {
        const reading = page.reading || {};
        return JSON.stringify({scope: reading.scope, maxNodes: reading.maxNodes,
            maxTextChars: reading.maxTextChars, cursor: reading.cursor,
            transportByteLimit: reading.transportByteLimit, truncationReasons: page.summary.truncationReasons,
            frames: (page.frames || []).map(frame => ({frameId: frame.frameId, url: frame.url, accessible: frame.accessible}))});
    }
    function remember(page) { baseline = signature(page); baselineView = view(page); baselinePage = page; }
    function notifyChange(page) {
        const current = signature(page), currentView = view(page);
        const previous = baselinePage;
        const moved = previous && previous.url !== page.url;
        const changed = baseline !== undefined && (moved || baselineView === currentView && current !== baseline);
        remember(page);
        if (!changed) return;
        function redact(value) {
            if (typeof value === "string") return sense.redactText(value);
            if (Array.isArray(value)) return value.map(redact);
            if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, item]) => [sense.redactText(key), redact(item)]));
            return value;
        }
        function rows(value) {
            return value.nodes.map(node => {
                    const detail = {text: node.text, value: node.value, url: node.url,
                        states: node.states, select: node.select, actions: node.actions};
                    return {address: node.elementPath, kind: node.role || "element", name: node.name || "",
                        deltaKey: JSON.stringify(detail), text: JSON.stringify(redact(detail))};
                });
        }
        const endpoint = url => {
            const safe = sense.redactText(url);
            return NativeKit.prefix(safe, 300) + (NativeKit.utf8Length(safe) > 300 ? "…" : "");
        };
        const sections = ((page.reading || {}).sections || []).slice(0, 3).map(section => NativeKit.prefix(sense.redactText(section), 32));
        function pageDelta() {
            const elementDelta = NativeKit.deltaRows(rows(previous), rows(page)) || "0 added, 0 removed, 0 changed";
            const oldLines = previous.summary.text.replace(/\r\n/g, "\n").split("\n");
            const newLines = page.summary.text.replace(/\r\n/g, "\n").split("\n");
            function extras(left, right) {
                const counts = new Map();
                for (const line of right) counts.set(line, (counts.get(line) || 0) + 1);
                let n = 0;
                for (const line of left) {
                    const remaining = counts.get(line) || 0;
                    if (remaining) counts.set(line, remaining - 1); else n++;
                }
                return n;
            }
            const split = elementDelta.indexOf(";");
            const counts = split < 0 ? elementDelta : elementDelta.slice(0, split);
            const detail = split < 0 ? "" : elementDelta.slice(split);
            return "Page: " + counts + " elements; text +" + extras(newLines, oldLines) + "/−" + extras(oldLines, newLines) + " lines"
                + (previous.title !== page.title ? "; title: " + sense.redactText(previous.title || "") + " → " + sense.redactText(page.title || "") : "") + detail;
        }
        const delta = moved ? "Navigation: now " + NativeKit.prefix(sense.redactText(page.title || ""), 60)
            + (sections.length ? "; top sections: " + sections.join(", ") : "")
            + "; " + endpoint(previous.url) + " → " + endpoint(page.url)
            : pageDelta();
        if (delta) sense.notify({address: base(page, true), summary: NativeKit.prefix(sense.redactText(delta), 900)});
    }
    function publish(material, request = {}) {
        const page = snapshot(material), root = base(page), rows = [];
        if (document(page)) {
            rows.push(siteThing("Page text", "text", root + "#@text", page.text));
            if (fetched(page)) rows.push(siteThing("Fetch coverage", "text", root + "#@coverage", JSON.stringify(page.coverage)));
            else rows.push(siteThing("Browser read receipt", "text", root + "#@receipt", JSON.stringify(page.source_receipt)));
            const asked = typeof request.address === "string" && request.address.startsWith("site:") ? request : {};
            publishRows("site", root, page.url, rows, asked, true, "#");
            return page;
        }
        // Source text is first so the independent view stays whole and ordered.
        rows.push(siteThing("Page text", "text", root + "#@text", page.summary.text));
        for (const node of page.nodes) {
            const name = typeof node.name === "string" && node.name ? node.name
                : typeof node.text === "string" && node.text ? node.text
                : typeof node.url === "string" && node.url ? node.url
                : typeof node.role === "string" ? node.role : "";
            if (!name) continue;
            const label = NativeKit.prefix(name, 400);
            // Keep source states and option labels visible; values stay redacted
            // exactly as the Chrome snapshot supplied them.
            const detail = [node.text, node.value,
                node.select ? JSON.stringify(node.select) : "",
                node.more ? "More: " + JSON.stringify({tab_id: page.tabId, scope: page.reading?.scope,
                    more: JSON.stringify(node.more)}) : ""].filter(v => typeof v === "string" && v).join("\n");
            rows.push(siteThing(label, typeof node.role === "string" && node.role ? node.role : "element",
                address(page, node), detail, verbs(node)));
        }
        const asked = typeof request.address === "string" && request.address.startsWith("site:") ? request : {};
        publishRows("site", root, page.title || page.url, rows, asked, true, "#");
        return page;
    }
    function act(request) {
        const page = snapshot(sense.source.read());
        if (fetched(page)) NativeKit.fail("A fetched document has no Chrome controls");
        if (visible(page)) NativeKit.fail("A visible browser document has no grounded control verbs");
        const node = page.nodes.find(node => address(page, node) === request.address);
        if (!node || !verbs(node).includes(request.verb)) NativeKit.fail("Read the site again before acting on this thing");
        const args = request.args || {};
        if (request.verb === "click" || request.verb === "open link") return sense.act("chrome.click", request.address, {});
        if (request.verb === "fill") {
            if (typeof args.value !== "string") NativeKit.fail("fill needs a string value");
            return sense.act("chrome.fill", request.address, {value: args.value});
        }
        if (request.verb === "select") {
            if (!Array.isArray(args.values) || args.values.some(value => typeof value !== "string")) NativeKit.fail("select needs string values");
            return sense.act("chrome.select", request.address, {values: args.values});
        }
        NativeKit.fail("The source does not offer that verb");
    }
    return {snapshot, fetched, visible, document, base, address, verbs, publish, act, remember, notifyChange};
})();
function read(request) {
    const page = SiteKit.publish(sense.source.read(), request);
    if (!SiteKit.document(page)) SiteKit.remember(page);
}
function act(request) { return SiteKit.act(request); }
function watch() { if (!SiteKit.document(SiteKit.snapshot(sense.source.read()))) sense.source.watch(); }
function changed(material) {
    const page = SiteKit.publish(material);
    SiteKit.notifyChange(page);
}
