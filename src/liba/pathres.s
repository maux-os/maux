*---------------------------------------------------------------
* pathres.s -- resolve a bare command word against PATH. This is
* the `p` in execvp.
*
* maux's SC_SPAWN is the execve shape: it takes a path and does
* not search. `sh` has always had a search of its own
* (BUILD_PATH), but it lives in the shell and reads the shell's
* OWN variable table, so nothing else could use it -- and
* src/bin/find.s's `-exec` therefore required an absolute
* pathname where a real find(1), which reaches exec through
* execvp, does not. That divergence is what this module closes.
*
* WHY IT DOES NOT SHARE sh's ROUTINE, and this is a real
* difference rather than duplication: `sh` must honour a PATH
* that was assigned and NOT exported, because an unexported
* variable still affects the shell itself. Every OTHER program
* is a child, and a child's only legitimate source is the
* ENVIRONMENT -- Bourne's rule, and the reason this reads
* GETENV. A program that consulted its parent's unexported
* variables would be reaching into a scope it cannot see.
*
* It shares the DEFAULT, which is policy: src/liba/pathtab.s.
*
* THE ENVIRONMENT SIDE ONLY STARTED WORKING ON 2026-08-25, when
* `sh` learned to IMPORT the environment it had always been able
* to export (docs/SHELL-GAPS.md). Before that a child's GETENV
* could never see a PATH the user had set, because no shell ever
* put one there -- so this module could not have worked, however
* it was written.
*---------------------------------------------------------------

* -- The literal 65 in libabss.s's PRS_BUF cannot be written as
* -- MLI_PTH_MAXLN+1: libabss.s is linked by every program in
* -- the tree, including harnesses that never `put` mli.equ, and
* -- a constant they cannot see fails to assemble for all of
* -- them (this exact mistake, with EPASS_MAX, cost a build on
* -- 2026-08-25). So the size is a literal THERE and checked
* -- HERE, where mli.equ is always in scope. Non-zero = error.
            err   PRS_BUFSZ-MLI_PTH_MAXLN-1

*---------------------------------------------------------------
* PATHRSLV -- IN: PTR0 = a NUL-terminated command word (liba
* text). OUT: carry CLEAR and PTR0 points at a path that OPENed
* successfully -- UNCHANGED when the word was already absolute,
* otherwise PRS_BUF. Carry SET = not found on any entry, and
* PTR0 is left alone.
*
* IT REPORTS NOT-FOUND AND RESTORES THE CALLER'S WORD. sh's
* BUILD_PATH also returns carry SET, but LEAVES the bare word in
* SH_PATHFULL so the caller's diagnostic can name what was
* typed. That is a fine design and this one simply does not need
* it -- find already has the word.
*
* CORRECTION 2026-08-26: an earlier version of this note said
* BUILD_PATH's `:exhausted` branch SPAWNS the word. It does not;
* both of its CALLERS ignored the carry it returns, which is a
* different bug in a different place and is now fixed in
* src/bin/sh.s. What that produced was an accidental
* current-directory search -- ProDOS resolves a path with no
* leading '/' against the prefix -- and it is how an
* unresolvable `ECHO` reached the kernel as a path starting with
* 'E' (docs/SPAWN-BANK7-CRASH.md).
*
* CLOBBERS: A, X, Y, PTR1, PTR2 (MKPATH's).
*---------------------------------------------------------------
PATHRSLV    ldy   #0
            lda   (PTR0),y
            cmp   #$AF                   ;'/' -- an absolute
            bne   :search                ;word needs no
            clc                          ;resolving
            rts

:search     lda   PTR0                   ;the word outlives
            sta   PRS_WORD               ;every buffer below
            lda   PTR0+1
            sta   PRS_WORD+1

*-- "PATH" IS BUILT, NOT EMITTED, and the default is COPIED
*-- rather than pointed at. check_purity's shape (B) flags any
*-- `lda #<SYM` / `sta PTRn` where that pointer is ever an
*-- indirect STORE destination in the program -- and MKPATH
*-- stores through PTR1. The symbols are read-only and the
*-- analysis is conservative on purpose, but EVERY liba module
*-- in this tree carries an EMPTY debt set and each one says it
*-- was written under the rule rather than re-baselined into
*-- it. So: no emitted text here either. A dum-block label is
*-- not text_data, so neither cell trips the shape.
            lda   #$D0                   ;"PATH", high-bit
            sta   PRS_NM
            lda   #$C1
            sta   PRS_NM+1
            lda   #$D4
            sta   PRS_NM+2
            lda   #$C8
            sta   PRS_NM+3
            stz   PRS_NM+4
            lda   #<PRS_NM
            sta   PTR0
            lda   #>PRS_NM
            sta   PTR0+1
            jsr   GETENV                 ;PTR1 = value on a hit
            bcc   :havesrc
*-- No PATH in the environment: copy the built-in default into
*-- the arena and parse THAT, so the one loop below serves both
*-- sources. Absolute-indexed, never through a pointer --
*-- PATHTAB is under 256 bytes and Y reaches all of it.
            ldy   #0
:cpdef      lda   PATHTAB,y
            sta   PTB_SRCBUF,y
            beq   :defdone
            iny
            cpy   #PTB_SRCSZ-1
            bne   :cpdef
            lda   #0
            sta   PTB_SRCBUF,y
:defdone    lda   #<PTB_SRCBUF
            sta   PTR1
            lda   #>PTB_SRCBUF
            sta   PTR1+1
*-- BOTH POINTERS LIVE IN THE ARENA AND ARE RELOADED INTO ZERO
*-- PAGE PER ITERATION, for two separate reasons the compiler
*-- found one of and reading found the other. (1) `(PRS_WORD),y`
*-- does not assemble: indirect-indexed needs a DIRECT PAGE
*-- pointer and the arena is not one. (2) PRS_EXISTS below sets
*-- PTR1 to its own MLI buffer, so the PATH source pointer does
*-- NOT survive the first probe -- every entry after the first
*-- would have walked whatever MKPATH left behind.
:havesrc    lda   PTR1
            sta   PRS_SRC
            lda   PTR1+1
            sta   PRS_SRC+1
            stz   PRS_SI

*-- One candidate per entry. X is the write cursor into PRS_BUF
*-- and PRS_SI the read cursor into the source, which is why
*-- neither is Y: Y is spent on the (PTR1),y read itself.
:entry      lda   PRS_SRC                ;PTR1 is not ours to
            sta   PTR1                   ;keep -- see :havesrc
            lda   PRS_SRC+1
            sta   PTR1+1
            ldx   #0
:cpent      ldy   PRS_SI
            lda   (PTR1),y
            beq   :entdone
            cmp   #$BA                   ;':' high-bit
            beq   :entsep
            inc   PRS_SI
            cpx   #PRS_BUFSZ-1
            bcs   :toolong
            sta   PRS_BUF,x
            inx
            bra   :cpent

*-- An entry ending in ':' has more behind it; one ending in NUL
*-- is the last. PRS_MORE carries that across the append and the
*-- probe, both of which need Y.
:entsep     inc   PRS_SI                 ;step over the ':'
            lda   #1
            sta   PRS_MORE
            bra   :append
:entdone    stz   PRS_MORE
:append     cpx   #0
            beq   :nextent               ;empty entry -- Bourne
                                         ;reads that as the cwd;
                                         ;maux has no cwd entry
                                         ;in a search path, so
                                         ;it is skipped
*-- Supply the separating '/' only if the entry did not bring
*-- one. `/mnt/MAUX` and `/mnt/MAUX/` must name the same
*-- directory.
            lda   PRS_BUF-1,x
            cmp   #$AF
            beq   :haveslash
            cpx   #PRS_BUFSZ-1
            bcs   :toolong
            lda   #$AF
            sta   PRS_BUF,x
            inx
:haveslash  lda   PRS_WORD
            sta   PTR2
            lda   PRS_WORD+1
            sta   PTR2+1
            ldy   #0
:cpword     lda   (PTR2),y
            beq   :built
            cpx   #PRS_BUFSZ-1
            bcs   :toolong
            sta   PRS_BUF,x
            inx
            iny
            bne   :cpword
:built      lda   #0
            sta   PRS_BUF,x

            lda   #<PRS_BUF
            sta   PTR0
            lda   #>PRS_BUF
            sta   PTR0+1
            jsr   PRS_EXISTS
            bcs   :nextent
            rts                          ;PTR0 already names it,
                                         ;carry clear from
                                         ;PRS_EXISTS

*-- A candidate longer than a ProDOS pathname is not an error,
*-- it is a MISS: some other entry may still fit. Skip to the
*-- end of this entry so the source cursor stays honest.
:toolong    ldy   PRS_SI
            lda   (PTR1),y
            beq   :tlend
            inc   PRS_SI
            cmp   #$BA
            bne   :toolong
            lda   #1
            sta   PRS_MORE
            bra   :nextent
:tlend      stz   PRS_MORE

*-- `bne` past a `jmp`: :entry is out of an 8-bit branch's
*-- reach from here now that the candidate builder sits between
*-- them.
:nextent    lda   PRS_MORE
            beq   :nomore
            jmp   :entry
:nomore
            lda   PRS_WORD               ;restore the caller's
            sta   PTR0                   ;word before failing
            lda   PRS_WORD+1
            sta   PTR0+1
            sec
            rts

*---------------------------------------------------------------
* PRS_EXISTS -- IN: PTR0 = a candidate path. OUT: carry CLEAR if
* it OPENs (and it is closed again immediately). Same probe
* src/bin/sh.s's PATH_EXISTS uses, and for the same reason: OPEN
* is the only question worth asking, because OPEN is what the
* spawn is about to do. GET_FILE_INFO would answer a DIFFERENT
* question and could say yes to something spawn then fails on.
*---------------------------------------------------------------
*-- THE PARMLISTS ARE ARENA CELLS FILLED HERE, not emitted
*-- `dfb`/`da` data. The MLI writes the refnum BACK into an
*-- OPEN parmlist, so emitted ones are writable text -- and this
*-- is a LIBA module, so every program linking it would inherit
*-- a dirty image and fail its own TEXT_IMMUTABLE audit.
*-- check-modules caught exactly that; src/bin/mv.s paid the
*-- same price for the same reason earlier this week (ten
*-- parmlists, 12 measured dirty bytes). Eight bytes of setup
*-- per probe is nothing beside the OPEN it precedes.
PRS_EXISTS  lda   #<PRS_PATHBUF
            sta   PTR1
            lda   #>PRS_PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            bcs   :nope                  ;over MLI_PTH_MAXLN
            lda   #PCOUNT_OPEN
            sta   PRS_OPARM
            lda   #<PRS_PATHBUF
            sta   PRS_OPARM+1
            lda   #>PRS_PATHBUF
            sta   PRS_OPARM+2
            stz   PRS_OPARM+3            ;io_buf: the kernel
            stz   PRS_OPARM+4            ;picks one
            stz   PRS_OPARM+5            ;refnum, filled by OPEN
            lda   #<PRS_OPARM
            ldx   #>PRS_OPARM
            jsr   SC_OPEN
            bcs   :nope
            lda   #PCOUNT_CLOSE
            sta   PRS_CPARM
            lda   PRS_OPARM+5
            sta   PRS_CPARM+1
            lda   #<PRS_CPARM
            ldx   #>PRS_CPARM
            jsr   SC_CLOSE
            clc
            rts
:nope       sec
            rts

