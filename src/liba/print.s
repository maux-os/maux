*---------------------------------------------------------------
* print.s -- print-to-fd, built on SC_WRITE (syscalls.s). No
* util may call SC_WRITE directly for ordinary text output --
* PUTC/PUTS are the liba- level interface; this is a style rule,
* not mechanically enforced the way the $FF00 choke point is
* (see Makefile's grep gate, which only checks for $FF00/SYS_*
* leakage, not SC_* discipline).
*
* docs/PROCIO.md sec 4: PUTC's INTERFACE is unchanged (still
* `jsr PUTC`, A=byte, X=fd) but its BODY now buffers -- see
* src/liba/stdio.s. Neither merlin32 nor real Merlin nests PUT
* (docs/TOOLCHAIN.md, commit 004bd02) -- includes are a
* TOP-LEVEL concern -- so stdio.s cannot be PUT from inside this
* file the way its own header once assumed; every top-level
* src/bin/*.s program that PUTs this file must PUT
* ../liba/stdio.s itself too (every current PUTC caller already
* does, since PUTC's body needs it -- see each program's own PUT
* list). PUTS flushes the
* target fd's own pending buffer FIRST (ordering: PUTS still
* issues its own single unbuffered SC_WRITE for the whole
* string, so anything already sitting in PUTC's buffer for that
* fd must land first or output reorders). GETC flushes every
* buffered stream before it blocks on SC_READ -- the mechanism
* behind "a line-buffered prompt appears before the read that
* follows it" (sec 6 gate (b)): sh's prompt has no trailing CR,
* so line buffering alone would never flush it on its own.
* Full design notes: L.PRINT.TXT (docs/a2/)
*---------------------------------------------------------------

PUTC        jmp   SIO_PUTC        ;tail call -- SIO_PUTC's own
                                  ;rts returns straight to
                                  ;PUTC's caller

*---------------------------------------------------------------
* PUTS -- write a NUL-terminated liba string to a file
* descriptor (the NUL itself is not written -- only the string
* bytes).
* IN:  X = fd, PTR0/PTR0+1 = string pointer
* OUT: carry clear = ok; carry set, A = errno CLOBBERS: A, X, Y.
* PTR0/PTR0+1 survive in practice (STRLEN restores them and
* SIO_FLUSH never touches them) but are declared volatile here:
* no caller reads them back, and PUTS should stay free to.
*---------------------------------------------------------------
PUTS        stx   PUTS_WPRM_REF     ;stash fd -- doubles as this
                                   ;call's own use AND the flush
                                   ;call's fd argument below
            lda   SIO_MODE,x       ;a FULLY BUFFERED fd (probed
            bne   :decided         ;via SYS_FDSTAT -- stdio.s
            jsr   SIO_MODEOF       ;SIO_MODEOF) takes the
:decided    cmp   #SIOM_FULL       ;buffered path below: the
            beq   :buffered        ;string joins the fd's own
                                   ;LC buffer behind whatever is
                                   ;already pending, and reaches
                                   ;the kernel in BUFSIZ writes
                                   ;instead of one SC_WRITE per
                                   ;call (docs/PERF-PLAN.md step
                                   ;4). Console/stderr keep the
                                   ;unbuffered write below.
            ldx   PUTS_WPRM_REF
            jsr   SIO_FLUSH        ;flush any bytes already
                                   ;buffered by PUTC for this fd
                                   ;FIRST -- PUTS's own write
                                   ;below is unbuffered, so
                                   ;ordering would otherwise
                                   ;invert (docs/PROCIO.md sec 6
                                   ;gate (a))
            jsr   STRLEN           ;uses PTR0, same as PUTS's
                                   ;own arg, and hands it back
                                   ;untouched; A/X = the 16-bit
                                   ;length
            sta   PUTS_WPRM_REQ
            stx   PUTS_WPRM_REQ+1 ;request_count high byte --
                                   ;STRLEN's own high byte since
                                   ;2026-08-22. It was hardcoded
                                   ;to 0 because STRLEN capped
                                   ;at 255 and returned 0 for a
                                   ;256-byte string, so a long
                                   ;line printed as NOTHING. The
                                   ;MLI field was always 2 bytes
                                   ;and SC_WRITE's own 255-byte
                                   ;cap is long gone (see
                                   ;docs/USERLAND.md "ABI
                                   ;RESOLUTIONS"), so the write
                                   ;path never was the limit
            lda   PTR0
            sta   PUTS_WPRM_BUF
            lda   PTR0+1
            sta   PUTS_WPRM_BUF+1
            lda   #PCOUNT_WRITE    ;stored, not emitted -- the
            sta   PUTS_WPARM       ;parmlist lives in
                                   ;src/liba/libabss.s now
                                   ;(docs/STICKY.md sec 21), and
                                   ;an MLI parmlist must be
                                   ;contiguous, so its one
                                   ;constant byte could not stay
                                   ;behind in text
            lda   #<PUTS_WPARM
            ldx   #>PUTS_WPARM
            jsr   SC_WRITE
            bcc   :out
*-- PUTS's write is UNBUFFERED, so it never passes through
*-- SIO_FLUSH, and a failure here would be invisible to stdio's
*-- error path (stdio.s's THE ERROR PATH). Record it on the SAME
*-- per-fd flag, first-error-wins, so FCLOSE and EXIT have one
*-- place to look instead of two.
*--
*-- WHAT THE GATE CAN AND CANNOT SEE, measured by sabotage
*-- 2026-08-24, because the honest version is more useful than
*-- the flattering one: check-writefail does NOT isolate this
*-- recorder. Every util ends a line with a PUTC'd CR, and on a
*-- line-buffered fd that CR's flush hits the same failure, so
*-- disabling EITHER recorder alone leaves the gate green and
*-- disabling BOTH turns `echo APPEND >> LOCKED` red. This one
*-- is here for the output that never reaches a CR -- a PUTS
*-- with no trailing terminator, where nothing is left buffered
*-- for EXIT's flush to fail on.
            ldx   PUTS_WPRM_REF
            ldy   SIO_ERR,x
            bne   :out
            sta   SIO_ERR,x        ;A = the kernel's errno
:out        rts

*-- The buffered path: bulk-append via stdio.s's SIO_PUTSB --
*-- one LC bank bracket per chunk instead of SIO_PUTC's per
*-- byte. Mid-string flush failures land in SIO_ERR; carry
*-- clear always: buffered errors are DEFERRED errors, surfaced
*-- by FCLOSE or EXIT's SIO_ANYERR sweep, same as every PUTC
*-- caller already accepts. PTR0 is consumed (this routine's
*-- header declares it volatile).
:buffered   ldx   PUTS_WPRM_REF
            jmp   SIO_PUTSB          ;tail call -- returns carry
                                     ;clear to PUTS's caller

* See L.PRINT.TXT: "GETC -- read a single RAW"
GETC        stx   GETC_WPRM_REF
            phy                    ;the OLD GETC never touched Y
                                   ;-- SIO_FLUSHALL does (it's a
                                   ;byte-mover chain), so
                                   ;preserve it explicitly (same
                                   ;reasoning as stdio.s's
                                   ;SIO_PUTC -- see its header,
                                   ;found via the same bug)
            jsr   SIO_FLUSHALL     ;flush every buffered stream
                                   ;before blocking on the read
                                   ;-- this is the whole
                                   ;mechanism behind "a line-
                                   ;buffered prompt appears
                                   ;before the read that follows
                                   ;it" (docs/PROCIO.md sec 6
                                   ;gate (b)): a prompt like "$
                                   ;" has no trailing CR, so
                                   ;line buffering alone would
                                   ;never flush it
            ply
            ;-- the parmlist's four CONSTANT fields, stored
            ;-- rather than emitted (docs/STICKY.md sec 21):
            ;-- param_count, the one-byte target's address, and
            ;-- a request_count of exactly 1. ref_num was
            ;-- already patched per call, at GETC's entry above.
            lda   #PCOUNT_READ
            sta   GETC_WPARM
            lda   #<GETC_BYTE
            sta   GETC_WPRM_BUF
            lda   #>GETC_BYTE
            sta   GETC_WPRM_BUF+1
            lda   #1
            sta   GETC_WPRM_REQ
            stz   GETC_WPRM_REQ+1
            lda   #<GETC_WPARM
            ldx   #>GETC_WPARM
            jsr   SC_READ
            bcs   :fail
            lda   GTC_WPRM_TRNS
            ora   GTC_WPRM_TRNS+1
            beq   :fail            ; trans_count == 0 -- EOF
            lda   GETC_BYTE
            clc
            rts
:fail       sec
            rts

* -- GETC_BYTE and both parmlists moved to src/liba/libabss.s
* -- (docs/STICKY.md sec 21): 17 bytes of emitted-and-written
* -- text, in every binary that prints anything. None of them
* -- needs a zero start -- the kernel's page exists for
* -- stdio.s's SIO_CNT_LO/HI and nothing else in liba.
