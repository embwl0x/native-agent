var SenseZip = (() => {
    const fail = NativeKit.fail, limit = 32 * 1024 * 1024;
    function u16(b, p) { if (p + 2 > b.length) fail("Truncated ZIP integer"); return b[p] | b[p + 1] << 8; }
    function u32(b, p) { return (u16(b, p) + u16(b, p + 2) * 65536) >>> 0; }
    const {inflate, crc32} = sense.bytes;
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
