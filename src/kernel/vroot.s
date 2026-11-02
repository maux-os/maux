*---------------------------------------------------------------
* vroot.s -- the virtual root (docs/VROOT.md): `/` is a table
* the KERNEL owns, not a directory on any disk. REAL twin;
* vroots.s is the stub every manifest without the virtual root
* puts instead (module choice, not `do`/`fin`).
*
* VIRTUAL -> PHYSICAL (VR_XLATE_P) happens once, at the syscall
* boundary, on the slot PRC_ABSPATH just finished: a MAP row
* gets the boot volume put in front (/bin/sh -> /MAUX/BIN/sh),
* /mnt/NAME/x loses its "/mnt" (-> /NAME/x), /dev is left to
* VR_DEVCALL (docs/EXEC-SHEBANG.md Part 3), anything else is not
* found. OPEN of a device never gets here (PRC_DEVOPEN answers
* first). PHYSICAL -> VIRTUAL
* (VR_REV) is PRC_GETPFX's reverse. Everything in between --
* the cwd slot, lending's reopen paths, bye -- stays physical.
*
* Adding a row (/proc) is one line in VR_TAB and one lister.
* Kinds: 1 = directory map, 2 = synthetic device dir, 3 = mnt.
*---------------------------------------------------------------
*-- VK_MAP/VK_DEV/VK_MNT: inc/proc.const.equ (loopseg.s's
*-- LP_CLASS reads them; REL cannot export an equate)

VR_START    ds    1                 ;VR_LOOK scratch
VR_LAST     ds    1
VR_END      ds    1                 ;index past the component
VR_LEN      ds    1                 ;its length
VR_ROW      ds    1                 ;VR_TAB offset of the match
VR_N        ds    1

*-- Row: name length, UPPER-case name, kind. 0 ends the table.
VR_TAB      dfb   3
            asc   'BIN'
            dfb   VK_MAP
            dfb   3
            asc   'USR'
            dfb   VK_MAP
            dfb   3
            asc   'ETC'
            dfb   VK_MAP
            dfb   3
            asc   'TMP'
            dfb   VK_MAP
            dfb   3
            asc   'DEV'
            dfb   VK_DEV
            dfb   3
            asc   'MNT'
            dfb   VK_MNT
            dfb   0
VR_MNTS     dfb   4
            asc   '/mnt'

*---------------------------------------------------------------
* VR_LOOK -- find the first component of the absolute path in
* PRC_PATHBUF. IN: X = index of its first character, Y = index
* of the path's last character. OUT: carry clear, A = the row's
* kind, VR_ROW = its offset; or carry set, no such row. Either
* way VR_END = index just past the component (a '/' or Y+1).
* Clobbers A, X, Y.
*---------------------------------------------------------------
VR_LOOK     stx   VR_START
            sty   VR_LAST
:scan       cpx   VR_LAST
            beq   :ch
            bcs   :cend
:ch         lda   PRC_PATHBUF,x
            cmp   #"/"+$80
            beq   :cend
            inx
            bra   :scan
:cend       stx   VR_END
            txa
            sec
            sbc   VR_START
            sta   VR_LEN
            beq   :nf
            stz   VR_ROW
:row        ldy   VR_ROW
            lda   VR_TAB,y
            beq   :nf
            cmp   VR_LEN
            bne   :next
            ldx   VR_START
:chr        iny
            lda   PRC_PATHBUF,x
            jsr   PDEV_FOLD
            cmp   VR_TAB,y
            bne   :next
            inx
            cpx   VR_END
            bne   :chr
            iny
            lda   VR_TAB,y
            clc
            rts
:next       ldy   VR_ROW
            lda   VR_TAB,y
            clc
            adc   #2
            adc   VR_ROW
            sta   VR_ROW
            bra   :row
:nf         sec
            rts

*---------------------------------------------------------------
* VR_BVLEN -- A = length of "/VOL", the boot volume's name with
* its leading slash, taken from PRC_PFXSAVE (captured here if no
* chdir has captured it yet). Carry set + error posted if ProDOS
* has no prefix. Uses PML_GPFX2, so PRC_PARM is not disturbed.
*---------------------------------------------------------------
VR_BVLEN    lda   PRC_PFXSAVE
            bne   :have
            jsr   PMLI_GPFX2_CL
            bne   :bad
            ldx   PRC_CANON
            beq   :bad
:cp         lda   PRC_CANON,x
            sta   PRC_PFXSAVE,x
            dex
            bpl   :cp
:have       ldx   #2
:fv         cpx   PRC_PFXSAVE
            beq   :chk
            bcs   :end
:chk        lda   PRC_PFXSAVE,x
            cmp   #"/"+$80
            beq   :end
            inx
            bra   :fv
:end        dex
            txa
            clc
            rts
:bad        lda   #MLIE_NOFILE
            jsr   PRC_FAIL_A
            sec
            rts

*---------------------------------------------------------------
* VR_INS -- put A bytes, taken from (P_PTR1)+1.., in front of
* the path in the slot at PRC_PATH_DST. Over 64: ERR_INVAL.
* VR_DEL -- drop the first A bytes of that path (A < length).
* Both: carry clear, length byte updated. Clobber A, X, Y.
*---------------------------------------------------------------
VR_INS      sta   VR_N
            ldx   PRC_PATH_DST
            lda   PRC_PATHBUF,x
            clc
            adc   VR_N
            cmp   #65
            bcs   VR_TOOLONG
            pha
            lda   PRC_PATHBUF,x
            clc
            adc   PRC_PATH_DST
            tax
            clc
            adc   VR_N
            tay
:sh         lda   PRC_PATHBUF,x
            sta   PRC_PATHBUF,y
            dey
            dex
            cpx   PRC_PATH_DST
            bne   :sh
            ldy   #0
:cp         iny
            inx
            lda   (P_PTR1),y
            sta   PRC_PATHBUF,x
            cpy   VR_N
            bne   :cp
            ldx   PRC_PATH_DST
            pla
            sta   PRC_PATHBUF,x
            clc
            rts
VR_TOOLONG  lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts

VR_DEL      sta   VR_N
            ldx   PRC_PATH_DST
            lda   PRC_PATHBUF,x
            sec
            sbc   VR_N
            sta   VR_LEN
            lda   PRC_PATH_DST
            tay
            iny
            clc
            adc   VR_N
            tax
            inx
            lda   VR_LEN
            sta   VR_N
:mv         lda   PRC_PATHBUF,x
            sta   PRC_PATHBUF,y
            inx
            iny
            dec   VR_N
            bne   :mv
            ldx   PRC_PATH_DST
            lda   VR_LEN
            sta   PRC_PATHBUF,x
            clc
            rts

*---------------------------------------------------------------
* VR_XLATE_P -- if VR_PEND says the slot at PRC_PATH_DST holds a
* VIRTUAL path, make it physical. Carry clear = done (or nothing
* to do); carry set = the error is posted.
*---------------------------------------------------------------
VR_XLATE_P  lda   VR_PEND
            bne   VR_XLATE
            clc
            rts
VR_XLATE    stz   VR_PEND
            ldx   PRC_PATH_DST
            lda   PRC_PATHBUF,x
            clc
            adc   PRC_PATH_DST
            tay                     ;Y = index of the last char
            inx
            inx                     ;X = first char after '/'
            jsr   VR_LOOK
            bcs   :noent
            cmp   #VK_MNT
            beq   :mnt
            cmp   #VK_DEV
            bne   :map
            jmp   VR_DEVCALL        ;/dev never reaches the MLI
:map        jsr   VR_BVLEN
            bcs   :ret
            pha
            lda   #<PRC_PFXSAVE
            sta   P_PTR1
            lda   #>PRC_PFXSAVE
            sta   P_PTR1+1
            pla
            jmp   VR_INS            ;"/VOL" + the virtual path
:mnt        lda   VR_END
            sec
            sbc   PRC_PATH_DST
            dec                     ;A = bytes of "/mnt"
            sta   VR_N
            ldx   PRC_PATH_DST
            lda   PRC_PATHBUF,x
            sec
            sbc   VR_N              ;what is left after "/mnt"
            cmp   #2
            bcc   :noent            ;"/mnt" alone, or "/mnt/"
            jsr   VR_MNTCK          ;a volume the machine has?
            bcs   :ret              ;loopseg.s / procdevs.s
            lda   VR_N
            jmp   VR_DEL
:noent      lda   #MLIE_NOFILE
            jsr   PRC_FAIL_A
            sec
:ret        rts

*---------------------------------------------------------------
* VR_REV -- PRC_GETPFX's reverse map. PRC_PATHBUF holds the cwd
* as stored: a synthetic one (bit 7 set on its '/') or a
* physical prefix. A physical prefix under a MAP row of the boot
* volume loses the volume (/MAUX/BIN/ -> /bin/); any other gets
* "/mnt" put in front. Carry set = it would pass 64, posted.
*---------------------------------------------------------------
VR_REV      lda   PRC_PATHBUF+1
            bpl   :phys
            and   #$7F
            sta   PRC_PATHBUF+1
            clc
            rts
:phys       stz   PRC_PATH_DST
            jsr   VR_BVLEN
            bcs   :mnt
            sta   VR_N
            lda   PRC_PATHBUF
            cmp   VR_N
            bcc   :mnt
            beq   :mnt              ;the volume root itself
            ldx   #1
:vc         lda   PRC_PATHBUF,x
            jsr   PDEV_FOLD
            cmp   PRC_PFXSAVE,x
            bne   :mnt
            cpx   VR_N
            beq   :vcd
            inx
            bra   :vc
:vcd        inx
            lda   PRC_PATHBUF,x
            cmp   #"/"+$80
            bne   :mnt              ;longer name: another vol
            inx
            cpx   PRC_PATHBUF
            beq   :c2
            bcs   :mnt
:c2         ldy   PRC_PATHBUF
            jsr   VR_LOOK
            bcs   :mnt
            cmp   #VK_MAP
            bne   :mnt
            lda   VR_N
            jsr   VR_DEL            ;drop "/MAUX"
            ldy   VR_ROW
            lda   VR_TAB,y
            sta   VR_N
            ldx   #2
:lc         lda   PRC_PATHBUF,x
            ora   #$20              ;the row's name, lower case
            sta   PRC_PATHBUF,x
            inx
            dec   VR_N
            bne   :lc
            clc
            rts
:mnt        lda   #<VR_MNTS
            sta   P_PTR1
            lda   #>VR_MNTS
            sta   P_PTR1+1
            lda   #4
            jmp   VR_INS

*---------------------------------------------------------------
* PRC_VROOT -- SYS_VROOT (docs/VROOT.md). Parmlist, 4 bytes:
*   +0 op   +1/+2 pointer (MLI_PATHLO)   +3 arg
* op 3 PHYS:   the path at the pointer (MLI-shaped, virtual or
*              relative) comes back there PHYSICAL (df).
* ONLY op 3 is in every image (df needs it, and MAUXEXPR has 30
* bytes to spare); ops 0 ROW, 1 MOUNT and 2 UMOUNT go to
* VR_OTHER (procdev.s, or procdevs.s's ERR_NOSYS).
*---------------------------------------------------------------
PRC_VROOT
            jsr   VR_BVLEN          ;boot prefix, once
            lda   #4
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+1
            sta   PRC_USER_PTR
            lda   PRC_PARM+2
            sta   PRC_USER_PTR+1
            lda   PRC_PARM
            cmp   #3
            bne   :other
            jsr   PCPY_MLI_PATH     ;op 3: the physical path
            bcs   :rts3
            jmp   PRC_PB_OUT
:rts3       rts
:other      jmp   VR_OTHER
