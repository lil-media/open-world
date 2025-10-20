const std = @import("std");
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

    pub fn init(width: u32, height: u32, title: [*:0]const u8) !SDLWindow {
        if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
            std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLInitFailed;
        }

        const window = c.SDL_CreateWindow(
            title,
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            @intCast(width),
            @intCast(height),
            c.SDL_WINDOW_METAL | c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
        ) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.WindowCreationFailed;
        };

        const metal_view = c.SDL_Metal_CreateView(window) orelse {
            std.debug.print("SDL_Metal_CreateView failed: {s}\n", .{c.SDL_GetError()});
            return error.MetalViewCreationFailed;
        };

        return SDLWindow{
            .window = window,
            .metal_view = metal_view,
            .should_close = false,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *SDLWindow) void {
        c.SDL_Metal_DestroyView(self.metal_view);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn pollEvents(self: *SDLWindow) void {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => self.should_close = true,
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.sym == c.SDLK_ESCAPE) {
                        self.should_close = true;
                    }
                },
                c.SDL_WINDOWEVENT => {
                    if (event.window.event == c.SDL_WINDOWEVENT_RESIZED) {
                        self.width = @intCast(event.window.data1);
                        self.height = @intCast(event.window.data2);
                    }
                },
                else => {},
            }
        }
    }
};
