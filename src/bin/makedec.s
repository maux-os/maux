*---------------------------------------------------------------
* makedec.s -- is this target out of date? The mod-time
* compare, the stat, and the internal-macro binding.
*
* Split out of makerun.s for as's 16,128-byte source window
* (check-dialect 3b): as holds the MANIFEST resident and
* streams each `put` one at a time, so the charge is the
* manifest plus the LARGEST put.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_DECIDE -- is rule MK_RULEI out of date? Sets MK_NEEDS.
*
* Out of date if the target does not exist, or if ANY dependency
* is NEWER than it. "Newer" is a big-endian compare of
* (date_hi, date_lo, time_hi, time_lo) -- see make.s's header
* for why that is honest without decoding the fields, and for
* the same-minute blind spot it inherits.
*
* A MISSING TARGET GETS A ZERO STAMP rather than none, so that
* $? in its recipe reports every prerequisite instead of the
* handful that happen to postdate an uninitialised cell.
*---------------------------------------------------------------
MK_DECIDE   stz   MK_NEEDS
            ldx   MK_RULEI
            lda   RULE_TGT,x
            sta   MK_NAMEP
            sta   MK_TGTP
            lda   RULE_TGT+MK_MAXRULE,x
            sta   MK_NAMEP+1
            sta   MK_TGTP+1
            jsr   MK_STAT
            lda   MK_EXISTS
            bne   :exists
            stz   MK_TSTAMP
            stz   MK_TSTAMP+1
            stz   MK_TSTAMP+2
            stz   MK_TSTAMP+3
            inc   MK_NEEDS             ;no target: always build
            rts
:exists     ldy   #3
:cpt        lda   MK_STAMP,y
            sta   MK_TSTAMP,y
            dey
            bpl   :cpt
            lda   MK_DEPN
            bne   :havedeps
            rts                        ;no deps and target
                                       ;exists: up to date
:havedeps   sta   MK_DCN
            jsr   MK_DEPFRST
:each       lda   PTR2
            sta   MK_FNAME
            lda   PTR2+1
            sta   MK_FNAME+1
            jsr   MK_STATN
            lda   MK_EXISTS
            beq   :nextdep             ;a missing dep was either
                                       ;built above or reported
            ldy   #3
:cpd        lda   MK_STAMP,y
            sta   MK_DSTAMP,y
            dey
            bpl   :cpd
            jsr   MK_NEWER
            bcc   :nextdep
            inc   MK_NEEDS
            rts
:nextdep    jsr   MK_SKIPP2
            dec   MK_DCN
            bne   :each
            rts

*---------------------------------------------------------------
* MK_NEWER -- carry SET if MK_DSTAMP is strictly newer than
* MK_TSTAMP. Big-endian compare over date-hi, date-lo, time-hi,
* time-lo: ProDOS's date is yyyyyyym mmmddddd and its time is
* 000hhhhh 00mmmmmm, so each field is ordered within itself and
* the four together sort correctly WITHOUT decoding any of them.
* Equal stamps are NOT newer -- that is the same-minute blind
* spot, stated in make.s's header rather than discovered.
*---------------------------------------------------------------
MK_NEWER    lda   MK_DSTAMP+1          ;date hi
            cmp   MK_TSTAMP+1
            bcc   :older
            bne   :newer
            lda   MK_DSTAMP            ;date lo
            cmp   MK_TSTAMP
            bcc   :older
            bne   :newer
            lda   MK_DSTAMP+3          ;time hi
            cmp   MK_TSTAMP+3
            bcc   :older
            bne   :newer
            lda   MK_DSTAMP+2          ;time lo
            cmp   MK_TSTAMP+2
            bcc   :older
            beq   :older               ;equal is not newer
:newer      sec
            rts
:older      clc
            rts

*---------------------------------------------------------------
* MK_STAT / MK_STATN -- GET_FILE_INFO on a name. MK_STAT takes
* MK_NAMEP, MK_STATN takes MK_FNAME; both set MK_EXISTS and, on
* a hit, MK_STAMP = mod date+time.
*---------------------------------------------------------------
MK_STAT     lda   MK_NAMEP
            sta   MK_FNAME
            lda   MK_NAMEP+1
            sta   MK_FNAME+1
*-- ALL THREE POINTERS ARE SAVED HERE, ONCE, FOR EVERY CALLER.
*-- MKPATH's own header says it clobbers PTR2, and this routine
*-- loads PTR0/PTR1 itself -- and a stat happens in the MIDDLE
*-- of two walks that own them: MK_DECIDE and MK_EMITQ
*-- walk the dependency buffer with PTR2, and $? is evaluated
*-- INSIDE macro expansion, whose source cursor is PTR0. Two
*-- symptoms, one cause: $? printed `A.SEFILE` (a real name,
*-- then the tail of what MKPATH left in PATHBUF), and expansion
*-- resumed at the last dependency NAME, not after the `$?` --
*-- so `ZORK $? END` came out `ZORK A.S B.SB.S`, with the rest
*-- of the recipe line silently gone.
MK_STATN    lda   PTR0
            sta   MK_P0SV
            lda   PTR0+1
            sta   MK_P0SV+1
            lda   PTR1
            sta   MK_P1SV
            lda   PTR1+1
            sta   MK_P1SV+1
            lda   PTR2
            sta   MK_P2SV
            lda   PTR2+1
            sta   MK_P2SV+1
            stz   MK_EXISTS
            lda   MK_FNAME
            sta   PTR0
            lda   MK_FNAME+1
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
*-- GFIPARM lives in the `dum` arena, which nothing zeroes and
*-- nothing initialises: its param_count and pathname pointer
*-- are set HERE, every call. Without them the MLI read a
*-- garbage count and a garbage path, GET_FILE_INFO failed for
*-- every name, and make concluded that a dependency sitting
*-- right there on the disk did not exist.
            lda   #PCOUNT_GFI
            sta   GFIPARM
            lda   #<PATHBUF
            sta   GFIPARM_PATH
            lda   #>PATHBUF
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :nofile
            inc   MK_EXISTS
            lda   GFIPARM_MDATE
            sta   MK_STAMP
            lda   GFIPARM_MDATE+1
            sta   MK_STAMP+1
            lda   GFIPARM_MTIME
            sta   MK_STAMP+2
            lda   GFIPARM_MTIME+1
            sta   MK_STAMP+3
:nofile     lda   MK_P0SV
            sta   PTR0
            lda   MK_P0SV+1
            sta   PTR0+1
            lda   MK_P1SV
            sta   PTR1
            lda   MK_P1SV+1
            sta   PTR1+1
            lda   MK_P2SV
            sta   PTR2
            lda   MK_P2SV+1
            sta   PTR2+1
            rts

*---------------------------------------------------------------
* MK_SETINT -- bind the internal macros for an EXPLICIT rule:
* $@ is the target, $< the first prerequisite, $* the target
* with its suffix removed. ($< outside an inference rule is
* unspecified by POSIX; the first prerequisite is what every
* make a user has met does, and it is the only answer that is
* ever useful.)
*---------------------------------------------------------------
MK_SETINT   ldx   MK_RULEI
            lda   RULE_TGT,x
            sta   MK_TGTP
            lda   RULE_TGT+MK_MAXRULE,x
            sta   MK_TGTP+1
            stz   MK_SRCP
            stz   MK_SRCP+1
            lda   MK_DEPN
            beq   MK_SETSTEM
            jsr   MK_DEPFRST
            lda   PTR2
            sta   MK_SRCP
            lda   PTR2+1
            sta   MK_SRCP+1
*-- fall through

MK_SETSTEM  lda   MK_TGTP
            sta   PTR0
            lda   MK_TGTP+1
            sta   PTR0+1
            ldy   #0
            sty   MK_STEML
:scan       lda   (PTR0),y
            beq   :done
            cmp   #$AE                 ;'.'
            bne   :next
            sty   MK_STEML
:next       iny
            bne   :scan
:done       lda   MK_STEML
            bne   :out
            sty   MK_STEML             ;no suffix: all of it
:out        rts

