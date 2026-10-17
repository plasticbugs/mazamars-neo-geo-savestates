# Savestates (Pocket Memories): design

Status: design, step 1 (pause) built. Primary target: Metal Slug (`mslug`).

## The idea: the CPUs save themselves

This core is Furrtek's gate-level NeoGeo. Its flops are clocked by derived
strobes (`PCK1`, `nSDW`, `WR_*` decodes, the `cells/` primitives), so
threading a read/write scan chain through the machine is not practical, and
FX68K, T80 and jt10 have no state ports. But almost all of the state is
visible to the CPUs through the machine's own buses:

| State | Size | How the CPU reaches it |
|---|---|---|
| 68k registers | 72 B | the 68k, in a stub (MOVEM, MOVE USP) |
| 68k PC, SR | 6 B | the exception frame the stub's interrupt pushed |
| Work RAM | 64 KB | 68k, 0x100000 |
| Palette RAM, both banks | 16 KB | 68k, 0x400000, bank latch 0x3A000F/1F |
| Slow + fast VRAM | 68 KB | 68k, LSPC port 0x3C0000-04 |
| Memory card | 2-8 KB | 68k, 0x800000 |
| Backup RAM (MVS) | 64 KB | 68k, 0xD00000 |
| Z80 registers, RAM | 2 KB + regs | the Z80, in an NMI stub |
| Write-only registers: LSPC mode/timer/VRAM modulo, system latch, 68k-Z80 latches, Z80 bank and NMI enable, YM2610 registers | < 1 KB | **shadows**: core logic records each write; the stub reads and replays them |
| Raster position, LSPC timer counter, IRQ pending | | hardware: save at a fixed raster point, or small read/load ports |

So the save/load engine is mostly software: a short 68000 stub (and a Z80
one) that the core makes the CPU run on demand, plus a window through which
the stub writes the snapshot to a buffer and reads it back.

## 68k: entering and leaving the stub

- **Enter**: raise interrupt level 7 (the only one the game cannot mask; the
  NeoGeo itself never uses it). The core answers that acknowledge cycle
  itself, and the vector fetch, so the CPU jumps to the stub. The CPU pushes
  PC and SR onto the supervisor stack first: that frame *is* the saved PC/SR.
- **Save stub**: `MOVEM.L D0-D7/A0-A6` and `USP` and `A7` (SSP) to the
  window, then copy RAM/VRAM/palette etc., then reload its registers and `RTE`.
  The game continues as if a very long interrupt had happened.
- **Load stub**: entered the same way from wherever the game is. Copies
  everything back (work RAM includes the saved stack and frame), then loads
  USP, SSP, D0-A6 and executes `RTE`, which pops the *saved* frame: the CPU
  resumes at the saved instruction with the saved SR. No reset, no change
  inside FX68K.
- **The bus**: the stub ROM, the window and the acknowledge/vector answers
  are muxed in at the CPU's own inputs (`FX68K_DATAIN`, `DTACK`) in
  `cpu_68k`, after the rest of the bus has resolved. The rest of the machine
  sees the stub's accesses to an unmapped region: 0xE00000-0xEFFFFF (stub
  code from 0xE00000, the window from 0xE80000). Not 0x600000-0x7FFFFF:
  MAME's map mirrors palette RAM over all of 0x400000-0x7FFFFF. Above
  0xE00000 nothing is mapped in MAME (MVS or AES) and NEO-C1 decodes no zone
  (A21=1 with A23/A22 set).
- **The buffer**: the window is backed by 512 KB of free CRAM0 at 0xA80000
  (`ss_mem.sv`), through a port of its own in `cram_16bit` (priority after
  the Pocket's word port, before the 68k, fix layer and Z80). The stub's
  window crosses from CLK_24M to clk_sys as a toggle handshake.
- **Leaving**: the stub's CTRL write ends the save or load, but the 68k
  keeps running (`run`) until the RTE's first stack pop, outside 0xE00000.
  Halted between the write and the RTE, a new request would be taken there,
  nested inside the stub (the bench caught this: SSP 6 bytes low).

## Z80 and YM2610

- Z80: same pattern through its NMI (vector 0x0066), returning with `RETN`.
  `LD A,I` gives the IFF2 that NMI saved. The NeoGeo's sound drivers use
  `IM 1`; the mode is not readable and is assumed (or snooped from the `ED 56`
  fetch). The game's own NMI (sound command) stays pending across a stub.
- YM2610: a 512-byte shadow of every register write. On load the Z80 stub
  writes them back (key-on last), which re-arms timers A/B; notes playing at
  the instant of the save restart rather than continue mid-envelope.

## Pocket interface

`savestate.sv`. `savestate_addr` = 0x80000000 (the bridge's 0x8xxxxxxx is
otherwise unused), `savestate_size` = `maxloadsize` = 0x80000, the whole
buffer. Bridge word n is {window word 2n, window word 2n+1}, so the file is
the window in 68k byte order. On "save" (0xA0) the core acks, is busy while
the stub runs, then answers OK; the Pocket then reads the buffer. On "load"
(0xA4) the Pocket has written the buffer; the core runs the load stub and
answers OK. A stub that has not finished after 1.8 s answers error (the 68k
held in reset, say). The CPUs are halted around all of it (`cpu_halt`,
step 1); only the 68k runs, for the stub. To do: a header (magic, game,
BIOS, MVS/AES, version) checked on load.

Bridge reads are pipelined (Analogue: the core "has up until the next read
strobe to drive bridge_rd_data"). Each read starts a prefetch of the next
word, so sequential reads are answered at once. A word costs two 16-bit
CRAM reads; in `sim/savestate` with a 12-clock PSRAM model that keeps up
with a transaction every 30 clk_74a cycles (about 10 MB/s) and fails at 25;
Analogue gives the bridge as "a few megabytes per second". Not measured on
hardware.

## Verification

1. 68k round trip on the CPU bench (`sim/ss68k`): run code, save at an
   instruction, run on; in a fresh run, load and run on. The bus traces after
   the two `RTE`s must be identical; and a save straight after a load must
   give the same snapshot. Then the same end to end (`sim/savestate`): the
   menu's halt, the Pocket's commands and bridge (pipelined reads), the CDC,
   `cram_16bit` and a PSRAM model, every bridge word checked against the
   buffer, and the buffer scribbled over between the load and the save.
2. The same for the Z80.
3. The whole machine in MAME terms: the core's frames after a load against
   the frames after the save, and against MAME with the same inputs where it
   applies.
4. Hardware: Metal Slug, save, play on, load, several times in a row; then
   other games.

## Order

1. Pause (built; hardware test pending).
2. 68k stub + bench round trip (no hardware).
3. Window and buffer in CRAM0, Pocket handshake, 68k-only state on hardware
   (registers + work RAM + palette + VRAM + LSPC shadows).
4. Z80 + YM2610.
5. Cart chips (bank registers, PVC/SMA/CMC games), memory card, backup RAM.
