*---------------------------------------------------------------
* findexpr.s -- find's expression engine: tokenize argv[2..]
* ONCE (TOKENIZE), then evaluate the SAME token array fresh for
* every visited path (EVAL_TOP, called from findtop.s's WALK).
* Extracted from find.s at a GLOBAL boundary, same "tier 2
* mains" discipline findtop.s/findact.s already established --
* one assembly stream, `put` exactly where the text sat.
*
* GRAMMAR (POSIX find XCU, "order of decreasing precedence"):
* expr := term { -o term } (OR) term := factor { [-a] factor }
* (AND, incl. implicit) factor:= '!' factor | '(' expr ')' |
* primary EVAL_EXPR/EVAL_TERM/EVAL_FACT implement this 1:1 by
* mutual recursion, one JSR level per grammar rule. Recursion
* depth is bounded AT TOKENIZE TIME (FIND_MAXNST simultaneous
* open parens, and independently FIND_MAXNST total `!` tokens),
* so the worst case cannot overrun the 256-byte hardware stack.
*
* SHORT-CIRCUIT via an EXPLICIT SOFTWARE STACK (EVALSTACK/
* EVALSP, EV_ENTER/EV_LEAVE/EV_GETACT/EV_SETRES/EV_GETRES
* below), not by
* skipping tokens textually. Every one of EVAL_EXPR/TERM/FACT
* takes an "active" flag (A on entry) and pushes it into a NEW
* frame; "active" and the frame's own running result both have
* to survive arbitrarily deep RECURSIVE calls the same routine
* makes to itself (via a paren or a chain of ANDs/ORs), and a
* flat dum byte would be clobbered by the very first nested call
* -- hence the array-indexed software stack instead of the
* hardware one (which holds no per-call state any caller here
* needs back, so ordinary JSR/RTS pairing is untouched). The
* right operand of `-a`/`-o` is handed active=0 exactly when the
* left side has already decided the whole conjunction/
* disjunction, so it is not merely UNCOUNTED but genuinely never
* evaluated -- no filesystem access, no -exec/-print/-prune side
* effect (POSIX's own wording: "shall not be evaluated").
*
* THE SAME EVALUATOR IS THE SYNTAX CHECKER (VALIDATE): a dry run
* with active=0 from TOKI=0 can never touch the filesystem
* (FACT_PRIM guards every real test behind EV_GETACT), so
* running it once at parse time both catches a malformed
* expression AND proves the grammar is exercised by the one
* implementation that matters, not a second hand-written checker
* that could disagree with it.
*
* DEFAULT -PRINT (POSIX: "if the given expression does not
* contain any of the primaries -exec, -ok, or -print, the given
* expression shall be effectively replaced by ( given expression
* ) -print" -- NOTE, precisely: NOT -prune. A bare `find DIR
* -prune` still gets a trailing -print, exactly like `find DIR`
* alone would; only -exec/-print (this tool has no -ok) count.
* EVAL_TOP implements the rewrite WITHOUT splicing LPAREN/
* RPAREN/PRINT tokens into the array: EVAL_EXPR already
* reduces the WHOLE given expression, however it is shaped, to
* one boolean; running -print exactly when that boolean is true
* and no real action ever fired is definitionally the same thing
* as "(given expression) -print" wrapped in real parens.
*
* -newer/-mtime/-size all RE-STAT the CURRENT path fresh (see
* STATPATH/GETSIZE) rather than trusting whatever WALK happened
* to have on hand for it. That is a deliberate choice, not a
* missed optimization: GET_FILE_INFO's own parmlist (TRM 4.4.3)
* has no EOF field at all, and READDIR's raw per-entry record
* (readdir.s) has no blocks_used field -- so the root argument
* (stat'd via GET_FILE_INFO in WALK) and a descendant (read via
* READDIR) hand WALK two DIFFERENT-shaped answers, and
* reconciling them so -size sees the same thing for both would
* cost more than just asking ProDOS again uniformly. -mtime/
* -newer read mod_date/mod_time, which BOTH shapes carry, but
* re-stating keeps the rule ONE rule ("ask ProDOS
* this file's own question") instead of two rules that happen to
* agree on that one field today.
*
* WHAT -mtime MEASURES, exactly, and where it is NOT precise:
* POSIX defines it as floor((initialization_time - mtime) /
* 86400) in SECONDS. This tool has no seconds-since-epoch clock
* value anywhere -- SC_CLOCK (src/liba/syscallp.s) hands back a
* ProDOS date+time-of-day pair, the same shape mod_date/mod_time
* already are -- so TESTMTIME instead computes a CALENDAR-DAY
* difference (DAYNUM(today) - DAYNUM(mtime's date), ignoring
* both sides' time-of-day). That is NOT the same number at a day
* boundary: a file touched 30 hours ago, if the calendar rolled
* over TWICE, one day off from a real 86400-second count would
* say once. Documented here rather than hidden; see docs/
* POSIX-GAPS.md. CLOCKOK=0 (no clock at boot, or an unreadable/
* Extended stamp -- same validity rule date.s/ls.s already use)
* makes -mtime FALSE for every file, per this task's own
* instruction, never an error.
*
* WHAT -size MEASURES: GET_EOF's own byte count via a fresh
* OPEN+GET_EOF+CLOSE (src/liba/syscalls.s already wraps GET_EOF
* as SC_GETEOF -- seek.s's LSEEK composes it for SEEK_END, this
* file calls it directly). `-size N` rounds UP to 512-byte
* blocks (POSIX's own rounding); `-size Nc` is bytes. N's
* magnitude is a 16-bit word (0-65535); a file at or past 64K
* bytes with the `c` suffix saturates the comparison rather than
* wrapping -- see TESTSIZE's own header for the exact edge.
*
* WHAT -newer MEASURES: a plain (mod_date, mod_time) pair
* compared as an unsigned magnitude, date first then time on a
* tie -- correct because of how ProDOS packs each word (TRM ch.
* 4: date is year:month:day from the TOP bits down, time is
* hour:minute the same way), so ordinary unsigned byte compares
* already collate correctly; no epoch conversion is needed or
* done. See DTGT.
*
* GAP ROWS not handled here at all (fall through TOKENIZE's
* dispatch loop to USAGE_ERR, same as any other unrecognized
* word): -perm, -user, -group -- permanent, see find.s's header.
* -depth and -ok SHIPPED 2026-10-08: -depth is an always-true
* primary whose only effect is DEPTHFLAG, read by WALK; -ok is
* -exec with OKFLAG set, which makes ACT_EXEC ask first.
*---------------------------------------------------------------

TT_END      equ   0
TT_LPAR     equ   1
TT_RPAR     equ   2
TT_NOT      equ   3
TT_AND      equ   4
TT_OR       equ   5
TT_NAME     equ   6
TT_TYPE     equ   7
TT_PRINT    equ   8
TT_PRUNE    equ   9
TT_EXEC     equ   10
TT_NEWER    equ   11
TT_MTIME    equ   12
TT_SIZEB    equ   13
TT_SIZEC    equ   14
TT_PATH     equ   15
TT_LINKS    equ   16
TT_XDEV     equ   17
TT_NOUSER   equ   18
TT_NOGROUP  equ   19
TT_DEPTH    equ   20
TT_OK       equ   21

AK_NONE     equ   0
AK_PTR      equ   1
AK_TYPE     equ   2
AK_NEWER    equ   3
AK_EXEC     equ   4
AK_NUM      equ   5
AK_NUMC     equ   6

FLAGCNT     equ   20

*---------------------------------------------------------------
* TOKENIZE -- argv[2..] -> TOKTYPE/TOKSIGN/TOKVLO/TOKVHI[0..
* NTOK-1], TT_END appended at [NTOK]. PARSE (findtop.s) calls
* this AFTER copying argv[1] into PATHBUF, exactly as the old
* single-pass PARSE did. Any malformed word, capacity overflow,
* or nesting past FIND_MAXNST is a USAGE_ERR (exit 2) -- the
* SAME family as every other "too complex"/"too long" refusal
* this file already had. CLOBBERS: everything.
*---------------------------------------------------------------
TOKENIZE    stz   NTOK
            stz   DEPTHFLAG
            stz   ANYACTION
            stz   PARENDEPTH
            stz   NOTCOUNT
            stz   EXECNSLOT
            stz   CLOCKNEED
            lda   #2
            sta   PARSEI
:tloop      lda   PARSEI
            cmp   ARGC
            bcc   :thave
            jmp   TOKDONE
:thave      lda   PARSEI
            jsr   GETARG
            inc   PARSEI
            ldx   #0
:tscan      cpx   #FLAGCNT
            bcc   :tscango
            jmp   TOKBADFLG
:tscango    lda   FLAGSTRLO,x
            sta   PTR1
            lda   FLAGSTRHI,x
            sta   PTR1+1
            jsr   STRCMP
            beq   :tfound
            inx
            bra   :tscan
:tfound     lda   FLAGARGK,x
            sta   CURAK
            lda   NTOK
            cmp   #FIND_MAXTOK
            bcc   :ttokrm
            jmp   TOKBADFLG
:ttokrm     ldy   NTOK
            lda   FLAGTOK,x
            sta   TOKTYPE,y
            pha
            lda   #0
            sta   TOKSIGN,y
            sta   TOKVLO,y
            sta   TOKVHI,y
            pla
            cmp   #TT_LPAR
            bne   :tckrp
            inc   PARENDEPTH
            lda   PARENDEPTH
            cmp   #FIND_MAXNST
            bcc   :takarg
            jmp   TOKBADFLG
:tckrp      cmp   #TT_RPAR
            bne   :tcknot
            lda   PARENDEPTH
            beq   :takarg
            dec   PARENDEPTH
            bra   :takarg
:tcknot     cmp   #TT_NOT
            bne   :tckact
            inc   NOTCOUNT
            lda   NOTCOUNT
            cmp   #FIND_MAXNST
            bcc   :takarg
            jmp   TOKBADFLG
:tckact     cmp   #TT_PRINT
            beq   :tsetact
            cmp   #TT_OK
            beq   :tsetact
            cmp   #TT_EXEC
            bne   :tckclk
:tsetact    lda   #1
            sta   ANYACTION
:tckclk     lda   TOKTYPE,y
            cmp   #TT_MTIME
            bne   :tckdep
            lda   #1
            sta   CLOCKNEED
            bra   :takarg
:tckdep     cmp   #TT_DEPTH
            bne   :takarg
            lda   #1
            sta   DEPTHFLAG
:takarg     lda   CURAK
            bne   :takarg2
            jmp   :tdonewd
:takarg2    cmp   #AK_PTR
            bne   :takarg3
            jmp   :taptr
:takarg3    cmp   #AK_TYPE
            bne   :takarg4
            jmp   :tatype
:takarg4    cmp   #AK_NEWER
            bne   :takarg5
            jmp   :tanewr
:takarg5    cmp   #AK_EXEC
            bne   :takarg6
            jmp   :taexec
:takarg6    cmp   #AK_NUM
            bne   :takarg7
            jmp   :tanum
:takarg7    jsr   TOKNEXTWD
            lda   #1
            jsr   PARSENUM
            bcc   :tnumcok
            jmp   TOKBADFLG
:tnumcok    ldy   NTOK
            lda   NPSIGN
            sta   TOKSIGN,y
            lda   NPVLO
            sta   TOKVLO,y
            lda   NPVHI
            sta   TOKVHI,y
            lda   NPSUF
            beq   :tszdone
            lda   #TT_SIZEC
            sta   TOKTYPE,y
:tszdone    jmp   :tdonewd
:tanum      jsr   TOKNEXTWD
            lda   #0
            jsr   PARSENUM
            bcc   :tnumok
            jmp   TOKBADFLG
:tnumok     ldy   NTOK
            lda   NPSIGN
            sta   TOKSIGN,y
            lda   NPVLO
            sta   TOKVLO,y
            lda   NPVHI
            sta   TOKVHI,y
            jmp   :tdonewd
:taptr      jsr   TOKNEXTWD
            ldy   NTOK
            lda   PTR0
            sta   TOKVLO,y
            lda   PTR0+1
            sta   TOKVHI,y
            jmp   :tdonewd
:tatype     jsr   TOKNEXTWD
            ldy   #0
            lda   (PTR0),y
            cmp   #$E6
            beq   :tatf
            cmp   #$E4
            beq   :tatd
            jmp   TOKBADFLG
:tatf       ldy   NTOK
            lda   #$E6
            sta   TOKVLO,y
            bra   :tatck
:tatd       ldy   NTOK
            lda   #$E4
            sta   TOKVLO,y
:tatck      ldy   #1
            lda   (PTR0),y
            beq   :tatok
            jmp   TOKBADFLG
:tatok      jmp   :tdonewd
:tanewr     jsr   TOKNEXTWD
            jsr   NEWERSTAT
            jmp   :tdonewd
:taexec     lda   EXECNSLOT
            cmp   #FIND_MAXEXEC
            bcc   :taexr
            jmp   TOKBADFLG
:taexr      ldy   NTOK
            lda   EXECNSLOT
            sta   TOKVLO,y
            jsr   TOKEXECWD
            inc   EXECNSLOT
:tdonewd    inc   NTOK
            jmp   :tloop
TOKBADFLG   jmp   USAGE_ERR
TOKDONE     ldy   NTOK
            lda   #TT_END
            sta   TOKTYPE,y
            rts

*---------------------------------------------------------------
* TOKNEXTWD -- consume the NEXT argv word for a 1-word primary
* argument (-name/-type/-newer/-mtime/-size/-links/-path).
* OUT: PTR0=word. USAGE_ERR (does not return) if none left.
* CLOBBERS: A, PTR0.
*---------------------------------------------------------------
TOKNEXTWD   lda   PARSEI
            cmp   ARGC
            bcc   :tnwok
            jmp   USAGE_ERR
:tnwok      lda   PARSEI
            jsr   GETARG
            inc   PARSEI
            rts

*---------------------------------------------------------------
* TOKEXECWD -- consume words into EXECTPL's EXECNSLOT-th slot
* until a bare ";" (same "must be EXACTLY ;" rule the old
* single-exec PARSE used). USAGE_ERR on a missing terminator
* or a template past FIND_EXCAP words in this ONE slot.
* CLOBBERS: everything.
*---------------------------------------------------------------
TOKEXECWD   lda   EXECNSLOT
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            sta   EXBASE
            clc
            adc   #FIND_EXCAP
            sta   EXCAPABS
            lda   EXBASE
            sta   EXOFF
:xloop      lda   PARSEI
            cmp   ARGC
            bcc   :xhave
            jmp   USAGE_ERR
:xhave      lda   PARSEI
            jsr   GETARG
            inc   PARSEI
            ldy   #0
            lda   (PTR0),y
            cmp   #$BB
            bne   :xnotsemi
            iny
            lda   (PTR0),y
            bne   :xnotsemi
            ldx   EXOFF
            stz   EXECTPL,x
            stz   EXECTPL+1,x
            rts
:xnotsemi   lda   EXOFF
            cmp   EXCAPABS
            bcc   :xroom
            jmp   USAGE_ERR
:xroom      ldx   EXOFF
            lda   PTR0
            sta   EXECTPL,x
            lda   PTR0+1
            sta   EXECTPL+1,x
            inc   EXOFF
            inc   EXOFF
            bra   :xloop

*---------------------------------------------------------------
* PARSENUM -- a POSIX find numeric argument: optional leading
* +/-, one or more digits, and (IN: A=1 only) an optional
* trailing 'c'. IN: PTR0=word, A=1 allow the 'c' suffix else 0.
* OUT: carry clear=ok (NPSIGN 0/1/2=exact/+/-, NPVLO/NPVHI=
* 16-bit magnitude, NPSUF=1 if 'c' seen); carry set=malformed.
* PTR0 untouched. CLOBBERS: A, Y.
*---------------------------------------------------------------
PARSENUM    sta   NPALLOWC
            stz   NPSIGN
            stz   NPVLO
            stz   NPVHI
            stz   NPSUF
            stz   NPDIGN
            ldy   #0
            lda   (PTR0),y
            cmp   #$AB
            bne   :pnchkmin
            lda   #1
            sta   NPSIGN
            iny
            bra   :pnloop
:pnchkmin   cmp   #$AD
            bne   :pnloop
            lda   #2
            sta   NPSIGN
            iny
:pnloop     lda   (PTR0),y
            beq   :pnend
            cmp   #$B0
            bcc   :pnc
            cmp   #$BA
            bcs   :pnc
            sec
            sbc   #$B0
            jsr   PN_ACCUM
            lda   #1
            sta   NPDIGN
            iny
            bra   :pnloop
:pnc        cmp   #$E3
            bne   :pnbad
            lda   NPALLOWC
            beq   :pnbad
            iny
            lda   (PTR0),y
            bne   :pnbad
            lda   #1
            sta   NPSUF
:pnend      lda   NPDIGN
            beq   :pnbad
            clc
            rts
:pnbad      sec
            rts

*---------------------------------------------------------------
* PN_ACCUM -- NPVLO/NPVHI := NPVLO/NPVHI*10 + A (A a 0-9 digit
* value). CLOBBERS: A.
*---------------------------------------------------------------
PN_ACCUM    pha
            lda   NPVLO
            sta   DNRESLO
            lda   NPVHI
            sta   DNRESHI
            asl   DNRESLO
            rol   DNRESHI
            lda   DNRESLO
            sta   CSTMP
            lda   DNRESHI
            sta   CSTMP2
            asl   DNRESLO
            rol   DNRESHI
            asl   DNRESLO
            rol   DNRESHI
            clc
            lda   DNRESLO
            adc   CSTMP
            sta   NPVLO
            lda   DNRESHI
            adc   CSTMP2
            sta   NPVHI
            pla
            clc
            adc   NPVLO
            sta   NPVLO
            bcc   :pnnc
            inc   NPVHI
:pnnc       rts

*---------------------------------------------------------------
* NEWERSTAT -- IN: PTR0 = the -newer FILE argv word. Fills
* NEWERMD/NEWERMT via GET_FILE_INFO. A file that will not stat
* is a real error (not a syntax one): print "find: FILE: cannot
* access" to stderr and EXIT(1) -- ERRPFX/ERRSUF_ACC are
* findact.s's own Data strings, reused verbatim. CLOBBERS:
* everything.
*---------------------------------------------------------------
NEWERSTAT   lda   PTR0
            sta   EVPATH
            lda   PTR0+1
            sta   EVPATH+1
            lda   #<EVMLIP
            sta   PTR1
            lda   #>EVMLIP
            sta   PTR1+1
            jsr   MKPATH
            lda   #<EVMLIP
            sta   GFIPARM_PATH
            lda   #>EVMLIP
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :nsok
            lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   EVPATH
            sta   PTR0
            lda   EVPATH+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<ERRSUF_ACC
            sta   PTR0
            lda   #>ERRSUF_ACC
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT
:nsok       lda   GFIPARM_MDATE
            sta   NEWERMD
            lda   GFIPARM_MDATE+1
            sta   NEWERMD+1
            lda   GFIPARM_MTIME
            sta   NEWERMT
            lda   GFIPARM_MTIME+1
            sta   NEWERMT+1
            rts

