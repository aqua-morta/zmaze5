# maze5 (Zig)

A Zig rewrite and extended version of **maze5 0.9.0** by Bernd Breitenbach, a generator for mazes
of many styles (orthogonal, hexagonal, triangular, cairo, octagon-square,
theta/circular, Klaassen's pentagons with n-fold rotational symmetry, voronoi based, aperiodic Penrose kites and darts,
Ammann–Beenker squares and rhombi, the supergolden stepped plane, the 12-fold shield and Socolar tilings, the 10-fold clamshell tiling, the "einstein" hat monotile, …) that writes PDF, SVG or PNG files.

## Building

Requires Zig 0.17; the program only links libc, no other library.

```sh
zig build                          # debug build -> zig-out/bin/maze5
zig build -Doptimize=ReleaseFast   # optimised build
zig build test                     # unit and end-to-end tests
```

`zig build wasm` builds the generator as a WebAssembly module
(`zig-out/web/maze5.wasm`, ~320 kB, optimised for size; `-Dwasm-optimize=fast`
for speed) for use in a browser, see [WebAssembly](#webassembly).

All output is written by the program itself: SVG and PDF by
`src/vector.zig`, PNG images are drawn by the rasterizer in `src/raster.zig`
(anti-aliased, nonzero winding) and encoded by `src/png.zig`, which also
decodes the PNG masks (all PNG formats). Text uses the viewer's sans-serif
font in SVG, Helvetica in PDF and a built-in stroke font in PNG.

## Usage

```sh
maze5 -t 4 -r 20 -c 20 -o maze.png              # 20x20 orthogonal maze
maze5 -t 6 -r 30 -c 40 -C 15mm -S 1 -m mask.png -o maze.svg
maze5 -t theta -r 1-20 -c 7 -o maze.pdf         # theta maze, empty center
maze5 -t klaassen -r 2-12 -c 5 -o maze.pdf      # 5-fold pentagon rings, empty center
maze5 -t random-disc -r 20 -c 20 -O -P -o disc.png
maze5 -t penrose -r 20 -c 30 -P -o penrose.png  # kites and darts
maze5 -t einstein -r 20 -c 30 -o hat.png        # the hat monotile
maze5 -t ammann-beenker -r 20 -c 30 -o ab.png   # squares and 45° rhombi
maze5 -t penrose:2 -r 20 -c 30 -o p3.png        # Penrose rhombs
maze5 -t supergolden -r 20 -c 30 -o sg.png      # stepped plane of a->ab, b->c, c->a
maze5 -t shield -r 20 -c 30 -o shield.png       # 12-fold: triangles, squares, shields
maze5 -t wheel -r 20 -c 30 -o wheel.png         # derived from the shield tiling
maze5 -t socolar -r 20 -c 30 -o socolar.png     # 12-fold: hexagons, squares, rhombi
maze5 -t clamshell -r 20 -c 30 -o clamshell.png # 10-fold: trapezoids and clamshells
maze5 -t 12-6-4 -r 24 -c 12 -o sq-hex-dodec.png  # squares, hexagons, dodecagons
maze5 -t floret -r 24 -c 12 -o floret.png      # floret pentagons
maze5 -t 4 -r 20 -c 20 -W A:0,1,2,1 -o w.png    # weighted directions
maze5 -t 6 -r 20 -c 20 -a wilson -o wilson.png  # unbiased (uniform) maze
maze5 -t 6-4 -r 20 -c 20 -X B -o pillars.png    # squares become pillars
maze5 -t 12-6-4 -r 24 -c 12 --cave A -o cave.png # dodecagons: rooms, one entry
maze5 -t 6-4 -r 20 -c 20 --max-openings A:2/C:2 -o lim.png  # hexagons: <= 2 openings
maze5 -t orthogonal -r 4 --recursion 2 -o rec.png # 4x4 maze in every cell, twice: 64x64
maze5 -t orthogonal -r 5 --recursion 2 --recursion-opening random -o rec.png
maze5 -t orthogonal -r 4 --recursion 2 --recursion-orientation random -o rec.png
maze5 -t triangular -r 4 --recursion 2 -o rec.png # triangle of triangles of triangles
maze5 -t hexagonal -r 2 --recursion 3 -o rec.png  # 7 hexagons, 4 levels: a snowflake
maze5 --help
```

The random number generator is a re-implementation of glibc's `random()`
(`src/rng.zig`), so most seeds give the same maze as the original C program.
Exact compatibility is no longer a goal, though: the trigonometric functions
are Zig's own, whose results can differ in the last bit from glibc's, which
changes some theta and voronoi disc mazes. `tools/compare.sh C_BINARY`
compares the output with the original C binary for ~500 combinations of
types, algorithms and options and shows where they differ.

`zig build gen-periodic -- TILING` (or `zig run tools/gen_periodic.zig --
TILING`) prints the structure tables of the periodic tilings 4.6.12
(`12-6-4`), floret pentagonal (`floret`) and the pentagonal tilings of
type 1, 2 and 10 (`pentagonal_1:1`, `pentagonal_1:2`, `pentagonal_2:1`,
`pentagonal_2:2`, `pentagonal_10`) from their geometry, ready to be pasted into
`src/structures.zig`; it can be extended for further periodic tilings, also
ones that are not edge-to-edge.

`tools/patterns.sh [OUTDIR]` renders a square PNG thumbnail of the grid of
every maze type and subtype (dummy mode `-d`), e.g. for a website; size,
cell size, line width and colors can be set with the `SIZE`, `CELL`, `LINE`,
`FG` and `BG` environment variables (see the script). It needs ImageMagick.

## WebAssembly

`src/wasm.zig` is the root of the browser build: the same generator without
files or a command line. The host (JavaScript) passes the command line
arguments (without the program name, NUL separated) and optionally a PNG mask
image; the rendered document (PNG, SVG or PDF as chosen with `-f`) stays in
the module's memory until the next call. Messages that the program would
print to stderr are collected in a log, and the effective parameters
(including a time based seed, which the host supplies) are available as JSON
like `--save` writes it.

```js
const { instance } = await WebAssembly.instantiate(bytes, {});
const m = instance.exports;
const args = new TextEncoder().encode(['-t', '6:2', '-r', '20', '-c', '20', '-f', 'svg'].join('\0'));
const ptr = m.maze5_alloc(args.length);
new Uint8Array(m.memory.buffer).set(args, ptr);
const status = m.maze5_run(ptr, args.length, 0, 0, Date.now() & 0x7fffffff); // 0 ok, 1 bad arguments, 2 failed, 3 out of memory
m.maze5_free(ptr, args.length);
const svg = new Uint8Array(m.memory.buffer).slice(m.maze5_result_ptr(), m.maze5_result_ptr() + m.maze5_result_len());
const log = new TextDecoder().decode(new Uint8Array(m.memory.buffer, m.maze5_log_ptr(), m.maze5_log_len()));
```

`maze5_types()` puts a JSON description of all maze types (specification,
names, features, cell types) into the result, `maze5_version()` the version.
A panic traps; its message can be read with `maze5_panic_ptr/len`. 

## Source layout

| file                    | contents                                              |
|-------------------------|-------------------------------------------------------|
| `src/main.zig`          | command line program: files, `--load`/`--save`, `--stats` |
| `src/app.zig`           | options, parameter conversion, construction, carving, rendering into memory |
| `src/wasm.zig`          | WebAssembly module (exports for the browser)          |
| `src/maze.zig`          | cells, walls, maze; periodic (tile based) mazes       |
| `src/structure.zig`     | tile structure type, type name lookup                 |
| `src/structures.zig`    | tile tables (translated from `structure.c`)           |
| `src/theta.zig`         | circular mazes                                        |
| `src/rotational.zig`    | Klaassen's n-fold rotational pentagonal tilings       |
| `src/voronoi.zig`       | voronoi mazes (Fortune's algorithm, clipping)         |
| `src/penrose.zig`       | Penrose kites & darts (deflation) and rhombs          |
| `src/hat.zig`           | aperiodic "einstein" hat mazes (metatiles)            |
| `src/ammann.zig`        | aperiodic Ammann–Beenker mazes                        |
| `src/multigrid.zig`     | de Bruijn's multigrid method (rhombi; hexagons at triple points) |
| `src/stepped.zig`       | supergolden stepped plane (dual substitution tiling)  |
| `src/shield.zig`        | 12-fold shield tiling (cut and project) and wheel     |
| `src/socolar.zig`       | 12-fold Socolar tiling (degenerate 6-grid, dual method) |
| `src/clamshell.zig`     | 10-fold clamshell tiling (substitution)               |
| `src/pillars.zig`       | `--pillars`/`--cave`/`--max-openings`: cell types     |
| `src/recursive.zig`     | `--recursion`: mazes made of copies of a small maze   |
| `src/tiling.zig`        | maze construction from arbitrary polygon tiles        |
| `src/carve.zig`         | backtracker, Prim, growing tree, Wilson, crossovers, opening limits |
| `src/render.zig`        | maze → strokes (walls, organic style, solution, text) |
| `src/output.zig`        | drawing on a canvas, PDF/SVG/PNG output               |
| `src/vector.zig`        | SVG and PDF writer                                    |
| `src/raster.zig`        | rasterizer for PNG output, stroke font                |
| `src/png.zig`           | PNG encoder and decoder (output, masks)               |
| `src/mask.zig`          | PNG masks (read with `src/png.zig`)                   |
| `src/params.zig`        | `--save`/`--load` parameter files (JSON)              |
| `src/rng.zig`           | glibc compatible `random()`                           |
| `src/geo.zig`           | 2D vector math                                        |

## Differences to the C version

* Bug fixes: `-d` works as short form of `--dummy`; `-D` without a level
  works; `--text` actually draws the letters (the original put cairo into an
  error state); the mask's y axis is scaled with the maze height; reading a
  mask pixel at the right/bottom edge no longer reads out of bounds; PNG
  masks of any format (e.g. grayscale) are accepted.
* Crossovers (`--crossings`) no longer break the maze: crossovers whose
  bridges would form a ring with other bridges (a loop no carving can
  avoid) are not built, and Prim's algorithm chooses its start cell after
  building the crossovers (the start could become a crossover, leaving parts
  of the maze unreachable). Mazes with crossovers therefore differ from the
  original, and very high densities are reached less often (a warning says
  how many crossovers were built).
* Bridges of crossovers work with a transparent background (`-B transparent`
  or an `rgba(…)` with alpha below 1): instead of being painted over with the
  background color, the walls and pillars below a bridge are cut out (SVG
  mask, PDF soft mask). Mazes with an opaque background are drawn as before.
* New algorithm `-a wilson` (Wilson's loop-erased random walks): every
  perfect maze of the grid is equally likely, so it has no bias towards long
  corridors (backtracker) or short dead ends (Prim). It works on all maze
  types and with crossovers. With `-W` the walks follow the weights; a walk
  that hasn't reached the maze after about 20·√cells steps continues
  unweighted, since walks against a strong bias would take very long.
* New option `-X/--pillars=TYPES` excludes cell types (the letters listed
  by `--help`) from the maze; the cells become filled pillars. The remaining
  cells must stay connected: pieces enclosed by pillars, or more than a few
  cells cut off at the border, are reported as an error, since then the
  tiling falls apart without these cell types (e.g. `-t 8-4 -X B`, squares
  without octagons). A few border cells cut off are turned into pillars.
  `--pillar-color=COLOR` sets their fill color (default: the maze color).
* New option `--cave=TYPES`: the cells of these types become rooms with a
  single entry. They are left out while carving (like pillars, so they
  never get the entrance or exit) and afterwards opened to one random
  neighbouring maze cell; as dead ends they keep the maze perfect.
* New option `--max-openings=T:N[/T:N...]` generalizes both: cells of type
  T get at most N openings (0: pillar, 1: cave). All carving algorithms
  respect the limits; cells left unconnected afterwards are attached by
  moving a passage of a full neighbour elsewhere, and if that fails the
  maze is carved again (up to 20 times) before an error is reported. Very
  tight limits can be impossible (e.g. `-t 8-4 --max-openings B:2`).
* New option `--recursion=LEVELS` (orthogonal, triangular and hexagonal
  mazes): a maze with `-r` cells along a side (a square, a triangle or a
  hexagon) is carved, then LEVELS times every cell is replaced by a copy
  of that maze; neighbouring copies are joined by one opening on their
  common side where the cell had a passage. The result is a perfect maze,
  for squares of `-r`^(LEVELS+1) cells per side. Downward triangles hold
  the copy upside down. Hexagons can't be divided into hexagons: every
  cell becomes a hexagon of hexagons, placed on the hexagonal lattice
  turned and scaled by the Eisenstein integer `-r` + (`-r`-1)·ω (these
  hexagons tile the plane), so the outline becomes snowflake like
  (`src/recursive.zig`). `--recursion-opening=POS` places
  the openings: `middle` (default), `random`, `first`, `last` or the cell
  number 1..`-r` (from the left of horizontal, the top of vertical sides).
  `--recursion-orientation=MODE` turns the copies: `same` (default),
  `rotate` (a random multiple of 90° for every copy), `random` (any of
  the eight rotations and reflections of the square for every copy),
  `sector` (towards the side of the sector between the diagonals the copy
  lies in) or `spiral` (towards the side a spiral through the cells
  follows: from the lower left corner north, then clockwise inwards).
  Copies at the bottom keep the base maze's orientation, the others are
  turned so that their bottom faces their side.
* `-e`/`-x` with a side work: the original compared the cell's position
  with the one of the "outside" cell (whose coordinates are a huge
  constant), so `north` and `west` accepted any border cell and `south` and
  `east` none at all. Now the wall to the outside must face that side and lie
  at the outermost part of it.
* Parameters loaded with `--load` serve as defaults; options given on the
  command line override them (the original reported them as "multiple
  given"). `--load` without a file name reads `~/.maze5.last`.
* `--version` and `--help` print to stdout and exit with status 0; errors
  exit with status 1. `--stats` prints to stderr.
* An output file (`-o`, or `-o -` for stdout) is required.
* Deep recursions (carving, path search) use explicit stacks, so very large
  mazes don't overflow the stack.
* The GIMP plugin (`gimp.c`) is not part of the rewrite.
