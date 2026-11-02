*---------------------------------------------------------------
* readdir.s -- directory-walk facade, extracted from ls.s's own
* inline walk per docs/FLEET.md's "readdir: build the facade,
* but do NOT copy dirent's shape" ruling. find.s is the SECOND
* consumer that triggered the move (ruling 1: build at the
* second consumer, not the first) -- ls.s is converted to call
* through this module too (its own gate, check-ls, is the proof
* the extraction is behavior-preserving).
*
* Ruling 2 (shape): return the ENTRY, not just a name. ProDOS's
* 39-byte directory entry already carries type/EOF/dates/storage
* type -- a POSIX dirent-shaped (name-only) API would force a
* caller like `ls -l` into a per-file GET_FILE_INFO storm to
* recover data this module already read and would otherwise
* discard. So READDIR fills a caller-owned RD_SIZE-byte record
* (layout below) with every field.
*
* Divided by what KIND of thing each field is (the ruling's own
* framing):
*  - DECODED: the GS/OS case bitflags (ProDOS 2.5 / GS/OS TN #8)
*    are how the name is STORED, not information a caller should
*    still have to re-derive -- so RD_NAME comes back already
*    case-decoded, display-ready.
*  - RAW: mod_date/mod_time come back as raw ProDOS words.
*    Deciding what an unreadable 2.5 Extended stamp MEANS is
*    policy (ls -l's own PRINTDATE, unaffected by this move).
*  - Deleted entries are skipped and the key-block header
*    (entry_length/entries_per_block/file_count) is consumed
*    entirely inside this module -- exactly the knowledge being
*    centralised.
*
* CALLING CONVENTION -- three entry points, one directory open
* at a time (this module is a SINGLETON: it has no per-handle
* state, only one OPENDIR may be live at once -- see find.s's
* own header for how it uses an explicit depth stack to stay
* within that, never holding two directories open at once):
*
*  OPENDIR   IN: A/X = lo/hi of an MLI-shaped (count-prefixed,
*            7-bit) pathname buffer -- the SAME shape ls.s's own
*            LISTDIR always took. OUT: carry clear = ok; carry
*            set, A = errno = open or first-block-read failed.
*  READDIR   IN: A/X = lo/hi of a caller-owned RD_SIZE-byte
*            destination record. OUT: carry clear = record
*            filled, call again for the next entry; carry set,
*            A=0 = directory exhausted (clean EOF -- no more
*            active entries, THIS call filled nothing); carry
*            set, A<>0 = a READ failed (A=errno) -- directory
*            is left OPEN, caller should still CLOSEDIR.
*  CLOSEDIR  no IN. Closes the fd OPENDIR opened. Call exactly
*            once per successful OPENDIR, whether READDIR ran to
*            exhaustion or the caller stopped early.
*
* Record layout (RD_SIZE=32 bytes -- same stride ls.s's own
* ENTRIES array already used, so ls.s's *32 MULT32 needs no
* change):
*   RD_LEN    1  name length
*   RD_NAME  16  name chars (high-bit) + NUL, CASE-DECODED
*   RD_FTYPE  1  file_type
*   RD_STYPE  1  storage_type (high nibble of the entry's own
*               offset-0 byte -- NEW: ls.s's private ENTRIES
*               record never carried this, only GFI-stat'd path
*               ARGUMENTS did; find.s's -type d/f needs it on
*               every WALKED entry too)
*   (1 byte pad)
*   RD_EOF    3  EOF, little-endian, RAW
*   RD_MDATE  2  mod_date, little-endian, RAW
*   RD_MTIME  2  mod_time, little-endian, RAW
*   RD_BLOCKS 2 blocks_used, little-endian, RAW (appended in
*               the old pad so every existing offset is stable)
*   (3 bytes pad, to RD_SIZE)
*---------------------------------------------------------------

* -- The RD_* offsets moved to inc/readdir.equ: du.s,
* -- find.s and ls.s index this record with `ldy #RD_*` far
* -- above their `put` of this file, and real Merlin-8 rejects
* -- a forward `equ` reference in an immediate operand. The
* -- layout above is still the documentation; only the equates
* -- moved.

*---------------------------------------------------------------
* SYNTHETIC MODE -- docs/DEVFS.md, 2026-09-30; the walks
* themselves moved to readsyn.s 2026-10-17 (docs/GLOB-VROOT.md).
* `/`, `/dev` and `/mnt` have no ProDOS directory to OPEN, so
* OPENDIR hands the path to SYN_OPEN (readsyn.s), which
* recognises them (7-bit, case-folded, optional trailing slash)
* and switches this singleton into one of three synthetic walks
* that touch NO directory block and issue NO 5.25" drive poll
* (operator ruling: never call ON_LINE unit 0). RD_DFD is the
* mode: 0 = the ordinary ProDOS walk in this file; bit 7 set =
* a synthetic walk, RD_SYN_ROOT/RD_SYN_DEV/RD_SYN_MNT, defined
* and run by readsyn.s (READDIR just jumps to RD_READSYN).
*
* RD_STYPE_BLK/RD_STYPE_CHR -- storage-type markers ProDOS never
* emits (docs/DEVFS.md): a block device (`/dev/sNdM`) and a
* character device (the ttys, `null`). Declared in
* inc/readdir.equ now, NOT here -- lsprint.s/lstop.s (put before
* this file in ls.s's own expansion order) need them too, the
* SAME forward-reference problem readdir.equ already exists to
* solve for RD_LEN/RD_NAME/etc (its own header). Still
* readdir.s's layout and nowhere else's to OWN, just not this
* file's own text.
*---------------------------------------------------------------
* -- The RD_SYN_* mode values and everything that produces the
* -- synthetic records live in readsyn.s (put right after this
* -- file) since 2026-10-17; this file keeps only the ordinary
* -- ProDOS walk and the OPENDIR/READDIR/CLOSEDIR doors.


*---------------------------------------------------------------
* OPENDIR -- open a directory and consume its key-block header,
* OR switch into synthetic mode for `/`, `/dev` or `/mnt`.
*---------------------------------------------------------------
OPENDIR     jsr   SYN_OPEN         ;readsyn.s: stores the path;
                                   ;carry CLEAR = `/`, `/dev` or
                                   ;`/mnt`, and the walk is open
            bcs   RD_OPENREAL      ;an ordinary path
            rts

RD_OPENREAL stz   RD_DFD         ;a previous OPENDIR on this
                                     ;singleton may have left
                                     ;synthetic mode set
            jsr   RD_INITPARM
            lda   #<RD_OPARM
            ldx   #>RD_OPARM
            jsr   SC_OPEN
            bcc   :opok
            rts
:opok       lda   RD_OPARM_REF
            sta   RD_DFD
            sta   RD_RPARM_REF
            lda   #<RD_RPARM
            ldx   #>RD_RPARM
            jsr   SC_READ
            bcc   :rdok
            pha
            lda   RD_DFD
            sta   RD_CPARM_REF
            lda   #<RD_CPARM
            ldx   #>RD_CPARM
            jsr   SC_CLOSE
            pla
            sec
            rts
:rdok       lda   RD_DIRBUF+$23
            sta   RD_ENTLEN
            lda   RD_DIRBUF+$24
            sta   RD_EPB
            lda   RD_DIRBUF+$25
            sta   RD_FCNT
            lda   RD_DIRBUF+$26
            sta   RD_FCNT+1
            clc
            lda   RD_ENTLEN
            adc   #4
            adc   #<RD_DIRBUF
            sta   RD_CURSOR
            lda   #>RD_DIRBUF
            adc   #0
            sta   RD_CURSOR+1
            lda   #2
            sta   RD_BENT
            stz   RD_ACNT
            stz   RD_ACNT+1
            stz   RD_DONEFLAG
            stz   RD_DONEERR
            clc
            rts

*---------------------------------------------------------------
* RD_INITPARM -- the parmlist fields that are genuinely
* CONSTANT, stored rather than emitted. OPENDIR's first act,
* which is enough for all three lists: no READDIR or CLOSEDIR
* can legally run before an OPENDIR (see the CALLING CONVENTION
* above), and OPENDIR's own error path closes through RD_CPARM.
*
* WHY THEY ARE STORES. An MLI parmlist must be CONTIGUOUS, so
* this module's three lists -- which are otherwise pure scratch
* -- cannot leave their param_count/buffer/request bytes behind
* in emitted text once the rest of the block moves to
* src/liba/libabss.s. docs/STICKY.md sec 21/24; src/bin/cat.s's
* INITPARMS is the same pattern at program scope.
*
* RD_OPARM_IOB IS DELIBERATELY ABSENT, for cat.s's INITPARMS's
* reason exactly: the kernel REPOINTS io_buffer at its own
* allocated buffer before issuing the real MLI call
* (src/kernel/procfile3.s PRC_OPEN's `lda #0 / sta
* PRC_PARM+MLI_IOBUFLO` then `jsr PRC_IBF_HI_A / sta
* PRC_PARM+MLI_IOBUFHI`) and never copies the field back, so
* whatever this module leaves there is read and discarded.
* CLOBBERS: A.
*---------------------------------------------------------------
RD_INITPARM lda   #PCOUNT_OPEN
            sta   RD_OPARM
            lda   #PCOUNT_READ
            sta   RD_RPARM
            lda   #<RD_DIRBUF
            sta   RD_RPARM_BUF
            lda   #>RD_DIRBUF
            sta   RD_RPARM_BUF+1
            lda   #<RD_BLKSZ
            sta   RD_RPARM_REQ
            lda   #>RD_BLKSZ
            sta   RD_RPARM_REQ+1
            lda   #PCOUNT_CLOSE
            sta   RD_CPARM
            rts

*---------------------------------------------------------------
* CLOSEDIR -- in synthetic mode, closes nothing (there is no fd)
* and just clears the mode. docs/DEVFS.md.
*---------------------------------------------------------------
CLOSEDIR    lda   RD_DFD
            bpl   :realclose
            stz   RD_DFD
            clc
            rts
:realclose  lda   RD_DFD
            sta   RD_CPARM_REF
            lda   #<RD_CPARM
            ldx   #>RD_CPARM
            jmp   SC_CLOSE

*---------------------------------------------------------------
* READDIR
*---------------------------------------------------------------
READDIR     sta   PTR0
            stx   PTR0+1
            lda   RD_DFD
            bpl   RD_READREAL
            jmp   RD_READSYN       ;readsyn.s; A = the mode
RD_READREAL ldy   RD_DONEFLAG
            beq   :notdoneyet
            lda   RD_DONEERR
            sec
            rts
:notdoneyet lda   RD_CURSOR
            sta   PTR1
            lda   RD_CURSOR+1
            sta   PTR1+1
:scan       ldy   #0
            lda   (PTR1),y
            beq   :skip
            and   #$0F
            sta   RD_NAMLEN
            bne   :havelen
:skip       jsr   RD_ADVANCE
            bcc   :scan
            sta   RD_DONEERR
            lda   #1
            sta   RD_DONEFLAG
            lda   RD_DONEERR
            sec
            rts

*-- an active entry sits at PTR1 -- copy every field into the
*-- caller's record (PTR0), case-decoding the name as we go
*-- (same bit-consuming algorithm ls.s's old PRINTENTNAME used,
*-- just running once here instead of once per print). --
:havelen    ldy   #0
            lda   (PTR1),y
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            ldy   #RD_STYPE
            sta   (PTR0),y
            lda   RD_NAMLEN
            ldy   #RD_LEN
            sta   (PTR0),y

            ldy   #$1C
            lda   (PTR1),y
            sta   RD_CASELO
            ldy   #$1D
            lda   (PTR1),y
            sta   RD_CASEHI
            bmi   :haveflag
            stz   RD_CASELO
            stz   RD_CASEHI
:haveflag   asl   RD_CASELO
            rol   RD_CASEHI       ;discard bit 15 itself
            stz   RD_CHARIDX
:cpname     lda   RD_CHARIDX
            cmp   RD_NAMLEN
            beq   :cpnamedone
            clc
            adc   #1               ;name starts at offset 1
            tay
            lda   (PTR1),y
            ora   #$80
            pha
            asl   RD_CASELO
            rol   RD_CASEHI        ;carry = this char's case bit
            pla
            bcc   :pemit
            cmp   #$C1              ;fold LETTERS ONLY -- case
            bcc   :pemit             ;flags can be set past
            cmp   #$DB               ;name_length, see
            bcs   :pemit              ;docs/PRODOS-VERSION.md
            ora   #$20
:pemit      pha
            lda   RD_CHARIDX
            clc
            adc   #RD_NAME
            tay
            pla
            sta   (PTR0),y
            inc   RD_CHARIDX
            bra   :cpname
:cpnamedone lda   RD_NAMLEN
            clc
            adc   #RD_NAME
            tay
            lda   #0
            sta   (PTR0),y          ;NUL terminator

            ldy   #$10
            lda   (PTR1),y
            ldy   #RD_FTYPE
            sta   (PTR0),y
            ldy   #$13
            lda   (PTR1),y
            ldy   #RD_BLOCKS
            sta   (PTR0),y
            ldy   #$14
            lda   (PTR1),y
            ldy   #RD_BLOCKS+1
            sta   (PTR0),y
            ldy   #$15
            lda   (PTR1),y
            ldy   #RD_EOF
            sta   (PTR0),y
            ldy   #$16
            lda   (PTR1),y
            ldy   #RD_EOF+1
            sta   (PTR0),y
            ldy   #$17
            lda   (PTR1),y
            ldy   #RD_EOF+2
            sta   (PTR0),y
            ldy   #$21
            lda   (PTR1),y
            ldy   #RD_MDATE
            sta   (PTR0),y
            ldy   #$22
            lda   (PTR1),y
            ldy   #RD_MDATE+1
            sta   (PTR0),y
            ldy   #$23
            lda   (PTR1),y
            ldy   #RD_MTIME
            sta   (PTR0),y
            ldy   #$24
            lda   (PTR1),y
            ldy   #RD_MTIME+1
            sta   (PTR0),y

            inc   RD_ACNT
            bne   :adv
            inc   RD_ACNT+1
:adv        jsr   RD_ADVANCE
            pha
            lda   PTR1
            sta   RD_CURSOR
            lda   PTR1+1
            sta   RD_CURSOR+1
            pla
            bcc   :advmore
            sta   RD_DONEERR
            lda   #1
            sta   RD_DONEFLAG
:advmore    clc                       ;THIS call always
            rts                       ;succeeds -- the outcome
                                      ;above is deferred to the
                                      ;NEXT call

*---------------------------------------------------------------
* RD_ADVANCE -- move PTR1 to the next raw slot, reading a fresh
* block when the current one is exhausted. First checks whether
* every ACTIVE entry the header promised has already been seen,
* regardless of raw slots physically remaining in the buffer.
* OUT: carry clear = PTR1 now at the next raw slot to inspect;
* carry set, A=0 = exhausted; carry set, A=errno = a READ
* failed. CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
RD_ADVANCE  lda   RD_ACNT+1
            cmp   RD_FCNT+1
            bcc   :notdone
            beq   :chkeq
            lda   #0
            sec
            rts
:chkeq      lda   RD_ACNT
            cmp   RD_FCNT
            bcc   :notdone
            lda   #0
            sec
            rts
:notdone    lda   RD_BENT
            cmp   RD_EPB
            bne   :sameblk
            lda   RD_DFD
            sta   RD_RPARM_REF
            lda   #<RD_RPARM
            ldx   #>RD_RPARM
            jsr   SC_READ
            bcs   :rderr
            lda   #1
            sta   RD_BENT
            clc
            lda   #<RD_DIRBUF
            adc   #4
            sta   PTR1
            lda   #>RD_DIRBUF
            adc   #0
            sta   PTR1+1
            clc
            rts
:sameblk    clc
            lda   PTR1
            adc   RD_ENTLEN
            sta   PTR1
            lda   PTR1+1
            adc   #0
            sta   PTR1+1
            inc   RD_BENT
            clc
            rts
:rderr      rts                       ;carry already set (bcs),
                                      ;A already holds SC_READ's
                                      ;errno


*---------------------------------------------------------------
* Module-private state USED TO BE DECLARED HERE, in 20 `ds`/
* `dfb`/`da` cells -- 560 emitted bytes, 512 of them RD_DIRBUF,
* riding into every binary that walks a directory (ls, du, find,
* df) and into every bank copy of every spawn. They are in
* src/liba/libabss.s's `dum` arena now (docs/STICKY.md sec 25),
* which is where liba's storage has to live: this module sits in
* the MIDDLE of every consumer's put-list, and a `dum` block
* opened before still-emitted code is silently overlaid by it
* (learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* Not one of the 20 needed the kernel's zeroed page -- every one
* is write-before-read, and the trace for each group is recorded
* beside its declaration in libabss.s rather than restated here.
* The three parmlists' constant fields are stored by
* RD_INITPARM above, because an MLI parmlist must be contiguous.
*---------------------------------------------------------------
