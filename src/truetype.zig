const c = @cImport({
    @cInclude("thirdparty/stb_truetype.h");
    @cInclude("thirdparty/lodepng/lodepng.h");
});


const std = @import("std");
const assert = std.debug.assert;

const font_atlas_w = 1024;
const font_atlas_h = 1024;

const code_first_char = 0x4E00; // '一'
const code_last_char = 0x9FFF; //
// const code_first_char = ' '; // '一'
// const code_last_char = '~'; //

const code_char_num = code_last_char - code_first_char + 1;

const font_size = 64.0;

const font_path = "C:/Windows/Fonts/simfang.ttf";


pub fn main() !void {
    const a = std.heap.c_allocator;
    const ttf_f = try std.fs.cwd().openFile(font_path, .{});
    const ttf_content = try ttf_f.readToEndAlloc(a, 1024*1024*1024);

    const font_ct = c.stbtt_GetNumberOfFonts(ttf_content.ptr); 
    std.log.info("font count: {}", .{ font_ct });

    for (0.. @intCast(font_ct)) |index| {
        var info: c.stbtt_fontinfo = undefined;
        const offset = c.stbtt_GetFontOffsetForIndex(ttf_content.ptr, @intCast(index));
        assert(c.stbtt_InitFont(&info, ttf_content.ptr, offset) != 0);

        const dummy_index = c.stbtt_FindGlyphIndex(&info, 11111);
        const CN_one_index = c.stbtt_FindGlyphIndex(&info, code_first_char);
        std.log.info("index for {}: {}", .{ code_first_char, CN_one_index });
        if (dummy_index == CN_one_index) {
            std.log.warn("Glyph does not exist in font", .{});
        }

        // if (font_ct < 0) unreachable;
        std.log.info("Generating glyphs from {}~{}, total {}", 
            .{ code_first_char, code_last_char, code_char_num });

        var font_bitmap: [font_atlas_w * font_atlas_h]u8 = undefined;
        var packed_chars: [code_char_num]c.stbtt_packedchar = undefined;
        var aligned_quads: [code_char_num]c.stbtt_aligned_quad = undefined;
        _ = &aligned_quads;

        var ctx = c.stbtt_pack_context {};

        const start = std.time.milliTimestamp();
        assert(c.stbtt_PackBegin(
                &ctx,
                &font_bitmap,
                font_atlas_w,
                font_atlas_h,
                0,
                1,
                null,
        ) == 1);

        const ret = c.stbtt_PackFontRange(
            &ctx,
            &ttf_content[@intCast(offset)],
            0,
            font_size,
            code_first_char,
            1,
            &packed_chars
        );
        _ = c.stbtt_PackFontRange(
            &ctx,
            &ttf_content[@intCast(offset)],
            0,
            font_size,
            code_first_char,
            code_char_num,
            &packed_chars
        );

        // c.stbtt_PackEnd(&ctx);
        const end = std.time.milliTimestamp();
        std.log.info("{}ms taken to rendered, ret: {}", .{ end-start, ret });

        for (0..code_char_num) |i| {
            var _x: f32 = undefined;
            var _y: f32 = undefined;
            c.stbtt_GetPackedQuad(&packed_chars, 
                font_atlas_w, font_atlas_h, 
                @intCast(i),
                &_x,
                &_y,
                &aligned_quads[i],
                0);
        }

        const bitmap_path = try std.fmt.allocPrintSentinel(std.heap.c_allocator, "bitmap_{}.png", .{ index }, 0);
        const encode_err = c.lodepng_encode_file(bitmap_path, &font_bitmap, font_atlas_w, font_atlas_h, c.LCT_GREY, 8);

        std.log.info("encode into file: {s}: {s}", .{ bitmap_path, c.lodepng_error_text(encode_err) });
    }
}
