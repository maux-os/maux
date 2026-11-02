*---------------------------------------------------------------
* shexp2.s -- sh's variable-emit half of expansion,
* split from shexpand.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2). One assembly
* stream: ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* EMITVAR -- IN: PTR0/Y at the first character of a `$NAME`
* identifier (already known to be a letter). Scans the whole
* identifier (letters/digits, capped VARNAMELEN, docs/SH-
* FEATURES.md sec 4), looks it up in the variable table, and
* appends its value to EXPBUF -- or nothing, if unset ($UNSET
* expands empty, Bourne). An identifier LONGER than VARNAMELEN
* can never match a stored name (VARSET refuses one that long)
* -- rather than truncate-and-maybe-false-match, the excess is
* still SCANNED (so Y ends up past the whole identifier, not a
* truncated prefix of it) but the lookup is skipped outright.
*
* PTR0/Y are DOEXPAND's own source-word cursor; both are saved
* before the lookup (which reuses PTR0/PTR1/PTR2 freely) and
* restored -- except Y, whose FINAL value (just past the
* identifier) is exactly the position DOEXPAND's :cpy loop
* should resume from, so it is deliberately left advanced.
* CLOBBERS: A, X, Y, PTR0 (restored), PTR1, PTR2.
*---------------------------------------------------------------
EMITVAR     stz   VNLEN
            stz   VNTOOLONG
:scan       lda   (PTR0),y
            jsr   ISIDENTCH
            bcc   :scandone
            lda   VNLEN
            cmp   #VARNAMELEN
            bcs   :toolong
            tax
            lda   (PTR0),y
            sta   VNBUF,x
            inc   VNLEN
            bra   :adv
:toolong    lda   #1
            sta   VNTOOLONG
:adv        iny
            bra   :scan
:scandone   ldx   VNLEN
            lda   #0
            sta   VNBUF,x
*-- Y (DOEXPAND's own resume cursor -- one past the whole
*-- identifier) MUST be saved here and restored below, same as
*-- PTR0: STRCMP CLOBBERS Y (its own header, string.s), and
*-- EMITSTRP starts its OWN copy at `ldy #0` -- either one left
*-- unrestored, Y comes back near 0 and DOEXPAND's :cpy re-reads
*-- from near the START of the token, re-hitting the SAME '$'
*-- forever. Found the hard way: `$UNSET` (VARFIND misses every
*-- slot, each STRCMP resets Y=0) hung outright; a HIT like
*-- `$FOO` only leaked one stray trailing byte into EXPBUF
*-- instead of looping -- silently wrong, not even loud.
            sty   VNRESUMEY
            lda   PTR0
            sta   DXSAVE
            lda   PTR0+1
            sta   DXSAVE+1
            lda   VNTOOLONG
            bne   :restore
            lda   #<VNBUF
            sta   PTR0
            lda   #>VNBUF
            sta   PTR0+1
            jsr   VARFIND
            bcs   :restore
            jsr   VSLOT_VAL
            lda   PTR1
            sta   PTR2
            lda   PTR1+1
            sta   PTR2+1
            jsr   EMITSTRP
:restore    lda   DXSAVE
            sta   PTR0
            lda   DXSAVE+1
            sta   PTR0+1
            ldy   VNRESUMEY
            rts


*---------------------------------------------------------------
* EMITBRACE -- `${NAME}` and V7's four conditional forms, added
* 2026-08-27 after the parity ledger was rebuilt against the
* manual (docs/SH-FEATURES.md sec 2.0). All four are V7, which
* recollection had put later:
*
*   ${NAME}      the value, or nothing
*   ${NAME-word} value if SET, else `word`
*   ${NAME+word} `word` if SET, else nothing
*   ${NAME=word} value if SET, else SET it to `word` and use it
*   ${NAME?word} value if SET, else print `word` and ABANDON
*
* `word` is evaluated lazily in V7 -- *"word is not evaluated
* unless it is to be used as the substituted string"* -- which
* falls out here for free: the unused branch SKIPS the word
* rather than emitting it, and nothing in a skipped span is
* expanded or run.
*
* `${1}` works too: V7 allows a digit as the parameter, and the
* braces are how you write `${1}0` without meaning `$10`, which
* is the main reason the form exists at all.
*
* IN: PTR0 = the word, Y at the `{`. OUT: Y one past the `}`.
* CLOBBERS: A, X, Y, PTR1, PTR2 (PTR0 preserved, like EMITVAR).
*---------------------------------------------------------------
EMITBRACE   iny                          ;past the '{'
            stz   VNLEN
:bscan      lda   (PTR0),y
            bne   :bhavech               ;`bne` past a `jmp` --
            jmp   :bunterm         ;range: the file's idiom
:bhavech    jsr   ISIDENTCH
            bcc   :bnamend
            ldx   VNLEN
            cpx   #VARNAMELEN
            bcs   :bnext                 ;over-long: keep
            sta   VNBUF,x                ;  scanning, VARFIND
            inc   VNLEN                  ;  will simply miss
:bnext      iny
            bra   :bscan
:bnamend    sta   BROP                   ;'}' or the operator
            ldx   VNLEN
            lda   #0
            sta   VNBUF,x
            iny                          ;past it
            sty   BRESUME
            lda   PTR0
            sta   BRSAVE
            lda   PTR0+1
            sta   BRSAVE+1
*-- A LONE DIGIT IS A POSITIONAL PARAMETER, not a variable name
*-- -- `${1}` is V7's way to write `$1` next to a digit. Only
*-- for the PLAIN form; `${1-x}` is not something V7 promises
*-- and positional parameters cannot be assigned to anyway.
            lda   VNLEN
            cmp   #1
            bne   :blookup
            lda   BROP
            cmp   #$FD                   ;'}'
            bne   :blookup
            lda   VNBUF
            cmp   #$B0                   ;'0'
            bcc   :blookup
            cmp   #$BA                   ;past '9'
            bcs   :blookup
            jsr   EMITARG
            jmp   :bdone                 ;`jmp` -- range
:blookup    lda   #<VNBUF
            sta   PTR0
            lda   #>VNBUF
            sta   PTR0+1
            jsr   VARFIND                ;carry clear = SET
*-- `ror` on memory shifts bit 0 OUT INTO CARRY, so the carry
*-- after this line is the PREVIOUS BRFOUND's low bit, NOT
*-- VARFIND's answer. Branching on it read stale state: a
*-- variable that WAS set took the unset path, so `${Q=no}` with
*-- Q already `made` substituted nothing. Test the byte we just
*-- built, never the carry a read-modify-write left behind.
            ror   BRFOUND                ;bit 7 = NOT found
*-- PTR2 defaults to EMPTYSTR so `%`/`%%`/`#`/`##` below always
*-- have a real NUL-terminated value to strip from, unset same
*-- as "" -- overwritten by VSLOT_VAL just below when SET. Every
*-- OTHER operator still branches on BRFOUND itself, never PTR2,
*-- so this default is inert for them.
            lda   #<EMPTYSTR
            sta   PTR2
            lda   #>EMPTYSTR
            sta   PTR2+1
            bit   BRFOUND
            bmi   :bunset
            jsr   VSLOT_VAL              ;PTR1 = the value
            lda   PTR1
            sta   PTR2
            lda   PTR1+1
            sta   PTR2+1
:bunset     lda   BRSAVE                 ;PTR0 back to the word
            sta   PTR0
            lda   BRSAVE+1
            sta   PTR0+1
            ldy   BRESUME
            lda   BROP
            cmp   #$FD                   ;'}' -- plain
            beq   :bplain
            cmp   #$AB                   ;'+'
            beq   :bplus
            cmp   #$AD                   ;'-'
            beq   :bdash
            cmp   #$BD                   ;'='
            beq   :bassign
            cmp   #$BF                   ;'?'
            bne   :noquery
            jmp   :bquery                ;`jmp` -- range
:noquery    cmp   #$A5                   ;'%' -- suffix strip
            bne   :nopct
            jmp   :bpct                  ;`jmp` -- range
:nopct      cmp   #$A3                   ;'#' -- prefix strip
            bne   :nohash
            jmp   :bhash                 ;`jmp` -- range
:nohash
*-- EVERY PATH RELOADS Y FROM BRESUME AFTER EMITSTRP, because
*-- EMITSTRP starts its own copy at `ldy #0` and returns Y
*-- indexing the VALUE, not this word -- the same clobber
*-- EMITVAR's header documents for STRCMP. Missing one put a
*-- stray `}` in the output (`${V}X` -> `set}X`) -- a wrong
*-- answer, not a crash. BRESUME means "index just past
*-- the name's terminator" until BRWORD runs, after which BRWORD
*-- has rewritten it to the index OF the closing '}'.
:bplain     bit   BRFOUND
            bmi   :bpdone                ;unset -- nothing
            jsr   EMITSTRP
:bpdone     ldy   BRESUME                ;already past the '}'
            rts
:bplus      bit   BRFOUND                ;word iff SET
            bmi   :bskipw
            bra   :bemitw
:bdash      bit   BRFOUND                ;word iff UNSET
            bpl   :bvalskip
:bemitw     lda   #BRW_EMIT
            jsr   BRWORD
            jmp   :bdone  ;`jmp` -- range
:bvalskip   jsr   EMITSTRP               ;set: value, skip word
            ldy   BRESUME
:bskipw     lda   #BRW_SKIP
            jsr   BRWORD
:bdone      ldy   BRESUME                ;BRWORD left the '}'
            iny                          ;index here
            rts
*-- `=` -- assign the default, then use it. The word is copied
*-- to a buffer because VARSET wants a NUL-terminated string,
*-- not a span. A table-full VARSET fails LOUDLY through its own
*-- carry, and this reports it the same way a bare assignment
*-- does rather than silently substituting nothing.
:bassign    bit   BRFOUND
            bpl   :bvalskip              ;already set
            lda   #BRW_COPY
            jsr   BRWORD
            lda   #<VNBUF
            sta   PTR0
            lda   #>VNBUF
            sta   PTR0+1
            lda   #<BRWBUF
            sta   PTR2
            lda   #>BRWBUF
            sta   PTR2+1
            phy
            jsr   VARSET
            ply
*-- VARSET CLOBBERS PTR0 -- it copies PTR2 over it to reach the
*-- value -- and its header's "CLOBBERS: A, X, Y, PTR1" does not
*-- say so. Restoring it here is not defensive: without it
*-- DOEXPAND's :cpy resumes reading from the VALUE buffer
*-- instead of the word, hits that buffer's NUL, and silently
*-- truncates the rest of the word (`[${Q=made}]` printed
*-- `[made` -- the `]` never arrived).
            lda   BRSAVE
            sta   PTR0
            lda   BRSAVE+1
            sta   PTR0+1
            bcs   :bfull
            lda   #<BRWBUF
            sta   PTR2
            lda   #>BRWBUF
            sta   PTR2+1
            jsr   EMITSTRP
            jmp   :bdone                 ; :bdone reloads Y
:bfull      jsr   SEL_VARFULL
            sta   PTR0
            stx   PTR0+1
            bra   :bsay
*-- `?` -- V7: *"print word and exit from the shell"*. maux
*-- abandons the LINE instead of exiting, which is what every
*-- other refusal in this shell does and what an interactive
*-- user wants; a script still stops, because the line carrying
*-- the reference never runs.
:bquery     bit   BRFOUND
            bpl   :bvalskip
            lda   #BRW_SKIP
            jsr   BRWORD
            lda   #<BRQ_MSG
            sta   PTR0
            lda   #>BRQ_MSG
            sta   PTR0+1
:bsay       jsr   PR_ERR
            lda   #1
            sta   LASTSTATUS
            jmp   MAINLOOP
:bunterm    lda   #<BRUNT_MSG
            sta   PTR0
            lda   #>BRUNT_MSG
            sta   PTR0+1
            bra   :bsay

*---------------------------------------------------------------
* `${V%pat}`/`${V%%pat}`/`${V#pat}`/`${V##pat}` (POSIX 2.6.2,
* docs/SH-FEATURES.md 2026-09-15): remove the shortest/longest
* matching suffix/prefix pattern. PTR2 already holds the value
* (or EMPTYSTR, see the pre-set above) and Y=BRESUME sits just
* past the operator's first character. A DOUBLED second
* character (`%%`/`##`) selects longest instead of shortest --
* the only lookahead this form needs. The pattern word is
* copied VERBATIM (BRW_COPY, no `$` expansion), the same
* simplification `${V=word}` already uses. CLOBBERS: A, X, Y,
* PTR0, PTR1, PTR2.
*---------------------------------------------------------------
:bpct       lda   (PTR0),y
            cmp   #$A5                   ;doubled '%%'
            bne   :bpct1
            iny
            lda   #1                     ;longest
            bra   :bpctgo
:bpct1      lda   #0                     ;shortest
:bpctgo     sta   VPMODE
            lda   #BRW_COPY
            jsr   BRWORD
            lda   #<BRWBUF
            sta   PTR1
            lda   #>BRWBUF
            sta   PTR1+1
            jsr   VPAT_STRIP
            lda   BRSAVE
            sta   PTR0
            lda   BRSAVE+1
            sta   PTR0+1
            jmp   :bdone  ;`jmp` -- range
:bhash      lda   (PTR0),y
            cmp   #$A3                   ;doubled '##'
            bne   :bhash1
            iny
            lda   #3                     ;longest prefix
            bra   :bhashgo
:bhash1     lda   #2                     ;shortest prefix
:bhashgo    sta   VPMODE
            lda   #BRW_COPY
            jsr   BRWORD
            lda   #<BRWBUF
            sta   PTR1
            lda   #>BRWBUF
            sta   PTR1+1
            jsr   VPAT_STRIP
            lda   BRSAVE
            sta   PTR0
            lda   BRSAVE+1
            sta   PTR0+1
            jmp   :bdone  ;`jmp` -- range

*---------------------------------------------------------------
* VPAT_STRIP -- IN: PTR2 = value (NUL-terminated), PTR1 =
* pattern (NUL-terminated, BRWBUF), VPMODE = 0 (%, suffix
* shortest) / 1 (%%, suffix longest) / 2 (#, prefix shortest) /
* 3 (##, prefix longest). Copies the value into VPVBUF (a
* scratch copy -- prefix candidates are tested by TEMPORARILY
* truncating it, which must never touch the live variable
* table), then walks candidate cut points with GLOBMATCH
* (liba/glob.s -- WHOLE-string match, reused verbatim rather
* than a second matcher) until one matches or all are
* exhausted, and emits the result via EMITSTRP. No match at all
* means the value is unchanged (POSIX). CLOBBERS: A, X, Y,
* PTR0, PTR1, PTR2.
*---------------------------------------------------------------
VPAT_STRIP  ldy   #0
:vcp        lda   (PTR2),y
            beq   :vcpd
            sta   VPVBUF,y
            iny
            cpy   #VARVALLEN
            bcc   :vcp
:vcpd       sty   VPLEN
*-- TYA then TAX, NOT a bare TAX -- there is no direct Y->X
*-- transfer on 6502, and TAX alone copies A (still holding the
*-- COPY LOOP's last LOAD -- the NUL that ended it) into X,
*-- landing the terminator at VPVBUF[0] instead of VPVBUF[VPLEN]
*-- and zeroing the real first character. Found live: VP_
*-- SUFTEST's own X=0 candidate then read a corrupted VPVBUF.
            tya
            tax
            lda   #0
            sta   VPVBUF,x
            lda   PTR1
            sta   VPPATP
            lda   PTR1+1
            sta   VPPATP+1
            lda   VPMODE
            cmp   #2
            bcs   :dopfx
*-- suffix modes: 0 = % (shortest -- try largest i first),
*-- 1 = %% (longest -- try smallest i first).
            cmp   #1
            beq   :suflong
:sufshort   ldx   VPLEN
:ssloop     jsr   VP_SUFTEST
            bcc   :cutsuf
            cpx   #0
            beq   :nohit
            dex
            bra   :ssloop
:suflong    ldx   #0
:slloop     jsr   VP_SUFTEST
            bcc   :cutsuf
            cpx   VPLEN
            beq   :nohit
            inx
            bra   :slloop
:cutsuf     lda   #0                     ;X = cutpos: emit
            sta   VPVBUF,x               ;  VPVBUF[0:X)
            bra   :emitv
*-- prefix modes: 2 = # (shortest -- try smallest i first),
*-- 3 = ## (longest -- try largest i first).
:dopfx      cmp   #2
            beq   :pfxshort
:pfxlong    ldx   VPLEN
:plloop     jsr   VP_PFXTEST
            bcc   :cutpfx
            cpx   #0
            beq   :nohit
            dex
            bra   :plloop
:pfxshort   ldx   #0
:psloop     jsr   VP_PFXTEST
            bcc   :cutpfx
            cpx   VPLEN
            beq   :nohit
            inx
            bra   :psloop
:cutpfx     txa                          ;X = cutpos: emit
            clc                          ;  VPVBUF[X:end)
            adc   #<VPVBUF
            sta   PTR2
            lda   #0
            adc   #>VPVBUF
            sta   PTR2+1
            jmp   EMITSTRP
:nohit      ldx   #0                     ;unchanged -- emit the
:emitv      lda   #<VPVBUF               ;  whole scratch copy
            sta   PTR2
            lda   #>VPVBUF
            sta   PTR2+1
            jmp   EMITSTRP

*---------------------------------------------------------------
* VP_SUFTEST -- IN: X = candidate suffix start i. OUT: carry per
* GLOBMATCH (clear = match) against VPVBUF+i. PRESERVES X.
* CLOBBERS: A, PTR0, PTR1.
*---------------------------------------------------------------
VP_SUFTEST  stx   VPI
            txa
            clc
            adc   #<VPVBUF
            sta   PTR1
            lda   #0
            adc   #>VPVBUF
            sta   PTR1+1
            lda   VPPATP
            sta   PTR0
            lda   VPPATP+1
            sta   PTR0+1
            jsr   GLOBMATCH
            php
            ldx   VPI
            plp
            rts

*---------------------------------------------------------------
* VP_PFXTEST -- IN: X = candidate prefix length i. OUT: carry
* per GLOBMATCH against VPVBUF[0:i), TEMPORARILY truncated at i
* and restored before return (a SCRATCH copy, never the live
* variable table). PRESERVES X. CLOBBERS: A, PTR0, PTR1.
*---------------------------------------------------------------
VP_PFXTEST  stx   VPI
            lda   VPVBUF,x
            sta   VPSAVE
            lda   #0
            sta   VPVBUF,x
            lda   #<VPVBUF
            sta   PTR1
            lda   #>VPVBUF
            sta   PTR1+1
            lda   VPPATP
            sta   PTR0
            lda   VPPATP+1
            sta   PTR0+1
            jsr   GLOBMATCH
            php
            ldx   VPI
            lda   VPSAVE
            sta   VPVBUF,x
            plp
            rts

*---------------------------------------------------------------
* BRWORD -- walk `word` from Y to its closing `}`. IN: A = mode
* (BRW_SKIP / BRW_EMIT / BRW_COPY). OUT: Y AT the `}` (or at the
* NUL if the form was unterminated -- EMITBRACE's `iny` then
* steps onto the NUL, and :cpy stops there rather than running
* off the token). CLOBBERS: A, X.
*---------------------------------------------------------------
BRWORD      sta   BRMODE
            stz   BRWLEN
:bw         lda   (PTR0),y
            beq   :bwend
            cmp   #$FD                   ;'}'
            beq   :bwend
            ldx   BRMODE
            cpx   #BRW_EMIT
            beq   :bwemit
            cpx   #BRW_COPY
            bne   :bwnext
            ldx   BRWLEN                 ;copy, bounded by the
            cpx   #VARVALLEN             ;  value length VARSET
            bcs   :bwnext                ;  will accept
            sta   BRWBUF,x
            inc   BRWLEN
            bra   :bwnext
:bwemit     jsr   EMITB
:bwnext     iny
            bra   :bw
:bwend      ldx   BRWLEN
            lda   #0
            sta   BRWBUF,x
            sty   BRESUME                ;the '}' index, for the
            rts                          ;callers' shared exit

*---------------------------------------------------------------
* ISIDENTCH -- IN: A = a byte. OUT: carry SET if it is a
* high-bit-ASCII letter 'A'-'Z' or digit '0'-'9' (a `$NAME`
* identifier character past the first), carry CLEAR otherwise.
* CLOBBERS: nothing but the flags.
*---------------------------------------------------------------
*-- lowercase joined the identifier alphabet 2026-08-30: the
*-- whole name pipeline (this scanner, the four first-char
*-- gates via ISNAME1 below) admitted only A-Z, so `for x in
*-- ...` -- the form a human types -- died with a syntax error
*-- the moment the operator tried it at the console, while
*-- every gate spelled its variables uppercase. Names are
*-- CASE-SENSITIVE (the table lookup is STRCMP; only builtin
*-- and reserved WORDS fold) -- Bourne semantics, not folding.
ISIDENTCH   cmp   #$B0
            bcc   ISNAME1
            cmp   #$BA
            bcc   :yes
            bra   ISNAME1
:yes        sec
            rts

*-- ISNAME1 -- IN: A = a byte. OUT: carry SET iff a LETTER
*-- (either case): the first-character rule for a variable
*-- name, shared by the assignment detector (shtok), VARSET's
*-- validator (shvar), `read` (shvar2) and RW_FOR (shvar2).
ISNAME1     cmp   #$C1                   ;'A'
            bcc   :low
            cmp   #$DB                   ;past 'Z'
            bcc   :ok
:low        cmp   #$E1                   ;'a'
            bcc   :no
            cmp   #$FB                   ;past 'z'
            bcs   :no
:ok         sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* COMMAND SUBSTITUTION -- `$(COMMAND)` (docs/ANACHRONISMS.md A10
* rules the SPELLING: `$( )`, not V7's backticks; docs/SH-
* FEATURES.md sec 14 has the feature notes). Run COMMAND,
* capture its stdout, strip EVERY trailing CR, and splice the
* result into the word in place -- after which the word is
* subject to whatever the surrounding context does to it
* (globbing for a bare word, none for a quoted one, VARSET for a
* `NAME=$(...)` assignment).
*
* WHERE THE CAPTURE HAPPENS, and why here: this is a WORD-level
* pass (WORDEXPAND's second scan), not a pipeline-level one. It
* therefore inherits, for free and without a second
* implementation, every rule the `$`-expansion pass already
* obeys -- `'...'` suppresses it (WORDEXPAND returns before
* reaching here), `"..."` does not, an unquoted `<<WORD`
* here-doc body gets it (CPTR_HEREDOC calls WORDEXPAND per line)
* and a `<<'WORD'` body does not (that path never calls
* WORDEXPAND at all). Not one of those four behaviours is coded
* below; they are all consequences of the hook's placement.
*
* RE-ENTRANCY -- the whole design question, answered by
* AVOIDANCE rather than by saving state:
*
*  - NOT the parser. SUB_RUN never calls TOKENIZE, PARSE,
*    CLASSIFY, RUN_PIPELINE or any builtin. It splits the
*    captured text on spaces itself (SUB_RUN's own :skip loop)
*    into SUBARGV, and spawns exactly ONE process. So LINEBUF
*    (which TOKENIZE squeezes IN PLACE), TOKPTR/TOKQUOTE/TOKI/
*    NTOK, CMD_ARGV/CMD_ARGC/CMD_INFILE/CMD_OUTFILE/NCMD, and
*    the construct stack are all structurally untouchable from
*    here -- not "carefully restored", never written.
*  - NOT DOEXPAND. EXPX/EXPSTART/EXPCUR are single global
*    cursors with no stack, so a nested DOEXPAND would corrupt
*    the outer one's in-progress slice. Hence the ordering in
*    WORDEXPAND: the `$` pass runs FIRST, to completion, and
*    this pass reads its finished output.
*  - EXPBUF is shared, and that is deliberate and safe: the `$`
*    pass's slice ends at EXPCUR and this pass allocates the
*    NEXT slice from EXPCUR, so source and destination never
*    overlap -- given EXP_FINISH's fix (see its header; before
*    it, they overlapped by exactly one byte, which is how that
*    pre-existing bug was found). The capture is appended
*    through the SAME EMITB every other expansion uses, so its
*    EXPBUFLEN-1 clamp bounds a long capture the same way it
*    bounds a long `$VAR` -- truncation, never a write past the
*    pool. A truncated capture still DRAINS the pipe to EOF
*    (SUB_RUN's :rd loop keeps reading after EMITB stops
*    storing), because a child left blocked on a full pipe would
*    never exit and SC_WAIT would never return.
*  - BUILD_PATH/FDABUF/SH_PATHFULL are idle. This runs during
*    PARSE (or CPTR_HEREDOC, or before CHCK_BLTN_VAR), before
*    RUN_PIPELINE has spawned anything for THIS line.
*  - BUT NOT "nothing outstanding to trip over", which is what
*    this entry claimed until 2026-09-16 and what SUB_WAITST's
*    pid-less SC_WAIT was built on: "before RUN_PIPELINE has
*    spawned anything" is about this LINE, and an earlier line's
*    `&` job is still a child of this shell and can zombie at
*    any moment. It did, measurably (check-shlang: the
*    background job's status became the substitution's `$?` and
*    the job's own `wait` then reported 0). SUB_WAITST reaps by
*    pid now and re-files every other child's report into the
*    job table -- see its header.
*
* v1 REFUSES, LOUDLY, rather than half-supporting: a nested
* `$( $( ) )`, and a `$(` with no closing `)`. Both are one
* diagnostic and a nonzero `$?` (SUB_ERR) -- see SUB_GRAB.
*
* IN: PTR0 = the word. OUT: PTR0 unchanged if it holds no `$(`,
* else repointed at a fresh EXPBUF slice. CLOBBERS: A, X, Y,
* PTR0, PTR1, PTR2.
*---------------------------------------------------------------
CMDSUBST    ldy   #0
:find       lda   (PTR0),y
            beq   :nosub
            cmp   #$A4                   ;'$' high-bit-set
            bne   :fadv
            iny
            lda   (PTR0),y
            cmp   #$A8                   ;'(' high-bit-set
            beq   :dosub
            bra   :find                  ;re-examine the peeked
                                         ;byte -- it may be a
                                         ;'$' itself
:fadv       iny
            bra   :find
:nosub      rts

*-- A `$(` is present: rebuild the whole word into a fresh
*-- EXPBUF slice, copying plain bytes and replacing each
*-- `$( ... )` with its capture. Same bump-allocate/emit/finish
*-- shape DOEXPAND uses, deliberately -- one buffer discipline
*-- in this file, not two.
:dosub      lda   #1                     ;a `$( )` capture is a
            sta   EXPSUBST               ;substitution result --
                                         ;IFS splits it (SPLIT_
                                         ;APPEND), Bourne rule
*-- Same pre-resolve as WORDEXPAND :yes, for the word that had
*-- no `$NAME` form and reached here directly -- EMITB_CS marks
*-- its literal separators low. When DOEXPAND already ran,
*-- DOEXPRAN makes EMITB_CS copy verbatim instead, because a
*-- high separator in THIS pass's source is a first-pass
*-- substitution result that must stay splittable.
            lda   PTR0
            sta   SPLWORD
            lda   PTR0+1
            sta   SPLWORD+1
            jsr   IFS_RESOLVE
            lda   SPLWORD
            sta   PTR0
            lda   SPLWORD+1
            sta   PTR0+1
            lda   EXPCUR
            sta   EXPSTART
            sta   EXPX
            ldy   #0
:cp         lda   (PTR0),y
            beq   :term
            cmp   #$A4
            bne   :plain
            iny
            lda   (PTR0),y
            cmp   #$A8
            beq   :sub
            lda   #$A4                   ;a '$' that does not
            jsr   EMITB                  ;  open a substitution
            bra   :cp                    ;  -- emit it, re-
                                         ;  examine the peek
:plain      jsr   EMITB_CS               ;literal to THIS pass:
                                         ;mark separators low --
                                         ;unless DOEXPAND ran,
                                         ;whose output must be
                                         ;copied verbatim
            iny
            bra   :cp
*-- SUB_GRAB and SUB_RUN both need Y and PTR0 for themselves
*-- (SUB_RUN reaches BUILD_PATH, SC_SPAWN and GETC, all of which
*-- own PTR0/PTR1/PTR2 and Y outright), so this loop's own
*-- cursor pair is stashed across them -- the same save/restore
*-- discipline EMITARG/EMITVAR already use around their lookups.
:sub        iny                          ;step past the '('
            jsr   SUB_GRAB
            bcs   :bad
            sty   SUBRESY
            lda   PTR0
            sta   SUBSAVP
            lda   PTR0+1
            sta   SUBSAVP+1
            jsr   SUB_RUN
            lda   SUBSAVP
            sta   PTR0
            lda   SUBSAVP+1
            sta   PTR0+1
            ldy   SUBRESY
            bra   :cp
:bad        jmp   SUB_ERR
:term       jmp   EXP_FINISH

*---------------------------------------------------------------
* SUB_GRAB -- IN: PTR0/Y at the first byte INSIDE a `$(`. Copies
* the substitution's body to SUBTXT, NUL-terminated, and leaves
* Y one past the matching `)`.
*
* OUT: carry clear on success; carry SET if the body runs to the
* word's end with no `)`, or if it contains a `(` at all --
* v1 refuses NESTING rather than mis-parsing it. Refusing is not
* a shrug: an inner `$( )` would need its OWN capture buffer and
* argv array while this one is live, which is the same
* re-entrancy the whole design avoids. `$( )` was still the
* right SPELLING to choose (docs/ANACHRONISMS.md A10) -- it is
* the one that CAN nest later, whereas backticks never could.
*
* A body longer than SUBMAX-1 is truncated (v1, the same best-
* effort clamp EXPBUF and HD_BODY already use) but still scanned
* to its real `)`, so Y always resumes in the right place.
* CLOBBERS: A, Y.
*---------------------------------------------------------------
SUB_GRAB    stz   SUBTLEN
:g          lda   (PTR0),y
            beq   :bad                   ;ran off the word --
                                         ;no closing ')'
            cmp   #$A9                   ;')' high-bit-set
            beq   :close
            cmp   #$A8                   ;'(' -- nesting, v1
            beq   :bad                   ;  refuses it loudly
*-- Shell OPERATORS, refused for the same reason and in the same
*-- place. SUB_RUN deliberately never calls PARSE/CLASSIFY/
*-- RUN_PIPELINE (sec 14.2 -- re-entrancy by avoidance): it
*-- splits on spaces and spawns exactly ONE child. So a `|` here
*-- was reaching the child AS AN ARGUMENT -- `$(CAT F | WC -l)`
*-- handed `cat` a filename called `|` and the only complaint
*-- came from cat, not from sh. That is a quiet wrong answer
*-- wearing a diagnostic's clothes. Refuse it instead, exactly
*-- as nesting is refused, until $( ) can host a pipeline (the
*-- design candidate is a nested `sh` reading the text from a
*-- pipe as its script -- cheap only once STICKY.md sec 10's
*-- lazy free lands, which needs a data/text boundary in `ld`).
*-- THE OPERATOR REFUSAL IS GONE, 2026-08-26. `| < > ; &` were
*-- refused because the body was spawned as ONE command and an
*-- operator in it would have been passed as a literal argument
*-- -- a wrong answer wearing a diagnostic's clothes. The body
*-- is now handed to a nested `sh`, which is what the comment
*-- above proposed as the design candidate, so every one of
*-- those characters means what it says. :badop survives for
*-- NESTING, which is still refused.
            phy
            ldy   SUBTLEN
            cpy   #SUBMAX-1
            bcs   :nostore
            sta   SUBTXT,y
            inc   SUBTLEN
:nostore    ply
            iny
            bra   :g
:close      iny                          ;step past the ')'
            phy
            ldy   SUBTLEN
            lda   #0
            sta   SUBTXT,y
            ply
            clc
            rts
:bad        sec
            rts
