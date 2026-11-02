*---------------------------------------------------------------
* shexpand.s -- the `$` expansion machinery: DOEXPAND and the
* EMIT* emitters that build a word in EXPBUF, `put` by
* src/bin/sh.s (NOT a standalone binary -- the same put-module
* shape as sedexec.s/expr.eval.s). sh.s was 190,960 bytes
* stripped against real Merlin-8's 41,215-byte source buffer,
* which holds the resident manifest plus ONE put file at a
* time, so the body is split across eight modules. Boundaries
* are banner lines at global labels, chosen along the shell's
* own concerns. Every symbol here resolves against sh.s's
* equates, data and arena -- see that file's header for the
* scope.
*---------------------------------------------------------------
*---------------------------------------------------------------
* ISEXPCH -- IN: A = the byte right after a '$'. OUT: carry SET
* if this is a form WORDEXPAND/DOEXPAND recognise ('?', '#', a
* digit '0'-'9', or a letter 'A'-'Z', all high-bit-set) -- carry
* CLEAR otherwise ('$' followed by anything else, or by nothing,
* stays literal). CLOBBERS: nothing but the flags.
*---------------------------------------------------------------
ISEXPCH     cmp   #$BF                   ;'?'
            beq   :yes
            cmp   #$A3                   ;'#'
            beq   :yes
            cmp   #$A4                   ;'$' -- `$$`, this
            beq   :yes                   ;shell's process number
            cmp   #$A1                   ;'!' -- `$!`, the last
            beq   :yes                   ;background pid
            cmp   #$AA                   ;'*' -- `$*`
            beq   :yes
            cmp   #$C0                   ;'@' -- `$@`
            beq   :yes
            cmp   #$FB                   ;'{' -- `${...}`. This
            beq   :yes                   ;gate decides whether
                                         ;DOEXPAND runs AT ALL,
                                         ;so a form missing here
                                         ;is passed through
                                         ;literally no matter
                                         ;what DOEXPAND knows
            cmp   #$B0                   ;'0'
            bcc   :alpha
            cmp   #$BA                   ;past '9'
            bcc   :yes
:alpha      jsr   ISNAME1                ;letter, either case
            bcc   :no                    ;(the uppercase-only
                                         ;test here was why $x
                                         ;never expanded while
                                         ;x= assigned fine)
:yes        sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* DOEXPAND -- PTR0 holds at least one `$?`; copy it into EXPBUF
* at EXPCUR, substituting LASTSTATUS (decimal) for every `$?`,
* and repoint PTR0 at the copy. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
DOEXPAND    lda   EXPCUR
            sta   EXPSTART
            sta   EXPX
            ldy   #0
:cpy        lda   (PTR0),y
            bne   :ckdollar              ;`bne` past a `jmp` --
            jmp   :term             ;range: the file's idiom
:ckdollar   cmp   #$A4                   ;'$'
            beq   :isdollar              ;`beq` past a `jmp` --
            jmp   :plain            ;range: the dispatch chain
:isdollar   iny                     ;below has outgrown it
            lda   (PTR0),y
            cmp   #$BF                   ;'?'
            beq   :dostat
            cmp   #$A3                   ;'#'
            beq   :dohash
            cmp   #$A4                   ;'$' -- `$$`
            beq   :dopid
            cmp   #$A1                   ;'!' -- `$!`
            beq   :dobg
            cmp   #$AA                   ;'*' -- all positional
            beq   :dostar                ;  parameters
            cmp   #$C0                   ;'@' -- V7 treats it
            beq   :dostar                ;  identically to `*`
            cmp   #$FB                   ;'{' -- `${...}`, the
            beq   :dobrace               ;braced forms
            cmp   #$A8                   ;'(' -- a `$( )` span
            beq   :dparen                ;travels VERBATIM
            cmp   #$B0                   ;'0'
            bcc   :dalpha
            cmp   #$BA                   ;past '9'
            bcs   :dalpha
            jmp   :doarg                  ;digit -- positional
:dalpha     jsr   ISNAME1                ;letter, either case
            bcc   :dlit
            jmp   :dovar                  ;letter -- $NAME
:dlit       lda   #$A4                   ;not a recognised form
            jsr   EMITB                  ;-- emit the '$'
                                         ;literally
            jmp   :cpy             ;range
                                         ;byte fresh
:dostat     phy
            jsr   EMITSTATUS
            ply
            iny
            jmp   :cpy             ;range
*-- A `$( )` SPAN IS COPIED BYTE FOR BYTE, expanding nothing
*-- inside it -- POSIX passes a substitution body VERBATIM and
*-- lets the SUBSHELL evaluate it. Until 2026-08-27 this pass
*-- ran straight through the parentheses, so the parent expanded
*-- the body before the child ever saw it: `$(V=2; ECHO $V)`
*-- printed the PARENT's V and `$(ECHO '$V')` lost its quotes to
*-- the wrong shell (docs/SHELL-GAPS.md sec 2's measured table).
*-- The unexported variables the body can no longer inherit that
*-- way now travel as assignments ahead of it -- SUB_WRVARS. The
*-- two are ONE change: either alone breaks `$V`.
*-- Nesting is SUB_GRAB's refusal, so the first ')' ends the
*-- span; a NUL inside one is an unclosed `$(`, which SUB_GRAB
*-- also refuses -- stop there rather than run off the word.
:dparen     lda   #$A4                   ;'$'
            jsr   EMITB
            lda   #$A8                   ;'('
            jsr   EMITB
            iny
:dpcpy      lda   (PTR0),y
            beq   :term
            jsr   EMITB
            iny
            cmp   #$A9                   ;')' -- span done, the
            bne   :dpcpy                 ;rest of the word
            jmp   :cpy             ;range
:dohash     phy
            jsr   EMITHASH
            ply
            iny
            jmp   :cpy             ;range
:doarg      phy
            jsr   EMITARG                 ;A still holds the
                                          ;digit char -- CMP
                                          ;never disturbs it
            ply
            iny
            jmp   :cpy             ;range
:dovar      jsr   EMITVAR                 ;IN: PTR0/Y at the
                                          ;name's first char;
                                          ;OUT: Y advanced past
                                          ;the whole identifier
                                          ;(no Y save/restore
                                          ;here -- the new Y IS
                                          ;the resume point)
            jmp   :cpy             ;range
:dobrace    jsr   EMITBRACE               ;Y advanced past the
            jmp   :cpy             ;range
:dopid      phy
            jsr   EMITPID
            ply
            iny
            jmp   :cpy                   ;`jmp` -- range
:dobg       phy
            jsr   EMITBGPID
            ply
            iny
            jmp   :cpy                   ;`jmp` -- range
:dostar     phy
            jsr   EMITSTAR
            ply
            iny
            jmp   :cpy                   ;`jmp` -- range
:plain      jsr   EMITB_LIT              ;literal byte -- a
                                         ;separator here is
                                         ;marked low, never
                                         ;split (SPLIT_APPEND)
            iny
            jmp   :cpy             ;range
*-- :term -- write the closing NUL DIRECTLY, not through EMITB.
*-- EMITB's own clamp (below) now reserves the LAST slot of
*-- EXPBUF for exactly this write, so EXPX is guaranteed <=
*-- EXPBUFLEN-1 here (a valid index) no matter how much content
*-- this word emitted -- going through EMITB's clamp a second
*-- time for the terminator itself would refuse this exact write
*-- once content filled the pool to that reserved boundary,
*-- reproducing the very bug the reservation exists to prevent
*-- one byte later. docs/FAT.md sec 13 recorded the old shape:
*-- content filling EXACTLY to EXPBUFLEN silently dropped this
*-- write, and a reader (STRCMP/EMITSTRP/this task's own new
*-- heredoc-body append loop) would then walk PAST the intended
*-- slice into whatever follows in EXPBUF, masked only by `ds`'s
*-- zeroed tail -- which HD_BODY, a `dum` arena, does NOT have.
*-- Long here-doc body lines are exactly what newly exercises
*-- this path (this task), so it is fixed here rather than noted
*-- and left.
:term       jmp   EXP_FINISH

*---------------------------------------------------------------
* EXP_FINISH -- close out the EXPBUF slice this word has been
* emitting into: write its terminating NUL at EXPX, publish the
* bump pointer, and repoint PTR0 at the slice. Shared by
* DOEXPAND and CMDSUBST -- both build a word the same way and
* must finish it the same way.
*
* BUG FIXED HERE, 2026-08-21 (pre-existing, found while writing
* CMDSUBST): this used to publish `EXPCUR = EXPX` -- the index
* OF the NUL, not one past it -- so the NEXT expanding word on
* the same line started its slice ON that terminator and
* overwrote it with its own first byte. `ECHO $1 $2` printed
* `ONETWO TWO`: word 1's pointer was still valid, but its string
* now ran straight on into word 2's. Nothing caught it because
* every gate case in the tree had exactly ONE expanding word per
* line -- the shared incidental docs/SH-FEATURES.md sec 11
* names. CMDSUBST turned it from a wrong answer into a
* guaranteed one: its source IS an EXPBUF slice and its
* destination the next slice, so the terminator it reads to stop
* at was the very byte it had already overwritten.
*
* EXPCUR is clamped to EXPBUFLEN-1 so a pool filled exactly to
* EMITB's own reservation boundary still leaves EXPX a VALID
* index for the next word's terminator write (a degenerate empty
* slice, never a store past the end of EXPBUF into DXSAVE).
* CLOBBERS: A, X, PTR0.
*---------------------------------------------------------------
EXP_FINISH  ldx   EXPX
            lda   #0
            sta   EXPBUF,x
            lda   EXPX
            clc
            adc   #1
            cmp   #EXPBUFLEN
            bcc   :cok
            lda   #EXPBUFLEN-1
:cok        sta   EXPCUR
            lda   EXPSTART
            clc
            adc   #<EXPBUF
            sta   PTR0
            lda   #0
            adc   #>EXPBUF
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* EMITB -- IN: A = byte. Appends to EXPBUF at EXPX, clamped to
* EXPBUFLEN-1 (best-effort truncation past that -- v1, matches
* FDABUF's own "generous, not enforced" precedent) -- ONE byte
* short of the pool's own end, deliberately: DOEXPAND's :term
* writes its closing NUL directly into that reserved last slot
* (see its own comment), so content emitted through THIS routine
* must never be allowed to claim it. Before this reservation, a
* word whose expansion filled the pool exactly to EXPBUFLEN
* dropped the terminator silently (docs/FAT.md sec 13) --
* clamping here one byte earlier, instead, means the reserved
* slot is
* ALWAYS free when :term reaches it, whatever content did.
* CLOBBERS: X.
*---------------------------------------------------------------
EMITB       ldx   EXPX
            cpx   #EXPBUFLEN-1
            bcs   :full
            sta   EXPBUF,x
            inc   EXPX
:full       rts

*---------------------------------------------------------------
* EMITB_LIT -- EMITB for a byte that is LITERAL source text in
* a word being expanded: if it is an active $IFS separator
* (high form), store it with bit 7 CLEAR so SPLIT_APPEND cannot
* split at it -- V7's "only the results of substitution are
* scanned", spelled in the same bit-7-clear-means-literal
* convention :bescput/UNESC already own. Every word this marks
* is UNESCed on its way out of the parser (APPEND_ARGV, the
* SET_* family, and CPTR_HEREDOC's body append), so the low
* form never escapes. A byte already low (a tokenizer escape)
* fails the high-set match and passes through unchanged.
* IN: A = the byte, IFSSET resolved. CLOBBERS: A, X.
*---------------------------------------------------------------
EMITB_LIT   jsr   ISIFS
            bne   :asis
            lda   SPLCH                  ;ISIFS parked the byte
            and   #$7F
            jmp   EMITB
:asis       lda   SPLCH
            jmp   EMITB

*---------------------------------------------------------------
* EMITB_CS -- CMDSUBST's :plain emitter. When DOEXPAND already
* ran (DOEXPRAN), its output is this pass's source and every
* HIGH separator in it is a first-pass SUBSTITUTION RESULT that
* must stay splittable -- copy verbatim. When the word came
* here directly, this pass is the first and its plain bytes are
* literal source -- mark them (EMITB_LIT).
*---------------------------------------------------------------
EMITB_CS    ldx   DOEXPRAN
            beq   EMITB_LIT
            jmp   EMITB

*---------------------------------------------------------------
* EMITSTATUS -- append LASTSTATUS as decimal ASCII to EXPBUF at
* EXPX (via liba's U2DEC), advance EXPX. CLOBBERS: A,X,Y,PTR1.
*---------------------------------------------------------------
EMITSTATUS  lda   EXPX
            clc
            adc   #4
            cmp   #EXPBUFLEN
            bcs   :skip                  ;no room -- drop it
            lda   EXPX
            clc
            adc   #<EXPBUF
            sta   PTR1
            lda   #0
            adc   #>EXPBUF
            sta   PTR1+1
            lda   LASTSTATUS
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            jsr   U2DEC
            clc
            adc   EXPX
            sta   EXPX
:skip       rts

*---------------------------------------------------------------
* EMITHASH -- append `$#` (ARGC-1-POS_SHIFT, the count of
* positional parameters still visible after `shift`, decimal
* ASCII) to EXPBUF. Same shape as EMITSTATUS just above -- only
* the value being formatted differs. Never touches PTR0
* (DOEXPAND's source word pointer). CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
EMITHASH    lda   EXPX
            clc
            adc   #4
            cmp   #EXPBUFLEN
            bcs   :skip
            lda   EXPX
            clc
            adc   #<EXPBUF
            sta   PTR1
            lda   #0
            adc   #>EXPBUF
            sta   PTR1+1
            lda   ARGC
            sec
            sbc   #1
            sec
            sbc   POS_SHIFT
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            jsr   U2DEC
            clc
            adc   EXPX
            sta   EXPX
:skip       rts

*---------------------------------------------------------------
* EMITSTRP -- append the NUL-terminated string at PTR2 to EXPBUF
* via EMITB, one byte at a time. Shared copy helper for EMITARG
* (a positional parameter's text) and EMITVAR (a variable's
* value) -- deliberately reads via PTR2, not PTR0, since PTR0 is
* DOEXPAND's own source-word pointer and must survive both
* callers untouched. CLOBBERS: A, Y.
*---------------------------------------------------------------
EMITSTRP    ldy   #0
:lp         lda   (PTR2),y
            beq   :done
            jsr   EMITB
            iny
            bra   :lp
:done       rts

*---------------------------------------------------------------
* EMITARG -- IN: A = the high-bit-ASCII digit right after `$`
* ('0'-'9'). Appends that positional parameter's text to EXPBUF.
* `$0` is always GETARG(0), unaffected by `shift` (POSIX: shift
* never touches $0); `$1`-`$9` are GETARG(N+POS_SHIFT). A digit
* past the end of argv (docs/SH-FEATURES.md: an unset positional
* parameter, same as an unset variable) emits nothing -- empty
* string, not an error.
*
* Saves/restores PTR0 around the GETARG call: GETARG's own
* contract repoints PTR0 at the argument string, which would
* otherwise clobber DOEXPAND's source-word cursor mid-copy.
* CLOBBERS: A, X, Y, PTR0 (restored before return), PTR2.
*---------------------------------------------------------------
EMITARG     sta   VDIGIT                   ;stash the digit char
                                           ;BEFORE A gets
                                           ;clobbered below --
                                           ;PTR0 must be saved
                                           ;too, but not by
                                           ;overwriting A first
            lda   PTR0
            sta   DXSAVE
            lda   PTR0+1
            sta   DXSAVE+1
            lda   VDIGIT
            and   #$0F
            sta   VTMP
            bne   :nz
            lda   SH_ARG0              ;$0: argv[0] or
            bra   :getit               ;the script path
:nz         lda   VTMP
            clc
            adc   POS_SHIFT
:getit      jsr   GETARG
            bcs   :restore                ;out of range -- empty
            lda   PTR0
            sta   PTR2
            lda   PTR0+1
            sta   PTR2+1
            lda   DXSAVE
            sta   PTR0
            lda   DXSAVE+1
            sta   PTR0+1
            jmp   EMITSTRP
:restore    lda   DXSAVE
            sta   PTR0
            lda   DXSAVE+1
            sta   PTR0+1
            rts



*---------------------------------------------------------------
* EMITPID -- `$$`, V7's *"process number of this shell"*.
*
* NO SYSCALL. A process cannot ask the kernel for its own pid --
* SYS_PSTAT indexes by slot and a process does not know its own
* -- so this looked like it needed a new kernel call, priced at
* ~14 bytes on every one of 27 kernel images plus a ratchet
* re-pin. It needs neither, for two reasons that are already
* true and only had to be noticed:
*
* 1. THE PID IS THE BANK NUMBER, by construction rather than by
*    luck. src/kernel/process.s's spawn stores ONE value from
*    PRC_ALLC_BANK into both:  `sta PRC_CHLD_BANK / sta
*    PRC_CHILD_PID`.
* 2. THE BANK ALREADY KNOWS ITS OWN NUMBER. BANK_ID ($FF2E) is
*    stamped by procspawn.s at bank-creation time and exists for
*    exactly this reason -- its own comment: *"$C073 is
*    write-only, so each bank must keep its own number somewhere
*    IT can read."* The $FFxx page is per-bank and already in
*    every process's address space; it is the page `jsr $FF00`
*    lands in.
*
* So `$$` is one load. Emitted as decimal through U2DEC, the
* same way EMITHASH renders `$#`, and clamped the same way so a
* full EXPBUF drops the number rather than overrunning.
* CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
EMITPID     lda   EXPX
            clc
            adc   #4
*-- `+1` IS THE WHOLE FIX. U2DEC writes at most 3 digits AND its
*-- own NUL, so 4 bytes are needed -- but EXPBUF is indexed
*-- 0..EXPBUFLEN-1, so EXPX+4 == EXPBUFLEN still FITS: digits at
*-- 124/125/126 and the terminator at 127. A plain
*-- `cmp #EXPBUFLEN` dropped `$$` ONE BYTE EARLY, silently, with
*-- room to spare -- a wrong answer, not a refusal. Reported by
*-- 2026-08-27; confirmed on the emulator by check-play's
*-- expansion-buffer-edge case, which prints 124 chars and no
*-- pid before this change.
            cmp   #EXPBUFLEN+1
            bcs   :pskip                 ;no room -- drop it,
            lda   EXPX                   ;EMITHASH's own rule
            clc
            adc   #<EXPBUF
            sta   PTR1
            lda   #0
            adc   #>EXPBUF
            sta   PTR1+1
            lda   BANK_ID
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            jsr   U2DEC
            clc
            adc   EXPX
            sta   EXPX
:pskip      rts

*---------------------------------------------------------------
* EMITBGPID -- `$!`, POSIX's "process ID of the most recent
* background command" (docs/SH-FEATURES.md, 2026-09-15).
* SH_BGPID (sh.s's own dum arena) is written by JOB_BG (shjob.s)
* at the moment a pipeline goes background -- same "the pid IS a
* bank number" fact EMITPID's own header explains, so this is
* one load and a decimal render, same shape and same EXPBUF
* clamp as EMITPID (+4, not +1 -- see EMITPID's own comment).
* v1: before any `&` has ever run, this prints "0" -- a
* documented departure from POSIX (which leaves `$!` UNSET, not
* zero) traded for a real SH_INIT_ZR sentinel instead of a
* second "has this ever been set" flag cell. CLOBBERS: A, X, Y,
* PTR1.
*---------------------------------------------------------------
EMITBGPID   lda   EXPX
            clc
            adc   #4
            cmp   #EXPBUFLEN+1
            bcs   :bskip
            lda   EXPX
            clc
            adc   #<EXPBUF
            sta   PTR1
            lda   #0
            adc   #>EXPBUF
            sta   PTR1+1
            lda   SH_BGPID
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            jsr   U2DEC
            clc
            adc   EXPX
            sta   EXPX
:bskip      rts

*---------------------------------------------------------------
* EMITSTAR -- `$*` / `$@`: all positional parameters from $1,
* separated by single spaces. Added 2026-08-27.
*
* ONE ROUTINE SERVES BOTH, and that is FAITHFUL rather than
* lazy. V7 sh(1): *"If parameter is * or @ then all the
* positional parameters, starting with $1, are substituted
* separated by spaces."* The `"$@"` word-preserving behaviour
* every modern shell has is a LATER refinement -- in V7 the two
* are the same thing, and a reader who expects them to differ is
* reading a later shell back into this one.
*
* Not the convenience it looks like: V7 defines a `for` with no
* list AS `for name in "$@"`, so a whole loop form is
* unreachable without this.
*
* Count is ARGC-1-POS_SHIFT, exactly as EMITHASH computes `$#`,
* so `$*` and `$#` cannot disagree about how many there are.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
EMITSTAR    lda   PTR0
            sta   DXSAVE
            lda   PTR0+1
            sta   DXSAVE+1
            lda   ARGC
            sec
            sbc   #1
            sec
            sbc   POS_SHIFT
            sta   STARN
            beq   :sdone                 ;none: expands to
            lda   #1                     ;  nothing, not to a
            sta   STARI                  ;  space
:sloop      lda   STARI
            clc
            adc   POS_SHIFT
            jsr   GETARG                 ;PTR0 = that argument
            bcs   :snext                 ;past ARGC -- skip
            lda   PTR0
            sta   PTR2
            lda   PTR0+1
            sta   PTR2+1
            jsr   EMITSTRP
:snext      lda   STARI
            cmp   STARN
            beq   :sdone                 ;no trailing separator
            lda   #$A0                   ;one space BETWEEN
            jsr   EMITB
            inc   STARI
            bra   :sloop
:sdone      lda   DXSAVE
            sta   PTR0
            lda   DXSAVE+1
            sta   PTR0+1
            rts
