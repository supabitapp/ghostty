//! Primary terminal IO ("termio") state. This maintains the terminal state,
//! pty, subprocess, etc. This is flexible enough to be used in environments
//! that don't have a pty and simply provides the input/output using raw
//! bytes.
pub const Termio = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.Environ.Map;
const posix = std.posix;
const termio = @import("../termio.zig");
const StreamHandler = @import("stream_handler.zig").StreamHandler;
const terminalpkg = @import("../terminal/main.zig");
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const internal_os = @import("../os/main.zig");
const windows = internal_os.windows;
const configpkg = @import("../config.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const compat_file = @import("../lib/compat/file.zig");

const log = std.log.scoped(.io_exec);

/// Mutex state argument for queueMessage.
pub const MutexState = enum { locked, unlocked };

/// Allocator
alloc: Allocator,

/// This is the implementation responsible for io.
backend: termio.Backend,

/// The derived configuration for this termio implementation.
config: DerivedConfig,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminalpkg.Terminal,

/// The shared render state
renderer_state: *renderer.State,

/// A handle to wake up the renderer. This hints to the renderer that
/// a repaint should happen.
renderer_wakeup: xev.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the surface.
surface_mailbox: apprt.surface.Mailbox,

/// The cached size info
size: renderer.Size,

/// The mailbox implementation to use.
mailbox: termio.Mailbox,

/// The stream parser. This parses the stream of escape codes and so on
/// from the child process and calls callbacks in the stream handler.
terminal_stream: StreamHandler.Stream,

/// Last time the cursor was reset. This is used to prevent message
/// flooding with cursor resets.
last_cursor_reset: ?std.Io.Timestamp = null,

/// State we have for thread enter. This may be null if we don't need
/// to keep track of any state or if its already been freed.
thread_enter_state: ?*ThreadEnterState = null,

/// The state we need to keep around only until we enter the IO
/// thread. Then we can throw it all away.
const ThreadEnterState = struct {
    arena: ArenaAllocator,

    /// Initial input to send to the subprocess after starting. This
    /// memory is freed once the subprocess start is attempted, even
    /// if it fails, because Exec only starts once.
    input: configpkg.io.RepeatableReadableIO,

    pub fn create(
        alloc: Allocator,
        config: *const configpkg.Config,
    ) !?*ThreadEnterState {
        // If we have no input then we have no thread enter state
        if (config.input.list.items.len == 0) return null;

        // Create our arena allocator
        var arena = ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        // Allocate our ThreadEnterState
        const ptr = try arena_alloc.create(ThreadEnterState);

        // Copy the input from the config
        const input = try config.input.cloneParsed(arena_alloc);

        // Return the initialized state
        ptr.* = .{
            .arena = arena,
            .input = input,
        };
        return ptr;
    }

    pub fn destroy(self: *ThreadEnterState) void {
        self.arena.deinit();
    }

    /// Prepare the inputs for use. Allocations happen on the arena.
    pub fn prepareInput(
        self: *ThreadEnterState,
    ) (Allocator.Error || error{InputNotFound})![]const Input {
        const alloc = self.arena.allocator();

        var inputs: std.ArrayList(Input) = try .initCapacity(
            alloc,
            self.input.list.items.len,
        );
        errdefer for (inputs.items) |item| item.deinit();

        for (self.input.list.items) |item| {
            inputs.appendAssumeCapacity(switch (item) {
                .raw => |v| .{ .string = v },
                .path => |path| file: {
                    const f = std.Io.Dir.cwd().openFile(
                        global.io(),
                        path,
                        .{},
                    ) catch |err| {
                        log.warn("failed to open input file={s} err={}", .{
                            path,
                            err,
                        });
                        return error.InputNotFound;
                    };

                    break :file .{ .file = f };
                },
            });
        }

        return inputs.items;
    }

    const Input = union(enum) {
        string: []const u8,
        file: std.Io.File,

        fn deinit(self: Input) void {
            switch (self) {
                .string => {},
                .file => |f| f.close(global.io()),
            }
        }
    };
};

/// The configuration for this IO that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    palette: terminalpkg.color.Palette,
    image_storage_limit: usize,
    cursor_style: terminalpkg.CursorStyle,
    cursor_blink: ?bool,
    cursor_color: ?configpkg.Config.TerminalColor,
    foreground: configpkg.Config.Color,
    background: configpkg.Config.Color,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    clipboard_write: configpkg.ClipboardAccess,
    clipboard_write_limit: usize,
    enquiry_response: []const u8,
    conditional_state: configpkg.ConditionalState,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const palette: terminalpkg.color.Palette = palette: {
            if (config.@"palette-generate") generate: {
                if (config.palette.mask.findFirstSet() == null) {
                    // If the user didn't set any values manually, then
                    // we're using the default palette and we don't need
                    // to apply the generation code to it.
                    break :generate;
                }

                break :palette terminalpkg.color.generate256Color(config.palette.value, config.palette.mask, config.background.toTerminalRGB(), config.foreground.toTerminalRGB(), config.@"palette-harmonious");
            }

            break :palette config.palette.value;
        };

        return .{
            .palette = palette,
            .image_storage_limit = config.@"image-storage-limit",
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink",
            .cursor_color = config.@"cursor-color",
            .foreground = config.foreground,
            .background = config.background,
            .osc_color_report_format = config.@"osc-color-report-format",
            .clipboard_write = config.@"clipboard-write",
            .clipboard_write_limit = config.@"clipboard-write-limit-bytes".value,
            .enquiry_response = try alloc.dupe(u8, config.@"enquiry-response"),
            .conditional_state = config._conditional_state,

            // This has to be last so that we copy AFTER the arena allocations
            // above happen (Zig assigns in order).
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// Initialize the termio state.
///
/// This will also start the child process if the termio is configured
/// to run a child process.
pub fn init(self: *Termio, alloc: Allocator, opts: termio.Options) !void {
    // The default terminal modes based on our config.
    const default_modes: terminalpkg.ModePacked = modes: {
        var modes: terminalpkg.ModePacked = .{};

        // Setup our initial grapheme cluster support if enabled. We use a
        // switch to ensure we get a compiler error if more cases are added.
        switch (opts.full_config.@"grapheme-width-method") {
            .unicode => modes.grapheme_cluster = true,
            .legacy => {},
        }

        // Set default cursor blink settings
        modes.cursor_blinking = opts.config.cursor_blink orelse true;

        break :modes modes;
    };

    // Create our terminal
    var term = try terminalpkg.Terminal.init(global.io(), alloc, opts: {
        const grid_size = opts.size.grid();
        break :opts .{
            .cols = grid_size.columns,
            .rows = grid_size.rows,
            .max_scrollback_bytes = opts.full_config.@"scrollback-limit-bytes".optional(),
            .max_scrollback_lines = opts.full_config.@"scrollback-limit-lines".optional(),
            .default_modes = default_modes,
            .default_cursor_style = opts.config.cursor_style,
            .default_cursor_blink = opts.config.cursor_blink,
            .colors = .{
                .background = .init(opts.config.background.toTerminalRGB()),
                .foreground = .init(opts.config.foreground.toTerminalRGB()),
                .cursor = cursor: {
                    const color = opts.config.cursor_color orelse break :cursor .unset;
                    const rgb = color.toTerminalRGB() orelse break :cursor .unset;
                    break :cursor .init(rgb);
                },
                .palette = .init(opts.config.palette),
            },
            .kitty_image_storage_limit = opts.config.image_storage_limit,
            .kitty_image_loading_limits = .allWithTempDir(global.tmpDirPath()),
        };
    });
    errdefer term.deinit(alloc);

    // Setup our terminal size in pixels for certain requests.
    term.width_px = term.cols * opts.size.cell.width;
    term.height_px = term.rows * opts.size.cell.height;

    // Setup our backend.
    var backend = opts.backend;
    backend.initTerminal(&term);

    const thread_enter_state = try ThreadEnterState.create(
        alloc,
        opts.full_config,
    );

    self.* = .{
        .alloc = alloc,
        .terminal = term,
        .config = opts.config,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .size = opts.size,
        .backend = backend,
        .mailbox = opts.mailbox,
        .terminal_stream = undefined,
        .thread_enter_state = thread_enter_state,
    };
    self.terminal_stream = .init(.{
        .allocator = alloc,
        .handler = self.streamHandler(&self.terminal, !self.backend.isHostManaged()),
    });
}

fn streamHandler(
    self: *Termio,
    terminal: *terminalpkg.Terminal,
    terminal_responses: bool,
) StreamHandler {
    return .{
        .alloc = self.alloc,
        .termio_mailbox = &self.mailbox,
        .surface_mailbox = self.surface_mailbox,
        .renderer_state = self.renderer_state,
        .renderer_wakeup = self.renderer_wakeup,
        .renderer_mailbox = self.renderer_mailbox,
        .size = &self.size,
        .terminal = terminal,
        .osc_color_report_format = self.config.osc_color_report_format,
        .clipboard_write = self.config.clipboard_write,
        .clipboard_write_limit = self.config.clipboard_write_limit,
        .enquiry_response = self.config.enquiry_response,
        .terminal_responses = terminal_responses,
        .surface_effects = terminal_responses,
    };
}

pub fn deinit(self: *Termio) void {
    self.backend.deinit();
    self.terminal.deinit(self.alloc);
    self.config.deinit();
    self.mailbox.deinit(self.alloc);

    // Clear any StreamHandler state
    self.terminal_stream.deinit();

    // Clear any initial state if we have it
    if (self.thread_enter_state) |v| v.destroy();
}

pub fn threadEnter(
    self: *Termio,
    thread: *termio.Thread,
    data: *ThreadData,
) !void {
    // Always free our thread enter state when we're done.
    defer if (self.thread_enter_state) |v| {
        v.destroy();
        self.thread_enter_state = null;
    };

    // If we have thread enter state then we're going to validate
    // and set that all up now so that we can error before we actually
    // start the command and pty.
    const inputs: ?[]const ThreadEnterState.Input = if (self.thread_enter_state) |v|
        try v.prepareInput()
    else
        null;
    defer if (inputs) |items| {
        for (items) |input| input.deinit();
    };

    data.* = .{
        .alloc = self.alloc,
        .loop = &thread.loop,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .mailbox = &self.mailbox,
        .backend = undefined, // Backend must replace this on threadEnter
    };

    // Setup our backend
    try self.backend.threadEnter(self.alloc, self, data);
    errdefer self.backend.threadExit(data);

    // If we have inputs, then queue them all up.
    for (inputs orelse &.{}) |input| switch (input) {
        .string => |v| self.queueWrite(data, v, false) catch |err| {
            log.warn("failed to queue input string err={}", .{err});
            return error.InputFailed;
        },
        .file => |f| {
            const contents = compat_file.readToEndAlloc(
                f,
                self.alloc,
                10 * 1024 * 1024, // 10 MiB max
            ) catch |err| {
                log.warn("failed to read input file err={}", .{err});
                return error.InputFailed;
            };
            defer self.alloc.free(contents);

            self.queueWrite(data, contents, false) catch |err| {
                log.warn("failed to queue input file err={}", .{err});
                return error.InputFailed;
            };
        },
    };
}

pub fn threadExit(self: *Termio, data: *ThreadData) void {
    self.backend.threadExit(data);
}

/// Send a message to the mailbox. Depending on the mailbox type in use
/// this may process now or it may just enqueue and process later.
///
/// This will also notify the mailbox thread to process the message. If
/// you're sending a lot of messages, it may be more efficient to use
/// the mailbox directly and then call notify separately.
pub fn queueMessage(
    self: *Termio,
    msg: termio.Message,
    mutex: MutexState,
) void {
    self.mailbox.send(msg, switch (mutex) {
        .locked => self.renderer_state.mutex,
        .unlocked => null,
    });
    self.mailbox.notify();
}

/// Queue a write directly to the pty.
///
/// If you're using termio.Thread, this must ONLY be called from the
/// mailbox thread. If you're not on the thread, use queueMessage with
/// mailbox messages instead.
///
/// If you're not using termio.Thread, this is not threadsafe.
pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.backend.queueWrite(self.alloc, td, data, linefeed);
}

/// Update the configuration.
pub fn changeConfig(self: *Termio, td: *ThreadData, config: *DerivedConfig) !void {
    // The remainder of this function is modifying terminal state or
    // the read thread data, all of which requires holding the renderer
    // state lock.
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    // Deinit our old config. We do this in the lock because the
    // stream handler may be referencing the old config (i.e. enquiry resp)
    self.config.deinit();
    self.config = config.*;

    // Update our stream handler. The stream handler uses the same
    // renderer mutex so this is safe to do despite being executed
    // from another thread.
    self.terminal_stream.handler.changeConfig(&self.config);
    td.backend.changeConfig(&self.config);

    // Update the configuration that we know about.
    //
    // Specific things we don't update:
    //   - command, working-directory: we never restart the underlying
    //   process so we don't care or need to know about these.

    // Update the default palette.
    self.terminal.colors.palette.changeDefault(config.palette);
    self.terminal.flags.dirty.palette = true;

    // Update all our other colors
    self.terminal.colors.background.default = config.background.toTerminalRGB();
    self.terminal.colors.foreground.default = config.foreground.toTerminalRGB();
    self.terminal.colors.cursor.default = cursor: {
        const color = config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };

    // Set the image limits
    self.terminal.setKittyGraphicsSizeLimit(self.alloc, config.image_storage_limit);
    self.terminal.setKittyGraphicsLoadingLimits(.allWithTempDir(global.tmpDirPath()));
}

/// Resize the terminal.
pub fn resize(
    self: *Termio,
    td: *ThreadData,
    size: renderer.Size,
) !void {
    self.size = size;
    const grid_size = size.grid();

    // Update the size of our pty.
    try self.backend.resize(grid_size, size.terminal());

    // Enter the critical area that we want to keep small
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // Update the size of our terminal state
        try self.terminal.resize(
            self.alloc,
            .{
                .cols = grid_size.columns,
                .rows = grid_size.rows,
                .cell_size_px = .{
                    .width = self.size.cell.width,
                    .height = self.size.cell.height,
                },
            },
        );

        // If we have size reporting enabled we need to send a report.
        if (self.terminal.modes.get(.in_band_size_reports)) {
            try self.sizeReportLocked(td, .mode_2048);
        }
    }

    // Mail the renderer so that it can update the GPU and re-render
    _ = self.renderer_mailbox.push(global.io(), .{ .resize = size }, .{ .forever = {} });
    self.renderer_wakeup.notify() catch {};
}

/// Make a size report.
pub fn sizeReport(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    try self.sizeReportLocked(td, style);
}

fn sizeReportLocked(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    const grid_size = self.size.grid();
    const report_size: terminalpkg.size_report.Size = .{
        .rows = grid_size.rows,
        .columns = grid_size.columns,
        .cell_width = self.size.cell.width,
        .cell_height = self.size.cell.height,
    };

    // 1024 bytes should be enough for size report since report
    // in columns and pixels.
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.size_report.encode(
        &writer,
        style,
        report_size,
    );

    try self.queueWrite(td, writer.buffered(), false);
}

/// Reset the synchronized output mode. This is usually called by timer
/// expiration from the termio thread.
pub fn resetSynchronizedOutput(self: *Termio) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.terminal.modes.set(.synchronized_output, false);
    self.renderer_wakeup.notify() catch {};
}

/// Clear the screen.
pub fn clearScreen(self: *Termio, td: *ThreadData, history: bool) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // If we're on the alternate screen, we do not clear. Since this is an
        // emulator-level screen clear, this messes up the running programs
        // knowledge of where the cursor is and causes rendering issues. So,
        // for alt screen, we do nothing.
        if (self.terminal.screens.active_key == .alternate) return;

        // Clear our selection
        self.terminal.screens.active.clearSelection();

        // Clear our scrollback
        if (history) self.terminal.eraseDisplay(.scrollback, false);

        // If we're not at a prompt, we just delete above the cursor.
        if (!self.terminal.cursorIsAtPrompt()) {
            if (self.terminal.screens.active.cursor.y > 0) {
                self.terminal.screens.active.eraseActive(
                    self.terminal.screens.active.cursor.y - 1,
                );
            }

            // Clear all Kitty graphics state for this screen. This copies
            // Kitty's behavior when Cmd+K deletes all Kitty graphics. I
            // didn't spend time researching whether it only deletes Kitty
            // graphics that are placed above the cursor or if it deletes
            // all of them. We delete all of them for now but if this behavior
            // isn't fully correct we should fix this later.
            self.terminal.screens.active.kitty_images.delete(
                self.terminal.io(),
                self.terminal.screens.active.alloc,
                &self.terminal,
                .{ .all = true },
            );

            return;
        }

        // At a prompt, we want to first fully clear the screen, and then after
        // send a FF (0x0C) to the shell so that it can repaint the screen.
        // Mark the current row as a not a prompt so we can properly
        // clear the full screen in the next eraseDisplay call.
        // TODO: fix this
        // self.terminal.markSemanticPrompt(.command);
        // assert(!self.terminal.cursorIsAtPrompt());
        self.terminal.eraseDisplay(.complete, false);
    }

    // If we reached here it means we're at a prompt, so we send a form-feed.
    try self.queueWrite(td, &[_]u8{0x0C}, false);
}

/// Scroll the viewport
pub fn scrollViewport(
    self: *Termio,
    scroll: terminalpkg.Terminal.ScrollViewport,
) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.terminal.scrollViewport(scroll);
}

/// Jump the viewport to the prompt.
pub fn jumpToPrompt(self: *Termio, delta: isize) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        self.terminal.screens.active.scroll(.{ .delta_prompt = delta });
    }

    try self.renderer_wakeup.notify();
}

/// Called when focus is gained or lost (when focus events are enabled)
pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {
    if (self.backend.isHostManaged()) return;
    self.renderer_state.mutex.lockUncancelable(global.io());
    const focus_event = self.renderer_state.terminal.modes.get(.focus_event);
    self.renderer_state.mutex.unlock(global.io());

    // If we have focus events enabled, we send the focus event.
    if (focus_event) {
        var buf: [terminalpkg.focus.max_encode_size]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        terminalpkg.focus.encode(&writer, if (focused) .gained else .lost) catch |err| {
            log.err("error encoding focus event err={}", .{err});
            return;
        };
        try self.queueWrite(td, writer.buffered(), false);
    }

    // We always notify our backend of focus changes.
    try self.backend.focusGained(td, focused);
}

/// Process output from the pty. This is the manual API that users can
/// call with pty data but it is also called by the read thread when using
/// an exec subprocess.
pub fn processOutput(self: *Termio, buf: []const u8) void {
    // We are modifying terminal state from here on out and we need
    // the lock to grab our read data.
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.processOutputLocked(buf);
}

pub const RestoreSnapshotError = terminalpkg.snapshot.DecodeExactError || error{
    SnapshotContinuationMismatch,
    UnsupportedBackend,
};

pub fn restoreSnapshot(
    self: *Termio,
    bytes: []const u8,
) RestoreSnapshotError!void {
    if (!self.backend.isHostManaged()) return error.UnsupportedBackend;

    var restored = try decodeSnapshot(self.alloc, bytes, .{
        .palette = self.config.palette,
        .background = self.config.background.toTerminalRGB(),
        .foreground = self.config.foreground.toTerminalRGB(),
        .cursor = if (self.config.cursor_color) |color| color.toTerminalRGB() else null,
        .cursor_style = self.config.cursor_style,
        .cursor_blink = self.config.cursor_blink,
    });
    defer restored.deinit(self.alloc);
    var stream = try initRestoredStream(
        StreamHandler.Stream,
        self.alloc,
        self.streamHandler(&restored.terminal.?, false),
        restored.continuation,
    );
    errdefer stream.deinit();

    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    self.terminal_stream.deinit();
    self.terminal.deinit(self.alloc);
    self.terminal = restored.takeTerminal();
    self.renderer_state.terminal = &self.terminal;
    stream.handler.terminal = &self.terminal;
    self.terminal_stream = stream;
    self.last_cursor_reset = null;
    self.terminal_stream.handler.queueRender() catch unreachable;
}

fn initRestoredStream(
    comptime Stream: type,
    alloc: Allocator,
    handler: anytype,
    continuation: terminalpkg.snapshot.Continuation,
) (Allocator.Error || error{SnapshotContinuationMismatch})!Stream {
    var stream: Stream = .init(.{
        .allocator = alloc,
        .handler = handler,
        .continuation_max_bytes = switch (continuation) {
            .ground => null,
            .bytes => |bytes| bytes.len,
        },
    });
    errdefer stream.deinit();

    switch (continuation) {
        .ground => {
            if (!stream.ground()) return error.SnapshotContinuationMismatch;
        },
        .bytes => |bytes| {
            stream.nextSlice(bytes);
            const replayed = try alloc.alloc(u8, bytes.len);
            defer alloc.free(replayed);
            var writer: std.Io.Writer = .fixed(replayed);
            stream.writeContinuation(&writer) catch return error.SnapshotContinuationMismatch;
            if (!std.mem.eql(u8, bytes, writer.buffered())) {
                return error.SnapshotContinuationMismatch;
            }
        },
    }

    return stream;
}

/// Process output from readdata but the lock is already held.
fn processOutputLocked(self: *Termio, buf: []const u8) void {
    // Schedule a render. We can call this first because we have the lock.
    self.terminal_stream.handler.queueRender() catch unreachable;

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    const now = std.Io.Timestamp.now(global.io(), .awake);
    cursor_reset: {
        if (self.last_cursor_reset) |last| {
            if (last.durationTo(now).toMilliseconds() <= 500) {
                break :cursor_reset;
            }
        }

        self.last_cursor_reset = now;
        _ = self.renderer_mailbox.push(global.io(), .{
            .reset_cursor_blink = {},
        }, .{ .instant = {} });
    }

    // If we have an inspector, we enter SLOW MODE because we need to
    // process a byte at a time alternating between the inspector handler
    // and the termio handler. This is very slow compared to our optimizations
    // below but at least users only pay for it if they're using the inspector.
    if (self.renderer_state.inspector) |insp| {
        for (buf, 0..) |byte, i| {
            insp.recordPtyRead(
                self.alloc,
                &self.terminal,
                buf[i .. i + 1],
            ) catch |err| {
                log.err("error recording pty read in inspector err={}", .{err});
            };

            self.terminal_stream.next(byte);
        }
    } else {
        self.terminal_stream.nextSlice(buf);
    }

    // If our stream handling caused messages to be sent to the mailbox
    // thread, then we need to wake it up so that it processes them.
    if (self.terminal_stream.handler.termio_messaged) {
        self.terminal_stream.handler.termio_messaged = false;
        self.mailbox.notify();
    }
}

/// Sends a DSR response for the current color scheme to the pty.
/// Record a Kitty clipboard protocol session grant so future requests
/// carrying the password skip the permission prompt.
pub fn kittyClipboardGrant(
    self: *Termio,
    pw: []const u8,
    dir: terminalpkg.kitty.clipboard.Grants.Direction,
) error{OutOfMemory}!void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    try self.terminal_stream.handler.kittyClipboardGrant(pw, dir);
}

pub fn colorSchemeReport(self: *Termio, td: *ThreadData, force: bool) !void {
    if (self.backend.isHostManaged()) return;
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    try self.colorSchemeReportLocked(td, force);
}

pub fn colorSchemeReportLocked(self: *Termio, td: *ThreadData, force: bool) !void {
    if (!force and !self.renderer_state.terminal.modes.get(.report_color_scheme)) {
        return;
    }
    const scheme: terminalpkg.device_status.ColorScheme = switch (self.config.conditional_state.theme) {
        .light => .light,
        .dark => .dark,
    };

    var buf: [terminalpkg.device_status.max_color_scheme_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeColorSchemeReport(&writer, scheme);
    try self.queueWrite(td, writer.buffered(), false);
}

/// Sends a visibility report to the pty. Unforced reports are only sent while
/// DEC mode 2033 is enabled.
pub fn visibilityReport(
    self: *Termio,
    td: *ThreadData,
    visible: bool,
    force: bool,
) !void {
    if (self.backend.isHostManaged()) return;
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    if (!force and !self.renderer_state.terminal.modes.get(.report_visibility)) {
        return;
    }

    var buf: [terminalpkg.device_status.max_visibility_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeVisibilityReport(
        &writer,
        if (visible) .potentially_visible else .not_visible,
    );
    try self.queueWrite(td, writer.buffered(), false);
}

/// ThreadData is the data created and stored in the termio thread
/// when the thread is started and destroyed when the thread is
/// stopped.
///
/// All of the fields in this struct should only be read/written by
/// the termio thread. As such, a lock is not necessary.
pub const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The event loop associated with this thread. This is owned by
    /// the Thread but we have a pointer so we can queue new work to it.
    loop: *xev.Loop,

    /// The shared render state
    renderer_state: *renderer.State,

    /// Mailboxes for different threads
    surface_mailbox: apprt.surface.Mailbox,

    /// Data associated with the backend implementation (i.e. pty/exec state)
    backend: termio.backend.ThreadData,
    mailbox: *termio.Mailbox,

    pub fn deinit(self: *ThreadData) void {
        self.backend.deinit(self.alloc);
        self.* = undefined;
    }
};

const SnapshotDefaults = struct {
    palette: terminalpkg.color.Palette,
    background: terminalpkg.color.RGB,
    foreground: terminalpkg.color.RGB,
    cursor: ?terminalpkg.color.RGB,
    cursor_style: terminalpkg.Screen.CursorStyle,
    cursor_blink: ?bool,
};

const RestoredSnapshot = struct {
    terminal: ?terminalpkg.Terminal,
    continuation: terminalpkg.snapshot.Continuation,

    fn takeTerminal(self: *RestoredSnapshot) terminalpkg.Terminal {
        const result = self.terminal.?;
        self.terminal = null;
        return result;
    }

    fn deinit(self: *RestoredSnapshot, alloc: Allocator) void {
        if (self.terminal) |*terminal| terminal.deinit(alloc);
        switch (self.continuation) {
            .ground => {},
            .bytes => |bytes| alloc.free(bytes),
        }
        self.* = undefined;
    }
};

fn decodeSnapshot(
    alloc: Allocator,
    bytes: []const u8,
    defaults: SnapshotDefaults,
) terminalpkg.snapshot.DecodeExactError!RestoredSnapshot {
    var reader: std.Io.Reader = .fixed(bytes);
    var decoded = try terminalpkg.snapshot.decodeExact(
        alloc,
        global.io(),
        &reader,
        .{ .max_continuation_bytes = 16 * 1024 * 1024 },
    );
    errdefer decoded.deinit(alloc);

    var terminal = decoded.toOwned();
    terminal.colors.palette.changeDefault(defaults.palette);
    terminal.colors.background.default = defaults.background;
    terminal.colors.foreground.default = defaults.foreground;
    terminal.colors.cursor.default = defaults.cursor;
    terminal.setDefaultCursorStyle(defaults.cursor_style);
    terminal.setDefaultCursorBlink(defaults.cursor_blink);

    return .{
        .terminal = terminal,
        .continuation = decoded.continuation,
    };
}

test "host-managed snapshot restore keeps program colors and applies renderer defaults" {
    const testing = std.testing;
    const RGB = terminalpkg.color.RGB;

    var source_palette = terminalpkg.color.default;
    source_palette[1] = .{ .r = 10, .g = 20, .b = 30 };
    var source = try terminalpkg.Terminal.init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .colors = .{
            .background = .init(.{ .r = 1, .g = 2, .b = 3 }),
            .foreground = .init(.{ .r = 4, .g = 5, .b = 6 }),
            .cursor = .init(.{ .r = 7, .g = 8, .b = 9 }),
            .palette = .init(source_palette),
        },
    });
    defer source.deinit(testing.allocator);
    source.colors.palette.set(1, .{ .r = 101, .g = 102, .b = 103 });
    source.colors.background.set(.{ .r = 111, .g = 112, .b = 113 });

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try terminalpkg.snapshot.encode(
        testing.allocator,
        &encoded.writer,
        &source,
        .{ .continuation = .ground },
    );

    var renderer_palette = terminalpkg.color.default;
    renderer_palette[1] = .{ .r = 20, .g = 30, .b = 40 };
    var restored = try decodeSnapshot(testing.allocator, encoded.written(), .{
        .palette = renderer_palette,
        .background = .{ .r = 21, .g = 22, .b = 23 },
        .foreground = .{ .r = 24, .g = 25, .b = 26 },
        .cursor = .{ .r = 27, .g = 28, .b = 29 },
        .cursor_style = .bar,
        .cursor_blink = false,
    });
    defer restored.deinit(testing.allocator);

    const terminal = &restored.terminal.?;
    try testing.expectEqual(renderer_palette[1], terminal.colors.palette.original[1]);
    try testing.expectEqual(RGB{ .r = 101, .g = 102, .b = 103 }, terminal.colors.palette.current[1]);
    try testing.expectEqual(RGB{ .r = 21, .g = 22, .b = 23 }, terminal.colors.background.default.?);
    try testing.expectEqual(RGB{ .r = 111, .g = 112, .b = 113 }, terminal.colors.background.override.?);
    try testing.expectEqual(RGB{ .r = 24, .g = 25, .b = 26 }, terminal.colors.foreground.default.?);
    try testing.expectEqual(RGB{ .r = 27, .g = 28, .b = 29 }, terminal.colors.cursor.default.?);
}

test "host-managed snapshot restore joins the first live byte exactly" {
    const testing = std.testing;
    const TerminalStream = @import("../terminal/stream_terminal.zig");

    const Case = struct {
        pending: []const u8,
        live: []const u8,
    };
    const cases = [_]Case{
        .{ .pending = "\xf0\x9f", .live = "\x98\x80" },
        .{ .pending = "\x1b[38;2;1;2", .live = ";3mZ" },
        .{ .pending = "\x1b]777;pending", .live = "\x1b\\Z" },
    };

    const Fixture = struct {
        fn inputCallback(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}

        fn resizeCallback(
            _: ?*anyopaque,
            _: u16,
            _: u16,
            _: u32,
            _: u32,
        ) callconv(.c) void {}

        fn encode(
            alloc: Allocator,
            terminal: *const terminalpkg.Terminal,
            stream: anytype,
        ) ![]u8 {
            var continuation: std.Io.Writer.Allocating = .init(alloc);
            defer continuation.deinit();
            try stream.writeContinuation(&continuation.writer);

            var encoded: std.Io.Writer.Allocating = .init(alloc);
            errdefer encoded.deinit();
            try terminalpkg.snapshot.encode(alloc, &encoded.writer, terminal, .{
                .continuation = if (continuation.written().len == 0)
                    .ground
                else
                    .{ .bytes = continuation.written() },
            });
            return encoded.toOwnedSlice();
        }
    };

    for (cases) |case| {
        var config = try configpkg.Config.default(testing.allocator);
        defer config.deinit();
        var renderer_wakeup = try xev.Async.init();
        defer renderer_wakeup.deinit();
        const renderer_mailbox = try renderer.Thread.Mailbox.create(testing.allocator);
        defer {
            while (renderer_mailbox.pop(global.io())) |_| {}
            renderer_mailbox.destroy(testing.allocator);
        }
        var io: Termio = undefined;
        var renderer_mutex: std.Io.Mutex = .init;
        var renderer_state: renderer.State = .{
            .mutex = &renderer_mutex,
            .terminal = &io.terminal,
        };
        io = io: {
            const size: renderer.Size = .{
                .screen = .{ .width = 64, .height = 48 },
                .cell = .{ .width = 8, .height = 16 },
                .padding = .{},
            };
            var derived = try DerivedConfig.init(testing.allocator, &config);
            errdefer derived.deinit();
            var terminal = try terminalpkg.Terminal.init(
                testing.io,
                testing.allocator,
                .{
                    .cols = size.grid().columns,
                    .rows = size.grid().rows,
                    .colors = .{
                        .background = .init(derived.background.toTerminalRGB()),
                        .foreground = .init(derived.foreground.toTerminalRGB()),
                        .cursor = cursor: {
                            const color = derived.cursor_color orelse break :cursor .unset;
                            const rgb = color.toTerminalRGB() orelse break :cursor .unset;
                            break :cursor .init(rgb);
                        },
                        .palette = .init(derived.palette),
                    },
                    .default_cursor_style = derived.cursor_style,
                    .default_cursor_blink = derived.cursor_blink,
                },
            );
            errdefer terminal.deinit(testing.allocator);
            var backend: termio.Backend = .{ .host_managed = .init(.{
                .userdata = null,
                .input = &Fixture.inputCallback,
                .resize = &Fixture.resizeCallback,
            }) };
            backend.initTerminal(&terminal);
            var mailbox = try termio.Mailbox.initSPSC(testing.allocator);
            errdefer mailbox.deinit(testing.allocator);
            break :io .{
                .alloc = testing.allocator,
                .backend = backend,
                .config = derived,
                .terminal = terminal,
                .renderer_state = &renderer_state,
                .renderer_wakeup = renderer_wakeup,
                .renderer_mailbox = renderer_mailbox,
                .surface_mailbox = undefined,
                .size = size,
                .mailbox = mailbox,
                .terminal_stream = undefined,
                .thread_enter_state = null,
            };
        };
        io.terminal_stream = .init(.{
            .allocator = testing.allocator,
            .handler = io.streamHandler(&io.terminal, false),
        });
        defer io.deinit();

        const palette = io.config.palette;
        const background = io.config.background.toTerminalRGB();
        const foreground = io.config.foreground.toTerminalRGB();
        const cursor = if (io.config.cursor_color) |color| color.toTerminalRGB() else null;
        var source = try terminalpkg.Terminal.init(testing.io, testing.allocator, .{
            .cols = 8,
            .rows = 3,
            .max_scrollback_lines = 4,
            .colors = .{
                .background = .init(background),
                .foreground = .init(foreground),
                .cursor = if (cursor) |color| .init(color) else .unset,
                .palette = .init(palette),
            },
            .default_cursor_style = io.config.cursor_style,
            .default_cursor_blink = io.config.cursor_blink,
        });
        defer source.deinit(testing.allocator);
        var source_stream: TerminalStream.Stream = .init(.{
            .allocator = testing.allocator,
            .handler = .init(&source),
            .continuation_max_bytes = 1024,
        });
        defer source_stream.deinit();
        source_stream.nextSlice("one\r\ntwo\r\nthree\r\nfour\r\n");
        source_stream.nextSlice("\x1b[?1049h\x1b[1;34mALT\x1b[?25l\x1b[?1049l");
        source_stream.nextSlice("\x1b[2;31m12345678");
        try source.setTitle("checkpoint title");
        try source.setPwd("file://localhost/checkpoint");
        source.colors.palette.set(1, .{ .r = 10, .g = 20, .b = 30 });
        source.colors.background.set(.{ .r = 11, .g = 21, .b = 31 });
        source_stream.nextSlice(case.pending);

        const checkpoint = try Fixture.encode(testing.allocator, &source, &source_stream);
        defer testing.allocator.free(checkpoint);
        source_stream.nextSlice(case.live);

        try io.restoreSnapshot(checkpoint);
        io.processOutput(case.live);
        const restored_terminal = &io.terminal;

        try testing.expectEqual(source.screens.active_key, restored_terminal.screens.active_key);
        try testing.expect(std.meta.eql(source.modes, restored_terminal.modes));
        try testing.expect(std.meta.eql(source.colors, restored_terminal.colors));
        try testing.expectEqualStrings(source.getTitle().?, restored_terminal.getTitle().?);
        try testing.expectEqualStrings(source.getPwd().?, restored_terminal.getPwd().?);
        for ([_]terminalpkg.ScreenSet.Key{ .primary, .alternate }) |key| {
            const source_screen = source.screens.get(key).?;
            const restored_screen = restored_terminal.screens.get(key).?;
            const source_text = try source_screen.dumpStringAlloc(
                testing.allocator,
                .{ .viewport = .{} },
            );
            defer testing.allocator.free(source_text);
            const restored_text = try restored_screen.dumpStringAlloc(
                testing.allocator,
                .{ .viewport = .{} },
            );
            defer testing.allocator.free(restored_text);
            try testing.expectEqualStrings(source_text, restored_text);
            try testing.expectEqual(source_screen.pages.scrollbar(), restored_screen.pages.scrollbar());
            try testing.expectEqual(source_screen.cursor.x, restored_screen.cursor.x);
            try testing.expectEqual(source_screen.cursor.y, restored_screen.cursor.y);
            try testing.expectEqual(source_screen.cursor.pending_wrap, restored_screen.cursor.pending_wrap);
            try testing.expectEqual(source_screen.cursor.style, restored_screen.cursor.style);
        }
    }
}

/// Get information about the process(es) attached to the backend. Returns
/// `null` if there was an error getting the information or the information is
/// not available on a particular platform.
pub fn getProcessInfo(self: *Termio, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.backend.getProcessInfo(info);
}
