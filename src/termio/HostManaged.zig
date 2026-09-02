const HostManaged = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

pub const InputCallback = *const fn (
    ?*anyopaque,
    [*]const u8,
    usize,
) callconv(.c) bool;

pub const ResizeCallback = *const fn (
    ?*anyopaque,
    u16,
    u16,
    u32,
    u32,
) callconv(.c) void;

pub const InputRejectedCallback = *const fn (
    ?*anyopaque,
    usize,
) callconv(.c) void;

userdata: ?*anyopaque,
input: InputCallback,
resize_callback: ResizeCallback,
input_capacity: usize,
input_rejected: InputRejectedCallback,

pub fn init(
    userdata: ?*anyopaque,
    input: InputCallback,
    resize_callback: ResizeCallback,
    input_capacity: usize,
    input_rejected: InputRejectedCallback,
) HostManaged {
    return .{
        .userdata = userdata,
        .input = input,
        .resize_callback = resize_callback,
        .input_capacity = input_capacity,
        .input_rejected = input_rejected,
    };
}

pub fn preflightInput(
    self: *const HostManaged,
    len: usize,
    carriage_returns: usize,
    linefeed: bool,
) !usize {
    const required = if (linefeed)
        std.math.add(usize, len, carriage_returns) catch {
            self.input_rejected(self.userdata, std.math.maxInt(usize));
            return error.InputTooLarge;
        }
    else
        len;
    if (required > self.input_capacity) {
        self.input_rejected(self.userdata, required);
        return error.InputTooLarge;
    }
    return required;
}

pub fn deinit(_: *HostManaged) void {}

pub fn initTerminal(_: *HostManaged, _: *terminal.Terminal) void {}

pub fn threadEnter(
    _: *HostManaged,
    _: Allocator,
    _: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    td.backend = .{ .host_managed = .{} };
}

pub fn threadExit(_: *HostManaged, _: *termio.Termio.ThreadData) void {}

pub fn focusGained(
    _: *HostManaged,
    _: *termio.Termio.ThreadData,
    _: bool,
) !void {}

pub fn resize(
    self: *HostManaged,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.resize_callback(
        self.userdata,
        grid_size.columns,
        grid_size.rows,
        screen_size.width,
        screen_size.height,
    );
}

pub fn queueWrite(
    self: *HostManaged,
    alloc: Allocator,
    _: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
    source: termio.WriteSource,
) !void {
    if (source == .terminal_reply or data.len == 0) return;
    const carriage_returns = if (linefeed) std.mem.count(u8, data, "\r") else 0;
    const len = try self.preflightInput(
        data.len,
        carriage_returns,
        linefeed,
    );
    if (!linefeed or std.mem.indexOfScalar(u8, data, '\r') == null) {
        if (!self.input(self.userdata, data.ptr, data.len)) {
            return error.InputRejected;
        }
        return;
    }

    const expanded = try alloc.alloc(u8, len);
    defer alloc.free(expanded);

    var index: usize = 0;
    for (data) |byte| {
        expanded[index] = byte;
        index += 1;
        if (byte == '\r') {
            expanded[index] = '\n';
            index += 1;
        }
    }
    if (!self.input(self.userdata, expanded.ptr, expanded.len)) {
        return error.InputRejected;
    }
}

pub fn childExitedAbnormally(
    _: *HostManaged,
    _: Allocator,
    _: *terminal.Terminal,
    _: u32,
    _: u64,
) !void {}

pub fn getProcessInfo(
    _: *HostManaged,
    comptime info: @import("../pty.zig").ProcessInfo,
) ?@import("../pty.zig").ProcessInfo.Type(info) {
    return null;
}

pub const ThreadData = struct {
    pub fn deinit(_: *ThreadData, _: Allocator) void {}
};
