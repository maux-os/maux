*---------------------------------------------------------------
* makeexp.s -- the ONE macro expander, and the tokenizer
* that splits what it wrote.
*
* Split out of makemac.s for as's 16,128-byte source window
* (check-dialect 3b): as holds the MANIFEST resident and
* streams each `put` one at a time, so the charge is the
* manifest plus the LARGEST put.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_EXPAND -- expand PTR0 into the buffer at PTR1, stopping at
* the NUL or CR that ends the source, or (at nesting level 0
* only) at the ';' that ends a dependency field.
*
* IN:  PTR0 = source, PTR1 = destination, EXP_END = the first
*      address NOT to write (the NUL still goes there).
* OUT: PTR1 = past the last byte written, a NUL at PTR1.
*
* A macro reference PUSHES the source pointer and continues in
* the macro's value, so `A = $(B)` resolves at use and nests.
* MK_EXPDEP bounds the nesting: a makefile can define a macro in
* terms of itself, and it should say so rather than run forever.
* An UNDEFINED macro expands to nothing, which is POSIX and is
* also the only answer that lets `$(CFLAGS)` sit in a rule
* nobody has set flags for.
*---------------------------------------------------------------
MK_EXPAND   stz   EXP_SP
            stz   EXP_LAST
:next       lda   (PTR0)
            bne   :notnul
            lda   EXP_SP
            beq   :fin
            jsr   MK_EXPPOP
            bra   :next
:notnul     cmp   #$8D                ;CR ends the line
            beq   :atend
*-- ';' ends a DEPENDENCY field (the rest is a command) and is
*-- ordinary byte in a recipe; EXP_SEMI is which of the two this
*-- call is, and nesting never ends on one
            cmp   #$BB
            bne   :nostop
            ldx   EXP_SP
            bne   :nostop
            ldx   EXP_SEMI
            bne   :fin
:nostop     cmp   #$DC                ;'\'
            beq   :bslash
            cmp   #$A4                ;'$'
            beq   :dollar
:emit       jsr   MK_EMIT
            jsr   MK_SRCINC
            bra   :next
:atend      lda   EXP_SP
            beq   :fin
            jsr   MK_EXPPOP
            bra   :next
:fin        lda   #0
            sta   (PTR1)
            rts
*-- a backslash is a line continuation only when a CR follows
*-- it; anywhere else it is an ordinary byte, because ProDOS
*-- pathnames have no use for one and a makefile might
:bslash     ldy   #1
            lda   (PTR0),y
            cmp   #$8D
            beq   :contin
            lda   #$DC
            bra   :emit
*-- a continuation joins with ONE space and the next line's own
*-- indentation is dropped. There is no shell here to hand a
*-- backslash-newline to, so a join has to produce the command
*-- the author meant -- and leaving the leading tab in would put
*-- a tab in the middle of every echoed command line.
*-- ...and only if there is not one already: `ZORK one \` ends
*-- in a blank already, and a second shows up in every echoed
*-- command line
:contin     jsr   MK_SRCINC
            jsr   MK_SRCINC
            lda   EXP_LAST
            cmp   #$A0
            beq   :cskip
            cmp   #$89
            beq   :cskip
            lda   #$A0
            jsr   MK_EMIT
:cskip      lda   (PTR0)
            cmp   #$A0
            beq   :cdrop
            cmp   #$89
            bne   :cdone
:cdrop      jsr   MK_SRCINC
            bra   :cskip
:cdone      jmp   :next
:dollar     ldy   #1
            lda   (PTR0),y
            bne   :havech
            jsr   MK_SRCINC           ;a bare '$' at the end of
            bra   :next               ;the text is dropped
:havech     cmp   #$A4                ;'$$' is a literal '$'
            beq   :dollit
            cmp   #$A8                ;'('
            beq   :paren
            cmp   #$FB                ;'{'
            beq   :paren
            jsr   MK_ONECH
            jmp   :next
:dollit     jsr   MK_SRCINC
            lda   #$A4
            jsr   MK_EMIT
            jsr   MK_SRCINC
            jmp   :next
:paren      jsr   MK_PARMAC
            jmp   :next

*---------------------------------------------------------------
* MK_ONECH -- `$X`: a one-character macro name, or one of the
* internal macros. V7: "If string1 is a single character, the
* parentheses are optional."
*---------------------------------------------------------------
MK_ONECH    ldy   #1
            lda   (PTR0),y
            sta   MK_SCRATCH
            stz   MK_SCRATCH+1
            jsr   MK_SRCINC
            jsr   MK_SRCINC
            jmp   MK_MACREF

*---------------------------------------------------------------
* MK_PARMAC -- `$(NAME)` or `${NAME}`. An unterminated reference
* is a diagnostic, not a guess: it is always a typo.
*---------------------------------------------------------------
MK_PARMAC   ldy   #1
            lda   (PTR0),y
            cmp   #$A8                ;'(' -> ')'
            bne   :brace
            lda   #$A9
            bra   :havedelim
:brace      lda   #$FD                ;'}'
:havedelim  sta   MK_DELIM
            jsr   MK_SRCINC           ;past the '$'
            jsr   MK_SRCINC           ;past the bracket
            ldx   #0
:scan       lda   (PTR0)
            beq   MK_BADMAC
            cmp   #$8D
            beq   MK_BADMAC
            cmp   MK_DELIM
            beq   :closed
            cpx   #MK_SCRSZ-1
            bcs   MK_BADMAC
            sta   MK_SCRATCH,x
            inx
            jsr   MK_SRCINC
            bra   :scan
:closed     lda   #0
            sta   MK_SCRATCH,x
            jsr   MK_SRCINC           ;past the bracket
            jmp   MK_MACREF

MK_BADMAC   lda   #<BADMACMSG
            ldx   #>BADMACMSG
            jmp   MK_DIE

*---------------------------------------------------------------
* MK_MACREF -- resolve the name now in MK_SCRATCH. Internal
* macros EMIT; a named macro PUSHES and the expander continues
* inside its value.
*
* PTR0/PTR1 are the expander's own working pointers and both
* lookups clobber them, so they are saved here rather than in
* four callers.
*---------------------------------------------------------------
MK_MACREF   lda   PTR0
            sta   EXP_SV0
            lda   PTR0+1
            sta   EXP_SV0+1
            lda   PTR1
            sta   EXP_SV1
            lda   PTR1+1
            sta   EXP_SV1+1
            lda   MK_SCRATCH+1
            bne   :named              ;longer than one character
            lda   MK_SCRATCH
            cmp   #$C0                ;'@'
            beq   :intern
            cmp   #$BC                ;'<'
            beq   :intern
            cmp   #$AA                ;'*'
            beq   :intern
            cmp   #$BF                ;'?'
            bne   :named
:intern     jsr   MK_RESTORE
            lda   MK_SCRATCH
            jmp   MK_INTERN
:named      lda   #<MK_SCRATCH
            sta   PTR0
            lda   #>MK_SCRATCH
            sta   PTR0+1
            jsr   MK_MACFIND
            bcs   :undef
            lda   PTR1
            sta   EXP_VAL
            lda   PTR1+1
            sta   EXP_VAL+1
            jsr   MK_RESTORE
            jsr   MK_EXPPUSH
            lda   EXP_VAL
            sta   PTR0
            lda   EXP_VAL+1
            sta   PTR0+1
            rts
:undef      jmp   MK_RESTORE

MK_RESTORE  lda   EXP_SV0
            sta   PTR0
            lda   EXP_SV0+1
            sta   PTR0+1
            lda   EXP_SV1
            sta   PTR1
            lda   EXP_SV1+1
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* MK_EXPPUSH / MK_EXPPOP -- the expander's source stack.
*---------------------------------------------------------------
MK_EXPPUSH  ldx   EXP_SP
            cpx   #MK_EXPDEP
            bcs   :deep
            lda   PTR0
            sta   EXP_STKL,x
            lda   PTR0+1
            sta   EXP_STKH,x
            inc   EXP_SP
            rts
:deep       lda   #<DEEPMACMSG
            ldx   #>DEEPMACMSG
            jmp   MK_DIE

MK_EXPPOP   dec   EXP_SP
            ldx   EXP_SP
            lda   EXP_STKL,x
            sta   PTR0
            lda   EXP_STKH,x
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* MK_EMIT -- one byte into the expansion buffer, or die naming
* the buffer rather than running off its end. EXP_END is the
* first address not to write; the NUL still goes there, which is
* why every caller sets it one short of the real end.
*---------------------------------------------------------------
MK_EMIT     pha
            lda   PTR1+1
            cmp   EXP_END+1
            bcc   :ok
            bne   :full
            lda   PTR1
            cmp   EXP_END
            bcc   :ok
:full       pla
            lda   #<LONGMSG
            ldx   #>LONGMSG
            jmp   MK_DIE
:ok         pla
            sta   EXP_LAST
            sta   (PTR1)
            inc   PTR1
            bne   :done
            inc   PTR1+1
:done       rts

MK_SRCINC   inc   PTR0
            bne   :done
            inc   PTR0+1
:done       rts

*---------------------------------------------------------------
* MK_EMITSTR -- emit the NUL-terminated string at PTR2.
*---------------------------------------------------------------
MK_EMITSTR  lda   PTR2
            ora   PTR2+1
            beq   :done               ;an unset internal macro
:loop       lda   (PTR2)              ;is the empty string
            beq   :done
            jsr   MK_EMIT
            inc   PTR2
            bne   :loop
            inc   PTR2+1
            bra   :loop
:done       rts

*---------------------------------------------------------------
* MK_TOKEN -- split the NUL-terminated buffer at PTR2 into
* NUL-separated words in place, counting them into MK_TOKN.
* Spaces AND tabs separate: a continued line joins with a space
* but the continuation's own leading tab arrives as data.
*---------------------------------------------------------------
MK_TOKEN    stz   MK_TOKN
*-- IT COMPACTS. A run of blanks used to become a RUN OF NULS,
*-- and every "next name" walk (MK_SKIPNM, MK_SKIPP2) then
*-- landed on the second NUL and read an EMPTY name -- which
*-- make reported as `no rule to make target `. A continued
*-- dependency line is the shape that makes the run (the blank
*-- before the backslash, then the join), so it was invisible
*-- until `\` was tested. Copying the words down means the
*-- separator is one NUL by construction and no walker has to
*-- know. The destination never overtakes the source, so this is
*-- safe in place; MK_TOK1 is the first word, which after
*-- compaction is the buffer's own first byte.
            lda   PTR2
            sta   PTR0
            sta   MK_TOK1
            lda   PTR2+1
            sta   PTR0+1
            sta   MK_TOK1+1
:skip       lda   (PTR2)
            beq   :done
            cmp   #$A0
            beq   :adv
            cmp   #$89
            bne   :word
:adv        jsr   MK_TOKINC
            bra   :skip
:word       lda   MK_TOKN
            cmp   #MK_MAXDEP
            bcs   :toomany
            inc   MK_TOKN
:wcopy      lda   (PTR2)
            beq   :endw
            cmp   #$A0
            beq   :endw
            cmp   #$89
            beq   :endw
            sta   (PTR0)
            jsr   MK_TOKINC
            jsr   MK_DSTINC
            bra   :wcopy
*-- step the SOURCE over the delimiter before terminating the
*-- destination: when nothing has been compacted yet the two
*-- pointers are equal, and writing the NUL first would put
*-- it under the source cursor
:endw       lda   (PTR2)
            beq   :term
            jsr   MK_TOKINC
:term       lda   #0
            sta   (PTR0)
            jsr   MK_DSTINC
            bra   :skip
:done       lda   #0
            sta   (PTR0)
            rts
:toomany    lda   #<TOOMANYMSG
            ldx   #>TOOMANYMSG
            jmp   MK_DIE

MK_DSTINC   inc   PTR0
            bne   :done
            inc   PTR0+1
:done       rts

MK_TOKINC   inc   PTR2
            bne   :done
            inc   PTR2+1
:done       rts

MANYMACMSG  asc   "make: too many macros"
            dfb   $8D,$00
BADMACMSG   asc   "make: unterminated macro reference"
            dfb   $8D,$00
DEEPMACMSG  asc   "make: macro expands into itself"
            dfb   $8D,$00
LONGMSG     asc   "make: expanded line too long"
            dfb   $8D,$00
