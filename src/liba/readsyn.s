*---------------------------------------------------------------
* readsyn.s -- readdir.s's SYNTHETIC half: the directories the
* kernel owns and no disk carries. Split from readdir.s
* 2026-10-17 (docs/GLOB-VROOT.md) so that `sh`'s glob can link
* the namespace policy for `/`, `/dev` and `/mnt` WITHOUT
* linking the ~600-byte ProDOS directory walker it has its own
* copy of -- and so that there is exactly ONE place that says
* what those three directories contain (finding 9: a second copy
* of the policy is the thing that drifts). mount and umount
* do not walk these directories at all: since KFIX8 they put
* readsys.s (the SC_* gates) and readfold.s (RD_FOLD) and NOT
* this file, which was ~790 dead bytes in each of them. The
* SC_* gates it calls live in readsys.s, which every program
* that puts this file puts right after it.
*
* One assembly stream: every consumer of readdir.s puts this
* file IMMEDIATELY after it, and every rule in readdir.s's
* header applies unchanged. The code is the old readdir.s text,
* moved verbatim, plus the two entry points below that OPENDIR
* and READDIR used to open-code:
*
*  SYN_OPEN  IN: A/X = lo/hi of an MLI-shaped (count-prefixed)
*            pathname. Stores it in RD_OPARM_PATH (the real
*            OPENDIR open reads it from there), decides whether
*            it names `/`, `/dev` or `/mnt` (SYS_VROOT op 5: the
*            KERNEL resolves the cwd, "." and ".." -- it was
*            RD_SYNCHK + RD_CANON, 257 B in every program that
*            puts this file), and if so opens the walk
*            (RD_SYN_DEVLST; no device I/O).
*            OUT: carry CLEAR = synthetic, open, READ it with
*            RD_READSYN; carry SET = an ordinary path, RD_DFD
*            = 0, nothing opened (the usual "not mine" sense of
*            a set carry). CLOBBERS: A, X, Y, PTR0.
*  RD_READSYN  IN: PTR0 = a caller-owned RD_SIZE-byte
*            record, A = RD_DFD (the mode SYN_OPEN set).
*            OUT: as READDIR's synthetic half -- carry clear =
*            record filled; carry set, A=0 = exhausted. Only
*            valid after a SYN_OPEN that returned carry CLEAR.
*            There is nothing to close (CLOSEDIR just clears the
*            mode). READDIR jumps here; sh's glob does the same
*            inline (shpth2.s :synwalk). This was SYN_READ, a
*            7-byte A/X-to-PTR0 front door only sh called, so
*            nine other programs carried it dead (KFIX8:
*            check-modules' dead routine audit found it).
*---------------------------------------------------------------

* -- $80/$81, not 1/2: RD_DFD is an ALIAS of RD_DFD (real
* -- mode's own fd), so its "synthetic" values must be
* -- distinguishable from every real fd (1-8, the io_buffer
* -- count) by a single `bpl`/`bmi` test on bit 7 -- see
* -- libabss.s's own comment on RD_DFD for why it is an
* -- alias at all.
RD_SYN_ROOT equ   $80
RD_SYN_DEV  equ   $81
RD_SYN_MNT  equ   $82

SYN_OPEN    sta   RD_OPARM_PATH
            stx   RD_OPARM_PATH+1
            sta   RD_RPARM+1        ;SYS_VROOT {5, path}: what
            stx   RD_RPARM+2        ;does the path NAME? (KFIX9)
            lda   #5
            sta   RD_RPARM
            lda   #<RD_RPARM
            ldx   #>RD_RPARM
            jsr   SC_VROOT
            bcc   :named
            lda   #0                ;refused: an ordinary path
:named      sta   RD_DFD
            cmp   #RD_SYN_ROOT
            bcc   :notsyn          ;bit 7 clear: ordinary path
            jsr   RD_SYN_DEVLST    ;-> RD_DIRBUF/RD_FCNT, no
                                   ;device I/O either way
            stz   RD_ENTLEN
            stz   RD_EPB
            clc
            rts
:notsyn     sec
            rts

RD_READSYN  cmp   #RD_SYN_DEV
            bne   :nd
            jmp   RD_READDEV
:nd         cmp   #RD_SYN_MNT
            bne   :rdroot
            jmp   RD_READMNT
:rdroot     jmp   RD_READROOT


*---------------------------------------------------------------
* RD_SYN_DEVLST -- one SYS_DEVLIST call into RD_DIRBUF, count
* into RD_FCNT. NO device is touched (docs/DEVFS.md) -- shared
* by both synthetic OPENDIRs. CLOBBERS: A, X, PTR0.
*---------------------------------------------------------------
RD_SYN_DEVLST
            lda   #<RD_DIRBUF
            sta   PTR0
            lda   #>RD_DIRBUF
            sta   PTR0+1
            jsr   SC_DEVLIST
            sta   RD_FCNT
            stz   RD_FCNT+1         ;ls reads the HIGH byte at
                                   ;:opok; BSS is not zero on
                                   ;dirty RAM (KFIX11)
            rts

*---------------------------------------------------------------
* RD_ZEROSIZE -- zero a fresh record's RD_EOF/RD_MDATE/RD_MTIME/
* RD_BLOCKS (9 bytes, offsets RD_EOF..RD_BLOCKS+1) at (PTR0) --
* every synthetic record (a volume, `dev`, or a device) reports
* zero size/date. CLOBBERS: A, Y.
*---------------------------------------------------------------
RD_ZEROSIZE ldy   #RD_EOF
            lda   #0
:zloop      sta   (PTR0),y
            iny
            cpy   #RD_EOF+9
            bne   :zloop
            rts

*---------------------------------------------------------------
* RD_READMNT -- READDIR for the synthetic `/mnt`, VROOT.md:
* the volumes. RD_ENTLEN walks RD_DIRBUF, SYS_DEVLIST's bytes
* (bit 0 = a built-in Disk ][, bit 1 = one the user MOUNTED). A
* Disk ][ that is not mounted is skipped with no SYS_ONLINE call
* at all -- the 2026-09-30 operator ruling, never poll a 5.25"
* drive to list anything -- and a mounted one gets exactly ONE,
* on its own unit (never unit 0). TRM 4.4.6: byte 0 of a
* per-unit ON_LINE entry is DSSS in the high nibble, the name
* length in the low nibble.
*---------------------------------------------------------------
RD_READMNT  lda   RD_ENTLEN
            cmp   RD_FCNT
            bcs   RD_RREOF
            ldx   RD_ENTLEN
            inc   RD_ENTLEN
            lda   RD_DIRBUF,x
            and   #3
            cmp   #1
            beq   RD_READMNT         ;unmounted Disk ][: no I/O
            lda   RD_DIRBUF,x
            and   #$F0
            sta   RD_RPARM+1        ;unit_num
            lda   #2
            sta   RD_RPARM
            lda   #<RD_ONBUF
            sta   RD_RPARM+2
            lda   #>RD_ONBUF
            sta   RD_RPARM+3
            lda   #<RD_RPARM
            ldx   #>RD_RPARM
            jsr   SC_ONLINE
            bcs   RD_READMNT         ;MLI failed -- skip
            lda   RD_ONBUF
            and   #$0F
            beq   RD_READMNT         ;no ProDOS volume -- skip
            sta   RD_RPARM_TR
            ldy   #RD_LEN
            sta   (PTR0),y
            lda   #$0F               ;a volume directory header
RD_RRNAME   pha
            stz   RD_CHARIDX
:cpname     lda   RD_CHARIDX
            cmp   RD_RPARM_TR
            beq   :nmdone
            clc
            adc   #1                 ;name starts at offset 1
            tay
            lda   RD_ONBUF,y
            ora   #$80
            pha
            lda   RD_CHARIDX
            clc
            adc   #RD_NAME
            tay
            pla
            sta   (PTR0),y
            inc   RD_CHARIDX
            bra   :cpname
:nmdone     lda   RD_RPARM_TR
            clc
            adc   #RD_NAME
            tay
            lda   #0
            sta   (PTR0),y
            ldy   #RD_FTYPE
            lda   #$0F
            sta   (PTR0),y
            ldy   #RD_STYPE
            pla
            sta   (PTR0),y
            jsr   RD_ZEROSIZE
            clc
            rts
RD_RREOF    lda   #0
            sec
            rts

*---------------------------------------------------------------
* RD_READROOT -- READDIR for the synthetic `/` (docs/VROOT.md):
* the kernel's root table, one SYS_VROOT row per call, each a
* directory. RD_ENTLEN is the row index. The names come back
* lower case as the kernel spells them; RD_NAME is display text.
*---------------------------------------------------------------
RD_READROOT lda   #0
            sta   RD_RPARM            ;op 0: ROW
            lda   #<RD_ONBUF
            sta   RD_RPARM+1
            lda   #>RD_ONBUF
            sta   RD_RPARM+2
            lda   RD_ENTLEN
            sta   RD_RPARM+3
            inc   RD_ENTLEN
            lda   #<RD_RPARM
            ldx   #>RD_RPARM
            jsr   SC_VROOT
            bcs   RD_RREOF
            lda   RD_ONBUF            ;n+1 (name, kind); 0 = end
            beq   RD_RREOF
            dec   a
            sta   RD_RPARM_TR
            ldy   #RD_LEN
            sta   (PTR0),y
            lda   #$0D                ;a directory
            bra   RD_RRNAME

*---------------------------------------------------------------
* RD_READDEV -- READDIR for the synthetic `/dev`. RD_EPB: 0 =
* the 7 fixed names (RD_ENTLEN 0..6); 1 = walking RD_DIRBUF for
* `sNdM` (EVERY entry -- floppies included, no I/O either way);
* 2 = exhausted. Device names come back LOWERCASE.
*---------------------------------------------------------------
RD_READDEV  lda   RD_EPB
            bne   :rdbuf
            lda   RD_ENTLEN
            cmp   #7
            bcc   :rdfixed
            stz   RD_ENTLEN
            lda   #1
            sta   RD_EPB
            bra   :rdbuf
:rdfixed    ldx   RD_ENTLEN
            inc   RD_ENTLEN
            lda   RD_FNLO,x
            sta   PTR1
            lda   RD_FNHI,x
            sta   PTR1+1
            ldy   #0
            lda   (PTR1),y
            sta   RD_RPARM_TR2
            ldy   #RD_LEN
            sta   (PTR0),y
            stz   RD_CHARIDX
:rdcpfx     lda   RD_CHARIDX
            cmp   RD_RPARM_TR2
            beq   :rdfxdone
            clc
            adc   #1
            tay
            lda   (PTR1),y
            ora   #$80
            pha
            lda   RD_CHARIDX
            clc
            adc   #RD_NAME
            tay
            pla
            sta   (PTR0),y
            inc   RD_CHARIDX
            bra   :rdcpfx
:rdfxdone   lda   RD_RPARM_TR2
            clc
            adc   #RD_NAME
            tay
            lda   #0
            sta   (PTR0),y
            ldy   #RD_FTYPE
            lda   #0
            sta   (PTR0),y
            ldy   #RD_STYPE
            lda   #RD_STYPE_CHR
            sta   (PTR0),y
            jsr   RD_ZEROSIZE
            clc
            rts
:rdbuf      lda   RD_ENTLEN
            cmp   RD_FCNT
            bcc   :rdhave
            lda   #0
            sec
            rts
:rdhave     ldy   RD_ENTLEN
            inc   RD_ENTLEN
            lda   RD_DIRBUF,y
            lsr   a
            lsr   a
            lsr   a
            lsr   a                  ;nibble (0-15): D<<3|slot
            sta   RD_RPARM_TR2
            and   #7
            clc
*-- HIGH-bit digit base (no "+$80" wrap -- see RD_READROOT's own
*-- note above): "0" double-quoted is ALREADY high-bit ($B0),
*-- and high-bit digits are contiguous ($B0-$B9) exactly like
*-- their low-bit twins, so adding the slot value (0-7) directly
*-- still lands on the right high-bit digit character.
            adc   #"0"
            sta   RD_CPARM
            lda   RD_RPARM_TR2
            cmp   #8
            lda   #"1"
            bcc   :rddrvok
            lda   #"2"
:rddrvok    sta   RD_CPARM_REF
            ldy   #RD_LEN
            lda   #4
            sta   (PTR0),y
            ldy   #RD_NAME
            lda   #"s"
            sta   (PTR0),y
            iny
            lda   RD_CPARM
            sta   (PTR0),y
            iny
            lda   #"d"
            sta   (PTR0),y
            iny
            lda   RD_CPARM_REF
            sta   (PTR0),y
            iny
            lda   #0
            sta   (PTR0),y
            ldy   #RD_FTYPE
            lda   #0
            sta   (PTR0),y
            ldy   #RD_STYPE
            lda   #RD_STYPE_BLK
            sta   (PTR0),y
            jsr   RD_ZEROSIZE
            clc
            rts

*-- The 7 fixed `/dev` names (docs/DEVFS.md: "listed
*-- unconditionally like the kernel's table; open decides
*-- presence"), each length-prefixed 7-bit ASCII, plus the
*-- lookup tables RD_READDEV indexes by RD_ENTLEN.
RD_FN0      dfb   3
            asc   'tty'
RD_FN1      dfb   4
            asc   'tty1'
RD_FN2      dfb   4
            asc   'tty2'
RD_FN3      dfb   4
            asc   'tty3'
RD_FN4      dfb   4
            asc   'tty4'
RD_FN5      dfb   4
            asc   'null'
RD_FN6      dfb   5
            asc   'ttya0'
RD_FNLO     dfb   <RD_FN0,<RD_FN1,<RD_FN2,<RD_FN3
            dfb   <RD_FN4,<RD_FN5,<RD_FN6
RD_FNHI     dfb   >RD_FN0,>RD_FN1,>RD_FN2,>RD_FN3
            dfb   >RD_FN4,>RD_FN5,>RD_FN6
