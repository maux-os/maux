*---------------------------------------------------------------
* env.s -- run a utility in a modified environment, or print the
* environment.
*
* Usage: env [-i] [name=value ...] [utility [argument...]]
*
* NAME COLLISION CHECK (task instructions asked for it explicit-
* ly): src/liba/env.s is a `put` MODULE (GETENV/ENVNTH/ENVPASS),
* never its own build product -- the Makefile's pattern rule is
* `$(BUILD)/%.bin: $(BINSRC)/%.s`, keyed off src/bin/ alone, so
* THIS file (src/bin/env.s) is the only source that ever
* produces build/env.bin. No two `put`-able files share a dir,
* and
* merlin32 always resolves `put` by the path GIVEN (`../liba/
* env.s` here), never by bare basename. Verified by assembling
* this file standalone before landing.
*
* PER XCU env.html: consume [-i] (start from an EMPTY
* environment rather than this process's own), then as many
* `name=value` operands as look like one (a '=' anywhere but
* position 0 -- both spellings, high-bit and plain, same as
* src/liba/env.s's own GETENV), stopping at the first operand
* that is not one. If nothing is left, PRINT the resulting
* environment, one `name=value` per line, and exit 0. Otherwise
* the first non-assignment operand is UTILITY, path-resolved
* against PATH (src/liba/pathres.s, the execvp shape) exactly as
* `find -exec`/`time` do, and everything after it is its own
* argv; UTILITY's argv[0] is the word AS TYPED, not the resolved
* path (execvp's own rule -- src/bin/time.s's BUILDARGV states
* it the same way). env exits with UTILITY's own status
* unchanged
* (SC_WAIT's byte, passed straight to EXIT -- no reinterpreting
* the $80|signo convention here).
*
* ONE MERGE PASS BUILDS THE FINAL LIST, used for BOTH printing
* and spawning -- there is no separate "pass-through" shortcut
* the way src/liba/env.s's own ENVPASS is for an UNMODIFIED
* environment, because env(1) needs the SAME merged list whether
* or not a utility follows. The list (ENVLIST, this process's
* own dum arena) holds POINTERS ONLY -- every string it points
* at already lives in argv text or in the CURRENT environment
* block, neither of which env copies -- built in two passes:
*  1. every `name=value` operand, LAST-typed first (so the FIRST
*     hit in the list is the one that should survive `env A=1
*     A=2`, matching this build's own first-match GETENV/ENVNTH
*     convention rather than sorting or de-duplicating twice).
*  2. unless -i, every entry of the CURRENT environment (src/
*     liba/env.s's ENVNTH) whose name does not match any operand
*     from pass 1 (ENV_SHADOW/NAMEEQ below, the same PATH-vs-
*     PATHOLOGY-safe compare src/liba/env.s's GETENV documents).
* A duplicate operand NAME within pass 1 (`env A=1 A=2 CMD`) is
* now DE-DUPLICATED too (SHIPPED 2026-09-17, ENV_DUP): since
* pass 1 already walks LAST-typed first, the first copy ENVLIST
* ever holds for a NAME is already the last-typed value, so
* ENV_DUP simply refuses to append a NAME the list already has
* -- no re-ordering, no removal of an already-placed entry, just
* a skip on every later (earlier-typed) duplicate. Before this,
* ENV_APPND had no dedup at all: BOTH "A=2" and "A=1" ended up
* in ENVLIST, so the child's own GETENV happened to answer
* correctly (first match, A=2) but the child's own `env` (or
* this process printing with no utility) enumerated both lines,
* where a real env prints one.
*
* CAPS, NOT DYNAMIC GROWTH (no heap on this machine): ENV_MAXENT
* (48) environment entries, EA_ARGVMAX (32) child argv words,
* each refused with a diagnostic and exit 1 rather than silently
* truncated -- the SAME posture time.s's BUILDARGV/TM_ARGVMAX
* already takes. Below either cap, the KERNEL may still refuse a
* spawn with ERR_2BIG (the environment or argv exceeds
* ARGV_PTR_LIM/ARG_MAX, inc/memmap.equ) -- that comes back
* from SC_SPAWN itself and is reported the same way sh.s's own
* ERR_2BIG decode is (shblt2.s), exit 1, not the generic
* "cannot execute" exit 126.
*
* EXIT STATUS (POSIX env.html, and matched to this tree's own
* sh(1)/xargs(1) convention): 0 on success (including "printed
* the environment"); 1 on a usage error, an overflow of either
* cap above, or a kernel ERR_2BIG; 126 if UTILITY was found but
* could not be run; 127 if UTILITY could not be found at all.
* "Found but not executable" is not a distinguishable failure on
* this machine (ProDOS has no execute permission bit separate
* from OPEN succeeding) -- 126 here means "PATH-resolved, but
* SC_SPAWN itself refused it for a reason other than ERR_2BIG",
* which is as close as this build gets (KNOWN_GAPS row).
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/errno.spawn.equ
            org   LOAD_BASE
            dsk   ../../build/env.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

ENV_MAXENT  equ   48                ;env list cap, see header
EA_ARGVMAX  equ   32                ;child argv cap, see header

START       stz   ENV_IFLG
            lda   #<OPTLIST
            ldx   #>OPTLIST
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$E9               ;'i' high-bit
            beq   :iflag
            jmp   :usage             ;'?' or anything else
:iflag      lda   #1
            sta   ENV_IFLG
            bra   :optlp
:optdone

*-- scan forward from OPTIND: as many NAME=VALUE operands as
*-- look like one; ENV_UIDX ends at the first that does not (or
*-- at ARGC if every remaining operand was one).
            lda   OPTIND
            sta   ENV_ABAS
            sta   ENV_SCAN
:asnlp      lda   ENV_SCAN
            cmp   ARGC
            bcs   :asndone
            jsr   ISASSIGN
            bcs   :asndone
            inc   ENV_SCAN
            bra   :asnlp
:asndone    lda   ENV_SCAN
            sta   ENV_UIDX
            sec
            sbc   ENV_ABAS
            sta   ENV_ACNT

*-- pass 1: operands, LAST-typed first.
            stz   ENV_ECNT
            lda   ENV_ACNT
            sta   ENV_AI
:aaddlp     lda   ENV_AI
            beq   :aadded
            dec   ENV_AI
            lda   ENV_ABAS
            clc
            adc   ENV_AI
            jsr   GETARG
            jsr   ENV_DUP
            bcs   :aok               ;NAME already placed
                                     ;(from a later-typed
                                     ;instance) -- this one
                                     ;loses, unplaced
            jsr   ENV_APPND
            bcc   :aok
            jmp   :envfull
:aok        bra   :aaddlp
:aadded

*-- pass 2: the current environment, unless -i, skipping any
*-- name pass 1 already placed.
            lda   ENV_IFLG
            bne   :olddone
            stz   ENV_EI
:oldlp      lda   ENV_EI
            jsr   ENVNTH
            bcs   :olddone
            jsr   ENV_SHDW
            bcs   :oldskip
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            jsr   ENV_APPND
            bcc   :oldskip
            jmp   :envfull
:oldskip    inc   ENV_EI
            bra   :oldlp
:olddone

*-- terminate the list.
            lda   ENV_ECNT
            asl   a
            tax
            stz   ENVLIST,x
            stz   ENVLIST+1,x

            lda   ENV_UIDX
            cmp   ARGC
            bcc   :spawn
            jmp   :print

*---------------------------------------------------------------
* :print -- no utility operand: the built list, one entry per
* line, to stdout.
*---------------------------------------------------------------
:print      stz   PM_I
:pmlp       lda   PM_I
            cmp   ENV_ECNT
            bcs   :pmdone
            asl   a
            tax
            lda   ENVLIST,x
            sta   PTR0
            lda   ENVLIST+1,x
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   PM_I
            bra   :pmlp
:pmdone     lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* :spawn -- ENV_UIDX names the utility; resolve, build its argv,
* spawn with ENVLIST as its environment, wait, exit with its
* status.
*---------------------------------------------------------------
:spawn      lda   ENV_UIDX
            jsr   GETARG              ;PTR0 = the word as typed
            lda   PTR0
            sta   ENV_ORGW
            lda   PTR0+1
            sta   ENV_ORGW+1
            jsr   PATHRSLV
            bcc   :found
            jmp   :notfound
:found      lda   PTR0
            sta   ENV_PATH
            lda   PTR0+1
            sta   ENV_PATH+1

            lda   ENV_ORGW
            sta   ARGVLIST
            lda   ENV_ORGW+1
            sta   ARGVLIST+1
            lda   ENV_UIDX
            clc
            adc   #1
            sta   ENV_AI2
            lda   #1
            sta   ENV_NI
:cvlp       lda   ENV_AI2
            cmp   ARGC
            bcs   :cvdone
            lda   ENV_NI
            cmp   #EA_ARGVMAX
            bcc   :cvok
            jmp   :toomany
:cvok       lda   ENV_AI2
            jsr   GETARG
            lda   ENV_NI
            asl   a
            tax
            lda   PTR0
            sta   ARGVLIST,x
            lda   PTR0+1
            sta   ARGVLIST+1,x
            inc   ENV_NI
            inc   ENV_AI2
            bra   :cvlp
:cvdone     lda   ENV_NI
            asl   a
            tax
            stz   ARGVLIST,x
            stz   ARGVLIST+1,x

            lda   ENV_PATH
            sta   PTR0
            lda   ENV_PATH+1
            sta   PTR0+1
            lda   #<ARGVLIST
            sta   PTR1
            lda   #>ARGVLIST
            sta   PTR1+1
            stz   PTR2
            stz   PTR2+1              ;NULL fdactions -- inherit
                                       ;fd 0/1/2
            lda   #<ENVLIST
            sta   SPWN_ENVP
            lda   #>ENVLIST
            sta   SPWN_ENVP+1
            jsr   SC_SPAWN
            bcs   :spawnerr
            lda   #<WSTATUS
            sta   PTR0
            lda   #>WSTATUS
            sta   PTR0+1
            jsr   SC_WAIT
            lda   WSTATUS              ;transparent, see header
            jsr   EXIT

:spawnerr   cmp   #ERR_2BIG
            beq   :toolarge
            ldx   #<ENVSPFX
            ldy   #>ENVSPFX
            jsr   SPAWNWHY               ;A = the errno still
            bcc   :cantexec              ;no bank, no file slot:
            lda   #126                   ;say so. 126: found,
            jsr   EXIT                   ;could not be run (man)
:cantexec   lda   #<CANTEXEC1
            sta   PTR0
            lda   #>CANTEXEC1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ENV_ORGW
            sta   PTR0
            lda   ENV_ORGW+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<CANTEXEC2
            sta   PTR0
            lda   #>CANTEXEC2
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #126
            jsr   EXIT

:notfound   lda   #<NOTFOUND1
            sta   PTR0
            lda   #>NOTFOUND1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ENV_ORGW
            sta   PTR0
            lda   ENV_ORGW+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<NOTFOUND2
            sta   PTR0
            lda   #>NOTFOUND2
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #127
            jsr   EXIT

:toolarge   lda   #<TOOLARGEM
            sta   PTR0
            lda   #>TOOLARGEM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:toomany    lda   #<TOOMANYMS
            sta   PTR0
            lda   #>TOOMANYMS
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:envfull    lda   #<ENVFULLMS
            sta   PTR0
            lda   #>ENVFULLMS
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
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
* ISASSIGN -- IN: A = argv index. OUT: carry CLEAR if that word
* is a NAME=VALUE operand (a '=', either spelling, at an offset
* other than 0); carry SET otherwise. PTR0 = the word either
* way (GETARG's own side effect). CLOBBERS: A, Y, PTR0.
*---------------------------------------------------------------
ISASSIGN    jsr   GETARG
            ldy   #0
:ialp       lda   (PTR0),y
            beq   :iano
            cmp   #ENV_EQHI
            beq   :iahit
            cmp   #ENV_EQLO
            beq   :iahit
            iny
            bne   :ialp
            bra   :iano               ;255 bytes, no '=' -- no
:iahit      cpy   #0
            beq   :iano               ;'=' first -- empty name
            clc
            rts
:iano       sec
            rts

*---------------------------------------------------------------
* NAMEEQ -- IN: PTR0, PTR1 = two NAME=VALUE strings. OUT: carry
* CLEAR if their NAME halves match exactly (both hit '=', either
* spelling, at the same offset, every byte before it equal);
* carry SET otherwise. The PATH-vs-PATHOLOGY case (one name a
* strict prefix of the other) mismatches because the SHORTER
* one's '=' byte is compared against the LONGER one's ordinary
* character at that offset -- never equal. CLOBBERS: A, Y.
*---------------------------------------------------------------
NAMEEQ      ldy   #0
:nelp       lda   (PTR0),y
            sta   NE_TMP
            lda   (PTR1),y
            cmp   NE_TMP
            bne   :nemis
            lda   NE_TMP
            cmp   #ENV_EQHI
            beq   :nehit
            cmp   #ENV_EQLO
            beq   :nehit
            iny
            bne   :nelp
            bra   :nemis              ;255 bytes, defensive
:nehit      clc
            rts
:nemis      sec
            rts

*---------------------------------------------------------------
* ENV_SHDW -- IN: PTR1 = a current-environment entry. OUT: carry
* SET if its NAME matches one of the ENV_ACNT operands at
* ENV_ABAS.. (shadowed -- do not re-add it); carry CLEAR
* otherwise. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
ENV_SHDW    stz   ES_K
:eslp       lda   ES_K
            cmp   ENV_ACNT
            bcs   :esno
            lda   ENV_ABAS
            clc
            adc   ES_K
            jsr   GETARG
            jsr   NAMEEQ
            bcc   :esyes
            inc   ES_K
            bra   :eslp
:esyes      sec
            rts
:esno       clc
            rts

*---------------------------------------------------------------
* ENV_DUP -- IN: PTR0 = a candidate NAME=VALUE operand. OUT:
* carry SET if its NAME already appears somewhere in
* ENVLIST[0..ENV_ECNT) -- pass 1 walks LAST-typed first, so if
* the list already holds this NAME, that copy is the last-typed
* one and THIS (earlier-typed) copy must not be added; carry
* CLEAR otherwise (append it). CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
ENV_DUP     stz   ED_K
:edlp       lda   ED_K
            cmp   ENV_ECNT
            bcs   :edno
            lda   ED_K
            asl   a
            tax
            lda   ENVLIST,x
            sta   PTR1
            lda   ENVLIST+1,x
            sta   PTR1+1
            jsr   NAMEEQ
            bcc   :edyes
            inc   ED_K
            bra   :edlp
:edyes      sec
            rts
:edno       clc
            rts

*---------------------------------------------------------------
* ENV_APPND -- IN: PTR0 = a pointer to append to ENVLIST. OUT:
* carry SET if ENV_MAXENT is already reached (ENVLIST left
* untouched).
* CLOBBERS: A, X.
*---------------------------------------------------------------
ENV_APPND   lda   ENV_ECNT
            cmp   #ENV_MAXENT
            bcs   :eafull
            asl   a
            tax
            lda   PTR0
            sta   ENVLIST,x
            lda   PTR0+1
            sta   ENVLIST+1,x
            inc   ENV_ECNT
            clc
            rts
:eafull     sec
            rts

OPTLIST     asc   "i"
            dfb   0
USAGEMSG    asc   "usage: env [-i] [name=value ...] "
            asc   "[utility [argument...]]"
            dfb   $8D,$00
TOOLARGEM   asc   "env: environment too large"
            dfb   $8D,$00
TOOMANYMS   asc   "env: argument list too long"
            dfb   $8D,$00
ENVFULLMS   asc   "env: too many environment variables"
            dfb   $8D,$00
NOTFOUND1   asc   "env: "
            dfb   $00
NOTFOUND2   asc   ": not found"
            dfb   $8D,$00
ENVSPFX     asc   'env: '
            dfb   0
CANTEXEC1   asc   "env: "
            dfb   $00
CANTEXEC2   asc   ": cannot execute"
            dfb   $8D,$00

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/spawnwhy.s
            put   ../liba/pathtab.s
            put   ../liba/pathres.s
            put   ../liba/env.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* env's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - ENV_IFLG: `stz`'d as START's FIRST instruction, before the
*    option loop that may set it -- the pass-2 `bne :olddone`
*    reader would otherwise see the `dum` arena's leftover byte
*    on a warm respawn (the same trap printf.s's USAGEMSG
*    placement was).
*  - ENV_ABAS/ENV_SCAN/ENV_UIDX/ENV_ACNT/ENV_AI/ENV_ECNT/ENV_EI:
*    each written before its own first read, in argv-scan order.
*  - PM_I: `stz`'d at :print, the only reader.
*  - ENV_ORGW/ENV_PATH/ENV_AI2/ENV_NI: written on the :spawn
*    path only, each before its own reader.
*  - NE_TMP/ES_K: NAMEEQ/ENV_SHDW's own first stores.
*  - ENVLIST/ARGVLIST: filled pointer-by-pointer, read only up
*    to the count that filled them.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ENV_IFLG    ds    1
ENV_ABAS    ds    1
ENV_SCAN    ds    1
ENV_UIDX    ds    1
ENV_ACNT    ds    1
ENV_AI      ds    1
ENV_ECNT    ds    1
ENV_EI      ds    1
PM_I        ds    1
ENV_ORGW    ds    2
ENV_PATH    ds    2
ENV_AI2     ds    1
ENV_NI      ds    1
NE_TMP      ds    1
ES_K        ds    1
ED_K        ds    1
WSTATUS     ds    1
ENVLIST     ds    ENV_MAXENT*2+2
ARGVLIST    ds    EA_ARGVMAX*2+2
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
