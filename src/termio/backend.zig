const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

// The preallocation size for the write request pool. This should be big
// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// The kinds of backends.
pub const Kind = enum { exec, host_managed };

/// Configuration for the various backend types.
pub const Config = union(Kind) {
    /// Exec uses posix exec to run a command with a pty.
    exec: termio.Exec.Config,
    host_managed: termio.HostManaged,
};

/// Backend implementations. A backend is responsible for owning the pty
/// behavior and providing read/write capabilities.
pub const Backend = union(Kind) {
    exec: termio.Exec,
    host_managed: termio.HostManaged,

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(),
            .host_managed => |*host| host.deinit(),
        }
    }

    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {
        switch (self.*) {
            .exec => |*exec| exec.initTerminal(t),
            .host_managed => |*host| host.initTerminal(t),
        }
    }

    pub fn threadEnter(
        self: *Backend,
        alloc: Allocator,
        io: *termio.Termio,
        td: *termio.Termio.ThreadData,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.threadEnter(alloc, io, td),
            .host_managed => |*host| try host.threadEnter(alloc, io, td),
        }
    }

    pub fn threadExit(self: *Backend, td: *termio.Termio.ThreadData) void {
        switch (self.*) {
            .exec => |*exec| exec.threadExit(td),
            .host_managed => |*host| host.threadExit(td),
        }
    }

    pub fn focusGained(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        focused: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.focusGained(td, focused),
            .host_managed => |*host| try host.focusGained(td, focused),
        }
    }

    pub fn resize(
        self: *Backend,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.resize(grid_size, screen_size),
            .host_managed => |*host| try host.resize(grid_size, screen_size),
        }
    }

    pub fn queueWrite(
        self: *Backend,
        alloc: Allocator,
        td: *termio.Termio.ThreadData,
        data: []const u8,
        linefeed: bool,
        source: termio.WriteSource,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.queueWrite(alloc, td, data, linefeed),
            .host_managed => |*host| try host.queueWrite(
                alloc,
                td,
                data,
                linefeed,
                source,
            ),
        }
    }

    pub fn childExitedAbnormally(
        self: *Backend,
        gpa: Allocator,
        t: *terminal.Terminal,
        exit_code: u32,
        runtime_ms: u64,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
            .host_managed => |*host| try host.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
        }
    }

    /// Get information about the process(es) attached to the backend. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *Backend, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (self.*) {
            .exec => |*exec| exec.getProcessInfo(info),
            .host_managed => |*host| host.getProcessInfo(info),
        };
    }
};

/// Termio thread data. See termio.ThreadData for docs.
pub const ThreadData = union(Kind) {
    exec: termio.Exec.ThreadData,
    host_managed: termio.HostManaged.ThreadData,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(alloc),
            .host_managed => |*host| host.deinit(alloc),
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};

test "host managed forwards user input and suppresses terminal replies" {
    const testing = std.testing;
    const Capture = struct {
        bytes: std.ArrayList(u8),
        grid: renderer.GridSize = .{},
        screen: renderer.ScreenSize = .{ .width = 0, .height = 0 },
        accept: bool = true,
        calls: usize = 0,
        rejected: usize = 0,
        rejected_len: usize = 0,

        fn input(userdata: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            if (!self.accept) return false;
            self.bytes.appendSlice(testing.allocator, data[0..len]) catch unreachable;
            return true;
        }

        fn resize(
            userdata: ?*anyopaque,
            columns: u16,
            rows: u16,
            width: u32,
            height: u32,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.grid = .{ .columns = columns, .rows = rows };
            self.screen = .{ .width = width, .height = height };
        }

        fn inputRejected(userdata: ?*anyopaque, len: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.rejected += 1;
            self.rejected_len = len;
        }
    };

    var capture: Capture = .{ .bytes = .empty };
    defer capture.bytes.deinit(testing.allocator);
    var backend: Backend = .{ .host_managed = .{
        .userdata = &capture,
        .input = Capture.input,
        .resize_callback = Capture.resize,
        .input_capacity = 8,
        .input_rejected = Capture.inputRejected,
    } };
    var thread_data: termio.Termio.ThreadData = undefined;

    try backend.queueWrite(
        testing.allocator,
        &thread_data,
        "one\rtwo",
        true,
        .user_input,
    );
    try backend.queueWrite(
        testing.allocator,
        &thread_data,
        "reply",
        false,
        .terminal_reply,
    );
    try backend.resize(
        .{ .columns = 120, .rows = 40 },
        .{ .width = 1920, .height = 1080 },
    );

    try testing.expectEqualStrings("one\r\ntwo", capture.bytes.items);
    try testing.expectEqual(renderer.GridSize{ .columns = 120, .rows = 40 }, capture.grid);
    try testing.expectEqual(renderer.ScreenSize{ .width = 1920, .height = 1080 }, capture.screen);
    try testing.expect(backend.getProcessInfo(.foreground_pid) == null);
    try testing.expect(backend.getProcessInfo(.tty_name) == null);
    try testing.expectEqual(@as(usize, 1), capture.calls);

    try testing.expectError(error.InputTooLarge, backend.queueWrite(
        testing.allocator,
        &thread_data,
        "oversized",
        false,
        .user_input,
    ));
    try testing.expectEqual(@as(usize, 1), capture.calls);
    try testing.expectEqual(@as(usize, 1), capture.rejected);
    try testing.expectEqual(@as(usize, 9), capture.rejected_len);

    capture.accept = false;
    try testing.expectError(error.InputRejected, backend.queueWrite(
        testing.allocator,
        &thread_data,
        "rejected",
        false,
        .user_input,
    ));
    try testing.expectEqualStrings("one\r\ntwo", capture.bytes.items);
    try testing.expectEqual(@as(usize, 2), capture.calls);
}
