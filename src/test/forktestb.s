*---------------------------------------------------------------
* forktestb.s -- image body for forktest.s (docs/FORK.md).
*
* WHAT THIS GATE HAS TO SHOW, and why each piece is here:
* ONE CALL RETURNS TWICE. A single `jsr $FF00` with Y=SYS_FORK,
* after which two processes continue from the same instruction
* with the same registers except A and the carry. Everything
* below hangs off that one call site -- there is deliberately no
* second entry point for the child, because a fork that needed
* one would not be a fork.
*
* THE CHILD'S MEMORY IS A TRUE COPY THAT THEN DIVERGES. The
* parent fills $0C00-$40FF with a position-dependent pattern
* and plants five signatures (zero page, the stack page, the
* image region, and two inside the 80STORE/HIRES window) BEFORE
* forking. The child reads all five back and the gate compares
* the two banks in bulk. Then each side writes cells the other
* must never see.
*
* THE 80STORE PHASE IS NOT DECORATION. The fork runs with
* 80STORE and HIRES both SET, which is the one state in which
* RAMRD/RAMWRT are ignored for $2000-$3FFF
* (learning:01KW1GTYHGXMBZNR6DMQB2F712). Without BankCopy's
* CLR80STORE bracket the copy of that window degenerates into a
* main->main copy onto itself -- silent, no crash -- and the
* child's $2000-$3FFF never arrives. $2ABC, $3F00 and the bulk
* compare are what see it. With the switches OFF this gate
* would pass with the bracket deleted, which is the whole
* reason they are on.
*
* FDS ARE SHARED, THE TABLE IS PRIVATE. A pipe is created
* before the fork. The child writes a byte through the
* inherited write end and the parent, blocked on the inherited
* read end, receives it -- one OBJECT, two tables. The child
* then CLOSES its read end; the parent's read still completes,
* which is the private half.
*
* THE BLOB IS COPIED TO $0800, so a label inside it is not the
* address it runs at (processtestb.s's own rule). Only relative
* branches and the fixed process-local addresses below are
* legal -- with ONE exception, the single long jump at the
* parent/child split, which spells the runtime address out as
* `LABEL+LOAD_BASE-PARENT_PROC`. Real Merlin-8 has no operator
* precedence and evaluates strictly left to right
* (learning:01M051DJW89KV4JYM1EC9SDZ5Y), so that expression is
* (LABEL+$0800)-PARENT_PROC under both assemblers -- which is
* the value wanted. Every other control transfer in the blob is
* a short branch.
*---------------------------------------------------------------


* -- Results in the PARENT's bank (aux bank 1). --
R_FORK_A    equ $1100        ;parent's fork() return = child pid
R_FORK_C    equ $1101        ;parent's carry, 0 = clear
R_PIPE_B    equ $1102        ;byte read back through the pipe
R_PIPE_N    equ $1103        ;that read's trans_count
R_CHLD_ST   equ $1104        ;child's exit status
R_WAIT_PID  equ $1105        ;pid wait() reaped
R_IMG_KEEP  equ $1106        ;parent's own S_IMG afterwards
R_ZP_KEEP   equ $1107        ;parent's own S_ZP2 afterwards
R_FORK_N    equ $1108        ;forks that SUCCEEDED before the
                              ;bank free list ran dry
R_EAGAIN    equ $1109        ;the errno the one after it gave
R_DONE      equ $11F0
R_ERR       equ $11F1

* -- Results in the CHILD's bank. Same addresses, different
* -- bank: that IS the isolation this gate measures. The child
* -- snapshots every inherited cell here BEFORE it diverges, so
* -- the gate can name the exact byte that failed instead of
* -- reporting "fork broken".
C_ZP        equ $1200        ;S_ZP  as the child inherited it
C_STK       equ $1201        ;S_STK   "
C_IMG       equ $1202        ;S_IMG   "
C_HIRES     equ $1203        ;S_HIRES "  ($2ABC, 80STORE window)
C_HIEND     equ $1204        ;S_HIEND "  ($3F00, same window)
C_POST      equ $1205        ;S_POST -- parent's POST-fork write
C_ZPPOST    equ $1206        ;S_ZP2   -- ditto, in zero page
C_A         equ $1207        ;child's fork() return value
C_CARRY     equ $1208        ;child's carry
C_MARK      equ $1209        ;$5C once the child has run at all
C_LOW       equ $120A        ;S_LOW ($0210, argv/env block)
C_TXT       equ $120B        ;S_TXT ($0567, 80STORE-only window)

* -- Process scratch, below the fill region and above the blob.
P_FRET      equ $1010
P_FCARRY    equ $1011
P_PIPEP     equ $1020        ;pipe() parmlist: one pointer
P_RFD       equ $1024        ;pipe() writes the two fds here
P_WFD       equ $1025
P_RW        equ $1028        ;read/write parmlist, 8 bytes
P_BUF       equ $1034
P_WAITP     equ $1038
P_BRKP      equ $103C
P_CLOSEP    equ $1040
P_EXITP     equ $1044

* -- The inherited signatures, one per region fork copies.
S_ZP        equ $80          ;process zero page
S_ZP2       equ $81          ;ditto -- parent writes it AFTER
S_STK       equ $0110        ;the stack page, well below SP
S_LOW       equ $0210        ;argv/env block (widened extent)
S_TXT       equ $0567        ;inside $0400-$07FF -- the window
                              ;80STORE governs ALONE, no HIRES;
                              ;sees the bracket for the widened
                              ;copy's newest exposure
S_IMG       equ $1500        ;plain image/heap region
S_HIRES     equ $2ABC        ;inside $2000-$3FFF
S_HIEND     equ $3F00        ;ditto, near the top of the window
S_POST      equ $1600        ;parent writes it AFTER the fork

* -- The bulk pattern is laid in TWO runs, $0C00-$0FFF and
* -- $1700-$40FF, with the scratch/result window $1000-$16FF
* -- deliberately left alone. Filling straight through it cost
* -- one debugging round: the pattern landed on R_DONE/R_ERR
* -- ($11F0/$11F1), the gate's poll loop read $E1/$E0 out of
* -- them and reported a brk failure the parent had never had.
* -- A harness cell inside a region the harness itself paints is
* -- a gate that lies.
FILL0_LO    equ $02          ;the widened low window,
FILL0_HI    equ $08          ;$0200-$07FF -- stops at the blob
FILL1_LO    equ $0C
FILL1_HI    equ $10
FILL2_LO    equ $17
FILL2_HI    equ $41
FILL_PTR    equ $F0          ;process ZP, the blob's own

*---------------------------------------------------------------
* Boot helpers -- identical to processtestb.s's.
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

BANNER      asc   "MAUX FORK"
BANNER_END

*---------------------------------------------------------------
* PARENT_PROC -- the process under test, copied verbatim to
* $0800 in aux bank 1.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_DONE

*-- 1. Fill $0C00-$40FF with a position-dependent pattern, so
*-- the gate's bulk parent-vs-child compare cannot pass on two
*-- pages of identical zeros. The value is (low byte XOR page),
*-- which differs from its neighbours in both directions -- a
*-- copy off by any amount shows up, not just a copy that never
*-- ran.
            stz   FILL_PTR
            lda   #FILL0_LO
            sta   FILL_PTR+1
            ldx   #FILL0_HI
:fill0      ldy   #0
:fill0b     tya
            eor   FILL_PTR+1
            sta   (FILL_PTR),y
            iny
            bne   :fill0b
            inc   FILL_PTR+1
            cpx   FILL_PTR+1
            bne   :fill0
            lda   #FILL1_LO
            sta   FILL_PTR+1
            ldx   #FILL1_HI
:fill1      ldy   #0
:fill1b     tya
            eor   FILL_PTR+1
            sta   (FILL_PTR),y
            iny
            bne   :fill1b
            inc   FILL_PTR+1
            cpx   FILL_PTR+1
            bne   :fill1
            lda   #FILL2_LO
            sta   FILL_PTR+1
            ldx   #FILL2_HI
:fill2      ldy   #0
:fill2b     tya
            eor   FILL_PTR+1
            sta   (FILL_PTR),y
            iny
            bne   :fill2b
            inc   FILL_PTR+1
            cpx   FILL_PTR+1
            bne   :fill2

*-- 1b. The same treatment for the parts of zero page and of the
*-- stack page the blob does not otherwise use. Without this the
*-- gate's bulk compare of those two pages would be a comparison
*-- of zeros against zeros, which passes whether or not
*-- FRK_CLN_ZP/FRK_CLN_STK ever ran -- and those two routines
*-- are the hand-rolled ALTZP window, the highest-risk code in
*-- src/kernel/procfork.s. absolute,Y again: PRC_ZP is $0000 and
*-- neither LDA nor STA has a zp,Y mode.
            ldy   #$90
:zpfill     tya
            eor   #$3C
            sta   PRC_ZP,y
            iny
            cpy   #$F0
            bne   :zpfill
            ldy   #$20
:stkfill    tya
            eor   #$C5
            sta   PRC_STACK,y
            iny
            cpy   #$80
            bne   :stkfill

*-- 2. The signatures, written with 80STORE OFF so the two in
*-- $2000-$3FFF really do land in this process's own bank.
            lda   #$5A
            sta   S_ZP
            stz   S_ZP2
            lda   #$6B
            sta   S_STK
            lda   #$4E
            sta   S_LOW
            lda   #$B7
            sta   S_TXT
            lda   #$A5
            sta   S_IMG
            lda   #$C3
            sta   S_HIRES
            lda   #$D4
            sta   S_HIEND
            stz   S_POST

*-- 3. brk = $4100. That is the extent fork copies -- 14592
*-- bytes, above every signature above, and deliberately close
*-- to sh's own image size so the measured cost means something.
            stz   P_BRKP
            lda   #$41
            sta   P_BRKP+1
            stz   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            bcc   :brkok
            sta   R_ERR
            lda   #$E1
            sta   R_DONE
            bra   *

*-- 4. A pipe, BEFORE the fork, so both sides end up holding
*-- the same two objects through their own private tables.
:brkok      lda   #<P_RFD
            sta   P_PIPEP
            lda   #>P_RFD
            sta   P_PIPEP+1
            lda   #<P_PIPEP
            ldx   #>P_PIPEP
            ldy   #SYS_PIPE
            jsr   $FF00
            bcc   :pipeok
            sta   R_ERR
            lda   #$E2
            sta   R_DONE
            bra   *

*-- 5. THE FORK, under 80STORE + HIRES. See this file's header:
*-- these two switches are the only state in which fork's copied
*-- range is exposed to the routing trap, and the kernel is
*-- masked for the whole of the call between them.
:pipeok     sta   SET80STORE
            sta   HIRESON
*-- fork() TAKES NO PARAMETERS, so this pointer is ignored --
*-- and it is deliberately NOT zero. The child's frame-A must be
*-- WRITTEN with 0 by the kernel, not merely inherited as one:
*-- with A=0 here, deleting FRK_PTCH_FRM's `sta FRAME_A,x`
*-- changed 774 binary bytes and left this gate GREEN. Measured
*-- 2026-08-23; the sabotage was reported as the no-op it was
*-- and the harness fixed rather than the green banked.
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_FORK
            jsr   $FF00

*-- BOTH PROCESSES ARE HERE. Capture A and the carry before
*-- anything else can disturb either: A is the return value, the
*-- carry is the error flag, and `adc #0` with A=0 turns the
*-- carry into a byte (D is 0 -- item 11 starts every process
*-- with P=$20).
            tax
            lda   #0
            adc   #0
            sta   P_FCARRY
            stx   P_FRET
            sta   CLR80STORE
            sta   HIRESOFF
            lda   P_FRET
            bne   :parent
            jmp   CHILD_SIDE+LOAD_BASE-PARENT_PROC

*---------------------------------------------------------------
* The PARENT's side.
*---------------------------------------------------------------
:parent     lda   P_FRET
            sta   R_FORK_A
            lda   P_FCARRY
            sta   R_FORK_C

*-- Post-fork, parent only. The child's copy of both cells was
*-- taken before either store, so the child must still read 0 --
*-- and it snapshots exactly that into C_POST/C_ZPPOST.
            lda   #$22
            sta   S_POST
            lda   #$99
            sta   S_ZP2

*-- Read one byte from the inherited read end. Nothing is in the
*-- pipe yet, so this BLOCKS -- which is what lets the child run
*-- at all: this image installs no timer, so a context switch
*-- happens only when somebody blocks.
            lda   #4
            sta   P_RW
            lda   P_RFD
            sta   P_RW+1
            lda   #<P_BUF
            sta   P_RW+2
            lda   #>P_BUF
            sta   P_RW+3
            lda   #1
            sta   P_RW+4
            stz   P_RW+5
            stz   P_RW+6
            stz   P_RW+7
            lda   #<P_RW
            ldx   #>P_RW
            ldy   #SYS_READ
            jsr   $FF00
            bcc   :readok
            sta   R_ERR
            lda   #$E3
            sta   R_DONE
            bra   *
:readok     lda   P_BUF
            sta   R_PIPE_B
            lda   P_RW+6
            sta   R_PIPE_N

*-- The child overwrote ITS S_IMG with $11 and ITS S_ZP2 stays
*-- 0. Neither may have reached here.
            lda   S_IMG
            sta   R_IMG_KEEP
            lda   S_ZP2
            sta   R_ZP_KEEP

*-- BANK EXHAUSTION, and it runs BEFORE the wait() below on
*-- purpose: an unreaped zombie keeps its bank, so the child's
*-- C_* block stays readable in bank 2 while this loop takes
*-- every other bank in the pool. Reap first and the free list
*-- hands bank 2 straight back out (it is LIFO), a later fork
*-- overwrites the very results the gate is about to read, and
*-- the gate reports on the wrong process.
*--
*-- The break drops to $0A00 first, so each of these forks
*-- copies 512 bytes rather than 14592. What is under test here
*-- is the ALLOCATOR's verdict when the free list runs dry, not
*-- thirteen more copies -- and a lowered break is legal (brk
*-- SET is absolute, and moving it down is what a program that
*-- has released its heap would do).
            stz   P_BRKP
            lda   #$0A
            sta   P_BRKP+1
            stz   P_BRKP+2
            lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_BRK
            jsr   $FF00
            bcc   :exready
            sta   R_ERR
            lda   #$E5
            sta   R_DONE
            bra   *
:exready    stz   R_FORK_N

*-- Each child here parks on its own `beq *`. It never actually
*-- runs (nothing below blocks, and this image has no timer, so
*-- no switch is ever taken) -- but if that ever changes, a
*-- parked child still holds its bank, which is the condition
*-- this loop needs. Silence is not relied on.
:exloop     lda   #<P_BRKP
            ldx   #>P_BRKP
            ldy   #SYS_FORK
            jsr   $FF00
            bcs   :exdone
            cmp   #0
            beq   *
            inc   R_FORK_N
            bra   :exloop
:exdone     sta   R_EAGAIN

            lda   #<R_CHLD_ST
            sta   P_WAITP
            lda   #>R_CHLD_ST
            sta   P_WAITP+1
            lda   #<P_WAITP
            ldx   #>P_WAITP
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :waitok
            sta   R_ERR
            lda   #$E4
            sta   R_DONE
            bra   *
:waitok     sta   R_WAIT_PID
            lda   #$AA
            sta   R_DONE
:halt       bra   :halt

*---------------------------------------------------------------
* The CHILD's side. Snapshot everything inherited BEFORE
* touching any of it, then diverge, then talk to the parent.
*
* The exit status is a SUMMARY ($C7 = the child's own syscalls
* all worked); the per-cell verdicts are the C_* block above,
* which the gate peeks out of the child's bank directly. That
* split is deliberate -- a single status byte cannot say which
* of nine inherited values was wrong, and this gate has to.
*---------------------------------------------------------------
CHILD_SIDE  lda   S_ZP
            sta   C_ZP
            lda   S_STK
            sta   C_STK
            lda   S_LOW
            sta   C_LOW
            lda   S_TXT
            sta   C_TXT
            lda   S_IMG
            sta   C_IMG
            lda   S_HIRES
            sta   C_HIRES
            lda   S_HIEND
            sta   C_HIEND
            lda   S_POST
            sta   C_POST
            lda   S_ZP2
            sta   C_ZPPOST
            lda   P_FRET
            sta   C_A
            lda   P_FCARRY
            sta   C_CARRY
            lda   #$5C
            sta   C_MARK

*-- Diverge: this store lands in the CHILD's bank only, and the
*-- parent re-reads its own copy afterwards.
            lda   #$11
            sta   S_IMG

*-- Optimistic status, overwritten by any failure below. Every
*-- branch here is a short forward one -- no long jumps in the
*-- blob apart from the split.
            lda   #$C7
            sta   P_EXITP

*-- Write one byte through the INHERITED write end. The parent
*-- is blocked on the other end of the same object.
            lda   #$77
            sta   P_BUF
            lda   #4
            sta   P_RW
            lda   P_WFD
            sta   P_RW+1
            lda   #<P_BUF
            sta   P_RW+2
            lda   #>P_BUF
            sta   P_RW+3
            lda   #1
            sta   P_RW+4
            stz   P_RW+5
            stz   P_RW+6
            stz   P_RW+7
            lda   #<P_RW
            ldx   #>P_RW
            ldy   #SYS_WRITE
            jsr   $FF00
            bcc   :wrok
            lda   #$C1
            sta   P_EXITP
:wrok       lda   P_RW+6
            cmp   #1
            beq   :wrcnt
            lda   #$C2
            sta   P_EXITP

*-- Close the read end IN THE CHILD ONLY. The parent's blocking
*-- read completing is what proves the table was private.
:wrcnt      lda   #1
            sta   P_CLOSEP
            lda   P_RFD
            sta   P_CLOSEP+1
            lda   #<P_CLOSEP
            ldx   #>P_CLOSEP
            ldy   #SYS_CLOSE
            jsr   $FF00
            bcc   :clok
            lda   #$C3
            sta   P_EXITP

:clok       lda   #<P_EXITP
            ldx   #>P_EXITP
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
PAR_PROC_END
PAR_PROC_LEN equ PAR_PROC_END-PARENT_PROC

* -- BUILD-TIME ASSERTION, not padding anybody reads: the blob
* -- must fit below $0C00 in the process bank, because the fill
* -- loop above starts there and would otherwise overwrite the
* -- code that is running it. merlin32 ERRORS on a negative `ds`
* -- (real Merlin-8 silently emits nothing --
* -- learning:01M0EDXWRX43PTQNR2WC0JT07F -- which is why the
* -- merlin32 assembly is the one that must run first).
            ds    1024-PAR_PROC_LEN

* -- the pad places nothing in particular at a block boundary;
* -- NBLOCKS in forktest.s must equal ($6400-$0800)/512 = 46
* -- (40 -> 41 on 2026-09-01: SYS_KILL grew the embedded
* -- kernel past the old fence; 43 -> 44 on 2026-09-03,
* -- VIDMODE V2.0's card store, 238 B over; processtest's
* -- own 24->48 history is the precedent).
            ds    $8200-*   ;60 -> 61 (2026-11-01: SGR 1
                                     ;gated on what the
                                     ;emphasis bit MEANS,
                                     ;+12 B kernel, 10 over --
                                     ;this harness had 2 B of
                                     ;headroom);
                                     ;58 -> 60 (2026-09-25:
                                     ;found ALREADY 593 B at
                                     ;2a3a649, before this
                                     ;session's bye-slice-1
                                     ;fixes touched it -- not
                                     ;newly caused, just newly
                                     ;exercised; this session's
                                     ;own growth added ~66 B
                                     ;more, to 659 over -- two
                                     ;blocks clears both);
                                     ;57 -> 58 (2026-09-21:
                                     ;SYS_HALT/`shutdown`,
                                     ;50B over $7A00);
                                     ;56->57 2026-09-13 merge;
                                     ;VT102 line with UltraTerm
                                     ;bold + SGR 1/22: 49B over
                                     ;$7800); 55 -> 56 (VT102
                                     ;sl 6: review
                                     ;VT1-VT9, 101B over
                                     ;$7600); 54 -> 55 (VT102
                                     ;sl 2/3: DCH/IRM + xenl,
                                     ;245B over $7400);
                                     ;53 -> 54 (VT102
                                     ;sl 1: tty9.s,
                                     ;234B over $7200); 52->53
                                     ;(ser.s ttya0; 52 IL/DL
                                     ;partial scroll -- 258 B
                                     ;over $6C00);
                                     ;49->50 (2026-09-08 jobctl
                                     ;B: PCB_STOPPED, the ^Z
                                     ;sweep, SYS_CONT/WAITJOB,
                                     ;the orphan reap -- 116 B
                                     ;over $6A00);
                                     ;48 -> 49 (2026-09-08, job-
                                     ;control A: TCSETFG + the
                                     ;foreground ^C sweep,
                                     ;procspawn2.s -- 183 B over
                                     ;$6800);
                                     ;47 -> 48 (2026-09-08, alt
                                     ;screen -- tty2.s/tty5.s,
                                     ;340 B over $6600);
                                     ;46 -> 47 (2026-09-07,
                                     ;io_buffer
                                     ;LENDING + LRU/park tables,
                                     ;137 B over $6400);
                                     ;45 -> 46 (run-batch,
                                     ;2026-09-04, 6 B over);
                                     ;44 -> 45 (surfaces)
