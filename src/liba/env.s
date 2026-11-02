*---------------------------------------------------------------
* env.s -- the environment, read side (docs/SYSCALL.md item
* 13c). Companion to argv.s: that module reads the argv half of
* the block the kernel stages at spawn, this one reads the envp
* half. Its own module rather than more of argv.s because a liba
* module is linked WHOLE (docs/REL-LIBA-SPIKE.md) and almost
* every program touches argv while almost none ever touches the
* environment.
*
* THE LAYOUT (inc/startup.equ, staged by src/kernel/
* procspawn.s PSTG_ENV):
*
*   ARGC                     argc
*   ARGV+0                   argv[0..argc-1], 2 bytes each
*   ARGV+2*argc              envc
*   ARGV+2*argc+1            envp[0..envc-1], 2 bytes each
*
* Only argc's address is fixed, so envc's is computed here --
* once, in the one routine allowed to know the arithmetic. Every
* offset in this file fits a single byte: the whole pointer
* region is ARGV_PTR_LIM (255) bytes and the kernel refuses to
* stage past it (ERR_2BIG), so envp's last pointer byte is at
* worst offset 254.
*---------------------------------------------------------------

* -- The '=' that separates NAME from VALUE. BOTH spellings are
* -- accepted: sh builds its environment out of high-bit liba
* -- text ($BD) and so does anything using `asc`, but a raw
* -- kernel-level harness may hand the kernel plain ASCII, and a
* -- getenv that silently missed those would be debugged as a
* -- staging bug. The NAME bytes themselves are compared
* -- EXACTLY, high bit included, the same as STRCMP does -- one
* -- convention per string, not per byte.
*-- ENV_EQHI/ENV_EQLO: hoisted to inc/zp.equ (put first
*-- by every consumer) -- shvar.s, put before this file in
*-- sh's own chain, compares against them immediate.

*---------------------------------------------------------------
* GETENV -- look one variable up in this process's environment.
*
* IN:  PTR0 = NUL-terminated NAME (no '='), liba-string
*      convention (high-bit set) if it came from `asc`
* OUT: carry CLEAR + PTR1 = the VALUE (the byte after the '='),
*      still NUL-terminated and still in the block; carry SET =
*      no such variable. An exported-but-empty variable is a
*      HIT whose value is the empty string -- "unset" and "set
*      to nothing" are different answers, which is the whole
*      point of the carry being the verdict.
* CLOBBERS: A, X, Y, PTR1. PRESERVES: PTR0 (the name is still
* there for a caller that wants to print it).
*---------------------------------------------------------------
GETENV      lda   ARGC                 ;envc sits just past the
            asl   a                    ;argv pointers -- argc is
            tay                        ;<= 127, so this fits
            lda   ARGV,y
            sta   GENV_CNT
            beq   :none                ;empty environment
            iny                        ;envp[0]'s own offset
            sty   GENV_OFF

:each       ldy   GENV_OFF
            lda   ARGV,y
            sta   PTR1
            iny
            lda   ARGV,y
            sta   PTR1+1

            ldy   #0
:cmp        lda   (PTR0),y
            beq   :endname
            cmp   (PTR1),y
            bne   :next
            iny
            bne   :cmp
            bra   :next                ;255-byte name: no
                                        ;environment entry this
                                        ;module stages is that
                                        ;long
:endname    lda   (PTR1),y             ;NAME must END here too,
            cmp   #ENV_EQHI            ;or this is a longer name
            beq   :hit                 ;that merely starts the
            cmp   #ENV_EQLO            ;same way (PATH vs
            bne   :next                ;PATHOLOGY)

:hit        iny                        ;step over the '=' --
            tya                        ;PTR1 += namelen + 1
            clc
            adc   PTR1
            sta   PTR1
            bcc   :found
            inc   PTR1+1
:found      clc
            rts

:next       lda   GENV_OFF
            clc
            adc   #2
            sta   GENV_OFF
            dec   GENV_CNT
            bne   :each
:none       sec
            rts

*---------------------------------------------------------------
* ENVNTH -- ENUMERATE the environment, as opposed to searching
* it. IN: A = 0-based index. OUT: carry CLEAR + PTR1 = the whole
* "NAME=VALUE" string, still in the block and still NUL-
* terminated; carry SET = the index is at or past envc, PTR1
* undefined.
*
* GETENV above answers "what is X". This answers "what is
* THERE", which is a different question and the one a shell
* importing its environment has to ask -- V7 sh(1): "On
* invocation, the shell scans the environment and creates a
* parameter for each name found." There was no way to ask it
* until now, which is the mechanical reason maux's environment
* was write-only: `export` staged one and no shell ever read one
* back.
*
* A SEPARATE ENTRY RATHER THAN A MODE FLAG ON GETENV, because
* the two carry verdicts do not mean the same thing: GETENV's
* set carry means "no such name", this one's means "no more
* entries". Folding them would make one `bcs` site have to know
* which question it had asked.
*
* THE INDEX IS NOT A CURSOR. Every call recomputes envc and the
* pointer base from ARGC, so callers may index in any order,
* re-ask for the same entry, or interleave GETENV calls, and
* nothing is left set up between calls. GENV_CNT/GENV_OFF are
* scratch WITHIN a call only.
*
* CLOBBERS: A, X, Y, PTR1. PRESERVES: PTR0.
*---------------------------------------------------------------
ENVNTH      pha                        ;index, wanted after the
                                        ;envc byte is located
            lda   ARGC                 ;envc sits just past the
            asl   a                    ;argv pointers -- the
            tay                        ;same arithmetic GETENV
            lda   ARGV,y               ;opens with
            sta   GENV_CNT
            iny                        ;envp[0]'s own offset
            sty   GENV_OFF
            pla
            cmp   GENV_CNT
            bcs   :past                ;index >= envc, incl. the
                                        ;empty-environment case
*-- index < envc <= 127, so index*2 <= 252 and the add cannot
*-- leave the byte -- GETENV's header already bounds the whole
*-- pointer region at offset 254 because the kernel refuses to
*-- stage past ARGV_PTR_LIM (ERR_2BIG).
            asl   a
            clc
            adc   GENV_OFF
            tay
            lda   ARGV,y
            sta   PTR1
            iny
            lda   ARGV,y
            sta   PTR1+1
            clc
            rts
:past       sec
            rts

*---------------------------------------------------------------
* ENVPASS -- point SPWN_ENVP at THIS process's own environment,
* so the child about to be spawned inherits it. OUT: carry CLEAR
* = SPWN_ENVP set; carry SET = the pointer region has no room
* for a terminator, SPWN_ENVP left NULL rather than stale.
* CLOBBERS: A, Y. PRESERVES: PTR0, PTR1, PTR2.
*
* CALL IT BEFORE LOADING PTR0-PTR2 FOR THE SPAWN. This version
* happens not to touch them, but SC_SPAWN's own contract is that
* the pointers are written immediately before the call, and an
* earlier draft of this routine DID clobber PTR1 -- which is
* SC_SPAWN's argv -- and cost a debugging round in src/bin/
* find.s. The symptom pointed nowhere near the cause: the spawn
* failed on a garbage pointer and -exec left an EMPTY output
* file, which reads as "find never ran".
*
* THIS IS THE execv/execvp SHAPE, and SC_SPAWN is the execve
* one. Unix has both: execve takes an explicit envp, execv
* passes `environ` implicitly, and find(1) calls the implicit
* form -- which is exactly why a real `find -exec` hands the
* child the environment it was itself given. maux had only the
* explicit form, so every caller had to opt IN to inheritance
* and src/bin/find.s opted out with `stz SPWN_ENVP`. That made
* the environment stop at the first -exec.
*
* NOTHING IS COPIED. The block already holds envp's pointers
* contiguously and in order at ARGV+2*argc+1; the ONLY thing
* SC_SPAWN wants that the block lacks is a NULL terminator,
* because the staged form is COUNT-prefixed. So the terminator
* is written into the pointer region's own unused tail and
* SPWN_ENVP points straight at the pointers that were already
* there.
*
* THOSE TAIL BYTES ARE PROVABLY FREE. The region is exactly
* ARGV_PTR_LIM (255) bytes -- ARGV+0 through ARGV+254 -- with
* argv's strings starting at the next page (PRC_ARGV_STR), and
* the kernel refuses with ERR_2BIG rather than staging past it.
* Anything beyond the last staged pointer was therefore never
* written by anyone. Writing there touches no string, no argv
* pointer, and nothing another process can see.
*
* AN EARLIER DRAFT BUILT A SEPARATE ARRAY IN liba's BSS, and it
* could not be made to assemble: the array's size needs a
* constant, src/liba/libabss.s is linked by EVERY program while
* env.s is linked by almost none, and there is no file both
* groups `put` before libabss.s -- startup.equ fixed the
* userland binaries and broke four src/test harnesses, which is
* how the coupling announced itself. A routine that needs no
* storage needs no such file.
*---------------------------------------------------------------
ENVPASS     lda   ARGC
            asl   a                    ;2*argc: envc's offset,
            tay                        ;argc <= 127 so no carry
            iny                        ;envp[0]'s own offset
            sty   GENV_OFF
            dey
            lda   ARGV,y               ;envc
            asl   a                    ;2*envc
            bcs   :nofit               ;envc > 127: cannot be,
                                        ;but it is one branch
            clc
            adc   GENV_OFF             ;one past the last byte
            bcs   :nofit               ;of the last pointer
*-- The terminator needs offsets end and end+1, and 254 is the
*-- last byte of the region, so end must be 253 or less.
            cmp   #254
            bcs   :nofit
            tay
            lda   #0
            sta   ARGV,y
            iny
            sta   ARGV,y
            lda   GENV_OFF             ;SPWN_ENVP = &envp[0],
            clc                        ;the pointers the kernel
            adc   #<ARGV               ;already staged
            sta   SPWN_ENVP
            lda   #>ARGV
            adc   #0
            sta   SPWN_ENVP+1
            clc
            rts
*-- NULL, not left alone. The carry is the real verdict and a
*-- caller must act on it -- but a caller that does not gets an
*-- EMPTY environment rather than whatever address the last
*-- spawn left in SPWN_ENVP. Empty is wrong; stale is wrong AND
*-- unpredictable, and SPWN_ENVP's own declaration says why that
*-- distinction is worth two instructions.
:nofit      stz   SPWN_ENVP
            stz   SPWN_ENVP+1
            sec
            rts
