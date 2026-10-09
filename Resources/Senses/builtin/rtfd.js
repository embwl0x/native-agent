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
var SenseRTF = (() => {
    const K = NativeKit;
    const cp1252 = "€\u0081‚ƒ„…†‡ˆ‰Š‹Œ\u008dŽ\u008f\u0090‘’“”•–—˜™š›œ\u009džŸ";
    function character(code, page) {
        if (code < 128) return String.fromCharCode(code);
        if (page !== 1252) K.fail("Unsupported RTF code page: " + page);
        return code < 160 ? cp1252[code - 128] : String.fromCharCode(code);
    }
    function extract(bytes, structured = false) {
        let raw = "";
        for (const byte of bytes) raw += String.fromCharCode(byte);
        if (!/^\{\\rtf1\b/.test(raw)) K.fail("Not an RTF version 1 document");
        let state = { skip: false, uc: 1, page: 1252, ignorable: false }, stack = [], output = "", fallback = 0;
        const blocks = []; let paragraph = "", table = [], cells = [], cellText = "", inRow = false;
        function flushParagraph() { if (paragraph) blocks.push({ text: paragraph }); paragraph = ""; }
        function flushTable() { if (table.length) blocks.push({ table }); table = []; }
        function append(text) {
            output += text;
            if (inRow) cellText += text;
            else { flushTable(); paragraph += text; }
        }
        const destinations = new Set(["fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "objdata", "filetbl", "listtable", "listoverridetable", "revtbl", "rsidtbl", "generator", "fldinst", "datastore", "themedata", "colorschememapping", "xmlnstbl"]);
        function emit(text) { if (fallback) { fallback--; return; } if (!state.skip) append(text); }
        for (let p = 0; p < raw.length;) {
            const ch = raw[p++];
            if (ch === "{") { if (stack.length >= 128) K.fail("RTF group depth exceeds 128"); stack.push(state); state = { ...state }; continue; }
            if (ch === "}") { if (!stack.length) K.fail("Unbalanced RTF group"); state = stack.pop(); continue; }
            if (ch === "\n" || ch === "\r") continue;
            if (ch !== "\\") { emit(character(ch.charCodeAt(0), state.page)); continue; }
            if (p >= raw.length) K.fail("Truncated RTF escape");
            const next = raw[p];
            if (next === "'") {
                const hex = raw.slice(p + 1, p + 3);
                if (!/^[a-f\d]{2}$/i.test(hex)) K.fail("Malformed RTF hex escape");
                emit(character(parseInt(hex, 16), state.page)); p += 3; continue;
            }
            if (!/[a-z]/i.test(next)) {
                p++;
                if (next === "*") state.ignorable = true;
                else if (next === "\n" || next === "\r") {
                    if (next === "\r" && raw[p] === "\n") p++;
                    if (!state.skip) { if (inRow) emit("\n"); else { output += "\n"; flushParagraph(); } }
                }
                else if (next === "~") emit("\u00a0");
                else if (next === "_") emit("\u2011");
                else if (next === "-") emit("\u00ad");
                else if ("{}\\".includes(next)) emit(next);
                continue;
            }
            const token = /^([a-z]+)(-?\d+)? ?/i.exec(raw.slice(p));
            if (!token) K.fail("Malformed RTF control word");
            p += token[0].length; const word = token[1], arg = token[2] === undefined ? undefined : Number(token[2]);
            if (state.ignorable || destinations.has(word)) { state.skip = true; state.ignorable = false; }
            if (word === "bin") { if (!Number.isInteger(arg) || arg < 0 || p + arg > raw.length) K.fail("Invalid RTF binary length"); p += arg; }
            else if (word === "ansicpg") { if (arg !== 1252) K.fail("Unsupported RTF code page: " + arg); state.page = arg; }
            else if (["mac", "pc", "pca"].includes(word)) K.fail("Unsupported RTF character set: " + word);
            else if (word === "uc") { if (!Number.isInteger(arg) || arg < 0 || arg > 16) K.fail("Invalid RTF Unicode fallback length"); state.uc = arg; }
            else if (word === "u") {
                if (!Number.isInteger(arg) || arg < -32768 || arg > 65535) K.fail("Invalid RTF Unicode value");
                if (!state.skip) append(String.fromCharCode(arg < 0 ? arg + 65536 : arg));
                fallback = state.uc;
            } else if (!state.skip && (word === "trowd" || word === "intbl" && arg !== 0)) {
                if (!inRow) { flushParagraph(); inRow = true; }
            } else if (!state.skip && word === "cell") {
                if (!inRow) K.fail("RTF table cell has no row");
                output += "\t"; cells.push(cellText); cellText = "";
            } else if (!state.skip && word === "row") {
                if (!inRow) K.fail("RTF table row has no start");
                if (cellText || !cells.length) cells.push(cellText);
                output += "\n"; table.push(cells); cells = []; cellText = ""; inRow = false;
            } else if (!state.skip && (word === "nestcell" || word === "nestrow" || word === "itap" && arg > 1)) K.fail("Nested RTF tables are unsupported");
            else if (word === "par" || word === "line") {
                if (inRow) emit("\n");
                else if (!state.skip) { output += "\n"; flushParagraph(); }
            } else if (word === "tab") emit("\t");
            else if (word === "emdash") emit("—");
            else if (word === "endash") emit("–");
            else if (word === "bullet") emit("•");
            else if (word === "lquote") emit("‘");
            else if (word === "rquote") emit("’");
            else if (word === "ldblquote") emit("“");
            else if (word === "rdblquote") emit("”");
        }
        if (stack.length) K.fail("Truncated RTF group");
        if (inRow) K.fail("Truncated RTF table row");
        flushParagraph(); flushTable();
        return structured ? blocks : output;
    }
    function readFormat(format, request) {
        const material = sense.source.read(K.sourceAddress(request.address)), base = K.root(material, "file:" + format);
        let data = K.bytes(material), attachments = [];
        if (format === "rtfd") {
            const zip = SenseZip.open(data), parts = zip.names.filter(n => /(^|\/)TXT\.rtf$/i.test(n));
            if (parts.length !== 1) K.fail("RTFD needs exactly one TXT.rtf package member");
            data = zip.get(parts[0]);
            attachments = zip.names.filter(n => !n.endsWith("/") && n !== parts[0]).map(n => K.thing(n, "attachment", K.address(base, "attachment", n), "Attachment bytes are not rendered."));
        }
        const rows = []; let paragraph = 0, table = 0;
        for (const block of extract(data, true)) {
            if (!block.table) {
                rows.push(K.thing("Paragraph " + (++paragraph), "paragraph", K.address(base, "paragraph", paragraph), block.text));
                continue;
            }
            const at = K.address(base, "table", ++table);
            const lines = block.table.map(row => row.map(text => text.replace(/\s+/g, " ").trim()).join(" | "));
            rows.push(K.thing("Table " + table, "table", at, lines.join("\n")));
            block.table.forEach((row, r) => {
                const rowAt = K.address(at, "row", r + 1);
                rows.push(K.thing("Row " + (r + 1), "row", rowAt, lines[r]));
                row.forEach((text, c) => rows.push(K.thing("Row " + (r + 1) + ", cell " + (c + 1), "cell", K.address(rowAt, "cell", c + 1), text)));
            });
        }
        K.publish("file:" + format, base, material.path.split("/").pop(), rows.concat(attachments), request);
    }
    return { extract, readFormat };
})();
function read(request) { SenseRTF.readFormat("rtfd", request); }
