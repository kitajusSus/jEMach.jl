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

    pub fn addString(self: *WorkspaceTable, allocator: std.mem.Allocator, s: []const u8) !struct { offset: u32, len: u32 } {
        const offset: u32 = @intCast(self.string_pool.items.len);
        try self.string_pool.appendSlice(allocator, s);
        return .{
            .offset = offset,
            .len = @intCast(s.len),
        };
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
