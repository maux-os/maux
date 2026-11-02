*---------------------------------------------------------------
* shtok.s -- sh's tokenizer half and classifier half, split from
* shlex.s at a GLOBAL boundary for the as source
* window (S9-PLAN sec 6, tier 2). One assembly stream:
* ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* TOKENIZE -- split LINEBUF (NUL-terminated) into whitespace-
* delimited tokens, NUL-terminated IN PLACE (each token's
* trailing space or the line's own NUL becomes that token's
* terminator). TOKPTR[i] = pointer to token i; TOKQUOTE[i] is
* its quote state (0 bare, 1 single-quoted/literal, 2 double-
* quoted); NTOK = token count. Whitespace = runs of $A0
* (space, high-bit-set) OUTSIDE any open quote span -- liba's
* own "split on runs of $A0" convention (docs/SH-DESIGN.md
* "Parsing (word split)"), extended by docs/SH-SUBSET.md sec
* 8.4's quoting ruling: a `'`/`"` opens a quoted SEGMENT (its
* content copied IN PLACE with the quote marks removed, so an
* embedded space no longer splits it -- `"FOO BAR"` is ONE
* token), and a bare segment owns backslash-escaping (`\X`
* strips the backslash and copies X literally). SEGMENTS
* CONCATENATE, POSIX-style (2026-09-15, docs/SH-FEATURES.md sec
* 23, :qsetup/:doquoted below): `'it''s'`, `"a"'b'c` and `x"y"`
* are each ONE token, quoted and bare/other-quoted segments
* glued with no delimiter between them. TOKQUOTE[i] ends up the
* token's WORST case across every segment it saw (0 if ANY
* segment was bare, else 2 if any was double-quoted, else 1) --
* not truly per-character, but per-byte bit-7 marking protects a
* SINGLE-quoted segment's own '$'/glob characters from
* WORDEXPAND/GLOB_APPEND's wider pass when a bare sibling forces
* the token open to both (:qloop1, below). A double-quoted
* segment's glob characters are NOT similarly protected -- '*'
* and '?' are both live expansion triggers right after a `$`
* (ISEXPCH, shexpand.s), so clearing them unconditionally would
* hide `$*`/`$?` the same way it measurably did once (:qloop2's
* own header) -- `"*"x` (glob-eligible only because of the bare
* `x`) is a known, untested gap, not a fix owed to this pass.
* An unterminated quote, or a
* MIXED form (a quote reached where the `<<`/`NAME=` quoting
* exception applies but at the wrong offset or a second time --
* :bqcheck's own header), is a syntax error: TOK_ERR is set (1
* unterminated, 2 mixed) and TOKENIZE returns immediately rather
* than silently extending or mis-handling the token -- the
* caller (MAINLOOP) checks TOK_ERR before ever calling PARSE.
*
* OPERATORS NEED NO BLANKS (`|` 2026-09-07, docs/SH-PIPE-NOSPACE
* .md; `<` `>` `;` `&` and their pairs KFIX 5, docs/KFIX-
* NOTES.md): a bare operator ends the word before it and is a
* token of its own, so `sort|uniq`, `echo hi>F`, `ls;pwd`,
* `sleep 5&` and `echo hi 2>&1` lex to the SAME tokens their
* spaced spellings do (see :bop's header for the lexeme and
* IO_NUMBER rules). A quoted operator (`'a|b'`, `"a>b"`, `\|`),
* one inside a `$( )`/ `( )` span, or one inside a `case`
* pattern (`A|B)`) stays content. The operator token is NOT in
* LINEBUF (OPBUF), which is why the `;`-lookbehind at :qbare
* dereferences TOKPTR through PTR0 instead of subtracting
* #<LINEBUF. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
*-- TOKI/EXPCUR are LINE-scoped (one TOKENIZE call per line),
*-- NOT per-pipeline-segment -- PARSE now runs once per
*-- `;`/`&&`/`||` segment and must resume where the last one
*-- left off, and EXPBUF's bump pool (WORDEXPAND, below) is
*-- shared across every segment of a line so two expanding
*-- words on the same line each get their own slice.
TOKENIZE    stz   NTOK
            stz   TOKI
            stz   EXPCUR
            stz   TOK_ERR
            stz   TOK_UNQ
            stz   OPPOS                  ;operator pool: empty
            stz   OPSKIP                 ;(:bop's pair latch)
            ldy   #0
:skip       lda   LINEBUF,y
            bne   :skipchk
            jmp   :done                  ;:done is far now --
                                         ;`jmp`, not `beq`
:skipchk    cmp   #$A0
            bne   :tokstart
            iny
            bra   :skip
:tokstart   lda   NTOK
            cmp   #MAXTOK
            bne   :tokok
            jmp   :toomany               ;too many tokens: an
                                         ;error, never a quiet
                                         ;truncation (KFIX2 5)
:tokok      tya
            ldx   NTOK                   ;SH-SEQ C: raw offset,
            sta   TOKOFF,x               ;  PRETOK's index
            stz   TOKCP,x                ;SH-CASE2 B: no `)` yet
            clc
            adc   #<LINEBUF
            sta   TOKTMP
            lda   #>LINEBUF
            adc   #0
            sta   TOKTMP+1
            ldx   NTOK
            txa
            asl   a
            tax
            lda   TOKTMP
            sta   TOKPTR,x
            lda   TOKTMP+1
            sta   TOKPTR+1,x
*-- Zeroed HERE, once per token, regardless of whether it starts
*-- bare or quoted (2026-09-15, concatenation): a quote-started
*-- token that later concatenates into bare content (:segbare)
*-- reaches :bqcheck's HDX_ELIG test too, and a quote-started
*-- token never used to run :qbare's own zeroing at all -- a
*-- stale HDX_ELIG from the PREVIOUS bare-started token would
*-- otherwise leak in. SUBDEPTH/SUBPRVD move here for the same
*-- reason (SUB_TRKCH, likewise reachable after :segbare).
            stz   SUBDEPTH
            stz   SUBPRVD
            stz   HDX_ELIG
            stz   HDX_USED
            stz   HDX_KIND
            stz   TOKGRP                  ;:qbgrp's own latch --
                                          ;sh.s's own header
            stz   CPOFF                   ;SH-CASE2 B: see :cpar
            lda   #1
            sta   TOKLVL                  ;this token's default
                                          ;TOKQUOTE (shpath.s's
                                          ;TOKLVL header)
*-- Classify by the FIRST character only -- the same "command
*-- position only" shape sec 6.1 already uses for reserved
*-- words. X becomes the WRITE cursor here (starts equal to the
*-- read cursor Y, the token's own start); every branch below
*-- only ever writes at or behind where it has already read, so
*-- the in-place squeeze can never overtake its own input.
            tya
            tax
*-- TOKWY = this token's own start offset, set HERE for BOTH
*-- entry paths (2026-09-15): :bpop's `cpx TOKWY` (a `|` reached
*-- while bare-scanning, testing whether it is the token's OWN
*-- first byte) is reachable from a token that STARTED quoted
*-- and concatenated into bare content (:segbare) just as
*-- easily as from one that started bare -- a stale TOKWY left
*-- over from the PREVIOUS token used to reach it that way.
*-- :qbare's own `stx TOKWY` below is now redundant (X still
*-- equals Y here) but stays, self-documenting at its own site.
            stx   TOKWY
            lda   LINEBUF,y
            cmp   #$A7                   ;''' high-bit-set
            beq   :qsetup
            cmp   #$A2                   ;'"' high-bit-set
            beq   :qsetup
            jmp   :qbare

*-- :qsetup -- IN: A = quote char just matched ($A7/$A2), Y =
*-- read cursor ON it. Sets QFLAGVAL/QCH for THIS segment and
*-- enters :doquoted -- the ONE reentrant quoted-segment
*-- scanner, called at token start (above) and at every
*-- concatenation point (:segend, :bqcheck) alike --
*-- CONCATENATION, 2026-09-15, docs/SH-FEATURES.md sec 23:
*-- `'it''s'`/`"a"'b'c`/`x"y"` all resolve to repeated calls
*-- here instead of the old blanket MIXED refusal.
:qsetup     cmp   #$A7
            beq   :qsetup1
            lda   #2
            sta   QFLAGVAL
            lda   #$A2
            sta   QCH
            jmp   :doquoted
:qsetup1    lda   #1
            sta   QFLAGVAL
            lda   #$A7
            sta   QCH
*-- fall through to :doquoted

*-- :doquoted -- IN: X = write cursor, Y = read cursor (ON the
*-- opening quote), QCH/QFLAGVAL set by :qsetup. TOKLVL is this
*-- token's EVENTUAL TOKQUOTE (shpath.s's own header), stored
*-- only at the token's real end (:segterm/:bterm/:bpop) -- a
*-- double-quoted segment upgrades it from the default 1 to 2
*-- UNLESS a bare segment already forced it to 0 (bare
*-- dominates: WORDEXPAND/GLOB_APPEND then run over the WHOLE
*-- token, and per-byte protection -- bit 7 cleared, :qloop1
*-- below -- is what keeps a SINGLE-quoted sibling segment's
*-- own '$'/glob characters from being caught by that wider
*-- pass; :qloop2's own header explains why a double-quoted
*-- one is NOT similarly protected). A single-quoted segment
*-- never changes TOKLVL: 1 is already its correct value.
:doquoted   lda   QFLAGVAL
            cmp   #2
            bne   :dqiny
            lda   TOKLVL
            beq   :dqiny
            lda   #2
            sta   TOKLVL
:dqiny      iny                          ;step past the opening
                                         ;quote -- never copied
            lda   QFLAGVAL
            cmp   #1
            beq   :qloop1
            jmp   :qloop2                ;double -- range

*-- :qloop1 -- single-quoted content: EVERY byte literal (POSIX
*-- 2.2.2), stored with bit 7 CLEARED (:bescput's own CTLESC
*-- convention) so a concatenated sibling segment's '$'/glob
*-- characters stay inert even when this token's FINAL TOKQUOTE
*-- ends up 0 or 2 because of that sibling.
:qloop1     lda   LINEBUF,y
            bne   :qchk1
            jmp   :unterm
:qchk1      cmp   QCH
            beq   :qclose
            and   #$7F
            sta   LINEBUF,x
            inx
            iny
            bra   :qloop1

*-- :qloop2 -- double-quoted content: POSIX 2.2.3's backslash
*-- table -- '\' loses its own special meaning ONLY before '$',
*-- '`', '"' or '\', in which case BOTH lose theirs (stored with
*-- bit 7 cleared, same convention as :qloop1); before any OTHER
*-- byte both the '\' and that byte stay literal, untouched.
*-- Glob metacharacters are NOT touched here (unlike ASGMARK's
*-- quoted-ASSIGNMENT rule): GLOB_APPEND already skips globbing
*-- for any token whose final TOKQUOTE is nonzero, and clearing
*-- a bare '?' would ALSO hide it from WORDEXPAND's own "$?"
*-- lookup -- measured regression, `ECHO "$?"` silently stopped
*-- expanding (check-shlang). ASGMARK gets away with it only
*-- because an assignment's value is never `$?`-expanded itself.
:qloop2     lda   LINEBUF,y
            bne   :qchk2
            jmp   :unterm
:qchk2      cmp   QCH
            beq   :qclose
            cmp   #$DC                   ;'\' high-bit-set
            beq   :qesc2
            sta   LINEBUF,x
            inx
            iny
            bra   :qloop2
:qesc2      iny                          ;step past the '\'
            lda   LINEBUF,y
            beq   :qeoln2
            cmp   #$A4                   ;'$'
            beq   :qeslit
            cmp   #$E0                   ;'`'
            beq   :qeslit
            cmp   #$A2                   ;'"'
            beq   :qeslit
            cmp   #$DC                   ;'\'
            beq   :qeslit
*-- any other byte: keep BOTH the '\' and the byte, literally --
*-- '\' is stored now; Y is ALREADY on the byte (this load was a
*-- peek only, no `iny` since) so :qloop2's own next pass reads
*-- and stores IT, ordinarily, right after -- a `dey` here would
*-- put Y back ON THE BACKSLASH, an infinite loop (found live,
*-- check-e2e: the harness never finished).
            lda   #$DC
            sta   LINEBUF,x
            inx
            bra   :qloop2
:qeslit     and   #$7F                   ;remove special meaning
            sta   LINEBUF,x
            inx
            iny
            bra   :qloop2
:qeoln2     lda   #$DC                   ;trailing '\' at EOL --
                                         ;keep it (:besc's own
                                         ;precedent); Y stays ON
                                         ;the NUL, so :qloop2's
                                         ;next pass hits :unterm
            sta   LINEBUF,x
            inx
            bra   :qloop2

*-- :qclose -- either loop's matching closing quote. What comes
*-- next decides whether the token ENDS here or CONCATENATES: a
*-- delimiter ends it (:segterm); another quote continues it as
*-- a NEW segment (:qsetup, right back into :doquoted); anything
*-- else resumes BARE scanning (:segbare) -- concatenation, not
*-- the old MIXED refusal (docs/SH-SUBSET.md sec 8.4 update).
:qclose     iny                          ;step past the closing
                                         ;quote -- never copied
:segend     lda   LINEBUF,y
            beq   :segterm
            cmp   #$A0
            beq   :segterm
*-- `'a'|cat`, `'a'>F`: an operator right after a closing quote
*-- delimits the token exactly as a blank does, left UNDER Y for
*-- :bop (through :skip and a fresh token start).
            jsr   ISOPCH                 ;`|` `<` `>` `;` `&`
            bcs   :segterm
            cmp   #$A7
            beq   :segq
            cmp   #$A2
            bne   :segbr
:segq       jmp   :qsetup                ;range: :qsetup is far
:segbr      jmp   :segbare
*-- :tokfinal -- OUT: A = the byte to store into TOKQUOTE for
*-- the token now ending. TOKGRP (sh.s's own header) wins if
*-- set -- a `(` GROUP token is always literal, whatever bare/
*-- quote lexing it also picked up along the way (:qbgrp's own
*-- header) -- else TOKLVL, the ordinary concatenated-segment
*-- result. CLOBBERS: nothing but A and the flags.
:tokfinal    ldx   NTOK                ;SH-CASE2 B: this token's
            lda   CPOFF                  ;  lexical `)` record
            sta   TOKCP,x
            lda   TOKGRP
            beq   :tfnogrp
            lda   #1
            rts
:tfnogrp    lda   TOKLVL
            rts

*-- :segterm -- the token's REAL end (any quote-close path).
*-- TOKWY is free here (this token is finishing) -- borrowed to
*-- stash the write cursor across the NTOK-indexed TOKQUOTE
*-- store, the same X-vs-NTOK-index idiom HDX_SAVEX already
*-- uses at :bqc3, below, for the identical conflict.
:segterm    stx   TOKWY
            jsr   :tokfinal
            ldx   NTOK
            sta   TOKQUOTE,x
            ldx   TOKWY
            lda   #0
            sta   LINEBUF,x
            inc   NTOK
            jmp   :skip
*-- :segbare -- resume ordinary bare scanning after a quoted
*-- segment (concatenation's other half): a bare segment ALWAYS
*-- dominates a token's final TOKQUOTE (:doquoted's own header,
*-- above) -- also reached directly from a token's own bare
*-- start (:qbnohd, below).
:segbare    stz   TOKLVL
            jmp   :bloop

*-- :qbare -- an ordinary token. `\X` strips the backslash and
*-- copies X with BIT 7 CLEAR, which marks that ONE BYTE literal
*-- without touching the token's quote level (sec 3b; see
*-- :bescput's own header for why the old per-token promotion
*-- was wrong in both directions); a bare
*-- `'`/`"` reached here MID-token (the first character already
*-- failed both quote checks above) is a MIXED form.
*--
*-- ONE exception, added for `<<WORD`'s own glued terminator
*-- (docs/SH-FEATURES.md sec 6/12): Bourne lets that WORD be
*-- quoted too (`<<'WORD'`/`<<"WORD"`, the literal-body form
*-- -- CLASSIFY's own header, below), but it still has to
*-- reach CLASSIFY as ONE bare token starting "<<"/"<<-" --
*-- squeezing it into a real :doquoted span would hide the
*-- "<<" prefix CLASSIFY needs. So: if THIS token's first
*-- bytes are "<<" (optionally "<<-") and the very next byte
*-- is a quote character, that ONE quote pair is squeezed out
*-- in place (same as :doquoted -- ONLY if the byte right
*-- after the closing quote is end-of-token or a space;
*-- otherwise still MIXED, no relaxation), and HDWORDQ[NTOK]
*-- records that this token's word WAS quoted -- the squeezed
*-- text alone can no longer tell `<<EOF` from `<<'EOF'`
*-- apart, so CLASSIFY (TOKI-indexed, since it runs later, per
*-- PARSE token) reads this array to know which. Any OTHER
*-- quote reached mid-token -- wrong position, or a second one
*-- -- is still MIXED, the ordinary rule, unchanged.
*-- A SECOND exception, for `$(...)` command substitution (docs/
*-- ANACHRONISMS.md A10): inside a `$(` ... `)` span a SPACE is
*-- ordinary content, not a token delimiter, so `$(LS
*-- /mnt/MAUX)`
*-- reaches CLASSIFY/WORDEXPAND as ONE word. SUBDEPTH tracks the
*-- span (SUB_TRKCH, below, called from :bok on every copied
*-- byte); SUBPRVD is "the byte just copied was a `$`", since a
*-- bare `(` opens nothing -- `ECHO (X` still splits normally.
*-- A double-QUOTED token needs none of this: :doquoted already
*-- keeps spaces, which is why `"$(LS /mnt/MAUX)"` worked before
*-- this line ever ran.
:qbare      stx   TOKWY
            ldx   NTOK
            stz   TOKQUOTE,x
            stz   HDWORDQ,x
            ldx   TOKWY
*-- SUBDEPTH/SUBPRVD/HDX_ELIG/HDX_USED/HDX_KIND zeroing moved to
*-- :tokstart (2026-09-15) -- shared with the quote-first entry.
*-- A `(` STARTING THE LINE OPENS A GROUP SPAN, so `( A ; B )`
*-- reaches CLASSIFY as ONE token the way `$( A ; B )` already
*-- does -- otherwise PARSE would split the body on its own `;`
*-- and the group would never exist as a unit. Pre-setting
*-- SUBDEPTH is the whole trick: SUB_TRKCH opens a span only for
*-- `$(`, so the leading `(` adds nothing and the matching `)`
*-- decrements 1 -> 0, ending the span exactly there. Anything
*-- after it (`> FILE`) tokenizes normally, and a `$( )` nested
*-- INSIDE the group still works -- the inner `$(` counts to 2
*-- and its `)` back to 1.
*--
*-- FIRST TOKEN ONLY (NTOK==0): the same command-position
*-- discipline SEG_FIRST already applies to constructs, and it
*-- leaves `ECHO (A` splitting the ordinary way, which
*-- SUB_TRKCH's own header promises.
*--
*-- TOKQUOTE=1 marks the whole token LITERAL to this shell:
*-- the body belongs to the SUBSHELL, exactly like a `$( )`
*-- span, so WORDEXPAND must not touch it (`( ECHO $V )` gets
*-- its V from SUB_WRVARS's serialisation, not from us).
*-- A GROUP MAY OPEN A SEGMENT, NOT ONLY A LINE. This guard used
*-- to be a bare `ldy NTOK / bne :qbnogrp`, i.e. `(` was seeded
*-- as a group span ONLY as token 0 of the whole LINE -- but a
*-- group is a SEGMENT-scoped construct and `;` does not split
*-- before TOKENIZE, so NTOK counts straight across it. In
*-- `ECHO A ; ( ECHO B ) ; ECHO C` the `(` is token 3, no span
*-- opened, and the paren fell through to be tokenized as an
*-- ORDINARY WORD -- so CHCK_GROUP never saw a group to accept
*-- or refuse, and the line misparsed. A line-scoped guard on a
*-- segment-scoped construct.
*--
*-- Found 2026-08-27 by the e2e shell-language section, and only
*-- because its CONTROL case (`ECHO A ; ECHO C`, no group)
*-- passed while the same list plus one group produced nothing.
*-- It was very nearly filed as CHCK_GROUP's documented
*-- redirect/pipeline refusal, which it is NOT: those refusals
*-- are loud, and this was a silent misparse.
*-- INDEX WITH Y, NEVER X. X is the live WRITE CURSOR here --
*-- :qbare saves it to TOKWY and restores it precisely so this
*-- stretch may use it, and BOTH exits below reload only Y (from
*-- TOKWY). An earlier cut used `tax` and destroyed the
*-- cursor: the shell then tokenized into wrong offsets, and
*-- the e2e harness HUNG at case 2 rather than failing a case.
            ldy   NTOK
            beq   :qbgrp                 ;token 0 -- eligible
            dey                          ;else eligible only
            tya                          ;right after a `;`
            asl   a
            tay
*-- Dereference TOKPTR through PTR0 (the direct page; the
*-- pointer table itself lives in a `dum` arena, so `(TOKTMP),y`
*-- is a Bad Address Mode). This used to subtract #<LINEBUF and
*-- index LINEBUF by the low-byte difference, which was exact
*-- while every token lived in LINEBUF -- a `|`/`||` token now
*-- points into OPBUF (see :bop), and the
*-- difference trick would read a junk byte for those. PTR0 is
*-- free here: nothing holds it across TOKENIZE (PARSE reloads
*-- it per token).
            lda   TOKPTR,y
            sta   PTR0
            lda   TOKPTR+1,y
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            cmp   #$BB                   ;';' high-bit-set
            bne   :qbnogrp
:qbgrp      ldy   TOKWY
            lda   LINEBUF,y
            cmp   #$A8                   ;'(' high-bit-set
            bne   :qbnogrp
*-- Seed SUBPRVD, NOT SUBDEPTH: it makes SUB_TRKCH treat this
*-- leading `(` exactly like the one in `$(` and open the span
*-- through the normal path, so the depth counts 1 for it rather
*-- than 2. Pre-setting SUBDEPTH was tried and is wrong:
*-- the `(` then increments a depth that already counted it,
*-- the closing `)` returns to 1 not 0, the span never ends,
*-- and the child receives a body with its own final `)` eaten.
*-- TOKGRP, NOT a direct TOKQUOTE store (2026-09-15): this
*-- token still runs the ordinary bare scan to find its own
*-- extent, and :segbare would otherwise force TOKLVL (hence
*-- TOKQUOTE) to 0 once that scan reaches plain content --
*-- :tokfinal (below) reads TOKGRP FIRST at every termination
*-- point so this survives it.
            lda   #1
            sta   SUBPRVD
            sta   TOKGRP
:qbnogrp
            ldy   TOKWY
            lda   LINEBUF,y
            cmp   #$BC                   ;'<'
            bne   :qbnoasg
            iny
            lda   LINEBUF,y
            cmp   #$BC                   ;'<'
            bne   :qbnoasg
            iny                          ;Y = tokstart+2
            lda   LINEBUF,y
            cmp   #$AD                   ;'-'
            bne   :qbnodash
            iny                          ;Y = tokstart+3
:qbnodash   lda   LINEBUF,y
            cmp   #$A7                   ;''' high-bit-set
            beq   :qbhdq
            cmp   #$A2                   ;'"' high-bit-set
            bne   :qbnoasg               ;`<<` with no quote --
                                         ;still try the
                                         ;assignment prefix
:qbhdq      sta   HDX_QCH
            tya
            sec
            sbc   TOKWY
            sta   HDX_PFXLEN            ;quote's offset from the
                                        ;token start (2 or 3)
            lda   #1
            sta   HDX_ELIG
            bra   :qbnohd               ;HDX_KIND stays 0 --
                                        ;heredoc
*-- THE SECOND ELIGIBLE PREFIX: `NAME=` before a quote, i.e. a
*-- QUOTED ASSIGNMENT (`V='a b'`, `V="a b"`). Until 2026-08-28
*-- maux had no such form at all -- `W='a b'` typed by a human
*-- was `sh: mixed quoting`, real V7 drift that this shell's own
*-- `$( )` serialiser had to route around (docs/SHELL-GAPS.md
*-- sec 2, "STILL OPEN"). It is the same shape as the `<<'WORD'`
*-- exception directly above and reuses the identical machinery:
*-- a quote is allowed to open at ONE recorded offset in an
*-- otherwise-bare token.
*--
*-- IFS is what made it urgent rather than merely missing. The
*-- canonical Bourne idiom is two halves -- `V='a b c'` to build
*-- a multi-word value and `for x in $V` to split it again --
*-- and splitting alone leaves the shell able to take such a
*-- value apart while still unable to write one down.
*--
*-- The name rule is CHCK_BLTN_VAR's, deliberately: a letter,
*-- then letters/digits, then `=`. If the two disagreed, a token
*-- this accepted would tokenize as an assignment and then fail
*-- to BE one, which is the silent-wrong-answer shape.
:qbnoasg    ldy   TOKWY
            lda   LINEBUF,y
            jsr   ISNAME1                ;letter, either case
            bcc   :qbnohd
:qbanm      iny
            lda   LINEBUF,y
            cmp   #$BD                   ;'=' -- end of the name
            beq   :qbaeq
            jsr   ISIDENTCH              ;letter or digit: keep
            bcs   :qbanm                 ;  scanning the name
            bra   :qbnohd                ;anything else: not an
                                         ;assignment prefix
:qbaeq      iny                          ;the byte after '='
            lda   LINEBUF,y
            cmp   #$A7                   ;''' high-bit-set
            beq   :qbasgq
            cmp   #$A2                   ;'"' high-bit-set
            bne   :qbnohd
:qbasgq     sta   HDX_QCH
            tya
            sec
            sbc   TOKWY
            sta   HDX_PFXLEN            ;quote's offset = the
                                        ;length of `NAME=`
            lda   #1
            sta   HDX_ELIG
            sta   HDX_KIND               ;1 = assignment, so the
                                         ;absorbing loop marks
                                         ;the content instead of
                                         ;flagging a heredoc
:qbnohd     ldy   TOKWY                  ;the lookahead above
                                        ;walked Y past the
                                        ;token's own start --
                                        ;restore it before
                                        ;:bloop's ordinary scan
                                        ;begins
*-- :segbare sets TOKLVL=0 (this token is bare -- shpath.s's own
*-- TOKLVL header) and falls into :bloop -- shared with every
*-- mid-token bare re-entry after a quoted segment (:segend).
            jmp   :segbare
*-- `jmp`, not `beq`, for :bterm/:btermsp below -- range: the
*-- `<<'WORD'`-quoting block (:bqcheck onward) now sits between
*-- here and there, same "range" reason the rest of this file
*-- already flags repeatedly.
:bloop      lda   LINEBUF,y
            bne   :bnotend
            jmp   :bterm
:bnotend    cmp   #$A0
            bne   :bnotsp
*-- A space INSIDE a `$( )` span is content, not a delimiter --
*-- see :qbare's own header. A is the byte and X/Y are the write
*-- /read cursors, so the depth test goes through the stack.
            pha
            lda   SUBDEPTH
            bne   :bspin
            pla
            jmp   :btermsp
:bspin      pla
            bra   :bok
:bnotsp     cmp   #$DC                   ;'\' high-bit-set
            beq   :besc
            cmp   #$A7
            beq   :bqhit
            cmp   #$A2
            beq   :bqhit
            jsr   ISOPCH                 ;`|` `<` `>` `;` `&` --
            bcc   :bok                   ;an operator with or
            jmp   :bop                   ;without blanks (`jmp`:
                                         ;range)
*-- A QUOTE INSIDE A `$( )` SPAN IS CONTENT TOO, exactly like
*-- the space above and for the same reason: the body belongs to
*-- the SUBSHELL, which does its own quoting. Without this,
*-- `ECHO [$(ECHO '$V')]` reached :bqcheck and died `sh: mixed
*-- quoting` -- the outer token judged by the inner body's
*-- quotes (bash prints `[$V]`; SHELL-GAPS sec 2's table
*-- measured the old pre-verbatim shell printing `[]`).
*-- SUBDEPTH already existed for the SPLITTING half of this;
*-- this is the QUOTING half, which nothing had taught it. Same
*-- stack idiom as the space test: X and Y are the live cursors.
:bqhit      pha
            lda   SUBDEPTH
            bne   :bqspan
            pla
            jmp   :bqcheck
:bqspan     pla
            bra   :bok
:bok        sta   LINEBUF,x
            inx
            iny
            jsr   SUB_TRKCH              ;A survives -- tracks
            bra   :bloop                 ;  `$(` ... `)` depth
:besc       stz   SUBPRVD               ;`\$` opens no span
            iny
            lda   LINEBUF,y
            bne   :bescput
            lda   #$DC                   ;trailing lone '\' at
                                         ;EOL -- nothing to
                                         ;escape (v1) -- keep it
                                         ;literally; Y is
                                         ;already ON the NUL, so
                                         ;:bloop ends the token
            sta   LINEBUF,x
            inx
            bra   :bloop
*-- THE ESCAPED BYTE IS STORED WITH BIT 7 CLEAR, and that one
*-- `and` is the whole of docs/SHELL-GAPS.md sec 3b. liba text
*-- is high-bit-set by convention, so a cleared byte cannot be
*-- confused with a typed one and marks itself LITERAL at zero
*-- storage cost -- the classic CTLESC trick spelled in this
*-- system's own vocabulary.
*--
*-- Everything downstream then does the right thing WITHOUT
*-- knowing about it, because every metacharacter test in this
*-- shell compares against a HIGH-BIT constant: WORDEXPAND looks
*-- for $A4 and a literal '$' is $24; HASMETA and GLOBMATCH look
*-- for $AA/$BF/$DB and a literal '*'/'?'/'[' is $2A/$3F/$5B;
*-- CLASSIFY looks for $BE and a literal '>' is $3E, so `\>` is
*-- a WORD and not a redirect. None of those tests needed a
*-- line changed.
*--
*-- The bits are put back by UNESC at the two places a word
*-- leaves the parser -- APPEND_ARGV and the redirect setters --
*-- which is AFTER the metacharacter passes and BEFORE anything
*-- can see the low form. See UNESC's own header.
:bescput    and   #$7F
            sta   LINEBUF,x
            inx
            iny
            bra   :bloop
*-- :bqcheck -- a quote character reached mid-bare-token. Fires
*-- the ONE `<<WORD`-quoting exception (:qbare's own header,
*-- above) only when eligible, not yet used, and at EXACTLY the
*-- recorded prefix offset. HDX_ELIG can only be 1 for a token
*-- that started with a `<<`/`<<-`/`NAME=` prefix (:qbare's own
*-- lookahead, run once, at token start) -- so an ORDINARY quote
*-- (HDX_ELIG=0) always falls to :qsetup instead: general
*-- concatenation (2026-09-15), not the old blanket :mixed. The
*-- other two failures (already used; wrong offset) mean THIS
*-- token DID start with that prefix and stay :mixed, unchanged
*-- -- the heredoc/assignment exception's own HDWORDQ/ASGMARK
*-- bookkeeping is not extended to concatenate further.
*-- `beq`/`bne` straight to :mixed would be OUT OF an 8-bit
*-- branch's range from here (same reason the rest of this
*-- file routinely uses `jmp` instead -- see the many "range"
*-- comments elsewhere) -- each check below branches PAST a
*-- `jmp :mixed` on failure, never TO :mixed directly.
:bqcheck    lda   HDX_ELIG
            bne   :bqc1
            lda   LINEBUF,y
            jmp   :qsetup
:bqc1       lda   HDX_USED
            beq   :bqc2
            jmp   :mixed
:bqc2       txa
            sec
            sbc   TOKWY
            cmp   HDX_PFXLEN
            beq   :bqc3
            jmp   :mixed
:bqc3       lda   #1
            sta   HDX_USED
            lda   HDX_KIND
            bne   :bqc3a                 ;assignment -- HDWORDQ
                                         ;is the HEREDOC's flag
                                         ;and means nothing here
            stx   HDX_SAVEX
            ldx   NTOK
            lda   #1
            sta   HDWORDQ,x
            ldx   HDX_SAVEX
:bqc3a      iny                          ;step past the opening
                                         ;quote -- never copied
:hdqloop    lda   LINEBUF,y
            bne   :hdqnotend             ;`jmp`, not `beq` --
                                         ;range (same reason as
                                         ;:bqcheck's own header,
                                         ;above)
*-- Ran off the token's own end with no closing quote: still
*-- `mixed quoting` to the user, but READLINE's classifier
*-- (shrlog.s) needs to know a quote is OPEN (SH-MLQUOTE).
            lda   HDX_QCH
            sta   QCH
            inc   TOK_UNQ                ;(zeroed at entry)
            jmp   :mixed
:hdqnotend
            cmp   HDX_QCH
            beq   :hdqclose
            pha
            lda   HDX_KIND
            beq   :hdqput                ;heredoc terminator --
                                         ;copied verbatim, since
                                         ;STRCMP matches it
                                         ;against body lines
            pla
            jsr   ASGMARK                ;assignment -- mark the
            bra   :hdqst                 ;content per quote type
:hdqput     pla
:hdqst      sta   LINEBUF,x
            inx
            iny
            bra   :hdqloop
:hdqclose   iny                          ;step past the closing
                                         ;quote -- never copied
            lda   LINEBUF,y
            beq   :hdqok
            cmp   #$A0
            beq   :hdqok
            jsr   ISOPCH                 ;`V='a b';ls`: an
            bcs   :hdqok                 ;operator ends it
                                         ;(:bop, via :bloop)
            jmp   :mixed                 ;junk glued to quote
:hdqok      jmp   :bloop                 ;resume ordinary bare
                                         ;scanning -- the very
                                         ;next byte is the
                                         ;token's own NUL or a
                                         ;delimiting space, so
                                         ;:bterm/:btermsp ends
                                         ;it normally right
                                         ;after
*-- :btermsp -- ended on a delimiting SPACE, not the line's own
*-- NUL: step past it BEFORE writing the terminator. A bare
*-- token with no removed characters has X==Y right up to this
*-- point, so writing the NUL at X (== Y, still ON the space)
*-- would clobber the very byte :skip is about to re-read next,
*-- truncating the rest of the line -- the delimiter must be
*-- behind Y before that write happens, not still under it.
:btermsp    iny
*-- NO QUOTE-LEVEL FORCING HERE ANY MORE. This used to set
*-- TOKQUOTE=1 for any token containing an escape, which
*-- suppressed expansion AND globbing for every OTHER character
*-- in the word. Measured 2026-08-25: that made `x\yV$FOO` print
*-- xyV$FOO where bash prints xyVIT2. Setting 2 instead was
*-- tried and REJECTED -- it fixes that word and breaks
*-- `A\$FOO` into AIT2, an escaped '$' silently expanding.
*-- Neither is a fix, because TOKQUOTE is per-TOKEN and
*-- backslash is per-CHARACTER: one word can hold an escaped '$'
*-- that must stay literal and a live '$' that must expand. The
*-- flag is gone; :bescput marks the individual bytes instead.
*-- :tokfinal (above) gives this token's final TOKQUOTE --
*-- stored here via the TOKWY-stash idiom (:segterm's comment),
*-- since X is the live write cursor and cannot be borrowed for
*-- the NTOK-indexed store without saving it first. TOKGRP is
*-- what makes this matter for :qbgrp's own group token: it is
*-- ALWAYS a bare token by the time it gets here.
:bterm      stx   TOKWY
            jsr   :tokfinal
            ldx   NTOK
            sta   TOKQUOTE,x
            ldx   TOKWY
            lda   #0
            sta   LINEBUF,x
:bdone      inc   NTOK
            jmp   :skip

*-- :bop -- an operator byte (`|` `<` `>` `;` `&`) reached in a
*-- bare token (docs/SH-PIPE-NOSPACE.md for `|`; docs/KFIX-
*-- NOTES.md item 5 for the rest). A quoted token never comes
*-- here, and `\X` went through :besc and is stored LOW, so it
*-- never matched a high-bit operator byte above -- quoting
*-- gates the split for free. Three cases keep the byte as
*-- CONTENT: inside a `$( )`/`( )` span (the body belongs to the
*-- subshell, same rule the space and quote tests above apply --
*-- learning:01M10BV3J3SET83R0ETWM7YVVB); inside a `case`
*-- pattern, a bare word ending in `)` (CS_CASEPAT's own test;
*-- TOK_ENDPAR looks ahead for it so `A|B)` reaches it whole);
*-- and where OP_LEXEME says the glued text is not an operator
*-- at all (`<<WORD` stays glued as it always was, and so does a
*-- `>&WORD` that is not a dup).
*--
*-- Otherwise the operator ENDS the word before it (if any) and
*-- is a token of its own, exactly the token the SPACED spelling
*-- gives CLASSIFY: `sort|uniq` is `sort | uniq`, `echo hi>F` is
*-- `echo hi > F`, `a||b` is `a || b` (never `a | | b`),
*-- `ls;pwd` is `ls ; pwd`. The lexeme is the longest operator
*-- CLASSIFY knows at that point (OP_LEXEME): `>>`, `>&D`,
*-- `<&D`, `||`, `&&`, `;;`, or the single byte. IO_NUMBER
*-- (POSIX): a pending word that is exactly ONE digit 0-7, bare
*-- and unsqueezed, followed by `>` is the operator's own prefix
*-- -- `2>F`, `2>>F`, `2>&1` are single `N>` tokens, and `2<F`,
*-- `2<&1` single `N<` tokens (KFIX3 item 2) -- while `a2>F` and
*-- `22>F` close their word first.
*--
*-- THE OPERATOR TOKEN LIVES IN OPBUF, NOT LINEBUF. Every other
*-- token is NUL-terminated in place, which works because its
*-- delimiter (a blank, or a squeezed quote) is a byte nobody
*-- needs. Here there is no such byte: `sort|uniq` has NO room
*-- for a NUL between `sort` and `|` (the write cursor X equals
*-- the read cursor Y when nothing was squeezed), and shifting
*-- the rest of the line right has no room on a full LINEMAX
*-- line. So the lexeme is COPIED into OPBUF (a bump pool, reset
*-- per line) first, the word's NUL is written over the operator
*-- byte (X <= Y: nothing past Y is touched), and TOKPTR[NTOK]
*-- points at the copy. Only LOAD_TOK_PTR dereferences TOKPTR,
*-- so a pointer outside LINEBUF costs nothing downstream.
*-- A,X,Y: A = the operator byte, X = write cursor, Y = read
*-- cursor ON it.
:bop        sta   OPCH
            lda   OPSKIP
            beq   :bop1
            stz   OPSKIP                 ;2nd byte of a pair
            bra   :bopcnt                ;already ruled content
:bop1       lda   SUBDEPTH
            bne   :bopcnt
            lda   OPCH
            cmp   #OPC_PIPE              ;only `|` can sit in a
            bne   :bopop                 ;case pattern `a|b)`
            jsr   TOK_ENDPAR
            bcs   :bopcnt
:bopop      jsr   OP_LEXEME              ;A = length, 0 = it is
            bne   :bopgo                 ;  content after all
:bopcnt     lda   OPCH
            jmp   :bok
:bopgo      sta   OPLEN
            stx   OPX
            sty   OPY
            stz   OPDIG
            cpx   TOKWY
            beq   :bopnow                ;the op IS the token
            cpx   OPY
            bne   :bopnow                ;squeezed: not bare
            lda   OPCH
            cmp   #OPC_GT
            beq   :bdigop
            cmp   #OPC_LT
            bne   :bopnow                ;`1;` `3|`: a word
:bdigop     ldx   TOKWY                  ;an all-digit word is
:bdig       lda   LINEBUF,x              ;an IO_NUMBER (POSIX)
            sec
            sbc   #OPC_DIG0
            cmp   #10
            bcs   :bopnow                ;not a number: a word
            inx
            cpx   OPX
            bne   :bdig
            ldx   TOKWY                  ;all digits: refuse all
            lda   LINEBUF,x              ;but one 0-7 before `>`
            inx                          ;or `<`
            cpx   OPX
            bne   :badfd                 ;`10>`: no such fd
            cmp   #OPC_DIG8
            bcs   :badfd                 ;`8>` `9>`: no such fd
            sta   OPDIG                  ;merged: `2>` `2>&1`
            bra   :bopnow                ;`2<` `2<&1`
:toomany    lda   #3                     ;KFIX2 5: MAXTOK, or
            bra   :terr                  ;the operator pool full
:badfd      lda   #4                     ;`8>F` `9<F`: a number
:terr       sta   TOK_ERR                ;before >/< this shell
            rts                          ;cannot hold
:bopnow     ldx   OPPOS
            cpx   #OPBUFSZ-8
            bcc   :bpool
            jmp   :toomany               ;pool full: TOK_ERR 3
:bpool      stx   OPSTART
            lda   OPDIG
            beq   :bcp0
            sta   OPBUF,x
            inx
:bcp0       lda   OPLEN
            sta   OPCNT
:bcp1       lda   LINEBUF,y
            sta   OPBUF,x
            inx
            iny
            dec   OPCNT
            bne   :bcp1
            lda   #0
            sta   OPBUF,x
            inx
            stx   OPPOS
            ldx   OPX
            cpx   TOKWY
            beq   :bset                  ;nothing pending
            lda   OPDIG
            bne   :bset                  ;digit became the token
            lda   #0
            sta   LINEBUF,x              ;close the pending word
            jsr   :tokfinal              ;its TOKQUOTE
            ldx   NTOK
            sta   TOKQUOTE,x
            inc   NTOK
            lda   NTOK
            cmp   #MAXTOK
            bne   :bslot
            jmp   :toomany               ;too many tokens
:bslot      ldx   NTOK
            stz   TOKQUOTE,x
            stz   HDWORDQ,x
            stz   TOKCP,x             ;SH-CASE2 B: operator slot
:bset       lda   NTOK
            asl   a
            tax
            clc
            lda   OPSTART
            adc   #<OPBUF
            sta   TOKPTR,x
            lda   #>OPBUF
            adc   #0
            sta   TOKPTR+1,x
            inc   NTOK
            jmp   :skip

:unterm     lda   #1
            sta   TOK_ERR
            rts
:mixed      lda   #2
            sta   TOK_ERR
            rts

:done       rts

*---------------------------------------------------------------
* ISOPCH -- A = a byte. Carry SET iff it is one of the five
* operator bytes TOKENIZE splits on: `|` `<` `>` `;` `&` (high-
* bit- set). A, X and Y preserved.
*---------------------------------------------------------------
ISOPCH      cmp   #OPC_PIPE
            beq   :yes
            cmp   #OPC_LT
            beq   :yes
            cmp   #OPC_GT
            beq   :yes
            cmp   #OPC_SEMI
            beq   :yes
            cmp   #OPC_AMP
            beq   :yes
            clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* OP_LEXEME -- OPCH = the operator byte, Y = its offset in
* LINEBUF. OUT: A = the length of the operator token starting
* there (1-3), or 0 when the glued text is NOT an operator and
* stays content (OPSKIP is then set so the pair's second byte
* follows it):
*   `|` `;` `&`  doubled is `||` `;;` `&&`, else the one byte;
*   `>`          `>>`, `>&D` (D = 0-7 or `-`), else `>`;
*   `<`          `<&D`, else `<` -- but `<<` (a here-doc, whose
*                WORD CLASSIFY wants glued to it) is content;
* and `>&WORD`/`<&WORD`, which CLASSIFY calls a word when
* spaced, are content too, so the split never turns one into a
* background `&`. CLOBBERS: A. X and Y preserved.
*---------------------------------------------------------------
OP_LEXEME   lda   OPCH
            cmp   #OPC_GT
            beq   :gt
            cmp   #OPC_LT
            beq   :lt
            cmp   LINEBUF+1,y            ;`||` `;;` `&&`
            beq   :two
:one        lda   #1
            rts
:two        lda   #2
            rts
:lt         lda   LINEBUF+1,y
            cmp   #OPC_LT
            beq   :cont                  ;`<<`
            bra   :dup
:gt         lda   LINEBUF+1,y
            cmp   #OPC_GT
            beq   :two                   ;`>>`
:dup        cmp   #OPC_AMP               ;`&` after `<` `>`
            bne   :one
            lda   LINEBUF+2,y
            cmp   #OPC_DASH                   ;'-'
            beq   :three
            cmp   #OPC_DIG0
            bcc   :cont
            cmp   #OPC_DIG8
            bcs   :cont
:three      lda   #3
            rts
:cont       lda   #1
            sta   OPSKIP
            lda   #0
            rts

*---------------------------------------------------------------
* TOK_ENDPAR -- does the bare token being lexed hold a case
* pattern's `)`? IN: Y = read cursor, inside the token (on a
* non-blank, non-NUL byte). OUT: carry SET if (a) a `)` comes
* before the next blank with no quote or backslash ahead of it
* (`a|b)echo hit`: the `|` is a pattern's alternation), or (b)
* the token's last byte is `)` (the older rule: `a|"b")` and
* `a|$X)`). The lookahead reads raw LINEBUF and cannot see quote
* state; the stop set is what keeps `echo L|echo")"X` a pipeline
* (the `)` is inside quotes; SH-CASE2 B H1). Preserves X and Y
* (X is :qbare's live write cursor). CLOBBERS: A.
*---------------------------------------------------------------
TOK_ENDPAR  phx
            phy
            ldx   #0                  ;1 once a stop byte passed
:scan       lda   LINEBUF,y
            beq   :end
            cmp   #$A0
            beq   :end
            cmp   #ALC_A9                   ;')' high-bit-set
            bne   :nxt
            cpx   #0
            beq   :yes                 ;bare `)` before any stop
:nxt        cmp   #ALC_A7                   ;quote
            beq   :stop
            cmp   #ALC_A2                   ;quote
            beq   :stop
            cmp   #ALC_DC                   ;backslash
            beq   :stop
            cmp   #ALC_A4             ;`$`: perhaps a `$(` span,
            bne   :adv                 ;  whose own `)` is not a
:stop       ldx   #1                     ;  pattern's (H2)
:adv        iny
            bne   :scan             ;LINEBUF[LINELEN] is NUL and
                                       ;LINELEN <= LINEMAX, so Y
                                         ;cannot wrap
:end        dey                          ;>= 1: the entry byte
            lda   LINEBUF,y              ;itself was neither
            cmp   #ALC_A9
            beq   :yes
            ply
            plx
            clc
            rts
:yes        ply
            plx
            sec
            rts

*---------------------------------------------------------------
* SUB_TRKCH -- IN: A = the byte :bok just copied into the token
* being built. Maintains SUBDEPTH ("how many `$(` spans are open
* inside THIS token") and SUBPRVD ("the previous copied byte was
* a `$`"), so :bloop can tell a delimiting space from one that
* is part of a command substitution's own argument list.
*
* MUST touch neither X nor Y -- they are :qbare's live write and
* read cursors -- so every test here goes through A and memory
* only, never an index register.
*
* Only a `(` IMMEDIATELY PRECEDED BY `$` opens a span: `ECHO (A`
* keeps splitting the ordinary way. A `)` with no span open is
* an ordinary character too. Nested `$(` still counts up, so the
* matching `)` is found correctly even for a form CMDSUBST
* itself goes on to refuse (see SUB_GRAB's own header).
* CLOBBERS: A.
*---------------------------------------------------------------
SUB_TRKCH   cmp   #$A8                   ;'(' high-bit-set
            beq   :opar
            cmp   #$A9                   ;')' high-bit-set
            beq   :cpar
            cmp   #$A4                   ;'$' high-bit-set
            beq   :dol
            stz   SUBPRVD
            rts
:dol        lda   #1
            sta   SUBPRVD
            rts
*-- A BARE `(` NESTS WHEN A SPAN IS ALREADY OPEN. Outside one it
*-- is still an ordinary character (`ECHO (A` splits normally),
*-- but inside a group span it must count, or the FIRST `)`
*-- closes the OUTER span and truncates the body. Measured
*-- before this: `( ( ECHO INNER ) ; ECHO OUTER )` handed the
*-- child `( ECHO INNER` -- unclosed -- and then ran
*-- `ECHO OUTER )` in the PARENT, printing `OUTER )`. With the
*-- span counted properly the body arrives whole and the child,
*-- being a whole shell, runs the inner group itself: nesting
*-- WORKS rather than merely failing cleanly.
:opar       lda   SUBPRVD
            bne   :opnest                ;`$(` always opens one
            lda   SUBDEPTH
            beq   :clr                   ;bare '(' outside a
                                         ;span -- not a span
:opnest     stz   SUBPRVD
            inc   SUBDEPTH
            rts
:cpar       stz   SUBPRVD
            lda   SUBDEPTH
            beq   :cand              ;SH-CASE2 B: a BARE `)`, or
            cmp   #1                    ;  the one that closes a
            bne   :dec                ;  seeded group's span, is
            lda   TOKGRP             ;  a pattern candidate: the
            beq   :dec                  ;  token's FIRST such is
:cand       lda   CPOFF               ;  recorded (offset in the
            bne   :dec                  ;  finished token). X is
            txa                         ;  already past the `)`.
            sec                          ;  offset + 1: 0 = none
            sbc   TOKWY
            sta   CPOFF
:dec        lda   SUBDEPTH
            beq   :nodec
            dec   SUBDEPTH
:nodec      rts
:clr        stz   SUBPRVD
            rts

*---------------------------------------------------------------
* ASGMARK -- IN: A = one content byte of a QUOTED ASSIGNMENT's
* value, HDX_QCH = the quote that opened it. OUT: A = the byte
* to store, with bit 7 CLEARED if this quote form must keep it
* literal. CLOBBERS: nothing but A and the flags.
*
* The whole of quoting semantics for this form, in one test,
* using the file's existing bit-7-clear-means-literal
* convention (:bescput's, and SHELL-GAPS sec 3b's) so that
* nothing downstream needs to know this ran -- every
* metacharacter test in the shell compares a HIGH-bit constant,
* and UNESC restores the bits at APPEND_ARGV before
* CHCK_BLTN_VAR ever reads the value:
*
*   '...'  EVERY byte literal -- no expansion, no globbing.
*   "..."  only the GLOB metacharacters `* ? [`; `$` stays high
*          so `V="$X"` still expands, which is the half that
*          distinguishes the two forms.
*
* THE GLOB HALF IS DEFENSIVE AND CURRENTLY UNOBSERVABLE, which
* is stated rather than left for someone to rediscover. An
* assignment word reaches GLOB_APPEND, but no ProDOS entry name
* can contain `=` (letters, digits and `.` only), so a pattern
* like `V=*` matches nothing and passes through LITERALLY --
* the same invariant CS_CASEPAT leans on. Removing these three
* compares would therefore change no output on this volume, and
* a gate case written for them was deleted for exactly that
* reason (it stayed green under sabotage). They are kept because
* correctness here should not rest on a filesystem accident: if
* that character set ever widens, this is what stops `V="*.S"`
* expanding against the volume at assignment time.
*
* A space is left HIGH in both forms, deliberately: quoting
* holds the word together at TOKENIZE time, and the stored
* VALUE is then an ordinary multi-word string that a later
* unquoted `$V` splits on (Bourne -- quoting at assignment time
* does not persist into the value). That is exactly what makes
* `V='a b c'` + `for x in $V` work as one idiom.
*---------------------------------------------------------------
ASGMARK     pha
            lda   HDX_QCH
            cmp   #$A7                   ;''' -- literal, whole
            beq   :all
            pla                          ;'"' -- globs only
            cmp   #$AA                   ;'*'
            beq   :clr
            cmp   #$BF                   ;'?'
            beq   :clr
            cmp   #$DB                   ;'['
            beq   :clr
            rts
:all        pla
:clr        and   #$7F
            rts
