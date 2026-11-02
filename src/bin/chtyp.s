*---------------------------------------------------------------
* chtyp.s -- change a ProDOS file's file_type and aux_type.
*
* Usage: chtyp [-t type] [-a aux] file...
*
* WHY THIS EXISTS, and it is not a convenience. On ProDOS the
* TYPE is where "can this be run?" lives -- inc/mli.equ says so
* at FTYPE_TXT, citing this very tool's ancestor: the GNO/ME
* precedent is no `chmod +x`, use `chtyp`
* (learning:01M0798FFCHB60SWQDE8NQEQXN). And maux leans on the
* AUX harder than ProDOS ever did: spawn() loads a binary AT ITS
* aux_type (src/kernel/procspawn3.s, S9 L3b). So without this
* tool a person could build something on the machine and have no
* way to stamp it -- `chmod` speaks the access byte and nothing
* speaks the other two.
*
* CLONED FROM GNO/ME's chtyp(1), mechanism not spelling. Its
* synopsis is `chtyp { [-t filetype] [-a auxtype] } | { -l lang
* } file...` and the three type FORMS below are its: a decimal
* number, a `$`-prefixed hex number, or an Apple mnemonic.
*
* WHAT IS DELIBERATELY NOT CLONED: `-l lang`. GNO's takes CC,
* ASM65816, IBASIC, LINK, APWC, PASCAL, REZ, EXEC, TMLPASCAL --
* ORCA/APW language stamps, which are aux_type conventions of a
* 65816 toolchain that does not exist here. maux's own languages
* are named by their types already.
*
* THE MNEMONICS ARE inc/mli.equ's OWN FTYPE_* NAMES, not a table
* retyped from the ProDOS file-type registry. That is the point:
* `chtyp -t REL` and the kernel's FTYPE_REL cannot drift apart,
* because they are the same twelve rows. maux writes MERLIN REL
* objects as $F8 and not $FE -- mli.equ is emphatic about it --
* so RELM is the one a person here actually wants, and both are
* offered rather than guessing.
*
* READ-MODIFY-WRITE, and the reason is chmod.s's verbatim:
* SET_FILE_INFO ($C3) writes access, file_type, aux_type,
* mod_date and mod_time from a FULL parameter block, so a caller
* that sends zeros for the fields it does not mean to change
* DESTROYS them. This GET_FILE_INFOs first, changes only the
* field(s) named on the command line, and writes the rest back
* unchanged. `chmod` does the same dance from the other side --
* it preserves the type while changing access, this preserves
* access while changing the type.
*
* `$` NEEDS QUOTING, exactly as GNO's own BUGS section warns for
* its shell, and for the same reason: `$` opens an expansion.
* Write `chtyp -t '$F8' FOO` or `chtyp -t \$F8 FOO`. An unquoted
* `$F8` reaches this program as whatever the shell made of it,
* which is usually empty -- so it is a usage error here and not
* a silent type change.
*
* A path that fails GET_FILE_INFO prints "chtyp: <path>: cannot
* access"; one that fails SET_FILE_INFO prints "chtyp: <path>:
* cannot change type". Either way ERRFLAG is set, chtyp
* continues with the remaining arguments, and exits 1. Neither
* option given, a bad number, or no file operand is a usage
* error to stderr, exit 2.
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
            dsk   ../../build/chtyp.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*-- THE PARMLISTS LIVE IN THE ARENA, NOT IN TEXT, and that is a
*-- correctness choice rather than a tidiness one. Emitted as
*-- `dfb`/`da` they are bytes of this program's IMAGE that the
*-- program and the MLI both write into -- check-textaudit
*-- measured 22 of 2,437 image bytes mutated over two runs.
*-- The kernel RETAINS a bank whose entry head is intact, so
*-- the next chtyp to warm-respawn there would start on mutated
*-- text. That is not theoretical: this tool's own gate passed a
*-- deleted aux write-back until it poisoned the parmlist first,
*-- because the previous run's value was still sitting in it.
*-- In the `dum` arena the fields are per-run state, which is
*-- what they are. more.s's INITPARMS is the precedent.
START       lda   #PCOUNT_GFI
            sta   GFIPARM
            lda   #PCOUNT_SFI
            sta   SFIPARM
            stz   ERRFLAG
            stz   HAVETYP
            stz   HAVEAUX
            lda   #<CTOPTS
            ldx   #>CTOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F4                ;'t' high-bit
            bne   :not_t
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSETYPE
            bcs   :usage
            lda   PVAL
            sta   NEWTYP
            lda   #1
            sta   HAVETYP
            bra   :optlp
:not_t      cmp   #$E1                ;'a' high-bit
            bne   :usage
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSENUM            ;16-bit, no mnemonics
            bcs   :usage
            lda   PVAL
            sta   NEWAUX
            lda   PVAL+1
            sta   NEWAUX+1
            lda   #1
            sta   HAVEAUX
            bra   :optlp
*-- NEITHER option is a usage error, not a no-op that silently
*-- rewrites every named file with its own current values.
:optdone    lda   HAVETYP
            ora   HAVEAUX
            beq   :usage
            lda   ARGC
            sec
            sbc   OPTIND
            bne   :startfl            ;at least one file
:usage      jmp   USAGE_ERR

*---------------------------------------------------------------
* Per-file loop -- chmod.s's, field for field.
*---------------------------------------------------------------
:startfl    lda   OPTIND
            sta   ARGIDX
:aloop      lda   ARGIDX
            cmp   ARGC
            bcc   :onemore
            jmp   :adone               ;the per-file body is
:onemore    jsr   GETARG               ;longer than a branch
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<PATHBUF
            sta   GFIPARM_PATH
            lda   #>PATHBUF
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :gfiok
            jsr   PRINTACCFAIL
            jmp   :anext
:gfiok      lda   #<PATHBUF
            sta   SFIPARM_PATH
            lda   #>PATHBUF
            sta   SFIPARM_PATH+1
*-- Everything not named on the command line is written back
*-- VERBATIM from the GET_FILE_INFO above.
            lda   GFIPARM_ACC
            sta   SFIPARM_ACC
            lda   GFIPARM_FTYP
            sta   SFIPARM_FTYP
            lda   GFIPARM_AUX
            sta   SFIPARM_AUX
            lda   GFIPARM_AUX+1
            sta   SFIPARM_AUX+1
            stz   SFIPARM_NULL
            stz   SFIPARM_NULL+1
            stz   SFIPARM_NULL+2
            lda   GFIPARM_MDATE
            sta   SFIPARM_MDATE
            lda   GFIPARM_MDATE+1
            sta   SFIPARM_MDATE+1
            lda   GFIPARM_MTIME
            sta   SFIPARM_MTIME
            lda   GFIPARM_MTIME+1
            sta   SFIPARM_MTIME+1
*-- ... and only then the field(s) the user asked for.
            lda   HAVETYP
            beq   :noftyp
            lda   NEWTYP
            sta   SFIPARM_FTYP
:noftyp     lda   HAVEAUX
            beq   :noaux
            lda   NEWAUX
            sta   SFIPARM_AUX
            lda   NEWAUX+1
            sta   SFIPARM_AUX+1
:noaux      lda   #<SFIPARM
            ldx   #>SFIPARM
            jsr   SC_SFI
            bcc   :anext
            jsr   PRINTCHFAIL
:anext      inc   ARGIDX
            jmp   :aloop
:adone      lda   ERRFLAG
            jmp   EXIT

USAGE_ERR   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jmp   EXIT

PRINTACCFAIL lda  #<ERRSUF_ACC
            sta   SUFPTR
            lda   #>ERRSUF_ACC
            sta   SUFPTR+1
            bra   PRINTFAIL
PRINTCHFAIL lda   #<ERRSUF_CH
            sta   SUFPTR
            lda   #>ERRSUF_CH
            sta   SUFPTR+1
PRINTFAIL   lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG              ;re-fetch: PUTS clobbers
            ldx   #FD_STDERR          ;PTR0
            jsr   PUTS
            lda   SUFPTR
            sta   PTR0
            lda   SUFPTR+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG
            rts

CTOPTS      asc   "t:a:"
            dfb   0

*-- The mnemonic table: every FTYPE_* inc/mli.equ names, as
*-- [NUL-terminated name][value]. One source, so `chtyp -t REL`
*-- and the kernel's FTYPE_REL cannot drift.
MNEMTAB
            asc   "TXT"
            dfb   0,FTYPE_TXT
            asc   "BIN"
            dfb   0,FTYPE_BIN
            asc   "DIR"
            dfb   0,FTYPE_DIR
            asc   "SYS"
            dfb   0,FTYPE_SYS
            asc   "BAS"
            dfb   0,FTYPE_BAS
            asc   "INT"
            dfb   0,FTYPE_INT
            asc   "VAR"
            dfb   0,FTYPE_VAR
            asc   "REL"
            dfb   0,FTYPE_REL
            asc   "RELM"
            dfb   0,FTYPE_RELM
            asc   "PAS"
            dfb   0,FTYPE_PAS
            asc   "ATK"
            dfb   0,FTYPE_ATK
            asc   "S16"
            dfb   0,FTYPE_S16
            dfb   0

USAGEMSG    asc   "usage: chtyp [-t type] [-a aux] file..."
            dfb   $8D,0
ERRPFX      asc   "chtyp: "
            dfb   0
ERRSUF_ACC  asc   ": cannot access"
            dfb   0
ERRSUF_CH   asc   ": cannot change type"
            dfb   0

            put   chtypnum.s
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
* chtyp's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND, chmod.s's own trailer. NOTHING ZEROES THIS ARENA
* (docs/STICKY.md sec 21): ERRFLAG, HAVETYP and HAVEAUX are all
* `stz`'d by START's first three instructions, because each is
* read by a `beq`/`bne` that decides whether a field gets
* written at all -- a stale one would change a type nobody asked
* to change. ARGIDX is stored before its first use, PVAL/NEWTYP/
* NEWAUX are written by the parsers before any reader.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ERRFLAG     ds    1
ARGIDX      ds    1
HAVETYP     ds    1              ;-t was given
HAVEAUX     ds    1              ;-a was given
NEWTYP      ds    1              ;.. its value
NEWAUX      ds    2              ;.. and -a's
PVAL        ds    2              ;parser result
MNIDX       ds    1              ;MATCHMNEM cursor
MNTMP       ds    1              ;.. one table byte
MTMP        ds    2              ;MUL10 scratch
DTMP        ds    1              ;one decimal digit, held
                                 ;ACROSS the MUL10 call
SUFPTR      ds    2              ;PRINTFAIL's chosen suffix
PATHBUF     ds    65
*-- GET_FILE_INFO and SET_FILE_INFO parameter blocks.
*-- The count byte of each is stored by START; every other field
*-- is written per file, by this program or by the MLI itself.
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
SFIPARM     ds    1
SFIPARM_PATH ds   2
SFIPARM_ACC ds    1
SFIPARM_FTYP ds   1
SFIPARM_AUX ds    2
SFIPARM_NULL ds   3
SFIPARM_MDATE ds  2
SFIPARM_MTIME ds  2
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end.
            err   */$BF00
            dend
