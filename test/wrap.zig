const builtin = @import("builtin");
const std = @import("std");

pub fn main() !u8 {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const all_args = try std.process.argsAlloc(arena);

    const input_dir = all_args[1];
    const output_dir = all_args[2];
    const exe_index = 3;

    try std.fs.cwd().deleteTree(output_dir);
    try std.fs.cwd().makeDir(output_dir);

    if (std.mem.eql(u8, input_dir, "--no-input")) {
        //
    } else {
        try copyDir(arena, input_dir, output_dir, input_dir, output_dir);
    }

    try std.posix.chdirZ(output_dir);
    if (builtin.os.tag == .windows) {
        var child: std.process.Child = .init(all_args[exe_index..], arena);
        try child.spawn();
        const result = try child.wait();
        switch (result) {
            .Exited => |code| return code,
            inline else => |sig, tag| {
                std.log.err("zig process terminated from {s} with {}", .{ @tagName(tag), sig });
                return 0xff;
            },
        }
    } else {
        const exe = std.os.argv[exe_index];
        const err = std.posix.execveZ(
            exe,
            @ptrCast(std.os.argv.ptr + exe_index),
            @ptrCast(std.os.environ.ptr),
        );
        std.log.err("exec '{s}' failed with {s}", .{ exe, @errorName(err) });
        return 0xff;
    }
}

fn copyDir(
    allocator: std.mem.Allocator,
    in_root: []const u8,
    out_root: []const u8,
    in_path: []const u8,
    out_path: []const u8,
) !void {
    var in_dir = try std.fs.cwd().openDir(in_path, .{ .iterate = true });
    defer in_dir.close();

    var it = in_dir.iterate();
    while (try it.next()) |entry| {
        const in_sub_path = try std.fs.path.join(allocator, &.{ in_path, entry.name });
        defer allocator.free(in_sub_path);
        const out_sub_path = try std.fs.path.join(allocator, &.{ out_path, entry.name });
        defer allocator.free(out_sub_path);
        switch (entry.kind) {
            .directory => {
                try std.fs.cwd().makeDir(out_sub_path);
                try copyDir(allocator, in_root, out_root, in_sub_path, out_sub_path);
            },
            .file => try std.fs.cwd().copyFile(in_sub_path, std.fs.cwd(), out_sub_path, .{}),
            .sym_link => {
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const in_target = try std.fs.cwd().readLink(in_sub_path, &target_buf);
                var out_target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const out_target = blk: {
                    if (std.fs.path.isAbsolute(in_target)) {
                        if (!std.mem.startsWith(u8, in_target, in_root)) std.debug.panic(
                            "expected symlink target to start with '{s}' but got '{s}'",
                            .{ in_root, in_target },
                        );
                        break :blk try std.fmt.bufPrint(
                            &out_target_buf,
                            "{s}{s}",
                            .{ out_root, in_target[in_root.len..] },
                        );
                    }
                    break :blk in_target;
                };

                if (builtin.os.tag == .windows) @panic(
                    "we got a symlink on windows?",
                ) else try std.posix.symlink(out_target, out_sub_path);
            },
            else => std.debug.panic("copy {}", .{entry}),
        }
    }
}
