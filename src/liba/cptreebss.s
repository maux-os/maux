*---------------------------------------------------------------
* cptreebss.s -- cptree.s's uninitialised storage, in its own
* `dum` block CHAINED onto libabss.s's.
*
* PUT ORDER, which is load-bearing:
*     put   ../liba/libabss.s      ;defines LIBA_BSSEND
*     put   ../liba/cptreebss.s   ;LIBA_BSSEND -> CPT_BSSEND
*     ...then the program's own `dum CPT_BSSEND` block.
*
* WHY IT IS NOT INSIDE cptree.s. A `dum` block computes
* addresses from the real PC where it opens and `dend` restores
* that PC, so a block opened in the MIDDLE of a program is
* silently overlaid by everything emitted after it
* (learning:01M0FNC75R7YSFRNS328WHXMHN). cptree.s sits in the
* middle of both consumers' put-lists. Same reason libabss.s is
* a separate module; same placement rule.
*
* WHY IT IS NOT IN libabss.s, WHICH WAS TRIED FIRST AND
* MEASURED. That module is one monolithic block `put` by all 40
* programs, so a cell added there is reserved by every one of
* them -- `ls`, `ld`, `sh`, `as` -- whether or not it will ever
* walk a tree. The claim that this costs "address space only"
* is TRUE and INSUFFICIENT: `as.s` bounds its own arena at
* SYMADR ($3C00), not $BF00, because the assembler's symbol
* table starts there, and it had about 540 bytes of headroom.
* cptree's ~950 blew straight through it: check-userland
* failed with "The evaluation of ERR expression is 0x1" at
* as.s:1302, which is that ceiling doing its job. Shrinking the
* assembler's symbol table to give `mv` a directory walk is not
* a trade worth making, and a shared arena makes every future
* liba addition pay it again.
*
* So the storage is chained instead: this module reserves its
* cells only for the two programs that `put` it, and the
* consumer's own arena then opens at CPT_BSSEND rather than
* LIBA_BSSEND. check_purity's sec 21 gate learned to tell a
* BSS-ONLY module apart from an emitting one to allow this --
* see check_arena_anchors(), which now follows the `put` and
* proves the module emits nothing, rather than assuming that
* anything after libabss.s must. The pattern is the one
* check_purity's own LIBA_DEBT note already sketched for
* expr.eval.s and testeval.s; it just had no gate support.
*
* WHY EVERY CELL IS EMITTED-FREE. `mv` is declared
* TEXT_IMMUTABLE (scripts/check_purity.py sec 29) and
* check-textaudit measures it every sweep; its entry head stays
* intact, so the kernel RETAINS its bank and the next `mv` of
* the session starts on whatever the last one wrote. An MLI
* parmlist is assembled data the kernel writes RESULTS back into
* (check_purity's write shape D), so a parmlist emitted into
* cptree's text would dirty mv's image on every run -- exactly
* the hazard learning:01M0T103ZQSAEGQ5D8FS8XZ8V4 records, which
* has already cost this project two bugs. So cptree declares NO
* emitted data at all: the eight parmlists are cells here, and
* their constant fields are STORED by cptree.s's CPT_INIT.
* readdir.s's RD_INITPARM is the precedent, and its line in
* check-purity's liba ratchet reads 0 for the same reason.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21). Every cell
* is write-before-read; the trace is recorded beside each group.
*---------------------------------------------------------------

* -- Depth of cptree's explicit walk stack. find.s's FIND_MAXDEP
* -- and du.s's DU_MAXDEP, for their reason: ProDOS caps an MLI
* -- pathname at 64 characters, so with real 15-character
* -- component names the reachable depth is a handful of levels.
* -- Exceeding it is a LOUD failure, never a truncated walk.
* -- CPT_MAXDEP moved to inc/cptree.equ: cptree.s tests it
* -- with `cmp #CPT_MAXDEP`, and this file is the dum arena and
* -- is necessarily put last.

* -- cptree's path buffers. find.s's FP_BUFLEN, for find.s's
* -- reason: the buffer must hold the CANDIDATE -- a full-length
* -- parent (MLI_PTH_MAXLN chars) + '/' + a 15-char ProDOS name
* -- + NUL -- so the 64-character verdict can be a CHECK rather
* -- than an overrun. A 64-char directory holding a long-named
* -- child is legal on disk (prefix + partial pathname reach
* -- 128, TRM ch. 2) even though no MLI call can open it.
CPT_PBUF    equ   MLI_PTH_MAXLN+17

* -- CPT_PBMIN restates the writers' sum INDEPENDENTLY of
* -- CPT_PBUF so the tripwire below still fires if CPT_PBUF
* -- itself is ever edited down. find.s carries the identical
* -- pair (FP_BUFLEN/FPMINSZ) because reverting its `ds` to 65
* -- passed its WHOLE gate: the carry fence masks the spill and
* -- a .bin byte count cannot witness a dum-arena change. A
* -- comment cannot hold this claim; an `err` can.
CPT_PBMIN   equ   MLI_PTH_MAXLN+17

* -- cptree's copy chunk, the same 512 mv.s and cp.s use.
* CPT_BUFSZ: def moved to cptree.equ (REL rule)

* -- READDIR's record stride. Spelled here rather than as
* -- RD_SIZE only for symmetry with the rest of this file;
* -- cptree.s carries an `err` that fails the assembly if the
* -- two ever disagree.
* CPT_RECSZ: def moved to cptree.equ (REL rule)

            dum   LIBA_BSSEND

* -- WALK STATE. CPT_DEPTH/CPT_RESN/CPT_ERR are zeroed by
* -- CPT_START and CPT_RMTREE before either is read.
CPT_DEPTH   ds    1
CPT_RESN    ds    2
CPT_SKIPN   ds    2
CPT_ERR     ds    1

* -- CPT_SKIPN MUST NOT BE CPT_RESN. CPT_RESN is this level's
* -- ABSOLUTE position and has to survive the replay: the next
* -- descend from this level pushes it again, and a level that
* -- came back from a child keeps counting from where it was,
* -- not from zero. Decrementing the position itself is the bug
* -- that made `find` ping-pong forever between a directory and
* -- its first child over any directory holding TWO OR MORE
* -- subdirectories, and terminate happily on one
* -- (src/bin/find.s, SKIPRESUME's header). Do not economise it.
* -- CPT_SKIPN is copied from CPT_RESN as CPT_SKIP's first two
* -- instructions and read only after.

* -- CURRENT PATHS. Liba strings (high-bit, NUL-terminated) --
* -- NOT MLI paths, because the walk appends to and truncates
* -- them constantly and MKPATH is the boundary, run fresh
* -- before every MLI call. Written whole by the consumer before
* -- CPT_START/CPT_RMTREE.
CPT_SLEN    ds    1
CPT_DLEN    ds    1
CPT_SRC     ds    CPT_PBUF
CPT_SGAP    equ   *-CPT_SRC+1
* -- SIZING TRIPWIRE: 0 while CPT_SRC is big enough for
* -- CPT_APPEND's worst case, 1 when it is not, and `err` fails
* -- the assembly. find.s's FPMINSZ/FPGAP1 idiom.
            err   CPT_PBMIN/CPT_SGAP
CPT_DST     ds    CPT_PBUF
CPT_DGAP    equ   *-CPT_DST+1
            err   CPT_PBMIN/CPT_DGAP

* -- CPT_OSL/CPT_ODL hold the lengths as they were BEFORE the
* -- current entry's name was appended, so a plain file can be
* -- copied and then un-appended, and a subdirectory can push
* -- its PARENT's lengths rather than its own. Both are written
* -- by the walk's entry handler before anything reads them.
* -- CPT_ALEN is CPT_APPEND's in/out length; CPT_TMP is scratch
* -- inside CPT_UNPATH only, written before its own read.
CPT_OSL     ds    1
CPT_ODL     ds    1
CPT_ALEN    ds    1
CPT_TMP     ds    1

* -- fds, each `sta`'d only after its own SC_OPEN returned
* -- carry-clear; no failure path reads either.
CPT_SFD     ds    1
CPT_DFD     ds    1

* -- THE WALK STACK. CPT_STKS/CPT_STKD save the two path lengths
* -- per paused ancestor level; CPT_STKR saves how many entries
* -- that level had already yielded, so the reopen can replay
* -- past them. Each slot is written by CPT_PUSH before the
* -- matching CPT_POP reads it -- CPT_DEPTH only ever pops an
* -- index it has itself pushed. CPT_RMTREE uses CPT_STKS only;
* -- it needs no resume count at all, because deleting IS its
* -- cursor (see cptree.s's header).
CPT_STKS    ds    CPT_MAXDEP
CPT_STKD    ds    CPT_MAXDEP
CPT_STKR    ds    CPT_MAXDEP*2

* -- READDIR's caller-owned record, written whole by READDIR
* -- before the walk reads it (readdir.s's own contract).
CPT_REC     ds    CPT_RECSZ

* -- MLI-shaped path scratch (1 count byte + up to 64 chars).
* -- MKPATH writes chars then the count byte and the MLI reads
* -- only count+1, so the tails are never in view. CPT_MP is
* -- always the SOURCE side and CPT_MP2 always the DESTINATION
* -- side; only CPT_GF_PATH and CPT_DP_PATH ever move between
* -- them, both being cells here and therefore not text.
CPT_MP      ds    65
CPT_MP2     ds    65

* -- copy-loop data_buffer. A process-bank address; the kernel
* -- copyin/outs through it via bankcopy. Filled by SC_READ, and
* -- CPT_WP_REQ is set from CPT_RP_TRAN, so the write-back never
* -- reads past what that call actually put there.
CPT_BUF     ds    CPT_BUFSZ

*---------------------------------------------------------------
* THE EIGHT PARMLISTS. Cells, not emitted data; see the header.
* An MLI parmlist must be CONTIGUOUS (learning:01M0M9R7RT22JEPP-
* 2R0Y6J9MBX), so the constant param_count/pointer/request bytes
* cannot stay behind in text once the rest of the block moves
* here: CPT_INIT stores every one of them, and it is the first
* thing both public entry points call.
*---------------------------------------------------------------
CPT_OP      ds    1              ;OPEN, source file
CPT_OP_PATH ds    2
CPT_OP_IOB  ds    2
CPT_OP_REF  ds    1

CPT_O2      ds    1              ;OPEN, destination file
CPT_O2_PATH ds    2
CPT_O2_IOB  ds    2
CPT_O2_REF  ds    1

CPT_CR      ds    1              ;CREATE, destination
CPT_CR_PATH ds    2
CPT_CR_ACC  ds    1
CPT_CR_FTYP ds    1
CPT_CR_AUX  ds    2
CPT_CR_STYP ds    1
CPT_CR_DATE ds    2
CPT_CR_TIME ds    2

CPT_GF      ds    1              ;GET_FILE_INFO
CPT_GF_PATH ds    2
CPT_GF_ACC  ds    1
CPT_GF_FTYP ds    1
CPT_GF_AUX  ds    2
CPT_GF_STYP ds    1
CPT_GF_BLKS ds    2
CPT_GF_MDAT ds    2
CPT_GF_MTIM ds    2
CPT_GF_CDAT ds    2
CPT_GF_CTIM ds    2

CPT_RP      ds    1              ;READ
CPT_RP_REF  ds    1
CPT_RP_BUF  ds    2
CPT_RP_REQ  ds    2
CPT_RP_TRAN ds    2

CPT_WP      ds    1              ;WRITE
CPT_WP_REF  ds    1
CPT_WP_BUF  ds    2
CPT_WP_REQ  ds    2
CPT_WP_TRAN ds    2

CPT_CL      ds    1              ;CLOSE
CPT_CL_REF  ds    1

CPT_DP      ds    1              ;DESTROY
CPT_DP_PATH ds    2

CPT_BSSEND
* -- The consumer's own `dum` block anchors HERE, not at
* -- LIBA_BSSEND and not at `*`: two blocks anchored at the same
* -- address ARE the same bytes. check_purity's sec 21 gate
* -- enforces exactly that for any module chained this way.
            dend
