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
| Build: tools/build_stub.sh (m68k-elf-as), which writes ss68k_stub.hex.

        .equ    STUB,   0xE00000        | this code
        .equ    CTRL,   0xE7FF00        | read: 0 save, 1 load.  write: done
        .equ    WIN,    0xE80000        | the window onto the savestate buffer
        .equ    REGS,   WIN+0x40        | D0-D7, A0-A6: 60 bytes
        .equ    USPV,   WIN+0x7C
        .equ    SSPV,   WIN+0x80
        .equ    WRAM,   WIN+0x1000      | 64 KB of work RAM

        .text
        .org    0
entry:
        tst.w   CTRL                    | flags only: the frame holds the game's SR
        bne.s   load

save:
        movem.l %d0-%d7/%a0-%a6, REGS
        move.l  %usp, %a0
        move.l  %a0, USPV
        move.l  %sp, SSPV
        lea     0x100000, %a0
        lea     WRAM, %a1
        move.w  #0x3FFF, %d0
1:      move.l  (%a0)+, (%a1)+
        dbra    %d0, 1b
        movem.l REGS, %d0-%d7/%a0-%a6
        move.w  #1, CTRL
        rte

load:
        lea     WRAM, %a0
        lea     0x100000, %a1
        move.w  #0x3FFF, %d0
1:      move.l  (%a0)+, (%a1)+
        dbra    %d0, 1b
        move.l  USPV, %a0
        move.l  %a0, %usp
        movea.l SSPV, %sp
        movem.l REGS, %d0-%d7/%a0-%a6
        move.w  #1, CTRL
        rte
