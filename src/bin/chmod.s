*---------------------------------------------------------------
* chmod.s -- change a ProDOS file's access byte.
*
* Usage: chmod [+-]FLAGS file...
*
* NOT Unix rwx (docs/ANACHRONISMS.md sec W2 -- a FORGO: ProDOS's
* access byte has no owner/group/other, only five real bits, so
* mapping rwx onto it "would be a lie in both directions"; the
* GNO/ME precedent, learning:01M0798FFCHB60SWQDE8NQEQXN, chose
* to speak the native byte instead and this follows that
* ruling). The ProDOS 8 TRM access byte (ch. 4.4.3):
*
*   bit 7 6 5 4-2    1 0
*       D RN B  rsvd W R
*
* THIS TOOL'S FLAG LETTERS (chosen here, matching GNO's own
* rwdnbi minus the GS/OS-only 'i' bit, which plain ProDOS 8 does
* not have):
*   d = destroy-enable   n = rename-enable   b = backup-needed
*   w = write-enable     r = read-enable
* A single leading '+' sets every named bit, '-' clears every
* named bit; bits 4-2 are reserved and this tool never touches
* them ("only ProDOS may change" them -- TRM).
*
* THE LOCK/UNLOCK IDIOM (the common real use): a locked file is
* the classic ProDOS access byte $21 (backup+read only -- D/RN/W
* all clear); a fully-open file is $C3/$E3 (D/RN/W/R set, B
* either way). So:
*   chmod -dnw FILE     locks FILE (resists DESTROY/RENAME and
*                       further writes)
*   chmod +dnw FILE     unlocks it again
*
* READ-MODIFY-WRITE (the whole reason this needs a kernel call
* rather than a hand-built parmlist per caller): SET_FILE_INFO
* ($C3) takes a FULL parameter block -- access, file_type,
* aux_type, mod_date, mod_time -- and writes every one of those
* fields verbatim. A caller that sends zeros for the fields it
* doesn't mean to change DESTROYS them. So this tool always
* GET_FILE_INFOs the target FIRST, changes ONLY the access byte
* in memory, and writes file_type/aux_type/mod_date/mod_time
* straight back unchanged (create_date/create_time are not even
* part of SET_FILE_INFO's parmlist -- TRM 4.4.4 -- so they can
* never be touched by this call at all). See scripts/
* check_chmod.py for the read-back proof: after locking and
* unlocking a file, every GET_FILE_INFO field except access is
* asserted byte-identical to what was staged.
*
* A path that fails GET_FILE_INFO prints "chmod: <path>: cannot
* access" to stderr; one that fails SET_FILE_INFO (e.g. a
* directory, or a volume that itself rejects the write) prints
* "chmod: <path>: cannot change mode" -- either way ERRFLAG is
* set, chmod continues with the remaining arguments, and exits
* 1. Fewer than 2 arguments, or a FLAGS string that is not
* '+'/'-' followed by one or more of d/n/b/w/r, is a usage
* error to stderr, exit 2.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/chmod.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*---------------------------------------------------------------
* START -- parse argv[1] into SETFLAG/FMASK, then apply it to
* every remaining argument.
*---------------------------------------------------------------
START       stz   ERRFLAG
            lda   ARGC
            cmp   #3
            bcs   :haveargs
            jmp   USAGE_ERR
:haveargs   lda   #1
            jsr   GETARG            ;PTR0 = argv[1] (flags)
            ldy   #0
            lda   (PTR0),y
            cmp   #$AB              ;'+' high-bit
            beq   :setmode
            cmp   #$AD              ;'-' high-bit
            beq   :clrmode
            jmp   USAGE_ERR
:setmode    lda   #1
            sta   SETFLAG
            bra   :scanfl
:clrmode    stz   SETFLAG
:scanfl     stz   FMASK
            iny
:floop      lda   (PTR0),y
            beq   :fdone
            cmp   #$E4              ;'d' high-bit
            bne   :fn1
            lda   #ACC_DESTROY
            bra   :orbit
:fn1        cmp   #$EE              ;'n' high-bit
            bne   :fn2
            lda   #ACC_RENAME
            bra   :orbit
:fn2        cmp   #$E2              ;'b' high-bit
            bne   :fn3
            lda   #ACC_BACKUP
            bra   :orbit
:fn3        cmp   #$F7              ;'w' high-bit
            bne   :fn4
            lda   #ACC_WRITE
            bra   :orbit
:fn4        cmp   #$F2              ;'r' high-bit
            beq   :isr
            jmp   USAGE_ERR
:isr        lda   #ACC_READ
:orbit      ora   FMASK
            sta   FMASK
            iny
            bra   :floop
:fdone      lda   FMASK
            bne   :startfl
            jmp   USAGE_ERR         ;"+" or "-" with no letters

*---------------------------------------------------------------
* Per-file loop -- argv[2..ARGC-1].
*---------------------------------------------------------------
:startfl    lda   #2
            sta   ARGIDX
:aloop      lda   ARGIDX
            cmp   ARGC
            bcs   :adone
            jsr   GETARG            ;PTR0 = argv[ARGIDX]
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<PATHBUF
            sta   GFIPARM_PATH
            lda   #>PATHBUF
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :gfiok
            jsr   PRINTACCFAIL
            jmp   :anext
:gfiok      jsr   COMPUTEACC
            lda   #<PATHBUF
            sta   SFIPARM_PATH
            lda   #>PATHBUF
            sta   SFIPARM_PATH+1
            lda   GFIPARM_FTYP
            sta   SFIPARM_FTYP
            lda   GFIPARM_AUX
            sta   SFIPARM_AUX
            lda   GFIPARM_AUX+1
            sta   SFIPARM_AUX+1
            stz   SFIPARM_NULL
            stz   SFIPARM_NULL+1
            stz   SFIPARM_NULL+2
            lda   GFIPARM_MDATE
            sta   SFIPARM_MDATE
            lda   GFIPARM_MDATE+1
            sta   SFIPARM_MDATE+1
            lda   GFIPARM_MTIME
            sta   SFIPARM_MTIME
            lda   GFIPARM_MTIME+1
            sta   SFIPARM_MTIME+1
            lda   #<SFIPARM
            ldx   #>SFIPARM
            jsr   SC_SFI
            bcc   :anext
            jsr   PRINTCHFAIL
:anext      inc   ARGIDX
            jmp   :aloop
:adone      lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* COMPUTEACC -- IN: GFIPARM_ACC, SETFLAG, FMASK. OUT:
* SFIPARM_ACC := GFIPARM_ACC with FMASK's bits set (SETFLAG<>0)
* or cleared (SETFLAG=0). Every bit NOT in FMASK is left exactly
* as GET_FILE_INFO reported it -- this IS the read-modify-write
* for the access byte itself, same discipline as every other
* SFIPARM field. CLOBBERS: A, Y.
*---------------------------------------------------------------
COMPUTEACC  lda   FMASK
            eor   #$FF
            sta   NOTMASK
            lda   GFIPARM_ACC
            ldy   SETFLAG
            beq   :doclear
            ora   FMASK
            sta   SFIPARM_ACC
            rts
:doclear    and   NOTMASK
            sta   SFIPARM_ACC
            rts

*---------------------------------------------------------------
* USAGE_ERR -- usage to stderr, exit 2. Does not return.
*---------------------------------------------------------------
USAGE_ERR   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* PRINTACCFAIL/PRINTCHFAIL -- "chmod: <ARGIDX's arg>: ..." to
* stderr, sets ERRFLAG. Re-GETARGs (PUTS clobbers PTR0).
*---------------------------------------------------------------
PRINTACCFAIL
            lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<ERRSUF_ACC
            sta   PTR0
            lda   #>ERRSUF_ACC
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            sta   ERRFLAG
            rts

PRINTCHFAIL lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<ERRSUF_CH
            sta   PTR0
            lda   #>ERRSUF_CH
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            sta   ERRFLAG
            rts

*---------------------------------------------------------------
* Data
*---------------------------------------------------------------
USAGEMSG    asc   "usage: chmod [+-]FLAGS file..."
            dfb   $8D,0
ERRPFX      asc   "chmod: "
            dfb   0
ERRSUF_ACC  asc   ": cannot access"
            dfb   $8D,0
ERRSUF_CH   asc   ": cannot change mode"
            dfb   $8D,0

* -- GET_FILE_INFO ($C4), PCOUNT_GFI-shaped (mli.equ).
GFIPARM     dfb   PCOUNT_GFI
GFIPARM_PATH da   0
GFIPARM_ACC dfb   0
GFIPARM_FTYP dfb  0
GFIPARM_AUX da    0
GFIPARM_STYP dfb  0
GFIPARM_BLKS da   0
GFIPARM_MDATE da  0
GFIPARM_MTIME da  0
GFIPARM_CDATE da  0
GFIPARM_CTIME da  0

* -- SET_FILE_INFO ($C3), PCOUNT_SFI-shaped (mli.equ): pathname,
* -- access, file_type, aux_type, null_field (3 bytes -- TRM:
* -- "preserve symmetry between this and GET_FILE_INFO"; should
* -- be zero), mod_date, mod_time. No storage_type/blocks_used/
* -- create_date/create_time slots -- not settable this way.
SFIPARM     dfb   PCOUNT_SFI
SFIPARM_PATH da   0
SFIPARM_ACC dfb   0
SFIPARM_FTYP dfb  0
SFIPARM_AUX da    0
SFIPARM_NULL dfb  0,0,0
SFIPARM_MDATE da  0
SFIPARM_MTIME da  0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* chmod's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*` (two
* blocks at `*` are the same bytes; libabss.s already opened
* one there). Anything emitted after `dend` would silently
* overlay this (learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - ERRFLAG: `stz` as START's first instruction, so the
*    exit-status read at :adone can never see a stale value.
*  - ARGIDX: `lda #2 / sta ARGIDX` before the first :aloop
*    read.
*  - SETFLAG: written on BOTH arms of the '+'/'-' test; every
*    other character jumps to USAGE_ERR.
*  - FMASK: `stz` at :scanfl, the single join point both arms
*    reach -- it is a parse accumulator that is explicitly
*    cleared, not one relying on a zero start.
*  - NOTMASK: `sta` as COMPUTEACC's third instruction, before
*    its own :doclear read.
*  - PATHBUF: MKPATH writes the char data and then the count
*    byte, and the MLI reads only count+1 bytes -- the tail is
*    never in view. GFIPARM/SFIPARM stay emitted above; their
*    `da PATHBUF` still resolves to this arena's address.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ARGIDX      ds    1
ERRFLAG     ds    1
SETFLAG     ds    1
FMASK       ds    1
NOTMASK     ds    1

PATHBUF     ds    65
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
