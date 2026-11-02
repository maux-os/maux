*---------------------------------------------------------------
* shsgbl2.s -- the second half of shsgblt.s (KFIX3), split at a
* GLOBAL label so the manifest's source-buffer budget stays
* under
* real Merlin-8's 41,215 bytes (check-dialect: manifest + `use`
* files + the largest single `put`; shsgblt.s alone was 27 KB of
* that term). `put` immediately after shsgblt.s, in the same
* $E000 segment, so the assembled bytes are unchanged. From
* `readonly` on: SB_RO_*, the variable-table-full printers, the
* `times` builtin, the name table (BLTTAB) and the #! reader.
* Every rule in shsgblt.s's header applies unchanged.
*---------------------------------------------------------------
SB_RO_ONE   lda   SBI
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            jsr   ISNAME1                ;a NAME starts with a
            bcs   :ro1scan               ;letter, either case
            jmp   SB_RO_BAD
:ro1scan    iny
            lda   (PTR0),y
            beq   :ro1bare
            cmp   #$BD                   ;'=' high-bit-set
            bne   :ro1scan
            cpy   #VARNAMELEN+1
            bcc   :ro1nmok
            jmp   SB_RO_BAD
:ro1nmok    sty   SBEQ
            ldx   #0
:ro1vscan   iny
            lda   (PTR0),y
            beq   :ro1vdone
            inx
            cpx   #VARVALLEN+1
            bcc   :ro1vscan
            jmp   SB_RO_BAD
:ro1vdone   ldy   SBEQ
            lda   #0
            sta   (PTR0),y               ;split: '=' -> NUL
            lda   SBEQ
            sec                          ;SBEQ+1: past the NUL
            adc   PTR0
            sta   PTR2
            lda   PTR0+1
            adc   #0
            sta   PTR2+1
            jsr   VARSET
            bcc   :ro1mark
            jsr   PR_VARFULL
            lda   #1
            sta   LASTSTATUS
            rts
*-- A bare NAME claims a slot holding "" if it has none yet, the
*-- same shape `export` uses -- otherwise `readonly X` on an
*-- unset X would protect nothing at all.
:ro1bare    jsr   STRLEN                 ;PTR0 restored; X = the
            cpx   #0                     ;high byte, 16-bit
            bne   :ro1toolng
            cmp   #VARNAMELEN+1
            bcs   :ro1toolng
            jsr   VARFIND                ;X = slot when found
            bcc   :ro1mark
            lda   #<SB_RO_EMPTY
            sta   PTR2
            lda   #>SB_RO_EMPTY
            sta   PTR2+1
            jsr   VARSET
            bcc   :ro1mark
            jsr   PR_VARFULL
            lda   #1
            sta   LASTSTATUS
            rts
:ro1mark    lda   #1
            sta   VARRO,x
            rts
:ro1toolng  jmp   SB_RO_BAD

SB_RO_BAD   lda   #<RO_BAD_M
            ldx   #>RO_BAD_M
            jsr   PR_ERRAX1
            rts

*---------------------------------------------------------------
* SB_RO_LIST -- `readonly NAME=VALUE`, one line per marked slot,
* on stdout. POSIX asks for output that can be read back in;
* this is that, for every value this shell can hold (VARVALLEN
* is 31 and the tokenizer takes an unquoted word of that length
* back unchanged unless it holds a blank -- a value WITH a blank
* re-reads as two words, a v1 gap recorded in docs/SH-FEATURES.
* md sec 29 rather than papered over with quoting this shell's
* own assignment parser would then have to strip).
*
* An occupied slot is one whose NAME byte 0 is nonzero --
* VARFIND's
* own definition; VARRO alone is not enough, since `unset` frees
* a slot by zeroing that byte.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
SB_RO_LIST  stz   SBI
:rolloop    ldx   SBI
            cpx   #MAXVARS
            beq   :rolldone
            lda   VARRO,x
            beq   :rollnext
            jsr   VSLOT_NAME            ;PTR1 = this slot's name
            ldy   #0
            lda   (PTR1),y
            beq   :rollnext              ;freed by `unset`
            lda   #<RO_PFX_M
            ldx   #>RO_PFX_M
            jsr   SB_POUT
            ldx   SBI
            jsr   VSLOT_NAME
            lda   PTR1
            ldx   PTR1+1
            jsr   SB_POUT
            lda   #<RO_EQ_M
            ldx   #>RO_EQ_M
            jsr   SB_POUT
            ldx   SBI
            jsr   VSLOT_VAL
            lda   PTR1
            ldx   PTR1+1
            jsr   SB_POUT
            jsr   SB_PRNL
:rollnext   inc   SBI
            bra   :rolloop
:rolldone   rts

*---------------------------------------------------------------
* PR_VARFULL -- the shared "VARSET refused" diagnostic. Every
* writer used to inline `lda #<VARFULL_MSG / ldx #> / jsr
* PR_ERRAX`, which said "variable table full" whatever the
* reason -- and `readonly` gives VARSET a second reason. One
* routine, seven call sites, and the message finally matches the
* refusal. VARROFAIL is VARSET's own output byte, stored on
* every call including the successful ones.
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
PR_VARFULL  jsr   SEL_VARFULL
            jmp   PR_ERRAX

*---------------------------------------------------------------
* SEL_VARFULL -- the same choice WITHOUT printing: A/X = the
* message. Three of the seven call sites do not reach PR_ERRAX
* at all -- they share a `:emit`/`:eprint`/`:bsay` tail that
* loads PTR0 itself -- so they take the selector and keep their
* own tail. CLOBBERS: A, X.
*---------------------------------------------------------------
SEL_VARFULL lda   VARROFAIL
            bne   :svfro
            lda   #<VARFULL_MSG
            ldx   #>VARFULL_MSG
            rts
:svfro      lda   #<VARRO_MSG
            ldx   #>VARRO_MSG
            rts

*---------------------------------------------------------------
* SB_T0CAP -- capture the shell's own start tick, once, from
* START (shlex.s). `times` subtracts it. IN/OUT: nothing;
* SH_TMODE 0 means "no usable timer" and makes `times` print
* structural zeros -- which covers BOTH a failed SYS_TICK and
* mode 3 (COOP), whose count never advances at all
* (src/kernel/procfile3.s PRC_TICK's own header, and docs/
* SHELL-GAPS.md sec 5 on why polling it would be wrong).
* SH_TICKBUF is in sh.s's arena, LOW, because SYS_TICK writes
* into it and the kernel refuses a process address >= $D000.
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
SB_T0CAP    lda   #<SH_TICKBUF
            sta   PTR0
            lda   #>SH_TICKBUF
            sta   PTR0+1
            jsr   SC_TICK
            bcc   :t0ok
            stz   SH_TMODE
            rts
*-- MODE 0 NEEDS NO CASE OF ITS OWN. K_TIMER_MODE is
*-- 0 until TIMER_PROBE runs (src/kernel/sched.s), and a harness
*-- that never probes -- src/test/shlangtest.s is one, measured
*-- 2026-09-16 -- reports 0 here forever. Storing it unchanged
*-- gives SH_TMODE 0, which is exactly the "no usable timer"
*-- value CHCK_BLTN_TMS tests for. The explicit case below is
*-- mode 3, COOP, which is a REAL probed answer whose counter
*-- still never advances.
:t0ok       lda   SH_TICKBUF+0
            cmp   #3                     ;COOP -- the count is
            bne   :t0live                ;frozen, so treat it as
            stz   SH_TMODE               ;no timer at all
            rts
:t0live     sta   SH_TMODE
            ldx   #0
:t0cp       lda   SH_TICKBUF+1,x
            sta   SH_T0,x
            inx
            cpx   #4
            bne   :t0cp
            rts

*---------------------------------------------------------------
* CHCK_BLTN_TMS -- `times` (POSIX XCU, a special builtin and one
* of V7 Bourne's own 21 -- learning:01M10WZW2BWWX6X4DYF4E5AD3D).
* Two lines, each "MmSS.HHs MmSS.HHs": the shell's user and
* system times, then its children's.
*
* WHAT MAUX CAN HONESTLY REPORT, and the divergence is recorded
* in docs/SH-FEATURES.md sec 29 rather than dressed up. There is
* no per-process CPU accounting in this kernel at all and no
* child accounting -- SYS_TICK is a machine-wide 60 Hz serviced-
* tick counter and nothing else. So:
*   field 1 (shell user)  = the shell's ELAPSED time, now minus
*                           the tick SB_T0CAP took at START
*   field 2 (shell sys)   = 0m0.00s, structurally
*   line 2 (children)     = 0m0.00s 0m0.00s, structurally
* Printing zeros for all four would have been defensible and
* useless; printing elapsed in field 1 is the one real number
* the machine has, and it is labelled as elapsed everywhere it
* is documented.
* OUT: carry SET = handled. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CHCK_BLTN_TMS
            lda   #<SB_TMS_STR
            sta   PTR1
            lda   #>SB_TMS_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :tmis
            clc
            rts
:tmis       jsr   SB_NOREDIR
            bcc   :tmok                  ;`bcc` over a `jmp` --
            jmp   :tmdone                ;range
:tmok       stz   LASTSTATUS
            lda   SH_TMODE
            beq   :tmnotm
            lda   #<SH_TICKBUF
            sta   PTR0
            lda   #>SH_TICKBUF
            sta   PTR0+1
            jsr   SC_TICK
            bcc   :tmlive                ;`bcc`/`beq` over a
:tmnotm     jmp   :tmzero                ;`jmp` -- range
:tmlive
*-- delta = now - SH_T0, 32 bits, UNROLLED: a loop would need
*-- the borrow to survive its own `cpx`, and `cpx` sets carry.
            sec
            lda   SH_TICKBUF+1
            sbc   SH_T0+0
            sta   SBACC+0
            lda   SH_TICKBUF+2
            sbc   SH_T0+1
            sta   SBACC+1
            lda   SH_TICKBUF+3
            sbc   SH_T0+2
            sta   SBACC+2
            lda   SH_TICKBUF+4
            sbc   SH_T0+3
            sta   SBACC+3
            jsr   SB_DIV60              ;ticks -> whole seconds,
            sta   SBREM                  ;A = leftover ticks
            jsr   SB_DIV60               ;seconds -> minutes,
            sta   SBSEC                  ;A = seconds 0-59
*-- PRNUM is 16-bit. A session past 65535 minutes (45 days)
*-- prints the cap rather than a wrapped number -- a ceiling is
*-- wrong by a knowable amount, a wrap is wrong by any amount.
            lda   SBACC+2
            ora   SBACC+3
            beq   :tmminok
            lda   #$FF
            sta   SBACC+0
            sta   SBACC+1
:tmminok    lda   SBACC+0
            sta   U2DEC_VAL
            lda   SBACC+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            lda   #<TMS_M_M
            ldx   #>TMS_M_M
            jsr   SB_POUT
            lda   SBSEC
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            lda   #<TMS_DOT_M
            ldx   #>TMS_DOT_M
            jsr   SB_POUT
            lda   SBREM
            jsr   SB_HUND
            jsr   SB_PR2
            lda   #<TMS_TAIL_M
            ldx   #>TMS_TAIL_M
            jsr   SB_POUT
            bra   :tmchild
:tmzero     lda   #<TMS_ZERO_M
            ldx   #>TMS_ZERO_M
            jsr   SB_POUT
:tmchild    lda   #<TMS_ZERO_M
            ldx   #>TMS_ZERO_M
            jsr   SB_POUT
:tmdone     sec
            rts

*---------------------------------------------------------------
* SB_DIV60 -- SBACC (32-bit) /= 60. OUT: A = the remainder,
* SBACC = the quotient. Restoring shift-and-subtract, 32 passes:
* the quotient shifts in at the bottom as the dividend shifts
* out at the top, so it needs no second register pair. The
* remainder stays under 60, so `rol a` can never carry out of
* it. CLOBBERS: A, Y.
*---------------------------------------------------------------
SB_DIV60    ldy   #32
            lda   #0
:dv1        asl   SBACC+0
            rol   SBACC+1
            rol   SBACC+2
            rol   SBACC+3
            rol   a
            cmp   #60
            bcc   :dv2
            sbc   #60
            inc   SBACC+0                ;bit 0 is 0 after the
:dv2        dey                          ;asl, so inc sets it
            bne   :dv1
            rts

*---------------------------------------------------------------
* SB_HUND -- IN: A = leftover ticks, 0-59. OUT: A = hundredths
* of a second, 0-98. That is floor(ticks*100/60) = floor(t*5/3),
* and 5/3 is exact in three steps: every whole 3 ticks is 5
* hundredths, and the 0/1/2 left over map through SB_R3TAB --
* floor(5*0/3)=0, floor(5*1/3)=1, floor(5*2/3)=3. A table of
* three bytes rather than a 60-entry one, and no 16-bit multiply
* at all. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SB_HUND     ldx   #0
:hd1        cmp   #3
            bcc   :hd2
            sbc   #3
            inx
            inx
            inx
            inx
            inx
            bra   :hd1
:hd2        tay
            txa
            clc
            adc   SB_R3TAB,y
            rts
SB_R3TAB    dfb   0,1,3

*---------------------------------------------------------------
* SB_PR2 -- print A (0-99) to stdout as exactly TWO digits.
* U2DEC suppresses leading zeros, which is right for a count and
* wrong for the fractional field of "0m0.05s". CLOBBERS: A, X,
* Y, PTR0.
*---------------------------------------------------------------
SB_PR2      ldx   #0
:p21        cmp   #10
            bcc   :p22
            sbc   #10
            inx
            bra   :p21
:p22        pha
            txa
            ora   #$B0                  ;digit -> high-bit ASCII
            ldx   #FD_STDOUT
            jsr   PUTC
            pla
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* The builtin NAME strings and BLTTAB. THEY STAY IN THE SEGMENT
* (this file's own header says why): STRCMPI reads them with
* `lda (PTR1),y` and nothing else sees them, so the kernel's
* >= $D000 copyin refusal never applies.
*
* `-v`/`-V`/`-p` are compared with STRCMP, not STRCMPI -- see
* CHCK_BLTN_CMD's header.
*---------------------------------------------------------------
SB_CMD_STR  asc   "COMMAND"
            dfb   0
SB_TYP_STR  asc   "TYPE"
            dfb   0
SB_EVL_STR  asc   "EVAL"
            dfb   0
SB_XEC_STR  asc   "EXEC"
            dfb   0
SB_RO_STR   asc   "READONLY"
            dfb   0
SB_TMS_STR  asc   "TIMES"
            dfb   0
SB_DV_STR   asc   "-v"
            dfb   0
SB_DVV_STR  asc   "-V"
            dfb   0
SB_DP_STR   asc   "-p"
            dfb   0
SB_RO_EMPTY dfb   0

*---------------------------------------------------------------
* BLTTAB -- every name this shell dispatches as a BUILTIN,
* NUL-separated with an empty entry to end the table: PATHTAB's
* own shape (src/liba/pathtab.s), for the same reason -- one
* flat block a single pointer walks, no parallel lo/hi arrays.
*
* IT IS A SECOND LIST AND THAT IS A LIABILITY. The truth is the
* `jsr` chain in shlex.s's MAINLOOP; this table is a transcript
* of it. A builtin added there and not here reports "not found"
* from `type` while working perfectly when typed, which is the
* quiet kind of wrong. check_shlang.py's `type` rows exist
* partly
* to keep the two honest. The RESERVED words are NOT duplicated
* -- SB_ISBLTN reads CHCK_RESERVED's own RESV_LO/HI instead.
*
* `:` and `.` and `[` are here as themselves: SIFOLD only
* touches letters, so STRCMPI and STRCMP are the same comparison
* on pure punctuation.
*---------------------------------------------------------------
BLTTAB      asc   ":"
            dfb   0
            asc   "."
            dfb   0
            asc   "["
            dfb   0
            asc   "BG"
            dfb   0
            asc   "BREAK"
            dfb   0
            asc   "CD"
            dfb   0
            asc   "COMMAND"
            dfb   0
            asc   "CONTINUE"
            dfb   0
            asc   "ECHO"
            dfb   0
            asc   "EVAL"
            dfb   0
            asc   "EXEC"
            dfb   0
            asc   "EXIT"
            dfb   0
            asc   "EXPORT"
            dfb   0
            asc   "FG"
            dfb   0
            asc   "GETOPTS"
            dfb   0
            asc   "JOBS"
            dfb   0
            asc   "READ"
            dfb   0
            asc   "READONLY"
            dfb   0
            asc   "SET"
            dfb   0
            asc   "SHIFT"
            dfb   0
            asc   "TEST"
            dfb   0
            asc   "TIMES"
            dfb   0
            asc   "TRAP"
            dfb   0
            asc   "TYPE"
            dfb   0
            asc   "UNSET"
            dfb   0
            asc   "WAIT"
            dfb   0
            dfb   0

*---------------------------------------------------------------
* SHEB_FIX -- `#!` (docs/EXEC-SHEBANG.md Part 2, the V7
* placement: the shell, not the kernel). RUN_PIPELINE calls it
* when SC_SPAWN answered ERR_NOEXEC for stage STAGEI: the file
* at SH_PATHFULL is
* there and is not a BIN/SYS program. If it is a TXT whose first
* line is `#!interp [arg]`, argv becomes
*     interp [arg] SCRIPT args...      (SCRIPT = SH_PATHFULL)
* and carry comes back CLEAR: the caller resolves argv[0] again
* (a bare interpreter goes through PATH) and spawns again. Carry
* SET: not a `#!` script, or too deep (an interpreter that is
* itself a script nests once, as on the host: two rewrites), or
* argv would not fit -- the caller says `cannot execute`.
*
* ONE optional argument, the rest of the line as a single word
* (trailing blanks trimmed), as Linux and the BSDs do. Both
* strings and the script path are copied into RL_BUF, which is
* dead at spawn time (READLINE stores every cell it reads, and
* the line being run is long since in LINEBUF): 128 bytes a
* level -- the line (62 bytes read) at +0, the script path at
* +63. A level-1 rewrite must not disturb level 0's argument
* string, which argv still points at. Text may be low- or
* high-bit (a2til writes low, maux high); the strings handed on
* are high-bit like every argv word. Only code lives here: the
* buffers are low (copyin refuses >= $D000).
*
* CLOBBERS: A, X, Y, PTR0-PTR2.
*---------------------------------------------------------------
SHEB_FIX
            lda   SHEB_N
            cmp   #2
            bcc   :go
:fail       sec
            rts
:go
            jsr   SHEB_BASE            ;PTR0 = this level's line
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            lda   #<SH_PATHFULL
            sta   PTR0
            lda   #>SH_PATHFULL
            sta   PTR0+1
            lda   #62
            jsr   XEC_PEEK             ;the shared reader
            bcc   :peeked
            jmp   :fail
:peeked     sta   SHEB_LEN
            jsr   SHEB_BASE            ;PTR0/PTR2 again
            lda   SHEB_LEN
            cmp   #3
            bcs   :long
            jmp   :fail
:long
*-- copy the script path beside the line (+63)
            ldy   #0
:cp         lda   SH_PATHFULL,y
            sta   (PTR2),y
            beq   :cpd
            iny
            cpy   #SH_PTHFLL_LEN-1
            bne   :cp
            lda   #0
            sta   (PTR2),y
:cpd
*-- `#!`
            ldy   #0
            jsr   SHEB_CH
            cmp   #'#'
            beq   :ok1
            jmp   :fail
:ok1
            iny
            jsr   SHEB_CH
            cmp   #'!'
            beq   :ok2
            jmp   :fail
:ok2
            iny
:sk1        jsr   SHEB_CH
            cmp   #' '
            beq   :nx1
            cmp   #$09
            bne   :iw
:nx1        iny
            bra   :sk1
:iw         cmp   #0
            bne   :ok3                 ;`#!` and nothing
            jmp   :fail
:ok3
            sty   SHEB_IY
:iw2        jsr   SHEB_CH              ;the interpreter word,
            beq   :iend                ;made high-bit as it goes
            cmp   #' '
            beq   :iend
            cmp   #$09
            beq   :iend
            ora   #$80
            sta   (PTR0),y
            iny
            bra   :iw2
:iend       pha                        ;what ended it (0 = EOL)
            lda   #0
            sta   (PTR0),y             ;NUL, in place
            pla
            ldx   #$FF                 ;X = arg offset, $FF none
            cmp   #0
            beq   :argdone
            iny
:sk2        jsr   SHEB_CH
            beq   :argdone
            cmp   #' '
            beq   :nx2
            cmp   #$09
            bne   :aw
:nx2        iny
            bra   :sk2
:aw         sty   SHEB_AY
            ldx   SHEB_AY
:aw2        jsr   SHEB_CH              ;the rest of the line
            beq   :aend
            ora   #$80
            sta   (PTR0),y
            iny
            bra   :aw2
:aend       dey                        ;trim trailing blanks
            lda   (PTR0),y
            and   #$7F
            cmp   #' '
            beq   :aend
            cmp   #$09
            beq   :aend
            iny
            lda   #0
            sta   (PTR0),y
:argdone    stx   SHEB_AY
*-- shift argv[1..] up by s = 1 or 2 slots and store the front
            lda   #2
            ldx   SHEB_AY
            cpx   #$FF
            beq   :s1
            lda   #4
:s1         sta   SHEB_S2              ;2*s
            lda   STAGEI
            tax
            lda   CMD_ARGC,x
            sta   SHEB_ARGC
            lsr   SHEB_S2
            clc
            adc   SHEB_S2
            cmp   #MAXARGV             ;argc+s <= MAXARGV-1 so
            bcc   :fits                ;the NULL slot survives
            jmp   :fail
:fits       asl   SHEB_S2
            jsr   ARGV_PTR_STG
            ldx   SHEB_ARGC
:mv         dex
            beq   :mvdone
            txa
            asl   a
            tay
            lda   (PTR1),y
            pha
            iny
            lda   (PTR1),y
            pha
            tya
            clc
            adc   SHEB_S2
            tay
            pla
            sta   (PTR1),y
            dey
            pla
            sta   (PTR1),y
            bra   :mv
:mvdone     ldy   SHEB_IY              ;interpreter
            jsr   SHEB_MKP
            ldy   #0
            jsr   SHEB_PUT
            ldy   SHEB_AY
            cpy   #$FF
            beq   :nearg
            jsr   SHEB_MKP             ;argument
            ldy   #2
            jsr   SHEB_PUT
:nearg      ldy   #63                  ;the script path
            jsr   SHEB_MKP
            ldy   SHEB_S2
            jsr   SHEB_PUT
            lda   SHEB_S2
            lsr   a
            ldx   STAGEI
            clc
            adc   CMD_ARGC,x
            sta   CMD_ARGC,x
            inc   SHEB_N
            clc
            rts

*-- SHEB_BASE -- PTR0 and PTR2 for this level (SHEB_N 0 or 1):
*-- PTR0 = RL_BUF + 128*level (the line), PTR2 = PTR0 + 63.
SHEB_BASE   lda   #<RL_BUF
            sta   PTR0
            lda   #>RL_BUF
            ldx   SHEB_N
            beq   :hi
            ldx   PTR0                 ;+128: lo += $80
            txa
            clc
            adc   #$80
            sta   PTR0
            lda   #>RL_BUF
            adc   #0
:hi         sta   PTR0+1
            lda   PTR0
            clc
            adc   #63
            sta   PTR2
            lda   PTR0+1
            adc   #0
            sta   PTR2+1
            rts

*-- SHEB_CH -- A = byte Y of the line, 7-bit; 0 at end of line
*-- (CR, LF, NUL or the bytes read). Z reflects A.
SHEB_CH     cpy   SHEB_LEN
            bcs   :end
            lda   (PTR0),y
            and   #$7F
            cmp   #$0D
            beq   :end
            cmp   #$0A
            beq   :end
            ora   #0
            rts
:end        lda   #0
            rts

*-- SHEB_MKP -- A/X = lo/hi of PTR0 + Y.
SHEB_MKP    tya
            clc
            adc   PTR0
            pha
            lda   PTR0+1
            adc   #0
            tax
            pla
            rts

*-- SHEB_PUT -- store A/X at (PTR1),Y; Y advances by 2.
SHEB_PUT    sta   (PTR1),y
            iny
            txa
            sta   (PTR1),y
            iny
            rts
