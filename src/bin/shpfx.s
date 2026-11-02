*---------------------------------------------------------------
* shpfx.s -- prefix assignments, `NAME=value cmd args`
* (docs/SH-PREFIX.md; POSIX 2.9.1, V7 sh(1) "augmented by
* prefixing it with one or more assignments"). `put` by
* src/bin/sh.s, low image.
*
* THE SHAPE.  PFX_PEEL runs once per segment, after the skip
* gates and set -x, on the words PARSE built.  For every stage
* it counts the leading assignment-shaped words (a letter, then
* an `=` somewhere, CHCK_BLTN_VAR's old loose rule and the same
* one SPLIT_APPEND and TC_ASGN use), splits each at its `=` in
* place, parks the NAME pointers in PFX_PTR and slides the rest
* of the stage's argv down over them, so everything downstream
* sees the command word at argv[0] as before.
*
*   no command word, one stage   NAME=v persists (a shell
*                                assignment); the old
*                                CHCK_BLTN_VAR case, widened
*   special builtin              persists, not exported
*   anything else                set EXPORTED for the command
*                                and put back afterwards
*
* "Set and put back" is a temporary var-table entry, saved in
* PFX_SSLOT/PFX_SKIND/PFX_SVAL and undone by PFX_RESTORE.  One
* stage: applied by PEEL, undone at :segdone (shlex.s), so a
* builtin sees it too (`IFS=: read a b`) and ^C or a failed
* spawn cannot leave it behind.  A pipeline: each stage is
* applied just before its ENV_STAGE and undone right after its
* SC_SPAWN returns (shblt2.s), because the kernel copies envp at
* the spawn.
* CLOBBERS: A, X, Y, PTR0-PTR2 throughout.
*---------------------------------------------------------------

*---------------------------------------------------------------
* PFX_ISASG -- IN: PTR0 = a NUL-terminated word. OUT: carry SET
* iff it starts with a letter and has an `=`. CLOBBERS: A, Y.
*---------------------------------------------------------------
PFX_ISASG   ldy   #0
            lda   (PTR0),y
            jsr   ISNAME1
            bcc   :no
:scan       iny
            lda   (PTR0),y
            beq   :no
            cmp   #$BD                   ;'=' high-bit-set
            bne   :scan
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* PFX_ALLASG -- are all CURARGC words already built for the
* stage under construction assignment-shaped?  SPLIT_APPEND asks
* so it can leave `B=$X` of `A=1 B=$X cmd` unsplit.  OUT: carry
* SET = yes (and for none at all).  PTR0 is preserved.
*---------------------------------------------------------------
PFX_ALLASG  lda   PTR0
            sta   PFX_SP
            lda   PTR0+1
            sta   PFX_SP+1
            ldx   NCMD
            lda   STGOFF,x
            sta   PFX_BASE
            stz   PFX_I
:lp         lda   PFX_I
            cmp   CURARGC
            bcs   :yes
            asl   a
            clc
            adc   PFX_BASE
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            jsr   PFX_ISASG
            bcc   :out
            inc   PFX_I
            bra   :lp
:yes        sec
:out        lda   PFX_SP
            sta   PTR0
            lda   PFX_SP+1
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* PFX_HASRD -- Z clear iff the single command has a redirection
* (`<`, `>`, `>>`, `N>`, `N>&M` ...).  CLOBBERS: A.
*---------------------------------------------------------------
PFX_HASRD   lda   CMD_INFILE+0
            ora   CMD_INFILE+1
            ora   CMD_OUTFILE+0
            ora   CMD_OUTFILE+1
            ora   DUPN
            rts

*---------------------------------------------------------------
* PFX_PEEL -- see the header.  OUT: carry SET = the segment is
* finished (assignments only, or an error already reported with
* LASTSTATUS set): skip the dispatch.  Carry CLEAR = go on, and
* for one stage with a command the prefixes are already in
* force.
*---------------------------------------------------------------
PFX_PEEL    stz   PFX_S
:stage      ldx   PFX_S
            cpx   NCMD
            bcc   :more
            jmp   :decide
:more
            stz   PFX_N,x
            lda   STGOFF,x
            sta   PFX_BASE
            stz   PFX_K
:cnt        lda   PFX_K
            ldx   PFX_S
            cmp   CMD_ARGC,x
            bcs   :counted
            asl   a
            clc
            adc   PFX_BASE
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            jsr   PFX_ISASG
            bcc   :counted
            inc   PFX_K
            bra   :cnt
:counted    lda   PFX_K
            beq   :next
            ldx   PFX_S
            cmp   CMD_ARGC,x
            bne   :peel
*-- nothing but assignments: a shell assignment when alone,
*-- left as it was in a pipeline
            lda   NCMD
            cmp   #1
            bne   :next
            jsr   PFX_REC
            bcs   :nofail1
            lda   #1
            sta   PFX_PERS
            stz   PFX_S
            jsr   PFX_APPLY
            bcc   :aok
:nofail1    jmp   :fail
:aok
*-- `A=1 > F` must still make F: run it as `:` (shbltn.s)
            jsr   PFX_HASRD
            beq   :plain
            jmp   :colon
:plain      stz   LASTSTATUS
            sec
            rts
:peel       jsr   PFX_REC
            bcs   :fail
*-- slide argv[K..argc] (the NUL pointer too) down over the
*-- prefix words
            ldx   PFX_S
            lda   CMD_ARGC,x
            sec
            sbc   PFX_K
            inc   a
            sta   PFX_I                  ;words to move
            lda   PFX_K
            asl   a
            clc
            adc   PFX_BASE
            tay                          ;Y = source offset
            ldx   PFX_BASE               ;X = destination
:mv         lda   CMD_ARGV,y
            sta   CMD_ARGV,x
            lda   CMD_ARGV+1,y
            sta   CMD_ARGV+1,x
            inx
            inx
            iny
            iny
            dec   PFX_I
            bne   :mv
            ldx   PFX_S
            lda   CMD_ARGC,x
            sec
            sbc   PFX_K
            sta   CMD_ARGC,x
:next       inc   PFX_S
            jmp   :stage
*-- one command: its prefixes take effect now (a pipeline's
*-- stages take theirs at their own spawn)
:decide     lda   NCMD
            cmp   #1
            bne   :ok
            lda   PFX_N+0
            beq   :ok
            jsr   PFX_ISSPEC
            lda   #0
            rol   a                      ;1 = special: persists
            sta   PFX_PERS
            stz   PFX_S
            jsr   PFX_APPLY
            bcs   :fail
:ok         clc
            rts
:fail       lda   #1
            sta   LASTSTATUS
            sec
            rts
:colon      lda   #<COLON_STR
            sta   CMD_ARGV+0
            lda   #>COLON_STR
            sta   CMD_ARGV+1
            lda   #1
            sta   CMD_ARGC+0
            clc
            rts

*-- PFX_REC, PFX_ISSPEC and PFX_SPECS MOVED to shsgcld.s (the
*-- $D000 segment, SH-ROOM2 step 2b). Their callers `jsr` them
*-- unchanged; the messages PFX_REC prints stay below $D000.
*---------------------------------------------------------------
* PFX_GETNAME -- PTR0 = the NAME of prefix PFX_I of stage PFX_S,
* PTR2 = its VALUE (the byte after the NUL PFX_REC laid).
*---------------------------------------------------------------
PFX_GETNAME lda   PFX_S
            asl   a
            asl   a
            asl   a
            clc
            adc   PFX_I
            asl   a
            tax
            lda   PFX_PTR,x
            sta   PTR0
            lda   PFX_PTR+1,x
            sta   PTR0+1
            ldy   #0
:l          iny
            lda   (PTR0),y
            bne   :l
            iny                          ;past the NUL
            tya
            clc
            adc   PTR0
            sta   PTR2
            lda   PTR0+1
            adc   #0
            sta   PTR2+1
            rts

*---------------------------------------------------------------
* PFX_APPLY -- put stage PFX_S's prefixes in force.  PFX_PERS
* 1 = a shell assignment (nothing saved, not exported); 0 =
* exported for the command, the old state saved for PFX_RESTORE.
* OUT: carry SET after reporting a refusal (table full or
* readonly), with everything already applied put back.
*---------------------------------------------------------------
PFX_APPLY   stz   PFX_I
:next       ldx   PFX_S
            lda   PFX_I
            cmp   PFX_N,x
            bcs   :ok
            jsr   PFX_GETNAME
            lda   PFX_PERS
            bne   :set
            jsr   VARFIND                ;carry set = a new name
            bcs   :new
            ldy   PFX_SV                 ;save the old export
            txa                          ;bit and the value
            sta   PFX_SSLOT,y
            lda   VAREXP,x
            sta   PFX_SKIND,y
            jsr   VSLOT_VAL
            lda   PFX_SV
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            tax
            ldy   #0
:cv         lda   (PTR1),y
            sta   PFX_SVAL,x
            beq   :saved
            inx
            iny
            bra   :cv
:new        ldy   PFX_SV
            lda   #$80                   ;made here: undone by
            sta   PFX_SKIND,y            ;freeing the slot
:saved      inc   PFX_SV
:set        jsr   VARSET
            bcs   :bad
            lda   PFX_PERS
            bne   :step
            lda   #1                     ;exported for the child
            sta   VAREXP,x
            ldy   PFX_SV
            dey
            txa
            sta   PFX_SSLOT,y            ;a new name's slot is
:step       inc   PFX_I                  ;only known now
            bra   :next
:ok         clc
            rts
:bad        lda   PFX_PERS
            bne   :bshow
            dec   PFX_SV                 ;this entry never took
:bshow      jsr   PFX_RESTORE
            jsr   PR_VARFULL
            sec
            rts

*---------------------------------------------------------------
* PFX_RESTORE -- undo every saved entry, newest first.  A no-op
* when none is saved, which is what :segdone relies on.
*---------------------------------------------------------------
PFX_RESTORE lda   PFX_SV
            beq   :done
:r          dec   PFX_SV
            ldy   PFX_SV
            ldx   PFX_SSLOT,y
            lda   PFX_SKIND,y
            bmi   :free
            sta   VAREXP,x               ;the old export bit
            tya
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            pha
            jsr   VSLOT_VAL
            plx
            ldy   #0
:cb         lda   PFX_SVAL,x
            sta   (PTR1),y
            beq   :nxt
            inx
            iny
            bra   :cb
:free       jsr   VSLOT_NAME
            lda   #0
            sta   (PTR1)                 ;an empty name = free
            sta   VAREXP,x
:nxt        lda   PFX_SV
            bne   :r
            jsr   SH_HFLUSH              ;PATH may be back
:done       rts

*---------------------------------------------------------------
* PFX_STG_APPLY / PFX_STG_UNDO -- the pipeline stage's turn,
* called around ENV_STAGE .. SC_SPAWN (shblt2.s).  A single
* command was applied by PFX_PEEL already.  _APPLY: carry SET
* after a reported refusal.  _RESTORE keeps A and the carry
* (SC_SPAWN's result).
*---------------------------------------------------------------
PFX_STG_APPLY
            lda   NCMD
            cmp   #1
            beq   :none
            ldx   STAGEI
            lda   PFX_N,x
            beq   :none
            stx   PFX_S
            stz   PFX_PERS
            jmp   PFX_APPLY
:none       clc
            rts

PFX_STG_UNDO
            php
            pha
            jsr   PFX_RESTORE
            pla
            plp
            rts

PFX_MANY_M  asc   "sh: too many assignments"
            dfb   $8D,0
