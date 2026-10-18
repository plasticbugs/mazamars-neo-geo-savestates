#!/bin/sh
# The Z80's side of savestates (tb_ssz80.sv): save at one point, load into
# a fresh run at another (Z80 RAM scribbled), and compare the Z80's bus
# cycles after each stub; then load, save again at once, and require the
# same snapshot back.
#
#   sim/ssz80/run.sh <m1rom> [save at] [load at] [cycles to compare]
#
# The M1 ROM is a game's Z80 program as the core loads it (the Darksoft
# set's m1rom); ROM data is not in the repository.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
m1=${1:?usage: $0 m1rom [save at] [load at] [cycles]}
save_at=${2:-150000}
load_at=${3:-90000}
want=${4:-60000}
obj="$root/build/sim/ssz80"
files=$("$root/sim/z80_rtl.sh" "$obj" | tr '\n' ' ')
cd "$obj"
verilator --cc --exe --build -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
    -Wno-MULTIDRIVEN -Wno-COMBDLY --no-assert --top-module tb_ssz80 -Mdir . -Irtl/jt12 \
    $files "$here/tb.vlt" "$here/tb_ssz80.sv" "$here/tb_ssz80.cpp" \
    > build.log 2>&1 || { grep -E "%Error|error:" build.log | head -20; exit 1; }
./Vtb_ssz80 "$m1" save "$save_at" "$want" state.bin > after_save.txt
./Vtb_ssz80 "$m1" load "$load_at" "$want" state.bin > after_load.txt
status=0
same=$(cmp after_save.txt after_load.txt 2>/dev/null | sed -n 's/.* line \([0-9]*\)$/\1/p')
if [ -z "$same" ] && cmp -s after_save.txt after_load.txt; then
    echo "PASS: $want Z80 bus cycles identical after save (at $save_at) and load (at $load_at)"
else
    echo "FAIL: the Z80 traces agree for $((${same:-1} - 1)) of $want bus cycles after save and load; first difference:"
    diff after_save.txt after_load.txt | head -4
    status=1
fi
# Byte for byte, but for the YM2610's timers (bytes 11-16): they count from
# the load's resume point to the next save's, as they would in the game
./Vtb_ssz80 "$m1" loadsave "$load_at" 0 state.bin state2.bin
diffs=$(cmp -l state.bin state2.bin | awk '$1 < 11 || $1 > 16')
if [ -z "$diffs" ]; then
    echo "PASS: saving straight after a load gives the same Z80 snapshot (the timers aside)"
else
    echo "FAIL: the Z80 snapshot after load+save differs (offset, octal values)"
    echo "$diffs" | head -5
    status=1
fi
exit $status
