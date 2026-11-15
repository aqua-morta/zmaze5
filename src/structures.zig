//! Tile structure tables for all maze types.
//!
//! A periodic structure describes a tile of `rows` x `columns` cells which is
//! repeated to build the maze. Each cell type lists its neighbours: the
//! offset (dx, dy) of the neighbouring cell within the cell grid and the wall
//! separating them (from `coords[i]` to `coords[i+1]`, relative to the cell
//! center). Arc walls carry the angle of the arc.
//!
//! Translated from the original C sources (maze5-0.9.0/src/structure.c).
//! All constants are typed `f64` so that every operation is rounded to double
//! precision exactly like in C; this keeps the geometry bit-identical.

const std = @import("std");
const structure = @import("structure.zig");

const Structure = structure.Structure;
const Neighbour = structure.Neighbour;
const Vec2 = structure.Vec2;

const STRUCTURE_ARCS = structure.ARCS;
const STRUCTURE_TILEABLE = structure.TILEABLE;
const STRUCTURE_RINGS = structure.RINGS;
const STRUCTURE_RANDOMNESS = structure.RANDOMNESS;
const STRUCTURE_CROSSOVERS = structure.CROSSOVERS;

const WALL_ARC = structure.WALL_ARC;
const WALL_BRIDGEABLE = structure.WALL_BRIDGEABLE;

const TYPE_A: u8 = 0;
const TYPE_B: u8 = 1;
const TYPE_C: u8 = 2;
const TYPE_D: u8 = 3;
const TYPE_E: u8 = 4;
const TYPE_F: u8 = 5;
const TYPE_G: u8 = 6;
const TYPE_H: u8 = 7;
const TYPE_CROSSABLE: u8 = 64;
const TYPE_NONE: u8 = 255;

const M_PI: f64 = std.math.pi;
const M_PI_2: f64 = std.math.pi / 2.0;
const _N: f64 = 9E9; // center of a non existing cell
const _60DEG: f64 = M_PI / 3.0;
const _90DEG: f64 = M_PI_2;
const _120DEG: f64 = 2.0 * _60DEG;

/// Neighbour at offset (dx, dy) separated by the wall from `coords[i]` to
/// `coords[i + 1]`, with wall `features` and (for arcs) the arc angle `value`.
fn nb(dx: i32, dy: i32, coords: []const Vec2, i: usize, features: u8, value: f64) Neighbour {
    return .{ .dx = dx, .dy = dy, .p1 = coords[i], .p2 = coords[i + 1], .features = features, .value = value };
}

// ---------------------------------------------------------------------------
// orthogonal structure

const Orthogonal = struct {
    const _A: f64 = 1.0;

    // multiples and fractions of the base lengths
    const _2A: f64 = 2.0 * _A;
    const _A_2: f64 = 0.5 * _A;

    const ortho_a_coords = [_]Vec2{
        .{ .x = _A_2, .y = _A_2 }, // N
        .{ .x = -_A_2, .y = _A_2 }, // W
        .{ .x = -_A_2, .y = -_A_2 }, // S
        .{ .x = _A_2, .y = -_A_2 }, // E
        .{ .x = _A_2, .y = _A_2 },
    };

    pub const ortho_struct = Structure{
        .name = "Orthogonal",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_CROSSOVERS,
        .rows = 1,
        .columns = 1,
        .width = _A,
        .height = _A,
        .xminadd = -_A_2,
        .xmaxadd = _A_2,
        .yminadd = -_A_2,
        .ymaxadd = _A_2,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 },
        },
        .cell_types = &.{
            TYPE_A | TYPE_CROSSABLE,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(0, 1, &ortho_a_coords, 0, WALL_BRIDGEABLE, 0), // N
                nb(-1, 0, &ortho_a_coords, 1, WALL_BRIDGEABLE, 0), // W
                nb(0, -1, &ortho_a_coords, 2, WALL_BRIDGEABLE, 0), // S
                nb(1, 0, &ortho_a_coords, 3, WALL_BRIDGEABLE, 0), // E
            },
        },
    };

    pub const ortho2_struct = Structure{
        .name = "Orthogonal (Arcs)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 2,
        .width = _2A,
        .height = _2A,
        .xminadd = -_A_2,
        .xmaxadd = _A_2,
        .yminadd = -_A_2,
        .ymaxadd = _A_2,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _A, .y = 0.0 },
            .{ .x = 0.0, .y = _A },  .{ .x = _A, .y = _A },
        },
        .cell_types = &.{
            TYPE_A | TYPE_CROSSABLE, TYPE_B | TYPE_CROSSABLE,
            TYPE_B | TYPE_CROSSABLE, TYPE_A | TYPE_CROSSABLE,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(0, 1, &ortho_a_coords, 0, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // N
                nb(-1, 0, &ortho_a_coords, 1, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // W
                nb(0, -1, &ortho_a_coords, 2, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // S
                nb(1, 0, &ortho_a_coords, 3, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // E
            },
            &.{ // TYPE_B
                nb(0, 1, &ortho_a_coords, 0, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // N
                nb(-1, 0, &ortho_a_coords, 1, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // W
                nb(0, -1, &ortho_a_coords, 2, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // S
                nb(1, 0, &ortho_a_coords, 3, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // E
            },
        },
    };
};

// ---------------------------------------------------------------------------
// triangle structure

const Triangle = struct {
    // sqrt(3)/2
    const TRIA_A: f64 = 0.866025403784438596588302061718;
    // 1/2
    const TRIA_B: f64 = 0.5;

    const _A: f64 = 1.0;
    const _B: f64 = TRIA_B / TRIA_A;

    // multiples and fractions of the base lengths
    const _2A: f64 = 2.0 * _A;
    const _A_2: f64 = 0.5 * _A;
    const _2B: f64 = 2.0 * _B;

    const tria_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = 0.0, .y = _A_2 }, // NW
        .{ .x = -_B, .y = -_A_2 }, // S
        .{ .x = _B, .y = -_A_2 }, // NE
        .{ .x = 0.0, .y = _A_2 },
    };

    const tria_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = _B, .y = _A_2 }, // N
        .{ .x = -_B, .y = _A_2 }, // SW
        .{ .x = 0.0, .y = -_A_2 }, // SE
        .{ .x = _B, .y = _A_2 },
    };

    pub const tria_struct = Structure{
        .name = "Triagonal",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 2,
        .columns = 2,
        .width = _2B,
        .height = _2A,
        .xminadd = 0.0,
        .xmaxadd = _B,
        .yminadd = -_A_2,
        .ymaxadd = _A_2,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _B, .y = 0.0 },
            .{ .x = 0.0, .y = _A },  .{ .x = _B, .y = _A },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,
            TYPE_B, TYPE_A,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(-1, 0, &tria_a_coords, 0, 0, 0), // NW
                nb(0, -1, &tria_a_coords, 1, 0, 0), // S
                nb(1, 0, &tria_a_coords, 2, 0, 0), // NE
            },
            &.{ // TYPE_B
                nb(0, 1, &tria_b_coords, 0, 0, 0), // N
                nb(-1, 0, &tria_b_coords, 1, 0, 0), // SW
                nb(1, 0, &tria_b_coords, 2, 0, 0), // SE
            },
        },
    };
};

// ---------------------------------------------------------------------------
// hexagon structure

const Hexagon = struct {
    // sqrt(3)
    const HEXA_A: f64 = 1.73205080756887719317660412344;
    // 3/2
    const HEXA_B: f64 = 1.5;

    const _A: f64 = 1.0;
    const _B: f64 = HEXA_B / HEXA_A;

    // multiples and fractions of the base lengths
    const _A_2: f64 = 0.5 * _A;
    const _2B: f64 = 2.0 * _B;
    const _B_3: f64 = _B / 3.0;
    const _2B_3: f64 = 2.0 * _B / 3.0;

    const hexa_coords = [_]Vec2{ // TYPE_A & TYPE_B
        .{ .x = _B_3, .y = _A_2 }, // N
        .{ .x = -_B_3, .y = _A_2 }, // NW
        .{ .x = -_2B_3, .y = 0.0 }, // SW
        .{ .x = -_B_3, .y = -_A_2 }, // S
        .{ .x = _B_3, .y = -_A_2 }, // SE
        .{ .x = _2B_3, .y = 0.0 }, // NE
        .{ .x = _B_3, .y = _A_2 },
    };

    pub const hexa_struct = Structure{
        .name = "Hexagonal",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_CROSSOVERS,
        .rows = 1,
        .columns = 2,
        .width = _2B,
        .height = _A,
        .xminadd = -_B_3,
        .xmaxadd = _2B_3,
        .yminadd = -_A_2,
        .ymaxadd = 0.0,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _B, .y = _A_2 },
        },
        .cell_types = &.{
            TYPE_A | TYPE_CROSSABLE, TYPE_B | TYPE_CROSSABLE,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(0, 1, &hexa_coords, 0, WALL_BRIDGEABLE, 0), // N
                nb(-1, 0, &hexa_coords, 1, WALL_BRIDGEABLE, 0), // NW
                nb(-1, -1, &hexa_coords, 2, WALL_BRIDGEABLE, 0), // SW
                nb(0, -1, &hexa_coords, 3, WALL_BRIDGEABLE, 0), // S
                nb(1, -1, &hexa_coords, 4, WALL_BRIDGEABLE, 0), // SE
                nb(1, 0, &hexa_coords, 5, WALL_BRIDGEABLE, 0), // NE
            },
            &.{ // TYPE_B
                nb(0, 1, &hexa_coords, 0, WALL_BRIDGEABLE, 0), // N
                nb(-1, 1, &hexa_coords, 1, WALL_BRIDGEABLE, 0), // NW
                nb(-1, 0, &hexa_coords, 2, WALL_BRIDGEABLE, 0), // SW
                nb(0, -1, &hexa_coords, 3, WALL_BRIDGEABLE, 0), // S
                nb(1, 0, &hexa_coords, 4, WALL_BRIDGEABLE, 0), // SE
                nb(1, 1, &hexa_coords, 5, WALL_BRIDGEABLE, 0), // NE
            },
        },
    };

    pub const hexa2_struct = Structure{
        .name = "Hexagonal (Arcs)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS,
        .rows = 1,
        .columns = 2,
        .width = _2B,
        .height = _A,
        .xminadd = -_B_3,
        .xmaxadd = _2B_3,
        .yminadd = -_A_2,
        .ymaxadd = 0.0,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _B, .y = _A_2 },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(0, 1, &hexa_coords, 0, WALL_ARC, _60DEG), // N
                nb(-1, 0, &hexa_coords, 1, WALL_ARC, -_60DEG), // NW
                nb(-1, -1, &hexa_coords, 2, WALL_ARC, _60DEG), // SW
                nb(0, -1, &hexa_coords, 3, WALL_ARC, -_60DEG), // S
                nb(1, -1, &hexa_coords, 4, WALL_ARC, _60DEG), // SE
                nb(1, 0, &hexa_coords, 5, WALL_ARC, -_60DEG), // NE
            },
            &.{ // TYPE_B
                nb(0, 1, &hexa_coords, 0, WALL_ARC, _60DEG), // N
                nb(-1, 1, &hexa_coords, 1, WALL_ARC, -_60DEG), // NW
                nb(-1, 0, &hexa_coords, 2, WALL_ARC, _60DEG), // SW
                nb(0, -1, &hexa_coords, 3, WALL_ARC, -_60DEG), // S
                nb(1, 0, &hexa_coords, 4, WALL_ARC, _60DEG), // SE
                nb(1, 1, &hexa_coords, 5, WALL_ARC, -_60DEG), // NE
            },
        },
    };

    pub const hexa3_struct = Structure{
        .name = "Hexagonal (Arcs,2)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS,
        .rows = 1,
        .columns = 2,
        .width = _2B,
        .height = _A,
        .xminadd = -_B_3,
        .xmaxadd = _2B_3,
        .yminadd = -_A_2,
        .ymaxadd = 0.0,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _B, .y = _A_2 },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(0, 1, &hexa_coords, 0, WALL_ARC, _60DEG), // N
                nb(-1, 0, &hexa_coords, 1, WALL_ARC, _60DEG), // NW
                nb(-1, -1, &hexa_coords, 2, WALL_ARC, -_60DEG), // SW
                nb(0, -1, &hexa_coords, 3, WALL_ARC, -_60DEG), // S
                nb(1, -1, &hexa_coords, 4, WALL_ARC, -_60DEG), // SE
                nb(1, 0, &hexa_coords, 5, WALL_ARC, _60DEG), // NE
            },
            &.{ // TYPE_B
                nb(0, 1, &hexa_coords, 0, WALL_ARC, _60DEG), // N
                nb(-1, 1, &hexa_coords, 1, WALL_ARC, _60DEG), // NW
                nb(-1, 0, &hexa_coords, 2, WALL_ARC, -_60DEG), // SW
                nb(0, -1, &hexa_coords, 3, WALL_ARC, -_60DEG), // S
                nb(1, 0, &hexa_coords, 4, WALL_ARC, -_60DEG), // SE
                nb(1, 1, &hexa_coords, 5, WALL_ARC, _60DEG), // NE
            },
        },
    };
};

// ---------------------------------------------------------------------------
// hexagonal-square structure

const HexagonSquare = struct {
    const _A: f64 = 1.0;

    // multiples and fractions of the base lengths
    const _2A: f64 = 2.0 * _A;
    const _A_2: f64 = 0.5 * _A;

    const hexa_square_a_coords = [_]Vec2{ // TYPE_A  (vertical hexagon)
        .{ .x = 0.0, .y = _A }, // NW
        .{ .x = -_A_2, .y = _A_2 }, // W
        .{ .x = -_A_2, .y = -_A_2 }, // SW
        .{ .x = 0.0, .y = -_A }, // SE
        .{ .x = _A_2, .y = -_A_2 }, // E
        .{ .x = _A_2, .y = _A_2 }, // NE
        .{ .x = 0.0, .y = _A },
    };

    const hexa_square_b_coords = [_]Vec2{ // TYPE_B (square)
        .{ .x = _A_2, .y = _A_2 }, // N
        .{ .x = -_A_2, .y = _A_2 }, // W
        .{ .x = -_A_2, .y = -_A_2 }, // S
        .{ .x = _A_2, .y = -_A_2 }, // E
        .{ .x = _A_2, .y = _A_2 },
    };

    const hexa_square_c_coords = [_]Vec2{ // TYPE_C (horizontal hexagon)
        .{ .x = _A_2, .y = _A_2 }, // N
        .{ .x = -_A_2, .y = _A_2 }, // NW
        .{ .x = -_A, .y = 0.0 }, // SW
        .{ .x = -_A_2, .y = -_A_2 }, // S
        .{ .x = _A_2, .y = -_A_2 }, // SE
        .{ .x = _A, .y = 0.0 }, // NE
        .{ .x = _A_2, .y = _A_2 },
    };

    pub const hexa_square_struct = Structure{
        .name = "Hexagon-Square",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 2,
        .width = _2A,
        .height = _2A,
        .xminadd = 0.0,
        .xmaxadd = _A,
        .yminadd = -_A_2,
        .ymaxadd = _A_2,
        .center_points = &.{
            .{ .x = _N, .y = _N },  .{ .x = _A, .y = 0.0 },
            .{ .x = 0.0, .y = _A }, .{ .x = _A, .y = _A },
        },
        .cell_types = &.{
            TYPE_NONE, TYPE_C,
            TYPE_A,    TYPE_B | TYPE_CROSSABLE,
        },
        .neighbours = &.{
            &.{ // TYPE_A  (vertical hexagon)
                nb(-1, 1, &hexa_square_a_coords, 0, 0, 0), // NW
                nb(-1, 0, &hexa_square_a_coords, 1, WALL_BRIDGEABLE, 0), // W
                nb(-1, -1, &hexa_square_a_coords, 2, 0, 0), // SW
                nb(1, -1, &hexa_square_a_coords, 3, 0, 0), // SE
                nb(1, 0, &hexa_square_a_coords, 4, WALL_BRIDGEABLE, 0), // E
                nb(1, 1, &hexa_square_a_coords, 5, 0, 0), // NE
            },
            &.{ // TYPE_B (square)
                nb(0, 1, &hexa_square_b_coords, 0, WALL_BRIDGEABLE, 0), // N
                nb(-1, 0, &hexa_square_b_coords, 1, WALL_BRIDGEABLE, 0), // W
                nb(0, -1, &hexa_square_b_coords, 2, WALL_BRIDGEABLE, 0), // S
                nb(1, 0, &hexa_square_b_coords, 3, WALL_BRIDGEABLE, 0), // E
            },
            &.{ // TYPE_C (horizontal hexagon)
                nb(0, 1, &hexa_square_c_coords, 0, WALL_BRIDGEABLE, 0), // N
                nb(-1, 1, &hexa_square_c_coords, 1, 0, 0), // NW
                nb(-1, -1, &hexa_square_c_coords, 2, 0, 0), // SW
                nb(0, -1, &hexa_square_c_coords, 3, WALL_BRIDGEABLE, 0), // S
                nb(1, -1, &hexa_square_c_coords, 4, 0, 0), // SE
                nb(1, 1, &hexa_square_c_coords, 5, 0, 0), // NE
            },
        },
    };

    pub const hexa_square2_struct = Structure{
        .name = "Hexagon-Square (Arcs)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 2,
        .width = _2A,
        .height = _2A,
        .xminadd = 0.0,
        .xmaxadd = _A,
        .yminadd = -_A_2,
        .ymaxadd = _A_2,
        .center_points = &.{
            .{ .x = _N, .y = _N },  .{ .x = _A, .y = 0.0 },
            .{ .x = 0.0, .y = _A }, .{ .x = _A, .y = _A },
        },
        .cell_types = &.{
            TYPE_NONE, TYPE_C,
            TYPE_A,    TYPE_B | TYPE_CROSSABLE,
        },
        .neighbours = &.{
            &.{ // TYPE_A  (vertical hexagon)
                nb(-1, 1, &hexa_square_a_coords, 0, 0, 0), // NW
                nb(-1, 0, &hexa_square_a_coords, 1, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // W
                nb(-1, -1, &hexa_square_a_coords, 2, 0, 0), // SW
                nb(1, -1, &hexa_square_a_coords, 3, 0, 0), // SE
                nb(1, 0, &hexa_square_a_coords, 4, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // E
                nb(1, 1, &hexa_square_a_coords, 5, 0, 0), // NE
            },
            &.{ // TYPE_B (square)
                nb(0, 1, &hexa_square_b_coords, 0, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // N
                nb(-1, 0, &hexa_square_b_coords, 1, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // W
                nb(0, -1, &hexa_square_b_coords, 2, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // S
                nb(1, 0, &hexa_square_b_coords, 3, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // E
            },
            &.{ // TYPE_C (horizontal hexagon)
                nb(0, 1, &hexa_square_c_coords, 0, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // N
                nb(-1, 1, &hexa_square_c_coords, 1, 0, 0), // NW
                nb(-1, -1, &hexa_square_c_coords, 2, 0, 0), // SW
                nb(0, -1, &hexa_square_c_coords, 3, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // S
                nb(1, -1, &hexa_square_c_coords, 4, 0, 0), // SE
                nb(1, 1, &hexa_square_c_coords, 5, 0, 0), // NE
            },
        },
    };
};

// ---------------------------------------------------------------------------
// cairo structure

const Cairo = struct {
    // 1/4*(sqrt(7)-1)
    const CAIRO_A: f64 = 0.411437827766147679042774143454;
    // 1/4*(sqrt(7)+1)
    const CAIRO_B: f64 = 0.911437827766147679042774143454;

    const _ALPHA: f64 = 0.84806207898148100455;

    const _A: f64 = CAIRO_A / (CAIRO_A + CAIRO_B);
    const _B: f64 = CAIRO_B / (CAIRO_A + CAIRO_B);

    // multiples and fractions of the base lengths
    const _2B: f64 = 2.0 * _B;
    const _3B: f64 = 3.0 * _B;
    const _4B: f64 = 4.0 * _B;

    const cairo_a_coords = [_]Vec2{ // TYPE_A  & TYPE E
        .{ .x = 0.0, .y = _B }, // NW
        .{ .x = -_A, .y = 0.0 }, // SW
        .{ .x = 0.0, .y = -_B }, // SE
        .{ .x = _B, .y = _A - _B }, // E
        .{ .x = _B, .y = _B - _A }, // NE
        .{ .x = 0.0, .y = _B },
    };

    const cairo_b_coords = [_]Vec2{ // TYPE_B & TYPE F
        .{ .x = 0.0, .y = _B }, // NW
        .{ .x = -_B, .y = _B - _A }, // W
        .{ .x = -_B, .y = _A - _B }, // SW
        .{ .x = 0.0, .y = -_B }, // SE
        .{ .x = _A, .y = 0.0 }, // NE
        .{ .x = 0.0, .y = _B },
    };

    const cairo_c_coords = [_]Vec2{ // TYPE_C & TYPE G
        .{ .x = _B - _A, .y = _B }, // N
        .{ .x = _A - _B, .y = _B }, // NW
        .{ .x = -_B, .y = 0.0 }, // SW
        .{ .x = 0.0, .y = -_A }, // SE
        .{ .x = _B, .y = 0.0 }, // NE
        .{ .x = _B - _A, .y = _B },
    };

    const cairo_d_coords = [_]Vec2{ // TYPE_D & TYPE H
        .{ .x = 0.0, .y = _A }, // NW
        .{ .x = -_B, .y = 0.0 }, // SW
        .{ .x = _A - _B, .y = -_B }, // S
        .{ .x = _B - _A, .y = -_B }, // SE
        .{ .x = _B, .y = 0.0 }, // NE
        .{ .x = 0.0, .y = _A },
    };

    pub const cairo_struct = Structure{
        .name = "Cairo",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 3,
        .columns = 3,
        .width = _4B,
        .height = _4B,
        .xminadd = 0.0,
        .xmaxadd = 0.0,
        .yminadd = 0.0,
        .ymaxadd = 0.0,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _2B, .y = 0.0 }, .{ .x = _3B, .y = -_B },
            .{ .x = _B, .y = _B },   .{ .x = _N, .y = _N },   .{ .x = _3B, .y = _B },
            .{ .x = _B, .y = _3B },  .{ .x = _2B, .y = _2B }, .{ .x = _4B, .y = _2B },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,    TYPE_C,
            TYPE_G, TYPE_NONE, TYPE_D,
            TYPE_H, TYPE_E,    TYPE_F,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(-1, 1, &cairo_a_coords, 0, 0, 0), // NW
                nb(-1, 0, &cairo_a_coords, 1, 0, 0), // SW
                nb(0, -1, &cairo_a_coords, 2, 0, 0), // SE
                nb(1, 0, &cairo_a_coords, 3, 0, 0), // E
                nb(0, 1, &cairo_a_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_B
                nb(-1, 1, &cairo_b_coords, 0, 0, 0), // NW
                nb(-1, 0, &cairo_b_coords, 1, 0, 0), // W
                nb(-1, -1, &cairo_b_coords, 2, 0, 0), // SW
                nb(1, 0, &cairo_b_coords, 3, 0, 0), // SE
                nb(1, 1, &cairo_b_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_C
                nb(0, 1, &cairo_c_coords, 0, 0, 0), // N
                nb(-1, 0, &cairo_c_coords, 1, 0, 0), // NW
                nb(-1, -1, &cairo_c_coords, 2, 0, 0), // SW
                nb(0, -1, &cairo_c_coords, 3, 0, 0), // SE
                nb(1, 0, &cairo_c_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_D
                nb(-1, 1, &cairo_d_coords, 0, 0, 0), // NW
                nb(-1, -1, &cairo_d_coords, 1, 0, 0), // SW
                nb(0, -1, &cairo_d_coords, 2, 0, 0), // S
                nb(1, -1, &cairo_d_coords, 3, 0, 0), // SE
                nb(0, 1, &cairo_d_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_E
                nb(-1, 0, &cairo_a_coords, 0, 0, 0), // NW
                nb(-1, -1, &cairo_a_coords, 1, 0, 0), // SW
                nb(1, -1, &cairo_a_coords, 2, 0, 0), // SE
                nb(1, 0, &cairo_a_coords, 3, 0, 0), // E
                nb(1, 1, &cairo_a_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_F
                nb(0, 1, &cairo_b_coords, 0, 0, 0), // NW
                nb(-1, 0, &cairo_b_coords, 1, 0, 0), // W
                nb(0, -1, &cairo_b_coords, 2, 0, 0), // SW
                nb(1, -1, &cairo_b_coords, 3, 0, 0), // SE
                nb(1, 0, &cairo_b_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_G
                nb(0, 1, &cairo_c_coords, 0, 0, 0), // N
                nb(-1, 1, &cairo_c_coords, 1, 0, 0), // NW
                nb(0, -1, &cairo_c_coords, 2, 0, 0), // SW
                nb(1, -1, &cairo_c_coords, 3, 0, 0), // SE
                nb(1, 1, &cairo_c_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_H
                nb(0, 1, &cairo_d_coords, 0, 0, 0), // NW
                nb(-1, 0, &cairo_d_coords, 1, 0, 0), // SW
                nb(0, -1, &cairo_d_coords, 2, 0, 0), // S
                nb(1, 0, &cairo_d_coords, 3, 0, 0), // SE
                nb(1, 1, &cairo_d_coords, 4, 0, 0), // NE
            },
        },
    };

    pub const cairo2_struct = Structure{
        .name = "Cairo (Arcs)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS,
        .rows = 3,
        .columns = 3,
        .width = _4B,
        .height = _4B,
        .xminadd = 0.0,
        .xmaxadd = 0.0,
        .yminadd = 0.0,
        .ymaxadd = 0.0,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _2B, .y = 0.0 }, .{ .x = _3B, .y = -_B },
            .{ .x = _B, .y = _B },   .{ .x = _N, .y = _N },   .{ .x = _3B, .y = _B },
            .{ .x = _B, .y = _3B },  .{ .x = _2B, .y = _2B }, .{ .x = _4B, .y = _2B },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,    TYPE_C,
            TYPE_G, TYPE_NONE, TYPE_D,
            TYPE_H, TYPE_E,    TYPE_F,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(-1, 1, &cairo_a_coords, 0, WALL_ARC, _ALPHA), // NW
                nb(-1, 0, &cairo_a_coords, 1, WALL_ARC, _ALPHA), // SW
                nb(0, -1, &cairo_a_coords, 2, WALL_ARC, -_ALPHA), // SE
                nb(1, 0, &cairo_a_coords, 3, WALL_ARC, -_ALPHA), // E
                nb(0, 1, &cairo_a_coords, 4, WALL_ARC, -_ALPHA), // NE
            },
            &.{ // TYPE_B
                nb(-1, 1, &cairo_b_coords, 0, WALL_ARC, -_ALPHA), // NW
                nb(-1, 0, &cairo_b_coords, 1, WALL_ARC, _ALPHA), // W
                nb(-1, -1, &cairo_b_coords, 2, WALL_ARC, -_ALPHA), // SW
                nb(1, 0, &cairo_b_coords, 3, WALL_ARC, _ALPHA), // SE
                nb(1, 1, &cairo_b_coords, 4, WALL_ARC, _ALPHA), // NE
            },
            &.{ // TYPE_C
                nb(0, 1, &cairo_c_coords, 0, WALL_ARC, -_ALPHA), // N
                nb(-1, 0, &cairo_c_coords, 1, WALL_ARC, -_ALPHA), // NW
                nb(-1, -1, &cairo_c_coords, 2, WALL_ARC, _ALPHA), // SW
                nb(0, -1, &cairo_c_coords, 3, WALL_ARC, _ALPHA), // SE
                nb(1, 0, &cairo_c_coords, 4, WALL_ARC, -_ALPHA), // NE
            },
            &.{ // TYPE_D
                nb(-1, 1, &cairo_d_coords, 0, WALL_ARC, _ALPHA), // NW
                nb(-1, -1, &cairo_d_coords, 1, WALL_ARC, -_ALPHA), // SW
                nb(0, -1, &cairo_d_coords, 2, WALL_ARC, _ALPHA), // S
                nb(1, -1, &cairo_d_coords, 3, WALL_ARC, -_ALPHA), // SE
                nb(0, 1, &cairo_d_coords, 4, WALL_ARC, _ALPHA), // NE
            },
            &.{ // TYPE_E
                nb(-1, 0, &cairo_a_coords, 0, WALL_ARC, _ALPHA), // NW
                nb(-1, -1, &cairo_a_coords, 1, WALL_ARC, _ALPHA), // SW
                nb(1, -1, &cairo_a_coords, 2, WALL_ARC, -_ALPHA), // SE
                nb(1, 0, &cairo_a_coords, 3, WALL_ARC, _ALPHA), // E
                nb(1, 1, &cairo_a_coords, 4, WALL_ARC, -_ALPHA), // NE
            },
            &.{ // TYPE_F
                nb(0, 1, &cairo_b_coords, 0, WALL_ARC, -_ALPHA), // NW
                nb(-1, 0, &cairo_b_coords, 1, WALL_ARC, -_ALPHA), // W
                nb(0, -1, &cairo_b_coords, 2, WALL_ARC, -_ALPHA), // SW
                nb(1, -1, &cairo_b_coords, 3, WALL_ARC, _ALPHA), // SE
                nb(1, 0, &cairo_b_coords, 4, WALL_ARC, _ALPHA), // NE
            },
            &.{ // TYPE_G
                nb(0, 1, &cairo_c_coords, 0, WALL_ARC, _ALPHA), // N
                nb(-1, 1, &cairo_c_coords, 1, WALL_ARC, -_ALPHA), // NW
                nb(0, -1, &cairo_c_coords, 2, WALL_ARC, _ALPHA), // SW
                nb(1, -1, &cairo_c_coords, 3, WALL_ARC, _ALPHA), // SE
                nb(1, 1, &cairo_c_coords, 4, WALL_ARC, -_ALPHA), // NE
            },
            &.{ // TYPE_H
                nb(0, 1, &cairo_d_coords, 0, WALL_ARC, _ALPHA), // NW
                nb(-1, 0, &cairo_d_coords, 1, WALL_ARC, -_ALPHA), // SW
                nb(0, -1, &cairo_d_coords, 2, WALL_ARC, -_ALPHA), // S
                nb(1, 0, &cairo_d_coords, 3, WALL_ARC, -_ALPHA), // SE
                nb(1, 1, &cairo_d_coords, 4, WALL_ARC, _ALPHA), // NE
            },
        },
    };
};

// ---------------------------------------------------------------------------
// octagonal-square structure

const OctagonSquare = struct {
    // 1/2
    const OS_A: f64 = 0.5;

    // sqrt(1/2)+1/2
    const OS_B: f64 = 1.20710678118654746171500846685;

    const _A: f64 = OS_A / (OS_A + OS_B);
    const _B: f64 = OS_B / (OS_A + OS_B);

    // multiples and fractions of the base lengths
    const _AB: f64 = _A + _B;

    const octa_square_a_coords = [_]Vec2{ // TYPE_A (square)
        .{ .x = _A, .y = _A }, // N
        .{ .x = -_A, .y = _A }, // W
        .{ .x = -_A, .y = -_A }, // S
        .{ .x = _A, .y = -_A }, // E
        .{ .x = _A, .y = _A },
    };

    const octa_square_b_coords = [_]Vec2{ // TYPE_B (octagon)
        .{ .x = _A, .y = _B }, // N
        .{ .x = -_A, .y = _B }, // NW
        .{ .x = -_B, .y = _A }, // W
        .{ .x = -_B, .y = -_A }, // SW
        .{ .x = -_A, .y = -_B }, // S
        .{ .x = _A, .y = -_B }, // SE
        .{ .x = _B, .y = -_A }, // E
        .{ .x = _B, .y = _A }, // NE
        .{ .x = _A, .y = _B },
    };

    pub const octa_square_struct = Structure{
        .name = "Octagon-Square",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 2,
        .width = 2.0 * _AB,
        .height = 2.0 * _AB,
        .xminadd = -_A,
        .xmaxadd = _B,
        .yminadd = -_A,
        .ymaxadd = _B,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _AB, .y = 0.0 },
            .{ .x = 0.0, .y = _AB }, .{ .x = _AB, .y = _AB },
        },
        .cell_types = &.{
            TYPE_A | TYPE_CROSSABLE, TYPE_B,
            TYPE_B,                  TYPE_A | TYPE_CROSSABLE,
        },
        .neighbours = &.{
            &.{ // TYPE_A (square)
                nb(0, 1, &octa_square_a_coords, 0, WALL_BRIDGEABLE, 0), // N
                nb(-1, 0, &octa_square_a_coords, 1, WALL_BRIDGEABLE, 0), // W
                nb(0, -1, &octa_square_a_coords, 2, WALL_BRIDGEABLE, 0), // S
                nb(1, 0, &octa_square_a_coords, 3, WALL_BRIDGEABLE, 0), // E
            },
            &.{ // TYPE_B (octagon)
                nb(0, 1, &octa_square_b_coords, 0, WALL_BRIDGEABLE, 0), // N
                nb(-1, 1, &octa_square_b_coords, 1, 0, 0), // NW
                nb(-1, 0, &octa_square_b_coords, 2, WALL_BRIDGEABLE, 0), // W
                nb(-1, -1, &octa_square_b_coords, 3, 0, 0), // SW
                nb(0, -1, &octa_square_b_coords, 4, WALL_BRIDGEABLE, 0), // S
                nb(1, -1, &octa_square_b_coords, 5, 0, 0), // SE
                nb(1, 0, &octa_square_b_coords, 6, WALL_BRIDGEABLE, 0), // E
                nb(1, 1, &octa_square_b_coords, 7, 0, 0), // NE
            },
        },
    };

    pub const octa_square3_struct = Structure{
        .name = "Octagon-Square (Arcs)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 2,
        .width = 2.0 * _AB,
        .height = 2.0 * _AB,
        .xminadd = -_A,
        .xmaxadd = _B,
        .yminadd = -_A,
        .ymaxadd = _B,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _AB, .y = 0.0 },
            .{ .x = 0.0, .y = _AB }, .{ .x = _AB, .y = _AB },
        },
        .cell_types = &.{
            TYPE_A | TYPE_CROSSABLE, TYPE_B,
            TYPE_B,                  TYPE_A | TYPE_CROSSABLE,
        },
        .neighbours = &.{
            &.{ // TYPE_A (square)
                nb(0, 1, &octa_square_a_coords, 0, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // N
                nb(-1, 0, &octa_square_a_coords, 1, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // W
                nb(0, -1, &octa_square_a_coords, 2, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // S
                nb(1, 0, &octa_square_a_coords, 3, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // E
            },
            &.{ // TYPE_B (octagon)
                nb(0, 1, &octa_square_b_coords, 0, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // N
                nb(-1, 1, &octa_square_b_coords, 1, 0, 0), // NW
                nb(-1, 0, &octa_square_b_coords, 2, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // W
                nb(-1, -1, &octa_square_b_coords, 3, 0, 0), // SW
                nb(0, -1, &octa_square_b_coords, 4, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // S
                nb(1, -1, &octa_square_b_coords, 5, 0, 0), // SE
                nb(1, 0, &octa_square_b_coords, 6, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // E
                nb(1, 1, &octa_square_b_coords, 7, 0, 0), // NE
            },
        },
    };
};

// ---------------------------------------------------------------------------
// octagonal-square structure variant 2

const OctagonSquare2 = struct {
    // sqrt(1/2)
    const OS_A: f64 = 0.70710678118654746171500846685;

    // sqrt(1/2)+1/2
    const OS_B: f64 = 1.20710678118654746171500846685;

    const _A: f64 = OS_A / (OS_A + OS_B);
    const _B: f64 = OS_B / (OS_A + OS_B);

    // multiples and fractions of the base lengths
    const _2B: f64 = 2.0 * _B;

    const octa_square2_a_coords = [_]Vec2{ // TYPE_A (square)
        .{ .x = 0.0, .y = _A }, // NW
        .{ .x = -_A, .y = 0.0 }, // SW
        .{ .x = 0.0, .y = -_A }, // SE
        .{ .x = _A, .y = 0.0 }, // NE
        .{ .x = 0.0, .y = _A },
    };

    const octa_square2_b_coords = [_]Vec2{ // TYPE_B (octagon)
        .{ .x = _B - _A, .y = _B }, // N
        .{ .x = _A - _B, .y = _B }, // NW
        .{ .x = -_B, .y = _B - _A }, // W
        .{ .x = -_B, .y = _A - _B }, // SW
        .{ .x = _A - _B, .y = -_B }, // S
        .{ .x = _B - _A, .y = -_B }, // SE
        .{ .x = _B, .y = _A - _B }, // E
        .{ .x = _B, .y = _B - _A }, // NE
        .{ .x = _B - _A, .y = _B },
    };

    pub const octa_square2_struct = Structure{
        .name = "Octagon-Square (2)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 2,
        .width = _2B,
        .height = _2B,
        .xminadd = -_B,
        .xmaxadd = 0,
        .yminadd = -_B,
        .ymaxadd = 0,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _N, .y = _N },
            .{ .x = _N, .y = _N },   .{ .x = _B, .y = _B },
        },
        .cell_types = &.{
            TYPE_B,    TYPE_NONE,
            TYPE_NONE, TYPE_A | TYPE_CROSSABLE,
        },
        .neighbours = &.{
            &.{ // TYPE_A (square)
                nb(-1, 1, &octa_square2_a_coords, 0, WALL_BRIDGEABLE, 0), // NW
                nb(-1, -1, &octa_square2_a_coords, 1, WALL_BRIDGEABLE, 0), // SW
                nb(1, -1, &octa_square2_a_coords, 2, WALL_BRIDGEABLE, 0), // SE
                nb(1, 1, &octa_square2_a_coords, 3, WALL_BRIDGEABLE, 0), // NE
            },
            &.{ // TYPE_B (octagon)
                nb(0, 2, &octa_square2_b_coords, 0, 0, 0), // N
                nb(-1, 1, &octa_square2_b_coords, 1, WALL_BRIDGEABLE, 0), // NW
                nb(-2, 0, &octa_square2_b_coords, 2, 0, 0), // W
                nb(-1, -1, &octa_square2_b_coords, 3, WALL_BRIDGEABLE, 0), // SW
                nb(0, -2, &octa_square2_b_coords, 4, 0, 0), // S
                nb(1, -1, &octa_square2_b_coords, 5, WALL_BRIDGEABLE, 0), // SE
                nb(2, 0, &octa_square2_b_coords, 6, 0, 0), // E
                nb(1, 1, &octa_square2_b_coords, 7, WALL_BRIDGEABLE, 0), // NE
            },
        },
    };

    pub const octa_square4_struct = Structure{
        .name = "Octagon-Square (2, Arcs)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 2,
        .width = _2B,
        .height = _2B,
        .xminadd = -_B,
        .xmaxadd = 0,
        .yminadd = -_B,
        .ymaxadd = 0,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _N, .y = _N },
            .{ .x = _N, .y = _N },   .{ .x = _B, .y = _B },
        },
        .cell_types = &.{
            TYPE_B,    TYPE_NONE,
            TYPE_NONE, TYPE_A | TYPE_CROSSABLE,
        },
        .neighbours = &.{
            &.{ // TYPE_A (square)
                nb(-1, 1, &octa_square2_a_coords, 0, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // NW
                nb(-1, -1, &octa_square2_a_coords, 1, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // SW
                nb(1, -1, &octa_square2_a_coords, 2, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // SE
                nb(1, 1, &octa_square2_a_coords, 3, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // NE
            },
            &.{ // TYPE_B (octagon)
                nb(0, 2, &octa_square2_b_coords, 0, 0, 0), // N
                nb(-1, 1, &octa_square2_b_coords, 1, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // NW
                nb(-2, 0, &octa_square2_b_coords, 2, 0, 0), // W
                nb(-1, -1, &octa_square2_b_coords, 3, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // SW
                nb(0, -2, &octa_square2_b_coords, 4, 0, 0), // S
                nb(1, -1, &octa_square2_b_coords, 5, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // SE
                nb(2, 0, &octa_square2_b_coords, 6, 0, 0), // E
                nb(1, 1, &octa_square2_b_coords, 7, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // NE
            },
        },
    };
};

// ---------------------------------------------------------------------------
// rhombic structure

const Rhombic = struct {
    const _A: f64 = 1.0;

    // multiples and fractions of the base lengths
    const _2A: f64 = 2.0 * _A;

    const rhombic_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = 0.0, .y = _A }, // NW
        .{ .x = -_A, .y = 0.0 }, // SW
        .{ .x = 0.0, .y = -_A }, // SE
        .{ .x = _A, .y = 0.0 }, // NE
        .{ .x = 0.0, .y = _A },
    };

    pub const rhombic_struct = Structure{
        .name = "Rhombic",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 2,
        .width = _2A,
        .height = _2A,
        .xminadd = 0.0,
        .xmaxadd = _A,
        .yminadd = 0.0,
        .ymaxadd = _A,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _N, .y = _N },
            .{ .x = _N, .y = _N },   .{ .x = _A, .y = _A },
        },
        .cell_types = &.{
            TYPE_A | TYPE_CROSSABLE, TYPE_NONE,
            TYPE_NONE,               TYPE_A | TYPE_CROSSABLE,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(-1, 1, &rhombic_a_coords, 0, WALL_BRIDGEABLE, 0), // NW
                nb(-1, -1, &rhombic_a_coords, 1, WALL_BRIDGEABLE, 0), // SW
                nb(1, -1, &rhombic_a_coords, 2, WALL_BRIDGEABLE, 0), // SE
                nb(1, 1, &rhombic_a_coords, 3, WALL_BRIDGEABLE, 0), // NE
            },
        },
    };

    pub const rhombic2_struct = Structure{
        .name = "Rhombic (Arcs)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 2,
        .width = _2A,
        .height = _2A,
        .xminadd = 0.0,
        .xmaxadd = _A,
        .yminadd = 0.0,
        .ymaxadd = _A,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _N, .y = _N },
            .{ .x = _N, .y = _N },   .{ .x = _A, .y = _A },
        },
        .cell_types = &.{
            TYPE_A | TYPE_CROSSABLE, TYPE_NONE,
            TYPE_NONE,               TYPE_B | TYPE_CROSSABLE,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(-1, 1, &rhombic_a_coords, 0, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // NW
                nb(-1, -1, &rhombic_a_coords, 1, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // SW
                nb(1, -1, &rhombic_a_coords, 2, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // SE
                nb(1, 1, &rhombic_a_coords, 3, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // NE
            },
            &.{ // TYPE B
                nb(-1, 1, &rhombic_a_coords, 0, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // NW
                nb(-1, -1, &rhombic_a_coords, 1, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // SW
                nb(1, -1, &rhombic_a_coords, 2, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // SE
                nb(1, 1, &rhombic_a_coords, 3, WALL_ARC | WALL_BRIDGEABLE, -_90DEG), // NE
            },
        },
    };

    pub const rhombic3_struct = Structure{
        .name = "Rhombic (Arcs,2)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 2,
        .width = _2A,
        .height = _2A,
        .xminadd = 0.0,
        .xmaxadd = _A,
        .yminadd = 0.0,
        .ymaxadd = _A,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _N, .y = _N },
            .{ .x = _N, .y = _N },   .{ .x = _A, .y = _A },
        },
        .cell_types = &.{
            TYPE_A | TYPE_CROSSABLE, TYPE_NONE,
            TYPE_NONE,               TYPE_A | TYPE_CROSSABLE,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(-1, 1, &rhombic_a_coords, 0, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // NW
                nb(-1, -1, &rhombic_a_coords, 1, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // SW
                nb(1, -1, &rhombic_a_coords, 2, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // SE
                nb(1, 1, &rhombic_a_coords, 3, WALL_ARC | WALL_BRIDGEABLE, _90DEG), // NE
            },
        },
    };
};

// ---------------------------------------------------------------------------
// hexagonal-rhombic structure

const HexagonRhombic = struct {
    // 3/4
    const HR_A: f64 = 0.75;
    // 1/4*sqrt(3)
    const HR_B: f64 = 0.4330127018922192982941510308592114597559;

    const _A: f64 = 1.0;
    const _B: f64 = HR_B / HR_A;
    const _C: f64 = 0.5 / HR_A;

    // multiples and fractions of the base lengths
    const _2A: f64 = 2.0 * _A;
    const _3A: f64 = 3.0 * _A;
    const _4A: f64 = 4.0 * _A;
    const _2B: f64 = 2.0 * _B;
    const _3B: f64 = 3.0 * _B;
    const _4B: f64 = 4.0 * _B;

    const hexa_rhombic_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = _B, .y = _A }, // N
        .{ .x = -_B, .y = _A - _C }, // W
        .{ .x = -_B, .y = -_A }, // S
        .{ .x = _B, .y = -_A + _C }, // E
        .{ .x = _B, .y = _A },
    };

    const hexa_rhombic_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = _B, .y = _A - _C }, // N
        .{ .x = -_B, .y = _A }, // W
        .{ .x = -_B, .y = -_A + _C }, // S
        .{ .x = _B, .y = -_A }, // E
        .{ .x = _B, .y = _A - _C },
    };

    const hexa_rhombic_c_coords = [_]Vec2{ // TYPE_C
        .{ .x = 0.0, .y = _C }, // NW
        .{ .x = -_2B, .y = 0 }, // SW
        .{ .x = 0.0, .y = -_C }, // SE
        .{ .x = _2B, .y = 0.0 }, // NE
        .{ .x = 0.0, .y = _C },
    };

    pub const hexa_rhombic_struct = Structure{
        .name = "Hexagonal-Rhombic",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_CROSSOVERS,
        .rows = 4,
        .columns = 2,
        .width = _4B,
        .height = _4A,
        .xminadd = _B,
        .xmaxadd = _2B,
        .yminadd = -_A,
        .ymaxadd = 0.0,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _2B, .y = 0.0 },
            .{ .x = _N, .y = _N },   .{ .x = _3B, .y = _A },
            .{ .x = 0.0, .y = _2A }, .{ .x = _2B, .y = _2A },
            .{ .x = _B, .y = _3A },  .{ .x = _N, .y = _N },
        },
        .cell_types = &.{
            TYPE_A | TYPE_CROSSABLE, TYPE_B | TYPE_CROSSABLE,
            TYPE_NONE,               TYPE_C | TYPE_CROSSABLE,
            TYPE_B | TYPE_CROSSABLE, TYPE_A | TYPE_CROSSABLE,
            TYPE_C | TYPE_CROSSABLE, TYPE_NONE,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(-1, 1, &hexa_rhombic_a_coords, 0, WALL_BRIDGEABLE, 0), // N
                nb(-1, 0, &hexa_rhombic_a_coords, 1, WALL_BRIDGEABLE, 0), // W
                nb(0, -1, &hexa_rhombic_a_coords, 2, WALL_BRIDGEABLE, 0), // S
                nb(1, 0, &hexa_rhombic_a_coords, 3, WALL_BRIDGEABLE, 0), // E
            },
            &.{ // TYPE_B
                nb(0, 1, &hexa_rhombic_b_coords, 0, WALL_BRIDGEABLE, 0), // N
                nb(-1, 0, &hexa_rhombic_b_coords, 1, WALL_BRIDGEABLE, 0), // W
                nb(-1, -1, &hexa_rhombic_b_coords, 2, WALL_BRIDGEABLE, 0), // S
                nb(1, 0, &hexa_rhombic_b_coords, 3, WALL_BRIDGEABLE, 0), // E
            },
            &.{ // TYPE_C
                nb(0, 1, &hexa_rhombic_c_coords, 0, WALL_BRIDGEABLE, 0), // NW
                nb(0, -1, &hexa_rhombic_c_coords, 1, WALL_BRIDGEABLE, 0), // SW
                nb(1, -1, &hexa_rhombic_c_coords, 2, WALL_BRIDGEABLE, 0), // SE
                nb(1, 1, &hexa_rhombic_c_coords, 3, WALL_BRIDGEABLE, 0), // NE
            },
        },
    };
};

// ---------------------------------------------------------------------------
// triangle-square structure

const TriangleSquare = struct {
    // cos(15 Deg)
    const _A: f64 = 0.9659258262890683122137147620378527790308;
    // sin(15 Deg)
    const _B: f64 = 0.2588190451025207394764038326684385538101;

    // sqrt(3)/2
    const _TH: f64 = 0.8660254037844385965883020617184229195118;
    // 1/3*sqrt(3)
    const _TC: f64 = 0.5773502691896257310588680411456152796745;
    // 1/2*sqrt(2)
    const _SC: f64 = 0.7071067811865475727373109293694142252207;

    // multiples and fractions of the base lengths
    const _2A: f64 = 2.0 * _A;

    const triangle_square_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = _A - _B - _TC * _B, .y = _A - _B - _TC * _A }, // NW
        .{ .x = -_B - _TC * _B, .y = _A - _TC * _A }, // SW
        .{ .x = -_TC * _B, .y = -_TC * _A }, // SE
        .{ .x = _A - _B - _TC * _B, .y = _A - _B - _TC * _A },
    };

    const triangle_square_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = _A - _B - _TC * _A, .y = _A - _B - _TC * _B }, // NW
        .{ .x = -_TC * _A, .y = -_TC * _B }, // SE
        .{ .x = _A - _TC * _A, .y = -_B - _TC * _B }, // SW
        .{ .x = _A - _B - _TC * _A, .y = _A - _B - _TC * _B },
    };

    const triangle_square_c_coords = [_]Vec2{ // TYPE_C
        .{ .x = _2A - _B - (_TH + 0.5) * _A, .y = _A - (_TH + 0.5) * _B }, // NW
        .{ .x = _A - _B - (_TH + 0.5) * _A, .y = _A - _B - (_TH + 0.5) * _B }, // NW
        .{ .x = _A - (_TH + 0.5) * _A, .y = -_B - (_TH + 0.5) * _B }, // SE
        .{ .x = _2A - (_TH + 0.5) * _A, .y = -(_TH + 0.5) * _B }, // SW
        .{ .x = _2A - _B - (_TH + 0.5) * _A, .y = _A - (_TH + 0.5) * _B },
    };

    const triangle_square_d_coords = [_]Vec2{ // TYPE_D
        .{ .x = _A - (_TH + 0.5) * _B, .y = _2A - _B - (_TH + 0.5) * _A }, // NW
        .{ .x = -(_TH + 0.5) * _B, .y = _2A - (_TH + 0.5) * _A }, // NW
        .{ .x = -_B - (_TH + 0.5) * _B, .y = _A - (_TH + 0.5) * _A }, // SE
        .{ .x = _A - _B - (_TH + 0.5) * _B, .y = _A - _B - (_TH + 0.5) * _A }, // NW
        .{ .x = _A - (_TH + 0.5) * _B, .y = _2A - _B - (_TH + 0.5) * _A },
    };

    const triangle_square_e_coords = [_]Vec2{ // TYPE_E
        .{ .x = _A - (_TC + 1.0) * _SC, .y = _2A - _B - (_TC + 1.0) * _SC }, // NW
        .{ .x = _A - _B - (_TC + 1.0) * _SC, .y = _A - _B - (_TC + 1.0) * _SC }, // NW
        .{ .x = _2A - _B - (_TC + 1.0) * _SC, .y = _A - (_TC + 1.0) * _SC }, // SW
        .{ .x = _A - (_TC + 1.0) * _SC, .y = _2A - _B - (_TC + 1.0) * _SC },
    };

    const triangle_square_f_coords = [_]Vec2{ // TYPE_F
        .{ .x = _2A - (2.0 * _TC + 1.0) * _SC, .y = _2A - (2.0 * _TC + 1.0) * _SC }, // NW
        .{ .x = _A - (2.0 * _TC + 1.0) * _SC, .y = _2A - _B - (2.0 * _TC + 1.0) * _SC }, // NW
        .{ .x = _2A - _B - (2.0 * _TC + 1.0) * _SC, .y = _A - (2.0 * _TC + 1.0) * _SC }, // SW
        .{ .x = _2A - (2.0 * _TC + 1.0) * _SC, .y = _2A - (2.0 * _TC + 1.0) * _SC },
    };

    pub const triangle_square_struct = Structure{
        .name = "Triangle-Square",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 3,
        .width = _2A,
        .height = _2A,
        .xminadd = -_B * _TC,
        .xmaxadd = _B + _TC * _B,
        .yminadd = -_B * _TC,
        .ymaxadd = _B + _TC * _B,
        .center_points = &.{
            .{ .x = _TC * _B, .y = _TC * _A },                 .{ .x = _TC * _A, .y = _TC * _B },                   .{ .x = (_TH + 0.5) * _A, .y = (_TH + 0.5) * _B },
            .{ .x = (_TH + 0.5) * _B, .y = (_TH + 0.5) * _A }, .{ .x = (_TC + 1.0) * _SC, .y = (_TC + 1.0) * _SC }, .{ .x = (2.0 * _TC + 1.0) * _SC, .y = (2.0 * _TC + 1.0) * _SC },
        },
        .cell_types = &.{
            TYPE_A,                  TYPE_B, TYPE_C | TYPE_CROSSABLE,
            TYPE_D | TYPE_CROSSABLE, TYPE_E, TYPE_F,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(0, 1, &triangle_square_a_coords, 0, WALL_BRIDGEABLE, 0), // NW
                nb(-1, 0, &triangle_square_a_coords, 1, WALL_BRIDGEABLE, 0), // SW
                nb(1, 0, &triangle_square_a_coords, 2, 0, 0), // SE
            },
            &.{ // TYPE_B
                nb(-1, 0, &triangle_square_b_coords, 0, 0, 0), // NW
                nb(-1, -1, &triangle_square_b_coords, 1, WALL_BRIDGEABLE, 0), // SE
                nb(1, 0, &triangle_square_b_coords, 2, WALL_BRIDGEABLE, 0), // SW
            },
            &.{ // TYPE_C
                nb(-1, 1, &triangle_square_c_coords, 0, WALL_BRIDGEABLE, 0), // NW
                nb(-1, 0, &triangle_square_c_coords, 1, WALL_BRIDGEABLE, 0), // NW
                nb(0, -1, &triangle_square_c_coords, 2, WALL_BRIDGEABLE, 0), // SE
                nb(1, 0, &triangle_square_c_coords, 3, WALL_BRIDGEABLE, 0), // SW
            },
            &.{ // TYPE_D
                nb(1, 1, &triangle_square_d_coords, 0, WALL_BRIDGEABLE, 0), // NW
                nb(-1, 0, &triangle_square_d_coords, 1, WALL_BRIDGEABLE, 0), // NW
                nb(0, -1, &triangle_square_d_coords, 2, WALL_BRIDGEABLE, 0), // SE
                nb(1, 0, &triangle_square_d_coords, 3, WALL_BRIDGEABLE, 0), // NW
            },
            &.{ // TYPE_E
                nb(-1, 0, &triangle_square_e_coords, 0, WALL_BRIDGEABLE, 0), // NW
                nb(1, -1, &triangle_square_e_coords, 1, WALL_BRIDGEABLE, 0), // NW
                nb(1, 0, &triangle_square_e_coords, 2, 0, 0), // SW
            },
            &.{ // TYPE_F
                nb(0, 1, &triangle_square_f_coords, 0, WALL_BRIDGEABLE, 0), // NW
                nb(-1, 0, &triangle_square_f_coords, 1, 0, 0), // NW
                nb(1, 0, &triangle_square_f_coords, 2, WALL_BRIDGEABLE, 0), // SW
            },
        },
    };

    pub const triangle_square2_struct = Structure{
        .name = "Triangle-Square (Arcs)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS | STRUCTURE_CROSSOVERS,
        .rows = 2,
        .columns = 3,
        .width = _2A,
        .height = _2A,
        .xminadd = -_B * _TC,
        .xmaxadd = _B + _TC * _B,
        .yminadd = -_B * _TC,
        .ymaxadd = _B + _TC * _B,
        .center_points = &.{
            .{ .x = _TC * _B, .y = _TC * _A },                 .{ .x = _TC * _A, .y = _TC * _B },                   .{ .x = (_TH + 0.5) * _A, .y = (_TH + 0.5) * _B },
            .{ .x = (_TH + 0.5) * _B, .y = (_TH + 0.5) * _A }, .{ .x = (_TC + 1.0) * _SC, .y = (_TC + 1.0) * _SC }, .{ .x = (2.0 * _TC + 1.0) * _SC, .y = (2.0 * _TC + 1.0) * _SC },
        },
        .cell_types = &.{
            TYPE_A,                  TYPE_B, TYPE_C | TYPE_CROSSABLE,
            TYPE_D | TYPE_CROSSABLE, TYPE_E, TYPE_F,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(0, 1, &triangle_square_a_coords, 0, WALL_ARC | WALL_BRIDGEABLE, _60DEG), // NW
                nb(-1, 0, &triangle_square_a_coords, 1, WALL_ARC | WALL_BRIDGEABLE, _60DEG), // SW
                nb(1, 0, &triangle_square_a_coords, 2, 0, 0), // SE
            },
            &.{ // TYPE_B
                nb(-1, 0, &triangle_square_b_coords, 0, 0, 0), // NW
                nb(-1, -1, &triangle_square_b_coords, 1, WALL_ARC | WALL_BRIDGEABLE, _60DEG), // SE
                nb(1, 0, &triangle_square_b_coords, 2, WALL_ARC | WALL_BRIDGEABLE, _60DEG), // SW
            },
            &.{ // TYPE_C
                nb(-1, 1, &triangle_square_c_coords, 0, WALL_ARC | WALL_BRIDGEABLE, -_60DEG), // NW
                nb(-1, 0, &triangle_square_c_coords, 1, WALL_ARC | WALL_BRIDGEABLE, -_60DEG), // NW
                nb(0, -1, &triangle_square_c_coords, 2, WALL_ARC | WALL_BRIDGEABLE, -_60DEG), // SE
                nb(1, 0, &triangle_square_c_coords, 3, WALL_ARC | WALL_BRIDGEABLE, -_60DEG), // SW
            },
            &.{ // TYPE_D
                nb(1, 1, &triangle_square_d_coords, 0, WALL_ARC | WALL_BRIDGEABLE, -_60DEG), // NW
                nb(-1, 0, &triangle_square_d_coords, 1, WALL_ARC | WALL_BRIDGEABLE, -_60DEG), // NW
                nb(0, -1, &triangle_square_d_coords, 2, WALL_ARC | WALL_BRIDGEABLE, -_60DEG), // SE
                nb(1, 0, &triangle_square_d_coords, 3, WALL_ARC | WALL_BRIDGEABLE, -_60DEG), // NW
            },
            &.{ // TYPE_E
                nb(-1, 0, &triangle_square_e_coords, 0, WALL_ARC | WALL_BRIDGEABLE, _60DEG), // NW
                nb(1, -1, &triangle_square_e_coords, 1, WALL_ARC | WALL_BRIDGEABLE, _60DEG), // NW
                nb(1, 0, &triangle_square_e_coords, 2, 0, 0), // SW
            },
            &.{ // TYPE_F
                nb(0, 1, &triangle_square_f_coords, 0, WALL_ARC | WALL_BRIDGEABLE, _60DEG), // NW
                nb(-1, 0, &triangle_square_f_coords, 1, 0, 0), // NW
                nb(1, 0, &triangle_square_f_coords, 2, WALL_ARC | WALL_BRIDGEABLE, _60DEG), // SW
            },
        },
    };
};

// ---------------------------------------------------------------------------
// pentagon-cross structure

const PentagonHouse = struct {
    const _A: f64 = 1.0;

    // multiples and fractions of the base lengths
    const _2A: f64 = 2.0 * _A;
    const _3A: f64 = 3.0 * _A;
    const _4A: f64 = 4.0 * _A;
    const _5A: f64 = 5.0 * _A;
    const _A_2: f64 = 0.5 * _A;

    const pentagon_house_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = _A_2, .y = _A_2 }, // N
        .{ .x = -_A_2, .y = _A_2 }, // W
        .{ .x = -_A_2, .y = -_A_2 }, // SW
        .{ .x = 0, .y = -_A }, // SE
        .{ .x = _A_2, .y = -_A_2 }, // E
        .{ .x = _A_2, .y = _A_2 },
    };

    const pentagon_house_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = _A_2, .y = _A_2 }, // N
        .{ .x = -_A_2, .y = _A_2 }, // W
        .{ .x = -_A_2, .y = -_A_2 }, // S
        .{ .x = _A_2, .y = -_A_2 }, // SE
        .{ .x = _A, .y = 0 }, // SW
        .{ .x = _A_2, .y = _A_2 },
    };

    const pentagon_house_c_coords = [_]Vec2{ // TYPE_C
        .{ .x = 0, .y = _A }, // NW
        .{ .x = -_A_2, .y = _A_2 }, // W
        .{ .x = -_A_2, .y = -_A_2 }, // S
        .{ .x = _A_2, .y = -_A_2 }, // E
        .{ .x = _A_2, .y = _A_2 }, // NE
        .{ .x = 0, .y = _A },
    };

    const pentagon_house_d_coords = [_]Vec2{ // TYPE_D
        .{ .x = _A_2, .y = _A_2 }, // N
        .{ .x = -_A_2, .y = _A_2 }, // NW
        .{ .x = -_A, .y = 0 }, // SW
        .{ .x = -_A_2, .y = -_A_2 }, // S
        .{ .x = _A_2, .y = -_A_2 }, // E
        .{ .x = _A_2, .y = _A_2 },
    };

    pub const pentagon_house_struct = Structure{
        .name = "Pentagon-House",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 5,
        .columns = 5,
        .width = _5A,
        .height = _5A,
        .xminadd = _A_2,
        .xmaxadd = _A_2,
        .yminadd = _A_2,
        .ymaxadd = _A_2,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _A, .y = 0.0 }, .{ .x = _2A, .y = 0.0 }, .{ .x = _3A, .y = 0.0 }, .{ .x = _N, .y = _N },
            .{ .x = 0.0, .y = _A },  .{ .x = _A, .y = _A },  .{ .x = _N, .y = _N },   .{ .x = _3A, .y = _A },  .{ .x = _4A, .y = _A },
            .{ .x = _N, .y = _N },   .{ .x = _A, .y = _2A }, .{ .x = _2A, .y = _2A }, .{ .x = _3A, .y = _2A }, .{ .x = _4A, .y = _2A },
            .{ .x = 0.0, .y = _3A }, .{ .x = _A, .y = _3A }, .{ .x = _2A, .y = _3A }, .{ .x = _N, .y = _N },   .{ .x = _4A, .y = _3A },
            .{ .x = 0.0, .y = _4A }, .{ .x = _N, .y = _N },  .{ .x = _2A, .y = _4A }, .{ .x = _3A, .y = _4A }, .{ .x = _4A, .y = _4A },
        },
        .cell_types = &.{
            TYPE_D,    TYPE_A,    TYPE_C,    TYPE_B,    TYPE_NONE,
            TYPE_C,    TYPE_B,    TYPE_NONE, TYPE_D,    TYPE_A,
            TYPE_NONE, TYPE_D,    TYPE_A,    TYPE_C,    TYPE_B,
            TYPE_A,    TYPE_C,    TYPE_B,    TYPE_NONE, TYPE_D,
            TYPE_B,    TYPE_NONE, TYPE_D,    TYPE_A,    TYPE_C,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(0, 1, &pentagon_house_a_coords, 0, 0, 0), // N
                nb(-1, 0, &pentagon_house_a_coords, 1, 0, 0), // W
                nb(-1, -1, &pentagon_house_a_coords, 2, 0, 0), // SW
                nb(1, -1, &pentagon_house_a_coords, 3, 0, 0), // SE
                nb(1, 0, &pentagon_house_a_coords, 4, 0, 0), // E
            },
            &.{ // TYPE_B
                nb(0, 1, &pentagon_house_b_coords, 0, 0, 0), // N
                nb(-1, 0, &pentagon_house_b_coords, 1, 0, 0), // W
                nb(0, -1, &pentagon_house_b_coords, 2, 0, 0), // S
                nb(1, -1, &pentagon_house_b_coords, 3, 0, 0), // SE
                nb(1, 1, &pentagon_house_b_coords, 4, 0, 0), // SW
            },
            &.{ // TYPE_C
                nb(-1, 1, &pentagon_house_c_coords, 0, 0, 0), // NW
                nb(-1, 0, &pentagon_house_c_coords, 1, 0, 0), // W
                nb(0, -1, &pentagon_house_c_coords, 2, 0, 0), // S
                nb(1, 0, &pentagon_house_c_coords, 3, 0, 0), // E
                nb(1, 1, &pentagon_house_c_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_D
                nb(0, 1, &pentagon_house_d_coords, 0, 0, 0), // N
                nb(-1, 1, &pentagon_house_d_coords, 1, 0, 0), // NW
                nb(-1, -1, &pentagon_house_d_coords, 2, 0, 0), // SW
                nb(0, -1, &pentagon_house_d_coords, 3, 0, 0), // S
                nb(1, 0, &pentagon_house_d_coords, 4, 0, 0), // E
            },
        },
    };
};

// ---------------------------------------------------------------------------
// house II structure

const PentagonHouse2 = struct {
    // 1/sqrt(10)
    const _A: f64 = 0.316227766016837941176476078908;

    // multiples and fractions of the base lengths
    const _2A: f64 = 2.0 * _A;
    const _3A: f64 = 3.0 * _A;
    const _4A: f64 = 4.0 * _A;
    const _5A: f64 = 5.0 * _A;
    const _6A: f64 = 6.0 * _A;
    const _7A: f64 = 7.0 * _A;
    const _8A: f64 = 8.0 * _A;
    const _9A: f64 = 9.0 * _A;
    const _10A: f64 = 10.0 * _A;

    const pentagon_house2_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = _A, .y = _3A }, // NW
        .{ .x = -_A, .y = _2A }, // W
        .{ .x = -_2A, .y = -_A }, // SW
        .{ .x = _A, .y = -_2A }, // SE
        .{ .x = _2A, .y = _A }, // E
        .{ .x = _A, .y = _3A },
    };

    const pentagon_house2_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = _2A, .y = _A }, // N
        .{ .x = -_A, .y = _2A }, // NW
        .{ .x = -_3A, .y = _A }, // SW
        .{ .x = -_2A, .y = -_A }, // E
        .{ .x = _A, .y = -_2A }, // S
        .{ .x = _2A, .y = _A },
    };

    const pentagon_house2_c_coords = [_]Vec2{ // TYPE_C
        .{ .x = _2A, .y = _A }, // N
        .{ .x = -_A, .y = _2A }, // W
        .{ .x = -_2A, .y = -_A }, // SW
        .{ .x = -_A, .y = -_3A }, // SE
        .{ .x = _A, .y = -_2A }, // E
        .{ .x = _2A, .y = _A },
    };

    const pentagon_house2_d_coords = [_]Vec2{ // TYPE_D
        .{ .x = _2A, .y = _A }, // N
        .{ .x = -_A, .y = _2A }, // W
        .{ .x = -_2A, .y = -_A }, // S
        .{ .x = _A, .y = -_2A }, // SE
        .{ .x = _3A, .y = -_A }, // NE
        .{ .x = _2A, .y = _A },
    };

    pub const pentagon_house2_struct = Structure{
        .name = "Pentagon House (2)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 3,
        .columns = 3,
        .width = _10A,
        .height = _10A,
        .xminadd = 0,
        .xmaxadd = _A,
        .yminadd = 0,
        .ymaxadd = _A,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 }, .{ .x = _4A, .y = _2A }, .{ .x = _7A, .y = _A },
            .{ .x = _2A, .y = _6A }, .{ .x = _5A, .y = _5A }, .{ .x = _8A, .y = _4A },
            .{ .x = _3A, .y = _9A }, .{ .x = _N, .y = _N },   .{ .x = _9A, .y = _7A },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,    TYPE_C,
            TYPE_G, TYPE_E,    TYPE_D,
            TYPE_H, TYPE_NONE, TYPE_F,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(-1, 1, &pentagon_house2_a_coords, 0, 0, 0), // N
                nb(-1, 0, &pentagon_house2_a_coords, 1, 0, 0), // W
                nb(-1, -1, &pentagon_house2_a_coords, 2, 0, 0), // SW
                nb(0, -1, &pentagon_house2_a_coords, 3, 0, 0), // SE
                nb(1, 0, &pentagon_house2_a_coords, 4, 0, 0), // E
            },
            &.{ // TYPE_B
                nb(0, 1, &pentagon_house2_b_coords, 0, 0, 0), // N
                nb(-1, 1, &pentagon_house2_b_coords, 1, 0, 0), // W
                nb(-1, 0, &pentagon_house2_b_coords, 2, 0, 0), // S
                nb(-1, -1, &pentagon_house2_b_coords, 3, 0, 0), // SE
                nb(1, 0, &pentagon_house2_b_coords, 4, 0, 0), // SW
            },
            &.{ // TYPE_C
                nb(0, 1, &pentagon_house2_c_coords, 0, 0, 0), // NW
                nb(-1, 0, &pentagon_house2_c_coords, 1, 0, 0), // W
                nb(-2, -1, &pentagon_house2_c_coords, 2, 0, 0), // S
                nb(0, -1, &pentagon_house2_c_coords, 3, 0, 0), // E
                nb(1, 0, &pentagon_house2_c_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_D
                nb(0, 1, &pentagon_house2_d_coords, 0, 0, 0), // N
                nb(-1, 0, &pentagon_house2_d_coords, 1, 0, 0), // N
                nb(0, -1, &pentagon_house2_d_coords, 2, 0, 0), // S
                nb(1, -1, &pentagon_house2_d_coords, 3, 0, 0), // SE
                nb(1, 0, &pentagon_house2_d_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_E(A)
                nb(-1, 1, &pentagon_house2_a_coords, 0, 0, 0), // N
                nb(-1, 0, &pentagon_house2_a_coords, 1, 0, 0), // W
                nb(0, -1, &pentagon_house2_a_coords, 2, 0, 0), // SW
                nb(1, 0, &pentagon_house2_a_coords, 3, 0, 0), // SE
                nb(1, 1, &pentagon_house2_a_coords, 4, 0, 0), // E
            },
            &.{ // TYPE_F(B)
                nb(1, 1, &pentagon_house2_b_coords, 0, 0, 0), // N
                nb(0, 1, &pentagon_house2_b_coords, 1, 0, 0), // W
                nb(-1, -1, &pentagon_house2_b_coords, 2, 0, 0), // S
                nb(0, -1, &pentagon_house2_b_coords, 3, 0, 0), // SE
                nb(1, -1, &pentagon_house2_b_coords, 4, 0, 0), // SW
            },
            &.{ // TYPE_G(C)
                nb(0, 1, &pentagon_house2_c_coords, 0, 0, 0), // NW
                nb(-1, 1, &pentagon_house2_c_coords, 1, 0, 0), // W
                nb(-1, 0, &pentagon_house2_c_coords, 2, 0, 0), // S
                nb(1, -1, &pentagon_house2_c_coords, 3, 0, 0), // E
                nb(1, 0, &pentagon_house2_c_coords, 4, 0, 0), // NE
            },
            &.{ // TYPE_H(D)
                nb(1, 1, &pentagon_house2_d_coords, 0, 0, 0), // N
                nb(0, 1, &pentagon_house2_d_coords, 1, 0, 0), // N
                nb(0, -1, &pentagon_house2_d_coords, 2, 0, 0), // S
                nb(1, -1, &pentagon_house2_d_coords, 3, 0, 0), // SE
                nb(2, 1, &pentagon_house2_d_coords, 4, 0, 0), // NE
            },
        },
    };
};

// ---------------------------------------------------------------------------
// pentagonal structure of type 1 (B + C = 180°, A + D + E = 360°): pairs of
// pentagons form centrally symmetric hexagons; the tiling is not edge-to-edge,
// so every pentagon has six neighbours
// generated by tools/gen_periodic.zig pentagonal_1:1

const PentagonType1 = struct {
    const pentagon_1_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = 5.0 / 28.0, .y = 17.0 / 42.0 },
        .{ .x = -9.0 / 28.0, .y = 89.0 / 168.0 },
        .{ .x = -4.0 / 7.0, .y = 13.0 / 84.0 },
        .{ .x = -9.0 / 28.0, .y = -79.0 / 168.0 },
        .{ .x = 5.0 / 28.0, .y = -25.0 / 42.0 },
        .{ .x = 19.0 / 28.0, .y = 47.0 / 168.0 },
        .{ .x = 5.0 / 28.0, .y = 17.0 / 42.0 },
    };

    const pentagon_1_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = -5.0 / 28.0, .y = 25.0 / 42.0 },
        .{ .x = -19.0 / 28.0, .y = -47.0 / 168.0 },
        .{ .x = -5.0 / 28.0, .y = -17.0 / 42.0 },
        .{ .x = 9.0 / 28.0, .y = -89.0 / 168.0 },
        .{ .x = 4.0 / 7.0, .y = -13.0 / 84.0 },
        .{ .x = 9.0 / 28.0, .y = 79.0 / 168.0 },
        .{ .x = -5.0 / 28.0, .y = 25.0 / 42.0 },
    };

    pub const pentagon_1_struct = Structure{
        .name = "Pentagon (Type 1, p2)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 1,
        .columns = 2,
        .width = 7.0 / 4.0,
        .height = 1.0,
        .xminadd = -25.0 / 56.0,
        .xmaxadd = 25.0 / 56.0,
        .yminadd = -115.0 / 336.0,
        .ymaxadd = 115.0 / 336.0,
        .center_points = &.{
            .{ .x = -3.0 / 7.0, .y = 53.0 / 336.0 }, .{ .x = 3.0 / 7.0, .y = -53.0 / 336.0 },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(0, 1, &pentagon_1_a_coords, 0, 0, 0),
                nb(-1, 1, &pentagon_1_a_coords, 1, 0, 0),
                nb(-1, 0, &pentagon_1_a_coords, 2, 0, 0),
                nb(0, -1, &pentagon_1_a_coords, 3, 0, 0),
                nb(1, 0, &pentagon_1_a_coords, 4, 0, 0),
                nb(1, 1, &pentagon_1_a_coords, 5, 0, 0),
            },
            &.{ // TYPE_B
                nb(-1, 0, &pentagon_1_b_coords, 0, 0, 0),
                nb(-1, -1, &pentagon_1_b_coords, 1, 0, 0),
                nb(0, -1, &pentagon_1_b_coords, 2, 0, 0),
                nb(1, -1, &pentagon_1_b_coords, 3, 0, 0),
                nb(1, 0, &pentagon_1_b_coords, 4, 0, 0),
                nb(0, 1, &pentagon_1_b_coords, 5, 0, 0),
            },
        },
    };
};

// ---------------------------------------------------------------------------
// pentagonal structure of type 1 with a = c, d = e, A + B = 180°,
// C + D + E = 360° (cm symmetry): chevrons of a pentagon and its mirror image,
// stacked in interlocking columns; edge-to-edge
// generated by tools/gen_periodic.zig pentagonal_1:2

const PentagonType1Cm = struct {
    const pentagon_1_cm_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = -11.0 / 60.0, .y = 2.0 / 5.0 },
        .{ .x = -13.0 / 30.0, .y = -1.0 / 10.0 },
        .{ .x = -11.0 / 60.0, .y = -3.0 / 5.0 },
        .{ .x = 19.0 / 60.0, .y = -7.0 / 20.0 },
        .{ .x = 19.0 / 60.0, .y = 13.0 / 20.0 },
        .{ .x = -11.0 / 60.0, .y = 2.0 / 5.0 },
    };

    const pentagon_1_cm_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = 11.0 / 60.0, .y = 2.0 / 5.0 },
        .{ .x = -19.0 / 60.0, .y = 13.0 / 20.0 },
        .{ .x = -19.0 / 60.0, .y = -7.0 / 20.0 },
        .{ .x = 11.0 / 60.0, .y = -3.0 / 5.0 },
        .{ .x = 13.0 / 30.0, .y = -1.0 / 10.0 },
        .{ .x = 11.0 / 60.0, .y = 2.0 / 5.0 },
    };

    pub const pentagon_1_cm_struct = Structure{
        .name = "Pentagon (Type 1, cm)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 2,
        .columns = 2,
        .width = 5.0 / 2.0,
        .height = 1.0,
        .xminadd = -19.0 / 60.0,
        .xmaxadd = 19.0 / 60.0,
        .yminadd = -1.0 / 4.0,
        .ymaxadd = 1.0 / 4.0,
        .center_points = &.{
            .{ .x = -19.0 / 60.0, .y = 7.0 / 20.0 },  .{ .x = 19.0 / 60.0, .y = 7.0 / 20.0 },
            .{ .x = -14.0 / 15.0, .y = 17.0 / 20.0 }, .{ .x = 14.0 / 15.0, .y = 17.0 / 20.0 },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,
            TYPE_B, TYPE_A,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(0, 1, &pentagon_1_cm_a_coords, 0, 0, 0),
                nb(0, -1, &pentagon_1_cm_a_coords, 1, 0, 0),
                nb(0, -2, &pentagon_1_cm_a_coords, 2, 0, 0),
                nb(1, 0, &pentagon_1_cm_a_coords, 3, 0, 0),
                nb(0, 2, &pentagon_1_cm_a_coords, 4, 0, 0),
            },
            &.{ // TYPE_B
                nb(0, 2, &pentagon_1_cm_b_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_1_cm_b_coords, 1, 0, 0),
                nb(0, -2, &pentagon_1_cm_b_coords, 2, 0, 0),
                nb(0, -1, &pentagon_1_cm_b_coords, 3, 0, 0),
                nb(0, 1, &pentagon_1_cm_b_coords, 4, 0, 0),
            },
        },
    };
};

// ---------------------------------------------------------------------------
// pentagonal structure of type 2 (c = e, B + D = 180°, pgg symmetry): the
// pentagon, its 180° rotation and two glide reflections; not edge-to-edge,
// so every pentagon has six neighbours
// generated by tools/gen_periodic.zig pentagonal_2:1

const PentagonType2 = struct {
    const pentagon_2_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = -17.0 / 240.0, .y = 19.0 / 40.0 },
        .{ .x = -25.0 / 48.0, .y = 13.0 / 40.0 },
        .{ .x = -113.0 / 240.0, .y = -21.0 / 40.0 },
        .{ .x = -1.0 / 48.0, .y = -27.0 / 40.0 },
        .{ .x = 23.0 / 48.0, .y = -7.0 / 40.0 },
        .{ .x = 127.0 / 240.0, .y = 27.0 / 40.0 },
        .{ .x = -17.0 / 240.0, .y = 19.0 / 40.0 },
    };

    const pentagon_2_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = -1.0 / 48.0, .y = 27.0 / 40.0 },
        .{ .x = -113.0 / 240.0, .y = 21.0 / 40.0 },
        .{ .x = -25.0 / 48.0, .y = -13.0 / 40.0 },
        .{ .x = -17.0 / 240.0, .y = -19.0 / 40.0 },
        .{ .x = 127.0 / 240.0, .y = -27.0 / 40.0 },
        .{ .x = 23.0 / 48.0, .y = 7.0 / 40.0 },
        .{ .x = -1.0 / 48.0, .y = 27.0 / 40.0 },
    };

    const pentagon_2_c_coords = [_]Vec2{ // TYPE_C
        .{ .x = 17.0 / 240.0, .y = 19.0 / 40.0 },
        .{ .x = -127.0 / 240.0, .y = 27.0 / 40.0 },
        .{ .x = -23.0 / 48.0, .y = -7.0 / 40.0 },
        .{ .x = 1.0 / 48.0, .y = -27.0 / 40.0 },
        .{ .x = 113.0 / 240.0, .y = -21.0 / 40.0 },
        .{ .x = 25.0 / 48.0, .y = 13.0 / 40.0 },
        .{ .x = 17.0 / 240.0, .y = 19.0 / 40.0 },
    };

    const pentagon_2_d_coords = [_]Vec2{ // TYPE_D
        .{ .x = 1.0 / 48.0, .y = 27.0 / 40.0 },
        .{ .x = -23.0 / 48.0, .y = 7.0 / 40.0 },
        .{ .x = -127.0 / 240.0, .y = -27.0 / 40.0 },
        .{ .x = 17.0 / 240.0, .y = -19.0 / 40.0 },
        .{ .x = 25.0 / 48.0, .y = -13.0 / 40.0 },
        .{ .x = 113.0 / 240.0, .y = 21.0 / 40.0 },
        .{ .x = 1.0 / 48.0, .y = 27.0 / 40.0 },
    };

    pub const pentagon_2_struct = Structure{
        .name = "Pentagon (Type 2)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 2,
        .columns = 2,
        .width = 2.0,
        .height = 2.0,
        .xminadd = -11.0 / 48.0,
        .xmaxadd = 11.0 / 48.0,
        .yminadd = -17.0 / 40.0,
        .ymaxadd = 17.0 / 40.0,
        .center_points = &.{
            .{ .x = -11.0 / 48.0, .y = -23.0 / 40.0 }, .{ .x = 37.0 / 48.0, .y = -17.0 / 40.0 },
            .{ .x = -37.0 / 48.0, .y = 17.0 / 40.0 },  .{ .x = 11.0 / 48.0, .y = 23.0 / 40.0 },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,
            TYPE_C, TYPE_D,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(0, 1, &pentagon_2_a_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_2_a_coords, 1, 0, 0),
                nb(0, -1, &pentagon_2_a_coords, 2, 0, 0),
                nb(1, -1, &pentagon_2_a_coords, 3, 0, 0),
                nb(1, 0, &pentagon_2_a_coords, 4, 0, 0),
                nb(1, 1, &pentagon_2_a_coords, 5, 0, 0),
            },
            &.{ // TYPE_B
                nb(0, 1, &pentagon_2_b_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_2_b_coords, 1, 0, 0),
                nb(0, -1, &pentagon_2_b_coords, 2, 0, 0),
                nb(1, -1, &pentagon_2_b_coords, 3, 0, 0),
                nb(1, 0, &pentagon_2_b_coords, 4, 0, 0),
                nb(1, 1, &pentagon_2_b_coords, 5, 0, 0),
            },
            &.{ // TYPE_C
                nb(-1, 1, &pentagon_2_c_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_2_c_coords, 1, 0, 0),
                nb(-1, -1, &pentagon_2_c_coords, 2, 0, 0),
                nb(0, -1, &pentagon_2_c_coords, 3, 0, 0),
                nb(1, 0, &pentagon_2_c_coords, 4, 0, 0),
                nb(0, 1, &pentagon_2_c_coords, 5, 0, 0),
            },
            &.{ // TYPE_D
                nb(-1, 1, &pentagon_2_d_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_2_d_coords, 1, 0, 0),
                nb(-1, -1, &pentagon_2_d_coords, 2, 0, 0),
                nb(0, -1, &pentagon_2_d_coords, 3, 0, 0),
                nb(1, 0, &pentagon_2_d_coords, 4, 0, 0),
                nb(0, 1, &pentagon_2_d_coords, 5, 0, 0),
            },
        },
    };
};

// ---------------------------------------------------------------------------
// pentagonal structure of type 2 with c = e, d = b, B + D = 180° (pgg
// symmetry): four pentagons meet at their vertex D; edge-to-edge
// generated by tools/gen_periodic.zig pentagonal_2:2

const PentagonType2EdgeToEdge = struct {
    const pentagon_2e_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = 65.0 / 231.0, .y = 1.0 / 2.0 },
        .{ .x = -67.0 / 231.0, .y = 5.0 / 14.0 },
        .{ .x = -166.0 / 231.0, .y = -2.0 / 7.0 },
        .{ .x = -34.0 / 231.0, .y = -3.0 / 7.0 },
        .{ .x = 164.0 / 231.0, .y = -1.0 / 7.0 },
        .{ .x = 65.0 / 231.0, .y = 1.0 / 2.0 },
    };

    const pentagon_2e_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = -34.0 / 231.0, .y = 3.0 / 7.0 },
        .{ .x = -166.0 / 231.0, .y = 2.0 / 7.0 },
        .{ .x = -67.0 / 231.0, .y = -5.0 / 14.0 },
        .{ .x = 65.0 / 231.0, .y = -1.0 / 2.0 },
        .{ .x = 164.0 / 231.0, .y = 1.0 / 7.0 },
        .{ .x = -34.0 / 231.0, .y = 3.0 / 7.0 },
    };

    const pentagon_2e_c_coords = [_]Vec2{ // TYPE_C
        .{ .x = -65.0 / 231.0, .y = 1.0 / 2.0 },
        .{ .x = -164.0 / 231.0, .y = -1.0 / 7.0 },
        .{ .x = 34.0 / 231.0, .y = -3.0 / 7.0 },
        .{ .x = 166.0 / 231.0, .y = -2.0 / 7.0 },
        .{ .x = 67.0 / 231.0, .y = 5.0 / 14.0 },
        .{ .x = -65.0 / 231.0, .y = 1.0 / 2.0 },
    };

    const pentagon_2e_d_coords = [_]Vec2{ // TYPE_D
        .{ .x = 34.0 / 231.0, .y = 3.0 / 7.0 },
        .{ .x = -164.0 / 231.0, .y = 1.0 / 7.0 },
        .{ .x = -65.0 / 231.0, .y = -1.0 / 2.0 },
        .{ .x = 67.0 / 231.0, .y = -5.0 / 14.0 },
        .{ .x = 166.0 / 231.0, .y = 2.0 / 7.0 },
        .{ .x = 34.0 / 231.0, .y = 3.0 / 7.0 },
    };

    pub const pentagon_2e_struct = Structure{
        .name = "Pentagon (Type 2, edge-to-edge)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 2,
        .columns = 2,
        .width = 2.0,
        .height = 11.0 / 7.0,
        .xminadd = -65.0 / 231.0,
        .xmaxadd = 65.0 / 231.0,
        .yminadd = -2.0 / 7.0,
        .ymaxadd = 2.0 / 7.0,
        .center_points = &.{
            .{ .x = -65.0 / 231.0, .y = -1.0 / 2.0 }, .{ .x = 166.0 / 231.0, .y = -2.0 / 7.0 },
            .{ .x = -166.0 / 231.0, .y = 2.0 / 7.0 }, .{ .x = 65.0 / 231.0, .y = 1.0 / 2.0 },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,
            TYPE_C, TYPE_D,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(0, 1, &pentagon_2e_a_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_2e_a_coords, 1, 0, 0),
                nb(0, -1, &pentagon_2e_a_coords, 2, 0, 0),
                nb(1, -1, &pentagon_2e_a_coords, 3, 0, 0),
                nb(1, 0, &pentagon_2e_a_coords, 4, 0, 0),
            },
            &.{ // TYPE_B
                nb(0, 1, &pentagon_2e_b_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_2e_b_coords, 1, 0, 0),
                nb(0, -1, &pentagon_2e_b_coords, 2, 0, 0),
                nb(1, 0, &pentagon_2e_b_coords, 3, 0, 0),
                nb(1, 1, &pentagon_2e_b_coords, 4, 0, 0),
            },
            &.{ // TYPE_C
                nb(-1, 0, &pentagon_2e_c_coords, 0, 0, 0),
                nb(-1, -1, &pentagon_2e_c_coords, 1, 0, 0),
                nb(0, -1, &pentagon_2e_c_coords, 2, 0, 0),
                nb(1, 0, &pentagon_2e_c_coords, 3, 0, 0),
                nb(0, 1, &pentagon_2e_c_coords, 4, 0, 0),
            },
            &.{ // TYPE_D
                nb(-1, 1, &pentagon_2e_d_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_2e_d_coords, 1, 0, 0),
                nb(0, -1, &pentagon_2e_d_coords, 2, 0, 0),
                nb(1, 0, &pentagon_2e_d_coords, 3, 0, 0),
                nb(0, 1, &pentagon_2e_d_coords, 4, 0, 0),
            },
        },
    };
};

// ---------------------------------------------------------------------------
// pentagonal structure of type 10 with a = b = 2c = 2e, A = B = E = 90°,
// C = D = 135° (cmm symmetry, turned by 45°): 2 x 2 squares with a corner cut
// off; not edge-to-edge, so some pentagons have seven neighbours
// generated by tools/gen_periodic.zig pentagonal_10

const PentagonType10 = struct {
    const SQRT2: f64 = @sqrt(2.0);

    const pentagon_10_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = (2.0 / 21.0) * SQRT2, .y = SQRT2 },
        .{ .x = (-19.0 / 21.0) * SQRT2, .y = 0.0 },
        .{ .x = (2.0 / 21.0) * SQRT2, .y = -SQRT2 },
        .{ .x = (25.0 / 42.0) * SQRT2, .y = (-1.0 / 2.0) * SQRT2 },
        .{ .x = (25.0 / 42.0) * SQRT2, .y = (1.0 / 2.0) * SQRT2 },
        .{ .x = (2.0 / 21.0) * SQRT2, .y = SQRT2 },
    };

    const pentagon_10_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = (-2.0 / 21.0) * SQRT2, .y = SQRT2 },
        .{ .x = (-25.0 / 42.0) * SQRT2, .y = (1.0 / 2.0) * SQRT2 },
        .{ .x = (-25.0 / 42.0) * SQRT2, .y = (-1.0 / 2.0) * SQRT2 },
        .{ .x = (-2.0 / 21.0) * SQRT2, .y = -SQRT2 },
        .{ .x = (17.0 / 42.0) * SQRT2, .y = (-1.0 / 2.0) * SQRT2 },
        .{ .x = (19.0 / 21.0) * SQRT2, .y = 0.0 },
        .{ .x = (17.0 / 42.0) * SQRT2, .y = (1.0 / 2.0) * SQRT2 },
        .{ .x = (-2.0 / 21.0) * SQRT2, .y = SQRT2 },
    };

    const pentagon_10_c_coords = [_]Vec2{ // TYPE_C
        .{ .x = (1.0 / 2.0) * SQRT2, .y = (25.0 / 42.0) * SQRT2 },
        .{ .x = (-1.0 / 2.0) * SQRT2, .y = (25.0 / 42.0) * SQRT2 },
        .{ .x = -SQRT2, .y = (2.0 / 21.0) * SQRT2 },
        .{ .x = 0.0, .y = (-19.0 / 21.0) * SQRT2 },
        .{ .x = SQRT2, .y = (2.0 / 21.0) * SQRT2 },
        .{ .x = (1.0 / 2.0) * SQRT2, .y = (25.0 / 42.0) * SQRT2 },
    };

    const pentagon_10_d_coords = [_]Vec2{ // TYPE_D
        .{ .x = 0.0, .y = (19.0 / 21.0) * SQRT2 },
        .{ .x = -SQRT2, .y = (-2.0 / 21.0) * SQRT2 },
        .{ .x = (-1.0 / 2.0) * SQRT2, .y = (-25.0 / 42.0) * SQRT2 },
        .{ .x = (1.0 / 2.0) * SQRT2, .y = (-25.0 / 42.0) * SQRT2 },
        .{ .x = SQRT2, .y = (-2.0 / 21.0) * SQRT2 },
        .{ .x = 0.0, .y = (19.0 / 21.0) * SQRT2 },
    };

    const pentagon_10_e_coords = [_]Vec2{ // TYPE_E
        .{ .x = (2.0 / 21.0) * SQRT2, .y = SQRT2 },
        .{ .x = (-17.0 / 42.0) * SQRT2, .y = (1.0 / 2.0) * SQRT2 },
        .{ .x = (-19.0 / 21.0) * SQRT2, .y = 0.0 },
        .{ .x = (-17.0 / 42.0) * SQRT2, .y = (-1.0 / 2.0) * SQRT2 },
        .{ .x = (2.0 / 21.0) * SQRT2, .y = -SQRT2 },
        .{ .x = (25.0 / 42.0) * SQRT2, .y = (-1.0 / 2.0) * SQRT2 },
        .{ .x = (25.0 / 42.0) * SQRT2, .y = (1.0 / 2.0) * SQRT2 },
        .{ .x = (2.0 / 21.0) * SQRT2, .y = SQRT2 },
    };

    const pentagon_10_f_coords = [_]Vec2{ // TYPE_F
        .{ .x = (-2.0 / 21.0) * SQRT2, .y = SQRT2 },
        .{ .x = (-25.0 / 42.0) * SQRT2, .y = (1.0 / 2.0) * SQRT2 },
        .{ .x = (-25.0 / 42.0) * SQRT2, .y = (-1.0 / 2.0) * SQRT2 },
        .{ .x = (-2.0 / 21.0) * SQRT2, .y = -SQRT2 },
        .{ .x = (19.0 / 21.0) * SQRT2, .y = 0.0 },
        .{ .x = (-2.0 / 21.0) * SQRT2, .y = SQRT2 },
    };

    pub const pentagon_10_struct = Structure{
        .name = "Pentagon (Type 10)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 2,
        .columns = 6,
        .width = 7.0 * SQRT2,
        .height = 3.0 * SQRT2,
        .xminadd = 0.0,
        .xmaxadd = 0.0,
        .yminadd = (-13.0 / 84.0) * SQRT2,
        .ymaxadd = (13.0 / 84.0) * SQRT2,
        .center_points = &.{
            .{ .x = (-2.0 / 21.0) * SQRT2, .y = 0.0 },    .{ .x = (23.0 / 21.0) * SQRT2, .y = 0.0 },                 .{ .x = (5.0 / 2.0) * SQRT2, .y = (-25.0 / 42.0) * SQRT2 }, .{ .x = (5.0 / 2.0) * SQRT2, .y = (25.0 / 42.0) * SQRT2 },  .{ .x = (82.0 / 21.0) * SQRT2, .y = 0.0 },                  .{ .x = (107.0 / 21.0) * SQRT2, .y = 0.0 },
            .{ .x = -SQRT2, .y = (44.0 / 21.0) * SQRT2 }, .{ .x = (17.0 / 42.0) * SQRT2, .y = (3.0 / 2.0) * SQRT2 }, .{ .x = (67.0 / 42.0) * SQRT2, .y = (3.0 / 2.0) * SQRT2 },  .{ .x = (143.0 / 42.0) * SQRT2, .y = (3.0 / 2.0) * SQRT2 }, .{ .x = (193.0 / 42.0) * SQRT2, .y = (3.0 / 2.0) * SQRT2 }, .{ .x = 6.0 * SQRT2, .y = (19.0 / 21.0) * SQRT2 },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B, TYPE_C, TYPE_D, TYPE_E, TYPE_F,
            TYPE_D, TYPE_E, TYPE_F, TYPE_A, TYPE_B, TYPE_C,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(-1, 1, &pentagon_10_a_coords, 0, 0, 0),
                nb(0, -1, &pentagon_10_a_coords, 1, 0, 0),
                nb(1, -1, &pentagon_10_a_coords, 2, 0, 0),
                nb(1, 0, &pentagon_10_a_coords, 3, 0, 0),
                nb(1, 1, &pentagon_10_a_coords, 4, 0, 0),
            },
            &.{ // TYPE_B
                nb(0, 1, &pentagon_10_b_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_10_b_coords, 1, 0, 0),
                nb(0, -1, &pentagon_10_b_coords, 2, 0, 0),
                nb(1, -1, &pentagon_10_b_coords, 3, 0, 0),
                nb(1, 0, &pentagon_10_b_coords, 4, 0, 0),
                nb(2, 0, &pentagon_10_b_coords, 5, 0, 0),
                nb(1, 1, &pentagon_10_b_coords, 6, 0, 0),
            },
            &.{ // TYPE_C
                nb(1, 0, &pentagon_10_c_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_10_c_coords, 1, 0, 0),
                nb(0, -1, &pentagon_10_c_coords, 2, 0, 0),
                nb(1, -1, &pentagon_10_c_coords, 3, 0, 0),
                nb(2, 0, &pentagon_10_c_coords, 4, 0, 0),
            },
            &.{ // TYPE_D
                nb(-1, 1, &pentagon_10_d_coords, 0, 0, 0),
                nb(-2, 0, &pentagon_10_d_coords, 1, 0, 0),
                nb(-1, 0, &pentagon_10_d_coords, 2, 0, 0),
                nb(1, 0, &pentagon_10_d_coords, 3, 0, 0),
                nb(0, 1, &pentagon_10_d_coords, 4, 0, 0),
            },
            &.{ // TYPE_E
                nb(-1, 1, &pentagon_10_e_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_10_e_coords, 1, 0, 0),
                nb(-2, 0, &pentagon_10_e_coords, 2, 0, 0),
                nb(-1, -1, &pentagon_10_e_coords, 3, 0, 0),
                nb(0, -1, &pentagon_10_e_coords, 4, 0, 0),
                nb(1, 0, &pentagon_10_e_coords, 5, 0, 0),
                nb(0, 1, &pentagon_10_e_coords, 6, 0, 0),
            },
            &.{ // TYPE_F
                nb(-1, 1, &pentagon_10_f_coords, 0, 0, 0),
                nb(-1, 0, &pentagon_10_f_coords, 1, 0, 0),
                nb(-1, -1, &pentagon_10_f_coords, 2, 0, 0),
                nb(1, -1, &pentagon_10_f_coords, 3, 0, 0),
                nb(0, 1, &pentagon_10_f_coords, 4, 0, 0),
            },
        },
    };
};

// ---------------------------------------------------------------------------
// hexagonal-pentagonal structure

const Pentagon3 = struct {
    const _A: f64 = 0.866025403784438596588302061718;
    const _B: f64 = 1.0;

    // multiples and fractions of the base lengths
    const _2A: f64 = 2.0 * _A;
    const _A_2: f64 = 0.5 * _A;
    const _A_4: f64 = _A / 4.0;
    const _3A_2: f64 = 1.5 * _A;
    const _3A_4: f64 = 3.0 * _A / 4.0;
    const _5A_4: f64 = 5.0 * _A / 4.0;
    const _3B: f64 = 3.0 * _B;
    const _B_2: f64 = 0.5 * _B;
    const _B_8: f64 = _B / 8.0;
    const _3B_2: f64 = 1.5 * _B;
    const _3B_8: f64 = 3.0 * _B / 8.0;
    const _5B_8: f64 = 5.0 * _B / 8.0;
    const _3B_4: f64 = 3.0 * _B / 4.0;
    const _9B_8: f64 = 9.0 * _B / 8.0;
    const _9B_4: f64 = 9.0 * _B / 4.0;

    const hexa_penta_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = _3B_8, .y = _3A_4 }, // NE
        .{ .x = -_B_8, .y = _3A_4 }, // NW
        .{ .x = -_3B_8, .y = _A_4 }, // NW
        .{ .x = -_5B_8, .y = -_A_4 }, // W
        .{ .x = -_3B_8, .y = -_3A_4 }, // SW
        .{ .x = _3B_8, .y = -_A_4 }, // SE
        .{ .x = _3B_8, .y = _3A_4 },
    };

    const hexa_penta_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = 0.0, .y = _A_2 }, // N
        .{ .x = -_3B_4, .y = 0.0 }, // W
        .{ .x = -_B_2, .y = -_A_2 }, // SW
        .{ .x = 0.0, .y = -_A_2 }, // S
        .{ .x = _B_2, .y = -_A_2 }, // SE
        .{ .x = _3B_4, .y = 0.0 }, // NE
        .{ .x = 0.0, .y = _A_2 },
    };

    const hexa_penta_c_coords = [_]Vec2{ // TYPE_B
        .{ .x = _B_8, .y = _3A_4 }, // NE
        .{ .x = -_3B_8, .y = _3A_4 }, // NW
        .{ .x = -_3B_8, .y = -_A_4 }, // SW
        .{ .x = _3B_8, .y = -_3A_4 }, // SE
        .{ .x = _5B_8, .y = -_A_4 }, // SE
        .{ .x = _3B_8, .y = _A_4 }, // E
        .{ .x = _B_8, .y = _3A_4 },
    };

    pub const pentagon_3_struct = Structure{
        .name = "Pentagon (Type 3)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 2,
        .columns = 3,
        .width = _3B,
        .height = _2A,
        .xminadd = -_3B_8,
        .xmaxadd = _3B_8,
        .yminadd = -_A_4,
        .ymaxadd = _A_2,
        .center_points = &.{
            .{ .x = _3B_8, .y = _A_4 },  .{ .x = _9B_8, .y = _A_4 },          .{ .x = _9B_4, .y = _A_2 },
            .{ .x = _3B_4, .y = _3A_2 }, .{ .x = _3B_2 + _3B_8, .y = _5A_4 }, .{ .x = _3B_2 + _9B_8, .y = _5A_4 },
        },
        .cell_types = &.{
            TYPE_A, TYPE_C, TYPE_E,
            TYPE_B, TYPE_D, TYPE_F,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(0, 1, &hexa_penta_a_coords, 0, 0, 0), // N
                nb(-1, 1, &hexa_penta_a_coords, 1, 0, 0), // NW
                nb(-1, 0, &hexa_penta_a_coords, 2, 0, 0), // SW
                nb(-1, -1, &hexa_penta_a_coords, 3, 0, 0), // SW
                nb(0, -1, &hexa_penta_a_coords, 4, 0, 0), // SE
                nb(1, 0, &hexa_penta_a_coords, 5, 0, 0), // E
            },
            &.{ // TYPE_B
                nb(0, 1, &hexa_penta_b_coords, 0, 0, 0), // NW
                nb(-1, 0, &hexa_penta_b_coords, 1, 0, 0), // W
                nb(0, -1, &hexa_penta_b_coords, 2, 0, 0), // SW
                nb(1, -1, &hexa_penta_b_coords, 3, 0, 0), // SE
                nb(1, 0, &hexa_penta_b_coords, 4, 0, 0), // SE
                nb(1, 1, &hexa_penta_b_coords, 5, 0, 0), // NE
            },
            &.{ // TYPE_C
                nb(-1, 1, &hexa_penta_c_coords, 0, 0, 0), // N
                nb(-1, 0, &hexa_penta_c_coords, 1, 0, 0), // NW
                nb(-1, -1, &hexa_penta_c_coords, 2, 0, 0), // SW
                nb(0, -1, &hexa_penta_c_coords, 3, 0, 0), // SE
                nb(1, 0, &hexa_penta_c_coords, 4, 0, 0), // NE
                nb(0, 1, &hexa_penta_c_coords, 5, 0, 0), // NE
            },
            &.{ // TYPE_D
                nb(1, 1, &hexa_penta_a_coords, 0, 0, 0), // N
                nb(0, 1, &hexa_penta_a_coords, 1, 0, 0), // NW
                nb(-1, 0, &hexa_penta_a_coords, 2, 0, 0), // SW
                nb(0, -1, &hexa_penta_a_coords, 3, 0, 0), // SW
                nb(1, -1, &hexa_penta_a_coords, 4, 0, 0), // SE
                nb(1, 0, &hexa_penta_a_coords, 5, 0, 0), // E
            },
            &.{ // TYPE_E
                nb(-1, 1, &hexa_penta_b_coords, 0, 0, 0), // NW
                nb(-1, 0, &hexa_penta_b_coords, 1, 0, 0), // W
                nb(-1, -1, &hexa_penta_b_coords, 2, 0, 0), // SW
                nb(0, -1, &hexa_penta_b_coords, 3, 0, 0), // SE
                nb(1, 0, &hexa_penta_b_coords, 4, 0, 0), // SE
                nb(0, 1, &hexa_penta_b_coords, 5, 0, 0), // NE
            },
            &.{ // TYPE_F
                nb(0, 1, &hexa_penta_c_coords, 0, 0, 0), // N
                nb(-1, 0, &hexa_penta_c_coords, 1, 0, 0), // NW
                nb(0, -1, &hexa_penta_c_coords, 2, 0, 0), // SW
                nb(1, -1, &hexa_penta_c_coords, 3, 0, 0), // SE
                nb(1, 0, &hexa_penta_c_coords, 4, 0, 0), // NE
                nb(1, 1, &hexa_penta_c_coords, 5, 0, 0), // NE
            },
        },
    };
};

// ---------------------------------------------------------------------------
// hexagonal-orthogonal-triagonal structure

const HexagonSquareTriangle = struct {
    const _A: f64 = 0.866025403784438596588302061718;
    const _B: f64 = 1.0;

    const _D_2: f64 = 0.5 * (_A - _B_2);

    // multiples and fractions of the base lengths
    const _2A: f64 = 2.0 * _A;
    const _A_2: f64 = 0.5 * _A;
    const _3A_2: f64 = 1.5 * _A;
    const _2B: f64 = 2.0 * _B;
    const _3B: f64 = 3.0 * _B;
    const _B_2: f64 = 0.5 * _B;
    const _3B_2: f64 = 1.5 * _B;
    const _5B_2: f64 = 5.0 * _B / 2.0;

    const hexa_ortho_tria_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = _B_2, .y = _A }, // N
        .{ .x = -_B_2, .y = _A }, // NW
        .{ .x = -_B, .y = 0.0 }, // SW
        .{ .x = -_B_2, .y = -_A }, // S
        .{ .x = _B_2, .y = -_A }, // SE
        .{ .x = _B, .y = 0.0 }, // NE
        .{ .x = _B_2, .y = _A },
    };

    const hexa_ortho_tria_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = _B_2, .y = _B_2 }, // N
        .{ .x = -_B_2, .y = _B_2 }, // W
        .{ .x = -_B_2, .y = -_B_2 }, // S
        .{ .x = _B_2, .y = -_B_2 }, // E
        .{ .x = _B_2, .y = _B_2 },
    };

    const hexa_ortho_tria_c_coords = [_]Vec2{ // TYPE_C
        .{ .x = _A_2, .y = 0.0 }, // NE
        .{ .x = -_A_2, .y = _B_2 }, // W
        .{ .x = -_A_2, .y = -_B_2 }, // SE
        .{ .x = _A_2, .y = 0.0 },
    };

    const hexa_ortho_tria_d_coords = [_]Vec2{ // TYPE_D
        .{ .x = _D_2, .y = _D_2 + _B_2 }, // NW
        .{ .x = -_D_2 - _B_2, .y = _D_2 }, // SW
        .{ .x = -_D_2, .y = -_D_2 - _B_2 }, // SE
        .{ .x = _D_2 + _B_2, .y = -_D_2 }, // NE
        .{ .x = _D_2, .y = _D_2 + _B_2 },
    };

    const hexa_ortho_tria_e_coords = [_]Vec2{ // TYPE_E
        .{ .x = _D_2 + _B_2, .y = _D_2 }, // NE
        .{ .x = -_D_2, .y = _D_2 + _B_2 }, // NW
        .{ .x = -_D_2 - _B_2, .y = -_D_2 }, // SW
        .{ .x = _D_2, .y = -_D_2 - _B_2 }, // SE
        .{ .x = _D_2 + _B_2, .y = _D_2 },
    };

    const hexa_ortho_tria_f_coords = [_]Vec2{ // TYPE_F
        .{ .x = _A_2, .y = _B_2 }, // NW
        .{ .x = -_A_2, .y = 0.0 }, // SW
        .{ .x = _A_2, .y = -_B_2 }, // E
        .{ .x = _A_2, .y = _B_2 },
    };

    pub const hexa_ortho_tria_struct = Structure{
        .name = "Hexagon, Square & Triangle",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 4,
        .columns = 4,
        .width = _2A + _3B,
        .height = _2A + _B,
        .xminadd = -_B_2,
        .xmaxadd = _A_2,
        .yminadd = -_B_2,
        .ymaxadd = _D_2,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 },       .{ .x = _B + _A_2, .y = 0.0 },            .{ .x = _3B_2 + _A, .y = 0.0 },       .{ .x = _2B + _3A_2, .y = 0.0 },
            .{ .x = _N, .y = _N },         .{ .x = _B + _D_2, .y = _B_2 + _D_2 },    .{ .x = _N, .y = _N },                .{ .x = _5B_2 + _A + _D_2, .y = _B_2 + _D_2 },
            .{ .x = 0.0, .y = _A + _B_2 }, .{ .x = _A_2 + _B_2, .y = _A + _B_2 },    .{ .x = _A + _3B_2, .y = _A + _B_2 }, .{ .x = _3A_2 + _5B_2, .y = _A + _B_2 },
            .{ .x = _N, .y = _N },         .{ .x = _B + _D_2, .y = _A + _B + _D_2 }, .{ .x = _N, .y = _N },                .{ .x = _5B_2 + _A + _D_2, .y = _A + _B + _D_2 },
        },
        .cell_types = &.{
            TYPE_A,    TYPE_F, TYPE_B,    TYPE_C,
            TYPE_NONE, TYPE_D, TYPE_NONE, TYPE_E,
            TYPE_B,    TYPE_C, TYPE_A,    TYPE_F,
            TYPE_NONE, TYPE_E, TYPE_NONE, TYPE_D,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(0, 2, &hexa_ortho_tria_a_coords, 0, 0, 0), // N
                nb(-1, 1, &hexa_ortho_tria_a_coords, 1, 0, 0), // NW
                nb(-1, -1, &hexa_ortho_tria_a_coords, 2, 0, 0), // SW
                nb(0, -2, &hexa_ortho_tria_a_coords, 3, 0, 0), // S
                nb(1, -1, &hexa_ortho_tria_a_coords, 4, 0, 0), // SE
                nb(1, 1, &hexa_ortho_tria_a_coords, 5, 0, 0), // NE
            },
            &.{ // TYPE_B
                nb(0, 2, &hexa_ortho_tria_b_coords, 0, 0, 0), // N
                nb(-1, 0, &hexa_ortho_tria_b_coords, 1, 0, 0), // W
                nb(0, -2, &hexa_ortho_tria_b_coords, 2, 0, 0), // S
                nb(1, 0, &hexa_ortho_tria_b_coords, 3, 0, 0), // E
            },
            &.{ // TYPE_C
                nb(0, 1, &hexa_ortho_tria_c_coords, 0, 0, 0), // NE
                nb(-1, 0, &hexa_ortho_tria_c_coords, 1, 0, 0), // NW
                nb(0, -1, &hexa_ortho_tria_c_coords, 2, 0, 0), // SW
            },
            &.{ // TYPE_D
                nb(0, 1, &hexa_ortho_tria_d_coords, 0, 0, 0), // NW
                nb(-1, -1, &hexa_ortho_tria_d_coords, 1, 0, 0), // SW
                nb(0, -1, &hexa_ortho_tria_d_coords, 2, 0, 0), // SE
                nb(1, 1, &hexa_ortho_tria_d_coords, 3, 0, 0), // NE
            },
            &.{ // TYPE_E
                nb(0, 1, &hexa_ortho_tria_e_coords, 0, 0, 0), // NE
                nb(-1, 1, &hexa_ortho_tria_e_coords, 1, 0, 0), // NW
                nb(0, -1, &hexa_ortho_tria_e_coords, 2, 0, 0), // SW
                nb(1, -1, &hexa_ortho_tria_e_coords, 3, 0, 0), // SE
            },
            &.{ // TYPE_F
                nb(0, 1, &hexa_ortho_tria_f_coords, 0, 0, 0), // NW
                nb(0, -1, &hexa_ortho_tria_f_coords, 1, 0, 0), // SW
                nb(1, 0, &hexa_ortho_tria_f_coords, 2, 0, 0), // E
            },
        },
    };

    pub const hexa_ortho_tria2_struct = Structure{
        .name = "Hexagon, Square & Triangle (Arcs)",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE | STRUCTURE_ARCS,
        .rows = 4,
        .columns = 4,
        .width = _2A + _3B,
        .height = _2A + _B,
        .xminadd = -_B_2,
        .xmaxadd = _A_2,
        .yminadd = -_B_2,
        .ymaxadd = _D_2,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 },       .{ .x = _B + _A_2, .y = 0.0 },            .{ .x = _3B_2 + _A, .y = 0.0 },       .{ .x = _2B + _3A_2, .y = 0.0 },
            .{ .x = _N, .y = _N },         .{ .x = _B + _D_2, .y = _B_2 + _D_2 },    .{ .x = _N, .y = _N },                .{ .x = _5B_2 + _A + _D_2, .y = _B_2 + _D_2 },
            .{ .x = 0.0, .y = _A + _B_2 }, .{ .x = _A_2 + _B_2, .y = _A + _B_2 },    .{ .x = _A + _3B_2, .y = _A + _B_2 }, .{ .x = _3A_2 + _5B_2, .y = _A + _B_2 },
            .{ .x = _N, .y = _N },         .{ .x = _B + _D_2, .y = _A + _B + _D_2 }, .{ .x = _N, .y = _N },                .{ .x = _5B_2 + _A + _D_2, .y = _A + _B + _D_2 },
        },
        .cell_types = &.{
            TYPE_A,    TYPE_F, TYPE_B,    TYPE_C,
            TYPE_NONE, TYPE_D, TYPE_NONE, TYPE_E,
            TYPE_B,    TYPE_C, TYPE_A,    TYPE_F,
            TYPE_NONE, TYPE_E, TYPE_NONE, TYPE_D,
        },
        .neighbours = &.{ // TYPE_A
            &.{
                nb(0, 2, &hexa_ortho_tria_a_coords, 0, WALL_ARC, _60DEG), // N
                nb(-1, 1, &hexa_ortho_tria_a_coords, 1, WALL_ARC, _60DEG), // NW
                nb(-1, -1, &hexa_ortho_tria_a_coords, 2, WALL_ARC, _60DEG), // SW
                nb(0, -2, &hexa_ortho_tria_a_coords, 3, WALL_ARC, _60DEG), // S
                nb(1, -1, &hexa_ortho_tria_a_coords, 4, WALL_ARC, _60DEG), // SE
                nb(1, 1, &hexa_ortho_tria_a_coords, 5, WALL_ARC, _60DEG), // NE
            },
            &.{ // TYPE_B
                nb(0, 2, &hexa_ortho_tria_b_coords, 0, WALL_ARC, -_60DEG), // N
                nb(-1, 0, &hexa_ortho_tria_b_coords, 1, WALL_ARC, -_120DEG), // W
                nb(0, -2, &hexa_ortho_tria_b_coords, 2, WALL_ARC, -_60DEG), // S
                nb(1, 0, &hexa_ortho_tria_b_coords, 3, WALL_ARC, -_120DEG), // E
            },
            &.{ // TYPE_C
                nb(0, 1, &hexa_ortho_tria_c_coords, 0, WALL_ARC, _120DEG), // NE
                nb(-1, 0, &hexa_ortho_tria_c_coords, 1, WALL_ARC, _120DEG), // NW
                nb(0, -1, &hexa_ortho_tria_c_coords, 2, WALL_ARC, _120DEG), // SW
            },
            &.{ // TYPE_D
                nb(0, 1, &hexa_ortho_tria_d_coords, 0, WALL_ARC, -_120DEG), // NW
                nb(-1, -1, &hexa_ortho_tria_d_coords, 1, WALL_ARC, -_60DEG), // SW
                nb(0, -1, &hexa_ortho_tria_d_coords, 2, WALL_ARC, -_120DEG), // SE
                nb(1, 1, &hexa_ortho_tria_d_coords, 3, WALL_ARC, -_60DEG), // NE
            },
            &.{ // TYPE_E
                nb(0, 1, &hexa_ortho_tria_e_coords, 0, WALL_ARC, -_120DEG), // NE
                nb(-1, 1, &hexa_ortho_tria_e_coords, 1, WALL_ARC, -_60DEG), // NW
                nb(0, -1, &hexa_ortho_tria_e_coords, 2, WALL_ARC, -_120DEG), // SW
                nb(1, -1, &hexa_ortho_tria_e_coords, 3, WALL_ARC, -_60DEG), // SE
            },
            &.{ // TYPE_F
                nb(0, 1, &hexa_ortho_tria_f_coords, 0, WALL_ARC, _120DEG), // NW
                nb(0, -1, &hexa_ortho_tria_f_coords, 1, WALL_ARC, _120DEG), // SW
                nb(1, 0, &hexa_ortho_tria_f_coords, 2, WALL_ARC, _120DEG), // E
            },
        },
    };
};

// ---------------------------------------------------------------------------
// Theta structure (dummy)

const Theta = struct {
    pub const theta_struct = Structure{
        .name = "Theta",
        .kind = "Circular",
        .construct = .theta,
        .features = STRUCTURE_RINGS,
    };
};

// ---------------------------------------------------------------------------
// Klaassen's pentagonal tilings with n-fold rotational symmetry (see
// rotational.zig); rings like the theta maze, the columns give n

const PentagonRotational = struct {
    pub const pentagon_rotational_struct = Structure{
        .name = "Pentagon (n-fold Rotational Symmetry)",
        .kind = "Circular",
        .construct = .pentagonal_rotational,
        .features = STRUCTURE_RINGS,
    };
};

// ---------------------------------------------------------------------------
// voronoi structure

const Voronoi = struct {
    pub const random_struct = Structure{
        .name = "Random",
        .kind = "Voronoi",
        .construct = .voronoi,
        .features = STRUCTURE_RANDOMNESS,
    };

    pub const random4_struct = Structure{
        .name = "Random-4",
        .kind = "Voronoi",
        .construct = .voronoi4,
        .features = STRUCTURE_RANDOMNESS,
    };

    pub const random6_struct = Structure{
        .name = "Random-6",
        .kind = "Voronoi",
        .construct = .voronoi6,
        .features = STRUCTURE_RANDOMNESS,
    };

    pub const random3_struct = Structure{
        .name = "Random-3",
        .kind = "Voronoi",
        .construct = .voronoi3,
        .features = STRUCTURE_RANDOMNESS,
    };

    pub const random_disc_struct = Structure{
        .name = "Random-Disc",
        .kind = "Voronoi",
        .construct = .voronoi_disc,
        .features = STRUCTURE_RANDOMNESS,
    };
};
// ---------------------------------------------------------------------------
// square, hexagon & dodecagon structure (truncated trihexagonal tiling 4.6.12)
// generated by tools/gen_periodic.zig 4.6.12

const TruncatedTrihexagonal = struct {
    const SQRT3: f64 = @sqrt(3.0);

    const truncated_trihexagonal_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = 1.0 / 2.0, .y = 1.0 + (1.0 / 2.0) * SQRT3 },
        .{ .x = -1.0 / 2.0, .y = 1.0 + (1.0 / 2.0) * SQRT3 },
        .{ .x = -1.0 / 2.0 + (-1.0 / 2.0) * SQRT3, .y = 1.0 / 2.0 + (1.0 / 2.0) * SQRT3 },
        .{ .x = -1.0 + (-1.0 / 2.0) * SQRT3, .y = 1.0 / 2.0 },
        .{ .x = -1.0 + (-1.0 / 2.0) * SQRT3, .y = -1.0 / 2.0 },
        .{ .x = -1.0 / 2.0 + (-1.0 / 2.0) * SQRT3, .y = -1.0 / 2.0 + (-1.0 / 2.0) * SQRT3 },
        .{ .x = -1.0 / 2.0, .y = -1.0 + (-1.0 / 2.0) * SQRT3 },
        .{ .x = 1.0 / 2.0, .y = -1.0 + (-1.0 / 2.0) * SQRT3 },
        .{ .x = 1.0 / 2.0 + (1.0 / 2.0) * SQRT3, .y = -1.0 / 2.0 + (-1.0 / 2.0) * SQRT3 },
        .{ .x = 1.0 + (1.0 / 2.0) * SQRT3, .y = -1.0 / 2.0 },
        .{ .x = 1.0 + (1.0 / 2.0) * SQRT3, .y = 1.0 / 2.0 },
        .{ .x = 1.0 / 2.0 + (1.0 / 2.0) * SQRT3, .y = 1.0 / 2.0 + (1.0 / 2.0) * SQRT3 },
        .{ .x = 1.0 / 2.0, .y = 1.0 + (1.0 / 2.0) * SQRT3 },
    };

    const truncated_trihexagonal_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = 1.0 / 2.0, .y = 1.0 / 2.0 },
        .{ .x = -1.0 / 2.0, .y = 1.0 / 2.0 },
        .{ .x = -1.0 / 2.0, .y = -1.0 / 2.0 },
        .{ .x = 1.0 / 2.0, .y = -1.0 / 2.0 },
        .{ .x = 1.0 / 2.0, .y = 1.0 / 2.0 },
    };

    const truncated_trihexagonal_c_coords = [_]Vec2{ // TYPE_C
        .{ .x = -1.0 / 4.0 + (1.0 / 4.0) * SQRT3, .y = 1.0 / 4.0 + (1.0 / 4.0) * SQRT3 },
        .{ .x = -1.0 / 4.0 + (-1.0 / 4.0) * SQRT3, .y = -1.0 / 4.0 + (1.0 / 4.0) * SQRT3 },
        .{ .x = 1.0 / 4.0 + (-1.0 / 4.0) * SQRT3, .y = -1.0 / 4.0 + (-1.0 / 4.0) * SQRT3 },
        .{ .x = 1.0 / 4.0 + (1.0 / 4.0) * SQRT3, .y = 1.0 / 4.0 + (-1.0 / 4.0) * SQRT3 },
        .{ .x = -1.0 / 4.0 + (1.0 / 4.0) * SQRT3, .y = 1.0 / 4.0 + (1.0 / 4.0) * SQRT3 },
    };

    const truncated_trihexagonal_d_coords = [_]Vec2{ // TYPE_D
        .{ .x = 1.0 / 2.0, .y = (1.0 / 2.0) * SQRT3 },
        .{ .x = -1.0 / 2.0, .y = (1.0 / 2.0) * SQRT3 },
        .{ .x = -1.0, .y = 0.0 },
        .{ .x = -1.0 / 2.0, .y = (-1.0 / 2.0) * SQRT3 },
        .{ .x = 1.0 / 2.0, .y = (-1.0 / 2.0) * SQRT3 },
        .{ .x = 1.0, .y = 0.0 },
        .{ .x = 1.0 / 2.0, .y = (1.0 / 2.0) * SQRT3 },
    };

    const truncated_trihexagonal_e_coords = [_]Vec2{ // TYPE_E
        .{ .x = 1.0 / 2.0, .y = (1.0 / 2.0) * SQRT3 },
        .{ .x = -1.0 / 2.0, .y = (1.0 / 2.0) * SQRT3 },
        .{ .x = -1.0, .y = 0.0 },
        .{ .x = -1.0 / 2.0, .y = (-1.0 / 2.0) * SQRT3 },
        .{ .x = 1.0 / 2.0, .y = (-1.0 / 2.0) * SQRT3 },
        .{ .x = 1.0, .y = 0.0 },
        .{ .x = 1.0 / 2.0, .y = (1.0 / 2.0) * SQRT3 },
    };

    const truncated_trihexagonal_f_coords = [_]Vec2{ // TYPE_F
        .{ .x = 1.0 / 4.0 + (-1.0 / 4.0) * SQRT3, .y = 1.0 / 4.0 + (1.0 / 4.0) * SQRT3 },
        .{ .x = -1.0 / 4.0 + (-1.0 / 4.0) * SQRT3, .y = 1.0 / 4.0 + (-1.0 / 4.0) * SQRT3 },
        .{ .x = -1.0 / 4.0 + (1.0 / 4.0) * SQRT3, .y = -1.0 / 4.0 + (-1.0 / 4.0) * SQRT3 },
        .{ .x = 1.0 / 4.0 + (1.0 / 4.0) * SQRT3, .y = -1.0 / 4.0 + (1.0 / 4.0) * SQRT3 },
        .{ .x = 1.0 / 4.0 + (-1.0 / 4.0) * SQRT3, .y = 1.0 / 4.0 + (1.0 / 4.0) * SQRT3 },
    };

    pub const truncated_trihexagonal_struct = Structure{
        .name = "Square, Hexagon & Dodecagon",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 6,
        .columns = 2,
        .width = 3.0 + SQRT3,
        .height = 3.0 + 3.0 * SQRT3,
        .xminadd = -3.0 / 8.0 + (-1.0 / 8.0) * SQRT3,
        .xmaxadd = 3.0 / 8.0 + (1.0 / 8.0) * SQRT3,
        .yminadd = -1.0 / 4.0 + (-1.0 / 4.0) * SQRT3,
        .ymaxadd = 1.0 / 4.0 + (1.0 / 4.0) * SQRT3,
        .center_points = &.{
            .{ .x = 0.0, .y = 0.0 },                                                           .{ .x = 3.0 / 2.0 + (1.0 / 2.0) * SQRT3, .y = 0.0 },
            .{ .x = -3.0 / 4.0 + (-1.0 / 4.0) * SQRT3, .y = 3.0 / 4.0 + (3.0 / 4.0) * SQRT3 }, .{ .x = 3.0 / 2.0 + (1.0 / 2.0) * SQRT3, .y = 1.0 / 2.0 + (1.0 / 2.0) * SQRT3 },
            .{ .x = 0.0, .y = 1.0 + SQRT3 },                                                   .{ .x = 3.0 / 4.0 + (1.0 / 4.0) * SQRT3, .y = 3.0 / 4.0 + (3.0 / 4.0) * SQRT3 },
            .{ .x = 0.0, .y = 3.0 / 2.0 + (3.0 / 2.0) * SQRT3 },                               .{ .x = 3.0 / 2.0 + (1.0 / 2.0) * SQRT3, .y = 3.0 / 2.0 + (3.0 / 2.0) * SQRT3 },
            .{ .x = 0.0, .y = 2.0 + 2.0 * SQRT3 },                                             .{ .x = 3.0 / 4.0 + (1.0 / 4.0) * SQRT3, .y = 9.0 / 4.0 + (9.0 / 4.0) * SQRT3 },
            .{ .x = -3.0 / 4.0 + (-1.0 / 4.0) * SQRT3, .y = 9.0 / 4.0 + (9.0 / 4.0) * SQRT3 }, .{ .x = 3.0 / 2.0 + (1.0 / 2.0) * SQRT3, .y = 5.0 / 2.0 + (5.0 / 2.0) * SQRT3 },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,
            TYPE_C, TYPE_D,
            TYPE_E, TYPE_F,
            TYPE_B, TYPE_A,
            TYPE_D, TYPE_C,
            TYPE_F, TYPE_E,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(0, 2, &truncated_trihexagonal_a_coords, 0, 0, 0),
                nb(0, 1, &truncated_trihexagonal_a_coords, 1, 0, 0),
                nb(-1, 1, &truncated_trihexagonal_a_coords, 2, 0, 0),
                nb(-1, 0, &truncated_trihexagonal_a_coords, 3, 0, 0),
                nb(-1, -1, &truncated_trihexagonal_a_coords, 4, 0, 0),
                nb(0, -1, &truncated_trihexagonal_a_coords, 5, 0, 0),
                nb(0, -2, &truncated_trihexagonal_a_coords, 6, 0, 0),
                nb(1, -2, &truncated_trihexagonal_a_coords, 7, 0, 0),
                nb(1, -1, &truncated_trihexagonal_a_coords, 8, 0, 0),
                nb(1, 0, &truncated_trihexagonal_a_coords, 9, 0, 0),
                nb(1, 1, &truncated_trihexagonal_a_coords, 10, 0, 0),
                nb(1, 2, &truncated_trihexagonal_a_coords, 11, 0, 0),
            },
            &.{ // TYPE_B
                nb(0, 1, &truncated_trihexagonal_b_coords, 0, 0, 0),
                nb(-1, 0, &truncated_trihexagonal_b_coords, 1, 0, 0),
                nb(0, -1, &truncated_trihexagonal_b_coords, 2, 0, 0),
                nb(1, 0, &truncated_trihexagonal_b_coords, 3, 0, 0),
            },
            &.{ // TYPE_C
                nb(-1, 2, &truncated_trihexagonal_c_coords, 0, 0, 0),
                nb(-1, 0, &truncated_trihexagonal_c_coords, 1, 0, 0),
                nb(0, -1, &truncated_trihexagonal_c_coords, 2, 0, 0),
                nb(0, 1, &truncated_trihexagonal_c_coords, 3, 0, 0),
            },
            &.{ // TYPE_D
                nb(0, 2, &truncated_trihexagonal_d_coords, 0, 0, 0),
                nb(0, 1, &truncated_trihexagonal_d_coords, 1, 0, 0),
                nb(-1, -1, &truncated_trihexagonal_d_coords, 2, 0, 0),
                nb(0, -1, &truncated_trihexagonal_d_coords, 3, 0, 0),
                nb(1, -1, &truncated_trihexagonal_d_coords, 4, 0, 0),
                nb(1, 0, &truncated_trihexagonal_d_coords, 5, 0, 0),
            },
            &.{ // TYPE_E
                nb(0, 1, &truncated_trihexagonal_e_coords, 0, 0, 0),
                nb(-1, 1, &truncated_trihexagonal_e_coords, 1, 0, 0),
                nb(0, -1, &truncated_trihexagonal_e_coords, 2, 0, 0),
                nb(0, -2, &truncated_trihexagonal_e_coords, 3, 0, 0),
                nb(1, 0, &truncated_trihexagonal_e_coords, 4, 0, 0),
                nb(1, 1, &truncated_trihexagonal_e_coords, 5, 0, 0),
            },
            &.{ // TYPE_F
                nb(-1, 0, &truncated_trihexagonal_f_coords, 0, 0, 0),
                nb(-1, -2, &truncated_trihexagonal_f_coords, 1, 0, 0),
                nb(0, -1, &truncated_trihexagonal_f_coords, 2, 0, 0),
                nb(0, 1, &truncated_trihexagonal_f_coords, 3, 0, 0),
            },
        },
    };
};

// ---------------------------------------------------------------------------
// floret pentagonal structure (dual of the snub hexagonal tiling 3.3.3.3.6)
// generated by tools/gen_periodic.zig floret

const FloretPentagonal = struct {
    const SQRT7: f64 = @sqrt(7.0);
    const SQRT21: f64 = @sqrt(21.0);

    const floret_a_coords = [_]Vec2{ // TYPE_A
        .{ .x = (-1.0 / 7.0) * SQRT7, .y = (2.0 / 21.0) * SQRT21 },
        .{ .x = (-3.0 / 14.0) * SQRT7, .y = (-1.0 / 42.0) * SQRT21 },
        .{ .x = (-1.0 / 14.0) * SQRT7, .y = (-5.0 / 42.0) * SQRT21 },
        .{ .x = (1.0 / 7.0) * SQRT7, .y = (-2.0 / 21.0) * SQRT21 },
        .{ .x = (2.0 / 7.0) * SQRT7, .y = (1.0 / 7.0) * SQRT21 },
        .{ .x = (-1.0 / 7.0) * SQRT7, .y = (2.0 / 21.0) * SQRT21 },
    };

    const floret_b_coords = [_]Vec2{ // TYPE_B
        .{ .x = (-1.0 / 14.0) * SQRT7, .y = (3.0 / 14.0) * SQRT21 },
        .{ .x = (-3.0 / 14.0) * SQRT7, .y = (-1.0 / 42.0) * SQRT21 },
        .{ .x = (-1.0 / 14.0) * SQRT7, .y = (-5.0 / 42.0) * SQRT21 },
        .{ .x = (1.0 / 7.0) * SQRT7, .y = (-2.0 / 21.0) * SQRT21 },
        .{ .x = (3.0 / 14.0) * SQRT7, .y = (1.0 / 42.0) * SQRT21 },
        .{ .x = (-1.0 / 14.0) * SQRT7, .y = (3.0 / 14.0) * SQRT21 },
    };

    const floret_c_coords = [_]Vec2{ // TYPE_C
        .{ .x = (1.0 / 14.0) * SQRT7, .y = (5.0 / 42.0) * SQRT21 },
        .{ .x = (-1.0 / 7.0) * SQRT7, .y = (2.0 / 21.0) * SQRT21 },
        .{ .x = (-3.0 / 14.0) * SQRT7, .y = (-1.0 / 42.0) * SQRT21 },
        .{ .x = (-1.0 / 14.0) * SQRT7, .y = (-5.0 / 42.0) * SQRT21 },
        .{ .x = (5.0 / 14.0) * SQRT7, .y = (-1.0 / 14.0) * SQRT21 },
        .{ .x = (1.0 / 14.0) * SQRT7, .y = (5.0 / 42.0) * SQRT21 },
    };

    const floret_d_coords = [_]Vec2{ // TYPE_D
        .{ .x = (1.0 / 14.0) * SQRT7, .y = (5.0 / 42.0) * SQRT21 },
        .{ .x = (-5.0 / 14.0) * SQRT7, .y = (1.0 / 14.0) * SQRT21 },
        .{ .x = (-1.0 / 14.0) * SQRT7, .y = (-5.0 / 42.0) * SQRT21 },
        .{ .x = (1.0 / 7.0) * SQRT7, .y = (-2.0 / 21.0) * SQRT21 },
        .{ .x = (3.0 / 14.0) * SQRT7, .y = (1.0 / 42.0) * SQRT21 },
        .{ .x = (1.0 / 14.0) * SQRT7, .y = (5.0 / 42.0) * SQRT21 },
    };

    const floret_e_coords = [_]Vec2{ // TYPE_E
        .{ .x = (1.0 / 14.0) * SQRT7, .y = (5.0 / 42.0) * SQRT21 },
        .{ .x = (-1.0 / 7.0) * SQRT7, .y = (2.0 / 21.0) * SQRT21 },
        .{ .x = (-3.0 / 14.0) * SQRT7, .y = (-1.0 / 42.0) * SQRT21 },
        .{ .x = (1.0 / 14.0) * SQRT7, .y = (-3.0 / 14.0) * SQRT21 },
        .{ .x = (3.0 / 14.0) * SQRT7, .y = (1.0 / 42.0) * SQRT21 },
        .{ .x = (1.0 / 14.0) * SQRT7, .y = (5.0 / 42.0) * SQRT21 },
    };

    const floret_f_coords = [_]Vec2{ // TYPE_F
        .{ .x = (1.0 / 14.0) * SQRT7, .y = (5.0 / 42.0) * SQRT21 },
        .{ .x = (-1.0 / 7.0) * SQRT7, .y = (2.0 / 21.0) * SQRT21 },
        .{ .x = (-2.0 / 7.0) * SQRT7, .y = (-1.0 / 7.0) * SQRT21 },
        .{ .x = (1.0 / 7.0) * SQRT7, .y = (-2.0 / 21.0) * SQRT21 },
        .{ .x = (3.0 / 14.0) * SQRT7, .y = (1.0 / 42.0) * SQRT21 },
        .{ .x = (1.0 / 14.0) * SQRT7, .y = (5.0 / 42.0) * SQRT21 },
    };

    pub const floret_struct = Structure{
        .name = "Floret Pentagonal",
        .kind = "Periodic",
        .construct = .periodic,
        .features = STRUCTURE_TILEABLE,
        .rows = 6,
        .columns = 2,
        .width = SQRT7,
        .height = SQRT21,
        .xminadd = (-1.0 / 14.0) * SQRT7,
        .xmaxadd = (1.0 / 14.0) * SQRT7,
        .yminadd = (-1.0 / 28.0) * SQRT21,
        .ymaxadd = (1.0 / 28.0) * SQRT21,
        .center_points = &.{
            .{ .x = (-2.0 / 7.0) * SQRT7, .y = (-1.0 / 7.0) * SQRT21 },  .{ .x = (1.0 / 14.0) * SQRT7, .y = (-3.0 / 14.0) * SQRT21 },
            .{ .x = (-5.0 / 14.0) * SQRT7, .y = (1.0 / 14.0) * SQRT21 }, .{ .x = (5.0 / 14.0) * SQRT7, .y = (-1.0 / 14.0) * SQRT21 },
            .{ .x = (-1.0 / 14.0) * SQRT7, .y = (3.0 / 14.0) * SQRT21 }, .{ .x = (2.0 / 7.0) * SQRT7, .y = (1.0 / 7.0) * SQRT21 },
            .{ .x = (-3.0 / 7.0) * SQRT7, .y = (2.0 / 7.0) * SQRT21 },   .{ .x = (3.0 / 14.0) * SQRT7, .y = (5.0 / 14.0) * SQRT21 },
            .{ .x = (-1.0 / 7.0) * SQRT7, .y = (3.0 / 7.0) * SQRT21 },   .{ .x = (1.0 / 7.0) * SQRT7, .y = (4.0 / 7.0) * SQRT21 },
            .{ .x = (-3.0 / 14.0) * SQRT7, .y = (9.0 / 14.0) * SQRT21 }, .{ .x = (3.0 / 7.0) * SQRT7, .y = (5.0 / 7.0) * SQRT21 },
        },
        .cell_types = &.{
            TYPE_A, TYPE_B,
            TYPE_C, TYPE_D,
            TYPE_E, TYPE_F,
            TYPE_B, TYPE_A,
            TYPE_D, TYPE_C,
            TYPE_F, TYPE_E,
        },
        .neighbours = &.{
            &.{ // TYPE_A
                nb(-1, 1, &floret_a_coords, 0, 0, 0),
                nb(-1, -1, &floret_a_coords, 1, 0, 0),
                nb(0, -1, &floret_a_coords, 2, 0, 0),
                nb(1, 0, &floret_a_coords, 3, 0, 0),
                nb(0, 1, &floret_a_coords, 4, 0, 0),
            },
            &.{ // TYPE_B
                nb(-1, 0, &floret_b_coords, 0, 0, 0),
                nb(-1, -1, &floret_b_coords, 1, 0, 0),
                nb(0, -2, &floret_b_coords, 2, 0, 0),
                nb(0, -1, &floret_b_coords, 3, 0, 0),
                nb(0, 1, &floret_b_coords, 4, 0, 0),
            },
            &.{ // TYPE_C
                nb(0, 2, &floret_c_coords, 0, 0, 0),
                nb(-1, 1, &floret_c_coords, 1, 0, 0),
                nb(-1, 0, &floret_c_coords, 2, 0, 0),
                nb(0, -1, &floret_c_coords, 3, 0, 0),
                nb(0, 1, &floret_c_coords, 4, 0, 0),
            },
            &.{ // TYPE_D
                nb(0, 1, &floret_d_coords, 0, 0, 0),
                nb(0, -1, &floret_d_coords, 1, 0, 0),
                nb(0, -2, &floret_d_coords, 2, 0, 0),
                nb(1, -1, &floret_d_coords, 3, 0, 0),
                nb(1, 0, &floret_d_coords, 4, 0, 0),
            },
            &.{ // TYPE_E
                nb(0, 2, &floret_e_coords, 0, 0, 0),
                nb(0, 1, &floret_e_coords, 1, 0, 0),
                nb(0, -1, &floret_e_coords, 2, 0, 0),
                nb(1, 0, &floret_e_coords, 3, 0, 0),
                nb(1, 1, &floret_e_coords, 4, 0, 0),
            },
            &.{ // TYPE_F
                nb(0, 1, &floret_f_coords, 0, 0, 0),
                nb(-1, 0, &floret_f_coords, 1, 0, 0),
                nb(0, -1, &floret_f_coords, 2, 0, 0),
                nb(1, -1, &floret_f_coords, 3, 0, 0),
                nb(1, 1, &floret_f_coords, 4, 0, 0),
            },
        },
    };
};

// ---------------------------------------------------------------------------
// penrose structure (aperiodic, see penrose.zig)

const Penrose = struct {
    pub const penrose_struct = Structure{
        .name = "Penrose (Kites & Darts)",
        .kind = "Aperiodic",
        .construct = .penrose,
        .features = 0,
    };

    pub const penrose_rhombs_struct = Structure{
        .name = "Penrose (Rhombs)",
        .kind = "Aperiodic",
        .construct = .penrose_rhombs,
        .features = 0,
    };
};

// ---------------------------------------------------------------------------
// einstein structure (aperiodic monotile, see hat.zig)

const Einstein = struct {
    pub const einstein_struct = Structure{
        .name = "Einstein (Hat)",
        .kind = "Aperiodic",
        .construct = .einstein,
        .features = 0,
    };
};

// ---------------------------------------------------------------------------
// ammann-beenker structure (aperiodic squares and rhombi, see ammann.zig)

const AmmannBeenker = struct {
    pub const ammann_beenker_struct = Structure{
        .name = "Ammann-Beenker (Squares & Rhombi)",
        .kind = "Aperiodic",
        .construct = .ammann_beenker,
        .features = 0,
    };
};

// ---------------------------------------------------------------------------
// dual tiling of the substitution a -> ab, b -> c, c -> a (aperiodic
// parallelograms, see stepped.zig)

const Supergolden = struct {
    pub const supergolden_struct = Structure{
        .name = "Supergolden (Stepped Plane)",
        .kind = "Aperiodic",
        .construct = .supergolden,
        .features = 0,
    };
};

// ---------------------------------------------------------------------------
// 12-fold shield and wheel tilings (see shield.zig)

const Shield = struct {
    pub const shield_struct = Structure{
        .name = "Shield (Triangles, Squares & Shields)",
        .kind = "Aperiodic",
        .construct = .shield,
        .features = 0,
    };
    pub const wheel_struct = Structure{
        .name = "Wheel (Pentagons & 12-gons)",
        .kind = "Aperiodic",
        .construct = .wheel,
        .features = 0,
    };
};

// ---------------------------------------------------------------------------
// 12-fold Socolar tiling (see socolar.zig)

const Socolar = struct {
    pub const socolar_struct = Structure{
        .name = "Socolar (Hexagons, Squares & Rhombi)",
        .kind = "Aperiodic",
        .construct = .socolar,
        .features = 0,
    };
};

// ---------------------------------------------------------------------------
// 10-fold clamshell tiling (see clamshell.zig)

const Clamshell = struct {
    pub const clamshell_struct = Structure{
        .name = "Clamshell (Trapezoids & Clamshells)",
        .kind = "Aperiodic",
        .construct = .clamshell,
        .features = 0,
    };
};

// ---------------------------------------------------------------------------

/// All structures in the order of the original `maze_structs` table.
pub const all = [_]*const Structure{ &Orthogonal.ortho_struct, &Orthogonal.ortho2_struct, &Triangle.tria_struct, &Hexagon.hexa_struct, &Hexagon.hexa2_struct, &Hexagon.hexa3_struct, &HexagonSquare.hexa_square_struct, &HexagonSquare.hexa_square2_struct, &Cairo.cairo_struct, &Cairo.cairo2_struct, &OctagonSquare.octa_square_struct, &OctagonSquare2.octa_square2_struct, &OctagonSquare.octa_square3_struct, &OctagonSquare2.octa_square4_struct, &Rhombic.rhombic_struct, &Rhombic.rhombic2_struct, &Rhombic.rhombic3_struct, &HexagonRhombic.hexa_rhombic_struct, &TriangleSquare.triangle_square_struct, &TriangleSquare.triangle_square2_struct, &PentagonHouse.pentagon_house_struct, &PentagonHouse2.pentagon_house2_struct, &PentagonType1.pentagon_1_struct, &PentagonType1Cm.pentagon_1_cm_struct, &PentagonType2.pentagon_2_struct, &PentagonType2EdgeToEdge.pentagon_2e_struct, &PentagonType10.pentagon_10_struct, &Pentagon3.pentagon_3_struct, &HexagonSquareTriangle.hexa_ortho_tria_struct, &HexagonSquareTriangle.hexa_ortho_tria2_struct, &TruncatedTrihexagonal.truncated_trihexagonal_struct, &FloretPentagonal.floret_struct, &Theta.theta_struct, &PentagonRotational.pentagon_rotational_struct, &Voronoi.random_struct, &Voronoi.random4_struct, &Voronoi.random6_struct, &Voronoi.random3_struct, &Voronoi.random_disc_struct, &Penrose.penrose_struct, &Penrose.penrose_rhombs_struct, &Einstein.einstein_struct, &AmmannBeenker.ammann_beenker_struct, &Supergolden.supergolden_struct, &Shield.shield_struct, &Shield.wheel_struct, &Socolar.socolar_struct, &Clamshell.clamshell_struct };

pub const ortho = [_]*const Structure{ &Orthogonal.ortho_struct, &Orthogonal.ortho2_struct };
pub const tria = [_]*const Structure{&Triangle.tria_struct};
pub const hexa = [_]*const Structure{ &Hexagon.hexa_struct, &Hexagon.hexa2_struct, &Hexagon.hexa3_struct };
pub const hexa_square = [_]*const Structure{ &HexagonSquare.hexa_square_struct, &HexagonSquare.hexa_square2_struct };
pub const cairo = [_]*const Structure{ &Cairo.cairo_struct, &Cairo.cairo2_struct };
pub const octa_square = [_]*const Structure{ &OctagonSquare.octa_square_struct, &OctagonSquare2.octa_square2_struct, &OctagonSquare.octa_square3_struct, &OctagonSquare2.octa_square4_struct };
pub const rhombic = [_]*const Structure{ &Rhombic.rhombic_struct, &Rhombic.rhombic2_struct, &Rhombic.rhombic3_struct };
pub const hexa_rhombic = [_]*const Structure{&HexagonRhombic.hexa_rhombic_struct};
pub const triangle_square = [_]*const Structure{ &TriangleSquare.triangle_square_struct, &TriangleSquare.triangle_square2_struct };
pub const pentagon_house = [_]*const Structure{ &PentagonHouse.pentagon_house_struct, &PentagonHouse2.pentagon_house2_struct };
pub const pentagon_1 = [_]*const Structure{ &PentagonType1.pentagon_1_struct, &PentagonType1Cm.pentagon_1_cm_struct };
pub const pentagon_2 = [_]*const Structure{ &PentagonType2.pentagon_2_struct, &PentagonType2EdgeToEdge.pentagon_2e_struct };
pub const pentagon_3 = [_]*const Structure{&Pentagon3.pentagon_3_struct};
pub const pentagon_10 = [_]*const Structure{&PentagonType10.pentagon_10_struct};
pub const hexa_ortho_tria = [_]*const Structure{ &HexagonSquareTriangle.hexa_ortho_tria_struct, &HexagonSquareTriangle.hexa_ortho_tria2_struct };
pub const truncated_trihexagonal = [_]*const Structure{&TruncatedTrihexagonal.truncated_trihexagonal_struct};
pub const floret = [_]*const Structure{&FloretPentagonal.floret_struct};
pub const theta = [_]*const Structure{&Theta.theta_struct};
pub const pentagon_rotational = [_]*const Structure{&PentagonRotational.pentagon_rotational_struct};
pub const random = [_]*const Structure{&Voronoi.random_struct};
pub const random4 = [_]*const Structure{&Voronoi.random4_struct};
pub const random6 = [_]*const Structure{&Voronoi.random6_struct};
pub const random3 = [_]*const Structure{&Voronoi.random3_struct};
pub const random_disc = [_]*const Structure{&Voronoi.random_disc_struct};
pub const penrose = [_]*const Structure{ &Penrose.penrose_struct, &Penrose.penrose_rhombs_struct };
pub const einstein = [_]*const Structure{&Einstein.einstein_struct};
pub const ammann_beenker = [_]*const Structure{&AmmannBeenker.ammann_beenker_struct};
pub const supergolden = [_]*const Structure{&Supergolden.supergolden_struct};
pub const shield = [_]*const Structure{&Shield.shield_struct};
pub const wheel = [_]*const Structure{&Shield.wheel_struct};
pub const socolar = [_]*const Structure{&Socolar.socolar_struct};
pub const clamshell = [_]*const Structure{&Clamshell.clamshell_struct};
