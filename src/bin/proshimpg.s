*---------------------------------------------------------------
* proshimpg.s -- the $BF00 shim page for proshim (TASKS.md #19,
* docs/EDASM-SHIM.md). Assembled STANDALONE at $BF00 (dsk
* build/proshim-page.bin, exactly 256 bytes) and embedded in
* proshim.bin via putbin; the loader copies it to $BF00 in its
* own bank before jumping to the tenant.
*
* What lives here and why HERE: (1) the MLI entry contract --
* `JSR $BF00` must land on a real JMP; (2) the global-page
* fields a system program reads at their REAL offsets (MACHID
* $BF98, DATE/TIME $BF90, DEVNUM $BF30, BITMAP $BF58 ...);
* (3) the two halves of the language-card discipline, which
* MUST execute below $C000: the entry samples the tenant's LC
* read state and forces LC RAM read (the core and the kernel's
* $FFxx door are LC RAM), the exit tail restores that state
* before RTS -- EDASM calls the MLI with the motherboard ROM
* switched in (learning:01M1X0F064TX9PZD2JFVEX9MJJ), and every
* kernel MLI bracket leaves the LC in the $C088 group, RAM
* read, write-protected (src/kernel/mli.s), so the tenant's
* bank selection would otherwise be lost on every call.
*
* Code fits the holes between fields; `ds ADDR-*` pins each
* field to its offset (asrom.s's literal-address idiom).
*---------------------------------------------------------------
            lst   off
            xc
            org   $BF00
            dsk   ../../build/proshimpg.bin
            typ   $00
            put   proshim.equ
            put   ../../inc/mm.hw.equ

MLIENT      jmp   PS_ENTRY               ;$BF00: the contract

* -- $BF03: entry. Save X/Y (the MLI preserves them), sample
* -- the LC read state, select the tenant's OWN bank group with
* -- RAM read + write enable (the core self-modifies), go.
PS_ENTRY    stx   PS_SAVEX
            sty   PS_SAVEY
            lda   RDLCRAM
            sta   PS_LCRAM
            lda   RDLCBNK2
            sta   PS_LCBNK
            bpl   :grp1                 ;bit7 clear -> bank1
            lda   LCBANK2_RAM            ;bank2: $C08B x2
            lda   LCBANK2_RAM
            jmp   PS_CORE
:grp1       lda   LCBANK1_RAM            ;bank1: $C083 x2
            lda   LCBANK1_RAM
            jmp   PS_CORE

            ds    $BF30-*
PG_DEVNUM   dfb   $70                    ;last device: SmartPort
                                         ;slot 7 drive 1
PG_DEVCNT   dfb   $00                    ;device count - 1
PG_DEVLST   dfb   $70                    ;one entry; rest zero
            ds    $BF33-*
PG_MKPARM   dfb   2                      ;$BF33 mark count
            ds    4                      ;$BF34 ref + 3-byte pos
            ds    $BF40-*
* $BF40-$BF49: proshim's cells (proshim.equ), zero at install
            ds    $BF4A-*
PG_WBUF     ds    1                      ;$BF4A COUT1 byte
PG_RBUF     ds    1                      ;$BF4B KEYIN byte
PG_WPARM    dfb   4,1                    ;$BF4C WRITE fd 1
            da    PS_WBUF
            dfb   1,0,0,0
            ds    $BF58-*
* BITMAP as ProDOS stamps it: pages 0,1,4-7 used, $BF used
PG_BITMAP   dfb   $CF
            ds    22
            dfb   $01
            ds    $BF90-*
PG_DATE     ds    2                      ;stamped by the loader
PG_TIME     ds    2
PG_LEVEL    dfb   0
PG_BUBIT    dfb   0
            ds    2                      ;$BF96-$BF97 spare
PG_MACHID   dfb   $B0                    ;TN #11: IIe, 128K, no
                                         ;80-col card, no clock
PG_SLTBYT   dfb   $80                    ;slot 7 has a ROM
PG_PFIXPTR  dfb   1                      ;prefix is set
PG_MLIACTV  dfb   0
PG_CMDADR   ds    2
PG_SAVEX    ds    1                      ;$BF9E
PG_SAVEY    ds    1                      ;$BF9F
            ds    $BFA0-*
PG_NLTAB    ds    16                     ;$BFA0: NEWLINE table
            ds    $BFB0-*
* -- $BFB0: exit tail. IN: A = MLI result, C = error flag.
* -- Re-select the tenant's group and ROM/RAM read state via a
* -- computed $C08x (always the write-enabled variant -- the
* -- write-protect state is not readable; EDASM re-asserts
* -- write enable before every store sequence), restore X/Y,
* -- and reload A so Z reflects the result (the kernel door
* -- patches only C in the caller's P).
PS_EXIT     php
            sta   PS_RESULT
            ldx   #$09                   ;$C089: bank2 group,
                                         ;ROM read, write-en
            bit   PS_LCBNK
            bmi   :bnk                   ;bit7 set -> keep bank2
            ldx   #$01                   ;$C081: bank1 group
:bnk        bit   PS_LCRAM
            bpl   :rom
            inx                          ;+2: the RAM-read twin
            inx
:rom        lda   LCBANK1_STORE,x        ;$C080,x -- double read
            lda   LCBANK1_STORE,x
            ldx   PS_SAVEX
            ldy   PS_SAVEY
            plp
            lda   PS_RESULT
            rts
            ds    $BFD6-*
PG_RPARM    dfb   4,0                    ;$BFD6 READ fd 0
            da    PS_RBUF
            dfb   1,0,0,0
            ds    $BFF0-*
            ds    12                     ;ISHACK, unused
PG_IVERSION dfb   0                      ;$BFFC
PG_KVERSION dfb   $24                    ;$BFFD: "ProDOS 2.4"
            dfb   0                      ;$BFFE
            dfb   0                      ;$BFFF
