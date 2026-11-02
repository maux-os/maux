*---------------------------------------------------------------
* sort.s -- sort lines of text.
*
* Usage: sort [-bcfmnru] [-t C] [-k N[,M]] [-o F] [FILE...]
*
* CONTRACT: read all input -- named FILEs in argv order, or fd 0
* if none -- into an in-process text arena, split it into lines
* (CR $8D terminated, same convention wc.s/ed.s use), sort the
* lines in ASCII order and write them to fd 1 (or -o's FILE),
* each followed by a CR. -r reverses the order. -u drops lines
* equal to the line immediately before them in the OUTPUT order
* (so it composes with -r: duplicates are still adjacent after
* sorting either direction). A FILE that cannot be opened prints
* "sort: cannot open <name>" to fd 2 and is SKIPPED, same as
* wc.s/grep.s.
*
* FLEET F.2 additions (2026-09-01, A12 spellings -- POSIX -k,
* not V7's +pos/-pos): -k N sorts on the key running from the
* START OF FIELD N to the end of the line; -k N,M ends the key
* after field M's last char. WITHOUT -t, fields are blank-runs-
* delimited and each field OWNS ITS LEADING BLANKS (POSIX
* default), so -k2's key on "a  b" is "  b" -- measured against
* /usr/bin/sort before the corpus cases were written. -n
* compares numerically: leading blanks, an optional '-', then an
* integer digit string -- compared by sign, then magnitude
* LENGTH (leading zeros stripped), then the digits themselves,
* so no arithmetic and no value cap. A line with no number
* counts as 0. DECIMAL POINTS ARE NOT PARSED (v1; the reference
* understands 3.14, this stops at the dot -- a named divergence
* waiting to matter, not a surprise).
*
* FLEET F.3 additions (2026-09-14, sortkey.s/sortcmp.s carry
* most of the new code -- see their own headers): -t C makes C
* the field separator for -k -- fields are then delimited by
* EXACTLY ONE C byte (empty fields count), and a separator
* BETWEEN the fields of a multi-field key stays IN the key, but
* the one ENDING the key does not (POSIX's own wording). -b
* ignores leading blanks when computing a key's start. -f
* folds a-z to A-Z for comparison only (output keeps the
* original case). -c checks that stdin/FILE is ALREADY in the
* requested order (honouring -r/-n/-k/-t/-b/-f): the first
* out-of-order line prints "sort: disorder: <line>" to fd 2 and
* exits 1; sorted input produces NO stdout and exits 0. -m
* (merge) is accepted and does nothing extra: an ordinary sort
* of the concatenated input is POSIX-conformant for already-
* sorted inputs, which is the only case -m promises about. -o
* FILE writes the result to FILE instead of fd 1 -- FILE may be
* one of the inputs, since every byte of every input is read
* into the arena before FILE is opened.
*
* PER-KEY TYPES (2026-10-08, docs/POSIX-SORTK.md): -k
* N[t][,M[t]] with t a run of b f n r; up to MAXKEYS (8) -k
* options, tried in order, a ninth is a usage error. A key
* with any type takes NO global flag (b on field_end counts as
* a type but sorts nothing); a key with none inherits -n -r -b
* -f (FINKEYS). The last resort is reversed by the global -r
* alone. d and i are refused.
*
* TIES: when a key (-k or -n) compares equal, the ORDERING falls
* back to a whole-line STRCMP -- the reference's last-resort
* rule, and what keeps output deterministic. -u does NOT take
* that fallback: it drops lines whose KEYS are equal (POSIX -u
* under -k/-n), so `sort -n -u` on "07/7" keeps one of them.
*
* LINE STORAGE. Every input byte is copied into the arena as it
* is read,
* EXCEPT a CR byte, which is stored as NUL ($00) instead. That
* makes each line an ordinary liba NUL-terminated string in
* place, so the sort can call STRCMP/PUTS directly -- no private
* string format, no hand-rolled compare (the HACKING.md rule
* this project keeps getting bitten by). A final input line with
* no trailing CR is still recorded: EOF with pending bytes
* appends one synthetic NUL, charged against the arena like any
* other byte.
*
* Line START addresses (not the text itself) go into LINEPTRS,
* one 16-bit slot per line, in the order lines are READ. Sorting
* permutes LINEPTRS only -- ED.s's ruling for this codebase, and
* this task's own: text never moves, only pointers do. A shell
* sort (halving gap, insertion-sort pass per gap) walks the
* pointer array; recursion never touches the 256-byte hardware
* stack.
*
* OVERFLOW MUST BE LOUD (task ruling, and
* learning:01M07V2D0T25FYD6ASCMPJYNWQ's whole point: a truncated
* answer that still runs is worse than a crash). CHKROOM runs
* before every arena byte write, ADDLINE before every new
* line-table slot; either out of room prints "sort: input too
* large" to fd 2 and exits 2 -- never a partial sort.
*
* THE ARENA IS HEAP, AND THE TWO ENDS SHARE IT (2026-08-22,
* docs/STICKY.md sec 20/21). This file used to declare a FIXED
* PARTITION -- `LINEPTRS ds 4000*2` (8000B) plus `ARENA ds
* 35600B` -- and that split was the bug, not the sizes:
*
*   - 4000 short lines exhausted the pointer table with the
*     35600-byte arena barely touched;
*   - 200 long lines exhausted the arena with 3800 pointer
*     slots -- 7600 bytes -- lying idle;
*   - and both numbers were COMPILE-TIME constants tuned by
*     hand against a measured build, 545 bytes below $BF00. The
*     same class of hand-tuning already overran the overlay
*     page in ed.s by seven bytes with every gate still green.
*
* Both now come out of one heap, obtained with brk(). The arena
* grows UP from the heap base; the line-pointer table grows
* DOWN from PRC_BRK_LIM, one 16-bit slot per line, so
* LINEPTRS[i] lives at PRC_BRK_LIM-2-2*i. There is exactly ONE
* failure mode left, and it is the true one: the two frontiers
* MEET. SRT_LIMIT tracks the table's lowest occupied address
* and is the only thing either check compares against -- an
* input that fits in the bank sorts, whatever shape it has.
*
* The heap runs from SRT_HEAP (declared at the very end of this
* file, one page above the last emitted byte -- see there) up
* to PRC_BRK_LIM ($BF00, inc/mm.procbnk2.equ). The
* KERNEL enforces that ceiling now: START asks for it by
* address and a refusal is a clean "sort: no heap" + exit 2,
* where the old arithmetic could only be checked by a human
* re-doing it after every edit.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.procbnk2.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/sort.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;read chunk, see GETBYTE
MAXKEYS     equ   8                ;-k table slots (gated)
FK_N        equ   $01              ;key flags (KT_FLG): -n
FK_R        equ   $02              ;  r  reverse THIS key
FK_B        equ   $04              ;  b  skip field_start blanks
FK_F        equ   $08              ;  f  fold case
FK_MOD      equ   $80       ;  the key carried a type of its
                            ;  own: no global flag applies

* -- LINEPTRS[i] == SRT_LPBAS-2*i. The table's TOP is the heap
* -- ceiling, which is a constant, so only its moving floor
* -- (SRT_LIMIT) is a runtime cell. No MAXLINES: the line count
* -- is now bounded by the same heap the text is, which is the
* -- whole point of the conversion.
SRT_LPBAS   equ   PRC_BRK_LIM-2

* -- sort.s's own zero-page window. liba claims $E0-$F1
* -- (inc/zp.equ); no other src/bin/*.s module is PUT here
* -- (ed.s's $30-$78, regex.s's $B0-$D1 window this file never
* -- links), so $30 up is free -- picked to match house style
* -- (ed.s also starts its own window at $30).
SRT_TPOS    equ   $30        ;2  arena bump-allocation cursor
SRT_LSTART  equ   $32        ;2  current line's start address
SRT_IDX     equ   $34        ;2  LPADDR/LPGET_A/LPSET_A: line #
SRT_AVAL    equ   $36        ;2  LPGET_A out / LPSET_A in: the
                             ;   line-pointer value itself
SRT_APTR    equ   $38        ;2  LPADDR out: &LINEPTRS[SRT_IDX]
SRT_TVAL    equ   $3A        ;2  SORTLINES: the element being
                             ;   inserted this pass
SRT_I       equ   $3C        ;2  SORTLINES/OUTPUT: outer index
SRT_J       equ   $3E        ;2  SORTLINES: inner index
SRT_JM      equ   $40        ;2  SORTLINES: J-GAP scratch
SRT_GAP     equ   $42        ;2  SORTLINES: shell-sort gap
SRT_PREV    equ   $44        ;2  OUTPUT: last line printed,
                             ;   for -u
SRT_CBYTE   equ   $46        ;1  READALL: byte under test
SRT_HASPREV equ   $47        ;1  OUTPUT: SRT_PREV is valid
SRT_LIMIT   equ   $48        ;2  the line table's lowest
                             ;   occupied address -- the ONE
                             ;   thing the arena may not reach
SRT_NEWLIM  equ   $4A        ;2  ADDLINE: SRT_LIMIT-2, tested
                             ;   before it is committed
SRT_KA      equ   $4C        ;2  CMPKEY: line A's key start
                             ;   (KEYB's in/out walking ptr)
SRT_KB      equ   $4E        ;2  CMPKEY: line B's key start
SRT_KAE     equ   $50        ;2  CMPKEY: A's key end (ptr AT
                             ;   the byte after the key)
SRT_KBE     equ   $52        ;2  CMPKEY: B's key end
SRT_NLA     equ   $54        ;2  NUMKCMP: A's significant-digit
                             ;   count (16-bit: no line cap)
SRT_NLB     equ   $56        ;2  NUMKCMP: B's
SRT_SGNA    equ   $58        ;1  NUMKCMP: A negative
SRT_SGNB    equ   $59        ;1  NUMKCMP: B negative
SRT_KCNT    equ   $5A        ;1  KEYB: fields left to skip
SRT_FA      equ   $5B        ;1  TXTKCMP: A's folded byte

START       stz   WANT_R
            stz   WANT_U
            stz   WANT_N
            stz   WANT_F
            stz   WANT_B
            stz   WANT_C
            stz   WANT_O
            stz   SEPFLAG
            stz   SEPCHAR
            stz   NKEYS
            stz   ERRFLAG
            stz   NLINES
            stz   NLINES+1
            lda   #FD_STDOUT
            sta   OUTFDV

            ;-- Establish the break at the top of this image's
            ;-- own storage, then move it straight to the
            ;-- ceiling: the second call hands back the FIRST
            ;-- one's break, which is the heap base. sort is a
            ;-- leaf utility with one consumer for the whole
            ;-- bank, so it takes the lot in one go rather than
            ;-- growing; ed.s does the opposite and grows on
            ;-- demand, both on the same primitive.
            lda   #<SRT_HEAP
            sta   PTR0
            lda   #>SRT_HEAP
            sta   PTR0+1
            jsr   SC_BRK
            bcs   :noheap
            lda   #<PRC_BRK_LIM
            sta   PTR0
            lda   #>PRC_BRK_LIM
            sta   PTR0+1
            jsr   SC_BRK
            bcc   :heapok
:noheap     lda   #<NOHEAPMSG
            sta   PTR0
            lda   #>NOHEAPMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT
:heapok     lda   PTR0
            sta   SRT_TPOS
            sta   SRT_LSTART
            lda   PTR0+1
            sta   SRT_TPOS+1
            sta   SRT_LSTART+1
            lda   #<PRC_BRK_LIM
            sta   SRT_LIMIT
            lda   #>PRC_BRK_LIM
            sta   SRT_LIMIT+1

            ;-- Options.
            lda   #<SORTOPTS
            ldx   #>SORTOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F2                  ;'r' high-bit-set
            bne   :not_r
            sta   WANT_R
            bra   :optlp
:not_r      cmp   #$F5                  ;'u'
            bne   :not_u
            sta   WANT_U
            bra   :optlp
:not_u      cmp   #$EE                  ;'n' numeric
            bne   :not_n
            sta   WANT_N
            bra   :optlp
:not_n      cmp   #$EB                  ;'k' key follows
            bne   :not_k
            jsr   PARSEKEY            ;OPTARG->next KT_ slot
            bcc   :optlp                ;bad spelling: usage
            bra   :badopt
:not_k      cmp   #$F4                  ;'t' field separator
            bne   :not_t
            jsr   SETSEP
            bra   :optlp
:not_t      cmp   #$EF                  ;'o' output file
            bne   :not_o
            jsr   SETOUT
            bra   :optlp
:not_o      cmp   #$E6                  ;'f' fold case
            bne   :not_f
            sta   WANT_F
            bra   :optlp
:not_f      cmp   #$E2                  ;'b' ignore blanks
            bne   :not_b
            sta   WANT_B
            bra   :optlp
:not_b      cmp   #$E3                  ;'c' check order
            bne   :not_c
            sta   WANT_C
            bra   :optlp
:not_c      cmp   #$ED                  ;'m' merge (a plain
            beq   :optlp                ;sort conforms)
:badopt     lda   #<USAGE
            sta   PTR0
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT
:optdone    jsr   FINKEYS   ;fold -n -r -b -f into keys
            lda   ARGC
            cmp   OPTIND
            bne   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            jsr   READALL
            bra   :allread

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
            jsr   READALL
            ldx   SRCFD
            stx   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            bra   :nextarg

:openerr    lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG

:nextarg    inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcc   :looparg

:allread
            ;-- a final unterminated line still counts.
            lda   SRT_TPOS
            cmp   SRT_LSTART
            bne   :tail
            lda   SRT_TPOS+1
            cmp   SRT_LSTART+1
            bne   :tail
            bra   :notail
:tail       jsr   CHKROOM
            lda   #0
            sta   (SRT_TPOS)
            jsr   ADDLINE
:notail
            ;-- -o: every input is read (above); safe to CREATE
            ;-- the target now, even if it names an input file.
            lda   WANT_O
            beq   :noout
            lda   #<OPATHBUF
            sta   PTR1
            lda   #>OPATHBUF
            sta   PTR1+1
            jsr   CREAT
            bcs   :outerr
            sta   OUTFDV
            bra   :noout
:outerr     lda   #<OUTERRMSG
            sta   PTR0
            lda   #>OUTERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT
:noout      lda   WANT_C
            beq   :dosort
            jsr   CHECKORDER
            lda   ERRFLAG
            jsr   EXIT
:dosort     jsr   SORTLINES
            jsr   OUTPUT
            lda   WANT_O
            beq   :noclose
            ldx   OUTFDV
            jsr   FCLOSE
            bcc   :noclose
            lda   #1
            sta   ERRFLAG
:noclose
            lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* READALL -- read SRCFD to EOF, splitting it into the arena and
* the line table as described in the file header. Jumps straight
* to OVERFLOW (via CHKROOM/ADDLINE) when the two frontiers meet,
* and never returns in that case.
*---------------------------------------------------------------
READALL     stz   BUFPOS
            stz   BUFLEN
:loop       jsr   GETBYTE
            bcs   :eof
            sta   SRT_CBYTE
            jsr   CHKROOM
*-- EITHER TERMINATOR ends a line: maux writes $8D, a file that
*-- came from outside carries ProDOS semantics: $0D.
            lda   SRT_CBYTE
            cmp   #$8D
            beq   :eol1
            cmp   #$0D
            bne   :put
:eol1       lda   #0
:put        sta   (SRT_TPOS)
            lda   SRT_CBYTE
            cmp   #$8D
            beq   :eol2
            cmp   #$0D
            bne   :adv
:eol2       jsr   ADDLINE
            inc   SRT_TPOS
            bne   :sl
            inc   SRT_TPOS+1
:sl         lda   SRT_TPOS
            sta   SRT_LSTART
            lda   SRT_TPOS+1
            sta   SRT_LSTART+1
            bra   :loop
:adv        inc   SRT_TPOS
            bne   :loop
            inc   SRT_TPOS+1
            bra   :loop
:eof        rts

*---------------------------------------------------------------
* CHKROOM -- OUT: rts if SRT_TPOS has a free byte before the
* line table's floor; jumps to OVERFLOW (no return) otherwise.
* SRT_LIMIT, not a constant: the arena's ceiling is wherever
* the pointer table has grown down to, and vice versa.
*---------------------------------------------------------------
CHKROOM     lda   SRT_TPOS+1
            cmp   SRT_LIMIT+1
            bcc   :ok
            bne   :full
            lda   SRT_TPOS
            cmp   SRT_LIMIT
            bcc   :ok
:full       jmp   OVERFLOW
:ok         rts

*---------------------------------------------------------------
* ADDLINE -- append SRT_LSTART to LINEPTRS[NLINES], NLINES++.
* The table grows DOWNWARD, so the new slot costs two bytes off
* SRT_LIMIT; jumps to OVERFLOW (no return) if taking them would
* cross the arena frontier. Committed only after the test --
* SRT_NEWLIM holds the candidate meanwhile.
*---------------------------------------------------------------
ADDLINE     sec
            lda   SRT_LIMIT
            sbc   #2
            sta   SRT_NEWLIM
            lda   SRT_LIMIT+1
            sbc   #0
            sta   SRT_NEWLIM+1
            cmp   SRT_TPOS+1
            bcc   :full
            bne   :room
            lda   SRT_NEWLIM
            cmp   SRT_TPOS
            bcs   :room
:full       jmp   OVERFLOW
:room       lda   SRT_NEWLIM
            sta   SRT_LIMIT
            lda   SRT_NEWLIM+1
            sta   SRT_LIMIT+1
            lda   NLINES
            sta   SRT_IDX
            lda   NLINES+1
            sta   SRT_IDX+1
            lda   SRT_LSTART
            sta   SRT_AVAL
            lda   SRT_LSTART+1
            sta   SRT_AVAL+1
            jsr   LPSET_A
            inc   NLINES
            bne   :done
            inc   NLINES+1
:done       rts

*---------------------------------------------------------------
* LPADDR -- IN: SRT_IDX. OUT: SRT_APTR = &LINEPTRS[SRT_IDX],
* which is SRT_LPBAS-2*SRT_IDX: the table hangs DOWN from the
* heap ceiling, so a higher index is a LOWER address. A
* SUBTRACT where this used to add -- the only consequence of
* the two-ended layout that reaches past ADDLINE/CHKROOM.
* LPGET_A -- also reads that slot into SRT_AVAL.
* LPSET_A -- also writes SRT_AVAL into that slot.
*---------------------------------------------------------------
LPADDR      lda   SRT_IDX
            asl   a
            sta   SRT_APTR
            lda   SRT_IDX+1
            rol   a
            sta   SRT_APTR+1
            sec
            lda   #<SRT_LPBAS
            sbc   SRT_APTR
            sta   SRT_APTR
            lda   #>SRT_LPBAS
            sbc   SRT_APTR+1
            sta   SRT_APTR+1
            rts

LPGET_A     jsr   LPADDR
            ldy   #0
            lda   (SRT_APTR),y
            sta   SRT_AVAL
            iny
            lda   (SRT_APTR),y
            sta   SRT_AVAL+1
            rts

LPSET_A     jsr   LPADDR
            ldy   #0
            lda   SRT_AVAL
            sta   (SRT_APTR),y
            iny
            lda   SRT_AVAL+1
            sta   (SRT_APTR),y
            rts

*---------------------------------------------------------------
* FINKEYS -- once every option is read: a key with NO type of
* its own (FK_MOD clear) takes the global -n -r -b -f; a key
* with any type takes none of them (XCU: "if no modifiers are
* given on any key, the global options apply", measured BSD ==
* GNU). With no -k at all, -n/-f/-b make ONE whole-line key
* (KEYNUM 0) that inherits them; -r alone stays the key-less
* plain path, whose last resort IS the compare. The global
* WANT_N/F/B cells are free afterwards -- KEYSCMP reuses them
* for the current key.
*---------------------------------------------------------------
FINKEYS     lda   #0
            ldx   WANT_N
            beq   :nn
            ora   #FK_N
:nn         ldx   WANT_R
            beq   :nr
            ora   #FK_R
:nr         ldx   WANT_B
            beq   :nb
            ora   #FK_B
:nb         ldx   WANT_F
            beq   :nf
            ora   #FK_F
:nf         sta   SRT_FA                ;G = the global flag set
            ldx   NKEYS
            bne   :inh
            and   #$0D                  ;N|B|F
            beq   :out
            stz   KT_NUM
            stz   KT_END
            stz   KT_FLG
            inc   NKEYS
            ldx   NKEYS
:inh        dex
            bmi   :out
            lda   KT_FLG,x
            bmi   :inh
            lda   SRT_FA
            sta   KT_FLG,x
            bra   :inh
:out        rts

*---------------------------------------------------------------
* SETSEP -- -t's handler. OPTARG points at the separator word;
* only its FIRST byte is the separator (POSIX -t takes exactly
* one char). Masked to 7 bits so KEYB's comparisons work under
* either text convention, same as ISBLANK.
*---------------------------------------------------------------
SETSEP      lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            lda   (PTR0)
            and   #$7F
            sta   SEPCHAR
            lda   #1
            sta   SEPFLAG
            rts

*---------------------------------------------------------------
* SETOUT -- -o's handler. Resolves OPTARG into OPATHBUF NOW
* (MKPATH's source is OPTARG, valid only until the next GETOPT)
* but does NOT open it -- the file is not created/truncated
* until every input has been read (header: -o may name an
* input).
*---------------------------------------------------------------
SETOUT      lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            lda   #<OPATHBUF
            sta   PTR1
            lda   #>OPATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #1
            sta   WANT_O
            rts
            put   sortcmp.s
            put   sortkey.s
            put   sortnum.s

*---------------------------------------------------------------
* OVERFLOW -- either cap was hit. LOUD failure, never a partial
* sort: message to fd 2, exit 2. Not reached from ADDLINE/
* CHKROOM's own rts path -- those jmp here directly.
*---------------------------------------------------------------
OVERFLOW    lda   #<OOMMSG
            sta   PTR0
            lda   #>OOMMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as wc.s/
* grep.s.
*---------------------------------------------------------------
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

REFILL      lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :eof
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            lda   RPARM_TRANS
            sta   BUFLEN
            stz   BUFPOS
            clc
            rts
:eof        sec
            rts

USAGE asc "usage: sort [-bcfmnru][-tC][-kN,M][-oF] [F..]"
            dfb   $8D,$00
ERRMSG      asc   "sort: cannot open "
            dfb   $00
OOMMSG      asc   "sort: input too large"
            dfb   $8D,$00
OUTERRMSG   asc   "sort: cannot open output file"
            dfb   $8D,$00
DISORDMSG   asc   "sort: disorder: "
            dfb   $00
* -- brk() refused: this binary has grown so close to $BF00
* -- that there is no heap left below the overlay page. A
* -- RUNTIME failure now, and a loud one -- the old fixed
* -- partition could only be checked by re-doing the header's
* -- arithmetic by hand after every edit, and ed.s proves what
* -- happens when nobody does (seven bytes into the overlay,
* -- every gate still green).
NOHEAPMSG   asc   "sort: no heap"
            dfb   $00

SORTOPTS    asc   "runk:t:o:fbcm"
            dfb   0

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/creat.s
            put   ../liba/syscalls.s
            put   ../liba/brk.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* SRT_HEAP -- where this program's heap begins, and the one
* thing the kernel cannot work out for itself: brk() enforces
* the CEILING, but only this file knows its own last byte.
*
* Must stay the textually LAST thing in the file. `dum`'s
* addresses are computed relative to the real PC at the point
* it opens, and anything emitted after `dend` resumes at that
* SAME real PC -- real code after this block would collide with
* the heap base it computes.
*
* THE 256-BYTE GAP IS DELIBERATE. docs/STICKY.md sec 21 puts a
* fixed kernel-zeroed page immediately after the image, so a
* heap starting at end-of-image would land on it. One page of
* reservation costs nothing measurable against a ~44KB heap and
* keeps this file correct whether that ruling has landed yet or
* not. START rounds up to a page boundary regardless, because
* the kernel keeps the break as a page NUMBER.
*
* THE HEAP IS UNCLEARED, AND THAT IS CORRECT HERE (sec 21:
* whether a heap block is cleared is the caller's malloc-
* versus-calloc decision, not the system's). Both regions were
* verified write-before-read while they were `dum`, and the
* argument does not depend on where the storage came from:
*
*   the arena: every byte is written via `sta (SRT_TPOS)` in
*   READALL (the main read loop, and the tail/EOF case) BEFORE
*   ADDLINE records that line's start pointer. Every later
*   reader (SORTLINES' STRCMP, OUTPUT's STRCMP/PUTS) reaches
*   arena bytes only through a published pointer.
*
*   the line table: every slot is written by ADDLINE (via
*   LPSET_A) for index 0..NLINES-1 before NLINES is incremented
*   past it. SORTLINES and OUTPUT bound every index they touch
*   against the CURRENT NLINES, so they never read a slot
*   ADDLINE has not written -- including NLINES==0, where both
*   loops fall through without touching slot 0.
*---------------------------------------------------------------
*-- sec 21: chain onto liba's block. `dend` restores the PC
*-- `dum` saved, so a second block opening at `*` would be
*-- the SAME BYTES as liba's own.
            dum   LIBA_BSSEND
SRT_ZPGRSV  ds    256

*-- sort's own scalars, 404 bytes that were still emitted `ds`
*-- zeros outside this arena. They go AFTER SRT_ZPGRSV (which
*-- must stay the first 256 bytes -- that is the window the
*-- kernel actually zeroes) and BEFORE SRT_HEAP (which must
*-- stay past everything, or the bump allocator would hand out
*-- addresses aliasing these cells). Trace (sec 21):
*--  - WANT_R/WANT_U/WANT_N/WANT_F/WANT_B/WANT_C/WANT_O/
*--    SEPFLAG/SEPCHAR/NKEYS/ERRFLAG/NLINES: `stz`'d in START's
*--    opening run, before the brk calls. NLINES is deliberately
*--    entry-only rather than per-file -- it accumulates across
*--    all argv files, which is what sort means.
*--  - KEYNUM/KEYEND/KIDX: written by KEYSCMP before CMPKEY
*--    reads them. KT_NUM/KT_END/KT_FLG[i], i < NKEYS: written
*--    whole by PARSEKEY (or FINKEYS' key 0) before FINKEYS or
*--    KEYSCMP reads slot i; nothing reads past NKEYS.
*--  - OUTFDV: `sta`'d to FD_STDOUT right after those `stz`'s,
*--    before any option is parsed -- overwritten by -o's own
*--    CREAT only if WANT_O ends up set.
*--  - SRCFD: written on both the stdin and the opened-file
*--    paths before any read.
*--  - ARGIDX: `sta` at :havefile; the stdin path branches to
*--    :allread and never reaches a reader.
*--  - BUFPOS/BUFLEN: `stz`'d by READALL, PER FILE -- which is
*--    what makes the argv loop correct as well as making
*--    GETBYTE's `pos >= len` refill test a decision rather
*--    than an accident.
*--  - PATHBUF/OPATHBUF: MKPATH writes chars then the count
*--    byte; the MLI reads only count+1. OPATHBUF is written
*--    only from SETOUT ('-o's own handler), read only when
*--    WANT_O gates it.
*--  - CBUF: filled by SC_READ, indexed only below the BUFLEN
*--    that same call set.
SRCFD       ds    1
ARGIDX      ds    1
WANT_R      ds    1              ;-r  reverse order
WANT_U      ds    1              ;-u  suppress duplicates
WANT_N      ds    1              ;-n  numeric compare
WANT_F      ds    1              ;-f  fold case
WANT_B      ds    1              ;-b  ignore leading blanks
WANT_C      ds    1              ;-c  check order, no output
WANT_O      ds    1              ;-o  output to OUTFDV, not
                                 ;    FD_STDOUT
SEPFLAG     ds    1              ;-t  given (else blank-run
                                 ;    fields, unaffected)
SEPCHAR     ds    1              ;-t's char, masked to 7 bits
OUTFDV      ds    1              ;OUTPUT's fd: FD_STDOUT, or
                                 ;-o's CREATEd fd
KEYNUM      ds    1              ;CURRENT key's first field
                                 ;(0=whole), KEYSCMP-loaded
KEYEND      ds    1              ;CURRENT key's M (0=to EOL)
NKEYS       ds    1              ;-k keys parsed (0 = none)
KIDX        ds    1              ;KEYSCMP: key being tried
KT_NUM      ds    MAXKEYS        ;per key: N (field_start)
KT_END      ds    MAXKEYS   ;         M (0 = to end of line)
KT_FLG      ds    MAXKEYS        ;         FK_ flags
ERRFLAG     ds    1
BUFPOS      ds    1
BUFLEN      ds    1
NLINES      ds    2              ;16-bit: the line count is
                                 ;bounded by the heap now, and
                                 ;runs to five figures

PATHBUF     ds    65
OPATHBUF    ds    65             ;-o's resolved path, built by
                                 ;SETOUT at option-parse time
CBUF        ds    BUFSZ

SRT_HEAP    ds    0     ;dum label (was `equ *`) so
                        ;the REL bss can ENT it
*-- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
*-- end, and $BF00 tops the process window. check_modules'
*-- image-window gate cannot see this -- a `dum` arena
*-- emits no bytes, so the .bin size says nothing about
*-- where the arena ENDS.
            err   */$BF00
            dend
