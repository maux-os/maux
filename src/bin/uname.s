*---------------------------------------------------------------
* uname.s -- print system identification.
*
* Usage: uname [-snrvma]
*
* CONTRACT (XCU uname): with no options, write the system name
* to stdout, followed by a CR. Each of -s/-n/-r/-v/-m selects
* one field (sysname/nodename/release/version/machine); -a
* selects all five. When MORE THAN ONE field is selected --
* whether by several letters or by -a -- every selected field
* is written on ONE line, space-separated, in the fixed order
* sysname nodename release version machine regardless of the
* order the options were given (XCU's own wording: "the fixed
* order"). Selecting the same field twice is not an error and
* does not repeat it. Exit 0; no operands (a usage error, exit
* 2, house convention).
*
* FIELD VALUES, and why each is what it is:
*   sysname  "maux" -- this system's name, not ProDOS's (uname
*            answers for the OS running the process, and a
*            ProDOS-hosted process is still a maux process).
*   nodename "apple2e" -- POSIX REQUIRES this field even though
*            maux has no hostname concept and no network stack
*            to name a host for (grepped: no HOSTNAME/nodename
*            equate anywhere in inc/ or src/kernel). A
*            constant naming the machine class is the honest
*            answer available, not an invented network name.
*   release  "1.0" -- grepped inc/ and src/kernel/ for a
*            kernel version equate or boot banner string; there
*            is none (docs list dates and commit hashes, never
*            a version number). This is a GIT-LESS PLACEHOLDER
*            constant, stated here rather than silently assumed
*            -- the day maux gets a real version equate, this
*            and VERSTR both start reading it instead.
*   version  "1.0" -- same reasoning; XCU distinguishes release
*            (the OS release) from version (this build of it),
*            but with neither tracked anywhere in the tree they
*            share the one placeholder rather than inventing a
*            second, differently-wrong number.
*   machine  "65c02" -- the CPU maux requires (`xc` throughout
*            this tree); not "6502", which cannot run this
*            image (65C02 opcodes are load-bearing, e.g. `stz`,
*            `bra`).
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
            dsk   ../../build/uname.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

OPTLIST     asc   "snrvma"
            dfb   0

START       lda   #<OPTLIST
            ldx   #>OPTLIST
            jsr   OPTINIT
            stz   SFLAG
            stz   NFLAG
            stz   RFLAG
            stz   VFLAG
            stz   MFLAG
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F3                   ;'s'
            beq   :fs
            cmp   #$EE                   ;'n'
            beq   :fn
            cmp   #$F2                   ;'r'
            beq   :fr
            cmp   #$F6                   ;'v'
            beq   :fv
            cmp   #$ED                   ;'m'
            beq   :fm
            cmp   #$E1                   ;'a'
            beq   :fa
            jmp   :usage                 ;'?' unrecognised --
                                         ;OPTLIST covers the
                                         ;other six, nothing
                                         ;else reaches here
:fs         lda   #1
            sta   SFLAG
            bra   :optlp
:fn         lda   #1
            sta   NFLAG
            bra   :optlp
:fr         lda   #1
            sta   RFLAG
            bra   :optlp
:fv         lda   #1
            sta   VFLAG
            bra   :optlp
:fm         lda   #1
            sta   MFLAG
            bra   :optlp
:fa         lda   #1
            sta   SFLAG
            sta   NFLAG
            sta   RFLAG
            sta   VFLAG
            sta   MFLAG
            bra   :optlp

:optdone    lda   ARGC
            cmp   OPTIND
            bne   :usage                 ;uname takes no
                                         ;operands
            lda   SFLAG
            ora   NFLAG
            ora   RFLAG
            ora   VFLAG
            ora   MFLAG
            bne   :haveflag
            lda   #1
            sta   SFLAG                  ;no options: -s
:haveflag   stz   NEEDSP
            lda   SFLAG
            beq   :ckn
            lda   #<SYSNAME
            ldx   #>SYSNAME
            jsr   PRFLD
:ckn        lda   NFLAG
            beq   :ckr
            jsr   PRSEP
            lda   #<NODENAME
            ldx   #>NODENAME
            jsr   PRFLD
:ckr        lda   RFLAG
            beq   :ckv
            jsr   PRSEP
            lda   #<RELSTR
            ldx   #>RELSTR
            jsr   PRFLD
:ckv        lda   VFLAG
            beq   :ckm
            jsr   PRSEP
            lda   #<VERSTR
            ldx   #>VERSTR
            jsr   PRFLD
:ckm        lda   MFLAG
            beq   :fin
            jsr   PRSEP
            lda   #<MACHSTR
            ldx   #>MACHSTR
            jsr   PRFLD
:fin        lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #0
            jsr   EXIT

:usage      lda   #<USAGE
            sta   PTR0
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* PRFLD -- print one field. IN: A/X = lo/hi of a NUL-terminated
* liba string. Sets NEEDSP so the NEXT PRSEP (if any) knows a
* separator now precedes whatever prints next -- this is the
* only place NEEDSP is armed; PRSEP itself only ever reads it.
* CLOBBERS: A, X, Y (via PUTS).
*---------------------------------------------------------------
PRFLD       sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #1
            sta   NEEDSP
            rts

*---------------------------------------------------------------
* PRSEP -- a single space between fields, but never before the
* FIRST one printed. NEEDSP starts at 0 (:haveflag) and is armed
* only by PRFLD, after it actually prints something -- so PRSEP
* correctly stays silent before the very first field regardless
* of WHICH field that is (S, or N/R/V/M alone under a single
* non-`-s` flag), and correctly prints before every field after
* that. BUG FIXED 2026-09-14: an earlier version armed NEEDSP
* HERE, on its own first call, instead of in PRFLD -- so the
* separator before the SECOND printed field (the common case:
* `-a`, or any two flags together) was silently skipped, e.g.
* "mauxapple2e ..." instead of "maux apple2e ...". Caught by
* check-posixutil's own '-a'/'-m -s' rows.
* CLOBBERS: A, X, Y (via PUTS on the printing path).
*---------------------------------------------------------------
PRSEP       lda   NEEDSP
            beq   :nosp
            lda   #<SPACECH
            sta   PTR0
            lda   #>SPACECH
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
:nosp       rts

USAGE       asc   "usage: uname [-snrvma]"
            dfb   $8D,$00
SPACECH     asc   " "
            dfb   0
SYSNAME     asc   "maux"
            dfb   0
NODENAME    asc   "apple2e"
            dfb   0
RELSTR      asc   "1.0"
            dfb   0
VERSTR      asc   "1.0"
            dfb   0
MACHSTR     asc   "65c02"
            dfb   0

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* uname's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*`.
* Anything emitted after `dend` would silently overlay it
* (learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - SFLAG/NFLAG/RFLAG/VFLAG/MFLAG: `stz` at START, before the
*    first :optlp read.
*  - NEEDSP: `stz` at :haveflag, before PRSEP's first read.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
SFLAG       ds    1
NFLAG       ds    1
RFLAG       ds    1
VFLAG       ds    1
MFLAG       ds    1
NEEDSP      ds    1
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
