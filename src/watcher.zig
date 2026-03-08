const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const Event = enum {
    created,
    modified,
    deleted,
};

pub const WatchCallback = *const fn (event: Event, filename: []const u8) void;

/// Watch the mapping directory for changes and invoke the callback.
pub fn watch(dir_path: []const u8, callback: WatchCallback) !void {
    switch (builtin.os.tag) {
        .linux => try watchInotify(dir_path, callback),
        .macos => try watchKqueue(dir_path, callback),
        else => @compileError("Unsupported OS for file watching"),
    }
}

/// Non-blocking single event poll (for testing).
pub fn pollOnce(dir_path: []const u8, callback: WatchCallback) !bool {
    switch (builtin.os.tag) {
        .linux => return pollInotifyOnce(dir_path, callback),
        .macos => return pollKqueueOnce(dir_path, callback),
        else => @compileError("Unsupported OS for file watching"),
    }
}

// --- Linux inotify implementation ---

fn watchInotify(dir_path: []const u8, callback: WatchCallback) !void {
    const ifd = try createInotifyWatch(dir_path);
    defer posix.close(ifd);

    while (true) {
        processInotifyEvents(ifd, callback) catch |err| {
            std.debug.print("inotify read error: {}\n", .{err});
            continue;
        };
    }
}

fn pollInotifyOnce(dir_path: []const u8, callback: WatchCallback) !bool {
    const ifd = try createInotifyWatch(dir_path);
    defer posix.close(ifd);

    // Use poll to check for events without blocking
    var pfd = [_]posix.pollfd{
        .{
            .fd = ifd,
            .events = posix.POLL.IN,
            .revents = 0,
        },
    };

    const ready = try posix.poll(&pfd, 100); // 100ms timeout
    if (ready > 0) {
        try processInotifyEvents(ifd, callback);
        return true;
    }
    return false;
}

fn createInotifyWatch(dir_path: []const u8) !i32 {
    const dir_path_z = try posix.toPosixPath(dir_path);
    const linux = std.os.linux;

    const ifd = linux.inotify_init1(linux.IN.NONBLOCK);
    if (@as(isize, @bitCast(ifd)) < 0) {
        return error.InotifyInitFailed;
    }

    const mask = linux.IN.CREATE | linux.IN.MODIFY | linux.IN.DELETE | linux.IN.CLOSE_WRITE;
    const wd = linux.inotify_add_watch(@intCast(ifd), &dir_path_z, mask);
    if (@as(isize, @bitCast(wd)) < 0) {
        posix.close(@intCast(ifd));
        return error.InotifyAddWatchFailed;
    }

    return @intCast(ifd);
}

fn processInotifyEvents(ifd: i32, callback: WatchCallback) !void {
    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    const n = posix.read(@intCast(ifd), &buf) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
    if (n == 0) return;

    var offset: usize = 0;
    while (offset < n) {
        const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));
        offset += @sizeOf(std.os.linux.inotify_event) + event.len;

        const name = event.getName() orelse continue;

        if (!std.mem.endsWith(u8, name, ".json")) continue;

        const linux = std.os.linux;
        const ev: Event = if (event.mask & linux.IN.CREATE != 0 or event.mask & linux.IN.CLOSE_WRITE != 0)
            .created
        else if (event.mask & linux.IN.MODIFY != 0)
            .modified
        else if (event.mask & linux.IN.DELETE != 0)
            .deleted
        else
            continue;

        callback(ev, name);
    }
}

// --- macOS kqueue implementation ---

fn watchKqueue(dir_path: []const u8, callback: WatchCallback) !void {
    _ = dir_path;
    _ = callback;
    // kqueue implementation for macOS
    // Note: kqueue monitors at directory level, not individual files
    // For full implementation, we'd need to track directory contents manually
    @compileError("kqueue implementation not yet available");
}

fn pollKqueueOnce(dir_path: []const u8, callback: WatchCallback) !bool {
    _ = dir_path;
    _ = callback;
    @compileError("kqueue implementation not yet available");
}

// --- Tests ---

test "watch callback fires on file create" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const State = struct {
        var event_count: usize = 0;
        var last_event: Event = .created;
    };

    const cb = struct {
        fn callback(event: Event, _: []const u8) void {
            State.event_count += 1;
            State.last_event = event;
        }
    }.callback;

    State.event_count = 0;

    // Set up watch before creating the file
    const ifd = try createInotifyWatch(dir_path);
    defer posix.close(ifd);

    // Create a file after the watch is set up
    tmp.dir.writeFile(.{ .sub_path = "test.json", .data = "{}" }) catch unreachable;

    // Brief wait for filesystem to sync (50ms)
    posix.nanosleep(0, 50_000_000);

    // Process pending events
    processInotifyEvents(ifd, cb) catch {};

    try std.testing.expect(State.event_count > 0);
}
