| 68000 savestate stub (docs/savestate-design.md).
|
| ss_m68k raises interrupt level 7 and answers the vector fetch with STUB, so
| the CPU arrives here in supervisor mode, interrupts masked, with the game's
| PC and SR in the frame it just pushed on the supervisor stack. CTRL says
| what to do; writing CTRL tells the hardware the stub is finished.
|
| Save: store D0-A6, USP and SSP (which points at the frame), copy the state
|       to the window, reload the registers, RTE: the game carries on.
| Load: copy the state back from the window (work RAM holds the saved stack
|       and frame), load USP, SSP and D0-A6, RTE: the CPU resumes at the
|       saved PC with the saved SR.
|
| A snapshot begins with a header: a magic number, the layout's version and
| the game's identity (its NGH number, and checksums of 4 KB of its P-ROM
| and of the BIOS). A load whose header does not match refuses: it changes
| nothing and writes CTRL with bit 1 set, which the Pocket is told as an
| error.
|
| The cartridge's chip, by its type (CTYPE): an SMA's bank and RNG through
| ss_m68k, loaded with one PORT-zone write and one read while CLOAD is set;
| a PVC's 8 KB of RAM through the bus, its bank and colour registers with it
| (its top 32 bytes: each port reads back what was written to it, or what
| writing it back restores). Without a chip, the P-ROM bank; a snapshot of
| another kind of chip restores none.
|
| The Z80 (ss_z80.sv, ssz80_stub.asm): ask for it (ZREQ), wait until it
| parks, copy its RAM and the YM2610 shadow out or in, tell it to resume or
| load, wait until it leaves its stub. Every wait gives up after ~0.1 s; a
| save then records no Z80 (WZOK 0), and loading such a snapshot leaves the
| Z80 as it is.
|
| No subroutines: a BSR would leave its return address below the game's
| stack, in the work RAM being saved.
|
| Build: tools/build_stub.sh (m68k-elf-as), which writes ss68k_stub_rom.sv.

        .equ    STUB,   0xE00000        | this code
        .equ    SVRAM,  0xE40000        | slow VRAM, 32K words
        .equ    FVRAM,  0xE50000        | fast VRAM, 2K words
        .equ    CTRL,   0xE7FF00        | read: 0 save, 1 load.  write: done,
                                        |   bit 1: the load refused
        .equ    SHAD,   0xE7FF10        | shadows of write-only registers:
                                        |   +0 system latch (bit n = latch n)
                                        |   +2 LSPC VRAM address, +4 modulo,
                                        |   +6 mode as written, +8 P-ROM bank
        .equ    WIN,    0xE80000        | the window onto the savestate buffer
        .equ    WHDR,   WIN+0x00        | magic, version, NGH, P-ROM sum, BIOS sum
        .equ    WKEEP,  WIN+0x20        | a refused load keeps D0-D3/A0 here
        .equ    REGS,   WIN+0x40        | D0-D7, A0-A6: 60 bytes
        .equ    MAGIC,  0x4E475353      | "NGSS"
        .equ    VERSION, 1
        .equ    USPV,   WIN+0x7C
        .equ    SSPV,   WIN+0x80
        .equ    WSHAD,  WIN+0x100       | the 8 shadow words
        .equ    WRAM,   WIN+0x1000      | 64 KB of work RAM
        .equ    WPAL,   WIN+0x11000     | palette banks 0 and 1, 8 KB each
        .equ    WSVRAM, WIN+0x15000     | slow VRAM, 64 KB
        .equ    WFVRAM, WIN+0x25000     | fast VRAM, 4 KB
        .equ    WZOK,   WIN+0x120       | 1: the Z80 part below was saved
        .equ    WZSP,   WIN+0x122       | its SP, parked
        .equ    WZNMI,  WIN+0x124       | bit 0 NMI on, 1 line low, 2 input held low
        .equ    WZREP,  WIN+0x126       | the reply latch
        .equ    WZYM,   WIN+0x128       | the YM2610's timers, 3 words
        .equ    WZRAM,  WIN+0x26000     | Z80 RAM, a byte a word, 4 KB
        .equ    WYM,    WIN+0x27000     | the YM2610 shadow, a byte a word, 1 KB
        .equ    WCHIP,  WIN+0x130       | the chip's type, then the SMA's bank
                                        | (2 words) and RNG
        .equ    WPVC,   WIN+0x28000     | the PVC's RAM, 8 KB

        | ss_m68k's chip block, for neo_sma
        .equ    CBANKH, 0xE7FF20
        .equ    CBANKL, 0xE7FF22
        .equ    CRNG,   0xE7FF24
        .equ    CTYPE,  0xE7FF26        | read: 0 none, 2 PVC, 3-7 SMA.  write: CLOAD
        .equ    CLOAD,  0xE7FF26

        | ss_z80's AUX port: the shadow words 5-7 are its ROM banks {1,0},
        | {3,2} and {NMI enable, command latch}
        .equ    ZRAM,   0xE60000
        .equ    ZYM,    0xE61000
        .equ    ZSTAT,  0xE62000        | read: bit 0 parked, 1 exited, 2 line low,
                                        | 3 input held low.  write: ZREQ
        .equ    ZSP,    0xE62002
        .equ    ZCMD,   0xE62004        | 1 resume, 2 load
        .equ    ZNMI,   0xE62006
        .equ    ZREP,   0xE62008
        .equ    ZBANK,  0xE6200A        | 4 words
        .equ    ZTIMER, 0xE62012        | 3 words
        .equ    ZWAIT,  0x8000          | ~0.1 s of polling
        .equ    SOUND,  0x320000        | read: the reply.  write: the command

        .equ    PALRAM,   0x400000
        .equ    PALBANK0, 0x3A000F
        .equ    PALBANK1, 0x3A001F
        .equ    SLATCH,   0x3A0001      | latch n: write 0x3A0001 + 2n + 0x10 * value
        .equ    VRAMADDR, 0x3C0000
        .equ    VRAMMOD,  0x3C0004
        .equ    LSPCMODE, 0x3C0006
        .equ    PBANK,    0x2FFFF0
        .equ    PORTZ,    0x200000
        .equ    PVCRAM,   0x2FE000

        | The game's identity: D1 its NGH number, D2 a checksum of its P-ROM
        | (0x000100-0x0010FF) and D3 one of the BIOS's (0xC00100-0xC010FF),
        | both past the 128 bytes of vectors that nVEC swaps between them
        .macro  ident
        move.w  0x000108, %d1
        moveq   #0, %d2
        lea     0x000100, %a0
        move.w  #0x3FF, %d0
1:      rol.l   #1, %d2
        add.l   (%a0)+, %d2
        dbra    %d0, 1b
        moveq   #0, %d3
        lea     0xC00100, %a0
        move.w  #0x3FF, %d0
2:      rol.l   #1, %d3
        add.l   (%a0)+, %d3
        dbra    %d0, 2b
        .endm

        .macro  copy src, dst, longs
        lea     \src, %a0
        lea     \dst, %a1
        move.w  #\longs-1, %d0
1:      move.l  (%a0)+, (%a1)+
        dbra    %d0, 1b
        .endm

        | Wait until ZSTAT bit \bit is set, or branch to \fail
        .macro  zwait bit, fail
        move.l  #ZWAIT, %d1
1:      btst    #\bit, ZSTAT+1
        bne.s   2f
        subq.l  #1, %d1
        bne.s   1b
        bra     \fail
2:
        .endm

        .text
        .org    0
entry:
        tst.w   CTRL                    | flags only: the frame holds the game's SR
        bne     load

save:
        movem.l %d0-%d7/%a0-%a6, REGS
        move.l  %usp, %a0
        move.l  %a0, USPV
        move.l  %sp, SSPV
        ident
        move.l  #MAGIC, WHDR
        move.w  #VERSION, WHDR+4
        move.w  %d1, WHDR+6
        move.l  %d2, WHDR+8
        move.l  %d3, WHDR+12
        copy    SHAD, WSHAD, 4
        copy    0x100000, WRAM, 0x4000
        move.b  %d0, PALBANK0
        copy    PALRAM, WPAL, 0x800
        move.b  %d0, PALBANK1
        copy    PALRAM, WPAL+0x2000, 0x800
        btst    #7, WSHAD+1             | back to the game's bank, as saved
        bne.s   2f
        move.b  %d0, PALBANK0
2:      copy    SVRAM, WSVRAM, 0x4000
        copy    FVRAM, WFVRAM, 0x400

        move.w  CTYPE, %d0              | the cartridge's chip
        move.w  %d0, WCHIP
        cmp.w   #2, %d0
        blo.s   7f
        bne.s   6f
        copy    PVCRAM, WPVC, 0x800
        bra.s   7f
6:      move.w  CBANKH, WCHIP+2
        move.w  CBANKL, WCHIP+4
        move.w  CRNG, WCHIP+6
7:

        clr.w   WZOK                    | the Z80, after the shadows (its NMI enable)
        move.w  #1, ZSTAT
        zwait   0, 9f
        move.w  ZSP, WZSP
        moveq   #0, %d0
        move.b  WSHAD+0x0E, %d0         | bit 0: NMI enabled
        move.w  ZSTAT, %d2
        btst    #2, %d2
        beq.s   3f
        bset    #1, %d0
3:      btst    #3, %d2
        beq.s   4f
        bset    #2, %d0
4:      move.w  %d0, WZNMI
        move.w  %d0, ZNMI               | the stub restores the NMI enable from it
        moveq   #0, %d0
        move.b  SOUND, %d0
        move.w  %d0, WZREP
        copy    ZRAM, WZRAM, 0x400
        copy    ZYM, WYM, 0x100
        move.w  #1, ZCMD                | resume
        zwait   1, 9f
        move.w  ZTIMER, WZYM
        move.w  ZTIMER+2, WZYM+2
        move.w  ZTIMER+4, WZYM+4
        move.w  #1, WZOK
9:
        movem.l REGS, %d0-%d7/%a0-%a6
        move.w  #1, CTRL
        rte

load:
        movem.l %d0-%d3/%a0, WKEEP      | the game's, should the load refuse
        ident
        cmp.l   #MAGIC, WHDR
        bne.s   refuse
        cmp.w   #VERSION, WHDR+4
        bne.s   refuse
        cmp.w   WHDR+6, %d1
        bne.s   refuse
        cmp.l   WHDR+8, %d2
        bne.s   refuse
        cmp.l   WHDR+12, %d3
        beq.s   1f
refuse:
        movem.l WKEEP, %d0-%d3/%a0
        move.w  #3, CTRL
        rte
1:
        copy    WRAM, 0x100000, 0x4000
        move.b  %d0, PALBANK0
        copy    WPAL, PALRAM, 0x800
        move.b  %d0, PALBANK1
        copy    WPAL+0x2000, PALRAM, 0x800
        copy    WSVRAM, SVRAM, 0x4000
        copy    WFVRAM, FVRAM, 0x400
        move.w  WSHAD, %d1              | the system latch, palette bank included
        lea     SLATCH, %a0
        moveq   #7, %d0
3:      lsr.w   #1, %d1
        bcc.s   4f
        move.b  %d0, 0x10(%a0)
        bra.s   5f
4:      move.b  %d0, (%a0)
5:      addq.l  #2, %a0
        dbra    %d0, 3b
        move.w  WSHAD+4, VRAMMOD
        move.w  WSHAD+6, LSPCMODE
        move.w  WSHAD+2, VRAMADDR

        move.w  CTYPE, %d0              | the cartridge's chip
        bne.s   6f
        move.w  WSHAD+8, PBANK          | none: the P-ROM bank
        bra.s   8f
6:      cmp.w   WCHIP, %d0
        bne.s   8f                      | a snapshot from another kind of chip
        cmp.w   #2, %d0
        bne.s   7f
        copy    WPVC, PVCRAM, 0x800
        bra.s   8f
7:      move.w  WCHIP+2, CBANKH
        move.w  WCHIP+4, CBANKL
        move.w  WCHIP+6, CRNG
        move.w  #1, CLOAD
        move.w  %d0, PORTZ              | the bank
        tst.w   PORTZ                   | the RNG
        move.w  #0, CLOAD
8:

        tst.w   WZOK                    | the Z80, if the snapshot has it
        beq     9f
        move.w  #1, ZSTAT
        zwait   0, 9f
        copy    WZRAM, ZRAM, 0x400
        copy    WYM, ZYM, 0x100
        move.b  WSHAD+0x0F, SOUND       | the command latch; the Z80 has NMIs off
        move.w  WZSP, ZSP
        move.w  WZNMI, ZNMI
        move.w  WZREP, ZREP
        moveq   #0, %d0
        move.b  WSHAD+0x0B, %d0         | the banks: word 5 is {1, 0}, 6 is {3, 2}
        move.w  %d0, ZBANK
        move.b  WSHAD+0x0A, %d0
        move.w  %d0, ZBANK+2
        move.b  WSHAD+0x0D, %d0
        move.w  %d0, ZBANK+4
        move.b  WSHAD+0x0C, %d0
        move.w  %d0, ZBANK+6
        move.w  WZYM, ZTIMER
        move.w  WZYM+2, ZTIMER+2
        move.w  WZYM+4, ZTIMER+4
        move.w  #2, ZCMD                | load
        zwait   1, 9f
9:
        move.l  USPV, %a0
        move.l  %a0, %usp
        movea.l SSPV, %sp
        movem.l REGS, %d0-%d7/%a0-%a6
        move.w  #1, CTRL
        rte
