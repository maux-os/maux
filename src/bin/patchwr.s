*---------------------------------------------------------------
* patchwr.s -- patch's WRITERS and its exits: the line emitter
* every output stream shares, the -b backup, the reject file,
* the derived-name builder, the trailing flush, the report on
* fd 2, and the six loud failures.
*
* `put` into src/bin/patch.s after patchio.s (split from it for
* check-dialect's as-window budget -- new code is born
* window-fit, see that gate's own AS_WINDOW_OVER note); one
* assembly stream, every rule in that manifest's header applies
* unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* EMITLN -- IN: PTR0 = text, X = fd. Write it and a CR.
*---------------------------------------------------------------
EMITLN      stx   EFD
            jsr   PUTS
            lda   #$8D
            ldx   EFD
            jmp   PUTC

* EMITT -- IN: A = 1-based target line number. Write it to OFD.
EMITT       jsr   TGTLINE
            ldx   OFD
            jmp   EMITLN

*---------------------------------------------------------------
* WRBACKUP -- -b: NAME.orig gets the target's original text,
* line for line, before a single byte of the patched file is
* written.
*---------------------------------------------------------------
WRBACKUP    lda   #<ORIGSUF
            ldx   #>ORIGSUF
            jsr   MKDERIV
            jsr   MKPATH2
            lda   #<PATH2BUF
            sta   PTR1
            lda   #>PATH2BUF
            sta   PTR1+1
            jsr   CREAT
            bcs   :bfail
            sta   BFD
            lda   #1
            sta   TIDX2
:bl         lda   TIDX2
            cmp   NT
            beq   :bw
            bcs   :bdone
:bw         lda   TIDX2
            jsr   TGTLINE
            ldx   BFD
            jsr   EMITLN
            inc   TIDX2
            bra   :bl
:bdone      ldx   BFD
            jmp   FCLOSE
:bfail      jmp   NOWRITE

*---------------------------------------------------------------
* REJPUT -- write the CURRENT hunk's raw lines, verbatim and in
* order, to NAME.rej, creating it on the first failed hunk and
* not at all if every hunk applies.
*---------------------------------------------------------------
REJPUT      lda   RJOPEN
            bne   :have
            lda   #<REJSUF
            ldx   #>REJSUF
            jsr   MKDERIV
            jsr   MKPATH2
            lda   #<PATH2BUF
            sta   PTR1
            lda   #>PATH2BUF
            sta   PTR1+1
            jsr   CREAT
            bcs   :rfail
            sta   RFD
            lda   #1
            sta   RJOPEN
:have       stz   TIDX2
:rl         lda   TIDX2
            cmp   NRAW
            bcs   :rdone
            lda   TIDX2
            ldx   #<RAWLP
            ldy   #>RAWLP
            jsr   LPGET
            lda   PT_LP2
            sta   PTR0
            lda   PT_LP2+1
            sta   PTR0+1
            ldx   RFD
            jsr   EMITLN
            inc   TIDX2
            bra   :rl
:rdone      rts
:rfail      jmp   NOWRITE

*---------------------------------------------------------------
* MKDERIV -- IN: A/X = lo/hi of a suffix string (".orig" or
* ".rej"). Build NAMEBUF's text plus that suffix in DERIVBUF.
* The last path component is TRUNCATED to 11 characters first
* if it would otherwise overflow ProDOS's 15-character name --
* the pathname PARSER is what enforces that limit, so an
* over-long derived name would be a file nothing could ever
* open (learning:01M07G8WT2R3G2P87EK1DNPVYP).
*---------------------------------------------------------------
MKDERIV     sta   PT_SCAN
            stx   PT_SCAN+1
            lda   #<NAMEBUF
            sta   PTR0
            lda   #>NAMEBUF
            sta   PTR0+1
            lda   #<DERIVBUF
            sta   PT_NBUF
            lda   #>DERIVBUF
            sta   PT_NBUF+1
            ldy   #0
            sty   PT_TMP            ;just past the last '/'
:scan       lda   (PTR0),y
            beq   :sdone
            cmp   #$AF              ;'/' high-bit-set
            bne   :snext
            iny
            sty   PT_TMP
            dey
:snext      iny
            bne   :scan
:sdone      ldy   #0                ;copy, stop 11 chars
:cl         tya                     ;into the LAST component
            sec
            sbc   PT_TMP
            cmp   #11
            bcs   :cdone
            lda   (PTR0),y
            beq   :cdone
            sta   (PT_NBUF),y
            iny
            bra   :cl
:cdone      lda   (PT_SCAN)
            beq   :adone
            sta   (PT_NBUF),y
            iny
            inc   PT_SCAN
            bne   :cdone
            inc   PT_SCAN+1
            bra   :cdone
:adone      lda   #0
            sta   (PT_NBUF),y
            lda   #<DERIVBUF
            sta   PTR0
            lda   #>DERIVBUF
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* FLUSHREST -- every target line from CURT to the end, after the
* last hunk (or after a rejected one).
*---------------------------------------------------------------
FLUSHREST   lda   CURT
            cmp   NT
            beq   :one
            bcs   :done
:one        lda   CURT
            jsr   EMITT
            inc   CURT
            bra   FLUSHREST
:done       rts

*---------------------------------------------------------------
* REPORT -- what happened, to fd 2. POSIX leaves this text
* unspecified and the two reference implementations disagree on
* it word for word (BSD: "1 out of 1 hunks failed--saving
* rejects to A.rej"; GNU: "1 out of 1 hunk FAILED -- saving
* rejects to file A.rej"), so this is maux's own wording on
* maux's own stream, and no gate compares it.
*---------------------------------------------------------------
REPORT      lda   #<MSGPAT
            sta   PTR0
            lda   #>MSGPAT
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<NAMEBUF
            sta   PTR0
            lda   #>NAMEBUF
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   EMITLN
            lda   NHFAIL
            beq   :done
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDERR
            jsr   PRNUM
            lda   #<MSGFAIL
            sta   PTR0
            lda   #>MSGFAIL
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   EMITLN
:done       rts

*---------------------------------------------------------------
* The loud exits. Each writes one line to fd 2 and exits 2;
* none of them returns.
*---------------------------------------------------------------
OVERFLOW    lda   #<OOMMSG
            ldx   #>OOMMSG
            bra   DIE2
NOPATCH     lda   #<NOPMSG
            ldx   #>NOPMSG
            bra   DIE2
NOTARGET    lda   #<NOTMSG
            ldx   #>NOTMSG
            bra   DIE2
NOWRITE     lda   #<NOWMSG
            ldx   #>NOWMSG
            bra   DIE2
MALFORMED   lda   #<BADMSG
            ldx   #>BADMSG
            bra   DIE2
USAGERR     lda   #<USAGEMSG
            ldx   #>USAGEMSG
DIE2        sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   EMITLN
            lda   #2
            jsr   EXIT

USAGEMSG    asc   "usage: patch [-bR][-p n][-i pat][-o out][f]"
            dfb   0
OOMMSG      asc   "patch: input too large"
            dfb   0
NOPMSG      asc   "patch: cannot read the patch"
            dfb   0
NOTMSG      asc   "patch: cannot open the file to patch"
            dfb   0
NOWMSG      asc   "patch: cannot write"
            dfb   0
BADMSG      asc   "patch: malformed patch"
            dfb   0
MSGPAT      asc   "patching file "
            dfb   0
MSGFAIL     asc   " hunk(s) rejected"
            dfb   0
ORIGSUF     asc   ".orig"
            dfb   0
REJSUF      asc   ".rej"
            dfb   0
POPTS       asc   "bRp:i:o:"
            dfb   0

IOPARM      dfb   PCOUNT_OPEN
IOPARM_PATH da    PATHBUF
IOPARM_IOBF da    $0000
IOPARM_REF  dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    PBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

TRPARM      dfb   PCOUNT_READ
TRPARM_REF  dfb   0
TRPARM_BUF  da    TBUF
TRPARM_REQ  da    BUFSZ
TRPARM_TRANS da   0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0
