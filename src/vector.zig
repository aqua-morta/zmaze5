//! Native SVG and PDF output (no cairo needed).
//!
//! A small drawing context with the operations the maze renderer uses
//! (paths with lines, Bézier curves and circular arcs, stroking, filling,
//! translation/rotation, simple text) that serializes to an SVG or a PDF
//! document in memory. It follows cairo's semantics: paths are built and
//! then stroked or filled (nonzero winding), an arc continues the current
//! subpath with a line to its start, the color applies to both strokes and
//! fills. Arcs are converted to Bézier curves (at most 90° each, like
//! cairo), so both formats only need lines and cubic curves.
//!
//! Text uses the viewer's sans-serif font in SVG and the standard
//! Helvetica font in PDF (no embedding needed); its widths are known, so
//! text can be centered exactly in PDF. In SVG text is centered with
//! `text-anchor`.
//!
//! A knockout group (`beginKnockout`/`endKnockout`) cuts an area out of the
//! drawing inside it, e.g. the walls below the bridges of crossings when the
//! background is transparent and can't hide them. SVG uses a `<mask>`, PDF a
//! luminosity soft mask (an ExtGState with a form XObject).

const std = @import("std");
const geo = @import("geo.zig");

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;

pub const Kind = enum { svg, pdf };

pub const Color = @import("render.zig").Color;

/// Text placement: `center` centers the text on the point, `right_bottom`
/// ends it at x with the baseline half a text height above y (the
/// copyright line in the lower right corner).
pub const TextAlign = enum { center, right_bottom };

/// Font size of all text (cairo's default).
pub const FONT_SIZE: f64 = 10.0;
/// Approximate height of digits and capitals relative to the font size
/// (used for vertical centering).
const CAP_HEIGHT: f64 = 0.72;

pub const Canvas = struct {
    gpa: Allocator,
    kind: Kind,
    width: f64,
    height: f64,
    /// SVG elements or the PDF content stream
    body: std.ArrayListUnmanaged(u8) = .empty,
    /// path data of the current path
    path: std.ArrayListUnmanaged(u8) = .empty,
    current: ?Vec2 = null,
    subpath_start: ?Vec2 = null,
    color: Color = .{ .red = 0, .green = 0, .blue = 0 },
    line_width: f64 = 2,
    /// open SVG groups (transformations)
    groups: usize = 0,
    /// PDF: the alpha values used (one graphics state each)
    alphas: std.ArrayListUnmanaged(f64) = .empty,
    pdf_alpha: f64 = 1,
    pdf_color_set: bool = false,
    /// user to page: x' = a·x + c·y + e, y' = b·x + d·y + f (y down; for the
    /// bounds of knockout masks)
    ctm: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    /// the state at the start of the open knockout group
    knockout: ?KnockoutStart = null,
    knockout_count: usize = 0,
    /// PDF: the soft masks of the knockout groups
    masks: std.ArrayListUnmanaged(Mask) = .empty,

    const KnockoutStart = struct { color: Color, line_width: f64, pdf_alpha: f64, groups: usize };
    /// The bounding box (user space) and the content stream of a soft mask.
    const Mask = struct { box: [4]f64, content: []u8 };

    pub fn init(gpa: Allocator, kind: Kind, width: f64, height: f64) Canvas {
        return .{ .gpa = gpa, .kind = kind, .width = width, .height = height };
    }

    pub fn deinit(cv: *Canvas) void {
        cv.body.deinit(cv.gpa);
        cv.path.deinit(cv.gpa);
        cv.alphas.deinit(cv.gpa);
        for (cv.masks.items) |m| cv.gpa.free(m.content);
        cv.masks.deinit(cv.gpa);
    }

    fn out(cv: *Canvas, comptime fmt: []const u8, args: anytype) !void {
        try cv.body.print(cv.gpa, fmt, args);
    }

    fn pathOut(cv: *Canvas, comptime fmt: []const u8, args: anytype) !void {
        try cv.path.print(cv.gpa, fmt, args);
    }

    // -- state ---------------------------------------------------------

    pub fn setColor(cv: *Canvas, col: Color) !void {
        cv.color = col;
        if (cv.kind == .pdf) {
            try cv.out("{d:.4} {d:.4} {d:.4} rg {d:.4} {d:.4} {d:.4} RG\n", .{ col.red, col.green, col.blue, col.red, col.green, col.blue });
            if (col.alpha != cv.pdf_alpha) {
                try cv.out("/GS{d} gs\n", .{try cv.alphaIndex(col.alpha)});
                cv.pdf_alpha = col.alpha;
            }
        }
    }

    fn alphaIndex(cv: *Canvas, a: f64) !usize {
        for (cv.alphas.items, 0..) |x, i| {
            if (x == a) return i;
        }
        try cv.alphas.append(cv.gpa, a);
        return cv.alphas.items.len - 1;
    }

    /// Line width; caps and joins are always round.
    pub fn setLineWidth(cv: *Canvas, w: f64) !void {
        cv.line_width = w;
        if (cv.kind == .pdf) try cv.out("{d:.4} w\n", .{w});
    }

    pub fn translate(cv: *Canvas, x: f64, y: f64) !void {
        const m = &cv.ctm;
        m[4] += m[0] * x + m[2] * y;
        m[5] += m[1] * x + m[3] * y;
        switch (cv.kind) {
            .svg => {
                try cv.out("<g transform=\"translate({d:.4},{d:.4})\">\n", .{ x, y });
                cv.groups += 1;
            },
            .pdf => try cv.out("1 0 0 1 {d:.4} {d:.4} cm\n", .{ x, y }),
        }
    }

    /// Rotation by `a` radians (clockwise on the page, like cairo's).
    pub fn rotate(cv: *Canvas, a: f64) !void {
        if (a == 0) return;
        const sa = @sin(a);
        const ca = @cos(a);
        const m = cv.ctm;
        cv.ctm[0] = m[0] * ca + m[2] * sa;
        cv.ctm[1] = m[1] * ca + m[3] * sa;
        cv.ctm[2] = -m[0] * sa + m[2] * ca;
        cv.ctm[3] = -m[1] * sa + m[3] * ca;
        switch (cv.kind) {
            .svg => {
                try cv.out("<g transform=\"rotate({d:.6})\">\n", .{a * 180.0 / std.math.pi});
                cv.groups += 1;
            },
            .pdf => {
                const s = @sin(a);
                const co = @cos(a);
                try cv.out("{d:.6} {d:.6} {d:.6} {d:.6} 0 0 cm\n", .{ co, s, -s, co });
            },
        }
    }

    // -- paths ---------------------------------------------------------

    pub fn moveTo(cv: *Canvas, x: f64, y: f64) !void {
        switch (cv.kind) {
            .svg => try cv.pathOut("M{f} {f}", .{ num(x), num(y) }),
            .pdf => try cv.pathOut("{f} {f} m\n", .{ num(x), num(y) }),
        }
        cv.current = .{ .x = x, .y = y };
        cv.subpath_start = cv.current;
    }

    pub fn lineTo(cv: *Canvas, x: f64, y: f64) !void {
        if (cv.current == null) return cv.moveTo(x, y);
        switch (cv.kind) {
            .svg => try cv.pathOut("L{f} {f}", .{ num(x), num(y) }),
            .pdf => try cv.pathOut("{f} {f} l\n", .{ num(x), num(y) }),
        }
        cv.current = .{ .x = x, .y = y };
    }

    pub fn curveTo(cv: *Canvas, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) !void {
        if (cv.current == null) try cv.moveTo(x1, y1);
        switch (cv.kind) {
            .svg => try cv.pathOut("C{f} {f} {f} {f} {f} {f}", .{ num(x1), num(y1), num(x2), num(y2), num(x3), num(y3) }),
            .pdf => try cv.pathOut("{f} {f} {f} {f} {f} {f} c\n", .{ num(x1), num(y1), num(x2), num(y2), num(x3), num(y3) }),
        }
        cv.current = .{ .x = x3, .y = y3 };
    }

    pub fn closePath(cv: *Canvas) !void {
        if (cv.current == null) return;
        switch (cv.kind) {
            .svg => try cv.pathOut("Z", .{}),
            .pdf => try cv.pathOut("h\n", .{}),
        }
        cv.current = cv.subpath_start;
    }

    pub fn rectangle(cv: *Canvas, x: f64, y: f64, w: f64, h: f64) !void {
        try cv.moveTo(x, y);
        try cv.lineTo(x + w, y);
        try cv.lineTo(x + w, y + h);
        try cv.lineTo(x, y + h);
        try cv.closePath();
    }

    /// Arc around (xc, yc) from angle a1 to a2 in the direction of
    /// increasing angles (cairo_arc).
    pub fn arc(cv: *Canvas, xc: f64, yc: f64, r: f64, a1: f64, a2_: f64) !void {
        var a2 = a2_;
        while (a2 < a1) a2 += 2 * std.math.pi;
        try cv.arcSegments(xc, yc, r, a1, a2);
    }

    /// Arc in the direction of decreasing angles (cairo_arc_negative).
    pub fn arcNegative(cv: *Canvas, xc: f64, yc: f64, r: f64, a1: f64, a2_: f64) !void {
        var a2 = a2_;
        while (a2 > a1) a2 -= 2 * std.math.pi;
        try cv.arcSegments(xc, yc, r, a1, a2);
    }

    fn arcSegments(cv: *Canvas, xc: f64, yc: f64, r: f64, a1: f64, a2: f64) !void {
        const start = Vec2{ .x = xc + r * @cos(a1), .y = yc + r * @sin(a1) };
        if (cv.current == null) try cv.moveTo(start.x, start.y) else try cv.lineTo(start.x, start.y);
        const total = a2 - a1;
        const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(total) / (std.math.pi / 2.0) - 1e-9))));
        const step = total / @as(f64, @floatFromInt(n));
        // control point distance for a circular arc of angle `step`
        const k = 4.0 / 3.0 * @tan(step / 4.0);
        var a = a1;
        for (0..n) |_| {
            const b = a + step;
            const ca = @cos(a);
            const sa = @sin(a);
            const cb = @cos(b);
            const sb = @sin(b);
            try cv.curveTo(
                xc + r * (ca - k * sa),
                yc + r * (sa + k * ca),
                xc + r * (cb + k * sb),
                yc + r * (sb - k * cb),
                xc + r * cb,
                yc + r * sb,
            );
            a = b;
        }
    }

    // -- painting ------------------------------------------------------

    const Paint = enum { stroke, fill, fill_stroke };

    fn paint(cv: *Canvas, what: Paint) !void {
        defer {
            cv.path.clearRetainingCapacity();
            cv.current = null;
            cv.subpath_start = null;
        }
        if (cv.path.items.len == 0) return;
        switch (cv.kind) {
            .svg => {
                const col = cv.color;
                try cv.out("<path d=\"{s}\"", .{cv.path.items});
                if (what == .stroke) {
                    try cv.out(" fill=\"none\"", .{});
                } else {
                    try cv.out(" fill=\"", .{});
                    try cv.svgColor(col);
                    try cv.out("\"", .{});
                    if (col.alpha != 1) try cv.out(" fill-opacity=\"{d:.4}\"", .{col.alpha});
                }
                if (what != .fill) {
                    try cv.out(" stroke=\"", .{});
                    try cv.svgColor(col);
                    try cv.out("\"", .{});
                    if (col.alpha != 1) try cv.out(" stroke-opacity=\"{d:.4}\"", .{col.alpha});
                }
                try cv.out("/>\n", .{});
            },
            .pdf => {
                try cv.body.appendSlice(cv.gpa, cv.path.items);
                try cv.out("{s}\n", .{switch (what) {
                    .stroke => "S",
                    .fill => "f",
                    .fill_stroke => "B",
                }});
            },
        }
    }

    fn svgColor(cv: *Canvas, col: Color) !void {
        const ch = struct {
            fn f(x: f64) u8 {
                return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
            }
        }.f;
        try cv.out("#{x:0>2}{x:0>2}{x:0>2}", .{ ch(col.red), ch(col.green), ch(col.blue) });
    }

    pub fn stroke(cv: *Canvas) !void {
        try cv.paint(.stroke);
    }

    pub fn fill(cv: *Canvas) !void {
        try cv.paint(.fill);
    }

    /// Fills the path and strokes its outline (cairo_fill_preserve +
    /// cairo_stroke with the same color).
    pub fn fillStroke(cv: *Canvas) !void {
        try cv.paint(.fill_stroke);
    }

    // -- knockout ------------------------------------------------------

    /// Starts a knockout group: `endKnockout` cuts an area out of everything
    /// drawn in between (only out of that, not out of what lies below). The
    /// transformation must not change inside the group.
    pub fn beginKnockout(cv: *Canvas) !void {
        std.debug.assert(cv.knockout == null);
        cv.knockout = .{ .color = cv.color, .line_width = cv.line_width, .pdf_alpha = cv.pdf_alpha, .groups = cv.groups };
        switch (cv.kind) {
            .svg => try cv.out("<g mask=\"url(#knockout{d})\">\n", .{cv.knockout_count}),
            .pdf => try cv.out("q /KO{d} gs\n", .{cv.knockout_count}),
        }
    }

    /// Ends the knockout group, cutting out the area of the current path
    /// (nonzero winding); the path is consumed like by `fill`.
    pub fn endKnockout(cv: *Canvas) !void {
        const start = cv.knockout.?;
        std.debug.assert(start.groups == cv.groups);
        cv.knockout = null;
        defer {
            cv.path.clearRetainingCapacity();
            cv.current = null;
            cv.subpath_start = null;
        }
        const id = cv.knockout_count;
        cv.knockout_count += 1;
        // the mask is white (drawn) on the whole page, black in the area
        const b = cv.userBounds();
        const x, const y, const w, const h = .{ num(b[0]), num(b[1]), num(b[2] - b[0]), num(b[3] - b[1]) };
        switch (cv.kind) {
            .svg => {
                try cv.out("</g>\n<mask id=\"knockout{d}\" maskUnits=\"userSpaceOnUse\" x=\"{f}\" y=\"{f}\" width=\"{f}\" height=\"{f}\">\n", .{ id, x, y, w, h });
                try cv.out("<rect x=\"{f}\" y=\"{f}\" width=\"{f}\" height=\"{f}\" fill=\"white\"/>\n", .{ x, y, w, h });
                if (cv.path.items.len > 0) try cv.out("<path d=\"{s}\" fill=\"black\"/>\n", .{cv.path.items});
                try cv.out("</mask>\n", .{});
            },
            .pdf => {
                try cv.out("Q\n", .{});
                var content: std.ArrayListUnmanaged(u8) = .empty;
                errdefer content.deinit(cv.gpa);
                try content.print(cv.gpa, "1 g {f} {f} {f} {f} re f 0 g\n", .{ x, y, w, h });
                if (cv.path.items.len > 0) {
                    try content.appendSlice(cv.gpa, cv.path.items);
                    try content.appendSlice(cv.gpa, "f\n");
                }
                const owned = try content.toOwnedSlice(cv.gpa);
                errdefer cv.gpa.free(owned);
                try cv.masks.append(cv.gpa, .{ .box = b, .content = owned });
                // `Q` restored the graphics state of the group's start; set
                // the current color and line width again
                cv.pdf_alpha = start.pdf_alpha;
                try cv.setColor(cv.color);
                if (cv.line_width != start.line_width) try cv.setLineWidth(cv.line_width);
            },
        }
    }

    /// Bounding box [x0, y0, x1, y1] of the page in user coordinates (a
    /// little larger, so masks cover the page completely).
    fn userBounds(cv: *const Canvas) [4]f64 {
        const m = cv.ctm;
        const det = m[0] * m[3] - m[1] * m[2];
        var b = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
        for ([_][2]f64{ .{ 0, 0 }, .{ cv.width, 0 }, .{ 0, cv.height }, .{ cv.width, cv.height } }) |p| {
            const px = p[0] - m[4];
            const py = p[1] - m[5];
            const ux = (m[3] * px - m[2] * py) / det;
            const uy = (-m[1] * px + m[0] * py) / det;
            b = .{ @min(b[0], ux), @min(b[1], uy), @max(b[2], ux), @max(b[3], uy) };
        }
        return .{ @floor(b[0]) - 1, @floor(b[1]) - 1, @ceil(b[2]) + 1, @ceil(b[3]) + 1 };
    }

    // -- text ----------------------------------------------------------

    pub fn text(cv: *Canvas, str: []const u8, x: f64, y: f64, alignment: TextAlign) !void {
        const h = CAP_HEIGHT * FONT_SIZE;
        switch (cv.kind) {
            .svg => {
                const anchor, const by = switch (alignment) {
                    .center => .{ "middle", y + h / 2 },
                    .right_bottom => .{ "end", y - h / 2 },
                };
                try cv.out("<text x=\"{f}\" y=\"{f}\" text-anchor=\"{s}\" font-family=\"sans-serif\" font-size=\"{d}\" fill=\"", .{ num(x), num(by), anchor, FONT_SIZE });
                try cv.svgColor(cv.color);
                try cv.out("\"", .{});
                if (cv.color.alpha != 1) try cv.out(" fill-opacity=\"{d:.4}\"", .{cv.color.alpha});
                try cv.out(">", .{});
                for (str) |ch| switch (ch) {
                    '<' => try cv.out("&lt;", .{}),
                    '>' => try cv.out("&gt;", .{}),
                    '&' => try cv.out("&amp;", .{}),
                    else => try cv.body.append(cv.gpa, ch),
                };
                try cv.out("</text>\n", .{});
            },
            .pdf => {
                var buf: [256]u8 = undefined;
                const latin = toLatin1(str, &buf);
                const w = helveticaWidth(latin) * FONT_SIZE;
                const tx, const ty = switch (alignment) {
                    .center => .{ x - w / 2, y + h / 2 },
                    .right_bottom => .{ x - w, y - h / 2 },
                };
                // the page is flipped (y down): flip the text back
                try cv.out("BT /F1 {d} Tf 1 0 0 -1 {f} {f} Tm (", .{ FONT_SIZE, num(tx), num(ty) });
                for (latin) |ch| switch (ch) {
                    '(', ')', '\\' => try cv.out("\\{c}", .{ch}),
                    else => if (ch < 32 or ch > 126) try cv.out("\\{o:0>3}", .{ch}) else try cv.body.append(cv.gpa, ch),
                };
                try cv.out(") Tj ET\n", .{});
            },
        }
    }

    // -- document ------------------------------------------------------

    /// The complete document.
    pub fn finish(cv: *Canvas) ![]u8 {
        var doc: std.ArrayListUnmanaged(u8) = .empty;
        errdefer doc.deinit(cv.gpa);
        switch (cv.kind) {
            .svg => {
                try doc.print(cv.gpa,
                    \\<?xml version="1.0" encoding="UTF-8"?>
                    \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}pt" height="{d}pt" viewBox="0 0 {d} {d}">
                    \\<g stroke-width="{d:.4}" stroke-linecap="round" stroke-linejoin="round">
                    \\
                , .{ cv.width, cv.height, cv.width, cv.height, cv.line_width });
                try doc.appendSlice(cv.gpa, cv.body.items);
                for (0..cv.groups) |_| try doc.appendSlice(cv.gpa, "</g>\n");
                try doc.appendSlice(cv.gpa, "</g>\n</svg>\n");
            },
            .pdf => try cv.finishPdf(&doc),
        }
        return doc.toOwnedSlice(cv.gpa);
    }

    fn finishPdf(cv: *Canvas, doc: *std.ArrayListUnmanaged(u8)) !void {
        const gpa = cv.gpa;
        var offsets: std.ArrayListUnmanaged(usize) = .empty;
        defer offsets.deinit(gpa);
        try doc.appendSlice(gpa, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");
        const first_gs = 6;
        // 1: catalog, 2: pages, 3: page, 4: contents, 5: font, 6..: alpha
        // states, then a graphics state and a form (the soft mask) per
        // knockout group
        const first_ko = first_gs + cv.alphas.items.len;
        try offsets.append(gpa, doc.items.len);
        try doc.appendSlice(gpa, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
        try offsets.append(gpa, doc.items.len);
        try doc.appendSlice(gpa, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
        try offsets.append(gpa, doc.items.len);
        try doc.print(gpa, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d} {d}] /Contents 4 0 R\n   /Resources << /Font << /F1 5 0 R >> /ExtGState <<", .{ cv.width, cv.height });
        for (0..cv.alphas.items.len) |i| try doc.print(gpa, " /GS{d} {d} 0 R", .{ i, first_gs + i });
        for (0..cv.masks.items.len) |i| try doc.print(gpa, " /KO{d} {d} 0 R", .{ i, first_ko + 2 * i });
        try doc.appendSlice(gpa, " >> >> >>\nendobj\n");
        // content: flip the y axis (cairo's coordinates have y down)
        var content: std.ArrayListUnmanaged(u8) = .empty;
        defer content.deinit(gpa);
        try content.print(gpa, "1 0 0 -1 0 {d} cm\n1 J 1 j\n", .{cv.height});
        try content.appendSlice(gpa, cv.body.items);
        const z = try deflate(gpa, content.items);
        defer gpa.free(z);
        try offsets.append(gpa, doc.items.len);
        try doc.print(gpa, "4 0 obj\n<< /Length {d} /Filter /FlateDecode >>\nstream\n", .{z.len});
        try doc.appendSlice(gpa, z);
        try doc.appendSlice(gpa, "\nendstream\nendobj\n");
        try offsets.append(gpa, doc.items.len);
        try doc.appendSlice(gpa, "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n");
        for (cv.alphas.items, 0..) |a, i| {
            try offsets.append(gpa, doc.items.len);
            try doc.print(gpa, "{d} 0 obj\n<< /Type /ExtGState /ca {d:.4} /CA {d:.4} >>\nendobj\n", .{ first_gs + i, a, a });
        }
        for (cv.masks.items, 0..) |m, i| {
            const gs = first_ko + 2 * i;
            try offsets.append(gpa, doc.items.len);
            try doc.print(gpa, "{d} 0 obj\n<< /Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G {d} 0 R >> >>\nendobj\n", .{ gs, gs + 1 });
            const mz = try deflate(gpa, m.content);
            defer gpa.free(mz);
            try offsets.append(gpa, doc.items.len);
            try doc.print(gpa, "{d} 0 obj\n<< /Type /XObject /Subtype /Form /BBox [{f} {f} {f} {f}]\n   /Group << /Type /Group /S /Transparency /CS /DeviceRGB >> /Length {d} /Filter /FlateDecode >>\nstream\n", .{ gs + 1, num(m.box[0]), num(m.box[1]), num(m.box[2]), num(m.box[3]), mz.len });
            try doc.appendSlice(gpa, mz);
            try doc.appendSlice(gpa, "\nendstream\nendobj\n");
        }
        const xref = doc.items.len;
        try doc.print(gpa, "xref\n0 {d}\n0000000000 65535 f \n", .{offsets.items.len + 1});
        for (offsets.items) |o| try doc.print(gpa, "{d:0>10} 00000 n \n", .{o});
        try doc.print(gpa, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ offsets.items.len + 1, xref });
    }
};

/// zlib compressed data (PDF's FlateDecode filter).
fn deflate(gpa: Allocator, data: []const u8) ![]u8 {
    const flate = std.compress.flate;
    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, @max(64, data.len / 4));
    errdefer aw.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var comp = flate.Compress.init(&aw.writer, window, .zlib, .default) catch return error.OutOfMemory;
    comp.writer.writeAll(data) catch return error.OutOfMemory;
    comp.finish() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// A coordinate printed with at most three decimals and without trailing
/// zeros (`{f}`).
const Num = struct {
    v: f64,

    pub fn format(n: Num, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var x = @round(n.v * 1000) / 1000;
        if (x == 0) x = 0; // no "-0"
        var buf: [64]u8 = undefined;
        var str: []const u8 = std.fmt.bufPrint(&buf, "{d:.3}", .{x}) catch unreachable;
        if (std.mem.indexOfScalar(u8, str, '.') != null) {
            str = std.mem.trimEnd(u8, str, "0");
            str = std.mem.trimEnd(u8, str, ".");
        }
        try w.writeAll(str);
    }
};

fn num(v: f64) Num {
    return .{ .v = v };
}

/// UTF-8 to Latin-1 (WinAnsi agrees with it for the printable characters
/// up to 0xFF that matter here); other characters become '?'.
fn toLatin1(str: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var it = std.unicode.Utf8View.init(str) catch {
        // not UTF-8: take the bytes as they are
        const m = @min(str.len, buf.len);
        @memcpy(buf[0..m], str[0..m]);
        return buf[0..m];
    };
    var cps = it.iterator();
    while (cps.nextCodepoint()) |cp| {
        if (n >= buf.len) break;
        buf[n] = if (cp < 256) @intCast(cp) else '?';
        n += 1;
    }
    return buf[0..n];
}

/// Widths of the Helvetica characters 32..126 (1/1000 of the font size).
const HELVETICA = [_]u16{
    278, 278, 355, 556, 556, 889, 667, 222, 333, 333, 389, 584, 278, 333, 278, 278, // space - /
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, // 0 - ?
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, // @ - O
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, // P - _
    222, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, // ` - o
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, // p - ~
};

/// Width of a Latin-1 string in Helvetica, in units of the font size.
fn helveticaWidth(str: []const u8) f64 {
    var w: f64 = 0;
    for (str) |ch| {
        w += @as(f64, @floatFromInt(if (ch >= 32 and ch <= 126) HELVETICA[ch - 32] else 556));
    }
    return w / 1000.0;
}

test "helvetica widths table" {
    try std.testing.expectEqual(@as(usize, 95), HELVETICA.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.556 * 3), helveticaWidth("123"), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.667 + 0.722), helveticaWidth("AD"), 1e-12);
}

test "svg document" {
    const gpa = std.testing.allocator;
    var cv = Canvas.init(gpa, .svg, 100, 50);
    defer cv.deinit();
    try cv.setLineWidth(2);
    try cv.setColor(.{ .red = 1, .green = 0, .blue = 0, .alpha = 0.5 });
    try cv.moveTo(1, 2);
    try cv.lineTo(3, 4);
    try cv.stroke();
    try cv.text("A<B", 50, 25, .center);
    const doc = try cv.finish();
    defer gpa.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "<path d=\"M1 2L3 4\" fill=\"none\" stroke=\"#ff0000\" stroke-opacity=\"0.5000\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, ">A&lt;B</text>") != null);
    try std.testing.expect(std.mem.endsWith(u8, doc, "</svg>\n"));
}

test "svg knockout uses a mask in the user space" {
    const gpa = std.testing.allocator;
    var cv = Canvas.init(gpa, .svg, 100, 50);
    defer cv.deinit();
    try cv.translate(10, 20);
    try cv.beginKnockout();
    try cv.moveTo(0, 0);
    try cv.lineTo(50, 0);
    try cv.stroke();
    try cv.rectangle(5, -5, 10, 10);
    try cv.endKnockout();
    const doc = try cv.finish();
    defer gpa.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "<g mask=\"url(#knockout0)\">\n<path d=\"M0 0L50 0\"") != null);
    // the white rectangle covers the page (shifted by the translation)
    try std.testing.expect(std.mem.indexOf(u8, doc, "<rect x=\"-11\" y=\"-21\" width=\"102\" height=\"52\" fill=\"white\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "fill=\"black\"/>\n</mask>") != null);
}

test "pdf knockout restores the graphics state" {
    const gpa = std.testing.allocator;
    var cv = Canvas.init(gpa, .pdf, 100, 50);
    defer cv.deinit();
    try cv.setColor(.{ .red = 0, .green = 0, .blue = 1, .alpha = 0.5 });
    try cv.beginKnockout();
    try cv.setColor(.{ .red = 1, .green = 0, .blue = 0, .alpha = 1 });
    try cv.setLineWidth(3);
    try cv.rectangle(5, 5, 10, 10);
    try cv.endKnockout();
    try std.testing.expect(std.mem.endsWith(u8, cv.body.items, "Q\n1.0000 0.0000 0.0000 rg 1.0000 0.0000 0.0000 RG\n/GS1 gs\n3.0000 w\n"));
    const doc = try cv.finish();
    defer gpa.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/KO0 8 0 R") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "8 0 obj\n<< /Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 9 0 R >> >>") != null);
}

test "pdf document has a valid xref table" {
    const gpa = std.testing.allocator;
    var cv = Canvas.init(gpa, .pdf, 100, 50);
    defer cv.deinit();
    try cv.setColor(.{ .red = 0, .green = 0, .blue = 1, .alpha = 0.33 });
    try cv.arc(50, 25, 10, 0, std.math.pi);
    try cv.fill();
    try cv.text("(c) ©", 90, 50, .right_bottom);
    const doc = try cv.finish();
    defer gpa.free(doc);
    // every xref entry points to "N 0 obj"
    const xref = std.mem.lastIndexOf(u8, doc, "\nxref\n").? + 1;
    var lines = std.mem.splitScalar(u8, doc[xref..], '\n');
    _ = lines.next();
    _ = lines.next();
    _ = lines.next(); // free entry
    var obj: usize = 1;
    while (lines.next()) |l| : (obj += 1) {
        if (!std.mem.endsWith(u8, l, " n ")) break;
        const off = try std.fmt.parseInt(usize, l[0..10], 10);
        var buf: [16]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, doc[off..], try std.fmt.bufPrint(&buf, "{d} 0 obj", .{obj})));
    }
    try std.testing.expectEqual(@as(usize, 7), obj); // 5 objects + 1 graphics state
    // the content stream: two Bézier segments for the half circle, the ©
    // as octal escape
    const start = std.mem.indexOf(u8, doc, "stream\n").? + 7;
    const end = std.mem.indexOf(u8, doc, "\nendstream").?;
    var in: std.Io.Reader = .fixed(doc[start..end]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    const content = try dec.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(content);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, content, " c\n"));
    try std.testing.expect(std.mem.indexOf(u8, content, "(\\(c\\) \\251) Tj") != null);
}
