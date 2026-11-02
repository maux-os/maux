*---------------------------------------------------------------
* shedit.s -- sh's line editor for the interactive console
* prompt (docs/TAB-A2.md; TAB-A2-NOTES.md). `put` by sh.s into
* the $D000 segment: CODE only, run by the CPU, so nothing here
* is ever handed to a syscall -- every buffer a syscall sees
* (the stage, the read buffer, LINEBUF) is in the arena.
*
* WHEN IT RUNS. READLINE calls ED_LINE only when SH_EDIT is set
* (START: fd 0 is a console) and CUR_IN_FD is fd 0. A script, a
* sourced file, `sh < file`, a $( ) child and a pipe never get
* here, and ED_LINE hands the line back to the old byte path
* (X = $FF) if SYS_TTYMODE refuses the fd.
*
* THE BRACKET (architect ruling, TAB-A2.md). Per line: raw,
* no echo, OPOST kept (a CR is a newline, as the kernel
* editor's output assumes); INT and TSTP to CATCH (previous
* actions saved); this process declared the console's foreground
* job ({1, self}, the SYS_TCSETFG self-declare), so ^C/^Z reach
* it as pending signals. A lone $8D read is Return OR the
* phantom line a ^C/^Z leaves, so it is told apart by
* SC_SIGPEND (learning:01M284J8X2HESJQ9VQHP8RRD5C, the rule;
* learning:01M56Q7BH2T3B9TPX7FM47Q0VC, why the shell needs it).
* ED_EXIT undoes all of it on EVERY path, before the line is
* parsed or anything is spawned.
*
* DISPLAY: relative motion only. The glass cursor is tracked as
* an INDEX into the line (ED_CUR); index i sits at row (S+i)/W,
* column (S+i)%W with S = the prompt's two cells and W the
* console's columns. The prompt is ASSUMED to start in column 0
* (the kernel editor reads VC_COL; a process cannot): after
* output with no final newline the wrap points the editor
* believes in are off by the prompt's real column. The line
* itself is always right -- it is a buffer -- and so is what
* runs; only an edit that crosses a row boundary on such a
* line can leave the glass untidy. (Moving the prompt to a fresh
* row instead changes the glass check-vt102 pins.)
* Painting resolves a deferred wrap the moment a character lands
* in the last column (a CR, which is a newline under OPOST),
* exactly the kernel editor's TTY_ED_ECHO, so the model is the
* immediate-wrap one its back-walk assumed. Motion is CUU/CUD/
* CUF/CUB only, relative to the tracked index, so a scroll
* during a paint cannot strand it.
*---------------------------------------------------------------
ED_PROMPTW  equ   2          ;"$ " and "> " are two cells
ED_OUTMAX   equ   176        ;flush the stage past this
ED_NKEYS    equ   17
ED_BLANK    equ   $A0    ;high-bit space, '[' and '1' as named
ED_LBRK     equ   $DB    ;constants (check-encoding's pin counts
ED_ONE      equ   $B1    ;bare high-bit immediates)

*---------------------------------------------------------------
* ED_INIT -- START, once: SH_EDIT, and an empty history (the
* ring is dead-copy storage, sh.s: the segments' source bytes on
* a cold spawn, the last run's on a warm respawn, so it is
* established here, not assumed: ED_HN/ED_HUSED say what is
* in it and nothing reads the ring before ED_HN does).
*---------------------------------------------------------------
ED_INIT     stz   SH_EDIT
            stz   ED_HN
            stz   ED_HUSED
            stz   ED_HUSED+1
            stz   ED_NOPROG
            lda   SH_INTERACT
            beq   :out
            lda   SH_NOEDIT          ;sh -E: the kernel's editor
            bne   :out
            jsr   ED_GEO             ;carry clear: a console
            bcs   :out
            inc   SH_EDIT
:out        rts

*-- ED_W := the console's columns; carry as SC_TTYGEO's.
ED_GEO      lda   #<ED_GEOBUF
            sta   PTR0
            lda   #>ED_GEOBUF
            sta   PTR0+1
            lda   #FD_STDIN
            jsr   SC_TTYGEO
            lda   ED_GEOBUF
            sta   ED_W
            rts

*---------------------------------------------------------------
* The stage: ED_OUT[0..ED_OUTN) goes out in ONE SC_WRITE.
*---------------------------------------------------------------
*-- ED_PUT stages A with no flush check (X, Y kept); ED_OUTB
*-- stages and flushes past ED_OUTMAX. The 16 spare bytes cover
*-- a
*-- run of ED_PUTs (one CSI is seven).
ED_PUT      phx
            ldx   ED_OUTN
            sta   ED_OUT,x
            inc   ED_OUTN
            plx
            rts

ED_OUTB     jsr   ED_PUT
            lda   ED_OUTN
            cmp   #ED_OUTMAX
            bcc   :out
            jmp   ED_FLUSH
:out        rts

ED_FLUSH    lda   ED_OUTN
            beq   :out
            sta   PUTS_WPRM_REQ
            stz   PUTS_WPRM_REQ+1
            lda   #FD_STDERR
            sta   PUTS_WPRM_REF
            lda   #<ED_OUT
            sta   PUTS_WPRM_BUF
            lda   #>ED_OUT
            sta   PUTS_WPRM_BUF+1
            lda   #PCOUNT_WRITE
            sta   PUTS_WPARM
            lda   #<PUTS_WPARM
            ldx   #>PUTS_WPARM
            jsr   SC_WRITE
            stz   ED_OUTN
:out        cli                      ;ends ED_LINE's masked path
            rts

*-- ESC [ <A decimal> <X = final>
ED_CSI      phx
            pha
            lda   #$9B
            jsr   ED_PUT
            lda   #ED_LBRK
            jsr   ED_PUT
            pla
            jsr   ED_NUM
            pla
            jmp   ED_PUT

*-- A (0..159) as decimal, no leading zeros.
ED_NUM      ldy   #0
            cmp   #100
            bcc   :t
            sbc   #100
            pha
            lda   #ED_ONE
            jsr   ED_PUT
            pla
            ldy   #1
:t          ldx   #0
:tl         cmp   #10
            bcc   :td
            sbc   #10
            inx
            bra   :tl
:td         pha
            txa
            bne   :pt
            tya
            beq   :u
            txa
:pt         ora   #$B0
            jsr   ED_PUT
:u          pla
            ora   #$B0
            jmp   ED_PUT

*---------------------------------------------------------------
* ED_RC -- A = a line index -> X = row, A = column.
*---------------------------------------------------------------
ED_RC       clc
            adc   #ED_PROMPTW
            ldx   #0
:lp         cmp   ED_W
            bcc   :out
            sbc   ED_W
            inx
            bra   :lp
:out        rts

*---------------------------------------------------------------
* ED_MOVETO -- A = target index: relative motion from ED_CUR,
* columns then rows (ED_P0/ED_P1 hold {row, column}).
*---------------------------------------------------------------
ED_MOVETO   sta   ED_TGT
            lda   ED_CUR
            jsr   ED_RC
            stx   ED_P0
            sta   ED_P0+1
            lda   ED_TGT
            sta   ED_CUR
            jsr   ED_RC
            stx   ED_P1
            sta   ED_P1+1
            ldx   #1
:ax         lda   ED_P1,x
            cmp   ED_P0,x
            beq   :nx
            bcs   :plus
            lda   ED_P0,x
            sec
            sbc   ED_P1,x
            ldy   ED_FINN,x
            bra   :go
:plus       sbc   ED_P0,x
            ldy   ED_FINP,x
:go         phx
            phy
            plx
            jsr   ED_CSI
            plx
:nx         dex
            bpl   :ax
            rts
ED_FINN     dfb   $C1,$C4            ;CUU, CUB
ED_FINP     dfb   $C2,$C3            ;CUD, CUF

*---------------------------------------------------------------
* ED_PAINT -- print LINEBUF[ED_CUR .. A), cursor assumed at
* ED_CUR; a character in the last column resolves its deferred
* wrap at once. Leaves ED_CUR = A.
*---------------------------------------------------------------
ED_PAINT    sta   ED_PEND
:lp         lda   ED_CUR
            cmp   ED_PEND
            bcs   :done
            tax
            lda   LINEBUF,x
            jsr   ED_OUTB
            inc   ED_CUR
            lda   ED_CUR
            jsr   ED_RC
            cmp   #0
            bne   :lp
            lda   #$8D
            jsr   ED_OUTB
            bra   :lp
:done       rts

*---------------------------------------------------------------
* ED_LINE -- READLINE's console path. OUT: carry clear = a line
* in LINEBUF/LINELEN (an interrupted line is the empty line);
* carry set, X = 0 = end of file; carry set, X = $FF = not a
* console after all, read it the old way.
*---------------------------------------------------------------
ED_LINE     jsr   SIO_FLUSHALL
            stz   ED_OUTN
            stz   ED_RAWF            ;not ours yet
            lda   #2
            ldx   #SIGA_CATCH
            jsr   SC_SIGNAL
            sta   ED_PINT
            lda   #SIG_TSTP
            ldx   #SIGA_CATCH
            jsr   SC_SIGNAL
            sta   ED_PTSTP
            lda   #1
            sta   FG_PARM
            lda   BANK_ID
            sta   FG_PARM+1
            stz   FG_PARM+2
            stz   FG_PARM+3
*-- DECLARED BEFORE the console goes raw: a kill -9 in between
*-- finds the shell in its console's foreground set, so
*-- PRC_TMD_RST cooks the console; the other order left it raw
*-- for the parent.
            jsr   ED_SETFG
            bcs   :bail              ;refused
            lda   #FD_STDIN
            ldx   #TMD_OPOST
            jsr   SC_TTYMODE         ;raw, no echo, OPOST kept
            bcs   :bail              ;not a console after all
            sta   ED_MODE
            inc   ED_RAWF
            and   #TMD_ECHO          ;stty -echo: nothing may
            bne   :fgok              ;show as a line is typed;
:bail       jsr   ED_EXIT            ;we paint our own echo, so
:old        jsr   ED_PROMPT          ;the kernel's editor reads
            ldx   #$FF
            rts
:fgok       jsr   ED_GEO
            jsr   ED_PROMPT          ;ready: NOW show the prompt
            stz   ED_LEN
            stz   ED_POS
            stz   ED_CUR
            stz   ED_KESC
            stz   ED_INTR
            lda   #$FF
            sta   ED_HCUR
:key        jsr   ED_FLUSH
            jsr   SC_SIGPEND         ;a ^C that raced a paint
            cmp   #0
            beq   :rd
            jsr   ED_SIG
            bcc   :rd
            jmp   :intr
:rd         lda   #PCOUNT_READ
            sta   RL_PARM
            lda   #FD_STDIN
            sta   RL_PARM_REF
            lda   #<RL_BUF
            sta   RL_PARM_BUF
            lda   #>RL_BUF
            sta   RL_PARM_BUF+1
            lda   #3                 ;an arrow: ONE 3-byte line
            sta   RL_PARM_REQ
            stz   RL_PARM_REQ+1
            lda   #<RL_PARM
            ldx   #>RL_PARM
            jsr   SC_READ
            bcs   :rerr
            lda   RL_PRM_TRNS
            beq   :eof
            cmp   #1
            bne   :bytes
            lda   RL_BUF
            cmp   #$8D
            bne   :bytes
* A lone CR ends the line (Return, or ^C/^Z's phantom). The
* kernel cooks the NEXT queued key at the next tick, in whatever
* mode it finds. Raw, it commits it silent; cooked, but before
* our newline, it echoes it onto the end of the command row.
* Neither is right for a key typed right behind Return, and no
* ordering of {mode, newline} closes the gap while a tick can
* land in it.
* So the tick is held off for exactly this short path (mode, the
* signal check, the newline write -- ED_FLUSH unmasks): the key
* is then cooked AFTER the newline, in cooked mode, and echoed.
            sei
            jsr   SC_SIGPEND         ;Return, or ^C/^Z's phantom
            cmp   #0
            beq   :nosig
            jsr   ED_SIG
            bcs   :intr
:nosig      lda   ED_KESC            ;ESC [ ate this CR:
            cmp   #2                 ;line open, still raw
            beq   :bytes
            jsr   ED_COOK
:bytes      stz   ED_BI
:blp        ldx   ED_BI
            cpx   RL_PRM_TRNS
            bcs   :key
            lda   RL_BUF,x
            inc   ED_BI
            jsr   ED_KEY
            bcc   :blp
            cmp   #1
            beq   :eof
            bra   :fin               ;Return: READLINE adds the
                                     ;line to history once it is
                                     ;COMPLETE (SH-MLQUOTE)
:rerr       cmp   #ERR_INTR
            bne   :eof
            jsr   SC_SIGPEND
            cmp   #0
            bne   :rsig
            jmp   :key
:rsig       jsr   ED_SIG
            bcs   :intr
            jmp   :key
:intr       jsr   ED_INTRNL
            stz   ED_LEN
:fin        ldx   ED_LEN
            lda   #0
            sta   LINEBUF,x
            stx   LINELEN
            jsr   ED_EXIT
            ldx   #0                 ;never $FF here: that means
            clc                      ;"read it the old way"
            rts
:eof        jsr   ED_EXIT
            ldx   #0
            sec
            rts

*-- The prompt MAINLOOP left owing (ED_PRM): its character and a
*-- space, to the console. Printed only once the console is
*-- ours, so a key typed the instant it shows is the editor's.
ED_PROMPT   lda   ED_PRM
            beq   :out
            stz   ED_PRM
            lda   ED_PCH
            jsr   ED_OUTB
            lda   #ED_BLANK
            jsr   ED_OUTB
            jmp   ED_FLUSH
:out        rts

*-- Classify the pending signals (A = the first popped): INT and
*-- TSTP interrupt the line; a signal with a trap armed is held
*-- for PUMP_TRAP. Carry set = interrupted.
ED_SIG      tax
            cmp   #2
            beq   :int
            cmp   #SIG_TSTP
            bne   :hold
:int        stx   ED_INTR
:hold       jsr   SIG_PARK           ;armed: parked for
            bcc   :next              ;PUMP_TRAP, as SIG_RETRY
            lda   ED_LEN             ;does; an empty prompt runs
            ora   CSPTR              ;the trap NOW (no construct
            bne   :next              ;open); a typed line is
            stx   ED_INTR            ;finished first
:next       jsr   SC_SIGPEND
            cmp   #0
            bne   ED_SIG
            lda   ED_INTR
            cmp   #1
            rts

ED_SETFG    lda   #<FG_PARM
            sta   PTR0
            lda   #>FG_PARM
            sta   PTR0+1
            jmp   SC_TCSETFG

*-- Back to the mode the line found, once.
ED_COOK     lda   ED_RAWF
            beq   :out
            stz   ED_RAWF
            lda   #FD_STDIN
            ldx   ED_MODE
            jmp   SC_TTYMODE
:out        rts

*-- Undo the bracket on every path: mode first (above), then the
*-- foreground declaration, then the dispositions.
ED_EXIT     cli
            jsr   ED_COOK
            stz   FG_PARM
            jsr   ED_SETFG
            lda   #2
            ldx   ED_PINT
            jsr   SC_SIGNAL
            lda   #SIG_TSTP
            ldx   ED_PTSTP
            jsr   SC_SIGNAL
            jsr   SC_SIGPEND
            cmp   #0
            beq   :mode
            jsr   ED_SIG
:mode       rts

*-- ^C/^Z: the kernel painted ^C + a newline at the cursor.
*-- Add the newlines that put the next prompt below the WHOLE
*-- line: (end row - cursor row), less one if the two cells
*-- crossed a row (cursor in the last column).
ED_INTRNL   lda   ED_CUR
            jsr   ED_RC
            stx   ED_P0
            sta   ED_P0+1
            lda   ED_LEN
            jsr   ED_RC
            txa
            sec
            sbc   ED_P0
            sta   ED_T1
            lda   ED_P0+1
            inc   a
            cmp   ED_W
            bne   :go
            lda   ED_T1
            beq   :out
            dec   ED_T1
:go         lda   ED_T1
            beq   :out
            lda   #$8D
            jsr   ED_OUTB
            dec   ED_T1
            bra   :go
:out        jmp   ED_FLUSH

*---------------------------------------------------------------
* ED_KEY -- one input byte. OUT: carry clear = go on; carry set
* with A = 0 Return, A = 1 end of file. The kernel editor's
* state machine, fed bytes however they were framed: ESC then a
* letter is Meta, ESC [ then A..D an arrow, any other ESC pair
* types the second key.
*---------------------------------------------------------------
ED_KEY      and   #$7F
            sta   ED_K
            lsr   ED_NOPROG          ;TAB TAB: see TC_TAB
            ldx   ED_KESC
            beq   :s0
            stz   ED_KESC
            cpx   #2
            beq   :csi
            cmp   #$5B
            bne   :meta
            lda   #2
            sta   ED_KESC
            clc
            rts
:meta       ora   #$20               ;ESC F is ESC f
            ldx   #2
:ml         cmp   ED_MKEYS,x
            beq   :mhit
            dex
            bpl   :ml
            lda   ED_K
            bra   :disp
:mhit       ora   #$80
            bra   :disp
:csi        ldx   #3
:cl         cmp   ED_CSIK,x
            beq   :ch
            dex
            bpl   :cl
            clc
            rts
:ch         lda   ED_CSIC,x
            bra   :disp
:s0         cmp   #$1B
            bne   :disp
            lda   #1
            sta   ED_KESC
            clc
            rts
:disp       ldx   #ED_NKEYS-1
:dl         cmp   ED_KEYS,x
            beq   :dhit
            dex
            bpl   :dl
            cmp   #$20
            bcc   :drop
            cmp   #$7F
            bcs   :drop
            ora   #$80
            jmp   ED_INS
:drop       clc
            rts
:dhit       txa
            asl   a
            tax
            jmp   (ED_VECS,x)

ED_MKEYS    dfb   $66,$62,$6B        ;f b k
ED_CSIK     dfb   $41,$42,$43,$44    ;A B C D
ED_CSIC     dfb   $10,$0E,$06,$02    ;^P ^N ^F ^B
ED_KEYS     dfb   $01,$02,$04,$05,$06,$08,$0B,$0C
            dfb   $0D,$0E,$10,$15,$7F,$E6,$E2,$EB
            dfb   $09
            err   *-ED_KEYS-ED_NKEYS
ED_VECS     da    ED_HOME,ED_LEFT,ED_DEL,ED_END
            da    ED_RIGHT,ED_BS,ED_KEOL,ED_CL
            da    ED_CR,ED_HNXT,ED_HPRV,ED_KILL
            da    ED_BS,ED_WDF,ED_WDB,ED_KEOL
            da    TC_TAB

*---------------------------------------------------------------
* Handlers. Each returns carry clear (go on) unless it says so,
* leaving the glass cursor at ED_POS.
*---------------------------------------------------------------
ED_GOTO     sta   ED_POS
            jsr   ED_MOVETO
            clc
            rts

ED_HOME     lda   #0
            bra   ED_GOTO
ED_END      lda   ED_LEN
            bra   ED_GOTO
ED_LEFT     lda   ED_POS
            beq   ED_NOP
            dec   a
            bra   ED_GOTO
ED_RIGHT    lda   ED_POS
            cmp   ED_LEN
            bcs   ED_NOP
            inc   a
            bra   ED_GOTO
ED_NOP      clc
            rts

ED_CR       lda   ED_LEN
            jsr   ED_MOVETO
            lda   #$8D
            jsr   ED_OUTB
            jsr   ED_FLUSH
            lda   #0
            sec
            rts

*-- ^D: end of file on an empty line, else delete forward.
ED_DEL      lda   ED_LEN
            beq   :eof
            lda   ED_POS
            cmp   ED_LEN
            bcs   ED_NOP
            jsr   ED_DELCH
            clc
            rts
:eof        lda   #1
            sec
            rts

ED_BS       lda   ED_POS
            beq   ED_NOP
            dec   a
            sta   ED_POS
            jsr   ED_MOVETO
            jsr   ED_DELCH
            clc
            rts

*-- Remove LINEBUF[ED_POS] (cursor there): close the gap,
*-- repaint
*-- the tail and one blank over the vacated cell, walk back.
ED_DELCH    ldx   ED_POS
:mv         inx
            cpx   ED_LEN
            bcs   :mvd
            lda   LINEBUF,x
            sta   LINEBUF-1,x
            bra   :mv
:mvd        dec   ED_LEN
            ldx   ED_LEN
            lda   #ED_BLANK
            sta   LINEBUF,x
            lda   ED_LEN
            inc   a
            jsr   ED_PAINT
            lda   ED_POS
            jmp   ED_MOVETO

ED_INS      ldx   ED_LEN
            cpx   #ED_LENMAX
            bcs   ED_NOP
            pha
            ldx   ED_LEN
:mv         cpx   ED_POS
            beq   :put
            lda   LINEBUF-1,x
            sta   LINEBUF,x
            dex
            bra   :mv
:put        pla
            sta   LINEBUF,x
            inc   ED_LEN
            inc   ED_POS
            lda   ED_LEN
            jsr   ED_PAINT
            lda   ED_POS
            jsr   ED_MOVETO
            clc
            rts

*-- Blank [0, LEN) on the glass and empty the buffer.
ED_WIPE     lda   #0
            jsr   ED_MOVETO
            ldx   #0
:bl         cpx   ED_LEN
            beq   :bd
            lda   #ED_BLANK
            sta   LINEBUF,x
            inx
            bra   :bl
:bd         lda   ED_LEN
            jsr   ED_PAINT
            lda   #0
            jsr   ED_MOVETO
            stz   ED_LEN
            stz   ED_POS
            rts

ED_KILL     jsr   ED_WIPE
            clc
            rts

*-- M-k: truncate at the cursor.
ED_KEOL     lda   ED_LEN
            cmp   ED_POS
            beq   :nop
            ldx   ED_POS
:bl         lda   #ED_BLANK
            sta   LINEBUF,x
            inx
            cpx   ED_LEN
            bne   :bl
            lda   ED_LEN
            jsr   ED_PAINT
            lda   ED_POS
            sta   ED_LEN
            jsr   ED_MOVETO
:nop        clc
            rts

*-- ^L: home + clear (the parser's ESC [ 2 J alone does not
*-- home), the prompt again, the line, the cursor.
ED_CL       ldx   #0
:lp         stx   ED_T1
            lda   ED_CLR,x
            jsr   ED_OUTB
            ldx   ED_T1
            inx
            cpx   #7
            bne   :lp
ED_REDRAW   lda   ED_PCH
            jsr   ED_OUTB
            lda   #ED_BLANK
            jsr   ED_OUTB
            stz   ED_CUR
            lda   ED_LEN
            jsr   ED_PAINT
            lda   ED_POS
            jsr   ED_MOVETO
            clc
            rts
ED_CLR      dfb   $9B,$DB,$C8,$9B,$DB,$B2,$CA

*-- Carry set iff LINEBUF[A] is a word character (alnum).
ED_ISW      tax
            lda   LINEBUF,x
            and   #$7F
            cmp   #$30
            bcc   :no
            cmp   #$3A
            bcc   :yes
            cmp   #$41
            bcc   :no
            cmp   #$5B
            bcc   :yes
            cmp   #$61
            bcc   :no
            cmp   #$7B
            bcc   :yes
:no         clc
            rts
:yes        sec
            rts

*-- M-f / M-b: over non-word characters, then over the word, in
*-- direction ED_DIR (+1 / -1); backward examines the character
*-- BEFORE the position.
ED_WDF      lda   #1
            bra   ED_WD
ED_WDB      lda   #$FF
ED_WD       sta   ED_DIR
            lda   ED_POS
            sta   ED_T1
            stz   ED_PH              ;0 non-word, 1 word
:lp         lda   ED_DIR
            bmi   :bk
            lda   ED_T1
            cmp   ED_LEN
            bcs   :done
            bra   :ex
:bk         lda   ED_T1
            beq   :done
            dec   a
:ex         jsr   ED_ISW             ;carry: a word character
            lda   #0
            rol   a
            cmp   ED_PH
            beq   :step              ;the phase's kind: step
            lda   ED_PH
            bne   :done              ;word phase met a non-word
            inc   ED_PH              ;non-word phase met a word
:step       lda   ED_T1
            clc
            adc   ED_DIR
            sta   ED_T1
            bra   :lp
:done       lda   ED_T1
            jmp   ED_GOTO

