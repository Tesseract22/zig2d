const std = @import("std");
const gl = @import("gl");
const RGBA = gl.RGBA;

const Context = struct {
    rock_tex: gl.Texture,
};

const GLContext = gl.Context(Context);
fn render(ctx: *GLContext) void {
    ctx.clear(RGBA.from_u32(0x181818ff));
    // ctx.draw_rect(.{ -0.25, -0.25 }, .{ 0.5, 0.5}, RGBA.from_u32(0xff00007f));
    // ctx.draw_rect(.{ -0.5, -0.5 }, .{ 1, 1 }, RGBA.from_u32(0x00ff007f));
    // ctx.draw_triangle(.{ -0.3, -0.3}, .{ 0.3, -0.3 }, .{0, 0.3}, .{ .b = 255, .a = 127 } );
    ctx.draw_tex(.{ -0.5, -0.5 }, .{ 1, 1 }, ctx.user_data.rock_tex, RGBA.from_u32(0xffffffff));

    ctx.draw_text(.{0.0, 0.0}, 1, "Hello, World", RGBA.from_u32(0xffffffff));
    ctx.draw_text_within_width(.{0.0, -0.1}, 1,
        "This is a loooooooooooooooooooong text", 0.2, RGBA.from_u32(0xffffffff));
}

pub fn main() !void {
    var user_data: Context = undefined;
    var ctx: GLContext = undefined;
    try ctx.init(&user_data, render, "demo", 1920, 1024, std.heap.c_allocator);

    user_data.rock_tex = gl.Texture.from_png_file("rock.png");

    while (!ctx.window_should_close()) {
        ctx.render();
    }

    ctx.close_window();
}
