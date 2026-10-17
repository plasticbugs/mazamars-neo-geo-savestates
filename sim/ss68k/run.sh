#!/bin/sh
# 68k savestate round trip: save at one point, load into a fresh run at
# another (with work RAM scribbled), and require the CPU's bus cycles after
# each stub's RTE to be identical.
#
#   sim/ss68k/run.sh <128 KB Neo Geo BIOS> [save at] [load at] [cycles to compare]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
bios=${1:?usage: $0 bios.rom [save at] [load at] [cycles]}
save_at=${2:-150000}
load_at=${3:-40000}
want=${4:-200000}
src="$root/src/NeoGeo Cart/core/NeoGeoCore"
obj="$root/build/sim/ss68k"
mkdir -p "$obj/rtl"
# Verilator's makefile cannot take the space in "NeoGeo Cart": copy the sources.
cp "$src/cpu/FX68K/microcodes.v" "$src/cpu/FX68K/fx68k.sv" "$src/cpu/FX68K/fx68kAlu.sv" \
    "$src/cpu/FX68K/uaddrPla.sv" "$src/cpu/cpu_68k.v" "$src/savestate/ss_m68k.sv" \
    "$src/savestate/ss68k_stub_rom.sv" "$obj/rtl/"
cd "$obj"
verilator --cc --exe --build -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK -Wno-UNOPTFLAT --no-assert \
    --top-module tb_ss68k -Mdir . \
    rtl/microcodes.v rtl/fx68k.sv rtl/fx68kAlu.sv rtl/uaddrPla.sv rtl/cpu_68k.v rtl/ss_m68k.sv rtl/ss68k_stub_rom.sv \
    "$here/tb_ss68k.sv" "$here/tb_ss68k.cpp" \
    > build.log 2>&1 || { grep -E "%Error|error:" build.log | head -20; exit 1; }
./Vtb_ss68k "$bios" save "$save_at" "$want" state.bin > after_save.txt
./Vtb_ss68k "$bios" load "$load_at" "$want" state.bin > after_load.txt
if cmp -s after_save.txt after_load.txt; then
    echo "PASS: $want bus cycles identical after save (at $save_at) and load (at $load_at)"
else
    echo "FAIL: the CPU diverges after the load (first difference below)"
    diff after_save.txt after_load.txt | head -6
    exit 1
fi
./Vtb_ss68k "$bios" loadsave "$load_at" 0 state.bin state2.bin
if cmp -s state.bin state2.bin; then
    echo "PASS: saving straight after a load gives the same snapshot, byte for byte"
else
    echo "FAIL: the snapshot after load+save differs from the original"
    cmp -l state.bin state2.bin | head -5
    exit 1
fi
