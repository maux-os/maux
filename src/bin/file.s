*---------------------------------------------------------------
* file.s -- describe each named file's ProDOS type.
*
* Usage: file name...
*
* CONTRACT: for each name argument, print
* "<name>: <description>" to fd 1. STATTED with GET_FILE_INFO
* ($C4, SC_GFI -- the same
* inc/mli.equ PCOUNT_GFI parameter-block shape ls.s's -l
* column already uses; see ls.s's GFIPARM comment for the
* precedent this file follows rather than re-derives).
*
* DIRECTORY CHECK runs first, on storage_type alone (the same
* rule ls.s's pass-1 dispatch uses): $0D (subdirectory) or $0F
* (volume directory) means "directory" -- file_type is not even
* consulted once storage_type says so. Everything else is a
* file_type table lookup:
*   $0F DIR -> directory      $04 TXT -> ascii text
*   $06 BIN -> binary         $FF SYS -> system program
*   $FC BAS -> applesoft program
*   $FA INT -> integer basic program
*   $FB VAR -> applesoft variables
*   $FE REL -> relocatable object
*   $EF PAS -> pascal area
*   $E2 ATK -> appletalk file
*   $B3 S16 -> gs/os application
* anything else -> "unknown type $XX" (two hex digits).
*
* A GFI failure prints "<name>: cannot stat" to stderr,
* continues with the remaining arguments, and forces exit 1.
* No arguments:
* usage to stderr, exit 2. Exit 0 only if every argument was
* described successfully.
*
* Uses ONLY liba (src/liba) -- no direct syscalls, no raw gate
* address, no raw call-number equates (SC_GFI wraps SYS_GFI --
* see src/liba/syscalls.s).
*---------------------------------------------------------------

            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/file.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*---------------------------------------------------------------
* START -- usage check, then describe each name argument in
* turn (argv[0] is the program name; names start at argv[1]).
*---------------------------------------------------------------
START       stz   ERRFLAG
            lda   ARGC
            cmp   #2
            bcs   :haveargs
            lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT
:haveargs   lda   #1
            sta   ARGIDX
:loop       lda   ARGIDX
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :ok
            jsr   PRINTFAIL
            lda   #1
            sta   ERRFLAG
            jmp   :next
:ok         lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #<SEPMSG
            sta   PTR0
            lda   #>SEPMSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            jsr   DESCRIBE
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:next       inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcc   :loop
            lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* PRINTFAIL -- "<ARGIDX's name>: cannot stat" to stderr, w/ CR.
*---------------------------------------------------------------
PRINTFAIL   lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<FAILMSG
            sta   PTR0
            lda   #>FAILMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

*---------------------------------------------------------------
* DESCRIBE -- IN GFIPARM_STYP/GFIPARM_FTYP (already populated by
* the caller's GFI call); prints the description word(s) to
* stdout, no trailing CR.
*---------------------------------------------------------------
DESCRIBE    lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #$0F              ;volume-dir storage_type --
            bne   :notdir           ;no house constant for this
                                    ;one (same as ls.s)
:isdir      lda   #<S_DIR
            sta   PTR0
            lda   #>S_DIR
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts
:notdir     lda   GFIPARM_FTYP
            jsr   PRINTDESC
            rts

* -- Entry count, defined HERE rather than after the table it
* -- counts: real Merlin-8 rejects a forward reference to an
* -- `equ` and merlin32 accepts one silently, so this unit
* -- assembled on the host and would not self-host. Keep it
* -- above its first use.
TYPETBL_N   equ   11

*---------------------------------------------------------------
* PRINTDESC -- IN A = file_type byte; table lookup, prints the
* matching description, or "unknown type $XX" if none matches.
*---------------------------------------------------------------
PRINTDESC   sta   DTYPE
            ldx   #0
            ldy   #0
:tloop      cpy   #TYPETBL_N
            beq   :unknown
            lda   TYPETBL,x
            cmp   DTYPE
            beq   :found
            inx
            inx
            inx
            iny
            bra   :tloop
:found      inx
            lda   TYPETBL,x
            sta   PTR0
            inx
            lda   TYPETBL,x
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts
:unknown    lda   #<S_UNK
            sta   PTR0
            lda   #>S_UNK
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   DTYPE
            jsr   HEXPRINT
            rts

*---------------------------------------------------------------
* HEXPRINT -- IN A = byte; prints "$xx", high-bit hex. The "$"
* is file-specific rendering; the digit pair is liba's PRHEX8
* (docs/FAT.md sec 3).
*---------------------------------------------------------------
HEXPRINT    pha
            lda   #$A4              ;'$' high-bit
            ldx   #FD_STDOUT
            jsr   PUTC
            pla
            ldx   #FD_STDOUT
            jsr   PRHEX8
            rts

*---------------------------------------------------------------
* Data
*---------------------------------------------------------------
* -- file_type -> description table. 3 bytes/entry: type byte,
* -- description string ptr (lo/hi). All FTYPE_*/STYP_DIR
* -- equates now come from mli.equ (docs/PLAN.md "The liba
* -- wave" added the ones missing at this table's first draft).
TYPETBL     dfb   FTYPE_DIR
            da    S_DIR
            dfb   FTYPE_TXT
            da    S_TXT
            dfb   FTYPE_BIN
            da    S_BIN
            dfb   FTYPE_SYS
            da    S_SYS
            dfb   FTYPE_BAS
            da    S_BAS
            dfb   FTYPE_INT
            da    S_INT
            dfb   FTYPE_VAR
            da    S_VAR
            dfb   FTYPE_REL
            da    S_REL
            dfb   FTYPE_PAS
            da    S_PAS
            dfb   FTYPE_ATK
            da    S_ATK
            dfb   FTYPE_S16
            da    S_S16

S_DIR       asc   "directory"
            dfb   0
S_TXT       asc   "ascii text"
            dfb   0
S_BIN       asc   "binary"
            dfb   0
S_SYS       asc   "system program"
            dfb   0
S_BAS       asc   "applesoft program"
            dfb   0
S_INT       asc   "integer basic program"
            dfb   0
S_VAR       asc   "applesoft variables"
            dfb   0
S_REL       asc   "relocatable object"
            dfb   0
S_PAS       asc   "pascal area"
            dfb   0
S_ATK       asc   "appletalk file"
            dfb   0
S_S16       asc   "gs/os application"
            dfb   0
S_UNK       asc   "unknown type "
            dfb   0

USAGEMSG    asc   "usage: file name..."
            dfb   $8D,0
FAILMSG     asc   ": cannot stat"
            dfb   $8D,0
SEPMSG      asc   ": "
            dfb   0

* -- GET_FILE_INFO ($C4), PCOUNT_GFI-shaped (inc/mli.equ):
* -- pathname, access, file_type, aux_type, storage_type,
* -- blocks_used, mod_date, mod_time, create_date, create_time.
GFIPARM     dfb   PCOUNT_GFI
GFIPARM_PATH da   PATHBUF
GFIPARM_ACC dfb   0
GFIPARM_FTYP dfb  0
GFIPARM_AUX da    0
GFIPARM_STYP dfb  0
GFIPARM_BLKS da   0
GFIPARM_MDATE da  0
GFIPARM_MTIME da  0
GFIPARM_CDATE da  0
GFIPARM_CTIME da  0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/hex.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* file's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*` (two
* blocks at `*` are the same bytes). Anything emitted after
* `dend` would silently overlay it
* (learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - ERRFLAG: `stz` as START's first instruction, before the
*    exit-status read.
*  - ARGIDX: `lda #1 / sta ARGIDX` before the first :loop read.
*  - DTYPE: `sta` as PRINTDESC's first instruction, before its
*    own compare reads it back.
*  - PATHBUF: MKPATH writes chars then the count byte, and the
*    MLI reads only count+1. GFIPARM stays emitted above; its
*    `da PATHBUF` still resolves to this arena's address.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ARGIDX      ds    1
ERRFLAG     ds    1
DTYPE       ds    1

PATHBUF     ds    65
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
