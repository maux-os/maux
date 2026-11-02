*---------------------------------------------------------------
* diffrec.s -- diff's DIRECTORY half: `diff -r`, and the two
* directory operand forms. Brief: docs/POSIX-DIFFR.md; the
* measurements it was built from: docs/POSIX-DIFFR-NOTES.md.
*
* `put` into src/bin/diff.s after diffcout.s; one assembly
* stream, every rule in diff.s's manifest header applies.
*
* WHAT THE HOSTS DO (BSD on the Mac, GNU on the box, identical
* on every line below unless noted):
*   - the two listings are merged in BYTE order of the names
*     (C locale: "Banana" < "apple"), not ls's folded order.
*     ProDOS names are upper case or case-flagged, and READDIR
*     hands back the DECODED name, so byte order of what the
*     user sees is the host's order.
*   - a name in one listing only: "Only in DIR: NAME".
*   - a name in both, both directories: with -r descend, without
*     it "Common subdirectories: A and B" (no output when -r).
*   - both plain files: the diff, preceded by the line
*     `diff OPTS A/x B/x` when (and only when) they differ. OPTS
*     are argv as TYPED, one space apart ("-ru", "-U 1").
*   - one a directory, one not: "File A/x is a directory while
*     file B/x is a regular file". GNU exits 1 on it, BSD 0;
*     POSIX says any difference is 1, so maux says 1.
*   - `diff FILE DIR` compares FILE with DIR/basename(FILE).
*   - the same file twice is identical, exit 0, nothing read.
*
* ONE DIRECTORY FD, AND NEVER TWO. readdir.s is a singleton, so
* each directory is read to the end into a NAME ARENA and closed
* before anything else opens. The comparison then needs no
* directory handle at all, only the two sorted lists, and a file
* pair holds exactly two fds (the pair diff's own). The walk
* therefore never presses on the 8-buffer pool, however deep.
*
* THE NAME ARENA is a stack. A level's two lists sit at its top;
* descending allocates the child's lists above them, returning
* releases them (DF_NTOP := the level's list-2 end). A listing
* that does not fit is OVERFLOW (loud, exit 2) -- never a
* truncated comparison. Records are RECSZ (17) bytes -- type
* (0 file, 1 directory) then the 16-byte decoded name, inserted
* in sorted position, so a list is sorted the moment it is read.
*
* DEPTH. DMAXDEP levels of FRSZ bytes each. The binding limit is
* really the MLI's 64-character pathname (cptree.equ's
* CPT_MAXDEP reasoning): a child that would push either display
* path past MLI_PTH_MAXLN is refused loudly (TOOLONG), as cp -R
* refuses it.
*
* The DISPLAY paths (DP1/DP2) are the operands as typed with
* "/NAME" appended per level; MKPATH turns them into MLI paths
* each use, so a "." operand resolves through MKPATH's own dot
* rule and the output keeps the spelling the user typed.
*---------------------------------------------------------------

*---------------------------------------------------------------
* Small cursor helpers.
*---------------------------------------------------------------
ATEND1      lda   DF_CUR1
            cmp   DF_E1
            bne   :r
            lda   DF_CUR1+1
            cmp   DF_E1+1
:r          rts

ATEND2      lda   DF_CUR2
            cmp   DF_E2
            bne   :r
            lda   DF_CUR2+1
            cmp   DF_E2+1
:r          rts

ADV1        clc
            lda   DF_CUR1
            adc   #RECSZ
            sta   DF_CUR1
            bcc   :r
            inc   DF_CUR1+1
:r          rts

ADV2        clc
            lda   DF_CUR2
            adc   #RECSZ
            sta   DF_CUR2
            bcc   :r
            inc   DF_CUR2+1
:r          rts

SETNM1      clc
            lda   DF_CUR1
            adc   #1
            sta   DF_TNAME
            lda   DF_CUR1+1
            adc   #0
            sta   DF_TNAME+1
            rts

SETNM2      clc
            lda   DF_CUR2
            adc   #1
            sta   DF_TNAME
            lda   DF_CUR2+1
            adc   #0
            sta   DF_TNAME+1
            rts

*---------------------------------------------------------------
* PUSHFR / POPFR -- save and restore one level: the 8-byte
* cursor block DF_CUR1..DF_E2 plus the two path lengths the
* level's own paths had (SDL1/SDL2). POPFR also truncates both
* display paths back to the level and releases the child lists.
*---------------------------------------------------------------
PUSHFR      lda   DEPTH
            cmp   #DMAXDEP
            bcc   :ok
            jmp   TOODEEP
:ok         inc   DEPTH
            ldx   #0
            ldy   #0
:cp         lda   DF_CUR1,x
            sta   (DF_FP),y
            inx
            iny
            cpx   #8
            bne   :cp
            lda   SDL1
            sta   (DF_FP),y
            iny
            lda   SDL2
            sta   (DF_FP),y
            clc
            lda   DF_FP
            adc   #FRSZ
            sta   DF_FP
            bcc   :r
            inc   DF_FP+1
:r          rts

POPFR       dec   DEPTH
            sec
            lda   DF_FP
            sbc   #FRSZ
            sta   DF_FP
            lda   DF_FP+1
            sbc   #0
            sta   DF_FP+1
            ldx   #0
            ldy   #0
:cp         lda   (DF_FP),y
            sta   DF_CUR1,x
            inx
            iny
            cpx   #8
            bne   :cp
            lda   (DF_FP),y
            sta   DL1
            iny
            lda   (DF_FP),y
            sta   DL2
            ldx   DL1
            stz   DP1,x
            ldx   DL2
            stz   DP2,x
            lda   DF_E2
            sta   DF_NTOP
            lda   DF_E2+1
            sta   DF_NTOP+1
            rts

*---------------------------------------------------------------
* MISMSG -- "File A is a T1 while file B is a T2", T1/T2 being
* 0 (regular file) or 1 (directory).
*---------------------------------------------------------------
MISMSG      lda   #<M_FILE
            ldx   #>M_FILE
            jsr   PMSG
            jsr   PDP1
            lda   #<M_ISA
            ldx   #>M_ISA
            jsr   PMSG
            lda   T1
            jsr   PTYPE
            lda   #<M_WHILE
            ldx   #>M_WHILE
            jsr   PMSG
            jsr   PDP2
            lda   #<M_ISA
            ldx   #>M_ISA
            jsr   PMSG
            lda   T2
            jsr   PTYPE
            jmp   PNL

PTYPE       bne   :dir
            lda   #<M_REG
            ldx   #>M_REG
            jmp   PMSG
:dir        lda   #<M_DIRY
            ldx   #>M_DIRY
            jmp   PMSG

*---------------------------------------------------------------
* PRHDR -- "diff OPTS A B": argv[1..OPTIND-1] as typed.
*---------------------------------------------------------------
PRHDR       lda   #<M_DIFF
            ldx   #>M_DIFF
            jsr   PMSG
            lda   #1
            sta   HDI
:lp         lda   HDI
            cmp   OPTIND
            bcs   :done
            lda   #<M_SP
            ldx   #>M_SP
            jsr   PMSG
            lda   HDI
            jsr   GETARG
            ldx   #FD_STDOUT
            jsr   PUTS
            inc   HDI
            bra   :lp
:done       lda   #<M_SP
            ldx   #>M_SP
            jsr   PMSG
            jsr   PDP1
            lda   #<M_SP
            ldx   #>M_SP
            jsr   PMSG
            jsr   PDP2
            jmp   PNL

*---------------------------------------------------------------
* PATHEQ -- carry SET if PATH1BUF and PATH2BUF name the same
* path (count-prefixed, case ignored). The same file twice is
* identical by definition, and OPENing it twice is refused by
* ProDOS ($50), so the pair diff must not try
* (learning:01M0P08K94TE5DNQ0JWCG885WG).
*---------------------------------------------------------------
PATHEQ      lda   PATH1BUF
            cmp   PATH2BUF
            bne   :no
            tax
            ldy   #1
:lp         beq   :yes
            lda   PATH1BUF,y
            eor   PATH2BUF,y
            and   #$5F
            bne   :no
            iny
            dex
            bra   :lp
:yes        sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* MIXED -- exactly one operand is a directory. The other (the
* file) is compared with DIR/basename(file). ST1 says which.
* Never returns: exits 0/1 from the pair diff, 1 on a type
* mismatch, 2 on trouble.
*---------------------------------------------------------------
MIXED       lda   ST1
            beq   :f1                   ;side 1 is the file
            lda   #<DP2                 ;side 2 is the file: its
            sta   DF_PD                 ;basename goes on DP1
            lda   #>DP2
            sta   DF_PD+1
            lda   #<DP1
            sta   PTR0
            lda   #>DP1
            sta   PTR0+1
            lda   DL1
            bra   :base
:f1         lda   #<DP1
            sta   DF_PD
            lda   #>DP1
            sta   DF_PD+1
            lda   #<DP2
            sta   PTR0
            lda   #>DP2
            sta   PTR0+1
            lda   DL2
:base       pha                         ;the directory's length
            lda   DF_PD                 ;find the file's name:
            sta   DF_TNAME              ;past the last '/'
            lda   DF_PD+1
            sta   DF_TNAME+1
            ldy   #0
:scan       lda   (DF_PD),y
            beq   :gotb
            cmp   #DSLASH
            bne   :nx
            tya
            clc
            adc   DF_PD
            sta   DF_TNAME
            lda   DF_PD+1
            adc   #0
            sta   DF_TNAME+1
            inc   DF_TNAME
            bne   :nx
            inc   DF_TNAME+1
:nx         iny
            bne   :scan
:gotb       pla
            jsr   APPEND
            bcc   :fits
            jmp   TOOLONG
:fits       ldx   ST1
            bne   :setl1
            sta   DL2
            lda   #<DP2
            sta   PTR0
            lda   #>DP2
            sta   PTR0+1
            lda   #<PATH2BUF
            sta   PTR1
            lda   #>PATH2BUF
            sta   PTR1+1
            lda   #2
            bra   :stat
:setl1      sta   DL1
            lda   #<DP1
            sta   PTR0
            lda   #>DP1
            sta   PTR0+1
            lda   #<PATH1BUF
            sta   PTR1
            lda   #>PATH1BUF
            sta   PTR1+1
            lda   #1
:stat       sta   OERRIDX
            jsr   GFISTAT
            beq   :pair                 ;target is no directory
            lda   ST1                   ;file vs dir: T1 is
            sta   T1                    ;side 1's kind, T2 the
            eor   #1                    ;other (ST1 is 0 or 1)
            sta   T2
            jsr   MISMSG
            lda   #1
            jsr   EXIT
:pair       stz   HDRFLAG
            jsr   DOPAIR
            jsr   EXIT

*---------------------------------------------------------------
* WALKTOP -- both operands are directories; DP1/DP2/DL1/DL2 hold
* them. Merge the two sorted listings level by level; exits with
* the walk's status.
*---------------------------------------------------------------
WALKTOP     stz   DEPTH
            stz   DSTAT
            lda   #<NAMES
            sta   DF_NTOP
            lda   #>NAMES
            sta   DF_NTOP+1
            lda   #<FRAMES
            sta   DF_FP
            lda   #>FRAMES
            sta   DF_FP+1
            jsr   LOADLISTS
:merge      jsr   ATEND1
            bne   :has1
            jsr   ATEND2
            beq   :lvldone
            jmp   :only2
:has1       jsr   ATEND2
            beq   :only1
            clc
            lda   DF_CUR1
            adc   #1
            sta   PTR0
            lda   DF_CUR1+1
            adc   #0
            sta   PTR0+1
            clc
            lda   DF_CUR2
            adc   #1
            sta   PTR1
            lda   DF_CUR2+1
            adc   #0
            sta   PTR1+1
            jsr   STRCMP
            beq   :pair
            bmi   :only1
            jmp   :only2

:only1      jsr   SETNM1
            jsr   ADV1
            lda   #<DP1
            ldx   #>DP1
            bra   :only
:only2      jsr   SETNM2
            jsr   ADV2
            lda   #<DP2
            ldx   #>DP2
:only       sta   DF_PD
            stx   DF_PD+1
            lda   #<M_ONLY
            ldx   #>M_ONLY
            jsr   PMSG
            lda   DF_PD
            ldx   DF_PD+1
            jsr   PMSG
            lda   #<M_COLON
            ldx   #>M_COLON
            jsr   PMSG
            lda   DF_TNAME
            ldx   DF_TNAME+1
            jsr   PMSG
            jsr   PNL
            lda   #1
            sta   DSTAT
            jmp   :merge

:lvldone    lda   DEPTH
            beq   :alldone
            jsr   POPFR
            jmp   :merge
:alldone    lda   DSTAT
            jsr   EXIT

:pair       ldy   #0
            lda   (DF_CUR1),y
            sta   T1
            lda   (DF_CUR2),y
            sta   T2
            jsr   SETNM1
            jsr   ADV1
            jsr   ADV2
            lda   DL1
            sta   SDL1
            lda   DL2
            sta   SDL2
            lda   #<DP1
            sta   PTR0
            lda   #>DP1
            sta   PTR0+1
            lda   DL1
            jsr   APPEND
            bcc   :f1
            jmp   TOOLONG
:f1         sta   DL1
            lda   #<DP2
            sta   PTR0
            lda   #>DP2
            sta   PTR0+1
            lda   DL2
            jsr   APPEND
            bcc   :f2
            jmp   TOOLONG
:f2         sta   DL2
            lda   T1
            cmp   T2
            bne   :mism
            cmp   #0
            bne   :bothdir
            lda   #1                    ;two plain files
            sta   HDRFLAG
            jsr   DOPAIR
            ora   DSTAT
            sta   DSTAT
            bra   :trunc
:mism       jsr   MISMSG
            lda   #1
            sta   DSTAT
            bra   :trunc
:bothdir    lda   RFLAG
            bne   :descend
            lda   #<M_COMSUB
            ldx   #>M_COMSUB
            jsr   PMSG
            jsr   PDP1
            lda   #<M_AND
            ldx   #>M_AND
            jsr   PMSG
            jsr   PDP2
            jsr   PNL
:trunc      ldx   SDL1
            stz   DP1,x
            stx   DL1
            ldx   SDL2
            stz   DP2,x
            stx   DL2
            jmp   :merge
:descend    jsr   PUSHFR
            jsr   LOADLISTS
            jmp   :merge

M_ONLY      asc   "Only in "
            dfb   0
M_COLON     asc   ": "
            dfb   0
M_COMSUB    asc   "Common subdirectories: "
            dfb   0
M_AND       asc   " and "
            dfb   0
M_FILE      asc   "File "
            dfb   0
M_ISA       asc   " is a "
            dfb   0
M_WHILE     asc   " while file "
            dfb   0
M_DIRY      asc   "directory"
            dfb   0
M_REG       asc   "regular file"
            dfb   0
M_DIFF      asc   "diff"
            dfb   0
M_SP        asc   " "
            dfb   0
M_LONG      asc   "diff: path too long"
            dfb   0
M_DEEP      asc   "diff: directory tree too deep"
            dfb   0
