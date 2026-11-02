*---------------------------------------------------------------
* shvar.s -- shell variables and the environment: the
* name/value table, export/import, shift, and the FOR frame
* state, `put` by src/bin/sh.s (NOT a standalone binary -- the
* same put-module shape as sedexec.s/expr.eval.s). sh.s was
* 190,960 bytes stripped against real Merlin-8's 41,215-byte
* source buffer, which holds the resident manifest plus ONE put
* file at a time, so the body is split across eight modules.
* Boundaries are banner lines at global labels, chosen along
* the shell's own concerns. Every symbol here resolves against
* sh.s's equates, data and arena -- see that file's header for
* the scope.
*---------------------------------------------------------------
*---------------------------------------------------------------
* Tier 2 -- $1-$9/$0/$#, `shift`, `VAR=value`/`$VAR`,
* `for`/`in`/`do`/`done` (docs/SH-FEATURES.md sec 4).
*---------------------------------------------------------------

*---------------------------------------------------------------
* VSLOT_NAME / VSLOT_VAL -- IN: X = variable-table slot (0..
* MAXVARS-1). OUT: PTR1 = &VARNAMES[X*VARNAMESZ] /
* &VARVALS[X*VARVALSZ]. Neither touches X (pure `txa`/shift/
* `adc`), so a caller looping on X or holding it across a call
* (VARFIND, VARSET) keeps it valid. Both strides (16, 32) stay
* under 256 for X's whole range (max 7*32=224), so no 16-bit
* math is needed. CLOBBERS: A.
*---------------------------------------------------------------
VSLOT_NAME  txa
            asl   a
            asl   a
            asl   a
            asl   a
            clc
            adc   #<VARNAMES
            sta   PTR1
            lda   #>VARNAMES
            adc   #0
            sta   PTR1+1
            rts

VSLOT_VAL   txa
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            clc
            adc   #<VARVALS
            sta   PTR1
            lda   #>VARVALS
            adc   #0
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* VARFIND -- IN: PTR0 = a NUL-terminated candidate name. OUT:
* carry CLEAR + X = the matching slot, or carry SET (table
* searched, no match -- X undefined). An EMPTY slot's name byte
* 0 is 0, which can never equal a real (non-empty) candidate's
* first byte, so no separate "is this slot used" check is
* needed -- STRCMP against an empty slot always comes back
* unequal on its own. CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
VARFIND     ldx   #0
:loop       cpx   #MAXVARS
            beq   :notfound
            jsr   VSLOT_NAME
            jsr   STRCMP                 ;preserves X
                                         ;(string.s's
            beq   :found                 ;own header)
            inx
            bra   :loop
:found      clc
            rts
:notfound   sec
            rts

*---------------------------------------------------------------
* VARSET -- IN: PTR0 = NUL-terminated name (already length-
* checked <= VARNAMELEN by the caller), PTR2 = NUL-terminated
* value (already length-checked <= VARVALLEN). Overwrites an
* existing variable of the same name, or claims the first free
* slot (name byte 0 == 0). OUT: carry CLEAR + X = the slot
* used, on success; carry SET (nothing written) if the table is
* FULL -- fails loudly, never silently drops or truncates it
* (docs/SH-FEATURES.md sec 4's own "size it explicitly ... fail
* loudly when full"). CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
VARSET      jsr   SH_HFLUSH          ;PATH may be this very
                                     ;store -- drop the tracked
                                     ;commands (POSIX sh's own
                                     ;rule: assignment to PATH
                                     ;clears the hash)
*-- `readonly` (docs/SH-FEATURES.md sec 29). THE REFUSAL LIVES
*-- HERE, not in the builtin, because there are seven writers --
*-- `NAME=v`, `export`, `read`, `for`, getopts' OPTIND and
*-- OPTARG, and `${V=word}` -- and a flag enforced at six of
*-- them is not a flag. VARROFAIL says WHICH refusal this was,
*-- so PR_VARFULL (shsgblt.s) can print the right message; it is
*-- stored unconditionally, including on the successful path,
*-- because a stale 1 would mislabel the NEXT caller's genuine
*-- table-full.
            stz   VARROFAIL
            jsr   VARFIND
            bcs   :scanfree
            lda   VARRO,x
            beq   :haveslot
            lda   #1
            sta   VARROFAIL
            sec
            rts
:scanfree   ldx   #0
:fl         cpx   #MAXVARS
            beq   :full
            jsr   VSLOT_NAME
            ldy   #0
            lda   (PTR1),y
            beq   :haveslot
            inx
            bra   :fl
*-- X IS THE SLOT AND MUST SURVIVE BOTH COPIES -- VSLOT_VAL
*-- indexes with it, and this routine's own contract returns it.
*-- STRCPY used to preserve X and the comment here said so; on
*-- 2026-08-22 STRCPY went 16-bit and started returning the
*-- length's HIGH BYTE in X, which silently made every slot
*-- address wrong. Symptom: assignments appeared to work and
*-- every later expansion of the variable came back EMPTY
*-- (`for` bodies printed bare prefixes, `export` staged none).
*-- Caught by check-shlang and check-env, not by reading -- the
*-- reliance was stated in a comment two lines BELOW the call.
:haveslot   jsr   VSLOT_NAME              ;PTR1 = dest for the
                                          ;name
            phx
            jsr   STRCPY                  ;PTR0(name)->PTR1
            plx
            lda   PTR2
            sta   PTR0
            lda   PTR2+1
            sta   PTR0+1
            jsr   VSLOT_VAL                ;PTR1 = dest for the
                                           ;value
            phx
            jsr   STRCPY
            plx
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* CHCK_BLTN_VAR is gone (SH-PREFIX): a bare `VAR=value` is now
* the no-command case of PFX_PEEL (shpfx.s), which also takes
* `A=1 B=2` and `NAME=value cmd`.  The refusals it carried (a
* name over VARNAMELEN, a value over VARVALLEN, a full or
* readonly table) are PFX_REC's and PFX_APPLY's, with the same
* messages and the same status 1.
*---------------------------------------------------------------

*---------------------------------------------------------------
* CHCK_BLTN_EXP -- the `export` builtin (docs/SYSCALL.md item
* 13c). `EXPORT NAME ...` marks each named variable for
* inheritance: ENV_STAGE hands the kernel exactly the marked
* slots at every spawn, and nothing else. Bourne's rule
* unmodified -- an unexported variable is a shell LOCAL and
* never reaches a child, which is what keeps `VAR=x` usable as
* scratch.
*
* A name with no slot yet is created EMPTY and marked, which is
* Bourne's own `export FOO` / `FOO=value` ordering: the mark
* lives in VAREXP beside the slot, not in the value, so the
* later assignment finds that same slot by name (VARSET) and
* the mark survives it.
*
* `EXPORT NAME=VALUE` is not accepted -- v7 sh does not accept
* it either (that spelling is ksh's), and here it would be read
* as a name containing '=' and marked as a variable nothing can
* ever assign. `EXPORT` with no names is a no-op success: there
* is no `env` in this system yet and nothing to print with.
*
* Command-position only (NCMD==1), the same shape CD/SHIFT/READ
* already use.
* OUT: carry SET = recognised and handled (do not spawn),
* LASTSTATUS set; carry CLEAR otherwise.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
CHCK_BLTN_EXP
            lda   #<EXPORT_STR
            sta   PTR1
            lda   #>EXPORT_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :isexport
            clc
            rts
:isexport   stz   LASTSTATUS
            lda   #1
            sta   EXPI
:eloop      lda   EXPI
            cmp   CMD_ARGC+0
            beq   :edone
            jsr   EXP_ONE
            inc   EXPI
            bra   :eloop
:edone      sec
            rts

*---------------------------------------------------------------
* EXP_ONE -- mark argv[EXPI]'s variable exported, creating the
* slot with an empty value if it has none yet. A full table is
* the same loud failure VARSET's own caller reports, never a
* silently unexported name.
*---------------------------------------------------------------
* THE NAME MUST BE MEASURED HERE. VARSET's header makes the
* length check the caller's job, and its three other callers all
* do it (CHCK_BLTN_VAR's `cpy #VARNAMELEN+1`, CHCK_BLTN_RD's
* `cpy #VARNAMELEN`, RW_FOR's `cmp #VARNAMELEN+1`). This one did
* not, so `export` took a word straight off the command line --
* up to LINEMAX=127 bytes -- and VARSET STRCPY'd it into a
* 16-byte VARNAMES slot, walking through the remaining slots and
* on into VARVALS. It then propagated: ENV_EMIT sizes SHENVBUF
* on the assumption that a name is at most VARNAMELEN, so the
* staged environment overflowed as well. Found by the caller
* audit for the 16-bit STRCPY, 2026-08-22; it is not a 256-byte
* bug, it is a 16-byte one that was hiding behind the same
* missing bound.
EXP_ONE     lda   EXPI
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            jsr   STRLEN                ;PTR0 restored
            cpx   #0                    ;16-bit: a high byte
            bne   :toolong              ;is past VARNAMELEN
            cmp   #VARNAMELEN+1
            bcs   :toolong
            jsr   VARFIND               ;X = slot when found
            bcc   :mark
            lda   #<EXP_EMPTY           ;no slot yet -- claim
            sta   PTR2                  ;one holding ""
            lda   #>EXP_EMPTY
            sta   PTR2+1
            jsr   VARSET                ;X = slot used
            bcs   :full
:mark       lda   #1
            sta   VAREXP,x
            rts
:full       jsr   PR_VARFULL
            lda   #1
            sta   LASTSTATUS
            rts
:toolong    lda   #<VARNMLONG_MSG
            ldx   #>VARNMLONG_MSG
            jsr   PR_ERRAX1
            rts

EXPORT_STR  asc   "EXPORT"
            dfb   0
EXP_EMPTY   dfb   0

*---------------------------------------------------------------
* CHCK_BLTN_UNS -- the `unset` builtin (POSIX XCU, Special
* Built-In Utilities). `UNSET NAME ...` frees each named
* variable's slot -- VARFIND finds it, then VARUNSET (below)
* zeroes its NAME byte, which is VARFIND's own definition of
* "free" (this file's header on VARFIND: "an EMPTY slot's name
* byte 0 is 0"). Unsetting a name that was never set is NOT an
* error.
*
* `-v` is accepted and ignored -- the default, and this shell
* has no other namespace `-v` could mean. `-f` is a usage error:
* functions do not exist here, so accepting it silently would
* suggest a function COULD have been unset.
*
* Command-position only (NCMD==1), same shape as EXPORT/SHIFT.
* OUT: carry SET = recognised (do not spawn), LASTSTATUS set;
* carry CLEAR otherwise.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
CHCK_BLTN_UNS
            lda   #<UNSET_STR
            sta   PTR1
            lda   #>UNSET_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :isunset
            clc
            rts
:isunset    stz   LASTSTATUS
            lda   #1
            sta   UNSETI
:uloop      lda   UNSETI
            cmp   CMD_ARGC+0
            beq   :udone
            jsr   UNSET_ONE
            inc   UNSETI
            bra   :uloop
:udone      sec
            rts

*---------------------------------------------------------------
* UNSET_ONE -- argv[UNSETI]: `-v` (no-op), `-f` (loud usage
* error, LASTSTATUS 1, no name touched), else an ordinary NAME
* (VARUNSET). CLOBBERS: A, X, PTR0-2.
*---------------------------------------------------------------
UNSET_ONE   lda   UNSETI
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            lda   #<UNSETV_STR
            sta   PTR1
            lda   #>UNSETV_STR
            sta   PTR1+1
            jsr   STRCMP
            beq   :ret
            lda   #<UNSETF_STR
            sta   PTR1
            lda   #>UNSETF_STR
            sta   PTR1+1
            jsr   STRCMP
            bne   :name
            lda   #<UNSETF_MSG
            ldx   #>UNSETF_MSG
            jmp   PR_ERRAX1
:name       jsr   VARUNSET
            bcc   :ret
            lda   #<VARRO_MSG
            ldx   #>VARRO_MSG
            jsr   PR_ERRAX1
:ret        rts

*---------------------------------------------------------------
* VARUNSET -- IN: PTR0 = NUL-terminated name. Frees the slot if
* found (VARFIND's own "name byte 0" contract); a no-op,
* successfully, if not found. CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
*-- READ-ONLY REFUSAL (docs/SH-FEATURES.md sec 29): POSIX makes
*-- `unset` on a read-only variable an error, not a no-op, and
*-- it must be -- a `readonly` a script could `unset` protects
*-- nothing. Carry SET here means REFUSED (the caller prints);
*-- carry CLEAR covers both "freed" and "there was no such
*-- variable", which POSIX says is not an error.
VARUNSET    jsr   VARFIND
            bcs   :nf
            lda   VARRO,x
            bne   :isro
            jsr   VSLOT_NAME
            lda   #0
            ldy   #0
            sta   (PTR1),y
            stz   VAREXP,x
:nf         clc
            rts
:isro       sec
            rts

*---------------------------------------------------------------
* VARUNSET_OA -- `getopts`'s own tail call (shvar2.s): unset
* OPTARG specifically, POSIX's rule for a loud missing-argument
* diagnostic. A plain trampoline, not a copy -- VARUNSET's own
* `rts` returns straight to WHOEVER called this. CLOBBERS: A,
* X, Y, PTR0, PTR1.
*---------------------------------------------------------------
VARUNSET_OA lda   #<OPTARG_STR
            sta   PTR0
            lda   #>OPTARG_STR
            sta   PTR0+1
            jmp   VARUNSET

UNSET_STR   asc   "UNSET"
            dfb   0
UNSETV_STR  asc   "-v"
            dfb   0
UNSETF_STR  asc   "-f"
            dfb   0
UNSETF_MSG  asc   "sh: unset: -f: no functions"
            dfb   $8D,0

*---------------------------------------------------------------
* ENV_IMPORT -- the OTHER half of V7 sh(1)'s environment rule,
* missing until 2026-08-25. Verbatim:
*
*   "On invocation, the shell scans the environment and creates
*    a parameter for each name found, giving it the
*    corresponding value. Executed commands inherit the same
*    environment. If the user modifies the values of these
*    parameters or creates new ones, none of these affects the
*    environment unless the export command is used to bind the
*    shell's parameter to the environment."
*
* maux shipped only the binding half. `export` staged an envp
* and no shell ever read one back, so the environment was
* WRITE-ONLY: measured 2026-08-25, `V=hello; EXPORT V; SH <
* script` where the script echoes $V printed the EMPTY string in
* the nested shell and `[hello]` in the outer one. Every piece
* worked -- ENV_STAGE built the block, the kernel staged it,
* GETENV could read it -- and nothing joined them up.
*
* AN IMPORTED VARIABLE IS AN EXPORTED ONE, and that is the
* subtle half. V7's second sentence is "executed commands
* inherit the same environment", so a name that arrived in the
* environment must still be in the environment of a GRANDchild
* without anyone re-exporting it. Setting VAREXP here is what
* makes inheritance transitive rather than one generation deep;
* omitting it would pass the obvious test (a child sees $PATH)
* and fail the one that matters (its child does not).
*
* IT RUNS AFTER SH_INIT_ZR AND BEFORE EVERYTHING ELSE, so a
* PATH arriving in the environment is already in the table by
* the time PATH_SRC first looks -- which is the whole reason
* `export PATH` in one shell now means anything in the next.
* No change to PATH_SRC was needed or made.
*
* WHAT IT DOES NOT DO: set LASTSTATUS. SH_INIT_ZR has just
* zeroed it and the first command has not run, so a failed
* import must not leave `$?` reading 1 before there is anything
* for it to be the status OF. The failure is on stderr instead,
* which is where a startup diagnostic belongs.
*---------------------------------------------------------------
ENV_IMPORT  stz   ENVIMPI
:loop       lda   ENVIMPI
            jsr   ENVNTH
            bcs   :done
            jsr   ENV_IMP1
            inc   ENVIMPI
            bra   :loop
:done       rts

*---------------------------------------------------------------
* ENV_IMP1 -- one entry. IN: PTR1 = "NAME=VALUE". Splits it,
* length-checks both halves against the table's fixed strides,
* and VARSETs it with the exported bit on.
*
* THE VALUE IS NOT COPIED OUT FIRST: it is the tail of the very
* string ENVNTH handed back, already NUL-terminated in place, so
* PTR2 can point straight at it and VARSET's own STRCPY does the
* one copy. Only the NAME needs a scratch buffer, because its
* terminator in the block is '=' and VARSET wants a NUL.
*
* AN ENTRY THAT CANNOT FIT IS SKIPPED, LOUDLY, AND THE SHELL
* STILL STARTS. The three limits are real (MAXVARS 8,
* VARNAMELEN 15, VARVALLEN 31) and V7 had none of them, so this
* case exists only because maux's table is fixed. Refusing to
* start would be the wrong end of "fail loudly" (docs/SH-
* FEATURES.md sec 4): a shell that will not come up because its
* PARENT exported a ninth variable is unusable, while one that
* says so on stderr and carries on is merely honest. The
* diagnostics are the same three the interactive paths use, so
* there is one vocabulary for "it did not fit".
*---------------------------------------------------------------
ENV_IMP1    ldy   #0
:scan       lda   (PTR1),y
            beq   :noeq
            cmp   #ENV_EQHI            ;both spellings, exactly
            beq   :haveeq              ;as GETENV accepts both
            cmp   #ENV_EQLO
            beq   :haveeq
*-- Length is tested BEFORE the store and AFTER the '=' tests,
*-- so a name of exactly VARNAMELEN bytes still fits: at Y ==
*-- VARNAMELEN the byte examined is the '=' itself and the
*-- branch above has already taken.
            cpy   #VARNAMELEN
            bcs   :nmlong
            sta   ENVIMPNM,y
            iny
            bne   :scan
:haveeq     lda   #0
            sta   ENVIMPNM,y           ;Y == name length
            iny                        ;step over the '='
            tya
            clc
            adc   PTR1
            sta   PTR2
            lda   PTR1+1
            adc   #0
            sta   PTR2+1               ;PTR2 = &VALUE, in place
*-- VARSET STRCPYs into a fixed-stride slot, so the value length
*-- is the CALLER's job here exactly as it is at every other
*-- VARSET site (see the `read` builtin's own note).
            ldy   #0
:vlen       lda   (PTR2),y
            beq   :vlenok
            iny
            cpy   #VARVALLEN+1
            bcc   :vlen
            bra   :vllong
:vlenok     lda   #<ENVIMPNM
            sta   PTR0
            lda   #>ENVIMPNM
            sta   PTR0+1
            jsr   VARSET               ;X = slot used; PTR1 is
            bcs   :full                ;clobbered, and the loop
            lda   #1                   ;recomputes it next pass
            sta   VAREXP,x
            rts
:noeq       lda   #<ENVBAD_MSG
            ldx   #>ENVBAD_MSG
            bra   :emit
:nmlong     lda   #<VARNMLONG_MSG
            ldx   #>VARNMLONG_MSG
            bra   :emit
:vllong     lda   #<VARVLLONG_MSG
            ldx   #>VARVLLONG_MSG
            bra   :emit
:full       jsr   SEL_VARFULL
:emit       sta   PTR0
            stx   PTR0+1
            jsr   PR_ERR
            rts

*---------------------------------------------------------------
* ENV_STAGE -- build the envp for the spawn about to happen:
* one "NAME=VALUE" string per EXPORTED slot, packed into
* SHENVBUF, with a NULL-terminated pointer array in SHENVARR,
* and SPWN_ENVP (src/liba/syscallp.s) pointed at it. The kernel
* re-packs both into the child's own block -- these bytes only
* have to survive until SC_SPAWN returns.
*
* Rebuilt before EVERY spawn rather than cached behind a dirty
* flag: eight slots of at most VARNAMESZ+VARVALSZ bytes is
* nothing beside the image copy a spawn already pays for, and a
* cache would be one more thing that can go stale in a shell
* where `.`, `for` and `read` all write the variable table.
*
* SIZING: MAXVARS(8) entries of at most VARNAMELEN(15) + '=' +
* VARVALLEN(31) + NUL = 48 bytes is SHENVBUFSZ (384), and
* MAXVARS+1 pointer slots is SHENVARRSZ -- the +1 is the NULL
* terminator's own slot, which the kernel's walk stops on.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
ENV_STAGE   lda   #<SHENVBUF
            sta   ENVBP
            lda   #>SHENVBUF
            sta   ENVBP+1
            stz   ENVN
            stz   ENVSLOT
:loop       ldx   ENVSLOT
            cpx   #MAXVARS
            beq   :done
            lda   VAREXP,x
            beq   :next
            jsr   ENV_EMIT
:next       inc   ENVSLOT
            bra   :loop
:done       lda   ENVN
            asl   a
            tax
            lda   #0                     ;envp[envc] == NULL
            sta   SHENVARR,x
            sta   SHENVARR+1,x
            lda   #<SHENVARR
            sta   SPWN_ENVP
            lda   #>SHENVARR
            sta   SPWN_ENVP+1
            rts

*---------------------------------------------------------------
* ENV_EMIT -- one exported slot (X = ENVSLOT) into the staging
* buffer: its pointer, its NAME, the '=' written OVER the name's
* own NUL, then its VALUE and that value's NUL.
*---------------------------------------------------------------
ENV_EMIT    lda   ENVN
            asl   a
            tay
            lda   ENVBP
            sta   SHENVARR,y
            lda   ENVBP+1
            sta   SHENVARR+1,y

            jsr   VSLOT_NAME             ;PTR1 = &name; X kept
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            lda   ENVBP
            sta   PTR1
            lda   ENVBP+1
            sta   PTR1+1
            jsr   STRCPY                 ;A = Y = name length
            tay
            lda   #$BD                   ;'=' high-bit, over the
            sta   (PTR1),y               ;NUL STRCPY just wrote
            iny
            tya                           ;ENVBP += namelen + 1
            clc
            adc   ENVBP
            sta   ENVBP
            lda   ENVBP+1
            adc   #0
            sta   ENVBP+1

            ldx   ENVSLOT
            jsr   VSLOT_VAL               ;PTR1 = &value
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            lda   ENVBP
            sta   PTR1
            lda   ENVBP+1
            sta   PTR1+1
            jsr   STRCPY                  ;A = value length
            sec                            ;ENVBP += len + 1 --
            adc   ENVBP                    ;the NUL counts, so
            sta   ENVBP                    ;`sec`, not `clc`
            lda   ENVBP+1
            adc   #0
            sta   ENVBP+1
            inc   ENVN
            rts

VARFULL_MSG asc   "sh: variable table full"
            dfb   $8D,0
VARNMLONG_MSG
            asc   "sh: variable name too long"
            dfb   $8D,0
VARVLLONG_MSG
            asc   "sh: variable value too long"
            dfb   $8D,0
*-- Import only: ENV_STAGE cannot produce an entry without an
*-- '=', so this fires only on a block built by hand (a raw
*-- kernel harness). Skipped loudly rather than guessed at --
*-- reading it as a name with an empty value would invent a
*-- variable nobody set.
ENVBAD_MSG  asc   "sh: malformed environment entry"
            dfb   $8D,0

*---------------------------------------------------------------
* CHCK_SHIFT -- the `shift` builtin. Command-position only
* (NCMD==1), same shape as CD/EXIT/TEST/BREAK above. No count
* argument (v1 -- the estimate this shipped against,
* docs/SH-FEATURES.md sec 4, is a plain `shift`; any extra
* argv is ignored rather than rejected). Shifting past the last
* positional parameter is a loud error (real Bourne's own "shift
* count out of range"), not a silent no-op that would leave $1
* reading a stale value forever.
* OUT: carry SET if the command was `shift` (handled -- do not
* spawn), carry CLEAR otherwise. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CHCK_SHIFT
            lda   #<SHIFT_STR
            sta   PTR1
            lda   #>SHIFT_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcs   :no
            lda   ARGC
            sec
            sbc   #1
            sec
            sbc   POS_SHIFT
            beq   :none
            inc   POS_SHIFT
            stz   LASTSTATUS
            sec
            rts
:none       lda   #<SHIFTERR_MSG
            ldx   #>SHIFTERR_MSG
            jsr   PR_ERRAX1
            sec
            rts
:no         clc
            rts

SHIFT_STR   asc   "SHIFT"
            dfb   0
SHIFTERR_MSG
            asc   "sh: shift: no positional parameters left"
            dfb   $8D,0
