#!/bin/sh
# The savestate path end to end (tb_savestate.sv): save at one point through
# the Pocket's command and bridge, load into a fresh run at another (work RAM,
# registers, Z80 RAM and the rest scribbled), and require both CPUs' bus
# cycles after the stubs to be identical; then load, save again at once, and
# require the same snapshot back.
#
#   sim/savestate/run.sh <128 KB Neo Geo BIOS> <m1rom> [save at] [load at] [cycles to compare]
#
# The M1 ROM is a game's Z80 program (the Darksoft set's m1rom); the 68k runs
# the BIOS alone, whose sound commands reach it. ROM data is not in the
# repository.
#
# SS_QUICK=1 saves and loads without the menu, as Analogue + Up and Down do
# (the game runs on but for the request); SS_NO_HOLD=1 takes savestate.sv's
# hold out, and then the watchdog check fails. Every request is checked
# against the game's watchdog.
#
# Every run also loads the snapshot, at the save's point, into a machine whose
# ROM differs from the save's (refuse), which must refuse it and run on as
# the save's run did.
#
# SS_CHIP=<cart_pchip> puts a cartridge chip in the PORT zone (2 PVC, 3-7
# SMA) with its state set to noise, and requires the load to bring back what
# the save saw.
#
# BRIDGE_GAP=<clk_74a cycles> sets how fast the Pocket's bridge transactions
# come (default 40, about 0.6 us a word, faster than "a few megabytes per
# second").
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
bios=${1:?usage: $0 bios.rom m1rom [save at] [load at] [cycles]}
m1=${2:?usage: $0 bios.rom m1rom [save at] [load at] [cycles]}
save_at=${3:-150000}
load_at=${4:-40000}
want=${5:-100000}
src="$root/src/NeoGeo Cart/core/NeoGeoCore"
obj="$root/build/sim/savestate"
mkdir -p "$obj/rtl"
files=$("$root/sim/z80_rtl.sh" "$obj" | tr '\n' ' ')
# Verilator's makefile cannot take the space in "NeoGeo Cart": copy the sources.
cp "$src/cpu/FX68K/microcodes.v" "$src/cpu/FX68K/fx68k.sv" "$src/cpu/FX68K/fx68kAlu.sv" \
    "$src/cpu/FX68K/uaddrPla.sv" "$src/cpu/cpu_68k.v" "$src/savestate/ss_m68k.sv" \
    "$src/savestate/ss68k_stub_rom.sv" "$src/savestate/ss_mem.sv" "$src/savestate/savestate.sv" \
    "$src/mem/cram_16bit.v" "$src/io/neo_sma.sv" "$src/io/neo_pvc.v" "$obj/rtl/"
sed -n '/^module synch_3/,/^endmodule/p' "$root/src/NeoGeo Cart/apf/common.v" > "$obj/rtl/synch_3.v"
cd "$obj"
verilator --cc --exe --build -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
    -Wno-MULTIDRIVEN -Wno-COMBDLY --no-assert --top-module tb_savestate -Mdir . -Irtl/jt12 \
    rtl/microcodes.v rtl/fx68k.sv rtl/fx68kAlu.sv rtl/uaddrPla.sv rtl/cpu_68k.v rtl/ss_m68k.sv \
    rtl/ss68k_stub_rom.sv rtl/ss_mem.sv rtl/savestate.sv rtl/cram_16bit.v rtl/synch_3.v $files \
    rtl/neo_sma.sv rtl/neo_pvc.v "$here/dpram_model.sv" "$here/psram_model.sv" "$here/tb.vlt" "$here/tb_savestate.sv" "$here/tb_savestate.cpp" \
    > build.log 2>&1 || { grep -E "%Error|error:" build.log | head -20; exit 1; }
rm -f chip_save.txt chip_load.txt
./Vtb_savestate "$bios" "$m1" save "$save_at" "$want" state.bin > after_save.txt
./Vtb_savestate "$bios" "$m1" load "$load_at" "$want" state.bin > after_load.txt
status=0
if cmp -s after_save.txt after_load.txt; then
    echo "PASS: $want 68k bus cycles identical after save (at $save_at) and load (at $load_at)"
else
    echo "FAIL: the 68k diverges after the load (first difference below)"
    diff after_save.txt after_load.txt | head -6
    status=1
fi
if [ -s z80_save.txt ] && cmp -s z80_save.txt z80_load.txt; then
    echo "PASS: the $(wc -l < z80_save.txt | tr -d ' ') Z80 bus cycles over the same time identical too"
else
    echo "FAIL: the Z80 diverges after the load, or ran no bus cycles (first difference below)"
    diff z80_save.txt z80_load.txt | head -6
    status=1
fi
if [ -n "$SS_CHIP" ] && [ "$SS_CHIP" != 0 ]; then
    if [ -s chip_save.txt ] && cmp -s chip_save.txt chip_load.txt; then
        echo "PASS: the cartridge chip ($(head -c 3 chip_save.txt), type $SS_CHIP) after the load is as the save found it"
    else
        echo "FAIL: the cartridge chip differs after the load (first difference below)"
        diff chip_save.txt chip_load.txt | head -6
        status=1
    fi
fi
if [ -n "$SS_QUICK" ]; then
    echo "(the refusal is checked with the menu only: without it the game runs on while the Pocket writes the buffer)"
elif ./Vtb_savestate "$bios" "$m1" refuse "$save_at" "$want" state.bin > after_refuse.txt 2> refused.txt &&
     grep -q "^load: refused" refused.txt && cmp -s after_save.txt after_refuse.txt; then
    echo "PASS: another game's snapshot is refused; the 68k's bus cycles after it are those after the save"
    # The Z80, which a refused load never asks for: as with no request at all
    ./Vtb_savestate "$bios" "$m1" idle "$save_at" "$want" state.bin > /dev/null 2>&1
    # over the refused run's cycles: the log stops when the 68k's does, and
    # without the stub's RTE the idle run's 68k gets there a little later
    if [ -s z80_refuse.txt ] && head -n "$(wc -l < z80_refuse.txt)" z80_idle.txt | cmp -s - z80_refuse.txt; then
        echo "PASS: the Z80's $(wc -l < z80_refuse.txt | tr -d ' ') bus cycles after it are those after the menu with no request"
    else echo "FAIL: the Z80 differs after the refused load"; diff z80_idle.txt z80_refuse.txt | head -4; status=1; fi
else
    echo "FAIL: another game's snapshot is not refused, or the machine is not left as it was"
    grep -v "^load: \\(menu\\|no menu\\)" refused.txt | head -4
    diff after_save.txt after_refuse.txt | head -4
    status=1
fi
./Vtb_savestate "$bios" "$m1" loadsave "$load_at" 0 state.bin state2.bin
# Compare what the stub writes (the layout in ss68k_stub.s), but for the
# YM2610's timers (WZYM, 0x128): they count from the load's resume to the
# next save, as they would in the game
python3 -I - state.bin state2.bin <<'PY' || status=1
import sys
a, b = (open(f, "rb").read() for f in sys.argv[1:3])
for f, x in zip(sys.argv[1:3], (a, b)):
    if x[0:6] != b"NGSS\0\1":
        sys.exit(f"FAIL: {f} has no header (magic NGSS, version 1)")
    if x[0x120:0x122] != b"\0\1":
        sys.exit(f"FAIL: {f} has no Z80 part (WZOK 0: the stub gave up waiting for it)")
# The P-ROM bank's latch (shadow word 4) is unused, and not restored, when a
# chip gives the PORT zone's address
kind = int.from_bytes(a[0x130:0x132], "big")
shadows = ((0x100, 0x110, "shadows"),) if not kind else \
          ((0x100, 0x108, "shadows"), (0x10A, 0x110, "shadows"))
for lo, hi, what in ((0x00, 0x10, "header"), (0x40, 0x84, "registers"), *shadows,
                     (0x120, 0x128, "Z80 SP, NMI, reply"),
                     (0x1000, 0x11000, "work RAM"), (0x11000, 0x15000, "palette"),
                     (0x15000, 0x25000, "slow VRAM"), (0x25000, 0x26000, "fast VRAM"),
                     (0x26000, 0x27000, "Z80 RAM"), (0x27000, 0x27400, "YM2610 shadow")):
    bad = [i for i in range(lo, hi) if a[i] != b[i]]
    if bad:
        sys.exit(f"FAIL: {what} differ after load+save, first at 0x{bad[0]:x}")
# The chip's part (WCHIP, 0x130; WPVC, 0x28000) as far as its type has one
ranges = [(0x130, 0x132, "chip type")]
if kind >= 3: ranges.append((0x132, 0x138, "SMA bank and RNG"))
if kind == 2: ranges.append((0x28000, 0x2A000, "PVC RAM"))
for lo, hi, what in ranges:
    bad = [i for i in range(lo, hi) if a[i] != b[i]]
    if bad:
        sys.exit(f"FAIL: {what} differ after load+save, first at 0x{bad[0]:x}")
print("PASS: saving straight after a load gives the same snapshot (registers, shadows, work RAM, "
      "palette, VRAM, the Z80's part" + (", the chip's" if kind else "") + ")")
PY
exit $status
