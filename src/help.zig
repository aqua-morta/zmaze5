//! Help and version texts.

pub const copyright =
    \\Copyright (C) 2006,2007,2011,2013,2015 Bernd Breitenbach
    \\This is free software.  You may redistribute copies of it under the terms of
    \\the GNU General Public License <http://www.gnu.org/licenses/gpl.html>.
    \\There is NO WARRANTY, to the extent permitted by law.
    \\
    \\Written by Bernd Breitenbach.
    \\
;

/// `{s}` is replaced by the program name.
pub const text =
    \\usage: {s} [OPTIONS] -r ROWS -c COLUMNS -o FILE
    \\
    \\-t,--type=TYPE             generate a maze of the given type
    \\    for some of the types you can specify a subtype by adding a colon ':'
    \\    followed by a number denoting the subtype (1 means the default type);
    \\    the following values are valid; the brackets list the cell types of
    \\    the maze type (cells with different neighbourhoods, e.g. hexagons and
    \\    squares) with their number of neighbours in parentheses; for subtypes
    \\    with differing cell types they are given per subtype (e.g. '2: A(4),B(4)'):
    \\    '3','triangular'        - a triangle based maze
    \\                              [A(3),B(3)]
    \\    '4','orthogonal'        - an orthogonal maze (subtypes: 1-2)
    \\                              [1: A(4); 2: A(4),B(4)]
    \\    '6','hexagonal','sigma' - a hexagonal maze (subtypes:1-3)
    \\                              [A(6),B(6)]
    \\    '3-4','triangle-square' - a maze made of triangles and squares (subtypes:1-2)
    \\                              [A(3),B(3),C(4),D(4),E(3),F(3)]
    \\    '6-4','hexagon-square'  - a maze made of hexagons and squares (subtypes:1-2)
    \\                              [A(6),B(4),C(6)]
    \\    '8-4','octagon-square'  - a maze made of octagons and squares (subtypes:1-4)
    \\                              [A(4),B(8)]
    \\    'rhombic','zeta'        - a rhombus based maze (subtypes:1-3)
    \\                              [1: A(4); 2: A(4),B(4); 3: A(4)]
    \\    'cairo'                 - a cairo-tiling based maze (subtypes:1-2)
    \\                              [A(5),B(5),C(5),D(5),E(5),F(5),G(5),H(5)]
    \\    'hexagonal-rhombic'     - a maze based on rhombic divided hexagons
    \\                              [A(4),B(4),C(4)]
    \\    'house'                 - a maze based on pentagonal house tiles (subtypes:1-2)
    \\                              [1: A(5),B(5),C(5),D(5); 2: A(5),B(5),C(5),D(5),E(5),F(5),G(5),H(5)]
    \\    '5_1','pentagonal_1'    - a maze based on pentagonal tiles of type 1, 1: p2 (not edge-to-edge), 2: cm (subtypes:1-2)
    \\                              [1: A(6),B(6); 2: A(5),B(5)]
    \\    '5_2','pentagonal_2'    - a maze based on pentagonal tiles of type 2, 1: not edge-to-edge, 2: edge-to-edge (subtypes:1-2)
    \\                              [1: A(6),B(6),C(6),D(6); 2: A(5),B(5),C(5),D(5)]
    \\    '5_3','pentagonal_3'    - a maze based on pentagonal tiles
    \\                              [A(6),B(6),C(6),D(6),E(6),F(6)]
    \\    '5_10','pentagonal_10'  - a maze based on pentagonal tiles of type 10 (squares with a cut corner)
    \\                              [A(5),B(7),C(5),D(5),E(7),F(5)]
    \\    '6-4-3'                 - a maze made of hexagons, squares and triangles (subtypes:1-2)
    \\                              [A(6),B(4),C(3),D(4),E(4),F(3)]
    \\    '12-6-4','square-hexagon-dodecagon' - a maze made of squares, hexagons and dodecagons
    \\                              [A(12),B(4),C(4),D(6),E(6),F(4)]
    \\    'floret','floret-pentagonal' - a maze based on floret pentagons
    \\                              [A(5),B(5),C(5),D(5),E(5),F(5)]
    \\    'theta'                 - a maze made of concentric rings
    \\                              for this type you can specify the first and the last
    \\                              ring with the '-r' option e.g. '-r 2-12' and the
    \\                              the number of inner segments (3-8) with the '-c' option
    \\    'pentagonal-rotational','klaassen' - a maze made of rings of congruent pentagons with
    \\                              n-fold rotational symmetry (Klaassen's tiling); '-r' gives the
    \\                              rings as for 'theta' (e.g. '-r 2-12'), '-c' the symmetry n (3-8)
    \\                              [A(5-7),B(5-6)] A: pentagon pointing outwards, B: inwards
    \\    'random'                - a maze based on random voronoi cells
    \\    'random-4'              - a maze based on square voronoi cells; the distortion can be controlled with -j
    \\    'random-6'              - a maze based on hexagonal voronoi cells; the distortion can be controlled with -j
    \\    'random-3'              - a maze based on triangular voronoi cells; the distortion can be controlled with -j
    \\    'random-disc'           - a maze based on voronoi cells forming a disc; the distortion can be controlled with -j
    \\    'penrose','kite-dart'   - an aperiodic maze made of Penrose kites and darts or,
    \\                              as subtype 2, thick and thin Penrose rhombs (subtypes:1-2)
    \\                              [1: A(4),B(4) A: kite, B: dart; 2: A(4),B(4) A: thick, B: thin rhomb]
    \\    'einstein','hat'        - an aperiodic maze made of a single tile, the "hat"
    \\                              [A(5-6),B(4)] A: hat, B: mirrored hat
    \\    'ammann-beenker','ammann' - an aperiodic maze made of squares and rhombi (Ammann-Beenker tiling)
    \\                              [A(4),B(4)] A: square, B: rhombus
    \\    'supergolden','stepped-plane' - an aperiodic maze made of three parallelograms: the dual
    \\                              of the substitution a->ab, b->c, c->a (a "stepped plane")
    \\                              [A(4),B(4),C(4)] A: large, B: small, C: medium parallelogram
    \\    'shield'                - an aperiodic maze with 12-fold symmetry (Gaehler's shield tiling)
    \\                              [A(3),B(4),C(6)] A: triangle, B: square, C: shield
    \\    'wheel'                 - an aperiodic maze derived from the shield tiling (similar to
    \\                              Nissen's wheel tiling)
    \\                              [A(5),B(12)] A: pentagon, B: three-armed 12-gon
    \\    'socolar','butterfly'   - an aperiodic maze with 12-fold symmetry (Socolar's tiling)
    \\                              [A(6),B(4),C(4)] A: hexagon, B: square, C: 30 degree rhombus
    \\    'clamshell'             - an aperiodic maze with 10-fold symmetry (Socolar's clamshell tiling)
    \\                              [A(4),B(4),C(4)] A, B: trapezoid (two kinds), C: clamshell
    \\
    \\-c, --columns=NUMBER       generate the maze with the specified no of columns
    \\-r, --rows=NUMBER          generate the maze with the specified
    \\    number of rows or rings if a theta maze is generated
    \\-o, --output=FILE          output file name; use - for stdout
    \\-f, --format=FORMAT        the output format; if not specified
    \\    the extension of the file specified by -o is used; the following values are valid:
    \\    'pdf'   - pdf format
    \\    'svg'   - svg vector format
    \\    'png'   - png bitmap format
    \\-a, --algorithm=NAME       specifies the algorithm to be used;
    \\     the following values are valid:
    \\     'backtracker' - a recursive backtracker (default)
    \\     'prim' - prim's algorithm
    \\     'tree'[:[0..1]] - growing tree algorithm
    \\    The optional parameter determines the river factor of the maze (default: 0.5).
    \\    Values below are resulting in a maze
    \\    with a higher river factor. A value of 0 makes this
    \\    algorithm behave exactly like the backtracker.
    \\     'wilson' - Wilson's algorithm (loop-erased random walks); every
    \\    possible maze is equally likely. With direction weights (-W) the
    \\    walks follow the weights (weight 0: only if no other direction is
    \\    possible); walks that don't find the maze for long continue unweighted.
    \\--arcs=FACTOR|ANGLE        Angle factor for arcs. Default value if omitted is 1.
    \\    Values between -2. and 2 are treated as a factor the angle is multiplied with.
    \\    Values from 2 to 180 or -2 to -180 are treated as an absolute angle in degrees.
    \\--boundary=outside|keep|inside  If the maze has walls with arcs determines the
    \\    orientation of the boundary arcs. Whether they are always bowed to the outside,
    \\    to the inside or keep their orientation.
    \\--crossings=N              number of crossovers (bridges); values in [0,0.5] are
    \\    treated as a fraction of the number of cells, values >= 1 as absolute number
    \\-W, --weights=T:W1,W2,...[/T:...]  direction weights for the cell types T of the maze
    \\    type (see the cell types listed with --type): whenever a direction is chosen at
    \\    random while carving, the n-th wall of a cell of type T is chosen with a probability
    \\    proportional to Wn; walls with weight 0 are only chosen if no other direction is
    \\    possible; e.g. for '-t 4' the walls are in the order down, left, up, right,
    \\    so '-t 4 -W A:0,1,2,1' never goes down, goes up with probability 0.5 and
    \\    left and right with 0.25 each; several cell types are separated by '/'
    \\-X, --pillars=T[,T...]     exclude the cells of the cell types T (see the cell types
    \\    listed with --type) from the maze: they become solid pillars the paths go around,
    \\    e.g. '-t 6-4 -X B' (hexagons only, the squares are pillars). The remaining cells
    \\    must still form a connected maze, otherwise an error is reported; single cells at
    \\    the border cut off by pillars become pillars as well
    \\--cave=T[,T...]            the cells of the cell types T become rooms with a single
    \\    entry: dead ends opened to one neighbouring maze cell, e.g. '-t 12-6-4 --cave A'
    \\    (the dodecagons). The other cells must form a connected maze without them;
    \\    caves without a neighbouring maze cell become pillars
    \\--max-openings=T:N[/T:N...] cells of the cell type T get at most N openings (passages,
    \\    including the entrance and exit), e.g. '-t 6-4 --max-openings A:2/C:2'.
    \\    'T:0' is the same as '--pillars=T', 'T:1' the same as '--cave=T'. Tight limits
    \\    may make a maze impossible (e.g. 2 for every cell: a single path through all
    \\    cells); after some attempts an error is reported. Limited cells don't
    \\    become crossovers
    \\--recursion=LEVELS         recursive maze ('-t orthogonal', 'triangular', 'hexagonal'): a maze
    \\    with '-r' cells along a side (a square, a triangle or a hexagon) is carved, then
    \\    LEVELS times every cell is replaced by a copy of it, joined to the neighbouring
    \\    copies by one opening where the cell had a passage, e.g. '-r 4 --recursion 2'
    \\    gives 64 x 64 squares; '-c' is not needed. Downward triangles hold the copy upside
    \\    down. Hexagons are replaced by hexagons of hexagons, which makes the outline
    \\    snowflake like ('-t hexagonal -r 2 --recursion 3': 7 cells, 343 times).
    \\    The number of cells grows fast (n = '-r', L = LEVELS):
    \\      orthogonal, triangular: n^(2(L+1))     e.g. n=4, L=2: 4096; n=4, L=3: 65536
    \\      hexagonal: (3n^2-3n+1)^(L+1)           e.g. n=2, L=3: 2401; n=3, L=3: 130321
    \\--recursion-opening=POS    where the copies of a recursive maze are joined on their common
    \\    side: 'middle' (default), 'random', 'first', 'last' or the cell number 1..'-r'
    \\    (counted from the left of horizontal and from the top of vertical sides; for
    \\    hexagons up to 2*'-r'-1)
    \\--recursion-orientation=MODE how the copies of a recursive maze are turned: 'same' (default,
    \\    all alike), 'rotate' (a random multiple of 90 degrees for every copy), 'random'
    \\    (a random rotation or reflection for every copy), 'sector' (turned towards the
    \\    nearest side of the maze, the sectors are separated by the diagonals) or 'spiral'
    \\    (turned towards the side the spiral through the cells follows there; it starts at
    \\    the lower left going north and winds clockwise inwards; hexagon mazes use the
    \\    sides of the rings around the center); copies at the bottom keep the
    \\    orientation of the base maze
    \\-O, --organic              render maze in an organic smooth way
    \\-F, --foreground=COLOR     the maze color; either three (four) float values
    \\    R,G,B(,A) between 0. and 1., '#RRGGBB', '#RGB', 'rgba(r,g,b,a)' or 'transparent'
    \\-B, --background=COLOR     the background color (same formats as --foreground)
    \\--pillar-color=COLOR       the fill color of pillars (--pillars, --max-openings T:0);
    \\    default: the maze color (same formats as --foreground)
    \\-e, --entrance=DIR         where to place the entrance 'north','west','south','east'
    \\-x, --exit=DIR             where to place the exit 'north','west','south','east'
    \\-S, --seed=NUMBER          set the seed from the random number generator
    \\-T, --tileable             create a tileable maze
    \\-C, --cellsize=SIZE        set the cell size (units: px, pt, mm, cm, in)
    \\-b, --bordersize=SIZE      set the border size
    \\-l, --linewidth=SIZE       set the line width
    \\-R, --rotate=DEGREES       rotate the maze
    \\--bridgewidth=[0.2,0.8]    set the bridge width
    \\--nomarks                  omit drawing of entrance/exit marks
    \\-P, --solution             draw the solution path
    \\--numbers                  draw cell numbers (for debugging purpose)
    \\--text=TEXT                draw the text specified along the solution
    \\    and fill random characters into the maze
    \\--fuzzy                    draw fuzzy strokes
    \\--amplitude=FLOAT          amplitude for fuzzy strokes
    \\--no-fuzzy=NUMBER          number of fuzzy substrokes
    \\-j, --jitter=NUMBER        factor for the irregularity of cells in random mazes [0,1]
    \\-w, --wall-length=NUMBER   remove walls which lengths are shorter in irregular mazes
    \\--rough-border             don't clip random mazes at a straight border
    \\-m, --mask=PNGFILE         specifies mask to be used for generating the maze
    \\--maxcells=NUMBER          refuse to create mazes with more cells
    \\--sample                   create a small png sample
    \\--save=FILE                save the parameters to FILE (default: ~/.maze5.last)
    \\--load[=FILE]              load parameters from FILE (default: ~/.maze5.last);
    \\    parameters given on the command line take precedence
    \\--stats                    print timing statistics to stderr
    \\-v, --version              print the program version
    \\-d, --dummy                don't create a maze, render a grid only
    \\-D, --debug[=LEVEL]        debug mode (draws cell numbers)
    \\--copyright                insert a copyright message into the maze
    \\-h, --help                 print this help
    \\
;
