// File-declared shape roles, ordered text names, and separate paragraph things.
var read = (() => {
    const K = NativeKit, X = SenseXML, addTable = SenseDocuments.addTable;
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
    return request => SenseDocuments.readFormat("pptx", request, pptx);
})();
