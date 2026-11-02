*---------------------------------------------------------------
* vidmode.s -- report or set THIS console's video mode.
*
* Usage: vidmode                 report cols x rows + discipline
*        vidmode 40|80           switch geometry (rows stay 24)
*        vidmode hq|card         80x24 on the UltraTerm (surf 2)
*        vidmode vt|apple        switch output discipline
*        vidmode 80 vt           both at once
*        vidmode onehead         single monitor: VIDSEL follows
*                                the active console (default)
*        vidmode dualhead        hold VIDSEL for a 2nd monitor
*                                (surface 3/4 wire; sec 11)
*
* CONTRACT (docs/VIDMODE.md sec 2): the SETTER is a write --
* `ESC [ cols ; rows ; disc v` rides the tty's escape parser,
* same no-privilege road as chvt(1) -- and the VERIFIER is
* SYS_TTYGEO, read back after an explicit flush (stdio is
* line-buffered at a tty and the sequence has no CR). The
* kernel IGNORES an impossible escape rather than erroring --
* the terminal discipline -- so it is this program's job to
* notice nothing changed and say `vidmode: refused` on stderr,
* exit 1. A UT-boot machine pins its geometry until V2, and
* that surfaces here as exactly that refusal.
*
* A stdout that is not a console (file, pipe) is refused BEFORE
* anything is written, by probing SYS_TTYGEO first -- an escape
* sequence in a redirected file helps nobody.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address, no
* kernel equates; see docs/USERLAND.md. The geo buffer's four
* bytes (cols, rows, backend id, discipline) are syscall ABI,
* documented at SYS_TTYGEO in inc/sc.proc.equ.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/vidmode.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   ARGC
            cmp   #4
            bcc   :argsok              ;at most two words
            jmp   :usage               ;(the verb table grew
                                       ;past branch range)
:argsok     stz   COLSREQ
            stz   DISCREQ
            stz   SURFREQ
            lda   #1
            sta   ARGN
:argloop    lda   ARGN
            cmp   ARGC
            bcc   :oneword
            jmp   :parsed
:oneword    jsr   GETARG               ;A = index -> PTR0
            lda   #<W40
            sta   PTR1
            lda   #>W40
            sta   PTR1+1
            jsr   STRCMPI
            bne   :try80
            lda   #40
            bra   :gotcols
:try80      lda   #<W80
            sta   PTR1
            lda   #>W80
            sta   PTR1+1
            jsr   STRCMPI
            bne   :tryhq
            lda   #80
            bra   :gotcols
:tryhq      lda   #<WHQ                ;`hq` / `card`: 80x24 on
            sta   PTR1                 ;the UltraTerm (VIDMODE
            lda   #>WHQ                ;V2.0, surface 2)
            sta   PTR1+1
            jsr   STRCMPI
            beq   :gotcard
            lda   #<WCARD
            sta   PTR1
            lda   #>WCARD
            sta   PTR1+1
            jsr   STRCMPI
            bne   :tryhead
:gotcard    lda   #2
            sta   SURFREQ
            lda   #80
:gotcols    ldx   COLSREQ              ;`vidmode 40 80` is a
            bne   :usage               ;contradiction, not a
            sta   COLSREQ              ;preference -- usage, not
            bra   :nextarg             ;last-one-wins (V1
                                       ;finding 5)
*-- `onehead`/`dualhead`: the machine head mode rides the mode
*-- escape's surface field (3/4), VIDMODE V2.1
:tryhead    lda   #<WONE
            sta   PTR1
            lda   #>WONE
            sta   PTR1+1
            jsr   STRCMPI
            bne   :trydual
            lda   #3                   ;onehead -> surface 3
            bra   :gothead
:trydual    lda   #<WDUAL
            sta   PTR1
            lda   #>WDUAL
            sta   PTR1+1
            jsr   STRCMPI
            bne   :tryvt
            lda   #4                   ;dualhead -> surface 4
:gothead    ldx   SURFREQ              ;one surface verb only
            bne   :usage
            sta   SURFREQ
            bra   :nextarg
:tryvt      lda   #<WVT
            sta   PTR1
            lda   #>WVT
            sta   PTR1+1
            jsr   STRCMPI
            bne   :tryap
            lda   #1                   ;wire code 1 = vt
            bra   :gotdisc
:tryap      lda   #<WAPPLE
            sta   PTR1
            lda   #>WAPPLE
            sta   PTR1+1
            jsr   STRCMPI
            bne   :usage
            lda   #2                   ;wire code 2 = apple
:gotdisc    ldx   DISCREQ              ;same for vt vs apple
            bne   :usage
            sta   DISCREQ
:nextarg    inc   ARGN
            jmp   :argloop

:usage      lda   #<USAGEMSG
            ldx   #>USAGEMSG
            jsr   ERRLINE
            lda   #2
            jmp   EXIT

:parsed     jsr   GEOPROBE             ;refuse a non-console
            bcc   :onatty              ;BEFORE writing anything
            lda   #<NOTTYMSG
            ldx   #>NOTTYMSG
            jsr   ERRLINE
            lda   #1
            jmp   EXIT
:onatty     lda   ARGC
            cmp   #2
            bcs   :setmode
            jsr   PRMODE               ;bare vidmode: report
            lda   #0
            jmp   EXIT

*-- The setter. Byte-at-a-time PUTCs for the same reason as
*-- chvt.s: a patched-in-place sequence makes the text mutable
*-- and check_purity refuses that (STICKY.md sec 29).
:setmode    lda   #$9B                 ;ESC
            jsr   PUTOUT
            lda   #$DB                 ;[
            jsr   PUTOUT
            lda   COLSREQ
            beq   :nocols
            cmp   #80
            beq   :c8
            lda   #$B4                 ;'4'
            bra   :cd
:c8         lda   #$B8                 ;'8'
:cd         jsr   PUTOUT
            lda   #$B0                 ;'0'
            jsr   PUTOUT
            lda   #$BB                 ;';'
            jsr   PUTOUT
            lda   #$B2                 ;'2'  rows: V1 is always
            jsr   PUTOUT               ;24 -- the kernel refuses
            lda   #$B4                 ;'4'  anything else
            jsr   PUTOUT
            bra   :disc
:nocols     lda   #$B0                 ;'0' -- keep geometry
            jsr   PUTOUT
            lda   #$BB                 ;';'
            jsr   PUTOUT
            lda   #$B0                 ;'0'
            jsr   PUTOUT
:disc       lda   #$BB                 ;';'
            jsr   PUTOUT
            lda   DISCREQ              ;0 = keep discipline
            clc
            adc   #$B0
            jsr   PUTOUT
            lda   SURFREQ              ;param 4 only when asked
            beq   :final               ;(0 = derive, the old
            lda   #$BB                 ;three-param wire)
            jsr   PUTOUT
            lda   SURFREQ
            clc
            adc   #$B0
            jsr   PUTOUT
:final      lda   #$F6                 ;'v'
            jsr   PUTOUT
            ldx   #FD_STDOUT           ;stdio holds escapes at a
            jsr   SIO_FLUSH            ;tty until a CR -- push
                                       ;them through NOW so the
                                       ;read-back sees the truth
            jsr   GEOPROBE
            bcs   :refused             ;cannot happen, but a
            lda   COLSREQ              ;probe error is a refusal
            beq   :ckdisc
            cmp   GEOBUF
            bne   :refused
:cksurf     lda   COLSREQ              ;a geometry request: the
            beq   :ckdisc              ;backend must match the
            lda   GEOBUF+2             ;surface asked for --
            cmp   #1                   ;1 = TTY_BKUT (tty.equ)
            beq   :isut
            lda   SURFREQ              ;not on the card: fine
            cmp   #2                   ;unless the card was
            beq   :refused             ;asked for
            bra   :ckdisc
:isut       lda   SURFREQ              ;on the card: fine only
            cmp   #2                   ;if the card was asked
            bne   :refused             ;for
:ckdisc     lda   DISCREQ
            beq   :won
            sec
            sbc   #1                   ;wire 1/2 -> stored 0/1
            cmp   GEOBUF+3
            bne   :refused
:won        jsr   PRMODE
            lda   #0
            jmp   EXIT
:refused    lda   #<REFUSMSG
            ldx   #>REFUSMSG
            jsr   ERRLINE
            lda   #1
            jmp   EXIT

*---------------------------------------------------------------
* GEOPROBE -- SC_TTYGEO(GEOBUF, stdout). Carry per the syscall.
*---------------------------------------------------------------
GEOPROBE    lda   #<GEOBUF
            sta   PTR0
            lda   #>GEOBUF
            sta   PTR0+1
            lda   #FD_STDOUT
            jsr   SC_TTYGEO
            rts

*---------------------------------------------------------------
* PRMODE -- print `40X24 APPLE` / `80X24 VT` + CR from GEOBUF.
*---------------------------------------------------------------
PRMODE      lda   GEOBUF
            jsr   PR2DIG
            lda   #$D8                 ;'X'
            jsr   PUTOUT
            lda   GEOBUF+1
            jsr   PR2DIG
            lda   #$A0                 ;space
            jsr   PUTOUT
            lda   GEOBUF+2             ;on the card: say HQ
            cmp   #1                   ;(TTY_BKUT)
            bne   :notut
            lda   #<WHQ
            sta   PTR0
            lda   #>WHQ
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$A0
            jsr   PUTOUT
:notut      lda   GEOBUF+3
            beq   :vt
            lda   #<WAPPLE
            sta   PTR0
            lda   #>WAPPLE
            sta   PTR0+1
            bra   :word
:vt         lda   #<WVT
            sta   PTR0
            lda   #>WVT
            sta   PTR0+1
:word       ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            jsr   PUTOUT
            rts

*-- PR2DIG -- two decimal digits from A (value < 100).
PR2DIG      stz   DIGT
:tens       cmp   #10
            bcc   :ones
            sbc   #10                  ;carry set by the cmp
            inc   DIGT
            bra   :tens
:ones       pha
            lda   DIGT
            ora   #$B0
            jsr   PUTOUT
            pla
            ora   #$B0
            jsr   PUTOUT
            rts

PUTOUT      ldx   #FD_STDOUT
            jsr   PUTC
            rts

*-- ERRLINE -- NUL string at A/X to stderr, plus CR.
ERRLINE     sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            rts

W40         asc   "40"
            dfb   $00
W80         asc   "80"
            dfb   $00
WHQ         asc   "HQ"
            dfb   $00
WCARD       asc   "CARD"
            dfb   $00
WVT         asc   "VT"
            dfb   $00
WAPPLE      asc   "APPLE"
            dfb   $00
WONE        asc   "ONEHEAD"
            dfb   $00
WDUAL       asc   "DUALHEAD"
            dfb   $00
USAGEMSG    asc   "usage: vidmode [40|80|hq|onehead|dualhead]"
            dfb   $00
NOTTYMSG    asc   "vidmode: stdout is not a console"
            dfb   $00
REFUSMSG    asc   "vidmode: refused"
            dfb   $00

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

            dum   LIBA_BSSEND
COLSREQ     ds    1
DISCREQ     ds    1
SURFREQ     ds    1              ;wire param 4: 0 derive,
                                 ;2 card (hq/card), 3 onehead,
                                 ;4 dualhead (head mode, V2.1)
ARGN        ds    1
DIGT        ds    1
GEOBUF      ds    4
            err   */$BF00
            dend
