*---------------------------------------------------------------
* mkdir.s -- create directories.
*
* Usage: mkdir [-p] DIR...
*
* CONTRACT: for each DIR argument, in order, create a ProDOS
* subdirectory. A directory is just an MLI CREATE with
* storage_type $0D and file_type $0F (mli.equ), and userland
* already controls both fields -- sh sets them for `>`
* redirection -- so this needs NO kernel support at all. That is
* the whole utility, and -p below reuses exactly this CREATE.
*
* A DIR that cannot be created prints "mkdir: cannot create
* <name>" to stderr and is SKIPPED; mkdir continues with the
* remaining arguments, the same shape cat.s uses for a file it
* cannot open. Exit status: 0 if every directory was created
* (or, under -p, already existed as a directory), 1 if any
* failed. With no operands it is a usage error (2).
*
* -p (POSIX): make missing intermediate directories, and accept
* an existing DIRECTORY leaf as success rather than failure.
* MKDIRP below does the walk; see its own header for the split
* rule. The MLI error it keys on -- $47, "duplicate filename" --
* is confirmed from the ProDOS 8 TRM's own "Possible Errors"
* table (street-library artifact d82965d8...), the same constant
* cp.s/mv.s already carry as ERR_DUPFN.
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
            dsk   ../../build/mkdir.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- ProDOS MLI error $47, "duplicate filename" (P8 TRM ch. 4's
* -- CREATE error table -- no house constant for MLI errno
* -- values exists yet, same precedent cp.s/mv.s already note).
* -- -p treats this as "already there" on an intermediate
* -- component, and on the leaf only when GET_FILE_INFO says the
* -- existing entry is itself a directory (MP_ISDIR below).
ERR_DUPFN   equ   $47

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
            jsr   MKDIRP
            bra   :chkcr
:plain      lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT
:chkcr      bcc   :nextarg

            lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG                 ;re-fetch: PUTS ate
                                         ;PTR0
            ldx   #FD_STDERR
            jsr   PUTS
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

USAGE       asc   "usage: mkdir [-p] DIR..."
            dfb   $8D,$00
ERRMSG      asc   "mkdir: cannot create "
            dfb   $00

*-- The only thing separating this from creating an ordinary
*-- file is the two type bytes below.
CRPARM      dfb   PCOUNT_CREATE
CRPARM_PATH da    PATHBUF
CRPARM_ACC  dfb   ACCESS_UNLKD
CRPARM_FTYP dfb   FTYPE_DIR
CRPARM_AUX  da    0
CRPARM_STYP dfb   STYP_DIR
CRPARM_DATE da    0
CRPARM_TIME da    0

* -- GET_FILE_INFO ($C4), PCOUNT_GFI-shaped (inc/mli.equ),
* -- same field order as du.s/ls.s's own GFIPARM. PATH is static
* -- -- MP_ISDIR is only ever called right after a CREATE on the
* -- very pathname already sitting in PATHBUF.
GFIPARM     dfb   PCOUNT_GFI
GFIPARM_PATH da   PATHBUF
GFIPARM_ACC dfb  0
GFIPARM_FTYP dfb 0
GFIPARM_AUX da   0
GFIPARM_STYP dfb 0
GFIPARM_BLKS da  0
GFIPARM_MDATE da 0
GFIPARM_MTIME da 0
GFIPARM_CDATE da 0
GFIPARM_CTIME da 0

*---------------------------------------------------------------
* MKDIRP -- mkdir -p for the operand whose MLI pathname is
* already in PATHBUF (MKPATH already ran). Creates every missing
* intermediate directory, then the leaf. OUT: carry CLEAR = the
* operand is fully satisfied (created, or the leaf already
* exists as a directory); carry SET = failure -- START's caller
* prints the usual "cannot create" diagnostic, same as a plain
* CREATE failure.
*
* WALK RULE: scan PATHBUF's characters left to right (PATHBUF+1
* is the first character, PATHBUF+0 the count byte -- mli.equ's
* pathname-buffer shape). An ABSOLUTE path's leading "/VOLUME"
* cannot be CREATEd -- it is not a plain duplicate-pathname case
* -- so the leading '/' and the '/' ending the volume name are
* both skipped (under "/mnt/" the volume is the second
* component and that '/' is skipped too: docs/VROOT.md); every
* '/' found after that is a split point. A
* RELATIVE path has no such component to skip -- every '/' is a
* split point, starting at the first one.
*
* At each split point the count byte is temporarily set to the
* prefix length (the characters before that '/') and CREATEd
* with the directory storage type (CRPARM, unchanged from the
* plain path above); ERR_DUPFN there means the component is
* already there and is not a failure -- the real count byte is
* restored either way before this loop continues or returns.
*
* The leaf (the full, unmodified pathname) is CREATEd last.
* ERR_DUPFN on the leaf is only acceptable when the existing
* entry is already a directory (MP_ISDIR) -- an existing plain
* file is a failure.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MKDIRP      lda   PATHBUF
            sta   MP_CNT
            stz   MP_WALKY
            lda   PATHBUF+1
            cmp   #'/'
            bne   :walk
            ldy   #1
:volscan    cpy   MP_CNT
            bcs   :volnone
            lda   PATHBUF+1,y
            cmp   #'/'
            beq   :volend
            iny
            bra   :volscan
:volnone    sty   MP_WALKY               ;bare "/VOLUME" -- Y is
                                         ;now MP_CNT, so :wloop
                                         ;falls right to :leaf
            bra   :walk
:volend     iny                          ;past that '/' too
            sty   MP_WALKY
            cpy   #5                     ;"/mnt/": volume is
            bne   :walk                  ;the NEXT component,
            lda   PATHBUF+2              ;not CREATEable either
            ora   #$20
            cmp   #'m'
            bne   :walk
            lda   PATHBUF+3
            ora   #$20
            cmp   #'n'
            bne   :walk
            lda   PATHBUF+4
            ora   #$20
            cmp   #'t'
            bne   :walk
:vol2       cpy   MP_CNT
            bcs   :volnone               ;bare "/mnt/VOL"
            lda   PATHBUF+1,y
            cmp   #'/'
            beq   :vol2end
            iny
            bra   :vol2
:vol2end    iny
            sty   MP_WALKY

:walk       ldy   MP_WALKY
:wloop      cpy   MP_CNT
            bcs   :leaf                  ;scanned the whole path
            lda   PATHBUF+1,y
            cmp   #'/'
            bne   :wnext
            sty   MP_SAVEY
            tya
            sta   PATHBUF                ;temporary count = the
                                         ;chars before this '/'
            lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT
            bcc   :wpass
            cmp   #ERR_DUPFN
            beq   :wpass
            pha                          ;caller doesn't need
                                         ;the errno, but restore
                                         ;PATHBUF before leaving
            lda   MP_CNT
            sta   PATHBUF
            pla
            sec
            rts
:wpass      lda   MP_CNT
            sta   PATHBUF                ;restore for the next
                                         ;split point / the leaf
            ldy   MP_SAVEY
:wnext      iny
            bra   :wloop

:leaf       lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT
            bcc   :ok
            cmp   #ERR_DUPFN
            bne   :fail
            jsr   MP_ISDIR
            bcc   :ok
:fail       sec
            rts
:ok         clc
            rts

*---------------------------------------------------------------
* MP_ISDIR -- GET_FILE_INFO on the pathname now sitting in
* PATHBUF (full, real count already restored) and report whether
* the existing entry is a directory. OUT: carry CLEAR = yes
* (storage_type STYP_DIR $0D, or the volume-dir type $0F -- the
* same two values ls.s/du.s/cp.s already test, no house
* constant for the second); carry SET = no -- a plain file, or
* GET_FILE_INFO itself failed -- either way the leaf's
* ERR_DUPFN is a real failure, not "already there".
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MP_ISDIR    lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :no
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :yes
            cmp   #$0F
            beq   :yes
:no         sec
            rts
:yes        clc
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
* mkdir's bss -- `dum`/`dend` at the TEXTUAL END, past every
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
*  - PATHBUF: MKPATH writes chars then the count byte, and the
*    MLI reads only count+1. CRPARM stays emitted above -- it
*    carries FIVE nonzero constants, so moving it would cost
*    five runtime stores to save eight bytes.
*  - MP_CNT/MP_WALKY/MP_SAVEY: MKDIRP's own scratch, written
*    fresh every call before any read -- see that routine.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ARGIDX      ds    1
ERRFLAG     ds    1
PFLAG       ds    1
MP_CNT      ds    1
MP_WALKY    ds    1
MP_SAVEY    ds    1
PATHBUF     ds    65             ;1 count byte + up to 64 chars
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
