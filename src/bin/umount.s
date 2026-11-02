*---------------------------------------------------------------
* umount.s -- unmount a volume.
*
* Usage: umount /mnt/NAME
*        umount /dev/sNdM
*
* A mounted Disk ][ goes back to being invisible: gone from
* /mnt, df and `mount`, and not read again by anything until
* it is mounted again. Refused (exit 1, "busy") while a file
* on the volume is open or parked, a process has its working
* directory on it, or a block device on the unit is open; the
* boot volume never goes. A fast unit (SmartPort, hard disk)
* cannot be unmounted ("not a mountable unit"). docs/VROOT.md.
*
* /dev/sNdM names the unit directly. /mnt/NAME is found by
* reading, with ONE ON_LINE each, the units the kernel already
* lists as mounted -- an unmounted Disk ][ is never polled.
*
* Exit: 0 ok, 1 failed, 2 usage.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/umount.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/readdir.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   #<PROGNAME
            sta   MNT_PROG
            lda   #>PROGNAME
            sta   MNT_PROG+1
            lda   ARGC
            cmp   #2
            beq   :argc
            jmp   USAGE
:argc
            lda   #1
            jsr   GETARG
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            lda   #<DLBUF
            sta   PTR0
            lda   #>DLBUF
            sta   PTR0+1
            jsr   SC_DEVLIST
            sta   NDEV
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            jsr   MNT_UNIT
            bcs   :byname
*-- /dev/sNdM: an unmounted Disk ][ is not mounted -- say so
*-- without reading it.
            sta   UNIT
            jsr   FLAGS             ;A = the unit's DEVLIST byte
            bcs   :nomount
            and   #3
            cmp   #1
            beq   :nomount
            lda   UNIT
            jsr   MNT_ONLINE
            bcs   :fail
            bra   :go
:nomount    lda   #$45
:fail       jmp   MNT_FAIL
*-- /mnt/NAME: find the unit whose volume has that name.
:byname     lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            ldy   #0
:pf         lda   (PTR0),y
            jsr   RD_FOLD
            cmp   MNTPFX,y
            bne   :nomount
            iny
            cpy   #5                ;"/MNT/"
            bne   :pf
            lda   (PTR0),y
            beq   :nomount          ;no name
            sty   NAMEIX
            stz   IDX
:scan       lda   IDX
            cmp   NDEV
            bcs   :nomount
            tax
            inc   IDX
            lda   DLBUF,x
            and   #3
            cmp   #1
            beq   :scan
            lda   DLBUF,x
            and   #$F0
            sta   UNIT
            jsr   MNT_ONLINE
            bcs   :scan
            jsr   SAMENAME
            bcc   :scan
:go         lda   UNIT
            ldx   #2                ;op 2: UMOUNT
            jsr   MNT_VROOT
            bcs   :fail
*-- a loop volume answers with the
            cmp   #0
*-- writes that were lost (LP_WFAIL)
            beq   :ok
            pha
            jsr   LOSTHEAD
            pla
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDERR
            jsr   PRNUM
            lda   #<LOSTMSG
            sta   PTR0
            lda   #>LOSTMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1                ;detached, but data was lost
            jsr   EXIT
:ok         lda   #0
            jsr   EXIT

*-- "umount: <operand>: " to stderr (PTR1 still the operand)
LOSTHEAD    lda   #<PROGNAME
            sta   PTR0
            lda   #>PROGNAME
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<MNT_COLON
            sta   PTR0
            lda   #>MNT_COLON
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<MNT_COLON
            sta   PTR0
            lda   #>MNT_COLON
            sta   PTR0+1
            ldx   #FD_STDERR
            jmp   PUTS

USAGE       lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* FLAGS -- IN: UNIT. OUT: carry CLEAR, A = that unit's DEVLIST
* byte as SYS_DEVLIST reports it; carry SET = no such unit.
*---------------------------------------------------------------
FLAGS       ldx   NDEV
:f          dex
            bmi   :no
            lda   DLBUF,x
            and   #$F0
            cmp   UNIT
            bne   :f
            lda   DLBUF,x
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* SAMENAME -- is the name after "/mnt/" (PTR1, from NAMEIX) the
* volume MNT_ONLINE just read? Carry SET = yes, whole name.
*---------------------------------------------------------------
SAMENAME    ldx   #1                ;MNT_NM[0] is '/'
            ldy   NAMEIX
:c          lda   (PTR1),y
            jsr   RD_FOLD
            sta   TMP
            lda   MNT_NM,x
            jsr   RD_FOLD
            cmp   TMP
            bne   :no
            cmp   #0
            beq   :yes              ;both ended together
            inx
            iny
            bra   :c
:no         clc
            rts
:yes        sec
            rts

PROGNAME    asc   "umount"
            dfb   0
USAGEMSG    asc   "usage: umount /mnt/NAME | /dev/sNdM"
            dfb   $8D,0
MNTPFX      asc   '/MNT/'
LOSTMSG     asc   " blocks were not written"
            dfb   $8D,0

            put   mntcom.s
            put   ../liba/string.s
            put   ../liba/readsys.s
            put   ../liba/readfold.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/hex.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* umount's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND (docs/STICKY.md sec 21). NOTHING ZEROES THIS
* ARENA: UNIT is written before any read on every path;
* NDEV/DLBUF by SC_DEVLIST first thing; IDX by the scan's own
* stz; NAMEIX by the "/mnt/" parse; TMP by SAMENAME; the
* MNT_* cells by their routines.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
UNIT        ds    1
NDEV        ds    1
IDX         ds    1
NAMEIX      ds    1
TMP         ds    1
DLBUF       ds    16
MNT_PROG    ds    2
MNT_TMP     ds    1
MNT_OPARM   ds    4
MNT_VPARM   ds    4
MNT_ONBUF   ds    16
MNT_NMLP    ds    1
MNT_NM      ds    17
            err   */$BF00
            dend
