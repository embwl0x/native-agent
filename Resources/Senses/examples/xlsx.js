var read = (() => {
    const K = NativeKit, X = SenseXML;
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
    return request => SenseDocuments.readFormat("xlsx", request, xlsx);
})();
