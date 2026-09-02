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
    host_managed: termio.HostManaged.Config,
};

/// Backend implementations. A backend is responsible for owning the pty
/// behavior and providing read/write capabilities.
pub const Backend = union(Kind) {
    exec: termio.Exec,
    host_managed: termio.HostManaged,

    pub fn isHostManaged(self: *const Backend) bool {
        return switch (self.*) {
            .exec => false,
            .host_managed => true,
        };
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(),
            .host_managed => {},
        }
    }

    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {
        switch (self.*) {
            .exec => |*exec| exec.initTerminal(t),
            .host_managed => |*host| host.resize(
                .{ .columns = t.cols, .rows = t.rows },
                .{ .width = t.width_px, .height = t.height_px },
            ) catch unreachable,
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
            .host_managed => {
                td.backend = .{ .host_managed = {} };
            },
        }
    }

    pub fn threadExit(self: *Backend, td: *termio.Termio.ThreadData) void {
        switch (self.*) {
            .exec => |*exec| exec.threadExit(td),
            .host_managed => {},
        }
    }

    pub fn focusGained(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        focused: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.focusGained(td, focused),
            .host_managed => {},
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
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.queueWrite(alloc, td, data, linefeed),
            .host_managed => |*host| try host.queueWrite(data, linefeed),
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
            .host_managed => {},
        }
    }

    /// Get information about the process(es) attached to the backend. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *Backend, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (self.*) {
            .exec => |*exec| exec.getProcessInfo(info),
            .host_managed => null,
        };
    }
};

/// Termio thread data. See termio.ThreadData for docs.
pub const ThreadData = union(Kind) {
    exec: termio.Exec.ThreadData,
    host_managed: void,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(alloc),
            .host_managed => {},
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};

test "host-managed backend forwards input and resize without a process" {
    const testing = std.testing;
    const HostManaged = termio.HostManaged;

    const State = struct {
        input: std.ArrayList(u8) = .empty,
        grid_size: renderer.GridSize = .{ .columns = 0, .rows = 0 },
        screen_size: renderer.ScreenSize = .{ .width = 0, .height = 0 },

        fn inputCallback(userdata: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(userdata.?));
            state.input.appendSlice(testing.allocator, data[0..len]) catch unreachable;
        }

        fn resizeCallback(
            userdata: ?*anyopaque,
            columns: u16,
            rows: u16,
            width: u32,
            height: u32,
        ) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(userdata.?));
            state.grid_size = .{ .columns = columns, .rows = rows };
            state.screen_size = .{ .width = width, .height = height };
        }
    };

    var state: State = .{};
    defer state.input.deinit(testing.allocator);
    var backend: HostManaged = .init(.{
        .userdata = &state,
        .input = &State.inputCallback,
        .resize = &State.resizeCallback,
    });

    try backend.queueWrite("one\rtwo", true);
    try testing.expectEqualStrings("one\r\ntwo", state.input.items);

    try backend.resize(
        .{ .columns = 91, .rows = 37 },
        .{ .width = 1400, .height = 900 },
    );
    try testing.expectEqual(@as(u16, 91), state.grid_size.columns);
    try testing.expectEqual(@as(u16, 37), state.grid_size.rows);
    try testing.expectEqual(@as(u32, 1400), state.screen_size.width);
    try testing.expectEqual(@as(u32, 900), state.screen_size.height);
}
