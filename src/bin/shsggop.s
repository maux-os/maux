*---------------------------------------------------------------
* shsggop.s -- the `getopts` builtin, segment-resident.
* Moved out of shvar2.s 2026-09-16 with NO source change: this
* file is `put` inside sh.s's `org PRC_LC_COMMON` block, so
* every label here resolves at $E000+ and the low image keeps
* only the `jsr`s into it. docs/SH-SUBSET.md ruling 7.6 has
* the mechanism (SEG_INIT, the low copy, the two tripwires).
*
* NOTHING HERE MAY BE REACHED BEFORE SEG_INIT RAN -- it is the
* first thing START (shlex.s) does.
*
* AND NOTHING HERE MAY BE HANDED TO A SYSCALL. The kernel's
* COPYIN_ENTRY/COPYOUT_ENTRY templates (src/kernel/entry2.s)
* REFUSE a process address >= $D000 outright ("LC path not
* wired yet", K_CPY_ERR=2), and BankCopy -- the path a tty or
* file write's BUFFER takes -- is built on them. So the
* strings, parmlists and buffers these routines hand to
* PUTS/PR_ERRAX/SC_* stayed behind in shvar2.s; only CODE moved.
*---------------------------------------------------------------

*---------------------------------------------------------------
* getopts -- POSIX XCU's `getopts OPTSTRING NAME [ARG...]`
* (docs/SH-FEATURES.md, 2026-09-15). One call parses ONE option
* from the operand list -- CMD_ARGV[3..] if given, else the
* script's OWN positional parameters ($1.."$#", the SAME
* GETARG(N+POS_SHIFT) mapping EMITARG/EMITHASH already use).
* OPTIND/OPTARG are ORDINARY shell variables (VARSET/VARFIND) --
* costing TWO of MAXVARS' eight slots whenever getopts is in use
* (docs/SH-SUBSET.md sec 8.x names this cost). GOPTCIDX (sh.s's
* dum arena) tracks the character offset inside a CLUSTERED
* option word ("-ab") -- that position has no POSIX-visible
* name, so it lives outside the variable table entirely, the
* same way a real shell's own internal getopts state does.
*
* v1 simplification, documented rather than hidden: the loud
* diagnostics do NOT embed the offending option letter (a
* dynamic message would need its own PUTS/PUTC path around
* PR_ERRAX's fixed-string contract) -- "illegal option" and
* "option requires an argument", unqualified. NAME/OPTARG DO
* carry the real letter; only the stderr TEXT is generic.
*
* Command-position only (NCMD==1), same shape as EXPORT/SHIFT.
* OUT: carry SET = recognised (do not spawn); LASTSTATUS/NAME/
* OPTARG/OPTIND set per POSIX. carry CLEAR if this was not
* "GETOPTS" at all. CLOBBERS: A, X, Y, PTR0-2.
*---------------------------------------------------------------
CHCK_BLTN_GOP
            lda   NCMD
            cmp   #1
            beq   :ncmd1
            clc
            rts
:ncmd1      lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            lda   #<GOPTS_STR
            sta   PTR1
            lda   #>GOPTS_STR
            sta   PTR1+1
            jsr   STRCMPI
            beq   :isgopt
            clc
            rts
:isgopt     stz   GOPTFAIL              ;this call's own VARSET
                                        ;failures, checked at
                                        ;GOPT_SETNM (below) --
                                        ;BUG found live on the
                                        ;emulator: a full table
                                        ;made GOPT_SETNM report
                                        ;success FOREVER (VARSET
                                        ;failed silently past
                                        ;its own diagnostic), a
                                        ;`while getopts` loop
                                        ;whose condition never
                                        ;goes false never
                                        ;stops
            lda   CMD_ARGC+0
            cmp   #3
            bcs   :haveargs
            jmp   GOPT_USAGE
*-- NAME's own first-char check, POSIX's "name shall be a valid
*-- shell variable name" -- the same rule CHCK_BLTN_VAR enforces
*-- for a bare assignment. Checked ONCE, before any option is
*-- even looked at: a bad NAME must not consume an operand on
*-- its way to being refused.
:haveargs   lda   CMD_ARGV+4
            sta   PTR0
            lda   CMD_ARGV+5
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            jsr   ISNAME1
            bcs   :nmok
            jmp   GOPT_USAGE
*-- OPTIND may have moved since the LAST call (a fresh process,
*-- or the script itself wrote it -- "OPTIND=1" to restart is
*-- POSIX-sanctioned) -- GOPTLASTOI is what THIS builtin set it
*-- to last time, so a mismatch means "start this operand over".
*-- GOPTLASTOI is then updated to THIS read UNCONDITIONALLY --
*-- BUG FOUND live on the emulator: a no-arg option mid-cluster
*-- (GOPT_ADVCL's "more" branch) advances GOPTCIDX WITHOUT ever
*-- touching OPTIND, so GOPTLASTOI would otherwise still hold
*-- whatever it was before this whole call chain started, never
*-- catching up to the stable value -- every mid-cluster
*-- continuation then misread itself as an EXTERNAL OPTIND
*-- change and reset GOPTCIDX to 1, forever re-parsing the SAME
*-- first letter (`-ab x` looped printing "a:" and never
*-- advanced to `b`). The fix is this one store.
:nmok       jsr   GOPT_RDOI              ;A = effective OPTIND
            cmp   GOPTLASTOI
            beq   :samen
            pha
            lda   #1
            sta   GOPTCIDX
            pla
:samen      sta   GOPTLASTOI
            jsr   GOPT_GETN              ;PTR0 = operand #A, or
            bcc   :havearg               ;  carry set = past the
            jmp   GOPT_NOMORE            ;  last one
:havearg    lda   GOPTCIDX
            cmp   #1
            bne   :midclus
*-- A fresh operand: "-", "--", a plain word, or a real cluster.
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD                   ;'-' high-bit
            beq   :dashfst
            jmp   GOPT_NOMORE            ;not an option word
:dashfst    iny
            lda   (PTR0),y
            bne   :notlone
            jmp   GOPT_NOMORE            ;a lone "-"
:notlone    cmp   #$AD                   ;second '-' too? "--"
            bne   :midclus
            iny
            lda   (PTR0),y
            bne   :midclus               ;"--X" -- a cluster
            jsr   GOPT_ROLL              ;skip the "--" marker
            jmp   GOPT_NOMORE
:midclus    ldy   GOPTCIDX
            lda   (PTR0),y
            sta   GOPTCH
            jsr   GOPT_FIND              ;PTR1/Y -> OPTSTRING
            bcs   :unknown
            iny
            lda   (PTR1),y
            cmp   #$BA                   ;':' -- takes an arg
            beq   :witharg
            jsr   GOPT_ADVCL             ;no arg -- just move on
*-- OPTARG does NOT persist from an EARLIER option's own
*-- argument here -- verified against this host: `-b x` then
*-- `-c` prints "c:", not the stale "c:x" a first cut shipped.
            jsr   VARUNSET_OA
            lda   GOPTCH
            jmp   GOPT_SETNM
:unknown    jsr   GOPT_ADVCL
            jsr   GOPT_SILENT
            bcc   :loudbad
            lda   GOPTCH
            jsr   GOPT_SETOA1
            lda   #$BF                   ;'?'
            jmp   GOPT_SETNM
:loudbad    jsr   VARUNSET_OA            ;loud mode: no stale
                                         ;OPTARG either (host-
                                         ;verified: "?: ", not
                                         ;"?:x")
            lda   #<GOPTBAD_MSG
            ldx   #>GOPTBAD_MSG
            jsr   PR_ERRAX
            lda   #$BF
            jmp   GOPT_SETNM
*-- Rest-of-word first (clustered "-bVALUE"), else the NEXT
*-- operand ("-b VALUE"), else missing.
:witharg    ldy   GOPTCIDX
            iny
            lda   (PTR0),y
            beq   :nextop
            tya
            clc
            adc   PTR0
            sta   GOPTVP
            lda   PTR0+1
            adc   #0
            sta   GOPTVP+1
            jsr   GOPT_ROLL              ;whole rest of this
                                         ;operand is consumed
            lda   GOPTVP
            sta   PTR2
            lda   GOPTVP+1
            sta   PTR2+1
            jsr   GOPT_SETOAP
            lda   GOPTCH
            jmp   GOPT_SETNM
:nextop     jsr   GOPT_RDOI
            clc
            adc   #1
            jsr   GOPT_GETN
            bcc   :haveval
            jsr   GOPT_ROLL
            jsr   GOPT_SILENT
            bcc   :loudmiss
            lda   GOPTCH
            jsr   GOPT_SETOA1
            lda   #$BA                   ;':' -- silent-missing
            jmp   GOPT_SETNM
:loudmiss   lda   #<GOPTREQ_MSG
            ldx   #>GOPTREQ_MSG
            jsr   PR_ERRAX
            jsr   VARUNSET_OA
            lda   #$BF
            jmp   GOPT_SETNM
:haveval    lda   PTR0
            sta   GOPTVP
            lda   PTR0+1
            sta   GOPTVP+1
            jsr   GOPT_ROLL              ;consumes THIS operand
            jsr   GOPT_ROLL              ;  and the value one
            lda   GOPTVP
            sta   PTR2
            lda   GOPTVP+1
            sta   PTR2+1
            jsr   GOPT_SETOAP
            lda   GOPTCH
            jmp   GOPT_SETNM

*---------------------------------------------------------------
* GOPT_RDOI -- OUT: A = the effective current OPTIND (1 if the
* variable is unset). CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
GOPT_RDOI   lda   #<OPTIND_STR
            sta   PTR0
            lda   #>OPTIND_STR
            sta   PTR0+1
            jsr   VARFIND
            bcs   :dflt
            jsr   VSLOT_VAL
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            jmp   PARSE_STATUS
:dflt       lda   #1
            rts

*---------------------------------------------------------------
* GOPT_WROI -- IN: A = new OPTIND value. Renders it decimal and
* VARSETs OPTIND, and remembers it in GOPTLASTOI so the NEXT
* call can tell whether the variable moved on its own. A full
* table is diagnosed the same way VARSET's other callers already
* do (VARFULL_MSG). CLOBBERS: A, X, Y, PTR0-2.
*---------------------------------------------------------------
GOPT_WROI   sta   GOPTLASTOI
            stz   U2DEC_VAL+1
            sta   U2DEC_VAL
            lda   #<GOPTNBUF
            sta   PTR1
            lda   #>GOPTNBUF
            sta   PTR1+1
            jsr   U2DEC
            lda   #<OPTIND_STR
            sta   PTR0
            lda   #>OPTIND_STR
            sta   PTR0+1
            lda   #<GOPTNBUF
            sta   PTR2
            lda   #>GOPTNBUF
            sta   PTR2+1
            jsr   VARSET
            bcc   :ok
            jsr   PR_VARFULL
            lda   #1
            sta   GOPTFAIL              ;GOPT_SETNM's own check
:ok         rts

*---------------------------------------------------------------
* GOPT_GETN -- IN: A = N, a 1-based operand index. OUT: carry
* clear + PTR0 -> operand N's text, or carry set (no such
* operand). Own ARG... (CMD_ARGC[0] >= 4) wins over the script's
* positional parameters, matching getopts's own precedence.
* CLOBBERS: A, X, PTR0.
*---------------------------------------------------------------
GOPT_GETN   sta   GOPTN
            lda   CMD_ARGC+0
            cmp   #4
            bcc   :pos
            lda   GOPTN
            clc
            adc   #2
            cmp   CMD_ARGC+0
            bcs   :none
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            clc
            rts
:pos        lda   GOPTN
            clc
            adc   POS_SHIFT
            jmp   GETARG
:none       sec
            rts

*---------------------------------------------------------------
* GOPT_FIND -- IN: GOPTCH = a char. OUT: carry clear + PTR1 ->
* OPTSTRING, Y = the index GOPTCH matched at; carry set = not
* found. CLOBBERS: A, Y, PTR1.
*---------------------------------------------------------------
GOPT_FIND   lda   CMD_ARGV+2
            sta   PTR1
            lda   CMD_ARGV+3
            sta   PTR1+1
            ldy   #0
:loop       lda   (PTR1),y
            beq   :nf
            cmp   GOPTCH
            beq   :fnd
            iny
            bra   :loop
:fnd        clc
            rts
:nf         sec
            rts

*---------------------------------------------------------------
* GOPT_SILENT -- OUT: carry SET if OPTSTRING starts with ':'
* (silent-error mode). CLOBBERS: A, Y, PTR1.
*---------------------------------------------------------------
GOPT_SILENT lda   CMD_ARGV+2
            sta   PTR1
            lda   CMD_ARGV+3
            sta   PTR1+1
            ldy   #0
            lda   (PTR1),y
            cmp   #$BA                   ;':' high-bit
            beq   :yes
            clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* GOPT_ADVCL -- the just-examined option TOOK NO ARGUMENT (or
* was unknown): move the cluster cursor to the next character,
* or roll to the next operand if this was the last one. IN:
* PTR0 -> current operand, GOPTCIDX = its offset. CLOBBERS: A,
* X, Y, PTR0-2 (via GOPT_ROLL).
*---------------------------------------------------------------
GOPT_ADVCL  ldy   GOPTCIDX
            iny
            lda   (PTR0),y
            bne   :more
            jmp   GOPT_ROLL
:more       inc   GOPTCIDX
            rts

*---------------------------------------------------------------
* GOPT_ROLL -- the current operand is fully consumed: OPTIND
* advances by one and the cluster cursor resets to 1. CLOBBERS:
* A, X, Y, PTR0-2.
*---------------------------------------------------------------
GOPT_ROLL   jsr   GOPT_RDOI
            clc
            adc   #1
            jsr   GOPT_WROI
            lda   #1
            sta   GOPTCIDX
            rts

*---------------------------------------------------------------
* GOPT_WRNM -- IN A = the character to store as NAME's value
* (the option letter, '?', or ':'). Just the write -- no
* LASTSTATUS, no return-carry -- since GOPT_NOMORE (below) needs
* the SAME write on ITS "no more options" tail, verified against
* this HOST's own getopts: `-a -- -b` sets NAME to '?' too, not
* just LASTSTATUS. CLOBBERS: A, X, Y, PTR0-2.
*---------------------------------------------------------------
GOPT_WRNM   sta   GOPTC1
            stz   GOPTC1+1
            lda   CMD_ARGV+4
            sta   PTR0
            lda   CMD_ARGV+5
            sta   PTR0+1
            lda   #<GOPTC1
            sta   PTR2
            lda   #>GOPTC1
            sta   PTR2+1
            jsr   VARSET
            bcc   :ok
            jsr   PR_VARFULL
            lda   #1
            sta   GOPTFAIL              ;GOPT_SETNM's own check
:ok         rts

*---------------------------------------------------------------
* GOPT_SETNM -- GOPT_WRNM plus the common "found an option"
* exit: LASTSTATUS 0, "handled" (carry set) to CHCK_BLTN_GOP's
* own caller -- UNLESS GOPTFAIL is now set (a VARSET failed
* somewhere in this call, WRNM's own or an earlier WROI's),
* in which case LASTSTATUS is 2, never 0: a `while getopts`
* loop's condition MUST eventually see false, and reporting
* success while a full table silently ate the write it depended
* on is exactly the shape that made it loop forever (found live
* on the emulator, docs/SH-FEATURES.md 2026-09-15).
* CLOBBERS: A, X, Y, PTR0-2.
*---------------------------------------------------------------
GOPT_SETNM  jsr   GOPT_WRNM
            lda   GOPTFAIL
            bne   :fatal
            stz   LASTSTATUS
            sec
            rts
:fatal      lda   #2
            sta   LASTSTATUS
            sec
            rts

*---------------------------------------------------------------
* GOPT_SETOA1 -- OPTARG = a ONE-character string. IN: A = the
* character. CLOBBERS: A, X, Y, PTR0-2.
*---------------------------------------------------------------
GOPT_SETOA1 sta   GOPTC2
            stz   GOPTC2+1
            lda   #<GOPTC2
            sta   PTR2
            lda   #>GOPTC2
            sta   PTR2+1
            jmp   GOPT_SETOAP

*---------------------------------------------------------------
* GOPT_SETOAP -- OPTARG = the string PTR2 already points at.
* CLOBBERS: A, X, Y, PTR0-1.
*---------------------------------------------------------------
GOPT_SETOAP lda   #<OPTARG_STR
            sta   PTR0
            lda   #>OPTARG_STR
            sta   PTR0+1
            jsr   VARSET
            bcc   :ok
            jsr   PR_VARFULL
:ok         rts

*---------------------------------------------------------------
* GOPT_NOMORE / GOPT_USAGE -- the two tails that end getopts
* WITHOUT naming an option: no options remain (LASTSTATUS 1), or
* the call itself was malformed (LASTSTATUS 2). Both are
* "handled" (carry set) -- getopts never falls through to spawn.
*---------------------------------------------------------------
GOPT_NOMORE lda   #$BF                   ;'?' -- this host's own
            jsr   GOPT_WRNM               ;getopts sets NAME
            lda   #1                      ;here too, not just
            sta   LASTSTATUS               ;LASTSTATUS
            sec
            rts
GOPT_USAGE  lda   #<GOPTUSE_MSG
            ldx   #>GOPTUSE_MSG
            jsr   PR_ERRAX
            lda   #2
            sta   LASTSTATUS
            sec
            rts
