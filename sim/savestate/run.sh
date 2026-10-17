#!/bin/sh
# The savestate path end to end (tb_savestate.sv): save at one point through
# the Pocket's command and bridge, load into a fresh run at another (work RAM
# and registers scribbled), and require the CPU's bus cycles after each stub
# to be identical; then load, save again at once, and require the same
# snapshot back.
#
#   sim/savestate/run.sh <128 KB Neo Geo BIOS> [save at] [load at] [cycles to compare]
#
# BRIDGE_GAP=<clk_74a cycles> sets how fast the Pocket's bridge transactions
# come (default 40, about 0.6 us a word, faster than "a few megabytes per
# second").
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
bios=${1:?usage: $0 bios.rom [save at] [load at] [cycles]}
save_at=${2:-150000}
load_at=${3:-40000}
want=${4:-100000}
src="$root/src/NeoGeo Cart/core/NeoGeoCore"
obj="$root/build/sim/savestate"
mkdir -p "$obj/rtl"
# Verilator's makefile cannot take the space in "NeoGeo Cart": copy the sources.
cp "$src/cpu/FX68K/microcodes.v" "$src/cpu/FX68K/fx68k.sv" "$src/cpu/FX68K/fx68kAlu.sv" \
    "$src/cpu/FX68K/uaddrPla.sv" "$src/cpu/cpu_68k.v" "$src/savestate/ss_m68k.sv" \
    "$src/savestate/ss68k_stub_rom.sv" "$src/savestate/ss_mem.sv" "$src/savestate/savestate.sv" \
    "$src/mem/cram_16bit.v" "$obj/rtl/"
sed -n '/^module synch_3/,/^endmodule/p' "$root/src/NeoGeo Cart/apf/common.v" > "$obj/rtl/synch_3.v"
cd "$obj"
verilator --cc --exe --build -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK -Wno-UNOPTFLAT --no-assert \
    --top-module tb_savestate -Mdir . \
    rtl/microcodes.v rtl/fx68k.sv rtl/fx68kAlu.sv rtl/uaddrPla.sv rtl/cpu_68k.v rtl/ss_m68k.sv \
    rtl/ss68k_stub_rom.sv rtl/ss_mem.sv rtl/savestate.sv rtl/cram_16bit.v rtl/synch_3.v \
    "$here/psram_model.sv" "$here/tb_savestate.sv" "$here/tb_savestate.cpp" \
    > build.log 2>&1 || { grep -E "%Error|error:" build.log | head -20; exit 1; }
./Vtb_savestate "$bios" save "$save_at" "$want" state.bin > after_save.txt
./Vtb_savestate "$bios" load "$load_at" "$want" state.bin > after_load.txt
if cmp -s after_save.txt after_load.txt; then
    echo "PASS: $want bus cycles identical after save (at $save_at) and load (at $load_at)"
else
    echo "FAIL: the CPU diverges after the load (first difference below)"
    diff after_save.txt after_load.txt | head -6
    exit 1
fi
./Vtb_savestate "$bios" loadsave "$load_at" 0 state.bin state2.bin
# Compare what the stub writes (the layout in ss68k_stub.s)
python3 -I - state.bin state2.bin <<'PY'
import sys
a, b = (open(f, "rb").read() for f in sys.argv[1:3])
for lo, hi, what in ((0x40, 0x84, "registers"), (0x100, 0x110, "shadows"),
                     (0x1000, 0x11000, "work RAM"), (0x11000, 0x15000, "palette"),
                     (0x15000, 0x25000, "slow VRAM"), (0x25000, 0x26000, "fast VRAM")):
    bad = [i for i in range(lo, hi) if a[i] != b[i]]
    if bad:
        sys.exit(f"FAIL: {what} differ after load+save, first at 0x{bad[0]:x}")
print("PASS: saving straight after a load gives the same snapshot (registers, shadows, work RAM, palette, VRAM)")
PY
