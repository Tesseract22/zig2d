const Font = @This();

const std = @import("std");
const assert = std.debug.assert;

const gl = @import("gl.zig");
const GLObj = gl.GLObj;
const Texture = @import("texture.zig");
const g = gl.g;

const c = @cImport({
    @cInclude("thirdparty/stb_truetype.h");
});


bitmap: Texture,
packed_chars: []c.stbtt_packedchar,
aligned_quads: []c.stbtt_aligned_quad,
code_first_char: u21,
code_char_num: u32,

// pub fn load_ttf_from_memory(ttf_content: []const u8, a: std.mem.Allocator) !Font 

pub fn load_ttf(
    ttf_file_path: []const u8,
    code_first_char: u21, code_char_num: u32,
    atlas_size: gl.Vec2u,
    font_size: f32,
    a: std.mem.Allocator,) !Font {
    const ttf_f = try std.fs.cwd().openFile(ttf_file_path, .{});
    const ttf_content = try ttf_f.readToEndAlloc(a, 1024*1024*1024);
    defer a.free(ttf_content);

    const font_ct = c.stbtt_GetNumberOfFonts(ttf_content.ptr); 
    std.log.info("font count: {}", .{ font_ct });
    if (font_ct < 0) unreachable;
    
    const font_bitmap = try a.alloc(u8, atlas_size[0] * atlas_size[1]);
    defer a.free(font_bitmap);
    const packed_chars = try a.alloc(c.stbtt_packedchar, code_char_num);
    const aligned_quads = try a.alloc(c.stbtt_aligned_quad, code_char_num);

    var ctx = c.stbtt_pack_context {};

    assert(c.stbtt_PackBegin(
            &ctx,
            font_bitmap.ptr,
            @intCast(atlas_size[0]),
            @intCast(atlas_size[1]),
            0,
            1,
            null,
    ) == 1);

    _ = c.stbtt_PackFontRange(
        &ctx,
        ttf_content.ptr,
        0,
        font_size,
        code_first_char,
        @intCast(code_char_num),
        packed_chars.ptr,
    );

    c.stbtt_PackEnd(&ctx);

    //
    // Populate the bitmap
    //
    for (0..code_char_num) |i| {
        var _x: f32 = undefined;
        var _y: f32 = undefined;
        c.stbtt_GetPackedQuad(packed_chars.ptr, 
            @intCast(atlas_size[0]), @intCast(atlas_size[1]), 
            @intCast(i),
            &_x,
            &_y,
            &aligned_quads[i],
            0);
    }
    var bitmap_tex_id: GLObj = undefined;
    g.glGenTextures(1, &bitmap_tex_id);
    g.glBindTexture(g.GL_TEXTURE_2D, bitmap_tex_id);

    g.glTexImage2D(g.GL_TEXTURE_2D, 0,
        g.GL_R8,
        @intCast(atlas_size[0]), @intCast(atlas_size[1]), 0, g.GL_RED, g.GL_UNSIGNED_BYTE, font_bitmap.ptr);
    g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_MIN_FILTER, g.GL_LINEAR);
    g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_MAG_FILTER, g.GL_LINEAR);
    g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_WRAP_S, g.GL_REPEAT);
    g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_WRAP_T, g.GL_REPEAT);


    return .{
        .bitmap = .{
            .id = bitmap_tex_id,
            .w = atlas_size[0],
            .h = atlas_size[1],
        },
        .packed_chars = packed_chars,
        .aligned_quads = aligned_quads,
        .code_first_char = code_first_char,
        .code_char_num = code_char_num,
    };
}


