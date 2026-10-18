#!/bin/sh
# The Z80 side's RTL for the Verilator benches, under <obj>: T80 converted to
# Verilog by GHDL (t80/T80s.v, again only when T80 changes), the machine's
# Z80 decode, banks and RAM, ss_z80 and its stub, and jt10. Prints the files
# to give Verilator, relative to <obj>; jt10 also needs -Irtl/jt12.
#
#   files=$(sim/z80_rtl.sh <obj>)
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
obj=${1:?usage: $0 obj}
src="$root/src/NeoGeo Cart/core/NeoGeoCore"
mkdir -p "$obj/rtl" "$obj/t80"
# One line of T80 needs a 9-bit literal where Quartus accepts a 4-bit one
# (ioq and x"7"); the copy is patched.
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
echo t80/T80s.v rtl/cpu_z80.v rtl/z80ctrl.v rtl/zmc.v rtl/ss_z80.sv rtl/ssz80_stub_rom.sv rtl/ss_dpram_2clk.sv
sed -n 's/.*qip_path) \([^ ]*\.v\) .*/rtl\/jt12\/\1/p' "$obj/rtl/jt12/jt10.qip"
sed -n 's/.*qip_path) \([^ ]*\.v\) .*/rtl\/jt49\/\1/p' "$obj/rtl/jt49/jt49.qip"
