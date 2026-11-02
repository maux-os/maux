*---------------------------------------------------------------
* regex2.s -- regex.s's second half: RE_ATOM_PARSE onward (atom
* decode, character-class test, \( \) group numbering,
* RE_FINDCLOS, group-repeat backtracking (RE_GSTAR/RE_GSSAVE),
* \1-\9 backreference match, RE_BKMATCH). Split from regex.s
* 2026-09-02 at the RE_ATOM_PARSE global boundary for BOTH
* self-hosting source-window budgets (check_librel.py's
* MERLIN_SOURCE_BUDGET=41215 resident+largest-put rule;
* build_librelas_image.py's as WINDOW=16126) -- the un-split
* file was 41,020 B raw, over the real-Merlin budget by 5,520 B
* and over as's window by thousands more once its equ put is
* charged. One assembly stream: every consumer `put`s this file
* IMMEDIATELY after regex.s, and every rule in regex.s's header
* applies unchanged. The RE_* zero-page equates this half needs
* (nearly all of them -- RE_ATOM_PARSE/RE_GROUPNUM/RE_GSTAR
* write state RE_MATCH/RE_MATCHHERE/RE_MATCHSTAR read, and vice
* versa) live in inc/regex.equ, `put` once by the consumer
* before regex.s -- see that file's header for why they moved.
*---------------------------------------------------------------

*---------------------------------------------------------------
* RE_ATOM_PARSE -- decode the single atom starting at RE_REP.
* Sets RE_AKIND (0/1/2/3), RE_ACHAR, RE_ANEG, RE_ACLS,
* RE_ACLSEND as documented at the top of the file, and RE_NEWREP
* = pattern pointer just past the atom (NOT yet accounting for a
* trailing '*' -- the caller checks that). Never called with
* *RE_REP == NUL (callers check that first).
*---------------------------------------------------------------
RE_ATOM_PARSE
            ldy   #0
            lda   (RE_REP),y
            cmp   #"\"
            beq   :esc
            cmp   #"."
            beq   :dot
            cmp   #"["
            bne   :plain
            jmp   :class             ;past the \n atom's reach

:plain      sta   RE_ACHAR
            lda   #0
            sta   RE_AKIND
            clc
            lda   RE_REP
            adc   #1
            sta   RE_NEWREP
            lda   RE_REP+1
            adc   #0
            sta   RE_NEWREP+1
            rts

:esc        ldy   #1
            lda   (RE_REP),y
            bne   :esc2
            lda   #"\"                ;trailing lone backslash
                                      ;-> literal \
            sta   RE_ACHAR
            lda   #0
            sta   RE_AKIND
            clc
            lda   RE_REP
            adc   #1
            sta   RE_NEWREP
            lda   RE_REP+1
            adc   #0
            sta   RE_NEWREP+1
            rts
*-- \( \) \1-\9 (W5): AKIND 4=group-open 5=group-close
*-- 6=backref (ACHAR=digit VALUE 1-9). Still 2-byte tokens,
*-- same NEWREP=+2 as any other escape -- the STRICT SUPERSET
*-- property is that every OTHER \X falls to :esclit exactly
*-- as before (this used to BE :esc2's own body). Before this
*-- change \( matched a literal '('; W5 in ANACHRONISMS.md
*-- records that as the one deliberate semantic break.
*-- \n is the NEWLINE (CR, the maux text line end): POSIX sed's
*-- rule for an RE over a multi-line pattern space (docs/SED.md,
*-- 2026-09-11). One engine, so ed/ex/vi/grep read \n the same
*-- way -- GNU ed does too; before this \n was a literal 'n'.
:esc2       cmp   #"n"
            bne   :notnl
            lda   #$8D
            bra   :esclit
:notnl      cmp   #"("
            beq   :gropen
            cmp   #")"
            beq   :grclos
            cmp   #"1"
            bcc   :esclit
            cmp   #":"            ;':' is '9'+1 -- no arith
            bcs   :esclit
            sec
            sbc   #"0"            ;digit VALUE (1-9) into A
            sta   RE_ACHAR
            lda   #6
            sta   RE_AKIND
            bra   :escadv
:gropen     lda   #4
            sta   RE_AKIND
            bra   :escadv
:grclos     lda   #5
            sta   RE_AKIND
            bra   :escadv
:esclit     sta   RE_ACHAR
            lda   #0
            sta   RE_AKIND
:escadv     clc
            lda   RE_REP
            adc   #2
            sta   RE_NEWREP
            lda   RE_REP+1
            adc   #0
            sta   RE_NEWREP+1
            rts

:dot        lda   #1
            sta   RE_AKIND
            clc
            lda   RE_REP
            adc   #1
            sta   RE_NEWREP
            lda   RE_REP+1
            adc   #0
            sta   RE_NEWREP+1
            rts

:class      clc
            lda   RE_REP
            adc   #1
            sta   RE_SCAN
            lda   RE_REP+1
            adc   #0
            sta   RE_SCAN+1

            ldy   #0
            lda   (RE_SCAN),y
            cmp   #"^"
            bne   :notneg
            lda   #1
            sta   RE_ANEG
            inc   RE_SCAN
            bne   :chkfirst
            inc   RE_SCAN+1
            bra   :chkfirst
:notneg     lda   #0
            sta   RE_ANEG

:chkfirst   lda   RE_SCAN
            sta   RE_ACLS
            lda   RE_SCAN+1
            sta   RE_ACLS+1
            ldy   #0
            lda   (RE_SCAN),y
            beq   :bad               ;NUL right after [ or [^ --
                                     ;malformed
            cmp   #"]"
            bne   :scanterm
            inc   RE_SCAN            ;a leading ']' is a MEMBER
            bne   :scanterm          ;(POSIX): RE_ACLS stays on
            inc   RE_SCAN+1          ;it, only the close-scan
                                     ;steps past it. (W5d: this
                                     ;used to move RE_ACLS too,
                                     ;so []a] matched only a.)

:scanterm   ldy   #0
            lda   (RE_SCAN),y
            beq   :bad
            cmp   #"]"
            beq   :found
            cmp   #"["               ;(W5d) [:name:] [=c=] [.c.]
            bne   :stnext            ;are skipped WHOLE -- their
            ldy   #1                 ;own ']' does not close
            lda   (RE_SCAN),y        ;the bracket expression
            cmp   #":"
            beq   :stcls
            cmp   #"="
            beq   :stcls
            cmp   #"."
            bne   :stnext
:stcls      sta   RE_TMP2            ;the token's delimiter
            inc   RE_SCAN            ;(idle scratch here)
            bne   :stcls2
            inc   RE_SCAN+1
:stcls2     inc   RE_SCAN
            bne   :stfind
            inc   RE_SCAN+1
:stfind     ldy   #0
            lda   (RE_SCAN),y
            beq   :bad               ;no closing X] -- malformed
            cmp   RE_TMP2
            bne   :stf2
            ldy   #1
            lda   (RE_SCAN),y
            cmp   #"]"
            beq   :stclose
:stf2       inc   RE_SCAN            ;still inside the token
            bne   :stfind
            inc   RE_SCAN+1
            bra   :stfind
:stclose    inc   RE_SCAN            ;onto the X]'s ']'; :stnext
            bne   :stnext            ;steps past it
            inc   RE_SCAN+1
:stnext     inc   RE_SCAN
            bne   :scanterm
            inc   RE_SCAN+1
            bra   :scanterm

:found      lda   RE_SCAN
            sta   RE_ACLSEND
            lda   RE_SCAN+1
            sta   RE_ACLSEND+1
            lda   #2
            sta   RE_AKIND
            clc
            lda   RE_SCAN
            adc   #1
            sta   RE_NEWREP
            lda   RE_SCAN+1
            adc   #0
            sta   RE_NEWREP+1
            rts

:bad        lda   #3
            sta   RE_AKIND
            rts

* See L.REGEX.TXT: "REATOMTEST -- does character A match"
RE_ATOM_TEST
            sta   RE_TESTCH
            lda   RE_AKIND
            cmp   #1
            beq   :isdot
            cmp   #2
            beq   :isclass

            lda   RE_TESTCH          ;literal
            cmp   RE_ACHAR
            bne   :no
            sec
            rts

:isdot      sec
            rts

:isclass    jsr   RE_CLASS_TEST
            lda   RE_ANEG
            beq   :done
            bcc   :flipset
            clc
            rts
:flipset    sec
            rts
:done       rts
:no          clc
            rts

*---------------------------------------------------------------
* RE_CLASS_TEST -- is RE_TESTCH a member of the class
* [RE_ACLS,RE_ACLSEND)? (Negation is applied by the caller,
* RE_ATOM_TEST, above -- this routine always answers the un-
* negated membership question.) Uses RE_MSCAN as its own private
* scan cursor -- deliberately distinct from RE_SCAN, see the
* header comment on RE_MSCAN. OUT: carry set = member, carry
* clear = not a member.
*---------------------------------------------------------------
RE_CLASS_TEST
            lda   RE_ACLS
            sta   RE_MSCAN
            lda   RE_ACLS+1
            sta   RE_MSCAN+1

:loop       lda   RE_MSCAN
            cmp   RE_ACLSEND
            bne   :have
            lda   RE_MSCAN+1
            cmp   RE_ACLSEND+1
            bne   :have
            clc
            rts

:have       ldy   #0
            lda   (RE_MSCAN),y
            sta   RE_TMP             ;c1
            cmp   #"\"               ;[\n]: the newline member
            bne   :notbs             ;(POSIX sed; see :esc2)
            ldy   #1
            lda   (RE_MSCAN),y
            cmp   #"n"
            bne   :notbs
            lda   #$8D
            cmp   RE_TESTCH
            bne   :nlno
            sec
            rts
:nlno       clc                      ;skip the 2-byte member
            lda   RE_MSCAN
            adc   #2
            sta   RE_MSCAN
            lda   RE_MSCAN+1
            adc   #0
            sta   RE_MSCAN+1
            bra   :loop
*-- (W5d) POSIX bracket tokens: [:name:] (12 names, C locale),
*-- [=c=] and [.c.] (a single character each in the C locale).
*-- An unknown name matches nothing and is skipped -- POSIX
*-- calls it undefined; nothing here is worth a loud path.
:notbs      cmp   #"["
            bne   :plainc
            ldy   #1
            lda   (RE_MSCAN),y
            cmp   #":"
            bne   :notcls
            jmp   :clsname
:notcls     cmp   #"="
            beq   :equiv
            cmp   #"."
            beq   :equiv
:plainc     ldy   #1
            lda   (RE_MSCAN),y
            cmp   #"-"
            bne   :single

            clc
            lda   RE_MSCAN
            adc   #2
            sta   RE_TMPPTR
            lda   RE_MSCAN+1
            adc   #0
            sta   RE_TMPPTR+1
            lda   RE_TMPPTR
            cmp   RE_ACLSEND
            bne   :dorange
            lda   RE_TMPPTR+1
            cmp   RE_ACLSEND+1
            bne   :dorange
            bra   :single            ;'-' with no c2 -- c1 alone
                                     ;this round

:dorange    ldy   #2
            lda   (RE_MSCAN),y
            sta   RE_TMP2            ;c2
            lda   RE_TESTCH
            cmp   RE_TMP
            bcc   :rangeno           ;testch < c1
            lda   RE_TMP2
            cmp   RE_TESTCH
            bcc   :rangeno           ;c2 < testch
            sec
            rts
:rangeno    clc
            lda   RE_MSCAN
            adc   #3
            sta   RE_MSCAN
            lda   RE_MSCAN+1
            adc   #0
            sta   RE_MSCAN+1
            bra   :loopj             ;via the jmp: :loop is past
                                     ;a branch's reach now

:single     lda   RE_TESTCH
            cmp   RE_TMP
            bne   :nextsingle
            sec
            rts
:nextsingle inc   RE_MSCAN
            bne   :loopj
            inc   RE_MSCAN+1
:loopj      jmp   :loop              ;past the [\n] member's
                                     ;reach for a branch

*-- [=c=] / [.c.]: A = the delimiter. Malformed -> '[' literal.
:equiv      sta   RE_TMP2
            ldy   #3
            lda   (RE_MSCAN),y
            cmp   RE_TMP2
            bne   :eqbad
            ldy   #4
            lda   (RE_MSCAN),y
            cmp   #"]"
            bne   :eqbad
            ldy   #2
            lda   (RE_MSCAN),y
            cmp   RE_TESTCH
            beq   :ismem
            lda   #5
:skipn      clc                      ;A = bytes to skip
            adc   RE_MSCAN
            sta   RE_MSCAN
            bcc   :skipj
            inc   RE_MSCAN+1
:skipj      jmp   :loop
:ismem      sec
            rts
:eqbad      jmp   :plainc

*-- [:name:]: walk RE_CLSNAMES (NUL-separated, NUL-ended) with
*-- RE_TMPPTR, RE_TMP2 counting the class number.
:clsname    clc
            lda   RE_MSCAN
            adc   #2
            sta   RE_MSCAN
            bcc   :cn0
            inc   RE_MSCAN+1
:cn0        lda   #<RE_CLSNAMES
            sta   RE_TMPPTR
            lda   #>RE_CLSNAMES
            sta   RE_TMPPTR+1
            lda   #0
            sta   RE_TMP2
:cnnext     ldy   #0
:cncmp      lda   (RE_TMPPTR),y
            beq   :cnend
            cmp   (RE_MSCAN),y
            bne   :cnmiss
            iny
            bra   :cncmp
:cnend      lda   (RE_MSCAN),y       ;name matched: need :]
            cmp   #":"
            bne   :cnmiss
            iny
            lda   (RE_MSCAN),y
            cmp   #"]"
            bne   :cnmiss
            iny
            sty   RE_TMP             ;token bytes to skip
            lda   RE_TMP2
            jsr   RE_CLSTEST
            bcs   :ismem
            lda   RE_TMP
            bra   :skipn
:cnmiss     ldy   #0                 ;next name in the table
:cnskip     lda   (RE_TMPPTR),y
            beq   :cnsk2
            iny
            bra   :cnskip
:cnsk2      iny
            tya
            clc
            adc   RE_TMPPTR
            sta   RE_TMPPTR
            bcc   :cnsk3
            inc   RE_TMPPTR+1
:cnsk3      inc   RE_TMP2
            ldy   #0
            lda   (RE_TMPPTR),y
            bne   :cnnext
*-- unknown name: skip to its :] (or the bracket's end) and
*-- count it as no member
:cnunk      lda   RE_MSCAN
            cmp   RE_ACLSEND
            bne   :cnu1
            lda   RE_MSCAN+1
            cmp   RE_ACLSEND+1
            beq   :cnu4
:cnu1       ldy   #0
            lda   (RE_MSCAN),y
            beq   :cnu3
            cmp   #":"
            bne   :cnu2
            ldy   #1
            lda   (RE_MSCAN),y
            cmp   #"]"
            bne   :cnu2
            lda   #2
            jmp   :skipn
:cnu2       inc   RE_MSCAN
            bne   :cnunk
            inc   RE_MSCAN+1
            bra   :cnunk
:cnu3       lda   RE_ACLSEND         ;ran off the pattern: end
            sta   RE_MSCAN           ;the member walk
            lda   RE_ACLSEND+1
            sta   RE_MSCAN+1
:cnu4       jmp   :loop

*---------------------------------------------------------------
* RE_CLSTEST -- (W5d) is RE_TESTCH in POSIX class A (0..11, the
* order of RE_CLSNAMES)? C locale, on the 7-bit value. OUT:
* carry set = member. Clobbers A, X; RE_TMP2 = the 7-bit char
* (RE_TMP is the caller's, untouched).
*---------------------------------------------------------------
RE_CLSTEST  pha
            lda   RE_TESTCH
            and   #$7F
            sta   RE_TMP2            ;NOT RE_TMP: the caller's
            pla                      ;skip count lives there
            asl
            tax
            jmp   (RE_CLSJMP,x)
RE_CLSJMP   da    C_ALPHA,C_DIGIT,C_ALNUM,C_UPPER
            da    C_LOWER,C_SPACE,C_BLANK,C_PUNCT
            da    C_PRINT,C_CNTRL,C_GRAPH,C_XDIGIT
RE_CLSNAMES asc   "alpha"
            dfb   0
            asc   "digit"
            dfb   0
            asc   "alnum"
            dfb   0
            asc   "upper"
            dfb   0
            asc   "lower"
            dfb   0
            asc   "space"
            dfb   0
            asc   "blank"
            dfb   0
            asc   "punct"
            dfb   0
            asc   "print"
            dfb   0
            asc   "cntrl"
            dfb   0
            asc   "graph"
            dfb   0
            asc   "xdigit"
            dfb   0,0

C_UPPER     lda   RE_TMP2
            cmp   #$41
            bcc   CLS_NO
            cmp   #$5B
            bcc   CLS_YES
            bra   CLS_NO
C_LOWER     lda   RE_TMP2
            cmp   #$61
            bcc   CLS_NO
            cmp   #$7B
            bcc   CLS_YES
            bra   CLS_NO
C_DIGIT     lda   RE_TMP2
            cmp   #$30
            bcc   CLS_NO
            cmp   #$3A
            bcc   CLS_YES
            bra   CLS_NO
C_ALPHA     jsr   C_UPPER
            bcs   CLS_YES
            bra   C_LOWER
C_ALNUM     jsr   C_ALPHA
            bcs   CLS_YES
            bra   C_DIGIT
CLS_YES     sec                      ;the shared exits sit mid-
            rts                      ;list so every routine's
CLS_NO      clc                      ;branch reaches them
            rts
C_XDIGIT    jsr   C_DIGIT
            bcs   CLS_YES
            lda   RE_TMP2
            cmp   #$41
            bcc   CLS_NO
            cmp   #$47
            bcc   CLS_YES
            cmp   #$61
            bcc   CLS_NO
            cmp   #$67
            bcc   CLS_YES
            bra   CLS_NO
C_SPACE     lda   RE_TMP2
            cmp   #$20
            beq   CLS_YES
            cmp   #$09               ;TAB LF VT FF CR
            bcc   CLS_NO
            cmp   #$0E
            bcc   CLS_YES
            bra   CLS_NO
C_BLANK     lda   RE_TMP2
            cmp   #$20
            beq   CLS_YES
            cmp   #$09
            beq   CLS_YES
            bra   CLS_NO
C_CNTRL     lda   RE_TMP2
            cmp   #$20
            bcc   CLS_YES
            cmp   #$7F
            beq   CLS_YES
            bra   CLS_NO
C_PRINT     lda   RE_TMP2
            cmp   #$20
            bcc   CLS_NO
            cmp   #$7F
            bcc   CLS_YES
            bra   CLS_NO
C_GRAPH     lda   RE_TMP2
            cmp   #$21
            bcc   CLS_NO
            cmp   #$7F
            bcc   CLS_YES
            bra   CLS_NO
C_PUNCT     jsr   C_GRAPH
            bcc   CLS_NO
            jsr   C_ALNUM
            bcs   CLS_NO
            bra   CLS_YES

*---------------------------------------------------------------
* RE_GROUPNUM -- which group number is the \( or \) marker AT
* RE_REP (in: A = AKIND to tally, 4 or 5)? Counts that marker
* kind from PTR1 (the ORIGINAL pattern start -- unclobbered by
* anything in this file) up to and including RE_REP, walking
* the pattern one atom at a time via RE_ATOM_PARSE so a class
* or an escape is skipped as a whole token rather than scanned
* byte-by-byte (a literal '(' inside [a-z()] must not count).
* OUT: A = count, saturated to 0 past 9 (an untracked group --
* the caller skips recording it). CLOBBERS RE_REP (the caller
* always restores it from its own RE_NEWREP right after, never
* reads it back here).
*---------------------------------------------------------------
RE_GROUPNUM sta   RE_GNKIND
            lda   RE_REP
            sta   RE_GNTARG
            lda   RE_REP+1
            sta   RE_GNTARG+1
            lda   #0
            sta   RE_GNCNT
            lda   PTR1
            sta   RE_REP
            lda   PTR1+1
            sta   RE_REP+1
:gnloop     ldy   #0
            lda   (RE_REP),y
            bne   :gnatom
            jsr   RE_PLANTED         ;(W5d) RE_GSTAR's temporary
            bcc   :gnzero            ;NUL over a \): a group
            lda   #5                 ;AFTER a \(..\)* used to
            sta   RE_AKIND           ;number as 0 here and lose
            clc                      ;its capture. Not planted:
            lda   RE_REP             ;the pattern's own NUL
            adc   #2
            sta   RE_NEWREP
            lda   RE_REP+1
            adc   #0
            sta   RE_NEWREP+1
            bra   :gnkind
:gnatom     jsr   RE_ATOM_PARSE
:gnkind     lda   RE_AKIND
            cmp   RE_GNKIND
            bne   :gnchk
            inc   RE_GNCNT
:gnchk      lda   RE_REP
            cmp   RE_GNTARG
            bne   :gnnext
            lda   RE_REP+1
            cmp   RE_GNTARG+1
            beq   :gndone
:gnnext     lda   RE_NEWREP
            sta   RE_REP
            lda   RE_NEWREP+1
            sta   RE_REP+1
            bra   :gnloop
:gnzero     lda   #0
            sta   RE_GNCNT
:gndone     lda   RE_GNCNT
            cmp   #10
            bcc   :gnret
            lda   #0
:gnret      rts

* -- RE_PLANTED: carry set = RE_REP sits on the NUL RE_GSTAR
* -- planted over a \) (a group repeat is active and the
* -- pointers agree). Absolute cells, valid only while
* -- RE_GSACT is set -- RE_MATCH clears it at entry.
RE_PLANTED  lda   RE_GSACT
            beq   :no
            lda   RE_REP
            cmp   RE_GSTOPPTR
            bne   :no
            lda   RE_REP+1
            cmp   RE_GSTOPPTR+1
            bne   :no
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* RE_FINDCLOS -- find the \) matching the \( whose content
* starts at RE_NEWREP (set by the RE_ATOM_PARSE call that just
* classified the \( itself, still fresh in the caller). Depth-
* counts nested \( / \) via RE_ATOM_PARSE, reusing RE_GNCNT as
* the depth counter (RE_GROUPNUM and this routine never run at
* once), so a nested group inside a starred group's own
* content is skipped as a whole rather than mistaken for the
* outer close. OUT: RE_GE = ptr to the matching \)'s own
* backslash byte, carry set. Carry clear = unbalanced (ran off
* the pattern's NUL first) -- caller treats that like AKIND=3,
* a safe no-match. CLOBBERS RE_REP.
*---------------------------------------------------------------
RE_FINDCLOS lda   #1
            sta   RE_GNCNT
            lda   RE_NEWREP
            sta   RE_REP
            lda   RE_NEWREP+1
            sta   RE_REP+1
:fcloop     ldy   #0
            lda   (RE_REP),y
            beq   :fcbad
            jsr   RE_ATOM_PARSE
            lda   RE_AKIND
            cmp   #4
            bne   :fcck5
            inc   RE_GNCNT
            bra   :fcadv
:fcck5      cmp   #5
            bne   :fcadv
            dec   RE_GNCNT
            bne   :fcadv
            lda   RE_REP              ;depth just hit 0 -- THIS
            sta   RE_GE                ;\) is the match
            lda   RE_REP+1
            sta   RE_GE+1
            sec
            rts
:fcadv      lda   RE_NEWREP
            sta   RE_REP
            lda   RE_NEWREP+1
            sta   RE_REP+1
            bra   :fcloop
:fcbad      clc
            rts

*---------------------------------------------------------------
* RE_BKMATCH -- match a \N backreference (in: A = group 1-9,
* RE_ATOM_PARSE's RE_ACHAR for AKIND=6) against the text at
* RE_RET. Walks [RE_GRPST[n],RE_GRPEND[n]) comparing byte for
* byte against (RE_RET),Y, using RE_TMPPTR as the group-side
* cursor -- idle here, since RE_CLASS_TEST's own use of it
* never overlaps a backref's straight-line compare (see the
* header note on RE_TMPPTR at the top of this file) -- and
* RE_GNTARG (RE_GROUPNUM's own scratch, equally idle here) to
* hold the group's end ptr. OUT: carry set + RE_RET advanced
* past the matched text = matched; carry clear = failed (a
* mismatch, text ran out first, or an UNSET group -- RE_GRPST's
* $FF hi-byte sentinel that RE_MATCH primes at its own entry).
*---------------------------------------------------------------
RE_BKMATCH  sec
            sbc   #1
            asl
            tax
            lda   RE_GRPST+1,x
            cmp   #$FF
            beq   :bkfail             ;never captured
            lda   RE_GRPST,x
            sta   RE_TMPPTR
            lda   RE_GRPST+1,x
            sta   RE_TMPPTR+1
            lda   RE_GRPEND,x
            sta   RE_GNTARG
            lda   RE_GRPEND+1,x
            sta   RE_GNTARG+1
:bkloop     lda   RE_TMPPTR
            cmp   RE_GNTARG
            bne   :bkgo
            lda   RE_TMPPTR+1
            cmp   RE_GNTARG+1
            beq   :bkdone             ;reached group end -- OK
:bkgo       ldy   #0
            lda   (RE_RET),y
            beq   :bkfail             ;text exhausted
            cmp   (RE_TMPPTR),y
            bne   :bkfail
            inc   RE_TMPPTR
            bne   :bkgo2
            inc   RE_TMPPTR+1
:bkgo2      inc   RE_RET
            bne   :bkloop
            inc   RE_RET+1
            bra   :bkloop
:bkdone     sec
            rts
:bkfail     clc
            rts

*---------------------------------------------------------------
* RE_GSTAR -- \(...\)* : zero-or-more repetitions of a WHOLE
* subexpression, with backtrack over the repetition COUNT (not
* a single character). Entered by tail JMP from RE_MATCHHERE's
* \( dispatch with RE_GS/RE_GE/RE_GCONT/RE_GNUM already set and
* the text position where the group begins in RE_RET.
*
* Greedily matches [RE_GS,RE_GE) against the text as many
* times as it can (RE_GSCAP = 255 reps, the count's byte; a
* line is at most 255 bytes anyway), EACH ATTEMPT BOUNDED
* to the subexpression by planting a temporary NUL at RE_GE and
* restoring the saved byte once the WHOLE routine is done (both
* the greedy scan below and the redo loop that follows need it
* -- neither one's own forward walk ever runs PAST RE_GE, so
* leaving it planted the whole time costs nothing) -- so the
* UNMODIFIED RE_MATCHHERE loop supplies "pattern exhausted ==
* success" for free, with NO new stop-pointer plumbing in the
* hot loop every other consumer pays for too.
*
* Then backtracks the COUNT against RE_GCONT (the pattern after
* the '*'), RE-DERIVING the text position for each candidate
* count by re-running that many bounded reps from RE_GSTART0 --
* trading a few redundant (cheap, already-known-to-succeed)
* bounded matches for a FIXED-SIZE routine with no rep-count-
* sized buffer at all, unlike an earlier version of this code
* that kept one (see the commit this landed in -- it blew a
* size budget `check-dialect`'s as.s window catches and no
* functional gate can). RE_GRPST/RE_GRPEND for RE_GNUM are set
* from the LAST rep of whichever count wins, in BOTH the greedy
* scan and the redo loop -- exact for every count, not just the
* greedy max.
*
* Nesting a \(...\)* inside another \(...\)* is untested
* territory this feature does not claim (a PHX/PLX bracket
* around each JSR RE_MATCHHERE below protects the redo loop's
* own rep counter from an inner group/backref/group-star's use
* of X, but two ACTIVE levels of this routine competing for
* RE_GSTOPPTR/RE_GSAVE/RE_GS/RE_GE/RE_GCONT/RE_GNUM/RE_GCOUNT/
* RE_GSTART0 -- all single-instance, not stacked -- is not).
*
* OUT: carry set, RE_RET = match end -- same contract as
* RE_MATCHHERE. Carry clear = fail.
*---------------------------------------------------------------
RE_GSCAP    equ   255                ;(W5d) was 8: \(ab\)\{10\}
                                     ;could never be met. The
                                     ;redo loop keeps no per-rep
                                     ;buffer, so the count is
                                     ;free to fill its byte.

*-- (W5b) The interval family applies to a group too:
*-- \(..\)\{n,m\} / \+ / \?. RE_REPOP left the floor/ceiling in
*-- RE_RMIN/RMAX/RINF; copy them FIRST, because the group's own
*-- content goes through RE_MATCHHERE below and any operator in
*-- it overwrites those three. The greedy scan stops at the
*-- ceiling, the redo
*-- loop backs the count down to the FLOOR instead of to 0, and
*-- a greedy count under the floor fails outright. A plain `*`
*-- arrives as floor 0 / no ceiling, so its path is unchanged.
RE_GSTAR    lda   RE_RMIN
            sta   RE_GRMIN
            lda   RE_RMAX
            sta   RE_GRMAX
            lda   RE_RINF
            sta   RE_GRINF
*-- (W5d) PRIVATE copies of the content start, the continuation
*-- and the group number: a \( inside the CONTINUATION rewrites
*-- RE_GS/RE_GE/RE_GNUM (the :gopen dispatch's own cells), and
*-- the redo loop below used to re-run the reps with THAT
*-- group's content after a failed continuation -- the reason
*-- \(a*\)*\(x\)\(\1\) could not be made to match ax.
*-- RE_GSTOPPTR already is the private RE_GE.
            lda   RE_GS
            sta   RE_GSS
            lda   RE_GS+1
            sta   RE_GSS+1
            lda   RE_GCONT
            sta   RE_GCC
            lda   RE_GCONT+1
            sta   RE_GCC+1
            lda   RE_GNUM
            sta   RE_GNN
            lda   RE_RET
            sta   RE_GSTART0
            lda   RE_RET+1
            sta   RE_GSTART0+1
            lda   #0
            sta   RE_GCOUNT

            lda   RE_GE
            sta   RE_GSTOPPTR
            lda   RE_GE+1
            sta   RE_GSTOPPTR+1
            ldy   #0
            lda   (RE_GSTOPPTR),y
            sta   RE_GSAVE
            lda   #0
            sta   (RE_GSTOPPTR),y
            lda   #1                 ;(W5d) RE_GROUPNUM reads
            sta   RE_GSACT           ;that NUL as a \)

:gsloop     lda   RE_GCOUNT
            cmp   #RE_GSCAP
            bcs   :gsdone
            lda   RE_GRINF
            bne   :gsgo
            lda   RE_GCOUNT
            cmp   RE_GRMAX
            bcs   :gsdone            ;at the ceiling
:gsgo       lda   RE_RET             ;this rep's own start
            pha
            lda   RE_RET+1
            pha
            lda   RE_GSS
            sta   RE_REP
            lda   RE_GSS+1
            sta   RE_REP+1
            jsr   RE_MATCHHERE
            bcc   :gspopf
            pla
            sta   RE_TMPPTR+1        ;this rep's start (idle
            pla                      ;scratch, see RE_BKMATCH's
            sta   RE_TMPPTR          ;own header)
            lda   RE_TMPPTR
            cmp   RE_RET
            bne   :gsnz
            lda   RE_TMPPTR+1
            cmp   RE_RET+1
            bne   :gsnz
            lda   RE_GCOUNT          ;zero-length rep -- stop;
            bne   :gsdone            ;(W5d) if it is the ONLY
            jsr   RE_GSSAVE          ;iteration it still SETS
            bra   :gsdone            ;the group, empty (POSIX:
                                     ;on x gives (0,0), and \1
                                     ;then matches the empty)
:gsnz       jsr   RE_GSSAVE          ;RE_GRPST/END[RE_GNN] =
                                     ;RE_TMPPTR..RE_RET
            inc   RE_GCOUNT
            bra   :gsloop
:gspopf     pla
            pla                      ;discard the pushed start
:gsdone     lda   RE_GCOUNT
            cmp   RE_GRMIN
            bcs   :gsback            ;fewer reps than the floor:
            jmp   :gsfail            ;fail (past branch reach)

* redo: for count = RE_GCOUNT downto the FLOOR (RE_GRMIN),
* RE-RUN that many reps
* from RE_GSTART0 (each already known to succeed -- it did
* during the greedy scan above) and try RE_GCC at the result.
:gsback     lda   RE_GSTART0
            sta   RE_RET
            lda   RE_GSTART0+1
            sta   RE_RET+1
            ldx   #0
:gsredo     cpx   RE_GCOUNT
            beq   :gsrdone
            lda   RE_RET
            pha
            lda   RE_RET+1
            pha
            lda   RE_GSS
            sta   RE_REP
            lda   RE_GSS+1
            sta   RE_REP+1
            phx
            jsr   RE_MATCHHERE
            plx
            pla
            sta   RE_TMPPTR+1
            pla
            sta   RE_TMPPTR
            phx
            jsr   RE_GSSAVE
            plx
            inx
            bra   :gsredo
:gsrdone    lda   RE_RET             ;the position after the
            pha                      ;reps -- the continuation
            lda   RE_RET+1           ;clobbers RE_RET
            pha
            lda   RE_GCC
            sta   RE_REP
            lda   RE_GCC+1
            sta   RE_REP+1
            jsr   RE_MATCHHERE
            bcs   :gspopok
            pla
            sta   RE_TMPPTR+1
            pla
            sta   RE_TMPPTR
*-- (W5d) POSIX's empty iteration: when the continuation fails
*-- with the group's capture set from its last NON-empty rep,
*-- the star may take one more, EMPTY, iteration here -- if the
*-- content can match nothing at this position -- which sets
*-- the group to (pos,pos), so a later \N is empty. Fowler's
*-- nullsubexpr rows 58/61: \(a*\)*\(x\)\(\1\) on ax is
*-- (0,2)(1,1)(1,2)(2,2). Tried AFTER the real capture, so in
*-- longest mode a tie keeps the real one (row 55).
            lda   RE_GNN
            beq   :gsnext            ;untracked group: no \N
            lda   RE_TMPPTR
            sta   RE_RET
            lda   RE_TMPPTR+1
            sta   RE_RET+1
            lda   RE_GSS
            sta   RE_REP
            lda   RE_GSS+1
            sta   RE_REP+1
            jsr   RE_MATCHHERE       ;bounded by the planted NUL
            bcc   :gsnext
            lda   RE_RET
            cmp   RE_TMPPTR
            bne   :gsnext            ;not empty: already tried
            lda   RE_RET+1
            cmp   RE_TMPPTR+1
            bne   :gsnext
            jsr   RE_GSSAVE          ;group := (pos,pos)
            lda   RE_GCC
            sta   RE_REP
            lda   RE_GCC+1
            sta   RE_REP+1
            jsr   RE_MATCHHERE
            bcs   :gssucc
:gsnext     lda   RE_GCOUNT
            cmp   RE_GRMIN
            beq   :gsfail            ;at the floor -- done
            dec   RE_GCOUNT
            jmp   :gsback
:gspopok    pla
            pla
            bra   :gssucc
:gsfail     ldy   #0
            lda   RE_GSAVE
            sta   (RE_GSTOPPTR),y
            stz   RE_GSACT
            clc
            rts
:gssucc     ldy   #0
            lda   RE_GSAVE
            sta   (RE_GSTOPPTR),y
            stz   RE_GSACT
            sec
            rts

*---------------------------------------------------------------
* RE_GSSAVE -- if RE_GNN is tracked (nonzero), record
* [RE_TMPPTR,RE_RET) as group RE_GNN's captured bounds.
* Factored out of RE_GSTAR's greedy scan and its redo loop --
* both set the SAME pair from the SAME two registers, once per
* rep. CLOBBERS A/X only.
*---------------------------------------------------------------
RE_GSSAVE   lda   RE_GNN
            beq   :gssk
            sec
            sbc   #1
            asl
            tax
            lda   RE_TMPPTR
            sta   RE_GRPST,x
            lda   RE_TMPPTR+1
            sta   RE_GRPST+1,x
            lda   RE_RET
            sta   RE_GRPEND,x
            lda   RE_RET+1
            sta   RE_GRPEND+1,x
:gssk       rts

* -- RE_GRPST/RE_GRPEND (\( \) \1-\9 capture storage, W5):
* -- declared in src/liba/regexbss.s, a SEPARATE `dum` block
* -- from libabss.s's own -- see that file's own header for
* -- why (libabss.s is put by every program including as.s,
* -- which never links regex.s at all, and its `err */SYMADR`
* -- size tripwire had no room for 36 more bytes there).
* -- Every `put regex.s` site also `put`s regexbss.s and
* -- repoints its OWN trailing `dum` to chain onto
* -- REGEX_BSSEND instead of LIBA_BSSEND directly. Read/
* -- written only via X-indexed absolute addressing
* -- (RE_GRPST,x etc), never (ptr),y, so they cost no ZP room.
