*---------------------------------------------------------------
* df.s -- report ProDOS volume block usage, POSIX -P form.
*
* Usage: df [-Pk] [file...]
*
* Output (always the POSIX -P shape; without -P the form is
* unspecified, so there is only one):
*   Filesystem 512-blocks Used Available Capacity Mounted on
*   /mnt/MAUX 8192 1685 6507 21% /mnt/MAUX
* One row per volume. The Filesystem column is the volume path:
* ProDOS has no device name for a volume the way a Unix mount
* has, and the volume path is what every maux tool takes.
* maux's block IS 512 bytes, so -k (1024-byte units) halves each
* count, rounding the total and used UP and taking Available as
* their difference; Capacity is always worked out from the
* 512-byte counts. -P is accepted and changes nothing.
*
* No operand -> every mounted volume, listed through liba's
* readdir on "/mnt" (docs/VROOT.md): the fast units, plus a
* Disk ][ only once `mount` has named it; one SYS_ONLINE per
* unit, never a poll of an unmounted drive (operator RULING).
* An operand -> the volume holding it: "/mnt/MAUX/SUB/FILE",
* "/bin/ls" (the boot volume's BIN) and "MAUX" (a bare name that
* is a volume) all report their /mnt/NAME. The operand is made
* physical by the kernel (SYS_VROOT op 3) and its first
* component is the volume. "/" and "/mnt" list every volume like
* no operand.
*
* THE NUMBERS: one SYS_GFI on "/VOL". ProDOS 8 Technical
* Reference Manual, GET_FILE_INFO: "When file information about
* a volume directory is requested, the total number of blocks on
* the volume is returned in the aux_type field and the total
* blocks for all files is returned in blocks_used." (library
* artifact d82965d8..., chunk 168). Total = aux_type, Used =
* blocks_used, Available = Total - Used. No bitmap read, no
* ON_LINE-to-unit mapping, no raw block access -- which is what
* this tool used to say it needed (it read the volume header's
* total_blocks and printed "used/free unavailable"). Opening a
* directory as a byte stream "works" because OPEN has no
* storage_type gate (learning:01M0PSV2PVPWKHZZF5A52EWX31); GFI
* is the right call, not that accident.
*
* A volume that fails GFI prints "df: <path>: cannot access" to
* stderr, is skipped, and forces exit 1. Exit 2 on a usage
* error.
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
            dsk   ../../build/df.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/readdir.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

DF_MAXNM    equ   25         ;"/mnt/" + 15-char name + margin

*---------------------------------------------------------------
* START
*---------------------------------------------------------------
START       stz   ERRFLAG
            stz   KFLAG
            lda   #<OPTSTR
            ldx   #>OPTSTR
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$D0              ;'P': accepted, no-op
            beq   :optlp
            cmp   #$EB              ;'k' high-bit
            bne   :badopt
            lda   #1
            sta   KFLAG
            bra   :optlp
:badopt     jmp   USAGE_ERR
:optdone    jsr   PRHEADER
            lda   ARGC
            sec
            sbc   OPTIND
            sta   NPATHS
            bne   :havepth
            jsr   DOALL
            jmp   :finish
:havepth    stz   ARGI
:aloop      lda   ARGI
            cmp   NPATHS
            bcs   :finish
            clc
            adc   OPTIND
            jsr   GETARG            ;PTR0 = argv[OPTIND+ARGI]
            jsr   PROCESSARG
            inc   ARGI
            bra   :aloop
:finish     lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* USAGE_ERR -- usage to stderr, exit 2. Does not return.
*---------------------------------------------------------------
USAGE_ERR   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* DOALL -- no operand (or "/"): one row per mounted volume, the
* records of readdir on "/mnt". readdir holds the directory open
* while each volume is stat'd -- STATVOL touches only SC_GFI,
* never readdir.
*---------------------------------------------------------------
DOALL       lda   #<ROOTMLI
            ldx   #>ROOTMLI
            jsr   OPENDIR
            bcc   :next
            lda   #<ROOTSTR
            sta   ERRP
            lda   #>ROOTSTR
            sta   ERRP+1
            jmp   PRINTACCESS
:next       lda   #<RD_RECORD
            ldx   #>RD_RECORD
            jsr   READDIR
            bcs   :done
            ldx   #4
:pfx        lda   MNTSTR,x          ;"/mnt/"
            sta   VOLPATH,x
            dex
            bpl   :pfx
            ldx   #0
:cpn        lda   RD_RECORD+RD_NAME,x
            sta   VOLPATH+5,x
            beq   :cpdone
            inx
            cpx   #DF_MAXNM-6
            bcc   :cpn
            stz   VOLPATH+5,x
:cpdone     jsr   STATREPT
            bra   :next
:done       jmp   CLOSEDIR

*---------------------------------------------------------------
* STATREPT -- stat VOLPATH and print its row, or its access
* error. CLOBBERS: everything.
*---------------------------------------------------------------
STATREPT    jsr   STATVOL
            bcs   :bad
            jmp   PRINTROW
:bad        lda   #<VOLPATH
            sta   ERRP
            lda   #>VOLPATH
            sta   ERRP+1
            jmp   PRINTACCESS

*---------------------------------------------------------------
* PROCESSARG -- IN: PTR0 = hi-bit NUL operand. Reports the
* volume holding it (see header for the shapes). CLOBBERS:
* everything.
*---------------------------------------------------------------
PROCESSARG  lda   PTR0
            sta   OPSAVE
            lda   PTR0+1
            sta   OPSAVE+1
            ldy   #0
            lda   (PTR0),y
            cmp   #$AF              ;'/' high-bit
            beq   :abs
            cmp   #$AE              ;'.' -- ./X, ../X, .
            beq   :path
            jsr   MAKESLASH         ;bare name: try a volume
            jsr   STATVOL
            bcs   :path             ;not one -- a path
            jmp   PRINTROW
:abs        iny
            lda   (PTR0),y
            bne   :path
            jmp   DOALL             ;"/" -- every volume
:path       jsr   CHKEXIST
            bcs   :nope
            jsr   MAPPHYS
            bcs   :nope
            jsr   VOLTRUNC
            jmp   STATREPT
:nope       lda   OPSAVE
            sta   ERRP
            lda   OPSAVE+1
            sta   ERRP+1
            jmp   PRINTACCESS

*---------------------------------------------------------------
* CHKEXIST -- IN: OPSAVE = the operand. OUT: carry clear = a GFI
* on it succeeds. MKPATH resolves ./.. itself (liba/mli.s), so
* nothing here leans on ProDOS 2.5's own bare-"." leniency
* (learning:01M0PBKZKZE55J4NE93TYNJCPC). CLOBBERS: A, X, Y,
* PTR0, PTR1.
*---------------------------------------------------------------
CHKEXIST    lda   OPSAVE
            sta   PTR0
            lda   OPSAVE+1
            sta   PTR0+1
            lda   #<MLIPATH
            sta   PTR1
            lda   #>MLIPATH
            sta   PTR1+1
            jsr   MKPATH
            lda   #<MLIPATH
            sta   GFIPARM_PATH
            lda   #>MLIPATH
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jmp   SC_GFI

*---------------------------------------------------------------
* MAPPHYS -- MLIPATH (CHKEXIST just built it) -> the PHYSICAL
* path, by the kernel's own table (SYS_VROOT op 3): "/bin/ls" is
* "/MAUX/BIN/ls", "/mnt/GAMES/X" is "/GAMES/X", a relative name
* is made absolute against THIS process's cwd first. OUT: carry
* clear, PTR0 = PHYBUF = the physical path as a hi-bit NUL
* string; carry set = no such mapping ("/mnt" itself). CLOBBERS:
* A, X, Y, PTR0.
*---------------------------------------------------------------
MAPPHYS     lda   #3
            sta   VPARM
            lda   #<MLIPATH
            sta   VPARM+1
            lda   #>MLIPATH
            sta   VPARM+2
            lda   #<VPARM
            ldx   #>VPARM
            jsr   SC_VROOT
            bcs   :out
            ldy   MLIPATH
:hi         lda   MLIPATH,y
            ora   #$80
            sta   PHYBUF-1,y
            dey
            bne   :hi
            ldy   MLIPATH
            lda   #0
            sta   PHYBUF,y          ;no STZ abs,Y on 65C02
            lda   #<PHYBUF
            sta   PTR0
            lda   #>PHYBUF
            sta   PTR0+1
            clc
:out        rts

*---------------------------------------------------------------
* MAKESLASH -- IN: PTR0 = hi-bit NUL volume name. OUT: VOLPATH =
* "/mnt/" + that name (truncated to fit), hi-bit NUL. CLOBBERS:
* A, X, Y.
*---------------------------------------------------------------
MAKESLASH   ldx   #4
:pfx        lda   MNTSTR,x
            sta   VOLPATH,x
            dex
            bpl   :pfx
            ldy   #0
:cparg      cpy   #DF_MAXNM-6
            bcs   :argtdone
            lda   (PTR0),y
            beq   :argtdone
            sta   VOLPATH+5,y
            iny
            bra   :cparg
:argtdone   lda   #0
            sta   VOLPATH+5,y     ;no STZ abs,Y on 65C02
            rts

*---------------------------------------------------------------
* VOLTRUNC -- IN: PTR0 = a PHYSICAL hi-bit NUL path, byte 0 =
* '/'. OUT: VOLPATH := "/mnt/" + its first component (the
* volume), hi-bit NUL, stopping at the next '/' or NUL.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
VOLTRUNC    ldx   #4
:pfx        lda   MNTSTR,x
            sta   VOLPATH,x
            dex
            bpl   :pfx
            ldy   #1
:vloop      cpy   #DF_MAXNM-5
            bcs   :vdone
            lda   (PTR0),y
            beq   :vdone
            cmp   #$AF
            beq   :vdone
            sta   VOLPATH+4,y
            iny
            bra   :vloop
:vdone      lda   #0
            sta   VOLPATH+4,y     ;no STZ abs,Y on 65C02
            rts

*---------------------------------------------------------------
* STATVOL -- GFI on VOLPATH. OUT: carry clear = TOTBLK
* (aux_type)
* and USEDBLK (blocks_used) set -- the TRM's volume-directory
* paragraph, quoted in the header; carry set = cannot stat.
*---------------------------------------------------------------
STATVOL     lda   #<VOLPATH
            sta   PTR0
            lda   #>VOLPATH
            sta   PTR0+1
            lda   #<MLIPATH
            sta   PTR1
            lda   #>MLIPATH
            sta   PTR1+1
            jsr   MKPATH
            lda   #<MLIPATH
            sta   GFIPARM_PATH
            lda   #>MLIPATH
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :out
            lda   GFIPARM_AUX
            sta   TOTBLK
            lda   GFIPARM_AUX+1
            sta   TOTBLK+1
            lda   GFIPARM_BLKS
            sta   USEDBLK
            lda   GFIPARM_BLKS+1
            sta   USEDBLK+1
            clc
:out        rts

*---------------------------------------------------------------
* PCT -- OUT: A = ceil(100*USEDBLK/TOTBLK), 0 for an empty
* volume (POSIX df's Capacity). 100*used is a 24-bit sum; the
* quotient is how many times TOTBLK comes off it before it runs
* out, <= 100 iterations. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PCT         stz   ACC
            stz   ACC+1
            stz   ACC+2
            ldx   #100
:mul        clc
            lda   ACC
            adc   USEDBLK
            sta   ACC
            lda   ACC+1
            adc   USEDBLK+1
            sta   ACC+1
            lda   ACC+2
            adc   #0
            sta   ACC+2
            dex
            bne   :mul
            ldy   #0
            lda   TOTBLK
            ora   TOTBLK+1
            beq   :pdone
:div        lda   ACC
            ora   ACC+1
            ora   ACC+2
            beq   :pdone
            iny
            sec
            lda   ACC
            sbc   TOTBLK
            sta   ACC
            lda   ACC+1
            sbc   TOTBLK+1
            sta   ACC+1
            lda   ACC+2
            sbc   #0
            sta   ACC+2
            bcs   :div              ;no borrow: take more
:pdone      tya
            rts

*---------------------------------------------------------------
* PRHEADER -- the -P header, 512-blocks or 1024-blocks.
*---------------------------------------------------------------
PRHEADER    lda   #<HDR1
            sta   PTR0
            lda   #>HDR1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #<HDRU512
            ldx   #>HDRU512
            ldy   KFLAG
            beq   :units
            lda   #<HDRU1K
            ldx   #>HDRU1K
:units      sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #<HDR2
            sta   PTR0
            lda   #>HDR2
            sta   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS

*---------------------------------------------------------------
* PRINTROW -- IN: VOLPATH, TOTBLK, USEDBLK. One -P row:
* "<vol> <total> <used> <avail> <pct>% <vol>" + CR to stdout.
*---------------------------------------------------------------
PRINTROW    jsr   PCT
            sta   PCTVAL
            lda   KFLAG
            beq   :units
            jsr   HALVE             ;-k: ceil(x/2)
:units      sec
            lda   TOTBLK
            sbc   USEDBLK
            sta   AVAIL
            lda   TOTBLK+1
            sbc   USEDBLK+1
            sta   AVAIL+1
            bcs   :avok
            stz   AVAIL             ;clamp, never wrap
            stz   AVAIL+1
:avok       jsr   PRVOL
            lda   TOTBLK
            ldx   TOTBLK+1
            jsr   SPNUM
            lda   USEDBLK
            ldx   USEDBLK+1
            jsr   SPNUM
            lda   AVAIL
            ldx   AVAIL+1
            jsr   SPNUM
            lda   PCTVAL
            ldx   #0
            jsr   SPNUM
            lda   #$A5              ;'%'
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PRVOL
            lda   #$8D
            ldx   #FD_STDOUT
            jmp   PUTC

* -- HALVE: TOTBLK and USEDBLK := ceil(x/2), 16-bit.
HALVE       ldx   #0
:h          clc
            lda   TOTBLK,x
            adc   #1
            sta   TOTBLK,x
            lda   TOTBLK+1,x
            adc   #0
            ror   a                 ;the add's carry is bit 16
            sta   TOTBLK+1,x
            lda   TOTBLK,x
            ror   a
            sta   TOTBLK,x
            inx
            inx
            cpx   #4
            bne   :h
            rts

* -- PRVOL: VOLPATH to stdout (both the Filesystem and the
* -- Mounted-on column, after/before a separating space).
PRVOL       lda   #<VOLPATH
            sta   PTR0
            lda   #>VOLPATH
            sta   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS

* -- SPNUM: a space, then A/X (lo/hi) as decimal to stdout.
SPNUM       sta   U2DEC_VAL
            stx   U2DEC_VAL+1
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            ldx   #FD_STDOUT
            jmp   PRNUM

*---------------------------------------------------------------
* PRINTACCESS -- "df: <ERRP>: cannot access" to stderr, sets
* ERRFLAG.
*---------------------------------------------------------------
PRINTACCESS lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ERRP
            sta   PTR0
            lda   ERRP+1
            sta   PTR0+1
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
            rts

*---------------------------------------------------------------
* Data
*---------------------------------------------------------------
OPTSTR      asc   "Pk"
            dfb   0
USAGEMSG    asc   "usage: df [-Pk] [file...]"
            dfb   $8D,0
HDR1        asc   "Filesystem "
            dfb   0
HDRU512     asc   "512-blocks"
            dfb   0
HDRU1K      asc   "1024-blocks"
            dfb   0
HDR2        asc   " Used Available Capacity Mounted on"
            dfb   $8D,0
ERRPFX      asc   "df: "
            dfb   0
ERRSUF      asc   ": cannot access"
            dfb   $8D,0
ROOTSTR     asc   "/mnt"
            dfb   0
ROOTMLI     dfb   4,$2F,$6D,$6E,$74 ;MLI-shaped "/mnt"
MNTSTR      asc   "/mnt/"

* -- GET_FILE_INFO ($C4), PCOUNT_GFI-shaped (inc/mli.equ).
GFIPARM     dfb   PCOUNT_GFI
GFIPARM_PATH da   0
GFIPARM_ACC dfb   0
GFIPARM_FTYP dfb  0
GFIPARM_AUX da    0
GFIPARM_STYP dfb  0
GFIPARM_BLKS da   0
GFIPARM_MDATE da  0
GFIPARM_MTIME da  0
GFIPARM_CDATE da  0
GFIPARM_CTIME da  0


            put   ../liba/string.s
            put   ../liba/readdir.s
            put   ../liba/readsyn.s
            put   ../liba/readsys.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* df's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - ERRFLAG/KFLAG: `stz` as START's first instructions.
*  - ARGI/NPATHS: written by START before any read.
*  - OPSAVE: written by PROCESSARG's first instructions, read
*    only by CHKEXIST and the :nope path after it.
*  - ERRP: written immediately before every PRINTACCESS call.
*  - TOTBLK/USEDBLK: both `sta`'d by STATVOL on its carry-clear
*    path, which is the only path PRINTROW follows.
*  - AVAIL/PCTVAL/ACC: written by PRINTROW/PCT before read.
*  - VOLPATH: written with its NUL by VOLTRUNC or DOALL's copy
*    before any reader.
*  - VPARM/PHYBUF: written whole by MAPPHYS before any read.
*  - MLIPATH: MKPATH writes chars then the count byte; the MLI
*    reads only count+1.
*  - RD_RECORD: written whole by READDIR before DOALL reads it.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ERRFLAG     ds    1
KFLAG       ds    1
ARGI        ds    1
NPATHS      ds    1
PCTVAL      ds    1
OPSAVE      ds    2
ERRP        ds    2
TOTBLK      ds    2
USEDBLK     ds    2
AVAIL       ds    2
ACC         ds    3

VOLPATH     ds    DF_MAXNM
VPARM       ds    4
PHYBUF      ds    66
MLIPATH     ds    65
RD_RECORD   ds    RD_SIZE
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
