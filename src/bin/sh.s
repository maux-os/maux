*---------------------------------------------------------------
* sh.s -- the v1 shell. docs/SH-DESIGN.md is the spec this file
* implements directly (that page states its own design is CLOSED
* -- zero open kernel questions -- against the ratified
* docs/SYSCALL.md rulings 9/10/11/13).
* Full design notes: B.SH.TXT (docs/a2/)
*---------------------------------------------------------------

            lst   off
            xc
            put   ../../inc/mm.procbank.equ
*-- BANK_ID ($FF2E) for `$$`. A `dum $FF00`/`dend` pair that
*-- emits nothing, so putting it costs no bytes -- and it is the
*-- ONE spelling of that address, rather than a second local
*-- equate drifting from the kernel's.
            put   ../../inc/mm.procbnk2.equ
                                              ;LOAD_BASE etc.
*-- PCB_STATE/PCB_STOPPED for the job table's SYS_PSTAT reads
*-- (shjob.s JOB_PSTOP, docs/JOB-CONTROL.md Increment C) -- the
*-- record IS the PCB row's first fields, and ps.s puts the same
*-- pair for the same reason. Equates and dum blocks only: no
*-- bytes. Part 2 must follow part 1 (its own header).
            put   ../../inc/mm.annex.equ
            put   ../../inc/mm.annex2.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/sc.fdact.equ
            put   ../../inc/errno.spawn.equ
*-- ERR_CHILD, for FG_WAIT's ERR_CHILD-vs-ERR_INTR decode
*-- (shjob.s). Equates only; kill.s/vi.s put it the same way.
            put   ../../inc/errno.krn.equ
            org   LOAD_BASE              ;ratified:
                                         ;docs/MEMMAP.md #3.1
            dsk   ../../build/sh.bin
            typ   $00

*-- the second code segment's far wall (the $C08B bank at $D000
*-- ends where the first segment's base begins): see the block
*-- before libabss. `err */X` fires when * >= X, and SEG_INIT
*-- copies the page CONTAINING the end too, so an end of exactly
*-- $E000 would write page $E0 -- the first segment's first page
*-- (KFIX3 review F1): the wall is $E000 itself, not past it.
*-- The editor's history ring no longer lives at the top of that
*-- bank (SH-ROOM2): the segment may use all of it. (The
*-- one-line stash for a walk's line in progress is arena,
*-- ED_STASH.)
ED_HSIZE    equ   $0200
ED_RINGSZ   equ   ED_HSIZE
ED_RINGP1   equ   ED_RINGSZ+1
SH_SEG2_LIM equ   PRC_LC_COMMON
SH_SEG1_LIM equ   FFXX_PAGE  ;the kernel's door: seg 1's wall
SEG_MAGIC   equ   $5A        ;shsegi.s -- segments installed
*-- redirect FILE record kinds, held in DUP_SRC (shparse.s):
*-- never a real source fd (0-7) and never $FF, the close
FREC_RD     equ   $FC        ;`N<`  open for reading
FREC_AP     equ   $FD        ;`>>`  open for append
FREC_WR     equ   $FE        ;`>`   open, truncating
            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ    ;ARGC/ARGV -- Tier 2
                                         ;positional parameters
            put   ../../inc/mli.equ
            put   ../../inc/readdir.equ ;RD_SIZE/RD_NAME: GREC

* -- v1 shell sizing (judgment calls, documented, not derived
* from any -- ratified budget -- see file header):
LINEMAX     equ   255        ;max input line length, bytes
                             ;(excl. CR/NUL). 127 -> 255 on
                             ;2026-08-30 (S9 L3): a 13-module
                             ;ld link line cannot fit 127 even
                             ;as bare names after CD, and V7's
                             ;own line limit was 512 -- 127 was
                             ;the odd one out.
*-- MAXTOK follows LINEMAX rather than standing on its own: the
*-- resource is the LINE's bytes, and a token costs at least two
*-- of them (one character plus one separator), so 127 bytes
*-- cannot hold more than 64 tokens. The `err` below is the
*-- tripwire docs/LIMITS.md asked for -- change LINEMAX and the
*-- ASSEMBLER objects, instead of a comment quietly going stale
*-- the way ARGV_MAX_CNT's "generous for a shell with no
*-- globbing" did. Written as additions only, and MEASURED
*-- (inc/memmap.equ has the probe result): in an `equ`,
*-- merlin32 applies precedence and real Merlin-8 2.59 goes
*-- strictly left to right, so `LINEMAX+1/2` is 127 to one and
*-- 64 to the other with no error from either. `err` itself is
*-- fine in both -- Merlin-8 2.59 assembled it clean.
*-- Operators split off a word WITHOUT a blank now (shtok.s
*-- :bop), so `a|b` is three tokens in three bytes and the
*-- two-bytes-per-token premise is no longer a hard bound -- the
*-- runtime MAXTOK checks in TOKENIZE (:tokstart and :bop) are
*-- what actually hold the table; the err below is kept as the
*-- LINEMAX-tracking tripwire it always was.
OPBUFSZ     equ   256        ;TOKENIZE's operator-token pool
*-- The operator bytes TOKENIZE splits on, and the digit range
*-- of an IO_NUMBER, high-bit-set like all liba text. Named, not
*-- raw immediates: check-encoding's ratchet only goes down.
OPC_PIPE    equ   $FC        ;'|'
OPC_LT      equ   $BC        ;'<'
OPC_GT      equ   $BE        ;'>'
OPC_SEMI    equ   $BB        ;';'
OPC_AMP     equ   $A6        ;'&'
OPC_DASH    equ   $AD        ;'-'
OPC_DIG0    equ   $B0        ;'0'
OPC_DIG8    equ   $B8        ;one past '7'
*-- shtabc.s / shtabc2.s: the characters TAB completion refuses
TCC_STAR    equ   $AA       ;'*'
TCC_QM      equ   $BF       ;'?'
TCC_BQ      equ   $E0       ;backquote
TCC_HASH    equ   $A3       ;'#'
TCC_DOT     equ   $AE       ;'.'
TCC_BADN    equ   9
*-- the editor's line cap (shedit.s), hoisted: shtabc.s uses it
ED_LENMAX   equ   127
*-- shpfx.s: prefix assignments one stage can carry
PFX_MAX     equ   8
MAXTOK      equ   128        ;max tokens per line -- see err
                             ;below
            err   MAXTOK+MAXTOK-LINEMAX-1
MAXCMD      equ   3          ;max pipeline stages (N commands,
                             ;N-1 pipes)
*-- MAXARGV IS NOT A LIMIT ANY MORE -- it is the size of sh's
*-- own CMD_ARGV buffer. The authoritative check is the
*-- kernel's ARG_MAX byte budget (inc/memmap.equ), which
*-- counts the bytes of the child's argv block rather than its
*-- entries, and
*-- returns ERR_2BIG instead of silently staging a prefix
*-- (docs/LIMITS.md). sh reports that code at :spawnerr.
*-- Raised 16 -> 32 because 16 was the kernel's old entry count,
*-- and `echo *` in a directory of 20 short files is ~200 bytes:
*-- it was refused for being twenty, not for being large.
*-- CEILING: CMD_ARGV is indexed by an 8-bit X across all
*-- MAXCMD stages, so MAXCMD*(MAXARGV+1)*2 must stay <= 256 --
*-- 99 slots at MAXCMD=3. Past that the index needs widening,
*-- not the constant raising.
*-- The stage stride lives once, in STGOFF, computed by the
*-- assembler; it used to be open-coded as three `asl a` in
*-- three routines, which is why raising MAXARGV once assembled
*-- cleanly and then failed at runtime with $46 -- argv[0] read
*-- from the wrong offset.
MAXARGV     equ   32         ;CMD_ARGV slots per stage (incl.
                             ;argv[0]) -- buffer size, not a
                             ;policy limit
*-- ARGSLOTS: one stage's block is MAXARGV words PLUS a NULL
*-- terminator slot. Without it a stage whose argv is full
*-- (MAXARGV words) runs straight into the NEXT stage's argv[0],
*-- which is nonzero, so the child reads on into that stage's
*-- words (SH-DEFECTS 12). ZR_CMD_TABLES zeroes the slot.
ARGSLOTS    equ   MAXARGV+1
CMDARGVSIZE equ   MAXCMD*ARGSLOTS*2  ; total CMD_ARGV byte size
*-- The 8-bit-index ceiling, asserted not commented: this
*-- fires if MAXCMD or MAXARGV changes, so whoever changes
*-- one has to come back and re-read why 256 is the wall.
*-- (`err` flags a NONZERO expression, so an equality is the
*-- only shape available -- a tripwire, not a range check.)
            err   CMDARGVSIZE-198
*-- And the kernel's foreground-job set (SYS_TCSETFG, docs/
*-- JOB-CONTROL.md Increment A) holds TCSETFG_MAX pids: a
*-- pipeline is MAXCMD stages, and both must move together or a
*-- wider pipeline could never be declared whole. Same tripwire
*-- shape as the line above.
            err   TCSETFG_MAX-MAXCMD
CMDFILESIZE equ   MAXCMD*2           ;total
                                     ;CMD_INFILE/CMD_OUTFILE
                                     ;size

*-- CONSTANTS HOISTED FROM LATER-PUT MODULES (2026-08-29, S9
*-- step 5's EQU forward-reference burn-down): each of these
*-- was defined in the module that "owns" it but USED, as an
*-- immediate operand, by a module put EARLIER in this unit --
*-- which real Merlin-8 refuses ("Illegal forward reference")
*-- even though merlin32 resolves it. The owning module keeps
*-- its reasoning comment and a pointer here. Values unchanged:
*-- the hoist is byte-identical by construction, and the build
*-- was cmp'd to prove it.
EXPBUFLEN   equ   128        ;shexpand/shpath -- expansion buf
MAXDUPS     equ   6          ;shpath -- redirect records
NFDMAP      equ   8          ;shbltn/shpath -- CHILDMAP entries
SH_PTHFLL_LEN equ MLI_PTH_MAXLN+1 ;shpath -- resolved-path buf
SH_CMDMAX   equ   32         ;shpath -- command-word buffer
MAXGLOB     equ   MAXARGV-1  ;shpath -- glob expansion cap
BRW_SKIP    equ   0          ;shsubst/shexpand -- EMITBRACE
BRW_EMIT    equ   1          ;  modes
BRW_COPY    equ   2
SUBPIPECAP  equ   250        ;shsubst -- $( ) capture cap
SUBMAX      equ   96         ;shsubst -- SUBTXT capacity
RESV_CNT    equ   14         ;shresv/shparse -- reserved words
                             ;(12 + `{`/`}` brace groups)
*-- FORWORDMAX 8 -> 16, 2026-09-15: any glob hit "sh: for: too
*-- many words" (docs/SH-FEATURES.md's console-loop spooling
*-- section). CSFORWORDS (below, `dum` arena -- FREE, no sh.bin
*-- bytes) is the only cost, MAXCDEPTH*FORWORDMAX*FORWORDLEN =
*-- 8*16*16 = 2048 B, well inside the arena's own headroom.
*-- FOR_ROWBASE's row-stride shift (shvar2.s) moves with it --
*-- still a power of 2 (256 = 2^8), so 8 shifts replace 7.
FORWORDMAX  equ   16         ;shbltn/shvar -- `for` word list
CASEWLEN    equ   32         ;shbltn/shresv -- case-word width
FORWORDLEN  equ   16         ;shbltn/shvar -- `for` word width

*-- Tier 2 variable-table sizing (docs/SH-FEATURES.md sec 4):
*-- defined here, ahead of everything that sizes storage off
*-- them (VNBUF below, VARNAMES/VARVALS further down), the same
*-- discipline MAXCDEPTH's own placement follows -- a `ds` needs
*-- the number in PASS 1, so the equ must sit before its first
*-- use, not just before its "logical" section.
VARNAMELEN  equ   15         ;max variable name length (excl.
                             ;NUL) -- generous for anything an
                             ;identifier-shaped $NAME can spell
VARVALLEN   equ   31         ;max value length (excl. NUL)
*-- BGMAX -- job-table rows (shjob.s, docs/JOB-CONTROL.md
*-- Increment C; before that the BG_PIDS reap list `wait`
*-- drained). Set to the BANK CEILING (docs/PLAN.md: a 1MB
*-- RamWorks III is 14 processes, and PRC_FREE_LIST's 16 bytes
*-- are "the right size", not a limitation to grow past): every
*-- live row holds at least one bank, so the table genuinely
*-- cannot fill before the machine does. A Done row holds none,
*-- but JOB_DRAIN frees those before every line.
*--
*-- CORRECTED 2026-08-24. This was 8, under a comment saying a
*-- table this size "cannot fill before the machine does" --
*-- a non-sequitur: 8 is LESS than 14, so the table fills six
*-- processes BEFORE the machine does. Past BGMAX BG_RECORD
*-- dropped the pid, so those six children were never reaped by
*-- `wait` and their banks leaked; a shell backgrounding more
*-- than eight jobs poisoned the pool for all that follow. The
*-- premise was right and the number contradicted it.
*--
*-- Costs nothing: the table lives in the `dum LIBA_BSSEND`
*-- arena below, so this moves an address, not a byte of sh.bin.
BGMAX       equ   14
*-- JOB_PID's size, zeroed with the rest of the table at entry
*-- (RULINGS-1: a respawn that lands in a dead shell's slot
*-- adopts its children, and a stale pid here made JOB_REAP
*-- print a `Done` notice for one under the old job's text).
JOBPIDSZ    equ   BGMAX*MAXCMD
*-- PARSE_SEPOP's value for `&` (1 is `;`, 2 `&&`, 3 `||`).
SEP_BG      equ   4
*-- `;;` ends a `case` branch. A SEPARATOR like `;` and not a
*-- reserved word, because a reserved word only ever matches at
*-- argv[0]: `ECHO A ;;` would hand `;;` to echo as an argument
*-- and print it, silently, which is the shape every other
*-- quiet-wrong-answer ruling in this file refuses.
SEP_DSEMI   equ   5
*-- SH-CASE2 B: a segment whose single word is a case PATTERN
*-- and
*-- whose terminating `)` PAT_SPLIT has already consumed. Runs
*-- like `;` (NEXT_SKIP); CS_CASEPAT trusts it instead of a
*-- trailing `)`.
SEP_PAT     equ   6
*-- Tracked-command cache slots (the cache itself is in the
*-- arena, near SH_CMDWORD). The equ lives HERE because
*-- shpath.s -- put earlier than the arena section -- uses it in
*-- an immediate operand, and real Merlin-8 refuses an equ
*-- forward reference (check-modules counts these).
SH_HASHN    equ   4
MAXVARS     equ   8          ;max distinct variables -- a slot's
                             ;name byte 0 == 0 means free, so no
                             ;separate "in use" flag is needed
                             ;(VARFIND/VARSET's own header)
*-- merlin32's `ds` operand parser rejects parenthesised
*-- expressions ("Impossible to decode Data format", measured --
*-- `ds MAXVARS*(VARNAMELEN+1)` fails, `ds MAXVARS*VARNAMESZ`
*-- does not), so the per-slot stride is its own named constant,
*-- same shape CMDARGVSIZE already uses for MAXCMD*MAXARGV*2.
VARNAMESZ   equ   VARNAMELEN+1
IFSSETMAX   equ   16         ;IFS separator-set copy (IFSSET in
                             ;the arena): 15 separator chars +
                             ;NUL. IFS_RESOLVE truncates a
                             ;longer $IFS value here -- 15
                             ;distinct separators is already
                             ;beyond any real script
VARVALSZ    equ   VARVALLEN+1
*-- Environment staging sizes (docs/SYSCALL.md item 13c), here
*-- for the same PASS-1 reason the two strides above are: a `ds`
*-- needs the number before it is reached. One slot's worst
*-- case is NAME + '=' + VALUE + NUL, and VARNAMESZ/VARVALSZ
*-- already carry the two NULs that '=' and the terminator take
*-- the place of -- so the sum is exact, not padded.
ENVSLOTSZ   equ   VARNAMESZ+VARVALSZ
*-- PATH_SRC's expansion buffer -- see that routine's own
*-- sizing note (a 31-character value can become at most 64
*-- bytes of NUL-separated, slash-terminated entries).
SH_PSRCSZ   equ   96

*---------------------------------------------------------------
* Entry: spawn() JMPs to the first byte of the loaded image
* (ratified, docs/SYSCALL.md ruling 11 -- no SEI/stack setup
* needed here). Tier 2 (docs/SH-FEATURES.md sec 4) wires sh's
* OWN argv to positional parameters: $0 is GETARG(0) (whatever
* the caller passed as argv[0] -- v1 has no separate "open the
* script and re-exec" step, so this is simply the spawn-time
* argv[0], not a resolved script path), $1-$9 are
* GETARG(1+POS_SHIFT) through GETARG(9+POS_SHIFT), $# is
* ARGC-1-POS_SHIFT. No flags (`-x` etc, Tier 3) are read from
* argv -- every byte of it is positional-parameter text.
*---------------------------------------------------------------
*---------------------------------------------------------------
* -- The body lives in the eight put modules below, split so
* -- this unit fits real Merlin-8's 41,215-byte source buffer
* -- (scripts/check_dialect.py budget 3): the resident manifest
* -- plus its largest single put must fit, and one 190KB file
* -- did not. Same put-module precedent as sed.s/sedexec.s; one
* -- assembly unit either way. They stand HERE, in the manifest,
* -- because Merlin cannot nest a put inside a put file -- which
* -- is also why the liba puts below stay at top level.
*---------------------------------------------------------------
*-- THE ALIAS TABLE (docs/SH-ALIAS-NOTES.md): eight slots, moved
*-- by SH-ROOM out of the LC common region into the dead copy of
*-- the segments (the dead-copy block near the end of this
*-- file), where it emits nothing and costs the window nothing.
*-- Only this CPU reads it, so no syscall is ever handed one of
*-- its addresses. NOT zero at start, and not a cell the loader
*-- supplies on a warm respawn either: ALI_INIT (shsgali.s)
*-- empties it from START. READ-AFTER-PUBLICATION: ALI_INIT
*-- clears each slot's first name byte and ALI_END, NOT
*-- ALI_VALS, and every reader goes through an occupied name
*-- byte (docs/SH-ROOM-NOTES.md sec 4 proves it per reader).
*-- Names 16 B (15 + NUL), values 32 B (31 + NUL), ALI_END = the
*-- expander's per-alias end offsets.
*-- High-bit character constants for shsgali.s (check-encoding
*-- counts bare printable high-bit immediates; named, they are
*-- constants like MLI_OPEN, not text).
ALC_A0     equ   $A0
ALC_A2     equ   $A2
ALC_A4     equ   $A4
ALC_A7     equ   $A7
ALC_A8     equ   $A8
ALC_A9     equ   $A9
ALC_AF     equ   $AF
ALC_B0     equ   $B0
ALC_BA     equ   $BA
ALC_BD     equ   $BD
ALC_C1     equ   $C1
ALC_DB     equ   $DB
ALC_DC     equ   $DC
ALC_DF     equ   $DF
ALC_E1     equ   $E1
ALC_FB     equ   $FB
ALC_FC     equ   $FC
            put   shlex.s
            put   shlex2.s
            put   shrlog.s
            put   shtok.s
            put   shcls.s
            put   shexpand.s
            put   shexp2.s
            put   shsubst.s
            put   shsub2.s
            put   shparse.s
            put   shresv.s
            put   shrsv2.s
            put   shvar.s
            put   shvar2.s
            put   shbltn.s
            put   shblt2.s
            put   shpath.s
            put   shpth2.s
            put   shtrap.s
            put   shjob.s
            put   shblt3.s
            put   shalias.s
            put   shtabc2.s
            put   shpfx.s
*-- TEST_EVAL (docs/SH-SUBSET.md sec 6.3: `test` MUST be a
*-- builtin here, not a binary). Its CODE runs from the $D000
*-- segment below (testeval.s, KFIX3 item 0); its cells and the
*-- parm block it hands to SC_GFI are in the arena (the
*-- "TEST_EVAL cells" below), because a syscall is never
*-- handed an address >= $D000.
            put   ../liba/glob.s
            put   ../liba/readsyn.s ;`/`, `/dev`, `/mnt` -- the
                                     ;kernel's own directories
            put   ../liba/readsys.s
            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/cmdpath.s ;CMDSLASH -- `./x`, `dir/x`
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/syssleep.s ;SC_SLPUNTIL -- shsgrw.s's
                                     ;one-tick wait
            put   ../liba/seek.s
            put   ../liba/creat.s
            put   ../liba/num.s   ;U2DEC -- $? decimal
            put   ../liba/pathtab.s   ;PATHTAB -- the default
                                     ;search path, shared
            put   ../liba/argv.s  ;GETARG -- Tier 2 positional
*-- ENVNTH -- ENV_IMPORT reads the environment the kernel
*-- staged. sh did NOT link this module before 2026-08-25,
*-- which is the mechanical form of the write-only bug: the
*-- read side of the environment was not in the binary.
            put   ../liba/env.s
                                 ;parameters
*---------------------------------------------------------------
* THE SECOND CODE SEGMENT (operator ruling 2026-09-16, docs/
* SH-SUBSET.md ruling 7.6 -- "segment, not overlay").
*
* Everything above this line is the LOW RESIDENT IMAGE: the
* parser, the expander, the spawn path, the prompt loop, and
* every string/parmlist/buffer the shell hands to a syscall.
* Everything between SH_SEG_BEG and SH_SEG_END is CODE that
* runs from the process language card's COMMON region,
* PRC_LC_COMMON = $E000 (inc/mm.procbnk2.equ, 7936 B,
* which the shell used none of).  SEG_INIT -- the first thing
* START does -- copies it there; see src/bin/shsegi.s for the
* bracket and for why the low copy has to survive.
*
* THE THREE `org`s, and why the third one matters most.
* merlin32 lays a mid-file `org` block down CONTIGUOUSLY in the
* flat output (measured 2026-09-16), so the segment's bytes are
* simply the tail of sh.bin and the spawn loader's single copy
* puts them at SH_SEG_LOW.  The third `org` then winds the PC
* back to the byte AFTER that low copy, which is where
* libabss.s's `dum *` anchors the whole bss arena -- so bss
* starts above the low copy instead of on top of it, and the
* copy is still intact on a WARM respawn (docs/STICKY.md sec
* 25), where the kernel reloads nothing at all.  Get that `org`
* wrong and every COLD gate stays green while check-shwarm goes
* red; that is the teeth this ruling was gated with.
*
* The arithmetic is backward references only (SH_SEG_LOW and
* both segment bounds are already defined where it is used) and
* has no parentheses -- merlin32 evaluates strictly left to
* right (learning:01M051DJW89KV4JYM1EC9SDZ5Y), and
* SH_SEG_LOW+SH_SEG_END-SH_SEG_BEG is correct read that way.
*
* LOAD_BASE+imagelen is unchanged by all this (the file is the
* same length it would have been), so the kernel's zeroed page
* (src/kernel/bankcopy.s BC_ZPAGE) still lands exactly on
* LIBA_ZPG, which is what check_purity.py asserts.
*---------------------------------------------------------------
            put   ../../inc/mm.hw.equ
            put   shsegi.s
SH_SEG_LOW
            org   PRC_LC_COMMON
SH_SEG_BEG
            put   shsgtrp.s
            put   shsggop.s
            put   shsgjob.s
            put   shsgblt.s
            put   shsgbl2.s
            put   shsgali.s
            put   shtabc.s
            put   shsgrw.s
            put   shsgmlq.s
SH_SEG_END
*-- THE DOOR: the $FFxx page is the kernel's one claim in a
*-- process bank.  Same `err` idiom as the arena tripwire at the
*-- bottom of this file -- the division is 0 while the segment
*-- fits and 1 the moment it does not.  Spelled FFXX_PAGE, the
*-- name inc/mm.procbnk2.equ already gives that address
*-- and this file already puts, rather than a second literal
*-- drifting from the kernel's -- which is also what keeps the
*-- Makefile's choke-point gate (check-userland: "only src/liba
*-- mentions $FF00") measuring syscall doors instead of
*-- assembly-time tripwires.
            err   */SH_SEG1_LIM
*-- THE SECOND SEGMENT (KFIX3 item 0): the language card's $D000
*-- bank, the one $C08B maps -- the steady state every process
*-- runs in, which liba stdio brackets away from and back to and
*-- the kernel restores (K_LCBANK) across a tick. stdio's own
*-- buffers are the OTHER bank ($C083), so $D000-$DFFF here is
*-- free, 4 KB, and CODE in it executes. The rules of the first
*-- segment hold unchanged, plus one: a routine here must never
*-- select $C083 itself (it would unmap itself); calling low
*-- code that brackets and restores $C08B is fine.
*-- The wind-back `org` below only names where its bytes sit in
*-- the flat file (SH_SEG2_SRC, behind the first segment's);
*-- an `equ` could not, SEG_INIT being a forward reference.
            org   SH_SEG_LOW+SH_SEG_END-SH_SEG_BEG
SH_SEG2_SRC
            org   PRC_LC_BANK2
SH_SEG2_BEG
            put   testeval.s
            put   shsgglb.s
            put   shsgsig.s
            put   shedit.s
            put   shedit2.s
            put   shsgcld.s
SH_SEG2_END
            err   */SH_SEG2_LIM
            org   SH_SEG2_SRC+SH_SEG2_END-SH_SEG2_BEG
SH_FILE_END
SH_FILE_ENDP1 equ SH_FILE_END+1
            put   ../liba/libabss.s

*---------------------------------------------------------------
* Reclaimed arenas (2026-08-21). merlin32's `ds` reserves AND
* EMITS the reserved bytes into the object file as zeros -- see
* learning:01M0FNC75R7YSFRNS328WHXMHN (ed.s/sort.s's own
* conversion, deposited to the vintage-apple street-library
* collection). `dum`/`dend` computes label addresses relative to
* the real PC at the point `dum` opens, without emitting
* anything, but `dend` restores that SAME real PC -- so this
* block MUST stay the textually LAST thing in the file, after
* every `put` above: anything emitted after `dend` would resume
* at the address this block just handed out and silently collide
* with it.
*
* `dum` memory is NOT zeroed -- it is whatever was already in
* the bank. Every arena below was individually traced for read-
* before-write safety at its OLD declaration site (see the
* comment left behind there) before being moved here; none of
* them depend on being zero at process startup.
*
* CORRECTED 2026-08-27. This paragraph used to say the variable
* table was "DELIBERATELY LEFT AS `ds`" because VARNAMES must be
* zero at startup. That was written BEFORE SH_INIT_ZR existed
* (docs/STICKY.md sec 32's warm-respawn fix), which now zeroes
* VARNAMES and VAREXP by name at every entry -- so the emitted
* zeros became redundant the day that landed, and nobody came
* back here. VARNAMES/VAREXP/VARVALS/EXPBUF are ALL in this
* arena now, 520 bytes off sh.bin. Two classes live here, not
* one: WRITE-BEFORE-READ (everything else) and ZEROED-AT-ENTRY
* (VARNAMES/VAREXP). The historical note continues -- no
* longer load-bearing (this task fixed the terminator-drop at
* its root: EMITB now clamps at EXPBUFLEN-1, reserving the
* pool's last slot, and DOEXPAND's :term writes its closing NUL
* directly into that guaranteed-free slot rather than through
* EMITB's own clamp a second time -- see both routines' own
* comments. A pool that fills content to the reservation
* boundary can no longer drop the terminator, under EITHER `ds`
* or `dum` -- but EXPBUF is left as `ds` anyway rather than
* moved, since there is no reason to disturb it now that the
* bug it was masking is fixed at the
* source.
*
* No zeroing loop is added for anything below: CMD_ARGV/
* CMD_INFILE/CMD_OUTFILE are unconditionally zeroed in full by
* ZR_CMD_TABLES before every segment's PARSE (the strongest
* evidence class here -- not merely written-before-read but
* reset every single time regardless of what a previous segment
* left behind); every other arena below is a pure write-then-
* read structure (a monotonic bump allocator, an in-place
* squeeze that never writes ahead of its own read cursor, or a
* flat buffer whose writer always lays down its own terminator,
* including at its length-cap boundary) whose readers are
* bounded by a count the very same writer just published.
*
* Tier 3 additions (docs/SH-FEATURES.md sec 4/6), traced the
* same way: HD_BODY is written ONLY through HD_APPENDB, a
* monotonic
* bump allocator (HDCUR reset to 0 at CPTR_HEREDOC's own
* start, same shape EXPBUF's own EMITB uses) -- RUN_PIPELINE's
* HD_WRITE_BODY then reads back EXACTLY HD_LEN bytes, the count
* HD_APPENDB's own caller just published, never more. It carries
* none of EXPBUF's NUL-terminator edge case: HD_WRITE_BODY is a
* raw byte-count SC_WRITE, not a NUL-scan, so a body that fills
* HD_BODY exactly still writes correctly, no terminator needed.
* HDLINEBUF is CPTR_HEREDOC's own per-line scratch -- every
* byte 0..HDLLEN-1 is written before :haveline NUL-terminates it
* and any reader (the tab-skip scan, the STRCMP against HD_WPTR,
* the append loop) ever looks at it, exactly LINEBUF's own
* precedent above.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
*-- TEST_EVAL's cells (testeval.s) -- the same list as the
*-- standalone harness's (src/test/testevtest.s). All are
*-- written before they are read within one call (EVAL_UNARY
*-- stores the GFI count and path pointer itself). The three
*-- cells testeval.s once aliased (CM_FLAGS, CM_TMPLO, TE_NEG)
*-- are cells of their own here: a bare label has no `ds` for
*-- the native bss module to turn into a symbol (3 B).
TE_ARGC     ds    1
TE_AVBASE   ds    2
TE_POS      ds    1
TE_OPCODE   ds    1
CM_FLAGS    ds    1
TE_TMPA     ds    1
TE_LTOK     ds    2
TE_RTOK     ds    2
TE_LVAL     ds    2
TE_RVAL     ds    2
TE_VAL      ds    2
CM_TMPLO    ds    1
TE_V2       ds    1
CM_TMPHI    ds    1
TE_NEG      ds    1
TE_REL      ds    1
TE_GFI      ds    1
TE_GFI_PATH ds    2
TE_GFI_ACC  ds    1
TE_GFI_FTYP ds    1
TE_GFI_AUX  ds    2
TE_GFI_STYP ds    1
TE_GFI_BLKS ds    2
TE_GFI_MDT  ds    2
TE_GFI_MTM  ds    2
TE_GFI_CDT  ds    2
TE_GFI_CTM  ds    2
TE_PATHBUF  ds    65
*-- ENV_IMPORT's cursor and its name-splitting scratch. In the
*-- ARENA and not `ds`, because both are write-before-read
*-- within one call chain: ENV_IMPORT opens `stz ENVIMPI`, and
*-- every ENVIMPNM byte VARSET later reads is one ENV_IMP1's
*-- own scan just wrote, NUL included. Declared as `ds` first
*-- and caught immediately by check-modules -- 775 bytes of
*-- emitted `ds` allowed, 792 found, which is these 17 exactly.
ENVIMPI     ds    1
ENVIMPNM    ds    VARNAMESZ
*---------------------------------------------------------------
* 2026-08-22 (docs/STICKY.md sec 28): the command-table and glob
* groups joined this arena -- 133 bytes that were emitted zeros.
*
* WHY sh IS THE EXCEPTION TO SEC 21'S "ZERO-DEPENDENCE IS RARE".
* Every other program in src/bin is a one-shot: it runs, it
* exits, and every cell it reads was written earlier in that
* same run. sh is a REPL, and the question for a REPL is
* narrower and harder -- is this cell read on the FIRST pass,
* before anything has run to set it? For SEVEN cells the answer
* is yes, and they STAY EMITTED as real zeros:
*
*   CSPTR       the construct-stack depth. CS_EFFSKIP does
*               `cpx CSPTR` on the first non-empty command line
*               and nothing ever initialises it -- only inc/dec.
*   LASTSTATUS  `$?` on the first line reads it.
*   POS_SHIFT   `$1`/`$#` on the first line read it; the only
*               write in the whole file is an `inc`, never a
*               plain store.
*   SCAN_ACT    CR_STARTSCAN reads it before any scan has run.
*   PCR_PEND    CR_INSTALL reads it before the `stz` two lines
*               below.
*   VARNAMES    128 B. THE FILE'S MOST LOAD-BEARING ZERO: there
*               is no variable counter -- MAXVARS slots are
*               scanned unconditionally and "free" IS a zero
*               name byte. The first $VAR, VAR=x, for, read or
*               export reads all eight names.
*   VAREXP      8 B. ENV_STAGE walks the WHOLE array regardless
*               of slot occupancy; a garbage byte exports a
*               variable nobody marked.
*
* VARVALS (256 B) also stays: it is technically write-before-
* read, but its correctness is entirely parasitic on VARNAMES
* being zero and the two are a pair.
*
* CSHEAD, CSRKIND/CSRFD/CSRTGT and PCR_KIND/PCR_FD/PCR_TGT stay
* too, on their own declarations' stated reasoning -- CR_FIND
* walks frames it did not push. That claim was re-examined this
* pass and NOT overturned; where a file says "deliberately
* emitted" and the payoff is tens of bytes, the declaration
* wins.
*
* Trace for what DID move:
*  - CMD_ARGC/CMD_APPEND/CMD_PID: ZR_CMD_TABLES clears every
*    slot to MAXCMD, and MAINLOOP calls it before PARSE on
*    every segment. The strongest evidence class in the file.
*  - CMD_TGTFD: same loop, but it writes FD_STDOUT, not zero --
*    so this one was never relying on the emitted zeros at all;
*    it was relying on the loop, which is exactly what makes it
*    safe here.
*  - CHILDMAP: BLD_FDCTS_STG writes the full identity
*    permutation at the top of every call. Also a nonzero fill.
*  - STAGEI: `stz` at RUN_PIPELINE's :pipesdone.
*  - CMD_INFD/CMD_OUTFD/FDAIDX: `stz` as BLD_FDCTS_STG's first
*    three instructions, per stage.
*  - FDABUF: a bump allocator at FDAIDX; EMIT_END lays the
*    FDACT_END terminator and the kernel's walk stops on it.
*  - FDATMP2: `sta` immediately before `lda`, every use.
*  - DUP_STG/DUP_TGT/DUP_SRC/DUP_POS: written at index DUPN
*    BEFORE `inc DUPN`, and DUPN is the only bound any reader
*    uses -- ZR_CMD_TABLES clears it per segment.
*  - DUPN/DUPI/DUPWANT/DUPTGT/DUPSRC: each stored at the head
*    of the routine that reads it.
*  - NPIPES: RUN_PIPELINE's first four instructions compute it
*    from NCMD. On pipe failure it is lowered to PIPEI and
*    RUN_PIPELINE returns, so no stage runs.
*  - PIPEI: `stz` at RUN_PIPELINE and again at CLS_ALL_PIPES.
*  - PIPETMP/WJSTAT/PSBUF: SC_PIPE's, SC_WAITJOB's and
*    SC_PSTAT's own output buffers -- the kernel writes them
*    before they are read.
*  - PIPE_RFD/PIPE_WFD: written at index PIPEI before
*    `inc PIPEI`; readers are bounded by NPIPES.
*  - the glob group: per-word or per-routine scratch, each
*    written at its routine's head -- GWORD/GLOBN by
*    GLOB_APPEND, GSLASH/GPREFLN/GPATOFF on BOTH branches of
*    the has-a-directory test, GENTLEN/GEPB/GFCNT/GACT in one
*    contiguous init block before the entry loop,
*    GNLEN/GCLO/GCHI in GLOB_NAME's first six instructions
*    (both the flags-present and no-flags branches write the
*    pair), and GNAME with its own NUL laid at :nend before
*    STRMATCH or GLOB_KEEP scans it -- GNLEN is masked to
*    #$0F so the terminator always fits the 16 bytes.
*---------------------------------------------------------------
CMD_ARGC    ds    MAXCMD
CMD_APPEND  ds    MAXCMD              ;1 = this stage's `>` was
                                      ;`>>` (docs/FLEET.md)
CMD_TGTFD
            ds    MAXCMD              ;this stage's output-
                                      ;redirect TARGET fd --
                                      ;FD_STDOUT unless a `2>`/
                                      ;`N>`/`N>>` set it;
                                      ;ZR_CMD_TABLES defaults
                                      ;every slot, SET_OUT
                                      ;overrides one
CMD_PID     ds    MAXCMD
*-- SYS_TCSETFG's parm block {count, pid0..pid2} (docs/JOB-
*-- CONTROL.md Increment A) -- FG_SETX (shbltn.s) writes all
*-- four before the call, every time. The kernel's set is sized
*-- TCSETFG_MAX; a pipeline is MAXCMD stages, and the two must
*-- agree or a 4-stage job could never be declared whole.
FG_PARM     ds    TCSETFG_MAX+1

STAGEI      ds    1
CMD_INFD    ds    1
CMD_OUTFD   ds    1
FDAIDX      ds    1
TGTSET      ds    1         ;bit N: child fd N was a dup TARGET
                                ;  this stage (shblt2.s)
USERFDS     ds    1         ;bit N (3-7): fd N is the USER's
                        ;  (an `exec` opened it, or the
                        ;  shell started with it); every
                        ;  child is granted it, shblt2.s
UFDK        ds    1         ;SH_INIT_ZR's probe cursor
SH_SP0      ds    1         ;S at the first MAINLOOP entry
FDABUF      ds    FDABUFSZ
FDATMP2     ds    1

DUP_STG     ds    MAXDUPS   ;which pipeline stage owns this one
DUP_TGT     ds    MAXDUPS   ;target fd (0-7)
DUP_SRC     ds    MAXDUPS   ;source fd (0-7), $FF = close, or a
                            ;FILE: $FE `>`, $FD `>>` (DUP_PTR)
DUP_POS     ds    MAXDUPS   ;0 = before this stage's file
                            ;redirect, 1 = after it
DUP_PTRL    ds    MAXDUPS   ;a FILE record's target name
DUP_PTRH    ds    MAXDUPS
XOUTN       ds    1         ;parent fds a stage's FILE records
XOUTFD      ds    MAXDUPS   ;  opened, closed after its spawn
OUTTGT      ds    1         ;SET_OUT's target fd and append flag
OUTAP       ds    1
DUPN        ds    1         ;records used this segment
DUPI        ds    1         ;EMIT_DUPS' own walk cursor
DUPWANT     ds    1         ;EMIT_DUPS' wanted DUP_POS value
DUPTGT      ds    1         ;EMIT_DUPS scratch: target fd held
DUPSRC      ds    1         ;EMIT_DUPS scratch: resolved PARENT
                            ;source fd held
DCHELD      ds    1         ;DUP_CHECK: bit N = child fd N held
CHILDMAP    ds    NFDMAP

NPIPES      ds    1
PIPEI       ds    1
PIPETMP     ds    2
PIPE_RFD    ds    MAXCMD-1
PIPE_WFD    ds    MAXCMD-1

*-- The job table (shjob.s, docs/JOB-CONTROL.md Increment C),
*-- BG_PIDS/BG_CNT's successor. JOB_ST through JOB_QUIET are
*-- ZEROED-AT-ENTRY by SH_INIT_ZR, as one run (JOB_PID's last
*-- byte included) -- keep them contiguous -- and they MUST be:
*-- lazy free hands a second
*-- `sh` the first one's text, and a stale row would make `wait`
*-- reap children this shell never had (BG_CNT's own rule). The
*-- rest is write-before-read: JOB_ALLOC writes a row's tail,
*-- status and text before anything reads them, JOB_SETPIDS its
*-- pids; WJSTAT/PSBUF are kernel output buffers; the J* cells
*-- are each routine's own scratch, stored before read.
JOB_ST      ds    BGMAX
JOB_CUR     ds    1
JOB_PREV    ds    1
JOB_FG      ds    1
JOB_QUIET   ds    1
JOB_PID     ds    BGMAX*MAXCMD
JOB_TAIL    ds    BGMAX
JOB_EXST    ds    BGMAX
JOB_TXT     ds    BGMAX*JOBTXTLEN
WJSTAT      ds    2
PSBUF       ds    6
JOB_FD      ds    1
JOB_X       ds    1
JTMP        ds    1
JTMP2       ds    1
JTMP3       ds    1
JTMP4       ds    1
*-- KILL_SPECS's cells (shjob.s, `kill %n`): KS_BUF holds the
*-- decimal pid text the rewritten argv slots point at: at most
*-- one 4-byte "NNN\0" per slot, and the slot count is capped at
*-- MAXARGV by the same check APPEND_ARGV makes, so it cannot
*-- overflow. WT_ROW is `wait %n`'s row+1 (0 = every job). All
*-- write-before-read, like the J* cells above.
KS_BUF      ds    MAXARGV*4
KS_BUFN     ds    1
KS_X        ds    1
KS_Y        ds    1
KS_N        ds    1
KS_M        ds    1
WT_ROW      ds    1
JTX_N       ds    1
JTX_A       ds    1

GWORD       ds    2
GSLASH      ds    1
GPREFLN     ds    1
GPATOFF     ds    1
GLOBN       ds    1
GEMIT       ds    1
GSLOT       ds    1
GDFD        ds    1
GENTLEN     ds    1
GEPB        ds    1
GBLKENT     ds    1
GFCNT       ds    2
GACT        ds    2
GNLEN       ds    1
GCLO        ds    1
GCHI        ds    1
GSI         ds    1
GSJ         ds    1
GSA         ds    1
GSB         ds    1
GSTMP       ds    1
*-- GREC: the readdir.s record RD_READSYN fills for a synthetic
*-- directory. Its RD_NAME field IS the name GLOB_NAME builds
*-- for an ordinary entry (high-bit, case-decoded, NUL-ended),
*-- so the two walks share GNAME, the matcher and GLOB_KEEP.
*-- The `err`s after the arena hold RD_NAME == 1 and
*-- RD_SIZE == 32 to this layout.
GREC        ds    1
GNAME       ds    31

CD_PATHBUF  ds    65
*-- CSFORWORDS: below the arena (see "TRAPTAB and CSFORWORDS").
*-- `case`'s saved word, one per frame (docs/SHELL-GAPS.md sec
*-- 4). Copied rather than pointed at because LINEBUF is
*-- overwritten by the next line read and a `case` is open
*-- across lines by construction. 32 bytes: longer than
*-- FORWORDLEN's 16 because a case word is routinely a PATH,
*-- where a `for` word is routinely a name. Over-long is a loud
*-- failure (RW_CASELONG), never a truncation -- a silently
*-- shortened word would match the wrong branch.
CSCASEW     ds    MAXCDEPTH*CASEWLEN
*-- CS_CASEMATCH scratch. All three are written before read on
*-- every call: CASEWP from CS_CASEWPTR at entry, and the two
*-- CASEALT cells on the path that sets a temporary terminator
*-- (CASEALTY is set to $FF first on the path that does not).
CASEWP      ds    2
CASEALTY    ds    1
CASEALTC    ds    1
SH_TPATHBUF ds    66
SH_CMDWORD  ds    SH_CMDMAX
*-- Tracked-command cache (the POSIX `hash` shape, 2026-08-29):
*-- a bare word that resolved through PATH keeps its resolved
*-- absolute path, so a 208-spawn strip pays BUILD_PATH's
*-- OPEN+CLOSE probe (per PATH prefix! the default table's
*-- /bin/ prefix does not even exist on the strip volume)
*-- once per DISTINCT command instead of once per spawn --
*-- measured as most of the volume-directory block reads left
*-- after the bucketing round. Slot valid iff its cmd byte 0 is
*-- nonzero; SH_INIT_ZR zeroes the heads and SH_HNEXT at START,
*-- and SH_HFLUSH (shpath.s) re-zeroes them on ANY VARSET,
*-- because PATH is just a variable. Stale-after-delete behaves
*-- exactly like POSIX hash: the spawn fails until re-set.
SH_HC0      ds    SH_CMDMAX
SH_HC1      ds    SH_CMDMAX
SH_HC2      ds    SH_CMDMAX
SH_HC3      ds    SH_CMDMAX
SH_HP0      ds    SH_PTHFLL_LEN
SH_HP1      ds    SH_PTHFLL_LEN
SH_HP2      ds    SH_PTHFLL_LEN
SH_HP3      ds    SH_PTHFLL_LEN
SH_HNEXT    ds    1
*-- LINEBUF: moved, see the dead-copy block
*-- TOKPTR: moved, see the dead-copy block
TOKQUOTE    ds    MAXTOK
*-- HDWORDQ: TOKENIZE's own `<<'WORD'`-was-quoted flag, one per
*-- token slot (docs/SH-FEATURES.md sec 6/12). Same access-
*-- pattern proof as TOKQUOTE's own comment above extends to
*-- cover this, with one addition: a :doquoted-produced token
*-- (byte 0 a quote mark) never writes its slot, but CLASSIFY
*-- can never reach the one read site (:hdword) for such a
*-- token either -- that requires byte 0 to be '<', which
*-- :doquoted's own token can never be -- so a stale slot is
*-- never read.
HDWORDQ     ds    MAXTOK
*-- SH-CASE2 B: TOKCP[i] = 1 + the offset, in token i's finished
*-- bytes, of its FIRST lexical `)` (0 = none). Built in CPOFF
*-- while
*-- a token is lexed and stored by :tokfinal; written for every
*-- word token before PARSE reads it, and cleared for the
*-- operator
*-- slots too (TOKENIZE :tokok/:bslot).
TOKCP       ds    MAXTOK
CPOFF       ds    1
CMD_ARGV    ds    2
* -- CMD_ARGV2: a REAL label at CMD_ARGV+2, not `CMD_ARGV+2`
* -- arithmetic -- an external REL high-byte fixup cannot carry
* -- out of a nonzero-low-byte addend (learning:
* -- 01M2PSVAFMJJQN1PMPVS0FPYZP: "any `>SYM+n` where SYM crosses
* -- a REL module boundary and `n & $FF != 0`" -- exactly the
* -- `#>CMD_ARGV+2` sites shparse.s uses to build argv[1..] as a
* -- pointer). Found via check-nas-librel (2026-09-30, docs/
* -- DEVFS-NOTES.md): SH byte mismatch, same signature as the
* -- learning's own CAL/MAKE/nulib2 instances. Splitting the
* -- `ds` changes no address and no byte count.
CMD_ARGV2   ds    CMDARGVSIZE-2
CMD_INFILE  ds    CMDFILESIZE
CMD_OUTFILE ds    CMDFILESIZE
SH_PATHFULL ds    SH_PTHFLL_LEN
SH_PATHBUF  ds    65
*-- SHEB_FIX's cells (shsgblt.s), all stored before read: SHEB_N
*-- and SHEB_RETRY at :stagego, the rest inside SHEB_FIX.
SH_ARG0     ds    1          ;argv index $0 is (shlex.s START)
SH_DASHS   ds    1          ;sh -s seen (shlex.s START)
SH_DASHC   ds    1          ;sh -c seen (shlex.s START)
SH_CMODE   ds    1          ;-c: 1 string pending, 2 it ran
OHI_FD     ds    1          ;OPEN_HI: the fd it was given
OHI_T      ds    1          ;OPEN_HI: the number being tried
SCRIDX      ds    1          ;START's option scan cursor
SHEB_N      ds    1
SHEB_RETRY  ds    1
SHEB_LEN    ds    1
SHEB_IY     ds    1
SHEB_AY     ds    1
SHEB_S2     ds    1
SHEB_ARGC   ds    1
GLOBIDX     ds    MAXGLOB
*-- GLOBTYP[slot]: the storage type of the match kept in
*-- GLOBBUF[slot] ($D directory, $F volume under /mnt, $A/$B
*-- device, ...). Written by GLOB_KEEP just before it publishes
*-- the slot via GLOBN; no reader yet (tab completion is first).
GLOBTYP     ds    MAXGLOB
*-- GLOBBUF: moved, see the dead-copy block
SH_GPATH    ds    65
*-- HD_BODY: moved, see the dead-copy block
*-- HDLINEBUF: moved, see the dead-copy block
*-- RAWLINE -- console-loop spooling (docs/SH-FEATURES.md,
*-- 2026-09-15): a pristine copy of LINEBUF, written whole by
*-- STRCPY at SH_RUNLINE's own entry (shlex.s), BEFORE
*-- STRIPCOMMENT/TOKENIZE mutate LINEBUF in place. Write-before-
*-- read, same class as everything else in this arena --
*-- SPOOL_ENTER never reads it except on a line already copied.
*-- RAWLINE: moved, see the dead-copy block
*-- STRPQST -- STRIPCOMMENT's own quote-span tracker (2026-09-
*-- 15, docs/SH-FEATURES.md sec 22): 0 outside a quote, else the
*-- byte that closes the one currently open ($A7/$A2), same
*-- shape and same name pattern as shtrap.s's SPOOL_QST. Zeroed
*-- at STRIPCOMMENT's own entry, so a stale span from the
*-- PREVIOUS line can never leak into this one.
STRPQST     ds    1
*-- ECHONFL -- CHCK_BLTN_ECH's (shbltn.s) -n flag, 2026-09-15.
*-- Lives here rather than beside ECHOI/ECHOFD (shsub2.s) so it
*-- costs no BIN_DEBT -- sec 21's arena, not one more byte on
*-- the grandfathered pile check_purity.BIN_DEBT already covers.
ECHONFL     ds    1
*-- SUBTXT/SUBARGV: command substitution's own capture text and
*-- argv array (CMDSUBST/SUB_GRAB/SUB_RUN). Traced the same way
*-- as everything above. SUBTXT: SUB_GRAB writes bytes
*-- 0..SUBTLEN-1 and then lays its OWN NUL down at SUBTLEN --
*-- including at the SUBMAX-1 truncation boundary, which is
*-- exactly the "writer always lays down its own terminator,
*-- including at its length-cap boundary" class this block's
*-- header names -- before SUB_RUN reads a single byte back.
*-- SUBARGV: SUB_RUN writes slot SUBNARG before incrementing
*-- past it and then writes the NUL POINTER at slot SUBNARG
*-- itself, so both readers (SUB_RUN's own argv[0] load and the
*-- kernel's argv walk, which stops on that NUL pointer and
*-- never trusts a count) are bounded by what the same writer
*-- just published. It is sized SUBARGMAX+1 slots so the
*-- terminator has somewhere to go even when the word cap is
*-- reached exactly.
SUBTXT      ds    SUBMAX
SUBARGV     ds    SUBARGMAX*2+2
*-- VARVALS -- the variable table's VALUES, moved here from
*-- emitted `ds` 2026-08-27 (256 bytes off sh.bin). Traced to
*-- this block's own write-before-read rule: the ONLY reader is
*-- VSLOT_VAL, every caller of which has already established
*-- that the slot is occupied by testing VARNAMES's name byte,
*-- and the only writer -- VARSET -- STRCPYs the NAME and then
*-- the VALUE for the same slot index before returning. So a
*-- slot's value is written strictly between "this slot became
*-- occupied" and any read of it. A slot that was never occupied
*-- is never read. SH_INIT_ZR's omission of VARVALS is the
*-- pre-existing evidence that this was always true.
VARVALS     ds    MAXVARS*VARVALSZ
*-- VARNAMES/VAREXP -- the rest of the variable table. These DO
*-- need to start zero, and SH_INIT_ZR is what establishes it,
*-- by name, at every entry. Unlike everything else in this
*-- arena they are NOT write-before-read -- they are
*-- zeroed-at-entry, which is the second sanctioned class here.
VARNAMES    ds    MAXVARS*VARNAMESZ
VAREXP      ds    MAXVARS
*-- VARRO -- the `readonly` bit, one byte per slot (docs/
*-- SH-FEATURES.md sec 29). IMMEDIATELY AFTER VAREXP ON PURPOSE:
*-- SH_INIT_ZR clears both in ONE run with a single
*-- `cpx #MAXVARS+MAXVARS`, the same "one contiguous run (sh.s's
*-- arena says so)" trick the job table's own zeroing already
*-- uses. Do not separate them without fixing that loop.
*--
*-- It needs the zero for exactly VAREXP's reason and a worse
*-- consequence: lazy free hands the next `sh` this one's bss,
*-- and a stale byte here would make a variable nobody protected
*-- refuse every assignment AND every `unset`, with no way left
*-- in the language to clear it.
VARRO       ds    MAXVARS
*-- VARROFAIL -- VARSET's refusal REASON, read by PR_VARFULL
*-- (shsgblt.s) to pick between "variable table full" and
*-- "read-only variable". Write-before-read: VARSET stores it on
*-- every call, before any branch that can reach the printer.
VARROFAIL   ds    1
*-- `times` (shsgblt.s): the SYS_TICK output buffer -- a SYSCALL
*-- buffer, so it has to be down here in the flat window and not
*-- in the $E000 segment (the kernel refuses a process address
*-- >= $D000) -- the shell's own start tick, and the timer mode
*-- SB_T0CAP decoded from it (0 = no usable timer, which covers
*-- both a failed call and mode 3's frozen counter). All three
*-- are written by SB_T0CAP at START before `times` can run.
SH_TICKBUF  ds    1
SH_TICKTGT  ds    4        ;the count (shsgrw.s adds 1 in place
                           ;= SYS_SLPUNTIL's parm)
SH_T0       ds    4
SH_TMODE    ds    1
*-- The six POSIX builtins' scratch (shsgblt.s). In the ARENA
*-- and not `ds` in that file for a reason peculiar to a
*-- language-card segment: SEG_INIT leaves the LC WRITE-
*-- PROTECTED, so a `ds` cell up there could not be stored to at
*-- all. Every one is written at the head of the routine that
*-- reads it -- SBI/SBLEN/SBSTAT/SBVERB by their own loops'
*-- initialisers, SBKIND/SBNAME/SBPATH inside SB_WHAT before any
*-- report, SBEQ by SB_RO_ONE's split, SBFD/SBDTGT/SBTGT by
*-- SB_DUPCL and SB_EXECRD immediately before use, SBACC/SBREM/
*-- SBSEC by the tick arithmetic that then consumes them.
SBI         ds    1
SBLEN       ds    1
SBVERB      ds    1
SBSTAT      ds    1
SBKIND      ds    1
SBNAME      ds    2
SBPATH      ds    2
SBEQ        ds    1
SBFD        ds    1
SBDTGT      ds    1
SBTGT       ds    1
SBPOS       ds    1
SIGI        ds    1         ;SIG_PUTNAME's table cursor
SIGN        ds    1         ;...and the name's length
SBACC       ds    4
SBREM       ds    1
SBSEC       ds    1
*-- EXPBUF -- the word-expansion pool. `stz EXPCUR` resets it
*-- once per line before TOKENIZE, DOEXPAND bump-allocates
*-- upward through EMITB, and every reader reaches it via a
*-- pointer the same pass just published. Write-before-read.
*-- EXPBUF: moved, see the dead-copy block
*-- EMITBRACE/BRWORD scratch. Traced: BROP/BRESUME/BRSAVE are
*-- stored at :bnamend before any read; BRFOUND is `ror`-ed from
*-- VARFIND's carry before the branch that tests it; BRMODE and
*-- BRWLEN are BRWORD's own first two instructions; BRWBUF is
*-- written 0..BRWLEN and NUL-terminated at BRWLEN before VARSET
*-- or EMITSTRP reads a byte.
*-- EMITSTAR's loop counters. Both stored before either is read:
*-- STARN by the count arithmetic, STARI by the `lda #1` that
*-- follows it on the non-empty path.
STARN       ds    1
STARI       ds    1
BROP        ds    1
BRESUME     ds    1
BRSAVE      ds    2
BRFOUND     ds    1
BRMODE      ds    1
BRWLEN      ds    1
BRWBUF      ds    VARVALLEN+1
*-- `${V%pat}`/`${V%%pat}`/`${V#pat}`/`${V##pat}` (docs/SH-
*-- FEATURES.md, 2026-09-15) scratch, VPAT_STRIP (shexp2.s).
*-- Traced: VPMODE/VPPATP are stored by EMITBRACE before the
*-- call; VPLEN by VPAT_STRIP's own copy loop before any reader;
*-- VPI/VPSAVE by VP_SUFTEST/VP_PFXTEST before either is read
*-- back in the SAME call; VPVBUF is filled 0..VPLEN and NUL-
*-- terminated before GLOBMATCH or EMITSTRP reads a byte.
VPMODE      ds    1        ;0=% 1=%% 2=# 3=##
VPLEN       ds    1
VPI         ds    1
VPPATP      ds    2
VPSAVE      ds    1
VPVBUF      ds    VARVALLEN+1
*-- Pipe A -- the BODY pipe to the nested shell's fd 0 -- and
*-- SUB_WRBODY's index (a cell because PUTC does not promise Y).
*-- Traced: SC_PIPE writes SUBPIPEA's two bytes before :pipedA
*-- reads them (the failure path never reads); :pipedA copies
*-- them into SUBBRFD/SUBBWFD before any use; SUB_WRBODY opens
*-- with `stz SUBBI`. All write-before-read on every pass, so no
*-- zero start is owed.
SUBPIPEA    ds    2
SUBBRFD     ds    1
SUBBWFD     ds    1
SUBBI       ds    1
*-- Nonzero iff fd 0 is a DEVICE (SC_FDSTAT with the high bit
*-- set) -- V7's interactive test, decided ONCE at START, which
*-- stores it (stz, then conditional set) before MAINLOOP's
*-- prompt guard -- the only reader -- can run. Every spawn
*-- passes through START, warm respawns included, so no emitted
*-- zero is owed (an emitted zero is a loader property --
*-- docs/STICKY.md sec 32).
SH_INTERACT ds    1
*-- OPEN-RW-1 (shsgrw.s). OW_VEC/OW_N/OW_ARMD/OW_INTR are stored
*-- at OW_RUN's head, OW_HIT at OW_DRAIN's head; OW_SEEN is
*-- write-only (a gate reads it: the retry count of the last
*-- redirect that waited). OW_INTR is read by PR_REDIRERR
*-- (shpath.s), stored first by every OW_RUN: set = a `>`/`>>` a
*-- ^C ended, not a refusal.
OW_VEC      ds    2
OW_N        ds    1
OW_ARMD     ds    1
OW_INTR     ds    1
OW_HIT      ds    1
OW_SEEN     ds    1
*-- SUB_WRVARS/SUB_VLINE/SUB_WRSTR/SUB_WRVAL scratch. Traced:
*-- SUBVSLOT and SUBVCNT are stored by SUB_WRVARS's own first
*-- two instructions; SUBVESC by SUB_VLINE's; SUBVLEN/SUBVNLEN
*-- are `sty`-ed at the end of the scan that computes them,
*-- before the budget arithmetic reads them; both writers open
*-- with `stz SUBSI`. All write-before-read on every pass.
SUBVSLOT    ds    1
SUBVCNT     ds    1
SUBVLEN     ds    1
SUBVNLEN    ds    1
SUBVESC     ds    1
SUBSI       ds    1
*-- CHCK_GROUP's own two. SUBGLEN is stored by the length scan
*-- before the copy loop reads it; SUBGI opens with `stz`.
SUBGLEN     ds    1
SUBGI       ds    1
*-- SUB_PREPCH's "the body was empty" flag, stored by its own
*-- first instruction before either caller reads it.
SUBGONE     ds    1
*-- IFS field splitting (SPLIT_APPEND/IFS_RESOLVE/ISIFS).
*-- All write-before-read within one call chain: WORDEXPAND
*-- opens with `stz EXPSUBST`; SPLWORD/SPLSTART/SPLPOS are
*-- stored by SPLIT_APPEND's own split path before any read;
*-- SPLCH by ISIFS's first instruction; IFSSET is filled whole
*-- (NUL included) by IFS_RESOLVE before ISIFS scans a byte.
*-- HDX_KIND -- WHICH eligible prefix :qbare matched: 0 =
*-- "<<"/"<<-" (the quoted span is a heredoc TERMINATOR, copied
*-- verbatim so STRCMP can match it against body lines), 1 =
*-- "NAME=" (the span is a VALUE, marked by ASGMARK). In the
*-- ARENA and not `ds`: :qbare `stz`s it at the top of every
*-- call, before :bqc3 or :hdqloop reads it, so it is owed no
*-- emitted zero -- which is what check-modules' BIN_DEBT
*-- ratchet caught when it was first written as a plain `ds`.
HDX_KIND    ds    1
*-- TOKLVL -- 2026-09-15 quote CONCATENATION (shtok.s, docs/
*-- SH-FEATURES.md sec 23): this token's EVENTUAL TOKQUOTE,
*-- built up over every segment and stored only at the token's
*-- real end. Write-before-read, same class as HDX_KIND above:
*-- :tokstart sets it to 1 before :doquoted/:segbare/:bloop ever
*-- read it, on every call, so it is owed no emitted zero.
TOKLVL      ds    1
*-- TOKGRP -- :qbgrp's own "this token opens a `(` GROUP" latch,
*-- 2026-09-15. A group token's TOKQUOTE must end up 1 (literal
*-- to THIS shell -- :qbgrp's own header) no matter what bare
*-- scanning TOKLVL otherwise settles on for it (:segbare forces
*-- TOKLVL=0 for EVERY token that reaches ordinary bare content,
*-- a group token included), so it cannot simply set TOKLVL and
*-- let the unified store win -- :tokfinal (shtok.s) reads this
*-- FIRST. Write-before-read, same class as TOKLVL above.
TOKGRP      ds    1
*-- The operator pool and :bop's cells (shtok.s, KFIX 5). In the
*-- ARENA, none owed an emitted zero: TOKENIZE resets OPPOS and
*-- OPSKIP on every call, and every other cell is written by
*-- :bop
*-- before it is read in the same pass.
*-- OPBUF: moved, see the dead-copy block
OPPOS       ds    1
OPSKIP      ds    1
OPCH        ds    1
OPLEN       ds    1
OPX         ds    1
OPY         ds    1
OPDIG       ds    1
OPSTART     ds    1
OPCNT       ds    1
EXPSUBST    ds    1
DOEXPRAN    ds    1
SPLWORD     ds    2
SPLSTART    ds    1
SPLPOS      ds    1
SPLCH       ds    1
IFSSET      ds    IFSSETMAX
*-- RDBUF: the `read` builtin's own line buffer (CHCK_BLTN_RD).
*-- It cannot share LINEBUF -- LINEBUF still holds the very line
*-- `READ A B` was tokenized out of, and CMD_ARGV points INTO
*-- it, so reading the input line over the top of it would
*-- destroy the variable NAMES before they were ever used.
*-- Traced for the read-before-write rule this block's header
*-- states: :rloop writes bytes 0..RDBLEN-1 and :rterm lays down
*-- its OWN NUL at RDBLEN -- including at the LINEMAX cap, where
*-- :rloop stops STORING but keeps draining the line, so the NUL
*-- always lands inside the buffer -- before the trailing-strip
*-- scan or the split loop reads a single byte back. Every read
*-- site is bounded by RDBLEN or by that NUL.
*-- RDBUF: moved, see the dead-copy block
*-- READLINE's seekable fast path (docs/PERF-PLAN.md step 5):
*-- one chunked SC_READ per script line + one SET_MARK back to
*-- just past the CR, replacing LINEMAX one-byte reads. All
*-- write-before-read: READLINE's fast path stores every cell
*-- (mark, parmlist, chunk) before its own scan reads them, and
*-- the bytewise path touches none of them.
*-- RL_BUF: moved, see the dead-copy block
RL_PARM     ds    1           ;PCOUNT_READ, stored per call
RL_PARM_REF ds    1
RL_PARM_BUF ds    2
RL_PARM_REQ ds    2
RL_PRM_TRNS ds    2
RL_CRP      ds    1           ;index of the CR in RL_BUF
RL_MARK     ds    3           ;line start + CRP + 1 -- its OWN
                              ;cell: LINE_MARK is the LOOP-HEAD
                              ;mark RW_LOOP_PUSH still needs
*-- SH-MLQUOTE, the logical-line reader (shrlog.s, shsgmlq.s,
*-- READLINE in shlex2.s). Every cell is stored before it is
*-- read: RL_PHYS clears the first three on each call, READLINE
*-- the next, and RL_LOGICAL the rest before its own reads.
RL_NOCR     ds    1     ;the line ended at EOF with no CR
RL_OVER     ds    1     ;it was over LINEMAX (255 kept)
RL_X256     ds    1     ;... and this is its 256th byte
RL_ED       ds    1     ;the line came from the editor
RL_ACCN     ds    1     ;bytes held in HDLINEBUF so far
RL_CONT     ds    1     ;1: RL_HMARK holds the head mark
RL_HMARK    ds    3     ;the FIRST physical line's mark
RL_KIND     ds    1     ;RL_CLASSIFY's verdict
RL_NEWN     ds    1     ;the joined length
RL_ODD      ds    1     ;odd run of trailing backslashes
TOK_UNQ     ds    1     ;TOK_ERR 2 was an OPEN quote (shtok.s)
RL_DSQ      ds    1     ;refusal scanner: 0 bare, else quote
RL_DSE      ds    1     ;... a backslash is pending
RL_DSW      ds    1     ;... at a word start
RL_DSC      ds    1     ;... in a comment
RL_DSX      ds    1     ;... a `(` here opens a group
HDOVF       ds    1     ;CPTR_HEREDOC: a line/body overflowed
STRPEX      ds    1     ;STRIPCOMMENT: an escaped byte's index
HDESC       ds    1     ;CPTR_HEREDOC: odd backslash run
*-- The environment's own staging (docs/SYSCALL.md item 13c),
*-- traced the same way as everything above. SHENVBUF is a
*-- monotonic bump allocator (ENVBP reset to SHENVBUF at every
*-- ENV_STAGE, ENV_EMIT the only writer) and the kernel reads
*-- back only what the pointers ENV_EMIT just published point
*-- at; SHENVARR gets slot ENVN written before ENVN is
*-- incremented past it, and the NULL terminator written at
*-- slot ENVN itself, so the kernel's walk -- which stops on
*-- that NULL and trusts no count -- is bounded by what the
*-- same writer just published. SUBARGV's own precedent above,
*-- exactly.
*-- SH_PATHSRC is PATH_SRC's output: it always writes the whole
*-- list, terminator included, immediately before BUILD_PATH's
*-- :trydir reads a byte of it. ENVBP/ENVN/ENVSLOT/EXPI/PSRCI/
*-- PSRCLAST are all `stz`'d or `sta`'d by the routine that
*-- then reads them (ENV_STAGE, CHCK_BLTN_EXP, PATH_SRC).
SHENVBUFSZ  equ   MAXVARS*ENVSLOTSZ
SHENVARRSZ  equ   MAXVARS*2+2
SHENVBUF    ds    SHENVBUFSZ
SHENVARR    ds    SHENVARRSZ
*-- SH_PATHSRC: moved, see the dead-copy block
ENVBP       ds    2
ENVN        ds    1
ENVSLOT     ds    1
EXPI        ds    1
PSRCI       ds    1
PSRCLAST    ds    1
SH_BSSEND                        ;scripts/check_shwarm.py's
                                 ;poison window ends here -- a
                                 ;`dum` label, emits nothing
                                 ;(src/bin/cat.s's CAT_BSSEND
                                 ;precedent)
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
*-- trap state (docs/SIGNALS.md sec 3, shtrap.s). TRAPACT is
*-- zeroed by SH_INIT_ZR every spawn; TRAPTAB (16 x 256B slots,
*-- BSS) is read only for an armed slot so it needs no zero.
*-- SH_EXITING/SH_EXITST carry the pending-exit handoff through
*-- the exit trap; SH_EXITING is zeroed at SH_INIT_ZR too.
TRAPACT     ds    16
SH_EXITING  ds    1
SH_EXITST   ds    1
TRAP_ARGX   ds    1
TRAP_SIG    ds    1
TRAP_MODE   ds    1
TRAP_TMP    ds    1
TRAP_ACT    ds    2
*-- Trapped signals SIG_RETRY popped while a blocking call was
*-- interrupted, waiting for PUMP_TRAP: TRAP_HELD[n] flags
*-- signal n, TRAP_PEND counts the flags set (0 = none).
*-- PUMP_TRAP drains them lowest first. Both are zeroed by
*-- SH_INIT_ZR: lazy free retains the bank.
TRAP_PEND   ds    1
TRAP_HELD   ds    16
*-- TRAPTAB: below the arena (see "TRAPTAB and CSFORWORDS").
*---------------------------------------------------------------
* Console-loop spooling (docs/SH-FEATURES.md, 2026-09-15):
* RW_WHILE/RW_LOOP_PUSH/RW_FOR (shresv.s/shvar2.s) SPOOL a
* non-seekable loop's whole text -- head through its matching
* DONE, however many lines that takes -- into a per-process temp
* file instead of dying, then `.`-source it (SPOOL_ENTER,
* shresv.s). RW_HEADPTR is CHCK_RESERVED's own capture, above.
*
* SH_SPOOL_LVL zeroed-at-entry, like CSPTR/SCAN_ACT/PCR_PEND
* above -- SH_INIT_ZR's own list gains it (0 = no spool file
* open; else the SRC_DEPTH value, post-inc, SH_EOF -- and now
* SH_EXIT, shtrap.s -- must match to unlink SPOOL_NAME). RAWLINE
* (above, HDLINEBUF's neighbor) holds the head line's PRISTINE
* text -- SPOOL_HOFS is CHCK_RESERVED's RW_HEADPTR translated
* into an offset into it. Everything else here is write-before-
* read: SPOOL_ENTER always builds SPOOL_NAME fresh before any
* open, and always fills SPOOL_FD/SPOOL_NEST/SPOOL_HOFS/
* SPOOL_LEN/SPOOL_SEEK before a later step reads them.
RW_HEADPTR  ds    2
SH_SPOOL_LVL
            ds    1
SPOOL_FD    ds    1
SPOOL_NEST  ds    1
SPOOL_HOFS  ds    1          ;RW_HEADPTR - LINEBUF -- the head's
                             ;own offset into RAWLINE
SPOOL_LEN   ds    1
SPOOL_SEEK  ds    3
SPOOL_CUR   ds    1          ;SPOOL_SPLIT's own cursor
SPOOL_SEGST ds    1          ;SPOOL_SPLIT/SPOOL_DOSPLIT: the
                             ;CURRENT segment's start offset
                             ;(relative to PTR0)
SPOOL_QST   ds    1          ;SPOOL_SPLIT's quote state for THIS
                             ;line -- 0 bare, else the CLOSING
                             ;quote byte itself ($A7 '...', $A2
                             ;"...") -- a `;` inside quotes is
                             ;not a segment boundary
SPOOL_TRUNC ds    1          ;SPOOL_SPLIT: this word is longer
                             ;than any keyword -- skip the
                             ;compare (a false-truncated match,
                             ;e.g. "WHILEX", must not read as
                             ;WHILE)
SPOOL_WBUF  ds    8          ;SPOOL_SPLIT's candidate word, NUL-
                             ;terminated, never longer than
                             ;"WHILE"/"UNTIL"
SPOOL_ID    ds    1          ;SPOOL_KWID's own return value,
                             ;held across its call so SPOOL_
                             ;ADJNEST can read it after PTR0 is
                             ;restored
SPOOL_NAME  ds    14         ;"/tmp/SH.SPLxx" + NUL (BANK_ID
                             ;hex; ex's EX.SWPxx naming, in the
                             ;one directory every cwd can reach)
*---------------------------------------------------------------
* SH_BGPID -- `$!` (docs/SH-FEATURES.md, 2026-09-15): the pid of
* the most recent background command. Zeroed at SH_INIT_ZR --
* "no `&` has ever run" needs a real sentinel, and 0 is never a
* pid RUN_PIPELINE hands a spawned child (bank 0 is the resident
* kernel, never a process). JOB_BG (shjob.s) writes it.
*---------------------------------------------------------------
SH_BGPID    ds    1
*-- UNSETI -- `unset`'s own argv walk cursor (CHCK_BLTN_UNS,
*-- shvar.s). Write-before-read, same class as EXPI above.
UNSETI      ds    1
*---------------------------------------------------------------
* GOPT_* -- `getopts`'s own state (shvar2.s, docs/SH-FEATURES.md
* 2026-09-15), none of it POSIX-visible: OPTIND/OPTARG are
* ORDINARY shell variables (VARSET/VARFIND), costing two of
* MAXVARS' eight slots instead. GOPTCIDX/GOPTLASTOI are zeroed
* at SH_INIT_ZR -- a fresh process's "no getopts call has ever
* run" needs a real sentinel, since GOPTLASTOI is compared
* against a live OPTIND that defaults to 1 the moment it is
* first read, and 0 can never be a real one. Everything else
* here is write-before-read, each routine's own scratch stored
* immediately before it is read back.
*---------------------------------------------------------------
GOPTCIDX    ds    1
GOPTLASTOI  ds    1
GOPTN       ds    1
GOPTCH      ds    1
GOPTVP      ds    2
GOPTC1      ds    2
GOPTC2      ds    2
GOPTNBUF    ds    4
GOPTFAIL    ds    1
*-- alias/unalias/hash (shsgali.s): scratch, each written before
*-- it is read; ALI_USED/ALI_MINPOS are set by ALI_INIT / the
*-- SH_RUNLINE hook. ALOUT builds one listing line (<= 150 B).
ALI_USED    ds    1
ALI_MINPOS  ds    1
ALP         ds    1
ALWE        ds    1
ALCMD       ds    1
ALDEP       ds    1
ALL         ds    1
ALN         ds    1
ALV         ds    1
ALH         ds    1
ALD         ds    1
ALU         ds    1
ALT         ds    1
ALIDX       ds    1
ALEQ        ds    1
ALI_LI      ds    1
ALPFX       ds    2
ALOUT       ds    160
*-- The line editor's cells (shedit.s), emitted nowhere. All are
*-- written before they are read within one ED_LINE call (it
*-- stores the per-line ones first thing); the history cells and
*-- SH_EDIT are established at START by ED_INIT.
SH_EDIT     ds    1           ;fd 0 is a console: edit
SH_NOEDIT   ds    1           ;sh -E: ...unless asked not
ED_W        ds    1           ;console columns
ED_LEN      ds    1
ED_POS      ds    1
ED_CUR      ds    1           ;the GLASS cursor, as a line index
ED_PCH      ds    1           ;the prompt's character, high bit
ED_PRM      ds    1           ;1: ED_LINE owes the prompt
ED_STASH    ds    128         ;[len][text]: a walk's line
ED_KESC     ds    1           ;0 idle, 1 saw ESC, 2 saw ESC [
ED_K        ds    1
ED_BI       ds    1
ED_MODE     ds    1           ;tty mode to restore
ED_RAWF     ds    1           ;1 while the console is ours (raw)
ED_PINT     ds    1           ;INT / TSTP actions to restore
ED_PTSTP    ds    1
ED_INTR     ds    1           ;an INT/TSTP interrupted this line
ED_HCUR     ds    1           ;history walk: $FF = not walking
ED_HN       ds    1           ;entries held
ED_HUSED    ds    2           ;ring bytes in use
ED_T1       ds    1
ED_T2       ds    1
ED_T3       ds    1
ED_TGT      ds    1
ED_P0       ds    2           ;{row, col} of the cursor / target
ED_P1       ds    2
ED_DIR      ds    1
ED_PH       ds    1
ED_PEND     ds    1
ED_OUTN     ds    1
ED_GEOBUF   ds    4
ED_OUT      ds    ED_OUTMAX+16
ED_NOPROG   ds    1           ;TAB: 2 after a no-progress TAB,
                              ;shifted by every key (ED_KEY)
*-- TAB completion's cells (shtabc.s). Each is written by
*-- TC_TAB / its callees before it is read within one TAB.
TC_ON       ds    1           ;1 while GLOB_APPEND walks for TAB
TC_ERR      ds    1           ;the scan was incomplete
TC_WAS      ds    1           ;ED_NOPROG as TAB found it
TC_SAVE     ds    1           ;LINEBUF[POS] under the scan NUL
TC_MODE     ds    1           ;0 command word, 1 pathname
TC_WS       ds    1           ;word start (line index)
TC_BS       ds    1           ;start of the leaf (after last /)
TC_BL       ds    1           ;leaf length typed
TC_LAST     ds    1           ;0: the word ends at the cursor
TC_RP       ds    1           ;redirect: 1 file, 2 fd/heredoc
TC_FORN     ds    1           ;`for` seen: its NAME is next
TC_CASE     ds    1           ;inside case ... esac: refuse
TC_FILT     ds    1           ;bit 7: runnable types only
TC_FOLDF    ds    1           ;bit 7: fold case (builtins)
TC_N        ds    1           ;records stored (<= MAXGLOB)
TC_CNT      ds    1           ;distinct candidates (sat. 255)
TC_LCP      ds    1           ;common prefix length, folded
TC_STY      ds    1           ;storage type of the candidate
TC_I        ds    1
TC_K        ds    1
TC_J        ds    1
TC_PI       ds    1           ;PATH component cursor
TC_SUF      ds    1           ;suffix character, 0 = none
TC_T1       ds    1
TC_MAXW     ds    1
TC_CW       ds    1
TC_COLS     ds    1
TC_COL      ds    1
TC_DIRF     ds    1
TC_CAND     ds    16          ;one candidate: name + NUL
TC_PAT      ds    66          ;GLOB_APPEND's word + `*` + NUL
*-- shpfx.s's cells.  PFX_SV is zeroed at START (a recycled bank
*-- hands this arena back dirty: TAB-A3 notes sec 5); PFX_N is
*-- written for every stage by each PFX_PEEL before anything
*-- reads it, and every other cell is stored before it is read.
PFX_N       ds    MAXCMD      ;prefix words peeled, per stage
PFX_PTR     ds    MAXCMD*PFX_MAX*2   ;their NAME pointers
PFX_SV      ds    1           ;saved entries PFX_RESTORE owes
PFX_SSLOT   ds    PFX_MAX
PFX_SKIND   ds    PFX_MAX     ;$80 made here | old export
PFX_SVAL    ds    PFX_MAX*VARVALSZ
PFX_S       ds    1           ;the stage being worked
PFX_I       ds    1
PFX_K       ds    1
PFX_T       ds    1
PFX_PERS    ds    1           ;1 = persists (no save, no export)
PFX_BASE    ds    1           ;the stage's offset in CMD_ARGV
PFX_SP      ds    2           ;PFX_ALLASG's saved PTR0
*-- SH-EXECLOOP: the `for` replay coordinate = LINE_MARK (the
*-- start of the logical line holding DO) + the token index of
*-- DO's segment. SEG_TOKI is the first token of the segment
*-- being run (set at every :seg); RW_DO_FOR files it per frame
*-- in CSFORTOK. RW_DONE_FOR posts it in RP_PEND; the next
*-- READLINE that succeeds turns it into RP_TOK, and
*-- :toknoerr starts PARSE there. LN_HD is set by a here-doc
*-- capture and cleared per line; HD_BEFORE is its value when
*-- the current segment began. PEND and TOK are zeroed by
*-- SH_INIT_ZR (a warm respawn retains this arena); the rest
*-- are written before they are read.
SEG_TOKI    ds    1
RP_PEND ds    1
RP_TOK  ds    1
LN_HD       ds    1
HD_BEFORE   ds    1
*-- STR_SRC = 1 while the line being run is a STRING (eval, a
*-- trap), not text read from CUR_IN_FD: SPOOL_ENTER must never
*-- read past the string's own end (it would steal the caller's
*-- lines).
*-- Set by SH_RUNSTR, cleared by :noteof; written before read.
STR_SRC     ds    1
*-- SH-SEQ B: CASE_EMPTY is 1 from a case pattern's match until
*-- the next command runs (shlex.s :csskipok clears it). Read at
*-- ESAC only when CSTAKEN says a pattern matched, and the match
*-- wrote it first: 1 at ESAC means an empty clause, status 0.
CASE_EMPTY  ds    1
*-- SH-CASE2 A: a while/until pops and re-pushes its frame each
*-- iteration, so the last body status rides in LP_PEND across
*-- the hop (CR_HANDOFF stores it; the next RW_LOOP_PUSH takes
*-- it and clears it: 0 = a fresh loop, whose body has not run)
*-- and lives in the frame's CSLPSTAT. LP_PEND is zeroed by
*-- SH_INIT_ZR; CSLPSTAT is stored at every push, before any
*-- read.
*-- PUMP_TRAP runs at depth 0 -- exactly between a loop's pop
*-- and
*-- its re-push -- and a trap string's own constructs would
*-- claim
*-- the outer loop's pending hand-off (PCR_PEND, LP_PEND). So
*-- the
*-- pump hides it: TRAPSV_LP holds LP_PEND, TRAPSV_D the
*-- SRC_DEPTH
*-- + 1 it was hidden at (0 = nothing hidden; zeroed by
*-- SH_INIT_ZR), and the first MAINLOOP top back at that depth
*-- puts it back (SH-CASE2 B H1).
LP_PEND     ds    1
TRAPSV_LP   ds    1
TRAPSV_D    ds    1
CSLPSTAT    ds    MAXCDEPTH
*-- SH-SEQ C: the `.` continuation (shbltn.s DOT_SAVE/CONT_POP).
*-- CONT_BUF is one 256-byte slot per possible `.` frame,
*-- indexed by SRC_DEPTH; SLOT_PTR adds the index to the HIGH
*-- byte only, so the base needs no page alignment (`ds \` is
*-- refused by nas). Slot: +0 separator (bit 7 = an alias
*-- spliced on that line), +1 EE_SUPP before, +2 STR_SRC, +3 the
*-- old CS_FLOOR, +4 the remainder text. Written by DOT_SAVE
*-- before CONT_POP reads it.
*-- CONT_SEP: set by CONT_POP, consumed by SH_RUNLINE's
*-- :toknoerr (zeroed by SH_INIT_ZR). EE_SUPP: 1 while a `.`
*-- that was in a tested position runs (ERREXIT_CK suppressed;
*-- zeroed). CS_FLOOR: the construct stack depth when the
*-- innermost `.` frame began; a terminator or break below it is
*-- refused (zeroed).
CONT_SEP    ds    1
EE_SUPP     ds    1
CS_FLOOR    ds    1
CONT_BUF    ds    SRC_MAXDEPTH*256
CSFORTOK    ds    MAXCDEPTH
SH_ARENA_END                     ;check-modules' window
                                 ;margin; a `dum` label,
                                 ;emits nothing (BSSEND's twin)
            err   */$BF00
            err   GNAME-GREC-RD_NAME
            err   CD_PATHBUF-GREC-RD_SIZE
            dend

*---------------------------------------------------------------
* TRAPTAB and CSFORWORDS -- the two biggest bss tables (4,096 B
* and 2,048 B), placed INSIDE the low copy of the segments
* (KFIX3 item 0). The window is $0800-$BF00 (46,848 B); the file
* is the low image, then the two segments' bytes (SEG_INIT's
* source), then the arena above it. A segment's code runs from
* the language card, so on a warm respawn its low copy is dead
* weight the arena sat above -- 7.9 KB of the window. Moving
* code into the card therefore freed nothing in the WINDOW (the
* tripwires' headroom, yes), and the arena was 134 B past $BF00
* with item 3's signal names in it. These two tables are the
* answer: SEG_INIT copies the tails ONLY on a cold spawn
* (SEGSTAMP is 0 when the loader has just written the file,
* SEG_MAGIC when a warm respawn finds the card intact), and both
* tables are read only after being written (a trap slot is read
* only when armed, a `for` row only after FOR_NEXT filled it),
* so the bytes under them being the tails' is harmless.
*
* The addresses are LITERAL, like ex's EX_SHADOW at $D000: the
* native linker places bss at the file's end and has no way to
* ask for "inside the tails", but an absolute `dum` is just
* equates in every piece. The block must lie between the end of
* the low image (SH-PREFIX moved it from $6700 to $6A00, DUPFD-1
* from $6A00 to $6B00, when the low image outgrew the old base;
* SH-ROOM shrank the image 716 B and moved it back to $6A00,
* with the alias table in its own block just below (see the
* end of this block); SH-EXECLOOP to $6D00, the same reason;
* SH-SEQ C to $6E00 (the `.` continuation grew the image);
* SH-CASE2 B to $7000 (the case-pattern split grew it again);
* `check-modules` asserts every
* cell here is >= SH_SEG_LOW, which an `err` cannot say here
* because the native piece cutter refuses a guard that leans on
* a label) and the end of the file (the `err` below).
* TRAPTAB is page-aligned (TRAP_SLOT_P1 adds the signo to the
* HIGH byte).
*---------------------------------------------------------------
            dum   $7000
TRAPTAB     ds    16*256
CSFORWORDS  ds    MAXCDEPTH*FORWORDMAX*FORWORDLEN
*-- SH-PREFIX Phase 0: the rest of the dead copy (after
*-- CSFORWORDS, to the file end) holds the arena's
*-- write-before-read buffers. Same rule as the two tables
*-- above: SEG_INIT reads the copy once, from START, before
*-- any of these is touched; a warm respawn never reads it.
GLOBBUF     ds    MAXGLOB*GLOBREC
LINEBUF     ds    LINEMAX+1
TOKPTR      ds    MAXTOK*2
HD_BODY     ds    HDBODYLEN
HDLINEBUF   ds    LINEMAX+1
RAWLINE     ds    LINEMAX+1
EXPBUF      ds    EXPBUFLEN
OPBUF       ds    OPBUFSZ
RDBUF       ds    LINEMAX+1
RL_BUF      ds    LINEMAX+1
SH_PATHSRC  ds    SH_PSRCSZ
*-- SH-SEQ C: TOKENIZE's raw read offset of each token, and the
*-- line it was tokenizing (post-alias, post-comment-strip);
*-- DOT_SAVE cuts the remainder of a `.` line out of PRETOK at
*-- TOKOFF[TOKI]. Both written before read, every line.
TOKOFF      ds    MAXTOK
PRETOK      ds    LINEMAX+1
SH_DEADCP_END                    ;the block's high-water mark
            err   */SH_FILE_ENDP1
            dend
*-- SH-ROOM: the alias table (shsgali.s, shtabc.s), in the dead
*-- copy BELOW TRAPTAB: its 392 B end exactly at TRAPTAB's page
*-- ($6B78 + $188 = $6D00; SH-EXECLOOP moved both up one page
*-- when the low image outgrew $6A78, as DUPFD-1 did before it),
*-- so the block above keeps its page alignment and its own
*-- high-water mark. NOT write-before-read
*-- as a whole: ALI_INIT (START, after SEG_INIT) clears each
*-- slot's first name byte and ALI_END; a value is read only
*-- through an occupied name. The base moves with the low
*-- image (check-modules: ALI_NAMES >= SH_SEG_LOW).
TRAPTABP1   equ   TRAPTAB+1
            dum   $6E78
ALI_NAMES   ds    128
ALI_VALS    ds    256
ALI_END     ds    8
            err   */TRAPTABP1
            dend
*-- SH-ROOM2: the editor's history ring, in the dead copy
*-- directly BELOW the alias table: ED_HRING + ED_HSIZE ends
*-- exactly at ALI_NAMES. It used to be LC data at the top of
*-- the $D000 bank; segment 2 grew over that, so the ring moved
*-- here, where it emits nothing. Read-after-publication, the
*-- alias table's rule (docs/SH-ROOM2-NOTES.md sec 4): ED_INIT
*-- (START, after SEG_INIT) clears ED_HN and ED_HUSED, and every
*-- reader of the ring runs after ED_HN says an entry exists;
*-- ED_HADD writes the entry before it publishes it. NEVER
*-- split it, never squeeze it: the base moves with the alias
*-- block (check-modules: SH_SEG_LOW <= ED_HRING, the ring ends
*-- at ALI_NAMES, and ALI_NAMES is below the file end).
ALI_NAMESP1 equ   ALI_NAMES+1
            dum   $6C78
ED_HRING    ds    ED_HSIZE
            err   */ALI_NAMESP1
            dend
