#!/bin/bash
# Regression test: compares the SVG output of the original C maze5 with the
# Zig rewrite for many maze types, algorithms and options. Both programs use
# the same random number generator, so most outputs are byte-identical; the
# Zig version uses its own trigonometric functions, so theta and disc mazes
# may differ where the geometry has exact ties.
#
# usage: tools/compare.sh [C_BINARY] [ZIG_BINARY]
#
# Known, intended differences: "dummy" (the C version lacks the short option
# -d), "text" (the C version never renders the --text letters) and some
# crossover mazes ("*/cross*", fixed crossover construction).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
C=${1:-$ROOT/maze5-0.9.0/maze5}
Z=${2:-$ROOT/zig-out/bin/maze5}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export HOME=$W
pass=0; fail=0
run() {
  local name="$1"; shift
  "$C" "$@" -o "$W/c.svg" >/dev/null 2>"$W/c.err"; local rc=$?
  "$Z" "$@" -o "$W/z.svg" >/dev/null 2>"$W/z.err"; local rz=$?
  if [ $rc -ne 0 ] || [ $rz -ne 0 ]; then
    echo "EXIT  $name  (c=$rc zig=$rz) :: $*"; fail=$((fail+1)); return
  fi
  if cmp -s "$W/c.svg" "$W/z.svg"; then
    pass=$((pass+1))
  else
    echo "DIFF  $name :: $*"; fail=$((fail+1))
  fi
}

types="3 4 4:2 6 6:2 6:3 3-4 3-4:2 6-4 6-4:2 8-4 8-4:2 8-4:3 8-4:4 rhombic rhombic:2 rhombic:3 cairo cairo:2 hexagonal-rhombic house house:2 5_3 6-4-3 6-4-3:2"
for t in $types; do
  for a in backtracker prim tree tree:0.2; do
    for s in 1 2 3; do
      run "$t/$a/$s" -t $t -a $a -r 12 -c 14 -S $s
    done
  done
  run "$t/tile" -t $t -r 12 -c 12 -S 5 -T
  run "$t/organic" -t $t -r 10 -c 10 -S 7 -O -P
  run "$t/sol" -t $t -r 10 -c 10 -S 8 -P --numbers
done
for t in theta; do
  for a in backtracker prim tree; do
    for s in 1 2 3; do
      run "theta/$a/$s" -t theta -a $a -r 10 -c 6 -S $s
      run "theta-ring/$a/$s" -t theta -a $a -r 2-10 -c 5 -S $s -P
    done
  done
  run "theta/organic" -t theta -r 8 -c 4 -S 9 -O
  run "theta/arcs" -t theta -r 8 -c 7 -S 9 --arcs 0.5 --boundary inside
done
for t in random random-4 random-6 random-3 random-disc; do
  for a in backtracker prim tree; do
    for s in 1 2 3 4; do
      run "$t/$a/$s" -t $t -a $a -r 15 -c 15 -S $s
    done
  done
  run "$t/rough" -t $t -r 12 -c 14 -S 11 --rough-border
  run "$t/jitter" -t $t -r 12 -c 14 -S 12 -j 0.8 -w 0.2
  run "$t/organic" -t $t -r 12 -c 12 -S 13 -O -P
  run "$t/oblong" -t $t -r 9 -c 20 -S 14
done
# crossovers / bridges
for t in 4 6 6-4 8-4 8-4:2 rhombic hexagonal-rhombic 3-4; do
  run "$t/cross" -t $t -r 14 -c 14 -S 21 --crossings 0.1
  run "$t/cross-prim" -t $t -r 14 -c 14 -S 22 --crossings 6 -a prim -P
  run "$t/cross-tree" -t $t -r 14 -c 14 -S 23 --crossings 0.2 -a tree -O
done
# rendering options
run "fuzzy" -t 4 -r 8 -c 8 -S 31 --fuzzy --amplitude 0.2 --no-fuzzy 5
run "colors" -t 6 -r 8 -c 8 -S 32 -F 1,0,0 -B "#00ff00" -l 1mm -C 1cm -b 0.5in
run "rotate" -t 6 -r 8 -c 8 -S 33 -R 30
run "nomarks" -t 6 -r 8 -c 8 -S 34 --nomarks
run "dummy" -t cairo -r 8 -c 8 -d
run "arcs-angle" -t 4:2 -r 8 -c 8 -S 35 --arcs 120 --boundary keep
run "arcs-neg" -t 6:3 -r 8 -c 8 -S 36 --arcs -0.7
run "bridgew" -t 4 -r 10 -c 10 -S 37 --crossings 4 --bridgewidth 0.6
run "entrance" -t 4 -r 10 -c 10 -S 38 -e north -x west
run "copyright" -t 4 -r 10 -c 10 -S 39 --copyright
run "text" -t 4 -r 10 -c 10 -S 40 --text maze
run "big" -t 4 -r 60 -c 80 -S 41
run "big-voronoi" -t random -r 50 -c 50 -S 42
echo "passed: $pass  failed: $fail"
