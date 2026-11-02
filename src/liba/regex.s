*---------------------------------------------------------------
* regex.s -- the Thompson-subset BRE matcher (operator's g/re/p
* ruling, task: "Build maux's ed"). Lives in src/liba, NOT
* inside ed -- so grep can later be extracted standalone against
* the same engine, as history did it (V6/V7 ed and grep share
* one compiled-regexp core).
* Full design notes: L.REGEX.TXT (docs/a2/)
*
* FIRST HALF of a two-file split (regex.s + regex2.s) made
* 2026-09-02 when grouping/backref growth pushed the single file
* over BOTH self-hosting source-window budgets (check_librel.py:
* resident + largest put > 41215; build_librelas_image.py: as's
* window > 16126). Split at the RE_ATOM_PARSE global boundary --
* RE_MATCHSTAR's last `rts` falls through to nothing, so no
* label crosses mid-routine. This half: RE_MATCH (top-level
* entry), RE_MATCHHERE, RE_MATCHSTAR (backtracking star, and
* since W5b -- docs/ANACHRONISMS.md, 2026-09-08 -- the BRE
* intervals \{n,m\} \+ \? as a floor/ceiling on the same
* loop), RE_REPOP/RE_RDNUM (the repetition-operator decoder).
* regex2.s continues with RE_ATOM_PARSE onward -- atom decode,
* character-class test, \( \) group numbering, group-repeat
* backtracking (RE_GSTAR/RE_GSSAVE), \1-\9 backreference match.
* Every `put` of this file is IMMEDIATELY followed by `put
* ../liba/regex2.s` -- see that file's own header. The RE_*
* zero-page equates both halves need moved to src/liba/
* regex.equ 2026-09-02 (same split, same reason as this file);
* `put` it BEFORE this file.
*---------------------------------------------------------------

* See L.REGEX.TXT: "REMATCH -- search a line for"
*-- PHX/:rgrst/PLX (W5): prime every group as "never
*-- captured" (RE_GRPST's hi byte = $FF, the sentinel
*-- RE_BKMATCH checks) so a \N with no \(...\) earlier in
*-- THIS pattern -- or stale state from a PREVIOUS call --
*-- fails safely instead of matching leftover garbage. X is
*-- the loop var; PHX/PLX bracket the whole routine so a
*-- pattern with no group at all is byte-for-byte the same
*-- CALLER-VISIBLE contract as before this feature (X was
*-- never touched here previously, so callers may depend on
*-- it surviving).
RE_MATCH    phx
            ldx   #16
:rgrst      lda   #$FF
            sta   RE_GRPST+1,x
            dex
            dex
            bpl   :rgrst

*-- (W5d) One walk of the pattern: RE_PATEND = its NUL, and
*-- RE_LONGEST = 1 if it holds a \( -- a repeated or optional
*-- GROUP after a repeat is the one BRE shape where the first
*-- greedy success is not the longest (x*\(xy\)* on xxy: greedy
*-- gives xx, POSIX wants xxy). Every other pattern keeps the
*-- first-success path, byte for byte the old engine. Patterns
*-- are under 256 bytes (every consumer's buffer is), so Y
*-- indexes the walk.
            stz   RE_LONGEST
            stz   RE_GSACT
            ldy   #0
:pscan      lda   (PTR1),y
            beq   :pend
            cmp   #"\"
            bne   :pnext
            iny
            lda   (PTR1),y
            beq   :pend
            cmp   #"("
            bne   :pnext
            lda   #1
            sta   RE_LONGEST
:pnext      iny
            bne   :pscan
            dey                      ;256th byte: treat as end
:pend       tya
            clc
            adc   PTR1
            sta   RE_PATEND
            lda   PTR1+1
            adc   #0
            sta   RE_PATEND+1

            ldy   #0
            lda   (PTR1),y
            cmp   #"^"
            bne   :noanchor

            ;anchored: the ONLY legal attempt is at the true
            ;line start,
            ;and only if the caller's search-from position IS
            ;that start.
            lda   PTR2
            cmp   PTR0
            bne   :anchorno
            lda   PTR2+1
            cmp   PTR0+1
            bne   :anchorno
            clc
            lda   PTR1
            adc   #1
            sta   RE_REP
            lda   PTR1+1
            adc   #0
            sta   RE_REP+1
            lda   PTR2
            sta   RE_RET
            lda   PTR2+1
            sta   RE_RET+1
            stz   RE_BESTSET
            jsr   RE_MATCHHERE
            bcs   :anchhit
            jsr   RE_TAKEBEST        ;longest mode: a recorded
            bcc   :anchorno          ;end counts as the hit
:anchhit    lda   PTR2
            sta   RE_MSTART
            lda   PTR2+1
            sta   RE_MSTART+1
            lda   RE_RET
            sta   RE_MEND
            lda   RE_RET+1
            sta   RE_MEND+1
            clc
            plx
            rts
:anchorno   sec
            plx
            rts

:noanchor   lda   PTR2
            sta   RE_SCANPOS
            lda   PTR2+1
            sta   RE_SCANPOS+1
:tryloop    lda   PTR1
            sta   RE_REP
            lda   PTR1+1
            sta   RE_REP+1
            lda   RE_SCANPOS
            sta   RE_RET
            lda   RE_SCANPOS+1
            sta   RE_RET+1
            stz   RE_BESTSET
            jsr   RE_MATCHHERE
            bcs   :tryhit
            jsr   RE_TAKEBEST
            bcc   :trynext
:tryhit     lda   RE_SCANPOS
            sta   RE_MSTART
            lda   RE_SCANPOS+1
            sta   RE_MSTART+1
            lda   RE_RET
            sta   RE_MEND
            lda   RE_RET+1
            sta   RE_MEND+1
            clc
            plx
            rts
:trynext    ldy   #0
            lda   (RE_SCANPOS),y
            beq   :nomatch          ;just tried at the NUL -- no
                                    ;more room
            inc   RE_SCANPOS
            bne   :tryloop
            inc   RE_SCANPOS+1
            bra   :tryloop
:nomatch    sec
            plx
            rts

*---------------------------------------------------------------
* RE_TAKEBEST -- (W5d) after a first-success walk came back
* empty: if longest mode recorded an end, make it THE match --
* RE_RET = RE_BEST, captures restored from the snapshot -- and
* return carry set. Carry clear = nothing recorded.
* RE_RECBEST -- the leaf's side: RE_RET is a complete match's
* end; keep it if it is the first or beats RE_BEST, snapshotting
* the capture registers with it. Clobbers A, X.
*---------------------------------------------------------------
RE_TAKEBEST lda   RE_BESTSET
            beq   :none
            lda   RE_BEST
            sta   RE_RET
            lda   RE_BEST+1
            sta   RE_RET+1
            ldx   #17
:rst        lda   RE_BGRPST,x
            sta   RE_GRPST,x
            lda   RE_BGRPEND,x
            sta   RE_GRPEND,x
            dex
            bpl   :rst
            sec
            rts
:none       clc
            rts

RE_RECBEST  lda   RE_BESTSET
            beq   :take
            lda   RE_BEST            ;keep only a LONGER end --
            cmp   RE_RET             ;equal keeps the first one
            lda   RE_BEST+1          ;(greedy order, which is
            sbc   RE_RET+1           ;the leftmost-subexpression
            bcs   :keep              ;order POSIX asks for)
:take       lda   #1
            sta   RE_BESTSET
            lda   RE_RET
            sta   RE_BEST
            lda   RE_RET+1
            sta   RE_BEST+1
            ldx   #17
:snap       lda   RE_GRPST,x
            sta   RE_BGRPST,x
            lda   RE_GRPEND,x
            sta   RE_BGRPEND,x
            dex
            bpl   :snap
:keep       rts

* See L.REGEX.TXT: "REMATCHHERE -- try to match starting"
RE_MATCHHERE
:loop       ldy   #0
            lda   (RE_REP),y
            bne   :chkdlr            ;pattern exhausted --
            jmp   :success           ;matched (JMP: the \(\)\N
                                     ;block between here and
                                     ;:success puts it out of a
                                     ;BEQ's branch range)
:chkdlr     cmp   #"$"
            bne   :notdollar
            ldy   #1
            lda   (RE_REP),y
            beq   :dlrlast           ;the LAST char: anchor
            cmp   #"\"               ;(W5d) `$` right before a
            bne   :notdollar         ;\) anchors too (both hosts
            iny                      ;agree; POSIX leaves it
            lda   (RE_REP),y         ;open) -- else literal
            cmp   #")"
            bne   :notdollar
            ldy   #0
            lda   (RE_RET),y
            bne   :dlrfail
            inc   RE_REP             ;skip the `$`, go on to
            bne   :loop              ;the \)
            inc   RE_REP+1
            bra   :loop
:dlrlast    ldy   #0
            lda   (RE_RET),y
            bne   :dlrfail           ;anchor: only ok at end of
                                     ;text -- JMP not BRA/BEQ
                                     ;below: the \(\)\N block
                                     ;puts :fail/:success out
                                     ;of 8-bit branch range
            inc   RE_REP             ;REP at the NUL, so the
            bne   :dlrsucc           ;:success leaf can tell the
            inc   RE_REP+1           ;real pattern end
:dlrsucc    jmp   :success
:dlrfail    jmp   :fail

:notdollar  jsr   RE_ATOM_PARSE
            lda   RE_AKIND
            cmp   #3
            bne   :notmal
            jmp   :fail              ;malformed [...] -- safe
                                     ;no-match
:notmal
            cmp   #4
            bne   :notgo
            jmp   :gopen
:notgo      cmp   #5
            bne   :notgc
            jmp   :gclose
:notgc      cmp   #6
            bne   :notbk
            jmp   :backref
:notbk

*-- Repetition operator after the atom? `*` as always, and
*-- (W5b) the BRE interval family \+ \? \{n\} \{n,\} \{n,m\}.
*-- RE_REPOP decodes whichever is there into RE_RMIN/RMAX/
*-- RINF and steps RE_NEWREP past it; a bare `*` yields the
*-- SAME state a star always meant (floor 0, no ceiling), so
*-- RE_MATCHSTAR's plain-star path is what it was before.
            jsr   RE_REPOP
            bcc   :nostar
            lda   RE_AKIND
            cmp   #3
            bne   :starjmp
            jmp   :fail              ;malformed \{ -- safe
                                     ;no-match, like a bad [...]
:starjmp    jmp   RE_MATCHSTAR       ;tail call -- its result IS
                                     ;our result

:nostar     ldy   #0
            lda   (RE_RET),y
            bne   :nsgo              ;text exhausted, atom needs
            jmp   :fail              ;one char
:nsgo       jsr   RE_ATOM_TEST
            bcs   :nsok
            jmp   :fail
:nsok       lda   RE_NEWREP
            sta   RE_REP
            lda   RE_NEWREP+1
            sta   RE_REP+1
            inc   RE_RET
            bne   :nsloop
            inc   RE_RET+1
:nsloop     jmp   :loop              ;(W5d) the `$` block above
                                     ;grew past a branch's reach

*-- \( ... \) group markers (W5). NON-CONSUMING: RE_RET is
*-- untouched and the SAME :loop continues, exactly like the
*-- $-at-end special case above -- so a plain (unstarred)
*-- group needs no recursion, just two markers that record a
*-- text position and fall through. Group NUMBER is computed
*-- FRESH every time (RE_GROUPNUM), never kept as running
*-- state: a starred atom's backtrack re-enters RE_MATCHHERE
*-- from a DIFFERENT invocation per retry (RE_MATCHSTAR's
*-- :backtrack), and any stack-based "currently open group"
*-- bookkeeping would not survive that split.
*--
*-- RE_GMARK/RE_GS are BOTH saved here, immediately, before
*-- RE_FINDCLOS or RE_GROUPNUM run a single step -- both call
*-- RE_ATOM_PARSE repeatedly as their own internal walk, which
*-- overwrites RE_NEWREP (and RE_REP) on every step. The first
*-- version of this code read RE_NEWREP back AFTER those calls
*-- and got whatever their LAST internal atom left there --
*-- measured 2026-09-02 as a real bug (check-e2e cases 111-113:
*-- every \(\)\N pattern matched nothing at all).
:gopen      lda   RE_REP             ;\('s OWN position --
            sta   RE_GMARK           ;RE_GROUPNUM's target
            lda   RE_REP+1
            sta   RE_GMARK+1
            lda   RE_NEWREP          ;GS, content start -- where
            sta   RE_GS              ;:gonum0/:gostar resume
            lda   RE_NEWREP+1
            sta   RE_GS+1
            jsr   RE_FINDCLOS        ;-> RE_GE = matching \)
            bcs   :gopok             ;unbalanced \( -- malformed
            jmp   :fail
*-- (W5b) a \(...\) group takes the same operator family a
*-- single atom does: RE_REPOP looks just past the \) and, if
*-- it finds one, RE_GSTAR runs the group with that floor and
*-- ceiling (a bare `*` decodes to the star it always was).
:gopok      clc
            lda   RE_GE
            adc   #2
            sta   RE_NEWREP          ;just past the \)
            lda   RE_GE+1
            adc   #0
            sta   RE_NEWREP+1
            jsr   RE_REPOP
            bcs   :gostar
            lda   RE_GMARK
            sta   RE_REP
            lda   RE_GMARK+1
            sta   RE_REP+1
            lda   #4
            jsr   RE_GROUPNUM        ;-> A = this group's # (0
                                     ;= untracked, >9)
            beq   :gonum0
            sec
            sbc   #1
            asl
            tax
            lda   RE_RET
            sta   RE_GRPST,x
            lda   RE_RET+1
            sta   RE_GRPST+1,x
:gonum0     ldy   #0                 ;(W5d) `^` right after the
            lda   (RE_GS),y          ;\( anchors (both hosts do;
            cmp   #"^"               ;POSIX leaves it open)
            bne   :gsplain
            lda   RE_RET
            cmp   PTR0
            bne   :gsanch
            lda   RE_RET+1
            cmp   PTR0+1
            bne   :gsanch
            inc   RE_GS              ;at line start: skip it
            bne   :gsplain
            inc   RE_GS+1
:gsplain    lda   RE_GS
            sta   RE_REP
            lda   RE_GS+1
            sta   RE_REP+1
            jmp   :loop
:gsanch     jmp   :fail
:gostar     lda   RE_AKIND
            cmp   #3
            bne   :gosok
            jmp   :fail              ;malformed \{ after the \)
:gosok      lda   RE_NEWREP          ;GCONT = past the operator,
            sta   RE_GCONT           ;taken NOW -- RE_GROUPNUM's
            lda   RE_NEWREP+1        ;own RE_ATOM_PARSE calls
            sta   RE_GCONT+1         ;clobber RE_NEWREP
            lda   RE_GMARK
            sta   RE_REP
            lda   RE_GMARK+1
            sta   RE_REP+1
            lda   #4
            jsr   RE_GROUPNUM
            sta   RE_GNUM            ;RE_GS already holds the
                                     ;content start, saved above
            jmp   RE_GSTAR           ;tail call -- its result IS
                                     ;our result

:gclose     lda   RE_NEWREP          ;past \) -- saved before
            sta   RE_GMARK           ;RE_GROUPNUM's own
            lda   RE_NEWREP+1        ;RE_ATOM_PARSE calls
            sta   RE_GMARK+1         ;clobber RE_NEWREP
            lda   #5
            jsr   RE_GROUPNUM
            beq   :gcnum0
            sec
            sbc   #1
            asl
            tax
            lda   RE_RET
            sta   RE_GRPEND,x
            lda   RE_RET+1
            sta   RE_GRPEND+1,x
:gcnum0     lda   RE_GMARK
            sta   RE_REP
            lda   RE_GMARK+1
            sta   RE_REP+1
            jmp   :loop

*-- \1-\9 backreference (W5). CONSUMES text: RE_BKMATCH
*-- compares the captured group against RE_RET and advances
*-- it on success -- see that routine's own header.
:backref    lda   RE_ACHAR
            jsr   RE_BKMATCH
            bcc   :fail
            lda   RE_NEWREP
            sta   RE_REP
            lda   RE_NEWREP+1
            sta   RE_REP+1
            jmp   :loop

*-- (W5d) The leaf. In longest mode a COMPLETE match (REP at
*-- the pattern's own NUL, not the temporary one RE_GSTAR
*-- plants inside a group) is RECORDED and then reported as a
*-- failure, so every caller keeps backtracking and every
*-- alternative gets its turn; RE_MATCH takes the longest at
*-- the end. A bounded sub-match keeps its real success.
:success    lda   RE_LONGEST
            beq   :succ
            lda   RE_REP
            cmp   RE_PATEND
            bne   :succ
            lda   RE_REP+1
            cmp   RE_PATEND+1
            bne   :succ
            jsr   RE_RECBEST
            clc
            rts
:succ       sec
            rts
:fail       clc
            rts

*---------------------------------------------------------------
* RE_MATCHSTAR -- greedy repetition match with backtrack: `*`,
* and (W5b) the BRE intervals \{n,m\} / \+ / \?. Entered by a
* tail JMP from RE_MATCHHERE with the atom descriptor already in
* RE_AKIND/ACHAR/ANEG/ACLS/ACLSEND, the floor/ceiling RE_REPOP
* decoded in RE_RMIN/RE_RMAX/RE_RINF, the continuation pattern
* pointer (just past the operator) in RE_NEWREP, and the text
* position where the repeated atom begins in RE_RET.
* OUT: carry set, RE_RET = ptr just past the match -- carry
* clear = fail.
*
* HOW THE INTERVAL GENERALISES THE STAR (the brief's one open
* question, answered by building it): the backtrack loop below
* already walks RE_TRYPTR DOWN from the greedy end to a FLOOR
* pointer, RE_STARTTXT, which for a star is the text position
* where the atom began (0 reps). An interval only moves that
* floor: the counted scan (:gcount) records the position just
* past the RE_RMIN-th rep INTO RE_STARTTXT as it goes, and the
* backtrack loop needs no change at all. The ceiling lives
* entirely inside the greedy scan (stop growing at RE_RMAX
* reps). So the state saved across the recursive RE_MATCHHERE
* call is EXACTLY what it was -- RE_RMIN/RMAX/RINF/RCNT are
* consumed before the first recursion and never restored.
*---------------------------------------------------------------
RE_MATCHSTAR
            lda   RE_NEWREP
            sta   RE_CONTPAT
            lda   RE_NEWREP+1
            sta   RE_CONTPAT+1
            lda   RE_RET
            sta   RE_STARTTXT
            sta   RE_SCAN
            lda   RE_RET+1
            sta   RE_STARTTXT+1
            sta   RE_SCAN+1
            stz   RE_RCNT

*-- The greedy scan, specialized by the star atom's KIND
*-- (2026-08-28, measured: the general jsr-RE_ATOM_TEST-per-
*-- character loop plus the test itself was ~10% of the whole
*-- self-hosting strip). A LITERAL star atom's scan is a bare
*-- compare loop; a DOT's is a scan to the NUL (dot matches any
*-- nonzero byte -- RE_ATOM_TEST's own :isdot says exactly
*-- that); only a CLASS atom still pays the general call. All
*-- three advance RE_SCAN identically, so :greedydone and the
*-- backtrack machinery see no difference.
*-- (W5b) A plain star -- floor 0, no ceiling -- takes these
*-- UNCHANGED loops; anything with a floor or a ceiling takes
*-- the counted scan at :gcount instead. That is the strict-
*-- superset argument in one branch: a pattern without the new
*-- operators never executes a new instruction here.
            lda   RE_RINF
            beq   :gcount            ;a ceiling
            lda   RE_RMIN
            bne   :gcount            ;a floor
            ldy   #0
            lda   RE_AKIND
            beq   :glit              ;0 = literal
            cmp   #1
            beq   :gdot              ;1 = dot
:greedy     ldy   #0                 ;RE_ATOM_TEST's class walk
                                     ;clobbers Y -- reload per
                                     ;iteration (the specialized
                                     ;loops below never call it,
                                     ;so their Y stays 0)
            lda   (RE_SCAN),y
            beq   :greedydone
            jsr   RE_ATOM_TEST
            bcc   :greedydone
            inc   RE_SCAN
            bne   :greedy
            inc   RE_SCAN+1
            bra   :greedy
:glit       lda   (RE_SCAN),y
            beq   :greedydone        ;NUL ends text (a literal
                                     ;atom never matches NUL)
            cmp   RE_ACHAR
            bne   :greedydone
            inc   RE_SCAN
            bne   :glit
            inc   RE_SCAN+1
            bra   :glit
:gdot       lda   (RE_SCAN),y
            beq   :greedydone        ;dot matches ANY nonzero
            inc   RE_SCAN
            bne   :gdot
            inc   RE_SCAN+1
            bra   :gdot

*-- (W5b) The counted scan: the general per-character test,
*-- stopping at the ceiling, and moving the backtrack floor to
*-- the RE_RMIN-th rep as it passes it. RE_RCNT saturates at
*-- 255 so an unbounded floor on a >255-byte run cannot wrap
*-- and re-fire the floor store (RE_DUP_MAX is 255; every
*-- consumer's line is at most that long anyway).
:gcount     lda   RE_RINF
            bne   :gcgo
            lda   RE_RCNT
            cmp   RE_RMAX
            bcs   :greedydone        ;at the ceiling
:gcgo       ldy   #0
            lda   (RE_SCAN),y
            beq   :greedydone
            jsr   RE_ATOM_TEST
            bcc   :greedydone
            inc   RE_SCAN
            bne   :gcnt
            inc   RE_SCAN+1
:gcnt       lda   RE_RCNT
            cmp   #$FF
            beq   :gcount            ;saturated
            inc   RE_RCNT
            lda   RE_RCNT
            cmp   RE_RMIN
            bne   :gcount
            lda   RE_SCAN            ;the floor: just past the
            sta   RE_STARTTXT        ;RE_RMIN-th rep
            lda   RE_SCAN+1
            sta   RE_STARTTXT+1
            bra   :gcount

:greedydone lda   RE_RCNT
            cmp   RE_RMIN
            bcs   :floorok
            clc                      ;fewer reps than the floor
            rts
:floorok    lda   RE_SCAN
            sta   RE_TRYPTR
            lda   RE_SCAN+1
            sta   RE_TRYPTR+1

*-- Star-before-disjoint-atom fast path (docs/PERF-PLAN.md step
*-- 2). If the atom AFTER the star is an UNSTARRED LITERAL that
*-- the star's own atom cannot match, the longest greedy run is
*-- the only candidate: every shorter TRYPTR would put that
*-- literal on a character the star atom just matched (that is
*-- what the greedy scan proved about those positions), where it
*-- must fail -- in `s/^ *;.*//` the ';' can only ever sit
*-- immediately past the LONGEST run of spaces. So try the
*-- longest once, as a tail call, and let its result be the
*-- star's result -- no backtrack loop, no 13-byte save/restore.
*-- CONSERVATIVE by construction: any other continuation shape
*-- (empty, '.', '[...]', an escaped-NUL edge, a starred atom,
*-- or a literal the star CAN match) falls through to :backtrack
*-- exactly as before. The star's atom descriptor is still
*-- loaded here (the greedy scan just used it), which is what
*-- makes the one-call disjointness test (RE_ATOM_TEST on the
*-- continuation's literal) free of any re-parse. Teeth:
*-- check-e2e's `grep a*al` case exists precisely because a
*-- sabotage of this guard (fast path taken UNCONDITIONALLY)
*-- passed check-sed AND check-ed (2026-08-28).
            ldy   #0
            lda   (RE_CONTPAT),y
            beq   :backtrack         ;empty continuation
            cmp   #"."
            beq   :backtrack         ;dot matches anything
            cmp   #"["
            beq   :backtrack         ;class: not analyzed
            cmp   #"\"
            bne   :djlit1
            ldy   #1                 ;escaped literal: the char
            lda   (RE_CONTPAT),y     ;is byte 1, atom is 2 wide
            beq   :backtrack         ;lone trailing backslash
            cmp   #"("               ;(W5d) a group marker or a
            beq   :backtrack         ;backref is NOT a literal:
            cmp   #")"               ;the inference below does
            beq   :backtrack         ;not hold -- full backtrack
            cmp   #"1"               ;(docs/REGEX-FASTPATH-
            bcc   :djesc             ;GROUP.md: [ab]*\(b\) on ab
            cmp   #":"               ;missed)
            bcc   :backtrack
:djesc      cmp   #"n"               ;\n is the newline byte,
            bne   :djesc2            ;not an 'n' -- test THAT
            lda   #$8D
:djesc2     iny
            bra   :djhave
:djlit1     ldy   #1                 ;plain literal, atom 1 wide
:djhave     sta   RE_TESTCH          ;park the literal (also
                                     ;RE_ATOM_TEST's input cell)
            lda   (RE_CONTPAT),y
            cmp   #"*"
            beq   :backtrack         ;starred continuation can
                                     ;match zero -- no inference
            cmp   #"\"
            bne   :djnobs
            iny                      ;(W5b) so can a literal
            lda   (RE_CONTPAT),y     ;under \? or \{0,..\} --
            cmp   #"?"               ;the same zero-reps hole
            beq   :backtrack         ;(\+ needs one, and keeps
            cmp   #$FB               ;the inference) -- $FB is
            beq   :backtrack         ;"{" high-bit, as every
                                     ;"x" literal here is:
                                     ;merlin32 cannot quote a
                                     ;brace
:djnobs     lda   RE_TESTCH
            jsr   RE_ATOM_TEST       ;can the STAR's atom match
            bcs   :backtrack         ;it? then shorter runs can
                                     ;still succeed -- backtrack
            lda   RE_CONTPAT         ;disjoint: single candidate
            sta   RE_REP
            lda   RE_CONTPAT+1
            sta   RE_REP+1
            lda   RE_TRYPTR
            sta   RE_RET
            lda   RE_TRYPTR+1
            sta   RE_RET+1
            jmp   RE_MATCHHERE       ;tail call -- carry and
                                     ;are exactly this routine's
                                     ;own OUT contract

:backtrack  lda   RE_AKIND
            pha
            lda   RE_ACHAR
            pha
            lda   RE_ANEG
            pha
            lda   RE_ACLS
            pha
            lda   RE_ACLS+1
            pha
            lda   RE_ACLSEND
            pha
            lda   RE_ACLSEND+1
            pha
            lda   RE_CONTPAT
            pha
            lda   RE_CONTPAT+1
            pha
            lda   RE_TRYPTR
            pha
            lda   RE_TRYPTR+1
            pha
            lda   RE_STARTTXT
            pha
            lda   RE_STARTTXT+1
            pha

            lda   RE_CONTPAT
            sta   RE_REP
            lda   RE_CONTPAT+1
            sta   RE_REP+1
            lda   RE_TRYPTR
            sta   RE_RET
            lda   RE_TRYPTR+1
            sta   RE_RET+1
            jsr   RE_MATCHHERE       ;carry = result; PLA/PLA
                                     ;below never touch the
                                     ;carry flag on 6502

            pla
            sta   RE_STARTTXT+1
            pla
            sta   RE_STARTTXT
            pla
            sta   RE_TRYPTR+1
            pla
            sta   RE_TRYPTR
            pla
            sta   RE_CONTPAT+1
            pla
            sta   RE_CONTPAT
            pla
            sta   RE_ACLSEND+1
            pla
            sta   RE_ACLSEND
            pla
            sta   RE_ACLS+1
            pla
            sta   RE_ACLS
            pla
            sta   RE_ANEG
            pla
            sta   RE_ACHAR
            pla
            sta   RE_AKIND
            bcs   :success           ;RE_RET is RE_MATCHHERE's
                                     ;own output, untouched by
                                     ;the PLAs above

            lda   RE_TRYPTR
            cmp   RE_STARTTXT
            bne   :decr
            lda   RE_TRYPTR+1
            cmp   RE_STARTTXT+1
            bne   :decr
            clc                      ;just tried the zero-repeat
                                     ;case -- done
            rts
:decr       lda   RE_TRYPTR
            bne   :nb
            dec   RE_TRYPTR+1
:nb         dec   RE_TRYPTR
            bra   :backtrack
:success    sec
            rts

*---------------------------------------------------------------
* RE_REPOP -- is there a repetition operator at RE_NEWREP (just
* past the atom RE_ATOM_PARSE decoded, or just past a \) )?
* `*`, and (W5b, docs/ANACHRONISMS.md) the BRE interval family:
* \+ (1 or more), \? (0 or 1), \{n\}, \{n,\}, \{n,m\}.
* OUT: carry clear = none (nothing touched). Carry set =
* RE_RMIN/RE_RMAX/RE_RINF set (RINF nonzero = no ceiling, RMAX
* then unread) and RE_NEWREP advanced past the operator -- or,
* for a malformed \{ (no digits, a bound over RE_DUP_MAX = 255,
* m < n, no closing \}), RE_AKIND = 3, the same safe no-match a
* malformed [...] already gets; callers check that first.
* BRE spelling both ways: a bare `{`, `+` or `?` never reaches
* here as an operator -- RE_ATOM_PARSE hands each over as a
* literal atom exactly as before -- and this routine looks only
* for the BACKSLASH forms. Uses only Y and A beyond the OUT
* cells (RE_RDNUM: X, RE_TMP/RE_TMP2).
*---------------------------------------------------------------
RE_REPOP    ldy   #0
            lda   (RE_NEWREP),y
            cmp   #"*"
            bne   :notstar
            lda   #0
            sta   RE_RMIN
            lda   #1
            sta   RE_RINF
            iny
            bra   :adv
:notstar    cmp   #"\"
            bne   :none
            iny
            lda   (RE_NEWREP),y
            cmp   #"+"
            bne   :notplus
            lda   #1
            sta   RE_RMIN
            sta   RE_RINF
            iny
            bra   :adv
:notplus    cmp   #"?"
            bne   :notqm
            lda   #0
            sta   RE_RMIN
            sta   RE_RINF
            lda   #1
            sta   RE_RMAX
            iny
            bra   :adv
:notqm      cmp   #$FB               ;"{" -- high-bit ASCII,
                                     ;as "x" assembles to
                                     ;(merlin32 cannot quote a
                                     ;brace or a comma)
            beq   :intv
:none       clc
            rts

:intv       iny
            jsr   RE_RDNUM           ;n -> A, X = digit count
            bcs   :bad
            cpx   #0
            beq   :bad               ;\{,m\} / \{\}: n required
            sta   RE_RMIN
            sta   RE_RMAX            ;\{n\}: exactly n
            lda   #0
            sta   RE_RINF
            lda   (RE_NEWREP),y
            cmp   #$AC               ;"," high-bit
            bne   :close
            iny
            lda   (RE_NEWREP),y
            cmp   #"\"
            bne   :rdmax
            lda   #1                 ;\{n,\}: no ceiling
            sta   RE_RINF
            bra   :close
:rdmax      jsr   RE_RDNUM
            bcs   :bad
            cpx   #0
            beq   :bad
            cmp   RE_RMIN
            bcc   :bad               ;m < n
            sta   RE_RMAX
:close      lda   (RE_NEWREP),y
            cmp   #"\"
            bne   :bad
            iny
            lda   (RE_NEWREP),y
            cmp   #$FD               ;"}" high-bit
            bne   :bad
            iny
:adv        tya                      ;Y = the operator's width
            clc
            adc   RE_NEWREP
            sta   RE_NEWREP
            bcc   :advok
            inc   RE_NEWREP+1
:advok      sec
            rts
:bad        lda   #3
            sta   RE_AKIND
            sec
            rts

*---------------------------------------------------------------
* RE_RDNUM -- read a decimal number at (RE_NEWREP),Y for
* RE_REPOP. OUT: A = value, X = digits consumed, Y past them,
* carry clear; carry set = the value passed 255. That 8-bit
* ceiling IS the RE_DUP_MAX cap (POSIX's floor for it), and it
* is why \{1,999999\} cannot run the machine into the ground:
* the pattern is refused as malformed, never attempted. Uses
* RE_TMP/RE_TMP2 -- RE_CLASS_TEST's scratch, idle between atoms.
*---------------------------------------------------------------
RE_RDNUM    ldx   #0
            stx   RE_TMP
:rdloop     lda   (RE_NEWREP),y
            cmp   #"0"
            bcc   :rddone
            cmp   #":"               ;'9'+1
            bcs   :rddone
            sec
            sbc   #"0"
            sta   RE_TMP2
            lda   RE_TMP
            cmp   #26
            bcs   :rdovf             ;26*10 > 255 already
            asl
            sta   RE_TMP             ;2v
            asl
            asl                      ;8v (<= 200: no carry out)
            adc   RE_TMP             ;10v
            adc   RE_TMP2            ;+digit; carry = overflow
            bcs   :rdovf
            sta   RE_TMP
            inx
            iny
            bra   :rdloop
:rddone     lda   RE_TMP
            clc
            rts
:rdovf      sec
            rts
