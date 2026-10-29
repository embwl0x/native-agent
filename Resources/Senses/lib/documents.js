var SenseDocuments = (() => {
    const K = NativeKit;
    function title(material) { return material.path.split("/").pop(); }
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
    function readFormat(format, request, parse) {
        const material = sense.source.read(K.sourceAddress(request.address)), zip = SenseZip.open(K.bytes(material));
        const base = K.root(material, "file:" + format);
        const rows = parse(zip, base);
        K.publish("file:" + format, base, title(material), rows, request);
    }
    return { readFormat, addTable };
})();
