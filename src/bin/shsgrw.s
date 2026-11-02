*---------------------------------------------------------------
* shsgrw.s -- OPEN-RW-1 stage A (docs/OPEN-RW-1.md): `>` and
* `>>` wait out a TRANSIENT other opener, in sh's $E000 segment.
* Every rule in shsgtrp.s's header applies: this code is only
* ever CALLED, no address here is handed to a syscall, and its
* cells live in the arena (the segment is write-protected).
*
* THE DEFECT. ProDOS refuses a second OPEN of an open file with
* $50 (MLIE_FILOPEN), and so does PRC_OPEN's own guard. `tail -f
* LOG` opens LOG for a moment once a second; a `cmd >> LOG` OPEN
* that lands inside that moment drew `sh: cannot redirect` and
* the command was dropped, though tail itself already tolerates
* the collision from its side.
*
* THE FIX. OW_RUN runs the OPEN (WR_TRY / AP_TRY, shpath.s) and,
* if it failed with $50 and ONLY $50, sleeps one tick
* (SYS_SLPUNTIL until now+1; a blocked call is rerun whole, so
* the target is absolute) and tries again, OW_MAX times at most.
* Any other error -- $46 path, $4E access, a write-locked `>`
* target's SET_EOF refusal (which liba CREAT returns with the fd
* already closed) -- returns at once, unretried. A retried CREAT
* is harmless: the CREATE is create-ignore-exists, and the
* truncating SET_EOF comes AFTER the OPEN that succeeded, so a
* first attempt that failed at OPEN has truncated nothing.
*
* WHAT THIS IS NOT. Unix never waits and never fails for another
* opener. This closes the transient case (a poller, a short
* `cp`). A LONG holder (`exec 3<F; echo x >> F`) still fails --
* after the bound instead of at once. The Unix fix is stage B
* (OPEN-RW-2: a writer joins the shared refnum).
*
* ^C. An interactive shell is in no foreground set while it
* opens a redirect, so a ^C would reach nobody. The first wait
* therefore does what the line editor does (shedit.s ED_LINE):
* INT and TSTP to CATCH, this shell declared its console's
* foreground job ({1, self}); a held signal ends the sleep with
* ERR_INTR. All of it is undone on EVERY exit (ED_EXIT).
* A ^C ends the open with OW_INTR set: PR_REDIRERR then prints
* nothing (the kernel painted `^C`) and the status is 130. A
* non-interactive sh arms nothing: ^C reaches it through the
* job it is part of, exactly as it does today.
*
* OW_SEEN (write-only) keeps the retry count of the last
* redirect that waited: a gate reads it from the sh bank to
* prove a retry was TAKEN, not just that timing let it pass.
*---------------------------------------------------------------
OW_MAX      equ   30          ;tries: 61 ticks (~1 s), 3-4x
                              ;the longest tail hold seen

*---------------------------------------------------------------
* OW_RUN -- IN: A/X = the try routine (WR_TRY or AP_TRY): OUT
* carry set + A = errno on failure, as the open itself returns.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
OW_RUN      sta   OW_VEC
            stx   OW_VEC+1
            stz   OW_N
            stz   OW_ARMD
            stz   OW_INTR
:try        jsr   OW_CALL
            bcc   :ok
            cmp   #$50                   ;MLIE_FILOPEN: busy
            bne   :bad
            ldx   OW_N
            cpx   #OW_MAX
            bcs   :bad                   ;the bound
            inc   OW_N
            inx
            stx   OW_SEEN
            lda   OW_ARMD
            bne   :wait
            jsr   OW_ARM
:wait       jsr   OW_SLEEP               ;carry set: give up
            bcc   :try
:bad        sec
:ok         pha
            php
            lda   OW_ARMD
            beq   :out
            jsr   ED_EXIT
:out        plp
            pla
            rts

OW_CALL     jmp   (OW_VEC)

*---------------------------------------------------------------
* OW_SLEEP -- one tick. OUT: carry clear = go and try again;
* carry set, A = ERR_INTR (a ^C or a trapped signal: OW_INTR
* set) or ERR_NOSYS (no tick source: COOP or unprobed -- nothing
* would end the wait, so the open fails as it always did).
*---------------------------------------------------------------
OW_SLEEP    lda   #<SH_TICKBUF
            sta   PTR0
            lda   #>SH_TICKBUF
            sta   PTR0+1
            jsr   SC_TICK
            bcs   :out
            inc   SH_TICKTGT             ;target = now+1, 32 bit
            bne   :go
            inc   SH_TICKTGT+1
            bne   :go
            inc   SH_TICKTGT+2
            bne   :go
            inc   SH_TICKTGT+3
:go         lda   #<SH_TICKTGT
            ldx   #>SH_TICKTGT
            jsr   SC_SLPUNTIL
            bcc   :out
            cmp   #ERR_INTR
            sec
            bne   :out
            jsr   OW_DRAIN               ;set: INT or trapped
            bcc   :out                   ;TERM: keep waiting
            lda   #1
            sta   OW_INTR
            lda   #ERR_INTR
            sec
:out        rts

*---------------------------------------------------------------
* OW_DRAIN -- pop every held signal. An untrapped one is dropped
* (SIG_PARK); a trapped one is parked for PUMP_TRAP. OUT: carry
* set if one was INT (2) or trapped. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
OW_DRAIN    stz   OW_HIT
:next       jsr   SC_SIGPEND
            cmp   #0
            beq   :done
            tax
            jsr   SIG_PARK
            bcs   :hit
            cpx   #2
            bne   :next
:hit        inc   OW_HIT
            bra   :next
:done       lda   OW_HIT
            lsr   a
            rts

*---------------------------------------------------------------
* OW_ARM -- the line editor's bracket (shedit.s ED_LINE), for an
* INTERACTIVE shell only: INT and TSTP to CATCH (the previous
* actions go where ED_EXIT will put them back from, ED_PINT and
* ED_PTSTP), this shell the console's foreground job. OW_ARMD
* records that it is up; ED_EXIT is the undo, on every exit:
* it clears the foreground set, restores both actions and drops
* or parks whatever signal is still held. ED_RAWF is 0 (the
* console is not ours), so it leaves the tty mode alone.
*---------------------------------------------------------------
OW_ARM      lda   SH_INTERACT
            beq   :out
            inc   OW_ARMD
            stz   ED_RAWF
            ldy   #1
:sig        lda   OW_SIGS,y
            ldx   #SIGA_CATCH
            phy
            jsr   SC_SIGNAL
            ply
            sta   ED_PINT,y
            dey
            bpl   :sig
            lda   #1                     ;{1, self}: ^C reaches
            sta   FG_PARM                ;this shell as a held
            lda   BANK_ID                ;signal, never as death
            sta   FG_PARM+1              ;(the kernel zeroes the
                                         ;slots past the count)
            jmp   ED_SETFG
:out        rts

OW_SIGS     dfb   2,SIG_TSTP
