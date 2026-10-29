// Tables print once; rows and cells remain addressed things for focused reads.
var read = (() => {
    const K = NativeKit, X = SenseXML, addTable = SenseDocuments.addTable;
    function wordText(node) {
        if (typeof node === "string") return "";
        if (["del", "instrText"].includes(node.name)) return "";
        if (node.name === "t") return X.text(node);
        if (node.name === "tab") return "\t";
        if (["br", "cr"].includes(node.name)) return "\n";
        return node.children.map(wordText).join("");
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
    return request => SenseDocuments.readFormat("docx", request, docx);
})();
