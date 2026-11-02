*---------------------------------------------------------------
* mvtop.s -- mv's front half,
* extracted from mv.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2 mains). One
* assembly stream: put exactly where the text sat; every rule
* in the manifest header applies unchanged.
*---------------------------------------------------------------
START       jsr   INITPARMS
            stz   IFLAG
            lda   #1
            sta   MSRCIDX
            lda   ARGC
            cmp   #3
            bcc   :usage
            lda   #1
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #"-"
            bne   :argcount
            iny
:optlp      lda   (PTR0),y
            beq   :optdone
            cmp   #"i"
            bne   :noti
            sta   IFLAG
            bra   :optnext
:noti       cmp   #"f"
            bne   :usage
            stz   IFLAG
:optnext    iny
            bra   :optlp
:optdone    cpy   #1
            beq   :usage
            lda   #2
            sta   MSRCIDX
:argcount   lda   ARGC
            sec
            sbc   MSRCIDX
            cmp   #2
            bcs   :haveargs
:usage
            lda   #<USAGE
            sta   PTR0
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*-- MULTI-INTO-DIRECTORY (FLEET F.2, 2026-09-01): `mv A B... D`
*-- moves each source into D, which must ALREADY be a directory
*-- -- checked once up front, so `mv A B C` with a plain-file C
*-- refuses before anything moves (the reference's "target is
*-- not a directory"). The 2-operand form is bit-for-bit the
*-- old behaviour, including replace-a-file. Each pair runs
*-- MOVEONE; a failed pair reports, sets the exit status and
*-- CONTINUES with the rest, POSIX's own rule.
:haveargs   stz   MERRFLG
            lda   ARGC
            sec
            sbc   MSRCIDX
            cmp   #3
            bcc   :mloop                ;plain pair
            lda   ARGC
            sec
            sbc   #1
            jsr   GETARG
            lda   #<DSTBUF
            sta   PTR1
            lda   #>DSTBUF
            sta   PTR1+1
            jsr   CPYARG
            bcs   :mtgtbad
            jsr   TGTISDIR
            bcc   :mloop
:mtgtbad    lda   #<NOTDIRMSG
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

:mloop      lda   MSRCIDX
            jsr   GETARG
            lda   #<SRCBUF
            sta   PTR1
            lda   #>SRCBUF
            sta   PTR1+1
            jsr   CPYARG
            bcs   :mfail
            lda   ARGC
            sec
            sbc   #1
            jsr   GETARG
            lda   #<DSTBUF
            sta   PTR1
            lda   #>DSTBUF
            sta   PTR1+1
            jsr   CPYARG
            bcs   :mfail
            jsr   MOVEONE
            bcc   :mnext
:mfail      lda   #1
            sta   MERRFLG
:mnext      inc   MSRCIDX
            lda   MSRCIDX
            clc
            adc   #1
            cmp   ARGC
            bcc   :mloop
            lda   MERRFLG
            jsr   EXIT

*---------------------------------------------------------------
* TGTISDIR -- carry clear iff DSTBUF names an EXISTING directory
* (a trailing slash is stripped for the stat only; the per-pair
* copy rebuilds DSTBUF anyway). Multi-form's up-front gate.
*---------------------------------------------------------------
TGTISDIR    ldy   #0
:scan       lda   DSTBUF,y
            beq   :atend
            iny
            bne   :scan
:atend      dey
            bmi   :notdir
            lda   DSTBUF,y
            cmp   #"/"
            bne   :stat
            lda   #0
            sta   DSTBUF,y
:stat       lda   #<DSTBUF
            sta   PTR0
            lda   #>DSTBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :notdir
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #$0F                  ;volume dir (ls.s/file.s
            beq   :isdir                ;precedent, no constant)
:notdir     sec
            rts
:isdir      clc
            rts

*---------------------------------------------------------------
* MOVEONE -- move SRCBUF to DSTBUF: the whole former single-shot
* body. OUT: carry clear = moved; carry set = failed, message
* already printed (every failure path prints for itself or via
* the PRINTED-guarded tail below).
*---------------------------------------------------------------
MOVEONE     stz   PRINTED

*-- SRC's OWN trailing slash, stripped before anything reads
*-- basename(SRC). See SRCSLASH.
            jsr   SRCSLASH

*-- Is SRC a directory? Asked ONCE, here, because three later
*-- decisions turn on it and each would otherwise re-stat.
            jsr   SRCISDIR

*-- `mv FILE/ anything` -- a trailing slash is POSIX's assertion
*-- that the operand IS a directory, so a plain file must be
*-- refused rather than quietly moved.
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
            jmp   REFUSED

*-- RESOLVE A DIRECTORY DESTINATION -- `mv SRC DIR` moves SRC
*-- INTO DIR, and `mv SRC DIR/` demands DIR be a directory.
*-- See DSTRESOLV's own header for the semantics and for why
*-- this is a fix rather than a divergence.
:srcok      jsr   DSTRESOLV
            bcc   :dstready
            jmp   :failed
:dstready
            lda   IFLAG
            beq   :confirmed
            jsr   :mvprompt
            bcc   :ok
:confirmed

            jsr   SAMEDIR
            bcc   :notsame              ;different directory
            jsr   TRYRENAME
            bcc   :ok                   ;renamed -- done
*-- RENAME refused (or the paths only looked equal). A directory
*-- SRC now takes the recursive road rather than being refused;
*-- everything else falls back to the single-file copy.
:notsame    lda   SRCISDIRF
            beq   :docopy
            jsr   MOVEDIR
            bcs   :dirfail
            bra   :ok
:docopy     jsr   COPYFILE
            bcs   :copyfail
            jsr   UNLINKSRC
            bcc   :ok
:copyfail   jmp   :failed
:ok         clc
            rts

*-- MVPROMPT -- carry clear means decline, set means proceed.
*-- A missing destination needs no question and proceeds.
:mvprompt   lda   #<DSTBUF
            sta   PTR0
            lda   #>DSTBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :mvpyes
            lda   #<PROMPTMSG
            sta   PTR0
            lda   #>PROMPTMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            ldx   #FD_STDIN
            jsr   GETC
            bcc   :mvpgot
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            bra   :mvpno
:mvpgot     pha
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            pla
            and   #$DF
            cmp   #$D9
            beq   :mvpyes
:mvpno      clc
            rts
:mvpyes     sec
            rts

*-- The recursive move's own failure exits. CPT_ERR carries
*-- either a real MLI errno -- always < $80 -- or one of
*-- cptree's two maux-side refusals, which take values no MLI
*-- call can return precisely so the two need no second flag.
:dirfail    lda   PRINTED               ;a policy refusal below
            bne   :fdone                ;already said its piece
            lda   CPT_ERR
            cmp   #CPTE_LONG
            beq   :dirlong
            cmp   #CPTE_DEEP
            beq   :dirdeep
            sta   LASTERR
            bra   :failed
:dirlong    lda   #<TOOLONG
            sta   PTR0
            lda   #>TOOLONG
            sta   PTR0+1
            bra   :dirmsg
:dirdeep    lda   #<DEEPMSG
            sta   PTR0
            lda   #>DEEPMSG
            sta   PTR0+1
:dirmsg     ldx   #FD_STDERR
            jsr   PUTS
            bra   :fdone
:failed     lda   PRINTED
            bne   :fdone
            lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<SRCBUF
            sta   PTR0
            lda   #>SRCBUF
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            ;-- raw MLI errno, LASTERR
            lda   #<ERRNOMSG
            sta   PTR0
            lda   #>ERRNOMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   LASTERR
            ldx   #FD_STDERR
            jsr   PRHEX8
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
:fdone      sec
            rts

*---------------------------------------------------------------
* REFUSED -- a refusal that has ALREADY printed its message:
* mark it so MOVEONE's tail does not print a second one, and
* fail the pair. jmp'd to, never fallen into.
*---------------------------------------------------------------
REFUSED     lda   #1
            sta   PRINTED
            sec
            rts

*---------------------------------------------------------------
* CPYARG -- STRCPY PTR0 into PTR1 (SRCBUF/DSTBUF, ARGBUFSZ bytes
* each), but REFUSE if it will not fit -- STRCPY has no such
* bound; only the caller knows the destination's size. Before
* 2026-08-22 mv called STRCPY raw and a long argv[1]/argv[2]
* silently spilled past its buffer, so mv could open/copy/UNLINK
* a path the user never typed.
*
* X must be tested before A is trusted: a 336-byte argument has
* a low byte of 80 and would sail through `cmp #ARGBUFSZ` on A
* alone (learning:01M07V2D0T25FYD6ASCMPJYNWQ). Unreachable
* through sh (LINEMAX 127), but the kernel's ARG_MAX is 1280
* with NO per-argument cap (inc/mm.procbnk2.equ) --
* 127 is sh's own policy, not a property of argv, and a direct
* SC_SPAWN caller is not bound by it.
*---------------------------------------------------------------
CPYARG      jsr   STRLEN
            cpx   #0             ;16-bit length: a high byte
            bne   :toolong       ;is far past ARGBUFSZ
            cmp   #ARGBUFSZ      ;len <= ARGBUFSZ-1, so the
            bcs   :toolong       ;terminator lands inside too
            jsr   STRCPY
            clc
            rts
:toolong    lda   #<TOOLONG
            sta   PTR0
            lda   #>TOOLONG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jmp   REFUSED        ;prints once; the pair fails
                                 ;and the loop moves on (the
                                 ;old exit-2 died with the
                                 ;single-shot shape)

*---------------------------------------------------------------
* SAMEDIR -- carry SET if SRCBUF and DSTBUF name files in the
* same directory, i.e. they agree up to and including the last
* "/" and both contain one.
*---------------------------------------------------------------
SAMEDIR     lda   #<SRCBUF
            sta   PTR0
            lda   #>SRCBUF
            sta   PTR0+1
            jsr   LASTSLASH
            sta   SRCDIR
            lda   #<DSTBUF
            sta   PTR0
            lda   #>DSTBUF
            sta   PTR0+1
            jsr   LASTSLASH
            sta   DSTDIR
            lda   SRCDIR
            beq   :no                   ;no "/" at all
            cmp   DSTDIR
            bne   :no                   ;different prefix length
            tay
:cmp        dey
            bmi   :yes
            lda   SRCBUF,y
            cmp   DSTBUF,y
            beq   :cmp
:no         clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* LASTSLASH -- A = index just PAST the last "/" in the string at
* PTR0, or 0 if there is none.
*---------------------------------------------------------------
LASTSLASH   ldy   #0
            sty   LSPOS
:loop       lda   (PTR0),y
            beq   :done
            cmp   #"/"
            bne   :next
            iny
            sty   LSPOS
            dey
:next       iny
            bne   :loop
:done       lda   LSPOS
            rts

*---------------------------------------------------------------
* DSTRESOLV -- resolve a DIRECTORY destination, Unix semantics.
* This is the "mv SRC DIR moves SRC INTO DIR" form.
*
*   DST exists and IS a directory  -> DST := DST/basename(SRC)
*   DST ends "/" and IS a directory -> same
*   DST ends "/" and is absent   -> carry SET, LASTERR=errno
*   DST ends "/" and is a FILE      -> refuse, exit 1 (ENOTDIR)
*   anything else               -> DSTBUF untouched, clc
*
* Works on DSTBUF -- the liba-string copy of argv[2] -- NOT on a
* built MLI path, because SAMEDIR, TRYRENAME and COPYFILE each
* MKPATH DSTBUF again for themselves; anything written past
* MKPATH would be discarded by the next one.
*
* WHY THIS EXISTS. This file's header used to claim "no
* directory destination form (DST is a full pathname, not a
* directory to move into)", and mv REFUSED an existing-directory
* DST at COPYFILE's :dupdir. That is avoidable semantic drift:
* every Unix moves SRC into DIR, the operation is expressible
* with the primitives ProDOS gives us, and a shell script that
* means one thing on the host and another here is the whole
* thing maux is not. An UNAVOIDABLE divergence is a platform
* limit (see ARGBUFSZ below, and the MLI's 64-byte pathname
* cap); this was never one.
*
* The trailing-slash rule is the same rule, not a second one:
* POSIX says a trailing slash asserts DST already IS a
* directory, so "DIR/" with no DIR is an error rather than a
* licence to CREATE a plain file called DIR -- which is exactly
* what ProDOS's own resolution of "DIR/" would otherwise do.
*---------------------------------------------------------------
DSTRESOLV   stz   DSLASHED
            ldy   #0
:scan       lda   DSTBUF,y
            beq   :atend
            iny
            bne   :scan
:atend      cpy   #0
            bne   :havedst
:near       clc                   ;:nofix is a routine away --
            rts                   ;out of a BEQ's reach
:havedst
            sty   DSTLEN
            dey
            beq   :stat           ;DST is "/" alone -- leave it
            lda   DSTBUF,y
            cmp   #"/"
            bne   :stat
            lda   #1
            sta   DSLASHED
            lda   #0
            sta   DSTBUF,y        ;strip it: stat the DIRECTORY
            sty   DSTLEN

*-- Built into PATHBUF, the buffer GFIPARM_PATH already
*-- names, so this stat writes no text at all. mv is declared
*-- TEXT_IMMUTABLE (scripts/check_purity.py) and check-textaudit
*-- measures it: repointing the parmlist here dirtied one
*-- byte of the image on EVERY run, and since mv's entry head
*-- stays intact the kernel RETAINS the bank, the next mv of
*-- the session would start on mutated text. That is the exact
*-- hazard the GFIPARM_PATH warm-bank defect above WAS
*-- (learning:01M0T103ZQSAEGQ5D8FS8XZ8V4); not writing the cell
*-- beats writing it carefully. PATHBUF is free to clobber:
*-- SAMEDIR, TRYRENAME, COPYFILE and UNLINKSRC each MKPATH it
*-- again for themselves.
:stat       lda   #<DSTBUF
            sta   PTR0
            lda   #>DSTBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :statok
*-- DST does not exist. With a trailing slash that is fatal --
*-- there is no directory to move into. Without one it is the
*-- ordinary "new name" case and CREATE will make it.
            ldx   DSLASHED
            beq   :near
            sta   LASTERR
            sec
            rts

:statok     lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #$0F              ;volume dir, no house
            beq   :isdir            ;constant (ls.s/file.s)
*-- DST exists and is a plain file: replace it, the documented
*-- behaviour. Unless a trailing slash promised a directory.
            ldx   DSLASHED
            beq   :near
            lda   #<NOTDIRMSG
            sta   PTR0
            lda   #>NOTDIRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            jmp   REFUSED

*-- Append "/" + basename(SRC). ARGBUFSZ bounds both buffers, so
*-- a name that would not fit is the same pathname-too-long
*-- refusal CPYARG already makes -- a real platform limit, and
*-- reported as one rather than silently truncated.
*-- LASTSLASH does `ldy #0` and walks Y, so it is called BEFORE
*-- Y becomes the append offset -- not after. Getting that
*-- backwards wrote the basename over the destination's own last
*-- characters ("/mnt/MAUX/T/DIR"+"A" became "/mnt/MAUX/T/DA"),
*-- and
*-- it did so SILENTLY: mv still exited 0 and still printed
*-- nothing, so only the post-state tree showed it.
:isdir      lda   #<SRCBUF
            sta   PTR0
            lda   #>SRCBUF
            sta   PTR0+1
            jsr   LASTSLASH        ;A = index just past last "/"
            tax
            ldy   DSTLEN
            cpy   #ARGBUFSZ-2
            bcs   :toolong
            lda   #"/"
            sta   DSTBUF,y
            iny
:copy       cpy   #ARGBUFSZ-1
            bcs   :toolong
            lda   SRCBUF,x
            sta   DSTBUF,y
            beq   :nofix           ;terminator copied too
            inx
            iny
            bne   :copy
:toolong    lda   #<TOOLONG
            sta   PTR0
            lda   #>TOOLONG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            jmp   REFUSED

:nofix      clc
            rts

*---------------------------------------------------------------
* TRYRENAME -- MLI RENAME. Carry clear on success.
*---------------------------------------------------------------
TRYRENAME   lda   #<SRCBUF
            sta   PTR0
            lda   #>SRCBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<DSTBUF
            sta   PTR0
            lda   #>DSTBUF
            sta   PTR0+1
            lda   #<PATHBUF2
            sta   PTR1
            lda   #>PATHBUF2
            sta   PTR1+1
            jsr   MKPATH
            lda   #<RNPARM
            ldx   #>RNPARM
            jsr   SC_RENAME
            rts

*---------------------------------------------------------------
* COPYFILE -- open SRC, stat SRC (file_type/aux_type, and reject
* a directory -- T4 DEFECT 1), create+open DST (destroying and
* retrying once if DST already exists AND is not itself a
* directory -- T4 DEFECT 2), copy, close both. Carry set on any
* failure -- a real SC_READ error included (see file header
* REGRESSION note), not just EOF.
*---------------------------------------------------------------
COPYFILE    lda   #<SRCBUF
            sta   PTR0
            lda   #>SRCBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :srcok         ;long-range jmp -- COPYFILE
            sta   LASTERR        ;grew past plain BCS's reach;
            jmp   :fail          ;errno for :failed's message
:srcok      lda   OPARM_REF
            sta   SRCFD

            ;-- stat SRC (SC_GFI) so DST's CREATE can carry
            ;-- SRC's real file_type/aux_type instead of a
            ;-- hardcoded BIN -- cp.s:118-131 is the model.
            ;-- NOTHING repoints GFIPARM_PATH any more, so its
            ;-- `da PATHBUF` initializer is valid on every run
            ;-- including a warm one, and no explicit set is
            ;-- needed here. It USED to be: the DST branch below
            ;-- overwrote it with PATHBUF2 and never put it
            ;-- back, and under LAZY FREE the next mv of the
            ;-- session inherits that bank unloaded -- so it
            ;-- stat'd DST where it meant SRC and the dir-SRC
            ;-- guard below silently never fired. Measured
            ;-- 2026-08-24, scripts/probe_mvdir.py; deposited as
            ;-- learning:01M0T103ZQSAEGQ5D8FS8XZ8V4. The cure is
            ;-- structural now rather than disciplined: every
            ;-- stat in this file goes through PATHBUF.
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :gfiok
            jmp   :closesrc
:gfiok      lda   GFIPARM_STYP     ;T4 DEFECT 1: reject dir SRC
            cmp   #STYP_DIR
            beq   :srcisdir
            cmp   #$0F              ;volume-dir storage_type,
            bne   :nodir            ;no house constant (cp.s)
:srcisdir   lda   #<DIRMSG
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
            lda   #0                ;LASTERR is moot -- PRINTED
            jmp   :closesrc         ;gags the errno line; the
                                    ;open SRC fd still closes
                                    ;(the old EXIT leaked it to
                                    ;process teardown)
:nodir      lda   GFIPARM_FTYP
            sta   CRPARM_FTYP
            lda   GFIPARM_AUX
            sta   CRPARM_AUX
            lda   GFIPARM_AUX+1
            sta   CRPARM_AUX+1

            lda   #<DSTBUF
            sta   PTR0
            lda   #>DSTBUF
            sta   PTR0+1
            lda   #<PATHBUF2
            sta   PTR1
            lda   #>PATHBUF2
            sta   PTR1+1
            jsr   MKPATH
            lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT
            bcc   :creatok
            cmp   #ERR_DUPFN        ;T4 DEFECT 2: destroy only
            bne   :cfail            ;on $47 -- else fatal
            ;-- DST exists. DESTROY also empties an EMPTY
            ;-- subdirectory (P8 TRM 4.4.2) -- stat DST first
            ;-- and refuse rather than replace a directory with
            ;-- a file. Reuses GFIPARM: SRC's own stat is
            ;-- already consumed into CRPARM above.
            lda   #<DSTBUF
            sta   PTR0
            lda   #>DSTBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH          ;into PATHBUF: no text write,
                                  ;and UNLINKSRC rebuilds it
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :cfail
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :dupdir
            cmp   #$0F
            bne   :notdir
:dupdir     lda   #ERR_DUPFN        ;refuse: DST is a directory
            jmp   :closesrc
:notdir     lda   #<D2PARM
            ldx   #>D2PARM
            jsr   SC_UNLINK
            bcc   :retry
:cfail      jmp   :closesrc
:retry      lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT
            bcc   :creatok
            jmp   :closesrc
:creatok    lda   #<O2PARM
            ldx   #>O2PARM
            jsr   SC_OPEN
            bcc   :dstok
            jmp   :closesrc
:dstok      lda   O2PARM_REF
            sta   DSTFD

:loop       lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcc   :rok
            ;-- carry-SET = a real error, not EOF -- see file
            ;-- header REGRESSION note. Was `bcs :done`.
            jmp   :wfail
:rok        lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :done
            lda   DSTFD
            sta   WPARM_REF
            lda   RPARM_TRANS
            sta   WPARM_REQ
            lda   RPARM_TRANS+1
            sta   WPARM_REQ+1
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcs   :wfail
            bra   :loop

:done       jsr   CLOSEBOTH
            clc
            rts
:wfail      sta   LASTERR        ;READ/WRITE errno, before
                                 ;CLOSEBOTH's own A overwrites
            jsr   CLOSEBOTH
            sec
            rts
:closesrc   sta   LASTERR        ;errno before SC_CLOSE clobbers
            ldx   SRCFD
            stx   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:fail       sec
            rts
