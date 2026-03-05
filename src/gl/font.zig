
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const gl = @import("gl.zig");
const GLObj = gl.GLObj;
const Texture = @import("texture.zig");
const g = gl.g;

const c = @cImport({
    @cInclude("thirdparty/stb_truetype.h");
});

var font_id: u8 = 0;
const Font = @This();
content: []const u8,
id: u8,

pub fn load_font_content(file_path: []const u8, gpa: Allocator) !Font {
    var ttf_f = try std.fs.cwd().openFile(file_path, .{});
    const ttf_content = ttf_f.readToEndAlloc(gpa, 1024*1024*1024) catch @panic("OOM");
    defer font_id += 1;
    return .{ .content = ttf_content, .id = font_id };
}

pub const Static = struct {
    bitmap: Texture,
    packed_chars: []c.stbtt_packedchar,
    aligned_quads: []c.stbtt_aligned_quad,
    code_first_char: u21,
    code_char_num: u32,

    pub fn load_ttf_from_file(
        ttf_file_path: []const u8,
        code_first_char: u21, code_char_num: u32,
        atlas_size: gl.Vec2u,
        font_size: f32,
        a: std.mem.Allocator,) !Static {

        const ttf_f = try std.fs.cwd().openFile(ttf_file_path, .{});
        const ttf_content = try ttf_f.readToEndAlloc(a, 1024*1024*1024);
        defer a.free(ttf_content);

        return load_ttf(ttf_content, code_first_char, code_char_num, atlas_size, font_size, a);
    }

    pub fn load_ttf(
        ttf_content: []const u8,
        code_first_char: u21, code_char_num: u32,
        atlas_size: gl.Vec2u,
        font_size: f32,
        a: std.mem.Allocator,) !Static {

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
};

pub const Dynamic = struct {

    pub const Glyph = u32;
    pub const HashKey = struct { 
        code: u21, 
        size: f32,
        font_id: u8,
    };
    const HashContext = struct {
        pub fn hash(_: HashContext, key: HashKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            auto_hash(&hasher, key);
            return hasher.final();
        }

        pub fn eql(_: HashContext, a: HashKey, b: HashKey) bool {
            return 
                a.code == b.code and 
                a.size == b.size and
                a.font_id == b.font_id;
        }

        fn auto_hash(hasher: anytype, key: anytype) void {
            const Key = @TypeOf(key);
            if (Key == []const u8 or Key == []u8) {
                return hasher.update(key);
            }
            switch (@typeInfo(Key)) {
                .float => |info| {
                    assert(key > 0);
                    return std.hash.autoHash(hasher, @as(std.meta.Int(.unsigned, info.bits), @bitCast(key)));
                },
                .@"struct" => |info| {
                    inline for (info.fields) |field| {
                        auto_hash(hasher, @field(key, field.name));
                    }
                },
                else => return std.hash.autoHash(hasher, key),
            }
        }
    };

    gpa: Allocator,

    spc: c.stbtt_pack_context,
    atlas_size: gl.Vec2u,

    tex: gl.GLObj,

    cache: std.HashMapUnmanaged(HashKey, Glyph, HashContext, 90) = .empty,

    packed_chars: std.ArrayList(c.stbtt_packedchar) = .empty,
    aligned_quads: std.ArrayList(c.stbtt_aligned_quad) = .empty,

    pub fn init(atlas_size: gl.Vec2u, gpa: Allocator) Dynamic {
        std.log.debug("here", .{});
        var spc: c.stbtt_pack_context = undefined;
        const bitmap = gpa.alloc(u8, atlas_size[0] * atlas_size[1]) catch unreachable; 
        assert(c.stbtt_PackBegin(&spc, bitmap.ptr, @intCast(atlas_size[0]), @intCast(atlas_size[1]), 0, 1, null) == 1);

        var bitmap_tex_id: GLObj = undefined;
        g.glGenTextures(1, &bitmap_tex_id);
        g.glBindTexture(g.GL_TEXTURE_2D, bitmap_tex_id);

        g.glTexImage2D(g.GL_TEXTURE_2D, 0,
            g.GL_R8,
            @intCast(atlas_size[0]), @intCast(atlas_size[1]), 0, g.GL_RED, g.GL_UNSIGNED_BYTE, bitmap.ptr);
        g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_MIN_FILTER, g.GL_LINEAR);
        g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_MAG_FILTER, g.GL_LINEAR);
        g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_WRAP_S, g.GL_REPEAT);
        g.glTexParameteri(g.GL_TEXTURE_2D, g.GL_TEXTURE_WRAP_T, g.GL_REPEAT);

        return .{
            .gpa = gpa,
            .spc = spc,
            .atlas_size = atlas_size,

            .tex = bitmap_tex_id,
        };
    }

    pub fn load_range(font_cache: *Dynamic, font: Font, start: u21, num: u21, font_size: f32) void {
        const before_size = font_cache.packed_chars.items.len;
        font_cache.packed_chars.appendNTimes(font_cache.gpa, undefined, num) catch @panic("OOM"); 
        font_cache.aligned_quads.appendNTimes(font_cache.gpa, undefined, num) catch @panic("OOM"); 
        const ret = c.stbtt_PackFontRange(
            &font_cache.spc,
            font.content.ptr,
            0,
            font_size,
            start,
            num,
            &font_cache.packed_chars.items[before_size],
        );
        if (ret != 1)
            std.log.warn("bitmap possibly ran out of space", .{});
        for (before_size..before_size+num, start..start+num) |i, code_point| {
            var _x: f32 = undefined;
            var _y: f32 = undefined;
            c.stbtt_GetPackedQuad(font_cache.packed_chars.items.ptr, 
                1024, 1024, 
                @intCast(i),
                &_x,
                &_y,
                &font_cache.aligned_quads.items[i],
                0);

            font_cache.cache.put(font_cache.gpa, .{ .code = @intCast(code_point), .size = font_size, .font_id = font.id }, @intCast(i)) catch @panic("OOM");
        }
        g.glBindTexture(g.GL_TEXTURE_2D, font_cache.tex);

        // TODO: optimize with TexSubImage2D
        g.glTexImage2D(g.GL_TEXTURE_2D, 0,
            g.GL_R8,
            @intCast(font_cache.spc.width), @intCast(font_cache.spc.height), 0, g.GL_RED, g.GL_UNSIGNED_BYTE, font_cache.spc.pixels);
    }

    pub fn get_or_load(font_cache: *Dynamic, font: Font, code: u21, font_size: f32) struct { c.stbtt_packedchar, c.stbtt_aligned_quad } {
        const key = HashKey { .code = code, .size = font_size, .font_id = font.id };
        const glyph = font_cache.cache.get(key) orelse blk: {
            font_cache.load_range(font, code, 1, font_size);
            break :blk font_cache.cache.get(key).?;
        };
        return .{
            font_cache.packed_chars.items[glyph],
            font_cache.aligned_quads.items[glyph],
        };
    }

    pub fn deinit(font_cache: *Dynamic) void {
        const gpa = font_cache.gpa;
        gpa.free(font_cache.spc.pixels[0..font_cache.atlas_size[0]*font_cache.atlas_size[1]]);
        c.stbtt_PackEnd(&font_cache.spc);

        font_cache.cache.deinit(gpa);
        font_cache.packed_chars.deinit(gpa);
        font_cache.aligned_quads.deinit(gpa);
    }

};


