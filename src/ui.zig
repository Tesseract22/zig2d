const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl");
const Vec2 = gl.Vec2;

const RGBA = gl.RGBA;

const bg_color = RGBA.from_u32(0x303030ff);

const UI = struct {
    gpa: Allocator,
    selected_title: []const u8 = "",
    
    const titles: []const []const u8 = &.{ "Title A", "Title B" };
    fn render(ctx: *UIContext) void {
        const ui = ctx.user_data;

        ctx.clear(bg_color);
        const btn_h = ctx.cal_font_h(0.5) * 2;
        for (titles, 1..) |title, i| {
            const if32: f32 = @floatFromInt(i);
            if (button(
                    ctx,
                    .{ ctx.x_left(), ctx.y_top()-if32*btn_h }, 
                    .{ 0.3, btn_h },
                    0.5,
                    title)) {
                // std.log.debug("Cliekd", .{}); 
                ui.selected_title = title;
            }
        }
        ctx.draw_rect_lines(.{ ctx.x_left(), ctx.y_bot() }, .{ 0.3, ctx.screen_h() }, 5, .from_u32(0xffffff30));

        ctx.draw_text(.{0, 0}, 1, ctx.input_chars.items, .white);
        // std.log.info("Mouse gl pos: {any} {any}", .{ctx.mouse_pos_gl, ctx.mouse_pos_screen});
    }

    // retunr true if hovered
    fn button(ctx: *UIContext, botleft: Vec2, size: Vec2, font_size: f32, text: []const u8) bool {
        const within = within_rect(ctx.mouse_pos_gl, botleft, size);
        if (within) {
            ctx.draw_rect(botleft, size, .from_u32(0xffffff30));
        }
        // const yoffset = 0.1*ctx.cal_font_h(0.5);
        ctx.draw_text(.{ botleft[0], botleft[1] + (size[1]-ctx.cal_font_h(font_size))/2 }, font_size, text, .white);
        ctx.draw_rect_lines(botleft, size, 5, .from_u32(0xffffff30));
        return within and ctx.mouse_left;
    }

    fn within_rect(p: Vec2, botleft: Vec2, size: Vec2) bool {
        return p[0] >= botleft[0] and p[1] >= botleft[1]
            and p[0] <= botleft[0] + size[0] and p[1] <= botleft[1] + size[1];
    }
};
const UIContext = gl.Context(UI);

pub fn main() !void {
    const a = std.heap.c_allocator;
    var ui = UI { .gpa = a };
    var ctx: UIContext = undefined;
    try UIContext.init(&ctx, &ui, UI.render, "ui demo", 1920, 1024, a);

    while (!ctx.window_should_close()) {
        ctx.render();
    }

    ctx.close_window();
}
