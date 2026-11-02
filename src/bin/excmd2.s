*---------------------------------------------------------------
* excmd2.s -- the `!` command family (EX_CBANG/EX_BANG_ESC/
* EX_BANG_FILT/EX_RBANG/EX_WBANG) and the EX_BG_* shell-spawn
* helpers + their parmlists. Split out of excmd.s 2026-09-07
* (docs/EX-REFACTOR-PLAN.md), `put` by ex.s and vi.s IMMEDIATELY
* after excmd.s -- PUT is textual inclusion, so this is one
* contiguous instruction stream with excmd.s and the emitted
* bytes are byte-identical to the pre-split single file
* (check-bytes/check-dual). Reason: excmd.s alone was 41,554 B
* stripped, over real Merlin`s 41,215 B buffer by itself, so
* ex.s/vi.s could not assemble under the vintage toolchain
* (check-dialect hazard 3). Everything here is ex-only; ed
* never assembles it, same as excmd.s.
*---------------------------------------------------------------

*---------------------------------------------------------------
* EX_CBANG -- `!` dispatch (EX_CMD's own entry, Y=0 IS the `!`
* itself -- ED_CMDPTR unconsumed). Keyed on ED_ADDRCNT: 0 ->
* EX_BANG_ESC (":!cmd", no buffer interaction); else ->
* EX_BANG_FILT ("[a,b]!cmd", a filter). `!` always matches once
* seen -- no clc/rts fallthrough case.
*---------------------------------------------------------------
EX_CBANG    inc   ED_CMDPTR      ;past the `!` -- both branches
            bne   :cb_nb         ;use ED_CMDPTR as the command
            inc   ED_CMDPTR+1    ;text pointer directly
:cb_nb      lda   ED_ADDRCNT
            bne   :cb_filt
            jmp   EX_BANG_ESC
:cb_filt    jmp   EX_BANG_FILT

*---------------------------------------------------------------
* EX_BANG_ESC -- `:!cmd` (no address): run `cmd` through `sh`,
* fd 0/1/2 ALL inherited from `ex` (output lands on the console,
* a real shell escape). No buffer interaction -- no EX_SNAPSHOT,
* no EX_DIRTY change. Script (EX.CMDxx): "cmd\r", handed to `sh`
* as argv[1] (`sh SCRIPTFILE` mode, EX3 rewire 2026-09-06) -- no
* fdactions at all, so a REAL pipeline in `cmd` (`cat | sort`)
* now works exactly as it would typed straight at the shell.
*---------------------------------------------------------------
EX_BANG_ESC
            jsr   EX_BG_MKNAM
            lda   #1              ;the one `!` form whose child
            sta   ED_GLASSOUT     ;writes to the console -- vi's
                                  ;`:` landing prompts for it
            jsr   EX_BG_COPNW
            bcs   :be_err
            lda   ED_CMDPTR
            sta   PTR0
            lda   ED_CMDPTR+1
            sta   PTR0+1
            jsr   EX_BG_WRLIT
            bcs   :be_err2
            jsr   EX_BG_WRCR
            bcs   :be_err2
            lda   EX_BG_FD
            jsr   EX_BG_CLOSE
            stz   EX_BG_FDACT       ;FDACT_END -- fd 0/1/2 all
                                    ;inherited from ex (the
                                    ;console); argv[1] carries
                                    ;the script now, EX3 rewire
            jsr   EX_BG_SPAWN
            bcs   :be_spwerr
            lda   #<EXBCUNL
            ldx   #>EXBCUNL
            jsr   SC_UNLINK
            jmp   MAINLOOP
:be_spwerr  lda   #<EXBCUNL
            ldx   #>EXBCUNL
            jsr   SC_UNLINK
            jmp   ED_ERR_JMP
:be_err2    lda   EX_BG_FD
            jsr   EX_BG_CLOSE
:be_err     jmp   ED_ERR_JMP

*---------------------------------------------------------------
* EX_BANG_FILT -- `[a,b]!cmd` (ED_ADDRCNT != 0): filter lines
* a..b through `cmd`. Mutating -- EX_SNAPSHOT first. `cmd` is
* handed to `sh` VERBATIM as its own script, via argv[1] (`sh
* SCRIPTFILE` mode, EX3 rewire 2026-09-06) -- a REAL pipeline
* (`cat | sort`) now attaches to the WHOLE execution rather
* than just its last stage, closing the deferred EX3 finding
* (the design review) that the former "cmd < EX.INxx" text
* approach could never fix: a shell binds `<`/`>` to the LAST
* pipeline stage or the LAST `;`/`&`-separated command
* (shparse.s), so `cat | sort` starved `cat` of input,
* `sort ; :` redirected only the trailing no-op, and `sort &`
* backgrounded the filter so ex read EX.OUTxx back empty and
* reported success. EX itself pre-opens BOTH EX.INxx (read) and
* EX.OUTxx (write) and hands them to `sh` via fdactions fd 0/fd
* 1 (EX_BG_IOPNR/EX_BG_OOPNW + EX_BG_SPAWN2) -- input reaches
* the FIRST stage (fd 0, inherited), output is captured from
* the LAST (fd 1, inherited), exactly as typing the pipeline
* straight at a shell would behave. After wait, delete [a,b]
* and read EX.OUTxx back in its place.
*
* HISTORY: on 2026-09-06 the spawned filter produced NO output
* when `sh` was `ex`'s OWN child (three process levels) --
* silent io_buffer exhaustion, the filter being the one `!`
* form whose grandchild needs TWO files open at once with ex's
* swap file held open too. The fix then was to close and reopen
* the swap fd around the spawn by hand. On 2026-09-07 the
* kernel took that job over for every file on the machine
* (io_buffer LENDING, docs/IOBUF-LENDING.md) and the hand-
* rolled EX_BG_SWCLOSE/EX_BG_SWOPEN were retired.
*---------------------------------------------------------------
EX_BANG_FILT
            jsr   ED_DFLT_DTDT
            jsr   ED_CHC_RNG12N
            bcc   :bf_rngok
            jmp   ED_ERR_JMP
:bf_rngok   lda   ED_GMODE          ;EX7 2026-09-06: keep the
            bne   :bf_skipsnap      ;ONE pre-global snapshot
            jsr   EX_SNAPSHOT       ;alive during a g/v pass,
:bf_skipsnap                        ;gate as edparse.s :havecmd
            jsr   EX_BG_MKNAM
            jsr   EX_BG_IOPNW
            bcc   :x1
            jmp   :bf_err
:x1
            jsr   EX_WRR_FD
            bcc   :x2
            jmp   :bf_err2
:x2
            lda   EX_BG_FD
            jsr   EX_BG_CLOSE
* -- pre-open EX.OUTxx for WRITE ourselves (EX_BG_OOPNW's own
* -- header explains why the filter form alone does this rather
* -- than trusting `sh`'s own `>` parsing) -- stash the fd in
* -- EX_BG_OWFD before EX_BG_FD gets reused for the cmd script.
            jsr   EX_BG_OOPNW
            bcc   :x2b
            jmp   :bf_err3
:x2b
            lda   EX_BG_FD
            sta   EX_BG_OWFD
            jsr   EX_BG_COPNW
            bcc   :x3
            jmp   :bf_err3b
:x3
            lda   ED_CMDPTR
            sta   PTR0
            lda   ED_CMDPTR+1
            sta   PTR0+1
            jsr   EX_BG_WRLIT
            bcc   :x4
            jmp   :bf_err4
:x4
            jsr   EX_BG_WRCR
            bcc   :x8
            jmp   :bf_err4
:x8
            lda   EX_BG_FD
            jsr   EX_BG_CLOSE
* -- EX.INxx/EX.OUTxx/EX.CMDxx all exist now (script + both
* -- data files). Reopen EX.INxx for READ -- fdactions dup it
* -- onto the child's fd 0, so the FIRST pipeline stage inherits
* -- it, and EX_BG_OWFD (already open for write) onto fd 1, so
* -- the LAST stage's output lands in EX.OUTxx -- both ends of a
* -- REAL pipeline now attach to the WHOLE `sh SCRIPTFILE`
* -- execution, not just its last stage (this header's own top).
            jsr   EX_BG_IOPNR
            bcc   :x9pre
            jmp   :bf_err3b
:x9pre
            lda   #FDACT_DUP
            sta   EX_BG_FDACT
            stz   EX_BG_FDACT+1
            lda   EX_BG_IRFD
            sta   EX_BG_FDACT+2
            lda   #FDACT_DUP
            sta   EX_BG_FDACT+3
            lda   #1
            sta   EX_BG_FDACT+4
            lda   EX_BG_OWFD
            sta   EX_BG_FDACT+5
            lda   #FDACT_END
            sta   EX_BG_FDACT+6
* -- 2026-09-07: the swap fd is NOT closed across the spawn any
* -- more. The kernel lends io_buffers (docs/IOBUF-LENDING.md):
* -- if the filter's grandchild needs the pool, the kernel parks
* -- the swap itself and reopens it at its mark on the next use.
* -- EX_BG_SWCLOSE/EX_BG_SWOPEN, which did that by hand, are
* -- gone.
            jsr   EX_BG_SPAWN2
            bcc   :x10
            jmp   :bf_spwerr
:x10
            jsr   ED_DLT_RANGE
            sec
            lda   ED_ADDR1
            sbc   #1
            sta   ED_RAFTER
            lda   ED_ADDR1+1
            sbc   #0
            sta   ED_RAFTER+1
            ;-- FF4 (2026-09-06): remember the pre-read cursor
            ;-- so we can put dot on the FIRST inserted line
            ;-- (POSIX) once ED_READLOOP is done -- its own
            ;-- default leaves dot on the LAST line, right for
            ;-- `r` but wrong for an addressed filter.
            lda   ED_RAFTER
            sta   EX_FSTART
            lda   ED_RAFTER+1
            sta   EX_FSTART+1
            jsr   EX_BG_OOPNR
            bcc   :x11
            jmp   :bf_noout
:x11
            lda   EX_BG_FD
            sta   ED_RFD
            stz   R_RDPOS
            stz   R_RDLEN
            jsr   ED_READLOOP
            lda   ED_RAFTER
            cmp   EX_FSTART
            bne   :bf_dotfix
            lda   ED_RAFTER+1
            cmp   EX_FSTART+1
            beq   :bf_nodot        ;nothing inserted -- dot
                                    ;stays where ED_DLT_RANGE
                                    ;left it
:bf_dotfix  lda   EX_FSTART
            sta   ED_CURLINE
            lda   EX_FSTART+1
            sta   ED_CURLINE+1
            inc   ED_CURLINE
            bne   :bf_nodot
            inc   ED_CURLINE+1
:bf_nodot   lda   EX_BG_FD
            jsr   EX_BG_CLOSE
            lda   #<EXBOUNL
            ldx   #>EXBOUNL
            jsr   SC_UNLINK
:bf_noout   lda   #<EXBIUNL
            ldx   #>EXBIUNL
            jsr   SC_UNLINK
            lda   #<EXBCUNL
            ldx   #>EXBCUNL
            jsr   SC_UNLINK
            jmp   MAINLOOP
:bf_spwerr  lda   #<EXBIUNL
            ldx   #>EXBIUNL
            jsr   SC_UNLINK
            lda   #<EXBCUNL
            ldx   #>EXBCUNL
            jsr   SC_UNLINK
            jmp   ED_ERR_JMP
:bf_err4    lda   EX_BG_FD
            jsr   EX_BG_CLOSE
:bf_err3b   lda   EX_BG_OWFD
            jsr   EX_BG_CLOSE
:bf_err3    lda   #<EXBIUNL
            ldx   #>EXBIUNL
            jsr   SC_UNLINK
            jmp   ED_ERR_JMP
:bf_err2    lda   EX_BG_FD
            jsr   EX_BG_CLOSE
:bf_err     jmp   ED_ERR_JMP

*---------------------------------------------------------------
* EX_WCHKBG -- EX_CWQ's own fallthrough when byte 1 isn't "q":
* is this "w" + SPACE(S) + "!" (the filter-write form), or plain
* "w"/"w!"/"w PATH" (classic chain, untouched)? "w!" (bang
* IMMEDIATELY after w, no space) is the classic force-overwrite
* flag (edfil2.s ED_CMD_W) and must NOT be caught here -- only a
* SPACE before the `!` means this command. OUT: carry clear,
* ED_CMDPTR unchanged = not this form; recognized = jmp
* EX_WBANG with Y = the `!` token's own offset.
*---------------------------------------------------------------
EX_WCHKBG   ldy   #1
            lda   (ED_CMDPTR),y
            cmp   #$A0          ;byte 1 MUST be a space; `w!`
            beq   :wcb_skip     ;(immediate bang) is the force
            clc                 ;flag -> classic chain, not this
            rts                 ;form
:wcb_skip   lda   (ED_CMDPTR),y
            cmp   #$A0
            bne   :wcb_chk
            iny
            bra   :wcb_skip
:wcb_chk    cmp   #"!"
            beq   :wcb_go
            clc
            rts
:wcb_go     jmp   EX_WBANG

*---------------------------------------------------------------
* EX_WBANG -- `[a,b]w !cmd` (filter-write, no read-back). Y (on
* entry) = the `!` token's offset -- advance ED_CMDPTR past it
* once, to the command text, before anything else. ED_ADDRCNT==
* 0 defaults to the WHOLE buffer (1,$), matching plain `w`'s own
* scope -- NOT ED_DFLT_DTDT's `.,.` (that default is for motion-
* shaped commands). Not a mutation -- no EX_SNAPSHOT. Script
* (EX.CMDxx): "cmd\r", handed to `sh` as argv[1] (`sh
* SCRIPTFILE` mode, EX3 rewire 2026-09-06); fd 0 is dup'd from
* a fresh READ of EX.INxx, fd 1/2 inherited -- a real pipeline's
* LAST stage writes straight to ex's own captured fd 1, same as
* `:!cmd`.
*---------------------------------------------------------------
EX_WBANG    iny
            tya
            clc
            adc   ED_CMDPTR
            sta   ED_CMDPTR
            lda   ED_CMDPTR+1
            adc   #0
            sta   ED_CMDPTR+1
            lda   ED_ADDRCNT
            bne   :wb_dflt
            lda   #1
            sta   ED_ADDR1
            stz   ED_ADDR1+1
            lda   ED_NLINES
            sta   ED_ADDR2
            lda   ED_NLINES+1
            sta   ED_ADDR2+1
            bra   :wb_rchk
:wb_dflt    jsr   ED_DFLT_DTDT
:wb_rchk    jsr   ED_CHC_RNG12N
            bcc   :wb_rngok
            jmp   ED_ERR_JMP
:wb_rngok   jsr   EX_BG_MKNAM
            jsr   EX_BG_IOPNW
            bcc   :x1
            jmp   :wb_err
:x1
            jsr   EX_WRR_FD
            bcc   :x2
            jmp   :wb_err2
:x2
            lda   EX_BG_FD
            jsr   EX_BG_CLOSE
            jsr   EX_BG_COPNW
            bcc   :x3
            jmp   :wb_err3
:x3
            lda   ED_CMDPTR
            sta   PTR0
            lda   ED_CMDPTR+1
            sta   PTR0+1
            jsr   EX_BG_WRLIT
            bcc   :x4
            jmp   :wb_err4
:x4
            jsr   EX_BG_WRCR
            bcc   :x5
            jmp   :wb_err4
:x5
            lda   EX_BG_FD
            jsr   EX_BG_CLOSE
            jsr   EX_BG_IOPNR
            bcc   :x6
            jmp   :wb_spwerr        ;EX.IN/EX.CMD both exist --
                                    ;same cleanup as a spawn
                                    ;failure's
:x6
            lda   #FDACT_DUP
            sta   EX_BG_FDACT
            stz   EX_BG_FDACT+1
            lda   EX_BG_IRFD
            sta   EX_BG_FDACT+2
            lda   #FDACT_END
            sta   EX_BG_FDACT+3
            jsr   EX_BG_SPAWN
            php
            lda   EX_BG_IRFD
            jsr   EX_BG_CLOSE
            plp
            bcc   :x8
            jmp   :wb_spwerr
:x8
            lda   #<EXBIUNL
            ldx   #>EXBIUNL
            jsr   SC_UNLINK
            lda   #<EXBCUNL
            ldx   #>EXBCUNL
            jsr   SC_UNLINK
            jmp   MAINLOOP
:wb_spwerr  lda   #<EXBIUNL
            ldx   #>EXBIUNL
            jsr   SC_UNLINK
            lda   #<EXBCUNL
            ldx   #>EXBCUNL
            jsr   SC_UNLINK
            jmp   ED_ERR_JMP
:wb_err4    lda   EX_BG_FD
            jsr   EX_BG_CLOSE
:wb_err3    lda   #<EXBIUNL
            ldx   #>EXBIUNL
            jsr   SC_UNLINK
            jmp   ED_ERR_JMP
:wb_err2    lda   EX_BG_FD
            jsr   EX_BG_CLOSE
:wb_err     jmp   ED_ERR_JMP

*---------------------------------------------------------------
* EX_CRHOOK -- EX_CMD's own `r` entry (Y=0 is `r`, unconsumed).
* Is this "r" + SPACE(S) + "!" (":r !cmd"), or plain "r"/"r
* file" (classic ED_CMD_R, untouched)? Two addresses is refused
* here (same scope as classic `r`) rather than falling through
* and letting ED_PRS_FNAME misread " !cmd" as a literal
* filename.
*---------------------------------------------------------------
EX_CRHOOK   ldy   #1
:rh_skip    lda   (ED_CMDPTR),y
            cmp   #$A0
            bne   :rh_chk
            iny
            bra   :rh_skip
:rh_chk     cmp   #"!"
            beq   :rh_go
            clc
            rts
:rh_go      lda   ED_ADDRCNT
            cmp   #2
            bne   :rh_addrok
            jmp   ED_ERR_JMP
:rh_addrok  iny
            tya
            clc
            adc   ED_CMDPTR
            sta   ED_CMDPTR
            lda   ED_CMDPTR+1
            adc   #0
            sta   ED_CMDPTR+1
            jmp   EX_RBANG

*---------------------------------------------------------------
* EX_RBANG -- `:r !cmd` / `[addr]r !cmd`. ED_CMDPTR (on entry)
* already points at the command text; ED_ADDRCNT is 0 or 1.
* Insert point defaults to the CURRENT line (0 addresses) or the
* one given address -- unlike classic `r`'s own "append at $"
* default, matching real ex's `r` (POSIX). Mutating -- snapshot
* first, exactly like `e` (EX_CEDIT) -- unless a g/v pass is
* already holding the pre-global snapshot (EX7 2026-09-06, same
* `ldx ED_GMODE / bne` gate as edparse.s's :havecmd). Validates
* the resolved address (EX1 2026-09-06) with ED_CHECK0N BEFORE
* any snapshot/spawn -- classic `r` has always had this guard
* (edfil2.s), this path had dropped it, and a bad address here
* reached ED_INSRT_AFTR's descending shift and corrupted the
* line table. Script (EX.CMDxx): "cmd\r", handed to `sh` as
* argv[1] (`sh SCRIPTFILE` mode, EX3 rewire 2026-09-06); fd 1
* is dup'd onto a fresh WRITE of EX.OUTxx (pre-opened via
* EX_BG_OOPNW), fd 0/2 inherited -- a real pipeline's LAST
* stage lands in EX.OUTxx, same as any other stdout redirect.
*---------------------------------------------------------------
EX_RBANG    lda   ED_ADDRCNT
            bne   :rb_use1
            lda   ED_CURLINE
            sta   ED_ADDR1
            lda   ED_CURLINE+1
            sta   ED_ADDR1+1
:rb_use1    jsr   ED_CHECK0N
            bcc   :rb_addrok
            jmp   ED_ERR_JMP
:rb_addrok  lda   ED_GMODE
            bne   :rb_skipsnap
            jsr   EX_SNAPSHOT
:rb_skipsnap
            jsr   EX_BG_MKNAM
            jsr   EX_BG_COPNW
            bcc   :x1
            jmp   :rb_err
:x1
            lda   ED_CMDPTR
            sta   PTR0
            lda   ED_CMDPTR+1
            sta   PTR0+1
            jsr   EX_BG_WRLIT
            bcc   :x2
            jmp   :rb_err2
:x2
            jsr   EX_BG_WRCR
            bcc   :x3
            jmp   :rb_err2
:x3
            lda   EX_BG_FD
            jsr   EX_BG_CLOSE
            jsr   EX_BG_OOPNW
            bcc   :x4
            jmp   :rb_spwerr        ;EX.CMD exists -- same
                                    ;cleanup as a spawn
                                    ;failure's
:x4
            lda   EX_BG_FD
            sta   EX_BG_OWFD
            lda   #FDACT_DUP
            sta   EX_BG_FDACT
            lda   #1
            sta   EX_BG_FDACT+1
            lda   EX_BG_OWFD
            sta   EX_BG_FDACT+2
            lda   #FDACT_END
            sta   EX_BG_FDACT+3
            jsr   EX_BG_SPAWN
            php
            lda   EX_BG_OWFD
            jsr   EX_BG_CLOSE
            plp
            bcc   :x6
            jmp   :rb_spwerr
:x6
            jsr   EX_BG_OOPNR
            bcc   :x7
            jmp   :rb_noout
:x7
            lda   EX_BG_FD
            sta   ED_RFD
            stz   R_RDPOS
            stz   R_RDLEN
            lda   ED_ADDR1
            sta   ED_RAFTER
            lda   ED_ADDR1+1
            sta   ED_RAFTER+1
            jsr   ED_READLOOP
            lda   EX_BG_FD
            jsr   EX_BG_CLOSE
            lda   #<EXBOUNL
            ldx   #>EXBOUNL
            jsr   SC_UNLINK
:rb_noout   lda   #<EXBCUNL
            ldx   #>EXBCUNL
            jsr   SC_UNLINK
            jmp   MAINLOOP
:rb_spwerr  lda   #<EXBCUNL
            ldx   #>EXBCUNL
            jsr   SC_UNLINK
            jmp   ED_ERR_JMP
:rb_err2    lda   EX_BG_FD
            jsr   EX_BG_CLOSE
            lda   #<EXBCUNL
            ldx   #>EXBCUNL
            jsr   SC_UNLINK
            jmp   ED_ERR_JMP
:rb_err     jmp   ED_ERR_JMP

*---------------------------------------------------------------
* EX_WRR_FD -- write lines ED_ADDR1..ED_ADDR2 (inclusive) to
* EX_BG_FD, one SC_WRITE per line's text plus a CR -- the `!`
* family's own line source (ED_DOWRITE is NOT reused: it parses
* a filename, applies the w! guard, and clears EX_DIRTY, none of
* which apply to a filter's INPUT). OUT: carry clear = wrote the
* whole range; carry set = a write failed partway.
*---------------------------------------------------------------
EX_WRR_FD   lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
:wr_loop    jsr   ED_LINETEXT
            jsr   EX_BG_WRLIT
            bcs   :wr_fail
            jsr   EX_BG_WRCR
            bcs   :wr_fail
            lda   ED_TMP16
            cmp   ED_ADDR2
            bne   :wr_next
            lda   ED_TMP16+1
            cmp   ED_ADDR2+1
            beq   :wr_done
:wr_next    inc   ED_TMP16
            bne   :wr_loop
            inc   ED_TMP16+1
            bra   :wr_loop
:wr_done    clc
            rts
:wr_fail    sec
            rts

*---------------------------------------------------------------
* EX_BG_MKNAM -- build the three temp-file names/paths the `!`
* family shares: EX.INxx (filter/w! input), EX.OUTxx (filter/r!
* output), EX.CMDxx (the one-line script handed to `sh`'s own fd
* 0) -- xx = 2 hex digits of BANK_ID, EXSW_ENSURE's own
* convention (exbuf.s), so concurrent ex/vi instances in
* different banks never collide. Idempotent -- safe to call
* before every `!` invocation, unlike EXSW_ENSURE's lazy-once
* swap open.
*---------------------------------------------------------------
EX_BG_MKNAM ldy   #0
:mn_in      lda   EXBG_INLIT,y
            sta   EX_BG_INNM,y
            iny
            cpy   #5
            bne   :mn_in
            lda   BANK_ID
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            jsr   EX_HEXCH
            sta   EX_BG_INNM+5
            lda   BANK_ID
            and   #$0F
            jsr   EX_HEXCH
            sta   EX_BG_INNM+6
            stz   EX_BG_INNM+7
            lda   #<EX_BG_INNM
            sta   PTR0
            lda   #>EX_BG_INNM
            sta   PTR0+1
            lda   #<EX_BG_INPTH
            sta   PTR1
            lda   #>EX_BG_INPTH
            sta   PTR1+1
            jsr   MKPATH

            ldy   #0
:mn_out     lda   EXBG_OUTLIT,y
            sta   EX_BG_OUTNM,y
            iny
            cpy   #6
            bne   :mn_out
            lda   BANK_ID
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            jsr   EX_HEXCH
            sta   EX_BG_OUTNM+6
            lda   BANK_ID
            and   #$0F
            jsr   EX_HEXCH
            sta   EX_BG_OUTNM+7
            stz   EX_BG_OUTNM+8
            lda   #<EX_BG_OUTNM
            sta   PTR0
            lda   #>EX_BG_OUTNM
            sta   PTR0+1
            lda   #<EX_BG_OUTPTH
            sta   PTR1
            lda   #>EX_BG_OUTPTH
            sta   PTR1+1
            jsr   MKPATH

            ldy   #0
:mn_cmd     lda   EXBG_CMDLIT,y
            sta   EX_BG_CMDNM,y
            iny
            cpy   #6
            bne   :mn_cmd
            lda   BANK_ID
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            jsr   EX_HEXCH
            sta   EX_BG_CMDNM+6
            lda   BANK_ID
            and   #$0F
            jsr   EX_HEXCH
            sta   EX_BG_CMDNM+7
            stz   EX_BG_CMDNM+8
            lda   #<EX_BG_CMDNM
            sta   PTR0
            lda   #>EX_BG_CMDNM
            sta   PTR0+1
            lda   #<EX_BG_CMDPTH
            sta   PTR1
            lda   #>EX_BG_CMDPTH
            sta   PTR1+1
            jmp   MKPATH

*---------------------------------------------------------------
* EX_BG_IOPNW -- CREATE(ignore exists)+OPEN EX.INxx for write,
* then EX_BG_TRUNC (a REUSED temp file from a shorter prior
* write must not keep a stale tail -- ED_DOWRITE's own
* reasoning). OUT: fd in EX_BG_FD, carry clear; carry set =
* CREATE/OPEN/SETEOF failed.
*---------------------------------------------------------------
EX_BG_IOPNW lda   #<EXBICRE
            ldx   #>EXBICRE
            jsr   SC_CREAT
            stz   EXBIOPN_IOB
            stz   EXBIOPN_IOB+1
            lda   #<EXBIOPN
            ldx   #>EXBIOPN
            jsr   SC_OPEN
            bcs   :iw_fail
            lda   EXBIOPN_REF
            sta   EX_BG_FD
            jmp   EX_BG_TRUNC
:iw_fail    sec
            rts

*---------------------------------------------------------------
* EX_BG_COPNW -- same shape as EX_BG_IOPNW, for EX.CMDxx.
*---------------------------------------------------------------
EX_BG_COPNW lda   #<EXBCCRE
            ldx   #>EXBCCRE
            jsr   SC_CREAT
            stz   EXBCOPW_IOB
            stz   EXBCOPW_IOB+1
            lda   #<EXBCOPW
            ldx   #>EXBCOPW
            jsr   SC_OPEN
            bcs   :cw_fail
            lda   EXBCOPW_REF
            sta   EX_BG_FD
            jmp   EX_BG_TRUNC
:cw_fail    sec
            rts

*---------------------------------------------------------------
* EX_BG_OOPNW -- CREATE+OPEN+TRUNC EX.OUTxx for WRITE. Used by
* BOTH the filter form and `r !cmd` (EX3 rewire, 2026-09-06):
* `sh`'s own script is argv[1] TEXT now, with no `<`/`>` syntax
* of its own left to parse, so both forms pre-open EX.OUTxx
* here and hand it to the child via fdactions fd 1 --
* EX_BG_SPAWN2 for the filter (fd 0 ALSO wired, to EX.INxx),
* plain EX_BG_SPAWN for `r !cmd` (fd 0 inherited). Originally
* added for the filter alone: measured 2026-09-06, BEFORE this
* rewire, `sh` parsing BOTH `<` and `>` on the SAME command
* line, three spawns deep (ex->sh->filter), silently produced
* NO output -- reliable at two levels (a bare harness spawning
* `sh` directly) and reliable with EITHER redirect alone at
* three, but not both together.
*---------------------------------------------------------------
EX_BG_OOPNW lda   #<EXBOCRE
            ldx   #>EXBOCRE
            jsr   SC_CREAT
            stz   EXBOOPW_IOB
            stz   EXBOOPW_IOB+1
            lda   #<EXBOOPW
            ldx   #>EXBOOPW
            jsr   SC_OPEN
            bcs   :ow_fail
            lda   EXBOOPW_REF
            sta   EX_BG_FD
            jmp   EX_BG_TRUNC
:ow_fail    sec
            rts

*---------------------------------------------------------------
* EX_BG_TRUNC -- SET_EOF(0) on EX_BG_FD, the shared tail of
* EX_BG_IOPNW/EX_BG_COPNW. Closes EX_BG_FD on a SETEOF failure
* (ED_DOWRITE's own :wfail posture) rather than leaking it. OUT:
* carry clear = truncated; carry set = SETEOF failed, fd closed.
*---------------------------------------------------------------
EX_BG_TRUNC lda   EX_BG_FD
            sta   EXBSE_REF
            stz   EXBSE_EOF
            stz   EXBSE_EOF+1
            stz   EXBSE_EOF+2
            lda   #<EXBSE
            ldx   #>EXBSE
            jsr   SC_SETEOF
            bcc   :tr_ok
            lda   EX_BG_FD
            jsr   EX_BG_CLOSE
            sec
            rts
:tr_ok      clc
            rts

*---------------------------------------------------------------
* EX_BG_IOPNR -- REOPEN EX.INxx read-only (a fresh fd at offset
* 0, handed to `sh`'s CHILD as ITS fd 0 via fdactions -- EX3
* rewire 2026-09-06, mirrors the OLD EX_BG_COPNR's shape (a
* fresh fd sidesteps the dup-offset problem) for the FIRST
* pipeline stage's input instead of the whole script). OUT: fd
* in EX_BG_IRFD, carry clear; carry set = OPEN failed.
*---------------------------------------------------------------
EX_BG_IOPNR stz   EXBIOPR_IOB
            stz   EXBIOPR_IOB+1
            lda   #<EXBIOPR
            ldx   #>EXBIOPR
            jsr   SC_OPEN
            bcs   :ir_fail
            lda   EXBIOPR_REF
            sta   EX_BG_IRFD
            clc
            rts
:ir_fail    sec
            rts

*---------------------------------------------------------------
* EX_BG_OOPNR -- OPEN EX.OUTxx for read-back (created and filled
* by `sh`'s own `>` redirection -- ex never CREATEs it). OUT: fd
* in EX_BG_FD, carry clear; carry set = not there / OPEN failed
* (the command produced no output, or failed outright).
*---------------------------------------------------------------
EX_BG_OOPNR stz   EXBOOPR_IOB
            stz   EXBOOPR_IOB+1
            lda   #<EXBOOPR
            ldx   #>EXBOOPR
            jsr   SC_OPEN
            bcs   :or_fail
            lda   EXBOOPR_REF
            sta   EX_BG_FD
            clc
            rts
:or_fail    sec
            rts

*---------------------------------------------------------------
* EX_BG_WRLIT -- IN: PTR0 = a NUL-terminated liba string (a
* command-text pointer into CMDBUF, or one of this file's own
* literal fragments/name buffers -- all the same shape). Writes
* it whole to EX_BG_FD. OUT: carry from SC_WRITE.
*---------------------------------------------------------------
EX_BG_WRLIT jsr   STRLEN
            sta   EXBWR_REQ
            stx   EXBWR_REQ+1
            lda   PTR0
            sta   EXBWR_BUF
            lda   PTR0+1
            sta   EXBWR_BUF+1
            lda   EX_BG_FD
            sta   EXBWR_REF
            lda   #<EXBWR
            ldx   #>EXBWR
            jmp   SC_WRITE

*---------------------------------------------------------------
* EX_BG_WRCR -- write one CR ($8D) to EX_BG_FD, reusing
* edfil2.s's own WCRPARM/WCRBYTE (the same "one CR byte" write
* ED_DOWRITE already does, just retargeted). OUT: carry from
* SC_WRITE.
*---------------------------------------------------------------
EX_BG_WRCR  lda   EX_BG_FD
            sta   WCRPARM_REF
            lda   #<WCRPARM
            ldx   #>WCRPARM
            jmp   SC_WRITE

*---------------------------------------------------------------
* EX_BG_CLOSE -- IN: A = fd. Generic close, reused by every step
* of the `!` family (each fd is opened, used, and closed well
* before the next one opens -- never two live at once).
*---------------------------------------------------------------
EX_BG_CLOSE sta   EXBCL_REF
            lda   #<EXBCL
            ldx   #>EXBCL
            jmp   SC_CLOSE

*---------------------------------------------------------------
* EX_BG_MKARGV -- build the argv every `!` form now shares:
* {"sh", EX_BG_CMDNM, NULL} -- `sh SCRIPTFILE` mode (EX3 rewire
* 2026-09-06). EX_BG_CMDNM is the SHORT high-bit liba name
* EX_BG_MKNAM already built (e.g. "EX.CMD01"), the SAME shape
* EX_BG_INNM/EX_BG_OUTNM were always written into script TEXT
* as -- NOT EX_BG_CMDPTH, which MKPATH already resolved to a
* 7-bit MLI pathname (mli.s's own boundary: liba strings are
* high-bit, ProDOS pathnames are not) and would misparse if
* handed back to `sh`'s OWN MKPATH call inside
* OPEN_REDIR_RD. CLOBBERS: A.
*---------------------------------------------------------------
EX_BG_MKARGV
            lda   #<EXBG_SHWORD
            sta   EX_BG_ARGV
            lda   #>EXBG_SHWORD
            sta   EX_BG_ARGV+1
            lda   #<EX_BG_CMDNM
            sta   EX_BG_ARGV+2
            lda   #>EX_BG_CMDNM
            sta   EX_BG_ARGV+3
            stz   EX_BG_ARGV+4
            stz   EX_BG_ARGV+5
            rts

*---------------------------------------------------------------
* EX_BG_SPAWN -- resolve `sh` against PATH/PATHTAB (PATHRSLV,
* find -exec's own template -- findact.s), spawn it with argv=
* {"sh", EX_BG_CMDNM} (EX_BG_MKARGV -- `sh` opens its OWN script
* via argv[1], EX3 rewire 2026-09-06) and CALLER-SUPPLIED
* fdactions already built in EX_BG_FDACT (0, 1, or 2 entries --
* EX_BANG_ESC needs none, EX_WBANG/EX_RBANG one, EX_BANG_FILT's
* own EX_BG_SPAWN2 two), and wait. v1 passes no environment
* (SPWN_ENVP=0) -- `sh` falls back to PATHTAB and still finds
* /bin/SORT etc. OUT: carry clear = spawned and waited;
* carry
* set = `sh` not found or SC_SPAWN/SC_WAIT itself failed -- the
* CALLER's own fd(s) (named in EX_BG_FDACT) are NOT closed here;
* every caller already owns that cleanup around this call. XC4
* 2026-09-06: the CHILD's own exit status (EX_BG_WSTAT) is
* deliberately NOT folded into this carry or into ED_ERRSTAT --
* a shell command that ran and exited nonzero is not an ex error
* under the POSIX ex/ed oracle; only a genuine infrastructure
* failure (spawn/wait) is.
*
* FLUSHES fd 1 FIRST. `%p`/`,p`/etc. write through liba's own
* buffered stdio (PUTS -- SIOM_FULL for a non-tty fd 1, which
* EXCAP-style captures always are); the child this spawns writes
* to the SAME fd via its own raw SC_WRITE, bypassing that buffer
* entirely. Measured 2026-09-06: without this, a `%p` right
* before a `!`/`r !`/`w !` command landed AFTER the spawned
* child's own output in the captured file -- program order and
* byte order diverged. SIO_FLUSH is a cheap no-op when nothing
* is buffered (its own header).
*---------------------------------------------------------------
*
* CONSOLE HOOKS (2026-09-07): EX_ONSPAWN right after the flush,
* EX_ONSPAWNED on EVERY exit including the failure ones -- vi's
* bodies (vicmd.s) hand the console to the child cooked and
* take raw mode back; ex.s's are no-op stubs. The carry verdict
* is re-derived AFTER the post hook (it clobbers A/X/Y).
*---------------------------------------------------------------
EX_BG_SPAWN ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            jsr   EX_ONSPAWN
            jsr   EX_BG_MKARGV
            lda   #<EXBG_SHWORD
            sta   PTR0
            lda   #>EXBG_SHWORD
            sta   PTR0+1
            jsr   PATHRSLV
            bcs   :sp_fail0
            stz   SPWN_ENVP
            stz   SPWN_ENVP+1
            lda   #<EX_BG_ARGV
            sta   PTR1
            lda   #>EX_BG_ARGV
            sta   PTR1+1
            lda   #<EX_BG_FDACT
            sta   PTR2
            lda   #>EX_BG_FDACT
            sta   PTR2+1
            jsr   SC_SPAWN
            bcs   :sp_fail0
            lda   #<EX_BG_WSTAT
            sta   PTR0
            lda   #>EX_BG_WSTAT
            sta   PTR0+1
            jsr   SC_WAIT         ;XC4: WSTAT->ED_ERRSTAT
                                  ;fold withdrawn -- a ran-
                                  ;and-exited shell command
                                  ;is not an ex error. Only
                                  ;SC_WAIT's own carry (an
                                  ;infra failure) propagates,
                                  ;so callers' plain `bcs ->
                                  ;ED_ERR_JMP` still fires on
                                  ;a real failure (EX_BG_WSTAT
                                  ;left unread here).
            bcs   :sp_fail0
:sp_ok      jsr   EX_ONSPAWNED
            clc
            rts
:sp_fail0   jsr   EX_ONSPAWNED
            sec
            rts

*---------------------------------------------------------------
* EX_BG_SPAWN2 -- EX_BG_SPAWN's own shape, for the FILTER form
* ONLY: EX_BANG_FILT has ALREADY built a 2-entry fdactions list
* in EX_BG_FDACT (dup EX_BG_IRFD, the fresh EX.INxx read fd,
* onto the child's fd 0; dup EX_BG_OWFD, EX_BG_OOPNW's pre-
* opened EX.OUTxx, onto fd 1) -- so a REAL pipeline attaches to
* the WHOLE execution, both ends, same as any other `sh
* SCRIPTFILE` spawn (EX3 rewire 2026-09-06). Both of EX's own
* fd copies close right after SC_SPAWN -- the child got its OWN
* independent references via the fdactions dups (PRC_DUP2_SET),
* so holding them here costs a needless iobuf for the whole
* run. Flushes fd 1 first too, same reasoning as EX_BG_SPAWN's
* own header -- defensive here (the filter child's own fd 1 is
* EX_BG_OWFD, not the console), but cheap and keeps the two
* routines' console-ordering guarantee identical. OUT/CLOBBERS:
* same as EX_BG_SPAWN -- carry set on failure closes
* EX_BG_IRFD/EX_BG_OWFD here too, since EX_BANG_FILT's own
* error path (:bf_spwerr) does not.
*---------------------------------------------------------------
EX_BG_SPAWN2
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            jsr   EX_ONSPAWN      ;console hooks: EX_BG_SPAWN
            jsr   EX_BG_MKARGV
            lda   #<EXBG_SHWORD
            sta   PTR0
            lda   #>EXBG_SHWORD
            sta   PTR0+1
            jsr   PATHRSLV
            bcc   :s2b
            jmp   :sp2_fail0
:s2b
            stz   SPWN_ENVP
            stz   SPWN_ENVP+1
            lda   #<EX_BG_ARGV
            sta   PTR1
            lda   #>EX_BG_ARGV
            sta   PTR1+1
            lda   #<EX_BG_FDACT
            sta   PTR2
            lda   #>EX_BG_FDACT
            sta   PTR2+1
            jsr   SC_SPAWN
            bcc   :s2c
            jmp   :sp2_fail1
:s2c
            lda   EX_BG_IRFD
            jsr   EX_BG_CLOSE
            lda   EX_BG_OWFD
            jsr   EX_BG_CLOSE
            lda   #<EX_BG_WSTAT
            sta   PTR0
            lda   #>EX_BG_WSTAT
            sta   PTR0+1
            jsr   SC_WAIT         ;XC4: same withdrawal as
                                  ;EX_BG_SPAWN -- the child's
                                  ;own status is not folded
                                  ;in; only SC_WAIT's carry
                                  ;(infra failure) propagates.
            bcs   :sp2_fail0
:s2ok       jsr   EX_ONSPAWNED
            clc
            rts
:sp2_fail1  lda   EX_BG_IRFD
            jsr   EX_BG_CLOSE
            lda   EX_BG_OWFD
            jsr   EX_BG_CLOSE
:sp2_fail0  jsr   EX_ONSPAWNED
            sec
            rts

*---------------------------------------------------------------
* The `!` family's own literal fragments and temp-file name
* stems (see EX_BG_MKNAM). Double-quoted `asc` -- high-bit
* ASCII, the console/CMDBUF convention throughout this file.
*---------------------------------------------------------------
EXBG_INLIT  asc   "EX.IN"
EXBG_OUTLIT asc   "EX.OUT"
EXBG_CMDLIT asc   "EX.CMD"
EXBG_SHWORD asc   "sh"
            dfb   0

*---------------------------------------------------------------
* EX.INxx parmlists (CREATE ignore-exists / OPEN write / UNLINK)
* -- same shape as exbuf.s's own EXCRE/EXOPP/EXUNL, one set per
* temp file since each parmlist's PATH field is bound to one
* fixed buffer.
*---------------------------------------------------------------
EXBICRE      dfb   PCOUNT_CREATE
EXBICRE_PATH da    EX_BG_INPTH
EXBICRE_ACC  dfb   ACCESS_UNLKD
EXBICRE_FTY  dfb   FTYPE_TXT
EXBICRE_AUX  da    0
EXBICRE_STY  dfb   STYP_SEEDLING
EXBICRE_CDT  da    0
EXBICRE_CTM  da    0

EXBIOPN      dfb   PCOUNT_OPEN
EXBIOPN_PATH da    EX_BG_INPTH
EXBIOPN_IOB  da    0
EXBIOPN_REF  dfb   0

EXBIUNL      dfb   PCNT_DESTROY
EXBIUNL_PATH da    EX_BG_INPTH

* EX_BG_IOPNR's own OPEN(read) -- a FRESH fd at offset 0, dup'd
* onto the spawned child's fd 0 via fdactions (EX3 rewire).
EXBIOPR      dfb   PCOUNT_OPEN
EXBIOPR_PATH da    EX_BG_INPTH
EXBIOPR_IOB  da    0
EXBIOPR_REF  dfb   0

*---------------------------------------------------------------
* EX.OUTxx parmlists -- OPEN(read)/UNLINK to read the result
* back (EX_BG_OOPNR, `r !cmd` and the filter form alike) PLUS
* CREATE/OPEN(write) (EX_BG_OOPNW) to PRE-open EX.OUTxx and
* hand it to `sh` via fdactions fd 1 -- EX3 rewire, 2026-09-06:
* BOTH `r !cmd` and the filter now do this (neither trusts
* `sh`'s own `>` parsing any more; `sh`'s script is argv[1]
* text now, with no redirection syntax of its own left to
* parse).
*---------------------------------------------------------------
EXBOOPR      dfb   PCOUNT_OPEN
EXBOOPR_PATH da    EX_BG_OUTPTH
EXBOOPR_IOB  da    0
EXBOOPR_REF  dfb   0

EXBOUNL      dfb   PCNT_DESTROY
EXBOUNL_PATH da    EX_BG_OUTPTH

EXBOCRE      dfb   PCOUNT_CREATE
EXBOCRE_PATH da    EX_BG_OUTPTH
EXBOCRE_ACC  dfb   ACCESS_UNLKD
EXBOCRE_FTY  dfb   FTYPE_TXT
EXBOCRE_AUX  da    0
EXBOCRE_STY  dfb   STYP_SEEDLING
EXBOCRE_CDT  da    0
EXBOCRE_CTM  da    0

EXBOOPW      dfb   PCOUNT_OPEN
EXBOOPW_PATH da    EX_BG_OUTPTH
EXBOOPW_IOB  da    0
EXBOOPW_REF  dfb   0

*---------------------------------------------------------------
* EX.CMDxx parmlists -- CREATE/OPEN-write (build the script) and
* UNLINK. `sh` opens this itself, via argv[1] (EX3 rewire), so
* there is no ex-side OPEN-read/reopen for it any more.
*---------------------------------------------------------------
EXBCCRE      dfb   PCOUNT_CREATE
EXBCCRE_PATH da    EX_BG_CMDPTH
EXBCCRE_ACC  dfb   ACCESS_UNLKD
EXBCCRE_FTY  dfb   FTYPE_TXT
EXBCCRE_AUX  da    0
EXBCCRE_STY  dfb   STYP_SEEDLING
EXBCCRE_CDT  da    0
EXBCCRE_CTM  da    0

EXBCOPW      dfb   PCOUNT_OPEN
EXBCOPW_PATH da    EX_BG_CMDPTH
EXBCOPW_IOB  da    0
EXBCOPW_REF  dfb   0

EXBCUNL      dfb   PCNT_DESTROY
EXBCUNL_PATH da    EX_BG_CMDPTH

*---------------------------------------------------------------
* Shared generic parmlists -- SET_EOF(0) (truncate a reused temp
* file), WRITE (EX_BG_WRLIT, ref/buf/req patched per call), and
* CLOSE (EX_BG_CLOSE, ref patched per call). Same reuse posture
* as edfil2.s's own WWPARM/WCLPARM.
*---------------------------------------------------------------
EXBSE       dfb   2
EXBSE_REF   dfb   0
EXBSE_EOF   dfb   0,0,0

EXBWR       dfb   PCOUNT_WRITE
EXBWR_REF   dfb   0
EXBWR_BUF   da    0
EXBWR_REQ   da    0
EXBWR_TRN   da    0

EXBCL       dfb   PCOUNT_CLOSE
EXBCL_REF   dfb   0

