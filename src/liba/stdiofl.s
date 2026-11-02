*---------------------------------------------------------------
* stdiofl.s -- stdio.s's flush/close/exit half. ONE module split
* across two files for S9's as-window budget (docs/S9-PLAN.md
* sec 5, W2): the charged term for ~24 units was stdio.s itself
* after the V7 buffering layer grew it past half the window.
* ALWAYS put IMMEDIATELY AFTER ../liba/stdio.s -- the pair is
* one assembly stream (equates, SIOM_* modes and BASE_HI_TABLE
* live in the first half; nothing here stands alone), and every
* rule in stdio.s's own header applies to this file unchanged.
* Split at a GLOBAL boundary (SIO_FLUSH's banner) so no :local
* is reparented.
*---------------------------------------------------------------
*---------------------------------------------------------------
* SIO_FLUSH -- flush one fd's pending buffered bytes (if any) to
* the kernel via ONE (or more, on a short write) real SC_WRITE.
* IN: X = fd. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SIO_FLUSH   stx   SIO_FLFD
            lda   SIO_CNT_LO,x
            ora   SIO_CNT_HI,x
            bne   :havework
            rts                            ;nothing buffered --
                                          ;cheap no-op, the
                                          ;common case for
                                          ;SIO_FLUSHALL's sweep
:havework
*-- The STAGE OWNER's bytes already live in ordinary RAM at its
*-- own base -- SC_WRITE can read them where they are, so the
*-- whole LC bracket + SIO_CPY hop (measured ~5% of the strip)
*-- exists only for the LC-backed fds.
            ldx   SIO_FLFD
            lda   SIO_BASEHI,x
            cmp   #$D0
            bcc   :ramdirect

            lda   LC_FREE_RW                 ;select bank 1 (sec
            lda   LC_FREE_RW                 ;5 bracket, again
                                          ;narrow: this routine
                                          ;never syscalls while
                                          ;selected)
            lda   #0
            sta   STG_PTR
            lda   SIO_BASEHI,x
            sta   STG_PTR+1
            lda   #<SIO_STAGE
            sta   DST_PTR
            lda   #>SIO_STAGE
            sta   DST_PTR+1
            lda   SIO_CNT_LO,x
            sta   SIO_CPYLO
            lda   SIO_CNT_HI,x
            sta   SIO_CPYHI
            jsr   SIO_CPY                  ;LC bank1 ->
                                           ;SIO_STAGE (ordinary
                                           ;RAM), plain same-
                                           ;process copy

            lda   LC_KRN_RW               ;reselect bank 2 --
                                          ;before the SC_WRITE
                                          ;below, which IS a
                                          ;syscall (sec 5's
                                          ;whole point)

            ldx   SIO_FLFD
            lda   #<SIO_STAGE
            sta   SIO_WPARM_BUF
            lda   #>SIO_STAGE
            sta   SIO_WPARM_BUF+1
            bra   :parm
:ramdirect  lda   SIO_BASELO,x            ;write straight from
            sta   SIO_WPARM_BUF           ;the owner's buffer
            lda   SIO_BASEHI,x
            sta   SIO_WPARM_BUF+1
:parm       lda   #PCOUNT_WRITE      ;stored, not emitted -- the
            sta   SIO_WPARM          ;parmlist is in bss now
            lda   SIO_CNT_LO,x
            sta   SIO_WPARM_REQ
            lda   SIO_CNT_HI,x
            sta   SIO_WPARM_REQ+1
            lda   SIO_FLFD
            sta   SIO_WPARM_REF
:wloop      lda   SIO_WPARM_REQ
            ora   SIO_WPARM_REQ+1
            beq   :wdone
            lda   #<SIO_WPARM
            ldx   #>SIO_WPARM
            jsr   SC_WRITE
            bcs   :werr                    ;write error: record
                                           ;it, give up on these
                                           ;bytes -- ERROR PATH
            lda   SIO_WPRM_TRNS
            ora   SIO_WPRM_TRNS+1
            beq   :wdone                   ;defensive: avoid an
                                          ;infinite loop on a
                                          ;0-byte "success"
            sec
            lda   SIO_WPARM_REQ
            sbc   SIO_WPRM_TRNS
            sta   SIO_WPARM_REQ
            lda   SIO_WPARM_REQ+1
            sbc   SIO_WPRM_TRNS+1
            sta   SIO_WPARM_REQ+1
            clc
            lda   SIO_WPARM_BUF
            adc   SIO_WPRM_TRNS
            sta   SIO_WPARM_BUF
            lda   SIO_WPARM_BUF+1
            adc   SIO_WPRM_TRNS+1
            sta   SIO_WPARM_BUF+1
            bra   :wloop

*-- A = the kernel's errno. The FIRST failure on an fd is the
*-- one kept: a stream that fails once usually fails every
*-- flush after it, and the first errno is the one that says
*-- why (the later ones can be a consequence).
:werr       ldx   SIO_FLFD
            ldy   SIO_ERR,x
            bne   :wdone                   ;already recorded
            sta   SIO_ERR,x

:wdone      ldx   SIO_FLFD
            stz   SIO_CNT_LO,x             ;reset -- even on a
            stz   SIO_CNT_HI,x             ;partial/failed write
                                           ;too. The bytes ARE
                                           ;lost; the change is
                                           ;that SIO_ERR knows
                                           ;they were, so an
                                           ;endless retry is not
                                           ;the alternative
            rts

*---------------------------------------------------------------
* SIO_CPY -- copy (SIO_CPYHI:SIO_CPYLO) bytes from (STG_PTR) to
* (DST_PTR), both zero-page indirect, Y always 0 (a plain 16-bit
* byte mover -- flush-frequency only, never per-character, so
* the simplicity is worth more than a page-optimized unrolled
* version here). CLOBBERS: A, Y.
*---------------------------------------------------------------
SIO_CPY     ldy   #0
:loop       lda   SIO_CPYLO
            ora   SIO_CPYHI
            beq   :done
            lda   (STG_PTR),y
            sta   (DST_PTR),y
            inc   STG_PTR
            bne   :s1
            inc   STG_PTR+1
:s1         inc   DST_PTR
            bne   :s2
            inc   DST_PTR+1
:s2         lda   SIO_CPYLO
            bne   :c1
            dec   SIO_CPYHI
:c1         dec   SIO_CPYLO
            bra   :loop
:done       rts

*---------------------------------------------------------------
* FCLOSE -- flush a written-to fd, THEN close it. The pairing
* exists because PUTC full-buffers a real file fd (fd >= 3) and
* only auto-flushes at 512B or at EXIT, so a bare SC_CLOSE on a
* file the program wrote through PUTC silently DROPS THE TAIL.
* See docs/PLAN.md's liba-wave ruling.
*
* Takes the FD, not a parmlist, and owns FCL_PARM below: the two
* halves disagree otherwise (SIO_FLUSH wants an fd in X,
* SC_CLOSE wants A/X -> a caller-declared PCOUNT_CLOSE block),
* and absorbing that mismatch is liba's job -- PROCIO.md sec 1.
* Additive: SC_CLOSE stays reachable and its callers are
* untouched.
*
* IN: X = fd. OUT: carry clear, or carry set + A = errno.
* CLOBBERS: A, X, Y -- SIO_FLUSH already clobbers all three, and
* SC_CLOSE is one of liba's bare SC_* gates, which clobber Y and
* never restore it (syscalls.s's "REGISTER DISCIPLINE" note).
* Do not depend on Y surviving a call to FCLOSE.
*
* THE ERRNO IS NOW TWO THINGS, and the WRITE error outranks the
* close: a stream whose flush failed did not deliver its bytes,
* which is the failure a caller must report, and a close that
* succeeds afterwards does not undo it. So the order is: close
* error if there was one, else the recorded write error, else
* success. Either way FCLOSE is where the error is DELIVERED --
* SIO_ERR is cleared for that fd here, because fd numbers get
* reused and a stale flag would make the next stream's EXIT lie.
*---------------------------------------------------------------
FCLOSE      stx   FCL_FD
            lda   #PCOUNT_CLOSE      ;stored, not emitted -- the
            sta   FCL_PARM           ;parmlist is in bss now
            jsr   SIO_FLUSH
            ldx   FCL_FD             ;take the write error out
            lda   SIO_ERR,x          ;of SIO_ERR before SC_CLOSE
            sta   FCL_WERR           ;overwrites A and the carry
            stz   SIO_ERR,x
            stz   SIO_MODE,x         ;the fd number is about to
                                     ;mean something else --
                                     ;reprobe on its next use
            txa                      ;release stage ownership
            clc                      ;if this fd held it, so
            adc   #1                 ;the next full-mode fd can
            cmp   SIO_STGOWN         ;claim the fast buffer
            bne   :ownkept
            stz   SIO_STGOWN
:ownkept
            lda   FCL_FD
            sta   FCL_PARM_REF
            lda   #<FCL_PARM
            ldx   #>FCL_PARM
            jsr   SC_CLOSE
            bcs   :out               ;close error -- its own
                                     ;errno is already in A
            lda   FCL_WERR
            beq   :out               ;clean flush AND clean
                                     ;close: carry still clear
            sec                      ;A = the write errno
:out        rts

* -- FCL_FD/FCL_PARM/FCL_PARM_REF: see the note at the end of
* -- this file -- they are in src/liba/libabss.s now.

*---------------------------------------------------------------
* SIO_FLUSHALL -- flush every fd (0-7). Used by EXIT (below) and
* by GETC (print.s) before a blocking read, so a pending
* line-buffered prompt reaches the tty before the read that
* follows it (docs/PROCIO.md sec 4/6 gate (b)). CLOBBERS: A, X,
* Y.
*---------------------------------------------------------------
SIO_FLUSHALL
            ldx   #0
:loop       txa
            pha
            jsr   SIO_FLUSH
            pla
            tax
            inx
            cpx   #8
            bne   :loop
            rts

*---------------------------------------------------------------
* EXIT -- the documented exit door (docs/PROCIO.md sec 4's V6
* exit()/_exit() split). Flushes every open stream, THEN calls
* SC_EXIT (the raw door, syscalls.s, unchanged). Every
* src/bin/*.s program routes its exit through here now -- see
* each file's own header/commit for the SC_EXIT audit
* (docs/PROCIO.md's dated results section). IN: A = status byte.
* Does not return (SC_EXIT doesn't).
*
* A PROGRAM THAT COULD NOT DELIVER ITS OUTPUT DOES NOT EXIT 0.
* After the final flush, any fd still carrying a recorded write
* error (one no FCLOSE consumed -- in practice fds 0-2, which
* nobody closes) turns a zero status into EXIT_WRFAIL. A
* nonzero status the program chose is left alone: it already
* says something went wrong, and the program knows more about
* what than this routine does.
*
* This is the one place the fix reaches EVERY util at once, and
* it is the honest reading of `echo REDIR > FILE` on a full or
* locked volume: the shell asked for bytes in a file, no bytes
* arrived, and `$?` is the only channel that can say so. It
* costs a util nothing -- no PUTC call site changes, which is
* what makes it affordable across 33 programs.
*---------------------------------------------------------------
EXIT        sta   SIO_EXITSTAT
            jsr   SIO_FLUSHALL
            lda   SIO_EXITSTAT
            bne   :go                      ;already nonzero
            jsr   SIO_ANYERR
            bcc   :go
            lda   #EXIT_WRFAIL
            sta   SIO_EXITSTAT
:go         lda   SIO_EXITSTAT
            jsr   SC_EXIT
            rts                            ;not reached --
                                          ;defensive, same
                                          ;convention as
                                          ;SC_EXIT's own :hang

*---------------------------------------------------------------
* SIO_ANYERR -- carry SET if any fd has an undelivered write
* error, with A = that errno; carry CLEAR if every stream is
* clean. Scans downward so fd 0 (the most likely one, and the
* most interesting) wins when several failed. CLOBBERS: A, X.
*---------------------------------------------------------------
SIO_ANYERR  ldx   #7
:loop       lda   SIO_ERR,x
            bne   :found
            dex
            bpl   :loop
            clc
            rts
:found      sec
            rts

* -- EVERY cell this module used to declare here now lives in
* -- src/liba/libabss.s's `dum` block (docs/STICKY.md sec 21):
* -- 545 bytes that were emitted zeros in all 36 binaries, most
* -- of it SIO_STAGE. SIO_CNT_LO/HI are the ONLY liba cells the
* -- kernel's zeroed page exists for -- see SIO_FLUSH above,
* -- which reads them before anything writes them. The two
* -- parmlists' param_count bytes are stored by SIO_FLUSH and
* -- FCLOSE now, because an MLI parmlist must be contiguous and
* -- so cannot leave one constant byte behind in text.
