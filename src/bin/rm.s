*---------------------------------------------------------------
* rm.s -- remove files, and with -r, trees.
*
* Usage: rm [-irf] FILE...
*
* CONTRACT: `rm FILE...` unlinks each FILE argument, in order.
* No operands after the flags is a usage error (message to
* stderr, exit 2). A FILE that fails prints "rm: cannot unlink
* <name>" to stderr and rm continues with the remaining
* arguments. Exit 0 if every removal succeeded, 1 if any
* reported failure.
*
* FLEET F.2 additions (2026-09-01): -r removes a DIRECTORY
* operand recursively via src/liba/cptree.s's CPT_RMTREE -- the
* engine that already powers cp -r and cross-parent mv; rm -r
* was its missing third leg. A -r operand is GFI-statted first:
* storage_type $0D/$0F takes the tree teardown, anything else
* the plain DESTROY. WITHOUT -r a directory operand just meets
* DESTROY, which succeeds on an EMPTY directory (ProDOS's own
* semantics -- this is also maux's rmdir, docs/FLEET.md F.3)
* and refuses a non-empty one with $4E.
*
* -f forgives ABSENCE, nothing else (POSIX's useful half): a
* failure whose errno is $44/$45/$46 (path/volume/file not
* found, P8 TRM ch. 4) is silent and does not touch the exit
* status. Every OTHER failure still prints and still exits 1 --
* -f is not a blindfold, and a teardown that dies mid-tree must
* say so.
*
* -i prompts before each removal; only y or Y proceeds. A
* declined operand is not an error and processing continues.
*
* unlink() is the real MLI DESTROY ($C1): param_count=1, just a
* pathname pointer, so DPARM stays EMITTED data -- DESTROY
* writes nothing back (check_purity write shape D does not
* apply). GET_FILE_INFO does write results, so GFIPARM lives in
* the bss arena and INITPARMS stores its constants at entry,
* mv.s's own discipline.
*
* Uses ONLY liba (src/liba) -- no direct syscalls, no raw gate
* address, no equates; see docs/USERLAND.md and syscalls.s's
* header for why.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/rm.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/readdir.equ
            put   ../../inc/cptree.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- MLI not-found errnos, the class -f forgives (P8 TRM ch. 4:
* -- $44 path not found, $45 volume not found, $46 file not
* -- found). Spelled here like mv.s's ERR_DUPFN -- a consumer's
* -- own equates, not liba's.
ERR_PATHNF  equ   $44
ERR_FILENF  equ   $46

START       jsr   INITPARMS
            stz   WANT_R
            stz   WANT_F
            stz   WANT_I
            stz   ERRFLAG
            lda   #<RMOPTS
            ldx   #>RMOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F2                   ;'r' recursive
            bne   :not_r
            sta   WANT_R
            bra   :optlp
:not_r      cmp   #$E6                   ;'f' forgive absence
            bne   :not_f
            sta   WANT_F
            bra   :optlp
:not_f      cmp   #$E9                   ;'i' prompt
            bne   :usage
            sta   WANT_I
            bra   :optlp
:optdone    lda   ARGC
            cmp   OPTIND
            bne   :haveargs
:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

:haveargs   lda   OPTIND
            sta   ARGIDX
:looparg    lda   ARGIDX
            jsr   GETARG                 ;-> PTR0 = argv[ARGIDX]
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   WANT_I
            beq   :confirmed
            jsr   RMPROMPT
            bcc   :nextarg
:confirmed
            lda   WANT_R
            beq   :plain
*-- -r: stat first. A directory takes the tree teardown; a
*-- plain file falls through to DESTROY; an unstattable operand
*-- is the same not-found lane the plain path would hit.
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :failed
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :tree
            cmp   #$0F                   ;volume dir -- no house
            bne   :plain                 ;constant (ls.s's own
                                         ;precedent)
:tree       lda   #<CPT_SRC              ;UNPATH writes through
            sta   PTR1                   ;PTR1 -- the first cut
            lda   #>CPT_SRC              ;left PTR1 on PATHBUF
            sta   PTR1+1                 ;(MKPATH's target) and
            lda   #<PATHBUF              ;CPT_SRC stayed arena
            ldx   #>PATHBUF              ;garbage; RMTREE walked
            jsr   CPT_UNPATH             ;a garbage path
            sta   CPT_SLEN
            jsr   CPT_INIT
            jsr   CPT_RMTREE
            bcc   :nextarg
            lda   CPT_ERR                ;reason travels like an
            bra   :failed                ;errno; >= $80 reasons
                                         ;are never "not found"
:plain      lda   #<DPARM
            ldx   #>DPARM
            jsr   SC_UNLINK
            bcc   :nextarg

*-- A = errno. -f forgives only the not-found class.
:failed     ldx   WANT_F
            beq   :report
            cmp   #ERR_PATHNF
            bcc   :report
            cmp   #ERR_FILENF+1
            bcc   :nextarg               ;$44-$46 under -f:
                                         ;silence, status intact
:report     lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG                 ;re-fetch -- PUTS above
                                         ;clobbered PTR0
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG

:nextarg    lda   ARGIDX
            clc
            adc   #1
            sta   ARGIDX
            cmp   ARGC
            bcs   :done
            jmp   :looparg
:done       lda   ERRFLAG
            jsr   EXIT

RMPROMPT    lda   #<PROMPTMSG
            sta   PTR0
            lda   #>PROMPTMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            ldx   #FD_STDIN
            jsr   GETC
            bcc   :got
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            bra   :no
:got        pha
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            pla
            and   #$DF
            cmp   #$D9
            beq   :yes
:no         clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* INITPARMS -- store GFIPARM's constants (the kernel writes its
* result fields back, so it cannot be emitted data -- mv.s's
* INITPARMS states the full argument).
*---------------------------------------------------------------
INITPARMS   lda   #PCOUNT_GFI
            sta   GFIPARM
            lda   #<PATHBUF
            sta   GFIPARM_PATH
            lda   #>PATHBUF
            sta   GFIPARM_PATH+1
            rts

USAGEMSG    asc   "usage: rm [-irf] FILE..."
            dfb   $00
ERRMSG      asc   "rm: cannot unlink "
            dfb   $00
PROMPTMSG   asc   "rm: remove? "
            dfb   0
RMOPTS      asc   "rfi"
            dfb   0
DPARM       dfb   PCNT_DESTROY
DPARM_PATH  da    PATHBUF

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/readdir.s
            put   ../liba/readsyn.s
            put   ../liba/readsys.s
            put   ../liba/cptree.s
            put   ../liba/cptree2.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s
            put   ../liba/cptreebss.s

*---------------------------------------------------------------
* rm's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at CPT_BSSEND -- NOT LIBA_BSSEND:
* cptreebss.s above chains LIBA_BSSEND -> CPT_BSSEND, so a
* LIBA_BSSEND anchor here ALIASES every CPT cell (the first cut
* did exactly that: CPT_RMTREE's walk scribbled PATHBUF/GFIPARM
* aliases mid-teardown and the e2e-fs run hung its whole cycle
* budget). mv.s's own arena is the precedent.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - WANT_R/WANT_F/WANT_I/ERRFLAG: `stz` in START.
*  - ARGIDX: `sta` from OPTIND before the first :looparg read.
*  - PATHBUF: MKPATH writes chars then the count byte, and the
*    MLI reads only count+1. DPARM stays emitted above; its
*    `da PATHBUF` still resolves to this arena's address.
*  - GFIPARM: constants stored by INITPARMS, result fields by
*    the kernel's copyback, before any read.
*  - CPT_* cells: CPT_INIT stores them (cptreebss.s's own
*    header), called before the one CPT_RMTREE.
*---------------------------------------------------------------
            dum   CPT_BSSEND
ARGIDX      ds    1
ERRFLAG     ds    1
WANT_R      ds    1              ;-r recursive
WANT_F      ds    1              ;-f forgive absence
WANT_I      ds    1              ;-i prompt before removal
PATHBUF     ds    65             ;1 count byte + up to 64 chars
                                 ;(MLI shape)

* -- GET_FILE_INFO ($C4), PCOUNT_GFI-shaped (inc/mli.equ).
* -- CONTIGUITY IS LOAD-BEARING: the MLI reads these as one
* -- block.
GFIPARM     ds    1
GFIPARM_PATH ds   2
GFIPARM_ACC ds    1
GFIPARM_FTYP ds   1
GFIPARM_AUX ds    2
GFIPARM_STYP ds   1
GFIPARM_BLKS ds   2
GFIPARM_MDATE ds  2
GFIPARM_MTIME ds  2
GFIPARM_CDATE ds  2
GFIPARM_CTIME ds  2
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
