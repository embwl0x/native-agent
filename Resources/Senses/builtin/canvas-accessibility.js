// Starter frame. ES2020 / JavaScriptCore; no modules, filesystem or network.
// Keep this in front of the sense's own read(request) implementation.
var NativeKit = (() => {
    const maximumTextBytes = 40000; // NativePage.maximumTextBytes
    const maximumItems = 100000;
    let lastFileBytes, lastPage, lastRows;
    function fail(message) { throw new Error(message); }
    function utf8Length(s) {
        let n = 0;
        for (const c of String(s)) {
            const v = c.codePointAt(0);
            n += v < 128 ? 1 : v < 2048 ? 2 : v < 65536 ? 3 : 4;
        }
        return n;
    }
    function prefix(s, budget) {
        let out = "", n = 0;
        for (const c of String(s)) {
            const size = utf8Length(c);
            if (n + size > budget) break;
            out += c; n += size;
        }
        return out;
    }
    function utf8(bytes) {
        let out = "";
        for (let p = 0; p < bytes.length;) {
            const first = bytes[p++];
            let value, count, minimum;
            if (first < 128) { out += String.fromCharCode(first); continue; }
            if (first >= 194 && first <= 223) { value = first & 31; count = 1; minimum = 128; }
            else if (first >= 224 && first <= 239) { value = first & 15; count = 2; minimum = 2048; }
            else if (first >= 240 && first <= 244) { value = first & 7; count = 3; minimum = 65536; }
            else fail("Invalid UTF-8 lead byte");
            while (count--) {
                if (p >= bytes.length || (bytes[p] & 192) !== 128) fail("Truncated or invalid UTF-8");
                value = value * 64 + (bytes[p++] & 63);
            }
            if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) fail("Invalid UTF-8 scalar");
            out += String.fromCodePoint(value);
        }
        return out.replace(/^\uFEFF/, "");
    }
    function textBytes(bytes) {
        if (bytes.length >= 2 && ((bytes[0] === 255 && bytes[1] === 254) || (bytes[0] === 254 && bytes[1] === 255))) {
            if (bytes.length % 2) fail("Truncated UTF-16");
            let text = ""; const little = bytes[0] === 255;
            for (let p = 2; p < bytes.length; p += 2) text += String.fromCharCode(little ? bytes[p] + 256 * bytes[p + 1] : 256 * bytes[p] + bytes[p + 1]);
            return text;
        }
        return utf8(bytes);
    }
    function bytes(material) {
        if (material.kind !== "file" || !material.data) fail("This sense needs file bytes from sense.source.read");
        const data = material.data instanceof Uint8Array ? material.data : Uint8Array.from(material.data);
        if (data.length > 128 * 1024 * 1024) fail("File exceeds the 128 MiB reader limit");
        lastFileBytes = data;
        return data;
    }
    function root(material, corner) {
        return material.kind === "file" ? "file:" + encodeURIComponent(material.path) + "#document" : corner + "#canvas";
    }
    function sourceAddress(address) {
        if (!address) return undefined;
        const base = address.split("#")[0];
        if (base.startsWith("file:")) return decodeURIComponent(base.slice(5));
        return address.startsWith("/") || address.startsWith("~") ? address : undefined;
    }
    function address(base, ...parts) { return base + "/" + parts.map(p => encodeURIComponent(String(p))).join("/"); }
    function thing(name, kind, at, text = "", verbs = []) {
        return { name: String(name), kind, address: at, text: paragraphs(text), verbs };
    }
    function paragraphs(text) { return String(text).replace(/\r\n|[\r\u2028\u2029]/g, "\n"); }
    // Compare source-owned structural rows, not a clipped published page.
    function deltaRows(before, after) {
        const old = new Map(before.map(row => [row.address, row]));
        const next = new Map(after.map(row => [row.address, row]));
        let added = 0, removed = 0, changed = 0; const details = [];
        const show = value => prefix(sense.redactText(String(value || "")).replace(/\s+/g, " ").trim(), 100);
        function detail(text) { if (details.length < 3) details.push(text); }
        for (const row of after) {
            const prior = old.get(row.address);
            if (!prior) { added++; detail("added " + show(row.kind) + " “" + show(row.name) + "”: " + show(row.text)); }
            else if (prior.name !== row.name || prior.kind !== row.kind || prior.text !== row.text || prior.deltaKey !== row.deltaKey) {
                changed++; detail("changed " + show(row.kind) + " “" + show(row.name) + "”: " + show(prior.text || prior.name) + " → " + show(row.text || row.name));
            }
        }
        for (const row of before) if (!next.has(row.address)) { removed++; detail("removed " + show(row.kind) + " “" + show(row.name) + "”"); }
        if (!added && !removed && !changed) return "";
        return sense.redactText(added + " added, " + removed + " removed, " + changed + " changed" + (details.length ? "; " + details.join("; ") : ""));
    }
    function column(index) {
        let name = "";
        for (let n = index + 1; n > 0; n = Math.floor((n - 1) / 26)) name = String.fromCharCode(65 + (n - 1) % 26) + name;
        return name;
    }
    // A request for a thing includes that thing and its descendants. A part
    // cursor resumes both item and UTF-8-safe text offset; nothing disappears.
    function publish(corner, base, title, items, request = {}, sourceNote = "") {
        lastRows = items;
        if (items.length > maximumItems) fail("Document exceeds the 100,000 thing limit");
        const identities = new Set();
        for (const item of items) {
            if (!item.address.startsWith(base + "/") || identities.has(item.address)) fail("Duplicate or foreign thing address: " + item.address);
            identities.add(item.address);
        }
        const requested = request.address;
        const asked = !requested || requested.startsWith("/") || requested.startsWith("~") ? base : requested;
        const match = /[?&]part=(\d+),(\d+)(?:&version=[^&]+)?$/.exec(asked);
        const selected = match ? asked.slice(0, match.index) : asked;
        if (selected !== base && !selected.startsWith(base + "/")) fail("Address belongs to another document");
        const rows = selected === base ? items : items.filter(t => t.address === selected || t.address.startsWith(selected + "/"));
        if (selected !== base && !rows.length) fail("Address is no longer present: " + selected);
        let i = match ? Number(match[1]) : 0, offset = match ? Number(match[2]) : 0;
        if (i > rows.length || (i === rows.length && offset) || (rows[i] && offset > rows[i].text.length)) fail("Invalid page cursor");
        const note = sourceNote ? String(sourceNote) + "\n\n" : "";
        if (utf8Length(note) >= maximumTextBytes) fail("Source-readiness line exceeds the page text limit");
        let text = note, budget = maximumTextBytes - utf8Length(note); const things = [], folded = [];
        while (i < rows.length && things.length < 160) {
            // Addressed-only details remain things, but print only when asked
            // for directly (table rows/cells must not repeat the whole table).
            const row = rows[i], visible = !row.addressedOnly || row.address === selected;
            // Container content is available on its thing; descendants carry
            // that content in reading order without printing it twice.
            const rowText = !visible || row.aggregate && rows.some(t => t.address.startsWith(row.address + "/")) ? "" : row.text;
            // Empty containers/details stay addressable without blank sections.
            const hasText = rowText.trim().length > 0;
            const heading = hasText ? prefix(row.name, 400) + "\n" : "";
            if (hasText && budget < utf8Length(heading) + 8) break;
            const body = prefix(rowText.slice(offset), budget - utf8Length(heading) - 2);
            if (body.trim()) { text += heading + body + "\n\n"; budget -= utf8Length(heading + body + "\n\n"); }
            const detail = prefix(row.text.replace(/\s+/g, " ").trim(), 240);
            things.push({ name: prefix(row.name, 400), kind: row.kind, address: row.address,
                ...(detail ? { detail } : {}), verbs: row.verbs });
            offset += body.length;
            if (offset < rowText.length) break;
            i++; offset = 0;
        }
        if (i < rows.length) {
            for (let j = i; j < Math.min(rows.length, i + 12); j++) folded.push(prefix(rows[j].name, 160));
            if (rows.length - i > 12) folded.push(String(rows.length - i - 12) + " further things");
        }
        const page = { address: asked, title: prefix(title, 600), text, things, folded };
        if (i < rows.length) page.more = selected + "?part=" + i + "," + offset;
        // sense.publish supplies the record's corner; the JS page contract does
        // not encode Swift's associated-value SenseCorner enum.
        sense.publish(page);
        lastPage = page;
    }
    function changed(material) {
        if (material.kind !== "file" || !material.data) fail("File watching needs file bytes");
        const next = material.data;
        if (lastFileBytes && next.length === lastFileBytes.length && next.every((b, i) => b === lastFileBytes[i])) return;
        // The changed entry supplies these bytes to source.read(). Use the root,
        // even if the preceding read selected a folded part of the document.
        const previous = lastRows;
        read({});
        if (!lastPage) fail("A changed file must publish its page");
        if (!previous) return; // registration-race read establishes a baseline
        const delta = deltaRows(previous, lastRows);
        if (delta) sense.notify({ address: lastPage.address, summary: prefix(delta, 900) });
    }
    return { maximumTextBytes, maximumItems, fail, utf8Length, prefix, utf8, textBytes,
        bytes, root, sourceAddress, address, thing, paragraphs, column, deltaRows, publish, changed };
})();

function watch() { sense.source.watch(); }
function changed(material) { NativeKit.changed(material); }

// Replace this read with your format reader; the plain-text starter is runnable.
function read(request) {
    const material = sense.source.read(NativeKit.sourceAddress(request.address));
    if (material.kind !== "text") NativeKit.fail("The starter frame needs a format-specific reader for this material");
    const root = "text:document";
    NativeKit.publish("need:document", root, "Document", [NativeKit.thing("Text", "text", root + "/text", material.text)], request);
}
// Canvas example: exposed AX plus independently recognized window text.
function read(request) {
    const K = NativeKit, material = sense.source.read();
    if (material.kind !== "accessibility" || !material.tree) K.fail("Canvas sense needs an accessibility tree");
    const base = K.root(material, "app:com.figma.Desktop"), rows = [], seen = new Set();
    let count = 0;
    function string(value) {
        if (typeof value === "string") return value;
        if (typeof value === "boolean" || typeof value === "number" && Number.isFinite(value)) return String(value);
        // Native MacScreenText's redacted representation is authoritative.
        if (value && typeof value === "object" && value.redacted === true) return "[redacted]";
        if (value && typeof value === "object" && typeof value.text === "string") return value.text;
        return "";
    }
    function walk(node, path) {
        if (!node || typeof node !== "object") K.fail("Malformed canvas accessibility node");
        if (++count > 10000 || path.length > 64) K.fail("Canvas accessibility tree exceeds reader limits");
        const role = string(node.role || node.AXRole), name = string(node.label || node.title || node.AXTitle || node.name || node.description || node.AXDescription || node.text);
        const secret = /SecureTextField|Password/i.test(role) || node.secret === true || node.secret_field === true || node.redacted === true;
        const identifier = string(node.identifier || node.AXIdentifier || node.source_id);
        const axPath = node.sourceAXPath || node.source_ax_path || node.ax_path || node.path;
        if (axPath && (!Array.isArray(axPath) || axPath.some(n => !Number.isSafeInteger(n) || n < 0))) K.fail("Invalid canvas accessibility path");
        const identity = identifier ? "id/" + encodeURIComponent(identifier) : Array.isArray(axPath) ? "ax/" + axPath.join(".") : "ax/" + path.join(".");
        const at = base + "/" + identity;
        if (name || role) {
            if (seen.has(at)) K.fail("Canvas accessibility identity is ambiguous: " + at); seen.add(at);
            const value = secret ? "[redacted]" : string(node.value === undefined ? node.AXValue : node.value);
            const detail = [role, value, node.selected === true ? "selected" : "", node.enabled === false ? "disabled" : "", !identifier ? "Address follows the accessibility path; reread after layout changes." : ""].filter(Boolean).join(" · ");
            const kind = /Outline|Row|Cell/i.test(role) ? "layer" : /Button/i.test(role) ? "button" : /Text/i.test(role) ? "text" : /Group|Canvas/i.test(role) ? "group" : "element";
            rows.push(K.thing(secret ? "Protected field" : name || role, kind, at, detail));
        }
        const children = node.children || node.AXChildren || [];
        if (!Array.isArray(children)) K.fail("Canvas accessibility children are not an array");
        children.forEach((child, i) => walk(child, path.concat(i)));
    }
    const tree = material.tree;
    // Accept both an AX tree and the current four-verbs observation's target
    // list. Handle numbers are never relabeled as persistent identifiers.
    const roots = Array.isArray(tree) ? tree : Array.isArray(tree.nodes) ? tree.nodes : Array.isArray(tree.targets) ? tree.targets : Array.isArray(tree.affordances) ? tree.affordances : Array.isArray(tree.windows) ? tree.windows : [tree.root || tree];
    roots.forEach((node, i) => walk(node, [i]));
    (tree.recognized_text || []).forEach((row, i) => {
        const text = string(row.text), f = row.frame;
        if (!text || !f) return;
        rows.push(K.thing(text, "window text", base + "/recognized/" + i,
            "On-device window text recognition · x=" + f.x + " y=" + f.y + " width=" + f.w + " height=" + f.h));
    });
    if (!rows.length) K.fail("The canvas exposes no named accessibility elements");
    K.publish("app:com.figma.Desktop", base, "Figma canvas", rows, request,
        typeof tree.renderer_wait_note === "string" ? tree.renderer_wait_note : "");
}
function watch() { sense.source.watch(); }
function changed(material) { read({address: null}); sense.notify({address: "app:com.figma.Desktop", summary: "Figma canvas changed."}); }
