*---------------------------------------------------------------
* stickytestb.s -- image body for stickytest.s (task #15). Split
* out so the top-level stays a thin MANIFEST -- same rationale
* as fileproctestb.s's own header (real Merlin holds the
* resident top-level source AND the PUT file being read in the
* same 41215-byte buffer; every byte here would come off every
* module's budget -- learning:01M051EM2HQ3ZVJTR1W9P3G86J).
*
* INTERFACE ASSUMPTION (flagged for the orchestrator): this file
* codes against docs/STICKY.md's DESCRIBED interface, not
* src/kernel/sticky.s (written in parallel by another agent,
* does not exist yet at authoring time). docs/STICKY.md section
* 5 rules the cache is TRANSPARENT to the spawn ABI --
* SYS_SPAWN's parameter block and return convention are
* UNCHANGED; the cache lives entirely inside the kernel's own
* path-based spawn-load routine. The one place this gate must
* guess at a new symbol is boot-time init: SCH_INIT and PRC_INIT
* both need an init call at boot (see ENTRY below), and a fresh
* annex cache directory (SB_DIR_CNT entries, docs/STICKY.md
* section 2) plausibly needs the same treatment. This file
* assumes the call is named SB_INIT, takes no arguments, and is
* safe to call once, right after PRC_INIT. If the real sticky.s
* exports a different name, or folds init into PRC_INIT itself
* (no separate call needed), that one JSR is the only line to
* reconcile.
*---------------------------------------------------------------


* -- Sentinel/result addresses in the parent process bank
* (task #15 gate protocol) --
* R_PHASE cycles through these values so check_sticky.py can
* find spawn-start/spawn-complete boundaries by polling ONE
* fixed address, the same step-and-peek idiom check_bankcopy.py
* uses for its READY/GO handshake:
*   $00 boot / SETUP_PATHS not yet done
*   $01 about to SYS_SPAWN #1 (cold spawn start)
*   $02 SYS_WAIT #1 returned  (cold spawn complete)
*   $03 about to SYS_SPAWN #2 (warm spawn start, same content)
*   $04 SYS_WAIT #2 returned  (warm spawn complete)
*   $05 rewrite (UNLINK+CREAT+WRITE+CLOSE) complete
*   $06 about to SYS_SPAWN #3 (post-rewrite spawn start)
*   $07 SYS_WAIT #3 returned  (post-rewrite spawn complete)
R_BASE          equ $1300
R_PHASE         equ R_BASE+0
R_SPAWN1_PID    equ R_BASE+1
R_WAIT1_PID     equ R_BASE+2
R_WAIT1_STAT    equ R_BASE+3   ;expect $55 (filechild.s's own
                               ;exit status -- OLD image ran)
R_SPAWN2_PID    equ R_BASE+4
R_WAIT2_PID     equ R_BASE+5
R_WAIT2_STAT    equ R_BASE+6   ;expect $55 again -- warm hit
                               ;must still serve the SAME
                               ;(unchanged) content
R_REWRITE_FD    equ R_BASE+7
R_SPAWN3_PID    equ R_BASE+8
R_WAIT3_PID     equ R_BASE+9
R_WAIT3_STAT    equ R_BASE+10  ;expect $77 (SCHILD_V2's exit
                               ;status) -- proves the THIRD
                               ;spawn ran the NEW image, not a
                               ;stale cached copy of the OLD one
R_RESULT_LEN    equ 11         ;R_BASE .. R_BASE+10, one peek

R_DONE          equ $13F0
R_ERR           equ $13F1
R_STEP          equ $13F2      ;1=spawn1 2=wait1 3=spawn2
                               ;4=wait2 5=unlink 6=create
                               ;7=open-for-write 8=write
                               ;9=close 10=spawn3 11=wait3

* Parent process scratch (paths + MLI/syscall parameter blocks).
MLI_PATH        equ $1000      ;"/mnt/MAUX/SCHILD", MLI length-
                               ;prefixed plain-ASCII form --
                               ;used by SYS_UNLINK/SYS_CREAT/
                               ;SYS_OPEN (real MLI call numbers,
                               ;syscall.equ)
SPAWN_PATH      equ $1020 ;"/mnt/MAUX/SCHILD", NUL-terminated
                               ;high-bit liba-string form --
                               ;used by SYS_SPAWN (maux-native
                               ;call, same convention
                               ;fileproctestb.s's CHILD_PATH/
                               ;ECHO_PATH use)
OPEN_PARM       equ $1040
CREATE_PARM     equ $1050
UNLINK_PARM     equ $1060
WRITE_PARM      equ $1070
CLOSE_PARM      equ $1080
SPAWN_PARM      equ $1090
WAIT_PARM       equ $10A0

*---------------------------------------------------------------
* Boot helpers -- identical shape to fileproctestb.s's own
* (BOOT_CPY_PAR/PATCH_PAR_FRM/NOIRQ/ENTRY).
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

NOIRQ       rts

ENTRY       sei
            cld
            ldx   #$FF
            txs

            ldy   #0
:banner     lda   BANNER,y
            sta   $0400,y
            iny
            cpy   #BANNER_END-BANNER
            bne   :banner

            jsr   INSTALL_COPY
            lda   #<NOIRQ
            sta   K_IRQ_HOOK
            lda   #>NOIRQ
            sta   K_IRQ_HOOK+1
            jsr   SCH_INIT
            jsr   PRC_INIT          ;which now clears the lazy-
                                    ;free tags itself (LZ_INIT,
                                    ;src/kernel/lazyfree.s) --
                                    ;the separate SB_INIT call
                                    ;this gate made when the
                                    ;cache was a bolt-on module
                                    ;is gone with the cache

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

BANNER      asc   "MAUX STICKY"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 (same reason fileproctestb.s gives: absolute JSR/JMP
* operands throughout).
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_STEP
* -- zero the WHOLE result block, not just R_PHASE: the gate
* -- timestamps the sample where R_SPAWNx_PID goes nonzero to
* -- isolate the loader window (spawn call -> spawn returned),
* -- so a junk pre-boot byte there would fake an instant spawn.
            ldx   #R_RESULT_LEN-1
:rzero      stz   R_BASE,x
            dex
            bpl   :rzero
            jsr   SETUP_PATHS

* -- Phase 1: cold spawn (miss -- populates the cache, per
* -- docs/STICKY.md section 5's "cold spawn" path) --
            lda   #1
            sta   R_STEP
            lda   #1
            sta   R_PHASE
            jsr   SPAWN_SCHILD
            bcc   :sp1ok
            jmp   P_ERR
:sp1ok      sta   R_SPAWN1_PID
            lda   #2
            sta   R_STEP
            jsr   WAIT_SCHILD1
            bcc   :wt1ok
            jmp   P_ERR
:wt1ok      sta   R_WAIT1_PID
            lda   #2
            sta   R_PHASE

* -- Phase 2: warm spawn -- SAME pathname, file unchanged. Per
* -- docs/STICKY.md section 5 this should be GET_FILE_INFO +
* -- one BankCopy, no OPEN/READ loop. --
            lda   #3
            sta   R_STEP
            lda   #3
            sta   R_PHASE
            jsr   SPAWN_SCHILD
            bcc   :sp2ok
            jmp   P_ERR
:sp2ok      sta   R_SPAWN2_PID
            lda   #4
            sta   R_STEP
            jsr   WAIT_SCHILD2
            bcc   :wt2ok
            jmp   P_ERR
:wt2ok      sta   R_WAIT2_PID
            lda   #4
            sta   R_PHASE

* -- Phase 3: rewrite the child binary ON DISK through the
* -- kernel's own file syscalls (docs/STICKY.md section 4 item
* -- 2's invalidation-by-pathname path: SYS_UNLINK then
* -- SYS_CREAT). The NEW body is SCHILD_V2 -- byte-identical in
* -- shape to filechild.s but exits $77 instead of $55, so
* -- wait() status alone proves which image ran. --
            lda   #5
            sta   R_STEP
            jsr   UNLK_SCHILD
            bcc   :unlok
            jmp   P_ERR
:unlok      lda   #6
            sta   R_STEP
            jsr   CRT_SCHILD
            bcc   :crtok
            jmp   P_ERR
:crtok      lda   #7
            sta   R_STEP
            jsr   OPN_SCHILD_WR
            bcc   :opnwrok
            jmp   P_ERR
:opnwrok    sta   R_REWRITE_FD
            lda   #8
            sta   R_STEP
            jsr   WR_SCHILD_V2
            bcc   :wrtok
            jmp   P_ERR
:wrtok      lda   #9
            sta   R_STEP
            lda   R_REWRITE_FD
            jsr   CLOSE_FD
            bcc   :clsok
            jmp   P_ERR
:clsok      lda   #5
            sta   R_PHASE

* -- Phase 4: third spawn. The kernel's own SYS_CREAT above must
* -- have invalidated the cached entry for this pathname --
* (docs/STICKY.md section 4 item 2) -- this spawn must load --
* the NEW on-disk bytes, cold or warm-but-correct either way; --
* what the gate checks is the observed exit status, $77, never
* -- the stale $55. --
            lda   #10
            sta   R_STEP
            lda   #6
            sta   R_PHASE
            jsr   SPAWN_SCHILD
            bcc   :sp3ok
            jmp   P_ERR
:sp3ok      sta   R_SPAWN3_PID
            lda   #11
            sta   R_STEP
            jsr   WAIT_SCHILD3
            bcc   :wt3ok
            jmp   P_ERR
:wt3ok      sta   R_WAIT3_PID
            lda   #7
            sta   R_PHASE

            lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

SETUP_PATHS lda   #16                   ;/mnt/MAUX/SCHILD, MLI
                                        ;length-prefixed form
            sta   MLI_PATH
            lda   #'/'
            sta   MLI_PATH+1
            lda   #'m'
            sta   MLI_PATH+2
            lda   #'n'
            sta   MLI_PATH+3
            lda   #'t'
            sta   MLI_PATH+4
            lda   #'/'
            sta   MLI_PATH+5
            lda   #'M'
            sta   MLI_PATH+6
            lda   #'A'
            sta   MLI_PATH+7
            lda   #'U'
            sta   MLI_PATH+8
            lda   #'X'
            sta   MLI_PATH+9
            lda   #'/'
            sta   MLI_PATH+10
            lda   #'S'
            sta   MLI_PATH+11
            lda   #'C'
            sta   MLI_PATH+12
            lda   #'H'
            sta   MLI_PATH+13
            lda   #'I'
            sta   MLI_PATH+14
            lda   #'L'
            sta   MLI_PATH+15
            lda   #'D'
            sta   MLI_PATH+16

            lda   #$AF ;/mnt/MAUX/SCHILD, high-
                                         ;bit NUL string
                                         ;(SYS_SPAWN ABI, same
                                         ;convention as
                                         ;fileproctestb.s's
                                         ;CHILD_PATH)
            sta   SPAWN_PATH
            lda   #$ED
            sta   SPAWN_PATH+1
            lda   #$EE
            sta   SPAWN_PATH+2
            lda   #$F4
            sta   SPAWN_PATH+3
            lda   #$AF
            sta   SPAWN_PATH+4
            lda   #$CD
            sta   SPAWN_PATH+5
            lda   #$C1
            sta   SPAWN_PATH+6
            lda   #$D5
            sta   SPAWN_PATH+7
            lda   #$D8
            sta   SPAWN_PATH+8
            lda   #$AF
            sta   SPAWN_PATH+9
            lda   #$D3
            sta   SPAWN_PATH+10
            lda   #$C3
            sta   SPAWN_PATH+11
            lda   #$C8
            sta   SPAWN_PATH+12
            lda   #$C9
            sta   SPAWN_PATH+13
            lda   #$CC
            sta   SPAWN_PATH+14
            lda   #$C4
            sta   SPAWN_PATH+15
            stz   SPAWN_PATH+16
            rts

SPAWN_SCHILD
            lda   #<SPAWN_PATH
            sta   SPAWN_PARM
            lda   #>SPAWN_PATH
            sta   SPAWN_PARM+1
            stz   SPAWN_PARM+2      ;no argv
            stz   SPAWN_PARM+3
            stz   SPAWN_PARM+4      ;no fdactions
            stz   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

WAIT_SCHILD1
            lda   #<R_WAIT1_STAT
            sta   WAIT_PARM
            lda   #>R_WAIT1_STAT
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

WAIT_SCHILD2
            lda   #<R_WAIT2_STAT
            sta   WAIT_PARM
            lda   #>R_WAIT2_STAT
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

WAIT_SCHILD3
            lda   #<R_WAIT3_STAT
            sta   WAIT_PARM
            lda   #>R_WAIT3_STAT
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

UNLK_SCHILD lda   #1
            sta   UNLINK_PARM
            lda   #<MLI_PATH
            sta   UNLINK_PARM+1
            lda   #>MLI_PATH
            sta   UNLINK_PARM+2
            lda   #<UNLINK_PARM
            ldx   #>UNLINK_PARM
            ldy   #SYS_UNLINK
            jsr   $FF00
            rts

CRT_SCHILD  lda   #7
            sta   CREATE_PARM
            lda   #<MLI_PATH
            sta   CREATE_PARM+1
            lda   #>MLI_PATH
            sta   CREATE_PARM+2
            lda   #$C3
            sta   CREATE_PARM+3
            lda   #$06
            sta   CREATE_PARM+4
            stz   CREATE_PARM+5      ;aux_type lo
            lda   #$08
            sta   CREATE_PARM+6      ;aux_type hi -- $0800,
                                     ;matches LOAD_BASE, same as
                                     ;the disk-staged SCHILD/
                                     ;FCHILD aux_type
            lda   #$01
            sta   CREATE_PARM+7
            stz   CREATE_PARM+8
            stz   CREATE_PARM+9
            stz   CREATE_PARM+10
            stz   CREATE_PARM+11
            lda   #<CREATE_PARM
            ldx   #>CREATE_PARM
            ldy   #SYS_CREAT
            jsr   $FF00
            rts

OPN_SCHILD_WR
            lda   #<MLI_PATH
            sta   OPEN_PARM+1
            lda   #>MLI_PATH
            sta   OPEN_PARM+2
            lda   #3
            sta   OPEN_PARM
            stz   OPEN_PARM+3
            stz   OPEN_PARM+4
            stz   OPEN_PARM+5
            lda   #<OPEN_PARM
            ldx   #>OPEN_PARM
            ldy   #SYS_OPEN
            jsr   $FF00
            bcs   :err
            lda   OPEN_PARM+5
            clc
            rts
:err        sec
            rts

STATUS_V2   equ   $77
*-- SCHILD_V2 template moved ABOVE its writer (S9 EQU
*-- burn-down 2026-08-29): SCHILD_V2_LEN was used in an
*-- immediate before its definition. Preceded by an rts --
*-- never fallen into.

SCHILD_V2   lda   #STATUS_V2
            sta   SV2_PARM
            lda   #<SV2_PARM
            ldx   #>SV2_PARM
            ldy   #SYS_EXIT
            jsr   $FF00
:v2park     bra   :v2park
SCHILD_V2_END
SCHILD_V2_LEN equ SCHILD_V2_END-SCHILD_V2

WR_SCHILD_V2
            lda   R_REWRITE_FD
            sta   WRITE_PARM+1
            lda   #<SCHILD_V2
            sta   WRITE_PARM+2
            lda   #>SCHILD_V2
            sta   WRITE_PARM+3
            lda   #SCHILD_V2_LEN
            sta   WRITE_PARM+4
            stz   WRITE_PARM+5
            stz   WRITE_PARM+6
            stz   WRITE_PARM+7
            lda   #4
            sta   WRITE_PARM
            lda   #<WRITE_PARM
            ldx   #>WRITE_PARM
            ldy   #SYS_WRITE
            jsr   $FF00
            rts

CLOSE_FD    sta   CLOSE_PARM+1
            lda   #1
            sta   CLOSE_PARM
            lda   #<CLOSE_PARM
            ldx   #>CLOSE_PARM
            ldy   #SYS_CLOSE
            jsr   $FF00
            rts

* -- Embedded "new" child image. Written to disk at runtime via
* -- WR_SCHILD_V2 (never executed in place here -- it is pure --
* data as far as PARENT_PROC is concerned, exactly like --
* fileproctestb.s's SIMG_EXIT stubs are inert bytes until --
* copied elsewhere). Byte-identical in SHAPE to filechild.s --
* (src/test/filechild.s, org $0800, single SYS_EXIT with a --
* fixed 1-byte parm at $0900) except for the status byte, so --
* neither instruction references its OWN assembled address -- --
* only the fixed external syscall trampoline ($FF00) and a --
* fixed external scratch cell ($0900) -- making the encoded --
* bytes correct regardless of where in PARENT_PROC this blob --
* happens to land, and correct again once BankCopy'd to --
* LOAD_BASE ($0800) in a fresh child bank by the spawn path. --
*-- STATUS_V2: hoisted above the relocated SCHILD_V2 template.
SV2_PARM    equ   $0900        ;same fixed cell filechild.s's
                               ;own PARM uses -- safe: each
                               ;child image runs alone in its
                               ;own bank/address space, never
                               ;concurrently with filechild.s

PAR_PROC_LEN equ *-PARENT_PROC
