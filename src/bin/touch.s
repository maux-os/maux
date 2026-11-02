*---------------------------------------------------------------
* touch.s -- stamp a file's modification time; create it empty
* if it does not exist. FLEET F.3 (2026-09-01): make landed, and
* touch is its natural companion.
*
* Usage: touch FILE...
*
* PER OPERAND: GET_FILE_INFO. An EXISTING file takes chmod.s's
* read-modify-write shape verbatim -- copy every GFI field back
* into SET_FILE_INFO's block, changing ONLY mod_date/mod_time,
* which come from SC_CLOCK's raw ProDOS Global Page words (the
* same source date.s prints; the words are already in the MLI's
* own encoding, so no conversion happens anywhere). A MISSING
* file ($44/$45/$46) is CREATEd empty, TXT type -- what a shell
* redirect makes -- with its create AND mod stamps from the same
* clock words. Any other failure prints "touch: <name>: cannot
* touch", sets exit 1, and the loop continues.
*
* NO CLOCK IS NOT AN ERROR: with no clock card the Global Page
* words are zero and the stamp is the "no date" ProDOS value --
* ls shows "-". That is the machine telling the truth, not touch
* failing; date.s's header owns the clock-detection story. If
* SC_CLOCK itself fails (kernel copy trouble), the operand is
* reported -- a GARBAGE stamp is worse than an honest error
* (date.s's own carry lesson, learned the hard way).
*
* -t STAMP / -r REF_FILE (SHIPPED 2026-09-17): PARSESTAMP parses
* [[CC]YY]MMDDhhmm[.SS] (a bare century, if given, is CONSUMED
* and IGNORED -- ProDOS's own packed date word stores only a
* 7-bit two-digit year, no century at all, the same field date.s
* decodes with its own pivot-78 rule on the way OUT; there is
* nothing to pivot on the way IN, since storing "20" already
* means the same 7 bits whether it came from "1920" or "2020").
* Seconds, if given after a literal '.', are PARSED (a non-digit
* there is still a usage error) and then DISCARDED -- ProDOS
* dates have MINUTE resolution, no seconds field to hold them.
* This is a documented truncation, not a silent one. -r reads
* the reference file's OWN mod_date/mod_time via GET_FILE_INFO
* and uses those verbatim, PATHBUF-reused (see GETREFSTAMP).
* Both funnel into the SAME TS_DATE/TS_TIME cells the live clock
* used to occupy outright (CLKBUF is gone -- SC_CLOCK now reads
* directly into TS_DATE/TS_TIME when neither flag is given, same
* 4-byte layout, same failure-zeros fallback). -c (no-create) is
* still not implemented; not needed by any script here.
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
            dsk   ../../build/touch.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- the not-found errno class (P8 TRM ch. 4), rm.s's spelling.
ERR_PATHNF  equ   $44
ERR_FILENF  equ   $46

START       stz   ERRFLAG
            stz   HAVESTAMP
            lda   #<TOPTS
            ldx   #>TOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F4                   ;'t' high-bit
            bne   :not_t
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSESTAMP
            bcs   :usage
            lda   #1
            sta   HAVESTAMP
            bra   :optlp
:not_t      cmp   #$F2                   ;'r' high-bit
            bne   :usage
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   GETREFSTAMP
            bcs   :usage
            lda   #1
            sta   HAVESTAMP
            bra   :optlp
:optdone
            lda   ARGC
            sec
            sbc   OPTIND
            bne   :haveargs
:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*-- the clock, read ONCE for the whole run (every operand gets
*-- the same instant, which is also what host touch does within
*-- its argument loop's resolution) -- UNLESS -t/-r already set
*-- TS_DATE/TS_TIME, in which case the live clock is irrelevant.
:haveargs   lda   HAVESTAMP
            bne   :clockok
            lda   #<TS_DATE
            sta   PTR0
            lda   #>TS_DATE
            sta   PTR0+1
            jsr   SC_CLOCK
            bcc   :clockok
            stz   TS_DATE                ;failed copy: stamp the
            stz   TS_DATE+1              ;honest "no date" zeros
            stz   TS_TIME                ;rather than bank
            stz   TS_TIME+1              ;garbage (date.s's own
                                         ;carry lesson)
:clockok    lda   OPTIND
            sta   ARGIDX
:aloop      lda   ARGIDX
            cmp   ARGC
            bcc   :body
            jmp   :adone                 ;outgrew a bcs
:body       jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :missing

*-- A device (storage $0A CHR, $0B BLK) has no stamp to keep:
*-- /dev is read-only and touching one is a quiet success, as
*-- on Unix (docs/EXEC-SHEBANG.md Part 3).
            lda   GFIPARM_STYP
            cmp   #$0A
            beq   :isdev
            cmp   #$0B
            bne   :stamp
:isdev      jmp   :anext
:stamp
*-- EXISTS: chmod.s's read-modify-write, mod stamps swapped.
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
            lda   TS_DATE                ;date lo
            sta   SFIPARM_MDATE
            lda   TS_DATE+1              ;date hi
            sta   SFIPARM_MDATE+1
            lda   TS_TIME                ;time lo
            sta   SFIPARM_MTIME
            lda   TS_TIME+1              ;time hi
            sta   SFIPARM_MTIME+1
            lda   #<SFIPARM
            ldx   #>SFIPARM
            jsr   SC_SFI
            bcs   :report
            bra   :anext

*-- MISSING: create it empty, stamped now. Any OTHER GFI errno
*-- is a real failure.
:missing    cmp   #ERR_PATHNF
            bcc   :report
            cmp   #ERR_FILENF+1
            bcs   :report
            lda   TS_DATE
            sta   CRPARM_CDATE
            lda   TS_DATE+1
            sta   CRPARM_CDATE+1
            lda   TS_TIME
            sta   CRPARM_CTIME
            lda   TS_TIME+1
            sta   CRPARM_CTIME+1
            lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT
            bcc   :anext

:report     lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG                 ;PUTS clobbered PTR0
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<ERRSUF
            sta   PTR0
            lda   #>ERRSUF
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            sta   ERRFLAG

:anext      inc   ARGIDX
            jmp   :aloop
:adone      lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* GETREFSTAMP -- IN: PTR0 = a -r operand (path text). OUT: carry
* CLEAR and TS_DATE/TS_TIME = that file's own mod_date/mod_time,
* on success; carry SET if it cannot be stat'd. PATHBUF is
* reused as scratch (GFIPARM_PATH already points at it, and the
* real per-FILE loop overwrites it again before ever reading it
* itself, so there is no lifetime conflict).
*---------------------------------------------------------------
GETREFSTAMP lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :bad
            lda   GFIPARM_MDATE
            sta   TS_DATE
            lda   GFIPARM_MDATE+1
            sta   TS_DATE+1
            lda   GFIPARM_MTIME
            sta   TS_TIME
            lda   GFIPARM_MTIME+1
            sta   TS_TIME+1
            clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* PARSESTAMP -- IN: PTR0 = a -t operand, [[CC]YY]MMDDhhmm[.SS].
* OUT: carry CLEAR and TS_DATE/TS_TIME packed (ProDOS's own
* layout -- date.s's decode, inverted); carry SET on any length,
* digit, or range error. See file header for the century/seconds
* handling. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PARSESTAMP  ldy   #0
:tslen      lda   (PTR0),y
            beq   :havelen
            and   #$7F
            cmp   #'.'
            beq   :havelen
            iny
            bra   :tslen
:havelen    cpy   #12
            beq   :is12
            cpy   #10
            beq   :is10
            sec
            rts
:is12       ldy   #0
            jsr   TS_RD2            ;century -- consumed, unused
            bcs   :failjmp
            jsr   TS_RD2            ;year-in-century == TS_YR
            bcs   :failjmp
            sta   TS_YR
            bra   :common
:is10       ldy   #0
            jsr   TS_RD2
            bcs   :failjmp
            sta   TS_YR
:common     jsr   TS_RD2
            bcs   :failjmp
            sta   TS_MON
            jsr   TS_RD2
            bcs   :failjmp
            sta   TS_DAY
            jsr   TS_RD2
            bcs   :failjmp
            sta   TS_HOUR
            jsr   TS_RD2
            bcs   :failjmp
            sta   TS_MIN
            bra   :seccheck
:failjmp    jmp   :bad
:seccheck   lda   (PTR0),y
            beq   :range
            and   #$7F
            cmp   #'.'
            bne   :failjmp2
            iny
            jsr   TS_RD2            ;seconds: parsed, discarded
            bcs   :failjmp2
            lda   (PTR0),y
            beq   :range
:failjmp2   jmp   :bad
:range      lda   TS_MON
            beq   :failjmp2
            cmp   #13
            bcs   :failjmp2
            lda   TS_DAY
            beq   :failjmp2
            cmp   #32
            bcs   :failjmp2
            lda   TS_HOUR
            cmp   #24
            bcs   :failjmp2
            lda   TS_MIN
            cmp   #60
            bcs   :failjmp2
            lda   TS_DAY
            and   #$1F
            sta   TS_TMP
            lda   TS_MON
            and   #$07
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            ora   TS_TMP
            sta   TS_DATE
            lda   TS_MON
            lsr   a
            lsr   a
            lsr   a
            and   #$01
            sta   TS_TMP
            lda   TS_YR
            and   #$7F
            asl   a
            ora   TS_TMP
            sta   TS_DATE+1
            lda   TS_MIN
            sta   TS_TIME
            lda   TS_HOUR
            sta   TS_TIME+1
            clc
            rts
:bad        sec
            rts
*---------------------------------------------------------------
* TS_RD2 -- IN: Y = offset into (PTR0). OUT: carry CLEAR, A =
* the
* 2-digit value at that offset (0-99), Y advanced by 2; carry
* SET if either byte is not a digit. CLOBBERS: A, Y.
*---------------------------------------------------------------
TS_RD2      lda   (PTR0),y
            and   #$7F
            cmp   #'0'
            bcc   :bad
            cmp   #'9'+1
            bcs   :bad
            sec
            sbc   #'0'
            sta   TS_TMP2
            iny
            lda   (PTR0),y
            and   #$7F
            cmp   #'0'
            bcc   :bad
            cmp   #'9'+1
            bcs   :bad
            sec
            sbc   #'0'
            sta   TS_TMP3
            iny
            lda   TS_TMP2
            asl   a
            sta   TS_TMP
            asl   a
            asl   a
            clc
            adc   TS_TMP           ;*8 + *2 = *10
            clc
            adc   TS_TMP3
            clc
            rts
:bad        sec
            rts

USAGEMSG    asc   "usage: touch [-t stamp | -r ref] FILE..."
            dfb   $8D,0
ERRPFX      asc   "touch: "
            dfb   0
ERRSUF      asc   ": cannot touch"
            dfb   $8D,0
TOPTS       asc   "t:r:"
            dfb   0

* -- GET_FILE_INFO ($C4), PCOUNT_GFI-shaped (mli.equ) --
* -- chmod.s's emitted-parmlist precedent (touch, like chmod, is
* -- not on the TEXT_IMMUTABLE roster).
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

* -- SET_FILE_INFO ($C3), PCOUNT_SFI-shaped -- chmod.s's block.
SFIPARM     dfb   PCOUNT_SFI
SFIPARM_PATH da   PATHBUF
SFIPARM_ACC dfb   0
SFIPARM_FTYP dfb  0
SFIPARM_AUX da    0
SFIPARM_NULL dfb  0,0,0
SFIPARM_MDATE da  0
SFIPARM_MTIME da  0

* -- CREATE ($C0), PCOUNT_CREATE-shaped -- cp.s's CRPARM, TXT
* -- (what a shell redirect makes) instead of SRC's type.
CRPARM      dfb   PCOUNT_CREATE
CRPARM_PATH da    PATHBUF
CRPARM_ACC  dfb   ACCESS_UNLKD
CRPARM_TYPE dfb   FTYPE_TXT
CRPARM_AUX  da    0
CRPARM_STORE dfb  STYP_SEEDLING
CRPARM_CDATE da   0              ;stamped from TS_DATE per run
CRPARM_CTIME da   0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* touch's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND (libabss.s already opened its own block at `*`).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - ERRFLAG/HAVESTAMP: `stz` as START's first two acts.
*  - ARGIDX: `lda OPTIND / sta` before the first :aloop read.
*  - TS_DATE/TS_TIME: written by SC_CLOCK, or stz'd whole on its
*    carry (the fabricated-date hazard date.s documents), UNLESS
*    HAVESTAMP -- then PARSESTAMP or GETREFSTAMP already wrote
*    all 4 bytes during option parsing, strictly before
*    :haveargs
*    ever reads HAVESTAMP to decide whether to call SC_CLOCK at
*    all.
*  - TS_YR/TS_MON/TS_DAY/TS_HOUR/TS_MIN/TS_TMP/TS_TMP2/TS_TMP3:
*    PARSESTAMP's/TS_RD2's own scratch, each written before its
*    own first read within the same call.
*  - PATHBUF: MKPATH writes chars then count; the MLI reads
*    only count+1. The three parmlists stay emitted above.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ARGIDX      ds    1
ERRFLAG     ds    1
HAVESTAMP   ds    1
TS_DATE     ds    2
TS_TIME     ds    2
TS_YR       ds    1
TS_MON      ds    1
TS_DAY      ds    1
TS_HOUR     ds    1
TS_MIN      ds    1
TS_TMP      ds    1
TS_TMP2     ds    1
TS_TMP3     ds    1
PATHBUF     ds    65
            err   */$BF00
            dend
