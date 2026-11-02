*---------------------------------------------------------------
* pr.s -- paginate files for printing.
*
* Usage: pr [+page] [-column] [-adFmt] [-e[c][n]] [-i[c][n]]
*           [-h header] [-l lines] [-n[char][width]]
*           [-o offset] [-s[c]] [-w width] [file...]
*
* IMPLEMENTED, in the order the task brief asked for, stopping
* at the ~3 KB budget: -t (suppress header/trailer/pagination
* entirely -- measured live: BSD /usr/bin/pr -t never breaks
* pages at all, regardless of -l), -l lines (default 66;
* 5-line header + BODYCAP=lines-10 body lines + PADDING to
* fill the page, not a fixed 5-line trailer -- measured: a
* short last page is padded with blank lines up to the full
* page length, not just five), -h header (replaces the
* filename in the header entirely), -n[char][width] (default
* tab, width 5, ATTACHED only -- no separate-argument form,
* since the option-argument is OPTIONAL and this tree's GETOPT
* only supports a MANDATORY attached-or-separate argument), -d
* (double spacing), -o offset (N literal spaces before every
* printed line, header included -- measured), +page (skip
* pages before N, still consuming their input). Since 2026-10-08
* the column engine is here too (prcol.s, prmrg.s, prout.s):
* -column, -a, -m, -w, -s[char], -e[char][gap], -i[char][gap],
* -F -- see those files' headers and docs/POSIX-PR-NOTES.md.
*
* PAGE ARITHMETIC (measured live against this host's BSD pr,
* which XCU leaves largely to the implementation): a page has
* a 5-line header ("\n\ndate file Page N\n\n") UNLESS -t,
* then up to BODYCAP=PAGELEN-10 content lines, then enough
* blank lines to bring the page up to exactly PAGELEN lines
* total -- even on the LAST page of a short file. If
* PAGELEN<=10 (no room for even one body line under a
* header), this build silently falls back to the -t shape (no
* header, no pagination at all) -- matching this host's own
* /usr/bin/pr -l 10 on a short file EXACTLY: no header
* printed, all lines copied straight through. Multiple FILE
* operands each get their OWN page-1-relative numbering and
* their own header naming that file (measured); stdin's
* header names no file at all (two spaces where the name
* would be).
*
* THE HEADER DATE IS THE FILE'S OWN LAST-MODIFICATION TIME
* (XCU: "Except when the -m option is specified... st_mtime"),
* read via GET_FILE_INFO the same way mkdir.s's MP_ISDIR
* already does, decoded the same packed-date/time shape as
* date.s/lsprint.s (day/month/year7/hour/minute, pivot-78
* century). For stdin
* (no file to stat) the CURRENT time is used instead (SC_CLOCK).
* This date is real wall-clock time and therefore NOT
* reproducible across two runs of this suite's own staging
* (a2til's write_file() stamps datetime.now(), not a fixed or
* zero ProDOS date) -- header rows in the suite are gated on
* SHAPE (page-count/number occurrences), never the literal date
* string; only the -t rows (no header at all) and the textaudit
* PAIR (which also uses -t, for exactly this reason) are
* byte-exact.
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
            dsk   ../../build/pr.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;read chunk, see GETBYTE
LBUFCAP     equ   200              ;one line, see READLN
DEFPGLEN    equ   66               ;default -l
DEFWIDTH    equ   5                ;default -n width
TABCH       equ   $89              ;default -n separator
HDRCAP      equ   40               ;-h header text, copied in
TABMAX      equ   1024             ;lines in one column page
NMAXM       equ   8                ;-m columns
NFILEM      equ   5                ;-m FILE operands (fd table)
ARENAEND    equ   $BF00            ;text arena ends here

START       stz   TFLAG
            stz   DFLAG
            stz   HAVEH
            stz   HAVEN
            stz   OFFSETVAL
            lda   #DEFPGLEN
            sta   PAGELEN
            stz   ERRFLAG
            lda   #1
            sta   STARTPAGE
            lda   #1
            sta   PSTART
            stz   AFLAG
            stz   MFLAG
            stz   FFLAG
            stz   SFLAG
            stz   EFLAG
            stz   IFLAG
            stz   HAVEW
            stz   NGIVEN
            lda   #1
            sta   NCOLS
            lda   #8
            sta   EGAP
            sta   IGAP
            lda   #TABCH
            sta   SEPCH
            sta   ETABCH
            sta   ITABCH

*-- the whole +page/option grammar lives in prparse.s's own
*-- OPTPARSE, `put` below (split for the as-window budget --
*-- see this file's own put line for the measurement).
            jsr   OPTPARSE
            jsr   COLINIT
            lda   MFLAG
            beq   :optsdn
            jsr   PRMERGE
            jmp   :alldn

:optsdn     lda   ARGIDX
            cmp   ARGC
            bne   :havefls
            lda   #FD_STDIN
            sta   CURFD
            lda   #<EMPTYSTR
            sta   FNAMEPTR
            lda   #>EMPTYSTR
            sta   FNAMEPTR+1
            lda   #<CLKBUF
            sta   PTR0
            lda   #>CLKBUF
            sta   PTR0+1
            jsr   SC_CLOCK
            lda   CLKBUF
            sta   HDATE
            lda   CLKBUF+1
            sta   HDATE+1
            lda   CLKBUF+2
            sta   HTIME
            lda   CLKBUF+3
            sta   HTIME+1
            jsr   PRFILEX
            jmp   :alldn

:havefls
:floop      lda   ARGIDX
            cmp   ARGC
            bcc   :fl_go
            jmp   :alldn
:fl_go      jsr   GETARG
            lda   PTR0
            sta   FNAMEPTR
            lda   PTR0+1
            sta   FNAMEPTR+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :fopn
            lda   #<CANTOPEN
            sta   PTR0
            lda   #>CANTOPEN
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   FNAMEPTR
            sta   PTR0
            lda   FNAMEPTR+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG
            jmp   :fnext
:fopn       lda   OPARM_REF
            sta   CURFD
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :fgfiok
            stz   HDATE
            stz   HDATE+1
            stz   HTIME
            stz   HTIME+1
            bra   :fgfid
:fgfiok     lda   GFI_MDATE
            sta   HDATE
            lda   GFI_MDATE+1
            sta   HDATE+1
            lda   GFI_MTIME
            sta   HTIME
            lda   GFI_MTIME+1
            sta   HTIME+1
:fgfid      jsr   PRFILEX
            lda   CURFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            bcc   :fnext
            lda   #1
            sta   ERRFLAG
:fnext      inc   ARGIDX
            jmp   :floop

:alldn      lda   ERRFLAG
            jsr   EXIT

            put   prparse.s
            put   prfmt.s
            put   prout.s
            put   prcol.s
            put   prmrg.s

* -- PRFILEX: one file, in whichever layout the options chose.
PRFILEX     lda   NCOLS
            cmp   #2
            bcc   :one
            jmp   PRFILEC
:one        jmp   PRFILE

CANTOPEN    asc   "pr: cannot open "
            dfb   $00
EMPTYSTR    dfb   0

OPARM       dfb   OPEN_RO
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

* -- GET_FILE_INFO ($C4), same field order as mkdir.s's own
* -- GFIPARM.
GFIPARM     dfb   PCOUNT_GFI
GFI_PATH    da    PATHBUF
GFI_ACC     dfb   0
GFI_FTYP    dfb   0
GFI_AUX     da    0
GFI_STYP    dfb   0
GFI_BLKS    da    0
GFI_MDATE   da    0
GFI_MTIME   da    0
GFI_CDATE   da    0
GFI_CTIME   da    0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/num.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* pr's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - TFLAG/DFLAG/HAVEH/HAVEN/OFFSETVAL/PAGELEN/ERRFLAG/
*    STARTPAGE/PSTART: START's own stores, before option parsing
*    or the file loop reads any of them.
*  - PLUS_PTR: the +page pre-scan's own store, read back
*    immediately.
*  - ARGIDX: `sta` from PSTART right after the pre-scan.
*  - ONW_PTR: the -n suffix parser's own store, read back
*    immediately.
*  - GV_ERR: GETVALWD's own store, every call, before its
*    caller's read.
*  - PD_ACC/PD_HAVE/PD_T2: PARSEDEC's own stores, every call,
*    before its own later reads.
*  - HEADERBUF: COPYHDR's own fill, only read when HAVEH is set
*    (which COPYHDR's own caller sets right after).
*  - CURFD/FNAMEPTR/HDATE/HTIME: written on every path (stdin or
*    an opened file) before PRFILE's first read of any of them.
*  - PR_DAY/PR_MON/PR_YR7/PR_HOUR/PR_MIN/PR_YRLO/PR_YRHI:
*    PRDATE's own stores, every call, before its own later
*    reads.
*  - PR2_ONE: PR2DIG0/PR2DIGSP's own store, read back
*    immediately -- both routines never run re-entrantly.
*  - PO_CNT/PP_CNT: PUTOFS/PRINTPAD's own stores, every call.
*  - EL_IDX: EMITLBUF's own stz, first thing, every call.
*  - PB_DLEN/PB_PAD: PRBODY's own stores, before their own
*    later reads.
*  - LINENOLO/HI/PAGENUM/BODYCNT/EFFT/BODYCAP/RLEOF: PRFILE's
*    own stores, before its own loop reads any of them.
*  - BUFPOS/BUFLEN: `stz`'d by PRFILE itself before READLN's
*    first call, once per file (a `dum` arena does not clear
*    itself between processes OR between files in one process --
*    same reason head.s's HEADCOPY resets per file).
*  - LLEN/LBUF: READLN's own stz/fill, first thing, every call.
*  - PATHBUF/CBUF: MKPATH/SC_READ fill them; read only up to
*    what was written.
*  - CLKBUF: SC_CLOCK's own buffer, read right after (stdin
*    path only).
*  - AFLAG..IGAP, NCOLS, NGIVEN, HAVEW: START's own stores.
* WIDTH:
*    COLINIT or -w. CGCH/CGGAP: PARSECG, every call. The column
*    geometry (STRIDE..CAPLN) is COLINIT's, read only in column
*    mode. CNT/ARP/FILLEOF/SLEN: FILLPAGE, first thing. ROWS:
*    CALCROWS. ROWI/ROWIDX/COLSTEP/ROWSTEP: PRROWS.
* COLI/LASTCOL/
*    COLPOS/IDX: PRROW. OUTCOL/PENDSP: EMBEG, per output line.
*    FIDX/ANY/MEXIST/MFD/MPOS/MLEN/MDONE/MCELLPG/MRDPG: PRMERGE
* (and
*    COLINIT's file count), all written before read. TAB/ARENA:
*    FILLPAGE and PRMERGE fill what they read.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
TFLAG       ds    1
DFLAG       ds    1
HAVEH       ds    1
HAVEN       ds    1
OFFSETVAL   ds    1
PAGELEN     ds    1
ERRFLAG     ds    1
STARTPAGE   ds    1
PSTART      ds    1
PLUS_PTR    ds    2
ARGIDX      ds    1
ONW_PTR     ds    2
GV_ERR      ds    1
PD_ACC      ds    1
PD_HAVE     ds    1
PD_T2       ds    1
PD_D        ds    1
NCHAR       ds    1
NWIDTH      ds    1
CURFD       ds    1
FNAMEPTR    ds    2
HDATE       ds    2
HTIME       ds    2
PR_DAY      ds    1
PR_MON      ds    1
PR_YR7      ds    1
PR_HOUR     ds    1
PR_MIN      ds    1
PR_YRLO     ds    1
PR_YRHI     ds    1
PR2_ONE     ds    1
PO_CNT      ds    1
PP_CNT      ds    1
EL_IDX      ds    1
PB_DLEN     ds    1
PB_PAD      ds    1
LINENOLO    ds    1
LINENOHI    ds    1
PAGENUM     ds    1
BODYCNT     ds    1
EFFT        ds    1
BODYCAP     ds    1
RLEOF       ds    1
BUFPOS      ds    1
BUFLEN      ds    1
LLEN        ds    1
AFLAG       ds    1
MFLAG       ds    1
FFLAG       ds    1
SFLAG       ds    1
SEPCH       ds    1
EFLAG       ds    1
ETABCH      ds    1
EGAP        ds    1
IFLAG       ds    1
ITABCH      ds    1
IGAP        ds    1
NCOLS       ds    1
NGIVEN      ds    1
HAVEW       ds    1
WIDTH       ds    2
CGCH        ds    1
CGGAP       ds    1
STRIDE      ds    1
TW          ds    1
AVAIL0      ds    1
AVAILN      ds    1
NUMPFX      ds    1
ROWSCAP     ds    1
CAPLN       ds    2
CNT         ds    2
ROWS        ds    1
ROWI        ds    1
COLI        ds    1
LASTCOL     ds    1
COLPOS      ds    1
CSN         ds    1
IDX         ds    2
ROWIDX      ds    2
COLSTEP     ds    2
ROWSTEP     ds    1
FILLEOF     ds    1
SLEN        ds    1
ARP         ds    2
DV          ds    2
OUTCOL      ds    1
PENDSP      ds    1
EMC         ds    1
EMD         ds    1
EMT         ds    1
FIDX       ds    1
ANY         ds    1
MCELLPG     ds    1
MRDPG       ds    1
MEXIST      ds    NMAXM
MFD         ds    NMAXM
MPOS        ds    NMAXM
MLEN        ds    NMAXM
MDONE       ds    NMAXM

HEADERBUF   ds    HDRCAP
LBUF        ds    LBUFCAP
PATHBUF     ds    65
CBUF        ds    BUFSZ
CLKBUF      ds    4
PRDIGBUF    ds    8
TAB         ds    TABMAX*2
* -- the text arena (page-aligned runtime pieces for -m live in
* -- it too) runs from here to ARENAEND; it must keep at least
* -- 16 pages + one for -m, and a few KB for a column page.
ARENA       ds    0
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's start;
* -- the arena needs 20 KB below $BF00 ($6A00).
            err   */$6A00
            dend
