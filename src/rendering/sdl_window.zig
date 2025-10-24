const std = @import("std");
const input = @import("../platform/input.zig");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_metal.h");
});

pub const SDLWindow = struct {
    window: *c.SDL_Window,
    metal_view: *anyopaque,
    should_close: bool,
    width: u32,
    height: u32,
    cursor_locked: bool,

    pub fn init(width: u32, height: u32, title: [*:0]const u8) !SDLWindow {
        if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
            std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLInitFailed;
        }

        const window = c.SDL_CreateWindow(
            title,
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            @as(c_int, @intCast(width)),
            @as(c_int, @intCast(height)),
            c.SDL_WINDOW_METAL | c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
        ) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.WindowCreationFailed;
        };

        const metal_view = c.SDL_Metal_CreateView(window) orelse {
            std.debug.print("SDL_Metal_CreateView failed: {s}\n", .{c.SDL_GetError()});
            return error.MetalViewCreationFailed;
        };

        // Start with cursor locked for FPS controls
        _ = c.SDL_SetRelativeMouseMode(c.SDL_TRUE);

        return SDLWindow{
            .window = window,
            .metal_view = metal_view,
            .should_close = false,
            .width = width,
            .height = height,
            .cursor_locked = true,
        };
    }

    pub fn deinit(self: *SDLWindow) void {
        c.SDL_Metal_DestroyView(self.metal_view);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn pollEvents(self: *SDLWindow, input_state: ?*input.InputState) void {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => self.should_close = true,
                c.SDL_KEYDOWN => {
                    if (input_state) |state| {
                        state.handleKey(@as(u16, @intCast(event.key.keysym.scancode)), true);
                    }
                },
                c.SDL_KEYUP => {
                    if (input_state) |state| {
                        state.handleKey(@as(u16, @intCast(event.key.keysym.scancode)), false);
                    }
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    if (input_state) |state| {
                        state.handleMouseButton(@as(u8, @intCast(event.button.button)), true);
                    }
                },
                c.SDL_MOUSEBUTTONUP => {
                    if (input_state) |state| {
                        state.handleMouseButton(@as(u8, @intCast(event.button.button)), false);
                    }
                },
                c.SDL_MOUSEMOTION => {
                    if (input_state) |state| {
                        state.handleMouseMotion(
                            @as(f32, @floatFromInt(event.motion.xrel)),
                            @as(f32, @floatFromInt(event.motion.yrel)),
                        );
                        state.setMousePosition(
                            @as(f32, @floatFromInt(event.motion.x)),
                            @as(f32, @floatFromInt(event.motion.y)),
                        );
                    }
                },
                c.SDL_MOUSEWHEEL => {
                    if (input_state) |state| {
                        state.handleMouseWheel(
                            @as(f32, @floatFromInt(event.wheel.x)),
                            @as(f32, @floatFromInt(event.wheel.y)),
                        );
                    }
                },
                c.SDL_WINDOWEVENT => {
                    if (event.window.event == c.SDL_WINDOWEVENT_RESIZED) {
                        self.width = @as(u32, @intCast(event.window.data1));
                        self.height = @as(u32, @intCast(event.window.data2));
                    }
                },
                c.SDL_TEXTINPUT => {
                    if (input_state) |state| {
                        var text_len: usize = 0;
                        while (text_len < event.text.text.len and event.text.text[text_len] != 0) : (text_len += 1) {}
                        state.handleTextInput(event.text.text[0..text_len]);
                    }
                },
                else => {},
            }
        }
    }

    pub fn setCursorLocked(self: *SDLWindow, locked: bool) void {
        self.cursor_locked = locked;
        _ = c.SDL_SetRelativeMouseMode(if (locked) c.SDL_TRUE else c.SDL_FALSE);
        _ = c.SDL_ShowCursor(if (locked) c.SDL_DISABLE else c.SDL_ENABLE);
    }

    pub fn toggleCursorLock(self: *SDLWindow) void {
        self.setCursorLocked(!self.cursor_locked);
    }

    pub fn startTextInput(_: *SDLWindow) void {
        c.SDL_StartTextInput();
    }

    pub fn stopTextInput(_: *SDLWindow) void {
        c.SDL_StopTextInput();
    }
};
