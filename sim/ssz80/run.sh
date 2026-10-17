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
src="$root/src/NeoGeo Cart/core/NeoGeoCore"
obj="$root/build/sim/ssz80"
mkdir -p "$obj/rtl" "$obj/t80"
# T80 is VHDL: GHDL converts it to Verilog. One line needs a 9-bit literal
# where Quartus accepts a 4-bit one (ioq and x"7"); the copy is patched.
if [ ! -f "$obj/t80/T80s.v" ] || [ -n "$(find "$src/cpu/T80" -newer "$obj/t80/T80s.v")" ]; then
    for f in T80_Pack T80_MCode T80_ALU T80_Reg T80 T80s; do cp "$src/cpu/T80/$f.vhd" "$obj/t80/"; done
    perl -pi -e 's/\(ioq and x"7"\)/(ioq and "000000111")/' "$obj/t80/T80.vhd"
    (cd "$obj/t80" && rm -f ./*.cf && \
     ghdl -a --std=08 -fsynopsys T80_Pack.vhd T80_MCode.vhd T80_ALU.vhd T80_Reg.vhd T80.vhd T80s.vhd 2>/dev/null && \
     ghdl --synth --std=08 -fsynopsys --latches --out=verilog T80s > T80s.v 2> synth.log)
fi
# Verilator's makefile cannot take the space in "NeoGeo Cart": copy the sources.
rm -rf "$obj/rtl/jt12" "$obj/rtl/jt49" && cp -R "$src/jt12/hdl" "$obj/rtl/jt12" && cp -R "$src/jt49/hdl" "$obj/rtl/jt49"
cp "$src/cpu/cpu_z80.v" "$src/io/z80ctrl.v" "$src/io/zmc.v" "$src/savestate/ss_z80.sv" \
    "$src/savestate/ssz80_stub_rom.sv" "$src/savestate/ss_dpram_2clk.sv" "$obj/rtl/"
jt=$(sed -n 's/.*qip_path) \([^ ]*\.v\) .*/rtl\/jt12\/\1/p' "$obj/rtl/jt12/jt10.qip" | tr '\n' ' ')
jt="$jt $(sed -n 's/.*qip_path) \([^ ]*\.v\) .*/rtl\/jt49\/\1/p' "$obj/rtl/jt49/jt49.qip" | tr '\n' ' ')"
cd "$obj"
verilator --cc --exe --build -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
    -Wno-MULTIDRIVEN -Wno-COMBDLY --no-assert --top-module tb_ssz80 -Mdir . -Irtl/jt12 \
    t80/T80s.v rtl/cpu_z80.v rtl/z80ctrl.v rtl/zmc.v rtl/ss_z80.sv rtl/ssz80_stub_rom.sv rtl/ss_dpram_2clk.sv \
    $jt "$here/tb.vlt" "$here/tb_ssz80.sv" "$here/tb_ssz80.cpp" \
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
