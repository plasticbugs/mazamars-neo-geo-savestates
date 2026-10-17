#!/bin/sh
# cpu_68k HALT bench: the bus trace with random halts must equal the trace
# without, cycle for cycle in CPU time.
#
#   sim/cpu68k_halt/run.sh <path to a 128 KB Neo Geo BIOS> [bus cycles]
#
# The BIOS is only something for the CPU to execute; it is never copied into
# the tree.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
bios=${1:?usage: $0 bios.rom [bus cycles]}
want=${2:-300000}
cpu="$root/src/NeoGeo Cart/core/NeoGeoCore/cpu"
obj="$root/build/sim/cpu68k_halt"
mkdir -p "$obj/rtl"
# Verilator's makefile cannot take the space in "NeoGeo Cart": copy the sources.
cp "$cpu/FX68K/microcodes.v" "$cpu/FX68K/fx68k.sv" "$cpu/FX68K/fx68kAlu.sv" \
    "$cpu/FX68K/uaddrPla.sv" "$cpu/cpu_68k.v" "$obj/rtl/"
cd "$obj"
verilator --cc --exe --build -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK -Wno-UNOPTFLAT --no-assert \
    --top-module tb_cpu68k_halt -Mdir . \
    rtl/microcodes.v rtl/fx68k.sv rtl/fx68kAlu.sv rtl/uaddrPla.sv rtl/cpu_68k.v \
    "$here/tb_cpu68k_halt.sv" "$here/tb_cpu68k_halt.cpp" \
    > build.log 2>&1 || { grep -E "%Error|error:" build.log | head -20; exit 1; }
./Vtb_cpu68k_halt "$bios" 0 "$want" > free.txt
./Vtb_cpu68k_halt "$bios" 1 "$want" > halted.txt
if cmp -s free.txt halted.txt; then
    echo "PASS: $want bus cycles identical with and without halts"
else
    echo "FAIL: traces differ (first difference below)"
    diff free.txt halted.txt | head -6
    exit 1
fi
