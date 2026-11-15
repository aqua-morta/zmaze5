#!/bin/sh
# Renders a PNG pattern image of every maze type (and subtype) using the
# dummy mode (-d, grid only), e.g. as thumbnails for a website.
#
# Tiling types are cut out of the centre of a larger grid, so the irregular
# border is hidden and every image shows the same scale. Types whose outline
# is characteristic (theta, pentagonal-rotational, random-disc, random-3) are rendered whole and
# fitted into the image instead.
#
# usage: tools/patterns.sh [OUTDIR]           (default: patterns)
#
# environment:
#   MAZE5     maze5 binary          (default: zig-out/bin/maze5)
#   SIZE      image size in pixels  (default: 256)
#   CELL      cell size in pixels   (default: 32)
#   FG, BG    colors as accepted by maze5 -F/-B (default: maze5's defaults;
#             BG=transparent gives transparent images)
#   LINE      line width in pixels (default: maze5's default, 2.5)
#   SEED      random seed           (default: 1)
#   OPTIPNG   set to 1 to compress the images with optipng
#
# Requires ImageMagick (convert). The images carry no time stamps or other
# metadata (-strip), so rendering them again gives identical files.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUTDIR=${1:-patterns}
MAZE5=${MAZE5:-$ROOT/zig-out/bin/maze5}
SIZE=${SIZE:-256}
CELL=${CELL:-32}
SEED=${SEED:-1}

command -v convert >/dev/null || { echo "ImageMagick 'convert' not found" >&2; exit 1; }
[ -x "$MAZE5" ] || { echo "maze5 binary '$MAZE5' not found (run 'zig build')" >&2; exit 1; }
mkdir -p "$OUTDIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# rows/columns for the cropped types: enough cells to cover SIZE with a
# generous margin (a structure's row can be smaller than the cell size)
N=$(( SIZE * 3 / CELL / 2 + 6 ))

# output name, -t argument, kind (crop, or fit with -r/-c)
TYPES="
orthogonal-1 orthogonal:1 crop
orthogonal-2 orthogonal:2 crop
triangular triangular crop
hexagonal-1 hexagonal:1 crop
hexagonal-2 hexagonal:2 crop
hexagonal-3 hexagonal:3 crop
triangle-square-1 triangle-square:1 crop
triangle-square-2 triangle-square:2 crop
hexagon-square-1 hexagon-square:1 crop
hexagon-square-2 hexagon-square:2 crop
octagon-square-1 octagon-square:1 crop
octagon-square-2 octagon-square:2 crop
octagon-square-3 octagon-square:3 crop
octagon-square-4 octagon-square:4 crop
rhombic-1 rhombic:1 crop
rhombic-2 rhombic:2 crop
rhombic-3 rhombic:3 crop
cairo-1 cairo:1 crop
cairo-2 cairo:2 crop
hexagonal-rhombic hexagonal-rhombic crop
house-1 house:1 crop
house-2 house:2 crop
pentagonal-1-1 pentagonal_1:1 crop
pentagonal-1-2 pentagonal_1:2 crop
pentagonal-2-1 pentagonal_2:1 crop
pentagonal-2-2 pentagonal_2:2 crop
pentagonal-3 pentagonal_3 crop
pentagonal-10 pentagonal_10 crop
hexagon-square-triangle-1 6-4-3:1 crop
hexagon-square-triangle-2 6-4-3:2 crop
square-hexagon-dodecagon 12-6-4 crop
floret floret crop
theta theta fit 1-6 6
pentagonal-rotational pentagonal-rotational fit 7 5
random random crop
random-4 random-4 crop
random-6 random-6 crop
random-3 random-3 fit 14 13
random-disc random-disc fit 8 8
penrose penrose crop
penrose-rhombs penrose:2 crop
einstein einstein crop
ammann-beenker ammann-beenker crop
supergolden supergolden crop
shield shield crop
wheel wheel crop
socolar socolar crop
clamshell clamshell crop
"

set --
[ -n "${FG:-}" ] && set -- "$@" -F "$FG"
[ -n "${BG:-}" ] && set -- "$@" -B "$BG"
[ -n "${LINE:-}" ] && set -- "$@" -l "$LINE"
BGCOLOR=${BG:-white}
[ "$BGCOLOR" = transparent ] && BGCOLOR=none
case $BGCOLOR in *,*) BGCOLOR="rgb($BGCOLOR)" ;; esac # R,G,B floats are not understood by convert

echo "$TYPES" | while read -r name type kind rows cols; do
    [ -n "$name" ] || continue
    raw="$TMP/$name.png"
    out="$OUTDIR/$name.png"
    if [ "$kind" = crop ]; then
        "$MAZE5" -d --nomarks -S "$SEED" -t "$type" -r "$N" -c "$N" -C "${CELL}px" -o "$raw" "$@"
        w=$(identify -format %w "$raw")
        h=$(identify -format %h "$raw")
        if [ "$w" -lt "$SIZE" ] || [ "$h" -lt "$SIZE" ]; then
            echo "$name: rendered image ${w}x$h is smaller than ${SIZE}px" >&2
            exit 1
        fi
        # shifted a bit, so that the crop doesn't end exactly on grid lines
        off=$(( CELL / 3 ))
        convert "$raw" -crop "${SIZE}x$SIZE+$(( (w - SIZE) / 2 + off ))+$(( (h - SIZE) / 2 + off ))" +repage -strip "$out"
    else
        # render, then render again with the cell size that makes the
        # maze fit (scaling the image would make the lines thinner)
        inner=$(( SIZE - SIZE / 16 ))
        "$MAZE5" -d --nomarks -S "$SEED" -t "$type" -r "$rows" -c "$cols" -C "${CELL}px" -o "$raw" "$@"
        dim=$(convert "$raw" -trim -format '%[fx:max(w,h)]' info:)
        cell=$(awk "BEGIN { printf \"%.3f\", $CELL * $inner / $dim }")
        "$MAZE5" -d --nomarks -S "$SEED" -t "$type" -r "$rows" -c "$cols" -C "${cell}px" -o "$raw" "$@"
        convert "$raw" -trim +repage -background "$BGCOLOR" -resize "${inner}x$inner>" \
            -gravity center -extent "${SIZE}x$SIZE" -strip "$out"
    fi
    [ "${OPTIPNG:-0}" = 1 ] && optipng -quiet -o2 "$out"
    echo "$out"
done
