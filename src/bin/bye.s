*---------------------------------------------------------------
* bye.s -- suspend maux, round-trip through a real ProDOS MLI
* QUIT, come back -- optionally launching a real .SYSTEM program
* on the machine handed over (docs/BYE.md "Slice 2 launch").
*
* Usage: bye
*        bye PATH.SYSTEM
*
* WHAT IT IS FOR. docs/BYE.md: true testing of a ProDOS program
* actually needs a real ProDOS 8, not the proshim, and today
* that means rebooting. `bye` is the return half of that loop --
* slice 1 proved the round trip with no program run; slice 2
* actually launches one.
*
* THE SPLIT WITH THE KERNEL. Same shape as `shutdown`: this
* program owns the words and nothing else. Every resource that
* has to be given up and reclaimed -- the periodic interrupt,
* main memory itself, the language card -- belongs to the
* kernel, so SYS_BYE (PRC_BYE, src/kernel/procbye.s) does the
* work and this only announces it.
*
* THE TYPE ($FF) AND SIZE (<= $7800) CHECKS ARE HERE, IN
* USERLAND, NOT IN THE KERNEL. MEASURED, not stylistic: a
* kernel-side GET_FILE_INFO+OPEN+GET_EOF+CLOSE check cost ~130 B
* of procbye.s's own image, which that file's PT_HOLD headroom
* (77 B before this slice) could not spare -- see procbye.s's
* own comment. liba already has SC_GFI/SC_OPEN/LSEEK/SC_CLOSE
* (src/liba/seek.s), so refusing here costs this program's own
* arena, not the kernel's, and no destructive round trip is even
* attempted for a bad file. TOCTOU CAVEAT: the file could change
* between this check and the launch (byelaunch.s, post-poison,
* has no clean way to report a refusal); accepted for a
* single-user dev tool, and byelaunch.s's own read loop stops
* at PMLI_IBF_BASE ($A000) regardless, so a grown file is
* truncated, not corrupting.
*
* UNLIKE `shutdown`, THIS CALL RETURNS. SC_HALT never comes
* back; SC_BYE always does, with A = 0 (success) or carry set
* and a real errno, once the machine has saved itself, destroyed
* itself, QUIT (and, with a path, run the named program), and
* restored itself. So the farewell and welcome-back messages are
* two separate PUTS calls around the one `jsr SC_BYE`, not a
* single message printed before a call that never returns.
*
* EXIT STATUS. 0 on the round trip completing. 2 for a usage
* error (more than one operand) or a refused PATH (not a
* .SYSTEM, or too large, printed with a reason). 1 if SC_BYE
* itself reports carry set -- the pinned-open-file refusal
* (docs/BYE.md item 2) names the OFT index; anything else prints
* the raw errno.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/bye.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- BYE_PIN_LO/HI: NOT put from inc/errno.krn.equ (that file's
* -- own header: "used ONLY inside src/kernel/*.s" -- a userland
* -- `put` would make that claim stale). PRC_BYE (procbye.s)
* -- encodes a pinned OFT index (1-15, OFT_COUNT=16, inc/
* -- mm.annex2.equ) as ERR_BYEPIN+index rather than a separate
* -- result field -- MEASURED cheaper against that file's own
* -- PT_HOLD headroom (see its own PBY_PARK_ALL comment). These
* -- two plain literals are the userland side of that same
* -- numeric contract; if ERR_BYEPIN ($EA) ever moves, both
* -- sides need updating together.
* -- LPE_NOSAVED ($D7): the kernel's "`bye` left no loop to
* -- re-attach" (inc/mm.lseg.equ; a kernel header, so literal
* -- here, as mount's reason table does for $D1-$D6).
LPE_NOSAVED equ   $D7
LOOPUNIT    equ   $B0              ;the loop's ON_LINE unit
NMSLASH     equ   $AF              ;'/' as the kernel names it
NMQUERY     equ   $BF              ;'?', no volume's name
CRCHAR      equ   $8D
BYE_PIN_LO  equ   $EA
BYE_PIN_HI  equ   $F9

START       lda   ARGC
            cmp   #1
            bne   :notbare
            jmp   BARE
:notbare    cmp   #2
            beq   WITHPATH
            jmp   USAGE

*---------------------------------------------------------------
* WITHPATH -- a tenant was named: build its MLI pathname, refuse
* it in userland if it is not a real .SYSTEM file or would
* overrun the launch's read window, else fall into GO with
* BYEPTR pointing at it.
*---------------------------------------------------------------
WITHPATH    lda   #1
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH

* -- type check: GET_FILE_INFO, refuse anything but $FF.
            lda   #PCOUNT_GFI
            sta   GFIPARM
            lda   #<PATHBUF
            sta   GFIPARM_PATH
            lda   #>PATHBUF
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   GFIOK
            jmp   OPENERR
GFIOK       lda   GFIPARM_FTYP
            cmp   #FTYPE_SYS
            beq   TYPEOK
            jmp   TYPEERR
TYPEOK

* -- size check: OPEN, LSEEK(SEEK_END), CLOSE -- refuse > $7800
* -- (docs/BYE.md item 4: the pool base was $9800 minus
* -- TENANT_ORG $2000; B1 moved it to $A000 and kept $7800).
            lda   #PCOUNT_OPEN
            sta   OPARM
            lda   #<PATHBUF
            sta   OPARM_PATH
            lda   #>PATHBUF
            sta   OPARM_PATH+1
            stz   OPARM_IOBUF
            stz   OPARM_IOBUF+1
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   OPENOK2
            jmp   OPENERR
OPENOK2     stz   SEEKBUF
            stz   SEEKBUF+1
            stz   SEEKBUF+2
            lda   #<SEEKBUF
            sta   PTR0
            lda   #>SEEKBUF
            sta   PTR0+1
            lda   OPARM_REF
            ldy   #SEEK_END
            jsr   LSEEK
            pha
            lda   OPARM_REF
            sta   CPARM_REF
            lda   #PCOUNT_CLOSE
            sta   CPARM
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            pla
            bcc   :szclose
            jmp   OPENERR
:szclose
* -- SEEKBUF now holds the EOF, 3 bytes little-endian. Refuse
* -- unless SEEKBUF+2=0 and SEEKBUF+1:0 <= $7800.
            lda   SEEKBUF+2
            bne   :szbig
            lda   SEEKBUF+1
            cmp   #$78
            bcc   :szok
            bne   :szbig
            lda   SEEKBUF
            beq   :szok
:szbig      jmp   TOOBIG
:szok       lda   #<PATHBUF
            sta   BYEPTR
            lda   #>PATHBUF
            sta   BYEPTR+1
            bra   GO

BARE        stz   BYEPTR
            stz   BYEPTR+1

*---------------------------------------------------------------
* GO -- BYEPTR set (0/0 for a bare `bye`, or PATHBUF for a
* tenant) -- print the farewell, flush, call SC_BYE, report.
*---------------------------------------------------------------
GO          lda   #<LEAVEMSG
            sta   PTR0
            lda   #>LEAVEMSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            jsr   SIO_FLUSHALL    ;SAY IT BEFORE YOU DO IT --
                                  ;the glass is about to belong
                                  ;to a real ProDOS QUIT a while
            lda   BYEPTR
            sta   PTR0
            lda   BYEPTR+1
            sta   PTR0+1
            jsr   SC_BYE
            bcc   BYEOK
            jmp   BYEFAIL
BYEOK       lda   #<BACKMSG
            sta   PTR0
            lda   #>BACKMSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
*-- a loop that was attached (S4)
            jmp   REATTACH

*---------------------------------------------------------------
* BYEFAIL -- SC_BYE returned carry set. A pinned-fd errno (docs/
* BYE.md item 2) names the OFT index; anything else prints the
* raw code. Neither the farewell nor a welcome-back message
* apply -- the round trip never happened.
*---------------------------------------------------------------
BYEFAIL     cmp   #BYE_PIN_LO
            bcc   RAWERR
            cmp   #BYE_PIN_HI+1
            bcs   RAWERR
            sec
            sbc   #BYE_PIN_LO
            jmp   PINFDMSG
RAWERR      pha
            lda   #<RAWMSG1
            sta   PTR0
            lda   #>RAWMSG1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            pla
            jsr   PRHEX2
            lda   #<RAWMSG2
            sta   PTR0
            lda   #>RAWMSG2
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jmp   EXIT

*---------------------------------------------------------------
* PINFDMSG -- A = the pinned OFT index (1-15). Print "bye: fd N
* is open (relatively) and cannot be parked" -- N as 1 or 2
* plain decimal digits (OFT_COUNT is 16, so N never exceeds 15).
*---------------------------------------------------------------
PINFDMSG    sta   PINNUM
            lda   #<PINMSG1
            sta   PTR0
            lda   #>PINMSG1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #0
            sta   PINTENS
            lda   PINNUM
            cmp   #10
            bcc   :ones
            sec
            sbc   #10
            sta   PINNUM
            inc   PINTENS
:ones       lda   PINTENS
            beq   :printones
            clc
            adc   #"0"
            sta   PINDIGS
            bra   :havetens
:printones  lda   #" "
            sta   PINDIGS
:havetens   lda   PINNUM
            clc
            adc   #"0"
            sta   PINDIGS+1
            lda   #<PINDIGS
            sta   PTR0
            lda   #>PINDIGS
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<PINMSG2
            sta   PTR0
            lda   #>PINMSG2
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jmp   EXIT

*---------------------------------------------------------------
* REATTACH -- the machine is back. If `bye` took a loop image
* away (the kernel keeps the record, SYS_VROOT op 4 with bit 1),
* attach it again; the tenant may have changed or deleted it, so
* anything the attach refuses, or that is no longer a ProDOS
* volume, is reported and left unmounted. Nothing recorded
* ($D7) is silence and exit 0.
*---------------------------------------------------------------
REATTACH    lda   #4
            sta   VPARM
            lda   #<ANYPATH
            sta   VPARM+1
            lda   #>ANYPATH
            sta   VPARM+2
            lda   #2
            sta   VPARM+3
            lda   #<VPARM
            ldx   #>VPARM
            jsr   SC_BVROOT
            bcc   :att
            cmp   #LPE_NOSAVED
            bne   LOOPERR
            lda   #0
            jmp   EXIT
*-- is it still a ProDOS volume?
:att        lda   #2
            sta   OLPARM
            lda   #LOOPUNIT
            sta   OLPARM+1
            lda   #<ONBUF
            sta   OLPARM+2
            lda   #>ONBUF
            sta   OLPARM+3
            lda   #<OLPARM
            ldx   #>OLPARM
            jsr   SC_BONLINE
            bcs   :gone
            lda   ONBUF
            and   #$0F
            bne   :ok
            lda   ONBUF+1
*-- detach it again: op 2 on $B0,
:gone       pha
*-- named "/?" (not a real volume)
            lda   #2
            sta   NMLP
            lda   #NMSLASH
            sta   NM
            lda   #NMQUERY
            sta   NM+1
            lda   #2
            sta   VPARM
            lda   #<NMLP
            sta   VPARM+1
            lda   #>NMLP
            sta   VPARM+2
            lda   #LOOPUNIT
            sta   VPARM+3
            lda   #<VPARM
            ldx   #>VPARM
            jsr   SC_BVROOT
            pla
            cmp   #0
            bne   LOOPERR
*-- no name at all: not a volume
            lda   #$52
            bra   LOOPERR
:ok         lda   #0
            jmp   EXIT

*-- "bye: loop device: <reason>" to stderr, exit 1. A = the
*-- code.
LOOPERR     pha
            lda   #<LOOPMSG
            sta   PTR0
            lda   #>LOOPMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            pla
            ldx   #0
:t          ldy   LREASON,x         ;code, pointer; 0 ends
            beq   :hex
            cmp   LREASON,x
            beq   :found
            inx
            inx
            inx
            bra   :t
:found      lda   LREASON+1,x
            sta   PTR0
            lda   LREASON+2,x
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jmp   EXIT
:hex        pha
            lda   #<LHEXMSG
            sta   PTR0
            lda   #>LHEXMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            pla
            jsr   PRHEX2
            lda   #CRCHAR
            sta   HEXBUF
            stz   HEXBUF+1
            lda   #<HEXBUF
            sta   PTR0
            lda   #>HEXBUF
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jmp   EXIT


*---------------------------------------------------------------
* PRHEX2 -- print A as two ASCII hex digits to stderr.
*---------------------------------------------------------------
PRHEX2      pha
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            jsr   :nyb
            pla
            and   #$0F
:nyb        cmp   #10
            bcc   :dig
            clc
            adc   #"A"-10
            bra   :out
:dig        clc
            adc   #"0"
:out        sta   HEXBUF
            lda   #<HEXBUF
            sta   PTR0
            lda   #>HEXBUF
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

TYPEERR     lda   #<TYPEMSG
            sta   PTR0
            lda   #>TYPEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jmp   EXIT

TOOBIG      lda   #<BIGMSG
            sta   PTR0
            lda   #>BIGMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jmp   EXIT

OPENERR     lda   #<OPENMSG
            sta   PTR0
            lda   #>OPENMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jmp   EXIT

USAGE       lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jmp   EXIT

LEAVEMSG    asc   "Leaving maux for ProDOS..."
            dfb   $8D,$00
BACKMSG     asc   "Welcome back."
            dfb   $8D,$00
USAGEMSG    asc   "usage: bye [PATH.SYSTEM]"
            dfb   $8D,$00
TYPEMSG     asc   "bye: not a .SYSTEM file (type $FF)"
            dfb   $8D,$00
BIGMSG      asc   "bye: too large for the launch window"
            dfb   $8D,$00
OPENMSG     asc   "bye: cannot open that file"
            dfb   $8D,$00
PINMSG1     asc   "bye: fd"
            dfb   $00
PINMSG2     asc   " is open (relatively) and cannot be"
            asc   " parked"
            dfb   $8D,$00
ANYPATH     dfb   4                 ;a path the kernel can
            asc   '/bin'            ;translate; unread (flag 2)
LOOPMSG     asc   "bye: loop device: "
            dfb   $00
LHEXMSG     asc   "error $"
            dfb   $00
LR46        asc   "no such file"
            dfb   $8D,$00
LR52        asc   "not a ProDOS volume"
            dfb   $8D,$00
LRD1        asc   "sparse image (holes below EOF)"
            dfb   $8D,$00
LRD3        asc   "not a tree file"
            dfb   $8D,$00
LREASON     dfb   $46
            da    LR46
            dfb   $52
            da    LR52
            dfb   $D1
            da    LRD1
            dfb   $D3
            da    LRD3
            dfb   0
RAWMSG1     asc   "bye: errno $"
            dfb   $00
RAWMSG2     asc   " -- cannot leave"
            dfb   $8D,$00

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/seek.s
            put   ../liba/syscalls.s
            put   ../liba/sysvroot.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* bye's bss -- anchored at LIBA_BSSEND, same trailer shape as
* proshim.s's own arena.
*  - PATHBUF: written whole by MKPATH before use.
*  - GFIPARM/OPARM/CPARM: constants stored above before each
*    call; result fields written by the kernel.
*  - SEEKBUF: zeroed before LSEEK, then holds the EOF.
*  - BYEPTR: the pointer SC_BYE reads (PTR0), set on both paths.
*  - PINNUM/PINTENS/PINDIGS/HEXBUF: BYEFAIL's own scratch.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
PATHBUF     ds    65
GFIPARM     ds    1
GFIPARM_PATH ds   2
GFIPARM_ACC ds    1
GFIPARM_FTYP ds   1
            ds    13            ;aux_type..create_time, unread
OPARM       ds    1
OPARM_PATH  ds    2
OPARM_IOBUF ds    2
OPARM_REF   ds    1
CPARM       ds    1
CPARM_REF   ds    1
SEEKBUF     ds    3
BYEPTR      ds    2
PINNUM      ds    1
PINTENS     ds    1
PINDIGS     ds    2
HEXBUF      ds    2
VPARM       ds    4
OLPARM      ds    4
ONBUF       ds    16
NMLP        ds    1
NM          ds    3
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
