*---------------------------------------------------------------
* sortcmp.s -- sort's ordering half: SORTLINES/OUTPUT and the
* whole -n/-k comparator family (SORTCMP/KEYSCMP/CMPKEY/KEYB/
* TXTKCMP/NUMKCMP/PARSEKEY/PARSEDEC). Split from sort.s
* 2026-09-01 at
* the SORTLINES global boundary: the keys grew sort's converted
* REL main past as's window and the L3 sweep skipped it as a
* NEW tier-2 -- the ratchet that keeps every util self-hosting.
* One assembly stream, put by sort.s exactly where the text
* sat; every manifest-header rule applies unchanged.
*---------------------------------------------------------------

*---------------------------------------------------------------
* SORTLINES -- shell sort (halving gap) over LINEPTRS[0..NLINES)
* by SORTCMP on the lines they address. SORTCMP already returns
* the FINAL sense (per-key r and the global -r are applied
* inside it), so the array ends up in final order directly --
* no separate reverse pass. No recursion: the 256-byte hardware
* stack never sees this loop.
*---------------------------------------------------------------
SORTLINES   lda   NLINES
            sta   SRT_GAP
            lda   NLINES+1
            sta   SRT_GAP+1
:halvegap   lsr   SRT_GAP+1
            ror   SRT_GAP
            lda   SRT_GAP
            ora   SRT_GAP+1
            bne   :gapok
            jmp   :sortdone
:gapok      lda   SRT_GAP
            sta   SRT_I
            lda   SRT_GAP+1
            sta   SRT_I+1
:iloop      lda   SRT_I+1
            cmp   NLINES+1
            bcc   :dorow
            beq   :chklo
            jmp   :nexti
:chklo      lda   SRT_I
            cmp   NLINES
            bcc   :dorow
            jmp   :nexti
:dorow      lda   SRT_I
            sta   SRT_IDX
            lda   SRT_I+1
            sta   SRT_IDX+1
            jsr   LPGET_A
            lda   SRT_AVAL
            sta   SRT_TVAL
            lda   SRT_AVAL+1
            sta   SRT_TVAL+1
            lda   SRT_I
            sta   SRT_J
            lda   SRT_I+1
            sta   SRT_J+1
:jloop      lda   SRT_J+1
            cmp   SRT_GAP+1
            bcc   :toins
            bne   :dosub
            lda   SRT_J
            cmp   SRT_GAP
            bcc   :toins
            bra   :dosub
:toins      jmp   :insert
:dosub      sec
            lda   SRT_J
            sbc   SRT_GAP
            sta   SRT_JM
            lda   SRT_J+1
            sbc   SRT_GAP+1
            sta   SRT_JM+1
            lda   SRT_JM
            sta   SRT_IDX
            lda   SRT_JM+1
            sta   SRT_IDX+1
            jsr   LPGET_A
            lda   SRT_AVAL
            sta   PTR0
            lda   SRT_AVAL+1
            sta   PTR0+1
            lda   SRT_TVAL
            sta   PTR1
            lda   SRT_TVAL+1
            sta   PTR1+1
            jsr   SORTCMP               ;already in FINAL sense
            cmp   #1                    ;(-r is inside SORTCMP)
            beq   :doshift
            bra   :insert
:doshift    lda   SRT_J
            sta   SRT_IDX
            lda   SRT_J+1
            sta   SRT_IDX+1
            jsr   LPSET_A
            lda   SRT_JM
            sta   SRT_J
            lda   SRT_JM+1
            sta   SRT_J+1
            jmp   :jloop
:insert     lda   SRT_J
            sta   SRT_IDX
            lda   SRT_J+1
            sta   SRT_IDX+1
            lda   SRT_TVAL
            sta   SRT_AVAL
            lda   SRT_TVAL+1
            sta   SRT_AVAL+1
            jsr   LPSET_A
            inc   SRT_I
            bne   :noh
            inc   SRT_I+1
:noh        jmp   :iloop
:nexti      jmp   :halvegap
:sortdone   rts

*---------------------------------------------------------------
* OUTPUT -- print LINEPTRS[0..NLINES) in array order (already
* the final order -- see SORTLINES). -u drops a line equal
* (STRCMP) to the immediately preceding PRINTED line.
*---------------------------------------------------------------
OUTPUT      stz   SRT_HASPREV
            stz   SRT_I
            stz   SRT_I+1
:oloop      lda   SRT_I+1
            cmp   NLINES+1
            bcc   :dop
            beq   :ochklo
            jmp   :odone
:ochklo     lda   SRT_I
            cmp   NLINES
            bcc   :dop
            jmp   :odone
:dop        lda   SRT_I
            sta   SRT_IDX
            lda   SRT_I+1
            sta   SRT_IDX+1
            jsr   LPGET_A
            lda   WANT_U
            beq   :doprint
            lda   SRT_HASPREV
            beq   :doprint
            lda   SRT_AVAL
            sta   PTR0
            lda   SRT_AVAL+1
            sta   PTR0+1
            lda   SRT_PREV
            sta   PTR1
            lda   SRT_PREV+1
            sta   PTR1+1
            jsr   KEYSCMP               ;-u drops on equal KEYS,
            beq   :oskip                ;no last-resort here
:doprint    lda   SRT_AVAL
            sta   PTR0
            lda   SRT_AVAL+1
            sta   PTR0+1
            ldx   OUTFDV                ;FD_STDOUT, or -o's fd
            jsr   PUTS
            lda   #$8D
            ldx   OUTFDV
            jsr   PUTC
            lda   SRT_AVAL
            sta   SRT_PREV
            lda   SRT_AVAL+1
            sta   SRT_PREV+1
            lda   #1
            sta   SRT_HASPREV
:oskip      inc   SRT_I
            bne   :onoh
            inc   SRT_I+1
:onoh       jmp   :oloop
:odone      rts

*---------------------------------------------------------------
* CHECKORDER -- -c. Walks LINEPTRS[0..NLINES) in the ORIGINAL
* (READ) order -- never sorted, never printed (POSIX -c: "Output
* shall not be sent to standard output") -- comparing each
* adjacent pair with SORTCMP, the same key/-n/-t/-b/-f-aware
* comparator SORTLINES uses, so -c checks the order actually
* REQUESTED. SORTCMP's result is already in the final sense, so
* A>B is a violation whatever -r/per-key r say. On the first
* out-of-order pair: "sort: disorder: <line>" to fd 2 (the
* LATER line, the one out of place relative to its predecessor),
* exit 1. Falls off the end (no violation) with a plain `rts` --
* caller exits via ERRFLAG, same as a clean sort.
*---------------------------------------------------------------
CHECKORDER  stz   SRT_I
            stz   SRT_I+1
:cloop      lda   SRT_I
            clc
            adc   #1
            sta   SRT_J
            lda   SRT_I+1
            adc   #0
            sta   SRT_J+1
            lda   SRT_J+1                ;I+1 < NLINES ?
            cmp   NLINES+1
            bcc   :cdo
            bne   :cok
            lda   SRT_J
            cmp   NLINES
            bcc   :cdo
            bra   :cok
:cdo        lda   SRT_I
            sta   SRT_IDX
            lda   SRT_I+1
            sta   SRT_IDX+1
            jsr   LPGET_A
            lda   SRT_AVAL
            sta   PTR0
            lda   SRT_AVAL+1
            sta   PTR0+1
            lda   SRT_J
            sta   SRT_IDX
            lda   SRT_J+1
            sta   SRT_IDX+1
            jsr   LPGET_A
            lda   SRT_AVAL
            sta   PTR1
            lda   SRT_AVAL+1
            sta   PTR1+1
            jsr   SORTCMP               ;final sense: A>B is bad
            cmp   #1
            beq   :cbad
:cnext      lda   SRT_J
            sta   SRT_I
            lda   SRT_J+1
            sta   SRT_I+1
            jmp   :cloop
:cbad       lda   #<DISORDMSG
            sta   PTR0
            lda   #>DISORDMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jsr   EXIT
:cok        rts

*---------------------------------------------------------------
* SORTCMP -- the sort's ordering, FINAL sense (A=0 equal, $FF
* A<B, 1 A>B, Z per A): each -k key in order (KEYSCMP), then the
* reference's LAST-RESORT whole-line STRCMP on a tie -- reversed
* by the GLOBAL -r only (measured: BSD and GNU agree). With no
* key table (plain sort, or -r alone) the last resort IS the
* compare. IN/OUT/preservation: STRCMP's contract exactly.
*---------------------------------------------------------------
SORTCMP     lda   NKEYS
            beq   :last
            jsr   KEYSCMP
            bne   :out
:last       jsr   STRCMP
            ldx   WANT_R
            beq   :out
            jmp   NEGA
:out        rts

*---------------------------------------------------------------
* KEYSCMP -- try the keys in order; the first that differs
* decides, negated if THAT key carries r (FK_R in KT_FLG). Each
* key is loaded into the single-key cells CMPKEY reads (KEYNUM/
* KEYEND/WANT_N/WANT_F/WANT_B -- the globals were folded into
* the table by FINKEYS, so they are free to be reused here).
* NKEYS=0 is the plain whole-line STRCMP. OUT: SORTCMP's sense.
*---------------------------------------------------------------
KEYSCMP     lda   NKEYS
            bne   :keys
            jmp   STRCMP
:keys       stz   KIDX
:kloop      ldx   KIDX
            lda   KT_NUM,x
            sta   KEYNUM
            lda   KT_END,x
            sta   KEYEND
            lda   KT_FLG,x
            tay
            and   #FK_N
            sta   WANT_N
            tya
            and   #FK_F
            sta   WANT_F
            tya
            and   #FK_B
            sta   WANT_B
            jsr   CMPKEY
            bne   :differ
            inc   KIDX
            lda   KIDX
            cmp   NKEYS
            bcc   :kloop
            lda   #0
            rts
:differ     ldx   KIDX
            ldy   KT_FLG,x
            tax                         ;A -> X: keep the result
            tya
            and   #FK_R
            beq   :asis
            txa
            jmp   NEGA
:asis       txa
            rts

*-- NEGA -- A (0/1/$FF) negated; Z per the result.
NEGA        eor   #$FF
            inc   a
            rts
