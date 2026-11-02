*---------------------------------------------------------------
* fdatestb.s -- image body for fdatest.s (docs/DUPFD-1.md, phase
* K). Split out so the top-level stays a thin MANIFEST
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J).
*
* WHAT THIS PROVES (scripts/check_fdact.py has the expected
* values and reads the kernel's own cells; keep the two in
* step).
* The parent builds fdactions lists and issues SYS_SPAWN itself.
*
* POSITIVE lists -- the spawn must succeed and the child ('V',
* exits $5A) must be reaped with that status:
*   P0  DUP 5<-3, END         fd 3 is the pipe's read end
*   P1  CLOSE 7 with the source byte $FF -- the reserved byte is
*       NOT judged (K6)
*   P2  a NULL list           (no actions)
*   P3  DUP 0<-3, DUP 1<-4    the shape sh builds
*   P4  32 x CLOSE 7, END     the bound's last legal list
*
* BAD lists -- the spawn must fail ERR_INVAL ($E1), each one
* TWICE:
* once with the builtin-image path 'V' (PRC_BLTN's carry-set
* branch, K7) and once with the file path /BIN/X (the branch
* that
* reaches PCPY_SPWN_PTH and LZ_WANT_SET, which arms LZ_WANT):
*   B0  DUP 4<-5     fd 5 is closed in the parent        (K1)
*   B1  DUP 0<-7     fd 7 is closed                      (K1)
*   B2  DUP 4<-8     source 8                            (K2)
*   B3  DUP 4<-$FF   source $FF
*   B4  DUP 8<-3     target 8
*   B5  DUP $FF<-3   target $FF
*   B6  CLOSE 8      target 8
*   B7  CLOSE $FF    target $FF
*   B8  opcode 3                                         (K3)
*   B9  opcode $FF
*   B10 CLOSE 7, then opcode 3 (a bad record AFTER a good one)
*   B11 33 x CLOSE 7, END     one record past the bound
*   B12 DUP 8<-0 -- a bad target whose SOURCE read leaves a
*       zero in PRC_BYTE (fd 0 is open): it primes B13
*   B13 list pointer $C000 -- the opcode is unreadable. A kernel
*       that ignored the read's carry would see the stale zero,
*       an END, and accept the list; so would B15 below
*   B14 DUP, 4 at $BFFE -- the source byte is at $C000
*   B15 DUP 4<-0 at $BFFD -- the NEXT opcode is at $C000 (the
*       source read just left a zero in PRC_BYTE again)
*   B16 DUP 4<-3, DUP 6<-7(closed), END                  (K4)
*   B17 DUP 4<-3, opcode 3, END
*   B18 DUP 4<-3, CLOSE 8, END
*   B19 255 bytes of $02, no END (every byte a valid CLOSE
*       record at every offset, so an unbounded walk never
*       ends). LAST: a kernel without the bound never returns.
*
* A read at $C000 or above is refused, and so is every read
* after it, so "the source byte is unreadable" (B14, B15) cannot
* be told apart from "the NEXT read is" -- a kernel that ignored
* only the source read's carry is an equivalent mutant, not a
* hole.
* In B16-B18 record 1 is a VALID dup that would add a reference
* to the pipe's read end: a validate-as-you-replay kernel
* applies it and then fails, and the gate's before/after
* refcounts differ.
*
* The parent stops at four handshakes (R_STATE = 1..4; it spins
* until the gate pokes R_GO to the same value) so that
* scripts/check_fdact.py can read the kernel at exactly those
* points: 1 = before any spawn, 2 = after the positives, 3 =
* after every bad list on the builtin path, 4 = after every one
* on the file path. Handshakes 2, 3 and 4 must read the same.
*
* THE POISON. A missing range check on a source reads PCB bytes
* that are NOT zero here: MAIN_ENTRY writes $0B at fd 8 and fd
* $FF of pid 1's table (PRC_SET_FDOBJ indexes with the very
* 8-bit add under test), which is the next PCB's first byte and
* pid 1's own PCB_BRK. A zero there would read as "closed" and
* fail the row anyway -- a vacuous green.
*---------------------------------------------------------------

NBAD        equ   20
POISON      equ   $0B
DN_OK       equ   $AA          ;R_DONE: the run finished
DN_BAD      equ   $EE          ;R_DONE: a setup call failed

* Result addresses in the parent process bank (aux bank 1).
R_POS_ERR   equ $1100        ;NPOS: 0 or the spawn errno
R_POS_PID   equ $1110        ;NPOS: the pid a spawn returned
R_POS_ST    equ $1120        ;NPOS: the child's exit status
R_BADV      equ $1140        ;NBAD: 'V' path, errno ($E1 wanted)
R_BADF      equ $1170        ;NBAD: file path, errno
R_PIPE      equ $11E0        ;rfd, wfd
R_FIN_ERR   equ $11D0        ;the last good spawn, after B0-B19
R_FIN_ST    equ $11D1
R_DONE      equ $11F0
R_ERR       equ $11F1
R_STATE     equ $11F2        ;parent -> gate: at handshake n
R_GO        equ $11F3        ;gate -> parent: released past n
R_WSTAT     equ $11F4        ;SC_WAIT's status landing cell

* Parent scratch. $9000+ is ordinary process memory in every
* bank; the image ends below $8800.
V_PATH      equ $9000        ;"V" -- PRC_BLTN's builtin tag
F_PATH      equ $9010        ;"/BIN/X" -- a file spawn
SPAWN_PARM  equ $9020
WAIT_PARM   equ $9030
PIPE_PARM   equ $9034
DUP2_PARM   equ $9038
ARGV_ARR    equ $9040        ;&path, NULL
LIST_BUF    equ $9100        ;258 B: the B19 fill needs 255+2

* Parent zero page (its own bank's ZP -- no kernel cells here).
CP          equ $20          ;2 case table cursor
DP          equ $22          ;2 where this list lives
SRCP        equ $24          ;2 literal bytes to copy
CI          equ $26          ;case index
PV          equ $27          ;path variant: 0 builtin, 1 file
CNT         equ $28
CK          equ $29

* Child scratch (its own bank).
V_PARML     equ $0900

*---------------------------------------------------------------
* Boot helpers -- same shape as argvtestb.s's.
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

* -- the poison: pid 1's fd 8 and fd $FF, by the same 8-bit add
* -- the kernel's own PRC_GET_FDOBJ makes.
POISON_PCB  lda   #1
            sta   P_PID
            lda   #8
            sta   P_FD
            lda   #POISON
            sta   P_TMP2
            jsr   PRC_SET_FDOBJ
            lda   #1
            sta   P_PID
            lda   #$FF
            sta   P_FD
            lda   #POISON
            sta   P_TMP2
            jsr   PRC_SET_FDOBJ
            rts

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

* -- a boot volume for the virtual root, so "/BIN/X" translates
* -- WITHOUT an MLI call (VR_BVLEN reads PRC_PFXSAVE if set) and
* -- reaches LZ_WANT_SET: a raw image has no ProDOS to ask.
            lda   #2
            sta   PRC_PFXSAVE
            lda   #"/"+$80
            sta   PRC_PFXSAVE+1
            lda   #'V'
            sta   PRC_PFXSAVE+2

            lda   #1
            jsr   PRC_STMP_BANK
            lda   #1
            jsr   PRC_SYNTH_FRM
            jsr   PATCH_PAR_FRM
            jsr   BOOT_CPY_PAR

            lda   #1
            ldx   #1
            jsr   SCH_CREATE
            jsr   POISON_PCB
            jsr   SCH_START

*---------------------------------------------------------------
* PARENT_PROC -- copied to its own assembled address in bank 1.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_DONE
            stz   R_STATE
            stz   R_GO
* -- $FF = "not reached": a stuck guest still says which rows
* -- it got through.
            ldx   #NBAD-1
            lda   #$FF
:ini        sta   R_BADV,x
            sta   R_BADF,x
            dex
            bpl   :ini

            lda   #'V'+$80               ;"V": one character,
            sta   V_PATH                 ;matched by PRC_BLTN
            stz   V_PATH+1
            ldx   #0
:fp         lda   FPATH_TXT,x
            sta   F_PATH,x
            beq   :fpdone
            inx
            bra   :fp
:fpdone

* -- fd 3 and fd 4 = the pipe's two ends (lowest free from 3).
            lda   #<R_PIPE
            sta   PIPE_PARM
            lda   #>R_PIPE
            sta   PIPE_PARM+1
            lda   #<PIPE_PARM
            ldx   #>PIPE_PARM
            ldy   #SYS_PIPE
            jsr   $FF00
            bcc   :pipeok
            sta   R_ERR
            lda   #DN_BAD
            sta   R_DONE
            bra   *
:pipeok
* -- fd 0 and fd 1 become the pipe's read end too, so B12-B15's
* -- stale-byte priming is a real, open fd (see the header).
            lda   #3
            ldx   #0
            jsr   P_DUP2
            lda   #3
            ldx   #1
            jsr   P_DUP2
            lda   #1                     ;handshake 1: nothing
            jsr   P_SYNC                 ;has been spawned yet

* -- the positives. The first spawn after handshake 1 is a GOOD
* -- list with a dup in it: the gate poked PRC_PAR_PID to a
* -- slot nobody owns, so a validator that read it (instead of
* -- K_CURPID) fails here, before any spawn can have set it.
            lda   #<POS_TAB
            sta   CP
            lda   #>POS_TAB
            sta   CP+1
            stz   CI
            stz   PV
* -- FDA_NPOS is 0 in the plain twin: no file to load a child
            lda   #FDA_NPOS
            beq   :pdone
:ploop      jsr   P_DECODE
            bcs   :pdone
            jsr   P_SPAWN
            ldx   CI
            bcs   :pfail
            sta   R_POS_PID,x
            lda   #0
            sta   R_POS_ERR,x
            jsr   P_WAIT
            ldx   CI
            lda   R_WSTAT
            sta   R_POS_ST,x
            bra   :pnext
:pfail      sta   R_POS_ERR,x
:pnext      inc   CI
            bra   :ploop
:pdone
            lda   #2                     ;handshake 2: positives
            jsr   P_SYNC                 ;reaped

* -- every bad list, builtin path then file path.
            stz   PV
:vloop      lda   #<BAD_TAB
            sta   CP
            lda   #>BAD_TAB
            sta   CP+1
            stz   CI
:bloop      jsr   P_DECODE
            bcs   :vnext
            jsr   P_SPAWN
            bcs   :bfail
            lda   #0                     ;it SPAWNED -- wrong
            jsr   P_STORE
            jsr   P_WAIT                 ;reap it anyway
            bra   :bnext
:bfail      jsr   P_STORE
:bnext      inc   CI
            bra   :bloop
* -- handshake 3 after the builtin pass, 4 after the file pass:
* -- a kernel that wanders into the loader on the file pass has
* -- still been measured after the first.
:vnext      lda   PV
            clc
            adc   #3
            jsr   P_SYNC
            inc   PV
            lda   PV
            cmp   #2
            bne   :vloop

* -- a good spawn still works after all that.
            lda   #FDA_NPOS
            beq   :alldone
            lda   #<POS_TAB
            sta   CP
            lda   #>POS_TAB
            sta   CP+1
            stz   PV
            jsr   P_DECODE
            jsr   P_SPAWN
            bcs   :finfail
            lda   #0
            sta   R_FIN_ERR
            jsr   P_WAIT
            lda   R_WSTAT
            sta   R_FIN_ST
            bra   :alldone
:finfail    sta   R_FIN_ERR
:alldone    lda   #DN_OK
            sta   R_DONE
:halt       bra   :halt

*---------------------------------------------------------------
* P_DUP2 -- dup2(A, X); any failure ends the run.
*---------------------------------------------------------------
P_DUP2      sta   DUP2_PARM
            stx   DUP2_PARM+1
            lda   #<DUP2_PARM
            ldx   #>DUP2_PARM
            ldy   #SYS_DUP2
            jsr   $FF00
            bcc   :ok
            sta   R_ERR
            lda   #DN_BAD
            sta   R_DONE
            bra   *
:ok         rts

*---------------------------------------------------------------
* P_SYNC -- A = n: raise it and wait for the gate to release it.
*---------------------------------------------------------------
P_SYNC      sta   R_STATE
:w          lda   R_GO
            cmp   R_STATE
            bne   :w
            rts

*---------------------------------------------------------------
* P_STORE -- A = this bad list's result; into R_BADV[CI] or
* R_BADF[CI] by PV.
*---------------------------------------------------------------
P_STORE     ldx   CI
            ldy   PV
            bne   :file
            sta   R_BADV,x
            rts
:file       sta   R_BADF,x
            rts

*---------------------------------------------------------------
* P_DECODE -- the case at (CP): build its list at its address
* and
* leave that address in SPAWN_PARM+4. Carry SET = end of table.
*   kind 0  dest(2) n bytes[n]   copy n literal bytes
*   kind 1  dest(2)              255 x $02 (a CLOSE of fd 2
*                                at every offset), no END
*   kind 2  dest(2) count        count x (CLOSE 7), END
*   kind $FF                     end of table
*---------------------------------------------------------------
P_DECODE    ldy   #0
            lda   (CP),y
            cmp   #$FF
            bne   :more
            sec
            rts
:more       sta   CK
            iny
            lda   (CP),y
            sta   DP
            sta   SPAWN_PARM+4
            iny
            lda   (CP),y
            sta   DP+1
            sta   SPAWN_PARM+5
            lda   CK
            beq   :lit
            cmp   #1
            beq   :fill

* -- kind 2: count x [CLOSE, 7, 0] then END
            iny
            lda   (CP),y
            sta   CNT
            ldy   #0
:rep        lda   CNT
            beq   :repend
            lda   #FDACT_CLOSE
            sta   (DP),y
            iny
            lda   #7
            sta   (DP),y
            iny
            lda   #0
            sta   (DP),y
            iny
            dec   CNT
            bra   :rep
:repend     lda   #FDACT_END
            sta   (DP),y
            lda   #4
            bra   :advance

* -- kind 1: 255 x $02
:fill       ldy   #0
            lda   #2
:fl         sta   (DP),y
            iny
            cpy   #255
            bne   :fl
            lda   #3
            bra   :advance

* -- kind 0: n literal bytes from (CP)+4
:lit        iny
            lda   (CP),y
            sta   CNT
            clc
            lda   CP
            adc   #4
            sta   SRCP
            lda   CP+1
            adc   #0
            sta   SRCP+1
            ldy   #0
:cb         cpy   CNT
            beq   :cbdone
            lda   (SRCP),y
            sta   (DP),y
            iny
            bra   :cb
:cbdone     lda   CNT
            clc
            adc   #4

:advance    clc                           ;CP += A
            adc   CP
            sta   CP
            bcc   :ok
            inc   CP+1
:ok         clc
            rts

*---------------------------------------------------------------
* P_SPAWN -- SYS_SPAWN with the path PV selects and the list
* P_DECODE just left in SPAWN_PARM+4. Carry and A straight back.
*---------------------------------------------------------------
P_SPAWN     lda   PV
            bne   :file
            lda   #<V_PATH
            ldx   #>V_PATH
            bra   :set
:file       lda   #<F_PATH
            ldx   #>F_PATH
:set        sta   SPAWN_PARM
            sta   ARGV_ARR
            stx   SPAWN_PARM+1
            stx   ARGV_ARR+1
            stz   ARGV_ARR+2
            stz   ARGV_ARR+3
            lda   #<ARGV_ARR
            sta   SPAWN_PARM+2
            lda   #>ARGV_ARR
            sta   SPAWN_PARM+3
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
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

FPATH_TXT   asc   '/BIN/X'
            dfb   0

*---------------------------------------------------------------
* The case tables. LIST_BUF = $9100. Rows are in the header.
*---------------------------------------------------------------
POS_TAB
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;P0
            dfb   FDACT_DUP,5,3,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;P1
            dfb   FDACT_CLOSE,7,$FF,FDACT_END
            dfb   0,0,0,0                        ;P2 NULL
            dfb   0,<LIST_BUF,>LIST_BUF,7        ;P3
            dfb   FDACT_DUP,0,3,FDACT_DUP,1,4,FDACT_END
            dfb   2,<LIST_BUF,>LIST_BUF,32       ;P4
            dfb   $FF

BAD_TAB
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B0
            dfb   FDACT_DUP,4,5,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B1
            dfb   FDACT_DUP,0,7,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B2
            dfb   FDACT_DUP,4,8,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B3
            dfb   FDACT_DUP,4,$FF,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B4
            dfb   FDACT_DUP,8,3,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B5
            dfb   FDACT_DUP,$FF,3,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B6
            dfb   FDACT_CLOSE,8,0,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B7
            dfb   FDACT_CLOSE,$FF,0,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B8
            dfb   3,4,3,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B9
            dfb   $FF,4,3,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,7        ;B10
            dfb   FDACT_CLOSE,7,0,3,4,3,FDACT_END
            dfb   2,<LIST_BUF,>LIST_BUF,33       ;B11
            dfb   0,<LIST_BUF,>LIST_BUF,4        ;B12
            dfb   FDACT_DUP,8,0,FDACT_END
            dfb   0,$00,$C0,0                    ;B13 ptr $C000
            dfb   0,$FE,$BF,2                    ;B14 at $BFFE
            dfb   FDACT_DUP,4
            dfb   0,$FD,$BF,3                    ;B15 at $BFFD
            dfb   FDACT_DUP,4,0
            dfb   0,<LIST_BUF,>LIST_BUF,7        ;B16
            dfb   FDACT_DUP,4,3,FDACT_DUP,6,7,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,7        ;B17
            dfb   FDACT_DUP,4,3,3,0,0,FDACT_END
            dfb   0,<LIST_BUF,>LIST_BUF,7        ;B18
            dfb   FDACT_DUP,4,3,FDACT_CLOSE,8,0,FDACT_END
            dfb   1,<LIST_BUF,>LIST_BUF          ;B19
            dfb   $FF

PAR_PROC_END
PAR_PROC_LEN equ PAR_PROC_END-PARENT_PROC

*---------------------------------------------------------------
* SIMG_FDA -- the 'V' child. Copied verbatim to $0800 in its own
* bank: branches only, no absolute reference to a label inside
* this blob. Exits $5A.
*---------------------------------------------------------------
SIMG_FDA
            lda   #$5A
            sta   V_PARML
            lda   #<V_PARML
            ldx   #>V_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
SIMG_FDA_END

* -- the pad places the image at a fixed block boundary; NBLOCKS
* -- in fdatest.s must equal ($8800-$0800)/512. merlin32 ERRORS
* on
* -- a negative ds; real Merlin-8 silently emits nothing
* -- (learning:01M0EDXWRX43PTQNR2WC0JT07F).
            ds    $8800-*
