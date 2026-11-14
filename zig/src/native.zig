const std = @import("std");

const skip_exact = [_][]const u8{
    "jEMach",
    "exit()",
    "quit()",
    "clear()",
    "ans",
};

const skip_substr = [_][]const u8{
    "jEMach.",
    "save_clean_session",
    "inspect_var",
    "publish_state",
};

const api_prefixes = [_][]const u8{
    "@jemach",
    "@inspect",
    "record(",
    "record_stop(",
    "workspace(",
    "list_procedures(",
    "find_procedures(",
    "search_procedures(",
    "autoload_procedures!(",
    "make_procedure(",
    "using jEMach",
    "import jEMach",
};

inline fn isAsciiWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

inline fn trimAscii(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and isAsciiWs(s[a])) : (a += 1) {}
    while (b > a and isAsciiWs(s[b - 1])) : (b -= 1) {}
    return s[a..b];
}

inline fn rtrimLen(s: []const u8) usize {
    var b: usize = s.len;
    while (b > 0 and isAsciiWs(s[b - 1])) : (b -= 1) {}
    return b;
}

inline fn eqlIgnoreCaseAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn isValidUserCmd(cmd: []const u8) bool {
    const s = trimAscii(cmd);
    if (s.len == 0) return false;

    for (skip_exact) |ex| {
        if (std.mem.eql(u8, s, ex)) return false;
    }
    for (skip_substr) |sub| {
        if (std.mem.indexOf(u8, s, sub) != null) return false;
    }
    for (api_prefixes) |pfx| {
        if (std.mem.startsWith(u8, s, pfx)) return false;
    }
    return true;
}

fn reverseSliceU32(s: []u32) void {
    var l: usize = 0;
    var r: usize = s.len;
    while (l + 1 < r) {
        r -= 1;
        const tmp = s[l];
        s[l] = s[r];
        s[r] = tmp;
        l += 1;
    }
}

fn rotateLeftU32(s: []u32, k: usize) void {
    if (s.len <= 1) return;
    const shift = k % s.len;
    if (shift == 0) return;
    reverseSliceU32(s[0..shift]);
    reverseSliceU32(s[shift..]);
    reverseSliceU32(s);
}

/// Parses Julia `repl_history.jl` raw byte slices in a single zero-allocation linear pass.
/// Keeps up to `max_cmds` most recent valid Julia-mode commands, unpacked into `out_buf`,
/// and records chronological `(offset, len)` pairs in `out_offsets` / `out_lens`.
/// Returns number of commands written (>= 0), or -1 if `out_buf` capacity is exceeded.
export fn jemach_parse_history_buf(
    src_ptr: [*]const u8,
    src_len: usize,
    skip_partial_first: u8,
    max_cmds: usize,
    out_buf: [*]u8,
    out_cap: usize,
    out_offsets: [*]u32,
    out_lens: [*]u32,
) callconv(.c) i64 {
    if (src_len == 0 or max_cmds == 0) return 0;

    const src = src_ptr[0..src_len];
    var i: usize = 0;
    if (skip_partial_first != 0) {
        if (std.mem.indexOfScalar(u8, src, '\n')) |nl| {
            i = nl + 1;
        } else {
            return 0;
        }
    }

    var block_is_julia: bool = true;
    var block_start: usize = 0;
    var out_pos: usize = 0;
    var block_has_line: bool = false;
    var total_valid: usize = 0;

    while (i < src_len) {
        const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src_len;
        const line = src[i..nl];
        i = nl + 1;

        if (std.mem.startsWith(u8, line, "# time:")) {
            if (block_has_line and block_is_julia) {
                const tlen = rtrimLen(out_buf[block_start..out_pos]);
                const trimmed = out_buf[block_start .. block_start + tlen];
                if (isValidUserCmd(trimmed)) {
                    const slot = total_valid % max_cmds;
                    out_offsets[slot] = @intCast(block_start);
                    out_lens[slot] = @intCast(tlen);
                    total_valid += 1;
                    out_pos = block_start + tlen;
                } else {
                    out_pos = block_start;
                }
            } else {
                out_pos = block_start;
            }
            block_is_julia = true;
            block_start = out_pos;
            block_has_line = false;
        } else if (std.mem.startsWith(u8, line, "# mode:")) {
            const mode_val = trimAscii(line[7..]);
            block_is_julia = eqlIgnoreCaseAscii(mode_val, "julia");
        } else if (line.len == 0 or line[0] != '#') {
            const clean = if (line.len > 0 and line[0] == '\t') line[1..] else line;
            const need = clean.len + @as(usize, if (block_has_line) 1 else 0);
            if (out_pos + need > out_cap) return -1;
            if (block_has_line) {
                out_buf[out_pos] = '\n';
                out_pos += 1;
            }
            if (clean.len > 0) {
                @memcpy(out_buf[out_pos .. out_pos + clean.len], clean);
                out_pos += clean.len;
            }
            block_has_line = true;
        }
    }

    if (block_has_line and block_is_julia) {
        const tlen = rtrimLen(out_buf[block_start..out_pos]);
        const trimmed = out_buf[block_start .. block_start + tlen];
        if (isValidUserCmd(trimmed)) {
            const slot = total_valid % max_cmds;
            out_offsets[slot] = @intCast(block_start);
            out_lens[slot] = @intCast(tlen);
            total_valid += 1;
        }
    }

    if (total_valid > max_cmds) {
        const start_slot = total_valid % max_cmds;
        rotateLeftU32(out_offsets[0..max_cmds], start_slot);
        rotateLeftU32(out_lens[0..max_cmds], start_slot);
        return @intCast(max_cmds);
    }
    return @intCast(total_valid);
}

const hex_digits = "0123456789abcdef";

/// Writes `"` + JSON-escaped `src[0..src_len]` + `"` into `dst[0..dst_cap]` using 16-byte SIMD fast scans.
/// Returns bytes written (>= 2), or -1 if `dst_cap` is smaller than worst-case (`6 * src_len + 2`).
export fn jemach_escape_json_str(
    src_ptr: [*]const u8,
    src_len: usize,
    dst_ptr: [*]u8,
    dst_cap: usize,
) callconv(.c) i64 {
    if (dst_cap < src_len * 6 + 2) return -1;

    const src = src_ptr[0..src_len];
    var o: usize = 0;
    dst_ptr[o] = '"';
    o += 1;

    var i: usize = 0;
    const Vec = @Vector(16, u8);
    const v_space: Vec = @splat(0x20);
    const v_quote: Vec = @splat('"');
    const v_bslash: Vec = @splat('\\');

    while (i + 16 <= src_len) {
        const chunk: Vec = src[i..][0..16].*;
        const m_ctrl = chunk < v_space;
        const m_quote = chunk == v_quote;
        const m_bslash = chunk == v_bslash;
        const m_any = m_ctrl | m_quote | m_bslash;
        if (!@reduce(.Or, m_any)) {
            dst_ptr[o..][0..16].* = chunk;
            o += 16;
            i += 16;
            continue;
        }
        // Fallback through scalar for this 16-byte chunk
        const chunk_end = i + 16;
        while (i < chunk_end) : (i += 1) {
            const c = src[i];
            if (c >= 0x20 and c != '"' and c != '\\') {
                dst_ptr[o] = c;
                o += 1;
            } else {
                o = writeEscapedByte(dst_ptr, o, c);
            }
        }
    }

    while (i < src_len) : (i += 1) {
        const c = src[i];
        if (c >= 0x20 and c != '"' and c != '\\') {
            dst_ptr[o] = c;
            o += 1;
        } else {
            o = writeEscapedByte(dst_ptr, o, c);
        }
    }

    dst_ptr[o] = '"';
    o += 1;
    return @intCast(o);
}

inline fn writeEscapedByte(dst_ptr: [*]u8, o: usize, c: u8) usize {
    switch (c) {
        '"' => {
            dst_ptr[o] = '\\';
            dst_ptr[o + 1] = '"';
            return o + 2;
        },
        '\\' => {
            dst_ptr[o] = '\\';
            dst_ptr[o + 1] = '\\';
            return o + 2;
        },
        '\n' => {
            dst_ptr[o] = '\\';
            dst_ptr[o + 1] = 'n';
            return o + 2;
        },
        '\r' => {
            dst_ptr[o] = '\\';
            dst_ptr[o + 1] = 'r';
            return o + 2;
        },
        '\t' => {
            dst_ptr[o] = '\\';
            dst_ptr[o + 1] = 't';
            return o + 2;
        },
        0x08 => {
            dst_ptr[o] = '\\';
            dst_ptr[o + 1] = 'b';
            return o + 2;
        },
        0x0c => {
            dst_ptr[o] = '\\';
            dst_ptr[o + 1] = 'f';
            return o + 2;
        },
        else => {
            dst_ptr[o] = '\\';
            dst_ptr[o + 1] = 'u';
            dst_ptr[o + 2] = '0';
            dst_ptr[o + 3] = '0';
            dst_ptr[o + 4] = hex_digits[c >> 4];
            dst_ptr[o + 5] = hex_digits[c & 0x0f];
            return o + 6;
        },
    }
}

test "jemach_parse_history_buf basic and ring wrap" {
    const testing = std.testing;
    const sample =
        "partial_junk_line\n" ++
        "# time: 2026-11-14 10:00:00 CET\n" ++
        "# mode: julia\n" ++
        "\ta = 1\n" ++
        "# time: 2026-11-14 10:00:01 CET\n" ++
        "# mode: jemach\n" ++
        "\tls\n" ++
        "# time: 2026-11-14 10:00:02 CET\n" ++
        "# mode: julia\n" ++
        "\t@jemach ls\n" ++
        "# time: 2026-11-14 10:00:03 CET\n" ++
        "# mode: julia\n" ++
        "\tfor i in 1:3\n" ++
        "\t    b = a + i\n" ++
        "\tend\n" ++
        "# time: 2026-11-14 10:00:04 CET\n" ++
        "# mode: julia\n" ++
        "\tc = 99\n";

    var out_buf: [1024]u8 = undefined;
    var offsets: [2]u32 = undefined;
    var lens: [2]u32 = undefined;

    const n = jemach_parse_history_buf(
        sample.ptr,
        sample.len,
        1,
        2,
        &out_buf,
        out_buf.len,
        &offsets,
        &lens,
    );
    try testing.expectEqual(@as(i64, 2), n);
    try testing.expectEqualStrings("for i in 1:3\n    b = a + i\nend", out_buf[offsets[0] .. offsets[0] + lens[0]]);
    try testing.expectEqualStrings("c = 99", out_buf[offsets[1] .. offsets[1] + lens[1]]);
}

test "jemach_escape_json_str simd and escapes" {
    const testing = std.testing;
    const s = "hello \"world\" \\ path\nline2\t\x01end_long_ascii_tail_0123456789";
    var dst: [512]u8 = undefined;
    const n = jemach_escape_json_str(s.ptr, s.len, &dst, dst.len);
    try testing.expect(n > 0);
    const out = dst[0..@intCast(n)];
    try testing.expectEqualStrings("\"hello \\\"world\\\" \\\\ path\\nline2\\t\\u0001end_long_ascii_tail_0123456789\"", out);
}
