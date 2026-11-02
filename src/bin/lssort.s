*---------------------------------------------------------------
* lssort.s -- ls's sorting half: SORTPATHS/PCMPJI/OPTKEYS/
* OPTKADDR/BLDKEY (the operand side), LISTDIR's collect loop,
* the ENTRIES addressing helpers, SORTENTRIES and ENTCMP. Split
* from lstop.s 2026-09-01 at the SORTPATHS global boundary for
* as's 16128-byte source window (check_dialect hazard 3b):
* -t/-r grew lstop.s to 16,869 stripped bytes, over the window
* BY ITSELF. One assembly stream, put by ls.s immediately after
* lstop.s; every manifest-header rule applies unchanged.
*---------------------------------------------------------------

*---------------------------------------------------------------
* LISTDIR -- open, read (via src/liba/readdir.s), collect (cap
* 128), sort and print one directory's contents. The walk itself
* -- key-block header, 39-byte entry stride, deleted-entry
* skipping, GS/OS case decode -- now lives entirely in
* OPENDIR/READDIR/CLOSEDIR (docs/FLEET.md's readdir ruling);
* this routine is just the collect-cap-sort-print policy that
* was always ls's own, not the walk's.
* IN:  A/X = lo/hi of an MLI-shaped (count-prefixed) pathname
*      buffer -- either PATHBUF (built by MKPATH) or PFXBUF
*      (GET_PREFIX's own answer, already the same shape).
* OUT: carry clear = ok (TRUNCATED set if the 128 cap was hit);
*      carry set = open/read failed, nothing printed.
*---------------------------------------------------------------
* SORTPATHS -- PORDER[0..NPATHS-1] = operand positions,
* sorted by NAME with STRCMPI (the same case-insensitive compare
* SORTENTRIES uses within a directory). Both passes index argv
* through PORDER, so operands are visited in sorted order rather
* than the order they were typed.
*
* WHY. /bin/ls sorts its operands before it groups them: `ls
* LSDIR TOPFILE1 EMPTYDIR` prints TOPFILE1, then EMPTYDIR's
* listing, then LSDIR's, even though EMPTYDIR was typed last.
* maux walked the arguments literally, so the same shell line
* produced a different ORDER here -- avoidable semantic drift,
* and the kind a script notices, because it changes stdout.
* Until 2026-08-25 the corpus ACCOMMODATED it, reordering
* reference's sections back into argv order; that transform is
* gone and the two agree directly.
*
* The files-first/directories-second grouping needed no work at
* all: pass 1 already prints plain files as it stats them and
* pass 2 lists the deferred directories afterwards, which IS the
* host's grouping. Sorting the operand list was the whole gap.
*
* Selection sort, NPATHS <= the STYPES bound. Loop counters live
* in memory, not X/Y, because GETARG and STRCMPI both clobber
* them. PORDER holds POSITIONS (0..NPATHS-1), never argv indices
* -- PATHSTART is added at each use site, exactly as before.
*---------------------------------------------------------------
SORTPATHS   stz   SP_I
:fill       lda   SP_I
            cmp   NPATHS
            bcs   :fdone
            ldx   SP_I
            sta   PORDER,x
            inc   SP_I
            bra   :fill
:fdone      stz   SP_I
:outer      lda   SP_I
            cmp   NPATHS
            bcs   :sdone
            lda   SP_I
            clc
            adc   #1
            sta   SP_J
:inner      lda   SP_J
            cmp   NPATHS
            bcs   :nexti
            jsr   PCMPJI          ;$FF = operand j sorts BEFORE
            cmp   #$FF            ;operand i under the active
            bne   :nextj          ;flags (-t/-r fold in there)
            ldx   SP_I
            lda   PORDER,x
            pha
            ldx   SP_J
            lda   PORDER,x
            ldx   SP_I
            sta   PORDER,x
            pla
            ldx   SP_J
            sta   PORDER,x
:nextj      inc   SP_J
            bra   :inner
:nexti      inc   SP_I
            bra   :outer
:sdone      rts

*---------------------------------------------------------------
* PCMPJI -- SORTPATHS' comparator: does operand PORDER[SP_J]
* sort BEFORE operand PORDER[SP_I]? $FF = yes (swap), else no.
* -t compares the OPTKEYS chronology keys, NEWEST FIRST, name
* breaking the tie; otherwise STRCMPI on the names. -r inverts
* the nonzero answer at the end, ties untouched.
*---------------------------------------------------------------
PCMPJI      lda   TFLAG
            beq   :names
            ldx   SP_J
            lda   PORDER,x
            jsr   OPTKADDR        ;-> PTR1
            lda   PTR1
            sta   LS_ENT          ;free during the path sort
            lda   PTR1+1
            sta   LS_ENT+1
            ldx   SP_I
            lda   PORDER,x
            jsr   OPTKADDR
            ldy   #0
:tcl        lda   (LS_ENT),y      ;J's key byte
            cmp   (PTR1),y        ;I's
            bne   :tdiff
            iny
            cpy   #5
            bne   :tcl
            bra   :names          ;same instant: name decides
:tdiff      bcc   :jolder
            lda   #$FF            ;J newer -> J first
            bra   :apply
:jolder     lda   #1
            bra   :apply
*-- operand i -> PTR1 (GETARG answers in PTR0, so it is copied
*-- out of the way before the second fetch overwrites it)
:names      ldx   SP_I
            lda   PORDER,x
            clc
            adc   PATHSTART
            jsr   GETARG
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
*-- operand j -> PTR0
            ldx   SP_J
            lda   PORDER,x
            clc
            adc   PATHSTART
            jsr   GETARG
            jsr   STRCMPI         ;$FF = (PTR0) before (PTR1)
:apply      ldx   RFLAG
            beq   :out
            cmp   #0
            beq   :out            ;a tie has no direction
            eor   #$FE            ;$FF <-> $01
:out        rts

*---------------------------------------------------------------
* OPTKEYS -- -t's stat prepass: build a 5-byte chronology key
* per operand in OPTIMES (stride 8) BEFORE SORTPATHS runs. A
* GFI failure keys as ALL ZEROS -- unstattable sorts oldest,
* and pass 1 will print the error either way; nothing is said
* here. No-op without -t (and SORTPATHS reads OPTIMES only
* under -t, which is what keeps the arena's no-zeroing rule
* safe).
*---------------------------------------------------------------
OPTKEYS     lda   TFLAG
            bne   :go
            rts
:go         stz   PATHIDX
:kloop      lda   PATHIDX
            cmp   NPATHS
            bcs   :kdone
            lda   PATHIDX
            clc
            adc   PATHSTART
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :kfail
            lda   PATHIDX
            jsr   OPTKADDR        ;slot -> PTR1
            lda   #<GFIPARM_MDATE
            sta   PTR0
            lda   #>GFIPARM_MDATE
            sta   PTR0+1
            jsr   BLDKEY
            bra   :knext
:kfail      lda   PATHIDX
            jsr   OPTKADDR
            lda   #0
            ldy   #4
:kz         sta   (PTR1),y
            dey
            bpl   :kz
:knext      inc   PATHIDX
            bra   :kloop
:kdone      rts

*---------------------------------------------------------------
* OPTKADDR -- A = operand POSITION -> PTR1 = &OPTIMES[A*8].
* Stride 8 (three shifts) for a 5-byte key; the 3 pad bytes buy
* the cheap addressing.
*---------------------------------------------------------------
OPTKADDR    sta   LS_TMP16
            stz   LS_TMP16+1
            asl   LS_TMP16
            rol   LS_TMP16+1
            asl   LS_TMP16
            rol   LS_TMP16+1
            asl   LS_TMP16
            rol   LS_TMP16+1
            clc
            lda   LS_TMP16
            adc   #<OPTIMES
            sta   PTR1
            lda   LS_TMP16+1
            adc   #>OPTIMES
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* BLDKEY -- 5-byte big-endian-comparable chronology key from a
* raw ProDOS mod_date/mod_time pair. IN: PTR0 = &mod_date (the
* 4 bytes date-lo,date-hi,time-lo,time-hi -- both GFIPARM_MDATE
* and a record's RD_MDATE have exactly this shape); PTR1 = the
* 5-byte destination. Key bytes, most significant first:
*   0  year, PIVOT-ADJUSTED: raw 0..77 means 2000..2077 (docs/
*      PRODOS-VERSION.md's standing ruling), so +100 puts it
*      ABOVE raw 78..99 (1978..1999) and a plain byte compare
*      is chronology
*   1  month bit 3 (date-hi bit 0)
*   2  date-lo (month bits 2-0 then day -- already in order)
*   3  hour (time-hi)   4  minute (time-lo)
* A ZERO date word keys all-zero: "no date" sorts oldest, not
* as the year 2000.
*---------------------------------------------------------------
BLDKEY      ldy   #0
            lda   (PTR0),y
            ldy   #1
            ora   (PTR0),y
            bne   :dated
            lda   #0
            ldy   #4
:zk         sta   (PTR1),y
            dey
            bpl   :zk
            rts
:dated      lda   (PTR0),y        ;date hi (y=1)
            lsr   a               ;year = hi>>1
            cmp   #78
            bcs   :pivoted
            adc   #100            ;carry known clear (bcc path)
:pivoted    ldy   #0
            sta   (PTR1),y
            ldy   #1
            lda   (PTR0),y
            and   #1              ;month bit 3
            sta   (PTR1),y
            ldy   #0
            lda   (PTR0),y        ;date lo
            ldy   #2
            sta   (PTR1),y
            ldy   #3
            lda   (PTR0),y        ;time hi = hour
            sta   (PTR1),y
            ldy   #2
            lda   (PTR0),y        ;time lo = minute
            ldy   #4
            sta   (PTR1),y
            rts

*---------------------------------------------------------------
LISTDIR     sta   LS_RPAR
            stx   LS_RPAR+1
            jsr   OPENDIR
            bcc   :opok
            sec
            rts
:opok       lda   RD_FCNT+1
*-- The low byte needs no test any more: with LS_MAXENT at 255
*-- every 8-bit count fits, so only a directory of 256 or more
*-- can truncate -- which is exactly what a nonzero high byte
*-- says. (It used to `cmp #129` here.)
            beq   :notbig
:bigcount   lda   #1
            sta   TRUNCATED
            bra   :capset
:notbig     stz   TRUNCATED
:capset     stz   ENTRYCOUNT
:rloop      lda   ENTRYCOUNT
            cmp   #LS_MAXENT
            bcs   :walkdone          ;collected the cap -- stop
            jsr   ENTADDR            ;LS_ENT=&ENTRIES[i], below
            lda   LS_ENT
            ldx   LS_ENT+1
            jsr   READDIR
            bcs   :rdone
            inc   ENTRYCOUNT
            bra   :rloop
:rdone      cmp   #0
            beq   :walkdone          ;clean EOF
            jsr   CLOSEDIR           ;a genuine mid-walk READ
            sec                      ;error -- abort, print
            rts                      ;nothing (old ls.s's own
                                      ;:rderr behavior)

:walkdone   jsr   CLOSEDIR
            jsr   SORTENTRIES
            jsr   PRINTENTRIES
            jsr   QUEUEDIRS
            clc
            rts

*---------------------------------------------------------------
* MULT32/ENTADDR/ENTADDR2 -- entry index -> &ENTRIES[index].
*---------------------------------------------------------------
MULT32      sta   LS_TMP16
            stz   LS_TMP16+1
            ldx   #5
:sh         asl   LS_TMP16
            rol   LS_TMP16+1
            dex
            bne   :sh
            rts

ENTADDR     jsr   MULT32
            clc
            lda   LS_TMP16
            adc   #<ENTRIES
            sta   LS_ENT
            lda   LS_TMP16+1
            adc   #>ENTRIES
            sta   LS_ENT+1
            rts

ENTADDR2    jsr   MULT32
            clc
            lda   LS_TMP16
            adc   #<ENTRIES
            sta   LS_ENT2
            lda   LS_TMP16+1
            adc   #>ENTRIES
            sta   LS_ENT2+1
            rts

*---------------------------------------------------------------
* SORTENTRIES -- ascending insertion sort by RD_NAME, using
* STRCMPI (case-insensitive -- see string.s's own header for why
* this needs folding now that readdir.s hands back a case-
* DECODED name, where the old ENT_NAME's plain STRCMP relied on
* every stored byte being uppercase).
*
* SORTS AN INDEX, NOT THE RECORDS (2026-09-03). The records stay
* where READDIR put them; ENTIDX[0..n-1] holds their order and
* PRINTENTRIES walks it. The old form shifted whole 32-byte
* records on every insertion step and re-derived both operands'
* addresses with a shift-multiply per compare: measured 1.12 M
* cycles of user code with no syscall in it for a 48-entry
* directory (docs/CONSOLE-OPT.md sec 8) -- a third of `ls`. Now
* a shift is one byte and the key's address is computed once per
* outer step. Stable, as before: equal keys keep READDIR order.
*
* ENTIDX is filled 0..n-1 BEFORE the <2 early-out, so a 0- or
* 1-entry listing still prints through a valid index (the
* read-before-write trace in ls.s's header).
*---------------------------------------------------------------
SORTENTRIES ldx   #0
:ident      cpx   ENTRYCOUNT
            bcs   :filled
            txa
            sta   ENTIDX,x
            inx
            bra   :ident
:filled     lda   ENTRYCOUNT
            cmp   #2
            bcs   :cansort
            jmp   :sdone
:cansort    lda   #1
            sta   SORTI
:outer      lda   SORTI
            cmp   ENTRYCOUNT
            bcc   :dosort
            jmp   :sdone
:dosort     ldx   SORTI
            lda   ENTIDX,x
            sta   SORTKEY            ;the record being placed
            jsr   ENTADDR            ;LS_ENT = &entries[key],
                                     ;fixed for this outer step
            lda   SORTI
            sec
            sbc   #1
            sta   SORTJ
:inner      lda   SORTJ
*-- $FF, NOT "negative". `bmi` here tested bit 7, which is set
*-- by the sentinel $FF (j fell off the bottom) AND by every
*-- real index from 128 up -- so the inner scan bailed instantly
*-- for every element past 127 and the tail of a big directory
*-- came out unsorted. THAT is what the old 128 cap was really
*-- pinned to: not the size of ENTRIES, but this branch. Raising
*-- the cap without this is a silently wrong listing, which is
*-- how check-e2e-fs case 16 caught it (2026-09-20).
            cmp   #$FF
            beq   :place
            tax
            lda   ENTIDX,x
            jsr   ENTADDR2           ;LS_ENT2 = &entries[idx[j]]
            jsr   ENTCMP             ;-t/-r-aware; plain mode is
            cmp   #$FF               ;the old STRCMPI unchanged.
            bne   :place             ;$FF = key before idx[j]:
            ldx   SORTJ              ;shift ONE BYTE up
            lda   ENTIDX,x
            sta   ENTIDX+1,x
            dec   SORTJ
            bra   :inner
:place      ldx   SORTJ              ;idx[j+1] = key. j may be
            inx                      ;-1: X wraps $FF -> 0, so
            lda   SORTKEY            ;index ENTIDX,x -- NOT
            sta   ENTIDX,x           ;ENTIDX+1,x (+256 at $FF)
            inc   SORTI
            jmp   :outer
:sdone      rts

*---------------------------------------------------------------
* ENTCMP -- SORTENTRIES' comparator: does the key record (at
* LS_ENT) sort BEFORE entries[idx[j]] (at LS_ENT2)? $FF = yes.
* -t builds both records' chronology keys with BLDKEY and takes
* the NEWER first, names breaking the tie; plain mode is the
* STRCMPI this replaced, byte for byte. -r inverts nonzero
* answers last, so it reverses -t and name order alike (ties
* keep no direction, which is what keeps the insertion sort
* stable on them). Both operands are POINTERS now -- the old
* KEYBUF copy, and its real-Merlin hi-byte-offset caveat, are
* gone.
*---------------------------------------------------------------
ENTCMP      lda   TFLAG
            beq   :names
            clc
            lda   LS_ENT
            adc   #RD_MDATE
            sta   PTR0
            lda   LS_ENT+1
            adc   #0
            sta   PTR0+1
            lda   #<KEYA
            sta   PTR1
            lda   #>KEYA
            sta   PTR1+1
            jsr   BLDKEY
            clc
            lda   LS_ENT2
            adc   #RD_MDATE
            sta   PTR0
            lda   LS_ENT2+1
            adc   #0
            sta   PTR0+1
            lda   #<KEYB
            sta   PTR1
            lda   #>KEYB
            sta   PTR1+1
            jsr   BLDKEY
            ldx   #0
:tcl        lda   KEYA,x
            cmp   KEYB,x
            bne   :tdiff
            inx
            cpx   #5
            bne   :tcl
            bra   :names             ;same instant: name decides
:tdiff      bcc   :kolder
            lda   #$FF               ;key newer -> key first
            bra   :apply
:kolder     lda   #1
            bra   :apply
:names      clc
            lda   LS_ENT
            adc   #RD_NAME
            sta   PTR0
            lda   LS_ENT+1
            adc   #0
            sta   PTR0+1
            clc
            lda   LS_ENT2
            adc   #RD_NAME
            sta   PTR1
            lda   LS_ENT2+1
            adc   #0
            sta   PTR1+1
            jsr   STRCMPI            ;case-insensitive -- see
                                      ;file header's SORTENTRIES
                                      ;note and string.s's own
:apply      ldx   RFLAG
            beq   :out
            cmp   #0
            beq   :out
            eor   #$FE               ;$FF <-> $01
:out        rts
