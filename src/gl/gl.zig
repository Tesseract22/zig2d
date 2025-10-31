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

        default_font: Font,

        vierwport_size: u32,
        aspect_ratio: f32, // width / height
        pixel_scale: f32, // how big is a pixel in gl coordinate
                          //
        
        mouse_pos_screen: Vec2i,
        mouse_pos_gl: Vec2,

        mouse_left: bool,

        input_chars: std.ArrayList(u8),
                          
       
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

            self.default_font = Font.load_ttf("src/gl/resources/fonts/Ubuntu.ttf", 
                code_first_char, code_char_num,
                atlas_size,
                font_size,
                std.heap.c_allocator)
                catch @panic("cannot load default font");
            self.white_tex = Texture.dummy();

            log("DEBUG: bitmap: {}x{}, id: {}", .{ self.default_font.bitmap.w, self.default_font.bitmap.h, self.default_font.bitmap.id });
            // log("DEBUG: enable range: {}, {} {}", .{ text_range_end, text_range_start, text_range_count });
            //
            // Finalize
            //
            self.render_fn = render_fn; 
            self.user_data = user_data;

            self.mouse_pos_screen = .{ @intCast(@divFloor(w, 2)), @intCast(@divFloor(h, 2)) };
            self.mouse_pos_gl = .{0, 0};

            self.a = a;
            self.input_chars = .empty;
        }

        pub fn screen_to_gl_coord(self: Self, v: Vec2u) Vec2 {
            const xf: f32 = @floatFromInt(v[0]);
            const yf: f32 = @floatFromInt(v[1]);
            const vf : f32 = @floatFromInt(self.vierwport_size);
            return if (self.aspect_ratio > 1)
                 .{
                    (xf/vf - 0.5) * 2,
                    (yf/(vf/self.aspect_ratio) - 0.5) * -2 / self.aspect_ratio,
                }
            else
                .{
                    (xf/(vf*self.aspect_ratio) - 0.5) * 2 * self.aspect_ratio,
                    (yf/vf - 0.5) * 2,
                };

        }

        pub fn window_should_close(self: *Self) bool {
            self.mouse_left = false;
            self.input_chars.clearRetainingCapacity();

            var event: c.RGFW_event = undefined;
            while (c.RGFW_window_checkEvent(self.window, &event) != 0) {
                switch (event.type) {
                    c.RGFW_mousePosChanged => {
                        // log("DEBUG mouse {},{}", .{ event.mouse.x, event.mouse.y });
                        self.mouse_pos_screen = .{ @intCast(event.mouse.x), @intCast(event.mouse.y) };
                        self.mouse_pos_gl = self.screen_to_gl_coord(.{ @intCast(self.mouse_pos_screen[0]), @intCast(self.mouse_pos_screen[1]) });
                    },
                    c.RGFW_mouseButtonPressed => {
                        self.mouse_left = event.button.value == c.RGFW_mouseLeft;
                    },
                    c.RGFW_keyPressed => {
                        self.input_chars.append(self.a, event.key.sym) catch unreachable;
                    },
                    else => {},
                }
            }
            return c.RGFW_window_shouldClose(self.window) != 0;
        }

        pub fn close_window(self: Self) void {
            return c.RGFW_window_close(self.window);
        }

        fn on_resize(win: ?*c.RGFW_window, w: i32, h: i32) callconv(.c) void {
            const ctx: *Self = @ptrCast(@alignCast(c.RGFW_window_getUserPtr(win)));
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

        pub fn render(self: *Self) void {
            self.render_fn(self);
            c.RGFW_window_swapBuffers_OpenGL(self.window);
        }

        const BaseVertexData = extern struct {
            pos: Vec3,
            rgba: Vec4,
            tex: Vec2,
        };

        pub fn clear(_: Self, rgba: RGBA) void {
            const rgba_vec4 = rgba.to_vec4();
            g.glClearColor(rgba_vec4[0], rgba_vec4[1], rgba_vec4[2], rgba_vec4[3]);
            g.glClear(g.GL_COLOR_BUFFER_BIT);

        }

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
                if (code_point < code_first_char or code_point > code_last_char) {
                    var encode_buf: [32]u8 = undefined;
                    if (std.unicode.utf8Encode(code_point, &encode_buf)) |len| {
                        log("WARNING: unsupported characteer `{s}`", .{ encode_buf[0..len] });
                    } else |err| {
                        log("WARNING: Invalid unicode sequence `0x{s}`: {}", .{ std.fmt.hex(code_point), err });
                    }
                    continue;
                }
                
                const packed_char = &self.default_font.packed_chars[code_point - code_first_char];
                const aligned_quad = &self.default_font.aligned_quads[code_point - code_first_char];

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
                    self.default_font.bitmap, tex_coord,
                    rgba,
                    false,
                   self.font_shader_pgm);
                local_pos[0] += advance;
            }

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

        pub fn screen_x(self: Self) f32 {
            return 2 * self.x_right();
        }

        pub fn screen_y(self: Self) f32 {
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
