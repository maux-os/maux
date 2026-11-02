*---------------------------------------------------------------
* grepbody.s -- grep's whole implementation. PUT by grep.s,
* which keeps only the equate puts, the org/dsk/typ triple, the
* liba puts and the `dum` arena.
*
* WHY THE SPLIT, 2026-09-21. Real Merlin holds the RESIDENT
* source -- the top-level manifest plus every `use` -- together
* with ONE `put` at a time, in 41,215 bytes, so a unit's budget
* is its manifest plus its LARGEST single put (check_dialect.py
* rule 3). grep.s's manifest had grown to 19,728 stripped bytes
* against a 22,811-byte largest put (liba/regex2.s), i.e. 42,539
* against 41,215: -F's arrival was what tipped it, but the
* manifest had been the whole program since the tool was
* written. Moving the body here leaves the manifest at a few
* hundred bytes, and this file is far smaller than regex2.s, so
* it never becomes the binding put. Same put-module precedent as
* sh.s's eight and sed.s/sedexec.s; ONE assembly unit either
* way, and check-bytes proves the split is byte-neutral.
*
* The liba puts stay at TOP LEVEL in grep.s -- Merlin cannot
* nest a put inside a put file -- which is also why this file
* ends where the liba chain begins rather than carrying it.
*---------------------------------------------------------------
PATMAX      equ   8                ;patterns in the set (-e/-f)
BUFSZ       equ   255              ;read chunk -- see GETBYTE
LINEMAX     equ   255              ;longest line we will match

START       stz   NPAT
            stz   WANT_V
            stz   WANT_N
            stz   WANT_C
            stz   WANT_E
            stz   WANT_I
            stz   WANT_L
            stz   WANT_S
            stz   WANT_Q
            stz   WANT_X
            stz   WANT_F
            stz   STDINF
            stz   PFX
            lda   #<GREPOPTS
            ldx   #>GREPOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F6                     ;'v' invert
            bne   :not_v
            sta   WANT_V
            bra   :optlp
:not_v      cmp   #$EE                     ;'n' line numbers
            bne   :not_n
            sta   WANT_N
            bra   :optlp
:not_n      cmp   #$E3                     ;'c' count only
            bne   :not_c
            sta   WANT_C
            bra   :optlp
:not_c      cmp   #$E9                     ;'i' fold case
            bne   :not_i
            sta   WANT_I
            bra   :optlp
:not_i      cmp   #$EC                     ;'l' names only
            bne   :not_l
            sta   WANT_L
            bra   :optlp
:not_l      cmp   #$F3                     ;'s' quiet open errs
            bne   :not_s
            sta   WANT_S
            bra   :optlp
*-- 'e' is $E5, LOWERCASE e high-bit-set: the case bit is bit 5
*-- and a wrong one here is invisible under a correct comment
*-- (learning:01M0PKP4ZK7NX6HASWHTKKZHDG, where find.s's `-type
*-- d` was $C4 and unreachable). GREPOPTS spells it too, and
*-- the corpus types the lowercase form.
:not_s      cmp   #$E5                     ;'e' RE follows
            bne   :not_e
*-- A SECOND -e ACCUMULATES. It used to be a usage error, and
*-- the header said so proudly; POSIX says every -e adds to the
*-- set and a line is selected if ANY pattern matches, which is
*-- the whole reason -e is repeatable.
            sta   WANT_E
            lda   OPTARG                   ;OPTARG is dead at
            sta   PTR0                     ;the NEXT GETOPT, so
            lda   OPTARG+1                 ;copy the RE out now
            sta   PTR0+1
            jsr   PATADD
            bra   :optlp
:not_e      cmp   #$F1                     ;'q' quiet, exit on
            bne   :not_q                   ;first match
            sta   WANT_Q
            bra   :optlp
:not_q      cmp   #$F8                     ;'x' whole-line match
            bne   :not_x
            sta   WANT_X
            bra   :optlp
:not_x      cmp   #$C6                     ;'F' fixed string --
            bne   :not_ff                  ;UPPERCASE, $C6 not
            sta   WANT_F                   ;$E6 (the case bit is
            bra   :optlp                   ;bit 5, see -e
:not_ff     cmp   #$E6                     ;'f' patterns from a
            bne   :usage                   ;file
            sta   WANT_E                   ;-f supplies the RE,
            lda   OPTARG                   ;same as -e does
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PATFILE
            jmp   :optlp                   ;out of bra range
:optdone    lda   WANT_E
            bne   :prefix                  ;-e gave us the RE
            lda   ARGC
            sec
            sbc   OPTIND
            cmp   #1
            bcs   :havere
:usage      lda   #<USAGE                  ;no pattern -- usage,
            sta   PTR0                     ;status 2
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*-- argv[OPTIND] is the pattern. Copy it out of the argv staging
*-- area into PATBUF: RE_MATCH clobbers PTR0/PTR1/PTR2 (liba
*-- convention) and we re-enter it once per line, so the pattern
*-- needs a home that survives the call.
:havere     lda   OPTIND
            jsr   GETARG                   ;pattern
            inc   OPTIND                   ;operands follow it
            jsr   PATADD

*-- Two or more FILE operands means every selected line and
*-- every -c count carries its file name. Counted from OPTIND,
*-- so it is the operands GIVEN, not the ones that open.
*-- -i folds the pattern HERE, after option parsing, not inside
*-- -e's handler: `grep -e RE -i` sees -i after the copy, and a
*-- fold at copy time would miss it.
*-- -F ESCAPES, it does not match differently. A fixed string is
*-- a BRE in which every metacharacter has been quoted, so the
*-- one engine keeps doing the matching and this tool grows no
*-- second matcher -- the same "one matcher behind both tools"
*-- reasoning that put the engine in liba in the first place.
*-- It runs BEFORE the fold and the anchor, and both still
*-- compose: '^' and '$' are not letters so FOLDCOPY does not
*-- touch them, and XANCHOR's "is it already anchored" tests see
*-- the backslash an escaped '^'/'$' now carries and correctly
*-- add a real anchor of their own.
*-- EACH pattern is prepared in turn, and each is prepared in
*-- PATBUF rather than in its own slot. That is deliberate:
*-- FESCAPE and XANCHOR rewrite a pattern IN PLACE with absolute
*-- PATBUF addressing, and teaching both of them to work through
*-- a pointer -- XANCHOR's shift loop especially -- would be a
*-- rewrite of two fiddly routines to save one copy that happens
*-- at most PATMAX times at startup and never per line.
:prefix     stz   PATIDX
:preplp     lda   PATIDX
            cmp   NPAT
            bcs   :prepdone
            jsr   SLOTIN                   ;slot -> PATBUF
            lda   WANT_F
            beq   :nofix
            jsr   FESCAPE
:nofix      lda   WANT_I
            beq   :nofold
            lda   #<PATBUF
            sta   PTR0
            lda   #>PATBUF
            sta   PTR0+1
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            jsr   FOLDCOPY
*-- -x anchors AFTER the fold -- '^'/'$' aren't letters, so
*-- the order between the two makes no difference either way.
:nofold     lda   WANT_X
            beq   :noanch
            jsr   XANCHOR
:noanch     jsr   SLOTOUT                  ;PATBUF -> slot
            inc   PATIDX
            bra   :preplp
:prepdone   lda   ARGC
            sec
            sbc   OPTIND
            cmp   #2
            bcc   :nopfx
            lda   #1
            sta   PFX
:nopfx      stz   MATCHED
            stz   ERRFLAG
            lda   ARGC
            cmp   OPTIND
            bne   :havefile
*-- no FILE: read stdin
            lda   #FD_STDIN
            sta   SRCFD
            lda   #1                       ;-l on stdin says
            sta   STDINF                   ;"(standard input)"
            jsr   GREPFD
            jsr   PRCOUNT
            bra   :done

:havefile   lda   OPTIND
            sta   ARGIDX
:looparg    lda   ARGIDX
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :openerr
            lda   OPARM_REF
            sta   SRCFD
            jsr   GREPFD
            jsr   PRCOUNT                  ;per FILE, and only
                                           ;for one that opened
            ldx   SRCFD
            stx   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            bra   :nextarg

:openerr    lda   WANT_S                   ;-s: keep the status,
            bne   :errquiet                ;lose the noise
            lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG                   ;PUTS clobbered PTR0
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
:errquiet   lda   #2
            sta   ERRFLAG

:nextarg    inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcc   :looparg

*-- Status: an open failure (2) outranks the match result, so a
*-- script cannot mistake "file missing" for "nothing matched".
:done       lda   ERRFLAG
            bne   :exit
            lda   MATCHED
            beq   :nomatch
            lda   #0
            bra   :exit
:nomatch    lda   #1
:exit       jsr   EXIT

*---------------------------------------------------------------
* GREPFD -- read SRCFD line by line, print the matching ones.
* IN: SRCFD. Sets MATCHED to 1 if any line matched.
*---------------------------------------------------------------
GREPFD      stz   BUFPOS
            stz   BUFLEN
            stz   NLINE                    ;-n's numbers and
            stz   NLINE+1                  ;-c's count both
            stz   NHIT                     ;RESTART at each
            stz   NHIT+1                   ;FILE, as they must
            stz   LDONE                  ;-l: 1 name per FILE
:loop       jsr   GETLINE
            bcs   :eof
            inc   NLINE                    ;-n numbers every
            bne   :test                    ;line read
            inc   NLINE+1
:test       jsr   TESTLINE
            lda   LDONE                    ;-l printed its name:
            bne   :eof                     ;done with this FILE
            bra   :loop
:eof        rts

*---------------------------------------------------------------
* TESTLINE -- run LINEBUF past the matcher, print it on a hit.
* RE_MATCH wants three pointers: the line, the pattern, and the
* position to search from (== line start for a plain search).
*---------------------------------------------------------------
*-- MATCH AGAINST A NORMALISED COPY, PRINT THE ORIGINAL. That is
*-- -i's old trick, widened to do the job -i never did: the copy
*-- is now masked to SEVEN BITS as well as case-folded, so the
*-- line's own encoding stops mattering.
*--
*-- It matters because a file that arrives from outside -- over
*-- `tip`, from `a2til`, out of a NuFX archive -- carries ProDOS
*-- semantics: low ASCII, $0D; maux writes high-bit, $8D.
*-- Measured 2026-09-21 on a file staged exactly as a2til's
*-- convert.text_from_host() produces it: `cat` displayed it
*-- perfectly (TTY_WR_CELL masks on the way to the glass) while
*-- `grep b` found NOTHING and returned silently. The one tool a
*-- person tries first works, so nothing warns them.
*--
*-- The PATTERN is masked to match, at the end of :prefix, after
*-- FESCAPE/FOLDCOPY/XANCHOR have had their high-bit view of it.
*-- Only the FILE's polarity is freed here; argv is still
*-- whatever the keyboard delivers, which is the next phase.
TESTLINE    jsr   NORMLINE
*-- ANY pattern selects the line (POSIX: -e is repeatable and -f
*-- reads a set), so it stops at the first hit. PTR0/PTR2 are
*-- re-seeded per attempt because RE_MATCH clobbers all three.
:pat        stz   PATIDX
            stz   PATHIT
:patlp      lda   PATIDX
            cmp   NPAT
            bcs   :patdone
            lda   #<FOLDBUF                ;the normalised copy,
            sta   PTR0                     ;always -- see
            lda   #>FOLDBUF                ;TESTLINE's header
            sta   PTR0+1
            lda   #<FOLDBUF
            sta   PTR2
            lda   #>FOLDBUF
            sta   PTR2+1
            jsr   PATPTR1                  ;PTR1 = slot PATIDX
            jsr   RE_MATCH
            bcs   :patnext
            lda   #1
            sta   PATHIT
            bra   :patdone
:patnext    inc   PATIDX
            bra   :patlp
:patdone    lda   PATHIT                   ;1 = some pattern hit
            ldx   WANT_V                   ;-v inverts it
            beq   :decided
            eor   #1
:decided    cmp   #0                       ;re-test A: the LDX
            beq   :nohit                   ;above left Z set
            lda   #1
            sta   MATCHED
*-- -q: nothing prints; exit(0) on the FIRST selected line,
*-- unread input and all.
            lda   WANT_Q
            beq   :notquiet
            lda   #0
            jsr   EXIT
:notquiet   lda   WANT_L                   ;-l: the name, once,
            beq   :counted                 ;nothing else -- it
            jmp   PRNAME                   ;overrides -c and -n
:counted    inc   NHIT
            bne   :cnt
            inc   NHIT+1
:cnt        lda   WANT_C                   ;-c: count only
            bne   :nohit
            jsr   PRPFX                    ;"FILE:" first, then
            lda   WANT_N                   ;then "NUM:", then it
            beq   :emit
            lda   NLINE
            sta   U2DEC_VAL
            lda   NLINE+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            lda   #$BA                     ;':' high-bit-set
            ldx   #FD_STDOUT
            jsr   PUTC
:emit       lda   #<LINEBUF
            sta   PTR0
            lda   #>LINEBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:nohit      rts

*---------------------------------------------------------------
* PRPFX -- print "FILE:" from argv[ARGIDX] when two or more FILE
* operands were given, and NOTHING otherwise, so one file and
* stdin both stay bare. CLOBBERS PTR0 -- every caller sets it
* again afterwards (PUTS is what clobbers it; :openerr's
* re-GETARG above is the same dance).
*---------------------------------------------------------------
PRPFX       lda   PFX
            beq   :out
            lda   ARGIDX
            jsr   GETARG                   ;the operand AS TYPED
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$BA                     ;':' high-bit-set
            ldx   #FD_STDOUT
            jsr   PUTC
:out        rts

*---------------------------------------------------------------
* PRCOUNT -- under -c, print this file's count as "[FILE:]N".
* Called after each file that OPENED, and once for stdin; a file
* that failed to open prints no count at all, which is what
* /usr/bin/grep does. Without -c it prints nothing. -q prints
* nothing here either -- reached only when NO line was ever
* selected (a selected line under -q exits the whole program
* from TESTLINE before this is ever called).
*---------------------------------------------------------------
PRCOUNT     lda   WANT_Q                   ;-q: nothing prints,
            bne   :out                     ;match or no match
            lda   WANT_L                   ;-l already said all
            bne   :out                     ;there is to say
            lda   WANT_C
            beq   :out
            jsr   PRPFX
            lda   NHIT
            sta   U2DEC_VAL
            lda   NHIT+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:out        rts

*---------------------------------------------------------------
* PRNAME -- -l's whole output: the current operand AS TYPED (or
* "(standard input)" when reading fd 0, the modern spelling) and
* a CR, then LDONE so GREPFD abandons the rest of the file.
* Reached only on a selected line, so MATCHED is already set.
*---------------------------------------------------------------
PRNAME      lda   STDINF
            bne   :stdin
            lda   ARGIDX
            jsr   GETARG                   ;operand -> PTR0
            bra   :say
:stdin      lda   #<M_STDIN
            sta   PTR0
            lda   #>M_STDIN
            sta   PTR0+1
:say        ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #1
            sta   LDONE
            rts

*---------------------------------------------------------------
* FOLDCOPY -- copy the NUL-terminated string at (PTR0) to (PTR1)
* lowercasing letters on the way: ora #$20 folds BOTH text
* conventions ($C1-$DA -> $E1-$FA high-bit, $41-$5A -> $61-$7A
* plain), and the case test masks bit 7 first so it sees them as
* one range. Non-letters pass through untouched. In-place is
* legal (PTR0 == PTR1: -i's pattern fold uses it).
*---------------------------------------------------------------
FOLDCOPY    ldy   #0
:loop       lda   (PTR0),y
            beq   :end
            tax
            and   #$7F
            cmp   #'A'
            bcc   :keep
            cmp   #'Z'+1
            bcs   :keep
            txa
            ora   #$20
            bra   :put
:keep       txa
:put        sta   (PTR1),y
            iny
            bne   :loop
:end        lda   #0                     ;terminate the copy --
            sta   (PTR1),y               ;a wrapped y (len 256,
            rts                          ;impossible here) still
                                           ;lands a NUL in range

*---------------------------------------------------------------
* TOPATBUF -- copy the NUL-terminated RE at PTR0 into PATBUF.
* Both spellings of the pattern need it out of the argv staging
* area before RE_MATCH is entered: the positional RE, and -e's
* OPTARG (which liba only guarantees until the next GETOPT).
*---------------------------------------------------------------
*-- SLOT ADDRESSING. A slot is 256 bytes, so slot N lives at
*-- PATTAB + N*256: the low byte never changes and the high byte
*-- is just >PATTAB + N. That is the whole reason the slot is a
*-- page and not the 64 bytes a pattern usually needs -- the
*-- arithmetic is one ADC instead of a multiply, and the table
*-- lives in the `dum` arena, which emits no image bytes at all,
*-- so the eight pages are free.
PATPTR1     lda   #<PATTAB
            sta   PTR1
            lda   #>PATTAB
            clc
            adc   PATIDX
            sta   PTR1+1
            rts

PATPTR0     lda   #<PATTAB
            sta   PTR0
            lda   #>PATTAB
            clc
            adc   PATIDX
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* PATADD -- append the NUL-terminated RE at PTR0 as the next
* pattern. Refuses (usage, exit 2) rather than dropping one: a
* grep that silently searched for fewer patterns than it was
* given would report "no match" for a pattern it never tried,
* which is the failure this tree exists to close.
*---------------------------------------------------------------
PATADD      lda   NPAT
            cmp   #PATMAX
            bcs   :toomany
            sta   PATIDX
            jsr   PATPTR1
            jsr   STRCPY
            inc   NPAT
            rts
:toomany    lda   #<TOOMANY
            sta   PTR0
            lda   #>TOOMANY
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jmp   EXIT

*---------------------------------------------------------------
* SLOTIN / SLOTOUT -- copy slot PATIDX into PATBUF and back.
* See :prefix for why the preparation happens in PATBUF.
*---------------------------------------------------------------
SLOTIN      jsr   PATPTR0
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            jmp   STRCPY

SLOTOUT     lda   #<PATBUF
            sta   PTR0
            lda   #>PATBUF
            sta   PTR0+1
            jsr   PATPTR1
            jmp   STRCPY

*---------------------------------------------------------------
* PATFILE -- -f: every LINE of the file at PTR0 is a pattern.
*
* It reuses GETLINE/GETBYTE, the same reader the search loop
* uses, by opening the pattern file as SRCFD and resetting the
* chunk cursors -- so a pattern file gets the identical
* treatment an input file does, including a final unterminated
* line. The cursors are reset again on the way out because the
* first real input file inherits them.
*
* An EMPTY pattern file is not an error and is not "match
* nothing by accident": POSIX says a null RE matches every line,
* and with zero patterns the match loop selects nothing, so the
* two disagree. An empty -f file therefore adds ONE empty
* pattern, which the engine treats as the null RE and which
* matches every line -- the behaviour the host's own grep has.
*---------------------------------------------------------------
PATFILE     lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :pfopenerr
            lda   OPARM_REF
            sta   SRCFD
            stz   BUFPOS
            stz   BUFLEN
            stz   PFANY
:pfline     jsr   GETLINE
            bcs   :pfeof
            lda   #1
            sta   PFANY
            lda   #<LINEBUF
            sta   PTR0
            lda   #>LINEBUF
            sta   PTR0+1
            jsr   PATADD
            bra   :pfline
:pfeof      lda   PFANY
            bne   :pfclose
            lda   #<EMPTYRE               ;empty file = null
            sta   PTR0                     ;RE, which matches
            lda   #>EMPTYRE                ;every line
            sta   PTR0+1
            jsr   PATADD
:pfclose    ldx   SRCFD
            stx   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            stz   BUFPOS
            stz   BUFLEN
            rts
:pfopenerr  lda   #<NOPATF
            sta   PTR0
            lda   #>NOPATF
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jmp   EXIT

*---------------------------------------------------------------
* NORMLINE -- LINEBUF into FOLDBUF with bit 7 SET, then -i's
* case fold. The printed line is always LINEBUF, so a matched
* line reaches stdout in the encoding it arrived in.
*
* UP, NOT DOWN -- the first version had it backwards. Masking
* both sides to seven bits looks like the neutral choice and
* breaks the matcher: liba's regex engine recognises its own
* metacharacters as HIGH-BIT literals, so a masked pattern
* turns
* '.' and '*' into ordinary characters. check-e2e said so
* immediately -- `GREP A.B`, `a.*t` and `a*al` all stopped
* matching while plain literals still worked.
*
* Setting bit 7 on the LINE instead leaves the pattern, the
* engine and liba's own FOLDCOPY in the single encoding they
* were all written for, and costs one ORA per byte.
*---------------------------------------------------------------
NORMLINE    ldy   #0
:nlloop     lda   LINEBUF,y
            beq   :nldone
            ora   #$80
            sta   FOLDBUF,y
            iny
            bne   :nlloop
:nldone     lda   #0
            sta   FOLDBUF,y
            lda   WANT_I
            beq   :nlrts
            lda   #<FOLDBUF                ;-i's fold, in place,
            sta   PTR0                     ;by the liba routine
            lda   #>FOLDBUF                ;that already knows
            sta   PTR0+1                   ;the ranges
            lda   #<FOLDBUF
            sta   PTR1
            lda   #>FOLDBUF
            sta   PTR1+1
            jsr   FOLDCOPY
:nlrts      rts

*---------------------------------------------------------------
* FESCAPE -- -F: rewrite PATBUF in place so the BRE engine
* matches it LITERALLY, by quoting every character BRE treats as
* special: . * [ \ ^ $
*
* WHY THIS AND NOT A SECOND MATCHER. `grep -F` differs from
* `grep` only in how the pattern is READ, never in how a line is
* tested, so the whole feature is a transform on the pattern and
* the existing engine does the work unchanged. A literal
* substring searcher would be a second matcher to keep correct
* alongside the first, for no behaviour the first cannot
* already produce.
*
* Quoting ']' is not needed and is deliberately not done: in a
* BRE, ']' outside a bracket expression is an ordinary
* character, and every '[' this routine sees has just been
* escaped, so no bracket expression can be open.
*
* IT REFUSES RATHER THAN TRUNCATES. Escaping can double a
* pattern's length, and PATBUF is LINEMAX+3. A pattern whose
* escaped form does not fit exits 2 with the usage line, the
* same posture XANCHOR takes for its own two bytes -- silently
* dropping part of a pattern would search for something the
* user did not ask for and say nothing.
*
* The rewrite runs BACKWARDS, from the NUL down, so it needs no
* second buffer: every byte moves up by the number of escapes
* still to its right, which is exactly what a reverse walk with
* one write cursor produces.
*---------------------------------------------------------------
FESCAPE     lda   #<PATBUF
            sta   PTR0
            lda   #>PATBUF
            sta   PTR0+1
            jsr   STRLEN                   ;A/X = lo/hi length
            cpx   #0
            bne   :ftoolong                ;>255: cannot fit
            sta   FLEN
            stz   FCNT
            ldy   #0
:fcount     cpy   FLEN
            beq   :fsized
            lda   (PTR0),y
            jsr   FISMETA
            bcc   :fnext
            inc   FCNT
            beq   :ftoolong                ;256 metacharacters
:fnext      iny
            bra   :fcount
*-- FLEN + FCNT must still leave room for the NUL, and for the
*-- two bytes XANCHOR may add after us.
:fsized     lda   FCNT
            beq   :fdone                   ;nothing special in
            clc                            ;-- already literal
            adc   FLEN
            bcs   :ftoolong
            cmp   #LINEMAX
            bcs   :ftoolong
            sta   FDST
            lda   FLEN
            sta   FSRC
*-- The NUL first, then each byte with its quote, walking down.
            ldy   FDST
            lda   #0
            sta   (PTR0),y
:floop      lda   FSRC
            beq   :fdone
            dec   FSRC
            dec   FDST
            ldy   FSRC
            lda   (PTR0),y
            ldy   FDST
            sta   (PTR0),y
            ldy   FSRC
            lda   (PTR0),y
            jsr   FISMETA
            bcc   :floop
            dec   FDST
            ldy   FDST
            lda   #"\"
            sta   (PTR0),y
            bra   :floop
:fdone      rts
:ftoolong   lda   #<FTOOLONG
            sta   PTR0
            lda   #>FTOOLONG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jmp   EXIT

*---------------------------------------------------------------
* FISMETA -- carry SET if A is a BRE metacharacter. High-bit-set
* codes throughout: these are argv bytes, and the double-quote
* form merlin32 assembles IS high-bit-set (the same spelling
* XANCHOR's own '^'/'$' compares use).
*---------------------------------------------------------------
FISMETA     cmp   #"."
            beq   :fyes
            cmp   #"*"
            beq   :fyes
            cmp   #"["
            beq   :fyes
            cmp   #"\"
            beq   :fyes
            cmp   #"^"
            beq   :fyes
            cmp   #"$"
            beq   :fyes
            clc
            rts
:fyes       sec
            rts

*---------------------------------------------------------------
* XANCHOR -- -x: rewrite PATBUF in place as ^PATBUF$, skipping
* either anchor already present (leading '^', or a trailing '$'
* not itself preceded by '\' -- an escaped dollar is a literal
* character, so it still needs the real anchor). PATBUF is
* LINEMAX+3 bytes so the pair always fits a LINEMAX-length
* pattern; this still refuses (usage, exit 2) instead of
* truncating if the sum would pass LINEMAX -- regex.s's own
* pattern walk assumes a pattern under 256 bytes (see RE_MATCH's
* header), so the anchored total must stay <= LINEMAX same as an
* input line does.
*---------------------------------------------------------------
XANCHOR     lda   #<PATBUF
            sta   PTR0
            lda   #>PATBUF
            sta   PTR0+1
            jsr   STRLEN                   ;A/X = lo/hi length
            stx   XHI
            sta   XLEN
            stz   XNEEDP
            stz   XNEEDS
            ldy   #0
            lda   (PTR0),y
            cmp   #"^"
            beq   :xhaspfx
            inc   XNEEDP
:xhaspfx    lda   XLEN
            beq   :xneedsf                 ;empty pattern: no
                                           ;last char to inspect
            ldy   XLEN
            dey
            lda   (PTR0),y
            cmp   #"$"
            bne   :xneedsf
            cpy   #0
            beq   :xchklim                 ;'$' is also the
                                           ;first char: nothing
                                           ;precedes it
            dey
            lda   (PTR0),y
            cmp   #"\"
            bne   :xchklim                 ;plain trailing '$':
                                           ;already anchored
:xneedsf    inc   XNEEDS
:xchklim    lda   XHI                      ;>=256 already --
            bne   :xtoolng                 ;refuse, don't guess
            lda   XNEEDP
            clc
            adc   XNEEDS
            sta   XREQ
            lda   #LINEMAX
            sec
            sbc   XREQ                     ;room left for the
            cmp   XLEN                     ;pattern itself
            bcc   :xtoolng
            lda   XNEEDP
            beq   :xnopfx
*-- shift right, NUL included, from the end backward so the
*-- overlap never reads a byte already overwritten.
            ldy   XLEN
:xshift     lda   PATBUF,y
            sta   PATBUF+1,y
            dey
            cpy   #$FF                     ;until Y wraps past 0
            bne   :xshift                  ;(bpl quits at 128)
            lda   #"^"
            sta   PATBUF
            inc   XLEN
:xnopfx     lda   XNEEDS
            beq   :xnosfx
            ldy   XLEN
            lda   #"$"
            sta   PATBUF,y
            iny
            lda   #0
            sta   PATBUF,y
:xnosfx     rts
:xtoolng    lda   #<USAGE
            sta   PTR0
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* GETLINE -- next CR-terminated line from SRCFD into LINEBUF,
* NUL-terminated (liba string shape, which is what RE_MATCH
* expects).
*
* OUT: carry clear = a line is in LINEBUF; carry set = EOF with
* nothing pending. A final line with no trailing CR IS returned.
* Over-long lines are truncated at LINEMAX and the rest of the
* physical line is discarded.
*---------------------------------------------------------------
GETLINE     ldy   #0
            sty   LINELEN
:next       jsr   GETBYTE
            bcs   :eofhit
            cmp   #$8D                     ;CR ends the line
            beq   :haveline
            ldy   LINELEN
            cpy   #LINEMAX
            bcs   :next                    ;full: drop the byte,
                                           ;keep scanning for CR
            sta   LINEBUF,y
            inc   LINELEN
            bra   :next

:haveline   ldy   LINELEN
            lda   #0
            sta   LINEBUF,y
            clc
            rts

*-- EOF: return a final unterminated line if we accumulated one,
*-- otherwise report end of input.
:eofhit     lda   LINELEN
            beq   :nothing
            ldy   LINELEN
            lda   #0
            sta   LINEBUF,y
            clc
            rts
:nothing    sec
            rts

*---------------------------------------------------------------
* GETBYTE -- one byte from SRCFD, buffered through CBUF.
* OUT: carry clear = byte in A; carry set = EOF.
*---------------------------------------------------------------
*-- A 255-byte chunk keeps BUFPOS/BUFLEN single bytes, so this
*-- one indexed load instead of 16-bit pointer arithmetic into a
*-- zero-page pair liba has not got to spare. The extra syscall
*-- per 255 bytes is not worth a new ZP allocation.
GETBYTE     ldx   BUFPOS
            cpx   BUFLEN
            bcc   :have
            jsr   REFILL
            bcs   :eof
            ldx   BUFPOS
:have       lda   CBUF,x
            inc   BUFPOS
            clc
            rts
:eof        sec
            rts

*---------------------------------------------------------------
* REFILL -- one SC_READ into CBUF. Carry set on EOF or error.
* A read error is treated as EOF, the v1 convention (see
* docs/USERLAND.md "ABI RESOLUTIONS").
*---------------------------------------------------------------
REFILL      lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :eof
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            lda   RPARM_TRANS         ;<=255 by construction, so
            sta   BUFLEN              ;the high byte is always 0
            stz   BUFPOS
            clc
            rts
:eof        sec
            rts

FTOOLONG    asc   "grep: -F pattern too long once quoted"
            dfb   $8D,$00
TOOMANY     asc   "grep: too many patterns"
            dfb   $8D,$00
NOPATF      asc   "grep: cannot open pattern file"
            dfb   $8D,$00
EMPTYRE     dfb   $00
USAGE       asc   "usage: grep [-cFilnqsvx][-e RE][-f F] RE.."
            dfb   $8D,$00
ERRMSG      asc   "grep: cannot open "
            dfb   $00
M_STDIN     asc   "(standard input)"
            dfb   $00

*-- One letter per flag the banner above advertises, and the
*-- ':' marks -e as argument-taking (src/liba/getopt.s). The
*-- banner and this string are checked against each other by
*-- eye only -- an advertised flag missing here is unreachable.
GREPOPTS    asc   "cnvilse:qxFf:"
            dfb   0

OPARM       dfb   OPEN_RO
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000          ;kernel-owned, main memory --
                                 ;see cat.s's header
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

