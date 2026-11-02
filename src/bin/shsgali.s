*---------------------------------------------------------------
* shsgali.s -- `alias`, `unalias`, `hash`, `fc` and the alias
* expander, segment-resident ($E000, like shsgblt.s). Strings a
* write sees are in shalias.s, low. docs/SH-ALIAS-NOTES.md.
*
* THE TABLE lives in the segments' dead low copy (sh.s, the
* dead-copy `dum` block, SH-ROOM): eight slots, name 15 chars +
* NUL (16 B) and value 31 chars + NUL (32 B). It costs the
* window nothing. It is NOT zero at start (cold: the segment
* tails; warm: the last run's table); ALI_INIT empties it from
* START on every entry by clearing each slot's first name byte
* and ALI_END -- NOT ALI_VALS. READ-AFTER-PUBLICATION: every
* reader reaches a slot through an occupied name byte
* (ALI_MATCH, ALI_FREE, ALI_RECNT, SA_LIST, TC_SALIAS test it
* first; ALI_FIND refuses an empty name, which would match a
* free slot and print its stale value). SA_ONE publishes the
* name and then writes the value, NUL-terminated, with no read
* between the two (nothing it calls touches the table).
* Aliases are not serialised to a subshell: a subshell is a
* fresh process whose START empties its own table.
*
* EXPANSION is a TEXT pass over LINEBUF (SH_RUNLINE, after
* STRIPCOMMENT, before TOKENIZE). A word is a candidate when
* it stands in COMMAND POSITION: first on the line or after a
* whole-word ; & && || | ( { ! or if/then/elif/else/while/
* until/do, or right after an alias whose value ended in a
* blank. ALI_END[i] is the end offset of alias i's expansion
* text while the scan is inside it (0 = inactive): a name that
* is active is not expanded again (POSIX 2.3.1), and crossing
* the end of one whose last value byte is a blank re-arms
* command position.
*---------------------------------------------------------------

*---------------------------------------------------------------
* ALI_INIT -- empty the table. CLOBBERS: A, X.
*---------------------------------------------------------------
ALI_INIT    ldx   #0
:z          stz   ALI_NAMES,x
            txa
            clc
            adc   #16
            tax
            cmp   #128
            bne   :z
            ldx   #7
:e          stz   ALI_END,x
            dex
            bpl   :e
            stz   ALI_USED
            rts

*---------------------------------------------------------------
* ALI_EXPAND -- carry SET = the expansion would exceed LINEMAX
* (nothing is truncated; the caller drops the line).
* CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
ALI_EXPAND  ldx   #7
:ze         stz   ALI_END,x
            dex
            bpl   :ze
            stz   ALP
            lda   #1
            sta   ALCMD
:next       ldy   ALP
:sk         lda   LINEBUF,y
            cmp   #ALC_A0
            bne   :wst
            iny
            bra   :sk
:wst        sty   ALP
            lda   LINEBUF,y
            bne   :havew
            clc
            rts
:havew      jsr   ALI_RETIRE
            jsr   ALI_WEND
            lda   ALCMD
            beq   :notcmd
            jsr   ALI_MATCH
            bcs   :notcmd
            jsr   ALI_SPLICE
            bcs   :err
            bra   :next
:notcmd     jsr   ALI_NEXTCMD
            lda   ALWE
            sta   ALP
            bra   :next
:err        rts

*---------------------------------------------------------------
* ALI_RETIRE -- every active alias whose expansion ended at or
* before ALP goes inactive; a trailing blank in its value makes
* this word a command position too. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
ALI_RETIRE  ldx   #0
:r          lda   ALI_END,x
            beq   :rn
            lda   ALP
            cmp   ALI_END,x
            bcc   :rn
            ldy   ALI_END,x
            dey
            lda   LINEBUF,y
            stz   ALI_END,x
            cmp   #ALC_A0
            bne   :rn
            lda   #1
            sta   ALCMD
:rn         inx
            cpx   #8
            bne   :r
            rts

*---------------------------------------------------------------
* ALI_WEND -- ALWE = index just past the word at ALP. Quote-
* aware ('..' ".." backslash), a `$( )` span keeps its blanks,
* and an operator byte ends the word before it and is a word by
* itself, with its doubled/`&` pair (shtok.s :bop: the same five
* bytes ISOPCH answers for, KFIX2 5; it was `|` only).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
ALI_WEND    ldy   ALP
            stz   ALDEP
            lda   LINEBUF,y
            jsr   ALI_ISBRK              ;an operator byte is
            bcc   :wl                    ;a word of its own: one
            iny                          ;byte, or the pair that
            cmp   #ALC_A8                ;a parenthesis is never
            beq   :opw                   ;paired: `((` = `(` `(`
            cmp   #ALC_A9                ;(review F8)
            beq   :opw
            cmp   LINEBUF,y              ;TOKENIZE keeps whole
            beq   :op2                   ;(|| && ;; << >> >& <&)
            cmp   #OPC_GT
            beq   :opamp
            cmp   #OPC_LT
            bne   :wdone
:opamp      lda   LINEBUF,y
            cmp   #OPC_AMP
            bne   :wdone
:op2        iny
:opw        bra   :wdone
:wl         lda   LINEBUF,y
            beq   :wdone
            ldx   ALDEP
            bne   :indep
            cmp   #ALC_A0
            beq   :wdone
            jsr   ALI_ISBRK              ;`ll;pwd` `ll>F` `ll)`
            bcs   :wdone                 ;ends the word
            cmp   #ALC_A7
            beq   :wsq
            cmp   #ALC_A2
            beq   :wdq
            cmp   #ALC_DC
            beq   :wbs
            cmp   #ALC_A4
            bne   :wadv
            lda   LINEBUF+1,y
            cmp   #ALC_A8
            bne   :wadv
            inc   ALDEP
            iny
            bra   :wadv
:indep      cmp   #ALC_A8
            bne   :ind2
            inc   ALDEP
            bra   :wadv
:ind2       cmp   #ALC_A9
            bne   :wadv
            dec   ALDEP
            bra   :wadv
:wsq        iny
:wsq1       lda   LINEBUF,y
            beq   :wdone
            cmp   #ALC_A7
            beq   :wadv
            iny
            bra   :wsq1
:wdq        iny
:wdq1       lda   LINEBUF,y
            beq   :wdone
            cmp   #ALC_A2
            beq   :wadv
            cmp   #ALC_DC
            bne   :wdq2
            iny
            lda   LINEBUF,y
            beq   :wdone
:wdq2       iny
            bra   :wdq1
:wbs        iny
            lda   LINEBUF,y
            beq   :wdone
:wadv       iny
            bra   :wl
:wdone      sty   ALWE
            rts

*---------------------------------------------------------------
* ALI_ISBRK -- A = a byte of LINEBUF. Carry SET iff it ends an
* alias word or is one: ISOPCH's five operator bytes (the
* tokenizer's own predicate, called, not copied) and the
* subshell parentheses `(` `)` (KFIX3 item 4). `(ll)` is the
* words `(` `ll` `)`: the one after `(` is in command position
* (CMDTAB lists `(`), which `(ll)` as one word never was. Only
* a BARE parenthesis gets here -- `$(` is consumed with its `$`
* by the word loop and its span runs at ALDEP > 0, quoted ones
* sit inside a quote scan -- so quoted and argument-position
* text is unchanged. A and Y preserved.
*---------------------------------------------------------------
ALI_ISBRK   jsr   ISOPCH
            bcs   :yes
            cmp   #ALC_A8                ;'('
            beq   :yes
            cmp   #ALC_A9                ;')'
            beq   :yes
            clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* ALI_MATCH -- the word [ALP,ALWE) against every INACTIVE
* alias name, case-sensitively. Carry CLEAR = match, ALIDX =
* slot. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
ALI_MATCH   stz   ALIDX
            ldx   #0
:ms         stx   ALT
            lda   ALI_NAMES,x
            beq   :mnext
            ldy   ALIDX
            lda   ALI_END,y
            bne   :mnext
            ldy   ALP
:mc         lda   ALI_NAMES,x
            beq   :mnamend
            cpy   ALWE
            bcs   :mnext
            cmp   LINEBUF,y
            bne   :mnext
            inx
            iny
            bra   :mc
:mnamend    cpy   ALWE
            bne   :mnext
            clc
            rts
:mnext      lda   ALT
            clc
            adc   #16
            tax
            inc   ALIDX
            cpx   #128
            bne   :ms
            sec
            rts

*---------------------------------------------------------------
* ALI_NEXTCMD -- ALCMD := is the word at [ALP,ALWE) one after
* which another command position follows (ALI_CMDTAB).
* CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
ALI_NEXTCMD stz   ALCMD
            lda   #<ALI_CMDTAB
            sta   PTR1
            lda   #>ALI_CMDTAB
            sta   PTR1+1
:ncl        ldy   #0
            lda   (PTR1),y
            beq   :ncdone
            jsr   ALI_CMPW
            bcc   :ncyes
            ldy   #0
:nca        lda   (PTR1),y
            beq   :ncad
            iny
            bra   :nca
:ncad       iny
            tya
            clc
            adc   PTR1
            sta   PTR1
            bcc   :ncl
            inc   PTR1+1
            bra   :ncl
:ncyes      lda   #1
            sta   ALCMD
:ncdone     rts

*-- ALI_CMPW -- word [ALP,ALWE) vs the NUL-terminated string at
*-- PTR1, letters folded. Carry CLEAR = equal. CLOBBERS: A,X,Y.
ALI_CMPW    ldx   ALP
            ldy   #0
:cl         lda   (PTR1),y
            beq   :cend
            cpx   ALWE
            bcs   :cno
            jsr   ALI_FOLD
            sta   ALT
            lda   LINEBUF,x
            jsr   ALI_FOLD
            cmp   ALT
            bne   :cno
            inx
            iny
            bra   :cl
:cend       cpx   ALWE
            bne   :cno
            clc
            rts
:cno        sec
            rts
ALI_FOLD    cmp   #ALC_E1
            bcc   :fd
            cmp   #ALC_FB
            bcs   :fd
            and   #ALC_DF
:fd         rts

ALI_CMDTAB  dfb   $BB,0                 ;;
            dfb   $A6,0                 ;&
            dfb   $A6,$A6,0             ;&&
            dfb   $FC,$FC,0             ;||
            dfb   $FC,0                 ;|
            dfb   $A8,0                 ;(
            dfb   $FB,0                 ;{
            dfb   $A1,0                 ;!
            asc   "IF"
            dfb   0
            asc   "THEN"
            dfb   0
            asc   "ELIF"
            dfb   0
            asc   "ELSE"
            dfb   0
            asc   "WHILE"
            dfb   0
            asc   "UNTIL"
            dfb   0
            asc   "DO"
            dfb   0
            dfb   0

*---------------------------------------------------------------
* ALI_SPLICE -- replace the word [ALP,ALWE) by alias ALIDX's
* value, in place, then rescan from ALP. Carry SET = the new
* line would exceed LINEMAX; LINEBUF is untouched then.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
ALI_SPLICE  lda   ALIDX
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            sta   ALU
            tax
            stz   ALV
:vl         lda   ALI_VALS,x
            beq   :vld
            inx
            inc   ALV
            bra   :vl
:vld        lda   ALWE
            sec
            sbc   ALP
            sta   ALN
            ldy   ALWE
:ll         lda   LINEBUF,y
            beq   :lld
            iny
            bra   :ll
:lld        sty   ALL
            tya
            clc
            adc   ALV
            sta   ALT
            lda   #0
            rol   a
            sta   ALH
            lda   ALT
            sec
            sbc   ALN
            lda   ALH
            sbc   #0
            beq   :fits
            sec
            rts
:fits       lda   ALV
            cmp   ALN
            beq   :copyv
            bcc   :shl
            sec
            sbc   ALN
            sta   ALD
            ldy   ALL
:sr         tya
            clc
            adc   ALD
            tax
            lda   LINEBUF,y
            sta   LINEBUF,x
            cpy   ALWE
            beq   :copyv
            dey
            bra   :sr
:shl        lda   ALN
            sec
            sbc   ALV
            sta   ALD
            ldy   ALWE
:sl         tya
            sec
            sbc   ALD
            tax
            lda   LINEBUF,y
            sta   LINEBUF,x
            beq   :copyv
            iny
            bra   :sl
:copyv      lda   ALV
            beq   :cvd
            sta   ALT
            ldx   ALU
            ldy   ALP
:cv         lda   ALI_VALS,x
            sta   LINEBUF,y
            inx
            iny
            dec   ALT
            bne   :cv
:cvd        ldx   #7
:ue         lda   ALI_END,x
            beq   :un
            clc
            adc   ALV
            sec
            sbc   ALN
            sta   ALI_END,x
:un         dex
            bpl   :ue
            lda   ALP
            clc
            adc   ALV
            ldx   ALIDX
            sta   ALI_END,x
            lda   ALP
            cmp   ALI_MINPOS
            bcs   :nm
            sta   ALI_MINPOS
:nm         clc
            rts

*---------------------------------------------------------------
* The builtins. CHCK_BLTN_ALI -- carry SET = handled.
* CLOBBERS: A, X, Y, PTR0-PTR2.
*---------------------------------------------------------------
CHCK_BLTN_ALI
            lda   #<ALI_ALIAS_S
            sta   PTR1
            lda   #>ALI_ALIAS_S
            sta   PTR1+1
            jsr   SB_MATCH
            bcs   :ckuna
            jsr   SB_NOREDIR
            bcs   :done
            jsr   SA_ALIAS
:done       sec
            rts
:ckuna      lda   #<ALI_UNA_S
            sta   PTR1
            lda   #>ALI_UNA_S
            sta   PTR1+1
            jsr   SB_MATCH
            bcs   :ckhash
            jsr   SB_NOREDIR
            bcs   :done
            jsr   SA_UNALIAS
            bra   :done
:ckhash     lda   #<ALI_HASH_S
            sta   PTR1
            lda   #>ALI_HASH_S
            sta   PTR1+1
            jsr   SB_MATCH
            bcs   :ckfc
            jsr   SB_NOREDIR
            bcs   :done
            jsr   SA_HASH
            bra   :done
:ckfc       lda   #<ALI_FC_S
            sta   PTR1
            lda   #>ALI_FC_S
            sta   PTR1+1
            jsr   SB_MATCH
            bcs   :no
            lda   #<FC_NSUP_M
            ldx   #>FC_NSUP_M
            jsr   PR_ERRAX
            lda   #2
            sta   LASTSTATUS
            bra   :done
:no         clc
            rts

ALI_ALIAS_S asc   "ALIAS"
            dfb   0
ALI_UNA_S   asc   "UNALIAS"
            dfb   0
ALI_HASH_S  asc   "HASH"
            dfb   0
ALI_FC_S    asc   "FC"
            dfb   0
ALI_LP      asc   "alias "
            dfb   0
ALI_DA_S    asc   "-a"
            dfb   0
ALI_DR_S    asc   "-r"
            dfb   0
*-- Punctuation an alias name may hold besides letters/digits.
ALI_OKCH    dfb   $AE,$DF,$AD,$A1,$A5,$AC,$C0,$AB,$BA,0

*-- ALI_RECNT -- ALI_USED := the number of occupied slots.
ALI_RECNT   stz   ALI_USED
            ldx   #0
:rc         lda   ALI_NAMES,x
            beq   :rcn
            inc   ALI_USED
:rcn        txa
            clc
            adc   #16
            tax
            cmp   #128
            bne   :rc
            rts

*-- ALI_FIND -- PTR0 = a NUL-terminated name. Carry CLEAR =
*-- found: ALIDX = slot, X = slot*16. Carry SET = absent. An
*-- EMPTY name is absent: it would compare equal to a free
*-- slot's zero first byte, and `alias ""` then printed that
*-- slot's unwritten value (SH-ROOM: found while proving the
*-- table read-after-publication).
ALI_FIND    lda   (PTR0)
            bne   :nz
            sec
            rts
:nz         stz   ALIDX
            ldx   #0
:fs         stx   ALT
            ldy   #0
:fc         lda   ALI_NAMES,x
            cmp   (PTR0),y
            bne   :fnext
            cmp   #0
            beq   :fyes
            inx
            iny
            bra   :fc
:fnext      lda   ALT
            clc
            adc   #16
            tax
            inc   ALIDX
            cpx   #128
            bne   :fs
            sec
            rts
:fyes       ldx   ALT
            clc
            rts

*-- ALI_FREE -- first free slot: carry CLEAR, ALIDX, X=slot*16.
ALI_FREE    stz   ALIDX
            ldx   #0
:ls         lda   ALI_NAMES,x
            beq   :lyes
            txa
            clc
            adc   #16
            tax
            inc   ALIDX
            cpx   #128
            bne   :ls
            sec
            rts
:lyes       clc
            rts

*-- SA_NOTFND -- "<prefix>NAME: not found" on stderr, status 1.
*-- IN: A/X = prefix (LOW string), PTR0 = the name.
SA_NOTFND   sta   ALPFX
            stx   ALPFX+1
            lda   PTR0
            sta   SBNAME
            lda   PTR0+1
            sta   SBNAME+1
            lda   ALPFX
            sta   PTR0
            lda   ALPFX+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   SBNAME
            sta   PTR0
            lda   SBNAME+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<BLT_NOTFN_M
            sta   PTR0
            lda   #>BLT_NOTFN_M
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            sta   LASTSTATUS
            rts

*---------------------------------------------------------------
* SA_ALIAS -- `alias [name[=value]...]`.
*---------------------------------------------------------------
SA_ALIAS    stz   LASTSTATUS
            lda   CMD_ARGC+0
            cmp   #2
            bcs   :args
            jmp   SA_LIST
:args       lda   #1
            sta   SBI
:loop       lda   SBI
            cmp   CMD_ARGC+0
            beq   :done
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            jsr   SA_ONE
            inc   SBI
            bra   :loop
:done       jmp   ALI_RECNT

*-- SA_LIST -- every defined alias, slot order, on stdout.
SA_LIST     stz   ALI_LI
:ll         lda   ALI_LI
            cmp   #8
            beq   :ld
            asl   a
            asl   a
            asl   a
            asl   a
            tax
            lda   ALI_NAMES,x
            beq   :ln
            lda   ALI_LI
            sta   ALIDX
            jsr   SA_PRTSLOT
:ln         inc   ALI_LI
            bra   :ll
:ld         rts

*-- SA_PRTSLOT -- `alias name='value'` for slot ALIDX, stdout.
*-- A value's own ' is written '\'' so it reads back in.
SA_PRTSLOT  ldy   #0
            ldx   #0
:p1         lda   ALI_LP,x
            beq   :p1d
            sta   ALOUT,y
            inx
            iny
            bra   :p1
:p1d        lda   ALIDX
            asl   a
            asl   a
            asl   a
            asl   a
            tax
:p2         lda   ALI_NAMES,x
            beq   :p2d
            sta   ALOUT,y
            inx
            iny
            bra   :p2
:p2d        lda   #ALC_BD
            sta   ALOUT,y
            iny
            lda   #ALC_A7
            sta   ALOUT,y
            iny
            lda   ALIDX
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            tax
:p3         lda   ALI_VALS,x
            beq   :p3d
            cmp   #ALC_A7
            bne   :p3c
            sta   ALOUT,y
            iny
            lda   #ALC_DC
            sta   ALOUT,y
            iny
            lda   #ALC_A7
            sta   ALOUT,y
            iny
:p3c        sta   ALOUT,y
            inx
            iny
            bra   :p3
:p3d        lda   #ALC_A7
            sta   ALOUT,y
            iny
            lda   #$8D
            sta   ALOUT,y
            iny
            lda   #0
            sta   ALOUT,y
            lda   #<ALOUT
            ldx   #>ALOUT
            jmp   SB_POUT

*---------------------------------------------------------------
* SA_ONE -- one `alias` operand, PTR0 = the word: `name` prints,
* `name=value` defines (split in place at the first `=`).
*---------------------------------------------------------------
SA_ONE      ldy   #0
:f          lda   (PTR0),y
            beq   :noeq
            cmp   #ALC_BD
            beq   :haseq
            iny
            bne   :f
:noeq       jmp   SA_PRINT1
:bad        lda   #<ALI_BADN_M
            ldx   #>ALI_BADN_M
            jmp   SA_ERR
:haseq      cpy   #1
            bcc   :bad
            cpy   #VARNAMELEN+1
            bcs   :bad
            sty   ALEQ
            ldy   #0
:nc         cpy   ALEQ
            beq   :ncd
            lda   (PTR0),y
            jsr   SA_CHOK
            bcs   :bad
            iny
            bra   :nc
:ncd        ldy   ALEQ
            lda   #0
            sta   (PTR0),y
            jsr   SB_ISBLTN
            cmp   #2
            bne   :notkw
            lda   #<ALI_RESV_M
            ldx   #>ALI_RESV_M
            jmp   SA_ERR
:notkw      lda   ALEQ
            sec
            adc   PTR0
            sta   PTR2
            lda   PTR0+1
            adc   #0
            sta   PTR2+1
            ldy   #0
:vc         lda   (PTR2),y
            beq   :vcd
            iny
            cpy   #VARVALLEN+1
            bcc   :vc
            lda   #<ALI_VLNG_M
            ldx   #>ALI_VLNG_M
            jmp   SA_ERR
:vcd        jsr   ALI_FIND
            bcc   :have
            jsr   ALI_FREE
            bcc   :have
            lda   #<ALI_FULL_M
            ldx   #>ALI_FULL_M
            jmp   SA_ERR
:have       ldy   #0
:sn         lda   (PTR0),y
            sta   ALI_NAMES,x
            beq   :snd
            inx
            iny
            bra   :sn
:snd        lda   ALIDX
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            tax
            ldy   #0
:sv         lda   (PTR2),y
            beq   :svd
            ora   #$80
            sta   ALI_VALS,x
            inx
            iny
            bra   :sv
:svd        sta   ALI_VALS,x
            rts
SA_ERR      jsr   PR_ERRAX
            lda   #1
            sta   LASTSTATUS
            rts

*-- SA_CHOK -- carry CLEAR if A may appear in an alias name.
SA_CHOK     cmp   #ALC_B0
            bcc   :ck3
            cmp   #ALC_BA
            bcc   :ok
:ck3        cmp   #ALC_C1
            bcc   :ck4
            cmp   #ALC_DB
            bcc   :ok
:ck4        cmp   #ALC_E1
            bcc   :ck5
            cmp   #ALC_FB
            bcc   :ok
:ck5        ldx   #0
:ol         ldy   ALI_OKCH,x
            beq   :no
            sty   ALT
            cmp   ALT
            beq   :ok
            inx
            bra   :ol
:no         sec
            rts
:ok         clc
            rts

*-- SA_PRINT1 -- `alias name`: print it, or say not found.
SA_PRINT1   jsr   ALI_FIND
            bcs   :absent
            jmp   SA_PRTSLOT
:absent     lda   #<ALI_PFX_M
            ldx   #>ALI_PFX_M
            jmp   SA_NOTFND

*---------------------------------------------------------------
* SA_UNALIAS -- `unalias name...` / `unalias -a`.
*---------------------------------------------------------------
SA_UNALIAS  stz   LASTSTATUS
            lda   CMD_ARGC+0
            cmp   #2
            bcs   :have
            lda   #<UNA_USE_M
            ldx   #>UNA_USE_M
            jsr   PR_ERRAX
            lda   #2
            sta   LASTSTATUS
            rts
:have       lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            lda   #<ALI_DA_S
            sta   PTR1
            lda   #>ALI_DA_S
            sta   PTR1+1
            jsr   STRCMP
            bne   :names
            jmp   ALI_INIT
:names      lda   #1
            sta   SBI
:loop       lda   SBI
            cmp   CMD_ARGC+0
            beq   :done
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            jsr   ALI_FIND
            bcs   :absent
            lda   #0
            sta   ALI_NAMES,x
            bra   :next
:absent     lda   #<UNA_PFX_M
            ldx   #>UNA_PFX_M
            jsr   SA_NOTFND
:next       inc   SBI
            bra   :loop
:done       jmp   ALI_RECNT

*---------------------------------------------------------------
* SA_HASH -- `hash [-r] [name...]`. sh HAS a tracked-command
* cache (SH_HC0.., shpath.s): `-r` flushes it for real, a name
* is resolved the way a spawn resolves it (BUILD_PATH, which
* also records it; a `/` name is probed). Bare `hash` prints
* nothing. Builtin and keyword names are PATH lookups like any
* other, so `hash cd` is "not found" (bash agrees).
*---------------------------------------------------------------
SA_HASH     stz   LASTSTATUS
            lda   CMD_ARGC+0
            cmp   #2
            bcs   :have
            rts
:have       lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            lda   #<ALI_DR_S
            sta   PTR1
            lda   #>ALI_DR_S
            sta   PTR1+1
            jsr   STRCMP
            bne   :names
            jmp   SH_HFLUSH
:names      lda   #1
            sta   SBI
:loop       lda   SBI
            cmp   CMD_ARGC+0
            beq   :done
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            sta   SBNAME+1
            lda   PTR0
            sta   SBNAME
            lda   #<SH_TPATHBUF          ;a slash word is a
            sta   PTR1                   ;path: never searched,
            lda   #>SH_TPATHBUF          ;resolved vs the cwd
            sta   PTR1+1
            jsr   CMDSLASH
            bcs   :srch
            jsr   PATH_EXISTS
            bra   :got
:srch       jsr   BUILD_PATH
:got        bcc   :next
            lda   SBNAME
            sta   PTR0
            lda   SBNAME+1
            sta   PTR0+1
            lda   #<HSH_PFX_M
            ldx   #>HSH_PFX_M
            jsr   SA_NOTFND
:next       inc   SBI
            bra   :loop
:done       rts
