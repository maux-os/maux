*---------------------------------------------------------------
* shtabc.s -- TAB completion for sh's line editor (TAB-A3.md,
* TAB-A3-NOTES.md). `put` by sh.s into the $E000 segment after
* shsgali.s, whose ALI_WEND / ALI_NEXTCMD it reuses for the
* forward context scan. CODE only: nothing here is handed to a
* syscall (every buffer a syscall sees is in the arena).
*
* TC_TAB is the editor's TAB handler (ED_VECS). The word under
* completion is [word start, cursor); the tail after the cursor
* is never touched. Enumeration runs GLOB_APPEND itself, with
* TC_ON set: GLOB_TRY then hands a matching name to TC_KEEP
* instead of GLOB_KEEP, and a failed open or read leaves TC_ERR
* (an INCOMPLETE scan inserts nothing).
*
* Candidates live in the glob arena's records (GLOBBUF, 64 B
* stride) as BARE leaf names, <= 15 characters + NUL, copied
* with an explicit bound; the directory property is GLOBTYP
* [slot], the storage type ($0D, $0F a volume; devices are $0A
* and $0B and are not directories). At most MAXGLOB records are
* STORED; every candidate is COUNTED and folded into the common
* prefix, so a 32nd match that changes the prefix still does
* (review finding 10).
*---------------------------------------------------------------

*---------------------------------------------------------------
* TC_TAB -- the TAB key. Always returns carry clear (a key never
* ends the line); a refusal changes nothing.
*---------------------------------------------------------------
TC_TAB      lda   ED_NOPROG          ;ED_KEY has shifted it: 1
            sta   TC_WAS             ;means TAB, no key, TAB
            stz   TC_ERR
            lda   ED_PCH
            cmp   #OPC_GT            ;a continuation (PS2) line
            beq   :nop
            lda   ED_POS             ;the byte after the cursor:
            cmp   ED_LEN             ;end of line, a blank or an
            beq   :cursok            ;operator character;
            tax                      ;else mid-word (review 14)
            lda   LINEBUF,x
            cmp   #ALC_A0
            beq   :cursok
            jsr   ISOPCH
            bcs   :cursok
            cmp   #ALC_A8
            beq   :cursok
            cmp   #ALC_A9
            bne   :nop
:cursok     ldx   ED_POS             ;the scan reads to a NUL at
            lda   LINEBUF,x          ;the cursor
            sta   TC_SAVE
            lda   #0
            sta   LINEBUF,x
            jsr   TC_SCAN
            php
            ldx   ED_POS
            lda   TC_SAVE
            sta   LINEBUF,x
            plp
            bcs   :nop
            lda   ED_POS
            sec
            sbc   TC_BS
            sta   TC_BL
            jsr   TC_COLLECT
            lda   TC_ERR
            bne   :nop
            lda   TC_CNT
            beq   :nop
            cmp   #1
            beq   :uniq
            lda   TC_LCP             ;several: insert the common
            cmp   TC_BL              ;prefix beyond the typed
            beq   :nopro
            sta   TC_J
            lda   TC_BL
            sta   TC_I
            stz   TC_SUF
            jsr   TC_INSERT
            clc
            rts
:nopro      lda   TC_WAS
            cmp   #1
            bne   :arm
            jsr   TC_LIST            ;TAB TAB, nothing between
:arm        lda   #2
            sta   ED_NOPROG
:nop        clc
            rts
:uniq       lda   TC_LCP
            sta   TC_J
            lda   TC_BL
            sta   TC_I
            ldx   GLOBTYP            ;a directory takes `/`,
            jsr   TC_ISDIR           ;anything else a blank --
            lda   #ALC_AF            ;but no blank if the tail
            bcs   :suf               ;already starts with one
            lda   #ALC_A0
            ldx   ED_POS
            cpx   ED_LEN
            bcs   :suf
            ldy   LINEBUF,x
            cpy   #ALC_A0
            bne   :suf
            lda   #0
:suf        sta   TC_SUF
            jsr   TC_INSERT
            clc
            rts

* TC_ISDIR -- X = a storage type. Carry SET iff $0D or $0F.
* ($0A/$0B devices and the file types do not match.)
TC_ISDIR    txa
            and   #$0D
            cmp   #$0D
            beq   :yes
            clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* TC_INSERT -- insert at the cursor: record 0's bytes [TC_I,
* TC_J), then TC_SUF if non-zero. ALL OR NONE: the whole
* insertion must fit ED_LENMAX or nothing is inserted. Carry
* SET = refused.
*---------------------------------------------------------------
TC_INSERT   lda   TC_J
            sec
            sbc   TC_I
            ldx   TC_SUF
            beq   :n1
            adc   #0                 ;carry is set: +1
:n1         clc
            adc   ED_LEN
            bcs   :no
            cmp   #ED_LENMAX+1
            bcs   :no
:ins        lda   TC_I
            cmp   TC_J
            bcs   :suf
            tax
            lda   GLOBBUF,x
            jsr   ED_INS
            inc   TC_I
            bra   :ins
:suf        lda   TC_SUF
            beq   :ok
            jsr   ED_INS
:ok         clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* TC_SCAN -- the FORWARD context scan over LINEBUF[0, POS)
* (NUL-terminated at the cursor by the caller). It uses the
* alias expander's own word splitter and command-position
* table, so it agrees with the lexer on operator adjacency by
* construction. OUT: carry SET = refuse; else TC_MODE (0
* command, 1 pathname), TC_WS (word start), TC_BS (start of the
* leaf after the last `/`). Refused: a comment, the fd of
* `>&`/`<&`, a here-document delimiter, the NAME of a `for`,
* anything between `case` and `esac`, and a word with a quote,
* backslash, `$`, backquote, glob character or `=`.  An
* assignment-shaped word before the command (`A=1 ca`) is a
* prefix assignment and leaves command position unchanged.
*---------------------------------------------------------------
TC_SCAN     stz   ALP
            lda   #1
            sta   ALCMD
            stz   TC_RP
            stz   TC_FORN
            stz   TC_CASE
:next       ldy   ALP
:sk         lda   LINEBUF,y
            cmp   #ALC_A0
            bne   :wst
            iny
            bra   :sk
:wst        sty   ALP
            lda   LINEBUF,y
            bne   :havew
            sty   TC_WS              ;no more words: an empty
            jmp   :final             ;word at the cursor
:havew      jsr   ALI_WEND
            ldy   ALWE
            lda   LINEBUF,y
            sta   TC_LAST            ;0: the word ends at cursor
            ldy   ALP
            lda   LINEBUF,y
            cmp   #TCC_HASH          ;a comment
            beq   :rf
            jsr   ALI_ISBRK
            bcs   :oper
            lda   TC_LAST
            bne   :notl
            jmp   :lastw
:notl       lda   TC_RP              ;a redirect operand: eaten,
            beq   :nrp               ;command position unchanged
            stz   TC_RP
            bra   :adv
:nrp        lda   TC_FORN
            beq   :nf1
            stz   TC_FORN            ;the NAME of a `for`
            stz   ALCMD
            bra   :adv
:nf1        lda   TC_CASE
            beq   :nf2
            lda   #<ESAC_STR         ;case ... esac: only `esac`
            ldx   #>ESAC_STR         ;matters
            jsr   TC_KW
            bcs   :adv
            stz   TC_CASE
            stz   ALCMD
            bra   :adv
:nf2        lda   ALCMD
            beq   :adv               ;an argument: no change
            ldy   ALP                ;an assignment-shaped word
            jsr   TC_ASGN            ;in command position is a
            bcs   :adv               ;a prefix assignment:
                                     ;still command position
            lda   #<FOR_STR
            ldx   #>FOR_STR
            jsr   TC_KW
            bcs   :nfor
            inc   TC_FORN
            stz   ALCMD
            bra   :adv
:nfor       lda   #<CASE_STR
            ldx   #>CASE_STR
            jsr   TC_KW
            bcs   :nkw
            inc   TC_CASE
            stz   ALCMD
            bra   :adv
:nkw        jsr   ALI_NEXTCMD        ;if/then/do/... re-arm
:adv        lda   ALWE
            sta   ALP
            jmp   :next
:rf         sec
            rts

:oper       lda   TC_RP              ;an operator where a
            bne   :rf                ;redirect operand belongs
            stz   TC_FORN
            lda   LINEBUF,y
            cmp   #OPC_LT
            beq   :redir
            cmp   #OPC_GT
            bne   :cmd
:redir      lda   #1                 ;< > >> <> : a file operand
            ldy   ALP
            iny
            cpy   ALWE
            beq   :rset              ;a one-byte operator
            lda   LINEBUF,y
            cmp   #OPC_AMP           ;>& <& : an fd
            beq   :fd
            cmp   #OPC_LT            ;<< : a delimiter
            bne   :file
:fd         lda   #2
            bra   :rset
:file       lda   #1
:rset       sta   TC_RP
            bra   :oend
:cmd        jsr   ALI_NEXTCMD        ;; | & && || ( : a command
:oend       lda   TC_LAST            ;follows; `)` and `;;` not
            beq   :empty
            bra   :adv
:empty      ldy   ALWE               ;the operator ends at the
            sty   TC_WS              ;cursor: an empty word
            jmp   :final

:lastw      lda   ALP                ;the word under the cursor
            sta   TC_WS
:final      lda   TC_FORN
            ora   TC_CASE
            bne   :refuse
            lda   TC_RP
            cmp   #2
            beq   :refuse
            sta   TC_MODE            ;1: after a redirect, path
            cmp   #1
            beq   :scan
            lda   ALCMD
            eor   #1                 ;0 command, 1 argument
            sta   TC_MODE
:scan       ldx   TC_WS
            stx   TC_BS
:rs         cpx   ED_POS
            bcs   :ok
            lda   LINEBUF,x
            ldy   #TCC_BADN-1
:rb         cmp   TC_BAD,y
            beq   :refuse
            dey
            bpl   :rb
            cmp   #ALC_AF
            bne   :rn
            lda   #1                 ;a `/` makes it a pathname
            sta   TC_MODE
            inx
            stx   TC_BS
            dex
:rn         inx
            bra   :rs
:ok         clc
            rts
:refuse     sec
            rts

* The bytes that refuse a word: ' " \ $ ` * ? [ =
TC_BAD      dfb   ALC_A7,ALC_A2,ALC_DC,ALC_A4,TCC_BQ
            dfb   TCC_STAR,TCC_QM,ALC_DB,ALC_BD

* TC_KW -- A/X = a NUL-ended keyword; compare the word at
* [ALP, ALWE), case folded. Carry CLEAR = equal.
TC_KW       sta   PTR1
            stx   PTR1+1
            jmp   ALI_CMPW

* TC_ASGN -- Y = ALP. Carry SET iff the word [ALP, ALWE) starts
* with a letter and has an `=` (CHCK_BLTN_VAR's shape).
TC_ASGN     lda   LINEBUF,y
            cmp   #ALC_C1
            bcc   :no
            cmp   #ALC_DB
            bcs   :no
:eq         iny
            cpy   ALWE
            bcs   :no
            lda   LINEBUF,y
            cmp   #ALC_BD
            bne   :eq
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* TC_COLLECT -- enumerate every candidate for the word: TC_N
* records stored, TC_CNT distinct candidates, TC_LCP their
* common prefix (case folded, spelled as record 0), TC_ERR on an
* incomplete scan.
*---------------------------------------------------------------
TC_COLLECT  stz   TC_N
            stz   TC_CNT
            stz   TC_LCP
            stz   TC_FILT
            lda   TC_MODE
            bne   :path
            jsr   TC_SALIAS          ;the resolver's own order:
            jsr   TC_SBLT            ;aliases, builtins,
            jsr   TC_SRESV           ;reserved words, then every
            jmp   TC_SPATH           ;PATH component
:path       lda   #<TC_NULS
            sta   PTR1
            lda   #>TC_NULS
            sta   PTR1+1
            jsr   TC_PATB
            bcs   TC_FAIL
            jmp   TC_WALK
TC_NULS     dfb   0

TC_FAIL     lda   #1
            sta   TC_ERR
            rts

* TC_PATB -- TC_PAT := (PTR1 string) + LINEBUF[WS, POS) + `*`.
* Carry SET = it would not fit GLOB_APPEND's 64-byte prefix.
TC_PATB     ldx   #0
            ldy   #0
:p          lda   (PTR1),y
            beq   :w
            sta   TC_PAT,x
            inx
            iny
            cpx   #64
            bcc   :p
            rts                      ;carry set
:w          ldy   TC_WS
:q          cpy   ED_POS
            bcs   :s
            lda   LINEBUF,y
            sta   TC_PAT,x
            inx
            iny
            cpx   #64
            bcc   :q
            rts
:s          lda   #TCC_STAR
            sta   TC_PAT,x
            lda   #0
            sta   TC_PAT+1,x
            clc
            rts

* TC_WALK -- run GLOB_APPEND over TC_PAT with TC_ON set.
TC_WALK     lda   #1
            sta   TC_ON
            stz   CURQFLAG
            lda   #<TC_PAT
            sta   PTR0
            lda   #>TC_PAT
            sta   PTR0+1
            jsr   GLOB_APPEND
            stz   TC_ON
            rts

*---------------------------------------------------------------
* TC_KEEP -- GLOB_TRY's hook (TC_ON): GNAME matched the pattern.
* Command position keeps runnable file types only (BIN, SYS and
* TXT -- a known superset, spawn runs a TXT only with `#!`).
* Returns carry clear (there is always room: only MAXGLOB are
* stored and the rest are counted).
*---------------------------------------------------------------
TC_KEEP     lda   TC_FILT
            bpl   :ok
            lda   GREC+RD_FTYPE
            cmp   #FTYPE_BIN
            beq   :ok
            cmp   #FTYPE_SYS
            beq   :ok
            cmp   #FTYPE_TXT
            bne   :skip
:ok         ldx   #0
:cp         lda   GNAME,x
            sta   TC_CAND,x
            beq   :cd
            inx
            cpx   #15
            bcc   :cp
            lda   #0
            sta   TC_CAND,x
:cd         lda   GREC+RD_STYPE
            jsr   TC_ADD
:skip       clc
            rts

*---------------------------------------------------------------
* TC_ADD -- A = the storage type; TC_CAND = the candidate. Drop
* a case-folded duplicate of a stored record; else fold it into
* the common prefix, store it if there is room, and count it.
*---------------------------------------------------------------
TC_ADD      sta   TC_STY
            ldx   #0
:dd         cpx   TC_N
            bcs   :new
            stx   TC_I
            txa
            sta   GSLOT
            jsr   GLOB_SLOTX
            ldy   #0
:c          lda   TC_CAND,y
            jsr   ALI_FOLD
            sta   TC_T1
            lda   (PTR0),y
            jsr   ALI_FOLD
            cmp   TC_T1
            bne   :diff
            lda   TC_CAND,y
            beq   :dup
            iny
            bra   :c
:diff       ldx   TC_I
            inx
            bra   :dd
:dup        rts
:new        lda   TC_CNT
            bne   :lcp
            ldy   #0                 ;the first: whole length
:sl         lda   TC_CAND,y
            beq   :sd
            iny
            bra   :sl
:sd         sty   TC_LCP
            bra   :store
:lcp        ldy   #0                 ;fold into record 0
:lp         cpy   TC_LCP
            bcs   :ld
            lda   TC_CAND,y
            jsr   ALI_FOLD
            sta   TC_T1
            lda   GLOBBUF,y
            jsr   ALI_FOLD
            cmp   TC_T1
            bne   :ld
            iny
            bra   :lp
:ld         sty   TC_LCP
:store      lda   TC_N
            cmp   #MAXGLOB
            bcs   :cnt
            sta   GSLOT
            jsr   GLOB_SLOTX
            ldy   #0
:st         lda   TC_CAND,y
            sta   (PTR0),y
            beq   :sdn
            iny
            bra   :st
:sdn        ldx   TC_N
            lda   TC_STY
            sta   GLOBTYP,x
            inc   TC_N
:cnt        lda   TC_CNT
            cmp   #255
            bcs   :out
            inc   TC_CNT
:out        rts

*---------------------------------------------------------------
* The command sources. TC_FOLDF bit 7 = match case-folded and
* spell lower case (builtins and reserved words are upper case
* in their tables); clear = exact (aliases compare exact bytes).
*---------------------------------------------------------------
TC_SALIAS   stz   TC_FOLDF
            ldx   #0
:a          stx   TC_K
            lda   ALI_NAMES,x
            beq   :n
            txa
            clc
            adc   #<ALI_NAMES
            sta   PTR1
            lda   #>ALI_NAMES
            adc   #0
            sta   PTR1+1
            jsr   TC_TRY
:n          lda   TC_K
            clc
            adc   #16
            tax
            cpx   #128
            bcc   :a
            rts

TC_SBLT     lda   #$80
            sta   TC_FOLDF
            lda   #<BLTTAB
            sta   PTR2
            lda   #>BLTTAB
            sta   PTR2+1
:b          lda   (PTR2)
            beq   :done
            lda   PTR2
            sta   PTR1
            lda   PTR2+1
            sta   PTR1+1
            jsr   TC_TRY
            ldy   #0                 ;on to the next string
:e          lda   (PTR2),y
            iny
            cmp   #0
            bne   :e
            tya
            clc
            adc   PTR2
            sta   PTR2
            bcc   :b
            inc   PTR2+1
            bra   :b
:done       rts

TC_SRESV    lda   #$80
            sta   TC_FOLDF
            ldx   #0
:r          stx   TC_K
            lda   RESV_LO,x
            sta   PTR1
            lda   RESV_HI,x
            sta   PTR1+1
            jsr   TC_TRY
            ldx   TC_K
            inx
            cpx   #RESV_CNT
            bcc   :r
            rts

* TC_TRY -- PTR1 = a candidate name. If the typed word is a
* prefix of it (TC_FOLDF), add it.
TC_TRY      ldx   TC_WS
            ldy   #0
:l          cpx   ED_POS
            bcs   :yes
            lda   (PTR1),y
            beq   :no
            jsr   TC_FC
            sta   TC_T1
            lda   LINEBUF,x
            jsr   TC_FC
            cmp   TC_T1
            bne   :no
            inx
            iny
            bra   :l
:no         rts
:yes        ldy   #0                 ;copy, bounded, spelled
:c          lda   (PTR1),y           ;lower case if folding
            beq   :e
            bit   TC_FOLDF
            bpl   :s
            cmp   #ALC_C1
            bcc   :s
            cmp   #ALC_DB
            bcs   :s
            adc   #$20
:s          sta   TC_CAND,y
            iny
            cpy   #15
            bcc   :c
:e          lda   #0
            sta   TC_CAND,y
            lda   #0
            jmp   TC_ADD

TC_FC       bit   TC_FOLDF
            bpl   :r
            jmp   ALI_FOLD
:r          rts

* TC_SPATH -- every PATH component, PATH_SRC's own semantics
* (PATH=. offers the cwd; a component listed twice is walked
* twice and its names are dropped as duplicates).
TC_SPATH    jsr   PATH_SRC
            stz   TC_PI
:comp       ldy   TC_PI
            lda   SH_PATHSRC,y
            beq   :done
            tya                      ;PTR1 := this component
            clc
            adc   #<SH_PATHSRC
            sta   PTR1
            lda   #>SH_PATHSRC
            adc   #0
            sta   PTR1+1
:nx         lda   SH_PATHSRC,y       ;step TC_PI past its NUL
            iny
            cmp   #0
            bne   :nx
            sty   TC_PI
            jsr   TC_PATB
            bcs   :comp              ;too long for the walker
            lda   #$80
            sta   TC_FILT
            jsr   TC_WALK
            bra   :comp
:done       rts
