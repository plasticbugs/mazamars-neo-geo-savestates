# Savestates (Pocket Memories): design

Status: pause built; the 68k side of savestates built and simulated (registers,
work RAM, palette, VRAM, system latch, LSPC registers, P-ROM bank); the Z80
side (registers, RAM, ROM banks, NMI, latches, YM2610 registers and timers)
simulated and synthesized, not yet fitted. Primary target: Metal Slug
(`mslug`).

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
| Slow + fast VRAM | 68 KB | the VRAMs' second port, in the stub's region (0xE40000, 0xE50000): no LSPC slot timing to meet |
| Memory card | 2-8 KB | 68k, 0x800000 |
| Backup RAM (MVS) | 64 KB | 68k, 0xD00000 |
| Z80 registers, RAM | 2 KB + regs | the Z80, in a stub entered by RST 38h (registers); RAM on its second port |
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

## The snapshot (v2)

Offsets in the window and in the Pocket's file (68k byte order):

| Offset | Size | What |
|---|---|---|
| 0x0040 | 60 B | D0-D7, A0-A6 |
| 0x007C | 4 B | USP |
| 0x0080 | 4 B | SSP (points at the frame: PC and SR) |
| 0x0100 | 16 B | shadows: system latch (bit n = latch n), LSPC VRAM address (after increments), modulo, mode as written, P-ROM bank, Z80 ROM banks {1, 0} and {3, 2}, {NMI enabled, command latch} |
| 0x0120 | 2 B | WZOK: 1 if the Z80 part below was saved |
| 0x0122 | 2 B | Z80 SP, parked in its stub |
| 0x0124 | 2 B | Z80 NMI: bit 0 enabled, 1 line low, 2 input held low |
| 0x0126 | 2 B | the reply latch (0x320000 read) |
| 0x0128 | 6 B | the YM2610's timers and prescaler (jt10 `ss_q`, 40 bits) |
| 0x0130 | 2 B | the cartridge's chip: 0 none, 2 PVC, 3-7 SMA (`cart_pchip`) |
| 0x0132 | 6 B | SMA: bank (2 words), RNG |
| 0x1000 | 64 KB | work RAM |
| 0x11000 | 16 KB | palette bank 0, bank 1 |
| 0x15000 | 64 KB | slow VRAM |
| 0x25000 | 4 KB | fast VRAM |
| 0x26000 | 4 KB | Z80 RAM, a byte a word |
| 0x27000 | 1 KB | the YM2610 register shadow, a byte a word |
| 0x28000 | 8 KB | PVC: its RAM, 0x2FE000-0x2FFFFF, ports included |

The load stub restores the system latch one bit at a time (0x3A0001 + 2n +
0x10 x value), then the LSPC modulo, mode and VRAM address, then the P-ROM
bank (a write to 0x2FFFF0). The shadows are read at 0xE7FF10 from
`syslatch`, `lspc2_a2` (`SS_*` outputs), `P_BANK`, `zmc` (`WINDOWS`),
`z80ctrl` (the NMI enable) and the command latch. Not yet saved: the LSPC
timer's reload value and count, pending IRQs, the raster position (the video
runs on through the menu), the YM2610's sound (below).

### Cartridge chips

The stub reads the chip's type at 0xE7FF26 (`cart_pchip`) and saves what
that chip holds:

- **None:** the P-ROM bank, written back to 0x2FFFF0. Only these carts get
  that write: on KOF '99 0x2FFFF0 is the SMA's bank register, and on a PVC it
  is port 8, the bank's low byte.
- **SMA** (KOF '99, Garou, Metal Slug 3, KOF 2000): the P-ROM bank (24 bits,
  set by a scrambled write the stub cannot invert) and the RNG (16 bits,
  stepped by every read of the PORT zone). `neo_sma` shows both on `SS_Q`,
  read at 0xE7FF20-25. To load, the stub writes them to `CHIP_D` (the same
  addresses), sets `CHIP_LOAD` (0xE7FF26), writes the PORT zone once (the
  bank) and reads it once (the RNG), and clears `CHIP_LOAD`. Both registers
  stay in their own clocks (the strobes' edges); `CHIP_LOAD` and `CHIP_D`
  are set beforehand and held, so they are only a multiplexer on each D
  input. The stub reads the PORT zone nowhere else, so a save leaves the RNG
  where it was.
- **PVC** (Metal Slug 5, SNK vs. Capcom, KOF 2003): none of its state needs
  a port. Its 8 KB of RAM is copied through the bus both ways, and the top
  32 bytes carry the registers with it: ports 0, 4 and 5 read the RAM that
  their last writes left, and writing that back sets the colour registers
  again; ports 8 and 9 read the bank, and writing it back sets it. Ports 1,
  2 and 6 have no effect on a write. The RAM under ports 1, 2, 6, 8 and 9
  ends up holding the ports' values, which no read can see.

A snapshot whose chip type is not the cartridge's restores no chip state.
PRO-CT0 (Fatal Fury 2, Super Sidekicks) is not saved: its shift register
lives only through one protection check, a few consecutive writes and a read.

## Z80 and YM2610

`ss_z80.sv` and `ssz80_stub.asm`; the header of `ss_z80.sv` has the maps.

- The 68k stub asks for the Z80 (ZREQ at 0xE62000) once the picture is
  copied. At the next fetch that starts an instruction `ss_z80` answers
  `RST 38h` in place of the opcode (a halted Z80 gets INT instead), and from
  then until the stub's last `RET` it answers the Z80's reads below 0x0C00
  with the stub and a mailbox, and holds INT off. The stub pushes the
  registers, works out IFF1 from `LD A,I`, stores SP and parks. The 68k
  copies Z80 RAM (its second port) and the YM2610 shadow, then writes ZCMD:
  resume, or load. A load takes the saved SP, writes the YM2610 shadow back,
  sets the ROM banks, the reply latch and the NMI line, and both paths end
  at the same instruction: pop, `EI`/`DI`, `RET`. The Z80 and the YM2610 run
  through the menu's halt for this (`run_z80`, `YM_RUN`); the YM2610 is held
  while the Z80 is parked.
- The game's NMI (a sound command). The stub never enters while one is
  pending or being handled (fetch at 0x0066 to `RETN`); the Z80's NMI input
  is held where it was at entry while the stub runs, so an NMI raised
  meanwhile is taken at the game's PC afterwards. The line's state and the
  input's hold are saved and set again on a load.
- YM2610: `ss_z80` keeps a 512-byte shadow of every register write. Writing
  them back cannot set the timers' counts, so jt10 has a port for its timers
  and prescaler (40 bits), read at the resume point of a save and set at the
  same point of a load: the timer IRQs then come at the same Z80 cycle.
  Notes playing at the instant of the save restart rather than continue
  mid-envelope; ADPCM and SSG state is not saved.
- The NeoGeo's sound drivers use `IM 1`; the mode is not readable and is
  assumed.

## Pocket interface

`savestate.sv`. `savestate_addr` = 0x80000000 (the bridge's 0x8xxxxxxx is
otherwise unused), `savestate_size` = `maxloadsize` = 0x80000, the whole
buffer. Bridge word n is {window word 2n, window word 2n+1}, so the file is
the window in 68k byte order. On "save" (0xA0) the core acks, is busy while
the stub runs, then answers OK; the Pocket then reads the buffer. On "load"
(0xA4) the Pocket has written the buffer; the core runs the load stub and
answers OK. A stub that has not finished after 1.8 s answers error (the 68k
held in reset, say). The CPUs are halted around all of it (`cpu_halt`,
step 1); only the 68k runs, for the stub, and the Z80 and YM2610 for
theirs. To do: a header (magic, game,
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
2. The same for the Z80 (`sim/ssz80`): T80 (converted by GHDL) running
   Metal Slug's M1 ROM, with `z80ctrl`, `zmc`, jt10 and sound commands, the
   68k's side played by the C++. Its points save with an NMI pending, inside
   the NMI handler and with wait states on every read. Then both CPUs
   together in `sim/savestate`, the 68k stub driving `ss_z80`.
   With `SS_CHIP` the bench's PORT zone has `neo_sma` or `neo_pvc` over a
   P2 ROM made from its addresses; their state is set to noise before the
   save and again before the load, and must come back as the save found it.
   The BIOS never touches the PORT zone, so this checks the stub's copy, not
   a game's use of the chip.
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
4. Z80 + YM2610 (in both benches; hardware test pending).
5. Cart chips: SMA and PVC (in `sim/savestate`, `SS_CHIP`; hardware test
   pending). Then memory card, backup RAM.
