*---------------------------------------------------------------
* diffdir.s -- diff -r's listing half: printing helpers, operand
* loading and stat, path append, the sorted name list and its
* read. Split from diffrec.s (which holds the walk itself) at a
* global label so no module is larger than difflpb.s. `put` into
* src/bin/diff.s beside it; one assembly stream.
*---------------------------------------------------------------

*---------------------------------------------------------------
* PMSG -- print the NUL-terminated string A/X (lo/hi) to stdout.
*---------------------------------------------------------------
PMSG        sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS

PNL         lda   #$8D
            ldx   #FD_STDOUT
            jmp   PUTC

PDP1        lda   #<DP1
            ldx   #>DP1
            bra   PMSG

PDP2        lda   #<DP2
            ldx   #>DP2
            bra   PMSG

*---------------------------------------------------------------
* ERREXIT -- A/X = message; to fd 2 with a CR, exit 2.
* OVERFLOW (diffhnk.s) is the same shape for "input too large".
*---------------------------------------------------------------
TOOLONG     lda   #<M_LONG
            ldx   #>M_LONG
            bra   ERREXIT

TOODEEP     lda   #<M_DEEP
            ldx   #>M_DEEP
ERREXIT     sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* LOADOP -- IN: A = argv index, PTR1 = DPn. Copies the operand,
* strips trailing slashes (never the lone "/"), OUT: A = length.
* More than MLI_PTH_MAXLN characters is refused through OPENERR
* (OERRIDX names the side): MKPATH would flag it too, but a
* silent cut here could land on a real shorter path.
*---------------------------------------------------------------
LOADOP      jsr   GETARG
            ldy   #0
:cp         lda   (PTR0),y
            sta   (PTR1),y
            beq   :cpd
            iny
            cpy   #MLI_PTH_MAXLN+1
            bcc   :cp
            lda   #0
            sta   (PTR1),y
            jmp   OPENERR
:cpd        cpy   #2
            bcc   :out
            dey
            lda   (PTR1),y
            cmp   #DSLASH
            bne   :unstrip
            lda   #0
            sta   (PTR1),y
            bra   :cpd
:unstrip    iny
:out        tya
            rts

*---------------------------------------------------------------
* GFISTAT -- IN: PTR0 = display path, PTR1 = PATHnBUF.
* OUT: A = 1 if it names a directory, else 0. Leaves the MLI
* path in PTR1's buffer. A path MKPATH refuses is OPENERR (it
* can name nothing real). A GET_FILE_INFO that FAILS answers 0:
* the open that follows reports the real error, and a path the
* MLI cannot stat but the kernel can open (/dev/null) still
* works as a plain file.
*---------------------------------------------------------------
GFISTAT     jsr   MKPATH
            bcc   :ok
            jmp   OPENERR
:ok         lda   PTR1
            sta   GFIPARM_PATH
            lda   PTR1+1
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :no
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :yes
            cmp   #$0F                  ;volume directory
            beq   :yes
:no         lda   #0
            rts
:yes        lda   #1
            rts

GFIPARM     dfb   PCOUNT_GFI
GFIPARM_PATH da   0
GFIPARM_ACC dfb   0
GFIPARM_FTYP dfb  0
GFIPARM_AUX da    0
GFIPARM_STYP dfb  0
GFIPARM_BLKS da   0
GFIPARM_MDATE da  0
GFIPARM_MTIME da  0
GFIPARM_CDATE da  0
GFIPARM_CTIME da  0

*---------------------------------------------------------------
* APPEND -- IN: PTR0 = DPn, A = its length, DF_TNAME = a name.
* Writes "/NAME" and a NUL after the old text. OUT: A = new
* length; carry SET = it exceeds MLI_PTH_MAXLN (caller refuses).
* DPn is sized for the longest write, so the refused string is
* never past its buffer.
*---------------------------------------------------------------
APPEND      sta   DF_TMP
            clc
            adc   PTR0
            sta   PTR1
            lda   PTR0+1
            adc   #0
            sta   PTR1+1
            lda   #DSLASH
            sta   (PTR1)
            inc   PTR1
            bne   :a1
            inc   PTR1+1
:a1         ldy   #0
:cp         lda   (DF_TNAME),y
            sta   (PTR1),y
            beq   :end
            iny
            bne   :cp
:end        tya
            sec
            adc   DF_TMP
            cmp   #MLI_PTH_MAXLN+1
            rts

*---------------------------------------------------------------
* INSREC -- insert the entry in RDREC into the list that starts
* at DF_LB and ends at DF_NTOP, keeping it sorted by name (byte
* order, STRCMP). Room is checked first: a full arena is
* OVERFLOW, never a dropped entry.
*---------------------------------------------------------------
INSREC      clc
            lda   DF_NTOP
            adc   #RECSZ
            sta   DF_S
            lda   DF_NTOP+1
            adc   #0
            sta   DF_S+1
            lda   #<NAMEEND
            cmp   DF_S
            lda   #>NAMEEND
            sbc   DF_S+1
            bcs   :room
            jmp   OVERFLOW
:room       lda   DF_LB
            sta   DF_P
            lda   DF_LB+1
            sta   DF_P+1
:scan       lda   DF_P
            cmp   DF_NTOP
            bne   :more
            lda   DF_P+1
            cmp   DF_NTOP+1
            beq   :found
:more       clc
            lda   DF_P
            adc   #1
            sta   PTR0
            lda   DF_P+1
            adc   #0
            sta   PTR0+1
            lda   #<RDREC+RD_NAME
            sta   PTR1
            lda   #>RDREC+RD_NAME
            sta   PTR1+1
            jsr   STRCMP
            cmp   #1
            beq   :found                ;record > new: go here
            clc
            lda   DF_P
            adc   #RECSZ
            sta   DF_P
            bcc   :scan
            inc   DF_P+1
            bra   :scan
:found      sec
            lda   DF_NTOP
            sbc   DF_P
            sta   DF_CNT
            lda   DF_NTOP+1
            sbc   DF_P+1
            sta   DF_CNT+1
            ora   DF_CNT
            beq   :place
            lda   DF_NTOP               ;source = last byte
            sec
            sbc   #1
            sta   DF_S
            lda   DF_NTOP+1
            sbc   #0
            sta   DF_S+1
            lda   DF_S                  ;dest = source + RECSZ
            clc
            adc   #RECSZ
            sta   DF_D
            lda   DF_S+1
            adc   #0
            sta   DF_D+1
:mv         lda   (DF_S)
            sta   (DF_D)
            lda   DF_S
            bne   :s1
            dec   DF_S+1
:s1         dec   DF_S
            lda   DF_D
            bne   :d1
            dec   DF_D+1
:d1         dec   DF_D
            lda   DF_CNT
            bne   :c1
            dec   DF_CNT+1
:c1         dec   DF_CNT
            lda   DF_CNT
            ora   DF_CNT+1
            bne   :mv
:place      lda   RDREC+RD_STYPE
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #$0F
            beq   :isdir
            lda   #0
            bra   :st
:isdir      lda   #1
:st         sta   (DF_P)
            ldy   #1
            ldx   #0
:nm         lda   RDREC+RD_NAME,x
            sta   (DF_P),y
            iny
            inx
            cpx   #16
            bne   :nm
            clc
            lda   DF_NTOP
            adc   #RECSZ
            sta   DF_NTOP
            bcc   :done
            inc   DF_NTOP+1
:done       rts

*---------------------------------------------------------------
* LISTDIR -- IN: A/X = MLI path of a directory, DF_LB = DF_NTOP.
* Reads every entry into the sorted list at DF_LB and CLOSES the
* directory before returning. A directory that will not open, or
* a read that fails, is OPENERR on side OERRIDX.
*---------------------------------------------------------------
LISTDIR     jsr   OPENDIR
            bcc   :rd
            jmp   OPENERR
:rd         lda   #<RDREC
            ldx   #>RDREC
            jsr   READDIR
            bcs   :end
            jsr   INSREC
            bra   :rd
:end        pha
            jsr   CLOSEDIR
            pla
            beq   :ok
            jmp   OPENERR
:ok         rts

*---------------------------------------------------------------
* LOADLISTS -- read DP1's directory then DP2's into the name
* arena at DF_NTOP; leave the cursors at the two list starts.
*---------------------------------------------------------------
LOADLISTS   lda   DF_NTOP
            sta   DF_CUR1
            sta   DF_LB
            lda   DF_NTOP+1
            sta   DF_CUR1+1
            sta   DF_LB+1
            lda   #1
            sta   OERRIDX
            lda   #<DP1
            sta   PTR0
            lda   #>DP1
            sta   PTR0+1
            lda   #<PATH1BUF
            sta   PTR1
            lda   #>PATH1BUF
            sta   PTR1+1
            jsr   MKPATH
            bcc   :m1
            jmp   OPENERR
:m1         lda   #<PATH1BUF
            ldx   #>PATH1BUF
            jsr   LISTDIR
            lda   DF_NTOP
            sta   DF_E1
            sta   DF_CUR2
            sta   DF_LB
            lda   DF_NTOP+1
            sta   DF_E1+1
            sta   DF_CUR2+1
            sta   DF_LB+1
            lda   #2
            sta   OERRIDX
            lda   #<DP2
            sta   PTR0
            lda   #>DP2
            sta   PTR0+1
            lda   #<PATH2BUF
            sta   PTR1
            lda   #>PATH2BUF
            sta   PTR1+1
            jsr   MKPATH
            bcc   :m2
            jmp   OPENERR
:m2         lda   #<PATH2BUF
            ldx   #>PATH2BUF
            jsr   LISTDIR
            lda   DF_NTOP
            sta   DF_E2
            lda   DF_NTOP+1
            sta   DF_E2+1
            rts

