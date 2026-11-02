*---------------------------------------------------------------
* bpatchd.s -- bpatch's back half: the three directive appliers
* (DIR_SET/DIR_EXPECT/DIR_FLIPLC), WRITEBACK (the final
* LSEEK+WRITE-loop+CLOSE), OPENFAIL (the open-failure reporter),
* every fatal-error exit + its message, and the keyword table
* PROCLINE dispatches against. Split from bpatch.s 2026-09-07,
* put immediately after bpatchp.s -- see that file's header for
* why. One assembly stream; every rule in bpatch.s's own header
* applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* DIR_SET -- `set OFF B [B ...]`. PTR0 is already positioned
* right after the "set" word (PROCLINE's own READWORD left it
* there, not having consumed trailing whitespace). Every B is
* written into TBUF as it is parsed -- OFF+bytes-written-so-far
* is checked against TLEN before each write, which is the same
* condition as the spec's whole-sum check (the first violation
* happens at the same byte either way), and lets the error EXIT
* immediately without a separate pre-pass. At least one B is
* required.
*---------------------------------------------------------------
DIR_SET     jsr   SKIPWS
            lda   PTR0+1
            cmp   LINEEND+1
            bcc   :ds1
            bne   :ds2
            lda   PTR0
            cmp   LINEEND
            bcc   :ds1
:ds2        jmp   ERR_BADSPEC
:ds1        jsr   READWORD
            jsr   HEXPARSE16
            bcc   :ds3
            jmp   ERR_BADSPEC
:ds3        stz   GOTONE
            clc
            lda   #<TBUF
            adc   OFFVAL
            sta   PTR1
            lda   #>TBUF
            adc   OFFVAL+1
            sta   PTR1+1
:ds4        jsr   SKIPWS
            lda   PTR0+1
            cmp   LINEEND+1
            bcc   :ds5
            bne   :ds6
            lda   PTR0
            cmp   LINEEND
            bcc   :ds5
:ds6        lda   GOTONE
            bne   :ds7
            jmp   ERR_BADSPEC
:ds7        rts
:ds5        jsr   READWORD
            jsr   HEXPARSE8
            bcc   :ds8
            jmp   ERR_BADSPEC
:ds8        pha
            lda   OFFVAL+1
            cmp   TLEN+1
            bcc   :ds9
            bne   :ds10
            lda   OFFVAL
            cmp   TLEN
            bcc   :ds9
:ds10       pla
            jmp   ERR_SETPAST
:ds9        pla
            sta   (PTR1)
            inc   PTR1
            bne   :ds11
            inc   PTR1+1
:ds11       inc   OFFVAL
            bne   :ds12
            inc   OFFVAL+1
:ds12       lda   #1
            sta   GOTONE
            jmp   :ds4

*---------------------------------------------------------------
* DIR_EXPECT -- `expect OFF B`. OFF must be < TLEN ("expect past
* end of file"); TBUF[OFF] must equal B ("expect failed").
*---------------------------------------------------------------
DIR_EXPECT  jsr   SKIPWS
            lda   PTR0+1
            cmp   LINEEND+1
            bcc   :de1
            bne   :de2
            lda   PTR0
            cmp   LINEEND
            bcc   :de1
:de2        jmp   ERR_BADSPEC
:de1        jsr   READWORD
            jsr   HEXPARSE16
            bcc   :de3
            jmp   ERR_BADSPEC
:de3        jsr   SKIPWS
            lda   PTR0+1
            cmp   LINEEND+1
            bcc   :de4
            bne   :de2
            lda   PTR0
            cmp   LINEEND
            bcc   :de4
            bra   :de2
:de4        jsr   READWORD
            jsr   HEXPARSE8
            bcc   :de5
            jmp   ERR_BADSPEC
:de5        sta   BYTETMP
            lda   OFFVAL+1
            cmp   TLEN+1
            bcc   :de6
            bne   :de7
            lda   OFFVAL
            cmp   TLEN
            bcc   :de6
:de7        jmp   ERR_EXPPAST
:de6        clc
            lda   #<TBUF
            adc   OFFVAL
            sta   PTR1
            lda   #>TBUF
            adc   OFFVAL+1
            sta   PTR1+1
            lda   (PTR1)
            cmp   BYTETMP
            beq   :de8
            jmp   ERR_EXPFAIL
:de8        rts

*---------------------------------------------------------------
* DIR_FLIPLC -- `flip-lc`, no operands. Scan TBUF[0..TLEN-3]:
* wherever byte i is $AD/$2C/$8D (LDA/BIT/STA absolute) and byte
* i+2 is $C0, rewrite a read-ROM language-card operand ($81/$82)
* to its read-RAM twin ($83/$80) -- the proshim monitor-in-RAM
* patch (street-library learning 01M1XH5NKEKR7VN47ZMZQFKE26),
* confirmed against that primary source. TLEN < 3 means the scan
* range is empty -- nothing to do.
*---------------------------------------------------------------
DIR_FLIPLC  lda   TLEN+1
            bne   :fl1
            lda   TLEN
            cmp   #3
            bcs   :fl1
            rts
:fl1        sec
            lda   TLEN
            sbc   #2
            sta   FLCNT
            lda   TLEN+1
            sbc   #0
            sta   FLCNT+1
            lda   #<TBUF
            sta   PTR1
            lda   #>TBUF
            sta   PTR1+1
:fl2        lda   FLCNT
            ora   FLCNT+1
            bne   :fl3
            rts
:fl3        lda   (PTR1)
            cmp   #$AD
            beq   :fl4
            cmp   #$2C
            beq   :fl4
            cmp   #$8D
            bne   :fl6
:fl4        ldy   #2
            lda   (PTR1),y
            cmp   #$C0
            bne   :fl6
            ldy   #1
            lda   (PTR1),y
            cmp   #$81
            bne   :fl5
            lda   #$83
            sta   (PTR1),y
            bra   :fl6
:fl5        cmp   #$82
            bne   :fl6
            lda   #$80
            sta   (PTR1),y
:fl6        inc   PTR1
            bne   :fl7
            inc   PTR1+1
:fl7        lda   FLCNT
            bne   :fl8
            dec   FLCNT+1
:fl8        dec   FLCNT
            jmp   :fl2

*---------------------------------------------------------------
* WRITEBACK -- LSEEK TARGETFD to 0 (SEEK_SET), WRITE TLEN bytes
* from TBUF (cat.s's/dd.s's own partial-write loop, since a
* single SC_WRITE may complete short), CLOSE. Any seek/write
* failure here is a condition the spec's own error list does not
* name (every documented error is caught earlier, before any
* byte reaches disk) -- ERR_WRFAIL is this file's own defensive
* fallback for it.
*---------------------------------------------------------------
WRITEBACK   stz   SEEKBUF
            stz   SEEKBUF+1
            stz   SEEKBUF+2
            lda   #<SEEKBUF
            sta   PTR0
            lda   #>SEEKBUF
            sta   PTR0+1
            lda   TARGETFD
            ldy   #SEEK_SET
            jsr   LSEEK
            bcc   :wb1
            jmp   ERR_WRFAIL
:wb1        lda   #PCOUNT_WRITE
            sta   WPARM
            lda   TARGETFD
            sta   WPARM_REF
            lda   TLEN
            sta   WPARM_REQ
            lda   TLEN+1
            sta   WPARM_REQ+1
            lda   #<TBUF
            sta   WPARM_BUF
            lda   #>TBUF
            sta   WPARM_BUF+1
:wb2        lda   WPARM_REQ
            ora   WPARM_REQ+1
            bne   :wb3
            jmp   :wb5
:wb3        lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcc   :wb4
            jmp   ERR_WRFAIL
:wb4        lda   WPARM_TRANS
            ora   WPARM_TRANS+1
            bne   :wb6
            jmp   ERR_WRFAIL
:wb6        sec
            lda   WPARM_REQ
            sbc   WPARM_TRANS
            sta   WPARM_REQ
            lda   WPARM_REQ+1
            sbc   WPARM_TRANS+1
            sta   WPARM_REQ+1
            clc
            lda   WPARM_BUF
            adc   WPARM_TRANS
            sta   WPARM_BUF
            lda   WPARM_BUF+1
            adc   WPARM_TRANS+1
            sta   WPARM_BUF+1
            jmp   :wb2
:wb5        lda   #PCOUNT_CLOSE
            sta   CPARM
            lda   TARGETFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            rts

*---------------------------------------------------------------
* OPENFAIL -- IN: PTR0 = the failing path (a fresh liba/argv
* string pointer -- OPENTGT/OPENSPEC re-GETARG right before this
* call, since PUTS below clobbers PTR0). Prints "bpatch: " +
* path + ": cannot open" + CR to stderr, EXIT 1. Shared by both
* callers -- the suffix text is identical either way.
*---------------------------------------------------------------
OPENFAIL    lda   PTR0
            sta   ERRPATH
            lda   PTR0+1
            sta   ERRPATH+1
            lda   #<MSGPFX
            sta   PTR0
            lda   #>MSGPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ERRPATH
            sta   PTR0
            lda   ERRPATH+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<MSGOPENSFX
            sta   PTR0
            lda   #>MSGOPENSFX
            sta   PTR0+1
            jmp   EXIT1MSG

*---------------------------------------------------------------
* EXIT1MSG -- IN: PTR0 = a liba message string. Print to stderr,
* EXIT 1. Shared tail for every fixed-message error below.
*---------------------------------------------------------------
EXIT1MSG    ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

* -- the fixed-message error exits: load PTR0, tail into
* -- EXIT1MSG (or, for the usage error alone, EXIT 2 directly --
* -- it needs a different status). None return.
USAGEERR    lda   #<MSGUSAGE
            sta   PTR0
            lda   #>MSGUSAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

ERR_TGTBIG  lda   #<MSGTGTBIG
            sta   PTR0
            lda   #>MSGTGTBIG
            sta   PTR0+1
            jmp   EXIT1MSG

ERR_SPECBIG lda   #<MSGSPCBIG
            sta   PTR0
            lda   #>MSGSPCBIG
            sta   PTR0+1
            jmp   EXIT1MSG

ERR_SETPAST lda   #<MSGSETPST
            sta   PTR0
            lda   #>MSGSETPST
            sta   PTR0+1
            jmp   EXIT1MSG

ERR_EXPPAST lda   #<MSGEXPPST
            sta   PTR0
            lda   #>MSGEXPPST
            sta   PTR0+1
            jmp   EXIT1MSG

ERR_EXPFAIL lda   #<MSGEXPFAL
            sta   PTR0
            lda   #>MSGEXPFAL
            sta   PTR0+1
            jmp   EXIT1MSG

ERR_UNKNOWN lda   #<MSGUNKNWN
            sta   PTR0
            lda   #>MSGUNKNWN
            sta   PTR0+1
            jmp   EXIT1MSG

ERR_BADSPEC lda   #<MSGBADSPC
            sta   PTR0
            lda   #>MSGBADSPC
            sta   PTR0+1
            jmp   EXIT1MSG

ERR_WRFAIL  lda   #<MSGWRFAIL
            sta   PTR0
            lda   #>MSGWRFAIL
            sta   PTR0+1
            jmp   EXIT1MSG

* -- messages -- liba's own high-bit-set convention (matches
* -- every other util's `asc` strings; PUTS/PUTC render this
* -- correctly on the console, unlike the plain 7-bit KW* table
* -- below, which is compared against masked spec-file bytes and
* -- never printed).
MSGUSAGE    asc   "usage: bpatch SPEC TARGET"
            dfb   $8D,0
MSGPFX      asc   "bpatch: "
            dfb   0
MSGOPENSFX  asc   ": cannot open"
            dfb   $8D,0
MSGTGTBIG   asc   "bpatch: target too large"
            dfb   $8D,0
MSGSPCBIG   asc   "bpatch: spec too large"
            dfb   $8D,0
MSGSETPST   asc   "bpatch: set past end of file"
            dfb   $8D,0
MSGEXPPST   asc   "bpatch: expect past end of file"
            dfb   $8D,0
MSGEXPFAL   asc   "bpatch: expect failed"
            dfb   $8D,0
MSGUNKNWN   asc   "bpatch: unknown directive"
            dfb   $8D,0
MSGBADSPC   asc   "bpatch: bad spec syntax"
            dfb   $8D,0
MSGWRFAIL   asc   "bpatch: write failed"
            dfb   $8D,0

* -- verb keyword table -- PLAIN 7-bit ASCII (single-quote
* -- literal convention, confirmed $61 not $E1 -- mli.s's own
* -- header note has the two quote conventions), matching
* -- READWORD's masked WORDBUF exactly. Never printed.
KWSET       dfb   's','e','t',0
KWEXPECT    dfb   'e','x','p','e','c','t',0
KWFLIPLC    dfb   'f','l','i','p','-','l','c',0
