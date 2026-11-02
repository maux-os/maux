*---------------------------------------------------------------
* shblt3.s -- the LOW-RESIDENT message strings for the six
* POSIX builtins whose CODE lives in the second code segment
* (src/bin/shsgblt.s, `command`/`type`/`eval`/`exec`/
* `readonly`/`times`). `put` by src/bin/sh.s like every other
* body module; the same pairing shtrap.s/shsgtrp.s and
* shvar2.s/shsggop.s already have.
*
* WHY A WHOLE FILE OF NOTHING BUT STRINGS. The kernel's
* COPYIN_ENTRY/COPYOUT_ENTRY templates (src/kernel/entry2.s)
* refuse a process address >= $D000 outright (K_CPY_ERR = 2,
* "LC path not wired yet"), and BankCopy -- the path a tty or
* file write's BUFFER takes -- is built on those two templates.
* So anything handed to PUTS/PR_ERRAX/SC_* has to sit in the
* ordinary $0200-$BFFF window, and only the CODE may move up to
* $E000. docs/SH-SUBSET.md ruling 7.6 and
* learning:01M2MCYEXW7JA7ZPZ4F7GC2217 are the argument.
*
* WHAT DID NOT NEED TO COME DOWN HERE, and this is the one
* refinement on shsgtrp.s/shsggop.s's own precedent: a string
* only ever read by the PROCESS's own CPU is not a syscall
* argument. The builtin NAME strings ("COMMAND", "TYPE", ...)
* are only ever compared by STRCMPI -- `lda (PTR1),y` against
* the process's own language card -- so they stay in the
* segment beside the code that uses them, and so does BLTTAB.
* Only the bytes a WRITE ever sees are here.
*
* Every symbol here resolves against sh.s's equates, data and
* arena -- see that file's header for the scope.
*---------------------------------------------------------------

*-- `type` / `command -v` / `command -V` report text. The
*-- wording is V7/BSD `type`'s (System III's `type` is where
*-- "NAME is PATH" comes from; V7 Bourne has no `type` at all,
*-- learning:01M10WZW2BWWX6X4DYF4E5AD3D lists its 21 builtins
*-- and neither `type` nor `command` is among them). POSIX XCU
*-- pins none of these strings, only the exit statuses, so they
*-- are recorded in docs/SH-FEATURES.md rather than inherited.
BLT_ISBLT_M asc   " is a shell builtin"
            dfb   $8D,0
BLT_ISKW_M  asc   " is a shell keyword"
            dfb   $8D,0
BLT_IS_M    asc   " is "
            dfb   0
BLT_NOTFN_M asc   ": not found"
            dfb   $8D,0
BLT_NL_M    dfb   $8D,0

*-- The shared refusal for the builtins that PRINT. Builtins
*-- dispatch BEFORE RUN_PIPELINE applies redirection (shbltn.s
*-- CHCK_BLTN_ECH's own header spells the trap out), and
*-- CHCK_BLTN_ECH also records why a builtin must NOT drive
*-- OPEN_REDIR_WR itself -- the shell's single shared set of
*-- redirect parmlists is read by the NEXT BLD_FDCTS_STG, and
*-- doing it emptied the following command's output file.
*-- `echo`/`test` can fall through to a binary of the same name
*-- when they meet a shape they cannot do; `type`, `times`,
*-- `readonly`, `eval` and `command -v` have no binary twin, so
*-- the honest answer is a refusal, not a silent write to the
*-- console.
BLT_NORDR_M asc   "sh: builtin: redirection not supported"
            dfb   $8D,0

*-- `readonly`
RO_PFX_M    asc   "readonly "
            dfb   0
RO_EQ_M     asc   "="
            dfb   0
RO_BAD_M    asc   "sh: readonly: bad name or value"
            dfb   $8D,0
*-- The refusal VARSET/VARUNSET raise for a read-only slot. It
*-- does NOT name the variable: PR_ERRAX's contract is a fixed
*-- string, and a dynamic one would need its own PUTS pair at
*-- every one of the seven VARSET call sites. Same v1 shape and
*-- same reason as getopts's unqualified "illegal option"
*-- (docs/SH-FEATURES.md sec 24).
VARRO_MSG   asc   "sh: read-only variable"
            dfb   $8D,0

*-- `eval`
EVAL_LONG_M asc   "sh: eval: line too long"
            dfb   $8D,0

*-- `exec`
EXEC_RD_M   asc   "sh: exec: cannot redirect"
            dfb   $8D,0

*-- `times`. The second line is ALWAYS this literal: maux has no
*-- per-process CPU accounting at all and no child accounting,
*-- so the children's pair is a structural zero rather than a
*-- measurement (docs/SH-FEATURES.md sec 29 records the
*-- divergence). The FIRST line's first field is the shell's own
*-- ELAPSED time, from SYS_TICK -- honest, and labelled as such
*-- in the documentation rather than passed off as user time.
TMS_M_M     asc   "m"
            dfb   0
TMS_DOT_M   asc   "."
            dfb   0
TMS_TAIL_M  asc   "s 0m0.00s"
            dfb   $8D,0
TMS_ZERO_M  asc   "0m0.00s 0m0.00s"
            dfb   $8D,0
