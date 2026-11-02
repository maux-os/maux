*---------------------------------------------------------------
* du.s -- report disk usage in 512-byte ProDOS blocks.
*
* Usage: du [-s] [-a] [-k] [path...]
*
* -k (SHIPPED 2026-09-17): report 1024-byte units instead of raw
* 512-byte ProDOS blocks -- TOKB converts U2DEC_VAL in place,
* right before PRLINE prints it, as (blocks+1)/2 (ceiling, since
* an odd block count is still a whole KB once you round up the
* half-block). Every accumulator (LEVTOT/DS_TOTAL and friends)
* keeps counting real 512-byte blocks throughout the walk --
* only the PRINTED copy in U2DEC_VAL is ever converted, so -k
* changes no arithmetic upstream of display.
*
* No path -> "." (names print relative: ./X ... then "."; see
* DOCWD). A trailing "/" on an operand is not doubled when the
* walk joins a child. Each path argument is stat'd with
* GET_FILE_INFO (SC_GFI): a FILE argument always prints one
* line, "<blocks>TAB<path>". A DIRECTORY argument is walked
* (src/liba/readdir.s's OPENDIR/READDIR/CLOSEDIR, the THIRD
* consumer -- ls.s and find.s are the first two) and every
* subdirectory's line prints when its own scan finishes --
* DEEPEST FIRST, the natural order of finishing a post-order
* walk -- with its total ROLLED UP into its parent before the
* parent finishes. The argument's own grand total prints last,
* ALWAYS (even under -s, which suppresses every other line).
*
* -s: summary only -- suppress every per-directory/-file line,
* print just the one grand total per argument.
* -a: also print a line for every FILE (directories always
* print, with or without -a).
*
* BLOCKS, NOT EOF/512: readdir.s's RD_RECORD does NOT carry
* blocks_used (confirmed by reading its layout -- RD_EOF is the
* only size field). A sapling file's blocks_used is its data
* blocks PLUS one index block, which EOF/512 rounding would
* miss. Rather than touch readdir.s (another consumer's gate
* depends on its shape), this file GET_FILE_INFOs every entry
* it visits itself -- the same SC_GFI ls.s already uses for its
* own path-argument stat -- to read the real blocks_used field.
* Cost: one extra MLI call per entry versus a hypothetical
* readdir.s with the field, paid once per du run, not per
* directory listed twice.
*
* A subdirectory's own total SEEDS at its own blocks_used (the
* storage its directory-block chain costs its PARENT), then
* accumulates every child -- so "the argument's total" already
* counts the argument directory's own block cost too, matching
* classic du semantics (`du -s dir` includes dir's own key
* block, not just what is stored under it).
*
* NO RECURSION, explicit depth stack (DU_MAXDEP=8), close-on-
* descend/reopen-and-replay-on-return -- readdir.s is a
* SINGLETON (one open directory at a time) for the same reason
* find.s documents in its own header, and this file follows
* find.s's OPENCUR/PUSHFRAME/POPFRAME/SKIPRESUME shape exactly,
* extended with a per-level running BLOCK TOTAL (LEVTOT,
* DS_TOTAL) alongside its per-level resume count. Exceeding
* DU_MAXDEP is a LOUD failure (stderr, exit 2), never a
* silently truncated walk.
*
* OVERFLOW: totals are 16-bit blocks -- exactly ProDOS's own
* range (a 32MB volume is 65,535 blocks). Every accumulation
* (a file's blocks into its directory, a finished child's total
* into its parent) is checked; a carry out of the 16-bit add is
* a LOUD "du: block count overflow" to stderr and exit(1), never
* a silently wrapped total.
*
* A path that fails to stat/open prints "du: <path>: cannot
* access" to stderr, is skipped, and forces exit 1 -- the
* remaining arguments (and remaining directory entries) still
* run. A child whose full path exceeds MLI_PTH_MAXLN (legal on
* disk; unopenable by any MLI call) prints "du: <path>:
* pathname too long", is skipped THE SAME WAY -- its blocks
* are then absent from every printed total, which the stderr
* line is the record of -- and forces exit 1. Exit 0 if every
* argument was accessible, 2 on a usage error or a depth-stack
* overflow.
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
            dsk   ../../build/du.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/readdir.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

DU_MAXDEP   equ   8         ;explicit depth stack -- see header

* -- FULLPATH is sized to BUILDCHILD's own worst case: a full
* -- PATHBUF (MLI_PTH_MAXLN chars) + '/' + a 15-char ProDOS
* -- name + NUL. The 64-char MLI limit is a carry verdict at
* -- BUILDCHILD, and an over-long child is reported and
* -- skipped -- see find.s's FP_BUFLEN note for the on-disk
* -- reachability argument (prefix+partial paths reach 128).
FP_BUFLEN   equ   MLI_PTH_MAXLN+17
FPMINSZ     equ   MLI_PTH_MAXLN+17
* -- FPMINSZ restates the writers' sum INDEPENDENTLY of
* -- FP_BUFLEN so the arena tripwire below still fires if
* -- FP_BUFLEN itself is ever edited down.

*---------------------------------------------------------------
* START
*---------------------------------------------------------------
START       stz   ERRFLAG
            stz   SFLAG
            stz   AFLAG
            stz   KFLAG
            lda   #<OPTSTR
            ldx   #>OPTSTR
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F3              ;'s' high-bit
            bne   :nots
            lda   #1
            sta   SFLAG
            bra   :optlp
:nots       cmp   #$E1              ;'a' high-bit
            bne   :notk
            lda   #1
            sta   AFLAG
            bra   :optlp
:notk       cmp   #$EB              ;'k' high-bit
            bne   :badopt
            lda   #1
            sta   KFLAG
            bra   :optlp
:badopt     jmp   USAGE_ERR
:optdone    lda   ARGC
            sec
            sbc   OPTIND
            sta   NPATHS
            bne   :havepth
            jsr   DOCWD
            jmp   :finish
:havepth    stz   ARGI
:aloop      lda   ARGI
            cmp   NPATHS
            bcs   :adone
            clc
            lda   ARGI
            adc   OPTIND
            jsr   GETARG
            jsr   PROCESSARG
            inc   ARGI
            jmp   :aloop
:adone
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
* DOCWD -- no path arguments: the operand is "." (POSIX du:
* "the current directory shall be used"), and every name is
* REPORTED relative to it -- "./DEMO", then "." for the grand
* total, the shape V7, GNU and BSD du all print (docs/
* DU-DF-NOTES.md has the oracle runs). Nothing here resolves
* "." itself: liba's MKPATH substitutes the prefix at the
* string->pathname boundary for every MLI call, so the
* absolute form is never built, never printed, and no ProDOS
* 2.5-only GET_FILE_INFO leniency is relied on
* (learning:01M0PBKZKZE55J4NE93TYNJCPC). It used to take
* GET_PREFIX's answer, which ALWAYS ends in "/", as the
* operand, and BUILDCHILD's own "/" then doubled it
* ("/mnt/MAUX//DEMO"). Falls into PROCESSARG and returns.
*---------------------------------------------------------------
DOCWD       lda   #<DOTSTR
            sta   PTR0
            lda   #>DOTSTR
            sta   PTR0+1
            jmp   PROCESSARG

*---------------------------------------------------------------
* PATHLONG -- PROCESSARG's refusal path. Global rather than a
* `:local` only so the two `bcs`/`bne` above can reach it from
* the top of a long routine.
*---------------------------------------------------------------
PATHLONG    lda   #<LONGMSG
            sta   PTR0
            lda   #>LONGMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* PROCESSARG -- IN: PTR0 = hi-bit NUL path string. Stats it;
* a file prints one line and returns; a directory is walked,
* then its grand total prints (always). CLOBBERS: everything.
*
* The length check covers BOTH entries -- an argv operand and
* DOCWD's "." -- and it guards two separate faults, the
* same pair find.s's CHKPATHARG does. `sta PATHLEN` below is an
* 8-bit store, so once STRCPY went 16-bit on 2026-08-22 a 256+
* byte operand would have stored its LOW byte there
* (learning:01M0MMCZDJCPAAHS1TJTQTV64Y); and the copy was never
* bounded at all, while PATHBUF is MLI_PTH_MAXLN+1 bytes with
* FULLPATH -- the walk's own assembly buffer -- immediately
* after it. STRLEN restores PTR0, which is what lets the STRCPY
* below reuse it.
*---------------------------------------------------------------
PROCESSARG  jsr   STRLEN
            cpx   #0
            bne   PATHLONG
            cmp   #MLI_PTH_MAXLN+1
            bcs   PATHLONG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   STRCPY
            sta   PATHLEN
            jsr   MKPATHBUF
            lda   #<MLIPATH
            sta   GFIPARM_PATH
            lda   #>MLIPATH
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :gfiok
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            jsr   PRINTACCESS
            lda   #1
            sta   ERRFLAG
            rts
:gfiok      lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #$0F
            beq   :isdir
            lda   GFIPARM_BLKS
            sta   U2DEC_VAL
            lda   GFIPARM_BLKS+1
            sta   U2DEC_VAL+1
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            jsr   PRLINE
            rts
:isdir      lda   GFIPARM_BLKS
            sta   LEVTOT
            lda   GFIPARM_BLKS+1
            sta   LEVTOT+1
* -- A VOLUME directory ($F) reports the whole VOLUME'S used
* -- count in blocks_used (ProDOS 8 TRM, GET_FILE_INFO: "the
* -- total blocks for all files is returned in blocks_used";
* -- df stands on the same sentence). Seeding the walk with it
* -- and then adding every child counted the volume twice:
* -- `du /mnt/MAUX` said 3362 on a volume with 1685 blocks used.
* -- Its own directory blocks are not reported separately, so
* -- the volume's seed is 0 and the total is its files.
            lda   GFIPARM_STYP
            cmp   #$0F
            bne   :seeded
            stz   LEVTOT
            stz   LEVTOT+1
:seeded            stz   DEPTH
            stz   CURRESN
            stz   CURRESN+1
            jsr   OPENCUR
            bcc   :walkgo
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            jsr   PRINTACCESS
            lda   #1
            sta   ERRFLAG
            rts
:walkgo     jsr   WALK
            lda   LEVTOT
            sta   U2DEC_VAL
            lda   LEVTOT+1
            sta   U2DEC_VAL+1
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            jsr   PRLINE
            rts

*---------------------------------------------------------------
* WALK -- iterative DFS over the already-OPENed PATHBUF/LEVTOT
* level. Returns (rts) once the top level (DEPTH 0) is
* exhausted; LEVTOT then holds that level's grand total.
* CLOBBERS: everything.
*---------------------------------------------------------------
WALK
:mainloop   lda   #<RD_RECORD
            ldx   #>RD_RECORD
            jsr   READDIR
            bcc   :rdok
            jmp   :ld
:rdok       jsr   BUILDCHILD
            bcc   :fits
:toolong
* -- child path exceeds MLI_PTH_MAXLN: no MLI call can open
* -- it, so its blocks cannot be counted either. Report it
* -- loudly, force exit 1, count the entry for the resume
* -- bookkeeping and keep walking -- the printed totals then
* -- EXCLUDE the skipped entry, which the stderr line says.
            jsr   PRINTLONGENT
            lda   #1
            sta   ERRFLAG
            jmp   :bumpcur
:fits       jsr   MKFULLP
            bcs   :toolong        ;a relative operand resolves
                                  ;LONGER than it prints:
                                  ;MKPATH's own carry fences
            lda   #<MLIPATH
            sta   GFIPARM_PATH
            lda   #>MLIPATH
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :cok
            lda   #<FULLPATH
            sta   PTR0
            lda   #>FULLPATH
            sta   PTR0+1
            jsr   PRINTACCESS
            lda   #1
            sta   ERRFLAG
            stz   GBLOCKS
            stz   GBLOCKS+1
            bra   :haveblk
:cok        lda   GFIPARM_BLKS
            sta   GBLOCKS
            lda   GFIPARM_BLKS+1
            sta   GBLOCKS+1
:haveblk    ldy   #RD_STYPE
            lda   RD_RECORD,y
            cmp   #STYP_DIR
            beq   :isedir
            lda   GBLOCKS
            ldx   GBLOCKS+1
            jsr   ADD16
            lda   AFLAG
            beq   :fnopr
            lda   SFLAG
            bne   :fnopr
            lda   GBLOCKS
            sta   U2DEC_VAL
            lda   GBLOCKS+1
            sta   U2DEC_VAL+1
            lda   #<FULLPATH
            sta   PTR0
            lda   #>FULLPATH
            sta   PTR0+1
            jsr   PRLINE
:fnopr      jmp   :bumpcur

:isedir     inc   CURRESN         ;count THIS entry (like a
            bne   :isedn1          ;file at :bumpcur) so the
            inc   CURRESN+1         ;PUSHFRAME below saves a
:isedn1     lda   DEPTH               ;resume count that skips
            cmp   #DU_MAXDEP          ;PAST this subdir, not
            bcc   :roomok             ;back onto it
            jsr   PRINTDEPTHERR
            jsr   CLOSEDIR
            lda   #2
            jsr   EXIT
:roomok     jsr   PUSHFRAME
            jsr   CLOSEDIR
            jsr   CP_FULLPATH
            stz   CURRESN
            stz   CURRESN+1
            lda   GBLOCKS
            sta   LEVTOT
            lda   GBLOCKS+1
            sta   LEVTOT+1
            inc   DEPTH
            jsr   OPENCUR
            bcs   :descfl
            jmp   :mainloop
:descfl     lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            jsr   PRINTACCESS
            lda   #1
            sta   ERRFLAG
            jmp   :popchild

:bumpcur    inc   CURRESN
            beq   :bumphi
            jmp   :mainloop
:bumphi     inc   CURRESN+1
            jmp   :mainloop

:ld         cmp   #0
            beq   :cleanof
            jsr   PRINTREADERR
            lda   #1
            sta   ERRFLAG
:cleanof    jsr   CLOSEDIR
:popchild   lda   DEPTH
            bne   :popit
            rts                    ;DEPTH 0 -- this argument's
                                   ;walk is done, LEVTOT is its
                                   ;grand total
:popit      lda   SFLAG
            bne   :nopr2
            lda   LEVTOT
            sta   U2DEC_VAL
            lda   LEVTOT+1
            sta   U2DEC_VAL+1
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            jsr   PRLINE
:nopr2      lda   LEVTOT
            sta   CHILDTOT
            lda   LEVTOT+1
            sta   CHILDTOT+1
            jsr   POPFRAME
            lda   CHILDTOT
            ldx   CHILDTOT+1
            jsr   ADD16
            jsr   OPENCUR
            bcc   :popok
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            jsr   PRINTACCESS
            lda   #1
            sta   ERRFLAG
            jmp   :popchild
:popok      jsr   SKIPRESUME
            jmp   :mainloop

*---------------------------------------------------------------
* ADD16 -- IN: A/X = lo/hi to add into LEVTOT. Overflow (carry
* out of the 16-bit add) is a fatal, loud error -- see header.
* CLOBBERS: A.
*---------------------------------------------------------------
ADD16       sta   ADD_LO
            stx   ADD_HI
            clc
            lda   LEVTOT
            adc   ADD_LO
            sta   LEVTOT
            lda   LEVTOT+1
            adc   ADD_HI
            sta   LEVTOT+1
            bcc   :noovf
            jmp   OVERFLOWERR
:noovf      rts

*---------------------------------------------------------------
* OVERFLOWERR -- "du: block count overflow" to stderr, exit 1.
* Does not return.
*---------------------------------------------------------------
OVERFLOWERR lda   #<OVFMSG
            sta   PTR0
            lda   #>OVFMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

*---------------------------------------------------------------
* PRLINE -- IN: PTR0 = path (hi-bit NUL), U2DEC_VAL = blocks.
* Prints "<blocks><TAB><path><CR>" to stdout. PRNUM's own PUTS
* call repoints PTR0 at PRNBUF, so the path pointer must be
* stashed first (found the hard way -- see report). CLOBBERS:
* everything PRNUM/PUTS/PUTC clobber, plus PRLPATH.
*---------------------------------------------------------------
PRLINE      lda   PTR0
            sta   PRLPATH
            lda   PTR0+1
            sta   PRLPATH+1
            lda   KFLAG
            beq   :nok
            jsr   TOKB
:nok        ldx   #FD_STDOUT
            jsr   PRNUM
            lda   #$89               ;TAB, high-bit
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   PRLPATH
            sta   PTR0
            lda   PRLPATH+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* TOKB -- U2DEC_VAL = (U2DEC_VAL+1)/2, 16-bit, ceiling. Turns a
* raw 512-byte ProDOS block count into 1024-byte units for -k.
*---------------------------------------------------------------
TOKB        clc
            lda   U2DEC_VAL
            adc   #1
            sta   U2DEC_VAL
            lda   U2DEC_VAL+1
            adc   #0
            sta   U2DEC_VAL+1
            lsr   U2DEC_VAL+1
            ror   U2DEC_VAL
            rts

*---------------------------------------------------------------
* PRINTACCESS -- IN: PTR0 = path. "du: <path>: cannot access" to
* stderr. CLOBBERS: A, X, Y, PTR0, EPPTR.
*---------------------------------------------------------------
PRINTACCESS lda   PTR0
            sta   EPPTR
            lda   PTR0+1
            sta   EPPTR+1
            lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   EPPTR
            sta   PTR0
            lda   EPPTR+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<ERRSUF_ACC
            sta   PTR0
            lda   #>ERRSUF_ACC
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

*---------------------------------------------------------------
* PRINTREADERR -- "du: <PATHBUF>: read error" to stderr.
*---------------------------------------------------------------
PRINTREADERR
            lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<ERRSUF_RD
            sta   PTR0
            lda   #>ERRSUF_RD
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

*---------------------------------------------------------------
* PRINTLONGENT -- "du: <FULLPATH>: pathname too long" to
* stderr. FULLPATH is NUL-terminated by BUILDCHILD (this
* routine's only caller path) before the length verdict.
*---------------------------------------------------------------
PRINTLONGENT
            lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<FULLPATH
            sta   PTR0
            lda   #>FULLPATH
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<ERRSUF_LNG
            sta   PTR0
            lda   #>ERRSUF_LNG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

*---------------------------------------------------------------
* PRINTDEPTHERR -- "du: max depth exceeded" to stderr.
*---------------------------------------------------------------
PRINTDEPTHERR
            lda   #<DEPTHMSG
            sta   PTR0
            lda   #>DEPTHMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

*---------------------------------------------------------------
* BUILDCHILD -- FULLPATH := PATHBUF[0..PATHLEN] + '/' +
* RD_RECORD's name + NUL. OUT: carry CLEAR = the child path is
* an addressable MLI pathname (<= MLI_PTH_MAXLN chars); carry
* SET = too long for any MLI call -- the caller must skip the
* entry LOUDLY and never CP_FULLPATH/MKFULLP it. The copy
* itself cannot overrun: FULLPATH is FP_BUFLEN bytes, the sum
* of the writers' own maxima (PATHLEN <= MLI_PTH_MAXLN by
* PROCESSARG's bound and the carry contract here; RD_NAME is
* at most 15 chars + NUL). Same contract as find.s's own
* BUILDCHILD. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
BUILDCHILD  ldx   #0
:cp1        cpx   PATHLEN
            beq   :cp1done
            lda   PATHBUF,x
            sta   FULLPATH,x
            inx
            bra   :cp1
:cp1done    cpx   #0                 ;one '/' between the parts,
            beq   :slash             ;never two: PATHBUF ends in
            lda   FULLPATH-1,x ;'/' for "BIN/", "/mnt/MAUX/"
            cmp   #$AF               ;operands (a bare "/" too)
            beq   :nosl
:slash      lda   #$AF               ;'/' high-bit
            sta   FULLPATH,x
            inx
:nosl       ldy   #0
:cp2        lda   RD_RECORD+RD_NAME,y
            sta   FULLPATH,x
            beq   :cp2done
            inx
            iny
            bra   :cp2
:cp2done    cpx   #MLI_PTH_MAXLN+1   ;X = length in chars;
            rts                      ;carry set = cannot fit an
                                     ;MLI pathname -- skip it

*---------------------------------------------------------------
* CP_FULLPATH -- PATHBUF := FULLPATH, PATHLEN updated.
*---------------------------------------------------------------
CP_FULLPATH ldx   #0
:cp         lda   FULLPATH,x
            sta   PATHBUF,x
            beq   :done
            inx
            bra   :cp
:done       stx   PATHLEN
            rts

*---------------------------------------------------------------
* MKPATHBUF -- PATHBUF (liba string) -> MLIPATH (MLI-shaped).
*---------------------------------------------------------------
MKPATHBUF   lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            lda   #<MLIPATH
            sta   PTR1
            lda   #>MLIPATH
            sta   PTR1+1
            jmp   MKPATH

*---------------------------------------------------------------
* MKFULLP -- FULLPATH (liba string) -> MLIPATH (MLI-shaped).
*---------------------------------------------------------------
MKFULLP     lda   #<FULLPATH
            sta   PTR0
            lda   #>FULLPATH
            sta   PTR0+1
            lda   #<MLIPATH
            sta   PTR1
            lda   #>MLIPATH
            sta   PTR1+1
            jmp   MKPATH

*---------------------------------------------------------------
* OPENCUR -- MKPATHBUF then OPENDIR(MLIPATH).
*---------------------------------------------------------------
OPENCUR     jsr   MKPATHBUF
            lda   #<MLIPATH
            ldx   #>MLIPATH
            jmp   OPENDIR

*---------------------------------------------------------------
* PUSHFRAME -- save PATHLEN/CURRESN/LEVTOT into DS_*[DEPTH].
*---------------------------------------------------------------
PUSHFRAME   ldx   DEPTH
            lda   PATHLEN
            sta   DS_PLEN,x
            txa
            asl   a
            tax
            lda   CURRESN
            sta   DS_RESN,x
            lda   CURRESN+1
            sta   DS_RESN+1,x
            lda   LEVTOT
            sta   DS_TOTAL,x
            lda   LEVTOT+1
            sta   DS_TOTAL+1,x
            rts

*---------------------------------------------------------------
* POPFRAME -- DEPTH--, restore PATHLEN/CURRESN/LEVTOT from
* DS_*[DEPTH], re-terminate PATHBUF at the restored length.
*---------------------------------------------------------------
POPFRAME    dec   DEPTH
            ldx   DEPTH
            lda   DS_PLEN,x
            sta   PATHLEN
            txa
            asl   a
            tax
            lda   DS_RESN,x
            sta   CURRESN
            lda   DS_RESN+1,x
            sta   CURRESN+1
            lda   DS_TOTAL,x
            sta   LEVTOT
            lda   DS_TOTAL+1,x
            sta   LEVTOT+1
            ldx   PATHLEN
            stz   PATHBUF,x
            rts

*---------------------------------------------------------------
* SKIPRESUME -- call READDIR CURRESN times, discarding results.
*
* COUNTS DOWN A COPY, for the reason src/bin/find.s's own
* SKIPRESUME spells out: CURRESN is this level's ABSOLUTE
* position and must survive the skip, because the next descend
* from this level PUSHFRAMEs it again. Spending it here makes
* the walk LOOP FOREVER over any directory holding TWO OR MORE
* subdirectories -- the second one saves a frame that says 1,
* comes back, skips one entry, re-reads itself, and descends
* again. This file copied find.s's shape (see the header) and
* copied the bug with it; both were fixed 2026-08-24.
*---------------------------------------------------------------
SKIPRESUME  lda   CURRESN
            sta   SKIPN
            lda   CURRESN+1
            sta   SKIPN+1
            ora   SKIPN
            beq   :sdone
:sloop      lda   #<RD_RECORD
            ldx   #>RD_RECORD
            jsr   READDIR
            bcs   :sdone
            lda   SKIPN
            bne   :sdec
            dec   SKIPN+1
:sdec       dec   SKIPN
            lda   SKIPN
            ora   SKIPN+1
            bne   :sloop
:sdone      rts

*---------------------------------------------------------------
* Data (real bytes -- outside the dum/dend arena).
*---------------------------------------------------------------
OPTSTR      asc   "sak"
            dfb   0

USAGEMSG    asc   "usage: du [-s] [-a] [-k] [path...]"
            dfb   $8D,0
DOTSTR      asc   "."
            dfb   0
OVFMSG      asc   "du: block count overflow"
            dfb   $8D,0
LONGMSG     asc   "du: pathname too long"
            dfb   $8D,0
DEPTHMSG    asc   "du: max depth exceeded"
            dfb   $8D,0
ERRPFX      asc   "du: "
            dfb   0
ERRSUF_ACC  asc   ": cannot access"
            dfb   $8D,0
ERRSUF_RD   asc   ": read error"
            dfb   $8D,0
ERRSUF_LNG  asc   ": pathname too long"
            dfb   $8D,0

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
* du's own scratch, dum/dend'd at the textual end (never `ds` --
* real zeros cost 39.07 cyc/byte at spawn time). `dum` memory is
* NOT zeroed -- every cell here is written before its first
* read:
*  - SKIPN: SKIPRESUME's countdown copy, written from CURRESN
*    as that routine's first two instructions and read only
*    after -- see its header for why the skip must not spend
*    CURRESN itself.
*  - ERRFLAG/SFLAG/AFLAG/DEPTH/CURRESN: zeroed by START before
*    anything else runs.
*  - ARGI: written by START's own loop setup before its first
*    read.
*  - LEVTOT: seeded from GFIPARM_BLKS (PROCESSARG) or GBLOCKS
*    (WALK's descend path) before any ADD16/PRLINE reads it.
*  - CHILDTOT/GBLOCKS/ADD_LO/ADD_HI/EPPTR/PRLPATH: each written
*    by its
*    own routine immediately before that same routine reads it
*    back.
*  - PATHLEN/PATHBUF: written by PROCESSARG's STRCPY before
*    WALK/MKPATHBUF ever read either.
*  - FULLPATH: written whole (NUL-terminated) by BUILDCHILD
*    before WALK's main loop reads it.
*  - MLIPATH: written by MKPATHBUF/MKFULLP before OPENDIR/SC_GFI
*    (which patch GFIPARM_PATH, real data above) read it.
*  - RD_RECORD: written whole by READDIR before WALK reads it.
*  - DS_PLEN/DS_RESN/DS_TOTAL: written by PUSHFRAME before the
*    matching POPFRAME reads that same slot.
*  - NPATHS: written by START before its own first read.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ERRFLAG     ds    1
SFLAG       ds    1
AFLAG       ds    1
KFLAG       ds    1
DEPTH       ds    1
CURRESN     ds    2
SKIPN       ds    2              ;SKIPRESUME's countdown copy
LEVTOT      ds    2
CHILDTOT    ds    2
GBLOCKS     ds    2
ADD_LO      ds    1
ADD_HI      ds    1
EPPTR       ds    2
PRLPATH     ds    2

ARGI        ds    1
NPATHS      ds    1

PATHLEN     ds    1
PATHBUF     ds    MLI_PTH_MAXLN+1
FULLPATH    ds    FP_BUFLEN
FPGAP1      equ   *-FULLPATH+1
* -- SIZING TRIPWIRE (adversarial review B2, 2026-08-23):
* -- the relayout's whole claim is that FULLPATH is at
* -- least the writers' sum -- PATHBUF + '/' + 15-char
* -- name + NUL -- and a comment cannot hold that claim:
* -- reverting this ds to 65 passed the WHOLE gate (the
* -- carry fence masks the spill, and the .bin byte count
* -- cannot witness a dum-arena change). The division is
* -- 0 while FULLPATH is big enough, 1 when it is not,
* -- and `err` fails the assembly -- same idiom as the
* -- arena-end tripwire below.
            err   FPMINSZ/FPGAP1
MLIPATH     ds    MLI_PTH_MAXLN+1

DS_PLEN     ds    DU_MAXDEP
DS_RESN     ds    DU_MAXDEP*2
DS_TOTAL    ds    DU_MAXDEP*2

RD_RECORD   ds    RD_SIZE

DU_BSSEND                        ;scripts/check_du.py's poison
                                 ;span ends here (same job as
                                 ;ls.s's LS_BSSEND)
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
            err   */$BF00
            dend
