*---------------------------------------------------------------
* edfil2.s -- ed's file-read half,
* split from edfile.s at a GLOBAL boundary for the as source
* window (S9-PLAN sec 6, tier 2). One assembly stream: ALWAYS
* put immediately after its predecessor; every rule in the
* original header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* ED_RDFILELINE -- like ED_RDCMDLINE, but reads from ED_RFD
* using its own read-ahead state (R_RDBUF/R_RDPOS/R_RDLEN), for
* the `r` command.
*---------------------------------------------------------------
ED_RDFILELINE
            ldy   #0
:copy       lda   R_RDPOS
            cmp   R_RDLEN
            bcc   :havebyte
            jsr   ED_REFILL_R
            lda   R_RDLEN
            bne   :copy
            lda   #0
            sta   CMDBUF,y
            tya
            sec
            rts
:havebyte   ldx   R_RDPOS
            lda   R_RDBUF,x
            inc   R_RDPOS
            cmp   #$8D
            bne   :notcr
            lda   #0
            sta   CMDBUF,y
            tya
            clc
            rts
:notcr      cpy   #CMDBUF_MAXLEN-1
            bcs   :trunc
            sta   CMDBUF,y
            iny
:trunc      bra   :copy

ED_REFILL_R lda   ED_RFD
            sta   RRPARM_REF
            tya
            pha
            lda   #<RRPARM
            ldx   #>RRPARM
            jsr   SC_READ
            pla
            tay
            bcs   :err
            lda   RRPARM_TRANS
            sta   R_RDLEN
            stz   R_RDPOS
            rts
:err        stz   R_RDLEN
            stz   R_RDPOS
            rts

RRPARM         dfb   PCOUNT_READ
RRPARM_REF     dfb   0
RRPARM_BUF     da    R_RDBUF
RRPARM_REQ     da    128
RRPARM_TRANS   da    0

ED_CMD_R    lda   ED_ADDRCNT
            cmp   #2
            bne   :toerr10
            jmp   ED_ERR_JMP
:toerr10
            lda   ED_ADDRCNT
            bne   :haveaddr
            ;-- FF3 (2026-09-06): classic `r FILE` with no
            ;-- address -- POSIX ed appends at $, POSIX ex (and
            ;-- maux's own `r !cmd`, EX_RBANG) inserts at . --
            ;-- ED_R_DFLT_DOT picks the default per binary.
            lda   #ED_R_DFLT_DOT
            beq   :r_dflt_eof
            lda   ED_CURLINE
            sta   ED_ADDR1
            lda   ED_CURLINE+1
            sta   ED_ADDR1+1
            bra   :haveaddr
:r_dflt_eof lda   ED_NLINES
            sta   ED_ADDR1
            lda   ED_NLINES+1
            sta   ED_ADDR1+1
:haveaddr   jsr   ED_CHECK0N
            bcc   :toerr11
            jmp   ED_ERR_JMP
:toerr11
            ;`r` with no filename reuses the remembered one (set
            ;by `e`/the initial load or a `w PATH`) -- but `r
            ;PATH` itself does NOT rebind it (POSIX: only e/f
            ;and the initial load change the current filename,
            ;2026-09-06). A later bare `w` writes back to the
            ;file the session opened, not to what `r` pulled in.
            jsr   ED_PRS_FNAME
            bcs   :r_nofname
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            bra   :r_pathrdy
:r_nofname  jsr   ED_HAS_FNAME
            bcs   :r_pathrdy
            jmp   ED_ERR_JMP
:r_pathrdy
            stz   ROPARM_IOBUF
            stz   ROPARM_IOBUF+1
            lda   #<ROPARM
            ldx   #>ROPARM
            jsr   SC_OPEN
            bcc   :toerr13
            jmp   ED_ERR_JMP
:toerr13
            lda   ROPARM_REF          ;NB: no ED_RMBR_FNAME --
            sta   ED_RFD              ;`r` must not rebind
            stz   R_RDPOS
            stz   R_RDLEN
            lda   ED_ADDR1
            sta   ED_RAFTER
            lda   ED_ADDR1+1
            sta   ED_RAFTER+1
            jsr   ED_READLOOP
            lda   ED_RFD
            sta   RCPARM_REF
            lda   #<RCPARM
            ldx   #>RCPARM
            jsr   SC_CLOSE
            jmp   MAINLOOP

*---------------------------------------------------------------
* ED_READLOOP -- IN: ED_RFD = fd to read from (already open),
* ED_RAFTER = the line to start inserting after (running cursor,
* updated as it goes; caller sets it -- ED_CMD_R uses ED_ADDR1,
* excmd.s's `e` uses 0 to insert at the very start of a freshly
* emptied table), R_RDPOS/R_RDLEN already zeroed by the caller.
* Reads CR-terminated lines via ED_RDFILELINE, inserting each
* after the running cursor, until EOF. M2 2026-09-02: split out
* of ED_CMD_R so excmd.s's `e` (replace the whole buffer with a
* new file, M2 item 6) can reuse the same load loop instead of
* duplicating it -- ED_CMD_R's own OBSERVABLE behavior is
* unchanged, this is a pure extraction. OUT: none (an
* ED_BUMP_ALLOC/ED_INSRT_AFTR failure mid-read prints `?` via
* ED_ERR and just stops early, same posture this loop always
* had).
*---------------------------------------------------------------
ED_READLOOP
:rloop      jsr   ED_RDFILELINE
            sta   ED_TMP16B
            php
            lda   ED_TMP16B
            bne   :doinsert
            plp
            bcs   :rdone
            php
:doinsert   lda   #<CMDBUF
            sta   ED_SRC
            lda   #>CMDBUF
            sta   ED_SRC+1
            lda   ED_TMP16B
            jsr   ED_BUMP_ALLOC
            bcs   :oomR
            lda   ED_RAFTER
            sta   ED_TMP16
            lda   ED_RAFTER+1
            sta   ED_TMP16+1
            jsr   ED_INSRT_AFTR
            bcs   :oomR
            lda   ED_CURLINE
            sta   ED_RAFTER
            lda   ED_CURLINE+1
            sta   ED_RAFTER+1
            plp
            bcs   :rdone
            bra   :rloop
:oomR       plp
            jsr   ED_ERR
:rdone      rts

ROPARM         dfb   PCOUNT_OPEN
ROPARM_PATH    da    PATHBUF
ROPARM_IOBUF   da    0
ROPARM_REF     dfb   0
RCPARM         dfb   PCOUNT_CLOSE
RCPARM_REF     dfb   0

*---------------------------------------------------------------
* ED_CMD_W -- write lines 1..$ to a file (no address prefix
* accepted).
*---------------------------------------------------------------
ED_CMD_W    lda   ED_ADDRCNT
            beq   :toerr14
            jmp   ED_ERR_JMP
:toerr14    stz   ED_WFORCE
            lda   #ED_WGUARD          ;ex/vi: parse `w!` (force
            beq   :w_go               ;overwrite of an existing
                                      ;path). ed `!` = future
                                      ;write-to-cmd -- untouched
            ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #"!"
            bne   :w_go
            lda   #1
            sta   ED_WFORCE
            inc   ED_CMDPTR            ;consume the `!`
            bne   :w_go
            inc   ED_CMDPTR+1
:w_go       jsr   ED_DOWRITE
            bcc   :w_ok
            jmp   ED_ERR_JMP
:w_ok       jmp   MAINLOOP

*---------------------------------------------------------------
* ED_DOWRITE -- do the actual write (filename resolution, then
* create/open/write-loop/close). M2 2026-09-02: split out of
* ED_CMD_W so excmd.s's `wq`/`x` (M2 item 1) can reuse the exact
* same write path -- ED_CMD_W's own OBSERVABLE behavior is
* unchanged, this is a pure extraction (same "no address prefix
* accepted" scope, checked by the caller before this runs).
* Calls EX_ONWRITE right before a successful return (ex: clears
* EX_DIRTY -- "cleared by w", M2 item 1; ed: no-op stub,
* edbuf.s). OUT: carry clear = wrote successfully; carry set =
* failed (no filename remembered, or a CREATE/OPEN/WRITE
* failure) -- caller decides how to report it.
*---------------------------------------------------------------
ED_DOWRITE
            ;2026-08-19: bare `w` (no filename token) uses the
            ;name remembered from the last successful r/w; bare
            ;`w` with nothing remembered yet stays `?`.
            jsr   ED_PRS_FNAME
            bcs   :w_nofname
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #ED_WGUARD          ;ex/vi guard: refuse `w
            beq   :w_pathrdy          ;PATH` if target exists
            lda   ED_WFORCE            ;and no `!` (POSIX). ed
            bne   :w_pathrdy           ;always overwrites.
            jsr   ED_FNAME_EQ         ;EX5 2026-09-06: target ==
            bcs   :w_pathrdy          ;current file needs no `!`
            lda   #<WGFIPARM
            ldx   #>WGFIPARM
            jsr   SC_GFI
            bcs   :w_pathrdy           ;GFI failed = not there,
                                       ;safe to write
            sec                         ;exists, no bang: refuse
            rts
:w_nofname  jsr   ED_HAS_FNAME
            bcs   :w_pathrdy
            sec
            rts
:w_pathrdy
            lda   #<WCREPARM
            ldx   #>WCREPARM
            jsr   SC_CREAT           ;best-effort -- see file
                                     ;header
            stz   WOPARM_IOBUF
            stz   WOPARM_IOBUF+1
            lda   #<WOPARM
            ldx   #>WOPARM
            jsr   SC_OPEN
            bcc   :toerr16
            sec
            rts
:toerr16
            ;XC1 2026-09-06: EX4's "never rebind" was too
            ;broad. POSIX is CONDITIONAL: `w PATH` sets the
            ;name only when none is established yet (an
            ;unnamed buffer); an already-named buffer keeps
            ;it. Test ED_CURFNAME directly rather than call
            ;ED_HAS_FNAME, which loads PATHBUF from
            ;ED_CURFNAME on the "already named" branch and
            ;would clobber the just-resolved target path.
            lda   ED_CURFNAME
            bne   :w_skiprmbr     ;already named -- EX4's fix
            jsr   ED_RMBR_FNAME   ;unnamed -- establish it
:w_skiprmbr
            ;The bare `w` path above (:w_nofname/
            ;ED_HAS_FNAME) is unaffected -- it only READS
            ;ED_CURFNAME, never sets it.
            lda   WOPARM_REF
            sta   ED_RFD
            ;2026-09-02: OPEN does not truncate on ProDOS, and
            ;writing fewer bytes than an existing target already
            ;held would leave its stale tail past our own EOF --
            ;SET_EOF(0) by handle right after OPEN, same idiom
            ;as liba/creat.s's CREAT and cp.s's overwrite path
            ;(both cited in the file header). A fresh/empty
            ;target is already at EOF 0, so this is a no-op
            ;there -- the common w-onto-new-file path stays put.
            sta   WSEPARM_REF
            stz   WSEPARM_EOF
            stz   WSEPARM_EOF+1
            stz   WSEPARM_EOF+2
            lda   #<WSEPARM
            ldx   #>WSEPARM
            jsr   SC_SETEOF
            bcs   :wfail
            lda   #1
            sta   ED_TMP16
            stz   ED_TMP16+1
            lda   ED_NLINES
            ora   ED_NLINES+1
            beq   :wdone
:wloop      lda   ED_TMP16
            sta   ED_TMP16B
            lda   ED_TMP16+1
            sta   ED_TMP16B+1
            jsr   ED_LINETEXT
            jsr   STRLEN         ;A/X = the 16-bit length, and
            sta   WWPARM_REQ     ;request_count is a 16-bit MLI
            stx   WWPARM_REQ+1   ;field -- a >255-byte line used
                                 ;to write as zero bytes and
                                 ;vanish from the file it was
                                 ;being saved to
            lda   PTR0
            sta   WWPARM_BUF
            lda   PTR0+1
            sta   WWPARM_BUF+1
            lda   ED_RFD
            sta   WWPARM_REF
            lda   #<WWPARM
            ldx   #>WWPARM
            jsr   SC_WRITE
            bcs   :wfail
            lda   ED_RFD
            sta   WCRPARM_REF
            lda   #<WCRPARM
            ldx   #>WCRPARM
            jsr   SC_WRITE
            bcs   :wfail
            lda   ED_TMP16B
            sta   ED_TMP16
            lda   ED_TMP16B+1
            sta   ED_TMP16+1
            lda   ED_TMP16
            cmp   ED_NLINES
            bne   :wnext
            lda   ED_TMP16+1
            cmp   ED_NLINES+1
            bne   :wnext
            bra   :wdone
:wnext      inc   ED_TMP16
            bne   :wnb
            inc   ED_TMP16+1
:wnb        bra   :wloop
:wdone      lda   ED_RFD
            sta   WCLPARM_REF
            lda   #<WCLPARM
            ldx   #>WCLPARM
            jsr   SC_CLOSE
            jsr   EX_ONWRITE          ;ex: EX_DIRTY=0, "cleared
                                      ;by w" (M2 item 1); ed:
                                      ;no-op stub
            clc
            rts

*-- A WRITE that fails is `?`, which is ed's entire error
*-- vocabulary. The fd is CLOSED first: `w` onto a locked or
*-- full target reported NOTHING before this (check-writefail's
*-- pinned defect), and leaking the ref_num would trade a silent
*-- failure for a slot the next `w` cannot have. Carry set tells
*-- the caller (ED_CMD_W, or excmd.s wq/x) to report it: `?` on
*-- stdout AND a nonzero session status via ED_ERR/ED_ERRSTAT
*-- (EX2). The buffer is intact and the editor keeps running --
*-- but a failed command IS a session error, so ed exits nonzero
*-- when it later quits or hits EOF. Real ed answers this
*-- way: POSIX "exit >0 if an error occurred", and /bin/ed exits
*-- 2 on a failed `w` even followed by `q`. (An earlier version
*-- of this note claimed exit 0 -- it was wrong; check-writefail
*-- pinned the wrong expectation to match until 2026-09-07.)
:wfail      lda   ED_RFD
            sta   WCLPARM_REF
            lda   #<WCLPARM
            ldx   #>WCLPARM
            jsr   SC_CLOSE
            sec
            rts

WCREPARM       dfb   PCOUNT_CREATE
WCREPARM_PATH  da    PATHBUF
WCREPARM_ACC   dfb   ACCESS_UNLKD
WCRPRM_FTYPE dfb   FTYPE_TXT      ;ed writes text
WCREPARM_AUX   da    0
WCRPRM_STYPE dfb   STYP_SEEDLING
WCRPRM_CDATE da    0
WCRPRM_CTIME da    0

WOPARM         dfb   PCOUNT_OPEN
WOPARM_PATH    da    PATHBUF
WOPARM_IOBUF   da    0
WOPARM_REF     dfb   0

* GET_FILE_INFO parm for the `w!` guard -- does PATHBUF already
* exist? PCOUNT_GFI-shaped (mli.equ); only the carry from SC_GFI
* is used, the result fields are scratch. (ex/vi only; ED_WGUARD
* gates the caller so ed never runs the probe.)
WGFIPARM       dfb   PCOUNT_GFI
WGFIPARM_PATH  da    PATHBUF
               dfb   0             ;access -- GFI fills the rest
               dfb   0             ;file_type
               da    0             ;aux_type
               dfb   0             ;storage_type
               da    0             ;blocks_used
               da    0             ;mod_date
               da    0             ;mod_time
               da    0             ;create_date
               da    0             ;create_time

;-- SET_EOF(0) by handle, right after OPEN -- see the :toerr16
;-- comment above. Param count 2 (ref_num + eof), same shape as
;-- liba/creat.s's CR8_SPARM/CR8_SREF/CR8_SEOF; no PCOUNT_SETEOF
;-- constant exists in inc/mli.equ, so creat.s's own hardcoded
;-- #2 is the precedent followed here.
WSEPARM        dfb   2
WSEPARM_REF    dfb   0
WSEPARM_EOF    dfb   0,0,0

WWPARM         dfb   PCOUNT_WRITE
WWPARM_REF     dfb   0
WWPARM_BUF     da    0
WWPARM_REQ     da    0
WWPARM_TRANS   da    0

WCRBYTE        dfb   $8D
WCRPARM        dfb   PCOUNT_WRITE
WCRPARM_REF    dfb   0
WCRPARM_BUF    da    WCRBYTE
WCRPARM_REQ    da    1
WCRPARM_TRANS  da    0

WCLPARM        dfb   PCOUNT_CLOSE
WCLPARM_REF    dfb   0
