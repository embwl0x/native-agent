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
