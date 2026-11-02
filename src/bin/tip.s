*---------------------------------------------------------------
* tip.s -- talk to the host over /dev/ttya0 (docs/SERIAL.md sec
* 3, docs/TASKS.md #22). fork()s: parent is the keyboard half
* (console -> line, raw+noecho, catches ^C/^Z, ~ escapes at line
* start), child is the line half (line -> console, ignores ^C).
* Console mode is 0 (strict VT102, docs/CONSOLE-VT102.md sec 3):
* tip does NOT fold the host's CR LF any more (VT102 slice 1,
* 2026-09-11) -- the console's own CR/LF handling renders a CR
* LF
* pair as one newline on its own, so folding here would double
* up. Bit 7 stripping stays (the host's high bit is not maux's).
* Gate: make check-tip (SERIAL.md 3e).
*
* Library notes (fetched before writing this file):
* learning:01M27HT1E4QBBFKGARYWBMMGRE (SSC: polled, jumper block
* is the null-modem); learning:01M27KGKPYZD5HY0TA3FSRDT63 (ROM
* page 7 signature only); learning:01M28001EKW3KDXM109P97AJHH
* (tick-context wake must restore K_CURBANK -- SER_POLL already
* does, tip's reads just ride it); learning:01M1AH9XWGC8ZS7HNBJ
* VJ2JHXW (screen gate: settle on two identical polls);
* learning:01M050C6KW01MPJ2TQTPMTZXN6 (13-char labels, 12 for a
* :local); learning:01M0VJF2DXZR55HGJ8PTN1MNJE (keep every
* loop's locals inside ONE global zone -- every :local below is
* defined and used within its own routine only).
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/errno.krn.equ
            org   LOAD_BASE
            dsk   ../../build/tip.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*---------------------------------------------------------------
* START -- open the line, save+raw the console, arm ^C/^Z, fork.
* CHILD_MAIN sits right after so `beq CHILD_MAIN` stays a short
* branch; the parent falls through to a `jmp PARENT_LOOP` (a JMP
* has no range limit).
*---------------------------------------------------------------
START       jsr   INITPARMS
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opened
            jsr   SAYNODEV
            lda   #1
            jsr   EXIT
:opened     lda   OPARM_REF
            sta   LINEFD

            lda   #FD_STDOUT            ;raw, no echo (both
            ldx   #0                    ;TMD_ICANON/TMD_ECHO
            jsr   SC_TTYMODE            ;clear) -- stty.s's own
            sta   SAVEMD                ;"stty raw -echo"

            lda   #2                    ;^C: parent CATCHes so
            ldx   #SIGA_CATCH           ;it can forward $03
            jsr   SC_SIGNAL
            lda   #SIG_TSTP             ;^Z: parent CATCHes so
            ldx   #SIGA_CATCH           ;it can forward $1A
            jsr   SC_SIGNAL

            jsr   SC_FORK
            bcc   :forkok
            jmp   FORKFAIL
:forkok     cmp   #0
            beq   CHILD_MAIN
            sta   CHPID
            lda   #1                    ;ATLOL: nothing typed
            sta   ATLOL                 ;yet = line start
            jmp   PARENT_LOOP

*---------------------------------------------------------------
* CHILD_MAIN/CHILD_LOOP -- 3c: line -> console. ^C ignored (the
* parent forwards it as a byte instead); ^Z caught and discarded
* (nothing would ever SYS_CONT a plain descendant). Bit 7 is
* stripped (the host's high bit is not maux's) but the bytes
* otherwise pass through UNCHANGED -- NO CR/LF fold any more
* (VT102 slice 1, 2026-09-11): the console's own strict-VT102
* terminal layer (tip's console mode is 0) already renders a
* host CR LF pair as one newline, so folding here would be
* redundant work undoing what the fold used to paper over.
*---------------------------------------------------------------
CHILD_MAIN  lda   #2
            ldx   #SIGA_IGN
            jsr   SC_SIGNAL
            lda   #SIG_TSTP
            ldx   #SIGA_CATCH
            jsr   SC_SIGNAL

CHILD_LOOP  lda   LINEFD
            sta   RPARM_REF
            lda   #<RBUF
            sta   RPARM_BUF
            lda   #>RBUF
            sta   RPARM_BUF+1
            lda   #64
            sta   RPARM_REQ
            stz   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcc   :gotdata
            cmp   #ERR_INTR
            bne   CHILD_LOOP             ;other error: retry
            jsr   SC_SIGPEND             ;drain and retry
            bra   CHILD_LOOP
:gotdata    lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   CHILD_LOOP
            ldy   #0                     ;strip bit 7 in place
:mask       cpy   RPARM_TRANS            ;(TRANS+1 is always 0
            beq   :cfwrite               ;here, a 64-byte read)
            lda   RBUF,y
            and   #$7F
            sta   RBUF,y
            iny
            bra   :mask
:cfwrite    lda   RPARM_TRANS            ;ONE write per read
            sta   WPARM_REQ
            stz   WPARM_REQ+1
            lda   #<RBUF
            sta   WPARM_BUF
            lda   #>RBUF
            sta   WPARM_BUF+1
            lda   #FD_STDOUT
            sta   WPARM_REF
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            jmp   CHILD_LOOP

*---------------------------------------------------------------
* PARENT_LOOP -- 3b: console -> line. Reads 1-3 raw bytes (the
* console's own framing -- an arrow is 3 bytes, a plain key 1);
* ERR_INTR forwards a held ^C/^Z as a plain byte on the line
* (never echoed locally); every other byte strips bit 7 and
* passes through PROCBYTE's ~ escape state machine.
*---------------------------------------------------------------
PARENT_LOOP lda   #FD_STDIN
            sta   RPARM_REF
            lda   #<RBUF
            sta   RPARM_BUF
            lda   #>RBUF
            sta   RPARM_BUF+1
            lda   #3
            sta   RPARM_REQ
            stz   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcc   :prok
            cmp   #ERR_INTR
            bne   PARENT_LOOP            ;other error: retry
            jsr   SC_SIGPEND
            cmp   #2
            bne   :prnotint
            lda   #$03
            jsr   SENDBYTE
            jmp   PARENT_LOOP
:prnotint   cmp   #SIG_TSTP
            bne   PARENT_LOOP            ;neither: ignore
            lda   #$1A
            jsr   SENDBYTE
            jmp   PARENT_LOOP
:prok       lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   PARENT_LOOP
*-- PHANTOM CR (learning: raw-arrows-framed-insert-erase, vi's
*-- own fix): a blocked raw read that a caught ^C/^Z wakes can
*-- come back with carry CLEAR and ONE byte, $8D -- the cook
*-- layer's phantom empty-CR line WINS the race against the
*-- pending signal. A bare CR must pop SC_SIGPEND to tell a
*-- phantom (signal pending) from a real RETURN (nothing
*-- pending -- fall through and send it like any other byte).
            lda   RPARM_TRANS+1
            bne   :pr_real
            lda   RPARM_TRANS
            cmp   #1
            bne   :pr_real
            lda   RBUF
            cmp   #$8D
            bne   :pr_real
            jsr   SC_SIGPEND
            cmp   #0
            beq   :pr_real               ;nothing pending: real
                                         ;RETURN, not a phantom
            cmp   #2
            bne   :pr_nott2
            lda   #$03
            jsr   SENDBYTE
            jmp   PARENT_LOOP
:pr_nott2   cmp   #SIG_TSTP
            beq   :pr_tstp
            jmp   PARENT_LOOP            ;neither: ignore
:pr_tstp    lda   #$1A
            jsr   SENDBYTE
            jmp   PARENT_LOOP
:pr_real    stz   PIDX
:prloop2    lda   PIDX
            cmp   RPARM_TRANS
            bcc   :pr_have
            jmp   PARENT_LOOP
:pr_have    tay
            lda   RBUF,y
            and   #$7F
            jsr   PROCBYTE
            inc   PIDX
            bra   :prloop2

*---------------------------------------------------------------
* PROCBYTE -- the ~ escape state machine (SERIAL.md 3b item 5).
* IN: A = one console byte, bit 7 already stripped. Escapes are
* recognised ONLY when ATLOL is set (previous byte SENT to the
* line was CR, or nothing sent yet).
*---------------------------------------------------------------
PROCBYTE    sta   BSCRATCH
            lda   ESCPEND
            beq   :pbnoesc
            stz   ESCPEND
            lda   BSCRATCH
            cmp   #'.'
            beq   :pbdisc
            cmp   #'?'
            beq   :pblist
            cmp   #'~'
            beq   :pbtilde
            lda   #'~'                  ;~X, X not . ? ~: send
            jsr   SENDBYTE               ;both bytes verbatim
            lda   BSCRATCH
            jsr   SENDBYTE
            lda   BSCRATCH
            cmp   #$0D
            bne   :pbnotcr
            lda   #1
            sta   ATLOL
            rts
:pbnotcr    stz   ATLOL
            rts
:pbtilde    lda   #'~'
            jsr   SENDBYTE
            stz   ATLOL
            rts
:pblist     jsr   PRESCLIST
            rts                         ;ATLOL unchanged: line
                                        ;untouched
:pbdisc     jmp   DISCONNECT
:pbnoesc    lda   ATLOL
            beq   :pbsend
            lda   BSCRATCH
            cmp   #'~'
            bne   :pbsend
            lda   #1
            sta   ESCPEND               ;swallow the ~, wait for
            rts                         ;the next byte
:pbsend     lda   BSCRATCH
            jsr   SENDBYTE
            lda   BSCRATCH
            cmp   #$0D
            bne   :pbnotcr2
            lda   #1
            sta   ATLOL
            rts
:pbnotcr2   stz   ATLOL
            rts

*---------------------------------------------------------------
* SENDBYTE -- write ONE byte to the line fd. IN: A = byte.
*---------------------------------------------------------------
SENDBYTE    sta   WBUF
            lda   #1
            sta   WPARM_REQ
            stz   WPARM_REQ+1
            lda   #<WBUF
            sta   WPARM_BUF
            lda   #>WBUF
            sta   WPARM_BUF+1
            lda   LINEFD
            sta   WPARM_REF
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            rts

*---------------------------------------------------------------
* PRESCLIST -- `~?`: the escape list, to the console only.
*---------------------------------------------------------------
PRESCLIST   lda   #<ESCLIST
            sta   PTR0
            lda   #>ESCLIST
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts

*---------------------------------------------------------------
* DISCONNECT -- `~.`: kill the child, reap it, restore the
* console (cooked+echo -- every raw-to-shell handoff restores
* it, the vi ^Z lesson), announce, close, exit 0.
*---------------------------------------------------------------
DISCONNECT  lda   CHPID
            ldx   #15
            jsr   SC_KILL
            lda   #<WAITBUF
            sta   PTR0
            lda   #>WAITBUF
            sta   PTR0+1
            jsr   SC_WAIT
            jsr   RESTOREMD
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #<EOTMSG
            sta   PTR0
            lda   #>EOTMSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   LINEFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* RESTOREMD -- console mode back to what it was at entry.
*---------------------------------------------------------------
RESTOREMD   lda   #FD_STDOUT
            ldx   SAVEMD
            jsr   SC_TTYMODE
            rts

*---------------------------------------------------------------
* FORKFAIL -- SC_FORK carried ERR_AGAIN: no bank free.
*---------------------------------------------------------------
FORKFAIL    jsr   SAYFORKF
            jsr   RESTOREMD
            lda   #1
            jsr   EXIT

SAYNODEV    lda   #<NODEVMSG
            sta   PTR0
            lda   #>NODEVMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            rts

*-- SAYFORKF runs from FORKFAIL, BEFORE RESTOREMD -- the console
*-- is still in tip's own raw mode (0, OPOST clear, VT102 slice
*-- 1) there, so a $8D would only return the column, not newline
*-- (docs/CONSOLE-VT102.md sec 3). $8A (LF) always advances,
*-- maux's kept deviation, mode-independent -- use it for any
*-- message tip prints to ITS OWN raw console, not $8D.
SAYFORKF    lda   #<FORKFMSG
            sta   PTR0
            lda   #>FORKFMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8A
            ldx   #FD_STDERR
            jsr   PUTC
            rts

*---------------------------------------------------------------
* INITPARMS -- the constant parmlist fields (docs/STICKY.md sec
* 21: nothing zeroes the arena, so only the genuinely constant
* cells are stored here; everything else is write-before-read).
*---------------------------------------------------------------
INITPARMS   lda   #PCOUNT_OPEN
            sta   OPARM
            lda   #<DEVPATH
            sta   OPARM_PATH
            lda   #>DEVPATH
            sta   OPARM_PATH+1
            lda   #PCOUNT_READ
            sta   RPARM
            lda   #PCOUNT_WRITE
            sta   WPARM
            lda   #PCOUNT_CLOSE
            sta   CPARM
            rts

DEVPATH     dfb   10
            asc   '/DEV/TTYA0'

NODEVMSG    asc   "tip: /dev/ttya0: no such device"
            dfb   0
FORKFMSG    asc   "tip: fork failed"
            dfb   0
EOTMSG      asc   "[EOT]"
            dfb   0
*-- $8A (LF), not $8D: PRESCLIST prints this to tip's OWN raw
*-- console (mode 0, OPOST clear) WHILE the session is live, so
*-- a CR here would only return the column (VT102 slice 1) -- LF
*-- always advances, mode-independent.
ESCLIST     asc   "~.  disconnect"
            dfb   $8A
            asc   "~?  this list"
            dfb   $8A
            asc   "~~  send ~"
            dfb   $8A,0

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* tip's own arena, chained onto liba's block (the house idiom).
* Read-before-write trace: LINEFD/SAVEMD/CHPID from START before
* any use; ATLOL set by START (parent) before PARENT_LOOP;
* ESCPEND only ever set then immediately cleared by PROCBYTE,
* read only right after being set; PIDX zeroed before
* PARENT_LOOP's byte loop; BSCRATCH/WBUF/RBUF are
* write-then-read
* scratch, every parmlist's constant fields come from INITPARMS,
* result fields are kernel-written before this program reads
* them, and every patched field (xPARM_REF/BUF/REQ) is set
* immediately before its own call.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
LINEFD      ds    1
SAVEMD      ds    1
CHPID       ds    1
ATLOL       ds    1
ESCPEND     ds    1
PIDX        ds    1
BSCRATCH    ds    1

RBUF        ds    64
WBUF        ds    1

OPARM       ds    1
OPARM_PATH  ds    2
OPARM_IOBUF ds    2
OPARM_REF   ds    1

RPARM       ds    1
RPARM_REF   ds    1
RPARM_BUF   ds    2
RPARM_REQ   ds    2
RPARM_TRANS ds    2

WPARM       ds    1
WPARM_REF   ds    1
WPARM_BUF   ds    2
WPARM_REQ   ds    2
WPARM_TRANS ds    2

CPARM       ds    1
CPARM_REF   ds    1

WAITBUF     ds    1
            err   */$BF00
            dend
