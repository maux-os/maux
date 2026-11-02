*---------------------------------------------------------------
* shpath.s -- PATH resolution, READLINE, IFS field splitting
* and globbing, `put` by src/bin/sh.s (NOT a standalone binary
* -- the same put-module shape as sedexec.s/expr.eval.s). sh.s
* was 190,960 bytes stripped against real Merlin-8's
* 41,215-byte source buffer, which holds the resident manifest
* plus ONE put file at a time, so the body is split across
* eight modules. Boundaries are banner lines at global labels,
* chosen along the shell's own concerns. Every symbol here
* resolves against sh.s's equates, data and arena -- see that
* file's header for the scope.
*---------------------------------------------------------------
*---------------------------------------------------------------
* EMIT_DUPS -- emit this stage's redirect-list records for ONE
* position (docs/SH-FEATURES.md sec 15, KFIX3 item 1). IN: A = 0
* (the records PARSE saw before this stage's first file
* redirect) or 1 (after it). Walks DUP_* in the order PARSE
* recorded them, which is source order. A record is one of
*
*   `N>&M`   dup the child's M onto N
*   `N>&-`   close N                       (DUP_SRC $FF)
*   FILE     open a later `>`/`N>`/`>>`, or a `N<`, and dup it
*            onto N (DUP_SRC $FE truncate, $FD append, $FC
*            read; DUP_PTR the name; SET_OUT/SET_INN, shparse.s)
*
* Each source fd is resolved through CHILDMAP, so what reaches
* FDABUF is a PARENT fd -- see BLD_FDCTS_STG's own header for
* why the kernel demands that. Both sides of the map are then
* updated, so `2>&1 3>&2` chains correctly.
*
* Duplicating from a fd this same list already CLOSED ($FF) is a
* REFUSAL, not a skip (DUPFD-1): `cat 3>&- 0<&3` must not read
* fd 0 and exit 0. DUP_CHECK (shblt2.s) judges the whole line
* before anything is opened, so this is the backstop for a
* caller that did not run it; it returns carry set and no
* record naming fd $FF reaches the kernel. A source the PARENT
* does not hold open is refused by the kernel (ERR_INVAL,
* PRC_FDA_CHECK) and by DUP_CHECK, which sees the user's fds
* (learning:01M0HEMY6X9SR68V9FJ9Q4VKSG for the kernel half).
*
* A FILE record opens the file NOW (the name lives in LINEBUF)
* and keeps the parent's fd in XOUTFD for CLS_OUTFD to close
* once the stage has spawned -- the kernel resolves a dup's
* source against the PARENT at spawn time, so it cannot be
* closed earlier. OUT: carry SET if an open failed (the stage is
* abandoned; the caller branches to its failure path, which runs
* CLS_OUTFD). CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
EMIT_DUPS   sta   DUPWANT
            stz   DUPI
:loop       lda   DUPI
            cmp   DUPN
            beq   :done
            tax
            lda   DUP_STG,x
            cmp   STAGEI
            bne   :next
            lda   DUP_POS,x
            cmp   DUPWANT
            bne   :next
            lda   DUP_TGT,x
            sta   DUPTGT
            lda   DUP_SRC,x
            cmp   #$FF
            beq   :close
            cmp   #FREC_RD
            bcs   :file                  ;$FC-$FE: a FILE record
            tax                         ;X = the SOURCE child fd
            lda   CHILDMAP,x
            cmp   #$FF
            beq   :badsrc                ;source already closed
            sta   DUPSRC
            ldx   DUPTGT
            lda   DUPSRC
            jsr   EMIT_DUP_A
            ldx   DUPTGT
            lda   DUPSRC
            sta   CHILDMAP,x
            bra   :next
:close      lda   DUPTGT
            jsr   EMIT_CLOSE_A
            ldx   DUPTGT
            lda   #$FF
            sta   CHILDMAP,x
:next       inc   DUPI
            bra   :loop
:done       clc
            rts
:file       pha                          ;the kind
            ldx   DUPI
            lda   DUP_PTRL,x
            sta   PTR0
            lda   DUP_PTRH,x
            sta   PTR0+1
            pla
            cmp   #FREC_AP
            beq   :fapp
            bcs   :ftrunc                ;FREC_WR
            jsr   OPEN_REDIR_RD          ;FREC_RD: `N<`
            bra   :fopen
:ftrunc     jsr   OPEN_REDIR_WR
            bra   :fopen
:fapp       jsr   OPEN_REDIR_AP
:fopen      bcs   :fbad
            ldx   XOUTN
            sta   XOUTFD,x
            inc   XOUTN
            ldx   DUPTGT
            jsr   EMIT_FILEFD
            bra   :next
:fbad       rts                          ;carry is set
:badsrc     txa                          ;X = M, now closed
            jsr   PR_BADFD
            sec
            rts

*---------------------------------------------------------------
* EMIT_FILEFD -- wire a freshly opened file onto a child fd: the
* child's X becomes the PARENT's fd A (a dup), then the child's
* inherited copy of A is closed, and CHILDMAP learns that X now
* names the file so a later `M>&X` copies the FILE, not the tty.
* IN: A = the parent's fd, X = the child's target fd.
*
* The dup is ALWAYS emitted. When the open lands on the very
* number the redirect names (`3>F` with fd 3 free) it is a no-op
* by the kernel's own rule (the child's object is already that
* file), but when an EARLIER record put something else on that
* number (`3>&2 3>F`) it is what installs the file.
*
* The close is skipped in two cases, both because it would shut
* an fd this stage wants open (KFIX3 review B1):
*   - A = X, the number just named: the same fd, now the file;
*   - A is the TARGET of an earlier record (TGTSET): the parent
*     opens every redirect's file on the next free number and
*     keeps it, so `6>A 2>B` opens B on 6 and the dup that put A
*     on 6 would be undone by closing it. The kernel dups from
*     the PARENT's table and closes in the CHILD's, which is why
*     only the close can hit.
* CLOBBERS: A, X, Y, DUPSRC, DUPTGT.
*---------------------------------------------------------------
EMIT_FILEFD stx   DUPTGT
            sta   DUPSRC
            sta   CHILDMAP,x
            jsr   EMIT_DUP_A
            ldx   DUPSRC
            lda   TGT_BIT,x
            and   TGTSET                 ;EMIT_DUP_A has just
            bne   :keep                  ;marked DUPTGT, not A
            lda   DUPSRC
            cmp   DUPTGT
            beq   :keep
            jmp   EMIT_CLOSE_A
:keep       rts

*---------------------------------------------------------------
* RSLV_PTH_STG -- PTR0 = spawn path for STAGEI (file
* header's path resolution ruling). CLOBBERS: A, X, Y, PTR0.
*
* A word CONTAINING a slash is a path, never searched (POSIX;
* KFIX10 item 3): CMDSLASH (liba/cmdpath.s) says so and, for
* `./x` and `../x`, resolves the dots against the cwd with the
* MKPATH that `cat ./x` uses. Only a word with no slash walks
* PATH. SH_TPATHBUF is the scratch: PATH_EXISTS is its only
* other user and it is idle until BUILD_PATH runs.
*---------------------------------------------------------------
RSLV_PTH_STG
            ldx   STAGEI
            lda   STGOFF,x
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            lda   #<SH_TPATHBUF
            sta   PTR1
            lda   #>SH_TPATHBUF
            sta   PTR1+1
            jsr   CMDSLASH
            bcc   :absolute
            jmp   BUILD_PATH
*-- An absolute word IS the resolved path already, but the
*-- spawn site (:spawnloop) reloads PTR0 from SH_PATHFULL
*-- UNCONDITIONALLY once BLD_FDCTS_STG/ENV_STAGE have clobbered
*-- it -- there is no way for THIS routine's return value to
*-- survive those calls in PTR0 itself, so it has to survive in
*-- memory instead. BUILD_PATH's bare-word branch already
*-- writes SH_PATHFULL for exactly that reason; this branch used
*-- to skip it, which is the bug (docs/PLAN.md's "an ABSOLUTE
*-- command word runs the WRONG PROGRAM" entry) -- a stale
*-- SH_PATHFULL from the PREVIOUS stage's bare-word resolution
*-- got spawned instead. Fix: make BOTH branches leave the
*-- resolved path in SH_PATHFULL, so the spawn site's "the path
*-- is still here" comment is finally true unconditionally
*-- rather than true on only one of the two paths that reach it.
*--
*-- Bounded at SH_PTHFLL_LEN-1, the same class of bound
*-- BUILD_PATH's own :cpbare/:cpword use, so a longer-than-legal
*-- argv word truncates rather than overruns SH_PATHFULL and
*-- whatever follows it (mv.s shipped exactly that overrun via
*-- an unbounded STRCPY on 2026-08-22 -- see SH_PTHFLL_LEN's own
*-- comment for why 65 is the right ceiling to bound against).
:absolute   ldy   #0
:cpabs      lda   (PTR0),y
            sta   SH_PATHFULL,y
            beq   :absdone
            iny
            cpy   #SH_PTHFLL_LEN-1
            bne   :cpabs
            lda   #0
            sta   SH_PATHFULL,y
*-- `clc` IS LOAD-BEARING as of 2026-08-26. This branch used to
*-- return whatever carry the last `cpy` in the copy loop left,
*-- which was harmless only while NO caller looked at it. Both
*-- callers look now, and an absolute command word reporting
*-- "not found" at random is exactly the sort of intermittent
*-- this tree should never have to debug.
:absdone    lda   #<SH_PATHFULL
            sta   PTR0
            lda   #>SH_PATHFULL
            sta   PTR0+1
            clc
            rts

*---------------------------------------------------------------
* BUILD_PATH -- resolve a bare command word against PATHTAB.
*
* IN:  PTR0 = word. OUT: PTR0 = SH_PATHFULL, the first candidate
* that exists, or the bare word if none did.
*
* Each candidate is tested by opening it and closing it again.
* The caller must resolve BEFORE staging redirections: that open
* needs an io_buffer, and probing while a redirect was already
* open emptied a three-stage pipeline.
*
* Spawning each candidate and retrying instead does NOT work --
* a failed SC_SPAWN does not leave the staged fd actions
* reusable, so every command on an image without /bin
* failed at the second attempt. Tried, reverted, recorded.
*
* A word that contains a slash never reaches here; RSLV_PTH_STG
* asks CMDSLASH first (a path is not searched).
*
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
*-- Copy the word into a flat buffer first, so every candidate
*-- build below is absolute-indexed. Reading it through a
*-- pointer would need a zero-page pair sh has not got.
*--
*-- An earlier version of this comment claimed merlin32 silently
*-- accepts `lda (LABEL),y` for a LABEL outside zero page. It
*-- does not: it reports "[Bad Address Mode] ... is located
*-- outside of the Direct Page" and exits 1, in 6502, 65C02 and
*-- 65816 modes alike. The mistake was reading a STALE .bin
*-- after filtering the output for "[Error]", which is not the
*-- category it uses. Check the exit code, not the text.
BUILD_PATH  ldy   #0
:cpcmd      lda   (PTR0),y
            sta   SH_CMDWORD,y
            beq   :cmdok
            iny
            cpy   #SH_CMDMAX-1
            bne   :cpcmd
            lda   #0
            sta   SH_CMDWORD,y
:cmdok
*-- Tracked-command lookup FIRST (the cache cells' comment in
*-- sh.s has the design): a hit skips PATH_SRC and the per-
*-- candidate OPEN+CLOSE probe entirely.
            ldx   #0
:hlk        lda   SHH_CLO,x
            sta   PTR1
            lda   SHH_CHI,x
            sta   PTR1+1
            ldy   #0
            lda   (PTR1),y
            beq   :hnext             ;empty slot
:hcmp       lda   (PTR1),y
            cmp   SH_CMDWORD,y
            bne   :hnext
            lda   SH_CMDWORD,y       ;equal -- both NUL?
            beq   :hhit
            iny
            bra   :hcmp
:hnext      inx
            cpx   #SH_HASHN
            bne   :hlk
            bra   :hmiss
:hhit       lda   SHH_PLO,x
            sta   PTR1
            lda   SHH_PHI,x
            sta   PTR1+1
            ldy   #0
:hcpy       lda   (PTR1),y
            sta   SH_PATHFULL,y
            beq   :hgot
            iny
            bra   :hcpy
:hgot       lda   #<SH_PATHFULL
            sta   PTR0
            lda   #>SH_PATHFULL
            sta   PTR0+1
            clc
            rts
:hmiss      jsr   PATH_SRC
            stz   SH_PATHI

:trydir     ldy   SH_PATHI               ;copy this prefix
            ldx   #0
:cpfx       lda   SH_PATHSRC,y
            beq   :pfxdone
            sta   SH_PATHFULL,x
            iny
            inx
            cpx   #SH_PTHFLL_LEN-2
            bne   :cpfx
:pfxdone    iny                          ;step past the NUL
            sty   SH_NEXTI
            cpx   #0
            bne   :notex
            jmp   :exhausted             ;empty prefix = end of
                                         ;table (jmp: the cache
                                         ;lookup pushed it out
                                         ;of branch range)
:notex

            ldy   #0                     ;append the word
:cpword     lda   SH_CMDWORD,y
            sta   SH_PATHFULL,x
            beq   :built
            iny
            inx
            cpx   #SH_PTHFLL_LEN-1
            bne   :cpword
            lda   #0
            sta   SH_PATHFULL,x
:built      lda   #<SH_PATHFULL
            sta   PTR0
            lda   #>SH_PATHFULL
            sta   PTR0+1
            jsr   PATH_EXISTS
            bcc   :found
            lda   SH_NEXTI
            sta   SH_PATHI
            bra   :trydir
:found
*-- Remember the resolution (round-robin). PTR1 is in this
*-- routine's declared clobber set.
            ldx   SH_HNEXT
            lda   SHH_CLO,x
            sta   PTR1
            lda   SHH_CHI,x
            sta   PTR1+1
            ldy   #0
:hscmd      lda   SH_CMDWORD,y
            sta   (PTR1),y
            beq   :hscd
            iny
            bra   :hscmd
:hscd       lda   SHH_PLO,x
            sta   PTR1
            lda   SHH_PHI,x
            sta   PTR1+1
            ldy   #0
:hspth      lda   SH_PATHFULL,y
            sta   (PTR1),y
            beq   :hspd
            iny
            bra   :hspth
:hspd       inx
            cpx   #SH_HASHN
            bne   :hsnw
            ldx   #0
:hsnw       stx   SH_HNEXT
            clc
            rts

*-- The slot-address tables, and the flush VARSET calls (PATH is
*-- just a variable, so ANY variable store may have changed it).
SHH_CLO     dfb   <SH_HC0,<SH_HC1,<SH_HC2,<SH_HC3
SHH_CHI     dfb   >SH_HC0,>SH_HC1,>SH_HC2,>SH_HC3
SHH_PLO     dfb   <SH_HP0,<SH_HP1,<SH_HP2,<SH_HP3
SHH_PHI     dfb   >SH_HP0,>SH_HP1,>SH_HP2,>SH_HP3

SH_HFLUSH   stz   SH_HC0
            stz   SH_HC1
            stz   SH_HC2
            stz   SH_HC3
            stz   SH_HNEXT
            rts

*-- Table exhausted: leave SH_PATHFULL holding the bare word so
*-- the caller's failure names what was actually typed.
:exhausted  ldy   #0
:cpbare     lda   SH_CMDWORD,y
            sta   SH_PATHFULL,y
            beq   :bared
            iny
            cpy   #SH_CMDMAX-1
            bne   :cpbare
            lda   #0
            sta   SH_PATHFULL,y
:bared      lda   #<SH_PATHFULL
            sta   PTR0
            lda   #>SH_PATHFULL
            sta   PTR0+1
            sec
            rts

*---------------------------------------------------------------
* PATH_EXISTS -- carry CLEAR if SH_PATHFULL can be opened.
* Opens and immediately closes: a test, not a use. Its own
* buffer and parmlists, never redirection's -- sharing those
* corrupted the redirect target between staging and spawning.
*---------------------------------------------------------------
PATH_EXISTS lda   #<SH_TPATHBUF
            sta   PTR1
            lda   #>SH_TPATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<SH_TOPARM
            ldx   #>SH_TOPARM
            jsr   SC_OPEN
            bcs   :nope
            lda   SH_TOPARM_REF
            sta   SH_TCPARM_REF
            lda   #<SH_TCPARM
            ldx   #>SH_TCPARM
            jsr   SC_CLOSE
            clc
            rts
:nope       sec
            rts

*---------------------------------------------------------------
* XEC_PEEK -- the ONE reader of "what does an executable-looking
* text file start with" (docs/EXEC-SHEBANG.md): SHEB_FIX reads
* `#!` line through it and `test -x` reads two bytes through it,
* so the two cannot disagree about a file.
* IN:  PTR0 = path (liba string), PTR1 = buffer, A = count
*      (1..255, buffer must hold them).
* OUT: carry CLEAR, A = bytes read (0 for an empty file); carry
*      SET = could not open or read it.
* CLOBBERS: X, Y, PTR0-PTR2. Uses PATH_EXISTS's probe parmlists.
*---------------------------------------------------------------
XEC_PEEK    sta   RL_PARM_REQ
            stz   RL_PARM_REQ+1
            lda   PTR1
            sta   RL_PARM_BUF
            lda   PTR1+1
            sta   RL_PARM_BUF+1
            lda   #<SH_TPATHBUF
            sta   PTR1
            lda   #>SH_TPATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<SH_TOPARM
            ldx   #>SH_TOPARM
            jsr   SC_OPEN
            bcs   :out
            lda   SH_TOPARM_REF
            sta   SH_TCPARM_REF
            sta   RL_PARM_REF
            lda   #PCOUNT_READ
            sta   RL_PARM
            lda   #<RL_PARM
            ldx   #>RL_PARM
            jsr   SC_READ
            lda   #0
            bcs   :closeit
            lda   RL_PRM_TRNS
:closeit    pha
            lda   #<SH_TCPARM
            ldx   #>SH_TCPARM
            jsr   SC_CLOSE
            pla
            clc
            rts
:out        sec
            rts

*---------------------------------------------------------------
* PATHTAB -- the search path, in order, NUL-terminated entries
* with an empty entry to end the table.
*
* /bin/ first so the utilities can live out of the volume
* root: a ProDOS volume directory is capped at whatever the
* formatter gave it (51 entries here) and cannot grow, while a
* subdirectory can. /mnt/MAUX/ stays second so an image that has
* not moved its binaries yet still works.
*
* The cwd is deliberately NOT searched. `cd` into a directory
* with a file called CAT should not change what CAT means.
*---------------------------------------------------------------
*
* IT IS THE DEFAULT NOW, NOT THE ONLY LIST (docs/SYSCALL.md item
* 13c): PATH_SRC below copies it into SH_PATHSRC only when the
* variable table has no PATH. Deliberately kept rather than
* deleted -- a shell that cannot find ECHO because a script
* clobbered PATH is unusable, and this machine has no other
* recovery path. Same reasoning ANACHRONISMS' test 1 records:
* the constraint that justified the fallback is gone, the
* fallback is still cheap insurance.
*-- PATHTAB moved to src/liba/pathtab.s on 2026-08-26 --
*-- `find -exec` needs the same default and a POLICY list
*-- copied twice is one more thing to forget to change.

*---------------------------------------------------------------
* PATH_SRC -- fill SH_PATHSRC with the prefix list BUILD_PATH is
* about to walk: the PATH variable's value if there is one, else
* PATHTAB verbatim. Called once per resolution, before the first
* candidate, with SH_CMDWORD already safely copied (this
* clobbers PTR0/PTR1).
*
* PATH is COLON-separated, Bourne's own spelling, and an entry
* that does not already end in '/' gets one -- so both
* "/bin/:/mnt/MAUX/" and "/bin:/mnt/MAUX" work, and
* neither spelling is a silently-wrong search. An EMPTY entry
* ("::", or a leading/trailing ':') is DROPPED rather than
* turned into "/": Bourne reads it as the current directory,
* this shell deliberately never searches the cwd (see PATHTAB's
* own note), and searching the volume root instead would be a
* third meaning nobody asked for.
*
* SIZING: VARVALLEN is 31, so the worst case is 31 colons -- 32
* empty entries, all dropped, which is why the buffer only has
* to hold a real value's own worst case: 31 characters, at most
* 16 added slashes, 16 terminators and the final empty entry.
* SH_PSRCSZ (96) covers that with room to spare, and PATHTAB
* itself is 21 bytes.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
PATH_SRC    lda   #<PATHVAR_STR
            sta   PTR0
            lda   #>PATHVAR_STR
            sta   PTR0+1
            jsr   VARFIND                ;X = slot when found
            bcc   :fromvar
*-- ONE PARSER, not two. This branch used to copy PATHTAB
*-- VERBATIM, which only worked while the table was stored in
*-- SH_PATHSRC's own NUL-separated form. src/liba/pathtab.s now
*-- holds it in the ':'-separated Unix format a user's PATH
*-- arrives in -- so the default goes through the SAME loop as
*-- real input, and the shell no longer has a code path that
*-- only the built-in list ever exercised.
*-- COPIED absolute-indexed, then parsed from the copy. A
*-- direct `lda #<PATHTAB / sta PTR1` is check_purity shape (B)
*-- -- PTR1 is an indirect STORE destination in this program
*-- (MKPATH) -- and liba modules in this tree carry EMPTY debt
*-- sets. Same dodge src/liba/pathres.s uses, same buffer.
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
            bra   :parse

:fromvar    jsr   VSLOT_VAL              ;PTR1 = &value
:parse      stz   PSRCI
            stz   PSRCLAST
            ldy   #0
:pv         lda   (PTR1),y
            beq   :pvend
            iny
            cmp   #$BA                   ;':' high-bit
            beq   :pvsep
            sta   PSRCLAST
            ldx   PSRCI
            sta   SH_PATHSRC,x
            inc   PSRCI
            bra   :pv
:pvsep      jsr   PSRC_ENDENT
            bra   :pv
:pvend      jsr   PSRC_ENDENT
            ldx   PSRCI                  ;empty entry = end of
            lda   #0                     ;table, BUILD_PATH's
            sta   SH_PATHSRC,x           ;own :exhausted test
            rts

*---------------------------------------------------------------
* PSRC_ENDENT -- close the entry being built: a trailing '/' if
* it has not got one, then its NUL. An entry with no characters
* at all is dropped entirely (PSRCLAST is 0 only there, since
* every real character stores itself into it).
*---------------------------------------------------------------
PSRC_ENDENT lda   PSRCLAST
            beq   :none
            cmp   #$AF                   ;'/' high-bit
            beq   :term
            ldx   PSRCI
            lda   #$AF
            sta   SH_PATHSRC,x
            inc   PSRCI
:term       ldx   PSRCI
            lda   #0
            sta   SH_PATHSRC,x
            inc   PSRCI
:none       stz   PSRCLAST
            rts

PATHVAR_STR asc   "PATH"
            dfb   0

*-- SH_TPATHBUF (probe only, never the redirection buffer) moved
*-- to the dum/dend block at the file's textual end (2026-08-21)
*-- -- MKPATH always writes it whole immediately before
*-- PATH_EXISTS's SC_OPEN reads it.
SH_TOPARM      dfb   OPEN_RO                  ;probes only read
SH_TOPARM_PTH  da    SH_TPATHBUF
SH_TOPRM_IOBF  da    0
SH_TOPARM_REF  dfb   0
SH_TCPARM      dfb   PCOUNT_CLOSE
SH_TCPARM_REF  dfb   0

*-- SH_CMDMAX: hoisted to sh.s's top block.
* -- SH_CMDWORD (command word, flat -- search is absolute
* indexed) -- moved to the dum/dend block at the file's textual
* end -- (2026-08-21) -- BUILD_PATH's :cpcmd loop always writes
* it -- whole (copying the source word's own NUL, or forcing one
* at -- the SH_CMDMAX-1 boundary) before :cpword/:cpbare/:trydir
* ever -- read it back.
SH_PATHI    ds    1                      ;offset of the PATHTAB
                                         ;entry being tried
SH_NEXTI    ds    1                      ;offset of the next one
*---------------------------------------------------------------
* ARGV_PTR_STG -- PTR1 = address of STAGEI's argv pointer-
* array block. CLOBBERS: A.
*---------------------------------------------------------------
ARGV_PTR_STG
            ldx   STAGEI
            lda   STGOFF,x
            clc
            adc   #<CMD_ARGV
            sta   PTR1
            lda   #>CMD_ARGV
            adc   #0
            sta   PTR1+1
            rts

* See B.SH.TXT: "OPENREDIRREAD -- open a  target"
OPEN_REDIR_RD
            lda   #<SH_PATHBUF
            sta   PTR1
            lda   #>SH_PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #OPEN_RO               ;`<` and script reads:
            sta   SH_OPARM               ;read intent (OPEN-RO)
            lda   #<SH_OPARM
            ldx   #>SH_OPARM
            jsr   SC_OPEN
            lda   #OPEN_APPEND           ;`>>` shares the parm:
            sta   SH_OPARM               ;its resting count
            bcs   :fail
            lda   SH_OPARM_REF
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* OPEN_HI -- IN: A = a fd the shell has just opened for its
* OWN use (its script, a `.` file, a construct's redirect).
* OUT: A = the fd to keep: the file moved to the highest free
* number above it (7 down), so a script's `exec 3<F` cannot
* dup2 over the descriptor the shell reads its next command
* from (SH-FD-NOTES sec 13: data run as code).  Bourne shells
* do the same (dash: fd 10); this table has 8 slots, so 7.
* A move that cannot be made leaves the fd where it is, and
* UFD_DUP2 still refuses an `exec` onto it.
* CLOBBERS: X, Y.
*---------------------------------------------------------------
OPEN_HI     sta   OHI_FD
            lda   #7
:try        sta   OHI_T
            cmp   OHI_FD
            bcc   :keep
            beq   :keep
            jsr   SC_FDSTAT              ;carry set = closed
            bcs   :free
            lda   OHI_T
            dec   a
            bra   :try
:free       ldx   OHI_T
            lda   OHI_FD
            jsr   SC_DUP2
            bcs   :keep
            lda   OHI_FD
            jsr   CLOSE_FD_A
            lda   OHI_T
            rts
:keep       lda   OHI_FD
            rts

* See B.SH.TXT: "OPENREDIRWRITE -- unlink an existing target"
*-- `>` is V7's creat(2), so it CALLS V7's creat --
*-- liba/creat.s (2026-08-29): CREATE-ignore-exists + OPEN +
*-- truncate-by-handle, one directory walk cheaper than the old
*-- UNLINK+CREATE+OPEN and identity-preserving on an existing
*-- target, exactly as Unix `>` is. That file's header carries
*-- the design; a SET_EOF refusal (write-locked target) comes
*-- back carry-set with the fd already closed.
OPEN_REDIR_WR
            lda   #<SH_PATHBUF
            sta   PTR1
            lda   #>SH_PATHBUF
            sta   PTR1+1
            jsr   MKPATH
*-- OPEN-RW-1 (shsgrw.s): a $50 busy open is retried, bounded.
*-- Not Unix -- a long holder still fails, after the bound.
            lda   #<WR_TRY
            ldx   #>WR_TRY
            jmp   OW_RUN             ;tail call -- fd/errno and
                                     ;carry are this routine's
                                     ;own OUT contract
WR_TRY      lda   #<SH_PATHBUF
            sta   PTR1
            lda   #>SH_PATHBUF
            sta   PTR1+1
            jmp   CREAT

* See B.SH.TXT: "OPENREDIRAPPEND -- `>>`: open a target WITHOUT"
* truncating an existing one (SC_CREAT's "already exists"
* failure is ignored on purpose -- that's the whole point of
* append, not a shortcut like OPEN_REDIR_WR's "ignore missing-
* file" above), a real path failure still surfaces at the OPEN
* below, then lseek(fd, 0, SEEK_END) over the freshly opened fd
* -- the exact package docs/FLEET.md's "`>>` and the seek
* family" specifies. Reuses SH_CRT_PARM verbatim (same access/
* file-type CREATE flags as `>`'s own -- append makes no txt/bin
* distinction).
OPEN_REDIR_AP
            lda   #<SH_PATHBUF
            sta   PTR1
            lda   #>SH_PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<AP_TRY               ;retried while busy
            ldx   #>AP_TRY               ;(OW_RUN, shsgrw.s)
            jsr   OW_RUN
            bcs   :fail
            lda   SH_OPARM_REF
            sta   SH_APND_FD
*-- A CHARACTER DEVICE HAS NO END TO SEEK TO (KFIX5): the kernel
*-- refuses lseek on /dev/null and the consoles, so `>>` used to
*-- close them and say "cannot redirect" -- `cmd >> /dev/null
*-- 2>&1` is a common script idiom. SC_FDSTAT's high bit is
*-- "device" (as SH_INTERACT's test above). A closed fd (carry)
*-- falls through to the seek, which reports it as before; a
*-- FILE whose seek fails still closes and reports at :seekfail.
            jsr   SC_FDSTAT
            bcs   :seek
            ora   #0
            bmi   :done
:seek       stz   SH_SEEKOFF
            stz   SH_SEEKOFF+1
            stz   SH_SEEKOFF+2
            lda   #<SH_SEEKOFF
            sta   PTR0
            lda   #>SH_SEEKOFF
            sta   PTR0+1
            lda   SH_APND_FD
            ldy   #SEEK_END
            jsr   LSEEK
            bcs   :seekfail
:done       lda   SH_APND_FD
            clc
            rts
:seekfail   lda   SH_APND_FD
            jsr   CLOSE_FD_A
            sec
            rts
:fail       sec
            rts
AP_TRY      lda   #<SH_CRT_PARM
            ldx   #>SH_CRT_PARM
            jsr   SC_CREAT                ;ignore "already
                                          ;exists" -- append
                                          ;must NOT destroy
                                          ;existing content
            lda   #<SH_OPARM
            ldx   #>SH_OPARM
            jmp   SC_OPEN

*---------------------------------------------------------------
* CLOSE_FD_A -- IN: A = fd. CLOBBERS: A, X.
*---------------------------------------------------------------
CLOSE_FD_A  sta   SH_CPARM_REF
            lda   #<SH_CPARM
            ldx   #>SH_CPARM
            jsr   SC_CLOSE
            rts

*---------------------------------------------------------------
* PR_ERR -- print the message at PTR0 to stderr.
*
* Four different failures used to share "command not found":
* a syntax error, a pipe that could not be created, a redirect
* that could not be opened, and an actual missing command. So
* `cat < /mnt/MAUX/NOSUCH` sent you looking for cat. Ruling 7
* says
* the shell does not decode the ERRNO, which is still true --
* these distinguish WHICH OPERATION failed, which the shell
* knows for certain without asking anyone.
*---------------------------------------------------------------
*-- PR_ERRAX -- the same thing with the message in A/X, which is
*-- 4 bytes cheaper at every call site than loading PTR0 by
*-- hand. Falls through; PR_ERR keeps its PTR0 entry for the
*-- callers that already have the pointer there.
PR_ERRAX    sta   PTR0
            stx   PTR0+1
PR_ERR      ldx   #FD_STDERR
            jsr   PUTS
            rts

PR_CMDNOTFND
            lda   #<CMDNTFND_MSG
            sta   PTR0
            lda   #>CMDNTFND_MSG
            sta   PTR0+1
            bra   PR_ERR

PR_NOEXEC   lda   #<NOEXEC_MSG
            sta   PTR0
            lda   #>NOEXEC_MSG
            sta   PTR0+1
            bra   PR_ERR

PR_SYNTAX   lda   #<SYNTAX_MSG
            sta   PTR0
            lda   #>SYNTAX_MSG
            sta   PTR0+1
            bra   PR_ERR

PR_PIPEFAIL lda   #<PIPE_MSG
            sta   PTR0
            lda   #>PIPE_MSG
            sta   PTR0+1
            bra   PR_ERR

*---------------------------------------------------------------
* CK_ORPHRDIR -- diagnose redirections that have no command to
* attach to, instead of dropping them. Two callers: a segment
* with no command word at all (a bare `< FILE` line), and a
* construct terminator with residual redirects (`DONE < FILE`,
* `FI < FILE` -- docs/SH-FEATURES.md sec 17/18). Silent when
* nothing was recorded, so a stray `;` or a bare `FI` stays
* silent as before. CLOBBERS: A, PTR0.
*---------------------------------------------------------------
CK_ORPHRDIR lda   CMD_INFILE
            ora   CMD_INFILE+1
            ora   CMD_OUTFILE
            ora   CMD_OUTFILE+1
            ora   DUPN
            ora   HD_ACTIVE              ;`fi <<EOF` too
            beq   :none
            jsr   PR_REDIRNOCM
            lda   #1
            sta   LASTSTATUS
:none       rts

PR_REDIRNOCM lda  #<REDIRNOCM_M
            sta   PTR0
            lda   #>REDIRNOCM_M
            sta   PTR0+1
            bra   PR_ERR

PR_TOOMANY  lda   #<TOOMANY_MSG
            sta   PTR0
            lda   #>TOOMANY_MSG
            sta   PTR0+1
            bra   PR_ERR

* PR_BADFD -- `sh: M: bad file descriptor`, A = M (0-7).
* PR_BADFDK -- the same without the number, for a spawn the
* kernel refused with ERR_INVAL (a list sh's own check missed).
PR_BADFD    clc
            adc   #'0'
            sta   BADFD_DIG
            lda   #<BADFD_MSG
            ldx   #>BADFD_MSG
            jmp   PR_ERRAX
PR_BADFDK   lda   #<BADFDK_MSG
            ldx   #>BADFDK_MSG
            jmp   PR_ERRAX

PR_REDIRERR lda   #<REDIR_MSG
            sta   PTR0
            lda   #>REDIR_MSG
            sta   PTR0+1
            bra   PR_ERR

*-- PR_ERRAX1 -- PR_ERRAX, then LASTSTATUS := 1 and return
*-- (SH-ROOM: the tail of twenty error sites). PR_ERRAX1M -- the
*-- same, then back to the prompt loop (it does not return).
*-- Registers on exit are PR_ERRAX's, then A = 1.
PR_ERRAX1   jsr   PR_ERRAX
            lda   #1
            sta   LASTSTATUS
            rts
PR_ERRAX1M  jsr   PR_ERRAX1
            jmp   MAINLOOP

BADFD_MSG   asc   'sh: '
BADFD_DIG   dfb   0
            asc   ': bad file descriptor'
            dfb   $0D,0
BADFDK_MSG  asc   'sh: bad file descriptor'
            dfb   $0D,0
CMDNTFND_MSG
            asc   "sh: command not found"
            dfb   $8D,0
NOPROC_MSG  asc   'sh: no more processes'
            dfb   $0D,0
NFILE_MSG   asc   'sh: file table full'
            dfb   $0D,0
*-- dfb hex, not asc "..": check-encoding's literal pin.
*-- "sh: cannot execute"
NOEXEC_MSG  dfb   $F3,$E8,$BA,$A0,$E3,$E1,$EE,$EE
            dfb   $EF,$F4,$A0,$E5,$F8,$E5,$E3,$F5
            dfb   $F4,$E5,$8D,0
SYNTAX_MSG  asc   "sh: syntax error"
            dfb   $8D,0
PIPE_MSG    asc   "sh: cannot create pipe"
            dfb   $8D,0
REDIRNOCM_M asc   "sh: redirection without a command"
            dfb   $8D,0
REDIR_MSG   asc   "sh: cannot redirect"
            dfb   $8D,0
TOOMANY_MSG asc   "sh: too many arguments"
            dfb   $8D,0
TOKUNTERM_MSG
            asc   "sh: unterminated quote"
            dfb   $8D,0
TOKMIXED_MSG
            asc   "sh: mixed quoting"
            dfb   $8D,0
*-- dfb hex, not asc "..": check-encoding's literal pin.
*-- "sh: line too long" (SH-MLQUOTE: refused whole, never run
*-- truncated). Low image: PR_ERRAX hands it to a syscall.
TOOLONG_MSG dfb   $F3,$E8,$BA,$A0,$EC,$E9,$EE,$E5
            dfb   $A0,$F4,$EF,$EF,$A0,$EC,$EF,$EE
            dfb   $E7,$8D,0

*---------------------------------------------------------------
* Module data.
*---------------------------------------------------------------
* -- LINEBUF, TOKPTR and TOKQUOTE all moved to the dum/dend
* block -- at the file's textual end (2026-08-21). LINEBUF:
* READLINE -- always writes bytes 0..LINELEN-1 then NUL-
* terminates at -- LINELEN before TOKENIZE (or STRIPCOMMENT)
* ever reads it, and -- TOKENIZE's in-place squeeze only ever
* writes at or behind -- where it has already read (write cursor
* X <= read cursor Y). -- TOKPTR/TOKQUOTE: TOKENIZE writes slot
* NTOK before incrementing -- NTOK past it, and every reader
* (LOAD_TOK_PTR via PARSE) only -- ever indexes 0..NTOK-1.
LINELEN     ds    1
NTOK        ds    1
TOKTMP      ds    2
TOKI        ds    1
TOK_ERR     ds    1        ;TOKENIZE's own error out: 0 ok,
                           ;1 unterminated quote, 2 mixed form,
                           ;3 too many tokens / OPBUF full,
                           ;4 number before >/< (no such fd)
CURQFLAG    ds    1        ;current token's TOKQUOTE, loaded
                           ;by LOAD_TOK_PTR -- WORDEXPAND and
                           ;GLOB_APPEND each consult it
                           ;independently
TOKWY       ds    1        ;TOKENIZE scratch: write cursor
                           ;stash while X is borrowed for a
                           ;TOKQUOTE store
QFLAGVAL    ds    1        ;TOKENIZE scratch: quote flag value
                           ;for the token currently being
                           ;copied
QCH         ds    1        ;TOKENIZE scratch: the quote char
                           ;(''' or '"') this token must close
                           ;on
*-- TOKLVL moved to sh.s's own `dum` arena (HDX_KIND's own
*-- neighborhood) -- write-before-read (:tokstart), so it
*-- costs no BIN_DEBT, unlike this file's OWN scratch above
*-- (sec 21's ratchet already counts THOSE as accepted debt).
*-- :qbare's quote-exception scratch -- shared by BOTH eligible
*-- prefixes now: `<<'WORD'` (docs/SH-FEATURES.md sec 6/12) and
*-- `NAME='value'` (docs/SHELL-GAPS.md sec 2b). All are freshly
*-- written (HDX_ELIG/HDX_USED/HDX_KIND explicitly zeroed) at
*-- the TOP of every :qbare call, so nothing here needs zeroing
*-- between lines.
HDX_ELIG    ds    1        ;this token's first bytes were an
                           ;eligible prefix followed by a quote
HDX_USED    ds    1        ;the one exception this token gets
                           ;has already fired
HDX_PFXLEN  ds    1        ;offset of that quote char from the
                           ;token's own start (2 or 3)
HDX_QCH     ds    1        ;which quote char (''' or '"') it was
HDX_SAVEX   ds    1        ;:bqcheck scratch: preserves the
                           ;write cursor X across an NTOK-
                           ;indexed HDWORDQ store
PARSE_SEPOP ds    1        ;what ended the last PARSE segment:
                           ;0=EOL 1=; 2=&& 3=||
SH_SKIP     ds    1        ;short-circuit state between segments
                           ;(MAINLOOP's :seg loop, NEXT_SKIP)
REDIR_FD    ds    1        ;CLASSIFY's own out: the target fd
                           ;digit (0-7) of the `N>`/`N>>` token
                           ;just classified (docs/SH-FEATURES.md
                           ;sec 3) -- meaningless except right
                          ;after a return of 8 or 9 (and now 11,
                           ;`N>&M` -- sec 15)
REDIR_SRC   ds    1        ;CLASSIFY's own out: the SOURCE fd
                           ;digit (0-7) of an `N>&M`, or $FF for
                           ;the `N>&-` close form -- meaningless
                           ;except right after a return of 11

*-- WORDEXPAND's scratch pool -- line-scoped (TOKENIZE resets
*-- EXPCUR), bump-allocated so multiple expanding words on one
*-- line each keep their own bytes (see WORDEXPAND's header).
*-- 128B (raised from 64 for Tier 2, docs/SH-FEATURES.md sec 4:
*-- a $NAME can now hold up to VARVALLEN bytes, more than any
*-- `$?` ever could) covers many expansions per line;
*-- EMITB/EMITSTATUS/EMITHASH/EMITARG/EMITVAR all clamp it.
*-- EXPBUFLEN: hoisted to sh.s's top block (EQU burn-down,
*-- 2026-08-29) -- shexpand, put earlier, uses it immediate.
EXPCUR      ds    1
EXPX        ds    1        ;DOEXPAND's cursor into EXPBUF
EXPSTART    ds    1        ;this word's slice start in EXPBUF
*-- EXPBUF moved to the arena 2026-08-27 (128 bytes). The note
*-- further down that kept it here said it was "left as `ds`
*-- anyway rather than moved, since there is no reason to
*-- disturb it" -- there is one now: bytes.
DXSAVE      ds    2        ;EMITARG/EMITVAR: DOEXPAND's own
                           ;PTR0, saved across a lookup that
                           ;needs PTR0 for itself
VDIGIT      ds    1        ;EMITARG scratch: the incoming digit
                           ;char, stashed before A gets
                           ;clobbered
VTMP        ds    1        ;EMITARG scratch: the binary digit
VNBUF       ds    VARNAMELEN+1  ;EMITVAR scratch: the scanned
                           ;identifier, NUL-terminated
VNLEN       ds    1        ;EMITVAR scratch: VNBUF's length so
                           ;far
VNTOOLONG   ds    1        ;EMITVAR scratch: identifier ran past
                           ;VARNAMELEN -- lookup skipped (see
                           ;EMITVAR's header)
VNRESUMEY   ds    1        ;EMITVAR scratch: Y just past the
                           ;identifier, saved across the lookup
                           ;(STRCMP/EMITSTRP both clobber Y)
POS_SHIFT   ds    1        ;`shift`'s own state -- 0-based
                           ;offset added to $1-$9's argv index;
                           ;$0/$# read it too (docs/SH-
                           ;FEATURES.md sec 4)

NCMD        ds    1
