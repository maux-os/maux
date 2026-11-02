*---------------------------------------------------------------
* trbody.s -- tr's whole implementation. PUT by tr.s, which
* keeps only the equate puts, the org/dsk/typ triple, the liba
* puts and the `dum` arena.
*
* WHY THE SPLIT, 2026-09-21. Two ceilings bind a unit in this
* tree and they are not the same number: real Merlin's
* 41,215-byte source buffer, and the vendored `as`'s 16,128-byte
* SOURCE WINDOW, which is the one that decides whether a unit
* can be rebuilt by maux itself. Backslash escapes and
* [:class:] expansion took tr.s's closure to 22,950 stripped and
* it stopped being self-hostable. Moving the body here leaves
* the manifest at a few hundred bytes; same put-module precedent
* as grep.s/grepbody.s the same day, and as sh.s's eight.
* check-bytes proves the split is byte-neutral.
*
* The liba puts stay at TOP LEVEL in tr.s -- Merlin cannot nest
* a put inside a put file.
*---------------------------------------------------------------
BUFSZ       equ   255              ;read chunk, same shape as
                                   ;wc.s/grep.s's GETBYTE

START       stz   WANT_C
            stz   WANT_D
            stz   WANT_S
            stz   HAVE_STR2
            lda   #<TROPTS
            ldx   #>TROPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$E3                  ;'c' high-bit-set
            beq   :is_c
*-- -C IS -c HERE, and that is conformance rather than a
*-- shortcut. POSIX separates them because -c complements the
*-- set of VALUES in string1 and -C the set of CHARACTERS, a
*-- distinction that exists only where a character can span more
*-- than one byte. This machine is single-byte throughout:
*-- one octet is one character -- so the two complements are
*-- the same set, and accepting -C as its own
*-- spelling of -c is what a conforming tr does here. 'C' is
*-- $C3, UPPERCASE: the case bit is bit 5, and a wrong one is
*-- invisible under a correct comment
*-- (learning:01M0PKP4ZK7NX6HASWHTKKZHDG).
            cmp   #$C3                  ;'C'
            bne   :not_c
:is_c       lda   #$E3                  ;one flag, either
            sta   WANT_C                ;spelling
            bra   :optlp
:not_c      cmp   #$E4                  ;'d'
            bne   :not_d
            sta   WANT_D
            bra   :optlp
:not_d      cmp   #$F3                  ;'s'
            beq   :is_s
            jmp   :usage                ;'?' or anything else
:is_s       sta   WANT_S
            bra   :optlp

:optdone    lda   ARGC
            sec
            sbc   OPTIND
            sta   NOPS
            cmp   #1
            beq   :onestr
            cmp   #2
            beq   :twostr
            jmp   :usage                ;0, or >2, operands
:onestr     lda   WANT_D
            ora   WANT_S
            bne   :havecnt              ;-d or -s: string2 opt.
            jmp   :usage                ;neither: string2 req'd
:twostr     lda   #1
            sta   HAVE_STR2
:havecnt

*-- expand string1 -> EXP1BUF/EXP1LEN, MEMBER1
            lda   #<MEMBER1
            sta   PTR1
            lda   #>MEMBER1
            sta   PTR1+1
            jsr   ZERO256
            lda   OPTIND
            jsr   GETARG
            jsr   ESCPASS
            lda   #<EXP1BUF
            sta   PTR1
            lda   #>EXP1BUF
            sta   PTR1+1
            lda   #<MEMBER1
            sta   PTR2
            lda   #>MEMBER1
            sta   PTR2+1
            jsr   EXPAND
            lda   EXCNT
            sta   EXP1LEN

            lda   HAVE_STR2
            beq   :nostr2

*-- expand string2 -> EXP2BUF/EXP2LEN, MEMBER2
            lda   #<MEMBER2
            sta   PTR1
            lda   #>MEMBER2
            sta   PTR1+1
            jsr   ZERO256
            lda   OPTIND
            clc
            adc   #1
            jsr   GETARG
            jsr   ESCPASS
            lda   #<EXP2BUF
            sta   PTR1
            lda   #>EXP2BUF
            sta   PTR1+1
            lda   #<MEMBER2
            sta   PTR2
            lda   #>MEMBER2
            sta   PTR2+1
            jsr   EXPAND
            lda   EXCNT
            sta   EXP2LEN
:nostr2

            lda   WANT_D
            beq   :setxlat
            jsr   SETUPDEL
            jmp   :run
*-- HAVE_STR2 (not EXP2LEN) gates the first branch: EXP2LEN is
*-- ONLY `sta`'d inside the "expand string2" block above, which
*-- runs only under HAVE_STR2 -- for a real one-operand call
*-- (-s, no -d) that block never executes, so EXP2LEN there is
*-- unwritten arena garbage (see the footer note) and must not
*-- be trusted until HAVE_STR2 confirms it was actually set.
:setxlat    lda   HAVE_STR2
            beq   :nostr2b              ;one operand -- EXP2LEN
                                        ;was never written
            lda   EXP2LEN               ;translate mode needs a
            bne   :haveset2             ;non-empty string2
            jmp   :usage                ;string2 given but empty
:nostr2b    lda   WANT_S
            bne   :sqonly               ;-s, no string2: squeeze
            jmp   :usage                ;only -- no xlat needed
:haveset2   jsr   SETUPXLT
            bra   :run
:sqonly     jsr   IDFILL                ;:xlate always runs when
                                        ;WANT_D is clear (below)
            jsr   SETUPDEL              ;PTR2 -> effective SET1

* -- BUFPOS/BUFLEN must be zeroed HERE, and this is a real fix,
* -- not bookkeeping: GETBYTE's first act is `ldx BUFPOS / cpx
* -- BUFLEN`, and until this store existed tr reached that
* -- compare having never written either cell. It worked only
* -- because `ds` happened to emit zeros -- so `pos >= len` was
* -- true by accident and REFILL ran. wc.s/grep.s/uniq.s, which
* -- GETBYTE's own comment says tr copies, each zero the pair
* -- explicitly (GREPFD, RUNUNIQ); tr was the one that did not.
* -- With the cells in `dum` the accident is gone: garbage where
* -- BUFPOS < BUFLEN skips REFILL and serves uninitialised CBUF
* -- bytes as input. See docs/STICKY.md sec 28.
:run        stz   BUFPOS
            stz   BUFLEN
            stz   LASTVALID
:cploop     jsr   GETBYTE
            bcs   :eof
            sta   CURBYTE
            lda   WANT_D
            beq   :xlate
            ldy   CURBYTE
            lda   DELFLAG,y
            bne   :cploop               ;deleted -- drop it
            lda   CURBYTE
            bra   :got
:xlate      ldy   CURBYTE
            lda   XTAB,y
:got        sta   OUTBYTE
            lda   WANT_S
            beq   :doemit
            ldy   OUTBYTE
            lda   (PTR2),y              ;PTR2 -- squeeze-set
                                        ;pointer set up by
                                        ;SETUPDEL/SETUPXLT
            beq   :notsq
            lda   LASTVALID
            beq   :sqfirst
            lda   OUTBYTE
            cmp   LASTOUT
            beq   :cploop               ;repeat -- squeeze
:sqfirst    lda   #1
            sta   LASTVALID
            lda   OUTBYTE
            sta   LASTOUT
            bra   :doemit
:notsq      stz   LASTVALID
:doemit     lda   OUTBYTE
            ldx   #FD_STDOUT
            jsr   PUTC
            bra   :cploop
:eof        lda   #0
            jsr   EXIT

:usage      lda   #<USAGE
            sta   PTR0
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* SETUPDEL -- build DELFLAG[256] and pick the squeeze source
* into PTR2. DELFLAG is the effective (possibly complemented)
* string1 set. Called for -d mode AND for the -s-only setup
* path at :sqonly -- both need "PTR2 -> effective SET1, no
* string2 in play"; DELFLAG doubles as the squeeze source
* itself whenever there is no string2 (see file header).
*---------------------------------------------------------------
SETUPDEL    lda   #<DELFLAG
            sta   PTR1
            lda   #>DELFLAG
            sta   PTR1+1
            jsr   ZERO256
            lda   WANT_C
            beq   :plaindel
            ldy   #0
:cloop      lda   MEMBER1,y
            bne   :cnext
            lda   #1
            sta   DELFLAG,y
:cnext      iny
            bne   :cloop
            bra   :delsq
:plaindel   ldy   #0
:pcpy       lda   MEMBER1,y
            sta   DELFLAG,y
            iny
            bne   :pcpy
:delsq      lda   HAVE_STR2
            beq   :sqstr1
            lda   #<MEMBER2
            sta   PTR2
            lda   #>MEMBER2
            sta   PTR2+1
            rts
:sqstr1     lda   #<DELFLAG
            sta   PTR2
            lda   #>DELFLAG
            sta   PTR2+1
            rts

*---------------------------------------------------------------
* IDFILL -- identity-fill XTAB[i]=i, all 256 entries. Shared by
* SETUPXLT (translate mode overwrites entries it maps) and the
* -s-only setup path at :sqonly (no translation at all, so the
* data path's unconditional XTAB lookup must be a no-op).
* CLOBBERS: A, Y.
*---------------------------------------------------------------
IDFILL      ldy   #0
:idloop     tya
            sta   XTAB,y
            iny
            bne   :idloop
            rts

*---------------------------------------------------------------
* SETUPXLT -- build XTAB[256] (translate mode) and point PTR2 at
* MEMBER2, the -s squeeze source (-c never touches string2).
*---------------------------------------------------------------
SETUPXLT    jsr   IDFILL
            lda   WANT_C
            bne   :xcomp

*-- plain: XTAB[EXP1BUF[i]] = EXP2BUF[min(i,EXP2LEN-1)]. Y is
*-- the loop index i throughout; X only holds a same-iteration
*-- value (dstpos, then the source byte), never carried across
*-- iterations, so the two never collide.
            ldy   #0
:xloop      cpy   EXP1LEN
            beq   :xdone
            cpy   EXP2LEN
            bcc   :xok
            ldx   EXP2LEN
            dex
            bra   :xstore
:xok        tya
            tax
:xstore     lda   EXP2BUF,x             ;A = translated byte
            ldx   EXP1BUF,y             ;X = source byte
            sta   XTAB,x
*-- The same mapping for the OTHER encoding of the pair, so a
*-- file in either convention translates -- and the REPLACEMENT
*-- is twinned too, which is what makes the output follow the
*-- input: a low-ASCII line yields low-ASCII replacements and
*-- stays one convention end to end. Indexing by the RAW byte
*-- rather than normalising the input is deliberate: it leaves
*-- $61 and $E1 distinguishable, so tr on binary is unchanged.
            sta   XT_TWIN
            txa
            eor   #$80
            tax
            lda   XT_TWIN
            eor   #$80
            sta   XTAB,x
            iny
            bra   :xloop
:xdone      bra   :xret

*-- complemented: ascending byte order, skipping MEMBER1 hits
:xcomp      stz   CIDX
            ldy   #0
:xcloop     lda   MEMBER1,y
            bne   :xcnext
            lda   CIDX
            cmp   EXP2LEN
            bcc   :xcok
            ldx   EXP2LEN
            dex
            bra   :xcstore
:xcok       tax
:xcstore    lda   EXP2BUF,x
            sta   XTAB,y
            inc   CIDX
:xcnext     iny
            bne   :xcloop
:xret       lda   #<MEMBER2
            sta   PTR2
            lda   #>MEMBER2
            sta   PTR2+1
            rts

*---------------------------------------------------------------
* EXPAND -- expand a NUL-terminated liba string at PTR0 into an
* ordered byte list at PTR1 (up to 255 entries, EXCNT saturates
* there rather than overrunning) and a 256-byte membership flag
* array at PTR2 (caller zeroes it first). "c1-c2" (ascending)
* expands to the run c1..c2; a '-' with nothing after it, or
* with c2<c1, is read as a literal character instead (see file
* header). CLOBBERS: A, X, Y, EXCNT/EXSRCY/EXC1/EXC2/EXCUR/
* EXBYTE (module scratch).
*---------------------------------------------------------------
EXPAND      stz   EXCNT
            stz   EXSRCY
:loop       ldy   EXSRCY
            lda   (PTR0),y
            beq   :done
            sta   EXC1
            iny
            lda   (PTR0),y
            cmp   #$AD                  ;'-' high-bit-set
            bne   :lit
            iny
            lda   (PTR0),y
            beq   :lit                  ;trailing '-' -- literal
            sta   EXC2
            cmp   EXC1
            bcc   :lit                  ;c2<c1 -- not a range
:range      lda   EXC1
            sta   EXCUR
:rloop      lda   EXCUR
            jsr   EXEMIT
            lda   EXCUR
            cmp   EXC2
            beq   :rdone
            inc   EXCUR
            bra   :rloop
:rdone      lda   EXSRCY
            clc
            adc   #3
            sta   EXSRCY
            bra   :loop
:lit        lda   EXC1
            jsr   EXEMIT
            inc   EXSRCY
            bra   :loop
:done       rts

*-- EXEMIT: A = byte to record. Appends to the ordered list
*-- (saturating EXCNT at 255) and always marks membership.
EXEMIT      sta   EXBYTE
            lda   EXCNT
            cmp   #255
            beq   :mark
            ldy   EXCNT
            lda   EXBYTE
            sta   (PTR1),y
            inc   EXCNT
*-- MEMBERSHIP IS MARKED FOR BOTH ENCODINGS of the character.
*-- A file that arrives from outside carries ProDOS semantics --
*-- low ASCII, $0D -- while maux writes high-bit; naming `a` has
*-- to mean the `a` in either. The ORDERED list above is NOT
*-- twinned: it is what pairs string1[i] with string2[i], and a
*-- twin in it would shift every later pair by one.
:mark       ldy   EXBYTE
            lda   #1
            sta   (PTR2),y
            lda   EXBYTE
            eor   #$80
            tay
            lda   #1
            sta   (PTR2),y
            rts

*---------------------------------------------------------------
* ZERO256 -- zero the 256-byte array at PTR1. CLOBBERS: A, Y.
*---------------------------------------------------------------
ZERO256     lda   #0
            ldy   #0
:loop       sta   (PTR1),y              ;STZ has no (zp),y mode
            iny
            bne   :loop
            rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered stdin, same shape as wc.s/grep.s.
*---------------------------------------------------------------
GETBYTE     ldx   BUFPOS
            cpx   BUFLEN
            bcc   :have
            jsr   REFILL
            bcs   :eof
            ldx   BUFPOS
:have       lda   CBUF,x
            inc   BUFPOS
            clc
            rts
:eof        sec
            rts

REFILL      lda   #FD_STDIN
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :eof
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            lda   RPARM_TRANS
            sta   BUFLEN
            stz   BUFPOS
            clc
            rts
:eof        sec
            rts

USAGE       asc   "usage: tr [-Ccds] string1 [string2]"
            dfb   $8D,$00

TROPTS      asc   "cdsC"
            dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

