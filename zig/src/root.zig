const std = @import("std");

pub const ItemKind = enum(u8) {
    variable = 0,
    function = 1,
    module = 2,
    type_def = 3,
};

/// Row entry for Struct-of-Arrays (SoA) layout
pub const WorkspaceRow = struct {
    name_offset: u32,
    name_len: u32,
    type_offset: u32,
    type_len: u32,
    value_offset: u32,
    value_len: u32,
    expr_offset: u32,
    expr_len: u32,
    parent_index: i32,
    depth: u16,
    kind: ItemKind,
    has_children: bool,
};

pub const StringSpan = struct {
    offset: u32,
    len: u32,
};

fn appendPoolString(pool: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !StringSpan {
    const offset: u32 = @intCast(pool.items.len);
    try pool.appendSlice(allocator, s);
    return .{
        .offset = offset,
        .len = @intCast(s.len),
    };
}

/// Data-Oriented Design (DoD) Workspace Table using Struct-of-Arrays (SoA)
pub const WorkspaceTable = struct {
    rows: std.MultiArrayList(WorkspaceRow),
    string_pool: std.ArrayList(u8),

    pub fn init() WorkspaceTable {
        return .{
            .rows = .{},
            .string_pool = .empty,
        };
    }

    pub fn deinit(self: *WorkspaceTable, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.string_pool.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *WorkspaceTable) void {
        self.rows.shrinkRetainingCapacity(0);
        self.string_pool.clearRetainingCapacity();
    }

    pub fn addString(self: *WorkspaceTable, allocator: std.mem.Allocator, s: []const u8) !StringSpan {
        return appendPoolString(&self.string_pool, allocator, s);
    }

    pub fn getString(self: *const WorkspaceTable, offset: u32, len: u32) []const u8 {
        return self.string_pool.items[offset .. offset + len];
    }

    pub fn addEntry(
        self: *WorkspaceTable,
        allocator: std.mem.Allocator,
        name: []const u8,
        kind: ItemKind,
        type_str: []const u8,
        value_str: []const u8,
        expr_str: []const u8,
        depth: u16,
        parent_index: i32,
        has_children: bool,
    ) !usize {
        const name_span = try self.addString(allocator, name);
        const type_span = try self.addString(allocator, type_str);
        const val_span = try self.addString(allocator, value_str);
        const expr_span = try self.addString(allocator, expr_str);

        const idx = self.rows.len;
        try self.rows.append(allocator, .{
            .name_offset = name_span.offset,
            .name_len = name_span.len,
            .type_offset = type_span.offset,
            .type_len = type_span.len,
            .value_offset = val_span.offset,
            .value_len = val_span.len,
            .expr_offset = expr_span.offset,
            .expr_len = expr_span.len,
            .parent_index = parent_index,
            .depth = depth,
            .kind = kind,
            .has_children = has_children,
        });
        return idx;
    }

    pub fn count(self: *const WorkspaceTable) usize {
        return self.rows.len;
    }

    /// Fast-path filter searching for variable names without decoding unneeded fields (DoD benefit)
    pub fn findByName(self: *const WorkspaceTable, target: []const u8) ?usize {
        const name_offsets = self.rows.items(.name_offset);
        const name_lens = self.rows.items(.name_len);

        for (name_offsets, name_lens, 0..) |offset, len, i| {
            const name = self.string_pool.items[offset .. offset + len];
            if (std.mem.eql(u8, name, target)) {
                return i;
            }
        }
        return null;
    }
};

test "DoD WorkspaceTable SoA and string pool" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var table = WorkspaceTable.init();
    defer table.deinit(allocator);

    _ = try table.addEntry(allocator, "df", .variable, "DataFrame (100 rows)", "100x2 DataFrame", "df", 0, -1, true);
    _ = try table.addEntry(allocator, ":colA", .variable, "Vector{Int64}", "[1, 2, 3...]", "df[!, :colA]", 1, 0, false);
    _ = try table.addEntry(allocator, "calculate", .function, "Function", "(1 method)", "calculate", 0, -1, false);

    try testing.expectEqual(@as(usize, 3), table.count());

    const found_idx = table.findByName(":colA");
    try testing.expect(found_idx != null);
    try testing.expectEqual(@as(usize, 1), found_idx.?);

    const depths = table.rows.items(.depth);
    try testing.expectEqual(@as(u16, 0), depths[0]);
    try testing.expectEqual(@as(u16, 1), depths[1]);
    try testing.expectEqual(@as(u16, 0), depths[2]);
}

pub const ProcOrigin = enum(u8) {
    disk = 0,
    modified = 1,
    live = 2,
    unloaded = 3,
};

pub const ProcStatus = enum(u8) {
    never = 0,
    ok = 1,
    err = 2,
};

/// Row entry for DoD Procedures & Live REPL Functions table (SoA layout)
pub const ProcRow = struct {
    name_offset: u32,
    name_len: u32,
    sig_offset: u32,
    sig_len: u32,
    file_offset: u32,
    file_len: u32,
    disk_hash: u64,
    live_hash: u64,
    last_run_time_ms: f64,
    last_run_alloc_bytes: u64,
    generation: u32,
    func_start_line: u32,
    last_error_line: u32,
    origin: ProcOrigin,
    status: ProcStatus,
};

/// Data-Oriented Design (DoD) Procedure Registry Table backed by a single contiguous string pool
pub const ProcTable = struct {
    rows: std.MultiArrayList(ProcRow),
    string_pool: std.ArrayList(u8),

    pub fn init() ProcTable {
        return .{
            .rows = .{},
            .string_pool = .empty,
        };
    }

    pub fn deinit(self: *ProcTable, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.string_pool.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *ProcTable) void {
        self.rows.shrinkRetainingCapacity(0);
        self.string_pool.clearRetainingCapacity();
    }

    pub fn getString(self: *const ProcTable, offset: u32, len: u32) []const u8 {
        return self.string_pool.items[offset .. offset + len];
    }

    pub fn addEntry(
        self: *ProcTable,
        allocator: std.mem.Allocator,
        name: []const u8,
        sig: []const u8,
        file: []const u8,
        origin: ProcOrigin,
        status: ProcStatus,
        disk_hash: u64,
        live_hash: u64,
        generation: u32,
        func_start_line: u32,
        last_run_time_ms: f64,
        last_run_alloc_bytes: u64,
        last_error_line: u32,
    ) !usize {
        const name_span = try appendPoolString(&self.string_pool, allocator, name);
        const sig_span = try appendPoolString(&self.string_pool, allocator, sig);
        const file_span = try appendPoolString(&self.string_pool, allocator, file);

        const idx = self.rows.len;
        try self.rows.append(allocator, .{
            .name_offset = name_span.offset,
            .name_len = name_span.len,
            .sig_offset = sig_span.offset,
            .sig_len = sig_span.len,
            .file_offset = file_span.offset,
            .file_len = file_span.len,
            .disk_hash = disk_hash,
            .live_hash = live_hash,
            .last_run_time_ms = last_run_time_ms,
            .last_run_alloc_bytes = last_run_alloc_bytes,
            .generation = generation,
            .func_start_line = func_start_line,
            .last_error_line = last_error_line,
            .origin = origin,
            .status = status,
        });
        return idx;
    }

    pub fn count(self: *const ProcTable) usize {
        return self.rows.len;
    }

    /// Cache-friendly name lookup scanning only `name_offset` / `name_len` columns
    pub fn findByName(self: *const ProcTable, target: []const u8) ?usize {
        const name_offsets = self.rows.items(.name_offset);
        const name_lens = self.rows.items(.name_len);
        for (name_offsets, name_lens, 0..) |offset, len, i| {
            if (std.mem.eql(u8, self.string_pool.items[offset .. offset + len], target)) {
                return i;
            }
        }
        return null;
    }

    pub fn countByOrigin(self: *const ProcTable, origin: ProcOrigin) usize {
        var total: usize = 0;
        for (self.rows.items(.origin)) |o| {
            if (o == origin) total += 1;
        }
        return total;
    }

    pub fn countModifiedOrLive(self: *const ProcTable) usize {
        var total: usize = 0;
        for (self.rows.items(.origin)) |o| {
            if (o == .modified or o == .live) total += 1;
        }
        return total;
    }
};

test "DoD ProcTable SoA, origin tracking, and clearRetainingCapacity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var procs = ProcTable.init();
    defer procs.deinit(allocator);

    _ = try procs.addEntry(allocator, "looking_for_plateu", "looking_for_plateu(D, N)", "procedures/looking_for_plateu.jl", .disk, .ok, 0x1111, 0x1111, 1, 14, 0.62, 3056, 0);
    _ = try procs.addEntry(allocator, "looking_for_plateu_v2", "looking_for_plateu_v2(D, N)", "", .live, .never, 0, 0x2222, 1, 1, 0.0, 0, 0);
    _ = try procs.addEntry(allocator, "fit_tau", "fit_tau(x)", "procedures/fit_tau.jl", .modified, .ok, 0x3333, 0x4444, 3, 5, 1.4, 512, 0);

    try testing.expectEqual(@as(usize, 3), procs.count());
    try testing.expectEqual(@as(usize, 1), procs.countByOrigin(.disk));
    try testing.expectEqual(@as(usize, 2), procs.countModifiedOrLive());

    const idx = procs.findByName("fit_tau");
    try testing.expect(idx != null);
    try testing.expectEqual(@as(usize, 2), idx.?);
    try testing.expectEqual(ProcOrigin.modified, procs.rows.items(.origin)[idx.?]);
    try testing.expectEqual(@as(u32, 3), procs.rows.items(.generation)[idx.?]);

    // Reuse capacity cleanly without reallocations
    const pool_cap = procs.string_pool.capacity;
    procs.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), procs.count());
    try testing.expectEqual(pool_cap, procs.string_pool.capacity);

    _ = try procs.addEntry(allocator, "fit_tau", "fit_tau(x)", "procedures/fit_tau.jl", .disk, .ok, 0x3333, 0x3333, 1, 5, 1.1, 512, 0);
    try testing.expectEqual(@as(usize, 0), procs.countModifiedOrLive());
}
