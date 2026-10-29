var read = (() => {
    const K = NativeKit, X = SenseXML, addTable = SenseDocuments.addTable;
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
    return request => SenseDocuments.readFormat("epub", request, epub);
})();
