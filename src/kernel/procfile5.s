*---------------------------------------------------------------
* procfile5.s -- the synthetic /DEV namespace.
*
* SPLIT OUT OF procfile3.s, 2026-08-30, and the reason is a
* ceiling rather than a taxonomy: procfile3.s is the LARGEST PUT
* of fifteen kernel manifests, and those manifests sat at 16,097
* bytes of as's 16,128-byte source window -- 31 bytes of
* headroom. Anything at all added to procfile3.s puts all
* fifteen over, so `as` (and only as, which is what makes this a
* SELF-HOSTING ceiling merlin32 cannot see) would refuse them
* with "source too large". docs/S9-PLAN.md section 5 names
* splitting the charged put as the remedy; the window charges
* resident + MAX(put), so a new small put costs nothing.
*
* Kernel modules are one flat symbol space, so PRC_OPEN calls
* straight into here with no declaration -- the same convention
* PRC_READ/PRC_WRITE's own move recorded in procfd.s.
*---------------------------------------------------------------

*---------------------------------------------------------------
* PRC_DEVOPEN -- resolve PRC_PATHBUF against the synthetic /DEV
* namespace.
*
* maux has NO on-disk device nodes and no mknod, and the reason
* is GNO/ME rather than anything about ProDOS metadata.
*
* GNO/ME is the one shipped, field-tested Unix for an Apple --
* the IIgs, over GS/OS -- and it has NO mknod.  Not "a limited
* mknod": the string does not occur anywhere in its published
* documentation.  Its devices are built-in kernel drivers
* (.TTYCO console, .TTYA[0-9,A-F] serial, .PTYQ[0-9,A-F] ptys,
* .NULL) which its kernel reference describes as "not installed
* like normal GS/OS drivers, but ... accessed the same way",
* through "the same Open, Read, Write, and Close calls that are
* used on files".  That is a synthetic namespace, and it is what
* is copied here.
*
* THE ARGUMENT FROM ProDOS RESERVED storage_type VALUES WAS
* WITHDRAWN.  An earlier version of this header leaned on the
* TRM's "all other values are reserved for future use" -- but
* ProDOS 8 has been end-of-life since the 1990s, so a label
* reserving values for a future that never came binds nobody.
* What survives is the CONSEQUENCE, not the label: a
* storage_type no reader knows still confuses every tool that
* reads these
* volumes, a2til included, and every gate in this tree reads its
* images with a2til.
*
* And the argument that never depended on Apple at all:
* /DEV/TTY0 names a RUNNING KERNEL's object, not a property of
* a disk.  A
* node written to a volume would travel to a machine whose
* console set differs.  Devices belong to the system, so the
* system is what names them.  See docs/CONSOLE.md sec 13.
*
* THE SPELLING IS MAUX'S, NOT GNO'S, DELIBERATELY, AND THE
* REASON IS THAT GNO'S NAMES SERVE A GOAL MAUX DOES NOT HAVE.
* .TTYCO and .NULL are GS/OS device names -- the native Apple
* character-device convention, a leading period, which cannot
* collide with a filename because a ProDOS name must BEGIN WITH
* A LETTER.  GNO used that convention because it is, in its own
* FAQ's words, "intended to be a REPLACEMENT for ORCA/Shell"
* while still running "the various ORCA languages and (the
* majority of) utilities" -- GS/OS binaries that open GS/OS
* device names.  Keeping that ecosystem working REQUIRED the
* GS/OS spelling.
*
* maux inherits no such ecosystem.  ProDOS 8's MLI offers no
* character-device namespace at all (that is a GS/OS feature),
* so there are no //e programs whose names we would be
* honouring, and a GNO binary is 65816 code that cannot run here
* regardless.  Copying .TTYCO would be cargo cult: it buys
* nothing and costs the name every shell script and every human
* habit already uses.  maux is Unix; /dev/null is what a human
* types.  The leading-dot mechanism is still worth remembering
* -- it is collision-proof by construction -- if an alias is
* ever wanted.
*
* KNOWN CONSEQUENCE, the same one Unix's own devfs has: a volume
* actually named DEV is shadowed by this namespace.  Worth
* stating because it was period practice -- GNO installed itself
* into /dev/gno, with /dev/gno/src and /dev/gno/orca beneath it.
*
* Entry: PRC_PATHBUF holds the caller's path, MLI count-prefixed
*        -- PCPY_MLI_PATH has run and has bounded it under 65.
* Exit:  carry SET             -- not a /DEV path at all; the
*                                 caller opens an ordinary file.
*        carry CLEAR, A != 0   -- A is the fd-table handle. For
*                                 tty/null/ser this is a raw
*                                 handle (>= FD_DEV_BASE); for
*                                 /dev/sNdM (docs/DEV-BLOCK.md,
*                                 PDEV_TRY_BLK below) it is a
*                                 fresh OFT_BLK index -- the
*                                 SAME byte space PRC_CUR_FDOBJ
*                                 already splits on
*                                 `cmp #FD_DEV_BASE`, so no new
*                                 marker type is needed:
*                                 PRC_OPEN stores whichever it
*                                 got, unchanged.
*        carry CLEAR, A == 0   -- a /DEV path naming no device;
*                                 the error is already posted.
*        Z reflects A on both carry-clear exits.
*
* A /DEV path is answered ENTIRELY here: an unrecognised name is
* $46 (file not found), never a fall-through to ProDOS, so a
* volume that happens to be called DEV cannot shadow a device.
*---------------------------------------------------------------
PRC_DEVOPEN
            lda   PRC_PATHBUF
            cmp   #6              ;"/DEV/" plus one name char
            bcc   :notdev
            ldy   #1
:pfx        lda   PRC_PATHBUF,y
            jsr   PDEV_FOLD
            cmp   PDEV_PFX-1,y
            bne   :notdev
            iny
            cpy   #6
            bne   :pfx
            sec
            lda   PRC_PATHBUF
            sbc   #5
            sta   P_COUNT         ;name length after the /DEV/
            stz   P_IDX
:ent        ldx   P_IDX
            lda   PDEV_TAB,x      ;entry name length, 0 ends
            beq   :unknown
            sta   P_TMP
            clc
            adc   P_IDX
            inc   a               ;past the length byte
            inc   a               ;past the handle byte
            sta   P_TMP2          ;offset of the next entry
            lda   P_TMP
            cmp   P_COUNT
            bne   :next
            ldy   #0
:chr        cpy   P_COUNT
            beq   :match
            inx
            iny
            lda   PRC_PATHBUF+5,y
            jsr   PDEV_FOLD
            cmp   PDEV_TAB,x
            beq   :chr
:next       lda   P_TMP2
            sta   P_IDX
            bra   :ent
:match      ldx   P_TMP2
            dex                   ;handle sits before the next
            lda   PDEV_TAB,x      ;entry -- nonzero, so Z clear
            cmp   #FD_SER0
            bne   :gothdl
            ldy   SER_PRESENT     ;Y, not A -- A still holds the
            bne   :gothdl         ;handle this routine returns
            jmp   :unknown        ;SSC undetected at boot -- the
                                  ;same "no such device" path
:gothdl     clc
            rts
:notdev     sec
            rts
:unknown
* -- docs/DEV-BLOCK.md's /dev/sNdM block devices: PDEV_TRYBLK_G
* -- is a glue label (procdev.s, real; procdevs.s, stub) called
* -- UNCONDITIONALLY (2026-09-27, coordinator review, DECISION 1
* -- -- module choice replaces `do ]KSEG_WANT`, which nas cannot
* -- assemble at all). The stub always answers carry SET ("not
* -- an
* -- sNdM path"), falling straight through to the ORIGINAL "no
* -- such device" answer below, unchanged.
            jsr   PDEV_TRYBLK_G
            bcs   :noblk        ;not shaped like sNdM at all
            rts                 ;matched -- PDEV_TRY_BLK already
                                ;leaves the full PRC_DEVOPEN
                                ;exit (found+allocated, or
                                ;not-found, error posted)
:noblk      lda   #MLIE_NOFILE
            jsr   PRC_FAIL_A
            lda   #0
            clc
            rts


*---------------------------------------------------------------
* PDEV_FOLD -- one path byte to 7-bit upper case.
*
* Both halves of that matter.  The high bit is not settled at
* this layer: liba's own `asc "..."` literals arrive high-bit
* set while characters typed at a console arrive stripped (see
* tty2.s), and ProDOS itself ignores the bit.  And the case fold
* is not decoration -- ProDOS compares case-insensitively, and
* nobody types /DEV/TTY0.  They type /dev/tty0.
*---------------------------------------------------------------
PDEV_FOLD   and   #$7F
            cmp   #$61            ;'a'
            bcc   :nofold
            cmp   #$7B            ;'z'+1
            bcs   :nofold
            and   #$DF
:nofold     rts

*-- 7-bit ASCII: `asc '..'` clears the high bit where `asc ".."`
*-- would set it.  PDEV_FOLD normalises the path side to match.
PDEV_PFX    asc   '/DEV/'

*-- Device table: length, upper-case name, fd-table handle; a
*-- zero length ends it.  Adding a device is one entry here plus
*-- its read/write arms in procmli.s/procmli3.s.
PDEV_TAB    dfb   3
            asc   'TTY'           ;the controlling terminal
            dfb   FD_TTY0
            dfb   4
            asc   'TTY1'
            dfb   FD_TTY0
            dfb   4
            asc   'TTY2'
            dfb   FD_TTY1
            dfb   4
            asc   'TTY3'
            dfb   FD_TTY2
            dfb   4
            asc   'TTY4'
            dfb   FD_TTY3
            dfb   4
            asc   'NULL'
            dfb   FD_NULL
            dfb   5
            asc   'TTYA0'
            dfb   FD_SER0
            dfb   0

*-- THE NAMES ARE ONE-BASED, THE HANDLES ARE ZERO-BASED, and
*-- that is deliberate: /DEV/TTY1 is the FIRST console, as it is
*-- on Linux and as `chvt 1` means. The first cut of this table
*-- had /DEV/TTY0 -> FD_TTY0, which invited exactly the
*-- off-by-one it then produced: `echo x > /dev/tty2` wrote to
*-- the THIRD console while `chvt 2` displayed the second, so
*-- two namespaces built in one session disagreed with each
*-- other. There is no /DEV/TTY0 -- nobody counts a zeroth
*-- console, and its only real effect was to make that mistake
*-- look plausible.
*--
*-- TTY1..TTY4 were DELIBERATELY ABSENT until 2026-08-30: while
*-- PRC_READ/PRC_WRITE discarded the handle all four names
*-- reached console 1, and a namespace whose entries silently
*-- alias is worse than a shorter one. Live now that those arms
*-- carry the console through.

