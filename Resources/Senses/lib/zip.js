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
