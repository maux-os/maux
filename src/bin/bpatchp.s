*---------------------------------------------------------------
* bpatchp.s -- bpatch's front half: START (argc check, open+read
* TARGET and SPEC with overflow checks), PARSESPEC/PROCLINE (the
* line splitter + directive dispatch), FINDEOL/SKIPWS/READWORD/
* WORDEQ (token extraction), HEXDIGIT/HEXPARSE16/HEXPARSE8 (hex
* parsing). Split from bpatch.s 2026-09-07 at a GLOBAL boundary
* for the as source window (check_dialect's 16128-byte budget).
* One assembly stream, put by bpatch.s right after the liba equ
* puts; every rule in bpatch.s's own header applies unchanged.
*
* POINTER CONVENTION used throughout this file: PTR0 is the
* "current scan position" into SBUF (a real moving pointer,
* 65C02 `(PTR0)`/`(PTR0),y` addressing, never Y-walked past 255
* since it is the raw address that advances, not an 8-bit offset
* from a fixed base). PTR1 is only a short-lived TBUF read/write
* pointer inside the directive appliers (bpatchd.s) -- never
* live across a READWORD/SKIPWS call in this file.
*---------------------------------------------------------------
*---------------------------------------------------------------
* START -- exactly two operands or usage error. Open+read both
* files (TARGET first, per spec step order), parse+apply, then
* write back and exit 0. Every called routine that hits an error
* EXITs directly -- nothing here needs to check a return code.
*---------------------------------------------------------------
START       lda   ARGC
            cmp   #3
            beq   :st1
            jmp   USAGEERR
:st1        jsr   OPENTGT
            jsr   OPENSPEC
            jsr   PARSESPEC
            jsr   WRITEBACK
            lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* OPENTGT -- OPEN argv[2] (must already exist), READ it whole
* into TBUF, TLEN = total bytes read. A read that would exceed
* TBUFMAX is checked with a 1-byte PEEK past the filled buffer:
* trans_count 0 there means EOF landed exactly at the cap
* (legal, TLEN stays TBUFMAX); nonzero means there is more
* data past the cap ("target too large"). Leaves TARGETFD open
* for WRITEBACK.
*---------------------------------------------------------------
OPENTGT     lda   #PCOUNT_OPEN
            sta   OPARM
            lda   #<PATHBUF
            sta   OPARM_PATH
            lda   #>PATHBUF
            sta   OPARM_PATH+1
            stz   OPARM_IOBUF
            stz   OPARM_IOBUF+1
            lda   #PCOUNT_READ
            sta   RPARM
            lda   #2
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :ot1
            lda   #2
            jsr   GETARG
            jmp   OPENFAIL
:ot1        lda   OPARM_REF
            sta   TARGETFD
            stz   TLEN
            stz   TLEN+1
:ot2        sec
            lda   #<TBUFMAX
            sbc   TLEN
            sta   RPARM_REQ
            lda   #>TBUFMAX
            sbc   TLEN+1
            sta   RPARM_REQ+1
            lda   RPARM_REQ
            ora   RPARM_REQ+1
            bne   :ot3
            jmp   :ot5
:ot3        clc
            lda   #<TBUF
            adc   TLEN
            sta   RPARM_BUF
            lda   #>TBUF
            adc   TLEN+1
            sta   RPARM_BUF+1
            lda   TARGETFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :ot4
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :ot4
            clc
            lda   TLEN
            adc   RPARM_TRANS
            sta   TLEN
            lda   TLEN+1
            adc   RPARM_TRANS+1
            sta   TLEN+1
            jmp   :ot2
:ot4        rts
:ot5        lda   #<PEEKBUF
            sta   RPARM_BUF
            lda   #>PEEKBUF
            sta   RPARM_BUF+1
            lda   #1
            sta   RPARM_REQ
            stz   RPARM_REQ+1
            lda   TARGETFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :ot4
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :ot4
            jmp   ERR_TGTBIG

*---------------------------------------------------------------
* OPENSPEC -- OPEN argv[1], READ it whole into SBUF, SLEN =
* total bytes read, then CLOSE it (spec step 2 -- SBUF resident
* for the parse, the fd does not need to). Same PEEK-based
* overflow check as OPENTGT, against SBUFMAX ("spec too large").
*---------------------------------------------------------------
OPENSPEC    lda   #PCOUNT_OPEN
            sta   OPARM
            lda   #<PATHBUF
            sta   OPARM_PATH
            lda   #>PATHBUF
            sta   OPARM_PATH+1
            stz   OPARM_IOBUF
            stz   OPARM_IOBUF+1
            lda   #PCOUNT_READ
            sta   RPARM
            lda   #1
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :os1
            lda   #1
            jsr   GETARG
            jmp   OPENFAIL
:os1        lda   OPARM_REF
            sta   SPECFD
            stz   SLEN
            stz   SLEN+1
:os2        sec
            lda   #<SBUFMAX
            sbc   SLEN
            sta   RPARM_REQ
            lda   #>SBUFMAX
            sbc   SLEN+1
            sta   RPARM_REQ+1
            lda   RPARM_REQ
            ora   RPARM_REQ+1
            bne   :os3
            jmp   :os5
:os3        clc
            lda   #<SBUF
            adc   SLEN
            sta   RPARM_BUF
            lda   #>SBUF
            adc   SLEN+1
            sta   RPARM_BUF+1
            lda   SPECFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :os4
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :os4
            clc
            lda   SLEN
            adc   RPARM_TRANS
            sta   SLEN
            lda   SLEN+1
            adc   RPARM_TRANS+1
            sta   SLEN+1
            jmp   :os2
:os4        lda   #PCOUNT_CLOSE
            sta   CPARM
            lda   SPECFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            rts
:os5        lda   #<PEEKBUF
            sta   RPARM_BUF
            lda   #>PEEKBUF
            sta   RPARM_BUF+1
            lda   #1
            sta   RPARM_REQ
            stz   RPARM_REQ+1
            lda   SPECFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :os4
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :os4
            jmp   ERR_SPECBIG

*---------------------------------------------------------------
* PARSESPEC -- walk SBUF[0..SLEN) one line at a time (FINDEOL
* finds each line's bound, PROCLINE tokenizes+dispatches it),
* until LPOS reaches SBUFEND. Returns (to START) once every line
* has been applied -- any error along the way EXITs directly and
* never returns here.
*---------------------------------------------------------------
PARSESPEC   lda   #<SBUF
            sta   LPOS
            lda   #>SBUF
            sta   LPOS+1
            clc
            lda   #<SBUF
            adc   SLEN
            sta   SBUFEND
            lda   #>SBUF
            adc   SLEN+1
            sta   SBUFEND+1
:ps1        lda   LPOS+1
            cmp   SBUFEND+1
            bcc   :ps2
            bne   :ps3
            lda   LPOS
            cmp   SBUFEND
            bcc   :ps2
:ps3        rts
:ps2        jsr   FINDEOL
            jsr   PROCLINE
            lda   NEXTLPOS
            sta   LPOS
            lda   NEXTLPOS+1
            sta   LPOS+1
            jmp   :ps1

*---------------------------------------------------------------
* PROCLINE -- tokenize+dispatch ONE line, [LPOS,LINEEND)
* (FINDEOL already set LINEEND). Blank (all-whitespace) or
* `#`-led lines are silently skipped. Otherwise the first word
* is matched against the three known verbs; no match is
* "unknown directive".
* Each DIR_* handler is reached by `jmp` (not `jsr`) so its own
* `rts` returns straight to PARSESPEC's `jsr PROCLINE` -- the
* shared-stack-frame tail-call idiom ddparse.s's PARSELOOP/KEY_*
* already uses.
*---------------------------------------------------------------
PROCLINE    lda   LPOS
            sta   PTR0
            lda   LPOS+1
            sta   PTR0+1
            jsr   SKIPWS
            lda   PTR0+1
            cmp   LINEEND+1
            bcc   :pc1
            bne   :pc2
            lda   PTR0
            cmp   LINEEND
            bcc   :pc1
:pc2        rts
:pc1        lda   (PTR0)
            and   #$7F
            cmp   #$23
            bne   :pc3
            rts
:pc3        jsr   READWORD
            lda   #<KWSET
            sta   PTR1
            lda   #>KWSET
            sta   PTR1+1
            jsr   WORDEQ
            cmp   #0
            bne   :pc4
            jmp   DIR_SET
:pc4        lda   #<KWEXPECT
            sta   PTR1
            lda   #>KWEXPECT
            sta   PTR1+1
            jsr   WORDEQ
            cmp   #0
            bne   :pc5
            jmp   DIR_EXPECT
:pc5        lda   #<KWFLIPLC
            sta   PTR1
            lda   #>KWFLIPLC
            sta   PTR1+1
            jsr   WORDEQ
            cmp   #0
            bne   :pc6
            jmp   DIR_FLIPLC
:pc6        jmp   ERR_UNKNOWN

*---------------------------------------------------------------
* FINDEOL -- IN: LPOS. Scans from LPOS for the first masked $0D
* or $0A, or SBUFEND, whichever comes first. OUT: LINEEND = that
* position (exclusive of any terminator found); NEXTLPOS =
* LINEEND+1 if a terminator was found (consumed), else SBUFEND
* (no more lines -- PARSESPEC's own loop test catches this next
* time around). CLOBBERS: A, PTR0.
*---------------------------------------------------------------
FINDEOL     lda   LPOS
            sta   PTR0
            lda   LPOS+1
            sta   PTR0+1
:fe1        lda   PTR0+1
            cmp   SBUFEND+1
            bcc   :fe2
            bne   :fe4
            lda   PTR0
            cmp   SBUFEND
            bcc   :fe2
:fe4        lda   PTR0
            sta   LINEEND
            lda   PTR0+1
            sta   LINEEND+1
            lda   SBUFEND
            sta   NEXTLPOS
            lda   SBUFEND+1
            sta   NEXTLPOS+1
            rts
:fe2        lda   (PTR0)
            and   #$7F
            cmp   #$0D
            beq   :fe3
            cmp   #$0A
            beq   :fe3
            inc   PTR0
            bne   :fe1
            inc   PTR0+1
            bra   :fe1
:fe3        lda   PTR0
            sta   LINEEND
            lda   PTR0+1
            sta   LINEEND+1
            clc
            lda   PTR0
            adc   #1
            sta   NEXTLPOS
            lda   PTR0+1
            adc   #0
            sta   NEXTLPOS+1
            rts

*---------------------------------------------------------------
* SKIPWS -- advance PTR0 past spaces ($20) / tabs ($09), masked,
* bounded by LINEEND. IN/OUT: PTR0. CLOBBERS: A.
*---------------------------------------------------------------
SKIPWS      lda   PTR0+1
            cmp   LINEEND+1
            bcc   :sw1
            bne   :sw2
            lda   PTR0
            cmp   LINEEND
            bcc   :sw1
:sw2        rts
:sw1        lda   (PTR0)
            and   #$7F
            cmp   #$20
            beq   :sw3
            cmp   #$09
            beq   :sw3
            rts
:sw3        inc   PTR0
            bne   :sw4
            inc   PTR0+1
:sw4        jmp   SKIPWS

*---------------------------------------------------------------
* READWORD -- IN: PTR0, LINEEND. Copies masked bytes from PTR0
* up to the next space/tab/LINEEND into WORDBUF (NUL-terminated)
* capped at WORDCAP chars -- a longer token cannot be any of the
* three verbs or a legal OFF/B token, so the extra chars are
* simply not stored (still consumed, so PTR0 lands correctly);
* the caller's own length/content check reports the right error
* either way ("unknown directive" or "bad spec syntax"). OUT:
* WORDBUF/WORDLEN, PTR0 advanced to the first space/tab/LINEEND
* after the word. CLOBBERS: A, X.
*---------------------------------------------------------------
READWORD    ldx   #0
:rw1        lda   PTR0+1
            cmp   LINEEND+1
            bcc   :rw2
            bne   :rw4
            lda   PTR0
            cmp   LINEEND
            bcc   :rw2
:rw4        stz   WORDBUF,x
            stx   WORDLEN
            rts
:rw2        lda   (PTR0)
            and   #$7F
            cmp   #$20
            beq   :rw4
            cmp   #$09
            beq   :rw4
            cpx   #WORDCAP
            bcs   :rw3
            sta   WORDBUF,x
            inx
:rw3        inc   PTR0
            bne   :rw1
            inc   PTR0+1
            jmp   :rw1

*---------------------------------------------------------------
* WORDEQ -- does WORDBUF equal the NUL-terminated 7-bit string
* at PTR1? OUT: A=0 if equal, A=1 if not. CLOBBERS: A, Y.
*---------------------------------------------------------------
WORDEQ      ldy   #0
:we1        lda   (PTR1),y
            cmp   WORDBUF,y
            bne   :we2
            cmp   #0
            beq   :we3
            iny
            bra   :we1
:we2        lda   #1
            rts
:we3        lda   #0
            rts

*---------------------------------------------------------------
* HEXDIGIT -- IN: A = one masked ASCII char. OUT: carry clear,
* A = nibble 0-15, if '0'-'9'/'A'-'F'/'a'-'f'; carry set
* (unchanged A) otherwise. CLOBBERS: A.
*---------------------------------------------------------------
HEXDIGIT    cmp   #$30
            bcc   :hd1
            cmp   #$3A
            bcc   :hd2
            cmp   #$41
            bcc   :hd1
            cmp   #$47
            bcc   :hd3
            cmp   #$61
            bcc   :hd1
            cmp   #$67
            bcc   :hd4
:hd1        sec
            rts
:hd2        sec
            sbc   #$30
            clc
            rts
:hd3        sec
            sbc   #$41
            clc
            adc   #10
            clc
            rts
:hd4        sec
            sbc   #$61
            clc
            adc   #10
            clc
            rts

*---------------------------------------------------------------
* HEXPARSE16 -- parse WORDBUF (WORDLEN chars) as 1-4 hex digits.
* OUT: carry clear, OFFVAL = value, on success; carry set
* (OFFVAL undefined) if WORDLEN is 0, >4, or a char is not hex.
* CLOBBERS: A, X.
*---------------------------------------------------------------
HEXPARSE16  lda   WORDLEN
            beq   :h61
            cmp   #5
            bcs   :h61
            stz   OFFVAL
            stz   OFFVAL+1
            ldx   #0
:h62        lda   WORDBUF,x
            jsr   HEXDIGIT
            bcs   :h61
            pha
            asl   OFFVAL
            rol   OFFVAL+1
            asl   OFFVAL
            rol   OFFVAL+1
            asl   OFFVAL
            rol   OFFVAL+1
            asl   OFFVAL
            rol   OFFVAL+1
            pla
            ora   OFFVAL
            sta   OFFVAL
            inx
            cpx   WORDLEN
            bne   :h62
            clc
            rts
:h61        sec
            rts

*---------------------------------------------------------------
* HEXPARSE8 -- parse WORDBUF (WORDLEN chars) as EXACTLY 2 hex
* digits. OUT: carry clear, A = byte value, on success; carry
* set if WORDLEN != 2 or either char is not hex. CLOBBERS: A.
*---------------------------------------------------------------
HEXPARSE8   lda   WORDLEN
            cmp   #2
            bne   :h81
            lda   WORDBUF
            jsr   HEXDIGIT
            bcs   :h81
            asl   a
            asl   a
            asl   a
            asl   a
            sta   BYTETMP
            lda   WORDBUF+1
            jsr   HEXDIGIT
            bcs   :h81
            ora   BYTETMP
            clc
            rts
:h81        sec
            rts
