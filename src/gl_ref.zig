const std = @import("std");

const c = @cImport({
    @cDefine("RGFW_OPENGL", {});
    @cDefine("RGFW_ADVANCED_SMOOTH_RESIZE", {});
    @cInclude("thirdparty/RGFW/RGFW.h");
});
const g = @cImport({
    @cInclude("thirdparty/glad.h");
    @cInclude("GL/gl.h");
});

var WINDOW_WIDTH: c_int = 1920;
var WINDOW_HEIGHT: c_int = 1024;

fn render(win: *c.RGFW_window) void {
    g.glClearColor(18.0/255.0, 18.0/255.0, 18.0/255.0, 1);
    g.glClear(g.GL_COLOR_BUFFER_BIT);

    g.glUseProgram(SHADER_PGM);
    g.glBindVertexArray(VAO);
    // g.glBindBuffer(g.GL_ELEMENT_ARRAY_BUFFER, EBO);
    // g.glDrawArrays(g.GL_TRIANGLES, 0, 3);
    g.glDrawElements(g.GL_TRIANGLES, 6, g.GL_UNSIGNED_INT, @ptrFromInt(0));

    // gl.glRotatef(0.1, 0, 0, 1);
    // gl.glBegin(gl.GL_TRIANGLES);
    // {
    //     gl.glColor3f(1.0, 0.0, 0.0); gl.glVertex2f(-0.6, -0.75);
    //     gl.glColor3f(0.0, 1.0, 0.0); gl.glVertex2f(0.6, -0.75);
    //     gl.glColor3f(0.0, 0.0, 1.0); gl.glVertex2f(0.0, 0.75);
    // }
    // gl.glEnd();
    // g.glBegin(g.GL_QUADS);
    // {
    //     g.glVertex2f(-0.5, 0.5);
    //     g.glVertex2f(0.5, 0.5);
    //     g.glVertex2f(0.5, -0.5);
    //     g.glVertex2f(-0.5, -0.5);
    // }
    // g.glEnd();
    c.RGFW_window_swapBuffers_OpenGL(win);
}

fn on_resize(_: ?*c.RGFW_window, w: i32, h: i32) callconv(.c) void {
    //.std.log.debug("resized", .{});
    // WINDOW_WIDTH = w;
    // WINDOW_HEIGHT = h;
    if (w > h)
        g.glViewport(0, @divFloor(h-w, 2), w, w)
    else
        g.glViewport(@divFloor(w-h, 2), 0, h, h);
}

fn on_refresh(win: ?*c.RGFW_window) callconv(.c) void {
    std.log.debug("refresh", .{});
    render(win.?);
}

const vs_src = @embedFile("gl/resources/shaders/base_vertex.glsl");
const fs_src = @embedFile("gl/resources/shaders/base_fragment.glsl");

const ShaderError = error { ShaderCompileError };
const ProgramError = error {
    LinkError,
} || ShaderError;

fn load_shader(src: [:0]const u8, kind: c_uint) ShaderError!g.GLuint {
    const shader = g.glCreateShader(kind);
    g.glShaderSource(shader, 1, &src.ptr, null);
    g.glCompileShader(shader);
    var success: c_int = undefined;
    g.glGetShaderiv(shader, g.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var log_buf: [256]u8 = undefined;
        g.glGetShaderInfoLog(shader, log_buf.len, null, &log_buf);
        std.log.err("Failed to compile {s} shader: {s}",
            .{ if (kind == g.GL_VERTEX_SHADER) "vertex" else "fragment", log_buf});
        return ShaderError.ShaderCompileError;
    }
    return shader;
}

fn create_program() ProgramError!g.GLuint {
    const vs = try load_shader(vs_src, g.GL_VERTEX_SHADER);
    const fs = try load_shader(fs_src, g.GL_FRAGMENT_SHADER);

    const pgm = g.glCreateProgram();
    g.glAttachShader(pgm, vs);
    g.glAttachShader(pgm, fs);

    g.glLinkProgram(pgm);
    var success: c_int = undefined;
    g.glGetProgramiv(pgm, g.GL_LINK_STATUS, &success);
    if (success == 0) {
        var log_buf: [256]u8 = undefined;
        g.glGetShaderInfoLog(pgm, log_buf.len, null, &log_buf);
        std.log.err("Failed to compile shader: {s}", .{log_buf});
        return ProgramError.LinkError;
    }
    return pgm;
}

fn use_program(pgm: g.GLuint) void {
    g.glUseProgram(pgm);
}

var VAO: g.GLuint = undefined;
var EBO: g.GLuint = undefined;
var SHADER_PGM: g.GLuint = undefined;

const Vec3 = [3]f32;
const Vec2 = [2]f32;
const Vec3u = [3]g.GLuint;

const VertexData = extern struct {
    pos: Vec3,
    rgba: [4]f32,
    tex: Vec2,
};

pub fn bind_vertex_attr(comptime T: type, array: []const T) !void {
    const struct_info = @typeInfo(T).@"struct";

    g.glBufferData(g.GL_ARRAY_BUFFER, @intCast(@sizeOf(T) * array.len), array.ptr, g.GL_STATIC_DRAW);
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

pub fn bind_vertex_texs_attr(
    comptime T: type, 
    comptime field: []const u8, 
    attr_loc: g.GLuint) !void {
    g.glVertexAttribPointer(attr_loc, 
        3, g.GL_FLOAT,
        g.GL_FALSE,
        @sizeOf(T),
        @ptrFromInt(@offsetOf(T, field)));
    g.glEnableVertexAttribArray(attr_loc);

}

pub fn main() !void {
    //const fs = g.glCreateShader(g.GL_VERTEX_SHADER);
    //g.glShaderSource(fs, 1, &fs_code, null);
    //std.log.debug("ShaderSource: {}", .{g.glGetError()});
    //g.glCompileShader(fs);
    //std.log.debug("CompileShader: {}", .{g.glGetError()});
    //
    
    
    const win = c.RGFW_createWindow("Hello from Zig", 0, 0, WINDOW_WIDTH, WINDOW_HEIGHT, 
        c.RGFW_windowCenter
        // | c.RGFW_windowNoResize
        | c.RGFW_windowOpenGL) orelse unreachable;
    c.RGFW_window_makeCurrentWindow_OpenGL(win);
    _ = c.RGFW_setWindowRefreshCallback(on_refresh);
    _ = c.RGFW_setWindowResizedCallback(on_resize);

    if (g.gladLoadGL(c.RGFW_getProcAddress_OpenGL) == 0) {
        std.log.err("failed to load GLAD", .{});
        return;
    }
    on_resize(win, WINDOW_WIDTH, WINDOW_HEIGHT);

    const gl_version = g.glGetString(g.GL_VERSION);
    std.log.debug("gl version: {s}", .{ gl_version });

    SHADER_PGM = try create_program();
    const vertexes = [_]VertexData {
        .{ .pos = .{0.5, 0.5, 0},   .rgba = .{1, 0, 0, 1}, .tex = .{1, 1} },
        .{ .pos = .{0.5, -0.5, 0},  .rgba = .{1, 0, 0, 1}, .tex = .{1, 0} },
        .{ .pos = .{-0.5, -0.5, 0}, .rgba = .{1, 0, 0, 1}, .tex = .{0, 0} },
        .{ .pos = .{-0.5, 0.5, 0},  .rgba = .{1, 0, 0, 1}, .tex = .{0, 1} },
    };
    const indices = [_]Vec3u {
        .{ 0, 1, 3},
        .{ 1, 2, 3},
    };

    g.glGenVertexArrays(1, &VAO);
    g.glBindVertexArray(VAO);

    var VBO: g.GLuint = undefined;
    g.glGenBuffers(1, &VBO);
    g.glBindBuffer(g.GL_ARRAY_BUFFER, VBO);

    g.glGenBuffers(1, &EBO);
    g.glBindBuffer(g.GL_ELEMENT_ARRAY_BUFFER, EBO);
    g.glBufferData(g.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, g.GL_STATIC_DRAW);

    
    try bind_vertex_attr(VertexData, &vertexes);
    // try bind_vertex_texs_attr(VertexData, "pos", 2);
    g.glEnable(g.GL_BLEND); 
    g.glBlendFunc(g.GL_SRC_ALPHA, g.GL_ONE_MINUS_SRC_ALPHA);
    g.glBlendEquation(g.GL_FUNC_ADD);

    while (c.RGFW_window_shouldClose(win) == 0) {
        var event: c.RGFW_event = undefined;
        while (c.RGFW_window_checkEvent(win, &event) != 0) {}
        render(win);    
        // gl.glFlush();

    }
    c.RGFW_window_close(win);
}
