*---------------------------------------------------------------
* shpth2.s -- sh's arg/state half of path handling,
* split from shpath.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2). One assembly
* stream: ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
CURARGC     ds    1
PARSE_ERR   ds    1
ARGVOFF     ds    1
* STGOFF -- byte offset of each pipeline stage's argv block
* inside CMD_ARGV. THE one place the stride is expressed: it was
* open-coded as three `asl a` in three separate routines, which
* is exactly why MAXARGV could not be raised (the file header
* used to say so, and that it failed at runtime with $46 because
* argv[0] came out of the wrong offset). The assembler computes
* these, so MAXARGV is a free parameter again -- but this table
* has one entry PER STAGE, so raising MAXCMD means adding one.
STGOFF      dfb   0*ARGSLOTS*2
            dfb   1*ARGSLOTS*2
            dfb   2*ARGSLOTS*2
* -- CMD_ARGV/CMD_INFILE/CMD_OUTFILE moved to the dum/dend block
* at -- the file's textual end (2026-08-21) -- ZR_CMD_TABLES's
* :z1/:z2 -- loops unconditionally zero all three, over their
* FULL declared -- size, once per pipeline segment, before PARSE
* (or anything -- else) ever reads them -- not merely "written
* before read" but -- reset in full every single time, so this
* is the strongest -- evidence class of the whole conversion.
* RW_SHIFT additionally -- re-zeroes CMD_ARGV's vacated trailing
* slot after a reserved- -- word shift, for the same reason (see
* that routine's header).
*-- The ordered fd-dup list (docs/SH-FEATURES.md sec 15). Four
*-- parallel arrays rather than packed records: every access is
*-- `lda ARRAY,x` with X the record index, no stride math, which
*-- is the same shape CMD_ARGC/CMD_APPEND/CMD_TGTFD already use.
*-- DUPN is the ONLY bound any reader uses and ZR_CMD_TABLES
*-- clears it per segment, so the arrays need no initialisation
*-- of their own. The STORAGE now lives in the dum/dend arena
*-- at the file's textual end; only the sizing equates below
*-- are still here, because they emit nothing and this is where
*-- their reasoning is written down.
*-- MAXDUPS (hoisted to sh.s): `N>&M`/`N>&-` records per
*-- SEGMENT (not per stage) -- overflow fails the line, SET_DUP
*-- NFDMAP (hoisted to sh.s): CHILDMAP entries -- PCB_FDTABLE's
*-- own 8-fd HARD LIMIT (inc/mm.annex.equ)
*-- FDABUF worst case for ONE stage: 2 records for fd 0 (dup+
*-- close), 2 for fd 1 (dup+close) = 12 bytes, plus MAXDUPS
*-- three-byte dup/close records, plus the one-byte FDACT_END.
*-- Written as ADDITIONS ONLY -- no `*` mixed with `+` --
*-- because
*-- merlin32 applies precedence in an `equ` and real Merlin-8
*-- 2.59 goes strictly left to right, so `12+MAXDUPS*3+1` would
*-- be 25 to one assembler and 49 to the other with no complaint
*-- from either (this file's own MAXTOK comment records the same
*-- measurement).
*-- KFIX3 item 1: a FILE record (a later `>`/`N>`/`>>` on a
*-- stage) emits a dup AND a close, two records, so each of the
*-- MAXDUPS list entries is now worth six bytes, not three.
*-- Compound redirection (sec 18) adds up to TWO more dup/close
*-- pairs per stage -- an enclosing construct's `<` on fd 0 and
*-- another's `>` on fd 1, which can both be live at once when
*-- an IF with an output redirect sits inside a WHILE with an
*-- input one -- so 12 more bytes. Additions only, same
*-- dialect reason the original expression gives below.
DUPFD3      equ   MAXDUPS+MAXDUPS+MAXDUPS
FDABUFSZ    equ   12+12+DUPFD3+DUPFD3+15+1

*-- LASTSTATUS STAYS EMITTED, and it is not an oversight: `$?`
*-- (EMITSTATUS) reads it, and so do NEXT_SKIP and RW_THEN, on
*-- the FIRST line of a script -- before any command has run to
*-- set it. `ECHO $?` as the first line is the whole proof. It
*-- is one of the seven cells in this file that genuinely need
*-- a real zero; see the arena header at the file's end for the
*-- full list and docs/STICKY.md sec 28 for the ruling.
LASTSTATUS  ds    1

*-- SH_PTHFLL_LEN: hoisted to sh.s's top block.
*-- Was a bare `40` until 2026-08-23's absolute-command-word fix
*-- (RSLV_PTH_STG's :absolute branch) needed to know it was safe
*-- to hold a WHOLE ProDOS pathname. 40 < MLI_PTH_MAXLN(64): a
*-- legal 41..64-character absolute command word would have
*-- truncated into a SHORTER, DIFFERENT, possibly-real pathname
*-- and spawned it with no diagnostic -- the same shape of bug
*-- as MKPATH's own 64-char truncation (docs/E2E.md sec 10.6
*-- finding 1). Sized to match SH_PATHBUF, this buffer's own
*-- sibling for the identical purpose (a full MLI pathname), so
*-- every candidate this file ever builds -- PATH-resolved or
*-- absolute -- fits without truncation. Free: SH_PATHFULL lives
*-- in the `dum` arena below, which emits no image bytes (the
*-- arena-end tripwire at this file's end catches an overrun),
*-- so growing it does not touch BIN_DEBT or sh.bin's size.
*-- SH_PATHFULL/SH_PATHBUF (MLI pathname buffer, mli.equ shape)
*-- moved to the dum/dend block at the file's textual end
*-- (2026-08-21). SH_PATHFULL: BUILD_PATH's :cpfx/:cpword always
*-- write it whole (natural NUL, or one forced at the
*-- SH_PTHFLL_LEN boundary) immediately before PATH_EXISTS/
*-- RSLV_PTH_STG's caller ever reads it (see the :spawnloop site
*-- that reads it right after RSLV_PTH_STG runs); RSLV_PTH_STG's
*-- :absolute branch writes it the same way, bounded the same
*-- way, for the same reason. SH_PATHBUF:
*-- MKPATH always writes it whole immediately before
*-- OPEN_REDIR_RD/WR/AP's SC_OPEN/SC_CREAT/SC_UNLINK read it.

*-- OAPPEND-1: the parm RESTS at OPEN_APPEND -- its only other
*-- user, OPEN_REDIR_RD, stores OPEN_RO around its one call and
*-- puts this back; AP_TRY (`>>`, `exec N>>`) opens as is.
SH_OPARM       dfb   OPEN_APPEND
SH_OPARM_PATH  da    SH_PATHBUF
SH_OPRM_IOBUF da    0
SH_OPARM_REF   dfb   0

SH_CRT_PARM     dfb   PCOUNT_CREATE
SH_CRT_PATH     da    SH_PATHBUF
SH_CRT_ACCESS   dfb   ACCESS_UNLKD
SH_CRT_FTYPE    dfb   FTYPE_TXT   ;`> file` makes a text
                                        ;stream, not a binary
SH_CRT_AUXTYP  da    0
SH_CRT_STYPE    dfb   STYP_SEEDLING
SH_CRT_CDATE    da    0
SH_CRT_CTIME    da    0

SH_DSTRY_PARM    dfb   PCNT_DESTROY
SH_DSTRY_PATH    da    SH_PATHBUF

SH_CPARM       dfb   PCOUNT_CLOSE
SH_CPARM_REF   dfb   0

* -- OPEN_REDIR_AP (`>>`) scratch: the just-opened fd (kept
* -- across the LSEEK call so a failed seek can still close it),
* -- and the 3-byte lseek(fd,0,SEEK_END) offset buffer, always 0
* -- on input (append always seeks to the CURRENT end, never a
* -- caller-chosen delta -- docs/FLEET.md's own package).
SH_APND_FD  ds    1
SH_SEEKOFF  ds    3

*---------------------------------------------------------------
* SPLIT_APPEND -- IFS field splitting (V7 sh(1), "Blank
* Interpretation"): the RESULTS OF SUBSTITUTION in an unquoted
* word are split into distinct arguments at $IFS characters,
* and a word that substitutes to nothing yields NO argument at
* all (the implicit-null rule -- `ECHO $UNSET X` hands echo ONE
* argument). Sits between WORDEXPAND and GLOB_APPEND, argv
* words only: each field globs separately, which is Bourne's
* own split-then-glob order.
*
* WHAT SPLITS: only a word in which a substitution actually
* happened (EXPSUBST, set by WORDEXPAND/CMDSUBST) and only
* unquoted (CURQFLAG==0) -- `"$V"` stays one argument, a
* literal `A:B` under IFS=: stays one word (the manual's rule;
* the historical implementation split literals too, which is
* the famous IFS=/ hole, and the manual wins here). The whole
* RESULT is then scanned, so a literal fragment glued to a
* substitution (`A$V`) joins its neighbouring field exactly as
* Bourne joins them. Escaped bytes travel with bit 7 CLEAR
* (:besc) and can never match a high-bit separator, so `\ `
* splits nothing -- the same zero-cost literality GLOBMATCH
* already leans on.
*
* WHAT NEVER SPLITS, and why, each a measured Bourne rule:
*   - an ASSIGNMENT (first word, NAME=... shape): `V=$W` takes
*     the whole value. Tested on the EXPANDED word, the same
*     view CHCK_BLTN_VAR gets, so the two cannot disagree.
*     (It still reaches GLOB_APPEND, which POSIX would not do --
*     an assignment's value is not pathname-expanded. Costs
*     nothing HERE because a ProDOS name holds only letters,
*     digits and `.`, so no directory entry can ever match a
*     pattern containing `=` and an unmatched pattern passes
*     through literally: `V=*.S` assigns `*.S`, agreeing with
*     bash by the same invariant CS_CASEPAT leans on. If that
*     character set ever widens, this stops being free.)
*   - the word of `CASE word IN` (first word of the stage is
*     CASE): the case word is matched whole, never split.
*   - redirect targets/here-doc bodies: their PARSE arms call
*     WORDEXPAND without this routine at all.
*
* Runs of separators count as one, and leading/trailing
* separators vanish -- with the DEFAULT set that is exactly
* V7; the POSIX-era whitespace/non-whitespace distinction
* (IFS=: making `A::B` yield an empty middle field) postdates
* the fence and is deliberately not reproduced.
*
* IN: PTR0 = the word (an EXPBUF slice when EXPSUBST=1 --
* writable, each field gets its NUL laid in place), CURQFLAG.
* OUT: every field appended via GLOB_APPEND. CLOBBERS: A, X,
* Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
SPLIT_APPEND
            lda   CURQFLAG
            bne   :verbatim
            lda   EXPSUBST
            bne   :maybe
:verbatim   jmp   GLOB_APPEND
:maybe      lda   CURARGC
            beq   :asgnck
            jsr   PFX_ALLASG             ;`A=1 B=$X cmd`: B
            bcs   :asgnck                ;is an assignment too
            lda   CURARGC
            cmp   #1
            beq   :caseck
            bra   :dosplit
*-- Assignment shape: a letter, then `=` anywhere before the
*-- NUL -- CHCK_BLTN_VAR's own rule, applied to the same
*-- (expanded) bytes it will later read.
:asgnck     ldy   #0
            lda   (PTR0),y
            ora   #$80                   ;the literal NAME= text
                                         ;may carry EMITB_LIT's
                                         ;low marks -- match
                                         ;either form, exactly
                                         ;as UNESC will leave it
                                         ;for CHCK_BLTN_VAR
            cmp   #$C1                   ;'A'
            bcc   :dosplit
            cmp   #$DB                   ;past 'Z'
            bcs   :dosplit
:eqscan     iny
            lda   (PTR0),y
            beq   :dosplit               ;no '=' -- a command
            ora   #$80
            cmp   #$BD                   ;'=' high-bit-set
            bne   :eqscan
            bra   :verbatim              ;NAME=... -- one word
*-- `CASE $V IN` -- argv[1] of a CASE stage is the case WORD,
*-- matched whole (Bourne; bash agrees). STRCMPI wants both
*-- pointers, so the word is parked in SPLWORD across it.
:caseck     lda   PTR0
            sta   SPLWORD
            lda   PTR0+1
            sta   SPLWORD+1
            ldx   NCMD
            lda   STGOFF,x
            tax
            ldy   #0
            jsr   ARGV_ISSTR
            php
            lda   SPLWORD
            sta   PTR0
            lda   SPLWORD+1
            sta   PTR0+1
            plp
            bne   :dosplit
            bra   :verbatim
*-- The split proper. GLOB_APPEND owns every register and all
*-- three pointers, so the cursor state lives in the arena
*-- (SPLWORD/SPLSTART/SPLPOS) and PTR0 is rebuilt from it
*-- around every field.
*-- IFSSET is already resolved: EXPSUBST=1 is only ever set at
*-- WORDEXPAND :yes / CMDSUBST :dosub, and both call
*-- IFS_RESOLVE at the same site (they need it for EMITB_LIT's
*-- marking before a byte is emitted).
:dosplit    lda   PTR0
            sta   SPLWORD
            lda   PTR0+1
            sta   SPLWORD+1
            stz   SPLPOS
:next       ldy   SPLPOS
:skipsep    lda   (PTR0),y
            beq   :done                  ;separators (or
                                         ;nothing) to the end --
                                         ;implicit null: no
                                         ;argument at all
            jsr   ISIFS
            bne   :field
            iny
            bra   :skipsep
:field      sty   SPLSTART
:fscan      lda   (PTR0),y
            beq   :lastf
            jsr   ISIFS
            beq   :cut
            iny
            bra   :fscan
:cut        lda   #0
            sta   (PTR0),y               ;end this field in
            iny                          ;place (EXPBUF slice)
            sty   SPLPOS
            jsr   SPL_ONE
            bra   :next
:lastf      jmp   SPL_ONE
:done       rts

*---------------------------------------------------------------
* SPL_ONE -- append the field at SPLWORD+SPLSTART via
* GLOB_APPEND, then restore PTR0 to the word base for the next
* scan. CLOBBERS: A, X, Y, PTR1, PTR2 (PTR0 = SPLWORD after).
*---------------------------------------------------------------
SPL_ONE     lda   SPLWORD
            clc
            adc   SPLSTART
            sta   PTR0
            lda   SPLWORD+1
            adc   #0
            sta   PTR0+1
            jsr   GLOB_APPEND
            lda   SPLWORD
            sta   PTR0
            lda   SPLWORD+1
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* IFS_RESOLVE -- copy the active separator set into IFSSET,
* NUL-terminated: $IFS's value when the variable is SET (an
* empty value means NO splitting, since nothing can match), the
* V7 default -- space, tab, newline -- when it is not. Called
* once per split (SPLIT_APPEND) and once per `read`
* (CHCK_BLTN_RD :rdstart), never per byte. CLOBBERS: A, X, Y,
* PTR0, PTR1.
*---------------------------------------------------------------
IFS_RESOLVE lda   #<IFS_STR
            sta   PTR0
            lda   #>IFS_STR
            sta   PTR0+1
            jsr   VARFIND
            bcs   :default
            jsr   VSLOT_VAL              ;PTR1 = the value
            ldy   #0
:cpy        lda   (PTR1),y
            sta   IFSSET,y
            beq   :done
            iny
            cpy   #IFSSETMAX-1
            bcc   :cpy
            lda   #0                     ;truncate a monster
            sta   IFSSET,y               ;$IFS at 15 chars
:done       rts
:default    ldy   #0
:dcpy       lda   IFS_DEF,y
            sta   IFSSET,y
            beq   :ddone
            iny
            bra   :dcpy
:ddone      rts

*---------------------------------------------------------------
* ISIFS -- IN: A = a byte. OUT: Z SET if it is in the active
* separator set (IFSSET -- call IFS_RESOLVE first). Replaces
* the old fixed-set RDB_ISWS, same flag convention. Preserves
* X and Y; A is clobbered (every caller tests flags only).
*---------------------------------------------------------------
ISIFS       sta   SPLCH
            phy
            ldy   #0
:scan       lda   IFSSET,y
            beq   :no
            cmp   SPLCH
            beq   :yes
            iny
            bra   :scan
:yes        ply
            lda   #0                     ;sets Z
            rts
:no         ply
            lda   #1                     ;clears Z
            rts

IFS_STR     asc   "IFS"
            dfb   0
*-- The V7 default: "space, tab, and newline" -- newline is CR
*-- ($8D) in liba text, which is what a multi-line `$( )`
*-- capture carries between lines.
IFS_DEF     dfb   $A0,$89,$8D,0

*---------------------------------------------------------------
* GLOB_APPEND -- PTR0 = one parsed word. If it holds a glob
* metacharacter, expand it against the directory it names and
* APPEND_ARGV every match in sorted order; otherwise append the
* word untouched.
*
* Unmatched patterns pass through LITERALLY (Bourne). Overflow
* fails the line instead of truncating: a half-expanded `rm *`
* is the kind of failure you discover afterwards.
*
* Only the last path component is matched -- `a/b*/c` is not
* expanded across directories, which is the usual small-shell
* limit. The directory part is reused verbatim as each result's
* prefix, so `/mnt/MAUX/*.txt` yields `/mnt/MAUX/notes.txt`
* while a
* bare `*.txt` yields bare names, relative to the cwd.
*
* The kernel-owned directories -- `/`, `/dev`, `/mnt` -- have no
* blocks to walk (docs/VROOT.md), so :opendir asks SYN_OPEN
* (liba readsyn.s, the SAME enumerators `ls` lists them with)
* first; a synthetic directory is read through RD_READSYN into
* GREC and feeds the one matcher, GLOB_TRY, through GNAME. No
* ProDOS call is made for them, and /mnt never polls a Disk ][.
* Every kept match also leaves its storage type in GLOBTYP[slot]
* ($D directory, $F volume, $A/$B device) for tab completion.
*
* Consults CURQFLAG (docs/SH-SUBSET.md sec 8.4, the SECOND of
* the two required consultations -- WORDEXPAND is the first):
* ANY quoted word (CURQFLAG<>0, single OR double) skips
* globbing entirely and is appended verbatim -- `"A*B"`/`'*'`
* must reach the program as the literal text, not a directory
* match or an unmatched-pattern passthrough that merely LOOKS
* the same. Bare words (0) run the metacharacter check exactly
* as before.
*---------------------------------------------------------------
GLOB_APPEND lda   CURQFLAG
            beq   :chkmeta
            jmp   APPEND_ARGV            ;quoted -- never
                                         ;globbed
:chkmeta    jsr   HASMETA
            bcc   :expand
            jmp   APPEND_ARGV

:expand     lda   PTR0
            sta   GWORD
            lda   PTR0+1
            sta   GWORD+1
            stz   GLOBN

            ;-- split at the LAST '/' : prefix vs pattern
            ldy   #0
            lda   #$FF
            sta   GSLASH
:findlp     lda   (PTR0),y
            beq   :split
            cmp   #$AF                   ;'/' high-bit-set
            bne   :nextf
            sty   GSLASH
:nextf      iny
            bne   :findlp
:split      lda   GSLASH
            cmp   #$FF
            bne   :havedir

            ;-- no '/': match in the current prefix, and emit
            ;-- bare names, as a shell does
            stz   GPREFLN
            stz   GPATOFF
            lda   #<SH_PFXPARM
            ldx   #>SH_PFXPARM
            jsr   SC_GETPFX
            bcs   :golit
            bra   :opendir
:golit      jmp   :literal

:havedir    lda   GSLASH                 ;prefix keeps the '/'
            inc   a
            cmp   #65                    ;SH_GPATH holds 64: a
            bcs   :golit                 ;longer: stays literal
            sta   GPREFLN
            sta   GPATOFF
            ldy   #0
:cpdir      cpy   GPREFLN
            beq   :cpdone
            lda   (PTR0),y
            and   #$7F                   ;MLI wants 7-bit
            sta   SH_GPATH+1,y
            iny
            bra   :cpdir
:cpdone     sty   SH_GPATH
            lda   SH_GPATH+1       ;`./x*` `../x*`: the open
            cmp   #$2E             ;wants the dots resolved
            bne   :opendir         ;(MKPATH, as cmdpath.s)
            lda   GWORD
            sta   PTR0
            lda   GWORD+1
            sta   PTR0+1
            ldy   GPREFLN
            lda   (PTR0),y         ;the byte after the prefix
            sta   GSLASH           ;(GSLASH is spent)
            lda   #0
            sta   (PTR0),y         ;end the prefix for MKPATH
            lda   #<SH_GPATH
            sta   PTR1
            lda   #>SH_GPATH
            sta   PTR1+1
            jsr   MKPATH
            php
            ldy   GPREFLN
            lda   GSLASH
            sta   (PTR0),y         ;the word back as it was
            plp
            bcs   :golit

:opendir    lda   #<SH_GPATH
            ldx   #>SH_GPATH
            jsr   SYN_OPEN               ;`/`, `/dev`, `/mnt`:
            bcs   :realdir               ;no blocks to walk
            jmp   :synwalk
:realdir    lda   #<SH_GOPARM
            ldx   #>SH_GOPARM
            jsr   SC_OPEN
            bcs   :golit
            lda   SH_GOPARM_REF
            sta   GDFD
            sta   SH_GRPARM_REF

            ;-- key block: entry length, entries/block, count
            lda   #<SH_GRPARM
            ldx   #>SH_GRPARM
            jsr   SC_READ
            bcs   :goclit
            bra   :hdrok
:goclit     jmp   :closelit
:hdrok      lda   RD_DIRBUF+$23
            sta   GENTLEN
            lda   RD_DIRBUF+$24
            sta   GEPB
            lda   RD_DIRBUF+$25
            sta   GFCNT
            lda   RD_DIRBUF+$26
            sta   GFCNT+1
            stz   GACT
            stz   GACT+1
            clc
            lda   GENTLEN
            adc   #4
            adc   #<RD_DIRBUF
            sta   PTR2
            lda   #>RD_DIRBUF
            adc   #0
            sta   PTR2+1
            lda   #2
            sta   GBLKENT

:entlp      lda   GACT+1                 ;walked every active
            cmp   GFCNT+1                ;entry?
            bcc   :live
            lda   GACT
            cmp   GFCNT
            bcc   :live
            bra   :walked
:live       ldy   #0
            lda   (PTR2),y
            beq   :nextent               ;inactive slot
            jsr   GLOB_NAME              ;-> GNAME, decoded
            inc   GACT
            bne   :cmp
            inc   GACT+1
:cmp        jsr   GLOB_TRY
            bcc   :nextent
            jmp   :toomany

:nextent    lda   GBLKENT
            cmp   GEPB
            bne   :sameblk
            lda   #<SH_GRPARM            ;block exhausted
            ldx   #>SH_GRPARM
            jsr   SC_READ
            bcs   :rdfail
            lda   #1
            sta   GBLKENT
            clc
            lda   #<RD_DIRBUF
            adc   #4
            sta   PTR2
            lda   #>RD_DIRBUF
            adc   #0
            sta   PTR2+1
            bra   :entlp
:sameblk    clc
            lda   PTR2
            adc   GENTLEN
            sta   PTR2
            lda   PTR2+1
            adc   #0
            sta   PTR2+1
            inc   GBLKENT
            bra   :entlp

:rdfail     lda   TC_ON                  ;completion: a read
            sta   TC_ERR                 ;error: incomplete
:walked     jsr   GLOB_CLOSE
:sorted     lda   TC_ON                  ;completion: no sort,
            bne   :edone                 ;no argv words
            lda   GLOBN
            beq   :literal               ;no match: pass through
            jsr   GLOB_SORT
            stz   GEMIT
:emitlp     lda   GEMIT
            cmp   GLOBN
            bcs   :edone
            ldx   GEMIT                  ;emit in SORTED
            lda   GLOBIDX,x              ;order; GLOB_SLOT
            sta   GSLOT                  ;FREE slot, not what
            jsr   GLOB_SLOTX             ;returns the free one
            jsr   APPEND_ARGV
            inc   GEMIT
            bra   :emitlp
:edone      rts

:synwalk    lda   #<GREC                 ;a synthetic directory:
            sta   PTR0                   ;no fd to close; the
            lda   #>GREC                 ;record's name is GNAME
            sta   PTR0+1
            lda   RD_DFD                 ;the mode SYN_OPEN set
            jsr   RD_READSYN
            bcs   :sorted
            jsr   GLOB_TRY
            bcc   :synwalk
            bra   :err2
:toomany    jsr   GLOB_CLOSE
:err2       lda   #2                     ;same "too many
            sta   PARSE_ERR              ;arguments" the parser
            rts                          ;already reports

:closelit   jsr   GLOB_CLOSE
:literal    lda   TC_ON                  ;completion: a failed
            bne   :tcfail                ;open = incomplete scan
            lda   GWORD
            sta   PTR0
            lda   GWORD+1
            sta   PTR0+1
            jmp   APPEND_ARGV
:tcfail     jmp   TC_FAIL

*---------------------------------------------------------------
* GLOB_TRY -- match GNAME against the pattern part of the word
* and keep it behind the directory prefix if it fits. Carry SET
* only when there is no room for a match (GLOB_KEEP's verdict);
* a name that simply does not match is carry CLEAR. Shared by
* the ordinary-entry walk and the synthetic one.
*---------------------------------------------------------------
GLOB_TRY    lda   GWORD
            clc
            adc   GPATOFF
            sta   PTR0
            lda   GWORD+1
            adc   #0
            sta   PTR0+1
            lda   #<GNAME
            sta   PTR1
            lda   #>GNAME
            sta   PTR1+1
            jsr   GLOBMATCH
            bcs   :miss
            lda   TC_ON                  ;TAB completion keeps
            bne   :tckeep                ;it instead (shtabc.s)
            jmp   GLOB_KEEP
:tckeep     jmp   TC_KEEP
:miss       clc
            rts

GLOB_CLOSE  lda   GDFD
            sta   SH_GCPARM_REF
            lda   #<SH_GCPARM
            ldx   #>SH_GCPARM
            jmp   SC_CLOSE

*---------------------------------------------------------------
* GLOB_NAME -- copy the entry at PTR2 into GNAME as a high-bit
* NUL-terminated string, decoding the GS/OS case bitflags so a
* match and an `echo *` both see the name as written
* (docs/PRODOS-VERSION.md).
*---------------------------------------------------------------
GLOB_NAME   ldy   #0
            lda   (PTR2),y
            pha
            and   #$0F
            sta   GNLEN
            pla                          ;storage type, for
            lsr   a                      ;GLOB_KEEP, in the
            lsr   a                      ;record's RD_STYPE
            lsr   a                      ;(RD_READSYN fills it
            lsr   a                      ;for synthetic dirs)
            sta   GREC+RD_STYPE
            ldy   #$10                   ;file type, for the
            lda   (PTR2),y               ;completer's runnable
            sta   GREC+RD_FTYPE          ;filter (synthetic dirs
                                         ;fill it themselves)
            ldy   #$1C
            lda   (PTR2),y
            sta   GCLO
            iny
            lda   (PTR2),y
            sta   GCHI
            bmi   :flags
            stz   GCLO                   ;no flags: no folding
            stz   GCHI
:flags      asl   GCLO                   ;drop bit 15, the
            rol   GCHI                   ;"flags present" marker
            ldx   #0
:nlp        cpx   GNLEN
            beq   :nend
            asl   GCLO                   ;carry = this char's
            rol   GCHI                   ;case bit
            txa
            tay
            iny
            lda   (PTR2),y
            ora   #$80
            bcc   :put
            cmp   #$C1                   ;fold LETTERS only
            bcc   :put
            cmp   #$DB
            bcs   :put
            ora   #$20
:put        sta   GNAME,x
            inx
            bra   :nlp
:nend       lda   #0
            sta   GNAME,x
            rts

*---------------------------------------------------------------
* GLOB_KEEP -- append GNAME, behind the directory prefix, as the
* next result record. Carry SET if there is no room.
*---------------------------------------------------------------
GLOB_KEEP   lda   GLOBN
            cmp   #MAXGLOB
            bcs   :full
            jsr   GLOB_SLOT              ;-> PTR0 = free record
            lda   GWORD                  ;indirect needs ZP, and
            sta   PTR1                   ;GWORD is absolute
            lda   GWORD+1
            sta   PTR1+1
            ldy   #0
:pfx        cpy   GPREFLN
            beq   :pfxdone
            lda   (PTR1),y
            sta   (PTR0),y
            iny
            bra   :pfx
:pfxdone    ldx   #0
:nm         lda   GNAME,x
            sta   (PTR0),y
            beq   :kdone
            iny
            inx
            bra   :nm
:kdone      ldx   GLOBN                  ;the match's storage
            lda   GREC+RD_STYPE          ;type, per record slot:
            sta   GLOBTYP,x              ;$D dir, $F volume, ...
            inc   GLOBN
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* GLOB_SLOT -- PTR0 = record GEMIT (emit path) or GLOBN (keep
* path); the caller sets GSLOT first via the two entry points.
*---------------------------------------------------------------
GLOB_SLOT   lda   GLOBN                  ;default: the free slot
            sta   GSLOT
            bra   GLOB_SLOTX
GLOB_SLOTX  lda   #0
            sta   PTR0+1
            lda   GSLOT
            ldx   #6                     ;x64 -- GLOBREC
:shl        asl   a
            rol   PTR0+1
            dex
            bne   :shl
            clc
            adc   #<GLOBBUF
            sta   PTR0
            lda   PTR0+1
            adc   #>GLOBBUF
            sta   PTR0+1
            rts

*-- DERIVED from MAXARGV, not chosen: one word may expand to at
*-- most "every argv slot except argv[0]". It tracked MAXARGV by
*-- hand before (15 against 16), which is how a limit and its
*-- derivative drift apart -- docs/LIMITS.md names this pair as
*-- the instance that happened within a day.
*-- MAXGLOB (= MAXARGV-1): hoisted to sh.s's top block.
GLOBREC     equ   64
* -- The glob scratch cells that used to sit here moved to the
* -- dum/dend block at the file's textual end, joining the three
* -- named below. Every one of them is per-word or per-routine
* -- scratch written at its routine's head; the trace is in that
* -- block's own header.
* -- GLOBIDX/GLOBBUF moved to the dum/dend block at the
* -- file's textual end (2026-08-21). GLOBIDX: GLOB_SORT's :init
* -- loop always writes the identity permutation for slots --
* 0..GLOBN-1 before :outer/:inner (GLOB_CMP) or the emit loop --
* read any slot, and every reader stays bounded by the SAME --
* GLOBN. GLOBBUF: GLOB_KEEP writes record GLOBN (refusing >= --
* MAXGLOB before it ever writes) then increments GLOBN; every --
* reader (GLOB_CMP, the emit loop) only reaches a record through
* -- an index GLOB_SORT/GLOB_KEEP already published. RD_DIRBUF
* -- is liba's own 512-byte block buffer (libabss.s); sh kept a
* -- private duplicate, GDIRBUF, until 2026-10-17. RD_DIRBUF:
* only -- ever read after the SC_READ that fills it (a fixed
* 512-byte -- ProDOS directory-block read) returns success --
* both the -- initial header read and the block-exhausted refill
* check carry -- (bcs) before any header/entry byte is touched.

SH_PFXPARM     dfb   1
SH_PFXPRM_PTH  da    SH_GPATH
SH_GOPARM      dfb   PCOUNT_OPEN
SH_GOPARM_PTH  da    SH_GPATH
SH_GOPRM_IOBF  da    0
SH_GOPARM_REF  dfb   0
SH_GRPARM      dfb   PCOUNT_READ
SH_GRPARM_REF  dfb   0
SH_GRPARM_BUF  da    RD_DIRBUF
SH_GRPARM_REQ  da    512
SH_GRPARM_TRN  da    0
SH_GCPARM      dfb   PCOUNT_CLOSE
SH_GCPARM_REF  dfb   0
* -- SH_GPATH moved to the dum/dend block at the file's textual
* end -- (2026-08-21) -- the :cpdir loop always writes it whole
* (prefix -- bytes then the length byte at SH_GPATH itself, via
* `sty -- SH_GPATH`) before SC_OPEN (:opendir) ever reads it.
