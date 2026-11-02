*---------------------------------------------------------------
* sortkey.s -- sort's key-bounds half: CMPKEY/KEYB/TXTKCMP
* plus PARSEKEY/PARSEMOD/PARSEDEC (SORTCMP/KEYSCMP, the key
* LOOP, live in sortcmp.s). Further split 2026-09-01:
* window charges the MAIN plus its LARGEST put, so one big put
* is the same debt as inline text; smaller pieces are the only
* way down. One assembly stream, put in place; every
* manifest-header rule applies unchanged.
*---------------------------------------------------------------

*---------------------------------------------------------------
* CMPKEY -- compare the KEYS of the lines at PTR0/PTR1: the -k
* field window, numerically under -n. With neither flag this is
* STRCMP itself. OUT: A=0 equal, $FF A<B, 1 A>B (flags per the
* lda/tya before rts). PRESERVES PTR0/PTR1 (KEYB copies, never
* walks the caller's pointers). CLOBBERS A,X,Y + the SRT_K*
* window.
*---------------------------------------------------------------
CMPKEY      lda   WANT_N
            ora   KEYNUM
            ora   WANT_F
            ora   WANT_B
            bne   :keyed
            jmp   STRCMP
:keyed      lda   PTR1                  ;B first, so A's results
            sta   SRT_KA                ;can stay where KEYB
            lda   PTR1+1                ;leaves them
            sta   SRT_KA+1
            jsr   KEYB
            lda   SRT_KA
            sta   SRT_KB
            lda   SRT_KA+1
            sta   SRT_KB+1
            lda   SRT_KAE
            sta   SRT_KBE
            lda   SRT_KAE+1
            sta   SRT_KBE+1
            lda   PTR0
            sta   SRT_KA
            lda   PTR0+1
            sta   SRT_KA+1
            jsr   KEYB
            lda   WANT_N
            beq   :txt
            jmp   NUMKCMP
:txt        jmp   TXTKCMP

*---------------------------------------------------------------
* KEYB -- key bounds for ONE line. IN: SRT_KA = line start.
* OUT: SRT_KA = key start (start of field KEYNUM); SRT_KAE = key
* end (the NUL for KEYEND=0, else after field KEYEND's last
* char). KEYNUM=0 means the whole line. Every scan stops at the
* NUL, so a line with too few fields yields an empty key. Under
* -n the end is not computed (digits end the number), so SRT_KAE
* is left equal to SRT_KA.
*
* -t (SEPFLAG): fields are delimited by exactly ONE SEPCHAR byte
* -- empty fields count, and a field owns none of its neighbour
* separators. Without -t, fields are blank-run delimited and a
* field OWNS ITS LEADING BLANKS (POSIX default) -- -k2's key on
* "a  b" is "  b".
*
* -b (WANT_B, the CURRENT key's b on field_start): after the key
* start above is found, skip any further leading blanks. Applies
* under -t too (a field can start with blanks right after its
* separator). b on field_END is accepted and changes nothing
* (measured, BSD == GNU, while there are no character offsets).
*---------------------------------------------------------------
KEYB        lda   KEYNUM
            beq   :whole
            sta   SRT_KCNT
            dec   SRT_KCNT
:fskip      lda   SRT_KCNT              ;skip KEYNUM-1 fields
            beq   :atkey
            lda   SEPFLAG
            bne   :tskip1
            jsr   SKIPBL
            jsr   SKIPNB
            bra   :fskdec
:tskip1     jsr   TSKIP
:fskdec     dec   SRT_KCNT
            bra   :fskip
:whole
:atkey      lda   WANT_B                ;-b: drop leading blanks
            beq   :nobb
            jsr   SKIPBL
:nobb       lda   WANT_N                ;-n: no end needed
            bne   :noend
            lda   KEYEND
            bne   :bounded
            ;-- to the NUL
            lda   SRT_KA
            sta   SRT_KAE
            lda   SRT_KA+1
            sta   SRT_KAE+1
:toeol      lda   (SRT_KAE)
            beq   :out
            inc   SRT_KAE
            bne   :toeol
            inc   SRT_KAE+1
            bra   :toeol
:bounded    ;-- fields KEYNUM..KEYEND: walk a COPY in KAE
            lda   SRT_KA
            sta   SRT_KAE
            lda   SRT_KA+1
            sta   SRT_KAE+1
            lda   KEYEND
            sec
            sbc   KEYNUM
            sta   SRT_KCNT              ;fields BETWEEN, then
            inc   SRT_KCNT              ;one more = through M
            lda   SEPFLAG
            beq   :floop
            jsr   TFLDEND
            bra   :out
:floop      jsr   SKIPBLE
            jsr   SKIPNBE
            dec   SRT_KCNT
            bne   :floop
            bra   :out
:noend      lda   SRT_KA
            sta   SRT_KAE
            lda   SRT_KA+1
            sta   SRT_KAE+1
:out        rts

*-- SKIPBL/SKIPNB advance SRT_KA past blanks / nonblanks;
*-- SKIPBLE/SKIPNBE are the same walks on SRT_KAE. All four
*-- stop at the NUL. A blank is space or tab in EITHER text
*-- convention (bit 7 masked before the test).
SKIPBL      lda   (SRT_KA)
            beq   :out
            jsr   ISBLANK
            bcc   :out
            inc   SRT_KA
            bne   SKIPBL
            inc   SRT_KA+1
            bra   SKIPBL
:out        rts

SKIPNB      lda   (SRT_KA)
            beq   :out
            jsr   ISBLANK
            bcs   :out
            inc   SRT_KA
            bne   SKIPNB
            inc   SRT_KA+1
            bra   SKIPNB
:out        rts

SKIPBLE     lda   (SRT_KAE)
            beq   :out
            jsr   ISBLANK
            bcc   :out
            inc   SRT_KAE
            bne   SKIPBLE
            inc   SRT_KAE+1
            bra   SKIPBLE
:out        rts

SKIPNBE     lda   (SRT_KAE)
            beq   :out
            jsr   ISBLANK
            bcs   :out
            inc   SRT_KAE
            bne   SKIPNBE
            inc   SRT_KAE+1
            bra   SKIPNBE
:out        rts

*-- ISBLANK -- carry set if A is a space or tab (either text
*-- convention). Preserves A.
ISBLANK     tax
            and   #$7F
            cmp   #$20
            beq   :yes
            cmp   #$09
            beq   :yes
            txa
            clc
            rts
:yes        txa
            sec
            rts

*---------------------------------------------------------------
* T-MODE FIELD WALKS (SEPFLAG) -- fields are exactly-one-CHAR
* delimited (POSIX -t): a separator ends a field even if empty,
* never blank-run collapsed. TCONTENTA/TCONTENTE walk SRT_KA/
* SRT_KAE over ONE field's content, stopping AT the next
* separator or the NUL -- never consuming it.
*---------------------------------------------------------------
TCONTENTA   lda   (SRT_KA)
            and   #$7F
            beq   :out
            cmp   SEPCHAR
            beq   :out
            inc   SRT_KA
            bne   TCONTENTA
            inc   SRT_KA+1
            bra   TCONTENTA
:out        rts

TCONTENTE   lda   (SRT_KAE)
            and   #$7F
            beq   :out
            cmp   SEPCHAR
            beq   :out
            inc   SRT_KAE
            bne   TCONTENTE
            inc   SRT_KAE+1
            bra   TCONTENTE
:out        rts

*---------------------------------------------------------------
* TSKIP -- advance SRT_KA past exactly ONE field: its content,
* then the separator ending it (consumed -- lands at the next
* field's start). Content run to the NUL leaves SRT_KA there,
* unconsumed: KEYB's "too few fields" empty-key rule.
*---------------------------------------------------------------
TSKIP       jsr   TCONTENTA
            lda   (SRT_KA)
            and   #$7F
            beq   :out
            inc   SRT_KA
            bne   :out
            inc   SRT_KA+1
:out        rts

*---------------------------------------------------------------
* TFLDEND -- IN: SRT_KAE = start of field KEYNUM, SRT_KCNT =
* KEYEND-KEYNUM+1. OUT: SRT_KAE positioned right AFTER field
* KEYEND's last content byte -- AT the separator ending it
* (excluded from the key), or at the NUL if the line ran out of
* fields first. A separator BETWEEN fields inside the span is
* consumed (walked over), so it stays INSIDE the key -- POSIX
* -t's "[a separator] can be included in a sort key".
*---------------------------------------------------------------
TFLDEND     jsr   TCONTENTE
            dec   SRT_KCNT
            beq   :out
            lda   (SRT_KAE)
            and   #$7F
            beq   :out
            inc   SRT_KAE
            bne   TFLDEND
            inc   SRT_KAE+1
            bra   TFLDEND
:out        rts

*---------------------------------------------------------------
* FOLDCH -- -f's fold: A's letter, if 'a'-'z' (either text
* convention -- bit 7 masked only for the RANGE test), returned
* with bit 5 cleared (lowercase - $20 = uppercase, and bit 5 is
* independent of bit 7, so this folds either convention without
* needing to know which one A is in). Non-letters pass through
* unchanged. Preserves X/Y.
*---------------------------------------------------------------
FOLDCH      pha
            and   #$7F
            cmp   #'a'
            bcc   :no
            cmp   #'z'+1
            bcs   :no
            pla
            and   #$DF
            rts
:no         pla
            rts

*---------------------------------------------------------------
* TXTKCMP -- byte compare of key A (SRT_KA..SRT_KAE) against
* key B (SRT_KB..SRT_KBE). A key that runs out first is the
* smaller (prefix rule, same as STRCMP's NUL rule). The bounds
* were cut at the NUL by KEYB, so no NUL test is needed here.
* OUT: A/flags per CMPKEY's contract.
*---------------------------------------------------------------
TXTKCMP     lda   SRT_KA                ;A exhausted?
            cmp   SRT_KAE
            bne   :haveA
            lda   SRT_KA+1
            cmp   SRT_KAE+1
            bne   :haveA
            ;-- A done; B too?
            lda   SRT_KB
            cmp   SRT_KBE
            bne   :alt                  ;A ended, B not: A<B
            lda   SRT_KB+1
            cmp   SRT_KBE+1
            bne   :alt
            lda   #0                    ;both ended: equal
            rts
:haveA      lda   SRT_KB                ;B exhausted alone: A>B
            cmp   SRT_KBE
            bne   :both
            lda   SRT_KB+1
            cmp   SRT_KBE+1
            bne   :both
            lda   #1
            rts
:both       lda   (SRT_KB)              ;fold B first so A ends
            ldx   WANT_F                ;up = folded A: `cmp`
            beq   :nofb                 ;wants A=A's byte,
            jsr   FOLDCH                ;operand=B's, same order
:nofb       sta   SRT_FA                ;the un-folded compare
            lda   (SRT_KA)              ;used below
            ldx   WANT_F
            beq   :nofa
            jsr   FOLDCH
:nofa       cmp   SRT_FA
            bcc   :alt
            bne   :agt
            inc   SRT_KA
            bne   :nca
            inc   SRT_KA+1
:nca        inc   SRT_KB
            bne   TXTKCMP
            inc   SRT_KB+1
            bra   TXTKCMP
:alt        lda   #$FF
            rts
:agt        lda   #1
            rts

*---------------------------------------------------------------
* PARSEKEY -- OPTARG holds one -k argument: "N[t][,M[t]]",
* decimal N >= 1, M >= N, t = any run of the key types b f n r
* (d and i are refused, not guessed at). Appends the key to
* KT_NUM/KT_END/KT_FLG slot NKEYS. Types on N and on M are
* MERGED into one flag set (measured: -k2r,2n == -k2,2nr),
* except b, which only counts on N. ANY type, b on M included,
* sets FK_MOD: the key then takes NO global flag (FINKEYS).
* OUT: carry clear + NKEYS+1; carry set = usage error (0,
* junk, M < N, a ninth key -- loud, never a guess).
*---------------------------------------------------------------
PARSEKEY    ldx   NKEYS
            cpx   #MAXKEYS
            bcs   :bad
            stz   KT_FLG,x
            stz   KT_END,x
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSEDEC
            bcs   :bad
            cmp   #0
            beq   :bad                  ;-k 0 means nothing
            ldx   NKEYS
            sta   KT_NUM,x
            lda   #FK_B                 ;b counts on field_start
            sta   SRT_FA
            jsr   PARSEMOD
            beq   :ok                   ;plain -k N[t]
            cmp   #$2C                  ;',' -- a quoted comma
            bne   :bad                  ;breaks merlin's parser
            inc   PTR0
            bne   :ncm
            inc   PTR0+1
:ncm        jsr   PARSEDEC
            bcs   :bad
            ldx   NKEYS
            cmp   KT_NUM,x              ;M >= N or it is not a
            bcc   :bad                  ;window
            sta   KT_END,x
            stz   SRT_FA                ;b on field_end: no bit
            jsr   PARSEMOD
            bne   :bad                  ;junk after M[t]
:ok         inc   NKEYS
            clc
            rts
:bad        sec
            rts

*-- PARSEMOD -- consume key-type letters at (PTR0), OR their
* bits
*-- (FK_N/R/F, FK_B only if SRT_FA says so) and FK_MOD into slot
*-- NKEYS's KT_FLG. OUT: A = the first non-type byte (7-bit),
*-- Z set if it is the NUL.
PARSEMOD    lda   (PTR0)
            and   #$7F
            ldy   #FK_N
            cmp   #'n'
            beq   :set
            ldy   #FK_R
            cmp   #'r'
            beq   :set
            ldy   #FK_F
            cmp   #'f'
            beq   :set
            ldy   SRT_FA
            cmp   #'b'
            bne   :done
:set        tya
            ora   #FK_MOD
            ldx   NKEYS
            ora   KT_FLG,x
            sta   KT_FLG,x
            inc   PTR0
            bne   PARSEMOD
            inc   PTR0+1
            bra   PARSEMOD
:done       cmp   #0                    ;Z = the NUL
            rts

*-- PARSEDEC -- decimal byte at (PTR0), advancing PTR0 past the
*-- digits. Carry set on no-digit or overflow (kill.s's
*-- PARSEPID shape: the x10 refuses to wrap).
PARSEDEC    stz   SRT_KCNT
            lda   (PTR0)
            jsr   ISDIGIT
            bcc   :bad
:loop       lda   (PTR0)
            jsr   ISDIGIT
            bcc   :ok
            and   #$7F
            sec
            sbc   #'0'
            pha
            lda   SRT_KCNT
            asl   a
            bcs   :badp
            asl   a
            bcs   :badp
            adc   SRT_KCNT
            bcs   :badp
            asl   a
            bcs   :badp
            sta   SRT_KCNT
            pla
            clc
            adc   SRT_KCNT
            bcs   :bad
            sta   SRT_KCNT
            inc   PTR0
            bne   :loop
            inc   PTR0+1
            bra   :loop
:badp       pla
:bad        sec
            rts
:ok         lda   SRT_KCNT
            clc
            rts
