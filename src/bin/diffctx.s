*---------------------------------------------------------------
* diffctx.s -- diff's CONTEXT output halves: -u (unified) and
* -c (context), plus the hunk-GROUPING pass both share and the
* small decimal parser -U/-C's option-argument needs.
*
* `put` into src/bin/diff.s after diffhnk.s; one assembly
* stream, every rule in diff.s's manifest header applies
* unchanged. It reads the SAME HUNKTBL diffhnk.s's OUTNORM/OUTE
* read -- no second pass over OPS, no second algorithm.
*
* THE GROUPING RULE (measured against this host's own BSD diff,
* 2026-09-17, by walking the gap from 0 to 8 unchanged lines
* with -u: `diff -u` merges two change regions into ONE hunk
* exactly while the number of unchanged lines BETWEEN them is
* <= 2*CTXN, and splits at 2*CTXN+1 -- with CTXN=3 the last
* merged gap is 6 and 7 is two hunks). GRPSCAN implements that
* and nothing else; every other number below is derived from
* the group's first and last hunk.
*
* RANGES. For a group [GS..GE]:
*   OSTART = max(1, HA[GS]+1 - CTXN)
*   OEND   = min(NA, HA[GE]+HDELS[GE] + CTXN)
*   OCNT   = OEND-OSTART+1, floored at 0
* and the same on the B side with HB/HINS/NB. A count of 0 can
* only arise when that side of the comparison has no lines in
* range at all (an empty file, or -U0/-C0 at a pure insertion),
* and BOTH formats then print the line number BEFORE the range
* -- `@@ -0,0` for an empty file1, `@@ -2,0` for an insertion
* after line 2 at -U0, `*** 0 ****` / `*** 2 ****` in -c. Also
* measured, not assumed.
*
* -u BODY: one line per op, prefix ' ' / '-' / '+', deletions
* of a change region before its insertions.
*
* -c BODY: two sections per group, prefix two characters --
* '  ' context, '- ' delete, '+ ' insert, '! ' for a line in a
* region that has BOTH (a change). A section's BODY is omitted
* entirely (its header line still prints) when that side has no
* changed line in the whole group -- that is what real diff
* does for a pure insertion (the `*** 1,3 ****` section prints
* no context lines at all) and it is the one rule here that
* looks like a bug until it is checked against the reference.
*
* TIMESTAMPS. POSIX's -u/-c header lines carry a pathname and a
* file timestamp; the timestamp's TEXT is unspecified. maux
* prints the pathname alone, no <tab>, no timestamp: a ProDOS
* file's modification stamp is whatever the clock said at
* WRITE time and is simply absent (zero) on a machine that
* booted with no clock -- the same NOCLOCK fact `date` and
* `ls -l` already carry -- so a timestamp here would be either
* a lie or a blank column. `patch` reads the name up to a
* <tab> OR to end-of-line for exactly this reason, so a maux
* diff feeds maux's patch and a host diff does too.
*---------------------------------------------------------------

*---------------------------------------------------------------
* DFPARSED -- IN: OPTARG -> high-bit NUL-terminated digits
* (split.s's own "copy OPTARG into PTR0, index with Y" idiom --
* OPTARG lives in liba's bss arena, not zero page, so it cannot
* be an indirect base itself). OUT: A = value, saturating at
* 239 (the accumulator refuses a 10x that would wrap; -U/-C are
* clamped to MAXLINES by the caller anyway). Jumps to USAGERR
* (no return) on a non-digit or an empty argument -- `diff -U x`
* is a usage error, not a silent 0.
*---------------------------------------------------------------
DFPARSED    lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            stz   DF_TMP2
            ldy   #0
            lda   (PTR0),y
            beq   :bad
:ploop      lda   (PTR0),y
            beq   :pdone
            and   #$7F
            cmp   #'0'
            bcc   :bad
            cmp   #'9'+1
            bcs   :bad
            and   #$0F
            sta   DF_TMP
            lda   DF_TMP2
            cmp   #24             ;24*10+9 would wrap a byte
            bcs   :sat
            asl   a               ;acc*2
            sta   DTMPA
            asl   a               ;acc*4
            asl   a               ;acc*8
            clc
            adc   DTMPA           ;acc*10
            clc
            adc   DF_TMP
            sta   DF_TMP2
            iny
            bra   :ploop
:sat        lda   #239
            sta   DF_TMP2
            iny
            bra   :ploop
:pdone      lda   DF_TMP2
            rts
:bad        jmp   USAGERR

*---------------------------------------------------------------
* PRSTR -- A/X = lo/hi of a NUL-terminated high-bit string.
* Print it to fd 1. PRCR -- one CR to fd 1. DFPUT1 -- A to
* fd 1. PRDEC -- A as unsigned decimal to fd 1.
*---------------------------------------------------------------
PRSTR       sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS

PRCR        lda   #$8D
DFPUT1      ldx   #FD_STDOUT
            jmp   PUTC

PRDEC       sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jmp   PRNUM

*---------------------------------------------------------------
* PRPA/PRPB -- IN: A = 1-based line number in file1/file2.
* Print CPFX, then CPFX2 if it is non-zero, then the line and a
* CR. CPFX2 = 0 is -u's one-character prefix; -c sets both.
*---------------------------------------------------------------
PRPA        sta   CLN
            jsr   PRPFX
            lda   CLN
            jmp   PRLINE_A

PRPB        sta   CLN
            jsr   PRPFX
            lda   CLN
            jmp   PRLINE_B

PRPFX       lda   CPFX
            jsr   DFPUT1
            lda   CPFX2
            beq   :nop2
            jsr   DFPUT1
:nop2       rts

*---------------------------------------------------------------
* PRNAMES -- the two header lines. IN: A/X = lo/hi of the
* first line's leader string, CHDR2 is always the second's.
* Used by -c (`*** f1` / `--- f2`); -u passes its own pair.
*---------------------------------------------------------------
PRNAME1     jsr   PRSTR
            lda   #<DP1             ;the PAIR's path (-r and
            sta   PTR0              ;FILE DIR name a path argv
            lda   #>DP1             ;never held)
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            jmp   PRCR

PRNAME2     jsr   PRSTR
            lda   #<DP2
            sta   PTR0
            lda   #>DP2
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            jmp   PRCR

*---------------------------------------------------------------
* GRPSCAN -- IN: GS = first hunk of a group. OUT: GE = last
* hunk of the group, and OSTART/OEND/OCNT, NSTART/NEND/NCNT
* filled for it. See the header for the merge rule and the
* range formulas. CLOBBERS: A,X,Y, HA/HB/HDELS/HINS, DF_TMP.
*---------------------------------------------------------------
GRPSCAN     lda   GS
            sta   GE
:sloop      lda   GE
            clc
            adc   #1
            cmp   NHUNKS
            bcs   :sdone         ;no hunk after GE
            lda   GE
            jsr   GETHUNK
            clc
            lda   HA
            adc   HDELS
            sta   CLN            ;last changed old line of GE
            lda   GE
            clc
            adc   #1
            jsr   GETHUNK
            lda   HA
            sec
            sbc   CLN            ;unchanged lines between
            sta   CLN2
            lda   CTXN
            asl   a              ;2*CTXN (CTXN is capped at
                                 ;MAXLINES, so no carry)
            cmp   CLN2
            bcc   :sdone         ;2*CTXN < gap -- split here
            inc   GE
            bra   :sloop
:sdone      lda   GS
            jsr   GETHUNK
            lda   HA
            sta   FHA
            lda   HB
            sta   FHB
            lda   GE
            jsr   GETHUNK
            clc
            lda   HA
            adc   HDELS
            sta   LAE
            clc
            lda   HB
            adc   HINS
            sta   LBE

            lda   FHA            ;OSTART
            cmp   CTXN
            bcc   :oat1
            sec
            sbc   CTXN
            clc
            adc   #1
            sta   OSTART
            bra   :oend
:oat1       lda   #1
            sta   OSTART
:oend       clc                  ;OEND
            lda   LAE
            adc   CTXN
            cmp   NA
            bcc   :oek
            lda   NA
:oek        sta   OEND
            lda   OEND           ;OCNT
            cmp   OSTART
            bcs   :ocok
            stz   OCNT
            bra   :nstart
:ocok       sec
            sbc   OSTART
            clc
            adc   #1
            sta   OCNT

:nstart     lda   FHB            ;NSTART
            cmp   CTXN
            bcc   :nat1
            sec
            sbc   CTXN
            clc
            adc   #1
            sta   NSTART
            bra   :nend
:nat1       lda   #1
            sta   NSTART
:nend       clc                  ;NEND
            lda   LBE
            adc   CTXN
            cmp   NB
            bcc   :nek
            lda   NB
:nek        sta   NEND
            lda   NEND           ;NCNT
            cmp   NSTART
            bcs   :ncok
            stz   NCNT
            rts
:ncok       sec
            sbc   NSTART
            clc
            adc   #1
            sta   NCNT
            rts

*---------------------------------------------------------------
* GRPHASD/GRPHASI -- carry SET if any hunk of the group has a
* deletion / an insertion. -c's two section bodies are printed
* only when their own side has one. CLOBBERS: A,X,Y, GK, and
* the HA/HB/HDELS/HINS quartet.
*---------------------------------------------------------------
GRPHASD     lda   GS
            sta   GK
:dl         lda   GK
            jsr   GETHUNK
            lda   HDELS
            bne   :dyes
            lda   GK
            cmp   GE
            bcs   :dno
            inc   GK
            bra   :dl
:dyes       sec
            rts
:dno        clc
            rts

GRPHASI     lda   GS
            sta   GK
:il         lda   GK
            jsr   GETHUNK
            lda   HINS
            bne   :iyes
            lda   GK
            cmp   GE
            bcs   :ino
            inc   GK
            bra   :il
:iyes       sec
            rts
:ino        clc
            rts

*---------------------------------------------------------------
* OUTU -- unified output. Header pair, then one `@@` hunk per
* group followed by its interleaved body.
*---------------------------------------------------------------
OUTU        lda   #<UHDR1
            ldx   #>UHDR1
            jsr   PRNAME1
            lda   #<UHDR2
            ldx   #>UHDR2
            jsr   PRNAME2
            stz   GS
:gloop      lda   GS
            cmp   NHUNKS
            bcc   :grp
            rts
:grp        jsr   GRPSCAN
            lda   #<UAT
            ldx   #>UAT
            jsr   PRSTR
            lda   OSTART
            sta   CLN
            lda   OCNT
            sta   CLN2
            jsr   PRRNGU
            lda   #<UATP
            ldx   #>UATP
            jsr   PRSTR
            lda   NSTART
            sta   CLN
            lda   NCNT
            sta   CLN2
            jsr   PRRNGU
            lda   #<UATE
            ldx   #>UATE
            jsr   PRSTR
            jsr   PRCR
            jsr   UBODY
            lda   GE
            clc
            adc   #1
            sta   GS
            bra   :gloop

*---------------------------------------------------------------
* PRRNGU -- IN: CLN = start, CLN2 = count. Prints POSIX's
* unified range: "l,c", or "l" when c is 1, or "l-1,0" when c
* is 0 (see the header -- measured).
*---------------------------------------------------------------
PRRNGU      lda   CLN2
            bne   :upos
            lda   CLN
            sec
            sbc   #1
            jsr   PRDEC
            lda   #$AC           ;',' as hex -- merlin32 gets
            jsr   DFPUT1         ;#"," wrong (diffhnk.s's note)
            lda   #$B0           ;'0'
            jmp   DFPUT1
:upos       lda   CLN
            jsr   PRDEC
            lda   CLN2
            cmp   #1
            beq   :udone
            lda   #$AC
            jsr   DFPUT1
            lda   CLN2
            jsr   PRDEC
:udone      rts

*---------------------------------------------------------------
* UBODY -- the group's interleaved body: leading context, then
* per hunk its deletions and insertions, then trailing context.
*---------------------------------------------------------------
UBODY       lda   OSTART
            sta   CURA
            lda   NSTART
            sta   CURB
            lda   GS
            sta   GK
:kloop      lda   GK
            cmp   GE
            beq   :dohunk
            bcs   :ktail
:dohunk     lda   GK
            jsr   GETHUNK
:uctx       lda   CURA
            cmp   HA
            beq   :uctxp
            bcs   :udels
:uctxp      lda   #$A0           ;' '
            sta   CPFX
            stz   CPFX2
            lda   CURA
            jsr   PRPA
            inc   CURA
            inc   CURB
            bra   :uctx
:udels      lda   HDELS
            beq   :uins
            sta   GKN
:udl        lda   #$AD           ;'-'
            sta   CPFX
            stz   CPFX2
            lda   CURA
            jsr   PRPA
            inc   CURA
            dec   GKN
            bne   :udl
:uins       lda   HINS
            beq   :uknext
            sta   GKN
:uil        lda   #$AB           ;'+'
            sta   CPFX
            stz   CPFX2
            lda   CURB
            jsr   PRPB
            inc   CURB
            dec   GKN
            bne   :uil
:uknext     inc   GK
            bra   :kloop
:ktail      lda   CURA
            cmp   OEND
            beq   :utp
            bcs   :utdone
:utp        lda   #$A0
            sta   CPFX
            stz   CPFX2
            lda   CURA
            jsr   PRPA
            inc   CURA
            inc   CURB
            bra   :ktail
:utdone     rts
