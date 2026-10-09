// iWork 2013+ ZIP / Index.zip / IWA. Field numbers follow Apple's archive
// descriptors (TSPArchiveMessages, TN/TP/KN, TST, TSWP), not byte-string guesses.
var SenseIWork = (() => {
    const K = NativeKit, Z = SenseZip, limit = 32 * 1024 * 1024;
    function varint(bytes, cursor) {
        let value = 0n, shift = 0n;
        for (let n = 0; n < 10; n++) {
            if (cursor.p >= bytes.length) K.fail("Truncated protobuf varint");
            const byte = bytes[cursor.p++];
            if (n === 9 && byte > 1) K.fail("Protobuf varint exceeds uint64");
            value |= BigInt(byte & 127) << shift;
            if (!(byte & 128)) return value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : value;
            shift += 7n;
        }
        K.fail("Protobuf varint exceeds uint64");
    }
    function integer(value) {
        if (!Number.isSafeInteger(value) || value < 0) K.fail("Protobuf integer is outside the reader's address range");
        return value;
    }
    function protobuf(bytes) {
        const fields = new Map(), cursor = { p: 0 }; let count = 0;
        while (cursor.p < bytes.length) {
            if (++count > 500000) K.fail("Protobuf field limit exceeded");
            const key = integer(varint(bytes, cursor)), number = Math.floor(key / 8), wire = key & 7;
            if (!number || number > 0x1fffffff) K.fail("Invalid protobuf field number");
            let value;
            if (wire === 0) value = varint(bytes, cursor);
            else if (wire === 1 || wire === 5 || wire === 2) {
                const size = wire === 1 ? 8 : wire === 5 ? 4 : integer(varint(bytes, cursor));
                if (cursor.p + size > bytes.length) K.fail("Truncated protobuf field");
                value = bytes.subarray(cursor.p, cursor.p + size); cursor.p += size;
            } else K.fail("Unsupported protobuf wire type: " + wire);
            if (!fields.has(number)) fields.set(number, []);
            fields.get(number).push(value);
        }
        return fields;
    }
    function values(fields, n) { return fields.get(n) || []; }
    function first(fields, n, fallback) { return values(fields, n)[0] === undefined ? fallback : values(fields, n)[0]; }
    function number(fields, n, fallback = 0) { return integer(first(fields, n, fallback)); }
    function child(fields, n) { const data = first(fields, n); if (!(data instanceof Uint8Array)) K.fail("Missing protobuf message field: " + n); return protobuf(data); }
    function string(fields, n, fallback = "") { const data = first(fields, n); return data === undefined ? fallback : K.utf8(data); }
    function reference(data) { return number(protobuf(data), 1); }
    function refs(fields, n) { return values(fields, n).map(reference); }
    function packedIntegers(fields, n) {
        const out = [];
        for (const value of values(fields, n)) {
            if (!(value instanceof Uint8Array)) { out.push(integer(value)); continue; }
            const cursor = { p: 0 };
            while (cursor.p < value.length) out.push(integer(varint(value, cursor)));
        }
        return out;
    }
    // IWA uses four-byte chunk headers (0 + uint24 length), then raw Snappy;
    // this is Apple's framing, not Google's stream-identifier/checksum framing.
    function snappy(bytes) {
        const cursor = { p: 0 }, size = integer(varint(bytes, cursor));
        if (size > limit) K.fail("Snappy chunk exceeds 32 MiB");
        const out = new Uint8Array(size); let pos = 0;
        function byte() { if (cursor.p >= bytes.length) K.fail("Truncated Snappy tag"); return bytes[cursor.p++]; }
        function little(n) { let v = 0, scale = 1; for (let i = 0; i < n; i++) { v += byte() * scale; scale *= 256; } return v; }
        while (cursor.p < bytes.length) {
            const tag = byte(), type = tag & 3; let count, distance;
            if (type === 0) {
                count = tag >> 2;
                if (count >= 60) count = little(count - 59);
                count++;
                if (cursor.p + count > bytes.length || pos + count > size) K.fail("Invalid Snappy literal bounds");
                out.set(bytes.subarray(cursor.p, cursor.p + count), pos); cursor.p += count; pos += count;
            } else {
                if (type === 1) { count = 4 + ((tag >> 2) & 7); distance = ((tag & 224) << 3) + byte(); }
                else { count = 1 + (tag >> 2); distance = little(type === 2 ? 2 : 4); }
                if (!distance || distance > pos || pos + count > size) K.fail("Invalid Snappy copy bounds");
                for (let n = 0; n < count; n++) { out[pos] = out[pos - distance]; pos++; }
            }
        }
        if (pos !== size) K.fail("Snappy size mismatch");
        return out;
    }
    function unframe(bytes) {
        const parts = []; let p = 0, size = 0;
        while (p < bytes.length) {
            if (p + 4 > bytes.length || bytes[p] !== 0) K.fail("Unsupported IWA chunk framing");
            const n = bytes[p + 1] + 256 * bytes[p + 2] + 65536 * bytes[p + 3]; p += 4;
            if (!n || p + n > bytes.length) K.fail("Truncated IWA chunk");
            const part = snappy(bytes.subarray(p, p + n)); p += n; size += part.length;
            if (size > limit) K.fail("IWA archive exceeds 32 MiB");
            parts.push(part);
        }
        const out = new Uint8Array(size); p = 0;
        for (const part of parts) { out.set(part, p); p += part.length; }
        return out;
    }
    function archive(zip) {
        if (zip.has("Index.zip")) zip = Z.open(zip.get("Index.zip"));
        const names = zip.names.filter(n => /(^|\/)Index\/.*\.iwa$/.test(n) || /^[^/]+\.iwa$/.test(n));
        if (!names.length) K.fail("No IWA archives; legacy iWork XML is unsupported");
        const objects = new Map(); let total = 0;
        for (const name of names) {
            const bytes = unframe(zip.get(name)), cursor = { p: 0 }; total += bytes.length;
            if (total > 128 * 1024 * 1024) K.fail("IWA expansion exceeds 128 MiB");
            while (cursor.p < bytes.length) {
                const size = integer(varint(bytes, cursor));
                if (cursor.p + size > bytes.length) K.fail("Truncated IWA ArchiveInfo");
                const info = protobuf(bytes.subarray(cursor.p, cursor.p + size)); cursor.p += size;
                const id = number(info, 1), messages = [];
                const incremental = number(info, 3) !== 0;
                for (const data of values(info, 2)) {
                    const header = protobuf(data), length = number(header, 3);
                    if (cursor.p + length > bytes.length) K.fail("Truncated IWA message");
                    // View-state archives may contain diffs that have no role in
                    // document content. Decode only objects the content owns.
                    messages.push({ type: number(header, 1), data: bytes.subarray(cursor.p, cursor.p + length),
                        header, refs: packedIntegers(header, 5) });
                    cursor.p += length;
                }
                const previous = objects.get(id);
                objects.set(id, { id, messages, incremental, duplicate: previous !== undefined });
                if (objects.size > K.maximumItems) K.fail("IWA object count exceeds 100,000");
            }
        }
        function get(id, type) {
            const object = objects.get(id);
            if (!object) K.fail("IWA object reference is missing: " + id);
            if (object.incremental || object.duplicate) K.fail("Content IWA object requires incremental merge decoding: " + id);
            const message = type === undefined ? object.messages[0] : object.messages.find(m => m.type === type);
            if (!message) K.fail("IWA object has unexpected archive type: " + id);
            if ([7,8,9,10,11].some(n => message.header.has(n))) K.fail("Content IWA message requires diff decoding: " + id);
            if (!message.fields) message.fields = protobuf(message.data);
            return { id, ...message };
        }
        function contentsUnder(ids, roles) {
            const seen = new Set(), out = [];
            function walk(id, depth, role) {
                if (seen.has(id)) return;
                if (depth > 64 || seen.size > 10000) K.fail("IWA drawable graph exceeds reader limits");
                seen.add(id); const object = get(id);
                // KN.PlaceholderArchive.kind is field 2; only Keynote callers
                // supply roles, since archive type numbers are app-specific.
                if (roles && object.type === 7) {
                    const kinds = { 1: "Slide number", 2: "Title", 3: "Body", 4: "Object" };
                    role = kinds[number(object.fields, 2)] || role;
                }
                if (object.type === 2001 || object.type === 6000) { out.push({ ...object, role }); return; }
                if ([1,2,4,5,6000,6001,10000,10001].includes(object.type)) return;
                // Follow drawable/text ownership, not style/theme references:
                // those can reach masters and material absent from this page.
                object.refs.forEach(next => {
                    const target = objects.get(next);
                    if (!target) K.fail("IWA object reference is missing: " + next);
                    if ([2001,2011,3001,3002,7,6000].includes(target.messages[0].type)) walk(next, depth + 1, role);
                });
            }
            ids.forEach(id => walk(id, 0, roles && roles.get(id))); return out;
        }
        return { get, textUnder: (ids, roles) => contentsUnder(ids, roles).filter(n => n.type === 2001),
            tablesUnder: ids => contentsUnder(ids).filter(n => n.type === 6000) };
    }
    function dataList(book, id, rich) {
        const out = new Map(), seen = new Set();
        function load(id) {
            if (seen.has(id)) K.fail("IWA string-list segment cycle"); seen.add(id);
            const list = book.get(id);
            // A segment's field 2 is Range, while a root list's field 2 is
            // nextListID. Follow only declared segment references, never scan.
            if (list.type !== 6005 && !(first(list.fields, 2) instanceof Uint8Array)) K.fail("Unsupported IWA data-list archive: " + list.type);
            for (const data of values(list.fields, 3)) {
                const entry = protobuf(data), key = number(entry, 1);
                if (out.has(key)) K.fail("Duplicate IWA string-list key");
                if (rich) {
                    const targets = refs(entry, 9).concat(refs(entry, 4));
                    if (!targets.length) K.fail("Missing IWA rich-text reference");
                    const text = book.textUnder(targets).map(n => string(n.fields, 3)).join("\n");
                    out.set(key, text);
                } else out.set(key, string(entry, 3));
            }
            refs(list.fields, 4).forEach(load);
        }
        if (id !== undefined) load(id);
        return out;
    }
    function decimal(bytes, offset) {
        if (offset + 16 > bytes.length) K.fail("Truncated Numbers decimal128");
        const top = bytes[offset + 15];
        if ((top & 0x60) === 0x60) K.fail("Unsupported Numbers decimal128 special value");
        const exponent = ((top & 127) << 7 | bytes[offset + 14] >> 1) - 6176;
        let coefficient = BigInt(bytes[offset + 14] & 1);
        for (let p = 13; p >= 0; p--) coefficient = coefficient * 256n + BigInt(bytes[offset + p]);
        if (!coefficient) return "0";
        let digits = coefficient.toString(), value;
        if (exponent >= 0 && exponent <= 24) value = digits + "0".repeat(exponent);
        else if (exponent < 0 && digits.length + exponent > 0) value = digits.slice(0, digits.length + exponent) + "." + digits.slice(digits.length + exponent);
        else if (exponent < 0 && exponent >= -24) value = "0." + "0".repeat(-exponent - digits.length) + digits;
        else value = digits + "e" + exponent;
        if (value.includes(".")) value = value.replace(/0+$/, "").replace(/\.$/, "");
        return (top & 128 ? "-" : "") + value;
    }
    function cell(bytes, strings, richStrings) {
        if (bytes.length < 12 || bytes[0] !== 5) K.fail("Unsupported Numbers cell storage version: " + bytes[0]);
        const type = bytes[1], flags = Z.u32(bytes, 8); let p = 12, dec, floating, date, str, rich;
        function take(size) { const at = p; p += size; if (p > bytes.length) K.fail("Truncated Numbers cell value"); return at; }
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        if (flags & 1) dec = decimal(bytes, take(16));
        if (flags & 2) floating = view.getFloat64(take(8), true);
        if (flags & 4) date = view.getFloat64(take(8), true);
        if (flags & 8) str = Z.u32(bytes, take(4));
        if (flags & 16) rich = Z.u32(bytes, take(4));
        if (type === 0) return "";
        if (type === 3) { if (!strings.has(str)) K.fail("Missing Numbers string key: " + str); return strings.get(str); }
        if (type === 9) { if (!richStrings.has(rich)) K.fail("Missing Numbers rich-text key: " + rich); return richStrings.get(rich); }
        if (type === 5) {
            if (!Number.isFinite(date)) K.fail("Numbers date has no finite stored value");
            const value = new Date(Date.UTC(2001, 0, 1) + date * 1000);
            if (!Number.isFinite(value.getTime())) K.fail("Numbers date exceeds supported range");
            return value.toISOString() + " (stored date; timezone format not applied)";
        }
        if (type === 6) { if (floating !== 0 && floating !== 1) K.fail("Invalid Numbers boolean"); return floating ? "true" : "false"; }
        if (type === 2 || type === 7) {
            const value = dec === undefined ? floating : dec;
            if (value === undefined || typeof value === "number" && !Number.isFinite(value)) K.fail("Numbers numeric cell has no finite stored value");
            return String(value) + (type === 7 ? " seconds" : "") + " (stored value; formulas are not recalculated)";
        }
        if (type === 8) return "Cell error (stored error code is not decoded).";
        K.fail("Unsupported Numbers cell type: " + type);
    }
    function table(book, modelID, at, rows, withData = false) {
        const model = book.get(modelID, 6001), f = model.fields, store = child(f, 4), tileStorage = child(store, 3);
        const nrows = number(f, 6), ncols = number(f, 7), name = string(f, 8, "Table");
        const tableThing = K.thing(name, "table", at, nrows + " rows × " + ncols + " columns");
        rows.push(tableThing);
        let dataRows = 0, dataColumns = 0;
        const strings = dataList(book, refs(store, 4)[0], false), rich = dataList(book, refs(store, 17)[0], true);
        const tileSize = number(tileStorage, 2, 256), coordinates = new Set();
        if (!tileSize) K.fail("Numbers tile size is zero");
        const tiles = values(tileStorage, 1).map(protobuf).sort((a, b) => number(a, 1) - number(b, 1));
        for (const entry of tiles) {
            const tileID = number(entry, 1), tile = book.get(refs(entry, 2)[0], 6002);
            const rowInfos = values(tile.fields, 5).map(protobuf).sort((a, b) => number(a, 1) - number(b, 1));
            for (const row of rowInfos) {
                const r = tileID * tileSize + number(row, 1), buffer = first(row, 6), offsets = first(row, 7);
                if (!buffer || !offsets) K.fail("Legacy pre-BNC Numbers cell tiles are unsupported");
                if (offsets.length % 2 || r >= nrows) K.fail("Invalid Numbers row bounds");
                const scale = number(row, 8) ? 4 : 1, stored = [];
                for (let c = 0; c < offsets.length / 2; c++) {
                    const offset = Z.u16(offsets, c * 2);
                    if (offset !== 65535) {
                        if (c >= ncols || offset * scale >= buffer.length) K.fail("Invalid Numbers column bounds");
                        stored.push({ c, offset: offset * scale });
                    }
                }
                if (stored.length !== number(row, 2)) K.fail("Numbers row cell count mismatch");
                for (let i = 0; i < stored.length; i++) {
                    const current = stored[i], end = i + 1 < stored.length ? stored[i + 1].offset : buffer.length;
                    if (end <= current.offset) K.fail("Numbers cell offsets are not increasing");
                    const ref = K.column(current.c) + (r + 1);
                    if (coordinates.has(ref)) K.fail("Duplicate Numbers coordinate: " + ref); coordinates.add(ref);
                    const value = cell(buffer.subarray(current.offset, end), strings, rich);
                    if (withData && !value) continue;
                    dataRows = Math.max(dataRows, r + 1); dataColumns = Math.max(dataColumns, current.c + 1);
                    rows.push(K.thing(ref, "cell", K.address(at, "cell", ref), value));
                    if (rows.length > K.maximumItems) K.fail("Numbers document exceeds 100,000 things");
                }
            }
        }
        if (withData) tableThing.text = dataRows + " rows × " + dataColumns + " columns with data";
    }
    function paragraphs(value, name, at, rows) {
        K.paragraphs(value).replace(/\uFFFC/g, "").split("\n").forEach((text, i) => {
            if (text.trim()) rows.push(K.thing(name + ", paragraph " + (i + 1), "paragraph", K.address(at, "paragraph", i + 1), text));
        });
    }
    function addText(book, ids, at, rows, roles) {
        let ordinal = 0;
        for (const text of book.textUnder(ids, roles)) {
            const value = string(text.fields, 3);
            if (value.replace(/\uFFFC/g, "").trim()) paragraphs(value, text.role || "Text " + (++ordinal), K.address(at, "text", text.id), rows);
        }
    }
    function numbers(book, base) {
        const doc = book.get(1, 1), rows = [];
        for (const id of refs(doc.fields, 1)) {
            const sheet = book.get(id, 2), at = K.address(base, "sheet", id), drawables = refs(sheet.fields, 2);
            rows.push(K.thing(string(sheet.fields, 1, "Sheet"), "sheet", at, ""));
            addText(book, drawables, at, rows);
            for (const info of book.tablesUnder(drawables)) {
                const modelID = refs(info.fields, 2)[0], model = book.get(modelID, 6001);
                table(book, modelID, K.address(at, "table", string(model.fields, 1, String(modelID))), rows, true);
            }
        }
        return rows;
    }
    function pages(book, base) {
        const doc = book.get(1), rows = [], bodies = refs(doc.fields, 4), styles = new Map();
        let paragraph = 0;
        if (doc.type !== 10000) K.fail("Unsupported Pages document archive type: " + doc.type);
        function paragraphStyle(id, seen = new Set()) {
            if (styles.has(id)) return styles.get(id);
            if (seen.has(id)) K.fail("Pages paragraph style inheritance cycle");
            seen.add(id);
            // TSWP.ParagraphStyleArchive.super is TSS.StyleArchive; properties
            // inherit through its declared parent, with local values overriding.
            const style = book.get(id, 2022), info = child(style.fields, 1), parent = refs(info, 3)[0];
            const inherited = parent === undefined ? {} : paragraphStyle(parent, seen);
            const properties = style.fields.has(12) ? child(style.fields, 12) : new Map();
            const result = { name: string(info, 1, inherited.name || ""), outline: first(properties, 27, inherited.outline) };
            styles.set(id, result); return result;
        }
        function addParagraphs(storage, at) {
            const value = values(storage.fields, 3).map(K.utf8).join("");
            // StorageArchive.table_para_style is an ObjectAttributeTable of
            // UTF-16 character offsets. An entry without an object clears it.
            const runs = storage.fields.has(5) ? values(child(storage.fields, 5), 1).map(data => {
                const entry = protobuf(data);
                return { offset: number(entry, 1), style: refs(entry, 2)[0] };
            }) : [];
            for (let i = 0; i < runs.length; i++) {
                if (runs[i].offset > value.length || i && runs[i].offset <= runs[i - 1].offset) K.fail("Invalid Pages paragraph style offsets");
            }
            let offset = 0, ordinal = 0, run = 0, styleID;
            // Keep offsets in the original string: CRLF and attachments count
            // toward IWA indices even though the displayed paragraph omits them.
            for (const match of value.matchAll(/([^\r\n\u2028\u2029]*)(\r\n|[\r\n\u2028\u2029]|$)/g)) {
                if (!match[0]) continue;
                ordinal++;
                while (run < runs.length && runs[run].offset <= offset) styleID = runs[run++].style;
                const text = match[1].replace(/\uFFFC/g, ""), style = styleID === undefined ? {} : paragraphStyle(styleID);
                if (text.trim()) {
                    // These are declared paragraph style names, never words in
                    // the document text. UINT32_MAX means no outline level.
                    const title = /^title$/i.test(style.name || "");
                    const heading = /^heading(?:\s+\d+)?$/i.test(style.name || "") || style.outline !== undefined && integer(style.outline) !== 0xffffffff;
                    rows.push(K.thing(title ? "Title" : heading ? "Heading" : "Paragraph " + (++paragraph),
                        title || heading ? "heading" : "paragraph", K.address(at, "paragraph", ordinal), text));
                }
                offset += match[0].length;
            }
        }
        for (const id of bodies) {
            const body = book.get(id, 2001);
            addParagraphs(body, K.address(base, "body", id));
        }
        for (const text of book.textUnder(refs(doc.fields, 3))) addParagraphs(text, K.address(base, "text", text.id));
        const tables = book.tablesUnder(refs(doc.fields, 3).concat(bodies.flatMap(id => book.get(id, 2001).refs)));
        for (const info of tables) {
            const modelID = refs(info.fields, 2)[0], model = book.get(modelID, 6001);
            table(book, modelID, K.address(base, "table", string(model.fields, 1, String(modelID))), rows);
        }
        return rows;
    }
    function keynote(book, base) {
        const rows = [];
        // Slide names and addresses follow the document's slide-tree order.
        const document = book.get(1, 1), show = book.get(refs(document.fields, 2)[0], 2);
        const tree = child(show.fields, 3), nodes = [], seen = new Set();
        function visit(id, depth) {
            if (depth > 64) K.fail("Keynote slide tree exceeds 64 levels");
            if (seen.has(id)) K.fail("Keynote slide tree contains a cycle"); seen.add(id);
            const node = book.get(id, 4); nodes.push(node);
            if (nodes.length > 10000) K.fail("Keynote slide count exceeds 10,000");
            refs(node.fields, 1).forEach(next => visit(next, depth + 1));
        }
        refs(tree, 2).forEach(id => visit(id, 0));
        if (!nodes.length) K.fail("Keynote has no supported slide-node archives");
        let slideNumber = 0;
        for (const node of nodes) {
            const slideID = refs(node.fields, 2)[0], slide = book.get(slideID, 5);
            if (!number(slide.fields, 19, 1)) continue;
            const at = K.address(base, "slide", ++slideNumber);
            const name = string(slide.fields, 10);
            rows.push(K.thing("Slide " + slideNumber, "slide", at, [name, number(node.fields, 4) ? "Skipped slide" : ""].filter(Boolean).join("\n")));
            const drawables = [...new Set([7,5,6,20,30,42].flatMap(n => refs(slide.fields, n)))];
            const roles = new Map();
            for (const [field, role] of [[5, "Title"], [6, "Body"], [20, "Slide number"], [30, "Object"]]) {
                refs(slide.fields, field).forEach(id => roles.set(id, role));
            }
            addText(book, drawables, at, rows, roles);
            addText(book, refs(slide.fields, 27), K.address(at, "notes"), rows);
            for (const info of book.tablesUnder(drawables)) {
                const modelID = refs(info.fields, 2)[0]; table(book, modelID, K.address(at, "table", modelID), rows);
            }
        }
        return rows;
    }
    function readFormat(format, request) {
        const material = sense.source.read(K.sourceAddress(request.address)), base = K.root(material, "file:" + format);
        const book = archive(Z.open(K.bytes(material))), rows = ({ numbers, pages, key: keynote })[format](book, base);
        K.publish("file:" + format, base, material.path.split("/").pop(), rows, request);
    }
    return { varint, protobuf, snappy, unframe, archive, readFormat };
})();
