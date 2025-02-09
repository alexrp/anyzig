const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Color = std.zig.Color;
const ThreadPool = std.Thread.Pool;
const cleanExit = std.process.cleanExit;
const native_os = builtin.os.tag;
const Cache = std.Build.Cache;
const Directory = std.Build.Cache.Directory;
const EnvVar = std.zig.EnvVar;

const zig = @import("zig");
const MultiHashHexDigest = zig.Package.Manifest.MultiHashHexDigest;

const Package = zig.Package;
const introspect = zig.introspect;

const log = std.log;

pub const std_options: std.Options = .{
    .logFn = anyzigLog,
};

fn anyzigLog(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_level = comptime (switch (scope) {
        .default => switch (level) {
            .info => "",
            inline else => ": " ++ level.asText(),
        },
        else => |s| "(" ++ @tagName(s) ++ "): " ++ level.asText(),
    });
    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        writer.print("anyzig" ++ scope_level ++ ": " ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

const Extent = struct { start: usize, limit: usize };

fn extractMinZigVersion(zon: []const u8) !?Extent {
    const needle = ".minimum_zig_version";

    var offset: usize = 0;
    while (true) {
        offset = skipWhitespaceAndComments(zon, offset);
        const minimum_zig_version = std.mem.indexOfPos(u8, zon, offset, needle) orelse return null;
        offset = skipWhitespaceAndComments(zon, minimum_zig_version + needle.len);
        if (zonInsideComment(zon, minimum_zig_version))
            continue;
        if (offset >= zon.len or zon[offset] != '=') {
            log.debug("build.zig.zon syntax error (missing '=' after '{s}')", .{needle});
            return null;
        }
        offset = skipWhitespaceAndComments(zon, offset + 1);
        if (offset >= zon.len or zon[offset] != '\"') {
            log.debug("build.zig.zon syntax error", .{});
            return null;
        }
        const version_start = offset + 1;
        while (true) {
            offset += 1;
            if (offset >= zon.len) {
                log.debug("build.zig.zon syntax error", .{});
                return null;
            }
            if (zon[offset] == '"') break;
        }
        return .{ .start = version_start, .limit = offset };
    }
}

fn zonInsideComment(zon: []const u8, start: usize) bool {
    if (start < 2) return false;
    if (zon[start - 1] == '\n') return false;
    var offset = start - 2;
    while (true) : (offset -= 1) {
        if (zon[offset] == '\n') return false;
        if (zon[offset] == '/' and zon[offset + 1] == '/') return true;
        if (offset == 0) return false;
    }
    return false;
}

fn skipWhitespaceAndComments(s: []const u8, start: usize) usize {
    var offset = start;
    var previous_was_slash = false;
    while (offset < s.len) {
        const double_slash = blk: {
            const at_slash = s[offset] == '/';
            const double_slash = previous_was_slash and at_slash;
            previous_was_slash = at_slash;
            break :blk double_slash;
        };
        if (double_slash) {
            while (true) {
                offset += 1;
                if (offset == s.len) break;
                if (s[offset] == '\n') {
                    offset += 1;
                    break;
                }
            }
        } else if (!std.ascii.isWhitespace(s[offset])) {
            break;
        } else {
            offset += 1;
        }
    }
    return offset;
}

fn loadBuildZigZon(arena: Allocator, build_root: BuildRoot) !?[]const u8 {
    const zon = build_root.directory.handle.openFile("build.zig.zon", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer zon.close();
    return try zon.readToEndAlloc(arena, std.math.maxInt(usize));
}

fn determineZigVersion(arena: Allocator, build_root: BuildRoot) ![]const u8 {
    const zon = try loadBuildZigZon(arena, build_root) orelse {
        log.err("TODO: no build.zig.zon file, maybe try determining zig version from build.zig?", .{});
        std.process.exit(0xff);
    };
    const version_extent = try extractMinZigVersion(zon) orelse {
        log.err("TODO: build.zig.zon does not have a minimum_zig_version, maybe try determining zig version from build.zig?", .{});
        std.process.exit(0xff);
    };
    const minimum_zig_version = zon[version_extent.start..version_extent.limit];
    log.info(
        "zig version '{s}' pulled from '{}build.zig.zon'",
        .{ minimum_zig_version, build_root.directory },
    );
    return try arena.dupe(u8, minimum_zig_version);

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: if we find ".{ .path = "..." }" in build.zig then we know zig must be older than 0.13.0

    // 0.12.0
    // <         .root_source_file = b.path("src/root.zig"),
    // 0.11.0
    // >         .root_source_file = .{ .path = "src/main.zig" },

    // log.info("fallback to default zig version 0.13.0", .{});
    // return "0.13.0";
}

pub fn main() !void {
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const all_args = try std.process.argsAlloc(arena);
    defer arena.free(all_args);

    const argv_index: usize, const manual_version: ?[]const u8 = blk: {
        if (all_args.len >= 2 and isRelease(all_args[1])) break :blk .{ 2, all_args[1] };
        break :blk .{ 1, null };
    };

    const maybe_command: ?[]const u8 = if (argv_index >= all_args.len) null else all_args[argv_index];

    const version: []const u8, const is_init = blk: {
        if (manual_version) |version| break :blk .{ version, true };
        if (maybe_command) |command| {
            if (std.mem.startsWith(u8, command, "-") and !std.mem.eql(u8, command, "-h") and !std.mem.eql(u8, command, "--help")) {
                try std.io.getStdErr().writer().print(
                    "error: expected a command but got '{s}'\n",
                    .{command},
                );
                std.process.exit(0xff);
            }
            if (std.mem.eql(u8, command, "init") or std.mem.eql(u8, command, "init-exe") or std.mem.eql(u8, command, "init-lib")) {
                try std.io.getStdErr().writer().print(
                    "error: anyzig init requires a version, i.e. 'zig 0.13.0 {s}'\n",
                    .{command},
                );
                std.process.exit(0xff);
            }
        }
        const build_root = try findBuildRoot(arena, .{}) orelse {
            try std.io.getStdErr().writeAll("anyzig: no build.zig\n" ++
                "run 'zig VERSION' to specify a version, or, run from a directory with a build.zig file.\n");
            std.process.exit(0xff);
        };
        break :blk .{ try determineZigVersion(arena, build_root), false };
    };

    const app_data_path = try std.fs.getAppDataDir(arena, "anyzig");
    defer arena.free(app_data_path);
    log.info("appdata '{s}'", .{app_data_path});

    const store_path = try std.fs.path.join(arena, &.{ app_data_path, "hashstore" });
    defer arena.free(store_path);

    var find_hash_error_count: u32 = 0;
    const maybe_hash = maybeHashAndPath(try findHash(store_path, version, &find_hash_error_count));
    if (maybe_hash == null and find_hash_error_count > 0) {
        log.err("store file had {} errors, fix them", .{find_hash_error_count});
        process.exit(0xff);
    }

    const override_global_cache_dir: ?[]const u8 = try EnvVar.ZIG_GLOBAL_CACHE_DIR.get(arena);
    var global_cache_directory: Directory = l: {
        const p = override_global_cache_dir orelse try introspect.resolveGlobalCacheDir(arena);
        break :l .{
            .handle = try fs.cwd().makeOpenPath(p, .{}),
            .path = p,
        };
    };
    defer global_cache_directory.handle.close();

    const hash = blk: {
        if (maybe_hash) |hash| {
            if (global_cache_directory.handle.access(&hash.path, .{})) |_| {
                log.info(
                    "zig '{s}' already exists at '{}{s}'",
                    .{ version, global_cache_directory, &maybe_hash.?.path },
                );
                break :blk hash;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            }
        }

        // TODO: fetch the download index if necessary
        const url = try getDefaultUrl(arena, version);
        defer arena.free(url);
        const hash = hashAndPath(try cmdFetch(gpa, arena, global_cache_directory, url, .{ .debug_hash = false }));
        if (maybe_hash) |*previous_hash| {
            if (!std.mem.eql(u8, &previous_hash.val, &hash.val)) {
                log.warn(
                    "version '{s}' hash has changed!\nold:{s}\nnew:{s}\n",
                    .{ version, &previous_hash.val, &hash.val },
                );
                try deleteHash(version, &previous_hash.val);
                var error_count: u32 = 0;
                assert(null == try findHash(store_path, version, &error_count));
            }
        }
        log.info("downloaded zig to '{}{s}'", .{ global_cache_directory, &hash.path });

        try std.fs.cwd().makePath(app_data_path);

        {
            const store_file = try std.fs.cwd().createFile(store_path, .{ .truncate = false });
            defer store_file.close();
            try store_file.seekFromEnd(0);
            try store_file.writer().print("{s} {s}\n", .{ version, &hash.val });
        }
        break :blk hash;
    };

    const versioned_zig = try global_cache_directory.joinZ(arena, &.{ &hash.path, "zig" });
    defer arena.free(versioned_zig);

    const stay_alive = is_init or (builtin.os.tag == .windows);

    if (stay_alive) {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: if on windows, create a job so our child process gets killed if
        //       our process gets killed
        var al: ArrayListUnmanaged([]const u8) = .{};
        try al.append(arena, versioned_zig);
        for (all_args[argv_index..]) |arg| {
            try al.append(arena, arg);
        }
        var child: std.process.Child = .init(al.items, arena);
        try child.spawn();
        const result = try child.wait();
        switch (result) {
            .Exited => |code| if (code != 0) std.process.exit(0xff),
            else => std.process.exit(0xff),
        }
    }

    if (is_init) {
        const build_root = try findBuildRoot(arena, .{}) orelse @panic("init did not create a build.zig file");
        log.info("{}{s}", .{ build_root.directory, build_root.build_zig_basename });
        const zon = try loadBuildZigZon(arena, build_root) orelse {
            const f = try std.fs.cwd().createFile("build.zig.zon", .{});
            defer f.close();
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: maybe don't use .name = placeholder?
            try f.writer().print(
                \\.{{
                \\    .name = "placeholder",
                \\    .version = "0.0.0",
                \\    .minimum_zig_version = "{s}",
                \\}}
                \\
            , .{version});
            return;
        };
        const version_extent = try extractMinZigVersion(zon) orelse {
            if (!std.mem.startsWith(u8, zon, ".{")) @panic("zon file did not start with '.{'");
            if (zon.len < 2 or zon[2] != '\n') @panic("zon file not start with '.{\\n");
            const f = try std.fs.cwd().createFile("build.zig.zon", .{});
            defer f.close();
            try f.writer().writeAll(zon[0..3]);
            try f.writer().print("    .minimum_zig_version = \"{s}\",\n", .{version});
            try f.writer().writeAll(zon[3..]);
            return;
        };

        const current_version = zon[version_extent.start..version_extent.limit];
        std.debug.panic("todo: ensure zon file contains zig version '{s}' (current is '{s}')", .{ version, current_version });
    }

    if (!stay_alive) {
        const argv = blk: {
            var al: ArrayListUnmanaged(?[*:0]const u8) = .{};
            try al.append(arena, versioned_zig);
            for (std.os.argv[argv_index..]) |arg| {
                try al.append(arena, arg);
            }
            break :blk try al.toOwnedSliceSentinel(arena, null);
        };
        const err = std.posix.execveZ(versioned_zig, argv, @ptrCast(std.os.environ.ptr));
        log.err("exec '{s}' failed with {s}", .{ versioned_zig, @errorName(err) });
        process.exit(0xff);
    }
}

fn isRelease(str: []const u8) bool {
    return if (std.SemanticVersion.parse(str)) |_| true else |e| switch (e) {
        error.Overflow => false,
        error.InvalidVersion => false,
    };
}

const arch = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .arm => "armv7a",
    .riscv64 => "riscv64",
    .powerpc64le => "powerpc64le",
    .powerpc => "powerpc",
    else => @compileError("Unsupported CPU Architecture"),
};
const os = switch (builtin.os.tag) {
    .windows => "windows",
    .linux => "linux",
    .macos => "macos",
    else => @compileError("Unsupported OS"),
};

const url_platform = os ++ "-" ++ arch;
const json_platform = arch ++ "-" ++ os;
const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

const VersionKind = enum { release, dev };
fn determineVersionKind(version: []const u8) VersionKind {
    return if (std.mem.indexOfAny(u8, version, "-+")) |_| .dev else .release;
}

pub fn getDefaultUrl(allocator: Allocator, compiler_version: []const u8) ![]const u8 {
    return switch (determineVersionKind(compiler_version)) {
        .dev => try std.fmt.allocPrint(allocator, "https://ziglang.org/builds/zig-" ++ url_platform ++ "-{0s}." ++ archive_ext, .{compiler_version}),
        .release => try std.fmt.allocPrint(allocator, "https://ziglang.org/download/{s}/zig-" ++ url_platform ++ "-{0s}." ++ archive_ext, .{compiler_version}),
    };
}

const HashAndPath = struct {
    val: MultiHashHexDigest,
    path: [2 + @sizeOf(MultiHashHexDigest):0]u8,
};
fn maybeHashAndPath(maybe_hash: ?MultiHashHexDigest) ?HashAndPath {
    return hashAndPath(maybe_hash orelse return null);
}
fn hashAndPath(hash: MultiHashHexDigest) HashAndPath {
    var path: [2 + @sizeOf(MultiHashHexDigest):0]u8 = undefined;
    path[0] = 'p';
    path[1] = std.fs.path.sep;
    @memcpy(path[2..], &hash);
    assert(path[path.len] == 0);
    return .{
        .val = hash,
        .path = path,
    };
}

fn findHash(store_path: []const u8, zig_version: []const u8, out_error_count: *u32) !?MultiHashHexDigest {
    const store_file = std.fs.cwd().openFile(store_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer store_file.close();

    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const content = try store_file.readToEndAlloc(arena, std.math.maxInt(usize));
    defer arena.free(content);
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var lineno: u32 = 0;
    while (line_it.next()) |line_full| {
        lineno += 1;
        const line = std.mem.trim(u8, line_full, &std.ascii.whitespace);
        if (line.len == 0) continue; // allow blank lines
        const sep_index = std.mem.indexOfAny(u8, line, &std.ascii.whitespace) orelse {
            log.err(
                "{s}:{}: missing whitespace separator",
                .{ store_path, lineno },
            );
            out_error_count.* += 1;
            continue;
        };
        const line_zig_version = std.mem.trim(u8, line[0..sep_index], &std.ascii.whitespace);
        const hash = std.mem.trim(u8, line[sep_index + 1 ..], &std.ascii.whitespace);
        if (hash.len != zig.Package.Manifest.multihash_hex_digest_len) {
            log.err(
                "{s}:{}: expected hash to be {} bytes but is {}",
                .{ store_path, lineno, zig.Package.Manifest.multihash_hex_digest_len, hash.len },
            );
            out_error_count.* += 1;
            continue;
        }

        if (std.mem.eql(u8, line_zig_version, zig_version)) {
            var result: MultiHashHexDigest = undefined;
            @memcpy(&result, hash);
            return result;
        }
    }
    return null;
}

fn deleteHash(store_path: []const u8, zig_version: []const u8) !void {
    _ = store_path;
    _ = zig_version;
    @panic("todo");
}

pub fn cmdFetch(
    gpa: Allocator,
    arena: Allocator,
    global_cache_directory: Directory,
    url: []const u8,
    opt: struct {
        debug_hash: bool,
    },
) !MultiHashHexDigest {
    const color: Color = .auto;
    const work_around_btrfs_bug = native_os == .linux and
        try EnvVar.ZIG_BTRFS_WORKAROUND.isSet(arena);

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(.{ .allocator = gpa });
    defer thread_pool.deinit();

    var http_client: std.http.Client = .{ .allocator = gpa };
    defer http_client.deinit();

    try http_client.initDefaultProxies(arena);

    var root_prog_node = std.Progress.start(.{
        .root_name = "Fetch",
    });
    defer root_prog_node.end();

    var job_queue: Package.Fetch.JobQueue = .{
        .http_client = &http_client,
        .thread_pool = &thread_pool,
        .global_cache = global_cache_directory,
        .recursive = false,
        .read_only = false,
        .debug_hash = opt.debug_hash,
        .work_around_btrfs_bug = work_around_btrfs_bug,
    };
    defer job_queue.deinit();

    var fetch: Package.Fetch = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .location = .{ .path_or_url = url },
        .location_tok = 0,
        .hash_tok = 0,
        .name_tok = 0,
        .lazy_status = .eager,
        .parent_package_root = undefined,
        .parent_manifest_ast = null,
        .prog_node = root_prog_node,
        .job_queue = &job_queue,
        .omit_missing_hash_error = true,
        .allow_missing_paths_field = false,
        .use_latest_commit = true,

        .package_root = undefined,
        .error_bundle = undefined,
        .manifest = null,
        .manifest_ast = undefined,
        .actual_hash = undefined,
        .has_build_zig = false,
        .oom_flag = false,
        .latest_commit = null,

        .module = null,
    };
    defer fetch.deinit();

    log.info("downloading '{s}'...", .{url});
    fetch.run() catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory", .{}),
        error.FetchFailed => {}, // error bundle checked below
    };

    if (fetch.error_bundle.root_list.items.len > 0) {
        var errors = try fetch.error_bundle.toOwnedBundle("");
        errors.renderToStdErr(color.renderOptions());
        process.exit(1);
    }

    const hex_digest = Package.Manifest.hexDigest(fetch.actual_hash);

    root_prog_node.end();
    root_prog_node = .{ .index = .none };

    return hex_digest;
}

const BuildRoot = struct {
    directory: Cache.Directory,
    build_zig_basename: []const u8,
    cleanup_build_dir: ?fs.Dir,

    fn deinit(br: *BuildRoot) void {
        if (br.cleanup_build_dir) |*dir| dir.close();
        br.* = undefined;
    }
};

const FindBuildRootOptions = struct {
    build_file: ?[]const u8 = null,
    cwd_path: ?[]const u8 = null,
};

fn findBuildRoot(arena: Allocator, options: FindBuildRootOptions) !?BuildRoot {
    const cwd_path = options.cwd_path orelse try process.getCwdAlloc(arena);
    const build_zig_basename = if (options.build_file) |bf|
        fs.path.basename(bf)
    else
        Package.build_zig_basename;

    if (options.build_file) |bf| {
        if (fs.path.dirname(bf)) |dirname| {
            const dir = fs.cwd().openDir(dirname, .{}) catch |err| {
                fatal("unable to open directory to build file from argument 'build-file', '{s}': {s}", .{ dirname, @errorName(err) });
            };
            return .{
                .build_zig_basename = build_zig_basename,
                .directory = .{ .path = dirname, .handle = dir },
                .cleanup_build_dir = dir,
            };
        }

        return .{
            .build_zig_basename = build_zig_basename,
            .directory = .{ .path = null, .handle = fs.cwd() },
            .cleanup_build_dir = null,
        };
    }
    // Search up parent directories until we find build.zig.
    var dirname: []const u8 = cwd_path;
    while (true) {
        const joined_path = try fs.path.join(arena, &[_][]const u8{ dirname, build_zig_basename });
        if (fs.cwd().access(joined_path, .{})) |_| {
            const dir = fs.cwd().openDir(dirname, .{}) catch |err| {
                fatal("unable to open directory while searching for build.zig file, '{s}': {s}", .{ dirname, @errorName(err) });
            };
            return .{
                .build_zig_basename = build_zig_basename,
                .directory = .{
                    .path = dirname,
                    .handle = dir,
                },
                .cleanup_build_dir = dir,
            };
        } else |err| switch (err) {
            error.FileNotFound => {
                dirname = fs.path.dirname(dirname) orelse return null;
                continue;
            },
            else => |e| return e,
        }
    }
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    process.exit(1);
}
