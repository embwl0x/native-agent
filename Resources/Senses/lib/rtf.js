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
