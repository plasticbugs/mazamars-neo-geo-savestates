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
| No subroutines: a BSR would leave its return address below the game's
| stack, in the work RAM being saved.
|
| Build: tools/build_stub.sh (m68k-elf-as), which writes ss68k_stub_rom.sv.

        .equ    STUB,   0xE00000        | this code
        .equ    SVRAM,  0xE40000        | slow VRAM, 32K words
        .equ    FVRAM,  0xE50000        | fast VRAM, 2K words
        .equ    CTRL,   0xE7FF00        | read: 0 save, 1 load.  write: done
        .equ    SHAD,   0xE7FF10        | shadows of write-only registers:
                                        |   +0 system latch (bit n = latch n)
                                        |   +2 LSPC VRAM address, +4 modulo,
                                        |   +6 mode as written, +8 P-ROM bank
        .equ    WIN,    0xE80000        | the window onto the savestate buffer
        .equ    REGS,   WIN+0x40        | D0-D7, A0-A6: 60 bytes
        .equ    USPV,   WIN+0x7C
        .equ    SSPV,   WIN+0x80
        .equ    WSHAD,  WIN+0x100       | the 8 shadow words
        .equ    WRAM,   WIN+0x1000      | 64 KB of work RAM
        .equ    WPAL,   WIN+0x11000     | palette banks 0 and 1, 8 KB each
        .equ    WSVRAM, WIN+0x15000     | slow VRAM, 64 KB
        .equ    WFVRAM, WIN+0x25000     | fast VRAM, 4 KB

        .equ    PALRAM,   0x400000
        .equ    PALBANK0, 0x3A000F
        .equ    PALBANK1, 0x3A001F
        .equ    SLATCH,   0x3A0001      | latch n: write 0x3A0001 + 2n + 0x10 * value
        .equ    VRAMADDR, 0x3C0000
        .equ    VRAMMOD,  0x3C0004
        .equ    LSPCMODE, 0x3C0006
        .equ    PBANK,    0x2FFFF0

        .macro  copy src, dst, longs
        lea     \src, %a0
        lea     \dst, %a1
        move.w  #\longs-1, %d0
1:      move.l  (%a0)+, (%a1)+
        dbra    %d0, 1b
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
        movem.l REGS, %d0-%d7/%a0-%a6
        move.w  #1, CTRL
        rte

load:
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
        move.w  WSHAD+8, PBANK
        move.l  USPV, %a0
        move.l  %a0, %usp
        movea.l SSPV, %sp
        movem.l REGS, %d0-%d7/%a0-%a6
        move.w  #1, CTRL
        rte
