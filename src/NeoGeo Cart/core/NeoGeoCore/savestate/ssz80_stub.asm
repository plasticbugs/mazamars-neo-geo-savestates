; Z80 savestate stub (docs/savestate-design.md), sjasmplus syntax.
;
; ss_z80 brings the Z80 here, to 0x0038, by answering RST 38h in place of
; the opcode of the instruction it was about to run, or by an interrupt if
; it was halted. It answers the stub's reads below 0x0C00 (see ss_z80.sv);
; RAM, the stack included, is the game's.
;
; Push every register on the game's stack, park (SP to the mailbox), wait
; for the 68k stub: it copies Z80 RAM and the YM2610 shadow out (save) or in
; (load), then says resume or load. Load takes the new SP, writes the
; YM2610's registers back from the shadow, restores the ROM banks, the
; reply latch, the NMI line (z80ctrl's flop: low from a command until a
; port 0 read) and what the Z80 saw of it. Both then pass the resume point,
; where ss_z80 reads or sets the YM2610's timers, restore the NMI enable,
; pop, and return.
;
; ss_z80 holds the Z80's NMI input while the stub runs. An NMI taken inside
; the stub (only when a load lowers the hold) comes to 0x0066, and is dropped.
;
; No CALLs: the return addresses would be left below the game's stack, in
; the RAM being saved.
;
; Build: tools/build_stub.sh, which writes ssz80_stub_rom.sv.

        DEVICE NOSLOT64K

ZCMD    EQU     0x0A00          ; read: 0 wait, 1 resume, 2 load. write: parked
ZFLAG   EQU     0x0A01          ; read: bit 0 entered by INT. write: done
ZSP     EQU     0x0A02          ; read: the SP to load. write: SP when parked
ZNMI    EQU     0x0A04          ; read: bit 0 NMI enabled, bit 1 NMI line low,
                                ; bit 2 the Z80's NMI input held low
ZREP    EQU     0x0A05          ; read: the reply latch
ZBANK   EQU     0x0A06          ; read: ROM bank windows 0-3
ZRESUME EQU     0x0A0A          ; write: the resume point (the YM2610's timers)
ZPULSE  EQU     0x0A0B          ; write: pulse z80ctrl's nSDW, as a command does
ZHOLD   EQU     0x0A0C          ; write: hold the Z80's NMI input as ZNMI bit 2
YMSH    EQU     0x0800          ; the YM2610 shadow: part A, then part B

        ORG     0x0038
        jp      entry

        ORG     0x0066
        retn

        ; Where SP points while the hold is set: an NMI's push writes into
        ; ROM space, which keeps nothing, and its RETN returns through this
        ; word
nmi_ret:
        dw      entry.nmi_done
NMISTACK EQU    $

entry:
        push    af
        push    bc
        push    de
        push    hl
        push    ix
        push    iy
        ex      af,af'
        exx
        push    af
        push    bc
        push    de
        push    hl
        ld      a,(ZFLAG)
        rra
        jr      c,.by_int       ; an interrupt: the return address is right, IFF1 was 1
        ld      hl,20           ; RST pushed the address after the opcode it
        add     hl,sp           ; replaced, ten pushes up: move it back by one
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        dec     de
        ld      (hl),d
        dec     hl
        ld      (hl),e
        ld      a,i             ; P/V = IFF2, which is IFF1 outside an NMI
        ld      b,0
        jp      po,.iff
        ld      b,1
        jr      .iff
.by_int:
        ld      b,1
.iff:
        ld      a,i
        ld      c,a
        push    bc              ; B = IFF1, C = I
        ld      (ZSP),sp
        out     (0x18),a        ; no NMI while parked
        ld      (ZCMD),a        ; parked
.wait:
        ld      a,(ZCMD)
        or      a
        jr      z,.wait
        cp      2
        jp      nz,.resume

        ; Load: the 68k has written RAM and the shadow
        ld      sp,(ZSP)

        ; The YM2610's registers, each part in order, leaving out what would
        ; start sounds: key on (A 0x28), ADPCM-B start (A 0x10), ADPCM-A (B 0x00)
        ld      hl,YMSH
        ld      e,0
.part_a:
        ld      a,e
        cp      0x10
        jr      z,.next_a
        cp      0x28
        jr      z,.next_a
        out     (4),a
.busy_a1:
        in      a,(4)
        rla
        jr      c,.busy_a1
        ld      a,(hl)
        out     (5),a
.busy_a2:
        in      a,(4)
        rla
        jr      c,.busy_a2
.next_a:
        inc     hl
        inc     e
        jr      nz,.part_a
.part_b:
        ld      a,e
        or      a
        jr      z,.next_b
        out     (6),a
.busy_b1:
        in      a,(4)
        rla
        jr      c,.busy_b1
        ld      a,(hl)
        out     (7),a
.busy_b2:
        in      a,(4)
        rla
        jr      c,.busy_b2
.next_b:
        inc     hl
        inc     e
        jr      nz,.part_b

        ; The ROM bank windows: a read of port 8-11 with the bank on A8-A15
        ld      a,(ZBANK)
        ld      b,a
        ld      c,0x08
        in      a,(c)
        ld      a,(ZBANK+1)
        ld      b,a
        ld      c,0x09
        in      a,(c)
        ld      a,(ZBANK+2)
        ld      b,a
        ld      c,0x0A
        in      a,(c)
        ld      a,(ZBANK+3)
        ld      b,a
        ld      c,0x0B
        in      a,(c)
        ld      a,(ZREP)
        out     (0x0C),a

        ; The NMI line, which the Z80 does not see while held. High: a port
        ; 0 read clears it. Low: with NMIs on, a pulse on nSDW sets it
        ld      a,(ZNMI)
        and     2
        jr      nz,.line_low
        in      a,(0)
        jr      .hold
.line_low:
        out     (0x08),a
        ld      (ZPULSE),a
.hold:
        ; Then what the Z80 saw of it: lowering that raises an NMI, taken
        ; by the end of the NOPs
        ld      sp,NMISTACK
        ld      (ZHOLD),a
        nop
        nop
.nmi_done:
        ld      sp,(ZSP)

.resume:
        ld      (ZRESUME),a     ; save reads the timers here, load sets them
        ld      a,(ZNMI)
        rra
        jr      nc,.nmi_off
        out     (0x08),a
        jr      .nmi_set
.nmi_off:
        out     (0x18),a
.nmi_set:
        pop     bc
        ld      a,c
        ld      i,a
        ld      a,b
        ld      (ZFLAG),a       ; done: the next RET leaves the stub
        or      a
        jr      z,.exit_di
        pop     hl
        pop     de
        pop     bc
        pop     af
        exx
        ex      af,af'
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        pop     af
        ei
        ret
.exit_di:
        pop     hl
        pop     de
        pop     bc
        pop     af
        exx
        ex      af,af'
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        pop     af
        di
        ret

        SAVEBIN "ssz80_stub.bin", 0, 0x0800
