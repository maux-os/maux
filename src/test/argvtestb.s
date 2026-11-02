*---------------------------------------------------------------
* argvtestb.s -- image body for argvtest.s.
* Split out so the top-level stays a thin MANIFEST
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J).
*
* WHAT THIS PROVES, case by case (scripts/check_argv.py has
* the expected values; keep the two in step):
*
*   0. 3 short args               -> spawn ok, argc 3
*      Regression cover: ordinary argv still works after the
*      rewrite.
*   1. ONE 100-byte arg           -> spawn ok, argc 1
*      The old per-arg PRC_ARGBUF cap silently cut every
*      argument at 63 bytes, so a 64-character ProDOS path
*      (the MLI's own maximum) arrived one character short.
*      The tail sentinel is what catches it.
*   2. 20 args x 64B = 1280B      -> spawn ok, argc 20
*      Exactly ARG_MAX. Must arrive WHOLE.
*   3. same + one EMPTY arg       -> spawn FAILS, ERR_2BIG
*      Exactly ARG_MAX+1 -- the empty arg contributes its
*      single NUL and nothing else. One byte past, not a
*      comfortable overshoot, because an off-by-one in the
*      check is exactly what a coarse test would miss.
*   4. 127 args x 2B             -> spawn ok, argc 127
*      The pointer array exactly full: 127 entries is 254 of the
*      255 bytes between PRC_ARGV_PTRS and the strings. Only 254
*      bytes of strings, so this isolates the OTHER map-derived
*      ceiling from the byte budget.
*   5. 128 args x 2B             -> spawn FAILS, ERR_2BIG
*      One pointer past. Still trivially inside ARG_MAX.
*   6. 3 short args again        -> spawn ok, argc 3
*      Nothing leaked. Cases 3 and 5 fail AFTER the child's bank
*      is allocated and stamped, so if PRC_SPAWN forgot to free
*      it on the argv-failure path, the free list would bleed a
*      bank per failure and this case is where it shows.
*
* THE SHARED BUDGET (docs/SYSCALL.md item 13c, 2026-08-22). The
* environment lives in the same block, so ARG_MAX now bounds
* argv's strings PLUS envp's. Every case above passes an EMPTY
* (but present) envp array, which is itself worth having; the
* three below are the pair's own ceiling:
*
*   7. 19 args x 64B + 1 env x 64B -> spawn ok, argc 19, envc 1
*      1216 + 64 = exactly ARG_MAX across the PAIR. Must arrive
*      whole -- and the child checks that the environment's
*      strings continue exactly where argv's ended, which is
*      what "one block" has to mean.
*   8. same + one EMPTY env entry -> spawn FAILS, ERR_2BIG
*      Exactly ARG_MAX+1, and the byte that overflows is in the
*      ENVIRONMENT while argv alone still fits. A budget that
*      was still two separate budgets passes case 7 and fails
*      here by succeeding -- which is the whole reason the
*      overflow is built one layer past where argv can see it
*      (learning:01M07V2D0T25FYD6ASCMPJYNWQ, and its companion
*      learning:01M0MHTWDNWJ3PSP2497SDZG97 for what a
*      two-budget implementation does to case 7).
*   9. 3 short args, empty env   -> spawn ok, argc 3
*      The no-leak repeat again, after the env failure path.
*
* The child ('V', SIMG_VERIFY) does not know any case's numbers.
* It checks INVARIANTS: every arg ends with the sentinel byte
* (so no arg was truncated), and every argv[i] points exactly
* where the previous string ended (so the pointer array and the
* packed strings agree) -- then the same two invariants over the
* environment, whose strings must continue from where argv's
* stopped and whose pointers live past the envc byte. It exits
* with ARGC, bit 7 SET when the environment was non-empty (no
* case here stages more than one entry, so that reports both
* counts), and $EE on any violation -- so a wrong count and a
* corrupt block stay distinguishable in the recorded status.
*---------------------------------------------------------------

* Result addresses in the parent process bank (aux bank 1).
*-- Hoisted above first use (S9 EQU burn-down 2026-08-29).
NCASE       equ   10

R_SPWERR    equ $1100        ;NCASE bytes: 0 or the spawn errno
R_STATUS    equ $1110        ;NCASE bytes: child exit status
R_WSTAT     equ $1120        ;SC_WAIT's status landing cell
R_DONE      equ $11F0
R_ERR       equ $11F1

* Parent process scratch. Deliberately HIGH: PARENT_PROC is
* copied to the address it was ASSEMBLED at (see BOOT_CPY_PAR),
* which moves whenever the kernel modules ahead of it change
* size, so its buffers must not sit anywhere that could drift
* into. $8000+ is ordinary process memory in every bank.
* SLACK IS DELIBERATE. The first draft packed these tightly and
* put V_PATH immediately above STRBUF -- so case 3, whose whole
* purpose is to write ONE byte more than ARG_MAX, wrote that
* byte onto the spawn path. Every case after it then spawned
* the empty path and came back ERR_INVAL, which looked just
* like a kernel bug and reproduced identically on the
* pre-fix kernel.
* A test whose overflow case overflows into the test's own
* fixtures cannot report on anything.
V_PATH      equ $8000        ;"V", high-bit NUL liba string
SPAWN_PARM  equ $8010
WAIT_PARM   equ $8020
ARGV_ARR    equ $8100        ;up to 128 pointers + NULL = 258B
STRBUF      equ $8400        ;up to 1281B of packed strings, and
                             ;nothing of ours above it until
                             ;$8900
* -- The environment's own two buffers, deliberately a page
* -- clear of STRBUF's own worst case ($8901) for the reason
* -- the comment above records: an overflow case that overflows
* -- into the test's own fixtures cannot report on anything.
ENV_ARR     equ $9000        ;env pointers + NULL
ENVSTR      equ $9100        ;packed env strings (no case here
                             ;stages more than 65 bytes of them)

* Parent zero page (its own bank's ZP -- no kernel cells here).
SP          equ $20          ;2  string write cursor
AP          equ $22          ;2  pointer-array write cursor
AI          equ $24          ;   arg index within a case
CN          equ $25          ;   this case's arg count
CL          equ $26          ;   this case's bytes per arg
CE          equ $27          ;   this case: append an empty arg?
CI          equ $28          ;   case index
CEN         equ $29          ;   this case: env entry count
CEL         equ $2A          ;   this case: bytes per env entry
CEE         equ $2B          ;   this case: append an empty env
                             ;   entry?

* Child scratch (its own bank).
V_EXP       equ $10          ;2  where argv[i] MUST point
V_P         equ $12          ;2  argv[i] as staged
V_IDX       equ $14
V_NARG      equ $15
V_LAST      equ $16          ;   last non-NUL byte seen
V_NENV      equ $17          ;   envc, as staged
V_EBASE     equ $18          ;   2*ARGC -- the envc byte's own
                             ;   offset into the pointer array
V_PARML     equ $0900

FILLBYTE    equ $C2          ;'B' high-bit set -- body filler
TAILBYTE    equ $B9          ;'9' high-bit set -- tail sentinel

*---------------------------------------------------------------
* Boot helpers -- same shape as shtestb.s's (that gate's parent
* also calls its own subroutines, so it too is copied to the
* address it was assembled at rather than to LOAD_BASE).
*---------------------------------------------------------------
BOOT_CPY_PAR
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PARENT_PROC
            sta   K_BC_SRCADDR
            lda   #>PARENT_PROC
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #<PARENT_PROC
            sta   K_BC_DSTADDR
            lda   #>PARENT_PROC
            sta   K_BC_DSTADDR+1
            lda   #1
            sta   K_BC_DSTBANK
            lda   #<PAR_PROC_LEN
            sta   K_BC_LEN
            lda   #>PAR_PROC_LEN
            sta   K_BC_LEN+1
            jsr   BankCopy
            rts

PATCH_PAR_FRM
            lda   #1
            sta   BANKSEL
            sta   ALTZPAUX
            lda   #<PARENT_PROC
            sta   $01FE
            lda   #>PARENT_PROC
            sta   $01FF
            sta   ALTZPMAIN
            rts

STAMP_MAIN  lda   LCBANK2_RAM
            lda   LCBANK2_RAM
            ldy   #0
:cp         lda   FFP_SYSC_ENT,y
            sta   $FF00,y
            iny
            bne   :cp
            rts

NOIRQ       rts

MAIN_ENTRY  jsr   INSTALL_COPY
            lda   #<NOIRQ
            sta   K_IRQ_HOOK
            lda   #>NOIRQ
            sta   K_IRQ_HOOK+1
            jsr   STAMP_MAIN
            jsr   SCH_INIT
            lda   #1                       ;gates pin 40 cols:
            sta   TTY_BKND_REQ             ;auto = best 80 now
            jsr   PRC_INIT

            lda   #1
            jsr   PRC_STMP_BANK
            lda   #1
            jsr   PRC_SYNTH_FRM
            jsr   PATCH_PAR_FRM
            jsr   BOOT_CPY_PAR

            lda   #1
            ldx   #1
            jsr   SCH_CREATE
            jsr   SCH_START

*---------------------------------------------------------------
* PARENT_PROC -- runs the case table. Copied to its own
* assembled address in bank 1, so the JSRs below are valid
* as assembled.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_DONE

            lda   #'V'+$80               ;the spawn path: one
            sta   V_PATH                 ;character, matched by
            stz   V_PATH+1               ;PRC_SPAWN's builtin
                                         ;table

            stz   CI
:caseloop   lda   CI
            cmp   #NCASE
            bcs   :alldone

            ldx   CI
            lda   CASE_N,x
            sta   CN
            lda   CASE_L,x
            sta   CL
            lda   CASE_E,x
            sta   CE
            lda   CASE_EN,x
            sta   CEN
            lda   CASE_EL,x
            sta   CEL
            lda   CASE_EE,x
            sta   CEE
            jsr   P_BUILD
            jsr   P_BLD_ENV

            jsr   P_SPAWN_V
            ldx   CI
            bcs   :failed
            lda   #0                     ;spawned: record no
            sta   R_SPWERR,x             ;errno, then reap and
            jsr   P_WAIT                 ;record the status the
            ldx   CI                     ;child exited with
            lda   R_WSTAT
            sta   R_STATUS,x
            bra   :nextcase
:failed     sta   R_SPWERR,x             ;A = errno (what
            lda   #0                     ;cases 3 and 5 test)
            sta   R_STATUS,x
:nextcase   inc   CI
            bra   :caseloop

:alldone    lda   #$AA
            sta   R_DONE
:halt       bra   :halt

*---------------------------------------------------------------
* P_BUILD -- lay out CN args of CL bytes each in STRBUF, with a
* pointer to each in ARGV_ARR, NULL-terminated (ordinary Unix
* argv in the parent's own memory -- ruling 13 says the kernel
* re-packs it, so the parent does nothing special).
*
* Each arg is (CL-2) filler bytes, then TAILBYTE, then NUL: the
* sentinel is the LAST character, so any truncation anywhere in
* the argument removes it and the child notices.
*---------------------------------------------------------------
P_BUILD     lda   #<STRBUF
            sta   SP
            lda   #>STRBUF
            sta   SP+1
            lda   #<ARGV_ARR
            sta   AP
            lda   #>ARGV_ARR
            sta   AP+1
            stz   AI

:each       lda   AI
            cmp   CN
            beq   :extra
            jsr   P_EMIT
            inc   AI
            bra   :each

:extra      lda   CE
            beq   :term
            ;-- one extra, EMPTY argument: a lone NUL. Costs the
            ;-- packed region exactly ONE byte, which is how
            ;-- "one past the ceiling" is expressed exactly.
            jsr   P_PUT_PTR
            ldy   #0
            lda   #0
            sta   (SP),y
            inc   SP
            bne   :term
            inc   SP+1

:term       ldy   #0                     ;argv[argc] == NULL
            lda   #0
            sta   (AP),y
            iny
            sta   (AP),y
            rts

*---------------------------------------------------------------
* P_BLD_ENV -- the same layout job for the ENVIRONMENT, into its
* own two buffers, by pointing P_EMIT's own cursors at them:
* CEN entries of CEL bytes, optionally one extra EMPTY entry,
* NULL-terminated. Runs AFTER P_BUILD, which is why it can
* overwrite CL -- and it always runs, so every case hands the
* kernel a real (if empty) envp array rather than a NULL one.
*---------------------------------------------------------------
P_BLD_ENV   lda   #<ENVSTR
            sta   SP
            lda   #>ENVSTR
            sta   SP+1
            lda   #<ENV_ARR
            sta   AP
            lda   #>ENV_ARR
            sta   AP+1
            stz   AI
            lda   CEL
            sta   CL

:each       lda   AI
            cmp   CEN
            beq   :extra
            jsr   P_EMIT
            inc   AI
            bra   :each

:extra      lda   CEE
            beq   :term
            ;-- one extra, EMPTY entry: a lone NUL, one byte of
            ;-- the SHARED budget and nothing else, which is how
            ;-- "one past the pair's ceiling" is expressed
            ;-- exactly.
            jsr   P_PUT_PTR
            ldy   #0
            lda   #0
            sta   (SP),y
            inc   SP
            bne   :term
            inc   SP+1

:term       ldy   #0                     ;envp[envc] == NULL
            lda   #0
            sta   (AP),y
            iny
            sta   (AP),y
            rts

*---------------------------------------------------------------
* P_EMIT -- one argument: its pointer, then its bytes.
*---------------------------------------------------------------
P_EMIT      jsr   P_PUT_PTR
            ldy   #0
            ldx   CL
            dex                          ;bytes before the NUL
            beq   :nul                   ;CL=1 -> empty string
            dex                          ;filler count
            beq   :sent
:fill       lda   #FILLBYTE
            sta   (SP),y
            iny
            dex
            bne   :fill
:sent       lda   #TAILBYTE
            sta   (SP),y
            iny
:nul        lda   #0
            sta   (SP),y
            clc                           ;SP += CL
            lda   SP
            adc   CL
            sta   SP
            bcc   :done
            inc   SP+1
:done       rts

*---------------------------------------------------------------
* P_PUT_PTR -- store SP into the next ARGV_ARR slot, advance AP.
*---------------------------------------------------------------
P_PUT_PTR   ldy   #0
            lda   SP
            sta   (AP),y
            iny
            lda   SP+1
            sta   (AP),y
            clc
            lda   AP
            adc   #2
            sta   AP
            bcc   :done
            inc   AP+1
:done       rts

*---------------------------------------------------------------
* P_SPAWN_V / P_WAIT -- carry and A come straight back from the
* syscall, which is the whole verdict for cases 3 and 5.
*---------------------------------------------------------------
P_SPAWN_V   lda   #<V_PATH
            sta   SPAWN_PARM
            lda   #>V_PATH
            sta   SPAWN_PARM+1
            lda   #<ARGV_ARR
            sta   SPAWN_PARM+2
            lda   #>ARGV_ARR
            sta   SPAWN_PARM+3
            stz   SPAWN_PARM+4           ;no fdactions
            stz   SPAWN_PARM+5
            lda   #<ENV_ARR              ;a REAL envp array in
            sta   SPAWN_PARM+6           ;every case -- empty
            lda   #>ENV_ARR              ;for the argv-only
            sta   SPAWN_PARM+7           ;cases, not NULL
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

P_WAIT      lda   #<R_WSTAT
            sta   WAIT_PARM
            lda   #>R_WSTAT
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :ok
            sta   R_ERR
:ok         rts

* -- The case table. Columns 0-6 are argv's (count, bytes per
* -- arg, trailing empty arg), 7-9 the environment's -- and the
* -- two halves of case 7/8 are read TOGETHER against ARG_MAX,
* -- which is the property under test: 19*64 + 1*64 = 1280 is
* -- the ceiling, and case 8's one extra empty entry is 1281.
* -- Keep in step with scripts/check_argv.py's own CASES.
*-- NCASE: hoisted above its first use (EQU burn-down).
CASE_N      dfb   3,1,20,20,127,128,3
            dfb   19,19,3
CASE_L      dfb   6,100,64,64,2,2,6
            dfb   64,64,6
CASE_E      dfb   0,0,0,1,0,0,0
            dfb   0,0,0
CASE_EN     dfb   0,0,0,0,0,0,0
            dfb   1,1,0
CASE_EL     dfb   0,0,0,0,0,0,0
            dfb   64,64,0
CASE_EE     dfb   0,0,0,0,0,0,0
            dfb   0,1,0

PAR_PROC_END
PAR_PROC_LEN equ PAR_PROC_END-PARENT_PROC

*---------------------------------------------------------------
* SIMG_VERIFY -- the 'V' child image. Copied verbatim to
* $0800 in its own bank, so: branches only, no absolute
* reference to any label inside this blob (same rule as
* processtestb.s's images).
*
* Checks the two invariants a correct argv has, without knowing
* which case spawned it:
*   - every argument's LAST byte is TAILBYTE, so nothing was
*     truncated (the old 64-byte per-arg cap would leave
*     FILLBYTE there instead);
*   - argv[0] is PRC_ARGV_STR and each argv[i] is exactly where
*     argv[i-1]'s string ended, so the pointer array and the
*     packed strings agree.
* Exits with ARGC when both hold, $EE otherwise.
*---------------------------------------------------------------
SIMG_VERIFY
            lda   PRC_ARGV_HDR
            sta   V_NARG
            bne   :haveargs
*-- argc 0 -- no case here passes an empty argv. This exits
*-- INLINE rather than branching to the shared `:bad` below:
*-- the environment's own checks now sit between the two, so
*-- that branch went out of 8-bit range -- and this blob may not
*-- `jmp` to a label inside itself (it is copied verbatim into
*-- another bank's $0800, so every internal reference has to be
*-- PC-relative). Six duplicated bytes beat a trampoline chain.
            lda   #$EE
            sta   V_PARML
            lda   #<V_PARML
            ldx   #>V_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
:haveargs   lda   #<PRC_ARGV_STR
            sta   V_EXP
            lda   #>PRC_ARGV_STR
            sta   V_EXP+1
            stz   V_IDX

:vloop      lda   V_IDX
            asl   a
            tax
            lda   PRC_ARGV_PTRS,x
            sta   V_P
            lda   PRC_ARGV_PTRS+1,x
            sta   V_P+1

            lda   V_P                    ;packed back-to-back,
            cmp   V_EXP                  ;in order?
            bne   :bad
            lda   V_P+1
            cmp   V_EXP+1
            bne   :bad

            ldy   #0
:vwalk      lda   (V_P),y
            beq   :vnul
            sta   V_LAST
            iny
            bne   :vwalk
            bra   :bad                   ;no NUL in 255 bytes --
                                         ;not something any case
                                         ;here builds
:vnul       cpy   #0
            beq   :bad                   ;empty arg -- ditto
            lda   V_LAST
            cmp   #TAILBYTE              ;tail intact?
            bne   :bad

            tya                           ;V_EXP += strlen + 1
            sec
            adc   V_EXP
            sta   V_EXP
            lda   #0
            adc   V_EXP+1
            sta   V_EXP+1

            inc   V_IDX
            lda   V_IDX
            cmp   V_NARG
            bne   :vloop
            bra   :envchk

*-- THE EXIT BLOCK SITS IN THE MIDDLE ON PURPOSE. This blob is
*-- copied verbatim to $0800 in another bank, so it may contain
*-- no absolute reference to a label inside itself -- branches
*-- only, and a branch is 8-bit. With the environment's checks
*-- added, an exit at the END was out of range of the argv loop
*-- and an exit at the END of the argv loop was out of range of
*-- the environment's; between the two, every branch is short.
:bad        lda   #$EE
:vexit      sta   V_PARML
            lda   #<V_PARML
            ldx   #>V_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *

*-- The environment, checked with the SAME two invariants and
*-- the SAME cursor. V_EXP still points at the byte after
*-- argv's last string, and that is exactly where envp[0]'s
*-- string has to start: one block, one packed region, argv's
*-- strings then envp's (docs/SYSCALL.md item 13c). envc itself
*-- sits immediately past argv's pointer array.
:envchk     lda   V_NARG
            asl   a
            sta   V_EBASE
            tax
            lda   PRC_ARGV_PTRS,x
            sta   V_NENV
            beq   :vgood                 ;no environment staged
            stz   V_IDX

:eloop      lda   V_IDX
            asl   a
            sec                          ;+1 -- step over the
            adc   V_EBASE                ;envc byte itself
            tax
            lda   PRC_ARGV_PTRS,x
            sta   V_P
            lda   PRC_ARGV_PTRS+1,x
            sta   V_P+1

            lda   V_P                    ;continues where argv's
            cmp   V_EXP                  ;strings stopped?
            bne   :bad
            lda   V_P+1
            cmp   V_EXP+1
            bne   :bad

            ldy   #0
:ewalk      lda   (V_P),y
            beq   :enul
            sta   V_LAST
            iny
            bne   :ewalk
            bra   :bad
:enul       cpy   #0
            beq   :bad
            lda   V_LAST
            cmp   #TAILBYTE              ;tail intact?
            bne   :bad

            tya                           ;V_EXP += strlen + 1
            sec
            adc   V_EXP
            sta   V_EXP
            lda   #0
            adc   V_EXP+1
            sta   V_EXP+1

            inc   V_IDX
            lda   V_IDX
            cmp   V_NENV
            bne   :eloop
            lda   V_NARG                 ;argv AND environment
            ora   #$80                   ;verified -- bit 7 says
            bra   :vexit                 ;the env was non-empty
:vgood      lda   V_NARG                 ;argv verified, no env
            bra   :vexit                 ;was staged at all
SIMG_VFY_END

* -- the pad places the verifier at a fixed block
* -- boundary; NBLOCKS below must equal ($XXXX-$0800)/512.
* -- History: $3800/24 -> $4000/28 (task #15, sticky.s) ->
* -- $4800/32 (2026-08-20, the seek family grew procfile.s
* -- and procfd2.s past $4000 by 509B) -> $5000/36
* -- (2026-08-26, SYS_TICK's PRC_TICK/PRC_TICKFTCH grew the
* -- kernel chain 96B past $4800). merlin32 ERRORS on a
* -- negative ds; real Merlin-8 SILENTLY EMITS NOTHING and
* -- lets the next PUT overwrite -- see the commons,
* -- learning:01M0EDXWRX43PTQNR2WC0JT07F. Keep merlin32
* -- assembling FIRST so the loud failure always wins.
            ds    $8000-*   ;60 (SYS_VCSTAT, lazy consoles --
                                  ;docs/COVER-OFF.md); 56
                                  ;(wake-preempt); 55 (sl5)
                                  ;54 (VT102 sl 2/3: DCH/IRM +
                                     ;xenl, tty9.s/tty2.s/
                                     ;procfd.s, 377 B over
                                     ;$7200); 53 (VT102 slice
                                     ;1: tty9.s, 366 B
                                     ;over $7000); 52 (ser.s
                                     ;ttya0 RX ring; 51 was
                                     ;was 51: IL/DL + vi scroll
                                     ;over $6A00);
                                     ;48->49 (2026-09-08 jobctl
                                     ;B: PCB_STOPPED, the ^Z
                                     ;sweep, SYS_CONT/WAITJOB,
                                     ;the orphan reap -- 248 B
                                     ;over $6800);
                                     ;47 -> 48 (2026-09-08, alt
                                     ;screen -- tty2.s/tty5.s/
                                     ;tty7.s, 18 B over $6600);
                                     ;46 -> 47 (2026-09-07,
                                     ;lending IB fixes);
                                     ;45 -> 46 (2026-09-07,
                                     ;LENDING + LRU/park tables,
                                     ;228 B over $6200);
                                     ;44 -> 45 (run-batch,
                                     ;2026-09-04, 138 B over);
                                     ;43 -> 44 (surfaces);
                                     ;42 -> 43 (VIDMODE V2.0,
                                     ;370 B over); 40 -> 42
                                     ;(procsig, 2026-09-02)
