*---------------------------------------------------------------
* stty.s -- report or set THIS console's terminal mode.
*
* Usage: stty                 report the current mode
*        stty raw             clear ICANON (no line/erase/kill)
*        stty -raw            set ICANON back (cooked line)
*        stty echo            set ECHO (paint typed bytes)
*        stty -echo           clear ECHO
*        stty opost           set OPOST (CR is a newline, VT102
*                              slice 1 -- docs/CONSOLE-VT102.md
*                              sec 3)
*        stty -opost          clear OPOST (strict VT102: CR only
*                              moves the column; LF still
*                              indexes,
*                              maux's own deviation)
*        stty sane            cooked default: ICANON+ECHO+OPOST
* Verbs may combine, e.g. `stty raw -echo` -- vi's target mode.
* Order within one invocation does not matter; each verb is a
* bit op against the CURRENT mode, applied in ONE commit so no
* half-changed state is ever visible to a tick mid-typing.
*
* CONTRACT (stty seed, docs -- SYS_TTYMODE, inc/syscall-
* proc.equ): TWO orthogonal bits only, ICANON and ECHO -- not
* V7's full raw-no-signal ladder (^C stays a signal in every
* mode; see tty3.s TTY_INTR, which this never touches). The
* SETTER is SC_TTYMODE(fd, newflags), which returns the
* PREVIOUS flags -- there is no separate GET call, so a bare
* `stty` (or a `stty raw` that must preserve the OTHER bit)
* probes with a harmless placeholder and immediately restores
* or overwrites it in the very next call; the console is never
* left holding the placeholder.
*
* A stdout that is not a console (file, pipe) is refused on
* stderr, exit 1 -- same GEOPROBE-style check vidmode.s uses,
* against SC_TTYMODE instead of SC_TTYGEO.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address, no
* kernel equates; see docs/USERLAND.md.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/stty.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

NOT_ICANON  equ   254         ;~TMD_ICANON
NOT_ECHO    equ   253         ;~TMD_ECHO
NOT_OPOST   equ   251         ;~TMD_OPOST -- three bits now

START       lda   ARGC
            cmp   #7                   ;program name + up to 5
            bcc   :argszok              ;verbs is plenty of room
            jmp   :usage
:argszok
* -- probe: a placeholder set() whose ONLY job is to hand back
* -- the real current mode in A. The cooked default (ICANON+
* -- ECHO+OPOST) is the safest possible momentary value to leave
* -- behind if a key lands in the gap before the restore/commit
* -- below.
            lda   #FD_STDOUT
            ldx   #TMD_ICANON+TMD_ECHO+TMD_OPOST
            jsr   SC_TTYMODE
            bcc   :probeok
            jmp   :ttyerr
:probeok    sta   OLDVAL
            sta   NEWVAL
            stz   SAWANY
            lda   #1
            sta   ARGN
:argloop    lda   ARGN
            cmp   ARGC
            bcc   :haveargn
            jmp   :parsed
:haveargn   jsr   GETARG                ;-> PTR0 = argv[ARGN]
            lda   #<AWRAW
            sta   PTR1
            lda   #>AWRAW
            sta   PTR1+1
            jsr   STRCMPI
            bne   :tnraw
            lda   NEWVAL
            and   #NOT_ICANON
            sta   NEWVAL
            jmp   :hit
:tnraw      lda   #<AWNRAW
            sta   PTR1
            lda   #>AWNRAW
            sta   PTR1+1
            jsr   STRCMPI
            bne   :techo
            lda   NEWVAL
            ora   #TMD_ICANON
            sta   NEWVAL
            jmp   :hit
:techo      lda   #<AWECHO
            sta   PTR1
            lda   #>AWECHO
            sta   PTR1+1
            jsr   STRCMPI
            bne   :tnecho
            lda   NEWVAL
            ora   #TMD_ECHO
            sta   NEWVAL
            jmp   :hit
:tnecho     lda   #<AWNECHO
            sta   PTR1
            lda   #>AWNECHO
            sta   PTR1+1
            jsr   STRCMPI
            bne   :topost
            lda   NEWVAL
            and   #NOT_ECHO
            sta   NEWVAL
            jmp   :hit
:topost     lda   #<AWOPOST
            sta   PTR1
            lda   #>AWOPOST
            sta   PTR1+1
            jsr   STRCMPI
            bne   :tnopost
            lda   NEWVAL
            ora   #TMD_OPOST
            sta   NEWVAL
            jmp   :hit
:tnopost    lda   #<AWNOPOST
            sta   PTR1
            lda   #>AWNOPOST
            sta   PTR1+1
            jsr   STRCMPI
            bne   :tsane
            lda   NEWVAL
            and   #NOT_OPOST
            sta   NEWVAL
            jmp   :hit
:tsane      lda   #<AWSANE
            sta   PTR1
            lda   #>AWSANE
            sta   PTR1+1
            jsr   STRCMPI
            beq   :saneok
            jmp   :usage
:saneok     lda   #TMD_ICANON+TMD_ECHO+TMD_OPOST
            sta   NEWVAL
:hit        lda   #1
            sta   SAWANY
            inc   ARGN
            jmp   :argloop

:parsed     lda   SAWANY
            bne   :commit
* -- bare report: restore the placeholder to the TRUE prior
* -- value (NEWVAL == OLDVAL here -- no verb touched it) and
* -- print it.
            lda   #FD_STDOUT
            ldx   NEWVAL
            jsr   SC_TTYMODE
            bcs   :ttyerr
            jsr   PRMODE
            lda   #0
            jmp   EXIT

:commit     lda   #FD_STDOUT
            ldx   NEWVAL
            jsr   SC_TTYMODE
            bcs   :ttyerr
            lda   #0
            jmp   EXIT

:ttyerr     lda   #<NOTTYMSG
            ldx   #>NOTTYMSG
            jsr   ERRLINE
            lda   #1
            jmp   EXIT

:usage      lda   #<USAGEMSG
            ldx   #>USAGEMSG
            jsr   ERRLINE
            lda   #2
            jmp   EXIT

*---------------------------------------------------------------
* PRMODE -- print "icanon echo" / "-icanon echo" / ... + CR,
* from OLDVAL. A leading '-' means the bit is CLEAR, V7's own
* stty(1) convention.
*---------------------------------------------------------------
PRMODE      lda   OLDVAL
            and   #TMD_ICANON
            bne   :ic1
            jsr   PRDASH
:ic1        lda   #<MICANON
            sta   PTR0
            lda   #>MICANON
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$A0                 ;space
            jsr   PUTOUT
            lda   OLDVAL
            and   #TMD_ECHO
            bne   :ec1
            jsr   PRDASH
:ec1        lda   #<MECHO
            sta   PTR0
            lda   #>MECHO
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$A0                 ;space
            jsr   PUTOUT
            lda   OLDVAL
            and   #TMD_OPOST
            bne   :op1
            jsr   PRDASH
:op1        lda   #<MOPOST
            sta   PTR0
            lda   #>MOPOST
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            jsr   PUTOUT
            rts

PRDASH      lda   #$AD                 ;'-'
            jmp   PUTOUT

PUTOUT      ldx   #FD_STDOUT
            jsr   PUTC
            rts

*-- ERRLINE -- NUL string at A/X to stderr, plus CR.
ERRLINE     sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            rts

AWRAW       asc   "RAW"
            dfb   $00
AWNRAW      asc   "-RAW"
            dfb   $00
AWECHO      asc   "ECHO"
            dfb   $00
AWNECHO     asc   "-ECHO"
            dfb   $00
AWOPOST     asc   "OPOST"
            dfb   $00
AWNOPOST    asc   "-OPOST"
            dfb   $00
AWSANE      asc   "SANE"
            dfb   $00
MICANON     asc   "ICANON"
            dfb   $00
MECHO       asc   "ECHO"
            dfb   $00
MOPOST      asc   "OPOST"
            dfb   $00
USAGEMSG    asc   "usage: stty [raw|-raw] [echo|-echo] "
            asc   "[opost|-opost] [sane]"
            dfb   $00
NOTTYMSG    asc   "stty: stdout is not a console"
            dfb   $00

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

            dum   LIBA_BSSEND
OLDVAL      ds    1
NEWVAL      ds    1
SAWANY      ds    1
ARGN        ds    1
            err   */$BF00
            dend
