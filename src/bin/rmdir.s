*---------------------------------------------------------------
* rmdir.s -- remove empty directories.
*
* Usage: rmdir [-p] DIR...
*
* CONTRACT: for each DIR argument, in order, remove it -- it
* must already be EMPTY. A DIR that cannot be removed prints
* "rmdir: cannot remove " + the pathname to stderr and rmdir
* SKIPS it, continuing with the remaining arguments (mkdir.s's
* own shape). Exit 0 if every DIR was removed, 1 if any failed.
* With no operands: usage error, exit 2.
*
* rmdir(2) does not exist on ProDOS -- MLI DESTROY ($C1) already
* removes an empty directory and refuses a non-empty one with
* $4E (street-library learning:01M0T0YSPMJE238VH46CZPDR2V, the
* TRM's own page-40 sentence; rm.s's plain, un-`-r` path already
* rests on the identical call). No new kernel support needed.
*
* -p (POSIX/BSD): after removing the leaf, also remove each
* pathname component from the right, in turn, as long as each
* removal succeeds -- BSD rmdir(1)'s own wording, measured
* (2026-09-14) against this host's rmdir: `rmdir -p a/b/c` with
* only "a" left non-empty removes c then b, reports failure on
* a, and EXITS 1 -- a parent that cannot be removed is a real,
* reported failure, not a silent stop. RMDIRP below does the
* walk; see its own header for the boundary rule.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/rmdir.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

OPTLIST     asc   "p"
            dfb   0

START       lda   #<OPTLIST
            ldx   #>OPTLIST
            jsr   OPTINIT
            stz   PFLAG
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$BF                   ;'?' unrecognised
            beq   :usage
            lda   #1                     ;OPTLIST's only other
            sta   PFLAG                  ;letter is 'p'
            bra   :optlp

:optdone    lda   ARGC
            sec
            sbc   OPTIND
            bne   :haveargs
:usage      lda   #<USAGE
            sta   PTR0
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

:haveargs   stz   ERRFLAG
            lda   OPTIND
            sta   ARGIDX
:looparg    lda   ARGIDX
            jsr   GETARG                 ;-> PTR0 = argv[ARGIDX]
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH                 ;liba string -> MLI
                                         ;pathname
            lda   PFLAG
            beq   :plain
            jsr   RMDIRP
            bra   :chkrm
:plain      lda   #<DPARM
            ldx   #>DPARM
            jsr   SC_UNLINK
:chkrm      bcc   :nextarg

            lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jsr   PRPATH                 ;PATHBUF, as it stood
                                         ;at the failing call
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG

:nextarg    inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcc   :looparg
            lda   ERRFLAG
            jsr   EXIT

USAGE       asc   "usage: rmdir [-p] DIR..."
            dfb   $8D,$00
ERRMSG      asc   "rmdir: cannot remove "
            dfb   $00

*-- MLI DESTROY ($C1): param_count=1, a pathname pointer only --
*-- DESTROY writes nothing back, so DPARM stays EMITTED data
*-- (check_purity write shape D does not apply), rm.s's own
*-- precedent for the identical call.
DPARM       dfb   PCNT_DESTROY
DPARM_PATH  da    PATHBUF

*---------------------------------------------------------------
* RMDIRP -- rmdir -p for the operand whose MLI pathname is
* already in PATHBUF (MKPATH already ran). Removes the leaf via
* DPARM/SC_UNLINK, then each parent pathname component in turn,
* stopping at the first failure -- a non-empty parent, same as a
* plain rmdir on it -- or at the volume boundary, whichever
* comes first. OUT: carry CLEAR = every attempted component was
* removed; carry SET = the call that just failed is the one
* PATHBUF still names -- the caller's PRPATH prints exactly that
* pathname, not the original operand, so a chain failure names
* the real culprit.
*
* BOUNDARY RULE, reusing mkdir.s MKDIRP's own volume-prefix scan
* (same shape, read forward once, used here as a floor rather
* than a start point): an absolute path's leading "/VOLUME/" is
* never a strip target -- DESTROYing a volume directory is not
* what -p means, and ProDOS has no such call besides. RP_MIN is
* set to the length of that prefix; a relative path gets 0.
* Stripping stops -- SUCCESSFULLY -- once no '/' remains at or
* above RP_MIN, i.e. once only the volume (or nothing, for a
* relative operand) would be left to remove.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RMDIRP      lda   PATHBUF+1
            cmp   #'/'
            bne   :novol
            ldy   #1
:volscan    cpy   PATHBUF
            bcs   :volnone
            lda   PATHBUF+1,y
            cmp   #'/'
            beq   :volend
            iny
            bra   :volscan
:volnone    sty   RP_MIN                 ;bare "/VOLUME", no
            bra   :try                   ;further '/' -- nothing
                                         ;above this is a split
:volend     iny                          ;past that '/' too
            sty   RP_MIN
            bra   :try
:novol      stz   RP_MIN

:try        lda   #<DPARM
            ldx   #>DPARM
            jsr   SC_UNLINK
            bcs   :fail
            lda   PATHBUF
            cmp   RP_MIN
            beq   :done                  ;nothing left above the
            bcc   :done                  ;boundary to strip
            sec
            sbc   #1
            tay                          ;Y = last char index
                                         ;(0-based)
:scan       cpy   RP_MIN
            bcc   :done                  ;fell below the floor
            lda   PATHBUF+1,y
            cmp   #'/'
            beq   :cut
            tya
            beq   :done                  ;Y=0, no match -- stop
                                         ;rather than wrap
            dey
            bra   :scan
:cut        sty   PATHBUF                ;truncate: drop the '/'
                                         ;and the rest after it
            bra   :try
:done       clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* PRPATH -- print PATHBUF (an MLI pathname: a count byte then
* that many LOW-ASCII characters) to fd 2 as a NUL-terminated,
* HIGH-bit liba string -- the same two conversions pwd.s's own
* GET_PREFIX printer already does, for the identical reason:
* printing the low-ASCII bytes raw would paint the name in
* inverse video on the //e's screen.
* MUTATES PATHBUF in place. Every caller reaches this only to
* report a failure and move to the next operand -- MKPATH
* rebuilds PATHBUF from scratch before anything reads it again.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRPATH      ldy   PATHBUF
            beq   :term
:hibit      lda   PATHBUF,y
            ora   #$80
            sta   PATHBUF,y
            dey
            bne   :hibit
:term       ldy   PATHBUF
            lda   #0
            sta   PATHBUF+1,y
            lda   #<PATHBUF+1
            sta   PTR0
            lda   #>PATHBUF+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* rmdir's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*`.
* Anything emitted after `dend` would silently overlay it
* (learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - PFLAG: `stz` at START, before OPTINIT's own loop reads it.
*  - ARGIDX: `sta` at :haveargs (from OPTIND) before the first
*    :looparg read.
*  - ERRFLAG: `stz` at :haveargs, which is the only path that
*    survives -- the no-operand path exits before reaching it.
*  - RP_MIN: RMDIRP's own scratch, written fresh every call
*    (every path through the volume-prefix scan stores it)
*    before its one read in :try's success arm.
*  - PATHBUF: MKPATH writes chars then the count byte, and the
*    MLI reads only count+1. DPARM stays emitted above -- its
*    `da PATHBUF` still resolves to this arena's address.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ARGIDX      ds    1
ERRFLAG     ds    1
PFLAG       ds    1
RP_MIN      ds    1
PATHBUF     ds    65             ;1 count byte + up to 64 chars
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
