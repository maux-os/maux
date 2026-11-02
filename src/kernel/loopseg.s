*---------------------------------------------------------------
* loopseg.s -- the loop device (docs/LOOP.md design A, homed per
* the ruling in docs/LOOP-S1.md): `mount IMAGE.po` attaches a
* ProDOS TREE file as unit $B0 (slot 3 drive 2, /RAM's slot).
* PLAY-ONLY, assembled under `org LSEG_ORG` after the KSEG block
* and cut off by scripts/split_kseg.py into the LSEG file, which
* KSEG_LOAD puts at $1300 at boot. It is ordinary main-RAM code:
* none of the nine KSEG rules bind it, and it may call the flat
* MLI wrappers.
*
*  LP_DRV      the DEVADR driver ProDOS calls (LC bank in, IRQs
*              on, no MLI). STATUS / READ / WRITE.
*  LP_OP45     SYS_VROOT ops 4 and 5 enter here (path RAW)
*  LP_ATTACH   SYS_VROOT op 4 (path in PRC_PATHBUF, PRC_PARM+3 =
*              the host unit the tool resolved)
*  LP_CLASS    SYS_VROOT op 5 (KFIX9): does a path name /, /dev
*              or /mnt once cwd, "." and ".." are resolved?
*  LP_DETACH   SYS_VROOT op 2 on unit $B0
*  LP_HBUSY    VR_BUSY's "is this unit the loop's host"
*
* The index block IS the block map: physical = lo : hi from the
* index block for loop block >> 8, indexed by the low byte. The
* host driver is reached through the trampoline at $FF00 -- the
* one instruction that must run from the LC after the host comes
* back is the one that turns RAMRD/RAMWRT off.
*---------------------------------------------------------------
LP_ATT      ds    1                 ;1 = attached
LP_HOST     ds    1                 ;host unit_num
LP_HVEC     ds    2                 ;host DEVADR vector
LP_CNT      ds    2                 ;blocks (from EOF)
LP_TAG      ds    1                 ;idx blk in SLOT, 0=none
LP_REF      ds    1                 ;the image file's refnum
LP_IBF      ds    1                 ;its pool io_buffer id
LP_SV       ds    6                 ;caller's $42-$47
LP_SAVE     ds    13                ;the $FF00 bytes we replace
LP_MISS     ds    2                 ;index-block fills, counted
LP_RO       ds    1                 ;1 = read-only (-r, locked)
*-- WRITEs that failed (saturates)
LP_WFAIL    ds    1
*-- 1 = a .2mg (read-only, stash)
LP_2M       ds    1
LP_OFF      ds    1                 ;its dataOffset, 1-64
*-- LP_TAIL (a .2mg read's carried bytes, 64) is not in the
*-- file: it is the first 64 bytes of K_BOUNCEBUF, which is dead
*-- for the whole of LP_2RD (docs/KFIX9-NOTES.md sec 1.1).
*-- LP_PATH (the image's physical path, 65) is a STATE cell of
*-- the KBSS chain (inc/mm.kbss.equ).
LP_TAIL     equ   K_BOUNCEBUF
*-- attach temporaries live in the LP_SLOT buffer, which
*-- the driver leaves alone until LP_ATT is set: not in the file
LP_S        equ   LP_SLOT           ;component start
LP_E        equ   LP_SLOT+1         ;index past the component
LP_L        equ   LP_SLOT+2         ;its length
LP_T        equ   LP_SLOT+3
LP_N        equ   LP_SLOT+4
LP_I        equ   LP_SLOT+5
LP_NIX      equ   LP_SLOT+6         ;index blocks in use
LP_LIM      equ   LP_SLOT+7         ;entries in the last (0=256)
LP_DB       equ   LP_SLOT+8         ;block to read (2)
LP_KEY      equ   LP_SLOT+10        ;the image's key block (2)
*-- `bye` parks the re-attach record where no reload reaches:
*-- the
*-- slot page is not in the file, and nothing uses it while
*-- detached
LP_RECM     equ   LP_SLOT+$7C       ;'L','P' = a record is here
LP_RECU     equ   LP_SLOT+$7E       ;host unit | flags
LP_RECP     equ   LP_SLOT+$80       ;the path, length first (65)

*-- the 13 bytes at $FF00: jsr $FF0A / sta RAMRDMAIN /
*-- sta RAMWRTMAIN / rts / jmp (LP_HVEC)
LP_TRAMP    dfb   $20,$0A,$FF,$8D,$02,$C0,$8D,$04,$C0,$60,$6C
            da    LP_HVEC
LP_2IMG     asc   '2IMG'
LP_PIN      dfb   $18,$AD,$99,$FE,$10 ;UpdateBitMap, ProDOS 2.4

*---------------------------------------------------------------
* LP_DRV -- the block driver.
*---------------------------------------------------------------
LP_DRV      cld
            lda   $42
            bne   :io
            ldx   LP_CNT
            ldy   LP_CNT+1
            lda   #0
            clc
            rts
:io         cmp   #3
            bcs   :e27              ;FORMAT: no
            cmp   #2
            bne   :nw
            ldx   LP_RO
            bne   :e2b              ;read-only: WRITE is $2B
:nw         lda   LP_ATT
            beq   :e28
            ldx   RD_DEVCNT
:dl         lda   RD_DEVLST,x       ;defined death: the host
            and   #$F0              ;must still be listed
            cmp   LP_HOST
            beq   :live
            dex
            bpl   :dl
:e28        lda   #$28
            bra   LP_ERR
:live       lda   $46               ;block < count
            cmp   LP_CNT
            lda   $47
            sbc   LP_CNT+1
            bcc   :inb
:e27        lda   #$27
*-- a WRITE that fails leaves its
LP_ERR      pha
*-- allocation in ProDOS's bitmap
            lda   $42
*-- buffer, dirty: throw it away
            cmp   #2
            bne   :n
            jsr   LP_DISC
            ldx   LP_WFAIL
            inx
            beq   :n
            stx   LP_WFAIL
:n          pla
            sec
            rts
:e2b        lda   #$2B
            bra   LP_ERR
:inb        ldx   #5
:sv         lda   $42,x
            sta   LP_SV,x
            dex
            bpl   :sv
            lda   LP_2M
            bne   LP_2RD
            jsr   LP_MAP
            bcs   LP_XIT
            jsr   LP_RDM
            bra   LP_XIT

*---------------------------------------------------------------
* LP_2RD -- READ of a .2mg block b. Its bytes are file bytes
* O+512b .. O+512b+511 (O = LP_OFF, 1-64): the tail of file
* block
* b and the first O bytes of block b+1. The caller's own buffer
* is the stash: block b+1 lands in it, its first O bytes are set
* aside in LP_TAIL, block b lands over it, the 512-O wanted
* bytes
* move down, the carried bytes close the page.
* LP_TAIL is K_BOUNCEBUF's first 64 bytes. BankCopy stages
* through that page ONLY for a bank->bank copy; its other writer
* is procfork.s. Both run from syscall bodies, not inside an MLI
* call. The timer ISR DOES reach BankCopy during one (TTY_TICK,
* TTY_POLL, TTY_COOK1, TTY_ED_CMIT, TTY_EDH_SAV), but those
* copies are main<->bank and never stage. check-kbss pins the
* set of bank->bank call sites: a new one must be reviewed for
* interrupt reachability first.
*---------------------------------------------------------------
LP_2RD      inc   $46
            bne   :a
            inc   $47
:a          jsr   LP_MAP
            bcs   LP_XIT
            jsr   LP_RDM
            bcs   LP_XIT
            ldy   LP_OFF
            dey
:hd         lda   ($44),y
            sta   LP_TAIL,y
            dey
            bpl   :hd
            jsr   LP_RST
*-- (check-loop K pokes K_BOUNCEBUF here: LP_TAIL lives there.
*-- Not on the line after the `bpl`: verilogapple's until_pc
*-- reports a hit on a branch's fall-through address whether or
*-- not the branch is taken)
LP_2STASHED jsr   LP_MAP
            bcs   LP_XIT
            jsr   LP_RDM
            bcs   LP_XIT
            jsr   LP_RST
*-- the source is the buffer + O
            lda   $44
            clc
            adc   LP_OFF
            sta   $46
            lda   $45
            adc   #0
            sta   $47
            ldy   #0
:p1         lda   ($46),y
            sta   ($44),y
            iny
            bne   :p1
            inc   $45
            inc   $47
            lda   #0
            sec
            sbc   LP_OFF
            tax                     ;256-O bytes on the 2nd page
:p2         lda   ($46),y
            sta   ($44),y
            iny
            dex
            bne   :p2
*-- Y = 256-O: the carried bytes
            ldx   #0
:tl         lda   LP_TAIL,x
            sta   ($44),y
            iny
            inx
            cpx   LP_OFF
            bne   :tl
            lda   #0
            clc
            bra   LP_XIT

LP_XIT      pha                     ;A, carry survive
            php
            jsr   LP_RST
            plp
            pla
            bcs   LP_ERRJ
LP_RTS      rts
LP_ERRJ     jmp   LP_ERR

*---------------------------------------------------------------
* LP_RDM -- read the mapped block ($46/$47 from LP_MAP) into the
* caller's buffer; a hole (0) is 512 zeros. Carry as the host's.
*---------------------------------------------------------------
LP_RDM      lda   $46
            ora   $47
            bne   :host
            tay                     ;Y = 0
:z          sta   ($44),y
            iny
            bne   :z
            inc   $45
:z2         sta   ($44),y
            iny
            bne   :z2
            dec   $45
            clc
            rts
:host       jmp   LP_HOSTC

*---------------------------------------------------------------
* LP_DISC -- discard ProDOS 2.4's volume-bitmap buffer if it is
* ours: bmaDev = $B0 -> bmaStat := 0 (not dirty), so the next
* FindBitMap re-reads it. Measured (docs/LOOP-S2-NOTES.md sec
* 2):
* a good call always leaves bmaStat clear, so a dirty one is a
* write that failed. Both cells are in the LC common page.
*---------------------------------------------------------------
LP_DISC     lda   BMA_DEV
            cmp   #RD_RAMUNIT
            bne   :x
            stz   BMA_STAT
:x          rts

*---------------------------------------------------------------
* LP_MAP -- $46/$47 = a block of the image FILE; out, carry
* clear: $46/$47 = its physical block on the host. Carry set, A
* =
* $27 for a hole (or the host's own error filling an index
* block).
* The index block IS the map: LP_IDX0 is pinned, LP_SLOT holds
* the one for the last other 256-block region (tag LP_TAG).
*---------------------------------------------------------------
LP_MAP      lda   $47
            beq   :i0
            cmp   LP_TAG
            beq   :slot
            tay                     ;miss: read index block Y
            stz   LP_TAG            ;invalid until it lands
            lda   LP_MAST,y         ;no such index block: a hole
*-- (only a -r mount lets one in)
            ora   LP_MAST+$80,y
            beq   :hole
            inc   LP_MISS
            bne   :mc
            inc   LP_MISS+1
:mc         lda   $46               ;the input outlives the fill
            pha
            lda   $47
            pha
            ldx   LP_MAST,y
            lda   LP_MAST+$80,y
            stx   $46
            sta   $47
            stz   $44
            lda   #>LP_SLOT
            sta   $45
            lda   #1
            sta   $42
            jsr   LP_HOSTC
            bcs   :fail
            jsr   LP_RST
            pla
            sta   $47
            pla
            sta   $46
            lda   $47
            sta   LP_TAG
:slot       ldy   $46
            ldx   LP_SLOT,y
            lda   LP_SLOT+$100,y
            bra   :go
:i0         ldy   $46
            ldx   LP_IDX0,y
            lda   LP_IDX0+$100,y
:go         stx   $46
            sta   $47
            txa
            ora   $47
            beq   :hole
            clc
            rts
*-- -r over a hole: it reads as zeros
:hole       lda   LP_RO
            beq   :e27
*-- $46/$47 = 0: nothing to read
            stz   $46
            stz   $47
            clc
            rts
:e27        lda   #$27
            sec
            rts
:fail       plx                     ;A and carry stay the host's
            plx
            rts


LP_RST      ldx   #5
:r          lda   LP_SV,x
            sta   $42,x
            dex
            bpl   :r
            rts

LP_HOSTC    lda   LP_HOST
            sta   $43
            jmp   $FF00

*---------------------------------------------------------------
* LP_HBUSY -- carry SET if unit PRC_PARM+3 is the host of the
* attached loop (umount of the host volume is busy).
*---------------------------------------------------------------
LP_HBUSY    lda   LP_ATT
            beq   :no
            lda   PRC_PARM+3
            cmp   LP_HOST
            bne   :no
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* LP_RD -- READ_BLOCK LP_DB from the host into PMLI_XFER_BUF.
* Carry set = failed. Leaves the kernel's LC bank selected.
*---------------------------------------------------------------
LP_RD       lda   LP_HOST
            sta   PML_RDBLK_PRM+MLI_BLK_UNIT
            lda   LP_DB
            sta   PML_RDBLK_PRM+MLI_BLK_NUMLO
            lda   LP_DB+1
            sta   PML_RDBLK_PRM+MLI_BLK_NUMHI
            jmp   PCASE_RD

*---------------------------------------------------------------
* LP_ATTACH -- SYS_VROOT op 4. IN: PRC_PATHBUF = the PHYSICAL
* path of the image, PRC_PARM+3 = the unit holding its volume.
* The file is OPENed first (it stays open for the life of the
* mount: ProDOS then refuses DESTROY, RENAME and a second
* writer), then walked to its key block from block 2.
*---------------------------------------------------------------
LP_ATTACH   lda   LP_ATT
            beq   :idle
            jmp   :busy
:idle
            lda   PRC_PARM+3        ;bit 1: re-attach what `bye`
            and   #2                ;detached (S4)
            beq   :fresh
            lda   LP_RECM
            cmp   #'L'
            bne   :ns
            lda   LP_RECM+1
            cmp   #'P'
            beq   :have
:ns         lda   #LPE_NOSAVED
            jmp   LP_FAILA
:have       stz   LP_RECM           ;once
            lda   LP_RECU
            sta   PRC_PARM+3
            ldy   LP_RECP
:rc         lda   LP_RECP,y
            sta   PRC_PATHBUF,y
            dey
            bpl   :rc
:fresh
            lda   RD_DEVCNT
            cmp   #13
            bcs   :noroom
            ldx   #4                ;the bitmap cells are 2.4's:
:pin        lda   BMA_PIN,x         ;UpdateBitMap must be the
            cmp   LP_PIN,x          ;bytes measured there
            bne   :badver
            dex
            bpl   :pin
            lda   BMA_PIN+14
            cmp   #$99
            bne   :badver
            lda   BMA_PIN+16
            cmp   #$60
            bne   :badver
            ldy   PRC_PATHBUF       ;kept for `bye` (S4)
:sp         lda   PRC_PATHBUF,y
            sta   LP_PATH,y
            dey
            bpl   :sp
            lda   PRC_PARM+3        ;unit | flags: bit 0 = -r
            and   #1
            sta   LP_RO
            stz   LP_WFAIL
            stz   LP_2M
            lda   PRC_PARM+3
            and   #$F0
            sta   LP_HOST
            jsr   PRC_ALLC_IBF      ;an open file is one of 8
            bcc   :gotib            ;FCBs: take a pool slot
            rts                     ;(error posted already)
:gotib      sta   LP_IBF
            stz   PML_OPN_PARMS+MLI_IOBUFLO
            jsr   PRC_IBF_HI_A
            sta   PML_OPN_PARMS+MLI_IOBUFHI
            jsr   PMLI_OPN_CALL
            beq   :opened
            pha
            lda   LP_IBF
            jsr   PRC_FR_IBF_A
            pla
            bra   LP_FAILA
:opened     lda   PML_OPN_PARMS+MLI_OPEN_REF
            sta   LP_REF
            bra   LP_WALK
:busy       lda   #MLIE_FILOPEN
            bra   LP_FAILA
:noroom     lda   #LPE_NOROOM
            bra   LP_FAILA
:badver     lda   #LPE_PRODOS
LP_FAILA    jsr   PRC_FAIL_A
            rts
*-- every failure after the OPEN comes here: close, then fail
LP_FAILC    pha
            lda   LP_REF
            jsr   PCLS_RAWREF_A
            lda   LP_IBF
            jsr   PRC_FR_IBF_A
            pla
            bra   LP_FAILA
LP_IOERR    lda   #$27
            bra   LP_FAILC
LP_NOTTREE  lda   #LPE_NOTTREE
            bra   LP_FAILC
LP_SPARSE   lda   #LPE_SPARSE
            bra   LP_FAILC
LP_NOFILE   lda   #MLIE_NOFILE
            bra   LP_FAILC

*-- skip the volume component: X ends on the '/' after it
LP_WALK     ldx   #2
:vol        lda   PRC_PATHBUF,x
            cmp   #"/"+$80
            beq   :voldone
            cpx   PRC_PATHBUF
            beq   LP_NOTTREE        ;"/VOL" alone
            inx
            bra   :vol
:voldone    lda   #2                ;volume directory key block
            sta   LP_DB
            stz   LP_DB+1
:comp       inx
            cpx   PRC_PATHBUF
            beq   :c1
            bcs   LP_NOTTREE        ;a trailing '/'
:c1         stx   LP_S
:fe         lda   PRC_PATHBUF,x
            cmp   #"/"+$80
            beq   :fend
            cpx   PRC_PATHBUF
            beq   :flast
            inx
            bra   :fe
:flast      inx
:fend       stx   LP_E
            txa
            sec
            sbc   LP_S
            sta   LP_L
:blk        jsr   LP_RD
            bcs   LP_IOERR
            lda   #4
            sta   P_PTR1
            lda   #>PMLI_XFER_BUF
            sta   P_PTR1+1
            lda   #13
            sta   LP_N
:ent        lda   (P_PTR1)
            and   #$F0
            beq   :nxt              ;deleted
            cmp   #$E0
            bcs   :nxt              ;a header
            lda   (P_PTR1)
            and   #$0F
            cmp   LP_L
            bne   :nxt
            ldy   #1
            ldx   LP_S
:cn         lda   PRC_PATHBUF,x
            jsr   PDEV_FOLD
            sta   LP_T
            lda   (P_PTR1),y
            jsr   PDEV_FOLD
            cmp   LP_T
            bne   :nxt
            cpy   LP_L
            beq   :hit
            inx
            iny
            bra   :cn
:nxt        clc
            lda   P_PTR1
            adc   #39
            sta   P_PTR1
            bcc   :nc
            inc   P_PTR1+1
:nc         dec   LP_N
            bne   :ent
            lda   PMLI_XFER_BUF+2   ;the next directory block
            sta   LP_DB
            lda   PMLI_XFER_BUF+3
            sta   LP_DB+1
            ora   LP_DB
            bne   :blk
            jmp   LP_NOFILE
:hit        ldy   #$11
            lda   (P_PTR1),y
            sta   LP_KEY
            iny
            lda   (P_PTR1),y
            sta   LP_KEY+1
            ldx   LP_E
            cpx   PRC_PATHBUF
            beq   :more
            bcs   :final            ;E > len: the last component
:more       lda   (P_PTR1)          ;a directory to descend into
            and   #$F0
            cmp   #$D0
            beq   :dirok
            jmp   LP_NOFILE
:dirok
            lda   LP_KEY
            sta   LP_DB
            lda   LP_KEY+1
            sta   LP_DB+1
            jmp   :comp
:final      lda   (P_PTR1)
            and   #$F0
            cmp   #$30
            beq   :tree
            jmp   LP_NOTTREE        ;seedling, sapling, dir
:tree
            ldy   #$1E              ;a write-protected image
*-- mounts read-only: the driver
            lda   (P_PTR1),y
            and   #2                ;answers $2B and throws away
            bne   :wok              ;the dirty bitmap (LP_DISC)
            lda   #1
            sta   LP_RO
:wok
            ldy   #$15
            lda   (P_PTR1),y
            sta   LP_T              ;EOF low
            iny
            lda   (P_PTR1),y
            tax                     ;EOF middle
            iny
            lda   (P_PTR1),y        ;EOF high
            lsr   a
            sta   LP_CNT+1
            txa
            ror   a
            sta   LP_CNT
            lda   LP_T
            adc   #$FF              ;carry = any remainder bit
            bcc   :cdone
            inc   LP_CNT
            bne   :cdone
            inc   LP_CNT+1
:cdone      lda   LP_CNT
            ora   LP_CNT+1
            bne   :nonempty
            jmp   LP_NOTTREE        ;an empty file
:nonempty
            jmp   LP_FILL

LP_IOE2     jmp   LP_IOERR
LP_SPA2     jmp   LP_SPARSE
*-- a whole index block is missing:
LP_NOIX     lda   LP_RO
*-- -r only, and it reads as zeros
            beq   LP_SPA2
            lda   LP_I
            beq   :z0
            jmp   LP_ADV
:z0         tay                     ;block 0 is the pinned copy
:zz         sta   LP_IDX0,y
            sta   LP_IDX0+$100,y
            iny
            bne   :zz
            jmp   LP_ADV
LP_FLC2     jmp   LP_FAILC

*---------------------------------------------------------------
* LP_FILL -- the master index (compacted), then every index
* block: a zero pointer below EOF is a hole (refused). Index
* block 0 is kept as the pinned LP_IDX0.
*---------------------------------------------------------------
LP_FILL     lda   LP_KEY
            sta   LP_DB
            lda   LP_KEY+1
            sta   LP_DB+1
            jsr   LP_RD
            bcs   LP_IOE2
            ldy   #0
:m          lda   PMLI_XFER_BUF,y
            sta   LP_MAST,y
            lda   PMLI_XFER_BUF+$100,y
            sta   LP_MAST+$80,y
            iny
            bpl   :m
            lda   LP_CNT+1          ;index blks = ceil(cnt/256)
            ldx   LP_CNT
            beq   :nz
            inc   a
:nz         sta   LP_NIX
            stz   LP_I
:ix         ldy   LP_I
            lda   LP_MAST,y
            sta   LP_DB
            lda   LP_MAST+$80,y
            sta   LP_DB+1
            ora   LP_DB
            beq   LP_NOIX
            jsr   LP_RD
            bcs   LP_IOE2
            lda   LP_I
            bne   :nocp
            ldy   #0                ;pin index block 0
:cp         lda   PMLI_XFER_BUF,y
            sta   LP_IDX0,y
            lda   PMLI_XFER_BUF+$100,y
            sta   LP_IDX0+$100,y
            iny
            bne   :cp
:nocp       stz   LP_LIM            ;0 = all 256
            lda   LP_I
            inc   a
            cmp   LP_NIX
            bne   :scan
            lda   LP_CNT
            sta   LP_LIM            ;the last block: cnt & 255
:scan       ldy   #0
:sc         lda   PMLI_XFER_BUF,y
            ora   PMLI_XFER_BUF+$100,y
            bne   :ok
            lda   LP_RO             ;a hole: -r tolerates it
            beq   :spar
:ok         iny
            cpy   LP_LIM
            bne   :sc
LP_ADV      inc   LP_I
            lda   LP_I
            cmp   LP_NIX
            bne   :ix
            jmp   LP_2IMGP
:spar       jmp   LP_SPARSE

*---------------------------------------------------------------
* LP_INST -- the install, the TRM's RAMIN order: vector, DEVCNT,
* DEVLST first. Masked; LP_ATT is the last store.
*---------------------------------------------------------------
LP_INST     lda   LP_HOST
            lsr   a
            lsr   a
            lsr   a
            tax
            lda   RD_NODEV,x        ;DEVADR[host]
            sta   LP_HVEC
            lda   RD_NODEV+1,x
            sta   LP_HVEC+1
            stz   LP_TAG
            php
            sei
            ldx   #12
:tr         lda   $FF00,x
            sta   LP_SAVE,x
            lda   LP_TRAMP,x
            sta   $FF00,x
            dex
            bpl   :tr
            ldx   RD_DEVCNT
            inx
:sh         lda   RD_DEVLST-1,x
            sta   RD_DEVLST,x
            dex
            bne   :sh
            lda   #RD_RAMUNIT
            sta   RD_DEVLST
            inc   RD_DEVCNT
            lda   #<LP_DRV
            sta   RD_RAMSLT
            lda   #>LP_DRV
            sta   RD_RAMSLT+1
            lda   #1
            sta   LP_ATT
            plp
            jmp   PRC_RET_OK0

*---------------------------------------------------------------
* LP_DETACH -- the inverse, then ON_LINE on $B0 (expect $28) to
* free the VCB, then CLOSE the image. The caller has already
* run VR_BUSY.
*---------------------------------------------------------------
LP_DETACH   lda   LP_ATT
            beq   :nodev
            jsr   LP_DET0
            jsr   PCASE_BANK        ;back to the kernel's bank
            jsr   LP_CLOSE
            lda   LP_WFAIL          ;the result: writes lost
            stz   LP_WFAIL
            jmp   PRC_RET_OK_A
:nodev      lda   #$28
            jmp   PRC_FAIL_A

*-- the unit out of DEVLST and DEVADR, the saved $FF00 bytes
*-- back,
*-- the bitmap buffer discarded, ON_LINE to free the VCB
LP_DET0     php
            sei
            ldx   RD_DEVCNT
:f          lda   RD_DEVLST,x
            and   #$F0
            cmp   #RD_RAMUNIT
            beq   :got
            dex
            bpl   :f
            bra   :tail
:got        cpx   RD_DEVCNT
            beq   :dec
            lda   RD_DEVLST+1,x
            sta   RD_DEVLST,x
            inx
            bra   :got
:dec        dec   RD_DEVCNT
:tail       lda   RD_NODEV
            sta   RD_RAMSLT
            lda   RD_NODEV+1
            sta   RD_RAMSLT+1
            ldx   #12
:rs         lda   LP_SAVE,x
            sta   $FF00,x
            dex
            bpl   :rs
            stz   LP_ATT
            plp
            jsr   LP_DISC           ;before the VCB goes
            lda   #RD_RAMUNIT
            sta   RDS_PARMS+1
            jmp   PMLI_ONLN_CL      ;expect $28: frees the VCB

LP_CLOSE    lda   LP_REF
            jsr   PCLS_RAWREF_A
            lda   LP_IBF
            jsr   PRC_FR_IBF_A
            stz   LP_RO
            stz   LP_2M
            rts

*---------------------------------------------------------------
* LP_BYEDET -- `bye`, from the cold segment, after its last way
* to fail (docs/LOOP-S2.md S4): leave the record that lets the
* `bye` tool re-attach this image, then detach -- the stock /RAM
* body back at $FF00 BEFORE PRC_RAMRECONN hands /RAM to the
* tenant. No PCASE_BANK: this runs under the cold segment's bank
* and must come back to it.
*---------------------------------------------------------------
LP_BYEDET   lda   LP_ATT
            beq   :none
            lda   #'L'
            sta   LP_RECM
            lda   #'P'
            sta   LP_RECM+1
            lda   LP_HOST
*-- the -r bit; a .2mg is ro anyway
            ora   LP_RO
            sta   LP_RECU
            ldy   LP_PATH
:pc         lda   LP_PATH,y
            sta   LP_RECP,y
            dey
            bpl   :pc
            jsr   LP_DET0
            lda   LCBANK1_RAM       ;the cold segment's bank, as
            lda   LCBANK1_RAM       ;PRC_BYE reselects it
            jsr   LP_CLOSE
            stz   LP_WFAIL
            rts
:none       stz   LP_RECM           ;no loop, no record: stale
            rts                     ;bytes may spell 'LP'

*---------------------------------------------------------------
* LP_2IMGP -- LP_FILL's last step. A 2IMG container is read-
* only.
*---------------------------------------------------------------
*-- a 2IMG container: ProDOS order (format 1), 1-64 bytes of
*-- header before the data, numBlocks whole blocks in the file.
*-- Served read-only through LP_2RD (docs/LOOP.md sec 4).
LP_2IMGP    lda   LP_IDX0
            sta   LP_DB
            lda   LP_IDX0+$100
            sta   LP_DB+1
            jsr   LP_RD
            bcs   :ioe
            ldy   #3
:m2         lda   PMLI_XFER_BUF,y
            cmp   LP_2IMG,y
            bne   :plain
            dey
            bpl   :m2
            lda   PMLI_XFER_BUF+$0C ;imageFormat = 1
            cmp   #1
            bne   :bad
            lda   PMLI_XFER_BUF+$0D
            ora   PMLI_XFER_BUF+$0E
            ora   PMLI_XFER_BUF+$0F
            ora   PMLI_XFER_BUF+$16 ;numBlocks fits 16 bits
            ora   PMLI_XFER_BUF+$17
            ora   PMLI_XFER_BUF+$19 ;dataOffset fits a byte
            ora   PMLI_XFER_BUF+$1A
            ora   PMLI_XFER_BUF+$1B
            bne   :bad
            lda   PMLI_XFER_BUF+$14
            ora   PMLI_XFER_BUF+$15
            beq   :bad              ;no blocks
            lda   PMLI_XFER_BUF+$18
            beq   :bad
            cmp   #65
            bcs   :bad              ;past 64 bytes
            sta   LP_OFF
*-- the file holds numBlocks + 1
            sec
            lda   LP_CNT            ;blocks (EOF/512 rounded up)
            sbc   PMLI_XFER_BUF+$14
            tax
            lda   LP_CNT+1
            sbc   PMLI_XFER_BUF+$15
            bcc   :bad
            stx   LP_DB
            ora   LP_DB
            beq   :bad
            lda   PMLI_XFER_BUF+$14
            sta   LP_CNT
            lda   PMLI_XFER_BUF+$15
            sta   LP_CNT+1
            lda   #1
            sta   LP_2M
            sta   LP_RO
:plain      jmp   LP_INST
:bad        lda   #LPE_2MG
            jmp   LP_FAILC
:ioe        jmp   LP_IOERR

*---------------------------------------------------------------
* VR_MNTCK -- /mnt/NAME names a volume the machine has (KFIX5).
* Called by VR_XLATE's :mnt arm (vroot.s) BEFORE the "/mnt" is
* stripped, so ProDOS is never asked for a volume it would only
* find by ON_LINEing every drive: `ls /mnt/GONE` and its five
* twins spun an unmounted Disk ][ for a second, and
* `ls /mnt/FLOPPY` LISTED the unmounted floppy that same search
* found, against docs/VROOT.md ("/mnt holds MOUNTED volumes")
* and the never-poll ruling of 2026-09-30.
*
* NAME passes if it is, in this order: the boot volume (a
* compare, no I/O -- nearly every path), the volume of a FAST
* unit (one ON_LINE of that unit each, all fast units first), or
* the volume of a Disk ][ the user MOUNTED (its ON_LINE spins
* that drive, which `mount` already did once on request). An
* unmounted Disk ][ is never asked. Not found: $45, ProDOS's own
* volume-not-found, posted, carry set.
*
* CALLED FROM THE COLD SEGMENT, IT DOES NOTHING. kbye.s (KSEG,
* under $C083) translates the tenant's path through here twice,
* the second time just before BYE_LEAVE. An ON_LINE there is
* wrong twice over: PCASE_BANK's $C08B under $D4xx code unmaps
* the code that is running (KFIX5 review B1), and kbye.s relies
* on nothing touching $C080-$C08F or the MLI after its state is
* stamped. The path was validated by `bye` itself in userland,
* through this routine from flat code, before SC_BYE was called.
* RDLCBNK2 bit 7 at entry ($C083 selected) says who is calling.
* Gate: check-tenant row 8 (no ON_LINE once PRC_BYE runs).
* IN:  VR_N = bytes of "/mnt"; PRC_PATH_DST names the slot.
* OUT: carry clear = pass; carry set = refused, error posted.
* KEEPS VR_N. Clobbers A, X, Y, P_PTR1/2, VR_START/END/LEN.
* LSEG, not KSEG: the segment has 18 B free, this is main RAM.
* Stub twin: procdevs.s (clc, rts) for every image without one.
*---------------------------------------------------------------
MC_T        ds    1                 ;one folded character
MC_U        ds    1                 ;PDL_ONE's answer
MC_X        ds    1                 ;DEVLST index (ONLINE: X)
MC_PASS     ds    1                 ;0 fast, 3 mounted Disk ][
MC_CN       ds    1                 ;cached name length, 0 none
MC_CB       ds    15                ;...its name, 7-bit

VR_MNTCK    lda   RDLCBNK2          ;bit 7: the segment's bank
            bpl   :flat
            clc                     ;a segment caller: pass
            rts
:flat       lda   VR_N
            clc
            adc   PRC_PATH_DST
            adc   #2
            tax                     ;first character of NAME
            ldy   PRC_PATH_DST
            lda   PRC_PATHBUF,y
            clc
            adc   PRC_PATH_DST
            tay                     ;last character of the path
            jsr   VR_LOOK           ;-> VR_START, VR_END, VR_LEN
            lda   VR_LEN
            beq   :no               ;"/mnt//x"
            cmp   #16
            bcs   :no               ;no volume name is that long
            jsr   VR_BVLEN          ;A = length of "/VOL"
            bcs   :ret              ;(no prefix: posted)
            dec
            ldx   #<PRC_PFXSAVE
            stx   P_PTR1
            ldx   #>PRC_PFXSAVE
            stx   P_PTR1+1
            ldx   #2
            jsr   MC_CMP
            bcs   :ok
*-- the last volume the walk below found: a path under a
*-- non-boot cwd names it again on every call
            lda   #<MC_CB
            sta   P_PTR1
            lda   #>MC_CB
            sta   P_PTR1+1
            lda   MC_CN
            ldx   #0
            jsr   MC_CMP
            bcs   :ok
            stz   MC_PASS
:pass       ldx   RD_DEVCNT
:unit       stx   MC_X
            jsr   PDL_ONE           ;DSSS0000 | bit0 Disk ][
            sta   MC_U              ;         | bit1 mounted
            and   #3
            cmp   MC_PASS
            bne   :next
            lda   MC_U
            and   #$F0
            sta   RDS_PARMS+1
            jsr   PMLI_ONLN_CL
            jsr   PCASE_BANK        ;kernel LC bank; C kept
            bcs   :next             ;no volume on that unit
            lda   #<PMLI_XFER_BUF
            sta   P_PTR1
            lda   #>PMLI_XFER_BUF
            sta   P_PTR1+1
            lda   PMLI_XFER_BUF
            and   #$0F              ;the name's length
            ldx   #1
            jsr   MC_CMP
            bcc   :next
            jsr   MC_KEEP           ;found: remember the name
            bra   :ok
:next       ldx   MC_X
            dex
            bpl   :unit
            lda   MC_PASS
            bne   :no
            lda   #3
            sta   MC_PASS
            bra   :pass
:no         lda   #MLIE_NOVOL
            jsr   PRC_FAIL_A
            sec
            rts
:ok         clc
:ret        rts

*-- MC_CMP -- is the name at (P_PTR1)+X, A characters, NAME (the
*-- path component VR_START..VR_END)? Both sides folded to 7-bit
*-- upper case (PDEV_FOLD). Carry set = equal.
MC_CMP      cmp   VR_LEN
            bne   :ne
            txa
            tay
            ldx   VR_START
:c          lda   (P_PTR1),y
            jsr   PDEV_FOLD
            sta   MC_T
            lda   PRC_PATHBUF,x
            jsr   PDEV_FOLD
            cmp   MC_T
            bne   :ne
            inx
            iny
            cpx   VR_END
            bne   :c
            sec
            rts
:ne         clc
            rts

*-- (MC_CMP with A = 0 never matches: VR_LEN is 1-15 here.)
*-- MC_KEEP -- remember NAME (folded) as the last volume the
*-- ON_LINE walk found. A POSITIVE cache only: a miss is never
*-- stored. Dropped by MC_FLUSH -- mount, umount and a loop
*-- attach/detach (every SYS_VROOT op: VR_OTHER) -- and
*-- by every `bye` (this segment is reloaded). Not covered, and
*-- named: a swapped removable medium keeps its old name
*-- accepted; the MLI's own answer for the gone volume ($45) is
*-- then what the caller sees.
MC_KEEP     ldx   VR_START
            ldy   #0
:k          lda   PRC_PATHBUF,x
            jsr   PDEV_FOLD
            sta   MC_CB,y
            inx
            iny
            cpx   VR_END
            bne   :k
            sty   MC_CN
            rts

MC_FLUSH    stz   MC_CN
            rts

*---------------------------------------------------------------
* LP_OP45 -- SYS_VROOT ops 4 and 5 arrive here with the user's
* path already copied RAW into slot 0 (PRC_ABSPATH has joined it
* to the cwd). Op 4 wants it physical; op 5 wants it as typed,
* resolved by LP_CLASS.
*---------------------------------------------------------------
LP_OP45     lda   PRC_PARM
            cmp   #5
            beq   LP_CLASS
            jsr   VR_XLATE_P
            bcs   :r
            jmp   LP_ATTACH
:r          rts

*---------------------------------------------------------------
* LP_CLASS -- SYS_VROOT op 5 (KFIX9; docs/VROOT.md): what does a
* path NAME once the cwd, "." and ".." are resolved? A = 0 an
* ordinary path, $80 "/", $81 "/dev", $82 "/mnt" -- liba's
* RD_SYN_* values, so readsyn.s stores it as it is. This was
* RD_CANON + RD_SYNCHK in every program that puts readsyn.s.
*
* No canonical string is built. Two facts about the resolved
* path decide the answer, and both survive a pop: DEPTH
* (components on the stack) and the FIRST component's kind
* (P_IDX, set when depth goes 0 -> 1: VR_LOOK's own row kinds).
* ".." at depth 0 stays there, like RD_CANON and MKP_POP.
*
* Slot 0 is VIRTUAL when PRC_ABSPATH left VR_PEND set (typed
* "/", or a synthetic cwd) and PHYSICAL after a real cwd, which
* VR_REV spells virtually (cwd "/MAUX/BIN" is "/bin"). A path
* still relative has no cwd of its own: ProDOS's prefix, the
* boot volume's root, "/mnt/MAUX/" -- depth 2, first kind MNT
* (what PRC_GETPFX answers for a process that never chdir'd).
* A joined path past 64 bytes is refused by the copier and an
* error comes back; the caller reads that as "ordinary".
*---------------------------------------------------------------
LP_CLASS    lda   PRC_PATHBUF
            bne   :go
            jmp   PRC_RET_OK_A      ;empty: A = 0, ordinary
:go         stz   P_COUNT           ;depth
            stz   P_IDX             ;first component's kind
            ldx   #1
            lda   PRC_PATHBUF+1
            cmp   #"/"+$80
            bne   :norel
            lda   VR_PEND
            bne   :virt
*-- A real cwd, joined: VR_REV respells the cwd, and must reach
*-- only the cwd. At a volume root it would also look at the
*-- first TYPED component (`cd /mnt/MAUX; BIN/../..`), so a
*-- root cwd is "/mnt" and the physical names, no VR_REV.
            jsr   VR_BVLEN
            bcs   :vroot
            sta   P_TMP2
            lda   K_CWD_BUF         ;the cwd's length
            sec
            sbc   P_TMP2
            cmp   #2                ;"/VOL" or "/VOL/" only
            bcc   :vroot
            jsr   VR_REV
            bcc   :virt
            rts                     ;too long to spell: failed
:virt       ldx   #2                ;past the leading "/"
            bra   :comp
:vroot      lda   #1                ;"/mnt" ...
            sta   P_COUNT
            lda   #VK_MNT
            sta   P_IDX
            ldx   #2                ;... then VOL, as it is
            bra   :comp
:norel      lda   #2                ;no cwd: /mnt/MAUX/
            sta   P_COUNT
            lda   #VK_MNT
            sta   P_IDX
:comp       ldy   PRC_PATHBUF       ;Y = last index
            jsr   VR_LOOK
            bcc   :kind
            lda   #0
:kind       sta   P_TMP
            lda   VR_LEN
            beq   :next             ;"//" or a trailing "/"
            cmp   #3
            bcs   :push
            ldx   VR_START
            lda   PRC_PATHBUF,x
            cmp   #'.'
            bne   :push
            lda   VR_LEN
            dec   a
            beq   :next             ;"." goes
            lda   PRC_PATHBUF+1,x
            cmp   #'.'
            bne   :push
            lda   P_COUNT           ;".." pops, clamped at "/"
            beq   :next
            dec   P_COUNT
            bra   :next
:push       inc   P_COUNT
            lda   P_COUNT
            dec   a
            bne   :next
            lda   P_TMP
            sta   P_IDX
:next       ldx   VR_END
            cpx   PRC_PATHBUF
            bcs   :done
            inx                     ;past the "/" that ended it
            bra   :comp
:done       lda   P_COUNT
            beq   :root
            dec   a
            bne   :ret0
            lda   P_IDX
            cmp   #VK_DEV
            bcc   :ret0
            cmp   #VK_MNT+1
            bcs   :ret0
            adc   #$7F              ;DEV -> $81, MNT -> $82
            bra   :ret              ;(carry is clear: A < M)
:root       lda   #$80
            bra   :ret
:ret0       lda   #0
:ret        jmp   PRC_RET_OK_A
