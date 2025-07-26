// Copyright (c) 2025, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gl = @import("zgl");
const wayland = @import("wayland");
const zig_args = @import("zig-args");

const egl = @cImport({
    @cDefine("WL_EGL_PLATFORM", "1");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cUndef("WL_EGL_PLATFORM");
});

const wl = wayland.client.wl;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;

pub const opengl_error_handling = .assert;
pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

/// Global uniforms for custom shaders.
pub const Uniforms = extern struct {
    resolution: [3]f32 align(16) = .{ 0, 0, 0 },
    time: f32 align(4) = 1,
    time_delta: f32 align(4) = 1,
    frame_rate: f32 align(4) = 1,
    frame: i32 align(4) = 1,
    channel_time: [4]f32 align(16) = [_]f32{ 0, 0, 0, 0 },
    channel_resolution: [4][3]f32 align(16) = [1][3]f32{.{ 0, 0, 0 }} ** 4,
    mouse: [4]f32 align(16) = .{ 0, 0, 0, 0 },
    date: [4]f32 align(16) = .{ 0, 0, 0, 0 },
    sample_rate: f32 align(4) = 1,
};

/// An output that represents a physical display.
const Output = struct {
    allocator: Allocator,

    /// The Wayland object representing the output.
    output: *wl.Output,
    /// Whether the `done` event has been received. This flag is cleared if any property
    /// is updated until the compositor sends the `done` event again.
    ready: bool = false,

    /// The ID of the output.
    id: u32,
    /// The name of the output. Set by the `name` event.
    name: []const u8 = undefined,
    /// The human-friendly description of the output. Set by the `description` event.
    description: ?[]const u8 = null,
    /// The scale of this output. Defaults to 1. This only determines the scale of the
    /// output in the compositor, not the scale of the rendered content (which is
    /// determined by the `fractional_scale` object, if available). Set by the `scale` event.
    scale: u32 = 1,
    /// The width of the output in pixels. This is not affected by the scale. Set by the
    /// `mode` event.
    width: u32 = undefined,
    /// The height of the output in pixels. This is not affected by the scale. Set by the
    /// `mode` event.
    height: u32 = undefined,

    /// Create a new output object.
    pub fn create(allocator: Allocator, output: *wl.Output) !*Output {
        const self = try allocator.create(Output);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .output = output,
            .id = output.getId(),
        };
        output.setListener(*Output, listener, self);

        return self;
    }

    /// The listener callback. This should be passed to `wl.Output.setListener`.
    fn listener(output: *wl.Output, event: wl.Output.Event, self: *Output) void {
        self.handle(output, event);
    }

    /// Destroy the output object and free its resources.
    pub fn destroy(self: *Output) void {
        self.allocator.free(self.name);
        if (self.description) |description| self.allocator.free(description);
        self.allocator.destroy(self);
    }

    /// Handle an output event.
    fn handle(self: *Output, output: *wl.Output, event: wl.Output.Event) void {
        _ = output;

        switch (event) {
            .name => |name| {
                // FIXME: Correctly deallocate the previous name.
                self.ready = false;
                self.name = self.allocator.dupe(u8, std.mem.sliceTo(name.name, 0)) catch @panic("OOM");
            },
            .description => |description| {
                if (self.description) |d| self.allocator.free(d);
                self.ready = false;
                self.description = self.allocator.dupe(u8, std.mem.sliceTo(description.description, 0)) catch @panic("OOM");
            },
            .mode => |mode| {
                self.ready = false;

                if (mode.width <= 0) @panic("output width is non-positive?!");
                if (mode.height <= 0) @panic("output height is non-positive?!");

                self.width = @intCast(mode.width);
                self.height = @intCast(mode.height);
            },
            .scale => |scale| {
                self.ready = false;

                if (scale.factor <= 0) @panic("output scale factor is non-positive?!");

                self.scale = @intCast(scale.factor);
            },
            .done => {
                self.ready = true;
            },
            .geometry => {},
        }
    }

    /// Roundtrip the display until this output is ready.
    pub fn wait(self: *Output, display: *wl.Display) !void {
        while (!self.ready) {
            if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        }
    }
};

/// A registry listener. This is used to listen for and instantiate global objects.
const RegistryListener = struct {
    allocator: Allocator,

    /// The Wayland display object. This is used to perform roundtrips.
    display: *wl.Display,

    // Protocol objects
    compositor: ?*wl.Compositor,
    layer_shell_v1: ?*zwlr.LayerShellV1,
    fractional_scale_manager_v1: ?*wp.FractionalScaleManagerV1,
    viewporter_v1: ?*wp.Viewporter,

    /// The outputs currently available.
    outputs: std.ArrayListUnmanaged(*Output),

    /// The listener callback. This should be passed to `wl.Registry.setListener`.
    pub fn listener(registry: *wl.Registry, event: wl.Registry.Event, self: *RegistryListener) void {
        self.handle(registry, event);
    }

    /// Deinitialize the registry listener.
    pub fn deinit(self: *RegistryListener) void {
        if (self.layer_shell_v1) |layer_shell_v1| layer_shell_v1.destroy();
        if (self.fractional_scale_manager_v1) |fractional_scale_manager_v1| fractional_scale_manager_v1.destroy();

        for (self.outputs.items) |output| {
            output.destroy();
        }
        self.outputs.deinit(self.allocator);
    }

    /// Handle a registry event.
    fn handle(self: *RegistryListener, registry: *wl.Registry, event: wl.Registry.Event) void {
        switch (event) {
            .global => |global| {
                // Protocol objects
                if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    self.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
                } else if (std.mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                    self.layer_shell_v1 = registry.bind(global.name, zwlr.LayerShellV1, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.FractionalScaleManagerV1.interface.name) == .eq) {
                    self.fractional_scale_manager_v1 = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                    self.viewporter_v1 = registry.bind(global.name, wp.Viewporter, 1) catch return;
                }

                // Outputs
                if (std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                    const output = registry.bind(global.name, wl.Output, 4) catch return;
                    self.addOutput(output) catch |err| std.debug.panic("Failed to add output: {}", .{err});
                }
            },
            .global_remove => |global_remove| {
                _ = global_remove;
                // if (std.mem.orderZ(u8, global_remove.interface, wl.Output.interface.name) == .eq) {
                //     if (!self.removeOutput(global_remove.name)) {
                //         std.debug.print("!!! Removing output ID {} but it was not found!\n", .{global_remove.name});
                //     }
                // }
            },
        }
    }

    fn addOutput(self: *RegistryListener, wl_output: *wl.Output) !void {
        const output = try Output.create(self.allocator, wl_output);
        errdefer output.destroy();

        try output.wait(self.display);
        try self.outputs.append(self.allocator, output);
    }

    fn removeOutput(self: *RegistryListener, id: c_uint) bool {
        for (self.outputs.items, 0..) |item, i| {
            if (item.getId() == id) {
                item.destroy();
                self.outputs.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

/// A wlroots surface object. This is used for the wlroots shell layer to display a surface.
const WlrSurface = struct {
    allocator: Allocator,

    // --- EGL ---
    /// The EGL display handle.
    egl_display: egl.EGLDisplay,
    /// The configuration chosen for EGL.
    egl_config: egl.EGLConfig,
    /// The EGL context handle.
    egl_context: egl.EGLContext,
    /// The EGL surface created for the window.
    egl_surface: egl.EGLSurface,

    // --- State ---
    /// The current width of the surface.
    width: u32 = undefined,
    /// The current height of the surface.
    height: u32 = undefined,
    /// The current scale of the surface buffer.
    scale: u32 = undefined,
    /// The destination width of the surface after applying any scaling necessary for the output.
    destination_width: u32 = undefined,
    /// The destination height of the surface after applying any scaling necessary for the output.
    destination_height: u32 = undefined,

    // --- Wayland Core ---
    /// The Wayland EGL window.
    wl_egl_window: *wl.EglWindow,
    /// The output associated with this surface.
    output: *Output,
    /// The Wayland surface.
    wl_surface: *wl.Surface,

    // --- Fractional scale handling ---
    /// The fractional scale object associated with the wl_surface. If the compositor does not
    /// support fractional scaling, this will be null.
    fractional_scale: ?*FractionalScale,
    /// The viewport associated with the wl_surface. This is used to scale the surface back to
    /// native size in a fractionally-scaled output.
    viewport: ?*wp.Viewport,

    // --- wlroots Layer Shell ---
    /// The wlroots surface.
    wlr_surface: *zwlr.LayerSurfaceV1,

    /// Create a wlroots surface with EGL for GPU rendering.
    pub fn createEgl(allocator: Allocator, display: *wl.Display, compositor: *wl.Compositor, layer_shell: *zwlr.LayerShellV1, fractional_scale_manager: ?*wp.FractionalScaleManagerV1, viewporter: ?*wp.Viewporter, output: *Output) !*WlrSurface {
        const self = try allocator.create(WlrSurface);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.output = output;

        self.width = output.width;
        self.height = output.height;
        self.scale = output.scale;
        self.destination_width = output.width;
        self.destination_height = output.height;

        try self.initEgl(display);
        errdefer {
            _ = egl.eglDestroySurface(self.egl_display, self.egl_surface);
            _ = egl.eglTerminate(self.egl_display);
        }

        self.wl_surface = try compositor.createSurface();
        errdefer self.wl_surface.destroy();

        self.wl_egl_window = try wl.EglWindow.create(self.wl_surface, @intCast(self.width), @intCast(self.height));
        errdefer self.wl_egl_window.destroy();

        self.egl_surface = egl.eglCreatePlatformWindowSurface(
            self.egl_display,
            self.egl_config,
            @ptrCast(self.wl_egl_window),
            null,
        ) orelse switch (egl.eglGetError()) {
            egl.EGL_BAD_MATCH => return error.MismatchedConfig,
            egl.EGL_BAD_CONFIG => return error.InvalidConfig,
            egl.EGL_BAD_NATIVE_WINDOW => return error.InvalidNativeWindow,
            else => return error.FailedToCreateSurface,
        };
        errdefer _ = egl.eglDestroySurface(self.egl_display, self.egl_surface);

        self.wlr_surface = try layer_shell.getLayerSurface(self.wl_surface, output.output, .background, "papertoy");
        errdefer self.wlr_surface.destroy();

        self.wlr_surface.setListener(*WlrSurface, listener, self);

        self.wlr_surface.setSize(self.width, self.height);
        self.wl_surface.setBufferScale(@intCast(self.scale));

        // TODO: Make the user set this.
        self.wlr_surface.setAnchor(.{ .top = true, .left = true });

        if (fractional_scale_manager) |manager| {
            self.fractional_scale = try FractionalScale.create(allocator, manager, self.wl_surface);
            self.viewport = try viewporter.?.getViewport(self.wl_surface);
        } else {
            // No fractional scale manager available for the current compositor.
            std.log.warn("No fractional scale manager available, using output scale instead", .{});
            self.fractional_scale = null;
            self.viewport = null;
        }
        errdefer if (self.fractional_scale) |scale| scale.destroy(allocator);

        // Roundtrip once to sync the configuration.
        self.wl_surface.commit();
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        return self;
    }

    /// Deinitialize the wlroots surface.
    pub fn deinit(self: *WlrSurface) void {
        _ = egl.eglDestroyContext(self.egl_display, self.egl_context);
        _ = egl.eglTerminate(self.egl_display);
        if (self.fractional_scale) |scale| scale.destroy(self.allocator);
        if (self.viewport) |viewport| viewport.destroy();
        self.allocator.destroy(self);
    }

    /// Make the EGL context current.
    fn makeCurrent(self: *WlrSurface) !void {
        if (egl.eglMakeCurrent(self.egl_display, self.egl_surface, self.egl_surface, self.egl_context) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ACCESS => return error.EglThreadError,
                egl.EGL_BAD_MATCH => return error.MismatchedContextOrSurfaces,
                egl.EGL_BAD_NATIVE_WINDOW => return error.EglWindowInvalid,
                egl.EGL_BAD_CONTEXT => return error.InvalidEglContext,
                egl.EGL_BAD_ALLOC => return error.OutOfMemory,
                else => return error.EglUnknownError,
            }
        }
    }

    /// Swap the EGL buffers.
    fn swapBuffers(self: *WlrSurface) !void {
        if (egl.eglSwapBuffers(self.egl_display, self.egl_surface) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.InvalidDisplay,
                egl.EGL_BAD_SURFACE => return error.PresentInvalidSurface,
                egl.EGL_CONTEXT_LOST => return error.EGLContextLost,
                else => return error.EglUnknownError,
            }
        }
    }

    /// Create a callback object that will be called when it is an appropriate time to render a new
    /// frame.
    fn requestAnimationFrame(self: *WlrSurface) !*wl.Callback {
        return self.wl_surface.frame();
    }

    /// Synchronize changes in the output size and scale with the surface.
    /// Returns whether any changes were applied.
    pub fn synchronizeOutputChanges(self: *WlrSurface, display: *wl.Display) !bool {
        try self.output.wait(display);

        var destination_width = self.output.width;
        var destination_height = self.output.height;
        if (self.fractional_scale) |scale| {
            destination_width = scale.scaleSize(destination_width);
            destination_height = scale.scaleSize(destination_height);
        }

        const width_changed = self.output.width != self.width;
        const height_changed = self.output.height != self.height;
        const scale_changed = self.output.scale != self.scale;
        const destination_width_changed = destination_width != self.destination_width;
        const destination_height_changed = destination_height != self.destination_height;

        if (!width_changed and !height_changed and !scale_changed and !destination_width_changed and !destination_height_changed) {
            // No changes to apply.
            return false;
        }

        self.width = self.output.width;
        self.height = self.output.height;
        self.scale = self.output.scale;
        self.destination_width = destination_width;
        self.destination_height = destination_height;

        self.wl_surface.setBufferScale(@intCast(self.scale));
        self.wlr_surface.setSize(self.width, self.height);
        self.wl_egl_window.resize(@intCast(self.width), @intCast(self.height), 0, 0);
        std.log.debug("Surface resized to ({}, {}) with scale {}", .{ self.width, self.height, self.scale });

        if (self.viewport) |viewport| {
            viewport.setSource(.fromInt(0), .fromInt(0), .fromInt(@intCast(self.width)), .fromInt(@intCast(self.height)));
            viewport.setDestination(@intCast(self.destination_width), @intCast(self.destination_height));
            std.log.debug("Viewport set to source: ({}, {}, {}, {}), destination: ({}, {})", .{ 0, 0, self.width, self.height, self.destination_width, self.destination_height });
        }

        self.wl_surface.commit();
        return true;
    }

    /// Initialize EGL.
    fn initEgl(self: *WlrSurface, display: *wl.Display) !void {
        self.egl_display = egl.eglGetPlatformDisplay(egl.EGL_PLATFORM_WAYLAND_KHR, display, null);

        var egl_major: egl.EGLint = 0;
        var egl_minor: egl.EGLint = 0;
        if (egl.eglInitialize(self.egl_display, &egl_major, &egl_minor) == egl.EGL_TRUE) {
            std.log.debug("EGL version {}.{}", .{ egl_major, egl_minor });
        } else switch (egl.eglGetError()) {
            egl.EGL_BAD_DISPLAY => return error.EglBadDisplay,
            else => return error.EglUnknownError,
        }

        self.egl_config = egl_config: {
            // zig fmt: off
            const egl_attributes = [_:egl.EGL_NONE]egl.EGLint{
                egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
                egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
                egl.EGL_RED_SIZE,        8,
                egl.EGL_GREEN_SIZE,      8,
                egl.EGL_BLUE_SIZE,       8,
                egl.EGL_ALPHA_SIZE,      8,
            };
            // zig fmt: on

            var egl_config: egl.EGLConfig = null;
            var egl_config_count: egl.EGLint = 0;
            if (egl.eglChooseConfig(self.egl_display, &egl_attributes, &egl_config, 1, &egl_config_count) == egl.EGL_TRUE) {
                std.log.debug("EGL config count: {}", .{egl_config_count});
            } else switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return error.EglBadAttribute,
                else => return error.EglUnknownError,
            }

            break :egl_config egl_config;
        };

        if (egl.eglBindAPI(egl.EGL_OPENGL_API) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_PARAMETER => return error.EglOpenglUnsupported,
                else => return error.EglUnknownError,
            }
        }

        self.egl_context = egl_context: {
            const config_attributes = [_:egl.EGL_NONE]egl.EGLint{
                egl.EGL_CONTEXT_MAJOR_VERSION, 4,
                egl.EGL_CONTEXT_MINOR_VERSION, 3,
            };

            break :egl_context egl.eglCreateContext(self.egl_display, self.egl_config, egl.EGL_NO_CONTEXT, &config_attributes) orelse switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return error.InvalidContextAttribute,
                egl.EGL_BAD_CONTEXT => return error.EglBadContext,
                egl.EGL_BAD_MATCH => return error.UnsupportedConfig,
                else => return error.EglUnknownError,
            };
        };

        try gl.loadExtensions({}, getProcAddress);
    }

    fn getProcAddress(ctx: void, name: [:0]const u8) ?gl.binding.FunctionPointer {
        _ = ctx;
        return egl.eglGetProcAddress(name);
    }

    /// Handle a wlroots surface event.
    fn listener(wlr_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *WlrSurface) void {
        _ = self;

        switch (event) {
            .configure => |configure| {
                const serial = configure.serial;
                wlr_surface.ackConfigure(serial);
            },
            .closed => {},
        }
    }
};

/// A fractional scale object, getting the fractional scale for a Wayland surface.
/// The surface must live at least as long as the fractional scale object.
const FractionalScale = struct {
    /// The Wayland fractional scale object.
    fractional_scale: *wp.FractionalScaleV1,

    /// The preferred scale, set by the `preferred_scale` event, in 120ths.
    preferred_scale: u32 = undefined,
    /// Whether an initial `preferred_scale` event has been received.
    ready: bool = false,

    /// Create a new fractional scale object.
    pub fn create(allocator: Allocator, manager: *wp.FractionalScaleManagerV1, surface: *wl.Surface) !*FractionalScale {
        const self = try allocator.create(FractionalScale);
        errdefer allocator.destroy(self);

        self.fractional_scale = try manager.getFractionalScale(surface);
        self.fractional_scale.setListener(*FractionalScale, listener, self);

        return self;
    }

    /// Destroy the fractional scale object and free its resources.
    pub fn destroy(self: *FractionalScale, allocator: Allocator) void {
        self.fractional_scale.destroy();
        allocator.destroy(self);
    }

    /// Scale the given size by the preferred scale. If no preferred scale has been set yet,
    /// this will return the original size.
    pub fn scaleSize(self: *FractionalScale, size: u32) u32 {
        return if (self.ready)
            (size * 120) / self.preferred_scale
        else
            size;
    }

    /// The listener callback. This should be passed to `wp.FractionalScaleV1.setListener`.
    fn listener(fractional_scale: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, self: *FractionalScale) void {
        _ = fractional_scale;

        switch (event) {
            .preferred_scale => |preferred_scale| {
                self.preferred_scale = preferred_scale.scale;
                self.ready = true;
            },
        }
    }
};

const vs_source =
    \\#version 430 core
    \\
    \\layout(location = 0) in vec2 position;
    \\
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\}
;
const shadertoy_preamble = @embedFile("shadertoy_preamble.glsl");

const Options = struct {
    output: u32 = 0,
    help: bool = false,
};

pub fn printUsage() !void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    try stderr.writeAll(
        \\Usage: papertoy [options] SHADER_FILE
        \\
        \\Run a Shadertoy-compatible shader in a wlroots layer shell, rendering it as
        \\an animated wallpaper.
        \\
        \\Arguments:
        \\  SHADER_FILE       The path to the shader file to render. This should be a GLSL
        \\                    fragment shader that is compatible with the Shadertoy API.
        \\Options:
        \\  --output <index>  Specify the output index to render to (default: 0)
        \\  --help            Show this help message
        \\
    );
}

fn handleArgsError(err: zig_args.Error) !void {
    std.log.err("failed parsing command line arguments: {f}", .{err});
    try printUsage();
}

pub fn main() !u8 {
    const allocator = std.heap.c_allocator;

    const options = zig_args.parseForCurrentProcess(Options, allocator, .{ .forward = handleArgsError }) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.WriteFailed => return 1, // Nothing we can do about this.
        error.InvalidArguments => return 1, // `handleArgsError` will have handled this.
        else => |e| {
            std.log.err("failed parsing command line arguments: {}", .{e});
            try printUsage();
            return 1;
        },
    };
    defer options.deinit();

    if (options.options.help) {
        try printUsage();
        return 0;
    }

    if (options.positionals.len != 1) {
        std.log.err("must have exactly one positional argument (got {})", .{options.positionals.len});
        try printUsage();
        return 1;
    }
    const shader_path = options.positionals[0];

    // TODO: Investigate all try uses below and make them return a user-friendly error.

    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var registry_listener: RegistryListener = .{
        .allocator = allocator,
        .display = display,
        .compositor = null,
        .layer_shell_v1 = null,
        .fractional_scale_manager_v1 = null,
        .viewporter_v1 = null,
        .outputs = .{},
    };
    defer registry_listener.deinit();

    registry.setListener(*RegistryListener, RegistryListener.listener, &registry_listener);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = registry_listener.compositor orelse return error.NoWlCompositor;
    const layer_shell = registry_listener.layer_shell_v1 orelse return error.NoWlrLayerShellV1;

    if (registry_listener.outputs.items.len < options.options.output) {
        std.log.err("output index {} is out of bounds ({} outputs available)", .{ options.options.output, registry_listener.outputs.items.len });
        return 1;
    }

    // TODO: Support multiple outputs at once.
    const output = registry_listener.outputs.items[options.options.output];

    const surface = try WlrSurface.createEgl(allocator, display, compositor, layer_shell, registry_listener.fractional_scale_manager_v1, registry_listener.viewporter_v1, output);
    defer surface.deinit();

    try surface.makeCurrent();

    const vert = gl.Shader.create(.vertex);
    defer vert.delete();
    vert.source(1, &.{vs_source[0..]});
    vert.compile();

    const frag = gl.Shader.create(.fragment);
    defer frag.delete();

    {
        const fs_file = std.fs.cwd().readFileAlloc(allocator, shader_path, std.math.maxInt(usize)) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("shader file not found: {s}", .{shader_path});
                return 1;
            },
            else => |e| {
                std.log.err("failed to read shader file: {}", .{e});
                return 1;
            },
        };
        defer allocator.free(fs_file);

        frag.source(2, &.{ shadertoy_preamble[0..], fs_file });
        frag.compile();
    }

    const program = gl.Program.create();
    defer program.delete();

    program.attach(vert);
    program.attach(frag);
    program.link();

    var uniforms = Uniforms{
        .resolution = .{ @floatFromInt(output.width), @floatFromInt(output.height), 0 },
        .frame_rate = 60.0,
    };

    const vao = gl.VertexArray.create();
    defer vao.delete();
    vao.bind();

    // zig fmt: off
    const vertices = [_]f32{
        -1.0, -1.0,
         1.0, -1.0,
         1.0,  1.0,
        -1.0,  1.0,
    };
    // zig fmt: on

    const vbo = gl.Buffer.create();
    defer vbo.delete();
    {
        vbo.bind(.array_buffer);
        vbo.data(f32, vertices[0..], .static_draw);

        vao.attribFormat(0, 2, .float, false, 0);
        vao.attribBinding(0, 0);
        gl.bindVertexBuffer(0, vbo, 0, 2 * @sizeOf(f32));
        vao.enableVertexAttribute(0);
    }

    const ubo = gl.Buffer.create();
    defer ubo.delete();
    ubo.bind(.uniform_buffer);
    ubo.data(Uniforms, &.{uniforms}, .static_draw);
    gl.bindBufferBase(.uniform_buffer, 0, ubo);

    const ebo = gl.Buffer.create();
    defer ebo.delete();
    {
        ebo.bind(.element_array_buffer);
        ebo.data(u8, &.{
            0, 1, 2, // Top-left triangle
            2, 3, 0, // Bottom-right triangle
        }, .static_draw);
    }

    const first_frame_time = try std.time.Instant.now();
    var last_frame_time = first_frame_time;
    var render_frame = true;
    var frame: usize = 0;

    while (true) {
        if (try surface.synchronizeOutputChanges(display)) {
            uniforms.resolution = .{ @floatFromInt(surface.width), @floatFromInt(surface.height), 0 };
            gl.viewport(0, 0, surface.width, surface.height);
        }

        // For the first frame, we want to render immediately.
        if (frame > 0 and display.dispatch() != .SUCCESS) return error.DispatchFailed;

        if (!render_frame) continue;
        render_frame = false;
        frame += 1;

        const callback = try surface.requestAnimationFrame();
        callback.setListener(*bool, setRenderFrame, &render_frame);

        const now = try std.time.Instant.now();
        const since_ns: f32 = @floatFromInt(now.since(first_frame_time));
        const delta_ns: f32 = @floatFromInt(now.since(last_frame_time));
        uniforms.time = since_ns / std.time.ns_per_s;
        uniforms.time_delta = delta_ns / std.time.ns_per_s;
        uniforms.frame = @intCast(frame);
        last_frame_time = now;

        program.use();
        vao.bind();
        ubo.data(Uniforms, &.{uniforms}, .static_draw);

        gl.drawElements(.triangles, 6, .unsigned_byte, 0);

        try surface.swapBuffers();
    }

    return 0;
}

fn setRenderFrame(callback: *wl.Callback, event: wl.Callback.Event, render_frame: *bool) void {
    defer callback.destroy();
    switch (event) {
        .done => {
            render_frame.* = true;
        },
    }
}
