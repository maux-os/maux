*---------------------------------------------------------------
* processtestb.s -- image body for processtest.s.
* Split out so the top-level stays a thin MANIFEST: real
* Merlin holds the resident top-level source AND the PUT
* file being read in the same 41215-byte buffer, so every
* byte here would come off every module's budget.
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J)
*---------------------------------------------------------------


* Result addresses in the parent process bank.
* RELOCATED $11xx -> $19xx (and scratch $10xx -> $18xx),
* 2026-09-02: PARENT_PROC is 2,413 bytes now -- copied to $0800
* it runs past $1100, and case 16's result stores were landing
* INSIDE code still to run (the wait wrote a child's status
* over the next case's bytes; the BRK trap said so). The blob
* may grow to $1800 before these move again -- and the copy
* length is PAR_PROC_LEN, so a blob past $1800 is ALSO the
* moment to re-derive this layout, not just nudge it
* ([[sacrificial-regions-are-load-bearing]]: ask what writes a
* region before reclaiming it).
R_EXT_SPW_PID  equ $1900
R_EXIT_STATUS     equ $1901
R_EXT_WT_PID   equ $1902
R_PIPE_RFD        equ $1903
R_PIPE_WFD        equ $1904
R_READER_PID      equ $1905
R_WRITER_PID      equ $1906
R_WAIT1_STAT    equ $1907
R_WAIT1_PID       equ $1908
R_WAIT2_STAT    equ $1909
R_WAIT2_PID       equ $190A
* -- brk gate (2026-08-22). Every SUCCESS-expected call stores
* -- the two bytes the kernel wrote back over the request (the
* -- PREVIOUS break); every FAILURE-expected call stores the
* -- errno instead. A success-expected call that actually fails
* -- is still caught: the kernel skips the copy-out on the error
* -- path, so the slot keeps the REQUEST, which never equals the
* -- expected old break in any step below.
R_BRK_E1          equ $1910   ;GROW before any SET      -> $E1
R_BRK_O1          equ $1911   ;SET $4000, old           -> $0000
R_BRK_O2          equ $1913   ;GROW $1800, old          -> $4000
R_BRK_O3          equ $1915   ;GROW $0001, old          -> $5000
R_BRK_O4          equ $1917   ;GROW 0 (query)           -> $5100
R_BRK_E2          equ $1919   ;SET $BF01                -> $E0
R_BRK_E3          equ $191A   ;SET $0700                -> $E1
R_BRK_O5          equ $191B   ;GROW 0 after 2 failures  -> $5100
R_BRK_O6          equ $191D   ;SET $BF00 (ceiling), old -> $5100
R_BRK_E4          equ $191F   ;GROW $0001 at ceiling    -> $E0
R_BRK_O7          equ $1920   ;SET $07FF (floor), old   -> $BF00
R_BRK_CST         equ $1922   ;child 'B' exit status    -> $B1
R_BRK_O8          equ $1923   ;GROW 0 after spawn/wait  -> $0800
* -- SYS_DUP2 (call 9, 2026-08-25). Fresh pipe, so these do not
* -- depend on whatever the pipe tests above left behind.
R_D2_RFD          equ $1930   ;pipe read fd  (SYS_PIPE writes)
R_D2_WFD          equ $1931   ;pipe write fd (SYS_PIPE writes)
R_D2_RET5         equ $1932   ;dup2(wfd,5)      -> 5
R_D2_SAME         equ $1933   ;dup2(rfd,rfd)    -> rfd
R_D2_BYTE         equ $1934   ;byte round-tripped THROUGH the
                              ;  alias after the original wfd
                              ;  was closed     -> $5A
R_D2_ERANGE       equ $1935   ;dup2(rfd,9)      -> errno
R_D2_ECLOSED      equ $1936   ;dup2(7,5), 7 shut-> errno
* -- SYS_KILL gauntlet (call 13, 2026-09-01). One cell per
* -- policy arm of src/kernel/procspawn2.s PRC_KILL.
R_K_ESRCH         equ $1938   ;kill(14), unused slot   -> $E7
R_K_E0            equ $1939   ;kill(0)                 -> $E7
R_K_PID           equ $193A   ;the blocked reader's pid
R_K_RET           equ $193B   ;kill(reader)            -> $00
R_K_WPID          equ $193C   ;wait after the kill: pid matches
R_K_WSTAT         equ $193D   ;  and status            -> $8F
R_K_ROOT          equ $193E   ;'Q' child's kill(1)     -> $E1
R_K_SELF          equ $193F   ;'K' child kills ITSELF  -> $8F
R_K_SIG0          equ $1940   ;kill(child, 0) probe    -> $00
* -- SYS_SIGNAL/SYS_SIGPEND/EINTR gauntlet (calls 14/15,
* -- 2026-09-02, docs/SIGNALS.md). One cell per policy arm.
R_S_OLD1          equ $1941   ;signal(2,CATCH) old     -> $00
R_S_PEND1         equ $1942   ;kill(self,2); sigpend   -> $02
R_S_PEND0         equ $1943   ;sigpend drained         -> $00
R_S_IGN           equ $1944   ;kill(self,15) under IGN:
                              ;  still alive marker    -> $77
R_S_E9            equ $1945   ;signal(9,CATCH)         -> $E1
R_S_EINTR         equ $1946   ;'C' child: blocked read
                              ;  EINTR'd, sigpend=15   -> $45
R_S_INH           equ $1947   ;'I' child: signal(3,CATCH)
                              ;  old = inherited IGN   -> $51
R_DONE            equ $19F0
R_ERR             equ $19F1

* Parent process scratch.
P_PATH      equ $1800
P_ARGV      equ $1810
P_SPAWN     equ $1820
P_WAIT      equ $1828
P_PIPEPARM  equ $182C
P_RFDA      equ $1830
P_WFDA      equ $1840
P_CLOSE     equ $1850
P_BRKP      equ $1860        ;brk parmlist: value lo/hi + mode
P_BRKSPWN   equ $1864        ;spawn parmlist for the 'B' child
P_BRKPATH   equ $1870
P_BRKARGV   equ $1874
P_BRKWAIT   equ $1878
P_D2PIPE    equ $1880        ;SYS_PIPE parmlist for the dup2 set
P_D2P       equ $1884        ;dup2 params: oldfd, newfd
P_D2IO      equ $1888        ;MLI read/write parmlist (8 bytes)
P_D2CL      equ $1894        ;close parmlist
P_D2BUF     equ $1898        ;one byte, written then read back
P_KILLP     equ $189C        ;SYS_KILL parmlist: pid, signo
P_KFDS      equ $189F        ;kill cases' pipe fds: rfd, wfd
                             ;(SYS_PIPE's parm is a POINTER to
                             ;this pair, not the pair)
P_RFDS      equ $18A2        ;case 16e's READY pipe fds

* Child process scratch.
C_PARML     equ $0900
C_BUF       equ $0940

*---------------------------------------------------------------
* Boot helpers.
*---------------------------------------------------------------
STAMP_MAIN  lda   LCBANK2_RAM
            lda   LCBANK2_RAM
            ldy   #0
:cp         lda   FFP_SYSC_ENT,y
            sta   $FF00,y
            iny
            bne   :cp
            rts

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
            lda   #<LOAD_BASE
            sta   K_BC_DSTADDR
            lda   #>LOAD_BASE
            sta   K_BC_DSTADDR+1
            lda   #1
            sta   K_BC_DSTBANK
            lda   #<PAR_PROC_LEN
            sta   K_BC_LEN
            lda   #>PAR_PROC_LEN
            sta   K_BC_LEN+1
            jsr   BankCopy
            rts

NOIRQ       rts

MAIN_ENTRY  ldy   #0
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
            jsr   STAMP_MAIN
            jsr   SCH_INIT
            lda   #1                       ;gates pin 40 cols:
            sta   TTY_BKND_REQ             ;auto = best 80 now
            jsr   PRC_INIT

            lda   #1
            jsr   PRC_STMP_BANK
            lda   #1
            jsr   PRC_SYNTH_FRM
            jsr   BOOT_CPY_PAR

            lda   #1
            ldx   #1
            jsr   SCH_CREATE
            jsr   SCH_START

BANNER      asc   "MAUX PROCESS"
BANNER_END

*---------------------------------------------------------------
* Process images. They are copied verbatim to $0800, so all data
* references are fixed process-local addresses, not labels
* inside these source blobs.
*---------------------------------------------------------------

PARENT_PROC
            stz   R_ERR

*-- brk gate. Straight-line, no internal JSRs: this blob is
*-- assembled here and COPIED to $0800, so a label inside it is
*-- not the address it runs at. Only relative branches and the
*-- fixed process-local addresses above are legal.

            ;-- 1. GROW before any SET -- the kernel must refuse
            ;-- to invent a heap base it cannot know.
            stz   P_BRKP
            stz   P_BRKP+1
            lda   #1
            sta   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            sta   R_BRK_E1

            ;-- 2. SET $4000 -- establishes the break.
            stz   P_BRKP
            lda   #$40
            sta   P_BRKP+1
            stz   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            lda   P_BRKP
            sta   R_BRK_O1
            lda   P_BRKP+1
            sta   R_BRK_O1+1

            ;-- 3. GROW $1800 -- returns the base of the block.
            stz   P_BRKP
            lda   #$10
            sta   P_BRKP+1
            lda   #1
            sta   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            lda   P_BRKP
            sta   R_BRK_O2
            lda   P_BRKP+1
            sta   R_BRK_O2+1

            ;-- 4. GROW 1 BYTE -- must cost a whole page.
            lda   #1
            sta   P_BRKP
            stz   P_BRKP+1
            lda   #1
            sta   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            lda   P_BRKP
            sta   R_BRK_O3
            lda   P_BRKP+1
            sta   R_BRK_O3+1

            ;-- 5. GROW 0 -- pure query, proves step 4 rounded.
            stz   P_BRKP
            stz   P_BRKP+1
            lda   #1
            sta   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            lda   P_BRKP
            sta   R_BRK_O4
            lda   P_BRKP+1
            sta   R_BRK_O4+1

            ;-- 6. SET $BF01 -- ONE byte into the overlay page.
            lda   #1
            sta   P_BRKP
            lda   #$BF
            sta   P_BRKP+1
            stz   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            sta   R_BRK_E2

            ;-- 7. SET $0700 -- below LOAD_BASE.
            stz   P_BRKP
            lda   #7
            sta   P_BRKP+1
            stz   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            sta   R_BRK_E3

            ;-- 8. GROW 0 -- neither refusal moved the break.
            stz   P_BRKP
            stz   P_BRKP+1
            lda   #1
            sta   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            lda   P_BRKP
            sta   R_BRK_O5
            lda   P_BRKP+1
            sta   R_BRK_O5+1

            ;-- 9. SET the ceiling itself -- must SUCCEED.
            stz   P_BRKP
            lda   #>PRC_BRK_LIM
            sta   P_BRKP+1
            stz   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            lda   P_BRKP
            sta   R_BRK_O6
            lda   P_BRKP+1
            sta   R_BRK_O6+1

            ;-- 10. GROW one byte AT the ceiling -- ERR_NOMEM.
            lda   #1
            sta   P_BRKP
            stz   P_BRKP+1
            lda   #1
            sta   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            sta   R_BRK_E4

            ;-- 11. SET $07FF -- rounds UP onto the floor.
            lda   #$FF
            sta   P_BRKP
            lda   #7
            sta   P_BRKP+1
            stz   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            lda   P_BRKP
            sta   R_BRK_O7
            lda   P_BRKP+1
            sta   R_BRK_O7+1

            ;-- 12. Spawn the 'B' child, which runs its OWN brk
            ;-- sequence in its OWN bank, and reap it.
            lda   #'B'+$80
            sta   P_BRKPATH
            stz   P_BRKPATH+1
            lda   #<P_BRKPATH
            sta   P_BRKARGV
            lda   #>P_BRKPATH
            sta   P_BRKARGV+1
            stz   P_BRKARGV+2
            stz   P_BRKARGV+3
            lda   #<P_BRKPATH
            sta   P_BRKSPWN
            lda   #>P_BRKPATH
            sta   P_BRKSPWN+1
            lda   #<P_BRKARGV
            sta   P_BRKSPWN+2
            lda   #>P_BRKARGV
            sta   P_BRKSPWN+3
            stz   P_BRKSPWN+4
            stz   P_BRKSPWN+5
            stz   P_BRKSPWN+6           ;NULL envp
            stz   P_BRKSPWN+7
            lda   #<P_BRKSPWN
            ldx   #>P_BRKSPWN
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :brk_spw_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:brk_spw_ok
            lda   #<R_BRK_CST
            sta   P_BRKWAIT
            lda   #>R_BRK_CST
            sta   P_BRKWAIT+1
            lda   #<P_BRKWAIT
            ldx   #>P_BRKWAIT
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :brk_wt_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:brk_wt_ok

            ;-- 13. The parent's own break survived the child's.
            stz   P_BRKP
            stz   P_BRKP+1
            lda   #1
            sta   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            lda   P_BRKP
            sta   R_BRK_O8
            lda   P_BRKP+1
            sta   R_BRK_O8+1

            lda   #'E'+$80
            sta   P_PATH
            stz   P_PATH+1
            lda   #<P_PATH
            sta   P_ARGV
            lda   #>P_PATH
            sta   P_ARGV+1
            stz   P_ARGV+2
            stz   P_ARGV+3
            lda   #<P_PATH
            sta   P_SPAWN
            lda   #>P_PATH
            sta   P_SPAWN+1
            lda   #<P_ARGV
            sta   P_SPAWN+2
            lda   #>P_ARGV
            sta   P_SPAWN+3
            stz   P_SPAWN+4
            stz   P_SPAWN+5
            stz   P_SPAWN+6           ;NULL envp
            stz   P_SPAWN+7
            lda   #<P_SPAWN
            ldx   #>P_SPAWN
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :spawn_e_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:spawn_e_ok sta   R_EXT_SPW_PID

            lda   #<R_EXIT_STATUS
            sta   P_WAIT
            lda   #>R_EXIT_STATUS
            sta   P_WAIT+1
            lda   #<P_WAIT
            ldx   #>P_WAIT
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :wait_e_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:wait_e_ok  sta   R_EXT_WT_PID

            lda   #<R_PIPE_RFD
            sta   P_PIPEPARM
            lda   #>R_PIPE_RFD
            sta   P_PIPEPARM+1
            lda   #<P_PIPEPARM
            ldx   #>P_PIPEPARM
            ldy   #SYS_PIPE
            jsr   $FF00
            bcc   :pipe_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:pipe_ok

*-- SEGMENT CUT POINT for the REL form (S9-PLAN 6b): this blob
*-- is one global-label-free zone larger than as's source
*-- window, so the generator needs a zone boundary here. No
*-- :local straddles this line (verified by the safe-cut scan)
*-- and nothing references the label -- it emits no bytes.
PTB_SEG2
            lda   #FDACT_DUP
            sta   P_RFDA
            stz   P_RFDA+1
            lda   R_PIPE_RFD
            sta   P_RFDA+2
            lda   #FDACT_CLOSE
            sta   P_RFDA+3
            lda   R_PIPE_WFD
            sta   P_RFDA+4
            stz   P_RFDA+5
            stz   P_RFDA+6

            lda   #'R'+$80
            sta   P_PATH
            stz   P_PATH+1
            lda   #<P_PATH
            sta   P_ARGV
            lda   #>P_PATH
            sta   P_ARGV+1
            stz   P_ARGV+2
            stz   P_ARGV+3
            lda   #<P_RFDA
            sta   P_SPAWN+4
            lda   #>P_RFDA
            sta   P_SPAWN+5
            stz   P_SPAWN+6           ;NULL envp
            stz   P_SPAWN+7
            lda   #<P_SPAWN
            ldx   #>P_SPAWN
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :spawn_r_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:spawn_r_ok sta   R_READER_PID

            lda   #FDACT_DUP
            sta   P_WFDA
            lda   #1
            sta   P_WFDA+1
            lda   R_PIPE_WFD
            sta   P_WFDA+2
            lda   #FDACT_CLOSE
            sta   P_WFDA+3
            lda   R_PIPE_RFD
            sta   P_WFDA+4
            stz   P_WFDA+5
            stz   P_WFDA+6

            lda   #'W'+$80
            sta   P_PATH
            stz   P_PATH+1
            lda   #<P_WFDA
            sta   P_SPAWN+4
            lda   #>P_WFDA
            sta   P_SPAWN+5
            stz   P_SPAWN+6           ;NULL envp
            stz   P_SPAWN+7
            lda   #<P_SPAWN
            ldx   #>P_SPAWN
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :spawn_w_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:spawn_w_ok sta   R_WRITER_PID

            lda   #1
            sta   P_CLOSE
            lda   R_PIPE_RFD
            sta   P_CLOSE+1
            lda   #<P_CLOSE
            ldx   #>P_CLOSE
            ldy   #SYS_CLOSE
            jsr   $FF00
            bcc   :close_r_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:close_r_ok lda   R_PIPE_WFD
            sta   P_CLOSE+1
            lda   #<P_CLOSE
            ldx   #>P_CLOSE
            ldy   #SYS_CLOSE
            jsr   $FF00
            bcc   :close_w_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *

:close_w_ok lda   #<R_WAIT1_STAT
            sta   P_WAIT
            lda   #>R_WAIT1_STAT
            sta   P_WAIT+1
            lda   #<P_WAIT
            ldx   #>P_WAIT
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :wait1_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:wait1_ok   sta   R_WAIT1_PID

            lda   #<R_WAIT2_STAT
            sta   P_WAIT
            lda   #>R_WAIT2_STAT
            sta   P_WAIT+1
            lda   #<P_WAIT
            ldx   #>P_WAIT
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :wait2_ok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:wait2_ok   sta   R_WAIT2_PID

*---------------------------------------------------------------
* SYS_DUP2 (call 9). Six checks, all through the syscall
* interface -- this harness runs as a PROCESS, so it cannot peek
* OFT_REFCNT directly and the refcount property has to be proved
* by BEHAVIOUR instead. :d2wr below is how: the original write
* fd is CLOSED before anything is written through the alias, so
* a dup2 that failed to take a reference would have freed the
* object and the write would fail. That is the check that
* matters; the rest are contract.
*---------------------------------------------------------------
            lda   #<R_D2_RFD
            sta   P_D2PIPE
            lda   #>R_D2_RFD
            sta   P_D2PIPE+1
            lda   #<P_D2PIPE
            ldx   #>P_D2PIPE
            ldy   #SYS_PIPE
            jsr   $FF00
            bcc   :d2pipeok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *

*-- dup2(wfd, 5): returns the NEW fd, not the old one.
:d2pipeok   lda   R_D2_WFD
            sta   P_D2P
            lda   #5
            sta   P_D2P+1
            lda   #<P_D2P
            ldx   #>P_D2P
            ldy   #SYS_DUP2
            jsr   $FF00
            bcc   :d2aok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:d2aok      sta   R_D2_RET5

*-- dup2(rfd, rfd) on an OPEN fd: returns it, does NOT close it.
*-- The read at :d2rdok below proves the "does not close"
*-- half: had this closed without reopening, that read fails.
            lda   R_D2_RFD
            sta   P_D2P
            sta   P_D2P+1
            lda   #<P_D2P
            ldx   #>P_D2P
            ldy   #SYS_DUP2
            jsr   $FF00
            bcc   :d2bok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:d2bok      sta   R_D2_SAME

*-- REFUSALS. Both must fail; the errno is recorded, not the
*-- carry, so a handler that "fails" by falling through to a
*-- success return cannot pass.
            lda   R_D2_RFD              ;newfd 9 is out of range
            sta   P_D2P                 ;  (PCB_FDTABLE is 8)
            lda   #9
            sta   P_D2P+1
            lda   #<P_D2P
            ldx   #>P_D2P
            ldy   #SYS_DUP2
            jsr   $FF00
            bcs   :d2rngok
            lda   #$EE                  ;it SUCCEEDED -- wrong
            sta   R_DONE
            bra   *
:d2rngok    sta   R_D2_ERANGE

            lda   #7                    ;fd 7 was never opened
            sta   P_D2P
            lda   #5
            sta   P_D2P+1
            lda   #<P_D2P
            ldx   #>P_D2P
            ldy   #SYS_DUP2
            jsr   $FF00
            bcs   :d2clsok
            lda   #$EE
            sta   R_DONE
            bra   *
:d2clsok    sta   R_D2_ECLOSED

*-- THE REFERENCE CHECK. Close the ORIGINAL write fd, then write
*-- through fd 5. One byte into an empty 256-byte pipe cannot
*-- block, and the matching read cannot block either.
            lda   #1
            sta   P_D2CL
            lda   R_D2_WFD
            sta   P_D2CL+1
            lda   #<P_D2CL
            ldx   #>P_D2CL
            ldy   #SYS_CLOSE
            jsr   $FF00
            bcc   :d2clok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:d2clok     lda   #$5A
            sta   P_D2BUF
            lda   #4
            sta   P_D2IO
            lda   #5                    ;write through the ALIAS
            sta   P_D2IO+1
            lda   #<P_D2BUF
            sta   P_D2IO+2
            lda   #>P_D2BUF
            sta   P_D2IO+3
            lda   #1
            sta   P_D2IO+4
            stz   P_D2IO+5
            stz   P_D2IO+6
            stz   P_D2IO+7
            lda   #<P_D2IO
            ldx   #>P_D2IO
            ldy   #SYS_WRITE
            jsr   $FF00
            bcc   :d2wrok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:d2wrok     stz   P_D2BUF          ;clear, so a read that
                                   ;  writes nothing cannot pass
                                   ;  on leftovers
            lda   #4
            sta   P_D2IO
            lda   R_D2_RFD
            sta   P_D2IO+1
            lda   #1
            sta   P_D2IO+4
            stz   P_D2IO+5
            stz   P_D2IO+6
            stz   P_D2IO+7
            lda   #<P_D2IO
            ldx   #>P_D2IO
            ldy   #SYS_READ
            jsr   $FF00
            bcc   :d2rdok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:d2rdok     lda   P_D2BUF
            sta   R_D2_BYTE
