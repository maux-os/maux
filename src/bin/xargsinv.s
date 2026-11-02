*---------------------------------------------------------------
* xargsinv.s -- xargs's INVOKE and TRACEPRINT, split out of
* xargsrun.s 2026-09-21 for the vendored `as`'s 16,128-byte
* source window: manifest (8,201) plus its largest single put
* (xargsrun.s, 8,352) had reached 16,553, and a unit over that
* window cannot be rebuilt by maux itself.
*
* Split HERE because it is the seam between BUILDING a batch
* (above: RUN_NMODE, BB_NEED, RUN_IMODE) and RUNNING one. `put`
* by xargs.s at top level -- Merlin cannot nest a put inside a
* put file. This is the FOURTH unit to cross that window in one
* day; see docs/POSIX-GAPS.md sec 6b on what that costs.
*---------------------------------------------------------------
*---------------------------------------------------------------
* INVOKE -- ARGVLIST already NULL-terminated, RESPATH set.
* -t traces, spawns with fd 0 closed and no environment,
* waits, folding the child's status into FINALCODE (or exits
* fatally on an abnormal one).
* CLOBBERS: everything.
*---------------------------------------------------------------
INVOKE      lda   PFLAG
            beq   :nopr
            jsr   PROMPTYN              ;-p replaces -t's trace
            bcc   :nottr
            rts                         ;declined: not an error
:nopr       lda   TFLAG
            beq   :nottr
            jsr   TRACEPRINT
:nottr      stz   SPWN_ENVP
            stz   SPWN_ENVP+1
            lda   RESPATH
            sta   PTR0
            lda   RESPATH+1
            sta   PTR0+1
            lda   #<ARGVLIST
            sta   PTR1
            lda   #>ARGVLIST
            sta   PTR1+1
            lda   #<FDA_CLOSE0
            sta   PTR2
            lda   #>FDA_CLOSE0
            sta   PTR2+1
            jsr   SC_SPAWN
            bcc   :spawned
            ldx   #<XARGSPFX             ;A = the errno still
            ldy   #>XARGSPFX
            jsr   SPAWNWHY               ;no bank/file slot: say
            bcc   :cantinv               ;so. 126: found, but
            lda   #126                   ;could not be invoked
            jsr   EXIT                   ;(man page, POSIX)
:cantinv    lda   #<CANTINVOKE
            sta   PTR0
            lda   #>CANTINVOKE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #126
            jsr   EXIT
:spawned    lda   #<WSTATUS
            sta   PTR0
            lda   #>WSTATUS
            sta   PTR0+1
            jsr   SC_WAIT
            lda   WSTATUS
            beq   :ok
            bmi   :fatal
            lda   #123
            sta   FINALCODE
:ok         rts
:fatal      lda   #<ABORTMSG
            sta   PTR0
            lda   #>ABORTMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #124
            jsr   EXIT

*---------------------------------------------------------------
* TRACEPRINT -- ARGVLIST's words, space-separated, CR, to
* stderr. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
TRACEPRINT  stz   TP_I
:loop       lda   TP_I
            asl   a
            tax
            lda   ARGVLIST,x
            ora   ARGVLIST+1,x
            beq   :done
            lda   TP_I
            beq   :first                ;no blank before word 0
            lda   #$A0
            ldx   #FD_STDERR
            jsr   PUTC
:first      lda   TP_I
            asl   a
            tax
            lda   ARGVLIST,x
            sta   PTR0
            lda   ARGVLIST+1,x
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            inc   TP_I
            bra   :loop
:done       lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PROMPTYN -- -p. Write ARGVLIST's words, one space apart, then
* "?..." to stderr; read ONE reply line from the terminal
* (stderr, the house rule more.s documents: it stays the
* console when stdin is a file or a pipe); carry CLEAR if the
* line begins with y or Y, carry SET (decline) for anything
* else, an empty line, EOF, a failed read, or stderr not being
* a console at all. CLOBBERS: everything.
*---------------------------------------------------------------
PROMPTYN    stz   TP_I
:loop       lda   TP_I
            asl   a
            tax
            lda   ARGVLIST,x
            ora   ARGVLIST+1,x
            beq   :done
            lda   TP_I
            beq   :first                ;no space before word 0
            lda   #$A0
            ldx   #FD_STDERR
            jsr   PUTC
:first      lda   TP_I
            asl   a
            tax
            lda   ARGVLIST,x
            sta   PTR0
            lda   ARGVLIST+1,x
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            inc   TP_I
            bra   :loop
:done       lda   #<PROMPTMSG
            sta   PTR0
            lda   #>PROMPTMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            ldx   #FD_STDERR
            jsr   SIO_FLUSH
            lda   #FD_STDERR
            jsr   SC_FDSTAT
            bcs   :no
            and   #$80                  ;wrapper leaves N alone
            beq   :no                   ;not a device: decline
            lda   #PCOUNT_READ
            sta   APCNT
            lda   #FD_STDERR
            sta   APREF
            lda   #<ANSBUF
            sta   APBUF
            lda   #>ANSBUF
            sta   APBUF+1
            lda   #8
            sta   APREQ
            stz   APREQ+1
            lda   #<APCNT
            ldx   #>APCNT
            jsr   SC_READ
            bcs   :no
            lda   APTRANS
            ora   APTRANS+1
            beq   :no
            lda   ANSBUF
            and   #$DF                  ;fold case: y -> Y
            cmp   #$D9                  ;'Y'
            bne   :no
            clc
            rts
:no         sec
            rts

PROMPTMSG   asc   "?..."
            dfb   0
