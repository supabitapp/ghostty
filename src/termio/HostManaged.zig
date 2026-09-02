const HostManaged = @This();

const renderer = @import("../renderer.zig");

pub const Config = struct {
    userdata: ?*anyopaque,
    input: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    resize: *const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void,
};

config: Config,

pub fn init(config: Config) HostManaged {
    return .{ .config = config };
}

pub fn queueWrite(self: *HostManaged, data: []const u8, linefeed: bool) !void {
    if (!linefeed) {
        if (data.len > 0) self.config.input(self.config.userdata, data.ptr, data.len);
        return;
    }

    var buffer: [4096]u8 = undefined;
    var input_index: usize = 0;
    while (input_index < data.len) {
        var output_index: usize = 0;
        while (input_index < data.len and output_index < buffer.len - 1) {
            const byte = data[input_index];
            input_index += 1;
            buffer[output_index] = byte;
            output_index += 1;
            if (byte == '\r') {
                buffer[output_index] = '\n';
                output_index += 1;
            }
        }
        self.config.input(self.config.userdata, &buffer, output_index);
    }
}

pub fn resize(
    self: *HostManaged,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.config.resize(
        self.config.userdata,
        grid_size.columns,
        grid_size.rows,
        screen_size.width,
        screen_size.height,
    );
}
