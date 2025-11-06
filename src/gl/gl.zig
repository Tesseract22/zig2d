const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const c = @cImport({
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

// const default_font = @embedFile("resources/fonts/Ubuntu.ttf");
const default_font_path = "C:/Windows/Fonts/simfang.ttf";

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

    pub fn from_u32(u: u32) RGBA {
        if (comptime @import("builtin").cpu.arch.endian() == .little)
            return @bitCast(@byteSwap(u))
        else
            return @bitCast(u);
    }
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

pub fn Context(comptime T: type) type {
    return struct {
        const atlas_size: Vec2u = .{ 1024, 1024 };

        pub const code_first_char = ' ';
        pub const code_last_char = '~';
        pub const code_char_num = code_last_char - code_first_char + 1;

        pub const font_size = 64.0;

        const rect_tex_coord = [_]Vec2 {
            .{1, 0},
            .{0, 0},
            .{0, 1},
            .{1, 1},
        };

        a: Allocator,

        window: *c.RGFW_window,

        render_fn: *const fn (ctx: *Self) void,
        user_data: *T,

        base_shader_pgm: GLObj,
        base_vert_shader: GLObj,
        base_frag_shader: GLObj,

        font_frag_shader: GLObj,
        font_shader_pgm: GLObj,

        base_VBO: GLObj,
        base_VAO: GLObj,
        rect_EBO: GLObj,

        bitmap_tex: Texture,
        white_tex: Texture,

        default_font: Font.Dynamic,

        w: i32,
        h: i32,
        vierwport_size: u32,
        aspect_ratio: f32, // width / height
        pixel_scale: f32, // how big is a pixel in gl coordinate
                          //
        
        mouse_pos_screen: Vec2i,
        mouse_pos_gl: Vec2,
        mouse_delta: Vec2,

        mouse_left: bool,
        mouse_scroll: Vec2,

        input_chars: std.ArrayList(u8),

        is_paste: bool,

        last_frame_time_us: i64,
        delta_time_us: i64,


                          
       
        const Self = @This();
        pub fn init(self: *Self, user_data: *T, render_fn: *const fn (ctx: *Self) void,
            title: [:0]const u8, w: i32, h: i32, a: Allocator) !void {

            self.window = c.RGFW_createWindow(title, 0, 0, w, h, 
                c.RGFW_windowCenter
                // | c.RGFW_windowNoResize
                | c.RGFW_windowOpenGL) orelse unreachable;
            c.RGFW_window_makeCurrentWindow_OpenGL(self.window);
            c.RGFW_window_setUserPtr(self.window, self);
            _ = c.RGFW_setWindowRefreshCallback(on_refresh);
            _ = c.RGFW_setWindowResizedCallback(on_resize);

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
            on_resize(self.window, w, h);

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
            //
            // Bitmap font
            //
            std.log.info("Generating glyphs from {}~{}, total {}", 
                .{ code_first_char, code_last_char, code_char_num });

            //self.default_font = Font.Dload_ttf(default_font, 
            //    code_first_char, code_char_num,
            //    atlas_size,
            //    font_size,
            //    std.heap.c_allocator)
            //    catch @panic("cannot load default font");
            self.default_font = Font.Dynamic.init_from_file(default_font_path, atlas_size, a) catch unreachable;
            self.white_tex = Texture.dummy();

            // log("DEBUG: bitmap: {}x{}, id: {}", .{ self.default_font.bitmap.w, self.default_font.bitmap.h, self.default_font.bitmap.id });
            // log("DEBUG: enable range: {}, {} {}", .{ text_range_end, text_range_start, text_range_count });
            //
            // Finalize
            //
            self.render_fn = render_fn; 
            self.user_data = user_data;

            self.mouse_pos_screen = .{ @intCast(@divFloor(w, 2)), @intCast(@divFloor(h, 2)) };
            self.mouse_pos_gl = .{0, 0};

            self.mouse_left = false;
            self.mouse_scroll = .{ 0, 0 };

            self.a = a;
            self.input_chars = .empty;
            self.is_paste = false;

            self.last_frame_time_us = std.time.microTimestamp();
            self.delta_time_us = 0;

        }

        // reset per-frame state and handle events
        pub fn window_should_close(self: *Self) bool {
            self.mouse_left = false;
            self.mouse_scroll = .{ 0, 0 };
            self.mouse_delta = .{ 0, 0 };

            self.input_chars.clearRetainingCapacity();
            self.is_paste = false;

            var event: c.RGFW_event = undefined;
            while (c.RGFW_window_checkEvent(self.window, &event) != 0) {
                switch (event.type) {
                    c.RGFW_mousePosChanged => {
                        // The `mouse.y`` here is 0 from the top, and WINDOW_HEIGHT at the bottom. This is reversed for opengl.
                        // To keep it consistent, we invert the y here.
                        // log("DEBUG mouse {},{}", .{ event.mouse.x, event.mouse.y });
                        self.mouse_pos_screen = .{ event.mouse.x, self.h-event.mouse.y };
                        self.mouse_pos_gl = self.screen_to_gl_coord(.{ self.mouse_pos_screen[0], self.mouse_pos_screen[1] });
                        self.mouse_delta = .{ event.mouse.vecX*self.pixel_scale, event.mouse.vecY*self.pixel_scale };
                    },
                    c.RGFW_mouseButtonPressed => {
                        self.mouse_left = event.button.value == c.RGFW_mouseLeft;
                    },
                    c.RGFW_keyPressed => {
                        // TODO: deal with unicode
                        const ch = event.key.sym;
                        // if (ch == c.RGFW_backSpace and self.input_chars.items.len > 0) self.input_chars.shrinkRetainingCapacity(self.input_chars.items.len-1)
                        // std.log.debug("key: value: 0x{s} sym: 0x{s}, mod: 0x{s}",
                        //     .{ std.fmt.hex(event.key.value), std.fmt.hex(event.key.sym), std.fmt.hex(event.key.mod) });
                        if (event.key.value == 'v'  and (event.key.mod & c.RGFW_modControl) != 0) self.is_paste = true;
                        if (ch < code_first_char or ch > code_last_char) continue
                        else {
                            self.input_chars.append(self.a, event.key.sym) catch unreachable;
                        }
                    },
                    c.RGFW_mouseScroll => {
                        self.mouse_scroll[0] += event.scroll.x;
                        self.mouse_scroll[1] += event.scroll.y;
                    },
                    else => {},
                }
            }
            const t = std.time.microTimestamp();
            self.delta_time_us = t - self.last_frame_time_us;
            self.last_frame_time_us = t; 
            return c.RGFW_window_shouldClose(self.window) != 0;
        }

        pub fn close_window(self: Self) void {
            return c.RGFW_window_close(self.window);
        }

        // on_resize and on_refresh handled smooth resizing
        fn on_resize(win: ?*c.RGFW_window, w: i32, h: i32) callconv(.c) void {
            const ctx: *Self = @ptrCast(@alignCast(c.RGFW_window_getUserPtr(win)));
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

        fn on_refresh(win: ?*c.RGFW_window) callconv(.c) void {
            // std.log.debug("refresh", .{});
            const ctx: *Self = @ptrCast(@alignCast(c.RGFW_window_getUserPtr(win)));
            ctx.render();
        }

        // Wrapper of user defined render function
        pub fn render(self: *Self) void {
            self.render_fn(self);
            c.RGFW_window_swapBuffers_OpenGL(self.window);
        }

        const BaseVertexData = extern struct {
            pos: Vec3,
            rgba: Vec4,
            tex: Vec2,
        };
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

        pub fn draw_text(self: *Self, pos: Vec2, size: f32, text: []const u8, rgba: RGBA) void {
            self.draw_text_within_width(pos, size ,text, std.math.floatMax(f32), rgba);
        }

        pub fn draw_text_within_width(
            self: *Self, pos: Vec2, scale: f32,
            text: []const u8, max_width: f32, rgba: RGBA) void {

            // std.log.debug("codepoints: {}", .{ std.unicode.utf8CountCodepoints(text) catch unreachable });
            const view = std.unicode.Utf8View.init(text) catch @panic("invalid utf8 string");
            var utf8_it = view.iterator();

            var local_pos = pos;
            while (utf8_it.nextCodepoint()) |code_point| {
                // if (code_point < code_first_char or code_point > code_last_char) {
                //     var encode_buf: [32]u8 = undefined;
                //     if (std.unicode.utf8Encode(code_point, &encode_buf)) |len| {
                //         log("WARNING: unsupported characteer `{any}`", .{ encode_buf[0..len] });
                //     } else |err| {
                //         log("WARNING: invalid unicode sequence `0x{s}`: {}", .{ std.fmt.hex(code_point), err });
                //     }
                //     continue;
                // }
                
                const packed_char, const aligned_quad = self.default_font.get_or_load(code_point);

                // TODO: use width instead of advance to determine linebreak?
                const advance = packed_char.xadvance * self.pixel_scale * scale;
                if (local_pos[0] + advance - pos[0] > max_width) {
                    local_pos[0] = pos[0]; 
                    local_pos[1] -= self.cal_font_h(scale);
                }

                const glyph_size = Vec2 {
                    @as(f32, @floatFromInt(packed_char.x1 - packed_char.x0))
                        * self.pixel_scale * scale,
                    @as(f32, @floatFromInt(packed_char.y1 - packed_char.y0))
                        * self.pixel_scale * scale,
                };

                const botleft = Vec2 {
                    local_pos[0] + (packed_char.xoff * self.pixel_scale * scale), 
                    local_pos[1] - 
                        (packed_char.yoff +
                         @as(f32, @floatFromInt(packed_char.y1)) -
                         @as(f32, @floatFromInt(packed_char.y0)))
                        * self.pixel_scale * scale,
                };

                const tex_coord = [4]Vec2 {
                    .{ aligned_quad.s1, aligned_quad.t0 },
                    .{ aligned_quad.s0, aligned_quad.t0 },
                    .{ aligned_quad.s0, aligned_quad.t1 },
                    .{ aligned_quad.s1, aligned_quad.t1 },
                };

                self.draw_tex_pro(botleft, glyph_size,
                    .{ .id = self.default_font.tex, .w = undefined, .h = undefined }, tex_coord,
                    rgba,
                    false,
                   self.font_shader_pgm);
                local_pos[0] += advance;
            }
        }

        // TODO: handle newline and invalid unicode
        pub fn text_width(self: *Self, scale: f32, text: []const u8) f32 {
            const view = std.unicode.Utf8View.init(text) catch @panic("invalid utf8 string");
            var utf8_it = view.iterator();
    
            var w: f32 = 0;
            while (utf8_it.nextCodepoint()) |code_point| {
                // if (code_point < code_first_char or code_point > code_last_char) {
                //     var encode_buf: [32]u8 = undefined;
                //     if (std.unicode.utf8Encode(code_point, &encode_buf)) |len| {
                //         log("WARNING: unsupported characteer `{any}`", .{ encode_buf[0..len] });
                //     } else |err| {
                //         log("WARNING: invalid unicode sequence `0x{s}`: {}", .{ std.fmt.hex(code_point), err });
                //     }
                //     continue;
                // }

                const packed_char, _ = self.default_font.get_or_load(code_point);

                // TODO: use width instead of advance to determine linebreak?
                const advance = packed_char.xadvance * self.pixel_scale * scale;
                w += advance;
            }
            return w;
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
            const glyph_info = &self.default_font.get_or_load(code_point);
            const packed_char = glyph_info[0];
            const glyph_size = Vec2 {
                @as(f32, @floatFromInt(packed_char.x1 - packed_char.x0))
                    * self.pixel_scale * scale,
                @as(f32, @floatFromInt(packed_char.y1 - packed_char.y0))
                    * self.pixel_scale * scale,
                };
            return glyph_size;
        }

        pub fn cal_font_h(self: *Self, scale: f32) f32 {
            return font_size * self.pixel_scale * scale;
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
}

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
