const std = @import("std");

const Texture = @This();

const gl = @import("gl.zig");
const GLObj = gl.GLObj;
const log = gl.log;
const RGBA = gl.RGBA;

const c = @cImport({
    @cInclude("thirdparty/lodepng/lodepng.h");
});

const g = gl.g;

w: c_uint,
h: c_uint,
id: GLObj,


// GLContext must be properly initialized before any texture is loaded
pub fn from_u32rgba_memory(w: c_uint, h: c_uint, data: [*]const RGBA) GLObj {
    var id: GLObj = undefined;
    g.glGenTextures(1, &id);
    g.glBindTexture(g.GL_TEXTURE_2D, id);
    g.glTexImage2D(g.GL_TEXTURE_2D, 0, g.GL_RGBA, 
        @intCast(w), @intCast(h), 0, g.GL_RGBA, g.GL_UNSIGNED_BYTE, data);
    g.glGenerateMipmap(g.GL_TEXTURE_2D);
    
    return id;
}

pub fn from_png_memory(data: []const u8) Texture {
    var tex: Texture = undefined;
    var out_ptr: [*]u8 = undefined;
    const err = c.lodepng_decode32(@ptrCast(&out_ptr), &tex.w, &tex.h, data.ptr, data.len);
    defer std.c.free(out_ptr);
    if (err != 0) {
        log("ERROR: cannot decode png [{}] {s}", 
            .{ err, c.lodepng_error_text(err) }); 
        @panic("FATAL");
    }
    tex.id = from_u32rgba_memory(tex.w, tex.h, out_ptr);
   
    return tex;
}

pub fn from_png_file(filename: [:0]const u8) Texture {
    var out_ptr: [*]u8 = undefined;
    var tex: Texture = undefined;
    const err = c.lodepng_decode32_file(@ptrCast(&out_ptr), &tex.w, &tex.h, filename);
    if (err != 0) {
        log("ERROR: cannot decode png file: {s}: [{}] {s}", 
            .{ filename, err, c.lodepng_error_text(err) }); 
        @panic("FATAL");
    }
    tex.id = from_u32rgba_memory(tex.w, tex.h, @alignCast(@ptrCast(out_ptr)));
    std.c.free(out_ptr);

    return tex;
}

pub fn dummy() Texture {
    var tex = Texture { .w = 16, .h = 16, .id = undefined };
    const data = [_]RGBA { RGBA {.r = 255, .g = 255, .b = 255, .a = 255 } } ** (16*16);

    tex.id = from_u32rgba_memory(16, 16, &data);

    g.glBindTexture(g.GL_TEXTURE_2D, tex.id); // not really neccesary, but whatever

    g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_WRAP_S, g.GL_REPEAT);	
    g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_WRAP_T, g.GL_REPEAT);
    g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_MIN_FILTER, g.GL_LINEAR_MIPMAP_LINEAR);
    g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_MAG_FILTER, g.GL_LINEAR);

    g.glTexImage2D(g.GL_TEXTURE_2D, 0, g.GL_RGBA, 
        @intCast(tex.w), @intCast(tex.h), 0, g.GL_RGBA, g.GL_UNSIGNED_BYTE, &data);
    g.glGenerateMipmap(g.GL_TEXTURE_2D);

    return tex;
}

pub fn deinit(self: Texture) void {
    _ = self;
}



