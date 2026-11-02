*---------------------------------------------------------------
* mvcopy.s -- mv's copy-tail half,
* extracted from mv.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2 mains). One
* assembly stream: put exactly where the text sat; every rule
* in the manifest header applies unchanged.
*---------------------------------------------------------------
CLOSEBOTH   ldx   SRCFD
            stx   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            ldx   DSTFD
            stx   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            rts

*---------------------------------------------------------------
* UNLINKSRC -- remove SRC after a clean copy.
*---------------------------------------------------------------
UNLINKSRC   lda   #<SRCBUF
            sta   PTR0
            lda   #>SRCBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<DPARM
            ldx   #>DPARM
            jsr   SC_UNLINK
            sta   LASTERR        ;errno for :failed's message
            rts

*---------------------------------------------------------------
* SRCSLASH -- strip SRC's own trailing "/", recording that it
* was there in SSLASHED.
*
* WHY IT EXISTS, AND WHY IT ARRIVED WITH THE RECURSIVE MOVE.
* DSTRESOLV takes basename(SRC) via LASTSLASH, which returns the
* index just PAST the last "/" -- so for "/T/DIR1/" that index
* is the terminator and the basename is EMPTY. `mv /T/DIR1/
* /T/DIR2` then appends nothing and DST stays "/T/DIR2", turning
* a move-INTO into a move-ONTO. That was harmless only while a
* directory SRC was refused outright; the moment mv can actually
* move one, the same line silently builds the wrong tree, exits
* 0 and prints nothing. Measured on the host: `mv DIR1/ DIR2`
* with DIR2 present gives DIR2/DIR1, exactly as `mv DIR1 DIR2`
* does -- a trailing slash on SRC changes nothing but the
* assertion that SRC is a directory, which START checks.
*---------------------------------------------------------------
SRCSLASH    stz   SSLASHED
            ldy   #0
:scan       lda   SRCBUF,y
            beq   :atend
            iny
            bne   :scan
:atend      cpy   #0
            beq   :done
            dey
            beq   :done                ;"/" alone -- leave it
            lda   SRCBUF,y
            cmp   #"/"
            bne   :done
            lda   #1
            sta   SSLASHED
            lda   #0
            sta   SRCBUF,y
:done       rts

*---------------------------------------------------------------
* SRCISDIR -- SRCISDIRF := 1 if SRC names a directory, else 0.
*
* Asked ONCE, up front, because three later decisions turn on it
* (the trailing-slash assertion, the RENAME-vs-recurse choice,
* and COPYFILE's own guard). A stat FAILURE leaves it 0 on
* purpose: a missing SRC is not this routine's error to report,
* and falling through to COPYFILE reproduces mv's existing
* "cannot move <src> errno=$46" exactly.
*
* Builds into PATHBUF, the buffer GFIPARM_PATH already names, so
* it writes no program text -- mv is TEXT_IMMUTABLE and the
* kernel retains its bank (learning:01M0T103ZQSAEGQ5D8FS8XZ8V4).
* Every stat in this file goes through PATHBUF for that reason.
*---------------------------------------------------------------
SRCISDIR    stz   SRCISDIRF
            lda   #<SRCBUF
            sta   PTR0
            lda   #>SRCBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :done
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :yes
            cmp   #$0F                 ;volume dir, no house
            bne   :done                ;constant (ls.s/file.s)
:yes        lda   #1
            sta   SRCISDIRF
:done       rts

*---------------------------------------------------------------
* DSTEMPTY -- carry CLEAR if the directory whose MLI path is
* already in PATHBUF holds no entries. One OPENDIR, one READDIR,
* one CLOSEDIR.
*
* A read error counts as NOT empty: the safe answer is the one
* that refuses, because the caller is deciding whether it may
* move a tree on top of this directory.
*---------------------------------------------------------------
DSTEMPTY    lda   #<PATHBUF
            ldx   #>PATHBUF
            jsr   OPENDIR
            bcs   :notempty
            lda   #<CPT_REC
            ldx   #>CPT_REC
            jsr   READDIR
*-- CLOSEDIR runs SC_CLOSE, which returns its own carry and A.
*-- Preserve READDIR's verdict across it.
            php
            pha
            jsr   CLOSEDIR
            pla
            plp
            bcc   :notempty            ;an entry -- not empty
            cmp   #0
            bne   :notempty            ;a READ error
            clc
            rts
:notempty   sec
            rts

*---------------------------------------------------------------
* CPYSRC / CPYPATHS -- hand cptree its own copies of the paths.
* SRCBUF/DSTBUF must survive untouched for the error printer,
* and the walk appends to and truncates its own two constantly.
*---------------------------------------------------------------
CPYSRC      lda   #<SRCBUF
            sta   PTR0
            lda   #>SRCBUF
            sta   PTR0+1
            lda   #<CPT_SRC
            sta   PTR1
            lda   #>CPT_SRC
            sta   PTR1+1
            jsr   STRCPY
            sta   CPT_SLEN
            rts

CPYPATHS    jsr   CPYSRC
            lda   #<DSTBUF
            sta   PTR0
            lda   #>DSTBUF
            sta   PTR0+1
            lda   #<CPT_DST
            sta   PTR1
            lda   #>CPT_DST
            sta   PTR1+1
            jsr   STRCPY
            sta   CPT_DLEN
            rts

*---------------------------------------------------------------
* MOVEDIR -- move a DIRECTORY across parents: mirror the tree
* under DST, then remove SRC bottom-up. Carry set on failure,
* with cptree's reason in CPT_ERR; the refusals below print for
* themselves and exit, because none of them is an errno.
*
* MLI RENAME cannot relink across directories at all (P8 TRM),
* which is why this costs a full recursive copy. DESTROY refuses
* a NON-EMPTY subdirectory ($4E, learning:01M0T0YSPMJE238VH46-
* CZPDR2V), which is why the teardown is deepest-child-first.
* Both are cptree's problem; this routine is the policy.
*
* THE POLICY, which is the host's and not invented:
*   DST is SRC or lies beneath it -> refuse (moving a directory
*     into itself; the host calls it "Invalid argument")
*   DST absent                    -> create it, mirror into it
*   DST exists, is a plain file   -> refuse ("Not a directory")
*   DST exists, is an EMPTY dir   -> mirror into it (the host
*     renames over an empty directory quite happily)
*   DST exists, is a NON-EMPTY dir-> refuse ("Directory not
*     empty"). `cp -r` MERGES here instead; that is a real
*     difference between the two tools, not drift.
* All five measured against /bin/mv on 2026-08-25.
*---------------------------------------------------------------
MOVEDIR     lda   #<SRCBUF
            sta   PTR0
            lda   #>SRCBUF
            sta   PTR0+1
            lda   #<DSTBUF
            sta   PTR1
            lda   #>DSTBUF
            sta   PTR1+1
            jsr   CPT_ISDESC
            bcc   :statdst
            lda   #<SELFMSG
            sta   PTR0
            lda   #>SELFMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jmp   REFUSED

:statdst    lda   #<DSTBUF
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
            bcs   :setup              ;absent -- CPT_MKDIR
                                       ;it, and reports if it
                                       ;cannot
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :dstdir
            cmp   #$0F
            beq   :dstdir
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

:dstdir     jsr   DSTEMPTY             ;PATHBUF still holds DST
            bcc   :setup
            lda   #<NOTEMPTMSG
            sta   PTR0
            lda   #>NOTEMPTMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jmp   REFUSED

*-- CPT_MKDIR treats a duplicate name that IS a directory as
*-- success, which is exactly the empty-DST case above; a
*-- duplicate that is a FILE it reports, and cannot be reached
*-- here because the stat just refused one.
:setup      jsr   CPYPATHS
            jsr   CPT_INIT
            jsr   CPT_MKDIR
            bcs   :fail
            jsr   CPT_START
            bcs   :fail
*-- The copy is complete before ANY source byte is destroyed --
*-- mv.s's own non-atomicity guarantee, at directory
*-- granularity. CPT_SRC comes back to the root on a clean walk,
*-- but it is REBUILT rather than trusted: a teardown pointed at
*-- the wrong path is not a recoverable mistake.
            jsr   CPYSRC
            jsr   CPT_RMTREE
            bcs   :fail
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* INITPARMS -- store every CONSTANT field of mv's ten MLI
* parmlists. START's first instruction calls it.
*
* WHY THE PARMLISTS ARE CELLS AND NOT EMITTED DATA, which is the
* whole point of this routine. `mv` is declared TEXT_IMMUTABLE
* (scripts/check_purity.py sec 29) and its entry head stays
* intact, so the kernel RETAINS its bank and the next `mv` of
* the session starts on whatever the last one wrote. An MLI
* parmlist is assembled data the kernel writes RESULTS back into
* -- ref_num, trans_count, and GET_FILE_INFO's whole 15-byte
* result block (check_purity's write shape D; src/kernel/
* procspawn.s PCPO_MLIPARM does the copyout). While these lists
* were emitted, every one of those results landed in mv's IMAGE.
*
* THE DECLARATION WAS TRUE ONLY BY ACCIDENT OF WORKLOAD.
* check-textaudit's `mv` pair is a SAME-DIRECTORY rename, which
* reaches MLI RENAME and nothing else -- and RENAME is the one
* call here with no result field. COPYFILE's OPEN/CREATE/READ/
* WRITE/CLOSE/GET_FILE_INFO were never executed by the audit, so
* mv measured clean while carrying the same writable text `cp`
* is declared TEXT_MUTABLE for. Adding SRCISDIR, which stats SRC
* on EVERY invocation including the rename, made it visible
* immediately: 12 of 4,406 image bytes, both runs, entry head
* intact. That is the gate doing its job, and the answer is not
* to stop stat'ing -- it is to stop writing text.
*
* So mv now is what it says it is, on EVERY path rather than on
* the one the audit happened to walk. It also retires this
* file's oldest trap for free: the GFIPARM_PATH warm-bank defect
* (learning:01M0T103ZQSAEGQ5D8FS8XZ8V4) could only bite because
* a repointed POINTER survived into the next run. A cell that is
* rewritten here on every entry cannot. The discipline of
* routing every stat through PATHBUF stays anyway -- belt and
* braces on a mistake that has been made twice.
*
* An MLI parmlist must be CONTIGUOUS (learning:01M0M9R7RT22JEPP-
* 2R0Y6J9MBX), so a list's constant bytes cannot be left behind
* in text once the rest of it moves to the arena -- all or
* nothing, per list. readdir.s's RD_INITPARM and cat.s's
* INITPARMS are the precedents. CLOBBERS: A.
*---------------------------------------------------------------
INITPARMS   lda   #PCNT_RENAME
            sta   RNPARM
            lda   #<PATHBUF
            sta   RNPARM_PATH
            sta   OPARM_PATH
            sta   GFIPARM_PATH
            sta   DPARM_PATH
            lda   #>PATHBUF
            sta   RNPARM_PATH+1
            sta   OPARM_PATH+1
            sta   GFIPARM_PATH+1
            sta   DPARM_PATH+1
            lda   #<PATHBUF2
            sta   RNPARM_NEW
            sta   O2PARM_PATH
            sta   CRPARM_PATH
            sta   D2PARM_PATH
            lda   #>PATHBUF2
            sta   RNPARM_NEW+1
            sta   O2PARM_PATH+1
            sta   CRPARM_PATH+1
            sta   D2PARM_PATH+1
            lda   #PCOUNT_OPEN
            sta   OPARM
            sta   O2PARM
*-- io_buffer is a documented DON'T-CARE: the kernel repoints it
*-- at its own allocated buffer before issuing the real MLI call
*-- (src/kernel/procfile3.s PRC_OPEN) and never copies the field
*-- back. Stored anyway -- an uncleared cell handed to a syscall
*-- is a cell nobody wrote, and "the kernel ignores it" is a
*-- fact about today's kernel, not a property of the ABI.
            stz   OPARM_IOBUF
            stz   OPARM_IOBUF+1
            stz   O2PARM_IOBF
            stz   O2PARM_IOBF+1
            lda   #PCOUNT_CREATE
            sta   CRPARM
            lda   #ACCESS_UNLKD
            sta   CRPARM_ACC
            lda   #FTYPE_BIN         ;pre-patch default only --
            sta   CRPARM_FTYP        ;COPYFILE overwrites both
            stz   CRPARM_AUX         ;from SRC's own stat before
            stz   CRPARM_AUX+1       ;CREATE ever runs
            lda   #STYP_SEEDLING
            sta   CRPARM_STYP
*-- dates stay zero: no clock is wired and SET_FILE_INFO is not
*-- exposed (docs/USERLAND.md "ABI RESOLUTIONS", task #11).
            stz   CRPARM_DATE
            stz   CRPARM_DATE+1
            stz   CRPARM_TIME
            stz   CRPARM_TIME+1
            lda   #PCOUNT_GFI
            sta   GFIPARM
            lda   #PCNT_DESTROY
            sta   D2PARM
            sta   DPARM
            lda   #PCOUNT_READ
            sta   RPARM
            lda   #PCOUNT_WRITE
            sta   WPARM
            lda   #<CBUF
            sta   RPARM_BUF
            sta   WPARM_BUF
            lda   #>CBUF
            sta   RPARM_BUF+1
            sta   WPARM_BUF+1
            lda   #<BUFSZ
            sta   RPARM_REQ
            lda   #>BUFSZ
            sta   RPARM_REQ+1
            lda   #PCOUNT_CLOSE
            sta   CPARM
            rts

USAGE       asc   "usage: mv [-fi] SRC... DST"
            dfb   $8D,$00
ERRMSG      asc   "mv: cannot move "
            dfb   $00
ERRNOMSG    asc   " errno=$"
            dfb   $00
NOTDIRMSG   asc   "mv: DST is not a directory"
            dfb   $00
TOOLONG     asc   "mv: pathname too long"
            dfb   $8D,$00
DIRMSG      asc   "mv: SRC is a directory"
            dfb   $00
SNOTDIRMSG  asc   "mv: SRC is not a directory"
            dfb   $00
NOTEMPTMSG  asc   "mv: DST is not empty"
            dfb   $8D,$00
SELFMSG     asc   "mv: cannot move a directory into itself"
            dfb   $8D,$00
DEEPMSG     asc   "mv: directory tree too deep"
            dfb   $8D,$00
