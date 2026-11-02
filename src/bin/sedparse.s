*---------------------------------------------------------------
* sedparse.s -- sed's script compiler, `put` by src/bin/sed.s
* (NOT a standalone binary). Compiles SCRIPTBUF (high-bit text,
* CR line ends, NUL-terminated) into the CA1T..CWFD arrays,
* one entry per command, indexed by command number. Strings a
* command needs at run time (REs, replacements, a/i/c text, y
* strings, filenames) are NUL-split IN PLACE inside SCRIPTBUF
* and pointed at. Any syntax the grammar in sed.s's header does
* not admit is a LOUD BADSCRIPT (does not return). The cursor
* is SD_SP, a zero-page pointer: the script is up to SCRMAX
* bytes, past 8-bit indexing.
*---------------------------------------------------------------
PARSESCRIPT lda   #<SCRIPTBUF
            sta   SD_SP
            lda   #>SCRIPTBUF
            sta   SD_SP+1
            stz   BLKDEPTH
PS_LOOP     jsr   SKIPSEP            ;blanks, CRs, ';'
            lda   (SD_SP)
            beq   PS_DONE
            cmp   #"#"
            bne   :cmd
            jsr   SKIPLINE
            bra   PS_LOOP
:cmd        jsr   PARSECMD
            bra   PS_LOOP
PS_DONE     lda   BLKDEPTH
            beq   :ok
            lda   #E_BRACE
            jmp   BADSCRIPT
:ok         jmp   RESOLVE

* -- cursor helpers --
SPINC       inc   SD_SP
            bne   :r
            inc   SD_SP+1
:r          rts

DSTINC      inc   SD_DST
            bne   :r
            inc   SD_DST+1
:r          rts

* -- SKIPBL: blanks and tabs.
SKIPBL      lda   (SD_SP)
            cmp   #$A0
            beq   :go
            cmp   #$89
            bne   :out
:go         jsr   SPINC
            bra   SKIPBL
:out        rts

* -- SKIPSEP: blanks, tabs, CRs and ';' (empty commands ok).
SKIPSEP     lda   (SD_SP)
            cmp   #$A0
            beq   :go
            cmp   #$89
            beq   :go
            cmp   #$8D
            beq   :go
            cmp   #$BB
            bne   :out
:go         jsr   SPINC
            bra   SKIPSEP
:out        rts

* -- SKIPLINE: to just past the next CR (or to the NUL).
SKIPLINE    lda   (SD_SP)
            beq   :out
            cmp   #$8D
            beq   :eat
            jsr   SPINC
            bra   SKIPLINE
:eat        jmp   SPINC
:out        rts

*---------------------------------------------------------------
* PARSECMD -- one command into entry NCMDS.
*---------------------------------------------------------------
PARSECMD    ldx   NCMDS
            cpx   #SED_MAXCMD
            bcc   :room
            lda   #E_TOOMANY
            jmp   BADSCRIPT
:room       stz   CA1T,x
            stz   CA2T,x
            stz   CFLG,x
            stz   CNUML,x
            stz   CNUMH,x
            stz   CACT,x
            stz   CP1L,x
            stz   CP1H,x
            stz   CP2L,x
            stz   CP2H,x
            stz   CWFD,x
            stz   ADDRFLD
            jsr   PARSEADDR
            jsr   SKIPBL
            lda   (SD_SP)
            cmp   #$AC               ;','
            bne   :noa2
            ldx   NCMDS
            lda   CA1T,x
            bne   :a2go
            jmp   PS_EADDR           ;',' with no addr1
:a2go       jsr   SPINC
            jsr   SKIPBL
            lda   #1
            sta   ADDRFLD
            jsr   PARSEADDR
            ldx   NCMDS
            lda   CA2T,x
            bne   :noa2
            jmp   PS_EADDR           ;',' with no addr2
:noa2       jsr   SKIPBL
:bang       lda   (SD_SP)
            cmp   #"!"
            bne   :verb
            ldx   NCMDS
            lda   CFLG,x
            ora   #SF_NEG
            sta   CFLG,x
            jsr   SPINC
            jsr   SKIPBL
            bra   :bang
:verb       lda   (SD_SP)
            jsr   VLOOKUP
            bcc   :known
            lda   #E_CMD
            jmp   BADSCRIPT
:known      ldx   NCMDS
            sta   CVERB,x
            jsr   SPINC
            asl   a
            tax
            jmp   (PTAB,x)

PS_EADDR    lda   #E_ADDR
            jmp   BADSCRIPT

* -- PS_TERM: after a command's own syntax: blanks, then NUL,
* -- CR or ';' (consumed), or '}' (left for PS_LOOP).
PS_TERM     jsr   SKIPBL
            lda   (SD_SP)
            beq   PS_EOL
            cmp   #$8D
            beq   :eat
            cmp   #$BB
            beq   :eat
            cmp   #$FD               ;'}'
            beq   PS_EOL
            lda   #E_EXTRA
            jmp   BADSCRIPT
:eat        jsr   SPINC
* -- PS_EOL: the command consumed its own line end.
PS_EOL      inc   NCMDS
            rts

* -- VLOOKUP: A = char -> A = verb code, carry clear; carry
* -- set if not a verb.
VLOOKUP     ldy   #0
:lp         cmp   VCHARS,y
            beq   :hit
            iny
            lda   VCHARS,y
            beq   :no
            lda   (SD_SP)
            bra   :lp
:hit        tya
            clc
            rts
:no         sec
            rts

* -- per-verb argument parsers, indexed by verb code --
PTAB        da    P_LBRACE,P_RBRACE,P_TEXT,P_BR
            da    P_TEXT,P_NONE,P_NONE,P_NONE
            da    P_NONE,P_NONE,P_NONE,P_NONE
            da    P_TEXT,P_NONE,P_NONE,P_NONE
            da    P_NONE,P_NONE,P_Q,P_FILE
            da    P_S,P_BR,P_FILE,P_NONE
            da    P_Y,P_LABEL

P_NONE      jmp   PS_TERM

*---------------------------------------------------------------
* PARSEADDR -- optional address at SD_SP into entry NCMDS's
* first (ADDRFLD=0) or second (ADDRFLD=1) address. Leaves the
* type 0 if no address starts here.
*---------------------------------------------------------------
PARSEADDR   lda   (SD_SP)
            cmp   #"$"
            beq   :dollar
            cmp   #"/"
            beq   :slash
            cmp   #"\"
            beq   :bsl
            cmp   #"0"
            bcc   :none
            cmp   #"9"+1
            bcs   :none
            jsr   PARSENUM
            lda   SD_NUM
            ora   SD_NUM+1
            bne   :numok
            jmp   PS_EADDR           ;address 0 does not exist
:numok      lda   #1
            bra   STOREADDR
:dollar     jsr   SPINC
            lda   #3
            bra   STOREADDR
:slash      lda   #"/"
            sta   SD_CH
            bra   :re
:bsl        jsr   SPINC              ;\cREc
            lda   (SD_SP)
            beq   :unterm
            cmp   #$8D
            beq   :unterm
            sta   SD_CH
:re         jsr   SPINC
            lda   SD_SP
            sta   SD_NUM
            lda   SD_SP+1
            sta   SD_NUM+1
            jsr   CUTRE
            lda   (SD_NUM)           ;empty RE: the last one
            bne   :reok              ;used, at run time
            stz   SD_NUM
            stz   SD_NUM+1
:reok       lda   #2
            bra   STOREADDR
:unterm     lda   #E_UNTERM
            jmp   BADSCRIPT
:none       rts

* -- STOREADDR: A = type, SD_NUM = value -> the ADDRFLD slot.
STOREADDR   ldx   NCMDS
            ldy   ADDRFLD
            bne   :second
            sta   CA1T,x
            lda   SD_NUM
            sta   CA1VL,x
            lda   SD_NUM+1
            sta   CA1VH,x
            rts
:second     sta   CA2T,x
            lda   SD_NUM
            sta   CA2VL,x
            lda   SD_NUM+1
            sta   CA2VH,x
            rts

*---------------------------------------------------------------
* CUTRE -- scan an RE from SD_SP to the next unescaped SD_CH
* delimiter, store a NUL over it, leave SD_SP just past it.
* '\X' skips both bytes; a bracket expression is skipped whole
* (the delimiter is literal inside [...], POSIX), honouring the
* leading ']' / '^]' rule regex2.s applies. Running into the
* script's NUL first is E_UNTERM (does not return).
* CUTPLAIN -- the same without the bracket rule (replacement
* text, y strings).
*---------------------------------------------------------------
CUTRE       lda   (SD_SP)
            bne   :nz
            jmp   CUT_UNT
:nz         cmp   SD_CH
            bne   :ncut
            jmp   CUT_CUT
:ncut       cmp   #"\"
            beq   :esc
            cmp   #"["
            beq   :brk
:adv        jsr   SPINC
            bra   CUTRE
:esc        jsr   SPINC
            lda   (SD_SP)
            beq   CUT_UNT
            bra   :adv
:brk        jsr   SPINC
            lda   (SD_SP)
            cmp   #"^"
            bne   :nb
            jsr   SPINC
            lda   (SD_SP)
:nb         cmp   #"]"
            bne   :bscan
            jsr   SPINC
:bscan      lda   (SD_SP)
            bne   :bs1
            jmp   CUT_UNT
:bs1        cmp   #"]"
            beq   :adv
            cmp   #"["               ;[:name:] [=c=] [.c.]: the
            bne   :bnext             ;']' does not close (W5d)
            jsr   SPINC
            lda   (SD_SP)
            cmp   #":"
            beq   :btok
            cmp   #"="
            beq   :btok
            cmp   #"."
            bne   :bscan
:btok       sta   SD_CNT             ;the token's delimiter
:bfind      jsr   SPINC
            lda   (SD_SP)
            bne   :bf1
            jmp   CUT_UNT
:bf1        cmp   SD_CNT
            bne   :bfind
            jsr   SPINC
            lda   (SD_SP)
            cmp   #"]"
            bne   :bfind
:bnext      jsr   SPINC
            bra   :bscan

CUTPLAIN    lda   (SD_SP)
            beq   CUT_UNT
            cmp   SD_CH
            beq   CUT_CUT
            cmp   #"\"
            bne   :adv
            jsr   SPINC
            lda   (SD_SP)
            beq   CUT_UNT
:adv        jsr   SPINC
            bra   CUTPLAIN

CUT_CUT     lda   #0
            sta   (SD_SP)
            jmp   SPINC
CUT_UNT     lda   #E_UNTERM
            jmp   BADSCRIPT

*---------------------------------------------------------------
* PARSENUM -- decimal at SD_SP -> SD_NUM (16-bit), SD_SP past
* the digits. A value that will not fit 16 bits is a LOUD
* E_ADDR, never a silent wrap.
*---------------------------------------------------------------
PARSENUM    stz   SD_NUM
            stz   SD_NUM+1
:lp         lda   (SD_SP)
            cmp   #"0"
            bcc   :done
            cmp   #"9"+1
            bcs   :done
            and   #$0F
            pha
            lda   SD_NUM             ;SD_NUM *= 10
            sta   SD_TMP
            lda   SD_NUM+1
            sta   SD_TMP+1
            asl   SD_NUM
            rol   SD_NUM+1
            bcs   :ovf
            asl   SD_NUM
            rol   SD_NUM+1
            bcs   :ovf
            clc
            lda   SD_NUM
            adc   SD_TMP
            sta   SD_NUM
            lda   SD_NUM+1
            adc   SD_TMP+1
            sta   SD_NUM+1
            bcs   :ovf
            asl   SD_NUM
            rol   SD_NUM+1
            bcs   :ovf
            pla
            clc
            adc   SD_NUM
            sta   SD_NUM
            lda   SD_NUM+1
            adc   #0
            sta   SD_NUM+1
            bcs   :ovf2
            jsr   SPINC
            bra   :lp
:done       rts
:ovf        pla
:ovf2       jmp   PS_EADDR

*---------------------------------------------------------------
* { and } -- '{' records itself on BLKSTK; '}' pops it and
* stores the command number after the '}' as the '{' entry's
* skip target (CP1). '}' takes no address.
*---------------------------------------------------------------
P_LBRACE    ldx   BLKDEPTH
            cpx   #MAXBLK
            bcc   :ok
            lda   #E_BRACE
            jmp   BADSCRIPT
:ok         lda   NCMDS
            sta   BLKSTK,x
            inc   BLKDEPTH
            jmp   PS_EOL             ;a command may follow at
                                     ;once: 2{p;}

P_RBRACE    ldx   NCMDS
            lda   CA1T,x
            beq   :noaddr
            jmp   PS_EADDR
:noaddr     lda   BLKDEPTH
            bne   :open
            lda   #E_BRACE
            jmp   BADSCRIPT
:open       dec   BLKDEPTH
            ldy   BLKDEPTH
            ldx   BLKSTK,y
            lda   NCMDS
            clc
            adc   #1
            sta   CP1L,x
            stz   CP1H,x
            jmp   PS_TERM

*---------------------------------------------------------------
* a, i, c -- text. Both spellings: POSIX `a\` + newline + text
* lines (an embedded newline is preceded by '\'; other '\' are
* removed and the next char taken literally; leading blanks of
* text lines are KEPT), and the one-line `a text` (leading
* blanks dropped) or `a\text` (kept). The text is compacted in
* place; CP1 points at it.
*---------------------------------------------------------------
P_TEXT      jsr   SKIPBL
            lda   (SD_SP)
            cmp   #"\"
            bne   :start
            jsr   SPINC
            lda   (SD_SP)
            cmp   #$8D
            bne   :start             ;a\text: text starts here
            jsr   SPINC              ;a\ newline: lines follow
:start      ldx   NCMDS
            lda   SD_SP
            sta   CP1L,x
            sta   SD_DST
            lda   SD_SP+1
            sta   CP1H,x
            sta   SD_DST+1
:lp         lda   (SD_SP)
            beq   :fin
            cmp   #$8D
            beq   :eol
            cmp   #"\"
            bne   :put
            jsr   SPINC              ;\X -> X (\CR -> CR)
            lda   (SD_SP)
            beq   :fin
:put        sta   (SD_DST)
            jsr   DSTINC
            jsr   SPINC
            bra   :lp
:eol        jsr   SPINC              ;consume the line end
:fin        lda   #0
            sta   (SD_DST)
            jmp   PS_EOL

*---------------------------------------------------------------
* b, t -- optional label to CR/';'/'}'/NUL. Empty = end of
* script (CP1 = $FFFF, RESOLVE turns it into NCMDS). A name is
* stored as a pointer with SF_LABREF set; RESOLVE binds it.
*---------------------------------------------------------------
P_BR        jsr   SKIPBL
            lda   (SD_SP)
            beq   :end
            cmp   #$8D
            beq   :end
            cmp   #$BB
            beq   :end
            cmp   #$FD
            beq   :end
            jsr   RDLABEL
            ldx   NCMDS
            lda   SD_TMP
            sta   CP1L,x
            lda   SD_TMP+1
            sta   CP1H,x
            lda   CFLG,x
            ora   #SF_LABREF
            sta   CFLG,x
            jmp   PS_EOL
:end        ldx   NCMDS
            lda   #$FF
            sta   CP1L,x
            sta   CP1H,x
            jmp   PS_TERM

*---------------------------------------------------------------
* : -- define a label (no address). Duplicates refused.
*---------------------------------------------------------------
P_LABEL     ldx   NCMDS
            lda   CA1T,x
            beq   :noaddr
            jmp   PS_EADDR
:noaddr     jsr   SKIPBL
            jsr   RDLABEL
            bcc   :named
            lda   #E_LABEL
            jmp   BADSCRIPT
:named      ldx   #0
:dup        cpx   NLAB
            bcs   :new
            lda   LABPL,x
            sta   PTR0
            lda   LABPH,x
            sta   PTR0+1
            lda   SD_TMP
            sta   PTR1
            lda   SD_TMP+1
            sta   PTR1+1
            jsr   STRCMP
            cmp   #0
            bne   :next
            lda   #E_DUPLAB
            jmp   BADSCRIPT
:next       inx
            bra   :dup
:new        cpx   #MAXLAB
            bcc   :room
            lda   #E_LABFULL
            jmp   BADSCRIPT
:room       lda   SD_TMP
            sta   LABPL,x
            lda   SD_TMP+1
            sta   LABPH,x
            lda   NCMDS
            sta   LABIDX,x
            inc   NLAB
            jmp   PS_EOL

* -- RDLABEL: SD_TMP := SD_SP; scan to CR/';'/NUL, trim
* -- trailing blanks, NUL-terminate, consume the terminator.
* -- carry set = empty label.
RDLABEL     lda   SD_SP
            sta   SD_TMP
            lda   SD_SP+1
            sta   SD_TMP+1
:scan       lda   (SD_SP)
            beq   :term
            cmp   #$8D
            beq   :term
            cmp   #$BB
            beq   :term
            jsr   SPINC
            bra   :scan
:term       pha                      ;the terminator
            lda   SD_SP
            sta   SD_WK
            lda   SD_SP+1
            sta   SD_WK+1
:trim       lda   SD_WK
            cmp   SD_TMP
            bne   :back
            lda   SD_WK+1
            cmp   SD_TMP+1
            beq   :trimmed
:back       lda   SD_WK
            bne   :nb
            dec   SD_WK+1
:nb         dec   SD_WK
            lda   (SD_WK)
            cmp   #$A0
            beq   :blank
            cmp   #$89
            beq   :blank
            inc   SD_WK
            bne   :trimmed
            inc   SD_WK+1
            bra   :trimmed
:blank      lda   #0
            sta   (SD_WK)
            bra   :trim
:trimmed    lda   #0
            sta   (SD_WK)
            pla
            beq   :noeat
            jsr   SPINC
:noeat      lda   (SD_TMP)
            beq   :empty
            clc
            rts
:empty      sec
            rts

* -- RDTOEOL: SD_TMP := SD_SP; the rest of the line verbatim,
* -- NUL-terminated, CR consumed. carry set = empty.
RDTOEOL     lda   SD_SP
            sta   SD_TMP
            lda   SD_SP+1
            sta   SD_TMP+1
:scan       lda   (SD_SP)
            beq   :nul
            cmp   #$8D
            beq   :cr
            jsr   SPINC
            bra   :scan
:cr         lda   #0
            sta   (SD_SP)
            jsr   SPINC
:nul        lda   (SD_TMP)
            beq   :empty
            clc
            rts
:empty      sec
            rts

*---------------------------------------------------------------
* r, w -- filename: the rest of the line. w files are pooled
* in WFTAB (one fd per distinct name); CP1 = the pool index
* for w, the name pointer for r.
*---------------------------------------------------------------
P_FILE      jsr   SKIPBL
            jsr   RDTOEOL
            bcc   :named
            jmp   P_EFILE
:named      ldx   NCMDS
            lda   CVERB,x
            cmp   #V_W
            beq   :wfile
            lda   SD_TMP
            sta   CP1L,x
            lda   SD_TMP+1
            sta   CP1H,x
            jmp   PS_EOL
:wfile      jsr   WFADD
            ldx   NCMDS
            sta   CP1L,x
            jmp   PS_EOL
P_EFILE     lda   #E_FILE
            jmp   BADSCRIPT

* -- WFADD: the name at SD_TMP -> its WFTAB index in A (added
* -- if new).
WFADD       ldx   #0
:lp         cpx   NWF
            bcs   :new
            lda   WFPL,x
            sta   PTR0
            lda   WFPH,x
            sta   PTR0+1
            lda   SD_TMP
            sta   PTR1
            lda   SD_TMP+1
            sta   PTR1+1
            jsr   STRCMP
            cmp   #0
            beq   :have
            inx
            bra   :lp
:new        cpx   #MAXWF
            bcc   :room
            lda   #E_WOPEN
            jmp   BADSCRIPT
:room       lda   SD_TMP
            sta   WFPL,x
            lda   SD_TMP+1
            sta   WFPH,x
            inc   NWF
:have       txa
            rts

*---------------------------------------------------------------
* s -- s/re/repl/flags. Any delimiter but newline and '\'.
* An empty RE means the last RE used (CP1 = 0). Flags: g, p,
* a number (the Nth match; with g, the Nth and every later
* one), and w FILE, which runs to the end of the line.
*---------------------------------------------------------------
P_S         lda   (SD_SP)
            beq   :unt
            cmp   #$8D
            beq   :unt
            cmp   #"\"
            bne   :delim
:unt        lda   #E_UNTERM
            jmp   BADSCRIPT
:delim      sta   SD_CH
            jsr   SPINC
            ldx   NCMDS
            lda   SD_SP
            sta   CP1L,x
            sta   SD_TMP
            lda   SD_SP+1
            sta   CP1H,x
            sta   SD_TMP+1
            jsr   CUTRE
            lda   (SD_TMP)
            bne   :pat
            ldx   NCMDS              ;empty: last RE at run time
            stz   CP1L,x
            stz   CP1H,x
:pat        ldx   NCMDS
            lda   SD_SP
            sta   CP2L,x
            lda   SD_SP+1
            sta   CP2H,x
            jsr   CUTPLAIN
:flags      lda   (SD_SP)
            cmp   #"g"
            beq   :fg
            cmp   #"p"
            beq   :fp
            cmp   #"w"
            beq   :fw
            cmp   #"0"
            bcc   :fdone
            cmp   #"9"+1
            bcs   :fdone
            jsr   PARSENUM
            lda   SD_NUM
            ora   SD_NUM+1
            bne   :nok
            lda   #E_FLAG            ;s///0 is meaningless
            jmp   BADSCRIPT
:nok        ldx   NCMDS
            lda   SD_NUM
            sta   CNUML,x
            lda   SD_NUM+1
            sta   CNUMH,x
            bra   :flags
:fg         lda   #SF_G
            bra   :orflag
:fp         lda   #SF_P
:orflag     ldx   NCMDS
            ora   CFLG,x
            sta   CFLG,x
            jsr   SPINC
            bra   :flags
:fw         jsr   SPINC
            jsr   SKIPBL
            jsr   RDTOEOL
            bcc   :wname
            jmp   P_EFILE
:wname      jsr   WFADD
            ldx   NCMDS
            sta   CWFD,x
            lda   CFLG,x
            ora   #SF_W
            sta   CFLG,x
            jmp   PS_EOL
:fdone      jmp   PS_TERM

*---------------------------------------------------------------
* y -- y/src/dst/. Both strings are unescaped in place (\\, \n,
* \<delim>, \X) and must come out the same length (< 255).
*---------------------------------------------------------------
P_Y         lda   (SD_SP)
            beq   :unt
            cmp   #$8D
            beq   :unt
            cmp   #"\"
            bne   :delim
:unt        lda   #E_UNTERM
            jmp   BADSCRIPT
:delim      sta   SD_CH
            jsr   SPINC
            ldx   NCMDS
            lda   SD_SP
            sta   CP1L,x
            lda   SD_SP+1
            sta   CP1H,x
            jsr   CUTPLAIN
            ldx   NCMDS
            lda   SD_SP
            sta   CP2L,x
            lda   SD_SP+1
            sta   CP2H,x
            jsr   CUTPLAIN
            ldx   NCMDS
            lda   CP1L,x
            sta   SD_WK
            lda   CP1H,x
            sta   SD_WK+1
            jsr   UNESC
            bcs   :ylen
            sty   SD_CNT
            ldx   NCMDS
            lda   CP2L,x
            sta   SD_WK
            lda   CP2H,x
            sta   SD_WK+1
            jsr   UNESC
            bcs   :ylen
            cpy   SD_CNT
            bne   :ylen
            jmp   PS_TERM
:ylen       lda   #E_YLEN
            jmp   BADSCRIPT

* -- UNESC: the string at SD_WK, in place. OUT: Y = length,
* -- carry set if it reached 255.
UNESC       lda   SD_WK
            sta   SD_DST
            lda   SD_WK+1
            sta   SD_DST+1
            ldy   #0
:lp         lda   (SD_WK)
            beq   :done
            cmp   #"\"
            bne   :put
            jsr   WKINC
            lda   (SD_WK)
            beq   :done
            cmp   #"n"
            bne   :put
            lda   #$8D
:put        sta   (SD_DST)
            jsr   DSTINC
            jsr   WKINC
            iny
            cpy   #255
            bne   :lp
            sec
            rts
:done       lda   #0
            sta   (SD_DST)
            clc
            rts

WKINC       inc   SD_WK
            bne   :r
            inc   SD_WK+1
:r          rts

*---------------------------------------------------------------
* q -- optional exit code.
*---------------------------------------------------------------
P_Q         jsr   SKIPBL
            lda   (SD_SP)
            cmp   #"0"
            bcc   :none
            cmp   #"9"+1
            bcs   :none
            jsr   PARSENUM
            ldx   NCMDS
            lda   SD_NUM
            sta   CP1L,x
:none       jmp   PS_TERM

*---------------------------------------------------------------
* RESOLVE -- after the whole script: bind every b/t label to
* its command number (an unknown one is E_LABEL, reported at
* the name), and turn the end-of-script marker into NCMDS.
*---------------------------------------------------------------
RESOLVE     ldx   #0
:lp         cpx   NCMDS
            bcs   :done
            lda   CFLG,x
            and   #SF_LABREF
            bne   :bind
            lda   CVERB,x
            cmp   #V_B
            beq   :chkend
            cmp   #V_T
            bne   :next
:chkend     lda   CP1H,x
            cmp   #$FF
            bne   :next
            lda   NCMDS
            sta   CP1L,x
            stz   CP1H,x
:next       inx
            bra   :lp
:done       rts
:bind       lda   CFLG,x
            and   #SF_LABREF!$FF
            sta   CFLG,x
            lda   CP1L,x
            sta   PTR1
            sta   SD_SP              ;for the error position
            lda   CP1H,x
            sta   PTR1+1
            sta   SD_SP+1
            ldy   #0
:find       cpy   NLAB
            bcs   :undef
            lda   LABPL,y
            sta   PTR0
            lda   LABPH,y
            sta   PTR0+1
            phy
            phx
            jsr   STRCMP
            plx
            ply
            cmp   #0
            beq   :found
            iny
            bra   :find
:found      lda   LABIDX,y
            sta   CP1L,x
            stz   CP1H,x
            bra   :next
:undef      lda   #E_LABEL
            jmp   BADSCRIPT
