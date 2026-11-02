*---------------------------------------------------------------
* find.s -- walk a directory tree, evaluating a real POSIX
* expression against every matching path (printing, or running
* actions, per that expression).
*
* Usage: find PATH expression
*   primaries: -name PAT -type f|d -path PAT -print -prune
*     -newer FILE -mtime [+-]N -size [+-]N[c] -links [+-]N
*     -xdev -nouser -nogroup -exec CMD ... ;
*   operators: ! expr | expr [-a] expr | expr -o expr | ( expr )
* ! binds tightest, then implicit/explicit -a, then -o (POSIX
* find XCU "order of decreasing precedence"). -a/-o short-
* circuit: the right operand is not evaluated (no side effects,
* no filesystem access) when the left side already decides the
* result. If the expression contains none of -exec/-print (the
* POSIX list -- NOT -prune, see below), the WHOLE expression is
* implicitly ANDed with a trailing -print, exactly as if it had
* been typed `( given expression ) -print`.
*
* docs/FLEET.md's "find" section rules this task, in order: 1.
* `-name`/`-path` match a GLOB, not a regex -- src/liba/
* glob.s's GLOBMATCH. `-name` matches the entry's own NAME only;
* `-path` matches the whole walked pathname. 2. `-exec CMD ...
* {} ;` PATH-resolves CMD since 2026-08-26 (src/liba/pathres.s),
* the way execvp does -- an absolute word still bypasses the
* search. It also needs a bare ";" to reach argv. The gate
* harness supplies one directly (scripts/check_find.py, same
* shape as check-ld/check-testev). THIS USED TO SAY -exec "only
* works today spawned directly by a gate harness (no shell
* involved)", which was over-broad and is why nobody tried it
* from a script: what sh eats is a BARE semicolon, as a command
* separator. A QUOTED one passes through as an ordinary word --
* measured 2026-08-25, `ECHO A ';' B` prints "A ; B" -- so `find
* ... -exec CMD ';'` works from sh today and check-env drives
* exactly that to prove -exec inherits the environment. No new
* quoting support was needed; the limitation was in the
* sentence. -exec's OWN truth value (for `-a`/`-o` chaining) is
* whether the spawned child exited zero -- POSIX's own rule --
* not "always true": `find X -exec CMD ; -print` only prints
* when CMD succeeded. 3. find is the SECOND consumer of the
* directory walk, so it carries src/liba/readdir.s
* (OPENDIR/READDIR/CLOSEDIR) -- see that file's own header --
* rather than duplicating it.
*
* THE EXPRESSION ENGINE (src/bin/findexpr.s) is a tokenize-once/
* evaluate-per-file design, NOT a re-parse-per-file one:
* TOKENIZE (PARSE's new body) turns argv[2..] into a flat token
* array (TOKTYPE/TOKSIGN/TOKVLO/TOKVHI, indexed 0..NTOK-1) ONE
* time, then a bounded-recursion-depth evaluator (EVAL_EXPR ->
* EVAL_TERM -> EVAL_FACT, one JSR level per grammar rule) walks
* that SAME array fresh for every visited path. Recursion depth
* is bounded at TOKENIZE time (FIND_MAXNEST simultaneous parens,
* FIND_MAXNEST total `!`s) so the worst case cannot overrun the
* 256-byte hardware stack; short-circuit is implemented by
* threading an "active" flag down through the recursion (an
* explicit software stack, EVALSTACK -- the hardware stack holds
* no per-call state a caller needs back, so JSR/RTS pairing
* stays completely ordinary) rather than by skipping tokens
* textually. The SAME evaluator, called once at parse time with
* active=0, is find's own syntax checker (a "dry run" that never
* touches the filesystem) -- one grammar, one implementation,
* checked against itself rather than duplicated.
*
* -mtime/-newer/-size all RE-STAT the current path fresh (GET_
* FILE_INFO or OPEN+GET_EOF+CLOSE) rather than reading whatever
* WALK happened to have around (GFIPARM for the root argument,
* READDIR's RD_RECORD for a descendant) -- those two sources
* disagree on what they carry (GET_FILE_INFO has no EOF field at
* all; READDIR's raw entry has no blocks_used), so re-stating
* the SAME primitive uniformly for root and descendant alike is
* simpler and more honest than reconciling two shapes. See
* findexpr.s's own header for what each of -mtime/-newer/-size
* measures and why.
*
* NO RECURSION IN THE WALK: a 6502 has a 256-byte hardware
* stack, AND (the sharper reason here) src/liba/readdir.s is a
* SINGLETON -- only one directory may be open at a time. True
* recursive descent would need a live OPENDIR handle per stack
* frame, which the facade does not offer (ProDOS's own per-
* process fd table is only 8 deep, PCB_FDTABLE -- 5 usable
* beyond stdin/stdout/stderr -- too few for an 8-deep walk
* anyway). Instead: an EXPLICIT depth stack (DS_PLEN/DS_RESN,
* FIND_MAXDEP=8 frames) records, per paused ancestor level, its
* own path length and how many entries it had already yielded.
* Descending CLOSES the current directory; returning to a paused
* ancestor REOPENS it fresh and replays READDIR that many times
* to skip back to where it paused (SKIPRESUME) -- no live fd
* survives a descend, so at most ONE directory fd is ever open.
* This trades "closed directories re-scan their own already-seen
* entries once per pop" for never needing more than one open fd;
* for a tool like find, walking small trees, that is the right
* side of the tradeoff (documented, not accidental).
*
* ProDOS pathnames cap at 64 characters; with 15-char component
* names the reachable depth is a handful of levels, so 8 frames
* is ample -- exceeding it is a LOUD failure (stderr message,
* exit 2), never a silently truncated walk. The 64-char cap is
* an MLI-CALL limit, not an on-disk one (prefix + partial
* pathname reach 128, TRM ch. 2), so a walk CAN meet a child
* whose full path no MLI call could open: that entry prints
* "find: <path>: pathname too long" to stderr, forces exit 1,
* and the walk continues with its siblings -- never an overrun
* (FULLPATH is sized to the builder's worst case, FP_BUFLEN) and
* never a descent into it.
*
* -exec spawns CMD via SC_SPAWN (docs/SYSCALL.md item 10: NULL
* fdactions means the child inherits fd 0/1/2 from find,
* unmodified), after resolving CMD against PATH with
* src/liba/pathres.s -- the execvp shape. An ABSOLUTE CMD is
* returned untouched by that resolver, so it costs nothing. A
* word that resolves nowhere is reported as an exec failure and
* the walk continues, exactly as an unopenable one was. Up to
* FIND_MAXEXEC (3) distinct `-exec` primaries may appear in one
* expression (each gets its own template slot in EXECTPL) -- a
* v1 limit, not a POSIX one, chosen to keep growth proportionate
* (a 4th `-exec` is a USAGE_ERR, same "too complex" family as
* the nesting caps below).
*
* GAP ROWS (not implemented -- fall through to USAGE_ERR, same
* as any other unrecognized primary): `-ok` (needs a blocking
* read-a-line-from-the-tty primitive liba does not have yet,
* and building one untested risks hanging an automated gate
* rather than failing it loudly); `-perm` (docs/ANACHRONISMS.md
* sec W2 already rules OUT a Unix rwx mapping onto ProDOS's
* D/RN/B/W/R access byte -- there is no honest octal-mode
* primary to write); `-user`/`-group` (no user database on
* ProDOS at all, so no name can ever resolve -- there is nothing
* to compare against); `-depth` (POSIX's post-order requirement
* means acting on a directory only AFTER its contents, which
* means DEFERRING the action taken at :godescend until
* POPFRAME/:unwind -- a real, scoped change to the depth-stack
* state machine this file's own header spends its whole preamble
* justifying, not a small addition; left as a named follow-up
* rather than rushed).
*
* Any scratch this file owns of its own lives in the `dum`/
* `dend` block at the textual end, after every `put` -- never
* `ds` (real zero bytes, 39.07 cyc/byte spawn cost). `dum`
* memory is NOT zeroed; every cell below is written before its
* first read (STARTUP explicitly zeroes the handful of flags/
* counters that need a defined value before any read -- see
* START -- and every buffer is filled in full, start to NUL, by
* the routine that owns it before anything else reads it).
*---------------------------------------------------------------

            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/find.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/readdir.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

FIND_MAXDEP equ   8         ;explicit depth stack -- see header
FIND_MAXEXA equ   16        ;max -exec template argv slots,
                            ;including the terminating NULL
FIND_EXCAP  equ   30        ;(FIND_MAXEXA-1)*2 -- last usable
                            ;byte offset, room left for the
                            ;NULL terminator pair
FIND_MAXEXEC equ  3         ;max distinct -exec primaries in
                            ;one expression -- see header
FIND_EXSTRD equ   32        ;=FIND_MAXEXA*2, per-slot stride
                            ;into EXECTPL/findexpr.s
FIND_MAXTOK equ   48        ;max tokens findexpr.s's TOKENIZE
                            ;will build from argv[2..] -- an
                            ;overflow is USAGE_ERR ("expression
                            ;too complex"), the same family as
                            ;FIND_EXCAP above
FIND_MAXNST equ   16        ;max simultaneous open parens, AND
                            ;(independently) max total `!`
                            ;tokens -- bounds EVAL_EXPR/TERM/
                            ;FACT's worst-case recursion depth
                            ;so it cannot overrun the 256-byte
                            ;hardware stack. See findexpr.s.
EVSTKSZ     equ   140       ;EVALSTACK bytes -- 2/frame, room
                            ;for well past FIND_MAXNST*3 frames

* -- FULLPATH is sized to BUILDCHILD's own worst case, not to
* -- the MLI's: a full PATHBUF (MLI_PTH_MAXLN chars -- PARSE
* -- bounds the argv route and CP_FULLPATH only ever copies a
* -- checked path) + '/' + a 15-char ProDOS name + NUL. The
* -- 64-char MLI limit is enforced AFTER the build, at one
* -- choke point (BUILDCHILD's carry), because "too long for
* -- an MLI path" is a per-ENTRY condition the walk reports
* -- and survives -- a 64-char directory with a long-named
* -- child is legal on disk (prefix+partial reach 128; TRM
* -- ch. 2) and used to overrun this buffer into MLIPATH.
FP_BUFLEN   equ   MLI_PTH_MAXLN+17
FPMINSZ     equ   MLI_PTH_MAXLN+17
* -- FPMINSZ restates the writers' sum INDEPENDENTLY of
* -- FP_BUFLEN so the arena tripwire below still fires if
* -- FP_BUFLEN itself is ever edited down.

            put   findtop.s
            put   findact.s
            put   findexpr.s
            put   findeval.s
            put   findtst.s
            put   ../liba/string.s
            put   ../liba/glob.s
            put   ../liba/readdir.s
            put   ../liba/readsyn.s
            put   ../liba/readsys.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s    ;SC_SPAWN/SC_WAIT --
            put   ../liba/spawnwhy.s
*-- ENVPASS -- -exec hands the child THIS process's environment.
*-- Must precede libabss.s, which sizes EPASS_ARR from the
*-- EPASS_MAX declared here (merlin32 resolves EQU forward
*-- references badly enough to miscompile silently --
*-- learning:01M05519PC55WGJNE4PY5HX4TH).
            put   ../liba/pathtab.s
            put   ../liba/pathres.s
            put   ../liba/env.s
            put   ../liba/libabss.s
                                        ;`find -exec`/`-print0`
                                        ;forks and reaps

*---------------------------------------------------------------
* find's own scratch, `dum`/`dend`'d at the textual end of the
* file per the task brief -- `dum` computes addresses only and
* emits NO bytes (never `ds`, which would emit real zeros and
* cost 39.07 cyc/byte at spawn time). Must stay textually LAST:
* `dum`'s addresses are relative to the real PC where it opens,
* and anything emitted after `dend` would collide with them.
*
* `dum` memory is NOT zeroed -- every cell here is written
* before its first read:
*  - ERRFLAG/DEPTH/CURRESN: zeroed by START before PARSE/WALK
*    ever run.
*  - SKIPN: SKIPRESUME's own countdown, copied from CURRESN as
*    that routine's first two instructions and read only after.
*    It exists so the skip cannot consume CURRESN, which is the
*    level's absolute position and has to outlive the resume --
*    see SKIPRESUME's header for the loop that cost.
*  - PATHLEN/PATHBUF: written by PARSE's STRCPY of argv[1]
*    before WALK reads either.
*  - MLIPATH: written by MKPATHBUF before OPENDIR/SC_GFI (which
*    patches GFIPARM_PATH, a real initialized parmlist declared
*    OUTSIDE this arena -- see the Data section above) read it.
*  - FULLPATH: written whole (NUL-terminated) by BUILDCHILD
*    before WALK's main loop reads it. FP_BUFLEN bytes -- sized
*    to BUILDCHILD's own worst case (see its header), so the
*    build cannot overrun; the MLI 64-char limit is a CARRY
*    verdict at the same routine, and an over-long child is
*    reported and skipped, never copied onward.
*  - RD_RECORD: written whole by READDIR before WALK reads it
*    (READDIR's own contract -- readdir.s's header).
*  - EXECTPL/PWORD: written by TOKENIZE's own -exec/word
*    handling (findexpr.s) before ACT_EXEC/BUILD_EXECV ever run
*    (a token only reaches ACT_EXEC if TOKENIZE built it, so the
*    slot it names is always one TOKENIZE filled).
*  - EXECARGV: written whole by BUILD_EXECV before SC_SPAWN
*    reads it.
*  - DS_PLEN/DS_RESN: written by PUSHFRAME before the matching
*    POPFRAME reads that same slot (DEPTH only ever pops a
*    frame index it has itself pushed).
*  - PARSEI: written by PARSE before its own first read.
*  - BN_LAST/AF_ISDIR/BE_PATH/EXWSTATUS: each written by its own
*    routine (BASENAME/EVAL_TOP/BUILD_EXECV/ACT_EXEC) before
*    that SAME routine reads it back.
*  - findexpr.s's OWN cells (TOKTYPE.. through GFSZLO/GFSZHI
*    below) are documented in THAT file's header, not restated
*    here -- same split find.s already keeps with findtop.s/
*    findact.s's routines.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ERRFLAG     ds    1
DEPTHFLAG   ds    1              ;-depth given (TOKENIZE zeroes)
OKFLAG      ds    1              ;the exec being run is -ok
OKCNT       ds    1              ;-ok reply parmlist, built
OKREF       ds    1              ;at use (writable text is not
OKBUF       ds    2              ;allowed -- docs/STICKY.md)
OKREQ       ds    2
OKTRANS     ds    2
OKANS       ds    8
DEPTH       ds    1
CURRESN     ds    2
SKIPN       ds    2              ;SKIPRESUME's countdown copy

PARSEI      ds    1
PWORD       ds    2

PATHLEN     ds    1
PATHBUF     ds    MLI_PTH_MAXLN+1
FULLPATH    ds    FP_BUFLEN
FPGAP1      equ   *-FULLPATH+1
* -- SIZING TRIPWIRE (adversarial review B2, 2026-08-23):
* -- the relayout's whole claim is that FULLPATH is at
* -- least the writers' sum -- PATHBUF + '/' + 15-char
* -- name + NUL -- and a comment cannot hold that claim:
* -- reverting this ds to 65 passed the WHOLE gate (the
* -- carry fence masks the spill, and the .bin byte count
* -- cannot witness a dum-arena change). The division is
* -- 0 while FULLPATH is big enough, 1 when it is not,
* -- and `err` fails the assembly -- same idiom as the
* -- arena-end tripwire below.
            err   FPMINSZ/FPGAP1
MLIPATH     ds    MLI_PTH_MAXLN+1

BN_LAST     ds    1
AF_ISDIR    ds    1
BE_PATH     ds    2
EXWSTATUS   ds    1

DS_PLEN     ds    FIND_MAXDEP
DS_RESN     ds    FIND_MAXDEP*2

RD_RECORD   ds    RD_SIZE
EXECTPL     ds    FIND_MAXEXEC*FIND_EXSTRD
EXECARGV    ds    FIND_MAXEXA*2

* -- findexpr.s's own arena -- see that file's header for the
* -- write-before-read trace of every cell below.
TOKTYPE     ds    FIND_MAXTOK
TOKSIGN     ds    FIND_MAXTOK
TOKVLO      ds    FIND_MAXTOK
TOKVHI      ds    FIND_MAXTOK
NTOK        ds    1
TOKI        ds    1
CURTT       ds    1
CURSIGN     ds    1
CURVLO      ds    1
CURVHI      ds    1
CURAK       ds    1
ANYACTION   ds    1
PARSEBAD    ds    1
PRUNEFLAG   ds    1
PARENDEPTH  ds    1
NOTCOUNT    ds    1
EXECNSLOT   ds    1
CLOCKOK     ds    1
CLOCKNEED   ds    1
CLKBUF2     ds    4
NOWDAYSLO   ds    1
NOWDAYSHI   ds    1
NEWERMD     ds    2
NEWERMT     ds    2
NPSIGN      ds    1
NPVLO       ds    1
NPVHI       ds    1
NPSUF       ds    1
EVALSTACK   ds    EVSTKSZ
EVALSP      ds    1
EVPATH      ds    2
EVBASE      ds    2
EVMLIP      ds    MLI_PTH_MAXLN+1
DATEWLO     ds    1
DATEWHI     ds    1
DAYV2       ds    1
MONTHV2     ds    1
YEARV2      ds    1
YRS8        ds    1
MULC        ds    1
MULPLO      ds    1
MULPHI      ds    1
DNRESLO     ds    1
DNRESHI     ds    1
ACTUALLO    ds    1
ACTUALHI    ds    1
CSTMP       ds    1
CSTMP2      ds    1
EVOPARM     ds    1
EVOPARM_PT  ds    2
EVOPARM_IO  ds    2
EVOPARM_RF  ds    1
FSZPARM     ds    1
FSZPARM_RF  ds    1
FSZPARM_EF  ds    3
EVCPARM     ds    1
EVCPARM_RF  ds    1
GSEOFERR    ds    1
EXBASE      ds    1
EXCAPABS    ds    1
EXOFF       ds    1
NPALLOWC    ds    1
NPDIGN      ds    1
EXECSLOT    ds    1
BE_SBASE    ds    1
BE_CMPR     ds    1
FIND_BSSEND                      ;scripts/check_find.py's poison
                                 ;span ends here (same job as
                                 ;ls.s's LS_BSSEND)
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
            err   */$BF00
            dend
