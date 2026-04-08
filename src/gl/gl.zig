const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const c = @cImport({
    @cDefine("RGFW_OPENGL", {});
    @cDefine("RGFW_ADVANCED_SMOOTH_RESIZE", {});
    @cInclude("thirdparty/RGFW/RGFW.h");

    @cInclude("thirdparty/lodepng/lodepng.h");
});

pub const g = @cImport({
    @cInclude("thirdparty/glad.h");
    @cInclude("GL/gl.h");
});

pub const Texture = @import("texture.zig");
pub const Font = @import("font.zig");

const base_vs_src = @embedFile("resources/shaders/base_vertex.glsl");
const base_fs_src = @embedFile("resources/shaders/base_fragment.glsl");
const font_fs_src = @embedFile("resources/shaders/font_fragment.glsl");

const default_font_path = "C:/Windows/Fonts/simhei.ttf";

pub const Vec2 = [2]f32;
pub const Vec3 = [3]f32;
pub const Vec4 = [4]f32;

pub const Vec2u = [2]g.GLuint;
pub const Vec3u = [3]g.GLuint;

pub const Vec2i = [2]g.GLint;

pub const ShaderError = error { ShaderCompileError };
pub const ProgramError = error {
    LinkError,
} || ShaderError;

pub const RGBA = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const white = RGBA { .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black = RGBA { .r = 0, .g = 0, .b = 0, .a = 0xff };
    pub const red = RGBA { .r = 0xff, .g = 0x00, .b = 0, .a = 0xff };
    pub const yellow = RGBA { .r = 0xff, .g = 0xff, .b = 0, .a = 0xff };
    pub const transparent = RGBA { .r = 0, .b = 0, .g = 0, .a = 0};

    pub fn to_vec4(rgba: RGBA) Vec4 {
        return .{
            @as(f32, @floatFromInt(rgba.r)) / 255.0,
            @as(f32, @floatFromInt(rgba.g)) / 255.0,
            @as(f32, @floatFromInt(rgba.b)) / 255.0,
            @as(f32, @floatFromInt(rgba.a)) / 255.0,
        };
    }

    pub fn from_vec4(v4: Vec4) RGBA {
        return .{
            .r = @intFromFloat(v4[0] * 255.0),
            .g = @intFromFloat(v4[1] * 255.0),
            .b = @intFromFloat(v4[2] * 255.0),
            .a = @intFromFloat(v4[3] * 255.0),
        };
    }

    pub fn from_u32(u: u32) RGBA {
        if (comptime @import("builtin").cpu.arch.endian() == .little)
            return @bitCast(@byteSwap(u))
        else
            return @bitCast(u);
    }

    pub fn gamma(rgba: RGBA, exp: f32) RGBA {
        var v4 = rgba.to_vec4();
        for (&v4) |*i| {
            i.* = std.math.pow(f32, i.*, exp);
        }

        return .from_vec4(v4);
    }
};

pub const BaseVertexData = extern struct {
    pos: Vec3,
    rgba: Vec4,
    tex: Vec2,
};

pub const GLObj = g.GLuint;

pub fn vec2_to_vec3(v2: Vec2) Vec3 {
    return .{ v2[0], v2[1], 0 };
}

pub const KeyState = enum {
    idle,
    pressed,
    hold,
};

pub const Context = struct {
    const atlas_size: Vec2u = .{ 1024, 1024 };

    pub const code_first_char = ' ';
    pub const code_last_char = '~';
    pub const code_char_num = code_last_char - code_first_char + 1;

    pub const font_pixels = 32.0;
    pub const display_font_pixels = 64.0;

    const rect_tex_coord = [_]Vec2 {
        .{1, 0},
        .{0, 0},
        .{0, 1},
        .{1, 1},
    };

    a: Allocator,

    window: *c.RGFW_window,

    render_fn: *const fn (ctx: *Self) void,

    base_shader_pgm: GLObj,
    base_vert_shader: GLObj,
    base_frag_shader: GLObj,

    font_frag_shader: GLObj,
    font_shader_pgm: GLObj,

    base_VBO: GLObj,
    base_VAO: GLObj,
    rect_EBO: GLObj,

    batch_VBO: GLObj,
    batch_VAO: GLObj,
    batch_EBO: GLObj,

    rect_EBO_list: std.ArrayList([2]Vec3u), // each rectangle consist of two triangles

    bitmap_tex: Texture,
    white_tex: Texture,

    fonts: Font.Dynamic,
    default_font: Font,
    active_font: Font,

    w: i32,
    h: i32,
    vierwport_size: u32,
    aspect_ratio: f32, // width / height
    pixel_scale: f32, // how big is a pixel in gl coordinate

    mouse_pos_screen: Vec2i,
    mouse_pos_gl: Vec2,
    mouse_delta: Vec2,

    mouse_scroll: Vec2,

    composition_codepoints: std.ArrayList(u21),

    is_paste: bool,

    last_frame_time_us: i64,
    delta_time_us: i64,

    const Self = @This();
    pub fn init(self: *Self, render_fn: *const fn (ctx: *Self) void,
        title: [:0]const u8, w: i32, h: i32, gpa: Allocator) !void {

        self.window = c.RGFW_createWindow(title, 0, 0, w, h, 
            c.RGFW_windowCenter
            // | c.RGFW_windowNoResize
            | c.RGFW_windowOpenGL) orelse unreachable;
        c.RGFW_window_makeCurrentWindow_OpenGL(self.window);
        c.RGFW_window_setUserPtr(self.window, self);
        _ = c.RGFW_setEventCallback(c.RGFW_windowRefresh, on_refresh);
        _ = c.RGFW_setEventCallback(c.RGFW_windowResized, on_resize);
        // c.RGFW_window_captureRawMouse(self.window, c.RGFW_TRUE);


        if (g.gladLoadGL(c.RGFW_getProcAddress_OpenGL) == 0) {
            log("ERROR: failed to load GLAD", .{});
            unreachable;
        }

        //
        // Blending
        //
        g.glEnable(g.GL_BLEND); 
        g.glBlendFunc(g.GL_SRC_ALPHA, g.GL_ONE_MINUS_SRC_ALPHA);
        g.glBlendEquation(g.GL_FUNC_ADD);

        const gl_version = g.glGetString(g.GL_VERSION);
        log("OpenGL version: {s}", .{ gl_version });
        self.on_resize_inner(w, h);

        //
        // Base shader program
        //
        self.base_vert_shader = try load_shader(base_vs_src, g.GL_VERTEX_SHADER);
        self.base_frag_shader = try load_shader(base_fs_src, g.GL_FRAGMENT_SHADER);
        self.base_shader_pgm = try create_program(self.base_vert_shader, self.base_frag_shader);

        // Font shader program
        self.font_frag_shader = try load_shader(font_fs_src, g.GL_FRAGMENT_SHADER);
        self.font_shader_pgm = try create_program(self.base_vert_shader, self.font_frag_shader);

        // vertex array buffer
        // it stores the mapping between VBO and the attributes in shaders
        g.glGenBuffers(1, &self.base_VBO);
        g.glBindBuffer(g.GL_ARRAY_BUFFER, self.base_VBO);

        g.glGenVertexArrays(1, &self.base_VAO);
        g.glBindVertexArray(self.base_VAO);
        bind_vertex_attr(BaseVertexData) catch unreachable;

        const indices = [_]Vec3u {
            .{ 0, 1, 3},
            .{ 1, 2, 3},
        };
        g.glGenBuffers(1, &self.rect_EBO);
        g.glBindBuffer(g.GL_ELEMENT_ARRAY_BUFFER, self.rect_EBO);
        g.glBufferData(g.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, g.GL_STATIC_DRAW);

        g.glGenBuffers(1, &self.batch_EBO);

        g.glGenBuffers(1, &self.batch_VBO);
        g.glBindBuffer(g.GL_ARRAY_BUFFER, self.batch_VBO);

        g.glGenVertexArrays(1, &self.batch_VAO);
        g.glBindVertexArray(self.batch_VAO);
        bind_vertex_attr(BaseVertexData) catch unreachable;


        self.rect_EBO_list = .empty;
        //
        // Bitmap font
        //
        self.fonts = .init(atlas_size, gpa);
        self.default_font = Font.load_font_content(default_font_path, gpa) catch unreachable;
        self.set_active_font(self.default_font);
        self.white_tex = Texture.dummy();

        //
        // Finalize
        //
        self.render_fn = render_fn; 

        self.mouse_pos_screen = .{ @intCast(@divFloor(w, 2)), @intCast(@divFloor(h, 2)) };
        self.mouse_pos_gl = .{0, 0};

        self.mouse_scroll = .{ 0, 0 };

        self.a = gpa;
        self.composition_codepoints = .empty;
        self.is_paste = false;

        self.last_frame_time_us = std.time.microTimestamp();
        self.delta_time_us = 0;
    }

    // reset per-frame state and handle events
    pub fn window_should_close(self: *Self) bool {
        self.mouse_scroll = .{ 0, 0 };
        self.mouse_delta = .{ 0, 0 };

        self.composition_codepoints.clearRetainingCapacity();
        self.is_paste = false;

        const t = std.time.microTimestamp();
        self.delta_time_us = t - self.last_frame_time_us;
        self.last_frame_time_us = t; 


        // var event: c.RGFW_event = undefined;
        // while (c.RGFW_window_checkEvent(self.window, &event) != 0) {
        //     switch (event.type) {
        //         c.RGFW_mousePosChanged => {
        //             // The `mouse.y`` here is 0 from the top, and WINDOW_HEIGHT at the bottom. This is reversed for opengl.
        //             // To keep it consistent, we invert the y here.
        //             // log("DEBUG mouse {},{}", .{ event.mouse.x, event.mouse.y });
        //             self.mouse_pos_screen = .{ event.mouse.x, self.h-event.mouse.y };
        //             self.mouse_pos_gl = self.screen_to_gl_coord(.{ self.mouse_pos_screen[0], self.mouse_pos_screen[1] });
        //             self.mouse_delta = .{ event.mouse.vecX*self.pixel_scale, event.mouse.vecY*self.pixel_scale };
        //         },
        //         c.RGFW_keyPressed => {
        //             // TODO: deal with unicode
        //             const ch = event.key.sym;
        //             if (ch == @intFromEnum(Key.backSpace)) self.backspace += 1
        //             else if (event.key.value == 'v'  and (event.key.mod & c.RGFW_modControl) != 0) self.is_paste = true
        //             else if (ch != 0 and ch != @intFromEnum(Key.escape) and std.ascii.isAscii(ch))
        //                 self.input_chars.append(self.a, ch) catch @panic("OOM");
        //         },
        //         c.RGFW_mouseScroll => {
        //             self.mouse_scroll[0] += event.scroll.x;
        //             self.mouse_scroll[1] += event.scroll.y;
        //         },
        //         c.RGFW_compositionCommitted => {
        //             const slice = std.mem.sliceTo(event.composition.commited_result, 0);
        //             _ = append_utf8_slice(&self.input_chars, self.a, slice) catch @panic("TODO: handle invalid utf8 sequence");
        //         },
        //         else => {},
        //     }
        // }

        return c.RGFW_window_shouldClose(self.window) != 0;
    }

    pub const Event = union(enum) {
        key_char: u21,
        composition: struct { bytes: []const u8, codepoints: []const u21 },
    };

    pub fn poll_event(self: *Self) ?Event {
        var event: c.RGFW_event = undefined;
        while (true) {
            if (c.RGFW_window_checkEvent(self.window, &event) == 0) return null;
            switch (event.type) {
                c.RGFW_mousePosChanged => {
                    // The `mouse.y`` here is 0 from the top, and WINDOW_HEIGHT at the bottom. This is reversed for opengl.
                    // To keep it consistent, we invert the y here.
                    // log("DEBUG mouse {},{}", .{ event.mouse.x, event.mouse.y });
                    self.mouse_pos_screen = .{ event.mouse.x, self.h-event.mouse.y };
                    self.mouse_pos_gl = self.screen_to_gl_coord(.{ self.mouse_pos_screen[0], self.mouse_pos_screen[1] });
                },
                c.RGFW_mouseRawMotion => {
                    self.mouse_delta = .{ event.delta.x*self.pixel_scale, event.delta.y*self.pixel_scale };
                },
                c.RGFW_mouseScroll => {
                    self.mouse_scroll[0] += event.delta.x;
                    self.mouse_scroll[1] += event.delta.y;
                },

                // c.RGFW_keyPressed => {
                //     // const ch = event.key.sym;
                //     // if (ch == @intFromEnum(Key.backSpace)) self.backspace += 1
                //     // else if (event.key.value == 'v'  and (event.key.mod & c.RGFW_modControl) != 0) self.is_paste = true
                //     // else if (ch != 0 and ch != @intFromEnum(Key.escape) and std.ascii.isAscii(ch))
                //     //     self.input_chars.append(self.a, ch) catch @panic("OOM");
                //     var mod_set = std.EnumSet(KeyMod).initEmpty();
                //     mod_set.bits.mask = @intCast(event.key.mod);
                //     log("sym: {}|{c}|{}", .{ event.key.sym, event.key.sym, event.key.value });
                //     return Event { .key_pressed = .{ .sym = event.key.sym, .mod = mod_set }};
                // },
                c.RGFW_keyChar => {
                    // var out: [4]u8 = undefined;
                    // const out_len = std.unicode.utf8Encode(@intCast(event.keyChar.value), &out) catch unreachable;
                    // log("key char: {}|{s}", .{ event.keyChar.value,  out[0..out_len] });
                    return Event { .key_char = @intCast(event.keyChar.value) };
                },
                // c.RGFW_compositionCommitted => {
                //     log("composition", .{});
                //     const slice = std.mem.sliceTo(event.composition.commited_result, 0);
                //     _ = append_utf8_slice(&self.composition_codepoints, self.a, slice) catch @panic("TODO: handle invalid utf8 sequence");
                //     return Event { .composition = .{ .bytes = slice, .codepoints = self.composition_codepoints.items } };
                // },
                else => {},
            }
        }


    }

    pub const MouseKey = enum(u8) {
        mouse_left = c.RGFW_mouseLeft,
        mouse_right = c.RGFW_mouseRight,
        mouse_middle = c.RGFW_mouseMiddle,
    };

    pub const Key = enum(u8) {
        NULL = c.RGFW_keyNULL,
        Escape = c.RGFW_keyEscape,
        Backtick = c.RGFW_keyBacktick,
        @"0" = c.RGFW_key0,
        @"1" = c.RGFW_key1,
        @"2" = c.RGFW_key2,
        @"3" = c.RGFW_key3,
        @"4" = c.RGFW_key4,
        @"5" = c.RGFW_key5,
        @"6" = c.RGFW_key6,
        @"7" = c.RGFW_key7,
        @"8" = c.RGFW_key8,
        @"9" = c.RGFW_key9,
        Minus = c.RGFW_keyMinus,
        Equal = c.RGFW_keyEqual,
        BackSpace = c.RGFW_keyBackSpace,
        Tab = c.RGFW_keyTab,
        Space = c.RGFW_keySpace,
        A = c.RGFW_keyA,
        B = c.RGFW_keyB,
        C = c.RGFW_keyC,
        D = c.RGFW_keyD,
        E = c.RGFW_keyE,
        F = c.RGFW_keyF,
        G = c.RGFW_keyG,
        H = c.RGFW_keyH,
        I = c.RGFW_keyI,
        J = c.RGFW_keyJ,
        K = c.RGFW_keyK,
        L = c.RGFW_keyL,
        M = c.RGFW_keyM,
        N = c.RGFW_keyN,
        O = c.RGFW_keyO,
        P = c.RGFW_keyP,
        Q = c.RGFW_keyQ,
        R = c.RGFW_keyR,
        S = c.RGFW_keyS,
        T = c.RGFW_keyT,
        U = c.RGFW_keyU,
        V = c.RGFW_keyV,
        W = c.RGFW_keyW,
        X = c.RGFW_keyX,
        Y = c.RGFW_keyY,
        Z = c.RGFW_keyZ,
        Period = c.RGFW_keyPeriod,
        Comma = c.RGFW_keyComma,
        Slash = c.RGFW_keySlash,
        Bracket = c.RGFW_keyBracket,
        CloseBracket = c.RGFW_keyCloseBracket,
        Semicolon = c.RGFW_keySemicolon,
        Apostrophe = c.RGFW_keyApostrophe,
        BackSlash = c.RGFW_keyBackSlash,
        Return = c.RGFW_keyReturn,
        Delete = c.RGFW_keyDelete,
        F1 = c.RGFW_keyF1,
        F2 = c.RGFW_keyF2,
        F3 = c.RGFW_keyF3,
        F4 = c.RGFW_keyF4,
        F5 = c.RGFW_keyF5,
        F6 = c.RGFW_keyF6,
        F7 = c.RGFW_keyF7,
        F8 = c.RGFW_keyF8,
        F9 = c.RGFW_keyF9,
        F10 = c.RGFW_keyF10,
        F11 = c.RGFW_keyF11,
        F12 = c.RGFW_keyF12,
        F13 = c.RGFW_keyF13,
        F14 = c.RGFW_keyF14,
        F15 = c.RGFW_keyF15,
        F16 = c.RGFW_keyF16,
        F17 = c.RGFW_keyF17,
        F18 = c.RGFW_keyF18,
        F19 = c.RGFW_keyF19,
        F20 = c.RGFW_keyF20,
        F21 = c.RGFW_keyF21,
        F22 = c.RGFW_keyF22,
        F23 = c.RGFW_keyF23,
        F24 = c.RGFW_keyF24,
        F25 = c.RGFW_keyF25,
        CapsLock = c.RGFW_keyCapsLock,
        ShiftL = c.RGFW_keyShiftL,
        ControlL = c.RGFW_keyControlL,
        AltL = c.RGFW_keyAltL,
        SuperL = c.RGFW_keySuperL,
        ShiftR = c.RGFW_keyShiftR,
        ControlR = c.RGFW_keyControlR,
        AltR = c.RGFW_keyAltR,
        SuperR = c.RGFW_keySuperR,
        Up = c.RGFW_keyUp,
        Down = c.RGFW_keyDown,
        Left = c.RGFW_keyLeft,
        Right = c.RGFW_keyRight,
        Insert = c.RGFW_keyInsert,
        Menu = c.RGFW_keyMenu,
        End = c.RGFW_keyEnd,
        Home = c.RGFW_keyHome,
        PageUp = c.RGFW_keyPageUp,
        PageDown = c.RGFW_keyPageDown,
        NumLock = c.RGFW_keyNumLock,
        PadSlash = c.RGFW_keyPadSlash,
        PadMultiply = c.RGFW_keyPadMultiply,
        PadPlus = c.RGFW_keyPadPlus,
        PadMinus = c.RGFW_keyPadMinus,
        PadEqual = c.RGFW_keyPadEqual,
        Pad1 = c.RGFW_keyPad1,
        Pad2 = c.RGFW_keyPad2,
        Pad3 = c.RGFW_keyPad3,
        Pad4 = c.RGFW_keyPad4,
        Pad5 = c.RGFW_keyPad5,
        Pad6 = c.RGFW_keyPad6,
        Pad7 = c.RGFW_keyPad7,
        Pad8 = c.RGFW_keyPad8,
        Pad9 = c.RGFW_keyPad9,
        Pad0 = c.RGFW_keyPad0,
        PadPeriod = c.RGFW_keyPadPeriod,
        PadReturn = c.RGFW_keyPadReturn,
        ScrollLock = c.RGFW_keyScrollLock,
        PrintScreen = c.RGFW_keyPrintScreen,
        Pause = c.RGFW_keyPause,
        World1 = c.RGFW_keyWorld1,
        World2 = c.RGFW_keyWorld2,

        const keyEnter = c.RGFW_keyReturn;
        const keyEquals = c.RGFW_keyEquals;
        const keyPadEquals = c.RGFW_keyPadEquals;
    };
    pub const KeyMod = enum(u8) {
        CapsLock = c.RGFW_modCapsLock,
        NumLock = c.RGFW_modNumLock,
        Control = c.RGFW_modControl,
        Alt = c.RGFW_modAlt,
        Shift = c.RGFW_modShift,
        Super = c.RGFW_modSuper,
        ScrollLock = c.RGFW_modScrollLock,
    };


    pub fn is_mouse_down(_: Self, key: MouseKey) bool {
        return c.RGFW_isMouseDown(@intFromEnum(key)) == 1;
    }

    pub fn is_mouse_pressed(_: Self, key: MouseKey) bool {
        return c.RGFW_isMousePressed(@intFromEnum(key)) == 1;
    }

    pub fn is_mouse_released(_: Self, key: MouseKey) bool {
        return c.RGFW_isMouseReleased(@intFromEnum(key)) == 1;
    }

    pub fn is_key_down(_: Self, key: Key) bool {
        return c.RGFW_isKeyDown(@intFromEnum(key)) == 1;
    }

    pub fn is_key_pressed(_: Self, key: Key) bool {
        return c.RGFW_isKeyPressed(@intFromEnum(key)) == 1;
    }

    pub fn is_key_released(_: Self, key: Key) bool {
        return c.RGFW_isKeyReleased(@intFromEnum(key)) == 1;
    }

    pub const MouseIcon = enum(u8) {
        mouse_normal= c.RGFW_mouseNormal,
        mouse_arrow = c.RGFW_mouseArrow,
        mouse_ibeam = c.RGFW_mouseIbeam,
        mouse_middle = c.RGFW_mouseCrosshair,
        mouse_pointing_hand = c.RGFW_mousePointingHand,
    };

    pub fn set_mouse_standard(self: Self, icon: MouseIcon) void {
        _ = c.RGFW_window_setMouseStandard(self.window, @intFromEnum(icon));
    }

    pub fn close_window(self: Self) void {
        return c.RGFW_window_close(self.window);
    }

    pub fn expand_rect_ebo(self: *Self, size: usize) void {
        while (size > self.rect_EBO_list.items.len) {
            const curr: c_uint = @intCast(self.rect_EBO_list.items.len*4); // each rectangle has 4 vertices
            const indices = [2]Vec3u {
                .{ 0+curr, 1+curr, 3+curr},
                .{ 1+curr, 2+curr, 3+curr},
            };

            self.rect_EBO_list.append(self.a, indices) catch unreachable;
        }
    }

    // on_resize and on_refresh handled smooth resizing
    fn on_resize(event_: ?*const c.RGFW_event) callconv(.c) void {
        const event = event_.?;
        const ctx: *Self = @ptrCast(@alignCast(c.RGFW_window_getUserPtr(event.common.win)));
        ctx.on_resize_inner(event.update.w, event.update.h);
    }

    fn on_resize_inner(ctx: *Self, w: i32, h: i32) void {
        ctx.w = w;
        ctx.h = h;
        //.std.log.debug("resized", .{});
        // WINDOW_WIDTH = w;
        // WINDOW_HEIGHT = h;
        if (w > h) {
            ctx.pixel_scale = 2.0 / @as(f32, @floatFromInt(w));
            g.glViewport(0, @divFloor(h-w, 2), w, w);
            ctx.vierwport_size = @intCast(w);
        }
        else {
            ctx.pixel_scale = 2.0 / @as(f32, @floatFromInt(h));
            g.glViewport(@divFloor(w-h, 2), 0, h, h);
            ctx.vierwport_size = @intCast(h);
        }
        ctx.aspect_ratio = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h));

    }

    fn on_refresh(event_: ?*const c.RGFW_event) callconv(.c) void {
        // std.log.debug("refresh", .{});
        const event = event_.?;
        const ctx: *Self = @ptrCast(@alignCast(c.RGFW_window_getUserPtr(event.common.win)));
        ctx.render();
    }

    // Wrapper of user defined render function
    pub fn render(self: *Self) void {
        self.render_fn(self);
        c.RGFW_window_swapBuffers_OpenGL(self.window);
    }

    // Drawing related

    pub fn clear(_: Self, rgba: RGBA) void {
        const rgba_vec4 = rgba.to_vec4();
        g.glClearColor(rgba_vec4[0], rgba_vec4[1], rgba_vec4[2], rgba_vec4[3]);
        g.glClear(g.GL_COLOR_BUFFER_BIT);

    }

    pub fn begin_scissor_gl_coord(ctx: *Self, botleft: Vec2, size: Vec2) void {
        const botleft_screen = ctx.gl_coord_to_screen(botleft);
        const size_screen = ctx.gl_size_to_screen(size);

        // const botleft2 = ctx.screen_to_gl_coord(botleft_screen);
        // std.log.debug("scissor: {any}; {any} <=> {any}", .{ botleft_screen, botleft, botleft2 });

        g.glScissor(@intCast(botleft_screen[0]), @intCast(botleft_screen[1]), @intCast(size_screen[0]), @intCast(size_screen[1])); 
        g.glEnable(g.GL_SCISSOR_TEST);
    }

    pub fn end_scissor(_: *Self) void {
        g.glDisable(g.GL_SCISSOR_TEST);
    }

    //
    // Drawing Shapes
    //

    pub fn draw_rect(self: *Self, botleft: Vec2, size: Vec2, rgba: RGBA) void {
        self.draw_tex(botleft, size, self.white_tex, rgba);
    }

    pub fn draw_rect_lines(self: *Self, botleft: Vec2, size: Vec2, thickness: f32, rgba: RGBA) void {
        g.glLineWidth(thickness);
        self.draw_tex_pro(botleft, size, self.white_tex, rect_tex_coord, rgba, true, self.base_shader_pgm);
        g.glLineWidth(1.0);
    }

    pub fn draw_circle_sector(self: *Self, center: Vec2, radius: f32, sector: u32, start: f32, end: f32, rgba: RGBA) void {
        assert(sector != 0);
        assert(end >= start);
        const sector_f: f32 = @floatFromInt(sector);
        const range = end - start;
        const segment = range/sector_f;
        const num_segment_to_fill_360 = 2*std.math.pi/segment;
        for (0..sector) |n| {
            const nf: f32= @floatFromInt(n);
            const a1 = nf * segment + start; // angle 1
            const a2 = @mod(nf+1, num_segment_to_fill_360) * segment + start; // angle 2
            const p1 = Vec2 {
                @cos(a1) * radius + center[0],
                @sin(a1) * radius + center[1],
            };
            const p2 = Vec2 {
                @cos(a2) * radius + center[0],
                @sin(a2) * radius + center[1],
            };
            self.draw_triangle(center, p1, p2, rgba);
        }
    }

    pub fn draw_circle(self: *Self, center: Vec2, radius: f32, rgba: RGBA) void {
        self.draw_circle_sector(center, radius, 50, 0, std.math.pi*2, rgba);
    }

    pub fn push_circle_sector_lines_vertexes(self: *Self, vertexes: *std.ArrayList(BaseVertexData), center: Vec2, radius: f32, sector: u32, start: f32, end: f32, rgba: RGBA) void {
        const sector_f: f32 = @floatFromInt(sector);
        const range = end - start;
        const segment = range/sector_f;
        // const num_segment_to_fill_360 = 2*std.math.pi/segment;
        for (0..sector+1) |n| {
            const nf: f32= @floatFromInt(n);
            const a1 = nf * segment + start; // angle 1
                                             // const a2 = @mod(nf+1, num_segment_to_fill_360) * segment + start; // angle 2
            const p1 = Vec2 {
                @cos(a1) * radius + center[0],
                @sin(a1) * radius + center[1],
            };
            // const p2 = Vec2 {
            //     @cos(a2) * radius + center[0],
            //     @sin(a2) * radius + center[1],
            // };
            vertexes.append(self.a, .{ .pos = vec2_to_vec3(p1), .rgba = rgba.to_vec4(), .tex = .{ 0, 0 } }) catch @panic("OOM");
        }
    }

    pub fn draw_circle_sector_lines(self: *Self, center: Vec2, radius: f32, sector: u32, start: f32, end: f32, thickness: f32, rgba: RGBA) void {
        const State = struct {
            var vertexes = std.ArrayList(BaseVertexData).empty;
        };
        State.vertexes.clearRetainingCapacity();
        self.push_circle_sector_lines_vertexes(&State.vertexes, center, radius, sector, start, end, rgba);
        self.draw_lines(State.vertexes.items, thickness);
    }


    pub fn draw_circle_lines(self: *Self, center: Vec2, radius: f32, thickness: f32, rgba: RGBA) void {
        self.draw_circle_sector_lines(center, radius, 50, 0, std.math.pi*2, thickness, rgba);
    }

    pub fn draw_rect_rounded(self: *Self, botleft: Vec2, size: Vec2, radius_: f32, rgba: RGBA) void {
        var radius = radius_;
        radius = @min(radius, size[0]/2);
        radius = @min(radius, size[1]/2);
        const inner_botleft = v2add(botleft, v2splat(radius));
        const inner_size = v2sub(size, v2splat(2*radius));
        self.draw_rect(inner_botleft, inner_size, rgba); // inner rect 
        self.draw_rect(v2add(botleft, .{ 0, radius }), .{ radius, inner_size[1] }, rgba); // left rect 
        self.draw_rect(v2add(botleft, .{ inner_size[0]+radius, radius }), .{ radius, inner_size[1] }, rgba); // right rect 
        self.draw_rect(v2add(botleft, .{ radius, 0 }), .{ inner_size[0], radius }, rgba); // bot rect 
        self.draw_rect(v2add(botleft, .{ radius, inner_size[1]+radius}), .{ inner_size[0], radius }, rgba); // top rect 
           
        const sector = 25;
        // const sector_f: f32 = @floatFromInt(sector);
        const quater = std.math.pi/2.0;
        self.draw_circle_sector(inner_botleft, radius, sector, 2*quater, 3*quater, rgba); // botleft
        self.draw_circle_sector(v2add(botleft, .{ radius, inner_size[1]+radius}), radius, sector, 1*quater, 2*quater, rgba); // topleft
        self.draw_circle_sector(v2add(inner_botleft, .{ inner_size[0], 0}), radius, sector, 3*quater, 4*quater, rgba); // botright
        self.draw_circle_sector(v2add(inner_botleft, inner_size), radius, sector, 0*quater, 1*quater, rgba); // topright
    }

    pub fn draw_rect_rounded_lines(self: *Self, botleft: Vec2, size: Vec2, radius: f32, thickness: f32, rgba: RGBA) void {
        const State = struct {
            var vertexes = std.ArrayList(BaseVertexData).empty;
        };
        State.vertexes.clearRetainingCapacity();
        const inner_botleft = v2add(botleft, v2splat(radius));
        const inner_size = v2sub(size, v2splat(2*radius));

        const sector = 25;
        const quater = std.math.pi/2.0;
        self.push_circle_sector_lines_vertexes(&State.vertexes, inner_botleft, radius, sector, 2*quater, 3*quater, rgba); // botlet
        self.push_circle_sector_lines_vertexes(&State.vertexes, v2add(inner_botleft, .{ inner_size[0], 0}), radius, sector, 3*quater, 4*quater, rgba); // botright
        self.push_circle_sector_lines_vertexes(&State.vertexes, v2add(inner_botleft, inner_size), radius, sector, 0*quater, 1*quater, rgba); // topright
        self.push_circle_sector_lines_vertexes(&State.vertexes, v2add(botleft, .{ radius, inner_size[1]+radius}), radius, sector, 1*quater, 2*quater, rgba); // topleft
        State.vertexes.append(self.a, .{ .pos = .{ botleft[0], inner_botleft[1], 0}, .rgba = rgba.to_vec4(), .tex = .{0,0} }) catch @panic("OOM");

        self.draw_lines(State.vertexes.items, thickness);
    }

    pub fn draw_triangle(self: *Self, i: Vec2, j: Vec2, k: Vec2, rgba: RGBA) void {
        const rgba_vec4 = rgba.to_vec4();
        const vertexes = [_]BaseVertexData {
            .{ .pos = vec2_to_vec3(i), .rgba = rgba_vec4, .tex = .{0, 0} },
            .{ .pos = vec2_to_vec3(j), .rgba = rgba_vec4, .tex = .{0, 0} },
            .{ .pos = vec2_to_vec3(k), .rgba = rgba_vec4, .tex = .{0, 0} },
        };
        g.glUseProgram(self.base_shader_pgm);

        g.glBindBuffer(g.GL_ARRAY_BUFFER, self.base_VBO);
        g.glBufferData(g.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertexes)), &vertexes, g.GL_STATIC_DRAW);

        g.glBindVertexArray(self.base_VAO);

        g.glBindTexture(g.GL_TEXTURE_2D, self.white_tex.id);   

        g.glDrawArrays(g.GL_TRIANGLES, 0, 3);
    }

    pub fn draw_tex(self: *Self, botleft: Vec2, size: Vec2, tex: Texture, rgba: RGBA) void {
        self.draw_tex_pro(botleft, size, tex, rect_tex_coord, rgba, false, self.base_shader_pgm);
    }

    pub fn draw_tex_pro(self: *Self,
        botleft: Vec2,
        size: Vec2,
        tex: Texture,
        tex_coord: [4]Vec2, // 0: topright, 1: topleft, 2: botleft, 3: botright
        rgba: RGBA,
        lines_only: bool,
        shader_program: GLObj) void {
        const left, const bot = botleft;
        const w, const h = size;
        const rgba_vec4 = rgba.to_vec4();

        // starts from the topright, and goes counter-clockwise
        const vertexes = [_]BaseVertexData {
            .{ .pos = .{left+w, bot+h, 0}, .rgba = rgba_vec4, .tex = tex_coord[0] },
            .{ .pos = .{left,   bot+h, 0}, .rgba = rgba_vec4, .tex = tex_coord[1] },
            .{ .pos = .{left,   bot,   0}, .rgba = rgba_vec4, .tex = tex_coord[2] },
            .{ .pos = .{left+w, bot,   0}, .rgba = rgba_vec4, .tex = tex_coord[3] },
        };

        self.draw_tex_vertex_data(vertexes, tex, lines_only, shader_program);
    }

    pub fn draw_tex_vertex_data(self: *Self, 
        vertexes: [4]BaseVertexData, 
        tex: Texture,
        lines_only: bool,
        shader_program: GLObj) void {

        g.glUseProgram(shader_program);

        g.glBindBuffer(g.GL_ARRAY_BUFFER, self.base_VBO);
        g.glBufferData(g.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertexes)), &vertexes, g.GL_STATIC_DRAW);



        g.glBindVertexArray(self.base_VAO);

        g.glBindTexture(g.GL_TEXTURE_2D, tex.id);   

        if (lines_only) {
            g.glDrawArrays(g.GL_LINE_LOOP, 0, 4);
        } else {
            g.glBindBuffer(g.GL_ELEMENT_ARRAY_BUFFER, self.rect_EBO);
            g.glDrawElements(g.GL_TRIANGLES, 6, g.GL_UNSIGNED_INT, @ptrFromInt(0));
        }
    }

    pub fn draw_tex_batch(self: *Self,
        vertexes: [][4]BaseVertexData,
        tex: Texture,
        line_thickness: ?f32,
        shader_program: GLObj) void {


        g.glUseProgram(shader_program);

        g.glBindBuffer(g.GL_ARRAY_BUFFER, self.batch_VBO);
        g.glBufferData(g.GL_ARRAY_BUFFER, @intCast(@sizeOf([4]BaseVertexData) * vertexes.len), vertexes.ptr, g.GL_STATIC_DRAW);

        g.glBindVertexArray(self.batch_VAO);

        g.glBindTexture(g.GL_TEXTURE_2D, tex.id);

        if (line_thickness) |thickness| {
            g.glLineWidth(thickness);
            for (0..vertexes.len) |i|
                g.glDrawArrays(g.GL_LINE_LOOP, @intCast(i*4), 4);
            g.glLineWidth(0);
        } else {
            self.expand_rect_ebo(vertexes.len);
            // std.log.debug("{}", .{ vertexes.len })
            g.glBindBuffer(g.GL_ELEMENT_ARRAY_BUFFER, self.rect_EBO);
            const EBO_size = @sizeOf([2]Vec3u) * self.rect_EBO_list.items.len;
            g.glBufferData(
                g.GL_ELEMENT_ARRAY_BUFFER,
                @intCast(EBO_size), self.rect_EBO_list.items.ptr,
                g.GL_STATIC_DRAW);
            g.glDrawElements(g.GL_TRIANGLES, @intCast(6 * vertexes.len), g.GL_UNSIGNED_INT, @ptrFromInt(0));
        }

        g.glUseProgram(0);
        g.glBindBuffer(g.GL_ARRAY_BUFFER, 0);
        g.glBindVertexArray(0);
        g.glBindTexture(g.GL_TEXTURE_2D, 0);   
        g.glBindBuffer(g.GL_ELEMENT_ARRAY_BUFFER, 0);
    }

    pub fn draw_lines(self: *Self,
        vertexes: []BaseVertexData,
        thickness: f32) void {
        g.glUseProgram(self.base_shader_pgm);

        g.glBindBuffer(g.GL_ARRAY_BUFFER, self.batch_VBO);
        g.glBufferData(g.GL_ARRAY_BUFFER, @intCast(@sizeOf([4]BaseVertexData) * vertexes.len), vertexes.ptr, g.GL_STATIC_DRAW);

        g.glBindVertexArray(self.batch_VAO);
        
        g.glBindTexture(g.GL_TEXTURE_2D, self.white_tex.id);

        g.glLineWidth(thickness);

        g.glDrawArrays(g.GL_LINE_STRIP, 0, @intCast(vertexes.len));
    }

    pub fn make_rect_vertex_data(_: *Self, botleft: Vec2, size: Vec2, rgba: RGBA) [4]BaseVertexData {
        const left, const bot = botleft;
        const w, const h = size;
        const rgba_vec4 = rgba.to_vec4();

        const tex_coord = rect_tex_coord;

        return [4]BaseVertexData {
            .{ .pos = .{left+w, bot+h, 0}, .rgba = rgba_vec4, .tex = tex_coord[0] },
            .{ .pos = .{left,   bot+h, 0}, .rgba = rgba_vec4, .tex = tex_coord[1] },
            .{ .pos = .{left,   bot,   0}, .rgba = rgba_vec4, .tex = tex_coord[2] },
            .{ .pos = .{left+w, bot,   0}, .rgba = rgba_vec4, .tex = tex_coord[3] },
        };
    }


    pub const DummyU21Iterator = struct {
        slice: []const u21,
        idx: u32 = 0,

        pub fn nextCodepoint(self: *DummyU21Iterator) ?u21 {
            if (self.idx >= self.slice.len) return null;
            self.idx += 1;
            return self.slice[self.idx - 1];
        }
    };

    pub fn CodePointVertexIterator(comptime Utf8Iterator: type) type {
        return struct {
            pos: Vec2,
            local_pos: Vec2,

            scale: f32,
            max_width: f32,
            rgba_vec4: Vec4,

            utf8_it: Utf8Iterator,

            ctx: *Self,
            fonts: *Font.Dynamic,
            active_font: Font,

            const It = @This();

            pub fn next(self: *It) ?[4]BaseVertexData {
                const scale = self.scale * (display_font_pixels / font_pixels);
                const pos = self.pos;
                const max_width = self.max_width;
                const rgba_vec4 = self.rgba_vec4;

                const code_point = self.utf8_it.nextCodepoint() orelse return null;
                if (code_point == '\n') @panic("newline not supported");
                // if (code_point < code_first_char or code_point > code_last_char) {
                //     var encode_buf: [32]u8 = undefined;
                //     if (std.unicode.utf8Encode(code_point, &encode_buf)) |len| {
                //         log("WARNING: unsupported characteer `{any}`", .{ encode_buf[0..len] });
                //     } else |err| {
                //         log("WARNING: invalid unicode sequence `0x{s}`: {}", .{ std.fmt.hex(code_point), err });
                //     }
                //     continue;
                // }

                const packed_char, const aligned_quad = self.fonts.get_or_load(self.active_font, code_point, font_pixels);

                // TODO: use width instead of advance to determine linebreak?
                const advance = packed_char.xadvance * self.ctx.pixel_scale * scale;
                if (self.local_pos[0] + advance - pos[0] > max_width) {
                    self.local_pos[0] = pos[0]; 
                    self.local_pos[1] -= self.ctx.cal_font_h(scale);
                }

                const w = 
                    @as(f32, @floatFromInt(packed_char.x1 - packed_char.x0))
                    * self.ctx.pixel_scale * scale;
                const h = 
                    @as(f32, @floatFromInt(packed_char.y1 - packed_char.y0))
                    * self.ctx.pixel_scale * scale;

                const left = self.local_pos[0] + (packed_char.xoff * self.ctx.pixel_scale * scale);
                const bot = self.local_pos[1] - 
                    (packed_char.yoff +
                     @as(f32, @floatFromInt(packed_char.y1)) -
                     @as(f32, @floatFromInt(packed_char.y0)))
                    * self.ctx.pixel_scale * scale;

                const tex_coord = [4]Vec2 {
                    .{ aligned_quad.s1, aligned_quad.t0 },
                    .{ aligned_quad.s0, aligned_quad.t0 },
                    .{ aligned_quad.s0, aligned_quad.t1 },
                    .{ aligned_quad.s1, aligned_quad.t1 },
                };

                self.local_pos[0] += advance;
                return [4]BaseVertexData {
                    .{ .pos = .{left+w, bot+h, 0}, .rgba = rgba_vec4, .tex = tex_coord[0] },
                    .{ .pos = .{left,   bot+h, 0}, .rgba = rgba_vec4, .tex = tex_coord[1] },
                    .{ .pos = .{left,   bot,   0}, .rgba = rgba_vec4, .tex = tex_coord[2] },
                    .{ .pos = .{left+w, bot,   0}, .rgba = rgba_vec4, .tex = tex_coord[3] },
                };

            }
        };
    }

    pub fn set_active_font(self: *Self, font: Font) void {
        self.active_font = font;
    } 

    pub fn make_code_point_vertex_data(
        self: *Self, pos: Vec2, scale: f32,
        text: []const u8, max_width: f32, rgba: RGBA) CodePointVertexIterator(std.unicode.Utf8Iterator) {

        const view = std.unicode.Utf8View.init(text) catch @panic("invalid utf8 string");
        const utf8_it = view.iterator();

        return .{
            .pos = pos,
            .local_pos = pos,
            .scale = scale,
            .max_width = max_width,
            .rgba_vec4 = rgba.to_vec4(),
            .utf8_it = utf8_it,
            .ctx = self,
            .fonts =  &self.fonts,
            .active_font = self.active_font,
        };
    }

    pub fn make_code_point_vertex_data_from_codepoints(
        self: *Self, pos: Vec2, scale: f32,
        codepoints: []const u21, max_width: f32, rgba: RGBA) CodePointVertexIterator(DummyU21Iterator) {

        return .{
            .pos = pos,
            .local_pos = pos,
            .scale = scale,
            .max_width = max_width,
            .rgba_vec4 = rgba.to_vec4(),
            .utf8_it = .{ .slice = codepoints },
            .ctx = self,
            .fonts =  &self.fonts,
            .active_font = self.active_font,
        };
    }

    pub fn draw_text(self: *Self, pos: Vec2, size: f32, text: []const u8, rgba: RGBA) void {
        self.draw_text_within_width(pos, size, text, std.math.floatMax(f32), rgba);
    }

    pub fn draw_text_within_width(
        self: *Self, pos: Vec2, scale: f32,
        text: []const u8, max_width: f32, rgba: RGBA) void {

        // std.log.debug("codepoints: {}", .{ std.unicode.utf8CountCodepoints(text) catch unreachable });
        var it = self.make_code_point_vertex_data(pos, scale, text, max_width, rgba);
        while (it.next()) |vertexes| {
            self.draw_tex_vertex_data(vertexes, .{ .id = self.fonts.tex, .w = undefined, .h = undefined }, false, self.font_shader_pgm);
        }
    }

    // TODO: handle newline and invalid unicode
    pub fn text_width_ascii(self: *Self, scale: f32, text: []const u8) f32 {
        const view = std.unicode.Utf8View.init(text) catch @panic("invalid utf8 string");
        var utf8_it = view.iterator();

        var w: f32 = 0;
        while (utf8_it.nextCodepoint()) |codepoint| {
            const packed_char, _ = self.fonts.get_or_load(self.active_font, codepoint, font_pixels);
            const advance = packed_char.xadvance * self.pixel_scale * scale * (display_font_pixels / font_pixels);
            w += advance;
        }
        return w;
    }

    pub fn text_width_codepoints(self: *Self, scale: f32, codepoints: []const u21) f32 {
        var w: f32 = 0;
        for (codepoints) |codepoint| {
            const packed_char, _ = self.fonts.get_or_load(self.active_font, codepoint, font_pixels);
            const advance = packed_char.xadvance * self.pixel_scale * scale * (display_font_pixels / font_pixels);
            w += advance;
        }
        return w;
    }

    pub fn ime_set_composition_windows(self: *Self, x: f32, y: f32) void {
        const sc_x, const sc_y = self.gl_coord_to_screen(.{ x, y });
        return c.RGFW_setCompositionWindows(self.window, sc_x, sc_y);
    }

    pub fn ime_disable_composition(self: *Self) void {
        c.RGFW_disableCompositionWindows(self.window);
    }

    // 
    // general wrappers/helpers of RGFW functionalities
    //
    pub fn clipboard(_: Self) []const u8 {
        var size: usize = undefined;
        const buf = c.RGFW_readClipboard(&size);
        if (size == 0) return "";
        assert(buf[size-1] == 0);
        return buf[0..size-1];
    }

    pub fn set_clipboard(_: Self, buf: []const u8) void {
        c.RGFW_writeClipboard(buf.ptr, @intCast(buf.len));
    }

    //
    // math helpers
    //
    pub fn get_char_size(self: *Self, scale: f32, code_point: u21) Vec2 {
        if (code_point < code_first_char or code_point > code_last_char) @panic("unsupported character");
        const glyph_info = &self.fonts.get_or_load(self.active_font, code_point, font_pixels);
        const packed_char = glyph_info[0];
        const glyph_size = Vec2 {
            @as(f32, @floatFromInt(packed_char.x1 - packed_char.x0))
                * self.pixel_scale * scale * (display_font_pixels / font_pixels),
            @as(f32, @floatFromInt(packed_char.y1 - packed_char.y0))
                * self.pixel_scale * scale * (display_font_pixels / font_pixels),
            };
        return glyph_size;
    }

    pub fn cal_font_h_pixel(_: Self, scale: f32) f32 {
        return display_font_pixels * scale;
    }

    pub fn cal_font_h(self: *Self, scale: f32) f32 {
        return self.cal_font_h_pixel(scale) * self.pixel_scale;
    }

    // return the gl y coordinate of the top of screen
    pub fn y_top(self: Self) f32 {
        if (self.aspect_ratio > 1) return 1 / self.aspect_ratio;
        return 1;
    }

    // return the gl y coordinate of the bottom of screen
    pub fn y_bot(self: Self) f32 {
        return -self.y_top();
    }

    pub fn x_right(self: Self) f32 {
        if (self.aspect_ratio < 1) return 1 * self.aspect_ratio;
        return 1;
    }

    pub fn x_left(self: Self) f32 {
        return -self.x_right();
    }

    pub fn screen_w(self: Self) f32 {
        return 2 * self.x_right();
    }

    pub fn screen_h(self: Self) f32 {
        return 2 * self.y_top();
    }

    pub fn h_perct(self: Self, perct: f32) f32 {
        return if (self.aspect_ratio > 1)
            perct * (2 / self.aspect_ratio)
            else 
                perct * 2;
    }

    pub fn w_perct(self: Self, perct: f32) f32 {
        return if (self.aspect_ratio > 1)
            perct * 2
            else 
                perct * 2 * self.aspect_ratio;
    }

    pub fn screen_to_gl_coord(self: Self, v: Vec2i) Vec2 {
        const xf: f32 = @floatFromInt(v[0]);
        const yf: f32 = @floatFromInt(v[1]);
        const vf : f32 = @floatFromInt(self.vierwport_size);
        return if (self.aspect_ratio > 1)
            .{
                (xf/vf - 0.5) * 2,
                (yf/(vf/self.aspect_ratio) - 0.5) * 2 / self.aspect_ratio,
            }
        else
            .{
                (xf/(vf*self.aspect_ratio) - 0.5) * 2 * self.aspect_ratio,
                (yf/vf - 0.5) * 2,
            };
    }

    pub fn gl_coord_to_screen(self: Self, v: Vec2) Vec2i {
        const vf: f32 = @floatFromInt(self.vierwport_size);
        return if (self.aspect_ratio > 1)
            .{
                @intFromFloat((v[0]/2 + 0.5) * vf),
                @intFromFloat((v[1]*self.aspect_ratio/2 + 0.5) * (vf/self.aspect_ratio)),
            }
        else
            .{
                @intFromFloat(((v[0]/self.aspect_ratio)/2 + 0.5) * (vf*self.aspect_ratio)),
                @intFromFloat((v[1]/2+0.5) * vf),
            };
    }

    pub fn gl_size_to_screen(self: Self, v: Vec2) Vec2i {
        const vf: f32 = @floatFromInt(self.vierwport_size);
        return .{
            @intFromFloat(v[0] / 2 * vf),
            @intFromFloat(v[1] / 2 * vf),
        };
    }

    pub fn pixels(self: Self, p: f32) f32 {
        return self.pixel_scale * p;
    }

    pub fn get_delta_time(self: Self) f32 {
        return @as(f32, @floatFromInt(self.delta_time_us)) / std.time.us_per_s;
    }
    // pub fn draw_line(self: *Self, i: Vec2, j: Vec2) void {

    // }


};

pub fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

fn load_shader(src: [:0]const u8, kind: c_uint) ShaderError!g.GLuint {
    const shader = g.glCreateShader(kind);
    g.glShaderSource(shader, 1, &src.ptr, null);
    g.glCompileShader(shader);
    var success: c_int = undefined;
    g.glGetShaderiv(shader, g.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var log_buf: [256]u8 = undefined;
        g.glGetShaderInfoLog(shader, log_buf.len, null, &log_buf);
        log("ERROR: Failed to compile {s} shader: {s}",
            .{ if (kind == g.GL_VERTEX_SHADER) "vertex" else "fragment", log_buf});
        return ShaderError.ShaderCompileError;
    }
    return shader;
}

fn create_program_from_src(vs_src: [:0]const u8, fs_src: [:0]const u8) ProgramError!g.GLuint {
    const vs = try load_shader(vs_src, g.GL_VERTEX_SHADER);
    const fs = try load_shader(fs_src, g.GL_FRAGMENT_SHADER);
    return create_program(vs, fs);
}

fn create_program(vs: GLObj, fs: GLObj) ProgramError!g.GLuint {
    const pgm = g.glCreateProgram();
    g.glAttachShader(pgm, vs);
    g.glAttachShader(pgm, fs);

    g.glLinkProgram(pgm);
    var success: c_int = undefined;
    g.glGetProgramiv(pgm, g.GL_LINK_STATUS, &success);
    if (success == 0) {
        var log_buf: [256]u8 = undefined;
        g.glGetShaderInfoLog(pgm, log_buf.len, null, &log_buf);
        log("ERROR: Failed to compile shader: {s}", .{log_buf});
        return ProgramError.LinkError;
    }
    return pgm;
}

fn use_program(pgm: g.GLuint) void {
    g.glUseProgram(pgm);
}



pub fn bind_vertex_attr(comptime T: type) !void {
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.fields, 0..) |f, i| {
        const field_info = @typeInfo(f.type).array;
        if (field_info.child != f32) @compileError("Unsupported type " ++ @typeName(f.type));
        g.glVertexAttribPointer(i, 
            field_info.len, g.GL_FLOAT,
            g.GL_FALSE,
            @sizeOf(T),
            @ptrFromInt(@offsetOf(T, f.name)));
        g.glEnableVertexAttribArray(i);
    }
}

pub fn append_utf8_slice(array: *std.ArrayList(u21), a: Allocator, buf: []const u8) !u32 {
    var ct: u32 = 0;
    const utf8_view = try std.unicode.Utf8View.init(buf);
    var it = utf8_view.iterator();
    while (it.nextCodepoint()) |codepoint|: (ct += 1) {
        array.append(a, codepoint) catch @panic("OOM");
    }
    return ct;
}

pub fn utf8_to_ascii(codepoints: []const u21, out: []u8) void {
    for (codepoints, out) |codepoint, *ch| {
        ch.* = @intCast(codepoint);
        assert(std.ascii.isAscii(ch.*));
    }
}

pub fn v2add(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

pub fn v2sub(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

pub fn v2scal(a: Vec2, b: f32) Vec2 {
    return .{ a[0] * b , a[1] * b };
}

// pub fn v2pixels(a: Vec2) Vec2 {
//     return .{ ctx.pixels(a[0]), ctx.pixels(a[1]) };
// }

pub fn v2eq(a: Vec2, b: Vec2) bool {
    return a[0] == b[0] and a[1] == b[1];
}

pub fn v2eq_approx(a: Vec2, b: Vec2) bool {
    return std.math.approxEqAbs(f32, a[0], b[0], 0.0001) and 
    std.math.approxEqAbs(f32, a[1], b[1], 0.0001);
}

pub fn v2splat(f: f32) Vec2 {
    return .{ f, f };
}
