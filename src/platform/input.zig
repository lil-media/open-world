const std = @import("std");
const math = @import("../utils/math.zig");

pub const max_keys = 512;
pub const max_mouse_buttons = 8;
pub const max_text_input = 64;

/// Common keyboard keys mapped to SDL scancodes for convenience.
pub const Key = enum(u16) {
    escape = 41,
    space = 44,
    enter = 40,
    w = 26,
    a = 4,
    s = 22,
    d = 7,
    q = 20,
    e = 8,
    r = 21,
    f = 9,
    f1 = 58,
    f2 = 59,
    f3 = 60,
    f4 = 61,
    f5 = 62,
    f6 = 63,
    f7 = 64,
    f8 = 65,
    f9 = 66,
    f10 = 67,
    f11 = 68,
    f12 = 69,
    plus = 46,
    minus = 45,
    backspace = 42,
    x = 27,
    delete = 76,
    shift_left = 225,
    ctrl_left = 224,
    alt_left = 226,
    up = 82,
    down = 81,
    left = 80,
    right = 79,
};

/// Mouse buttons matched to SDL constants.
pub const MouseButton = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    x1 = 4,
    x2 = 5,
};

/// Aggregated per-frame input state.
pub const InputState = struct {
    keys: [max_keys]bool = [_]bool{false} ** max_keys,
    keys_pressed: [max_keys]bool = [_]bool{false} ** max_keys,
    keys_released: [max_keys]bool = [_]bool{false} ** max_keys,

    mouse_buttons: [max_mouse_buttons]bool = [_]bool{false} ** max_mouse_buttons,
    mouse_pressed: [max_mouse_buttons]bool = [_]bool{false} ** max_mouse_buttons,
    mouse_released: [max_mouse_buttons]bool = [_]bool{false} ** max_mouse_buttons,

    mouse_position: math.Vec2 = math.Vec2.zero(),
    mouse_delta: math.Vec2 = math.Vec2.zero(),
    scroll_delta: math.Vec2 = math.Vec2.zero(),
    text_input: [max_text_input]u8 = [_]u8{0} ** max_text_input,
    text_input_len: usize = 0,

    /// Reset transient per-frame values (call once at frame begin).
    pub fn beginFrame(self: *InputState) void {
        @memset(self.keys_pressed[0..], false);
        @memset(self.keys_released[0..], false);
        @memset(self.mouse_pressed[0..], false);
        @memset(self.mouse_released[0..], false);
        self.mouse_delta = math.Vec2.zero();
        self.scroll_delta = math.Vec2.zero();
        self.text_input_len = 0;
    }

    /// Update key state from a scancode event.
    pub fn handleKey(self: *InputState, scancode: u16, is_down: bool) void {
        if (scancode >= max_keys) return;

        if (is_down) {
            if (!self.keys[scancode]) {
                self.keys_pressed[scancode] = true;
            }
            self.keys[scancode] = true;
        } else {
            if (self.keys[scancode]) {
                self.keys_released[scancode] = true;
            }
            self.keys[scancode] = false;
        }
    }

    /// Update mouse button state.
    pub fn handleMouseButton(self: *InputState, button: u8, is_down: bool) void {
        if (button == 0 or button > max_mouse_buttons) return;
        const idx = button - 1;

        if (is_down) {
            if (!self.mouse_buttons[idx]) {
                self.mouse_pressed[idx] = true;
            }
            self.mouse_buttons[idx] = true;
        } else {
            if (self.mouse_buttons[idx]) {
                self.mouse_released[idx] = true;
            }
            self.mouse_buttons[idx] = false;
        }
    }

    /// Update relative mouse motion.
    pub fn handleMouseMotion(self: *InputState, delta_x: f32, delta_y: f32) void {
        self.mouse_delta = self.mouse_delta.add(math.Vec2.init(delta_x, delta_y));
    }

    /// Update absolute mouse position.
    pub fn setMousePosition(self: *InputState, x: f32, y: f32) void {
        self.mouse_position = math.Vec2.init(x, y);
    }

    /// Update scroll wheel delta.
    pub fn handleMouseWheel(self: *InputState, delta_x: f32, delta_y: f32) void {
        self.scroll_delta = self.scroll_delta.add(math.Vec2.init(delta_x, delta_y));
    }

    /// Append UTF-8 text input captured this frame.
    pub fn handleTextInput(self: *InputState, text: []const u8) void {
        for (text) |ch| {
            if (self.text_input_len >= max_text_input) break;
            self.text_input[self.text_input_len] = ch;
            self.text_input_len += 1;
        }
    }

    /// Consume accumulated text input (resets the buffer).
    pub fn takeTextInput(self: *InputState) []const u8 {
        const slice = self.text_input[0..self.text_input_len];
        self.text_input_len = 0;
        return slice;
    }

    /// Check if a key is currently held down.
    pub fn isKeyDown(self: *const InputState, key: Key) bool {
        return self.keys[@intFromEnum(key)];
    }

    /// Check if a key was pressed this frame.
    pub fn wasKeyPressed(self: *const InputState, key: Key) bool {
        return self.keys_pressed[@intFromEnum(key)];
    }

    /// Check if a key was released this frame.
    pub fn wasKeyReleased(self: *const InputState, key: Key) bool {
        return self.keys_released[@intFromEnum(key)];
    }

    /// Check if a mouse button is currently held.
    pub fn isMouseDown(self: *const InputState, button: MouseButton) bool {
        return self.mouse_buttons[@intFromEnum(button) - 1];
    }

    /// Check if a mouse button was pressed this frame.
    pub fn wasMousePressed(self: *const InputState, button: MouseButton) bool {
        return self.mouse_pressed[@intFromEnum(button) - 1];
    }

    /// Check if a mouse button was released this frame.
    pub fn wasMouseReleased(self: *const InputState, button: MouseButton) bool {
        return self.mouse_released[@intFromEnum(button) - 1];
    }
};
