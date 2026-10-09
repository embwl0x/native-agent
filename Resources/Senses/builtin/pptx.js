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
// ZIP's central directory + raw DEFLATE, entirely in ES2020. No host IO.
var SenseZip = (() => {
    const fail = NativeKit.fail, limit = 32 * 1024 * 1024;
    function u16(b, p) { if (p + 2 > b.length) fail("Truncated ZIP integer"); return b[p] | b[p + 1] << 8; }
    function u32(b, p) { return (u16(b, p) + u16(b, p + 2) * 65536) >>> 0; }
    function inflate(input, size) {
        if (size > limit) fail("ZIP entry exceeds 32 MiB");
        const output = new Uint8Array(size); let pos = 0, bit = 0;
        function bits(n) {
            if (bit + n > input.length * 8) fail("Truncated DEFLATE stream");
            let value = 0;
            for (let k = 0; k < n; k++, bit++) value |= ((input[bit >> 3] >> (bit & 7)) & 1) << k;
            return value;
        }
        function tree(lengths) {
            const counts = new Array(16).fill(0), next = new Array(16).fill(0), table = new Map();
            for (const n of lengths) { if (n < 0 || n > 15) fail("Invalid Huffman length"); if (n) counts[n]++; }
            let code = 0, available = 1;
            for (let n = 1; n <= 15; n++) {
                available = available * 2 - counts[n];
                if (available < 0) fail("Oversubscribed Huffman tree");
                code = (code + counts[n - 1]) * 2; next[n] = code;
            }
            lengths.forEach((length, symbol) => {
                if (!length) return;
                let c = next[length]++, reversed = 0;
                for (let n = 0; n < length; n++) { reversed = reversed * 2 + (c & 1); c >>= 1; }
                table.set(length * 65536 + reversed, symbol);
            });
            return table;
        }
        function symbol(table) {
            let code = 0;
            for (let n = 1; n <= 15; n++) {
                code |= bits(1) << (n - 1);
                const found = table.get(n * 65536 + code);
                if (found !== undefined) return found;
            }
            fail("Invalid DEFLATE code");
        }
        function emit(value) {
            if (pos >= size) fail("DEFLATE exceeds declared size");
            output[pos++] = value;
            if (pos % 65536 === 0) sense.progress();
        }
        const lengthBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258];
        const lengthExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0];
        const distanceBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577];
        const distanceExtra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13];
        let last = false;
        while (!last) {
            last = !!bits(1); const type = bits(2);
            if (type === 0) {
                bit = Math.ceil(bit / 8) * 8;
                const count = bits(16), complement = bits(16);
                if ((count ^ complement) !== 65535) fail("Bad stored DEFLATE block");
                for (let n = 0; n < count; n++) emit(bits(8));
                continue;
            }
            if (type === 3) fail("Reserved DEFLATE block");
            let literals, distances;
            if (type === 1) {
                literals = tree(Array.from({ length: 288 }, (_, n) => n < 144 ? 8 : n < 256 ? 9 : n < 280 ? 7 : 8));
                distances = tree(new Array(32).fill(5));
            } else {
                const nl = bits(5) + 257, nd = bits(5) + 1, nc = bits(4) + 4;
                if (nl > 286) fail("Invalid DEFLATE literal count");
                // RFC 1951 code-length alphabet order.
                const canonicalOrder = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];
                const lengths = new Array(19).fill(0);
                for (let n = 0; n < nc; n++) lengths[canonicalOrder[n]] = bits(3);
                const codes = tree(lengths), all = [];
                while (all.length < nl + nd) {
                    const code = symbol(codes);
                    if (code < 16) all.push(code);
                    else {
                        if (code === 16 && !all.length) fail("Huffman repeat has no predecessor");
                        const count = code === 16 ? bits(2) + 3 : code === 17 ? bits(3) + 3 : bits(7) + 11;
                        if (all.length + count > nl + nd) fail("Huffman repeat exceeds tree");
                        const value = code === 16 ? all[all.length - 1] : 0;
                        for (let n = 0; n < count; n++) all.push(value);
                    }
                }
                if (!all[256]) fail("DEFLATE tree has no end marker");
                literals = tree(all.slice(0, nl)); distances = tree(all.slice(nl));
            }
            for (;;) {
                const code = symbol(literals);
                if (code === 256) break;
                if (code < 256) { emit(code); continue; }
                if (code > 285) fail("Reserved DEFLATE length");
                const count = lengthBase[code - 257] + bits(lengthExtra[code - 257]);
                const dc = symbol(distances);
                if (dc > 29) fail("Reserved DEFLATE distance");
                const distance = distanceBase[dc] + bits(distanceExtra[dc]);
                if (distance > pos) fail("DEFLATE copy precedes output");
                for (let n = 0; n < count; n++) emit(output[pos - distance]);
            }
        }
        if (pos !== size || Math.ceil(bit / 8) !== input.length) fail("DEFLATE size mismatch");
        return output;
    }
    const crcTable = Array.from({ length: 256 }, (_, n) => {
        for (let k = 0; k < 8; k++) n = n & 1 ? 0xedb88320 ^ n >>> 1 : n >>> 1;
        return n >>> 0;
    });
    function crc32(bytes) {
        let crc = 0xffffffff, consumed = 0;
        for (const b of bytes) {
            crc = crcTable[(crc ^ b) & 255] ^ crc >>> 8;
            if (++consumed % 65536 === 0) sense.progress();
        }
        return (crc ^ 0xffffffff) >>> 0;
    }
    function open(data) {
        let end = -1;
        for (let p = data.length - 22; p >= Math.max(0, data.length - 65557); p--) {
            if (u32(data, p) === 0x06054b50 && p + 22 + u16(data, p + 20) === data.length) { end = p; break; }
        }
        if (end < 0) fail("Not a ZIP archive (directory-style packages must be supplied as ZIP bytes)");
        const count = u16(data, end + 10), start = u32(data, end + 16), directorySize = u32(data, end + 12);
        if (u16(data, end + 4) || u16(data, end + 6) || u16(data, end + 8) !== count) fail("Multi-disk ZIP is unsupported");
        if (count === 65535 || start === 0xffffffff || directorySize === 0xffffffff) fail("ZIP64 is unsupported");
        if (count > 8000 || start + directorySize > end) fail("Invalid or excessive ZIP directory");
        const entries = new Map(); let p = start, inflated = 0;
        for (let n = 0; n < count; n++) {
            if (u32(data, p) !== 0x02014b50) fail("Invalid ZIP central directory");
            const flags = u16(data, p + 8), method = u16(data, p + 10), crc = u32(data, p + 16);
            const packed = u32(data, p + 20), size = u32(data, p + 24), nl = u16(data, p + 28), el = u16(data, p + 30), cl = u16(data, p + 32);
            const offset = u32(data, p + 42), next = p + 46 + nl + el + cl;
            if (next > start + directorySize || u16(data, p + 34)) fail("Invalid ZIP entry bounds");
            const name = NativeKit.utf8(data.subarray(p + 46, p + 46 + nl));
            if (name.startsWith("/") || name.includes("\\") || name.includes("\0") || name.split("/").some(s => s === ".." || s === ".")) fail("Unsafe ZIP path");
            if (entries.has(name)) fail("Duplicate ZIP path: " + name);
            if (flags & 1 || flags & 64) fail("Encrypted ZIP is unsupported");
            if (packed === 0xffffffff || size === 0xffffffff || offset === 0xffffffff) fail("ZIP64 entry is unsupported");
            entries.set(name, { flags, method, crc, packed, size, offset }); p = next;
        }
        if (p !== start + directorySize) fail("ZIP directory size mismatch");
        function get(name) {
            const e = entries.get(name);
            if (!e) fail("Missing ZIP entry: " + name);
            if (e.size > limit) fail("ZIP entry exceeds 32 MiB: " + name);
            inflated += e.size;
            if (inflated > 128 * 1024 * 1024) fail("ZIP read exceeds 128 MiB expansion limit");
            if (u32(data, e.offset) !== 0x04034b50 || u16(data, e.offset + 8) !== e.method || u16(data, e.offset + 6) !== e.flags) fail("ZIP local header mismatch");
            const nl = u16(data, e.offset + 26), el = u16(data, e.offset + 28), begin = e.offset + 30 + nl + el;
            if (NativeKit.utf8(data.subarray(e.offset + 30, e.offset + 30 + nl)) !== name || begin + e.packed > start) fail("ZIP local entry bounds mismatch");
            const packed = data.subarray(begin, begin + e.packed);
            const result = e.method === 0 ? packed : e.method === 8 ? inflate(packed, e.size) : fail("Unsupported ZIP compression: " + e.method);
            if (result.length !== e.size || crc32(result) !== e.crc) fail("ZIP checksum mismatch: " + name);
            sense.progress();
            return result;
        }
        return { names: Array.from(entries.keys()), has: name => entries.has(name), get, text: name => NativeKit.textBytes(get(name)) };
    }
    return { open, inflate, u16, u32 };
})();
// Small namespace-aware-enough reader for OOXML / EPUB, not a browser DOM.
var SenseXML = (() => {
    const fail = NativeKit.fail;
    function entities(text) {
        const named = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0", ndash: "–", mdash: "—", lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”", hellip: "…", copy: "©", reg: "®" };
        return text.replace(/&([^;\s]+);/g, (_, name) => {
            if (name[0] === "#") {
                const hex = name[1] === "x", digits = name.slice(hex ? 2 : 1);
                if (!(hex ? /^[a-f\d]+$/i : /^\d+$/).test(digits)) fail("Invalid XML character reference");
                const code = parseInt(digits, hex ? 16 : 10);
                if (!code || code > 0x10ffff || code >= 0xd800 && code <= 0xdfff) fail("Invalid XML scalar");
                return String.fromCodePoint(code);
            }
            if (!(name in named)) fail("Unsupported XML entity: " + name);
            return named[name];
        });
    }
    function parse(text) {
        const root = { name: "", attrs: {}, children: [] }, stack = [root];
        const token = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!DOCTYPE\s[^>]*>|<\/?[A-Za-z_](?:"[^"]*"|'[^']*'|[^'">])*>|[^<]+/g;
        let match, end = 0, nodes = 0;
        while ((match = token.exec(text))) {
            if (match.index !== end) fail("Malformed XML"); end = token.lastIndex;
            const s = match[0], parent = stack[stack.length - 1];
            if (s.startsWith("<!--") || s.startsWith("<?")) continue;
            if (s.startsWith("<!DOCTYPE")) { if (s.includes("[")) fail("XML entity declarations are unsupported"); continue; }
            if (s.startsWith("<![CDATA[")) { parent.children.push(s.slice(9, -3)); continue; }
            if (s.startsWith("</")) {
                if (stack.length === 1 || s.slice(2, -1).trim() !== parent.qualified) fail("Unbalanced XML element");
                stack.pop(); continue;
            }
            if (s[0] !== "<") { parent.children.push(entities(s)); continue; }
            if (++nodes > 500000 || stack.length > 128) fail("XML structure exceeds reader limits");
            if (nodes % 2048 === 0) sense.progress();
            const name = /^<([^\s/>]+)/.exec(s)[1], attrs = {};
            const tail = s.slice(1 + name.length, s.endsWith("/>") ? -2 : -1);
            const attr = /\s+([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g; let a, consumed = 0;
            while ((a = attr.exec(tail))) {
                if (a.index !== consumed || Object.prototype.hasOwnProperty.call(attrs, a[1])) fail("Malformed XML attributes");
                attrs[a[1]] = entities(a[2] === undefined ? a[3] : a[2]); consumed = attr.lastIndex;
            }
            if (tail.slice(consumed).trim()) fail("Malformed XML attributes");
            const node = { name: name.split(":").pop(), qualified: name, attrs, children: [] };
            parent.children.push(node);
            if (!s.endsWith("/>")) stack.push(node);
        }
        if (end !== text.length || stack.length !== 1) fail("Truncated XML");
        return root;
    }
    function children(node, name) { return node.children.filter(c => typeof c !== "string" && (!name || c.name === name)); }
    function all(node, name) {
        const out = []; let visited = 0;
        function walk(n) {
            if (typeof n === "string") return;
            if (++visited % 2048 === 0) sense.progress();
            if (n.name === name) out.push(n); n.children.forEach(walk);
        }
        walk(node); return out;
    }
    function attr(node, name) {
        if (node.attrs[name] !== undefined) return node.attrs[name];
        const key = Object.keys(node.attrs).find(k => k.split(":").pop() === name);
        return key === undefined ? undefined : node.attrs[key];
    }
    let textNodes = 0;
    function text(node) {
        if (typeof node === "string") return node;
        if (++textNodes % 2048 === 0) sense.progress();
        if (["script", "style", "del", "delText"].includes(node.name)) return "";
        if (["tab", "br", "cr"].includes(node.name)) return node.name === "tab" ? "\t" : "\n";
        return node.children.map(text).join("");
    }
    function resolve(base, target) {
        if (!target || /^[a-z][a-z\d+.-]*:/i.test(target) || target.startsWith("/")) fail("External or invalid package relationship");
        const parts = base.split("/").slice(0, -1);
        for (const part of decodeURIComponent(target.split("#")[0]).split("/")) {
            if (part === "..") { if (!parts.length) fail("Relationship escapes package"); parts.pop(); }
            else if (part && part !== ".") parts.push(part);
        }
        return parts.join("/");
    }
    function relationships(zip, part) {
        const pieces = part.split("/"), filename = pieces.pop();
        const rel = (pieces.length ? pieces.join("/") + "/" : "") + "_rels/" + filename + ".rels";
        const out = new Map();
        if (!zip.has(rel)) return out;
        for (const r of all(parse(zip.text(rel)), "Relationship")) {
            if (attr(r, "TargetMode") === "External") continue;
            out.set(attr(r, "Id"), { path: resolve(part, attr(r, "Target")), type: attr(r, "Type") });
        }
        return out;
    }
    return { parse, children, all, attr, text, resolve, relationships };
})();
var SenseDocuments = (() => {
    const K = NativeKit, X = SenseXML;
    function title(material) { return material.path.split("/").pop(); }
    function wordText(node) {
        if (typeof node === "string") return "";
        if (["del", "instrText"].includes(node.name)) return "";
        if (node.name === "t") return X.text(node);
        if (node.name === "tab") return "\t";
        if (["br", "cr"].includes(node.name)) return "\n";
        return node.children.map(wordText).join("");
    }
    function addTable(rows, name, at, cells, addressedOnly = false) {
        const lines = cells.map(row => row.map(cell => cell.text.replace(/\s+/g, " ").trim()).join(" | "));
        rows.push(K.thing(name, "table", at, lines.join("\n")));
        cells.forEach((row, r) => {
            const rowAt = K.address(at, "row", r + 1);
            rows.push({ ...K.thing("Row " + (r + 1), "row", rowAt, lines[r]), addressedOnly });
            row.forEach((cell, c) => rows.push({ ...K.thing("Row " + (r + 1) + ", cell " + (c + 1), "cell",
                K.address(rowAt, "cell", c + 1), cell.detail === undefined ? cell.text : cell.detail), addressedOnly }));
        });
    }
    function docx(zip, base) {
        const body = X.all(X.parse(zip.text("word/document.xml")), "body")[0];
        if (!body) K.fail("DOCX has no document body");
        const rows = []; let paragraph = 0, table = 0;
        function block(node, parent) {
            if (node.name === "p") {
                paragraph++;
                const value = wordText(node), id = X.attr(node, "paraId") || paragraph;
                if (!value.trim()) return;
                const style = X.all(node, "pStyle")[0], styleName = style && X.attr(style, "val");
                rows.push(K.thing(styleName && /heading|title/i.test(styleName) ? value : "Paragraph " + paragraph,
                    styleName && /heading|title/i.test(styleName) ? "heading" : "paragraph", K.address(parent, "paragraph", id), value));
            } else if (node.name === "tbl") {
                const at = K.address(parent, "table", ++table), trs = X.children(node, "tr");
                addTable(rows, "Table " + table, at, trs.map(tr => X.children(tr, "tc").map(tc => {
                    const value = X.children(tc, "p").map(wordText).join("\n");
                    const span = X.all(tc, "gridSpan")[0], merge = X.all(tc, "vMerge")[0];
                    const detail = value + (span ? "\nColumn span: " + X.attr(span, "val") : "") + (merge ? "\nVertical merge: " + (X.attr(merge, "val") || "continue") : "");
                    return { text: value, detail };
                })), true);
                trs.forEach((tr, r) => X.children(tr, "tc").forEach((tc, c) => {
                    X.children(tc).filter(n => n.name !== "p").forEach(n => block(n, K.address(at, "row", r + 1, "cell", c + 1)));
                }));
            } else if (node.name === "sdt") {
                const at = K.address(parent, "control", ++paragraph);
                rows.push(K.thing("Content control " + paragraph, "text", at));
                X.children(node, "sdtContent").forEach(content => X.children(content).forEach(n => block(n, at)));
            } else if (node.name === "altChunk") K.fail("DOCX embedded alternate-format content is unsupported");
        }
        X.children(body).forEach(node => block(node, base));
        for (const part of zip.names.filter(n => /^word\/(header\d+|footer\d+|footnotes|endnotes)\.xml$/.test(n)).sort()) {
            const at = K.address(base, "part", part), root = X.children(X.parse(zip.text(part)))[0];
            rows.push(K.thing(part.slice(5, -4), "section", at));
            const containers = ["footnotes", "endnotes"].includes(root.name) ? X.children(root) : [root];
            containers.forEach(container => X.children(container).forEach(node => block(node, at)));
        }
        return rows;
    }
    function xlsx(zip, base) {
        const part = "xl/workbook.xml", workbook = X.parse(zip.text(part)), rels = X.relationships(zip, part);
        const strings = zip.has("xl/sharedStrings.xml") ? X.all(X.parse(zip.text("xl/sharedStrings.xml")), "si").map(n => X.all(n, "t").map(X.text).join("")) : [];
        const rows = [];
        for (const sheet of X.all(workbook, "sheet")) {
            const name = X.attr(sheet, "name"), id = X.attr(sheet, "sheetId"), relationship = rels.get(X.attr(sheet, "r:id"));
            if (!relationship) K.fail("XLSX sheet relationship is missing: " + name);
            if (!relationship.type.endsWith("/worksheet")) K.fail("Unsupported XLSX sheet kind: " + relationship.type);
            const at = K.address(base, "sheet", id), cells = X.all(X.parse(zip.text(relationship.path)), "c");
            rows.push(K.thing(name, "sheet", at, cells.length + " stored cells" + (X.attr(sheet, "state") ? " · " + X.attr(sheet, "state") : "")));
            for (const cell of cells) {
                const ref = X.attr(cell, "r"), type = X.attr(cell, "t") || "n";
                if (!/^[A-Z]+[1-9]\d*$/.test(ref || "")) K.fail("XLSX cell has no valid coordinate");
                const v = X.children(cell, "v")[0], formula = X.children(cell, "f")[0];
                let value = v ? X.text(v) : "";
                if (type === "s") {
                    if (!/^\d+$/.test(value) || strings[Number(value)] === undefined) K.fail("XLSX shared string index is missing");
                    value = strings[Number(value)];
                } else if (type === "inlineStr") value = X.all(cell, "t").map(X.text).join("");
                else if (type === "b") { if (!/^[01]$/.test(value)) K.fail("Invalid XLSX boolean"); value = value === "1" ? "true" : "false"; }
                else if (!["n", "str", "e", "d"].includes(type)) K.fail("Unsupported XLSX cell type: " + type);
                if (type === "n" && value) value += " (stored number; display format not applied)";
                if (formula) value += "\nFormula: " + X.text(formula) + (v ? "\nValue is cached; not recalculated." : "\nNo cached value is present; formula is not recalculated.");
                rows.push(K.thing(ref, "cell", K.address(at, "cell", ref), value));
            }
            const sheetRels = X.relationships(zip, relationship.path);
            for (const rel of sheetRels.values()) {
                if (!rel.type.endsWith("/table")) continue;
                const table = X.all(X.parse(zip.text(rel.path)), "table")[0];
                if (!table) K.fail("XLSX table part has no table");
                rows.push(K.thing(X.attr(table, "displayName") || X.attr(table, "name"), "table", K.address(at, "table", X.attr(table, "id")), "Range: " + X.attr(table, "ref")));
            }
        }
        return rows;
    }
    function drawingText(node) {
        if (typeof node === "string" || node.name === "tbl") return "";
        if (node.name === "p") {
            function run(n) {
                if (typeof n === "string") return "";
                if (["t", "br", "tab"].includes(n.name)) return X.text(n);
                return X.children(n).map(run).join("");
            }
            return run(node);
        }
        return X.children(node).map(drawingText).filter(Boolean).join("\n");
    }
    function pptx(zip, base) {
        const part = "ppt/presentation.xml", rels = X.relationships(zip, part), rows = [];
        const slides = X.all(X.parse(zip.text(part)), "sldId");
        slides.forEach((slide, i) => {
            const rel = rels.get(X.attr(slide, "r:id"));
            if (!rel || !rel.type.endsWith("/slide")) K.fail("PPTX slide relationship is missing");
            const tree = X.parse(zip.text(rel.path)), at = K.address(base, "slide", i + 1);
            const shapeTree = X.all(tree, "spTree")[0];
            if (!shapeTree) K.fail("PPTX slide has no shape tree");
            const shapes = [];
            function collect(node) {
                for (const child of X.children(node)) {
                    if (["sp", "graphicFrame", "pic", "cxnSp", "grpSp", "contentPart"].includes(child.name)) {
                        shapes.push(child);
                        if (child.name === "grpSp") collect(child);
                    } else if (child.name === "AlternateContent") {
                        // Markup compatibility stores mutually exclusive branches.
                        const branch = X.children(child, "Choice")[0] || X.children(child, "Fallback")[0];
                        if (branch) collect(branch);
                    } else if (X.all(child, "txBody").length) shapes.push(child);
                }
            }
            collect(shapeTree);
            const slideRels = X.relationships(zip, rel.path);
            const layoutRel = [...slideRels.values()].find(r => r.type.endsWith("/slideLayout"));
            const layoutPlaceholders = layoutRel ? X.all(X.parse(zip.text(layoutRel.path)), "ph") : [];
            rows.push(K.thing("Slide " + (i + 1), "slide", at));
            let textNumber = 0;
            shapes.forEach((shape, order) => {
                const placeholder = shape.name === "grpSp" ? undefined : X.all(shape, "ph")[0];
                let role = placeholder && X.attr(placeholder, "type");
                if (placeholder && role === undefined) {
                    // Slide placeholders inherit their role from the layout
                    // placeholder with the same declared index (default 0).
                    const index = X.attr(placeholder, "idx") || "0";
                    const inherited = layoutPlaceholders.find(p => (X.attr(p, "idx") || "0") === index);
                    role = inherited && X.attr(inherited, "type");
                }
                // These are DrawingML placeholder types, never guesses from text.
                const roles = { title: "Title", ctrTitle: "Title", body: "Body", subTitle: "Subtitle",
                    dt: "Date", ftr: "Footer", sldNum: "Slide number", hdr: "Header", obj: "Object",
                    chart: "Chart", tbl: "Table", clipArt: "Clip art", dgm: "Diagram", media: "Media", pic: "Picture" };
                const shapeAt = K.address(at, "shape", order + 1), name = roles[role] || "Text " + (++textNumber);
                const tables = shape.name === "grpSp" ? [] : X.all(shape, "tbl");
                const shapeText = tables.length || shape.name === "grpSp" ? "" : drawingText(shape);
                rows.push(K.thing(name, shape.name === "graphicFrame" ? "graphic" : "shape", shapeAt));
                if (shapeText) X.all(shape, "p").forEach((p, j) => {
                    const value = drawingText(p);
                    if (value.trim()) rows.push(K.thing(name + ", paragraph " + (j + 1), "paragraph", K.address(shapeAt, "paragraph", j + 1), value));
                });
                tables.forEach((table, t) => addTable(rows, name + " table " + (t + 1), K.address(shapeAt, "table", t + 1),
                    X.children(table, "tr").map(tr => X.children(tr, "tc").map(tc => ({ text: drawingText(tc) })))));
            });
            for (const noteRel of slideRels.values()) {
                if (noteRel.type.endsWith("/notesSlide")) rows.push(K.thing("Speaker notes", "notes", K.address(at, "notes"), drawingText(X.parse(zip.text(noteRel.path)))));
            }
        });
        return rows;
    }
    function epub(zip, base) {
        if (zip.has("META-INF/encryption.xml")) K.fail("Encrypted or obfuscated EPUB resources are unsupported");
        const container = X.parse(zip.text("META-INF/container.xml"));
        const rootfile = X.all(container, "rootfile").find(n => X.attr(n, "media-type") === "application/oebps-package+xml");
        if (!rootfile) K.fail("EPUB has no OPF rootfile");
        const opfPath = X.attr(rootfile, "full-path"), opf = X.parse(zip.text(opfPath));
        const manifest = new Map(X.all(opf, "item").map(n => [X.attr(n, "id"), n])), rows = [];
        let chapterNumber = 0;
        for (const ref of X.all(opf, "itemref")) {
            const id = X.attr(ref, "idref"), item = manifest.get(id);
            if (!item) K.fail("EPUB spine item is missing: " + id);
            if (X.attr(item, "media-type") !== "application/xhtml+xml") K.fail("Unsupported EPUB spine media: " + X.attr(item, "media-type"));
            const part = X.resolve(opfPath, X.attr(item, "href")), doc = X.parse(zip.text(part));
            const body = X.all(doc, "body")[0];
            if (!body) K.fail("EPUB chapter has no body: " + part);
            const at = K.address(base, "chapter", id);
            const chapter = { ...K.thing("Chapter " + (++chapterNumber), "chapter", at), aggregate: true };
            rows.push(chapter);
            const firstBlock = rows.length;
            let ordinal = 0, heading = 0, paragraph = 0;
            function walk(node) {
                if (typeof node === "string") { if (node.trim()) rows.push(K.thing("Text " + (++ordinal), "text", K.address(at, "block", ordinal), node)); return; }
                if (["script", "style"].includes(node.name)) return;
                if (["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "pre", "blockquote", "table"].includes(node.name)) {
                    ordinal++;
                    const value = X.text(node).trim(), blockAt = K.address(at, "block", X.attr(node, "id") || ordinal);
                    if (node.name === "table") {
                        const trs = X.children(node).flatMap(n => n.name === "tr" ? [n] : ["thead", "tbody", "tfoot"].includes(n.name) ? X.children(n, "tr") : []);
                        addTable(rows, "Table " + ordinal, blockAt, trs.map(tr => X.children(tr).filter(n => ["td", "th"].includes(n.name)).map(cell => ({ text: X.text(cell).trim() }))));
                        return;
                    }
                    const isHeading = /^h\d$/.test(node.name);
                    rows.push(K.thing(isHeading ? "Heading " + (++heading) : "Paragraph " + (++paragraph), isHeading ? "heading" : "paragraph", blockAt, value));
                } else node.children.forEach(walk);
            }
            body.children.forEach(walk);
            const blocks = rows.slice(firstBlock), firstHeading = blocks.find(row => row.kind === "heading" && row.text.trim());
            chapter.text = firstHeading ? firstHeading.text : blocks.map(row => row.text).filter(Boolean).join("\n\n");
            if (!chapter.text.trim()) K.fail("EPUB chapter has no readable text: " + part);
            if (X.attr(ref, "linear") === "no") chapter.text = "Outside primary reading order\n" + chapter.text;
        }
        return rows;
    }
    function readFormat(format, request) {
        const material = sense.source.read(K.sourceAddress(request.address)), zip = SenseZip.open(K.bytes(material));
        const base = K.root(material, "file:" + format);
        const rows = ({ docx, xlsx, pptx, epub })[format](zip, base);
        K.publish("file:" + format, base, title(material), rows, request);
    }
    return { readFormat };
})();
// File-declared shape roles, ordered text names, and separate paragraph things.
function read(request) { SenseDocuments.readFormat("pptx", request); }
