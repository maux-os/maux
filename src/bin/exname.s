*---------------------------------------------------------------
* exname.s -- ex's command-NAME table and operand-class check
* (docs/EX-BADCMD.md). `put` by ex.s and vi.s ONLY, right after
* excmd2.s; ed never assembles it (ed keeps V7's one-letter
* dispatch, edparse.s untouched).
*
* THE BUG THIS REPLACES. The ed-derived dispatcher took ONE byte
* at ED_CMDPTR as the verb and ignored the rest, so `:cxyz` ran
* CHANGE (and sat in line-input mode with no message), `:dxyz`
* deleted the current line, `:wxyz` wrote the file. POSIX ex
* reads a command NAME -- the run of letters -- and refuses a
* name that is not a command or an abbreviation of one.
*
* HOW IT WORKS. EX_CMD calls EX_NAME first. EX_NAME takes the
* run of letters at ED_CMDPTR (after any blanks) as the WORD,
* looks it up in EXN_TAB as a prefix of a full name no shorter
* than that row's minimum, and REWRITES the word in place to the
* canonical one- or two-byte spelling the old handlers already
* understand: `delete` -> blanks + `d`, `substitute` -> `s`,
* `number` -> `#`, `copy` -> `t`, `mark`/`ma` -> `k` (its
* operand follows), `wq` stays `wq`. ED_CMDPTR then points at
* the
* canonical byte, so every handler downstream (EX_CMD's own
* switch, then edparse.s's one-letter chain) runs unchanged. The
* rewrite is IDEMPOTENT -- the word is right-aligned behind
* blanks, and blanks before a command are skipped -- which a g/v
* command list needs: edparse.s re-parses the saved text once
* per marked line.
*
* THEN THE OPERAND CLASS (last byte of a table row) is checked
* against what follows the verb, because the one-letter handlers
* never looked: `2d3`, `p#`, `2=x`, `1zx` all used to succeed
* with the junk ignored. Class 0 = the handler parses its own
* operand (s g v r w e m t k); 1 = nothing may follow; 2 = an
* immediate `!` may follow, then nothing (q wq x a i c); 3 =
* only
* digits (z); 4 = as 0, but the blanks between the word and its
* operand are folded into the word, so the verb lands ADJACENT
* to
* the address (m t) or mark letter (k) that its handler reads at
* byte 1. Classes 1-2 also normalise the tail: a NUL is
* written right after the verb (or its `!`), so the handlers'
* own "byte 1 is NUL" tests (u, x, q, wq) see exactly that.
*
* A word that is not a name, or whose letters are fewer than the
* row's minimum, is refused "word: Not an editor command"; a bad
* tail "Trailing characters". EX_ERRMSG records the text for vi
* (EX_MSGP, shown on the status line by VI_COLON), prints it in
* interactive ex, and stays silent for a script (stdin not a tty
* -- POSIX `ex -s`, exactly as ED_ERR does for its `?`). Both
* set
* ED_ERRSTAT, so the exit status is nonzero.
*
* Not table rows, left to the old chain: `!` `&` and every other
* non-letter first byte (ED_ERR's `?`). `k` and `=` `#` take a
* word of exactly ONE byte -- `kx` is mark x, not a name `kx`.
* NAMES NOT IMPLEMENTED (append is there; abbreviate, args,
* file,
* map, next, put, set, yank, ...) are simply absent, so they are
* refused rather than misread as a verb they merely begin with:
* `set` used to be a substitute with `e` as its delimiter.
*
* Table row = name (high-bit ASCII), NUL, minimum length, canon
* byte 1, canon byte 2 (0 = none), class. A row for a name that
* is another's prefix (`co` vs `change`) is fine -- the word
* must
* be a prefix of the NAME, so `co` cannot be `change`.
*---------------------------------------------------------------

EXN_MSGLEN  equ   12        ;most word bytes echoed in a message

*---------------------------------------------------------------
* EX_NAME -- see the header. IN: ED_CMDPTR at the first byte of
* the command text, which is non-NUL. OUT (rts): ED_CMDPTR at
* the
* canonical verb, or untouched if the first byte is not a letter
* (or `=` `#`). A refusal never returns: it reports, drops
* EX_CMD's
* and the dispatcher's return addresses, and `jmp MAINLOOP`s.
* CLOBBERS: A, X, Y, PTR1, PTR2, EXN_WLEN, EXN_N.
*---------------------------------------------------------------
EX_NAME     ldy   #0
:en_blank   lda   (ED_CMDPTR),y
            cmp   #" "
            bne   :en_skipd
            iny
            bne   :en_blank
:en_skipd   tax             ;X = first byte after the blanks
            bne   :en_start
:en_leave   rts                   ;nothing there: not ours
:en_start   tya
            beq   :en_noadv
            clc
            adc   ED_CMDPTR       ;ED_CMDPTR past the blanks
            sta   ED_CMDPTR
            bcc   :en_noadv
            inc   ED_CMDPTR+1
:en_noadv   cpx   #"k"      ;`kx` = mark x: a one-byte word
            beq   :en_one
            cpx   #"="
            beq   :en_one
            cpx   #"#"
            beq   :en_one
            txa
            and   #$DF            ;fold case: letters $C1-$DA
            cmp   #$C1
            bcc   :en_leave
            cmp   #$DB
            bcs   :en_leave
            ldy   #1
:en_run     lda   (ED_CMDPTR),y
            and   #$DF
            cmp   #$C1
            bcc   :en_wend
            cmp   #$DB
            bcs   :en_wend
            iny
            cpy   #16
            bcc   :en_run
:en_wend    bra   :en_have
:en_one     ldy   #1
:en_have    sty   EXN_WLEN
            lda   #<EXN_TAB
            sta   PTR1
            lda   #>EXN_TAB
            sta   PTR1+1
:en_row     lda   (PTR1)
            bne   :en_hasrow
            jmp   :en_bad         ;end of table: not a command
:en_hasrow  ldy   #0
:en_cmp     cpy   EXN_WLEN
            beq   :en_pfx
            lda   (PTR1),y
            cmp   (ED_CMDPTR),y
            bne   :en_mis
            iny
            bra   :en_cmp
:en_pfx     ldx   #0        ;the word is a prefix of the name
            bra   :en_seek
:en_mis     ldx   #1
:en_seek    lda   (PTR1),y        ;find the name's NUL
            beq   :en_nul
            iny
            bne   :en_seek
:en_nul     tya
            sec                   ;+1 steps over the NUL
            adc   PTR1
            sta   PTR1
            bcc   :en_nc
            inc   PTR1+1
:en_nc      txa
            beq   :en_found       ;PTR1 -> this row's minimum
            lda   PTR1
            clc
            adc   #4              ;min, canon 1, canon 2, class
            sta   PTR1
            bcc   :en_row
            inc   PTR1+1
            bra   :en_row
:en_found   ldy   #0
            lda   EXN_WLEN
            cmp   (PTR1),y  ;fewer letters than the minimum?
            bcs   :en_long
            jmp   :en_bad
:en_long    ldy   #3
            lda   (PTR1),y
            cmp   #4        ;class 4: the operand is an address
            bne   :en_noext ;or a mark letter the handler wants
:en_ext     ldy   EXN_WLEN  ;ADJACENT -- fold the blanks that
            lda   (ED_CMDPTR),y ;follow the word into it, so the
            cmp   #" "      ;verb is rewritten right behind
            bne   :en_noext       ;the operand (`t 3` -> `t3`)
            inc   EXN_WLEN
            bra   :en_ext
:en_noext   ldx   #1              ;X = n, the canonical length
            ldy   #2
            lda   (PTR1),y
            pha                   ;canon byte 2 (0 = none)
            beq   :en_n1
            inx
:en_n1      stx   EXN_N
            dey
            lda   (PTR1),y
            pha                   ;canon byte 1
            lda   EXN_WLEN
            sec
            sbc   EXN_N
            sta   EXN_WLEN        ;d = blanks to lay down first
            ldy   #0
            lda   #" "
:en_fill    cpy   EXN_WLEN
            beq   :en_filled
            sta   (ED_CMDPTR),y
            iny
            bra   :en_fill
:en_filled  pla
            sta   (ED_CMDPTR),y ;the canonical verb,
            iny
            pla
            beq   :en_placed
            sta   (ED_CMDPTR),y
:en_placed  lda   EXN_WLEN
            clc
            adc   ED_CMDPTR ;ED_CMDPTR -> the canonical verb
            sta   ED_CMDPTR
            bcc   :en_cls
            inc   ED_CMDPTR+1
:en_cls     ldy   #3
            lda   (PTR1),y        ;operand class
            beq   :en_ok
            cmp   #4
            bcs   :en_ok
            tax
            ldy   EXN_N
            cpx   #3
            beq   :en_dig
            lda   (ED_CMDPTR),y
            cmp   #"!"
            bne   :en_blk
            cpx   #2
            bne   :en_trbad ;a bang this verb does not take
            iny                   ;the bang sits right after it
:en_blk     sty   EXN_N           ;the NUL goes here
:en_trl     lda   (ED_CMDPTR),y
            beq   :en_trend
            cmp   #" "
            bne   :en_trbad
            iny
            bne   :en_trl
:en_trend   lda   #0
            ldy   EXN_N
            sta   (ED_CMDPTR),y
:en_ok      rts
:en_dig     lda   (ED_CMDPTR),y
            beq   :en_ok
            cmp   #"0"
            bcc   :en_trbad
            cmp   #"9"+1
            bcs   :en_trbad
            iny
            bne   :en_dig
:en_trbad   lda   #1
            bra   :en_fail
:en_bad     lda   #0
:en_fail    jsr   EX_ERRMSG
            pla             ;drop EX_NAME's caller, EX_CMD,
            pla             ;and the dispatcher's own return
            pla                   ;address: every command ends
            pla                   ;`jmp MAINLOOP`, never `rts`
            jmp   MAINLOOP

*---------------------------------------------------------------
* EX_ERRMSG -- refuse the current command WITH a message. IN:
* A =
* 0 for "<word>: Not an editor command" (the word is EXN_WLEN
* bytes at ED_CMDPTR, shown up to EXN_MSGLEN of them), 1 for
* "Trailing characters". Sets ED_ERRSTAT, leaves the text in
* EX_MSGBUF with EX_MSGP pointing at it (vi's status line reads
* that after its repaint), and prints it only for an interactive
* ex: ED_D1FLAG set means vi's `:` bridge; stdin not a tty means
* a script, which stays silent like ED_ERR's `?`. CLOBBERS: A,
* X, Y, PTR0, PTR2.
*---------------------------------------------------------------
EX_ERRMSG   ldx   #1
            stx   ED_ERRSTAT
            ldx   #0
            cmp   #0
            bne   :em_tail
            ldy   #0
:em_word    cpy   EXN_WLEN
            beq   :em_wdone
            cpy   #EXN_MSGLEN
            beq   :em_wdone
            lda   (ED_CMDPTR),y
            sta   EX_MSGBUF,y
            iny
            bra   :em_word
:em_wdone   lda   #":"
            sta   EX_MSGBUF,y
            iny
            lda   #" "
            sta   EX_MSGBUF,y
            iny
            tya
            tax
            lda   #<EXN_MNOCMD
            sta   PTR2
            lda   #>EXN_MNOCMD
            bra   :em_copy
:em_tail    lda   #<EXN_MTRAIL
            sta   PTR2
            lda   #>EXN_MTRAIL
:em_copy    sta   PTR2+1
            ldy   #0
:em_cp      lda   (PTR2),y
            sta   EX_MSGBUF,x
            beq   :em_cdone
            inx
            iny
            bra   :em_cp
:em_cdone   lda   #<EX_MSGBUF
            sta   EX_MSGP
            sta   PTR0
            lda   #>EX_MSGBUF
            sta   EX_MSGP+1
            sta   PTR0+1
            lda   ED_D1FLAG
            bne   :em_done        ;vi: shown after its repaint
            lda   #0
            jsr   SC_FDSTAT       ;stdin a tty?
            bcs   :em_show
            bmi   :em_show        ;device: interactive, say it
            rts                   ;script: status only, no text
:em_show    ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:em_done    rts

EXN_MNOCMD  asc   "Not an editor command"
            dfb   0
EXN_MTRAIL  asc   "Trailing characters"
            dfb   0

*---------------------------------------------------------------
* EXN_TAB -- see the header for the row layout. Order only
* matters between names where one word could be a prefix of two:
* none is, by construction (`m` move vs `ma` mark, `s` vs `su`
* are told apart by the minimum and the next letter).
*---------------------------------------------------------------
EXN_TAB     asc   "append"
            dfb   0,1,"a",0,2
            asc   "change"
            dfb   0,1,"c",0,2
            asc   "copy"
            dfb   0,2,"t",0,4
            asc   "delete"
            dfb   0,1,"d",0,1
            asc   "edit"
            dfb   0,1,"e",0,0
            asc   "global"
            dfb   0,1,"g",0,0
            asc   "insert"
            dfb   0,1,"i",0,2
            asc   "join"
            dfb   0,1,"j",0,1
            asc   "k"
            dfb   0,1,"k",0,4
            asc   "list"
            dfb   0,1,"l",0,1
            asc   "move"
            dfb   0,1,"m",0,4
            asc   "mark"
            dfb   0,2,"k",0,4
            asc   "number"
            dfb   0,2,"#",0,1
            asc   "print"
            dfb   0,1,"p",0,1
            asc   "quit"
            dfb   0,1,"q",0,2
            asc   "read"
            dfb   0,1,"r",0,0
            asc   "substitute"
            dfb   0,1,"s",0,0
            asc   "t"
            dfb   0,1,"t",0,4
            asc   "undo"
            dfb   0,1,"u",0,1
            asc   "vglobal"
            dfb   0,1,"v",0,0
            asc   "write"
            dfb   0,1,"w",0,0
            asc   "wq"
            dfb   0,2,"w","q",2
            asc   "xit"
            dfb   0,1,"x",0,2
            asc   "z"
            dfb   0,1,"z",0,3
            asc   "="
            dfb   0,1,"=",0,1
            asc   "#"
            dfb   0,1,"#",0,1
            dfb   0
