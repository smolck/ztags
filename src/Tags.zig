const std = @import("std");

const Tags = @This();

const EntryList = std.ArrayListUnmanaged(Entry);

const Kind = enum {
    function,
    field,
    @"struct",
    @"enum",
    @"union",
    variable,
    constant,

    fn parse(text: []const u8) ?Kind {
        return if (std.mem.eql(u8, text, "function"))
            .function
        else if (std.mem.eql(u8, text, "field"))
            .field
        else if (std.mem.eql(u8, text, "struct"))
            .@"struct"
        else if (std.mem.eql(u8, text, "enum"))
            .@"enum"
        else if (std.mem.eql(u8, text, "union"))
            .@"union"
        else if (std.mem.eql(u8, text, "variable"))
            .variable
        else if (std.mem.eql(u8, text, "constant"))
            .constant
        else
            null;
    }

    test "Kind.parse" {
        inline for (@typeInfo(Kind).Enum.fields) |field| {
            const parsed = Kind.parse(field.name) orelse {
                std.debug.print("Kind variant \"{s}\" missing in Kind.parse()\n", .{field.name});
                return error.MissingParseVariant;
            };
            try std.testing.expectEqual(parsed, @intToEnum(Kind, field.value));
        }
    }
};

const Entry = struct {
    ident: []const u8,
    filename: []const u8,
    text: []const u8,
    kind: Kind,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.ident);
        allocator.free(self.text);
    }

    fn eql(self: Entry, other: Entry) bool {
        return std.mem.eql(u8, self.ident, other.ident) and
            std.mem.eql(u8, self.filename, other.filename) and
            std.mem.eql(u8, self.text, other.text) and
            self.kind == other.kind;
    }
};

allocator: std.mem.Allocator,
entries: EntryList,
visited: std.StringHashMap(void),

pub fn init(allocator: std.mem.Allocator) Tags {
    return Tags{
        .allocator = allocator,
        .entries = .{},
        .visited = std.StringHashMap(void).init(allocator),
    };
}

pub fn deinit(self: *Tags) void {
    for (self.entries.items) |entry| {
        entry.deinit(self.allocator);
    }

    self.entries.deinit(self.allocator);

    var it = self.visited.keyIterator();
    while (it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.visited.deinit();
}

pub fn findTags(self: *Tags, fname: []const u8) anyerror!void {
    const gop = try self.visited.getOrPut(fname);
    if (gop.found_existing) {
        return;
    }
    gop.value_ptr.* = {};

    const mapped = a: {
        var file = try std.fs.cwd().openFile(fname, .{});
        defer file.close();

        const metadata = try file.metadata();
        const size = metadata.size();
        if (size == 0) {
            return;
        }

        if (metadata.kind() == .Directory) {
            return error.NotFile;
        }

        break :a try std.os.mmap(null, size, std.os.PROT.READ, std.os.MAP.SHARED, file.handle, 0);
    };
    defer std.os.munmap(mapped);

    const source = std.meta.assumeSentinel(mapped, 0);

    var allocator = self.allocator;
    var ast = try std.zig.parse(allocator, source);
    defer ast.deinit(allocator);

    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    const tags = ast.nodes.items(.tag);
    const tokens = ast.nodes.items(.main_token);
    const data = ast.nodes.items(.data);
    for (tags) |node, i| {
        var ident: ?[]const u8 = null;
        var kind: ?Kind = null;

        switch (node) {
            .builtin_call_two => {
                const builtin = ast.tokenSlice(tokens[i]);
                if (std.mem.eql(u8, builtin[1..], "import")) {
                    const name_index = tokens[data[i].lhs];
                    const name = std.mem.trim(u8, ast.tokenSlice(name_index), "\"");
                    if (std.mem.endsWith(u8, name, ".zig")) {
                        const dir = std.fs.path.dirname(fname) orelse continue;
                        const import_fname = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{
                            dir,
                            name,
                        });

                        const resolved = try std.fs.path.resolve(allocator, &.{import_fname});
                        self.findTags(resolved) catch |err| switch (err) {
                            error.FileNotFound => continue,
                            else => return err,
                        };
                    }
                }
                continue;
            },
            .fn_decl => {
                ident = ast.tokenSlice(tokens[i] + 1);
                kind = .function;
            },
            .global_var_decl,
            .simple_var_decl,
            .local_var_decl,
            .aligned_var_decl,
            => {
                var name = ast.tokenSlice(tokens[i] + 1);
                if (std.mem.eql(u8, name, "_")) {
                    continue;
                }
                if (std.mem.startsWith(u8, name, "@\"")) {
                    name = std.mem.trim(u8, name[1..], "\"");
                }

                ident = name;
                kind = if (std.mem.eql(u8, ast.tokenSlice(tokens[i]), "const"))
                    .constant
                else
                    .variable;

                switch (data[i].rhs) {
                    0 => {},
                    else => |rhs| switch (tags[rhs]) {
                        .container_decl,
                        .container_decl_trailing,
                        .container_decl_two,
                        .container_decl_two_trailing,
                        .container_decl_arg,
                        .container_decl_arg_trailing,
                        => {
                            const container_type = ast.tokenSlice(tokens[rhs]);
                            kind = switch (container_type[0]) {
                                's' => .@"struct",
                                'e' => .@"enum",
                                'u' => .@"union",
                                else => continue,
                            };
                        },
                        .tagged_union,
                        .tagged_union_trailing,
                        .tagged_union_two,
                        .tagged_union_two_trailing,
                        .tagged_union_enum_tag,
                        .tagged_union_enum_tag_trailing,
                        => kind = .@"union",
                        .builtin_call_two => if (std.mem.eql(u8, ast.tokenSlice(tokens[rhs]), "@import")) {
                            // Ignore variables of the form
                            //   const foo = @import("foo");
                            // Having these as tags is generally not useful and creates a lot of
                            // redundant noise
                            continue;
                        },
                        .field_access => {
                            // Ignore variables of the form
                            //      const foo = SomeContainer.foo
                            // i.e. when the name of the variable is just an alias to some field
                            const identifier_token = ast.tokenSlice(data[rhs].rhs);
                            if (std.mem.eql(u8, identifier_token, name)) {
                                continue;
                            }
                        },
                        else => {},
                    },
                }
            },
            .container_field_init,
            .container_field_align,
            .container_field,
            => {
                var name = ast.tokenSlice(tokens[i]);
                if (std.mem.eql(u8, name, "_")) {
                    continue;
                }
                if (std.mem.startsWith(u8, name, "@\"")) {
                    name = std.mem.trim(u8, name[1..], "\"");
                }
                ident = name;
                kind = .field;
            },
            else => continue,
        }

        try self.entries.append(allocator, .{
            .ident = try allocator.dupe(u8, ident.?),
            .filename = fname,
            .kind = kind.?,
            .text = try getNodeText(allocator, ast, @intCast(u32, i)),
        });
    }
}

/// Read tags entries from a tags file
pub fn read(self: *Tags, data: []const u8) !void {
    var lines = std.mem.tokenize(u8, data, "\n");
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '!') {
            continue;
        }

        var ident: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var text: ?[]const u8 = null;
        var kind: ?Kind = null;

        var i: usize = 0;
        var fields = std.mem.tokenize(u8, line, "\t");
        while (fields.next()) |field| : (i += 1) {
            switch (i) {
                0 => ident = field,
                1 => filename = field,
                2 => text = text: {
                    var slice = field;
                    if (slice.len > 0 and slice[0] == '/') {
                        slice = slice[1..];
                    }

                    if (std.mem.lastIndexOf(u8, slice, "/;\"")) |j| {
                        slice = slice[0..j];
                    }

                    break :text slice;
                },
                3 => kind = Kind.parse(field),
                else => break,
            }
        }

        if (ident == null or filename == null or text == null or kind == null) {
            continue;
        }

        ident = try self.allocator.dupe(u8, ident.?);
        errdefer self.allocator.free(ident.?);

        const gop = try self.visited.getOrPut(filename.?);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, filename.?);
            gop.value_ptr.* = {};
        }
        filename = gop.key_ptr.*;

        text = try std.mem.replaceOwned(u8, self.allocator, text.?, "\\/", "/");
        errdefer self.allocator.free(text.?);

        try self.entries.append(self.allocator, .{
            .ident = ident.?,
            .filename = filename.?,
            .text = text.?,
            .kind = kind.?,
        });
    }
}

pub fn write(self: *Tags, relative: bool) ![]const u8 {
    var contents = std.ArrayList(u8).init(self.allocator);
    defer contents.deinit();

    var writer = contents.writer();

    try writer.writeAll(
        \\!_TAG_FILE_SORTED	1	/1 = sorted/
        \\!_TAG_FILE_ENCODING	utf-8
        \\
    );

    self.entries = try removeDuplicates(self.allocator, &self.entries);

    const cwd = if (relative)
        try std.fs.realpathAlloc(self.allocator, ".")
    else
        null;
    defer if (cwd) |c| self.allocator.free(c);

    // Cache relative paths to avoid recalculating for the same absolute path. If the relative paths
    // option is not enabled this has no cost other than some stack space and a couple of no-op
    // function calls
    var relative_paths = std.StringHashMap([]const u8).init(self.allocator);
    defer {
        var it = relative_paths.valueIterator();
        while (it.next()) |val| self.allocator.free(val.*);
        relative_paths.deinit();
    }

    for (self.entries.items) |entry| {
        const text = try escape(self.allocator, entry.text);
        defer if (text.ptr != entry.text.ptr) self.allocator.free(text);

        const filename = if (cwd) |c| filename: {
            const gop = try relative_paths.getOrPut(entry.filename);
            if (!gop.found_existing) {
                gop.value_ptr.* = try std.fs.path.relative(self.allocator, c, entry.filename);
            }

            break :filename gop.value_ptr.*;
        } else entry.filename;

        try writer.print("{s}\t{s}\t/{s}/;\"\t{s}\n", .{
            entry.ident,
            filename,
            text,
            @tagName(entry.kind),
        });
    }

    return try contents.toOwnedSlice();
}

fn removeDuplicates(allocator: std.mem.Allocator, orig: *EntryList) !EntryList {
    std.sort.sort(Entry, orig.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return switch (std.mem.order(u8, a.ident, b.ident)) {
                .lt => true,
                .gt => false,
                .eq => switch (std.mem.order(u8, a.filename, b.filename)) {
                    .lt => true,
                    .gt => false,
                    .eq => std.mem.lessThan(u8, a.text, b.text),
                },
            };
        }
    }.lessThan);
    defer orig.deinit(allocator);

    var deduplicated_entries = EntryList{};

    var last_unique: usize = 0;
    for (orig.items) |entry, i| {
        if (i == 0 or !orig.items[last_unique].eql(entry)) {
            try deduplicated_entries.append(allocator, entry);
            last_unique = i;
        } else {
            entry.deinit(allocator);
        }
    }

    return deduplicated_entries;
}

test "removeDuplicates" {
    var allocator = std.testing.allocator;
    const input = [_]Entry{
        .{
            .ident = try allocator.dupe(u8, "foo"),
            .filename = "foo.zig",
            .text = try allocator.dupe(u8, "hi this is foo"),
            .kind = .variable,
        },
        .{
            .ident = try allocator.dupe(u8, "foo"),
            .filename = "foo.zig",
            .text = try allocator.dupe(u8, "hi this is foo"),
            .kind = .variable,
        },
        .{
            .ident = try allocator.dupe(u8, "bar"),
            .filename = "foo.zig",
            .text = try allocator.dupe(u8, "hi this is bar"),
            .kind = .variable,
        },
        .{
            .ident = try allocator.dupe(u8, "baz"),
            .filename = "baz.zig",
            .text = try allocator.dupe(u8, "hi this is baz"),
            .kind = .function,
        },
        .{
            .ident = try allocator.dupe(u8, "foo"),
            .filename = "foo.zig",
            .text = try allocator.dupe(u8, "hi this is foo"),
            .kind = .variable,
        },
        .{
            .ident = try allocator.dupe(u8, "bar"),
            .filename = "foo.zig",
            .text = try allocator.dupe(u8, "hi this is bar"),
            .kind = .variable,
        },
    };

    var orig = EntryList{};
    try orig.appendSlice(allocator, &input);

    var deduplicated = try removeDuplicates(allocator, &orig);
    defer {
        for (deduplicated.items) |entry| entry.deinit(allocator);
        deduplicated.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 3), deduplicated.items.len);
    try std.testing.expectEqual(input[2], deduplicated.items[0]);
    try std.testing.expectEqual(input[3], deduplicated.items[1]);
    try std.testing.expectEqual(input[0], deduplicated.items[2]);
}

fn getNodeText(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index) ![]const u8 {
    const token_starts = tree.tokens.items(.start);
    const first_token = tree.firstToken(node);
    const last_token = tree.lastToken(node);
    const start = token_starts[first_token];
    const end = token_starts[last_token] + tree.tokenSlice(last_token).len;
    const text = std.mem.sliceTo(tree.source[start..end], '\n');
    const start_of_line = if (start > 0 and tree.source[start - 1] == '\n') "^" else "";
    const end_of_line = if (start + text.len < tree.source.len and tree.source[start + text.len] == '\n')
        "$"
    else
        "";
    return try std.mem.concat(allocator, u8, &.{ start_of_line, text, end_of_line });
}

fn escape(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const escape_chars = "\\/";
    const escaped_length = blk: {
        var count: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfAnyPos(u8, text, start, escape_chars)) |i| {
            count += 1;
            start = i + 1;
        }

        break :blk text.len + count;
    };

    if (text.len == escaped_length) {
        return text;
    }

    var output = try std.ArrayList(u8).initCapacity(allocator, escaped_length);
    defer output.deinit();

    for (text) |c| {
        if (std.mem.indexOfScalar(u8, escape_chars, c)) |_| {
            output.appendAssumeCapacity('\\');
        }

        output.appendAssumeCapacity(c);
    }

    return try output.toOwnedSlice();
}

test "escape" {
    var allocator = std.testing.allocator;

    {
        const unescaped = "and/or\\/";
        const escaped = try escape(allocator, unescaped);
        defer allocator.free(escaped);

        try std.testing.expectEqualStrings("and\\/or\\\\\\/", escaped);
    }

    {
        const unescaped = "hello world";
        const escaped = try escape(allocator, unescaped);
        try std.testing.expectEqualStrings(unescaped, escaped);
    }
}

test "Tags.findTags" {
    var test_dir = try std.fs.cwd().makeOpenPath("test", .{});
    defer {
        test_dir.close();
        std.fs.cwd().deleteTree("test") catch unreachable;
    }

    const a_src =
        \\const b = @import("b.zig");
        \\
        \\const MyEnum = enum {
        \\    a,
        \\    b,
        \\};
        \\
        \\const MyStruct = struct {
        \\    c: u8,
        \\    d: u8,
        \\};
        \\
        \\const MyUnion = union(enum) {
        \\    e: void,
        \\    f: u32,
        \\};
        \\
        \\fn myFunction(s: MyStruct, e: MyEnum, u: MyUnion) u8 {
        \\    const x = switch (e) {
        \\        .a => s.d,
        \\        .b => s.c,
        \\    };
        \\
        \\    const y = switch (u) {
        \\        .e => null,
        \\        .f => |f| f,
        \\    };
        \\
        \\    if (x > y) {
        \\        return x;
        \\    }
        \\
        \\    return b.anotherFunction(y);
        \\}
        \\
    ;

    const b_src =
        \\fn anotherFunction(x: u8) u8 {
        \\    var y = x + 1;
        \\    return y * 2;
        \\}
        \\
    ;

    try test_dir.writeFile("a.zig", a_src);
    try test_dir.writeFile("b.zig", b_src);

    var tags = Tags.init(std.testing.allocator);
    defer tags.deinit();

    const full_path = try test_dir.realpathAlloc(std.testing.allocator, "a.zig");
    try tags.findTags(full_path);

    const cwd = try std.fs.cwd().openDir(".", .{});
    try test_dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    const actual = try tags.write(true);
    defer std.testing.allocator.free(actual);

    const golden =
        \\!_TAG_FILE_SORTED	1	/1 = sorted/
        \\!_TAG_FILE_ENCODING	utf-8
        \\MyEnum	a.zig	/^const MyEnum = enum {$/;"	enum
        \\MyStruct	a.zig	/^const MyStruct = struct {$/;"	struct
        \\MyUnion	a.zig	/^const MyUnion = union(enum) {$/;"	union
        \\a	a.zig	/a/;"	field
        \\anotherFunction	b.zig	/fn anotherFunction(x: u8) u8 {$/;"	function
        \\b	a.zig	/b/;"	field
        \\c	a.zig	/c: u8/;"	field
        \\d	a.zig	/d: u8/;"	field
        \\e	a.zig	/e: void/;"	field
        \\f	a.zig	/f: u32/;"	field
        \\myFunction	a.zig	/^fn myFunction(s: MyStruct, e: MyEnum, u: MyUnion) u8 {$/;"	function
        \\x	a.zig	/const x = switch (e) {$/;"	constant
        \\y	a.zig	/const y = switch (u) {$/;"	constant
        \\y	b.zig	/var y = x + 1/;"	variable
        \\
    ;

    try std.testing.expectEqualStrings(golden, actual);
}

test "Tags.read" {
    const input =
        \\!_TAG_FILE_SORTED	1	/1 = sorted/
        \\!_TAG_FILE_ENCODING	utf-8
        \\MyEnum	a.zig	/^const MyEnum = enum {$/;"	enum
        \\MyStruct	a.zig	/^const MyStruct = struct {$/;"	struct
        \\MyUnion	a.zig	/^const MyUnion = union(enum) {$/;"	union
        \\a	a.zig	/a/;"	field
        \\anotherFunction	b.zig	/fn anotherFunction(x: u8) u8 {$/;"	function
        \\b	a.zig	/b/;"	field
        \\c	a.zig	/c: u8/;"	field
        \\d	a.zig	/d: u8/;"	field
        \\e	a.zig	/e: void/;"	field
        \\f	a.zig	/f: u32/;"	field
        \\myFunction	a.zig	/^fn myFunction(s: MyStruct, e: MyEnum, u: MyUnion) u8 {$/;"	function
        \\x	a.zig	/const x = switch (e) {$/;"	constant
        \\y	a.zig	/const y = switch (u) {$/;"	constant
        \\y	b.zig	/var y = x + 1/;"	variable
        \\
    ;

    var tags = Tags.init(std.testing.allocator);
    defer tags.deinit();

    try tags.read(input);
    const output = try tags.write(true);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(input, output);
}
