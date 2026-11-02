*---------------------------------------------------------------
* cp.s -- copy a file.
*
* CONTRACT: `cp SRC DST` copies the contents of file SRC to file
* DST. Exit 0 on success, 1 on any create/open/read/write error;
* a wrong argument count is a usage error (stderr, exit 2).
*
* RECURSIVE COPY (2026-08-25, task #16): `cp -r SRC DST` and
* `cp -R SRC DST` copy a DIRECTORY tree. BOTH spellings are
* accepted -- POSIX spells it -R, GNU takes either, so a script
* written against either host runs here. The flag must be
* argv[1]; cp has no option permutation today and gaining one
* was not that change. COPYDIR is the policy and
* src/liba/cptree.s is the engine, shared with mv's recursive
* move; docs/CPTREE.md is the design note.
*
* WITHOUT -r a directory SOURCE is still REFUSED, and that is
* not drift: /bin/cp refuses it too ("cp: DIR is a directory
* (not copied)", exit 1). The ('cp', 'no recursive copy')
* divergence entry died on 2026-08-25 because it had been
* manufactured -- the corpus asked the REFERENCE `cp -r`, a
* different question, and then ruled away the difference that
* created. Do not bring it back.
*
* cp -r MERGES into an existing destination directory where `mv`
* demands an empty one. Measured against /bin/cp and /bin/mv the
* same day: a real difference between the two tools, not drift.
*
* DIRECTORY TARGET (2026-08-25): `cp SRC DIR` copies SRC INTO
* DIR when DIR exists and is a directory, and `cp SRC DIR/`
* demands DIR be one -- Unix semantics, resolved up front by
* DSTRESOLV. This header used to say there was no directory-
* target support; that was avoidable semantic drift, not a
* design decision, and it is gone. Refusing a directory SOURCE
* is NOT drift and stays: /bin/cp without -r refuses it too.
*
* REWORKED this round against the RATIFIED ABI (docs/SYSCALL.md)
* -- CONSUMER-REALITY FINDING (see final report): the real MLI
* CREATE call ($C0, TRM ch. 4) has NO ref_num result field at
* all -- it only creates the directory entry. This slice's
* ORIGINAL draft assumed creat() returns a usable fd directly
* (V6 convention), which does not hold once file calls forward
* to a REAL MLI. cp now does the genuine two-step MLI dance
* every ProDOS system program does: CREATE the file, then a
* SEPARATE OPEN to actually get a ref_num/fd. This is not a maux
* invention -- it's how ProDOS itself requires new files to be
* made usable.
*
* By default CREATE supplies the destination's ordinary access,
* storage type and date policy while file_type/aux_type follow
* the source. With -p, cp additionally carries the source's
* access, create/modification dates, file_type and aux_type
* through CREATE and SET_FILE_INFO.
*
* io_buffer (architect review, merge-blocking finding, corrected
* this round): BOTH OPEN calls' io_buffer fields are kernel-
* owned MAIN memory, NOT process buffers -- the MLI dereferences
* io_buffer CONTINUOUSLY while a file stays open and cannot see
* process banks at all, so a process-bank address there would be
* meaningless to it. cp used to reserve SIOBUF/DIOBUF (1024B
* each, 2KB total) for this; both are GONE -- the fields are set
* to $0000 (PROPOSED convention, task #11 ratifies --
* docs/USERLAND.md "ABI RESOLUTIONS"). CBUF (the READ/WRITE
* data_buffer) is NOT affected by this -- that field is
* correctly a process-bank address; the kernel copyin/outs
* through it via bankcopy.
*
* Uses ONLY liba (src/liba) -- no direct syscalls, no raw gate
* address, no equates; see docs/USERLAND.md and syscalls.s's
* header for why.
*
* STREAM T4 (2026-08-23), three defects pinned by
* scripts/e2e_fs_mutate.py's DEFECTS table, fixed together:
*
* 1. cp COULD NOT OVERWRITE AN EXISTING DESTINATION AT ALL --
*    SC_CREAT's carry was unconditionally treated as fatal, so
*    a DST that already existed (MLI errno ERR_DUPFN, $47)
*    made cp fail outright where host cp trivially replaces
*    the file.
*
* 2. SRC BEING A DIRECTORY WAS COPIED, NOT REJECTED -- this
*    file's own header (above) says "copies exactly one
*    regular file"; GFIPARM_STYP was fetched by the SC_GFI
*    stat and never tested. FIX: reject storage_type STYP_DIR
*    ($0D) or the volume-dir storage_type $0F (no house
*    constant for the second -- same precedent as ls.s/file.s)
*    with a diagnostic, exit 1, BEFORE CREATE/OPEN of DST ever
*    runs. SEVERITY: ProDOS OPEN has no storage_type gate
*    (PRC_OPEN, src/kernel/procfile3.s, a plain MLI delegate --
*    learning:01M0PSV2PVPWKHZZF5A52EWX31; the same mechanism
*    src/liba/readdir.s's OPENDIR relies on), so unfixed, SRC's
*    raw directory blocks get copied into a GARBLED,
*    misleadingly-typed DST, cp EXITS 0, prints nothing.
*
* 3. REVIEW FINDING (2026-08-23): defect 1's ORIGINAL fix used
*    SC_SETEOF to truncate DST to 0 in place after OPEN, rather
*    than DESTROY-and-recreate -- deliberately, to avoid a
*    worse failure mode (DESTROY succeeds, CREATE then fails
*    for an unrelated reason, DST gone with NOTHING in its
*    place). But CREATE is the ONLY call that sets file_type/
*    aux_type and never touches an EXISTING entry (mv.s:35-39
*    states this identically), so truncate-in-place left the
*    stat-and-patch of CRPARM_TYPE/CRPARM_AUX (below) DEAD CODE
*    on exactly the overwrite path this fix added: `cp SRC DST`
*    onto a pre-existing BIN-typed DST left it BIN even when
*    SRC was TXT. FIX, matching mv.s's own choice: destroy DST
*    and retry CREATE (with SRC's type already patched into
*    CRPARM) instead of truncating in place, so the retried
*    CREATE actually applies the type. This reintroduces the
*    exact hazard defect 1's truncate avoided (DESTROY succeeds,
*    retry CREATE fails, DST is gone) -- accepted for the same
*    reason mv.s accepts it: a non-atomic replace has no cheaper
*    option on a filesystem with no rename/truncate-with-type
*    primitive. GUARDED the same way mv.s guards it, too:
*    DESTROY also empties an EMPTY subdirectory (P8 TRM 4.4.2),
*    so DST is GET_FILE_INFO-stat'd before the destroy and a
*    directory DST is REFUSED (ordinary :err path) rather than
*    deleted and replaced by a file.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/cp.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/readdir.equ
            put   ../../inc/cptree.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   512

* -- ProDOS MLI error $47, "duplicate filename" (P8 TRM ch. 4's
* -- CREATE error table) -- no house constant for MLI errno
* -- values exists yet (inc/errno.equ covers only maux's own
* -- kernel/spawn error space). CREATE returns exactly this when
* -- DST already names a file -- the one CREATE failure this
* -- program treats as "fine, open the existing file and
* -- truncate it" rather than a real error (see :sok2 below).
ERR_DUPFN   equ   $47

*-- ARGUMENT SHAPES. `cp SRC DST` is argc 3, unchanged.
*-- Options occupy argv[1] and may be clustered. Both -r and -R
*-- select recursive copying; -p preserves ProDOS metadata and
*-- -i prompts before replacement. The flag must come FIRST --
*-- cp has no option
*-- permutation today and gaining one is not this change.
START       stz   RFLAG
            stz   PFLAG
            stz   IFLAG
            stz   MERRFLG
            lda   #1
            sta   FIRSTSRC
            lda   ARGC
            cmp   #3
            bcs   :argok
            jmp   :usage                 ;fewer than 2 operands
:argok
            lda   #1
            jsr   GETARG                 ;-> PTR0 = argv[1]
            ldy   #0
            lda   (PTR0),y
            cmp   #"-"
            bne   :noflag
            iny
:flaglp     lda   (PTR0),y
            beq   :flagdone
            cmp   #"r"
            beq   :flagok
            cmp   #"R"
            beq   :flagok
            cmp   #"p"
            bne   :notp
            sta   PFLAG
            bra   :flagnext
:notp       cmp   #"i"
            bne   :usage
            sta   IFLAG
            bra   :flagnext
:flagok
            lda   #1
            sta   RFLAG
:flagnext   iny
            bra   :flaglp
:flagdone   cpy   #1
            beq   :usage
            lda   #2
            sta   FIRSTSRC
:noflag     lda   ARGC
            sec
            sbc   FIRSTSRC               ;operand count
            cmp   #2
            bcc   :usage
            cmp   #3
            bcc   :golist                ;exactly SRC DST: the
                                         ;old shape, bit for bit
*-- MULTI-INTO-DIRECTORY (FLEET F.2, 2026-09-01): `cp A B... D`
*-- copies each source into D, which must ALREADY be a
*-- directory -- checked once up front. Each pair runs CPONE; a
*-- failed pair reports, sets exit 1, and the loop CONTINUES,
*-- POSIX's rule.
            jsr   TGTCHK
            bcc   :golist
            lda   #<NOTDIRMSG
            sta   PTR0
            lda   #>NOTDIRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jsr   EXIT
:golist     lda   FIRSTSRC
            sta   CPSRC
:mloop      jsr   CPONE
            bcc   :mnext
            lda   #1
            sta   MERRFLG
:mnext      inc   CPSRC
            lda   CPSRC
            clc
            adc   #1
            cmp   ARGC
            bcc   :mloop
            lda   MERRFLG
            jsr   EXIT
:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* TGTCHK -- carry clear iff the LAST operand names an existing
* directory. Builds it into DPATHBUF (clobbered per-pair anyway)
* and stats through GFIPARM. A trailing slash comes off for the
* stat, DSTRESOLV-style.
*---------------------------------------------------------------
TGTCHK      lda   ARGC
            sec
            sbc   #1
            jsr   GETARG
            lda   #<DPATHBUF
            sta   PTR1
            lda   #>DPATHBUF
            sta   PTR1+1
            jsr   MKPATH
            ldy   DPATHBUF
            beq   :notdir
            cpy   #1
            beq   :stat                  ;"/" alone
            lda   DPATHBUF,y
            cmp   #'/'
            bne   :stat
            dey
            sty   DPATHBUF
:stat       lda   #<DPATHBUF
            sta   GFIPARM_PATH
            lda   #>DPATHBUF
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :notdir
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #$0F                   ;volume dir (ls.s)
            beq   :isdir
:notdir     sec
            rts
:isdir      clc
            rts

*---------------------------------------------------------------
* CPONE -- copy argv[CPSRC] to argv[ARGC-1]: the whole former
* single-shot body. OUT: carry clear = copied; carry set =
* failed with its message already printed (directly, or the
* PRINTED-guarded generic in CPERR). A GLOBAL label on purpose:
* the loop above and the body below are separate local-label
* zones now (CPERR's own header tells the cross-zone story).
*
* FD DISCIPLINE, new with the loop: the old single-shot exits
* leaked open fds to process teardown, which a per-pair failure
* cannot -- MLI io_buffers are a pool of 6 system-wide. Every
* failure past an OPEN now unwinds through CPCLSRC/CPCLBOTH.
*---------------------------------------------------------------
CPONE       stz   PRINTED
            lda   CPSRC
            jsr   GETARG                 ;-> PTR0 = SRC path
                                         ;(liba string)
            lda   #<SPATHBUF
            sta   PTR1
            lda   #>SPATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   ARGC
            sec
            sbc   #1
            jsr   GETARG                 ;-> PTR0 = DST path
            lda   #<DPATHBUF
            sta   PTR1
            lda   #>DPATHBUF
            sta   PTR1+1
            jsr   MKPATH
*-- SRC's own trailing "/" comes off BEFORE DSTRESOLV reads
*-- basename(SRC) -- see SRCSLASH. Then the one stat that three
*-- decisions turn on.
            jsr   SRCSLASH
            jsr   SRCISDIR
            lda   SSLASHED
            beq   :srcok
            lda   SRCISDIRF
            bne   :srcok
            lda   #<SNOTDIRMSG
            sta   PTR0
            lda   #>SNOTDIRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   PRINTED
            jmp   CPERR
:srcok      jsr   DSTRESOLV
            bcc   :dstok            ;long-range: :err sits past
            jmp   CPERR               ;the whole copy-loop body
*-- WITH -r AND A DIRECTORY SOURCE, take the recursive road.
*-- With -r and a plain FILE source this falls straight through
*-- to the ordinary single-file copy, which is what the host
*-- does too -- `cp -r file dest` is not an error. WITHOUT -r a
*-- directory source is still REFUSED, by the guard further
*-- down: /bin/cp refuses it too, so that is not drift and the
*-- ('cp','no recursive copy') entry that claimed otherwise died
*-- on 2026-08-25 for exactly that reason.
:dstok      lda   RFLAG
            beq   :notrec
            lda   SRCISDIRF
            beq   :notrec
            jsr   COPYDIR              ;refusals print inside
            bcs   :direrr              ;COPYDIR itself
            clc
            rts
:direrr     jmp   DIRERR
:notrec     lda   #<SOPARM
            ldx   #>SOPARM
            jsr   SC_OPEN
            bcc   :sok1                  ;long-range: :err sits
                                         ;past the
            jmp   CPERR                    ;whole
                                         ;CREATE/OPEN/copy-loop
                                         ;body
:sok1                                    ;-- correction
                                         ;(architect review):
                                         ;NOT the io_buffers,
                                         ;which were never
                                         ;between a branch and
                                         ;its target -- plain
                                         ;code distance, a plain
                                         ;BCS's +/-127B can't
                                         ;reach
            lda   SOPARM_REF
            sta   SRCFD

            ;-- DST's path was built (and its directory form
            ;-- resolved) before SRC was opened; see :ok above.
            ;stat SRC (SC_GFI, SYS_GFI $C4) so DST's CREATE can
            ;carry SRC's real file_type/aux_type instead of a
            ;hardcoded BIN -- see header.
            ;POINT GFIPARM_PATH AT SRC EXPLICITLY. The `da
            ;SPATHBUF` initializer below is NOT enough: the
            ;:dupfn branch overwrites that cell with DPATHBUF
            ;and never restores it, and under LAZY FREE
            ;(src/kernel/lazyfree.s) the next `cp` of the
            ;session is handed the SAME BANK with NO image
            ;copy -- so it inherits the overwrite and stats DST
            ;where it means SRC, silently defeating the dir-SRC
            ;guard below. Same defect as mv.s; measured
            ;2026-08-24 with scripts/probe_mvdir.py.
            ;Deposited as
            ;learning:01M0T103ZQSAEGQ5D8FS8XZ8V4.
            lda   #<SPATHBUF
            sta   GFIPARM_PATH
            lda   #>SPATHBUF
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :sokgfi
            jmp   CPCLSRC
:sokgfi     ;defect 2 -- reject SRC being a directory, BEFORE
            ;any CREATE/OPEN of DST (see header). STYP_DIR
            ;($0D) or the volume-dir storage_type $0F (no
            ;house constant -- same precedent as ls.s/file.s).
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #$0F              ;volume-dir storage_type --
            bne   :nodir            ;no house constant for this
                                    ;one (same as ls.s/file.s)
:isdir      lda   #<DIRMSG
            sta   PTR0
            lda   #>DIRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   PRINTED
            jmp   CPCLSRC
:nodir      lda   GFIPARM_FTYP
            sta   CRPARM_TYPE
            lda   GFIPARM_AUX
            sta   CRPARM_AUX
            lda   GFIPARM_AUX+1
            sta   CRPARM_AUX+1
            lda   PFLAG
            beq   :mkdst
            jsr   PREPATTR
:mkdst
            ;CREATE first -- makes the directory entry, returns
            ;NO fd
            ;(real MLI CREATE has no ref_num field -- see
            ;header).
            lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT
            bcc   :sok2
            cmp   #ERR_DUPFN        ;defect 1/3 -- DST exists;
            beq   :dupfn            ;any OTHER errno is fatal
            jmp   CPCLSRC
            ;-- DST exists. DESTROY also empties an EMPTY
            ;-- subdirectory (P8 TRM 4.4.2) -- stat DST first
            ;-- and refuse rather than replace a directory with
            ;-- a file. Reuses GFIPARM: SRC's own stat is
            ;-- already consumed into CRPARM above (:nodir).
:dupfn      lda   #<DPATHBUF
            sta   GFIPARM_PATH
            lda   #>DPATHBUF
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :dgfiok
            jmp   CPCLSRC
:dgfiok     lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :ddir
            cmp   #$0F
            bne   :notddir
:ddir       jmp   CPCLSRC
:notddir    lda   IFLAG
            beq   :dounlink
            jsr   CPPROMPT
            bcs   :dounlink
            jmp   CPSKIP
:dounlink   lda   #<DDPARM
            ldx   #>DDPARM
            jsr   SC_UNLINK
            bcc   :retry
            jmp   CPCLSRC
:retry      lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT
            bcc   :sok2
            jmp   CPCLSRC
            ;-- ...then OPEN the just-created (fresh or
            ;-- destroy-and-recreated) file to get a fd. CREATE
            ;-- guarantees eof=0 on both paths now, so no
            ;-- separate truncate step is needed (defect 3 --
            ;-- see file header).
:sok2       lda   #<DOPARM
            ldx   #>DOPARM
            jsr   SC_OPEN
            bcc   :sok3
            jmp   CPCLSRC
:sok3       lda   DOPARM_REF
            sta   DSTFD

:cpylp      lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcc   :sok4
            jmp   CPCLBOTH
:sok4       lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :cpydone                ;trans_count == 0 --
                                          ;EOF
            lda   RPARM_TRANS
            sta   WPARM_REQ
            lda   RPARM_TRANS+1
            sta   WPARM_REQ+1
            lda   DSTFD
            sta   WPARM_REF
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcc   :sok5
            jmp   CPCLBOTH
:sok5       bra   :cpylp

:cpydone    lda   SRCFD
            sta   C1PARM_REF
            lda   #<C1PARM
            ldx   #>C1PARM
            jsr   SC_CLOSE
            lda   DSTFD
            sta   C2PARM_REF
            lda   #<C2PARM
            ldx   #>C2PARM
            jsr   SC_CLOSE
            lda   PFLAG
            beq   :copyok
            lda   #<SFIPARM
            ldx   #>SFIPARM
            jsr   SC_SFI
            bcc   :copyok
            jmp   CPERR
:copyok
            clc
            rts

*-- PREPATTR -- copy the source GFI fields used by CREATE/SFI.
PREPATTR    lda   GFIPARM_CDATE
            sta   CRPARM_CDATE
            lda   GFIPARM_CDATE+1
            sta   CRPARM_CDATE+1
            lda   GFIPARM_CTIME
            sta   CRPARM_CTIME
            lda   GFIPARM_CTIME+1
            sta   CRPARM_CTIME+1
            lda   GFIPARM_ACC
            sta   SFIPARM_ACC
            lda   GFIPARM_FTYP
            sta   SFIPARM_FTYP
            lda   GFIPARM_AUX
            sta   SFIPARM_AUX
            lda   GFIPARM_AUX+1
            sta   SFIPARM_AUX+1
            lda   GFIPARM_MDATE
            sta   SFIPARM_MDATE
            lda   GFIPARM_MDATE+1
            sta   SFIPARM_MDATE+1
            lda   GFIPARM_MTIME
            sta   SFIPARM_MTIME
            lda   GFIPARM_MTIME+1
            sta   SFIPARM_MTIME+1
            rts

*-- CPPROMPT -- prompt on fd 2; carry set only for y/Y.
CPPROMPT    lda   #<PROMPTMSG
            sta   PTR0
            lda   #>PROMPTMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            ldx   #FD_STDIN
            jsr   GETC
            bcc   :got
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            bra   :no
:got        pha
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            pla
            and   #$DF
            cmp   #$D9
            beq   :yes
:no         clc
            rts
:yes        sec
            rts

CPSKIP      lda   SRCFD
            sta   C1PARM_REF
            lda   #<C1PARM
            ldx   #>C1PARM
            jsr   SC_CLOSE
            clc
            rts

*---------------------------------------------------------------
* CPCLBOTH/CPCLSRC -- failure unwinds: close what this pair
* opened, then take the shared failure exit. jmp'd to, stack
* balanced at CPONE's frame, so CPERR's rts lands in the loop.
*---------------------------------------------------------------
CPCLBOTH    lda   DSTFD
            sta   C2PARM_REF
            lda   #<C2PARM
            ldx   #>C2PARM
            jsr   SC_CLOSE
CPCLSRC     lda   SRCFD
            sta   C1PARM_REF
            lda   #<C1PARM
            ldx   #>C1PARM
            jsr   SC_CLOSE
            jmp   CPERR
            put   cpdir.s
            put   cpcopyd.s

USAGEMSG    asc   "usage: cp [-iprR] SRC... DST"
            dfb   $00
ERRMSG      asc   "cp: error"
            dfb   $00
NOTDIRMSG   asc   "cp: DST is not a directory"
            dfb   $00
TOOLONGM    asc   "cp: pathname too long"
            dfb   $00
DIRMSG      asc   "cp: SRC is a directory"
            dfb   $00
SNOTDIRMSG  asc   "cp: SRC is not a directory"
            dfb   $00
SELFMSG     asc   "cp: cannot copy a directory into itself"
            dfb   $00
PROMPTMSG   asc   "cp: overwrite? "
            dfb   $00
DEEPMSG     asc   "cp: directory tree too deep"
            dfb   $00
SOPARM      dfb   PCOUNT_OPEN
SOPARM_PATH da    SPATHBUF
SOPARM_IOBF da    $0000          ;kernel-owned (main memory) --
                                 ;see header
SOPARM_REF  dfb   0              ; result: SRC fd

DOPARM      dfb   PCOUNT_OPEN
DOPARM_PATH da    DPATHBUF
DOPARM_IOBF da    $0000          ;kernel-owned (main memory) --
                                 ;see header
DOPARM_REF  dfb   0              ; result: DST fd

* GET_FILE_INFO parmlist (SC_GFI, SYS_GFI $C4),
* PCOUNT_GFI-shaped (inc/mli.equ) -- stats SRC so
* CRPARM_TYPE/CRPARM_AUX below can be patched from the real
* values before CREATE runs, and again stats DST (GFIPARM_PATH
* repointed at DPATHBUF) on a duplicate-name CREATE failure, to
* refuse destroying a directory (defect 3 -- see header).
GFIPARM       dfb   PCOUNT_GFI
GFIPARM_PATH  da    SPATHBUF
GFIPARM_ACC   dfb   0
GFIPARM_FTYP  dfb   0
GFIPARM_AUX   da    0
GFIPARM_STYP  dfb   0
GFIPARM_BLKS  da    0
GFIPARM_MDATE da    0
GFIPARM_MTIME da    0
GFIPARM_CDATE da    0
GFIPARM_CTIME da    0

* CREATE parmlist -- CRPARM_TYPE/CRPARM_AUX are PATCHED from
* GFIPARM (SRC's real file_type/aux_type) just before SC_CREAT
* runs; the dfb/da values below are only the pre-patch default
* (never actually used -- see header). access/storage_type/dates
* remain liba-chosen defaults unless -p patches them.
CRPARM        dfb   PCOUNT_CREATE
CRPARM_PATH   da    DPATHBUF
CRPARM_ACCESS dfb   ACCESS_UNLKD
CRPARM_TYPE   dfb   FTYPE_BIN
CRPARM_AUX    da    0
CRPARM_STORE  dfb   STYP_SEEDLING
CRPARM_CDATE  da    0            ;no clock wired -- see
                                 ;docs/USERLAND.md
CRPARM_CTIME  da    0            ; "ABI RESOLUTIONS"

* DESTROY parmlist for an already-existing DST -- the copy loop
* destroys DST and retries CREATE once when CREATE reports a
* duplicate pathname AND DST is not itself a directory (defect
* 3 -- see header). Same shape as the SRC path (SPATHBUF is
* never destroyed by cp; this parmlist exists only for DST).
DDPARM      dfb   PCNT_DESTROY
DDPARM_PATH da    DPATHBUF

SFIPARM     dfb   PCOUNT_SFI
SFIPARM_PATH da   DPATHBUF
SFIPARM_ACC dfb   0
SFIPARM_FTYP dfb  0
SFIPARM_AUX da    0
SFIPARM_NULL dfb  0,0,0
SFIPARM_MDATE da  0
SFIPARM_MTIME da  0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0              ; patched from SRCFD each chunk
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0              ; result: bytes actually read

WPARM       dfb   PCOUNT_WRITE
WPARM_REF   dfb   0              ; patched from DSTFD each chunk
WPARM_BUF   da    CBUF
WPARM_REQ   da    0              ;patched from RPARM_TRANS each
                                 ;chunk
WPARM_TRANS da    0

C1PARM      dfb   PCOUNT_CLOSE
C1PARM_REF  dfb   0              ; patched from SRCFD
C2PARM      dfb   PCOUNT_CLOSE
C2PARM_REF  dfb   0              ; patched from DSTFD

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
*-- readdir.s + cptree.s: `cp -r` (2026-08-25). Both are CODE
*-- and both must be `put` BEFORE libabss.s, which opens liba's
*-- `dum` arena and must stay last -- sec 21's own gate fails
*-- program that puts anything after it. cptree's storage lives
*-- in libabss.s for that reason; see the cptree section there.
            put   ../liba/readdir.s
            put   ../liba/readsyn.s
            put   ../liba/readsys.s
            put   ../liba/cptree.s
            put   ../liba/cptree2.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s
            put   ../liba/cptreebss.s

*---------------------------------------------------------------
* cp's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN). 644 bytes that were
* emitted zeros. The eight parmlists stay above as initialised
* data; `da SPATHBUF` / `da CBUF` resolve into this arena as
* forward references.
*
* cp is structurally cat.s with a second fd, and this is the
* same trace cat.s writes out at its own arena.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - SRCFD/DSTFD: each `sta`'d only after its own SC_OPEN
*    returned carry-clear; every `:err` path reads neither.
*  - SPATHBUF/DPATHBUF: MKPATH writes chars then the count
*    byte, and the MLI reads only count+1 -- the tails are
*    never in view. SPATHBUF is also SC_GFI's pathname.
*  - CBUF: filled by SC_READ, and WPARM_REQ is set from
*    RPARM_TRANS, so SC_WRITE never reads past what this
*    call actually wrote.
*---------------------------------------------------------------
            dum   CPT_BSSEND
SRCFD       ds    1
DSTFD       ds    1

*-- RFLAG/PFLAG/IFLAG: `stz` at START before any read.
*-- ARGIDX: written by :haveargs before its own first read.
*-- SSLASHED/SRCISDIRF: `stz` is the first instruction of
*-- SRCSLASH/SRCISDIR respectively, and START calls both before
*-- anything downstream reads either.
RFLAG       ds    1
PFLAG       ds    1
IFLAG       ds    1
ARGIDX      ds    1
*-- MERRFLG/FIRSTSRC/CPSRC: stored in START's opening run
*-- before any read; PRINTED: `stz` is CPONE's first act.
MERRFLG     ds    1
FIRSTSRC    ds    1
CPSRC       ds    1
PRINTED     ds    1
SSLASHED    ds    1
SRCISDIRF   ds    1

DSLASHED    ds    1
SPATHBUF    ds    65
DPATHBUF    ds    65
CBUF        ds    BUFSZ          ;data_buffer -- process-bank
                                 ;address, kernel copyin/outs
                                 ;through it
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
