*---------------------------------------------------------------
* proshim.s -- run a well-behaved ProDOS 8 .SYSTEM program as
* a maux process (TASKS.md #19, docs/EDASM-SHIM.md).
*
* Usage: proshim PATH.SYSTEM
*
* Opens the named file, reads its image to $2000 in THIS bank
* (a .SYSTEM loads flat at $2000, ProDOS 8 TRM ch. 5), installs
* the three shim pieces -- the $BF00 page (proshimpg.s), the
* MLI core at $E000 (proshimcr.s) and the ROM-entry stubs at
* $F941 (proshimrm.s), each assembled standalone at its real
* address and embedded here via putbin, the asrom.s mechanism
* -- stamps the date from SC_CLOCK into the fake global page,
* points CSW/KSW at the headless console stubs, masks IRQs,
* and JMPs to $2000. execve-style: the bank gets taller and
* proshim is gone; the tenant owns everything below $BF00,
* its own zero page and stack, and the LC.
*
* Why I=1 (docs/EDASM-SHIM.md P0 step 2): a tenant that
* switches the motherboard ROM in around monitor calls hides
* this bank's $FFxx page, IRQ vector included, and that state
* is not trappable -- so the tenant is cooperative, yielding
* at every MLI call the shim translates. Named trigger for
* revisiting: a tenant that must be interruptible mid-compute.
*
* Warm reuse is SAFE and needs no head trick: proshim never
* overwrites its own $0800 code (the tenant lands at $2000,
* above proshim's image), so a retained bank whose head still
* matches is handed back to a fresh proshim that re-reads its
* tenant and re-copies the shim from scratch -- idempotent
* from LOAD_BASE. lazy free (src/kernel/lazyfree.s) may hold
* it or not; either is correct.
*
* Uses ONLY liba until the takeover; no direct gate, no raw
* SYS_* (check-userland's grep gate).
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.hw.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/proshim.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ
            put   proshim.equ

TENANT      equ   $2000          ;where a .SYSTEM image runs
STAGE       equ   $4000          ;where it is READ first
* -- proshim's own code+bss reach past $2000 (liba's arena plus
* -- this program's parmlists), so reading straight to $2000
* -- would put `sta RPARM` inside the image. Read it high,
* -- copy down last. Ceiling STAGE..$BEFF -> a tenant up to
* -- ~31 KB (EDASM.SYSTEM is 4 KB); the limit is noted in #19.
TENANT_CEIL equ   $BF           ;first page off-limits
SYSNAME     equ   $0280          ;ProDOS system-program name
CHUNK_HI    equ   $10           ;read 4 KB per call
* -- the ROM-stub equates sit BEFORE their first use: real
* -- Merlin-8 refuses a forward-referenced equate ("Illegal
* -- forward reference", the self-host sweep found it here
* -- 2026-09-13); merlin32 silently accepts one.
CSW         equ   $36
KSW         equ   $38
COUT1_STUB  equ   $FDF0          ;copied ROM COUT1
KEYIN_STUB  equ   $FD1B          ;copied ROM KEYIN
RDKEY_LDY   equ   $FD0D          ;the LDY #$0B operand in RDKEY
GETLN_E     equ   $FD6A          ;copied ROM GETLN entry
GETLN1_E    equ   $FD6F          ;copied ROM GETLN1 entry

START       jmp   MAIN

MAIN        lda   #1
            jsr   GETARG
            bcc   :arg
            jmp   USAGE
:arg
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #PCOUNT_OPEN
            sta   OPARM
            lda   #<PATHBUF
            sta   OPARM_PATH
            lda   #>PATHBUF
            sta   OPARM_PATH+1
            lda   #0
            sta   OPARM_IOBUF    ;kernel-owned, discarded
            sta   OPARM_IOBUF+1
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opened
            jmp   OPENERR
:opened
            lda   OPARM_REF
            sta   RPARM_REF
            sta   CPARM_REF
            lda   #PCOUNT_READ
            sta   RPARM
            lda   #PCOUNT_CLOSE
            sta   CPARM
            lda   #<STAGE
            sta   RPARM_BUF
            lda   #>STAGE
            sta   RPARM_BUF+1
:rd         lda   #0
            sta   RPARM_REQ
            lda   #CHUNK_HI
            sta   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcc   :got
            jmp   READERR
:got
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            clc
            lda   RPARM_BUF
            adc   RPARM_TRANS
            sta   RPARM_BUF
            lda   RPARM_BUF+1
            adc   RPARM_TRANS+1
            sta   RPARM_BUF+1
            cmp   #TENANT_CEIL
            bcc   :fits
            jmp   TOOBIG
:fits
            lda   RPARM_TRANS+1
            cmp   #CHUNK_HI
            bcc   :eof           ;short read = end of file
            jmp   :rd
:eof        lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            lda   RPARM_BUF+1
            cmp   #>STAGE
            bne   INSTALL
            lda   RPARM_BUF
            bne   INSTALL
            jmp   EMPTY

*-- the takeover. From here on nothing returns to liba. --
INSTALL     lda   #<CLKBUF
            sta   PTR0
            lda   #>CLKBUF
            sta   PTR0+1
            jsr   SC_CLOCK       ;a clockless rig answers zeros:
                                 ;the null date, which ProDOS
                                 ;sanctions
            lda   LCBANK2_RAM    ;LC RAM read + write, the
            lda   LCBANK2_RAM    ;process's default group
            lda   #<CORE_BLOB
            sta   PTR0
            lda   #>CORE_BLOB
            sta   PTR0+1
            lda   #<PS_CORE
            sta   PTR1
            lda   #>PS_CORE
            sta   PTR1+1
            lda   #<CORE_LEN
            sta   CPLEN
            lda   #>CORE_LEN
            sta   CPLEN+1
            jsr   COPYBLOB
* -- copy the REAL //e monitor ROM $F800-$FEFF into the tenant's
* -- LC RAM (stopping below the $FF00 syscall gate), so a tenant
* -- that reads LC RAM gets a COMPLETE monitor. $C081 reads ROM
* -- and writes LC RAM at once, so lda/sta at the
* -- same address copies ROM->RAM. Then redirect the two console
* -- leaves: COUT1 -> fd 1, KEYIN -> fd 0
* -- (fd 0), and blunt RDKEY's 80-col-firmware trampoline so it
* -- goes straight to KSW. The tenant's own screen pokes then
* -- land harmlessly on its (invisible) bank text page.
* -- MUST mask IRQs before going read-ROM: a VBL IRQ here
* -- would fetch $FFFE from ROM, not the kernel gate, and
* -- derail. (The tenant runs I=1 anyway.)
            sei
            lda   LCBANK1_RW            ;read ROM, write LC RAM
            lda   LCBANK1_RW
            lda   #0
            sta   PTR0
            sta   PTR1
            lda   #$F8
            sta   PTR0+1
            sta   PTR1+1
:romcp      lda   (PTR0)
            sta   (PTR1)
            inc   PTR0
            bne   :rc1
            inc   PTR0+1
:rc1        inc   PTR1
            bne   :rc2
            inc   PTR1+1
:rc2        lda   PTR0+1
            cmp   #$FF                  ;stop at $FF00
            bcc   :romcp
* -- redirect the copied monitor's console leaves (still in the
* -- $C081 write-RAM window) --
            lda   #$4C                  ;JMP
            sta   COUT1_STUB            ;$FDF0 (COUT1)
            lda   #<PS_CORE_FDOUT
            sta   COUT1_STUB+1
            lda   #>PS_CORE_FDOUT
            sta   COUT1_STUB+2
            lda   #$4C
            sta   KEYIN_STUB            ;$FD1B (KEYIN)
            lda   #<PS_CORE_FDIN
            sta   KEYIN_STUB+1
            lda   #>PS_CORE_FDIN
            sta   KEYIN_STUB+2
* -- $FD0D: LDY #$0B -> LDY #$00, so RDKEY skips the firmware
            lda   #0
            sta   RDKEY_LDY
            lda   #$4C                  ;GETLN/GETLN1 -> PS
            sta   GETLN_E
            sta   GETLN1_E
            lda   #<PS_CORE_GETLN
            sta   GETLN_E+1
            sta   GETLN1_E+1
            lda   #>PS_CORE_GETLN
            sta   GETLN_E+2
            sta   GETLN1_E+2
* -- overwrite the copied ROM's SETKBD/SETVID with simple
* -- versions that force KSW=$FD1B / CSW=$FDF0 (the fd leaves).
* -- On a //e those routines are 80-col-aware and would
* -- otherwise re-point CSW at the slot-3 firmware ($C307) on a
* -- PR#0, escaping the pipe.
            ldx   #SVKB_END-SVKB_TBL-1
:svkb       lda   SVKB_TBL,x
            sta   $FE89,x
            dex
            bpl   :svkb
            lda   LCBANK1_RAM           ;back to read RAM
            lda   LCBANK1_RAM
            lda   #<PAGE_BLOB
            sta   PTR0
            lda   #>PAGE_BLOB
            sta   PTR0+1
            lda   #<PS_PAGE
            sta   PTR1
            lda   #>PS_PAGE
            sta   PTR1+1
            lda   #0
            sta   CPLEN
            lda   #1
            sta   CPLEN+1
            jsr   COPYBLOB
            ldx   #3             ;date/time -> $BF90-$BF93
:dt         lda   CLKBUF,x
            sta   PS_DATE,x
            dex
            bpl   :dt
* -- stamp the tenant pathname at $0280, as ProDOS does when
* -- launches a .SYSTEM file: a well-behaved program reads it to
* -- derive its own directory and SET_PREFIX there, so its
* -- relative overlay opens (EDASM.ED etc) resolve. PATHBUF is
* -- already the count-prefixed 7-bit MLI pathname MKPATH built.
            ldx   PATHBUF        ;count byte
:sn         lda   PATHBUF,x
            sta   SYSNAME,x
            dex
            bpl   :sn
            lda   #<COUT1_STUB   ;CSW/KSW at the copied ROM's
            sta   CSW
            lda   #>COUT1_STUB
            sta   CSW+1
            lda   #<KEYIN_STUB
            sta   KSW
            lda   #>KEYIN_STUB
            sta   KSW+1
* -- length of the staged image = RPARM_BUF - STAGE, captured
* -- into ZP: the copy-down below overwrites proshim's own bss
* -- ($2042+, which the tenant region spans), so nothing it
* -- needs may live there. PTR0=src, PTR1=dst, PTR2=count.
            sec
            lda   RPARM_BUF
            sbc   #<STAGE
            sta   PTR2
            lda   RPARM_BUF+1
            sbc   #>STAGE
            sta   PTR2+1
            lda   #<STAGE
            sta   PTR0
            lda   #>STAGE
            sta   PTR0+1
            lda   #<TENANT
            sta   PTR1
            lda   #>TENANT
            sta   PTR1+1
            sei                  ;cooperative tenant (header)
* -- forward copy STAGE->TENANT; dst is a whole page below src,
* -- so each byte is read before it is overwritten.
CPDOWN      lda   PTR2
            ora   PTR2+1
            beq   :cpdone
            lda   (PTR0)
            sta   (PTR1)
            inc   PTR0
            bne   :c1
            inc   PTR0+1
:c1         inc   PTR1
            bne   :c2
            inc   PTR1+1
:c2         lda   PTR2
            bne   :c3
            dec   PTR2+1
:c3         dec   PTR2
            bra   CPDOWN
:cpdone     lda   #0
            ldx   #0
            ldy   #0
            jmp   TENANT

* COPYBLOB -- (PTR0) -> (PTR1), CPLEN bytes, forward.
COPYBLOB    ldy   #0
:lp         lda   CPLEN
            ora   CPLEN+1
            beq   :done
            lda   (PTR0),y
            sta   (PTR1),y
            inc   PTR0
            bne   :s1
            inc   PTR0+1
:s1         inc   PTR1
            bne   :s2
            inc   PTR1+1
:s2         lda   CPLEN
            bne   :s3
            dec   CPLEN+1
:s3         dec   CPLEN
            jmp   :lp
:done       rts

*-- diagnostics: "proshim: <message>" to stderr, exit 1 --
USAGE       lda   #<MSG_USAGE
            ldx   #>MSG_USAGE
            jmp   DIE
OPENERR     lda   #<MSG_OPEN
            ldx   #>MSG_OPEN
            jmp   DIE
READERR     lda   #<MSG_READ
            ldx   #>MSG_READ
            jmp   DIE
TOOBIG      lda   #<MSG_BIG
            ldx   #>MSG_BIG
            jmp   DIE
EMPTY       lda   #<MSG_EMPTY
            ldx   #>MSG_EMPTY
DIE         sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jmp   EXIT

MSG_USAGE   asc   "proshim: usage: proshim FILE.SYSTEM",8D,00
MSG_OPEN    asc   "proshim: cannot open file",8D,00
MSG_READ    asc   "proshim: read error",8D,00
MSG_BIG     asc   "proshim: image reaches $BF00",8D,00
MSG_EMPTY   asc   "proshim: empty image",8D,00

* SETKBD ($FE89) then a NOP pad ($FE92) then SETVID ($FE93):
SVKB_TBL    dfb   $A9,$1B,$85,$38,$A9,$FD,$85,$39,$60  ;KSW
            dfb   $EA                                   ;pad
            dfb   $A9,$F0,$85,$36,$A9,$FD,$85,$37,$60  ;CSW
SVKB_END
PAGE_BLOB
            putbin ../../build/proshimpg.bin
CORE_BLOB
            putbin ../../build/proshimcr.bin
CORE_LEN    equ   *-CORE_BLOB

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* proshim's bss -- anchored at LIBA_BSSEND (libabss.s opened
* its own block at the image end). Nothing zeroes this arena
* (docs/STICKY.md sec 21); every cell is written before read:
*  - PATHBUF: written whole by MKPATH before OPEN.
*  - OPARM/RPARM/CPARM: constants and pointers stored above
*    before each call; result fields written by the kernel.
*  - CLKBUF: written by SC_CLOCK before the stamp loop.
*  - CPLEN: stored before every COPYBLOB.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
PATHBUF     ds    65
OPARM       ds    1
OPARM_PATH  ds    2
OPARM_IOBUF ds    2
OPARM_REF   ds    1
RPARM       ds    1
RPARM_REF   ds    1
RPARM_BUF   ds    2
RPARM_REQ   ds    2
RPARM_TRANS ds    2
CPARM       ds    1
CPARM_REF   ds    1
CLKBUF      ds    4
CPLEN       ds    2
            err   */$BF00
            dend
