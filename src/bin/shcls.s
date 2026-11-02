*---------------------------------------------------------------
* shcls.s -- sh's tokenizer half and classifier half, split from
* shlex.s at a GLOBAL boundary for the as source
* window (S9-PLAN sec 6, tier 2). One assembly stream:
* ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* CLASSIFY -- classify a token as an operator or an ordinary
* word. `;`/`&&` follow the SAME v1 rule `<`/`>` already set:
* an operator must be its OWN whitespace-delimited token
* ("A ; B", not "A;B") -- one rule, applied consistently
* (docs/SH-SUBSET.md sec 6.1's own phrase for the same idea).
* EXCEPT (2026-09-07 for `|`/`||`, KFIX 5 for the rest):
* TOKENIZE splits an unquoted operator off a bare word itself
* (shtok.s :bop, docs/SH-PIPE-NOSPACE.md, docs/KFIX-NOTES.md),
* so `sort|uniq` and `echo hi>F` arrive here as the same
* tokens their spaced spellings give; the ">X"/"<X"/"|X is a
* word" rules below are what a QUOTED or escaped one gets, and
* are kept as written.
* `N>`/`N>>` (docs/SH-FEATURES.md sec 3) extend the SAME rule
* one more time: a leading digit is checked ONLY as the token's
* very FIRST character (a word like "X2>" never reaches the
* digit path at all -- its first byte fails every cmp below and
* falls straight to the plain-word default), and a digit not
* immediately followed by '>' is just an ordinary word ("2",
* "22", "2x") -- exactly the shape ">X"/"<X"/"|X" already use.
* `N>&M`/`>&M`/`N>&-` (docs/SH-FEATURES.md sec 15) extend it
* once more, and the SAME digit rule governs BOTH fds -- see
* CLS_DUPTAIL's own header.
* IN:  PTR0/PTR0+1 = token pointer (NUL-terminated)
* OUT: A = 0 (word), 1 (`<`), 2 (`>`), 3 (`|`), 4 (`>>`),
*      5 (`;`), 6 (`&&`), 7 (`||`), 8 (`N>`), 9 (`N>>`), 10
*      (a here-doc, Tier 3 docs/SH-FEATURES.md sec 4/6), 11 (fd
*      duplication `N>&M`/`>&M`/`<&M`, or fd close `N>&-`/`>&-`/
*      `<&-`; sec 15 (output) and 2026-09-15 (`<&`, the input
*      side -- SAME class, REDIR_FD forced to FD_STDIN since
*      `<&` carries no digit of its own to read it from) --
*      REDIR_FD is the TARGET fd, REDIR_SRC the SOURCE fd
*      0-7 or $FF for the close form) -- for 8
*      and 9, REDIR_FD holds the target fd digit (0-7 --
*      PCB_FDTABLE's own hard limit, see the digit-range check
*      below). For 10, HD_STRIP holds 0 (`<<WORD`) or 1
*      (`<<-WORD`), HD_WPTR points at WORD's first character
*      -- still inside THIS token, NUL-terminated by the
*      token's own end (TOKENIZE already squeezed it, quotes
*      included -- see :qbare's own header) -- and HD_QUOTED
*      holds 0 (`<<WORD`, Bourne expands the body) or 1
*      (`<<'WORD'`/`<<"WORD"`, Bourne does NOT -- docs/SH-
*      FEATURES.md sec 6/12), read from HDWORDQ[TOKI] since the
*      squeezed text alone cannot tell the two apart any more.
*      v1 only recognises the GLUED form, `<<WORD`/`<<-WORD` --
*      no space before WORD, matching the idiom `ED FILE
*      <<EOF` uses. A bare `<<`/`<<-` with NOTHING after it (no
*      WORD at all) does NOT return 10 -- it falls
*      through to the plain-word default, same v1 shape ">X"/"N"
*      alone already use below.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CLASSIFY    ldy   #0
            lda   (PTR0),y
            cmp   #$BC                   ; '<' high-bit-set
            beq   :m1
            cmp   #$BE                   ; '>' high-bit-set
            beq   :m2
            cmp   #$FC                   ; '|' high-bit-set
            bne   :ck4a                  ;`jmp`, not `beq` --
            jmp   :m3                    ; range (`<&` pushed
                                         ;:m3 out of reach)
:ck4a       cmp   #$BB                   ; ';' high-bit-set
            bne   :ck5                   ;`jmp`, not `beq` --
            jmp   :m4                    ; range (sec 15's dup
:ck5        cmp   #$A6                   ; tail pushed :m4/:m5
            bne   :ckdig                 ; out of an 8-bit
            jmp   :m5                    ; branch's reach)
:ckdig
*-- Digit range is '0'-'7', NOT '0'-'9': PCB_FDTABLE (memmap-
*-- annex.equ) is an 8-entry HARD LIMIT, and PRC_FDACTIONS'S
*-- PRC_GET_FDOBJ/PRC_SET_FDOBJ trust the target/source fd byte
*-- with no bounds check of their own -- a fd of 8 or 9 would
*-- index straight past the table into the NEXT PCB field. "8>"/
*-- "9>" fall through to the plain-word default below instead,
*-- same as any digit-token that never becomes an operator.
            cmp   #$B0                   ; '0'-'7' high-bit-set?
            bcc   :isword
            cmp   #$B8                   ; past '7'?
            bcs   :isword
            jmp   :m6
:isword     lda   #0
            rts
:m1         iny
            lda   (PTR0),y
            beq   :m1solo                ;lone '<' -- redirect
*-- "<&N"/"<&-" -- the input-side twin of ">&"/"N>&" (docs/
*-- SH-FEATURES.md, 2026-09-15): same CLS_DUPTAIL tail, target
*-- fd forced to FD_STDIN since "<&" has no digit prefix of its
*-- own to read (unlike ">&", stdin has no second fd slot to
*-- pick from). Y=1 here, exactly CLS_DUPTAIL's own contract.
            cmp   #$A6                   ;'&' high-bit-set?
            bne   :m1nodup
            lda   #FD_STDIN
            sta   REDIR_FD
            jmp   CLS_DUPTAIL
:m1nodup
*-- `beq` PAST a `jmp`, not `bne :word0`: adding the ";;" case
*-- below pushed :word0 out of an 8-bit branch's reach from
*-- here. Same idiom :bqcheck already uses for :mixed.
            cmp   #$BC                   ;second char ALSO '<'?
            beq   :m1hd                  ;"<X" -- word (v1 rule,
            jmp   :word0                 ;unchanged)
:m1hd
*-- "<<..." -- a here-doc (Tier 3). `<<-` strips the `-`, then
*-- whatever remains (if anything) is WORD, glued, no space --
*-- see this routine's own header.
            iny                          ;Y=2, char after "<<"
            lda   (PTR0),y
            cmp   #$AD                   ;'-' high-bit-set?
            bne   :hdnodash
            lda   #1
            sta   HD_STRIP
            iny                          ;Y=3, skip past the '-'
            bra   :hdword
:hdnodash   stz   HD_STRIP
:hdword     lda   (PTR0),y
            beq   :word0                 ;nothing after -- v1:
                                         ;the whole token stays
                                         ;a plain word, same
                                         ;shape "N" alone
                                         ;already uses
            tya
            clc
            adc   PTR0
            sta   HD_WPTR
            lda   #0
            adc   PTR0+1
            sta   HD_WPTR+1
*-- Bourne's own rule (docs/SH-FEATURES.md sec 6/12): TOKENIZE
*-- recorded whether THIS token's word was quoted in
*-- HDWORDQ[TOKI] (:qbare's own header) -- TOKI still indexes
*-- the token PARSE just handed CLASSIFY, untouched since
*-- LOAD_TOK_PTR's caller read it.
            ldx   TOKI
            lda   HDWORDQ,x
            sta   HD_QUOTED
            lda   #10
            rts
:m1solo     lda   #1
            rts
:m2         iny
            lda   (PTR0),y
            beq   :m2solo               ;lone '>' -- redirect
*-- ">&M" / ">&-" -- the BARE dup form, i.e. "1>&M" (sec 15).
*-- Set the implied target fd here; CLS_DUPTAIL (below) reads
*-- the source from the byte after the '&', Y still on it.
            cmp   #$A6                   ;'&' high-bit-set?
            bne   :m2nodup
            lda   #FD_STDOUT
            sta   REDIR_FD
            jmp   CLS_DUPTAIL
:m2nodup    cmp   #$BE                   ;second char also '>'?
            bne   :word0                 ;">X" -- not an op, a
                                         ;word (same rule as
                                         ;"<X"/"|X" above)
            iny
            lda   (PTR0),y
            bne   :word0                 ;">>X" -- not a
                                         ;recognized op either
            lda   #4                     ;exactly ">>"
            rts
:m2solo     lda   #2
            rts
:m3         iny
            lda   (PTR0),y
            beq   :m3solo               ;lone '|' -- pipe
            cmp   #$FC                   ;second char also '|'?
            bne   :word0                 ;"|X" -- word (v1 rule)
            iny
            lda   (PTR0),y
            bne   :word0                 ;"||X" -- not "||"
            lda   #7                     ;exactly "||"
            rts
:m3solo     lda   #3
            rts
:m4         iny
            lda   (PTR0),y
            beq   :m4solo
            cmp   #$BB                   ;";;" -- a `case`
            bne   :m4word                ;  branch terminator
            iny
            lda   (PTR0),y
            bne   :m4word                ;";;X" is just a word
            lda   #13
            rts
:m4solo     lda   #5                     ;exactly ";"
            rts
*-- Trampoline: :word0 is out of an 8-bit branch's reach from
*-- here, the same way the rest of this routine already needs
*-- `jmp` for :m4/:m5.
:m4word     jmp   :word0
:m5         iny
            lda   (PTR0),y
            beq   :m5bg                  ;exactly "&" -- run the
                                         ;segment in background
                                         ;(docs/SH-BG.md; the
                                         ;SH-SUBSET sec 4
                                         ;exclusion was lifted
                                         ;by ANACHRONISMS W4)
            cmp   #$A6                   ;second char also '&'?
            bne   :word0
            iny
            lda   (PTR0),y
            bne   :word0                 ;"&&X" -- not "&&"
            lda   #6                     ;exactly "&&"
            rts
:word0      lda   #0
            rts
:m5bg       lda   #12
            rts

*-- :m6 -- digit-prefixed redirect operator (`N>`/`N>>`). Y=0,
*-- A=the high-bit ASCII digit the dispatch above already
*-- matched (its cmp/bcc/bcs chain never touched A). Stash the
*-- fd number FIRST -- even a token that turns out to be a plain
*-- word falls through cases below that read A again before
*-- returning, and REDIR_FD is harmless to set on a word (the
*-- caller only reads it when CLASSIFY's own return value is 8
*-- or 9).
:m6         and   #$0F                   ;hi-bit ASCII digit ->
            sta   REDIR_FD               ;binary 0-7 (dispatch
                                         ;above already refused
                                         ;'8'/'9')
            iny                          ;Y=1, past the digit
            lda   (PTR0),y
            cmp   #$BE                   ;'>' ?
            beq   :m6gt
            cmp   #OPC_LT                ;'<' ? (KFIX3 item 2)
            beq   :m6lt
            lda   #0                     ;"N" alone, or "Nx" --
            rts                          ;word (v1 rule)
*-- "N<" and "N<&M". The token is exactly the digit, `<`, and
*-- optionally a dup tail; anything else glued on ("2<X",
*-- "2<<") is a plain word, as "N>X" is. "0<" is "<": the same
*-- redirect, the same slot, so class 1. "N<&M" is the existing
*-- dup tail with N as the target (it is "<&M" when N is 0).
:m6lt       iny                          ;Y=2
            lda   (PTR0),y
            beq   :m6lsolo               ;lone "N<"
            cmp   #OPC_AMP               ;'&' -- "N<&M"/"N<&-"
            beq   CLS_DUPTAIL
            lda   #0                     ;"N<X" -- word
            rts
:m6lsolo    lda   REDIR_FD
            beq   :m6l0
            lda   #14                    ;"N<" onto fd N
            rts
:m6l0       lda   #1                     ;"0<" is "<"
            rts
:m6gt       iny                          ;Y=2
            lda   (PTR0),y
            beq   :m6solo                ;lone "N>"
            cmp   #$A6                   ;'&' -- "N>&M"/"N>&-"
            beq   CLS_DUPTAIL          ;  (REDIR_FD already set
                                         ;   by :m6's own `and`)
            cmp   #$BE                   ;second '>' too?
            beq   :m6ap
            lda   #0                     ;"N>X" -- word
            rts
:m6ap       iny                          ;Y=3
            lda   (PTR0),y
            bne   :m6word                ;"N>>X" -- word
            lda   #9                     ;exactly "N>>"
            rts
:m6word     lda   #0
            rts
:m6solo     lda   #8                     ;exactly "N>"
            rts

*---------------------------------------------------------------
* CLS_DUPTAIL -- the shared tail of `>&X` and `N>&X` (docs/SH-
* FEATURES.md sec 15). IN: Y = the offset of the '&' inside the
* token, REDIR_FD already holding the TARGET fd. OUT: A = 11
* and REDIR_SRC = the source fd (0-7) or $FF (the `&-` close
* form), or A = 0 -- an ordinary word -- for anything else.
*
* The SOURCE digit is clamped to '0'-'7' for the SAME reason the
* target one is (learning:01M0HEMY6X9SR68V9FJ9Q4VKSG): both fds
* reach PRC_GET_FDOBJ/PRC_SET_FDOBJ, which index PCB_FDTABLE --
* an 8-entry HARD LIMIT -- with no bounds check of their own, so
* the PARSER is the only thing standing between a script and PCB
* corruption. "2>&8" falls through to the plain-word default,
* exactly as "8>" already does.
*
* Trailing junk ("2>&1X") is a word too, matching the ">X"/"N>X"
* rule every other operator here already follows.
*---------------------------------------------------------------
CLS_DUPTAIL iny                          ;past the '&'
            lda   (PTR0),y
            cmp   #$AD                   ;'-' -- the close form
            beq   :isclose
            cmp   #$B0                   ;'0'-'7' high-bit-set?
            bcc   :notop
            cmp   #$B8                   ;past '7'?
            bcs   :notop
            and   #$0F
            sta   REDIR_SRC
            bra   :ckend
:isclose    lda   #$FF                 ;$FF = "close it", never
            sta   REDIR_SRC              ;  a real fd (0-7)
:ckend      iny
            lda   (PTR0),y
            bne   :notop                 ;"2>&1X" -- a word
            lda   #11
            rts
:notop      lda   #0
            rts

*---------------------------------------------------------------
* LOAD_TOK_PTR -- IN: A = token index. OUT: PTR0 = TOKPTR[A],
* CURQFLAG = TOKQUOTE[A] -- every caller needs the word right
* before deciding whether to expand/glob it, so loading both
* here means WORDEXPAND/GLOB_APPEND never have to be re-handed
* the index themselves (docs/SH-SUBSET.md sec 8.4: the flag
* must be consulted at BOTH of those, and this is the one
* place both call sites already funnel through). CLOBBERS: A,X.
*---------------------------------------------------------------
LOAD_TOK_PTR
            pha
            tax
            lda   TOKQUOTE,x
            sta   CURQFLAG
            pla
            asl   a
            tax
            lda   TOKPTR,x
            sta   PTR0
            lda   TOKPTR+1,x
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* WORDEXPAND -- sh's expansion pass (`$?` today -- the first
* expansion mechanism sh has ever had). Scans the word at PTR0
* for a `$?`; if found, builds the substituted text in the LINE-
* scoped EXPBUF pool (bump-allocated by EXPCUR, reset once per
* line by TOKENIZE -- CMD_ARGV/CMD_INFILE/CMD_OUTFILE all store
* POINTERS into token text rather than copies, so two expanding
* words on one line must not share a single overwritten buffer)
* and repoints PTR0 at it. An ordinary word (no `$?`) costs one
* scan, no copy, no change to PTR0.
*
* Tier 2 (docs/SH-FEATURES.md sec 4) landed exactly where this
* header predicted: DOEXPAND's dispatch on the byte after `$`
* now also recognises a digit (`$0`-`$9`, positional -- an
* argv-table lookup via GETARG), `#` (`$#`, the positional
* count), and a letter (`$NAME`, a name/value table lookup) --
* each still writing through EMITB-shaped helpers into the SAME
* EXPBUF pool. WORDEXPAND's own job -- "does this word need
* expanding at all" -- did not change, only ISEXPCH's (below)
* idea of "at all" grew to match.
*
* Consults CURQFLAG (docs/SH-SUBSET.md sec 8.4): a single-
* quoted word (CURQFLAG=1, "literal") skips this pass entirely
* -- `'$?'` must print `$?`, not the exit status. Bare (0) and
* double-quoted (2) words both still expand -- `"$?"` DOES
* expand, which is the other half of the same proof.
*
* IN: PTR0 = word pointer, CURQFLAG = its quote state (set by
* LOAD_TOK_PTR). OUT: PTR0 unchanged, or repointed at an EXPBUF
* slice. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
WORDEXPAND  stz   EXPSUBST               ;no substitution has
                                         ;happened in THIS word
                                         ;yet (SPLIT_APPEND's
                                         ;split gate)
            stz   DOEXPRAN               ;EMITB_CS's "already
                                         ;marked" flag
            lda   CURQFLAG
            cmp   #1
            bne   :goscan
            rts                          ;single-quoted --
                                         ;literal, no expansion
                                         ;at all
:goscan     ldy   #0
:scan       lda   (PTR0),y
            beq   :none
            cmp   #$A4                   ;'$' high-bit-set
            bne   :adv
            iny
            lda   (PTR0),y
            jsr   ISEXPCH                 ;carry set = '?', '#',
                                          ;a digit, or a letter
            bcs   :yes
            bra   :scan                  ;re-examine the peeked
                                         ;byte -- it may itself
                                         ;start a recognised
                                         ;form
:adv        iny
            bra   :scan
*-- `$(...)` command substitution runs AFTER the `$` pass, as a
*-- second scan over whatever that pass produced (docs/
*-- ANACHRONISMS.md A10, docs/SH-FEATURES.md sec 14). The order
*-- is the whole trick: by the time CMDSUBST looks at the word,
*-- every `$VAR`/`$1`/`$?` INSIDE the parentheses has already
*-- been substituted, so `$(GREP $PAT F)` runs the command the
*-- user meant -- with no re-entrant call into DOEXPAND, which
*-- shares EXPX/EXPSTART globally and could not survive one.
*-- `$(` itself is deliberately NOT in ISEXPCH, so DOEXPAND
*-- passes it through literally (its :dlit path) for CMDSUBST to
*-- find. Both entries land here: a word with no recognised `$`
*-- form at all still has to be scanned for `$(`.
:yes        lda   #1                     ;a recognised form WILL
            sta   EXPSUBST               ;substitute -- ISEXPCH
                                         ;never fires on `$(`,
                                         ;so this is exact
            sta   DOEXPRAN
*-- Resolve $IFS BEFORE expanding: DOEXPAND's :plain marks each
*-- LITERAL separator byte low (EMITB_LIT) so SPLIT_APPEND can
*-- split only what substitution produced -- the manual's rule,
*-- in the file's own bit-7 vocabulary. IFS_RESOLVE owns PTR0
*-- for its lookup, so the word pointer is parked in SPLWORD.
            lda   PTR0
            sta   SPLWORD
            lda   PTR0+1
            sta   SPLWORD+1
            jsr   IFS_RESOLVE
            lda   SPLWORD
            sta   PTR0
            lda   SPLWORD+1
            sta   PTR0+1
            jsr   DOEXPAND
:none       jmp   CMDSUBST
