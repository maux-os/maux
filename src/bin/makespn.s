*---------------------------------------------------------------
* makespn.s -- running a recipe: the command prefixes, -t's
* touch, and the argv split that spawns it.
*
* Split out of makerun.s for as's 16,128-byte source window
* (check-dialect 3b): as holds the MANIFEST resident and
* streams each `put` one at a time, so the charge is the
* manifest plus the LARGEST put.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_RECIPE -- expand, echo and run each command line of rule
* MK_RULEI, stopping at the first that exits nonzero.
*
* Echoing before running is make's own behaviour and it is not
* decoration: it is the only record of what a build actually
* did, and -n turns it into a dry run by echoing without
* spawning.
*
* THE THREE COMMAND PREFIXES, all V7: '@' silences the echo,
* '-' ignores a nonzero exit, '+' runs the line even under -n.
* They are stripped from the EXPANDED line, so `$(AT)cmd` works
* and so does an inference recipe that is silent for every
* target it serves.
*---------------------------------------------------------------
MK_RECIPE   ldx   MK_RULEI
            lda   RULE_NCMD,x
            bne   :have
            rts                  ;a rule with dependencies and
                                 ;no recipe is legal -- it
                                 ;just groups things
:have       sta   MK_CMDN
            lda   RULE_CMD,x
            sta   MK_CMDP
            lda   RULE_CMD+MK_MAXRULE,x
            sta   MK_CMDP+1
*-- -q asks a question and runs nothing: something was out of
*-- date, which is the whole answer
            lda   QFLAG
            beq   :nottouch
            lda   #1
            sta   QOUT
            rts
:nottouch   lda   TFLAG
            beq   :each
            jmp   MK_TOUCH
:each       jsr   MK_EXPCMD
            stz   CMD_AT
            stz   CMD_DASH
            stz   CMD_PLUS
            lda   #<MK_CMDBUF
            sta   PTR2
            lda   #>MK_CMDBUF
            sta   PTR2+1
:pfx        lda   (PTR2)
            cmp   #$C0                 ;'@'
            beq   :isat
            cmp   #$AD                 ;'-'
            beq   :isdash
            cmp   #$AB                 ;'+'
            beq   :isplus
            bra   :pfxdone
:isat       inc   CMD_AT
            bra   :pfxnext
:isdash     inc   CMD_DASH
            bra   :pfxnext
:isplus     inc   CMD_PLUS
:pfxnext    jsr   MK_TOKINC
            bra   :pfx
:pfxdone    lda   PTR2
            sta   MK_RUNP
            lda   PTR2+1
            sta   MK_RUNP+1
*-- under -n the printed line IS the output, so '@' does not
*-- suppress it; otherwise '@' and -s and .SILENT all do
            lda   NFLAG
            bne   :echo
            lda   SFLAG
            ora   CMD_AT
            bne   :norun
:echo       lda   MK_RUNP
            sta   PTR0
            lda   MK_RUNP+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:norun      lda   NFLAG
            beq   :spawn
            lda   CMD_PLUS
            beq   :skiprun
:spawn      jsr   MK_SPAWN
            lda   STOPFLAG
            bne   :done
:skiprun    dec   MK_CMDN
            beq   :done
            jsr   MK_SKIPCM
            bra   :each
:done       rts

MK_SKIPCM   lda   MK_CMDP
            sta   PTR0
            lda   MK_CMDP+1
            sta   PTR0+1
*-- a recipe line is stored RAW and terminated by the NUL that
*-- replaced its CR; the NEXT one always begins with a TAB (the
*-- reader strips only the first command's), so the terminator
*-- is the NUL a TAB follows. The first multi-command recipe
*-- ever run (nas self-make, 2026-09-14) had its second command
*-- start at `-o`, then at `<tab>/bin/NAS`.
:scan       lda   (PTR0)
            beq   :nul
:next       inc   PTR0
            bne   :scan
            inc   PTR0+1
            bra   :scan
:nul        ldy   #1
            lda   (PTR0),y
            cmp   #$89                 ;high-bit TAB
            bne   :next
            iny
            tya
            clc
            adc   PTR0
            sta   MK_CMDP
            lda   PTR0+1
            adc   #0
            sta   MK_CMDP+1
            rts

*---------------------------------------------------------------
* MK_TOUCH -- -t: bring the target up to date by DATING it,
* without running anything. GET_FILE_INFO then SET_FILE_INFO
* with only the two date fields changed, which is the
* read-modify-write discipline src/bin/chmod.s established for
* this call.
*---------------------------------------------------------------
MK_TOUCH    lda   MK_TGTP
            sta   MK_FNAME
            lda   MK_TGTP+1
            sta   MK_FNAME+1
            jsr   MK_STATN
            lda   MK_EXISTS
            bne   :haveit
            rts                        ;nothing to date
:haveit     lda   SFLAG
            bne   :quiet
            lda   #<TOUCHMSG
            sta   PTR0
            lda   #>TOUCHMSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   MK_TGTP
            sta   PTR0
            lda   MK_TGTP+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:quiet      lda   #<TOUCHCLK
            sta   PTR0
            lda   #>TOUCHCLK
            sta   PTR0+1
            jsr   SC_CLOCK
*-- PATHBUF still holds the MLI form of this name: MK_STATN put
*-- it there and nothing since has called MKPATH
            lda   #PCOUNT_SFI
            sta   SFIPARM
            lda   #<PATHBUF
            sta   SFIPARM_PATH
            lda   #>PATHBUF
            sta   SFIPARM_PATH+1
            lda   GFIPARM_ACC
            sta   SFIPARM_ACC
            lda   GFIPARM_FTYP
            sta   SFIPARM_FTYP
            lda   GFIPARM_AUX
            sta   SFIPARM_AUX
            lda   GFIPARM_AUX+1
            sta   SFIPARM_AUX+1
            stz   SFIPARM_NULL
            stz   SFIPARM_NULL+1
            stz   SFIPARM_NULL+2
            lda   TOUCHCLK
            sta   SFIPARM_MDATE
            lda   TOUCHCLK+1
            sta   SFIPARM_MDATE+1
            lda   TOUCHCLK+2
            sta   SFIPARM_MTIME
            lda   TOUCHCLK+3
            sta   SFIPARM_MTIME+1
            lda   #<SFIPARM
            ldx   #>SFIPARM
            jsr   SC_SFI
            bcs   :failed
            rts
:failed     lda   #<TOUCHERRMSG
            sta   PTR0
            lda   #>TOUCHERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jmp   MK_SETERR

*---------------------------------------------------------------
* MK_SPAWN -- tokenize the EXPANDED command line at MK_RUNP on
* spaces into an argv, spawn it, and wait.
*
* THERE IS NO SHELL BETWEEN make AND THE COMMAND. That is a real
* limit, stated in make.s's header: no pipes, no redirection, no
* globbing in a recipe. It is also why this is safe to do at all
* in a program this size -- argv is a split on spaces and
* nothing more, with no quoting rules to get subtly wrong.
*
* The split happens in MK_CMDBUF, never in MKTEXT, so the recipe
* SURVIVES its own execution -- which one inference rule serving
* five hundred targets rather depends on.
*---------------------------------------------------------------
* MAKE-FLUSH: our echo sits in liba's buffer when fd 1 is a file
* or pipe; the child writes through its own. Flush first.
MK_SPAWN    jsr   SIO_FLUSHALL
            stz   MK_ARGVN
            lda   MK_RUNP
            sta   PTR0
            lda   MK_RUNP+1
            sta   PTR0+1
:tok        lda   (PTR0)
            beq   :tokdone
            cmp   #$A0                 ;skip runs of spaces
            beq   :issp
            cmp   #$89                 ;and tabs, which a
            bne   :word                ;continued line brings in
:issp       lda   #0
            sta   (PTR0)               ;split in place
            inc   PTR0
            bne   :tok
            inc   PTR0+1
            bra   :tok
:word       ldx   MK_ARGVN
*-- the self-rebuild's worst recipe is 20 tokens (MAKE's own
*-- link line); 16 refused CP's 17 -- the first util with a
*-- 13-module link -- while CAT's 15 sailed through
*-- (check-selfmake, 2026-09-01). MK_MAXARG, measured.
            cpx   #MK_MAXARG
            bcc   :argsok            ;`bcc` past a `jmp` --
            jmp   :toomanyargs       ;the tokenizer outruns
:argsok                              ;a branch
            txa
            asl   a
            tax
            lda   PTR0
            sta   SPWN_ARGV,x
            lda   PTR0+1
            sta   SPWN_ARGV+1,x
            inc   MK_ARGVN
:wscan      lda   (PTR0)
            beq   :tokdone
            cmp   #$A0
            beq   :tok
            cmp   #$89
            beq   :tok
            inc   PTR0
            bne   :wscan
            inc   PTR0+1
            bra   :wscan
:tokdone    lda   MK_ARGVN
            bne   :haveargs
            rts                        ;blank recipe line
:haveargs   asl   a                    ;NULL-terminate argv
            tax
            lda   #0
            sta   SPWN_ARGV,x
            sta   SPWN_ARGV+1,x
*-- SC_SPAWN's contract is PTR0 = path, PTR1 = argv, PTR2 =
*-- fdactions, and SPWN_ENVP written by the caller -- it builds
*-- PROCPARM itself. Handing it a parmlist in PTR0, which is
*-- what this did first, makes it read the parmlist AS the path
*-- and everything else as garbage.
*--
*-- ENVPASS points SPWN_ENVP at this process's own environment,
*-- so a recipe command inherits what make inherited. find.s's
*-- own header records why opting out with `stz SPWN_ENVP` was
*-- wrong there and it is wrong here for the same reason: a
*-- program spawned by make should see the environment the user
*-- exported.
*--
*-- argv[0] is a COMMAND WORD, resolved the way `sh -c` would
*-- (KFIX10 item 4; POSIX runs each recipe line through sh). A
*-- word with a slash is a path and is never searched: CMDSLASH
*-- also resolves `./x` against the cwd. A bare word walks PATH
*-- (PATHRSLV, execvp's search, reading the environment). A path
*-- is not probed first -- the spawn's own refusal says whether
*-- the file is there, as it does for sh, and a probe would cost
*-- an OPEN and CLOSE per command (measured on the self-make).
*-- Resolving needs no spawn state, so it runs before ENVPASS.
            lda   SPWN_ARGV
            sta   PTR0
            lda   SPWN_ARGV+1
            sta   PTR0+1
            lda   #<MK_CPATH
            sta   PTR1
            lda   #>MK_CPATH
            sta   PTR1+1
            jsr   CMDSLASH
            bcc   :resolved
            jsr   PATHRSLV             ;carry clear: PTR0 opens
            bcs   :notfound
:resolved   lda   PTR0                 ;ENVPASS may move PTR0
            pha
            lda   PTR0+1
            pha
            jsr   ENVPASS
            pla
            sta   PTR0+1
            pla
            sta   PTR0
            lda   #<SPWN_ARGV
            sta   PTR1
            lda   #>SPWN_ARGV
            sta   PTR1+1
            stz   PTR2                 ;no fd actions
            stz   PTR2+1
            jsr   SC_SPAWN
            bcs   :spawnerr
            lda   #<WSTATUS
            sta   PTR0
            lda   #>WSTATUS
            sta   PTR0+1
            jsr   SC_WAIT
            bcc   :waited
            jmp   :spawnfail           ;out of a branch's reach
:waited     lda   WSTATUS
            beq   :ok
*-- a command that failed stops the build, and says which one --
*-- unless this line begins '-' or .IGNORE/-i is in force, in
*-- which case the status is discarded exactly as V7 says
            lda   CMD_DASH
            ora   IFLAG
            bne   :ok
            lda   #<CMDFAILMSG
            sta   PTR0
            lda   #>CMDFAILMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jsr   MK_SETERR
:ok         rts
*-- SC_SPAWN's refusal: the open's MLI $44 path, $45 volume or
*-- $46 file not found is "not found"; anything else (not a
*-- program, too big, a loader refusal) is a command that exists
*-- and cannot run, and keeps "cannot spawn command".
:spawnerr   cmp   #$46
            beq   :notfound
            cmp   #$45
            beq   :notfound
            cmp   #$40                 ;invalid path (`d/../x`)
            beq   :notfound
            cmp   #$44
            bne   :spawnfail
:notfound   lda   #<NFPFXMSG       ;"make: CMD: not found"
            sta   PTR0
            lda   #>NFPFXMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   SPWN_ARGV            ;the word as typed, in
            sta   PTR0                 ;the message's polarity
            lda   SPWN_ARGV+1          ;(low: argv is high-bit)
            sta   PTR0+1
            ldy   #0
:nflow      lda   (PTR0),y
            and   #$7F
            sta   MK_CPATH,y           ;MK_CPATH is idle here
            beq   :nfword
            iny
            cpy   #64
            bne   :nflow
            lda   #0
            sta   MK_CPATH,y
:nfword     lda   #<MK_CPATH
            sta   PTR0
            lda   #>MK_CPATH
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<NFSUFMSG
            sta   PTR0
            lda   #>NFSUFMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   CMD_DASH             ;not found is a failed
            ora   IFLAG                ;command: a `-` line or
            bne   :nfok                ;-i goes on
            jmp   MK_SETERR
:nfok       rts
:spawnfail  ldx   #<MKERRPFX            ;A = the errno still
            ldy   #>MKERRPFX
            jsr   SPAWNWHY               ;no bank/file slot: say
            bcs   :spwhy
            lda   #<SPAWNMSG
            sta   PTR0
            lda   #>SPAWNMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
:spwhy      jmp   MK_SETERR
:toomanyargs lda  #<ARGSMSG
            sta   PTR0
            lda   #>ARGSMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jmp   MK_SETERR

NORULEMSG   asc   "make: no rule to make target "
            dfb   0
CYCLEMSG    asc   "make: circular dependency"
            dfb   $8D,$00
DEEPMSG     asc   "make: dependencies nested too deeply"
            dfb   $8D,$00
CMDFAILMSG  asc   "make: command failed"
            dfb   $8D,$00
NFPFXMSG    asc   'make: '
            dfb   0
NFSUFMSG    asc   ': not found'
            dfb   $0D,$00
MKERRPFX    asc   'make: '
            dfb   0
SPAWNMSG    asc   "make: cannot spawn command"
            dfb   $8D,$00
ARGSMSG     asc   "make: too many arguments in one command"
            dfb   $8D,$00
TOUCHMSG    asc   "touch "
            dfb   0
TOUCHERRMSG asc   "make: cannot touch target"
            dfb   $8D,$00
