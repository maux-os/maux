*---------------------------------------------------------------
* testeval.s -- the `test`/`[` expression evaluator (engine
* only). docs/SH-SUBSET.md sec 6.3: `test` must be a shell
* BUILTIN here, not a binary -- spawn is length-driven and
* BankCopy alone is 75% of even a warm spawn, so a re-spawned
* `test` binary still costs ~0.06s per call. This file is the
* engine sh's builtin dispatch will call; it does not parse
* `[`/`]` itself (docs/ANACHRONISMS.md A2b: the shell strips
* the trailing `]` before this ever sees the tokens).
*
* Modeled on src/liba/glob.s: a pure evaluator, no I/O of its
* own beyond GET_FILE_INFO for the file-test primaries, gated by
* its own case table (src/test/testevtestb.s) rather than
* depended on blind.
*
* Operators, POSIX.1-2024 test.html plus the primaries
* docs/POSIX-GAPS.md sec 2's `test` row named as the gap:
*   file:    -f -d -e -s -r -w -x
*   always-false (no such ProDOS object): -b -c -g -h -L -p -S
*   -u
*   string:  -z -n = != (a bare word is its own 1-arg test)
*   integer: -eq -ne -lt -gt -le -ge
*   logic:   ! -a -o and `( expr )` grouping
*
* PROVENANCE NOTE on -a/-o/( ): the LIVE XCU test(1) page
* (POSIX.1-2024, Issue 8, fetched for this task) says Austin
* Group Defect 1330 REMOVED these from the normative grammar --
* APPLICATION USAGE now tells script authors to spell them
* `test e1 && test e2` and shell-level `( )`/`{ }` instead. They
* are shipped here anyway: every real `test`/`[` (bash, dash,
* GNU coreutils) still carries them for historical scripts, sh
* already passes a bare `(`/`)` through as an ordinary word (a
* bare `(` only nests when a `$(` span is already open --
* src/bin/shtok.s SUB_TRKCH), and docs/POSIX-GAPS.md priced this
* exact scope (~300 B) before this task started. Implementing an
* obsolescent-but-still-real primary costs nothing a script
* would notice; the fetched page's own words are quoted above
* so the next reader does not re-derive this from a stale
* assumption.
*
* GRAMMAR (precedence, loosest to tightest): `expr -o expr`,
* `expr -a expr`, `! expr`, primary. `-a` binds tighter than
* `-o`, same as historical test(1) and the removed POSIX text.
* A primary is `( expr )`, UOP ARG, ARG BOP ARG, or a bare ARG
* (nonzero-length test). A unary op is applied ONLY when its
* pathname operand slot is available (bounds-checked); with none
* left, the op token itself degrades to an ordinary bare word --
* the same leniency real shells show at an expression's ragged
* edge, and the only way the mandatory 1-argument rule
* ("test -f" alone is TRUE, not "usage error, missing operand")
* comes out right under one unified grammar. A UOP is otherwise
* GREEDY: it
* always consumes the very next token as its operand, even a
* token that looks like `-a`/`)`/another operator -- the
* well-known historical `test -f -a -r FILE` footgun, kept
* because it is what "the same as real test" means; POSIX itself
* calls constructs like this UNSPECIFIED once more than 4 total
* arguments are in play, so any deterministic choice conforms.
*
* THREE DECISIONS, documented per the task brief (unchanged from
* the file's first cut -- only the file-test roster grew):
*
* (1) -d/-f distinguish by storage_type, NOT file_type -- the
* SAME field src/bin/ls.s tests (STYP_DIR $0D, plus the
* volume-dir $0F oddball ls.s also treats as a directory).
* file_type is a content-format hint (TXT/BIN/SYS/...); it has
* no "this is a directory" case at all, and no volume-dir case
* either.
*
* (2) A GET_FILE_INFO failure (nonexistent or inaccessible
* path) is FALSE for every file-test primary -- never an error.
* POSIX test never errors on a missing path, and a builtin that
* did would break the single most common script idiom,
* `if test -f X`.
*
* (3) A non-numeric operand to -eq/-ne/-lt/-gt/-le/-ge is a
* SYNTAX error (status 2), per POSIX -- it is the only way a
* caller can tell "3 -eq x" apart from "3 -eq 4" (both would
* otherwise read as false). Only unsigned decimal digits are
* accepted (no leading +/-, no whitespace); values above 65535
* wrap silently -- undocumented by POSIX and not needed by
* scripts on this machine.
*
* (4) THE NEW FILE-TEST MAPPINGS, each the maux rule where
* ProDOS has no matching concept:
*   -s  GET_FILE_INFO never returns a byte-exact EOF (only
*       blocks_used -- src/bin/ls.s's own header says so; an
*       exact size needs SYS_GET_EOF on an OPEN fd, a much
*       heavier call for one primary). Mapped to blocks_used
*       > 0: a file with no data block allocated is the ProDOS
*       shape closest to POSIX's "zero length".
*   -r/-w  the ProDOS access byte's read-enable ($01, ACC_READ)
*       and write-enable ($02, ACC_WRITE) bits (src/liba/
*       mli.equ) -- the only permission bits ProDOS has.
*   -x  exists and file_type is SYS ($FF) or BIN ($06) -- ProDOS
*       has no execute bit; this reads back "the loader would
*       run it", which is what "executable" means on this
*       machine.
*   -b -c -g -h -L -p -S -u  ProDOS has no block/char specials,
*       no setuid/setgid bits, no symbolic links, no FIFOs, no
*       sockets -- CONSTANT FALSE for any operand, any path,
*       always. This is conformant, not a shortcut: POSIX only
*       requires "true if pathname resolves to a Y"; none of
*       these Y ever exists here, so the honest answer is always
*       "no, this pathname is not one of those" without even
*       looking at the operand.
*---------------------------------------------------------------

REL_LT      equ   0
REL_EQ      equ   1
REL_GT      equ   2

*---------------------------------------------------------------
* TEST_EVAL -- evaluate a `test`/`[` expression.
* IN:  X = argc (element count; 0 is legal -- empty test).
*      PTR0 = pointer to the argv array: X consecutive 2-byte
*      little-endian pointers, each to a NUL-terminated high-
*      bit-ASCII string -- the SAME array-of-word-pointers
*      shape as sh.s's own CMD_ARGV / liba's ARGV
*      (src/liba/argv.s), reached through a caller-supplied
*      zero-page pointer instead of a fixed address, so this
*      engine has no dependency on sh's own layout.
* OUT: A = 0 true, 1 false, 2 usage/syntax error (POSIX test's
*      own exit-status convention).
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2 -- liba's shared pointer
*      scratch, same contract as GLOBMATCH/STRCMP/MKPATH. The
*      argv array pointer does NOT survive the call -- copy it
*      out first if the caller needs it again.
*
* argc 0 -> false; argc 1 -> POSIX's own mandatory "non-null
* string" test (bypasses the general grammar entirely -- see the
* header's GRAMMAR note on why this one case cannot be folded
* in); argc >= 2 -> the general OR_EXPR grammar below, with a
* trailing-token check afterward (anything OR_EXPR did not
* consume is a syntax error -- the same net effect the old
* fixed-arity dispatch had for every case that dispatch
* covered).
*---------------------------------------------------------------
TEST_EVAL   stx   TE_ARGC
            lda   PTR0
            sta   TE_AVBASE
            lda   PTR0+1
            sta   TE_AVBASE+1
            lda   TE_ARGC
            bne   :n1
            lda   #1               ;0 args -> false
            rts
:n1         cmp   #1
            bne   :gen
            lda   #0
            jsr   GETTOK
            ldy   #0
            lda   (PTR1),y
            beq   :n1false
            lda   #0
            rts
:n1false    lda   #1
            rts
:gen        stz   TE_POS
            jsr   OR_EXPR
            cmp   #2
            beq   :ret
            sta   TE_TMPA
            lda   TE_POS
            cmp   TE_ARGC
            beq   :ok
            lda   #2               ;unconsumed trailing token(s)
            rts
:ok         lda   TE_TMPA
:ret        rts

*---------------------------------------------------------------
* OR_EXPR -- `and_expr ( -o and_expr )*`, POSIX/historical
* precedence (loosest -- `-o` binds LAST). IN/OUT: consumes from
* TE_POS onward; A = 0/1/2.
*
* The running left-hand value is kept on the HARDWARE STACK
* (pha/pla), not a shared variable -- AND_EXPR, which this
* routine calls, needs the very same kind of "running value
* across a nested call" slot for its own `-a` chaining, and
* `( )` grouping means OR_EXPR can call itself indirectly
* (PRIMARY -> OR_EXPR) at any depth. A fixed byte clobbers on
* the first nested use (found by check-testev's own 'foo -o ""'
* case going false when a plain shared TE_TMPB was tried); the
* stack gives every active call frame its own slot for free.
*---------------------------------------------------------------
OR_EXPR     jsr   AND_EXPR
            cmp   #2
            beq   :ret
:chk        pha
            jsr   PEEKTOK
            bcs   :done
            jsr   ISDASHO
            bcs   :done
            inc   TE_POS
            jsr   AND_EXPR
            cmp   #2
            beq   :err
            cmp   #0
            beq   :ist
            pla                     ;right false -- keep left
            bra   :chk
:ist        pla                     ;right true -- result true
            lda   #0
            bra   :chk
:done       pla
:ret        rts
:err        pla                     ;balance the stack, then
            lda   #2                ;propagate the syntax error
            rts

*---------------------------------------------------------------
* AND_EXPR -- `not_expr ( -a not_expr )*`, binds tighter than
* `-o`. Same stack-based shape as OR_EXPR, opposite combine
* rule, same reentrancy reason.
*---------------------------------------------------------------
AND_EXPR    jsr   NOT_EXPR
            cmp   #2
            beq   :ret
:chk        pha
            jsr   PEEKTOK
            bcs   :done
            jsr   ISDASHA
            bcs   :done
            inc   TE_POS
            jsr   NOT_EXPR
            cmp   #2
            beq   :err
            cmp   #1
            beq   :isf
            pla                     ;right true -- keep left
            bra   :chk
:isf        pla                     ;right false -- result false
            lda   #1
            bra   :chk
:done       pla
:ret        rts
:err        pla
            lda   #2
            rts

*---------------------------------------------------------------
* NOT_EXPR -- `! not_expr` | primary. Tail-calls both ways (no
* work left to do after either branch returns).
*---------------------------------------------------------------
NOT_EXPR    jsr   PEEKTOK
            bcs   :prim
            jsr   ISBANG
            bcs   :prim
            inc   TE_POS
            jsr   NOT_EXPR
            jmp   NEGATE
:prim       jmp   PRIMARY

*---------------------------------------------------------------
* NEGATE -- IN/OUT A = status. Flips 0<->1; 2 (error) passes
* through -- negating a syntax error is still an error, not a
* truth value.
*---------------------------------------------------------------
NEGATE      cmp   #2
            beq   :done
            eor   #1
:done       rts

*---------------------------------------------------------------
* PRIMARY -- `( expr )` | UOP ARG | ARG BOP ARG | ARG. Advances
* TE_POS by however many tokens it consumes. A = 0/1/2.
*---------------------------------------------------------------
PRIMARY     jsr   PEEKTOK
            bcc   :havetok
            lda   #2                ;primary expected, none left
            rts
:havetok    jsr   ISLPAREN
            bcs   :nop
            inc   TE_POS
            jsr   OR_EXPR
            cmp   #2
            beq   :ret
            sta   TE_TMPA
            jsr   PEEKTOK
            bcs   :bad
            jsr   ISRPAREN
            bcs   :bad
            inc   TE_POS
            lda   TE_TMPA
:ret        rts
:bad        lda   #2                ;missing closing `)`
            rts
:nop        jsr   MATCH_UOP
            bcs   :maybebop
            sta   TE_OPCODE
            lda   TE_POS
            clc
            adc   #1
            cmp   TE_ARGC
            bcs   :bareword          ;no operand left -- degrade
            pha
            clc
            adc   #1
            sta   TE_POS
            pla
            jsr   GETTOK
            lda   TE_OPCODE
            jsr   EVAL_UNARY
            rts
:maybebop   lda   TE_POS
            clc
            adc   #2
            cmp   TE_ARGC
            bcs   :bareword          ;need 2 more toks for a BOP
            lda   TE_POS
            clc
            adc   #1
            jsr   GETTOK
            jsr   MATCH_BOP
            bcs   :bareword
            sta   TE_OPCODE
            lda   TE_POS
            jsr   GETTOK
            lda   PTR1
            sta   TE_LTOK
            lda   PTR1+1
            sta   TE_LTOK+1
            lda   TE_POS
            clc
            adc   #2
            jsr   GETTOK
            lda   PTR1
            sta   TE_RTOK
            lda   PTR1+1
            sta   TE_RTOK+1
            lda   TE_POS
            clc
            adc   #3
            sta   TE_POS
            lda   TE_OPCODE
            jsr   EVAL_BINARY
            rts
:bareword   lda   TE_POS
            jsr   GETTOK
            inc   TE_POS
            ldy   #0
            lda   (PTR1),y
            beq   :bwfalse
            lda   #0
            rts
:bwfalse    lda   #1
            rts

*---------------------------------------------------------------
* PEEKTOK -- IN: TE_POS. OUT: carry CLEAR + PTR1 = tok[TE_POS]
* (via GETTOK) if TE_POS < TE_ARGC; carry SET (no token, PTR1
* untouched) otherwise. Does NOT advance TE_POS.
*---------------------------------------------------------------
PEEKTOK     lda   TE_POS
            cmp   TE_ARGC
            bcs   :none
            jsr   GETTOK
            clc
            rts
:none       sec
            rts

*---------------------------------------------------------------
* EVAL_UNARY -- apply a unary test operator.
* IN:  A = opcode (0=-f 1=-d 2=-e 3=-z 4=-n 5=-s 6=-r 7=-w 8=-x,
*      9..16 = -b -c -g -h -L -p -S -u, always-false), PTR1 =
*      operand. OUT: A = 0/1 (never 2 -- no unary op here can
*      malform).
*---------------------------------------------------------------
EVAL_UNARY  cmp   #9
            bcc   :notf9
            lda   #1                ;no such ProDOS object, ever
            rts
:notf9      cmp   #3
            beq   :strtest
            cmp   #4
            beq   :strtest
            bra   :fileop
:strtest    cmp   #3
            beq   :zcheck
            ldy   #0
            lda   (PTR1),y
            beq   :false2            ;-n on empty
            lda   #0
            rts
:zcheck     ldy   #0
            lda   (PTR1),y
            bne   :false2
            lda   #0                 ;-z on empty
            rts
:false2     lda   #1
            rts
:fileop     sta   TE_OPCODE
            lda   PTR1
            sta   PTR0
            sta   TE_VAL
            lda   PTR1+1
            sta   PTR0+1
            sta   TE_VAL+1
            lda   #<TE_PATHBUF
            sta   PTR1
            lda   #>TE_PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #PCOUNT_GFI        ;the parm block is arena
            sta   TE_GFI             ;storage in sh: set it up
            lda   #<TE_PATHBUF       ;here, every call
            sta   TE_GFI_PATH
            lda   #>TE_PATHBUF
            sta   TE_GFI_PATH+1
            lda   #<TE_GFI
            ldx   #>TE_GFI
            jsr   SC_GFI
            bcs   :notexist
            lda   TE_OPCODE
            cmp   #2
            beq   :true1             ;-e: exists, any type
            cmp   #5
            beq   :sztest
            cmp   #6
            beq   :rtest
            cmp   #7
            beq   :wtest
            cmp   #8
            beq   :xtest
            ;-- else 0 (-f) or 1 (-d) --
            lda   TE_GFI_STYP
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #$0F               ;volume-dir, ls.s's own
            beq   :isdir             ;oddball -- no house const
            lda   TE_OPCODE
            cmp   #0                 ;-f on a non-directory
            beq   :true1
            lda   #1
            rts
:isdir      lda   TE_OPCODE
            cmp   #1                 ;-d on a directory
            beq   :true1
            lda   #1
            rts
:sztest     lda   TE_GFI_BLKS
            ora   TE_GFI_BLKS+1
            beq   :false1
            bra   :true1
:rtest      lda   TE_GFI_ACC
            and   #ACC_READ
            beq   :false1
            bra   :true1
:wtest      lda   TE_GFI_ACC
            and   #ACC_WRITE
            beq   :false1
            bra   :true1
:xtest      lda   TE_GFI_FTYP
            cmp   #FTYPE_SYS
            beq   :true1
            cmp   #FTYPE_BIN
            beq   :true1
            cmp   #FTYPE_TXT         ;a TXT runs if `#!`
            bne   :false1            ;(docs/EXEC-SHEBANG.md)
            jmp   TE_XTXT
:false1     lda   #1
            rts
:true1      lda   #0
            rts
:notexist   lda   #1
            rts

*-- TE_XTXT -- -x on a TXT: true (A=0) iff it starts `#!`, read
*-- through sh's XEC_PEEK, the reader SHEB_FIX uses. A=1 false.
TE_XTXT     lda   TE_VAL
            sta   PTR0
            lda   TE_VAL+1
            sta   PTR0+1
            lda   #<TE_PATHBUF
            sta   PTR1
            lda   #>TE_PATHBUF
            sta   PTR1+1
            lda   #62
            jsr   XEC_PEEK
            bcs   :no
            sta   TE_V2
            cmp   #3
            bcc   :no
            lda   TE_PATHBUF
            and   #$7F
            cmp   #'#'
            bne   :no
            lda   TE_PATHBUF+1
            and   #$7F
            cmp   #'!'
            bne   :no
            ldy   #2                 ;an interpreter follows,
:skip       cpy   TE_V2           ;as SHEB_FIX insists
            bcs   :no
            lda   TE_PATHBUF,y
            and   #$7F
            cmp   #' '
            beq   :nxt
            cmp   #$09
            beq   :nxt
            cmp   #$0D
            beq   :no
            cmp   #$0A
            beq   :no
            lda   #0
            rts
:nxt        iny
            bra   :skip
:no         lda   #1
            rts

*---------------------------------------------------------------
* EVAL_BINARY -- apply a binary test operator.
* IN:  A = opcode (0='=' 1='!=' 2=-eq 3=-ne 4=-lt 5=-gt 6=-le
*      7=-ge), TE_LTOK/TE_RTOK = the two operand pointers.
* OUT: A = 0/1/2. `=`/`!=` are plain STRCMP -- no numeric
*      coercion, same as real /bin/test. The integer ops parse
*      BOTH operands via STR2NUM first; a non-numeric operand
*      on either side is status 2 (see file header, decision 3).
*---------------------------------------------------------------
EVAL_BINARY cmp   #2
            bcs   :numop
            jmp   :streq
:numop      sta   TE_OPCODE
            lda   TE_LTOK
            sta   PTR1
            lda   TE_LTOK+1
            sta   PTR1+1
            jsr   STR2NUM
            bcc   :lok
            jmp   :synerr
:lok        lda   TE_VAL
            sta   TE_LVAL
            lda   TE_VAL+1
            sta   TE_LVAL+1
            lda   TE_RTOK
            sta   PTR1
            lda   TE_RTOK+1
            sta   PTR1+1
            jsr   STR2NUM
            bcc   :rok
            jmp   :synerr
:rok        lda   TE_VAL
            sta   TE_RVAL
            lda   TE_VAL+1
            sta   TE_RVAL+1
            jsr   CMP16
            beq   :releq
            bcs   :relgt
            lda   #REL_LT
            bra   :relgo
:relgt      lda   #REL_GT
            bra   :relgo
:releq      lda   #REL_EQ
:relgo      sta   TE_REL
            lda   TE_OPCODE
            cmp   #2
            beq   :ieq
            cmp   #3
            beq   :ine
            cmp   #4
            beq   :ilt
            cmp   #5
            beq   :igt
            cmp   #6
            beq   :ile
            ;-- else 7 = -ge --
            lda   TE_REL
            cmp   #REL_LT
            beq   :false
            bra   :true
:ieq        lda   TE_REL
            cmp   #REL_EQ
            beq   :true
            bra   :false
:ine        lda   TE_REL
            cmp   #REL_EQ
            beq   :false
            bra   :true
:ilt        lda   TE_REL
            cmp   #REL_LT
            beq   :true
            bra   :false
:igt        lda   TE_REL
            cmp   #REL_GT
            beq   :true
            bra   :false
:ile        lda   TE_REL
            cmp   #REL_GT
            beq   :false
            bra   :true
:streq      sta   TE_OPCODE
            lda   TE_LTOK
            sta   PTR0
            lda   TE_LTOK+1
            sta   PTR0+1
            lda   TE_RTOK
            sta   PTR1
            lda   TE_RTOK+1
            sta   PTR1+1
            jsr   STRCMP
            ldx   TE_OPCODE
            cpx   #0
            beq   :seq
            cmp   #0
            beq   :false
            bra   :true
:seq        cmp   #0
            beq   :true
:false      lda   #1
            rts
:true       lda   #0
            rts
:synerr     lda   #2
            rts

*---------------------------------------------------------------
* CMP16 -- SIGNED 16-bit compare, TE_LVAL vs TE_RVAL (SHIPPED
* 2026-09-17, alongside STR2NUM's sign -- `-eq`/`-lt`/etc. are
* "algebraically equal"/"less than", not unsigned, and STR2NUM
* now returns two's-complement negatives). OUT: Z set iff equal;
* C set iff TE_LVAL >= TE_RVAL (standard 6502 CMP flag
* convention, extended to 16 bits AND to sign).
*
* METHOD: compute L-R as a real 16-bit SBC (so N/V come out of
* actual hardware subtract semantics, not reasoned about by
* hand), then correct N for signed overflow via the classic
* N-xor-V rule: the SBC's own N is the sign of the WRAPPED
* (mod-65536) result, which is only the true sign when the
* subtraction did not overflow a 16-bit signed range; V says
* whether it did, so N^V is the true "result is negative" bit.
* Ends with a real CMP against 0 or 1 so the flags an ordinary
* `rts` hands back to the caller (beq/bcs, as EVAL_BINARY reads
* them) are genuine 6502 flags, not narration.
*
* SCRATCH: reuses TE_V2 (STR2NUM's own *10 scratch, dead once
* STR2NUM returns) and TE_TMPA (PRIMARY's own `(expr)` stash,
* written only strictly AFTER its OR_EXPR call -- including any
* nested CMP16 -- returns) rather than new `ds` bytes: both are
* provably not live while CMP16 runs (EVAL_BINARY calls CMP16
* only after BOTH STR2NUM calls have finished, and before its
* own TE_OPCODE dispatch reads TE_TMPA-adjacent state), and
* check_purity's BIN_DEBT ratchet is exact-equality on this
* file's emitted `ds` total -- adding real bytes here would need
* a bump there for cells that do not actually need one.
*---------------------------------------------------------------
*-- The three names are LABELS on the storage block below, not
*-- `equ` aliases. An `equ` whose operand is a label defined
*-- LATER in the file is a forward EQU reference: merlin32
*-- resolves it, real Merlin-8 and `nas` do not, and `nas` does
*-- it SILENTLY -- it sized `sta CM_TMPLO` as zero page and the
*-- REL link of sh came out 11 bytes short with no diagnostic
*-- (2026-09-17, check-nas-librel). A second label costs nothing
*-- and says the same thing.
CMP16       sec
            lda   TE_LVAL
            sbc   TE_RVAL
            sta   CM_TMPLO
            lda   TE_LVAL+1
            sbc   TE_RVAL+1
            sta   CM_TMPHI         ;N/V now reflect this SBC
            php
            pla
            sta   CM_FLAGS
            lda   CM_TMPLO
            ora   CM_TMPHI
            beq   :iseq
            lda   CM_FLAGS
            and   #$40             ;V flag (bit 6)
            beq   :noflip
            lda   CM_FLAGS
            eor   #$80             ;overflow: true sign is NOT N
            bra   :haven
:noflip     lda   CM_FLAGS
:haven      bmi   :isneg
            lda   #1
            cmp   #0               ;C=1 (L>=R), Z=0 (not equal)
            rts
:isneg      lda   #0
            cmp   #1               ;C=0 (L<R), Z=0
            rts
:iseq       lda   #0
            cmp   #0               ;C=1, Z=1
            rts

*---------------------------------------------------------------
* STR2NUM -- parse a decimal integer, SIGNED (SHIPPED 2026-09-
* 17: an optional leading '-', same as `-eq` et al.'s own
* "n1"/"n2" are conventionally signed decimal integers"). No '+'
* -- not needed by any case here and BSD test doesn't take one
* either (verified live). Magnitude parses exactly as before;
* a negative result is formed by two's-complementing TE_VAL once
* parsing finishes, so the 65535-range/overflow behavior of the
* digit accumulator below is unchanged.
* IN:  PTR1 = NUL-terminated high-bit-ASCII string.
* OUT: carry CLEAR, TE_VAL/TE_VAL+1 = 16-bit value, on success;
* carry SET if the string is empty, is a bare "-", or has any
* non-digit byte (see file header, decision 3).
*
* SCRATCH: TE_NEG aliases TE_REL (CMP16's own relation cell) --
* not live during STR2NUM (CMP16 runs only after STR2NUM
* returns, from EVAL_BINARY), same BIN_DEBT reasoning as CMP16's
* own CM_TMPLO/CM_TMPHI/CM_FLAGS above.
*---------------------------------------------------------------
STR2NUM     stz   TE_VAL
            stz   TE_VAL+1
            stz   TE_NEG
            ldy   #0
            lda   (PTR1),y
            beq   :bad             ;empty string
            cmp   #$AD             ;'-' high-bit-set: a sign
            bne   :loop
            inc   TE_NEG
            iny
            lda   (PTR1),y
            beq   :bad             ;bare "-", no digits follow
:loop       lda   (PTR1),y
            beq   :fin
            cmp   #$B0             ;'0' high-bit-set
            bcc   :bad
            cmp   #$BA             ;past '9'
            bcs   :bad
            and   #$0F             ;digit value 0-9
            pha
            asl   TE_VAL
            rol   TE_VAL+1         ;TE_VAL = orig*2
            lda   TE_VAL
            sta   TE_V2
            lda   TE_VAL+1
            sta   TE_V2+1          ;TE_V2 = orig*2 (saved)
            asl   TE_VAL
            rol   TE_VAL+1         ;orig*4
            asl   TE_VAL
            rol   TE_VAL+1         ;orig*8
            clc
            lda   TE_VAL
            adc   TE_V2
            sta   TE_VAL
            lda   TE_VAL+1
            adc   TE_V2+1
            sta   TE_VAL+1         ;orig*10
            pla
            clc
            adc   TE_VAL
            sta   TE_VAL
            lda   #0
            adc   TE_VAL+1
            sta   TE_VAL+1
            iny
            bne   :loop
            bra   :fin             ;255-byte cap -- string.s's
                                   ;own v1 simplification
:fin        lda   TE_NEG
            beq   :ok
            sec
            lda   #0
            sbc   TE_VAL
            sta   TE_VAL
            lda   #0
            sbc   TE_VAL+1
            sta   TE_VAL+1
:ok         clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* MATCH_UOP -- match a unary test operator.
* IN:  PTR1 = candidate token.
* OUT: carry CLEAR + A = opcode (see EVAL_UNARY's header) on a
* match; carry SET if PTR1 matches none of these.
*---------------------------------------------------------------
MATCH_UOP   ldx   #0
:loop       cpx   #17
            beq   :nomatch
            lda   UOPLO,x
            sta   PTR0
            lda   UOPHI,x
            sta   PTR0+1
            jsr   STRCMP
            cmp   #0
            beq   :found
            inx
            bra   :loop
:found      txa
            clc
            rts
:nomatch    sec
            rts

UOPLO       dfb   <S_DASHF,<S_DASHD,<S_DASHE,<S_DASHZ
            dfb   <S_DASHN,<S_DASHS,<S_DASHR,<S_DASHW
            dfb   <S_DASHX,<S_DASHB,<S_DASHC,<S_DASHG
            dfb   <S_DASHH,<S_DASHL,<S_DASHP,<S_DASHCS
            dfb   <S_DASHU
UOPHI       dfb   >S_DASHF,>S_DASHD,>S_DASHE,>S_DASHZ
            dfb   >S_DASHN,>S_DASHS,>S_DASHR,>S_DASHW
            dfb   >S_DASHX,>S_DASHB,>S_DASHC,>S_DASHG
            dfb   >S_DASHH,>S_DASHL,>S_DASHP,>S_DASHCS
            dfb   >S_DASHU

*---------------------------------------------------------------
* MATCH_BOP -- match a binary test operator.
* IN:  PTR1 = candidate token.
* OUT: carry CLEAR + A = opcode (0='=' 1='!=' 2=-eq 3=-ne
*      4=-lt 5=-gt 6=-le 7=-ge) on a match; carry SET if PTR1
*      matches none of these.
*---------------------------------------------------------------
MATCH_BOP   ldx   #0
:loop       cpx   #8
            beq   :nomatch
            lda   BOPLO,x
            sta   PTR0
            lda   BOPHI,x
            sta   PTR0+1
            jsr   STRCMP
            cmp   #0
            beq   :found
            inx
            bra   :loop
:found      txa
            clc
            rts
:nomatch    sec
            rts

BOPLO       dfb   <S_EQ,<S_NE,<S_EQOP,<S_NEOP
            dfb   <S_LT,<S_GT,<S_LE,<S_GE
BOPHI       dfb   >S_EQ,>S_NE,>S_EQOP,>S_NEOP
            dfb   >S_LT,>S_GT,>S_LE,>S_GE

*---------------------------------------------------------------
* ISBANG -- IN PTR1 = token. OUT: carry CLEAR if the token is
* exactly "!" (negation); carry SET otherwise. Matches
* GLOBMATCH's own clear-on-match convention.
*---------------------------------------------------------------
ISBANG      ldy   #0
            lda   (PTR1),y
            cmp   #$A1              ;'!' high-bit-set
            bne   :no
            iny
            lda   (PTR1),y
            bne   :no
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* ISLPAREN/ISRPAREN -- IN PTR1 = token. OUT: carry CLEAR if the
* token is exactly "(" / ")"; carry SET otherwise. Same
* hand-rolled shape as ISBANG (cheaper than a generic STRCMP
* call for a fixed one-byte token).
*---------------------------------------------------------------
ISLPAREN    ldy   #0
            lda   (PTR1),y
            cmp   #$A8              ;'(' high-bit-set
            bne   :no
            iny
            lda   (PTR1),y
            bne   :no
            clc
            rts
:no         sec
            rts

ISRPAREN    ldy   #0
            lda   (PTR1),y
            cmp   #$A9              ;')' high-bit-set
            bne   :no
            iny
            lda   (PTR1),y
            bne   :no
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* ISDASHA/ISDASHO -- IN PTR1 = token. OUT: carry CLEAR if the
* token is exactly "-a" / "-o"; carry SET otherwise. Same
* hand-rolled shape as ISBANG.
*---------------------------------------------------------------
ISDASHA     ldy   #0
            lda   (PTR1),y
            cmp   #$AD              ;'-' high-bit-set
            bne   :no
            iny
            lda   (PTR1),y
            cmp   #$E1              ;'a' high-bit-set
            bne   :no
            iny
            lda   (PTR1),y
            bne   :no
            clc
            rts
:no         sec
            rts

ISDASHO     ldy   #0
            lda   (PTR1),y
            cmp   #$AD              ;'-' high-bit-set
            bne   :no
            iny
            lda   (PTR1),y
            cmp   #$EF              ;'o' high-bit-set
            bne   :no
            iny
            lda   (PTR1),y
            bne   :no
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* GETTOK -- fetch a token pointer from the caller's argv array.
* IN:  A = token index (0-based).
* OUT: PTR1 = pointer to that token's NUL-terminated high-bit
*      string. CLOBBERS: A, Y, PTR0.
*
* PTR0 is reloaded from TE_AVBASE every call rather than kept
* live, because indirect-Y addressing needs a ZERO-PAGE
* pointer and PTR0-2 are liba's only zero-page slots (zp.equ)
* -- there is nowhere else to hold "the array" AND dereference
* it at once, so the array's home is TE_AVBASE (ordinary
* memory) and PTR0 is just scratch, same as everywhere else.
*---------------------------------------------------------------
GETTOK      asl   a
            tay
            lda   TE_AVBASE
            sta   PTR0
            lda   TE_AVBASE+1
            sta   PTR0+1
            lda   (PTR0),y
            sta   PTR1
            iny
            lda   (PTR0),y
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* Operator literal strings -- high-bit ASCII, NUL-terminated,
* same convention as every liba string (docs/USERLAND.md).
*---------------------------------------------------------------
S_DASHF     asc   "-f"
            dfb   0
S_DASHD     asc   "-d"
            dfb   0
S_DASHE     asc   "-e"
            dfb   0
S_DASHZ     asc   "-z"
            dfb   0
S_DASHN     asc   "-n"
            dfb   0
S_DASHS     asc   "-s"
            dfb   0
S_DASHR     asc   "-r"
            dfb   0
S_DASHW     asc   "-w"
            dfb   0
S_DASHX     asc   "-x"
            dfb   0
S_DASHB     asc   "-b"
            dfb   0
S_DASHC     asc   "-c"
            dfb   0
S_DASHG     asc   "-g"
            dfb   0
S_DASHH     asc   "-h"
            dfb   0
S_DASHL     asc   "-L"
            dfb   0
S_DASHP     asc   "-p"
            dfb   0
S_DASHCS    asc   "-S"
            dfb   0
S_DASHU     asc   "-u"
            dfb   0
S_EQ        asc   "="
            dfb   0
S_NE        asc   "!="
            dfb   0
S_EQOP      asc   "-eq"
            dfb   0
S_NEOP      asc   "-ne"
            dfb   0
S_LT        asc   "-lt"
            dfb   0
S_GT        asc   "-gt"
            dfb   0
S_LE        asc   "-le"
            dfb   0
S_GE        asc   "-ge"
            dfb   0

