*---------------------------------------------------------------
* findtop.s -- find's front half,
* extracted from find.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2 mains). One
* assembly stream: put exactly where the text sat; every rule
* in the manifest header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* START
*---------------------------------------------------------------
START       stz   ERRFLAG
            stz   DEPTH
            stz   CURRESN
            stz   CURRESN+1
            jsr   PARSE
            jsr   WALK
            lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* PARSE -- copy argv[1] into PATHBUF (CHKPATHARG-bounded,
* exactly as before), then hand argv[2..] to findexpr.s's
* TOKENIZE (the
* expression grammar) and VALIDATE (the syntax dry run). GETNOW
* runs once, after validation, only if a -mtime primary actually
* appeared (CLOCKNEED, set by TOKENIZE) -- POSIX's own
* "initialization time" wants find's OWN start, not some later
* moment. Does not return on a usage error (USAGE_ERR, exit 2).
* CLOBBERS: everything.
*---------------------------------------------------------------
PARSE       lda   ARGC
            cmp   #2
            bcs   :havepath
            jmp   USAGE_ERR
:havepath   lda   #1
            jsr   GETARG
            jsr   CHKPATHARG     ;PTR0 survives, by contract
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   STRCPY
            sta   PATHLEN
            jsr   TOKENIZE
            jsr   VALIDATE
            lda   CLOCKNEED
            beq   :pdone
            jsr   GETNOW
:pdone      rts

*---------------------------------------------------------------
* WALK -- iterative DFS over PATHBUF's tree. Visits PATHBUF
* itself first (classic find behavior: the starting point is
* tested against filters too, exactly like every descendant),
* then -- if it is a directory -- walks its contents. CLOBBERS:
* everything.
*---------------------------------------------------------------
WALK        jsr   MKPATHBUF
            lda   #<MLIPATH
            sta   GFIPARM_PATH
            lda   #>MLIPATH
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :rootok
            jsr   PRINTACCESERR
            lda   #1
            sta   ERRFLAG
            rts
:rootok     lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :risdir
            cmp   #$0F
            bne   :risfile
:risdir     lda   #1
            bra   :rgotkind
:risfile    lda   #0
:rgotkind   pha
*-- BASENAME TAKES PTR0 AND EVAL_TOP TAKES PTR1. These two
*-- lines used to load PTR1 and then call BASENAME, which reads
*-- and rewrites PTR0 -- so BASENAME operated on whatever PTR0
*-- happened to hold and the filter was handed the WHOLE PATH.
*-- `-name` therefore globbed against "/mnt/MAUX/DIR/FOO.TXT"
*-- and
*-- not "FOO.TXT", contradicting this file's own rule 1
*-- ("matched against the entry's own NAME only, not the whole
*-- path"). Fixed 2026-08-25.
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            jsr   BASENAME             ;PTR0 = the NAME alone
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            pla
            ldx   DEPTHFLAG
            beq   :rooteval
            cmp   #1                  ;-depth: a dir waits
            beq   :rootskip           ;for its contents
:rooteval   jsr   EVAL_TOP
:rootskip   lda   DEPTHFLAG
            beq   :rootpr
            stz   PRUNEFLAG           ;-depth: -prune no-op
:rootpr     lda   PRUNEFLAG
            beq   :rootcont
            rts                       ;-prune on the root itself
                                      ;-- nothing more to walk
:rootcont
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :godescend
            cmp   #$0F
            beq   :godescend
            rts                       ;root is a plain file --
                                      ;nothing more to walk
:godescend  stz   DEPTH
            stz   CURRESN
            stz   CURRESN+1
            jsr   OPENCUR
            bcc   :mainloop
            jsr   PRINTACCESERR
            lda   #1
            sta   ERRFLAG
            jsr   DEPTHACT            ;-depth: act on root
            rts

*---------------------------------------------------------------
* Main loop: read one entry from the currently-open directory
* (invariant: whenever DEPTH's level is "active", its directory
* IS open; every ancestor is closed).
*---------------------------------------------------------------
:mainloop   lda   #<RD_RECORD
            ldx   #>RD_RECORD
            jsr   READDIR
            bcc   :haveent           ;bcs/jmp trampoline -- the
            jmp   :leveldone         ;too-long path below pushed
                                     ;:leveldone out of range
:haveent    jsr   BUILDCHILD
            bcc   :fits
* -- child path exceeds MLI_PTH_MAXLN: no MLI call can ever
* -- open it, so report it loudly, count the entry for the
* -- resume bookkeeping, and keep walking the siblings. It
* -- must NOT reach CP_FULLPATH (PATHBUF stays <= 64) and
* -- must not descend even if it is a directory.
            jsr   PRINTLONGERR
            lda   #1
            sta   ERRFLAG
            inc   CURRESN
            bne   :mainloop
            inc   CURRESN+1
            bra   :mainloop
:fits       ldy   #RD_STYPE
            lda   RD_RECORD,y
            cmp   #STYP_DIR
            beq   :edir
            lda   #0
            bra   :ekind
:edir       lda   #1
:ekind      pha
*-- BASENAME TAKES PTR0 AND EVAL_TOP TAKES PTR1. These two
*-- lines used to load PTR1 and then call BASENAME, which reads
*-- and rewrites PTR0 -- so BASENAME operated on whatever PTR0
*-- happened to hold and the filter was handed the WHOLE PATH.
*-- `-name` therefore globbed against "/mnt/MAUX/DIR/FOO.TXT"
*-- and
*-- not "FOO.TXT", contradicting this file's own rule 1
*-- ("matched against the entry's own NAME only, not the whole
*-- path"). Fixed 2026-08-25.
            lda   #<FULLPATH
            sta   PTR0
            lda   #>FULLPATH
            sta   PTR0+1
            jsr   BASENAME             ;PTR0 = the NAME alone
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            lda   #<FULLPATH
            sta   PTR0
            lda   #>FULLPATH
            sta   PTR0+1
            pla
            ldx   DEPTHFLAG
            beq   :entryeval
            cmp   #1                  ;-depth: a directory waits
            beq   :entryskip          ;for its contents
:entryeval  jsr   EVAL_TOP
:entryskip  inc   CURRESN
            bne   :ecarry
            inc   CURRESN+1
:ecarry     lda   DEPTHFLAG
            beq   :ecpr
            stz   PRUNEFLAG
:ecpr       lda   PRUNEFLAG
            bne   :mainloop           ;pruned -- never descend,
                                      ;whatever kind it is
            ldy   #RD_STYPE
            lda   RD_RECORD,y
            cmp   #STYP_DIR
            bne   :mainloop           ;plain file -- next entry
            lda   DEPTH
            cmp   #FIND_MAXDEP
            bcc   :roomleft
            jsr   PRINTDEPTHERR
            jsr   CLOSEDIR
            lda   #2
            jsr   EXIT
:roomleft   jsr   PUSHFRAME
            jsr   CLOSEDIR
            jsr   CP_FULLPATH
            stz   CURRESN
            stz   CURRESN+1
            inc   DEPTH
            jsr   OPENCUR
            bcs   :descfail          ;bcs/jmp trampoline --
            jmp   :mainloop          ;:mainloop is out of bcc
                                     ;range since the too-long
                                     ;entry path was added
:descfail   jsr   PRINTACCESERR
            lda   #1
            sta   ERRFLAG
            jmp   :unwind

:leveldone  cmp   #0
            beq   :cleanof
            jsr   PRINTREADERR
            lda   #1
            sta   ERRFLAG
:cleanof    jsr   CLOSEDIR
:unwind     lda   DEPTH
            beq   :alldone
            jsr   DEPTHACT            ;-depth: act on PATHBUF
                                      ;(the dir just finished)
                                      ;before the pop
            jsr   POPFRAME
            jsr   OPENCUR
            bcc   :skipn
            jsr   PRINTACCESERR
            lda   #1
            sta   ERRFLAG
            jmp   :unwind
:skipn      jsr   SKIPRESUME
            jmp   :mainloop
:alldone    jsr   DEPTHACT            ;-depth: the root, last
            rts

*---------------------------------------------------------------
* DEPTHACT -- under -depth, run the expression against the
* directory whose listing has just finished (PATHBUF is its
* full path: CP_FULLPATH put it there on the way down and
* POPFRAME has not yet taken it back). A directory is acted on
* AFTER its contents, which is the whole of -depth. Does
* nothing without -depth. CLOBBERS: everything.
*---------------------------------------------------------------
DEPTHACT    lda   DEPTHFLAG
            beq   :no
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            jsr   BASENAME
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            lda   #1
            jsr   EVAL_TOP
            stz   PRUNEFLAG
:no         rts

*---------------------------------------------------------------
* BASENAME -- IN: PTR0 = string. OUT: PTR0 repointed past the
* LAST '/' (hi-bit), or unchanged if none. CLOBBERS: A, Y.
*---------------------------------------------------------------
BASENAME    ldy   #0
            lda   #$FF
            sta   BN_LAST
:scan       lda   (PTR0),y
            beq   :done
            cmp   #$AF               ;'/' high-bit
            bne   :next
            tya
            sta   BN_LAST
:next       iny
            bne   :scan
:done       lda   BN_LAST
            cmp   #$FF
            beq   :nofound
            inc   BN_LAST
            clc
            lda   BN_LAST
            adc   PTR0
            sta   PTR0
            lda   #0
            adc   PTR0+1
            sta   PTR0+1
:nofound    rts
