*---------------------------------------------------------------
* mount.s -- list the mounted volumes, or mount a floppy.
*
* Usage: mount
*        mount /dev/sNdM
*        mount [-r] IMAGE.po
*
* No operand: one line per volume the kernel shows under /mnt,
*   /dev/s7d1 on /mnt/MAUX
* a fast unit (SmartPort, hard disk) is always mounted; a
* Disk ][ only after it was mounted here. No operand never
* touches an unmounted drive.
*
* One operand: the Disk ][ at that unit is read ONCE (ON_LINE on
* that unit and no other -- the user asked) and, if it holds a
* ProDOS volume, marked mounted so /mnt, df and `mount` show it.
* A drive with no readable volume fails with the MLI's own
* reason ($52 not a ProDOS volume, $28 no device) and sets
* nothing.
* Mounting a fast unit is a no-op that succeeds. docs/VROOT.md.
*
* One operand that is not /dev/sNdM names a FILE: a ProDOS tree
* file (.po / .hdv) on a mounted volume. The kernel attaches it
* as unit $B0 (/dev/s3d2) and the volume inside appears under
* /mnt like any other; `umount` detaches it. This tool finds
* the unit that holds the file's volume (one ON_LINE per listed
* unit, never unit 0) and calls SYS_VROOT op 4; the kernel walks
* the directory, refuses a sparse image, a 2IMG, a seedling or
* sapling, a second mount, and keeps the file open until umount.
* There is NO losetup. docs/LOOP-S1.md.
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
            dsk   ../../build/mount.bin
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
            stz   RFLAG
            lda   ARGC
            cmp   #1
            beq   LIST
            cmp   #3                ;mount -r IMAGE
            bne   :two
            lda   #1
            jsr   GETARG
            ldy   #0
:ro         lda   (PTR0),y
            cmp   MNT_RO,y
            bne   USAGE
            iny
            cpy   #3
            bne   :ro
            inc   RFLAG
            lda   #2
            bra   :arg
:two        cmp   #2
            bne   USAGE
            lda   #1
:arg        jsr   GETARG
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            jsr   MNT_UNIT
            bcc   :isdev
            ldy   #0                ;/dev/ but no unit: the old
:d5         lda   (PTR0),y          ;reason; anything else is
            jsr   RD_FOLD           ;an image file
            cmp   MNT_DEVPFX,y
            bne   :image
            iny
            cpy   #5
            bne   :d5
            lda   #$E1
            jmp   :fail
:image      jmp   LOOPMNT
:isdev      ldx   RFLAG
            bne   USAGE             ;-r is for image files
            sta   UNIT
            jsr   MNT_ONLINE
            bcs   :fail
            lda   UNIT
            ldx   #1                ;op 1: MOUNT
            jsr   MNT_VROOT
            bcs   :fail
            lda   #0
            jsr   EXIT
:fail       jmp   MNT_FAIL

USAGE       lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* LIST -- every DEVLST unit that is not an unmounted Disk ][,
* the BOOT volume first, then ascending slot and drive (operator
* 2026-10-11: "yes sort it"; DEVLST order put the last unit
* found first, so /dev/s7d2 printed above the boot volume).
* One ON_LINE per listed unit, as before: the names are kept in
* LNAMES (17 B each: "/NAME" hi-bit NUL) so the two print passes
* never ask the drive twice. The boot volume's name is the first
* component of SYS_VROOT op 3 (PHYS) applied to "/bin".
*---------------------------------------------------------------
LIST        lda   #<DLBUF
            sta   PTR0
            lda   #>DLBUF
            sta   PTR0+1
            jsr   SC_DEVLIST
            sta   NDEV
*-- drop unmounted Disk ][ entries, keep the DSSS nibble only
            ldx   #0
            ldy   #0
:filt       cpx   NDEV
            bcs   :filtd
            lda   DLBUF,x
            inx
            sta   TMP
            and   #3
            cmp   #1
            beq   :filt             ;unmounted Disk ][: skip
            lda   TMP
            and   #$F0
            sta   DLBUF,y
            iny
            bra   :filt
:filtd      sty   NDEV
*-- bubble sort by key (slot, then drive); NDEV <= 14
:bpass      stz   SWAPPED
            ldx   #0
:bcmp       inx
            cpx   NDEV
            bcs   :bend
            lda   DLBUF-1,x
            jsr   KEYOF
            sta   KEYV
            lda   DLBUF,x
            jsr   KEYOF
            cmp   KEYV
            bcs   :bcmp             ;in order
            lda   DLBUF,x
            ldy   DLBUF-1,x
            sta   DLBUF-1,x
            tya
            sta   DLBUF,x
            inc   SWAPPED
            bra   :bcmp
:bend       lda   SWAPPED
            bne   :bpass
*-- one ON_LINE per unit; the name (or a 0 byte) into LNAMES
            stz   IDX
:names      lda   IDX
            cmp   NDEV
            bcs   :namesd
            jsr   LNPTR             ;PTR1 -> LNAMES slot
            ldx   IDX
            lda   DLBUF,x
            sta   UNIT
            jsr   MNT_ONLINE
            ldy   #0
            bcs   :noname
:cpn        lda   MNT_NM,y
            sta   (PTR1),y
            beq   :named
            iny
            cpy   #16
            bcc   :cpn
:noname     lda   #0
            sta   (PTR1),y
:named      inc   IDX
            bra   :names
:namesd
*-- the boot volume's name: PHYS of "/bin" -> "/VOL/BIN"
            lda   #<BINSTR
            sta   PTR0
            lda   #>BINSTR
            sta   PTR0+1
            lda   #<MLIPATH
            sta   PTR1
            lda   #>MLIPATH
            sta   PTR1+1
            jsr   MKPATH
            ldy   MLIPATH
:cpb        lda   MLIPATH,y
            sta   PHYBUF,y
            dey
            bpl   :cpb
            lda   #3
            sta   MNT_VPARM
            lda   #<PHYBUF
            sta   MNT_VPARM+1
            lda   #>PHYBUF
            sta   MNT_VPARM+2
            lda   #<MNT_VPARM
            ldx   #>MNT_VPARM
            jsr   SC_VROOT
            stz   BOOTNM            ;empty unless PHYS answered
            bcs   :pass1
            ldy   #1                ;PHYBUF: len, "/VOL/BIN"
            ldx   #0
:cpv        cpy   PHYBUF
            beq   :bvend
            bcs   :bvend
            lda   PHYBUF,y
            ora   #$80              ;hi-bit, like MNT_NM
            cpx   #0
            beq   :bv1
            cmp   #"/"              ;$AF: "/"+$80 would be $2F
            beq   :bvend            ;("x" has bit 7 set here)
:bv1        sta   BOOTNM,x
            inx
            iny
            cpx   #16
            bcc   :cpv
:bvend      lda   #0
            sta   BOOTNM,x
*-- pass 1: the boot volume; pass 2: everyone else
:pass1      lda   #1
            sta   PASS
:ploop      stz   IDX
:pnext      lda   IDX
            cmp   NDEV
            bcs   :pdone
            jsr   LNPTR
            ldy   #0
            lda   (PTR1),y
            beq   :pskip            ;no volume on this unit
            jsr   ISBOOT            ;A=1: this slot is the boot
            cmp   PASS              ;pass 1 wants 1, pass 2 0
            bne   :pskip
            ldx   IDX
            lda   DLBUF,x
            jsr   MNT_DEVNAME
            lda   #<ONSTR
            sta   PTR0
            lda   #>ONSTR
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            jsr   LNPTR
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:pskip      inc   IDX
            bra   :pnext
:pdone      dec   PASS              ;1 -> 0 -> $FF
            bpl   :ploop
            lda   #0
            jsr   EXIT

*-- KEYOF: A = DSSS0000 -> (SSS << 1) | D, ascending slot/drive
KEYOF       pha
            and   #$70
            lsr   a
            lsr   a
            lsr   a                 ;SSS in bits 3-1
            sta   KEYT
            pla
            asl   a                 ;C = D
            lda   #0
            rol   a                 ;A = D
            ora   KEYT
            rts

*-- LNPTR: PTR1 = LNAMES + IDX*17
LNPTR       lda   IDX
            asl   a                 ;x2
            asl   a                 ;x4
            asl   a                 ;x8
            asl   a                 ;x16
            clc
            adc   IDX               ;x17
            adc   #<LNAMES
            sta   PTR1
            lda   #>LNAMES
            adc   #0
            sta   PTR1+1
            rts

*-- ISBOOT: A = 1 when the hi-bit NUL string at (PTR1) equals
*-- BOOTNM (also hi-bit NUL; empty never matches), else 0
ISBOOT      ldy   #0
            lda   BOOTNM
            beq   :no
:cmpb       lda   (PTR1),y
            cmp   BOOTNM,y
            bne   :no
            beq   :chkend
:chkend     lda   BOOTNM,y
            beq   :yes
            iny
            cpy   #17
            bcc   :cmpb
:no         lda   #0
            rts
:yes        lda   #1
            rts

*---------------------------------------------------------------
* LOOPMNT -- mount FILE (PTR1 = the operand, a hi-bit NUL path).
*---------------------------------------------------------------
LOOPMNT     lda   PTR1
            sta   OPSAVE
            lda   PTR1+1
            sta   OPSAVE+1
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            lda   #<MLIPATH
            sta   PTR1
            lda   #>MLIPATH
            sta   PTR1+1
            jsr   MKPATH            ;absolute, 7-bit
            ldy   MLIPATH           ;a copy for the physical map
:cp         lda   MLIPATH,y
            sta   PHYBUF,y
            dey
            bpl   :cp
            lda   #3                ;op 3 PHYS
            sta   MNT_VPARM
            lda   #<PHYBUF
            sta   MNT_VPARM+1
            lda   #>PHYBUF
            sta   MNT_VPARM+2
            lda   #<MNT_VPARM
            ldx   #>MNT_VPARM
            jsr   SC_VROOT
            bcc   :phys
            jmp   LOOPFAIL
:phys       lda   #<DLBUF
            sta   PTR0
            lda   #>DLBUF
            sta   PTR0+1
            jsr   SC_DEVLIST
            sta   NDEV
            stz   IDX
*-- find the unit whose volume name is PHYBUF's first component
:scan       lda   IDX
            cmp   NDEV
            bcc   :more
            lda   #$45              ;its volume is not mounted
            jmp   LOOPFAIL
:more       tax
            inc   IDX
            lda   DLBUF,x
            and   #3
            cmp   #1
            beq   :scan             ;an unmounted Disk ][: never
            lda   DLBUF,x           ;polled
            and   #$F0
            sta   UNIT
            jsr   MNT_ONLINE
            bcs   :scan
            ldx   #1                ;PHYBUF[1] is '/'
            ldy   #0
:nm         inx
            iny
            lda   MNT_NM,y
            beq   :end              ;the volume name ended
            jsr   RD_FOLD
            sta   TMP
            cpx   PHYBUF
            beq   :last
            bcs   :scan             ;the path ended inside it
:last       lda   PHYBUF,x
            ora   #$80
            jsr   RD_FOLD
            cmp   TMP
            bne   :scan
            bra   :nm
:end        cpx   PHYBUF            ;the path continues with '/'
            bcs   :scan             ;(or ends: no file)
            lda   PHYBUF,x
            cmp   #'/'
            bne   :scan
            lda   #4                ;op 4 LOOPATT
            sta   MNT_VPARM
            lda   #<MLIPATH
            sta   MNT_VPARM+1
            lda   #>MLIPATH
            sta   MNT_VPARM+2
*-- a sparse image is made dense
            lda   RFLAG
            bne   :nodens           ;first, unless -r (S3)
            jsr   DENSIFY
            bcc   :nodens
            jmp   LOOPFAIL
*-- unit | read-only flag (bit 0)
:nodens     lda   UNIT
            ora   RFLAG
            sta   MNT_VPARM+3
            lda   #<MNT_VPARM
            ldx   #>MNT_VPARM
            jsr   SC_VROOT
            bcc   :mnted
            jmp   LOOPFAIL
*-- a file that is not a ProDOS volume: detach again
:mnted      lda   #$B0
            jsr   MNT_ONLINE
            bcc   :ok
            pha
            lda   #2
            sta   MNT_NMLP
            lda   #$AF
            sta   MNT_NM
            lda   #$BF
            sta   MNT_NM+1
            lda   #$B0
            ldx   #2                ;op 2: UMOUNT
            jsr   MNT_VROOT
            pla
            jmp   LOOPFAIL
:ok         lda   #0
            jsr   EXIT
LOOPFAIL    pha
            lda   OPSAVE
            sta   PTR1
            lda   OPSAVE+1
            sta   PTR1+1
            pla
            jmp   MNT_FAIL

PROGNAME    asc   "mount"
            dfb   0
USAGEMSG    asc   "usage: mount [-r] [/dev/sNdM | IMAGE]"
            dfb   $8D,0
MNT_RO      asc   "-r"
            dfb   0
ONSTR       asc   " on /mnt"
            dfb   0
BINSTR      asc   "/bin"           ;PHYS -> the boot volume
            dfb   0

            put   mntcom.s
            put   mntdens.s
            put   ../liba/string.s
            put   ../liba/readsys.s
            put   ../liba/readfold.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/hex.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* mount's bss -- `dum`/`dend` at the TEXTUAL END (docs/STICKY.md
* sec 21), anchored at LIBA_BSSEND. NOTHING ZEROES THIS ARENA:
* every cell is written before it is read -- UNIT by MNT_UNIT's
* caller or LIST's loop, NDEV/IDX by LIST, DLBUF by SC_DEVLIST,
* the MNT_* cells by their routines (MNT_NM and MNT_NMLP by
* MNT_ONLINE before any reader; MNT_ONBUF by the MLI).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
UNIT        ds    1
RFLAG       ds    1
TMP         ds    1
SWAPPED     ds    1
KEYV        ds    1
KEYT        ds    1
PASS        ds    1
BOOTNM      ds    17               ;"/VOL" hi-bit NUL
LNAMES      ds    238              ;14 x 17: "/NAME" per unit
OPSAVE      ds    2
MLIPATH     ds    65
PHYBUF      ds    66
*-- DENSIFY (mntdens.s): parmlists and counters; CBUF is its
*-- 512-byte block. Written before read on every path.
DGFI        ds    1
DGFI_PATH   ds    2
DGFI_ACC    ds    1
DGFI_FTYP   ds    1
DGFI_AUX    ds    2
DGFI_STYP   ds    1
DGFI_BLKS   ds    2
DGFI_MDATE  ds    2
DGFI_MTIME  ds    2
DGFI_CDATE  ds    2
DGFI_CTIME  ds    2
DOPN        ds    1
DOPN_PATH   ds    2
DOPN_IOB    ds    2
DOPN_REF    ds    1
DEOF        ds    5
DRW         ds    8
DSM         ds    5
DCLP        ds    2
DFD         ds    1
DBEFORE     ds    2
DN          ds    2
DLAST       ds    2
DEXP        ds    2
DI          ds    2
CBUF        ds    512
NDEV        ds    1
IDX         ds    1
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
