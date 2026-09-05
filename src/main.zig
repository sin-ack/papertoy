// Copyright (c) 2025, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gl = @import("zgl");
const wayland = @import("wayland");
const zig_args = @import("zig-args");

const Shader = @import("shader.zig").Shader;
const GlobalAttributes = @import("shader.zig").GlobalAttributes;

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
    name: ?[]const u8 = null,
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
    /// The refresh rate of the output in Hz (informative, not used for rendering).
    /// We pass it down to the shader in case it wants to use it.
    refresh_rate: u32 = undefined,
    /// The transform of the output. Set by the `geometry` event.
    transform: wl.Output.Transform = .normal,

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
        if (self.name) |n| self.allocator.free(n);
        if (self.description) |description| self.allocator.free(description);
        self.allocator.destroy(self);
    }

    /// Handle an output event.
    fn handle(self: *Output, output: *wl.Output, event: wl.Output.Event) void {
        _ = output;

        switch (event) {
            .name => |name| {
                if (self.name) |n| self.allocator.free(n);
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
                if (mode.refresh <= 0) @panic("output refresh rate is non-positive?!");

                self.width = @intCast(mode.width);
                self.height = @intCast(mode.height);
                self.refresh_rate = @intCast(@divTrunc(mode.refresh, 1000));
            },
            .scale => |scale| {
                self.ready = false;

                if (scale.factor <= 0) @panic("output scale factor is non-positive?!");

                self.scale = @intCast(scale.factor);
            },
            .done => {
                self.ready = true;
            },
            .geometry => |geometry| {
                self.transform = geometry.transform;
            },
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

/// Wrapper around the Wayland EGL display and configuration.
const GLDisplay = struct {
    /// The EGL display handle.
    egl_display: egl.EGLDisplay,
    /// The configuration chosen for EGL.
    egl_config: egl.EGLConfig,

    pub fn init(display: *wl.Display) !GLDisplay {
        var self: GLDisplay = .{
            .egl_display = egl.eglGetPlatformDisplay(egl.EGL_PLATFORM_WAYLAND_KHR, display, null),
            .egl_config = undefined,
        };

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

        try gl.loadExtensions({}, getProcAddress);

        return self;
    }

    pub fn deinit(self: *GLDisplay) void {
        _ = egl.eglTerminate(self.egl_display);
    }

    fn getProcAddress(ctx: void, name: [:0]const u8) ?gl.binding.FunctionPointer {
        _ = ctx;
        return egl.eglGetProcAddress(name);
    }
};

/// Wrapper around an EGL context for one output.
const GLContext = struct {
    /// The EGL display and config this context belongs to.
    gl_display: *GLDisplay,
    /// The EGL context handle.
    egl_context: egl.EGLContext,

    pub fn init(gl_display: *GLDisplay) !GLContext {
        const egl_context = egl_context: {
            const config_attributes = [_:egl.EGL_NONE]egl.EGLint{
                egl.EGL_CONTEXT_MAJOR_VERSION, 3,
                egl.EGL_CONTEXT_MINOR_VERSION, 3,
            };

            break :egl_context egl.eglCreateContext(gl_display.egl_display, gl_display.egl_config, egl.EGL_NO_CONTEXT, &config_attributes) orelse switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return error.InvalidContextAttribute,
                egl.EGL_BAD_CONTEXT => return error.EglBadContext,
                egl.EGL_BAD_MATCH => return error.UnsupportedConfig,
                else => return error.EglUnknownError,
            };
        };

        return .{
            .gl_display = gl_display,
            .egl_context = egl_context,
        };
    }

    pub fn deinit(self: *GLContext) void {
        _ = egl.eglDestroyContext(self.gl_display.egl_display, self.egl_context);
    }
};

/// A wlroots surface object. This is used for the wlroots shell layer to display a surface.
const WlrSurface = struct {
    allocator: Allocator,

    // --- EGL ---
    /// The EGL display and config shared by all output contexts.
    gl_display: *GLDisplay,
    /// The OpenGL context for this surface.
    gl_context: GLContext,
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
    /// The custom resolution to use for the surface set by the user. If set,
    /// overrides the output resolution.
    custom_resolution: ?Resolution = null,

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

    /// Pending configuration from the compositor.
    pending_config: ?struct {
        serial: u32,
        width: u32,
        height: u32,
    } = null,
    config_dirty: bool = false,

    /// Create a wlroots surface with EGL for GPU rendering.
    pub fn createEgl(allocator: Allocator, gl_display: *GLDisplay, compositor: *wl.Compositor, layer_shell: *zwlr.LayerShellV1, fractional_scale_manager: ?*wp.FractionalScaleManagerV1, viewporter: ?*wp.Viewporter, output: *Output, custom_resolution: ?Resolution) !*WlrSurface {
        const self = try allocator.create(WlrSurface);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.output = output;
        self.gl_display = gl_display;
        self.gl_context = try GLContext.init(gl_display);
        errdefer self.gl_context.deinit();

        self.destination_width = output.width;
        self.destination_height = output.height;
        self.custom_resolution = custom_resolution;

        if (custom_resolution) |resolution| {
            self.destination_width = resolution.width;
            self.destination_height = resolution.height;
        }

        self.width = self.destination_width;
        self.height = self.destination_height;
        self.scale = output.scale; // Initial scale guess, will be refined in handleConfiguration or by fractional scale

        self.wl_surface = try compositor.createSurface();
        errdefer self.wl_surface.destroy();

        self.wl_egl_window = try wl.EglWindow.create(self.wl_surface, @intCast(self.width), @intCast(self.height));
        errdefer self.wl_egl_window.destroy();

        self.egl_surface = egl.eglCreatePlatformWindowSurface(
            self.gl_display.egl_display,
            self.gl_display.egl_config,
            @ptrCast(self.wl_egl_window),
            null,
        ) orelse switch (egl.eglGetError()) {
            egl.EGL_BAD_MATCH => return error.MismatchedConfig,
            egl.EGL_BAD_CONFIG => return error.InvalidConfig,
            egl.EGL_BAD_NATIVE_WINDOW => return error.InvalidNativeWindow,
            else => return error.FailedToCreateSurface,
        };
        errdefer _ = egl.eglDestroySurface(self.gl_display.egl_display, self.egl_surface);

        self.wlr_surface = try layer_shell.getLayerSurface(self.wl_surface, output.output, .background, "papertoy");
        errdefer self.wlr_surface.destroy();

        self.wlr_surface.setListener(*WlrSurface, listener, self);

        // We want to ignore any exclusive zones set by other surfaces.
        self.wlr_surface.setExclusiveZone(-1);
        self.wlr_surface.setSize(self.destination_width, self.destination_height);
        if (fractional_scale_manager != null) {
            self.wl_surface.setBufferScale(1);
        } else {
            self.wl_surface.setBufferScale(@intCast(self.scale));
        }

        // Anchor to all 4 sides to fill the screen.
        self.wlr_surface.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });

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

        return self;
    }

    /// Deinitialize the wlroots surface.
    pub fn deinit(self: *WlrSurface) void {
        _ = egl.eglDestroySurface(self.gl_display.egl_display, self.egl_surface);
        self.gl_context.deinit();
        if (self.fractional_scale) |scale| scale.destroy(self.allocator);
        if (self.viewport) |viewport| viewport.destroy();
        self.allocator.destroy(self);
    }

    /// Make the EGL context current.
    fn makeCurrent(self: *WlrSurface) !void {
        if (egl.eglMakeCurrent(self.gl_display.egl_display, self.egl_surface, self.egl_surface, self.gl_context.egl_context) != egl.EGL_TRUE) {
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
        if (egl.eglSwapBuffers(self.gl_display.egl_display, self.egl_surface) != egl.EGL_TRUE) {
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

    /// Handle any pending configuration events from the compositor.
    /// Returns whether the surface size changed.
    pub fn handleConfiguration(self: *WlrSurface) !bool {
        if (!self.config_dirty) return false;
        const config = self.pending_config orelse return false;

        self.config_dirty = false;
        self.wlr_surface.ackConfigure(config.serial);

        // Determine the logical size of the surface.
        var logical_width = config.width;
        var logical_height = config.height;

        // If the compositor sends a zero dimension, it means we should decide
        // that size. Default only the zero axis to the output's logical size.
        if (logical_width == 0 or logical_height == 0) {
            var output_width = self.output.width;
            var output_height = self.output.height;

            // If the output is rotated 90 or 270 degrees, swap width and height.
            switch (self.output.transform) {
                .@"90", .@"270", .flipped_90, .flipped_270 => {
                    std.mem.swap(u32, &output_width, &output_height);
                },
                else => {},
            }

            if (logical_width == 0) logical_width = output_width / self.output.scale;
            if (logical_height == 0) logical_height = output_height / self.output.scale;
        }

        // Custom resolution overrides everything.
        if (self.custom_resolution) |resolution| {
            logical_width = resolution.width;
            logical_height = resolution.height;
        }

        var buffer_width = logical_width;
        var buffer_height = logical_height;
        var buffer_scale: i32 = @intCast(self.scale);

        if (self.fractional_scale) |fs| {
            buffer_width = fs.scaleSize(logical_width);
            buffer_height = fs.scaleSize(logical_height);
            buffer_scale = 1;
        } else {
            buffer_width = logical_width * self.output.scale;
            buffer_height = logical_height * self.output.scale;
            buffer_scale = @intCast(self.output.scale);
        }

        const width_changed = self.width != buffer_width;
        const height_changed = self.height != buffer_height;
        // We also need to check if destination size changed, or scale changed.
        const dest_width_changed = self.destination_width != logical_width;
        const dest_height_changed = self.destination_height != logical_height;
        const scale_changed = self.scale != buffer_scale;

        if (!width_changed and !height_changed and !dest_width_changed and !dest_height_changed and !scale_changed) return false;

        self.width = buffer_width;
        self.height = buffer_height;
        self.destination_width = logical_width;
        self.destination_height = logical_height;
        self.scale = @intCast(buffer_scale);

        self.wl_surface.setBufferScale(buffer_scale);
        self.wlr_surface.setSize(self.destination_width, self.destination_height);
        self.wl_egl_window.resize(@intCast(self.width), @intCast(self.height), 0, 0);

        std.log.debug("Surface configured: Buffer={}x{}, Logical={}x{}, Scale={}", .{ self.width, self.height, self.destination_width, self.destination_height, buffer_scale });

        if (self.viewport) |viewport| {
            viewport.setSource(.fromInt(0), .fromInt(0), .fromInt(@intCast(self.width)), .fromInt(@intCast(self.height)));
            viewport.setDestination(@intCast(self.destination_width), @intCast(self.destination_height));
        }

        return true;
    }

    /// Handle a wlroots surface event.
    fn listener(wlr_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *WlrSurface) void {
        _ = wlr_surface;

        switch (event) {
            .configure => |configure| {
                self.pending_config = .{
                    .serial = configure.serial,
                    .width = configure.width,
                    .height = configure.height,
                };
                self.config_dirty = true;
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
            (size * self.preferred_scale) / 120
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

const Resolution = struct {
    width: u32,
    height: u32,
};

const OutputConfig = struct {
    id: ?[]const u8 = null,
    resolution: ?Resolution = null,
    frame_rate: ?u32 = null,
};

// Global storage for output configurations parsed from CLI
var global_output_configs = std.ArrayListUnmanaged(OutputConfig){};

const OutputConfigCLI = struct {
    pub fn parse(str: []const u8) !OutputConfigCLI {
        const allocator = std.heap.c_allocator;
        const config = try parseOutputConfigString(allocator, str);
        try global_output_configs.append(allocator, config);
        return .{};
    }
};

const Options = struct {
    output: OutputConfigCLI = .{}, // Dummy field to trigger parsing
    @"frame-rate": ?u32 = null,
    resolution: ?[]const u8 = null,
    help: bool = false,
};

fn parseResolution(s: []const u8) !Resolution {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    var it = std.mem.splitScalar(u8, trimmed, 'x');
    const width_str = it.next() orelse return error.InvalidResolutionFormat;
    const height_str = it.next() orelse return error.InvalidResolutionFormat;
    if (it.next() != null) return error.InvalidResolutionFormat;

    const width = std.fmt.parseInt(u32, width_str, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidResolutionValue,
        error.Overflow => return error.ResolutionOverflow,
    };
    const height = std.fmt.parseInt(u32, height_str, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidResolutionValue,
        error.Overflow => return error.ResolutionOverflow,
    };
    if (width == 0 or height == 0) return error.ResolutionMustBePositive;
    return .{ .width = width, .height = height };
}

fn parseOutputConfigString(allocator: Allocator, s: []const u8) !OutputConfig {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return error.OutputIdRequired;

    if (std.mem.indexOfScalar(u8, trimmed, '=') == null) {
        if (std.mem.indexOfScalar(u8, trimmed, ',') != null) return error.InvalidOutputConfig;
        return .{ .id = try allocator.dupe(u8, trimmed) };
    }

    var config: OutputConfig = .{};
    errdefer if (config.id) |id| allocator.free(id);

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw_pair| {
        const pair = std.mem.trim(u8, raw_pair, " \t\r\n");
        if (pair.len == 0) return error.InvalidOutputConfig;

        var pair_it = std.mem.splitScalar(u8, pair, '=');
        const key = std.mem.trim(u8, pair_it.next() orelse return error.InvalidOutputConfig, " \t\r\n");
        const value = std.mem.trim(u8, pair_it.next() orelse return error.InvalidOutputConfig, " \t\r\n");
        if (pair_it.next() != null) return error.InvalidOutputConfig;

        if (std.mem.eql(u8, key, "id")) {
            if (value.len == 0) return error.OutputIdRequired;
            if (config.id != null) return error.DuplicateOutputId;
            config.id = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "resolution")) {
            if (config.resolution != null) return error.DuplicateResolution;
            config.resolution = try parseResolution(value);
        } else if (std.mem.eql(u8, key, "frame-rate")) {
            if (config.frame_rate != null) return error.DuplicateFrameRate;
            config.frame_rate = std.fmt.parseInt(u32, value, 10) catch |err| switch (err) {
                error.InvalidCharacter => return error.InvalidFrameRateValue,
                error.Overflow => return error.FrameRateOverflow,
            };
            if (config.frame_rate.? == 0) return error.FrameRateMustBePositive;
        } else {
            return error.UnknownOutputConfigKey;
        }
    }

    if (config.id == null) return error.OutputIdRequired;
    return config;
}

fn applyOutputConfigDefaults(config: *OutputConfig, resolution: ?Resolution, frame_rate: ?u32) void {
    if (config.resolution == null) config.resolution = resolution;
    if (config.frame_rate == null) config.frame_rate = frame_rate;
}

fn findDuplicateOutputConfig(configs: []const OutputConfig) ?[]const u8 {
    for (configs, 0..) |config, i| {
        const id = config.id.?;
        for (configs[i + 1 ..]) |other| {
            if (std.mem.eql(u8, id, other.id.?)) return id;
        }
    }
    return null;
}

test "parseResolution parses trimmed positive dimensions" {
    const resolution = try parseResolution(" 1920x1080 ");
    try std.testing.expectEqual(@as(u32, 1920), resolution.width);
    try std.testing.expectEqual(@as(u32, 1080), resolution.height);
}

test "parseResolution rejects malformed or zero dimensions" {
    try std.testing.expectError(error.InvalidResolutionFormat, parseResolution("1920"));
    try std.testing.expectError(error.InvalidResolutionFormat, parseResolution("1920x1080x60"));
    try std.testing.expectError(error.InvalidResolutionValue, parseResolution("widex1080"));
    try std.testing.expectError(error.ResolutionMustBePositive, parseResolution("0x1080"));
    try std.testing.expectError(error.ResolutionMustBePositive, parseResolution("1920x0"));
}

test "parseOutputConfigString accepts explicit config and legacy output shorthand" {
    const allocator = std.testing.allocator;

    const explicit = try parseOutputConfigString(allocator, "id=DP-1,resolution=1920x1080,frame-rate=60");
    defer allocator.free(explicit.id.?);
    try std.testing.expectEqualStrings("DP-1", explicit.id.?);
    try std.testing.expectEqual(@as(u32, 1920), explicit.resolution.?.width);
    try std.testing.expectEqual(@as(u32, 1080), explicit.resolution.?.height);
    try std.testing.expectEqual(@as(u32, 60), explicit.frame_rate.?);

    const shorthand = try parseOutputConfigString(allocator, " HDMI-A-1 ");
    defer allocator.free(shorthand.id.?);
    try std.testing.expectEqualStrings("HDMI-A-1", shorthand.id.?);
    try std.testing.expectEqual(@as(?Resolution, null), shorthand.resolution);
    try std.testing.expectEqual(@as(?u32, null), shorthand.frame_rate);
}

test "parseOutputConfigString rejects ambiguous and duplicate fields" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.OutputIdRequired, parseOutputConfigString(allocator, ""));
    try std.testing.expectError(error.OutputIdRequired, parseOutputConfigString(allocator, "resolution=1920x1080"));
    try std.testing.expectError(error.InvalidOutputConfig, parseOutputConfigString(allocator, "DP-1,HDMI-A-1"));
    try std.testing.expectError(error.DuplicateOutputId, parseOutputConfigString(allocator, "id=DP-1,id=HDMI-A-1"));
    try std.testing.expectError(error.DuplicateResolution, parseOutputConfigString(allocator, "id=DP-1,resolution=1920x1080,resolution=1280x720"));
    try std.testing.expectError(error.DuplicateFrameRate, parseOutputConfigString(allocator, "id=DP-1,frame-rate=60,frame-rate=30"));
    try std.testing.expectError(error.FrameRateMustBePositive, parseOutputConfigString(allocator, "id=DP-1,frame-rate=0"));
    try std.testing.expectError(error.ResolutionMustBePositive, parseOutputConfigString(allocator, "id=DP-1,resolution=0x1080"));
}

test "applyOutputConfigDefaults only fills missing values" {
    var config: OutputConfig = .{
        .id = "DP-1",
        .resolution = .{ .width = 1280, .height = 720 },
        .frame_rate = null,
    };

    applyOutputConfigDefaults(&config, .{ .width = 1920, .height = 1080 }, 30);
    try std.testing.expectEqual(@as(u32, 1280), config.resolution.?.width);
    try std.testing.expectEqual(@as(u32, 720), config.resolution.?.height);
    try std.testing.expectEqual(@as(u32, 30), config.frame_rate.?);
}

test "findDuplicateOutputConfig detects repeated output ids" {
    const configs = [_]OutputConfig{
        .{ .id = "DP-1" },
        .{ .id = "HDMI-A-1" },
        .{ .id = "DP-1" },
    };
    try std.testing.expectEqualStrings("DP-1", findDuplicateOutputConfig(&configs).?);

    const unique_configs = [_]OutputConfig{
        .{ .id = "DP-1" },
        .{ .id = "HDMI-A-1" },
    };
    try std.testing.expectEqual(@as(?[]const u8, null), findDuplicateOutputConfig(&unique_configs));
}

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
        \\  --output <config>  Configure individual outputs. Can be specified multiple times.
        \\                     Format: "id=<name>[,resolution=<WxH>][,frame-rate=<fps>]"
        \\                     Compatibility shorthand: --output <name>
        \\                     Example: --output "id=DP-1,resolution=1920x1080,frame-rate=60"
        \\                     If not specified, renders on all available outputs.
        \\  --frame-rate <fps> Set a default frame rate for selected outputs (default: native)
        \\  --resolution <WxH> Set a default positive logical resolution for selected outputs
        \\  --help             Show this help message
        \\
    );
}

fn handleArgsError(err: zig_args.Error) !void {
    std.log.err("failed parsing command line arguments: {f}", .{err});
    try printUsage();
}

const FramePacing = struct {
    callback: *wl.Callback,
    target_frame_interval_ns: ?u64 = null,
    next_frame_time: u64 = 0,
};

const Paper = struct {
    /// The allocator used for this paper's resources.
    allocator: Allocator,
    /// The Wayland surface associated with this paper.
    surface: *WlrSurface,
    /// The shader program being rendered.
    shader: *Shader,
    /// Global shader attributes (e.g. time, resolution).
    global_attributes: GlobalAttributes,
    /// Whether a new frame should be rendered. True when a frame callback is received (vsync).
    render_frame: bool = false,
    /// Frame callback plus optional frame-rate cap for this surface.
    frame_pacing: FramePacing,

    pub fn create(
        allocator: Allocator,
        gl_display: *GLDisplay,
        compositor: *wl.Compositor,
        layer_shell: *zwlr.LayerShellV1,
        fractional_scale_manager: ?*wp.FractionalScaleManagerV1,
        viewporter: ?*wp.Viewporter,
        output: *Output,
        custom_resolution: ?Resolution,
        shader_source: []const u8,
        target_frame_rate: ?u32,
    ) !*Paper {
        const self = try allocator.create(Paper);
        errdefer allocator.destroy(self);

        self.allocator = allocator;

        self.surface = try WlrSurface.createEgl(allocator, gl_display, compositor, layer_shell, fractional_scale_manager, viewporter, output, custom_resolution);
        errdefer self.surface.deinit();

        try self.surface.makeCurrent();

        self.global_attributes = GlobalAttributes.init();
        errdefer self.global_attributes.deinit();
        self.global_attributes.bind();

        self.shader = try Shader.create(allocator, shader_source, .{ .width = self.surface.width, .height = self.surface.height }, target_frame_rate orelse output.refresh_rate);
        errdefer self.shader.destroy(allocator);

        self.render_frame = false;
        self.frame_pacing = .{
            .callback = try self.surface.requestAnimationFrame(),
            .target_frame_interval_ns = if (target_frame_rate) |fps| @as(u64, std.time.ns_per_s) / fps else null,
        };
        self.frame_pacing.callback.setListener(*bool, setRenderFrame, &self.render_frame);

        return self;
    }

    pub fn destroy(self: *Paper) void {
        self.surface.makeCurrent() catch {};
        self.shader.destroy(self.allocator);
        self.global_attributes.deinit();
        self.frame_pacing.callback.destroy();
        self.surface.deinit();
        self.allocator.destroy(self);
    }
};

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

    const default_resolution = if (options.options.resolution) |resolution|
        parseResolution(resolution) catch |err| {
            std.log.err("invalid --resolution '{s}': {}", .{ resolution, err });
            return 1;
        }
    else
        null;

    const default_frame_rate = if (options.options.@"frame-rate") |frame_rate| frame_rate: {
        if (frame_rate == 0) {
            std.log.err("frame rate must be positive, got 0", .{});
            return 1;
        }
        break :frame_rate frame_rate;
    } else null;

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

    const shader_source = std.fs.cwd().readFileAlloc(allocator, shader_path, std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("shader file not found: {s}", .{shader_path});
            return 1;
        },
        else => |e| {
            std.log.err("failed to read shader file: {}", .{e});
            return 1;
        },
    };
    defer allocator.free(shader_source);

    defer {
        for (global_output_configs.items) |output_config| {
            if (output_config.id) |id| allocator.free(id);
        }
        global_output_configs.deinit(allocator);
    }

    if (global_output_configs.items.len == 0) {
        // No specific outputs requested, use all available outputs with the
        // global defaults from legacy options, if any.
        for (registry_listener.outputs.items) |output| {
            try output.wait(display); // Ensure output is ready
            try global_output_configs.append(allocator, .{
                .id = try allocator.dupe(u8, output.name.?),
                .resolution = default_resolution,
                .frame_rate = default_frame_rate,
            });
        }
    } else {
        for (global_output_configs.items) |*output_config| {
            applyOutputConfigDefaults(output_config, default_resolution, default_frame_rate);
        }
    }

    if (global_output_configs.items.len == 0) {
        std.log.err("no outputs configured, cannot render", .{});
        return 1;
    }

    if (findDuplicateOutputConfig(global_output_configs.items)) |id| {
        std.log.err("duplicate output id in --output config: {s}", .{id});
        return 1;
    }

    var gl_display = try GLDisplay.init(display);
    defer gl_display.deinit();

    var papers = std.ArrayListUnmanaged(*Paper){};
    defer {
        for (papers.items) |paper| paper.destroy();
        papers.deinit(allocator);
    }

    for (global_output_configs.items) |output_config| {
        const output_id = output_config.id.?;
        // Find the actual output based on the ID
        var selected_output: ?*Output = null;
        for (registry_listener.outputs.items) |output| {
            try output.wait(display); // Ensure output is ready
            if (std.mem.eql(u8, output.name.?, output_id)) {
                selected_output = output;
                break;
            }
        }

        const output = selected_output orelse {
            std.log.err("output with name '{s}' not found", .{output_id});
            std.log.info("available outputs:", .{});
            for (registry_listener.outputs.items) |out| {
                std.log.info("- {s} ({}x{}, {}Hz)", .{
                    out.name orelse "unknown",
                    out.width,
                    out.height,
                    out.refresh_rate,
                });
            }
            return 1;
        };

        const target_resolution = output_config.resolution;

        const paper = try Paper.create(
            allocator,
            &gl_display,
            compositor,
            layer_shell,
            registry_listener.fractional_scale_manager_v1,
            registry_listener.viewporter_v1,
            output,
            target_resolution,
            shader_source,
            output_config.frame_rate,
        );
        try papers.append(allocator, paper);
        if (output_config.frame_rate) |fps| {
            std.log.info("Rendering on output: {s} (resolution: {}x{}, frame-rate: {})", .{
                output.name.?,
                paper.surface.destination_width,
                paper.surface.destination_height,
                fps,
            });
        } else {
            std.log.info("Rendering on output: {s} (resolution: {}x{}, frame-rate: native)", .{
                output.name.?,
                paper.surface.destination_width,
                paper.surface.destination_height,
            });
        }
    }

    // Initial roundtrip to receive the first configure event from the compositor.
    // We must acknowledge this event before we can attach any buffers (render).
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    for (papers.items) |paper| {
        _ = try paper.surface.handleConfiguration();
    }

    while (true) {
        // Always dispatch pending events first.
        const dispatched = display.dispatchPending();
        if (dispatched != .SUCCESS) return error.DispatchFailed;

        const now = try std.time.Instant.now();
        const now_ns = now.since(std.mem.zeroes(std.time.Instant));

        var smallest_frame_cap_sleep_time: ?u64 = null;
        var rendered_count: usize = 0;

        for (papers.items) |paper| {
            var should_render_this_frame = false;
            if (paper.shader.frame == 0 or paper.render_frame) {
                if (paper.frame_pacing.target_frame_interval_ns) |frame_interval_ns| {
                    if (paper.shader.frame == 0 or now_ns >= paper.frame_pacing.next_frame_time) {
                        should_render_this_frame = true;
                        paper.render_frame = false;
                        paper.frame_pacing.next_frame_time = now_ns + frame_interval_ns;
                    } else {
                        const sleep_time = paper.frame_pacing.next_frame_time - now_ns;
                        if (smallest_frame_cap_sleep_time == null or sleep_time < smallest_frame_cap_sleep_time.?) {
                            smallest_frame_cap_sleep_time = sleep_time;
                        }
                    }
                } else {
                    should_render_this_frame = true;
                    paper.render_frame = false;
                }
            }

            if (!should_render_this_frame) continue;

            // We are going to render
            rendered_count += 1;

            try paper.surface.makeCurrent();

            _ = try paper.surface.handleConfiguration();
            // Update viewport and resolution uniforms every frame because each output may have
            // a different configured size.
            paper.shader.resolution = .{ .width = paper.surface.width, .height = paper.surface.height };
            gl.viewport(0, 0, paper.surface.width, paper.surface.height);

            paper.global_attributes.bind();
            try paper.shader.render();

            paper.frame_pacing.callback.destroy();
            paper.frame_pacing.callback = try paper.surface.requestAnimationFrame();
            paper.frame_pacing.callback.setListener(*bool, setRenderFrame, &paper.render_frame);

            try paper.surface.swapBuffers();
        }

        if (rendered_count == 0) {
            // If nothing was rendered, wait for events or the next capped frame time.
            if (smallest_frame_cap_sleep_time) |sleep_time| {
                var fds = [_]std.posix.pollfd{.{
                    .fd = display.getFd(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                _ = std.posix.poll(&fds, @intCast(sleep_time / 1_000_000)) catch {};
            } else {
                // If no custom frame rates, and nothing rendered, just block for events.
                if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
            }
        }
    }

    return 0;
}

fn setRenderFrame(callback: *wl.Callback, event: wl.Callback.Event, render_frame: *bool) void {
    _ = callback;
    switch (event) {
        .done => {
            render_frame.* = true;
        },
    }
}
