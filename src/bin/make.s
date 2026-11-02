*---------------------------------------------------------------
* make.s -- keep files up to date, the V7 way (S9 L5).
*
* Usage: make [-eikNnpqrSst] [-f MAKEFILE] [NAME=value ...]
*             [target ...]
*
* CONTRACT: read a makefile of the classic shape --
*
*     NAME = value
*     .SUFFIXES: .R .S
*     .S.R:
*         <tab>ASSEMBLER -o $@ $<
*     target: dep dep dep
*     <tab>command
*
* -- and for each requested target (or the FIRST non-special
* rule in the file if none is named), bring its dependencies up
* to date first, then run its recipe if any dependency is newer
* than the target or the target does not exist. Echo each
* command before running it. Stop at the first command that
* exits nonzero. Exit 0 if everything is up to date or was made,
* 1 on any failure, 2 on a usage error.
*
* WHY OUT-OF-DATE IS A RAW BYTE COMPARE, not a decode. ProDOS
* mod_date/mod_time are two 16-bit fields whose format is opaque
* under ProDOS 2.5's Extended shape, but EQUALITY needs no
* decoding and ORDERING is what we actually need. The fields are
* ordered within themselves (date is yyyyyyym mmmddddd, time is
* 000hhhhh 00mmmmmm), so a big-endian compare of
* (date_hi, date_lo, time_hi, time_lo) sorts correctly without
* interpreting a single field. That is the same discipline the
* spawn cache's freshness test uses
* (learning:01M0BQQ6XN04NQAWE0WAQX1RG5) -- and it inherits the
* same blind spot, stated here rather than discovered later:
* TWO WRITES IN THE SAME MINUTE COMPARE EQUAL, so a rebuild
* finished within a minute of its source's last write can be
* judged up to date. ProDOS has no finer clock; -t is the escape
* and `make -B`-style forcing is still not implemented.
*
* SCOPE, stated so nobody reads more into it. There ARE macros,
* inference rules and internal macros now (docs/MAKE-POSIX.md;
* they are what let the self-host graph fit at all). There is
* still NO parallelism, no included makefiles, no `::` rules,
* and -- the one that bites -- NO SHELL BETWEEN make AND THE
* COMMAND. A command line is tokenized on blanks and spawned
* directly, so no pipes, redirection or globbing in a recipe,
* and `#` in a recipe is a character rather than a comment.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.procbnk2.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/make.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*-- sizing constants
*-- THE ARENA IS THE BUDGET, and macros changed its shape.
*-- MKTEXT now holds the makefile RAW -- macros are expanded
*-- lazily (makemac.s's header) -- so the cap bounds the FILE,
*-- not its expansion, and a macro-written makefile is several
*-- times smaller than the graph it describes. The nas self-make
*-- MAKEFILE was 40,133 B longhand against a 28,672 cap; written
*-- with macros and one inference rule it is a third of that.
*-- The history of this number: 17,408 -> 18,432 (the friction
*-- batch's eight window-split modules each cost a rule) ->
*-- 20,480 (2026-09-13, the roster) -> 28,672 (2026-09-14, the
*-- nas graph's per-piece rules) -> 24,576 (2026-09-18, macros:
*-- the file shrank and the arena bought MK_DEPBUF with the
*-- difference).
MK_TXTSZ    equ   22528     ;makefile text held whole, RAW
*-- 224 -> 240 on 2026-09-13 (the as graph reached 225 rules) ->
*-- 192 on 2026-09-18, a REDUCTION: two inference rules replace
*-- the 512 assembly rules the nas graph used to spell out, so
*-- that graph is 98 rules where it was 244, and the table can
*-- give its bytes to MK_TXTSZ instead. 255 was always the
*-- ceiling (the tables are X-indexed) and the roster grew 46 ->
*-- 85 utils in a month; the count is no longer the thing to
*-- watch.
MK_MAXRULE  equ   192        ;rules
MK_MAXTGT   equ   8          ;targets named on the command line
*-- deps per RULE is a different number from targets per COMMAND
*-- LINE, and borrowing MK_MAXTGT for it (as the dep loop did)
*-- refused the self-rebuild MAKEFILE at its 38-dep ALL line --
*-- MK_TOOMANY at parse, everything downstream 'missing'.
MK_MAXDEP   equ   96         ;names one dep line expands to
*-- 24 -> 32 on 2026-09-14: a nas-route link recipe (main, -l
*-- util, liba modules + pieces, bss chunks) spawns 30 tokens.
MK_MAXARG   equ   32         ;argv slots per spawned recipe
                             ;command (worst measured: 20)
*-- 16 -> 8 on 2026-09-18. Every level carries a 1 KB expanded
*-- dependency list, so depth costs arena outright; the deepest
*-- chain in the self-host graph is five (ALL -> ALLG -> program
*-- -> object -> source). Still the cycle bound as well.
MK_DEPTH    equ   8          ;recursion depth, and the cycle
                             ;bound
*-- a power of two and a whole number of pages, so this depth's
*-- buffer is a shift of DEPTH rather than a multiply (makeinf.s
*-- MK_DEPBASE). 512 -> 1024 on 2026-09-18: the play kernel
*-- links 44 modules, 989 characters expanded, and the buffer
*-- holds the EXPANSION, not the macro that wrote it.
MK_DEPBSZ   equ   1024       ;expanded dep list, per depth
MK_CMDSZ    equ   1024       ;expanded recipe line
MK_NAMSZ    equ   256        ;targets that contained a '$'
MK_MAXMAC   equ   64         ;macro definitions
MK_MAXSUF   equ   12         ;.SUFFIXES entries
MK_SUFTSZ   equ   96         ;bytes of suffix text
MK_EXPDEP   equ   8          ;macro nesting, and the
                             ;expands-into-itself bound
MK_SCRSZ    equ   40         ;longest macro NAME
INF_RNSZ    equ   20         ;".s1.s2"
INF_SRCSZ   equ   64         ;an inferred source name
*-- SIZE-1, EQUATED RATHER THAN WRITTEN INLINE, and this is not
*-- style. Merlin's `<` and `>` are OPERAND PREFIXES: they apply
*-- to the whole expression, so `#>MK_NAMES+MK_NAMSZ-1` is the
*-- high byte of the SUM. nas reads the same line as the high
*-- byte of MK_NAMES alone -- $8F where merlin32 emits $90 --
*-- and the two builds differ in one byte, 1,215 into the image,
*-- with no diagnostic from either. Found by the self-make
*-- byte-identity gate 2026-09-18, which is the only thing that
*-- could have found it. A prefix applied to a BARE SYMBOL
*-- cannot be read two ways, so every limit gets a name.
MK_TXTLIM   equ   MK_TXTSZ-1
MK_DEPLIM   equ   MK_DEPBSZ-1
MK_CMDLIM   equ   MK_CMDSZ-1
MK_NAMLIM   equ   MK_NAMSZ-1

START       stz   INF_ACTIVE      ;read by every $?, set
            jsr   MK_ARGS         ;only by an inference
            jsr   MK_READ
            jsr   MK_PARSE
            jsr   MK_SPECIAL
            lda   PFLAG
            beq   :norun
            jsr   MK_PRINT
:norun      jsr   MK_RUNALL
*-- -q answers a QUESTION: 1 if anything was out of date, and
*-- nothing was run to find out. A real ERROR still outranks the
*-- answer -- "nothing to do" and "could not tell" are not the
*-- same reply, and exiting 0 for the second is a lie a script
*-- acts on.
            lda   ERRFLAG
            bne   :status
            lda   QFLAG
            beq   :status
            lda   QOUT
            jsr   EXIT
:status     lda   ERRFLAG
            jsr   EXIT

            put   makeargs.s
            put   makeread.s
            put   makehdr.s
            put   makemac.s
            put   makeexp.s
            put   makeinf.s
            put   makeinf2.s
            put   makeprt.s
            put   makerun.s
            put   makedec.s
            put   makespn.s

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/cmdpath.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/env.s
            put   ../liba/pathtab.s    ;PATHTAB -- the default
            put   ../liba/pathres.s    ;PATHRSLV -- PATH search
            put   ../liba/syscallp.s
            put   ../liba/spawnwhy.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* make's arena -- `dum`/`dend` at the TEXTUAL END, chained onto
* liba's block (docs/STICKY.md sec 21).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ERRFLAG     ds    1              ;the exit status, sticky
STOPFLAG    ds    1              ;unwind? -k is what separates
                                 ;  this from ERRFLAG
MK_FAIL     ds    1              ;did THIS entry fail?
QOUT        ds    1              ;-q's answer
NFLAG       ds    1              ;-n: print, do not run
IFLAG       ds    1              ;-i / .IGNORE
KFLAG       ds    1              ;-k
SFLAG       ds    1              ;-s / .SILENT
EFLAG       ds    1              ;-e
TFLAG       ds    1              ;-t
QFLAG       ds    1              ;-q
RFLAG       ds    1              ;-r
PFLAG       ds    1              ;-p
OPTI        ds    1
OPTCH       ds    1
ARGI        ds    1
NTARGETS    ds    1
MKPATH_P    ds    2              ;-> makefile pathname (argv or
                                 ;  DFLTMK)
TGTLO       ds    MK_MAXTGT
TGTHI       ds    MK_MAXTGT

*-- the makefile, held whole and indexed into. Rules point at
*-- offsets in here rather than copying strings.
MKTEXT      ds    MK_TXTSZ
MKLEN       ds    2

*-- rule table, struct-of-arrays. RULE_TGT is the target name
*-- (NUL-terminated in place, the parser having overwritten its
*-- ':' -- or in MK_NAMES if it needed expanding), RULE_DEP the
*-- RAW dependency text, and RULE_CMD the first recipe line.
*-- RULE_NDEP is gone: a macro can expand to any number of
*-- names, so the count is whatever MK_EXPDEPS finds.
NRULES      ds    1
RULE_TGT    ds    MK_MAXRULE*2
RULE_DEP    ds    MK_MAXRULE*2
RULE_CMD    ds    MK_MAXRULE*2
RULE_NCMD   ds    MK_MAXRULE
RULE_MADE   ds    MK_MAXRULE     ;0 = not visited, 1 = in
                                 ;progress (cycle guard), 2 =
                                 ;done, 3 = done and FAILED
DEPTH       ds    1

*-- scratch for the walk
MK_RULEI    ds    1
MK_FI       ds    1              ;MK_FINDNM's own index
MK_SAVEI    ds    MK_DEPTH
MK_SAVED    ds    MK_DEPTH       ;MK_DEPN, per depth
MK_SAVENL   ds    MK_DEPTH       ;MK_NAMEP lo, per depth
MK_SAVENH   ds    MK_DEPTH       ;MK_NAMEP hi, per depth
MK_SAVEF    ds    MK_DEPTH       ;did a dependency fail?
MK_SAVEC    ds    MK_DEPTH       ;MK_DEPC, per depth
MK_SAVRI    ds    MK_DEPTH       ;MK_BUILDI's own rule index
MK_SAVIL    ds    MK_DEPTH       ;MK_INFRUN's target, lo
MK_SAVIH    ds    MK_DEPTH       ;                    hi
MK_DEP1L    ds    MK_DEPTH       ;first dep NAME, per depth
MK_DEP1H    ds    MK_DEPTH
MK_NAMEP    ds    2
MK_FNAME    ds    2              ;the name a lookup/stat is
                                 ;  about
MK_TSTAMP   ds    4              ;target's mod date+time
MK_DSTAMP   ds    4              ;dependency's
MK_EXISTS   ds    1
MK_NEEDS    ds    1
MK_CMDP     ds    2
MK_CMDN     ds    1
MK_DEPN     ds    1              ;the rule's dep COUNT
MK_DEPC     ds    1              ;the walk's COUNTDOWN
MK_DCN      ds    1              ;MK_DECIDE's own countdown
MK_STAMP    ds    4
MK_P0SV     ds    2              ;PTR0/1/2 across a stat
MK_P1SV     ds    2
MK_P2SV     ds    2
MK_ARGVN    ds    1
MK_RUNP     ds    2              ;the command, past its prefixes
CMD_AT      ds    1              ;'@'
CMD_DASH    ds    1              ;'-'
CMD_PLUS    ds    1              ;'+'
SPWN_ARGV   ds    MK_MAXARG*2+2
WSTATUS     ds    1
MK_CPATH    ds    66             ;CMDSLASH's resolved ./x
PATHBUF     ds    65
TOUCHCLK    ds    4

*-- macros
NMACROS     ds    1
MAC_NAME    ds    MK_MAXMAC*2
MAC_VAL     ds    MK_MAXMAC*2
MAC_FLAG    ds    MK_MAXMAC      ;1 = from the command line
MAC_I       ds    1
MAC_ISCMD   ds    1
MAC_SVAL    ds    2
MAC_NP      ds    2
MAC_VP      ds    2

*-- the expander
EXP_SP      ds    1
EXP_STKL    ds    MK_EXPDEP
EXP_STKH    ds    MK_EXPDEP
EXP_END     ds    2
EXP_SEMI    ds    1
EXP_LAST    ds    1              ;the last byte emitted
EXP_SV0     ds    2
EXP_SV1     ds    2
EXP_VAL     ds    2
MK_SCRATCH  ds    MK_SCRSZ
MK_DELIM    ds    1
MK_TOKN     ds    1
MK_TOK1     ds    2              ;the first word MK_TOKEN found
MK_TOKF     ds    1

*-- internal macros
MK_TGTP     ds    2              ;$@
MK_SRCP     ds    2              ;$<
MK_STEML    ds    1              ;$* is a LENGTH of $@
MK_SCNT     ds    1
MK_QN       ds    1              ;$?'s countdown
MK_QANY     ds    1
MK_QSAVE    ds    2

*-- the parser's per-line cells
HDR_EOL     ds    2
HDR_NEXT    ds    2
HDR_FIRST   ds    1              ;first rule of this header
HDR_TGT     ds    2
HDR_HASD    ds    1              ;did the target contain a '$'?
HDR_DEP     ds    2
HDR_SEMI    ds    2              ;an inline `; command`
HDR_CMDP    ds    2
HDR_SV0     ds    2
HDR_SV1     ds    2

*-- special targets and inference
SPI         ds    1
DEFRULE     ds    1              ;.DEFAULT, or $FF
MK_SPTR     ds    2
NSUFFIX     ds    1
SUF_L       ds    MK_MAXSUF
SUF_H       ds    MK_MAXSUF
SUFTEXT     ds    MK_SUFTSZ
SUFLEN      ds    1
INF_ACTIVE  ds    1
INF_I1      ds    1
INF_I2      ds    1
INF_SLEN    ds    1              ;stem length
INF_TLEN    ds    1              ;target length
INF_SFLEN   ds    1              ;suffix length
INF_STEM2   ds    1
INF_SFP     ds    2
INF_RULEI   ds    1
INF_HASR    ds    1              ;the source has a rule
INF_RNAME   ds    INF_RNSZ
INF_SRC     ds    INF_SRCSZ

*-- expansion buffers
MK_NAMES    ds    MK_NAMSZ
MK_NAMESP   ds    2
MK_CMDBUF   ds    MK_CMDSZ
MK_DEPBUF   ds    MK_DEPBSZ*MK_DEPTH

GFIPARM     ds    1
GFIPARM_PATH ds   2
GFIPARM_ACC ds    1
GFIPARM_FTYP ds   1
GFIPARM_AUX ds    2
GFIPARM_STYP ds   1
GFIPARM_BLKS ds   2
GFIPARM_MDATE ds  2
GFIPARM_MTIME ds  2
GFIPARM_CDATE ds  2
GFIPARM_CTIME ds  2
SFIPARM     ds    1
SFIPARM_PATH ds   2
SFIPARM_ACC ds    1
SFIPARM_FTYP ds   1
SFIPARM_AUX ds    2
SFIPARM_NULL ds   3
SFIPARM_MDATE ds  2
SFIPARM_MTIME ds  2
*-- the arena must stay below the $BF00 overlay page (the
*-- ed.s/sort.s idiom) -- added with the MK_TXTSZ raise, which
*-- the arena and deserved a ceiling that fails loudly.
            err   */$BF00
            dend


