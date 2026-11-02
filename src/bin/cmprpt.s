*---------------------------------------------------------------
* cmprpt.s -- cmp's reporting half: DIFFER/EOFCOMMON/OPENERR and
* -l's PRLPAIR/OCT3, and the 24-bit
* decimal printer PR3NUM/U3DEC. Split from cmp.s
* 2026-09-01 at the
* DIFFER global boundary for as's 16128-byte source window
* (check_dialect hazard 3b): -l pushed the single-file unit
* over. One assembly stream, put by cmp.s before the liba
* modules; every manifest-header rule applies unchanged.
*---------------------------------------------------------------

*---------------------------------------------------------------
* DIFFER -- report the first difference and exit 1. POSIX's own
* STDOUT section gives this message's exact format and says it
* goes to STANDARD OUTPUT (verified live against BSD cmp:
* stdout, exit 1, nothing on stderr) -- unlike EOFCOMMON/
* OPENERR below, which stay on stderr as ordinary diagnostics.
* 2026-09-13 fix: this routine used to write FD_STDERR always.
*---------------------------------------------------------------
DIFFER      lda   WANT_S
            bne   :dsil
            lda   F1IDX
            jsr   GETARG
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   F2IDX
            jsr   GETARG                ;PUTS above clobbered
                                        ;PTR0 -- re-fetch
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #<DIFFMID
            sta   PTR0
            lda   #>DIFFMID
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   BYTECNT
            sta   N3VAL
            lda   BYTECNT+1
            sta   N3VAL+1
            lda   BYTECNT+2
            sta   N3VAL+2
            ldx   #FD_STDOUT
            jsr   PR3NUM
            lda   #<LINEMID
            sta   PTR0
            lda   #>LINEMID
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            clc                          ;L = LINECNT + 1
            lda   LINECNT
            adc   #1
            sta   N3VAL
            lda   LINECNT+1
            adc   #0
            sta   N3VAL+1
            lda   LINECNT+2
            adc   #0
            sta   N3VAL+2
            ldx   #FD_STDOUT
            jsr   PR3NUM
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:dsil       lda   #1
            jsr   EXIT

*---------------------------------------------------------------
* EOFCOMMON -- one file ended before the other. IN: SHORTIDX =
* argv index of the shorter file.
*---------------------------------------------------------------
EOFCOMMON   lda   WANT_S
            bne   :esil
            lda   #<EOFMSG
            sta   PTR0
            lda   #>EOFMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   SHORTIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
:esil       lda   #1
            jsr   EXIT

*---------------------------------------------------------------
* OPENERR -- IN: OERRIDX = argv index of the file that failed to
* open. Exit 2 -- always reported, -s does not silence this.
*---------------------------------------------------------------
OPENERR     lda   #<OPENMSG
            sta   PTR0
            lda   #>OPENMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   OERRIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* PRLPAIR -- one -l line: "%6d %3o %3o" + CR to stdout, BSD
* cmp's exact bytes. IN: BYTECNT (1-based offset), CURB1/CURB2.
*---------------------------------------------------------------
PRLPAIR     lda   BYTECNT
            sta   N3VAL
            lda   BYTECNT+1
            sta   N3VAL+1
            lda   BYTECNT+2
            sta   N3VAL+2
            lda   #<N3BUF
            sta   PTR1
            lda   #>N3BUF
            sta   PTR1+1
            jsr   U3DEC                 ;A = digit count 1..8
            sta   PADTMP
            cmp   #6
            bcs   :nopad                ;7-8 digits overflow %6d
            lda   #6
            sec
            sbc   PADTMP
            tax
:pad        lda   #$A0
            phx
            ldx   #FD_STDOUT
            jsr   PUTC
            plx
            dex
            bne   :pad
:nopad      lda   #<N3BUF
            sta   PTR0
            lda   #>N3BUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   CURB1
            jsr   OCT3
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   CURB2
            jsr   OCT3
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PR3NUM -- print N3VAL (24-bit) as decimal to fd X. Same
* contract as liba's PRNUM, one byte wider. CLOBBERS A,X,Y,PTR0,
* PTR1, N3VAL.
*---------------------------------------------------------------
PR3NUM      stx   N3FD
            lda   #<N3BUF
            sta   PTR1
            lda   #>N3BUF
            sta   PTR1+1
            jsr   U3DEC
            lda   #<N3BUF
            sta   PTR0
            lda   #>N3BUF
            sta   PTR0+1
            ldx   N3FD
            jsr   PUTS
            rts

*---------------------------------------------------------------
* U3DEC -- N3VAL (24-bit unsigned) -> decimal string at (PTR1),
* NUL-terminated, A = digit count (1..8). Repeated subtraction
* of eight powers of ten; same shape as ls's U3DEC (src/bin/
* lsprint.s) and liba's U2DEC, one byte wider. liba has no
* 24-bit printer; ls's is private to ls.s. Consumes N3VAL.
*---------------------------------------------------------------
U3DEC       ldy   #0
            stz   N3LZ
            ldx   #0
:digitloop  stz   N3DIG
:sub8       lda   POW8+2,x
            sta   N3SUB+2
            lda   POW8+1,x
            sta   N3SUB+1
            lda   POW8,x
            sta   N3SUB
            lda   N3VAL+2
            cmp   N3SUB+2
            bcc   :nodig
            bne   :dosub
            lda   N3VAL+1
            cmp   N3SUB+1
            bcc   :nodig
            bne   :dosub
            lda   N3VAL
            cmp   N3SUB
            bcc   :nodig
:dosub      sec
            lda   N3VAL
            sbc   N3SUB
            sta   N3VAL
            lda   N3VAL+1
            sbc   N3SUB+1
            sta   N3VAL+1
            lda   N3VAL+2
            sbc   N3SUB+2
            sta   N3VAL+2
            inc   N3DIG
            bra   :sub8
:nodig      lda   N3DIG
            bne   :emit
            lda   N3LZ
            bne   :emit
            cpx   #21                   ;units position
            beq   :emit
            bra   :skip
:emit       lda   #1
            sta   N3LZ
            lda   N3DIG
            ora   #$B0
            sta   (PTR1),y
            iny
:skip       inx
            inx
            inx
            cpx   #24
            bne   :digitloop
            lda   #0
            sta   (PTR1),y
            tya
            rts

POW8        dfb   $80,$96,$98           ;10,000,000
            dfb   $40,$42,$0F           ;1,000,000
            dfb   $A0,$86,$01           ;100,000
            dfb   $10,$27,$00           ;10,000
            dfb   $E8,$03,$00           ;1,000
            dfb   $64,$00,$00           ;100
            dfb   $0A,$00,$00           ;10
            dfb   $01,$00,$00           ;1

*---------------------------------------------------------------
* OCT3 -- A as three octal digits, leading zeros as SPACES (a
* zero byte prints "  0"), matching the reference's %3o.
*---------------------------------------------------------------
OCT3        sta   OCTB
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a                     ;d1 = bits 7-6
            beq   :z1
            ora   #$B0                  ;'0' high-bit
            ldx   #FD_STDOUT
            jsr   PUTC
            bra   :mid
:z1         lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   OCTB
            and   #$38                  ;middle digit zero too?
            beq   :z2
:mid        lda   OCTB
            lsr   a
            lsr   a
            lsr   a
            and   #7
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            bra   :last
:z2         lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
:last       lda   OCTB
            and   #7
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts
