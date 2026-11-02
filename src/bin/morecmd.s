*---------------------------------------------------------------
* morecmd.s -- more's keyboard (put by more.s). The console goes
* raw+noecho for the run (RAWENTER, the mode vi uses) and comes
* back cooked+echo at EVERY way out and around every child
* (RAWLEAVE/RAWBACK) -- a raw->shell handoff always restores.
* RAWKEY reads one key (arrows arrive framed as 3 bytes and map
* to k/j/space/b); ^Z is the cooperative stop vi does. CMDLOOP
* prompts, gathers a count, dispatches through KEYTAB. A
* forward-class command that ran out of file moves to the next
* file or ends the run (POSIX more's end-of-file rule).
*---------------------------------------------------------------

RAWENTER    lda   #FD_STDOUT
            ldx   #MP_RAWMODE
            jsr   SC_TTYMODE
            sta   SAVEMD
            lda   #1
            sta   RAWON
            lda   #MP_SIGTSTP
            ldx   #SIGA_CATCH
            jsr   SC_SIGNAL
            jmp   ALTENTER               ;-A: park the shell

RAWLEAVE    lda   RAWON
            beq   :r
            stz   RAWON
            jsr   ALTLEAVE               ;-A: restore it FIRST
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            lda   #FD_STDOUT
            ldx   SAVEMD
            jmp   SC_TTYMODE
:r          rts

RAWBACK     lda   #FD_STDOUT
            ldx   #MP_RAWMODE
            jsr   SC_TTYMODE
            lda   #1
            sta   RAWON
            rts

*-- ALTENTER / ALTLEAVE -- -A only: smcup / rmcup (ESC [ ? 1049
*-- h / l, docs/VI-ALTSCREEN.md; the kernel parks the shell's
*-- screen under this pid and restores it, or does so itself if
*-- the pager dies). Flushed at once, so the park precedes the
*-- first paint and the restore precedes a stop, spawn or exit.
ALTENTER    lda   OPT_A
            bne   :go
            rts
:go         lda   #<ALTONSEQ
            ldx   #>ALTONSEQ
            bra   ALTPUT
ALTLEAVE    lda   OPT_A
            bne   :go
            rts
:go         lda   #<ALTOFFSEQ
            ldx   #>ALTOFFSEQ
ALTPUT      ldy   PTR0                   ;PUTS clobbers PTR0;
            phy                          ;RUNCHILD's PATHRSLV
            ldy   PTR0+1                 ;left the child's path
            phy                          ;there for SC_SPAWN
            jsr   PUTSP
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            ply
            sty   PTR0+1
            ply
            sty   PTR0
            rts

ALTONSEQ    dfb   $9B,$DB,$BF,$B1,$B0,$B4,$B9,$E8,0 ;ESC[?1049h
ALTOFFSEQ   dfb   $9B,$DB,$BF,$B1,$B0,$B4,$B9,$EC,0 ;ESC[?1049l

*---------------------------------------------------------------
* RAWKEY -- one key from CMDFD. OUT: carry clear, A = the key
* (an arrow already mapped; ARROWFLG says so). Carry set: the
* read failed for good (EOF on the command fd, or an error
* other than a held ^Z -- that one parks and retries).
*---------------------------------------------------------------
RAWKEY      ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            stz   ARROWFLG
:rd         lda   CMDFD
            sta   RPARM_REF
            lda   #<KEYBUF
            sta   RPARM_BUF
            lda   #>KEYBUF
            sta   RPARM_BUF+1
            lda   #3
            sta   RPARM_REQ
            stz   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcc   :ok
            cmp   #ERR_INTR
            bne   :fail
            jsr   SC_SIGPEND
            cmp   #MP_SIGTSTP
            bne   :fail
            jsr   SUSPEND
            bra   :rd
:fail       sec
            rts
:ok         lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :fail
            lda   RPARM_TRANS
            cmp   #3
            bne   :one
            lda   KEYBUF
            cmp   #$9B
            bne   :one
            lda   KEYBUF+1
            cmp   #$DB
            bne   :one
            inc   ARROWFLG
            lda   KEYBUF+2
            cmp   #$C1                   ;up
            bne   :na
            lda   #"k"
            bra   :got
:na         cmp   #$C2                   ;down
            bne   :nb
            lda   #"j"
            bra   :got
:nb         cmp   #$C3                   ;right
            bne   :nc
            lda   #$A0
            bra   :got
:nc         cmp   #$C4                   ;left
            bne   :one
            lda   #"b"
            bra   :got
:one        lda   KEYBUF
:got        clc
            rts

*-- SUSPEND -- cooperative ^Z: cooked+echo for the shell, park,
*-- raw again and a fresh page when continued.
SUSPEND     jsr   RAWLEAVE               ;(-A: rmcup before the
            jsr   SC_STOP                ;stop, vi's VI_SUSPEND)
            jsr   RAWBACK
            jsr   ALTENTER
            jmp   REPAINT

*---------------------------------------------------------------
* LINEIN -- A = the prompt character; read a line into INBUF
* (NUL-ended, INLEN long) with our own echo: BS/DEL erase, ^U
* kills, RETURN ends, ESC cancels (carry set). Arrows ignored.
*---------------------------------------------------------------
LINEIN      ldx   #FD_STDOUT
            jsr   PUTC
            stz   INLEN
:k          jsr   RAWKEY
            bcs   :cancel
            ldy   ARROWFLG
            bne   :k
            cmp   #$8D
            beq   :done
            cmp   #$9B
            beq   :cancel
            cmp   #$88
            beq   :bs
            cmp   #$FF
            beq   :bs
            cmp   #$95
            beq   :kill
            cmp   #$A0
            bcc   :k
            ldy   INLEN
            cpy   #PATMAX
            bcs   :k
            sta   INBUF,y
            inc   INLEN
            ldx   #FD_STDOUT
            jsr   PUTC
            bra   :k
:done       ldy   INLEN
            lda   #0
            sta   INBUF,y
            clc
            rts
:cancel     sec
            rts
:bs         lda   INLEN
            beq   :k
            dec   INLEN
            jsr   RUBOUT
            bra   :k
:kill       lda   INLEN
            beq   :k
            dec   INLEN
            jsr   RUBOUT
            bra   :kill

*-- RUBOUT -- BS, space, BS.
RUBOUT      lda   #$88
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$88
            ldx   #FD_STDOUT
            jmp   PUTC

*-- INERASE -- back over what LINEIN echoed (prompt char too).
INERASE     ldx   INLEN
            inx
:bs         phx
            lda   #$88
            ldx   #FD_STDOUT
            jsr   PUTC
            plx
            dex
            bne   :bs
            lda   #<CEOLSEQ
            ldx   #>CEOLSEQ
            jmp   PUTSP

*---------------------------------------------------------------
* CMDLOOP -- prompt, count, command; until QUITFLG.
*---------------------------------------------------------------
CMDLOOP     lda   QUITFLG
            beq   :run
:leave      rts
:run        lda   OPT_E                  ;-e: the last line of
            beq   :prompt                ;the last file ends it
            lda   ATEOF
            beq   :prompt
            lda   ISLAST
            beq   :prompt
            bra   :quit
:prompt     lda   MSGUP                  ;a message is standing
            beq   :draw                  ;in for the prompt
            stz   MSGUP
            bra   :count
:draw       jsr   PROMPT
:count      stz   MP_CNT
            stz   MP_CNT+1
            stz   CNTSET
:key        jsr   RAWKEY
            bcs   :quit
            cmp   #"0"
            bcc   :notdig
            cmp   #"9"+1
            bcs   :notdig
            and   #$0F
            jsr   CNTDIGIT
            bra   :key
:notdig     pha
            jsr   ERASEPROMPT
            pla
            stz   FWDCLASS
            ldx   ATEOF                  ;forward AT the end-of-
            stx   WASEOF                 ;file prompt moves on;
            jsr   DISPATCH               ;reaching it: a prompt
            lda   QUITFLG
            bne   :leave
            lda   FWDCLASS
            beq   CMDLOOP
            lda   WASEOF
            beq   CMDLOOP
            lda   ISLAST                 ;forward at the end:
            bne   :quit                  ;next file, or out
            stz   MP_CNT
            stz   MP_CNT+1
            stz   CNTSET
            jsr   NEXTFILE
            jmp   CMDLOOP
:quit       lda   #1
            sta   QUITFLG
            rts

*-- CNTDIGIT -- MP_CNT = MP_CNT*10 + A.
CNTDIGIT    pha
            lda   MP_CNT
            sta   MP_TMP
            lda   MP_CNT+1
            sta   MP_TMP+1
            asl   MP_CNT
            rol   MP_CNT+1
            asl   MP_CNT
            rol   MP_CNT+1
            lda   MP_CNT
            clc
            adc   MP_TMP
            sta   MP_CNT
            lda   MP_CNT+1
            adc   MP_TMP+1
            sta   MP_CNT+1
            asl   MP_CNT
            rol   MP_CNT+1
            pla
            clc
            adc   MP_CNT
            sta   MP_CNT
            bcc   :nc
            inc   MP_CNT+1
:nc         lda   #1
            sta   CNTSET
            rts

*-- CNTDEF -- no count given: MP_CNT = A.
CNTDEF      ldx   CNTSET
            bne   :r
            sta   MP_CNT
            stz   MP_CNT+1
:r          rts

*---------------------------------------------------------------
* DISPATCH -- A = key -> its handler via KEYTAB (key, address).
*---------------------------------------------------------------
DISPATCH    ldx   #0
:lp         ldy   KEYTAB,x
            beq   :unknown
            cmp   KEYTAB,x
            beq   :hit
            inx
            inx
            inx
            bra   :lp
:hit        lda   KEYTAB+1,x
            sta   MP_TMP
            lda   KEYTAB+2,x
            sta   MP_TMP+1
            jmp   (MP_TMP)
:unknown    rts

KEYTAB      dfb   $A0
            da    K_SPACE
            dfb   "f"
            da    K_FWD
            dfb   $86
            da    K_FWD
            dfb   "b"
            da    K_BACK
            dfb   $82
            da    K_BACK
            dfb   "j"
            da    K_LINES
            dfb   $8D
            da    K_LINES
            dfb   $8A
            da    K_LINES
            dfb   "k"
            da    K_BACKL
            dfb   "d"
            da    K_HALF
            dfb   $84
            da    K_HALF
            dfb   "u"
            da    K_UHALF
            dfb   $95
            da    K_UHALF
            dfb   "s"
            da    K_SKIP
            dfb   "g"
            da    K_GOTO
            dfb   "G"
            da    K_GOEND
            dfb   "r"
            da    REPAINT
            dfb   $8C
            da    REPAINT
            dfb   "R"
            da    REPAINT
            dfb   "m"
            da    K_MARK
            dfb   $A7
            da    K_QUOTE
            dfb   "/"
            da    K_SLASH
            dfb   "?"
            da    K_QUEST
            dfb   "n"
            da    K_AGAIN
            dfb   "N"
            da    K_AGAINR
            dfb   $BD
            da    INFO
            dfb   $87
            da    INFO
            dfb   $BA
            da    K_COLON
            dfb   "v"
            da    K_VI
            dfb   "!"
            da    K_BANG
            dfb   "q"
            da    K_QUIT
            dfb   "Q"
            da    K_QUIT
            dfb   "Z"
            da    K_ZZ
            dfb   "h"
            da    HELP
            dfb   0

*---------------------------------------------------------------
* Forward motion.
*---------------------------------------------------------------
*-- SPACE: a screenful, or count lines.
K_SPACE     inc   FWDCLASS
            lda   CNTSET
            bne   K_LINESX
K_SCREEN    jsr   NEXTLN                 ;a full page forward
            jsr   ENSURE                 ;PAINTS from the top
            bcs   :scroll                ;after a clear when a
            lda   MP_LN                  ;next line exists --
            pha                          ;scrolling 23 rows in
            lda   MP_LN+1                ;cost 23 x ~23k cycles
            pha                          ;on native 80 (69% of
            jsr   CLEARSCR               ;a page turn; the card
            stz   PREVBLANK              ;scrolls for 800). TOP
            lda   PAGEROWS               ;is the page's first
            jsr   FILLROWS               ;line exactly, not
            pla                          ;derived from BOT, so
            sta   TOP+1                  ;`=` and `b` stay right
            pla                          ;on a short last page.
            sta   TOP                    ;At the end: nothing to
            rts                          ;clear for; the prompt
:scroll     lda   PAGEROWS               ;logic sees ATEOF as
            jsr   FILLROWS               ;before.
            jmp   TOPFROMBOT

*-- f ^F: a screenful, or count lines -- but a count past the
*-- screen shows only the final screenful.
K_FWD       inc   FWDCLASS
            lda   CNTSET
            beq   K_SCREEN
            lda   MP_CNT+1
            bne   :big
            lda   MP_CNT
            cmp   PAGEROWS
            bcc   K_LINESX
            beq   K_LINESX
:big        lda   BOT                    ;TOP = BOT+1+count-rows
            clc
            adc   #1
            sta   MP_LN
            lda   BOT+1
            adc   #0
            sta   MP_LN+1
            lda   MP_LN
            clc
            adc   MP_CNT
            sta   MP_LN
            lda   MP_LN+1
            adc   MP_CNT+1
            sta   MP_LN+1
            lda   MP_LN
            sec
            sbc   PAGEROWS
            sta   MP_LN
            bcs   :ok
            dec   MP_LN+1
:ok         jmp   GOTOLINE

*-- j RETURN ^J: count lines (default 1).
K_LINES     inc   FWDCLASS
            lda   #1
            jsr   CNTDEF
K_LINESX    jsr   FILLLINES
            jmp   TOPFROMBOT

*-- d ^D: half a screen; a count becomes the new half.
K_HALF      inc   FWDCLASS
            jsr   SETHALF
            lda   HALF
            sta   MP_CNT
            stz   MP_CNT+1
            bra   K_LINESX

*-- SETHALF -- a count on d/u resets HALF (clamped to 255).
SETHALF     lda   CNTSET
            beq   :r
            lda   MP_CNT+1
            beq   :small
            lda   #255
            sta   HALF
            rts
:small      lda   MP_CNT
            beq   :r
            sta   HALF
:r          rts

*-- s: a screenful starting count lines past the last shown.
K_SKIP      inc   FWDCLASS
            lda   #1
            jsr   CNTDEF
            lda   BOT
            clc
            adc   #1
            sta   MP_LN
            lda   BOT+1
            adc   #0
            sta   MP_LN+1
            lda   MP_LN
            clc
            adc   MP_CNT
            sta   MP_LN
            lda   MP_LN+1
            adc   MP_CNT+1
            sta   MP_LN+1
            jsr   SAVEPOS
            jmp   GOTOLINE

*---------------------------------------------------------------
* Backward motion -- all redraw from a new TOP.
*---------------------------------------------------------------
K_BACK      lda   PAGEROWS
            jsr   CNTDEF
            bra   BACKN
K_BACKL     lda   #1
            jsr   CNTDEF
            bra   BACKN
K_UHALF     jsr   SETHALF
            lda   HALF
            sta   MP_CNT
            stz   MP_CNT+1
*-- BACKN -- TOP -= MP_CNT (floor 0); redraw.
BACKN       lda   TOP
            sec
            sbc   MP_CNT
            sta   TOP
            lda   TOP+1
            sbc   MP_CNT+1
            sta   TOP+1
            bcs   :ok
            stz   TOP
            stz   TOP+1
:ok         jmp   REPAINT

*-- g: line count (default 1).  G: line count, or the end.
K_GOTO      lda   #1
            jsr   CNTDEF
            jsr   CNTTOLN
            jsr   SAVEPOS
            jmp   GOTOLINE
K_GOEND     lda   CNTSET
            beq   :end
            jsr   CNTTOLN
            jsr   SAVEPOS
            jmp   GOTOLINE
:end        jsr   SAVEPOS
            jmp   LASTSCREEN

*-- CNTTOLN -- MP_LN = MP_CNT - 1 (line numbers count from 1).
CNTTOLN     lda   MP_CNT
            sec
            sbc   #1
            sta   MP_LN
            lda   MP_CNT+1
            sbc   #0
            sta   MP_LN+1
            bcs   :r
            stz   MP_LN
            stz   MP_LN+1
:r          rts

*-- SAVEPOS -- '' remembers where a large movement left from.
SAVEPOS     lda   TOP
            sta   LASTPOS
            lda   TOP+1
            sta   LASTPOS+1
            rts

*-- GOTOLINE -- TOP = MP_LN if that line exists, else the last
*-- screenful; redraw.
GOTOLINE    jsr   ENSURE
            bcs   LASTSCREEN
            lda   MP_LN
            sta   TOP
            lda   MP_LN+1
            sta   TOP+1
            jmp   REPAINT

*-- LASTSCREEN -- scan to the end; TOP = TOTAL - rows; redraw.
LASTSCREEN  lda   #$FF
            sta   MP_LN
            lda   #$7F
            sta   MP_LN+1
            jsr   ENSURE                 ;runs the scan to EOF
            lda   TOTAL
            sec
            sbc   PAGEROWS
            sta   TOP
            lda   TOTAL+1
            sbc   #0
            sta   TOP+1
            bcs   :ok
            stz   TOP
            stz   TOP+1
:ok         jmp   REPAINT

*---------------------------------------------------------------
* Marks: m<letter> sets, '<letter> returns, '' the previous
* position.
*---------------------------------------------------------------
K_MARK      jsr   RAWKEY
            bcs   :r
            jsr   MARKIDX
            bcs   :r
            lda   TOP
            sta   MARKS,x
            lda   TOP+1
            sta   MARKS+1,x
:r          rts
K_QUOTE     jsr   RAWKEY
            bcs   :r
            cmp   #$A7
            beq   :prev
            jsr   MARKIDX
            bcs   :r
            lda   MARKS+1,x
            cmp   #$FF                   ;unset
            beq   :r
            lda   MARKS,x
            sta   MP_LN
            lda   MARKS+1,x
            sta   MP_LN+1
            jsr   SAVEPOS
            jmp   GOTOLINE
:prev       lda   LASTPOS
            sta   MP_LN
            lda   LASTPOS+1
            sta   MP_LN+1
            jsr   SAVEPOS
            jmp   GOTOLINE
:r          rts

*-- MARKIDX -- A = a letter -> X = its MARKS slot; carry set if
*-- not a-z.
MARKIDX     cmp   #"a"
            bcc   :bad
            cmp   #"z"+1
            bcs   :bad
            sec
            sbc   #"a"
            asl   a
            tax
            clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* Search: /pat ?pat n N. The pattern is a BRE for RE_MATCH; a
* leading ! inverts; an empty pattern repeats the last one.
*---------------------------------------------------------------
K_SLASH     stz   SRCHDIR
            lda   #"/"
            bra   SEARCHIN
K_QUEST     lda   #1
            sta   SRCHDIR
            lda   #"?"
SEARCHIN    jsr   LINEIN
            php
            jsr   INERASE
            plp
            bcc   :go
            rts
:go         stz   SRCHNOT
            ldx   #0
            lda   INBUF
            cmp   #"!"
            bne   :copy
            inc   SRCHNOT
            inx
:copy       ldy   #0
:cp         lda   INBUF,x
            sta   PATBUF,y
            beq   :copied
            inx
            iny
            bne   :cp
:copied     lda   PATBUF
            bne   :fresh
            lda   HAVEPAT                ;empty: the last one
            beq   :nopat
            lda   LASTNOT
            sta   SRCHNOT
            bra   DOSEARCH
:fresh      lda   #1
            sta   HAVEPAT
            lda   SRCHDIR
            sta   LASTDIR
            lda   SRCHNOT
            sta   LASTNOT
            bra   DOSEARCH
:nopat      lda   #<NOPATMSG
            ldx   #>NOPATMSG
            jmp   MSG

K_AGAIN     lda   LASTDIR
            sta   SRCHDIR
            bra   AGAINGO
K_AGAINR    lda   LASTDIR
            eor   #1
            sta   SRCHDIR
AGAINGO     lda   LASTNOT
            sta   SRCHNOT
            lda   HAVEPAT
            beq   :nopat
            bra   DOSEARCH
:nopat      lda   #<NOPATMSG
            ldx   #>NOPATMSG
            jmp   MSG

*-- DOSEARCH -- from TOP+1 forward (or TOP-1 back), the count'th
*-- line matching (or not): it becomes TOP.
DOSEARCH    lda   #1
            jsr   CNTDEF
            lda   OPT_I
            beq   :nofold
            ldy   #0
:fp         lda   PATBUF,y
            jsr   FOLDCH
            sta   PATFOLD,y
            beq   :nofold
            iny
            bne   :fp
:nofold     lda   TOP
            sta   MP_LN
            lda   TOP+1
            sta   MP_LN+1
:step       lda   SRCHDIR
            bne   :back
            inc   MP_LN
            bne   :test
            inc   MP_LN+1
            bra   :test
:back       lda   MP_LN
            ora   MP_LN+1
            bne   :bk
            jmp   NOTFOUND
:bk         lda   MP_LN
            bne   :dl
            dec   MP_LN+1
:dl         dec   MP_LN
:test       jsr   ENSURE
            bcc   :have
            jmp   NOTFOUND
:have       jsr   FETCH
            lda   OPT_I
            beq   :match
            ldy   #0
:fl         lda   LINEBUF,y
            beq   :match
            jsr   FOLDCH
            sta   LINEBUF,y
            iny
            bne   :fl
:match      lda   #<LINEBUF
            sta   PTR0
            sta   PTR2
            lda   #>LINEBUF
            sta   PTR0+1
            sta   PTR2+1
            lda   #<PATBUF
            ldx   #>PATBUF
            ldy   OPT_I
            beq   :pat
            lda   #<PATFOLD
            ldx   #>PATFOLD
:pat        sta   PTR1
            stx   PTR1+1
            jsr   RE_MATCH
            lda   #0
            rol   a                      ;A = 1 no match
            eor   #1                     ;A = 1 matched
            eor   SRCHNOT
            beq   :step
            lda   MP_CNT                 ;a hit: the count'th?
            bne   :dc
            dec   MP_CNT+1
:dc         dec   MP_CNT
            lda   MP_CNT
            ora   MP_CNT+1
            bne   :step
            jsr   SAVEPOS
            lda   MP_LN
            sta   TOP
            lda   MP_LN+1
            sta   TOP+1
            jmp   REPAINT
NOTFOUND    lda   #<NOTFNDMSG
            ldx   #>NOTFNDMSG
            jmp   MSG

*-- FOLDCH -- A-Z -> a-z (high-bit ASCII), for -i.
FOLDCH      cmp   #"A"
            bcc   :r
            cmp   #"Z"+1
            bcs   :r
            ora   #$20
:r          rts

*---------------------------------------------------------------
* : commands -- n p e q t.
*---------------------------------------------------------------
K_COLON     jsr   RAWKEY
            bcs   :r
            cmp   #"n"
            beq   :next
            cmp   #"p"
            beq   :prev
            cmp   #"q"
            beq   K_QUIT
            cmp   #"e"
            beq   :exam
:r          rts
:next       lda   #1
            jsr   CNTDEF
            jmp   NEXTFILE
:prev       lda   #1
            jsr   CNTDEF
            jmp   PREVFILE
:exam       jmp   EXAMINE

K_QUIT      lda   #1
            sta   QUITFLG
            rts
K_ZZ        jsr   RAWKEY
            bcs   :r
            cmp   #"Z"
            beq   K_QUIT
:r          rts

*-- NEXTFILE -- the count'th next operand that opens; none left
*-- ends the run.
NEXTFILE    lda   NFILES
            beq   :r
            lda   #1
            jsr   CNTDEF
:n          inc   CURIDX
            lda   CURIDX
            cmp   ARGC
            bcs   :none
            jsr   OPENCUR
            bcs   :n
            lda   MP_CNT
            bne   :dl
            dec   MP_CNT+1
:dl         dec   MP_CNT
            lda   MP_CNT
            ora   MP_CNT+1
            bne   :n
            jmp   SHOWFIRST
:none       lda   #1
            sta   QUITFLG
:r          rts

*-- PREVFILE -- the count'th previous operand that opens; at the
*-- first, the first again.
PREVFILE    lda   NFILES
            beq   :r
            lda   #1
            jsr   CNTDEF
:p          lda   CURIDX
            cmp   OPTIND
            beq   :first
            dec   CURIDX
            jsr   OPENCUR
            bcs   :p
            lda   MP_CNT
            bne   :dl
            dec   MP_CNT+1
:dl         dec   MP_CNT
            lda   MP_CNT
            ora   MP_CNT+1
            bne   :p
            jmp   SHOWFIRST
:first      jsr   OPENCUR
            bcs   :none
            jmp   SHOWFIRST
:none       lda   #1
            sta   QUITFLG
:r          rts

*-- EXAMINE -- :e name: open it in place of the current file
*-- (the current one stays if it will not open); empty = the
*-- current file again from the top.
EXAMINE     lda   #"e"
            jsr   LINEIN
            php
            jsr   INERASE
            plp
            bcc   :go
            rts
:go         lda   INBUF
            bne   :named
            jmp   :reopen
:named      lda   #<INBUF
            sta   PTR0
            lda   #>INBUF
            sta   PTR0+1
            lda   #<TMPPATH2
            sta   PTR1
            lda   #>TMPPATH2
            sta   PTR1+1
            jsr   MKPATH
            lda   #<TMPPATH2
            sta   OPARM_PATH
            lda   #>TMPPATH2
            sta   OPARM_PATH+1
            stz   OPARM_IOBUF
            stz   OPARM_IOBUF+1
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            php
            lda   #<PATHBUF
            sta   OPARM_PATH
            lda   #>PATHBUF
            sta   OPARM_PATH+1
            plp
            bcs   :cant
            lda   OPARM_REF
            pha
            jsr   CLOSECUR
            pla
            sta   RDFD
            stz   ISSTDIN
            ldy   #64                    ;the path becomes the
:cp         lda   TMPPATH2,y             ;current one, the name
            sta   PATHBUF,y              ;the typed text
            dey
            bpl   :cp
            ldy   #PATMAX
:cn         lda   INBUF,y
            sta   EXNAME,y
            dey
            bpl   :cn
            lda   #<EXNAME
            sta   CURNAME
            lda   #>EXNAME
            sta   CURNAME+1
            jsr   TABRESET
            jsr   SIZEFROMFD
            lda   #1                     ;ISLAST stays as the
            sta   ISLAST                 ;operand list says; an
            lda   NFILES                 ;examined file is last
            beq   :show                  ;unless operands remain
            jsr   CALCLAST
:show       jsr   CLEARSCR
            jmp   SHOWFIRST
:cant       lda   #<CANTMSG
            ldx   #>CANTMSG
            jmp   MSG
:reopen     jsr   REOPEN
            bcs   :r
            jsr   CLEARSCR
            jmp   SHOWFIRST
:r          rts

*-- REOPEN -- the current file again (PATHBUF), table reset.
REOPEN      lda   ISSTDIN
            bne   :bad
            jsr   CLOSECUR
            stz   OPARM_IOBUF
            stz   OPARM_IOBUF+1
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :bad
            lda   OPARM_REF
            sta   RDFD
            jsr   TABRESET
            jsr   SIZEFROMFD
            clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* v -- vi on the current file; back to the same place after,
* re-read (vi may have rewritten it).
*---------------------------------------------------------------
K_VI        lda   ISSTDIN
            beq   :file
            lda   #<NOFILEMSG
            ldx   #>NOFILEMSG
            jmp   MSG
:file       lda   #<VIWORD
            sta   ARGVB
            lda   #>VIWORD
            sta   ARGVB+1
            lda   CURNAME
            sta   ARGVB+2
            lda   CURNAME+1
            sta   ARGVB+3
            stz   ARGVB+4
            stz   ARGVB+5
            lda   #<VIWORD
            ldx   #>VIWORD
            jsr   RUNCHILD
            bcs   :novi
            jsr   ALTENTER               ;-A: vi's own rmcup put
            lda   TOP                    ;the shell screen back
            sta   MP_LN
            lda   TOP+1
            sta   MP_LN+1
            jsr   REOPEN
            bcs   :gone
            jmp   GOTOLINE
:gone       lda   #1
            sta   QUITFLG
            rts
:novi       ldy   #<NOVIMSG              ;A = RUNCHILD's errno
            ldx   #>NOVIMSG
            jmp   :why

*---------------------------------------------------------------
* !command -- the line goes into MORE.CMDxx and `sh` runs it
* (ex's own `!` route: sh has no -c). The output scrolls the
* page; r redraws.
*---------------------------------------------------------------
K_BANG      lda   #"!"
            jsr   LINEIN
            bcc   :go1
            rts
:go1        lda   INLEN
            bne   :go2
            rts
:go2        lda   #<CMDLIT
            ldx   #>CMDLIT
            jsr   TMPNAMESET             ;TMPNAME/TMPPATH -- the
            ldy   #64                    ;spill's name is not
:cp         lda   TMPPATH,y              ;needed again: it was
            sta   CMDPATH,y              ;MKPATHed at open
            dey
            bpl   :cp
            ldy   #11
:cn         lda   TMPNAME,y
            sta   CMDNAME,y
            dey
            bpl   :cn
            lda   #<CMDPATH
            ldx   #>CMDPATH
            jsr   TMPCREATE
            bcc   :made
            jmp   :nosh
:made       lda   #1
            sta   CMDFILE
            lda   OPARM_REF
            sta   WPARM_REF
            sta   CPARM_REF
            ldy   INLEN
            lda   #$8D
            sta   INBUF,y
            iny
            sty   WPARM_REQ
            stz   WPARM_REQ+1
            lda   #<INBUF
            sta   WPARM_BUF
            lda   #>INBUF
            sta   WPARM_BUF+1
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            lda   #<SHWORD
            sta   ARGVB
            lda   #>SHWORD
            sta   ARGVB+1
            lda   #<CMDNAME
            sta   ARGVB+2
            lda   #>CMDNAME
            sta   ARGVB+3
            stz   ARGVB+4
            stz   ARGVB+5
            lda   #<SHWORD
            ldx   #>SHWORD
            jsr   RUNCHILD
            bcs   :nosh
            lda   OPT_A
            beq   :plain
            lda   #<BANGDONE             ;-A: the output is on
            ldx   #>BANGDONE             ;the shell screen: mark
            jsr   PUTSP                  ;it, wait for a key,
            lda   #$8D                   ;back to the page
            ldx   #FD_STDOUT             ;(less "!done"); the CR
            jsr   PUTC                   ;leaves the parked
            jsr   RAWKEY                 ;cursor at a line start
            jsr   ALTENTER               ;for the shell's prompt
            jmp   REPAINT
:plain      lda   #<BANGDONE
            ldx   #>BANGDONE
            jmp   MSG
:nosh       ldy   #<NOSHMSG              ;A = RUNCHILD's errno
            ldx   #>NOSHMSG
:why        cmp   #ERR_NOMEM             ;the machine's reason:
            bne   :nm1                   ;a full table is not a
            ldy   #<NOPROCMSG            ;vi or sh that cannot
            ldx   #>NOPROCMSG            ;be run
            bra   :say
:nm1        cmp   #ERR_NFILE
            bne   :say
            ldy   #<NFULLMSG
            ldx   #>NFULLMSG
:say        tya
            jmp   MSG

*-- RUNCHILD -- A/X = the command word (PATHRSLV finds it),
*-- ARGVB built: cooked console, a fresh line, spawn, wait, raw
*-- again. Carry set when it could not be run.
RUNCHILD    sta   PTR0
            stx   PTR0+1
            jsr   PATHRSLV
            bcs   :fail0
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   RAWLEAVE
            lda   #<ARGVB
            sta   PTR1
            lda   #>ARGVB
            sta   PTR1+1
            lda   #FDACT_END
            sta   FDACT
            lda   #<FDACT
            sta   PTR2
            lda   #>FDACT
            sta   PTR2+1
            stz   SPWN_ENVP
            stz   SPWN_ENVP+1
            jsr   SC_SPAWN
            bcs   :back
            lda   #<WSTAT
            sta   PTR0
            lda   #>WSTAT
            sta   PTR0+1
            jsr   SC_WAIT
            jsr   RAWBACK
            clc
            rts
:back       pha                          ;the errno: the caller
            jsr   RAWBACK                ;names the cause
            jsr   ALTENTER               ;-A: the page again,
            lda   OPT_A                  ;then the caller's
            beq   :bk                    ;message on it
            jsr   REPAINT
:bk         pla
            sec
            rts
:fail0      lda   #0                     ;not a spawn refusal
:fail       sec
            rts

VIWORD      asc   "vi"
            dfb   0
SHWORD      asc   "sh"
            dfb   0
NOPATMSG    asc   "No previous regular expression"
            dfb   0
NOTFNDMSG   asc   "Pattern not found"
            dfb   0
CANTMSG     asc   "Cannot open that file"
            dfb   0
NOFILEMSG   asc   "No file to edit"
            dfb   0
NOVIMSG     asc   "more: cannot run vi"
            dfb   0
NOSHMSG     asc   "more: cannot run sh"
            dfb   0
NOPROCMSG   asc   'more: no more processes'
            dfb   0
NFULLMSG    asc   'more: file table full'
            dfb   0
BANGDONE    asc   "------"
            dfb   0
