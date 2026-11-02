*---------------------------------------------------------------
* pathchk.s -- check pathnames for validity/portability.
*
* Usage: pathchk [-p] [-P] pathname...
*
* No option (maux's OWN limits, not the host's): a component
* over PC_COMPMAX (15) characters, or a whole pathname over
* MLI_PTH_MAXLN (64, inc/mli.equ -- MKPATH's own cap, cited
* rather than duplicated) is a failure. A component's first
* character must be a letter; the rest must be letters, digits,
* or a period (ProDOS's own directory-entry naming rule,
* case-insensitive -- both cases accepted, never folded). A
* NONEXISTENT intermediate directory is NOT an error (the XCU
* text: "It is not considered an error if a pathname argument
* contains a nonexistent component..."); an EXISTING one that is
* not itself a directory is (CKEXIST, GET_FILE_INFO's own
* storage_type, the same STYP_DIR/$0F test mkdir.s's MP_ISDIR
* already uses).
*
* -p: the POSIX portable character set [A-Za-z0-9._-],
* PC_PORTMAX (14, _POSIX_NAME_MAX) per component, PC_PPATHMX
* (255 -- see CKONE's own note: _POSIX_PATH_MAX is 256, one
* past what an 8-bit length counter can even represent) for
* the whole path. No existence check at all under -p (this
* host's own pathchk(1) agrees -- verified live, 2026-09-15).
*
* -P: in addition to whichever of the above is active, an
* EMPTY pathname or any component beginning with '-' is a
* failure (confirmed against this host's own pathchk(1) man
* page: "-P... is empty... contains a component that starts
* with a hyphen").
*
* Any failure: "pathchk: " + the pathname, to stderr; the
* pathname is otherwise unaffected and the NEXT operand is still
* checked. Exit 1 if any operand failed, 0 if all passed.
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
            dsk   ../../build/pathchk.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- ProDOS's own directory-entry name_length field is 4 bits
* -- (P8 TRM ch. 4) -- 15 is the largest component ProDOS itself
* -- can ever store, independent of MLI_PTH_MAXLN (the WHOLE
* -- pathname cap MKPATH enforces, inc/mli.equ).
PC_COMPMAX  equ   15
PC_PORTMAX  equ   14             ;_POSIX_NAME_MAX (XCU limits.h)
PC_PPATHMX  equ   255            ;see CKONE's own note

START       lda   #<OPTLIST
            ldx   #>OPTLIST
            jsr   OPTINIT
            stz   PFLAG
            stz   BIGPFLAG
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$BF                  ;'?' unrecognised
            beq   :usage
            cmp   #$F0                  ;'p'
            bne   :notp
            lda   #1
            sta   PFLAG
            bra   :optlp
:notp       lda   #1                    ;OPTLIST's only other
            sta   BIGPFLAG              ;letter is 'P'
            bra   :optlp
:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

:optdone    stz   ERRFLAG
            lda   OPTIND
            sta   ARGIDX
:looparg    lda   ARGIDX
            cmp   ARGC
            bcs   :done
            jsr   GETARG                ;-> PTR0
            jsr   CKONE
            lda   CK_ERR
            beq   :nextarg
            lda   #1
            sta   ERRFLAG
            lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG                ;re-fetch: PUTS ate PTR0
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
:nextarg    inc   ARGIDX
            bra   :looparg
:done       lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* CKONE -- IN: PTR0 = one pathname operand (liba string). OUT:
* CK_ERR = 1 if any active check fails, 0 if all pass.
* CLOBBERS: A, X, Y, PTR1, PTR2.
*---------------------------------------------------------------
CKONE       stz   CK_ERR
            jsr   PC_STRLN
            sty   CK_LEN
            lda   BIGPFLAG
            beq   :cobpd
            lda   CK_LEN
            bne   :cobpd
            lda   #1
            sta   CK_ERR
:cobpd      lda   PFLAG
            bne   :cowlp
            lda   CK_LEN
            cmp   #MLI_PTH_MAXLN+1
            bcc   :cowld
            lda   #1
            sta   CK_ERR
            bra   :cowld
:cowlp      lda   CK_LEN
            cmp   #PC_PPATHMX
            bcc   :cowld
            lda   #1
            sta   CK_ERR
:cowld      lda   CK_LEN
            beq   :codone
            jsr   CKCOMP
            lda   PFLAG
            bne   :codone
            jsr   CKEXIST
:codone     rts

*---------------------------------------------------------------
* PC_STRLN -- IN: PTR0. OUT: Y = length up to the NUL (0-255).
* CLOBBERS: A, Y.
*---------------------------------------------------------------
PC_STRLN      ldy   #0
:sllp       lda   (PTR0),y
            beq   :sldn
            iny
            bra   :sllp
:sldn       rts

*---------------------------------------------------------------
* CKCOMP -- walks PTR0's string splitting on '/', validating
* each component's length and character set (and, under -P, its
* leading character) via CKCOMP1. Sets CK_ERR; never clears it.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CKCOMP      ldy   #0
            sty   CK_CSTART
:ccnext     ldy   CK_CSTART
:ccscan     lda   (PTR0),y
            beq   :ccend
            cmp   #$AF                  ;'/' high-bit
            beq   :ccend
            iny
            bra   :ccscan
:ccend      tya
            sec
            sbc   CK_CSTART
            sta   CK_CLEN
            jsr   CKCOMP1
            ldy   CK_CSTART
            clc
            lda   CK_CSTART
            adc   CK_CLEN
            tay
            lda   (PTR0),y
            beq   :ccdone
            iny
            sty   CK_CSTART
            bra   :ccnext
:ccdone     rts

*---------------------------------------------------------------
* CKCOMP1 -- validates one component: PTR0[CK_CSTART ..
* CK_CSTART+CK_CLEN). Length + charset per PFLAG; leading '-'
* under BIGPFLAG. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CKCOMP1     lda   PFLAG
            bne   :c1p
            lda   CK_CLEN
            cmp   #PC_COMPMAX+1
            bcc   :c1ld
            lda   #1
            sta   CK_ERR
            bra   :c1ld
:c1p        lda   CK_CLEN
            cmp   #PC_PORTMAX+1
            bcc   :c1ld
            lda   #1
            sta   CK_ERR
:c1ld       lda   CK_CLEN
            beq   :c1hy
            ldy   CK_CSTART
            lda   (PTR0),y
            ldx   PFLAG
            bne   :c1skf
            jsr   ISLETTER
            bcs   :c1fok
            lda   #1
            sta   CK_ERR
:c1fok
:c1skf      lda   CK_CSTART
            clc
            adc   CK_CLEN
            sta   CK_CEND
            ldy   CK_CSTART
:c1cl       cpy   CK_CEND
            bcs   :c1hy
            sty   CK_YSAVE
            lda   PFLAG
            bne   :c1pc
            ldy   CK_YSAVE
            lda   (PTR0),y
            jsr   ISLDP
            bcs   :c1cok
            lda   #1
            sta   CK_ERR
            bra   :c1cok
:c1pc       ldy   CK_YSAVE
            lda   (PTR0),y
            jsr   ISPORT
            bcs   :c1cok
            lda   #1
            sta   CK_ERR
:c1cok      ldy   CK_YSAVE
            iny
            bra   :c1cl
:c1hy       lda   BIGPFLAG
            beq   :c1dn
            lda   CK_CLEN
            beq   :c1dn
            ldy   CK_CSTART
            lda   (PTR0),y
            cmp   #$AD                  ;'-' high-bit
            bne   :c1dn
            lda   #1
            sta   CK_ERR
:c1dn       rts

*---------------------------------------------------------------
* ISLETTER -- IN: A = a high-bit source byte. OUT: carry SET if
* it is A-Z or a-z. CLOBBERS: A.
*---------------------------------------------------------------
ISLETTER    and   #$7F
            cmp   #'A'
            bcc   :ilno
            cmp   #'Z'+1
            bcc   :ilyes
            cmp   #'a'
            bcc   :ilno
            cmp   #'z'+1
            bcc   :ilyes
:ilno       clc
            rts
:ilyes      sec
            rts

*---------------------------------------------------------------
* ISLDP -- IN: A = a high-bit source byte. OUT: carry SET if it
* is a letter, digit, or period. CLOBBERS: A.
*---------------------------------------------------------------
ISLDP       and   #$7F
            cmp   #'.'
            beq   :ilpy
            cmp   #'0'
            bcc   :ilpn
            cmp   #'9'+1
            bcc   :ilpy
            cmp   #'A'
            bcc   :ilpn
            cmp   #'Z'+1
            bcc   :ilpy
            cmp   #'a'
            bcc   :ilpn
            cmp   #'z'+1
            bcc   :ilpy
:ilpn       clc
            rts
:ilpy       sec
            rts

*---------------------------------------------------------------
* ISPORT -- IN: A = a high-bit source byte. OUT: carry SET if it
* is in the portable filename character set [A-Za-z0-9._-].
* CLOBBERS: A.
*---------------------------------------------------------------
ISPORT      and   #$7F
            cmp   #'-'
            beq   :ipy
            cmp   #'_'
            beq   :ipy
            cmp   #'.'
            beq   :ipy
            cmp   #'0'
            bcc   :ipn
            cmp   #'9'+1
            bcc   :ipy
            cmp   #'A'
            bcc   :ipn
            cmp   #'Z'+1
            bcc   :ipy
            cmp   #'a'
            bcc   :ipn
            cmp   #'z'+1
            bcc   :ipy
:ipn        clc
            rts
:ipy        sec
            rts

*---------------------------------------------------------------
* CKEXIST -- default mode only (caller checks !PFLAG). Resolves
* PTR0's pathname through MKPATH, then walks its intermediate
* components (same split-and-restore shape as mkdir.s's own
* MKDIRP :walk, GET_FILE_INFO in place of CREATE): an EXISTING
* prefix that is not a directory sets CK_ERR; a prefix that
* does not exist is left alone (not an error -- the XCU text
* quoted in this file's own header). The LEAF itself is never
* checked here -- only pathnames strictly BEFORE it. CLOBBERS:
* A, X, Y, PTR1, PTR2.
*---------------------------------------------------------------
CKEXIST     lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            bcs   :cxdn                 ;too long -- the whole-
                                         ;length check already
                                         ;flagged it
            lda   PATHBUF
            sta   CX_CNT
            lda   PATHBUF+1
            cmp   #'/'
            bne   :cxw0
            ldy   #1
:cxvs       cpy   CX_CNT
            bcs   :cxdn                 ;bare "/VOLUME" --
                                         ;nothing to walk
            lda   PATHBUF+1,y
            cmp   #'/'
            beq   :cxve
            iny
            bra   :cxvs
:cxve       iny
            bra   :cxw1
:cxw0       ldy   #0
:cxw1       sty   CX_WALKY
:cxloop     ldy   CX_WALKY
            cpy   CX_CNT
            bcs   :cxdn                 ;reached the leaf
            lda   PATHBUF+1,y
            cmp   #'/'
            bne   :cxnx
            sty   CX_SAVEY
            tya
            sta   PATHBUF                ;temp count = chars
                                         ;before this '/'
            lda   #<GXPARM
            ldx   #>GXPARM
            jsr   SC_GFI
            bcs   :cxrs                 ;doesn't exist -- fine
            lda   GXPARM_STYP
            cmp   #STYP_DIR
            beq   :cxrs
            cmp   #$0F
            beq   :cxrs
            lda   #1
            sta   CK_ERR
:cxrs       lda   CX_CNT
            sta   PATHBUF
            ldy   CX_SAVEY
:cxnx       iny
            sty   CX_WALKY
            bra   :cxloop
:cxdn       rts

OPTLIST     asc   "pP"
            dfb   0
USAGEMSG    asc   "usage: pathchk [-p] [-P] pathname..."
            dfb   $8D,$00
ERRMSG      asc   "pathchk: "
            dfb   $00

* -- GET_FILE_INFO ($C4), PCOUNT_GFI-shaped (inc/mli.equ),
* -- same field order as mkdir.s's own GFIPARM.
GXPARM      dfb   PCOUNT_GFI
GXPARM_PATH da    PATHBUF
GXPARM_ACC  dfb   0
GXPARM_FTYP dfb   0
GXPARM_AUX  da    0
GXPARM_STYP dfb   0
GXPARM_BLKS da    0
GXPARM_MDT  da    0
GXPARM_MTM  da    0
GXPARM_CDT  da    0
GXPARM_CTM  da    0

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
* pathchk's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - PFLAG/BIGPFLAG: `stz`'d at START, before OPTINIT's loop.
*  - ERRFLAG: `stz` at :optdone.
*  - ARGIDX: `sta` at :optdone from OPTIND.
*  - CK_ERR: `stz`'d at CKONE's own start, every call.
*  - CK_LEN/CK_CSTART/CK_CLEN/CK_CEND/CK_YSAVE: each routine's
*    own store before its own later read, every call.
*  - CX_CNT/CX_WALKY/CX_SAVEY: CKEXIST's own scratch, written
*    fresh before any read, every call.
*  - PATHBUF: MKPATH writes chars then the count byte.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
PFLAG       ds    1
BIGPFLAG    ds    1
ERRFLAG     ds    1
ARGIDX      ds    1
CK_ERR      ds    1
CK_LEN      ds    1
CK_CSTART   ds    1
CK_CLEN     ds    1
CK_CEND     ds    1
CK_YSAVE    ds    1
CX_CNT      ds    1
CX_WALKY    ds    1
CX_SAVEY    ds    1
PATHBUF     ds    65
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
