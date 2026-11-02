*---------------------------------------------------------------
* realpath.s -- print the absolute, canonical pathname of each
* operand.
*
* Usage: realpath [-E|-e] file...
*
* POSIX.1-2024's own SYNOPSIS is ONE operand ("realpath
* [-E|-e] file"); this build extends to `file...` the same way
* head.s/paste.s/cksum.s already take more than one, each
* operand handled independently and a failure on one not
* stopping the rest -- house convention, not a spec violation
* (the utility still behaves exactly as specified for a single
* operand).
*
* -E vs -e, PER THE XCU OPTIONS TEXT (fetched at design time,
* opengroup.org realpath.html): "-e: treat it as an error if
* resolving the LAST component ... results in ENOENT" / "-E: do
* NOT treat it as an error". The DEFAULT (neither given) is
* explicitly left "unspecified" by the DESCRIPTION -- so this
* build picks -E as the default (the last component may be
* missing), matching GNU coreutils' own unflagged behaviour
* (its default mode requires every component EXCEPT the last),
* which is what a script author reaches for most often. The
* last of -E/-e WINS if both are given, per the same OPTIONS
* text ("The last option specified shall determine...").
*
* CANONICALIZATION is done ENTIRELY IN LIBA'S HIGH-BIT TEXT
* DOMAIN, dirname.s's own style (no MLI call, no MKPATH) --
* MKPATH's own dot-handling (src/liba/mli.s) resolves only a
* LEADING run of "." / ".." against the cwd (its header says so:
* "scoped to the leading run ... A/../B resolves nowhere") and
* the kernel's PRC_DOTDOT is `cd`-only (PRC_SETPFX), so neither
* one folds an EMBEDDED ".." the way `./A/../F` needs. So this
* file does its own component split/push/pop (RP_SPLIT/RP_PUSH/
* RP_POP) on a plain slash-delimited buffer, exactly as if it
* were text -- then feeds the ALREADY-FOLDED, always-absolute
* result through MKPATH just once per existence check, purely
* as the high-bit-to-7-bit-count-prefixed converter it also is
* (its dot-check never fires because the folded string always
* starts with '/', never '.'). ".." pops down to the virtual
* root "/" and stops there (docs/VROOT.md: the volume is
* /mnt/NAME, a directory like any other), the same answer
* liba's MKP_POP gives `cd ..`.
*
* EXISTENCE (-e/-E) is GET_FILE_INFO (SC_GFI) on the folded
* path -- testeval.s's own `test -e/-d/-f` package, not a new
* mechanism. -e checks the WHOLE folded path; -E checks only
* the part before the last component (temporarily NUL the last
* slash, GFI, restore the byte) -- a single-component result
* (just the volume) has no "part before the last component" at
* all, so -E always accepts it outright.
*
* THE PRINTED FORM is RP_CANON itself: it is built and kept in
* liba's own high-bit convention throughout (the '/' characters
* included, $AF not $2F), so it needs no MAKEHI pass before
* PUTS -- unlike pwd.s, which converts GET_PREFIX's raw 7-bit
* answer once, this file works in high-bit text from the start
* and only strips it going the OTHER way, into RP_MLI, for the
* GFI calls.
*
* A failure on one operand prints a diagnostic to stderr and
* sets exit 1, but the loop continues -- the good operands
* still print (XCU: realpath is diagnose-and-continue, house
* convention besides).
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
            dsk   ../../build/realpath.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

RP_RAWSZ    equ   220        ;pre-fold buf: cwd+'/'+operand
RP_CANSZ    equ   160        ;folded canonical buffer

START       lda   #<OPTLIST
            ldx   #>OPTLIST
            jsr   OPTINIT
            stz   RP_MODE            ;0 = -E, see header
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #"E"
            beq   :isbige
            cmp   #"e"
            beq   :islile
            jmp   :usage
:isbige     stz   RP_MODE
            bra   :optlp
:islile     lda   #1
            sta   RP_MODE
            bra   :optlp
:optdone
            lda   OPTIND
            cmp   ARGC
            bcc   :haveop
            jmp   :usage

:haveop     stz   RP_EXIT
            lda   OPTIND
            sta   RP_OI
:oploop     lda   RP_OI
            cmp   ARGC
            bcs   :alldone
            jsr   GETARG              ;PTR0 = operand
            lda   PTR0
            sta   RP_OPRND
            lda   PTR0+1
            sta   RP_OPRND+1
            jsr   RP_RESOLVE
            bcc   :resok
            jsr   RP_DIAGERR
            bra   :nextop
:resok      jsr   RP_CHECK
            bcc   :exists
            jsr   RP_DIAGNOENT
            bra   :nextop
:exists     lda   #<RP_CANON
            sta   PTR0
            lda   #>RP_CANON
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:nextop     inc   RP_OI
            jmp   :oploop
:alldone    lda   RP_EXIT
            jsr   EXIT

:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* RP_RESOLVE -- IN: PTR0 = operand text. OUT: carry CLEAR,
* RP_CANON = the folded absolute pathname (high-bit,
* NUL-terminated); carry SET, RP_ERRCODE set (1 = no readable
* current directory for a relative operand, 2 = too long to
* build; 3 is retired -- folded to nothing is the root "/").
* CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
RP_RESOLVE  ldy   #0
            lda   (PTR0),y
            cmp   #$AF                ;'/' high-bit -- absolute
            beq   :isabs
            jsr   RP_GETCWD
            bcc   :havecwd
            lda   #1
            sta   RP_ERRCODE
            sec
            rts
:havecwd    ldy   RP_RLEN
            cpy   #RP_RAWSZ-2
            bcc   :sroom
            jmp   :toolong
:sroom      lda   #$AF
            sta   RP_RAW,y
            iny
            sty   RP_RLEN
            jsr   RP_APPEND
            bcc   :havesrc
            jmp   :toolong
:isabs      stz   RP_RLEN
            jsr   RP_APPEND
            bcc   :havesrc
            jmp   :toolong
:havesrc    jsr   RP_SPLIT
            bcc   :split_ok
            jmp   :toolong
:split_ok   lda   RP_CLEN
            bne   :ok
            lda   #$AF                ;folded to nothing: the
            sta   RP_CANON            ;virtual root, "/"
            stz   RP_CANON+1
            lda   #1
            sta   RP_CLEN
:ok         clc
            rts
:toolong    lda   #2
            sta   RP_ERRCODE
            sec
            rts

*---------------------------------------------------------------
* RP_GETCWD -- fill RP_RAW[0..) with the current ProDOS prefix,
* high-bit, NO trailing slash (GET_PREFIX's own answer never has
* one); RP_RLEN = its length. Carry SET on an SC_GETPFX failure
* or an empty prefix (nothing to resolve a relative path
* against) -- pwd.s's own PFXBUF shape, converted once here
* instead of at print time. CLOBBERS: A, X.
*---------------------------------------------------------------
RP_GETCWD   lda   #<RP_GPPARM
            ldx   #>RP_GPPARM
            jsr   SC_GETPFX
            bcs   :fail
            lda   RP_PFXTMP
            beq   :fail
            sta   RP_RLEN
            ldx   #0
:cplp       cpx   RP_RLEN
            beq   :done
            lda   RP_PFXTMP+1,x
            ora   #$80
            sta   RP_RAW,x
            inx
            bra   :cplp
:done       clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RP_APPEND -- IN: PTR0 = NUL-terminated high-bit text; RP_RLEN
* = the current length already in RP_RAW. Appends PTR0's text at
* RP_RLEN, NUL-terminates, updates RP_RLEN. Carry SET, RP_RAW
* left NUL-terminated at whatever it reached, if it does not fit
* in RP_RAWSZ-1 bytes. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RP_APPEND   ldy   #0
:lp         lda   (PTR0),y
            beq   :done
            ldx   RP_RLEN
            cpx   #RP_RAWSZ-1
            bcs   :over
            sta   RP_RAW,x
            inc   RP_RLEN
            iny
            bne   :lp
            bra   :over               ;255-byte word: refuse
:done       ldx   RP_RLEN
            stz   RP_RAW,x
            clc
            rts
:over       ldx   RP_RLEN
            stz   RP_RAW,x
            sec
            rts

*---------------------------------------------------------------
* RP_SPLIT -- fold RP_RAW[0..RP_RLEN) into RP_CANON: split on
* '/', drop empty and "." components, ".." pops the previous
* one (RP_POP, which stops at the root). OUT:
* carry CLEAR, RP_CANON NUL-terminated at RP_CLEN; carry SET =
* RP_CANON overflowed (RP_CANSZ). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RP_SPLIT    stz   RP_CLEN
            stz   RP_SY
:skip       lda   RP_SY
            cmp   RP_RLEN
            bcs   :alldone
            ldy   RP_SY
            lda   RP_RAW,y
            cmp   #$AF
            bne   :havestrt
            inc   RP_SY
            bra   :skip
:havestrt   lda   RP_SY
            sta   RP_CSTART
:find       lda   RP_SY
            cmp   RP_RLEN
            bcs   :gotcomp
            ldy   RP_SY
            lda   RP_RAW,y
            cmp   #$AF
            beq   :gotcomp
            inc   RP_SY
            bra   :find
:gotcomp    lda   RP_SY
            sec
            sbc   RP_CSTART
            sta   RP_CLENC
            cmp   #1
            bne   :notdot1
            ldy   RP_CSTART
            lda   RP_RAW,y
            cmp   #$AE                ;'.' high-bit
            bne   :notdot1
            jmp   :skip
:notdot1    lda   RP_CLENC
            cmp   #2
            bne   :dopush
            ldy   RP_CSTART
            lda   RP_RAW,y
            cmp   #$AE
            bne   :dopush
            iny
            lda   RP_RAW,y
            cmp   #$AE
            bne   :dopush
            jsr   RP_POP
            jmp   :skip
:dopush     jsr   RP_PUSH
            bcc   :skip
            sec
            rts
:alldone    ldx   RP_CLEN
            stz   RP_CANON,x
            clc
            rts

*---------------------------------------------------------------
* RP_PUSH -- append '/' + RP_RAW[RP_CSTART..+RP_CLENC) to
* RP_CANON at RP_CLEN, updating RP_CLEN. Carry SET on overflow.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RP_PUSH     ldx   RP_CLEN
            cpx   #RP_CANSZ-2
            bcc   :room
            sec
            rts
:room       lda   #$AF
            sta   RP_CANON,x
            inx
            ldy   RP_CSTART
            lda   RP_CLENC
            sta   RP_TMPCNT
:cplp       lda   RP_TMPCNT
            beq   :done
            cpx   #RP_CANSZ-1
            bcc   :cok
            sec
            rts
:cok        lda   RP_RAW,y
            sta   RP_CANON,x
            inx
            iny
            dec   RP_TMPCNT
            bra   :cplp
:done       stx   RP_CLEN
            clc
            rts

*---------------------------------------------------------------
* RP_FINDLAST -- the last '/' in RP_CANON[0..RP_CLEN). OUT: X =
* its index; carry SET if that index is > 0 (a real parent
* boundary exists); carry CLEAR if RP_CANON is empty or the only
* slash is at index 0 (a bare volume -- nothing above it).
* CLOBBERS: A, X.
*---------------------------------------------------------------
RP_FINDLAST lda   RP_CLEN
            bne   :havelen
            ldx   #0
            clc
            rts
:havelen    sec
            sbc   #1
            sta   RP_PI
:bscan      ldx   RP_PI
            lda   RP_CANON,x
            cmp   #$AF
            beq   :found
            lda   RP_PI
            beq   :none
            dec   RP_PI
            bra   :bscan
:found      lda   RP_PI
            beq   :none
            sec
            rts
:none       ldx   #0
            clc
            rts

*---------------------------------------------------------------
* RP_POP -- drop RP_CANON's last component (truncate at the last
* '/', dropping the slash and everything after); popping the
* first component leaves RP_CLEN 0, which RP_RESOLVE turns into
* the virtual root "/" (docs/VROOT.md). A, X.
*---------------------------------------------------------------
RP_POP      jsr   RP_FINDLAST
            bcc   :root
            stx   RP_CLEN
            rts
:root       stz   RP_CLEN             ;pop the first component:
            rts                       ;nothing left is the root

*---------------------------------------------------------------
* RP_CHECK -- existence per -E/-e (RP_MODE) against RP_CANON.
* OUT: carry CLEAR = satisfied (print it); carry SET = ENOENT.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
RP_CHECK    jsr   RP_FINDLAST
            bcs   :multicomp
            lda   RP_MODE
            bne   :needfull
            clc                       ;-E, single component: OK
            rts
:multicomp  stx   RP_SAVEIDX
            lda   RP_MODE
            bne   :needfull
            ldx   RP_SAVEIDX
            lda   RP_CANON,x
            sta   RP_SAVEBYT
            lda   #0
            sta   RP_CANON,x
            jsr   RP_GFICHK
            php
            ldx   RP_SAVEIDX
            lda   RP_SAVEBYT
            sta   RP_CANON,x
            plp
            rts
:needfull   jsr   RP_GFICHK
            rts

*---------------------------------------------------------------
* RP_GFICHK -- MKPATH(RP_CANON -> RP_MLI) + SC_GFI. Carry CLEAR
* = exists; carry SET = MKPATH overflow or SC_GFI failure --
* both mean "cannot resolve", the same outward diagnosis.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
RP_GFICHK   lda   #<RP_CANON
            sta   PTR0
            lda   #>RP_CANON
            sta   PTR0+1
            lda   #<RP_MLI
            sta   PTR1
            lda   #>RP_MLI
            sta   PTR1+1
            jsr   MKPATH
            bcs   :nope
            lda   #<RP_GFI
            ldx   #>RP_GFI
            jsr   SC_GFI
            rts
:nope       sec
            rts

*---------------------------------------------------------------
* RP_DIAGERR -- "realpath: <operand>: <msg>" to stderr per
* RP_ERRCODE; sets RP_EXIT = 1.
*---------------------------------------------------------------
RP_DIAGERR  jsr   RP_SAYOP
            lda   RP_ERRCODE
            cmp   #1
            beq   :nocwd
            cmp   #2
            beq   :long
            lda   #<E_INVALID
            ldx   #>E_INVALID
            bra   :say
:nocwd      lda   #<E_NOCWD
            ldx   #>E_NOCWD
            bra   :say
:long       lda   #<E_TOOLONG
            ldx   #>E_TOOLONG
:say        jsr   RP_SAYERR
            rts

*---------------------------------------------------------------
* RP_DIAGNOENT -- "realpath: <operand>: No such file or
* directory" to stderr; sets RP_EXIT = 1.
*---------------------------------------------------------------
RP_DIAGNOENT
            jsr   RP_SAYOP
            lda   #<E_NOENT
            ldx   #>E_NOENT
            jsr   RP_SAYERR
            rts

*---------------------------------------------------------------
* RP_SAYOP -- "realpath: " + the current operand (RP_OPRND), no
* CR yet. CLOBBERS: A, X, PTR0.
*---------------------------------------------------------------
RP_SAYOP    lda   #<RP_PREFIX
            sta   PTR0
            lda   #>RP_PREFIX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   RP_OPRND
            sta   PTR0
            lda   RP_OPRND+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

*---------------------------------------------------------------
* RP_SAYERR -- A/X = message tail; print + CR to stderr, set
* RP_EXIT = 1. CLOBBERS: A, X, PTR0.
*---------------------------------------------------------------
RP_SAYERR   sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   RP_EXIT
            rts

OPTLIST     asc   "Ee"
            dfb   0
USAGEMSG    asc   "usage: realpath [-E|-e] file..."
            dfb   $8D,$00
RP_PREFIX   asc   "realpath: "
            dfb   0
E_NOENT     asc   ": No such file or directory"
            dfb   $8D,$00
E_NOCWD     asc   ": no current directory to resolve"
            asc   " against"
            dfb   $8D,$00
E_TOOLONG   asc   ": file name too long"
            dfb   $8D,$00
E_INVALID   asc   ": invalid pathname"
            dfb   $8D,$00

RP_GPPARM      dfb   1
RP_GPPARM_BUF  da    RP_PFXTMP

RP_GFI         dfb   PCOUNT_GFI
RP_GFI_PATH    da    RP_MLI
RP_GFI_ACC     dfb   0
RP_GFI_FTYP    dfb   0
RP_GFI_AUX     da    0
RP_GFI_STYP    dfb   0
RP_GFI_BLKS    da    0
RP_GFI_MDT     da    0
RP_GFI_MTM     da    0
RP_GFI_CDT     da    0
RP_GFI_CTM     da    0

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
* realpath's own bss -- `dum`/`dend` off LIBA_BSSEND, no zero
* fills needed (docs/STICKY.md sec 21): every cell below is
* write-before-read on the path that reads it.
*  - RP_MODE: `stz`'d/set by the option loop before :haveop
*    ever reads it.
*  - RP_EXIT/RP_OI: `haveop`'s own first writes.
*  - RP_OPRND: written every iteration before RP_RESOLVE/
*    RP_CHECK's diagnostics ever read it.
*  - RP_RLEN/RP_CLEN/RP_SY/RP_CSTART/RP_CLENC/RP_TMPCNT/RP_PI/
*    RP_SAVEIDX/RP_SAVEBYT: each written before its own first
*    read inside the routine that owns it.
*  - RP_ERRCODE: RP_RESOLVE's own failure paths set it before
*    RP_DIAGERR ever reads it.
*  - RP_PFXTMP/RP_RAW/RP_CANON/RP_MLI: filled byte-by-byte (or
*    by SC_GETPFX/MKPATH) before being read back.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
RP_MODE     ds    1
RP_EXIT     ds    1
RP_OI       ds    1
RP_OPRND    ds    2
RP_ERRCODE  ds    1
RP_RLEN     ds    1
RP_CLEN     ds    1
RP_SY       ds    1
RP_CSTART   ds    1
RP_CLENC    ds    1
RP_TMPCNT   ds    1
RP_PI       ds    1
RP_SAVEIDX  ds    1
RP_SAVEBYT  ds    1
RP_PFXTMP   ds    80
RP_RAW      ds    RP_RAWSZ
RP_CANON    ds    RP_CANSZ
RP_MLI      ds    65
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
