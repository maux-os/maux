*---------------------------------------------------------------
* lstop.s -- ls's front half,
* extracted from ls.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2 mains). One
* assembly stream: put exactly where the text sat; every rule
* in the manifest header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* START -- option parse, then dispatch to the cwd case or the
* two-pass (files-then-directories) path-argument case.
*---------------------------------------------------------------
START       jsr   LSINITPARM
            ldx   #FD_STDOUT         ;a batch printer: buffer
            jsr   SIO_SETFULL        ;fully even on a tty (the
                                     ;console scrolls once per
                                     ;write(); stdio.s)
            stz   LFLAG
            stz   TFLAG
            stz   RFLAG
            stz   CFLAG
            stz   ONEFLAG
            stz   DFLAG
            stz   FFLAG
            stz   SFLAG
            stz   RECFLAG
            stz   RCOUNT
            stz   RERRFLAG
            stz   ERRFLAG
            lda   ARGC
            cmp   #1
            bne   :hasarg
            jmp   :noopt
:hasarg
            lda   #1
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD              ;'-' high-bit
            beq   :isopt
            jmp   :noopt
:isopt
*-- one option WORD, clustered: "-lt", "-ltr". Still argv[1]
*-- only (the header's leading-word contract -- the old "one
*-- flag slot" reason is gone but a SECOND option word past a
*-- possible operand is still nothing V6-shaped), and a letter
*-- outside ltr is :badopt, "-" alone included.
            iny
            lda   (PTR0),y
            beq   :badopt           ;lone "-"
:optch      lda   (PTR0),y
            beq   :optdone
            cmp   #$EC              ;'l' high-bit
            bne   :not_l
            lda   #1
            sta   LFLAG
            bra   :optnx
:not_l      cmp   #$F4              ;'t' newest first
            bne   :not_t
            lda   #1
            sta   TFLAG
            bra   :optnx
:not_t      cmp   #$F2              ;'r' reverse
            bne   :not_r
            lda   #1
            sta   RFLAG
            bra   :optnx
:not_r      cmp   #$C3              ;'C' columns even when
            beq   :isc              ;stdout is not a console
            cmp   #$E3              ;'c'
            bne   :not_c
:isc        lda   #1
            sta   CFLAG
            bra   :optnx
:not_c      cmp   #$B1              ;'1' one name per line
            bne   :not_1
            lda   #1
            sta   ONEFLAG
            bra   :optnx
:not_1      cmp   #$E4              ;'d' directory itself
            bne   :not_d
            sta   DFLAG
            bra   :optnx
:not_d      cmp   #$C6              ;'F' type suffix
            bne   :not_f
            sta   FFLAG
            bra   :optnx
:not_f      cmp   #$F3              ;'s' blocks used
            bne   :not_s
            sta   SFLAG
            bra   :optnx
:not_s      cmp   #$D2              ;'R' recursive
            bne   :badopt
            sta   RECFLAG
:optnx      iny
            bra   :optch
:optdone    lda   #2
            sta   PATHSTART
            jmp   :argsdone
:badopt     lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT
:noopt      lda   #1
            sta   PATHSTART
:argsdone   lda   ARGC
            sec
            sbc   PATHSTART
            sta   NPATHS
            bne   :havepaths

*-- no path arguments: list the cwd --
            lda   #<GPPARM
            ldx   #>GPPARM
            jsr   SC_GETPFX
            bcs   :nocwd
            lda   PFXBUF            ;GET_PREFIX's count byte
            beq   :nocwd
            lda   #<PFXBUF
            ldx   #>PFXBUF
            jsr   LISTDIR
            bcc   :cwdrec
            lda   #1
            sta   ERRFLAG
:cwdrec     jsr   RUNREC
:cwdok      lda   ERRFLAG
            jsr   EXIT
:nocwd      lda   #<NOCWDMSG
            sta   PTR0
            lda   #>NOCWDMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

*---------------------------------------------------------------
* VALIDATE -- scan every path-list argument (argv[PATHSTART..])
* for a leading "-" BEFORE pass 1 does any work, per the file
* header's CONTRACT: ANY such argument -- "-l" included, no
* exceptions -- is an unknown option there (usage to stderr,
* exit 2, nothing else printed).
*---------------------------------------------------------------
:havepaths  stz   PATHIDX
:vloop      lda   PATHIDX
            cmp   NPATHS
            bcs   :vdone
            clc
            adc   PATHSTART
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD              ;'-' high-bit
            beq   :badopt           ;any dash past argv[1] is
                                     ;an unknown option here --
                                     ;see the header's CONTRACT
            inc   PATHIDX
            jmp   :vloop
:vdone      jsr   OPTKEYS           ;-t: stat times BEFORE the
            jsr   SORTPATHS         ;sort that needs them
            stz   PATHIDX
*-- docs/DEVFS.md: learn once whether THIS invocation's cwd is
*-- the synthetic /dev -- LS_DEVCHK needs it for a bare relative
*-- operand ("cd /dev; ls s6d1"). PFXBUF comes back low-bit
*-- (PRC_GETPFX copies K_CWD_BUF verbatim), the SAME spelling
*-- PRC_SETPFX always records it in -- an exact byte compare,
*-- no fold needed.
            stz   LS_CWDDEV
            lda   #<GPPARM
            ldx   #>GPPARM
            jsr   SC_GETPFX
            bcs   :p1init
            lda   PFXBUF
            cmp   #5
            bne   :p1init
            lda   PFXBUF+1
            cmp   #"/"+$80
            bne   :p1init
            lda   PFXBUF+2
            cmp   #"d"+$80
            bne   :p1init
            lda   PFXBUF+3
            cmp   #"e"+$80
            bne   :p1init
            lda   PFXBUF+4
            cmp   #"v"+$80
            bne   :p1init
            lda   PFXBUF+5
            cmp   #"/"+$80
            bne   :p1init
            lda   #1
            sta   LS_CWDDEV
:p1init

*---------------------------------------------------------------
* PASS 1 -- stat every path argument. Files print now; deferred
* directories are remembered in STYPES for pass 2.
*---------------------------------------------------------------
:p1loop     lda   PATHIDX
            cmp   NPATHS
            bcs   :p1done
            ldy   PATHIDX
            lda   PORDER,y        ;sorted operand order, not
            clc                   ;argv order -- see SORTPATHS
            adc   PATHSTART
            sta   ARGIDX
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            jsr   LS_DEVCHK         ;docs/DEVFS.md: a device
                                    ;operand is SYNTHESISED,
                                    ;never
                                    ;GET_FILE_INFO'd (it would
                                    ;just fail)
            bcc   :gfiok
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :gfiok
            ldy   PATHIDX
            lda   #$FF
            sta   STYPES,y
            jsr   PRINTACCESERR
            lda   #1
            sta   ERRFLAG
            jmp   :p1next
:gfiok      lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #$0F              ;volume-dir storage_type --
            beq   :isdir            ;no house constant for this
                                    ;one
            ldy   PATHIDX
            lda   #0
            sta   STYPES,y
            jsr   PRINTARGFILE
            jmp   :p1next
:isdir      ldy   PATHIDX
            lda   DFLAG
            beq   :deferdir
            lda   #0
            sta   STYPES,y
            jsr   PRINTARGFILE
            jmp   :p1next
:deferdir
            lda   GFIPARM_STYP
            sta   STYPES,y
:p1next     inc   PATHIDX
            jmp   :p1loop
:p1done

*---------------------------------------------------------------
* PASS 2 -- list every directory deferred by pass 1, in argument
* order, with the header/blank-line rule from the file header.
*---------------------------------------------------------------
            stz   DIRSHOWN
            stz   PATHIDX
:p2loop     lda   PATHIDX
            cmp   NPATHS
            bcc   :p2go
            jmp   :p2done
:p2go       ldy   PATHIDX
            lda   STYPES,y
            cmp   #STYP_DIR
            beq   :p2isdir
            cmp   #$0F
            bne   :p2next
:p2isdir    ldy   PATHIDX
            lda   PORDER,y        ;sorted, as pass 1
            clc
            adc   PATHSTART
            sta   ARGIDX
            lda   NPATHS
            cmp   #1
            beq   :nohdr            ;single argument -- no
                                    ;header, -R included: BSD
                                    ;`ls -R D` names D's
                                    ;SUBDIRECTORIES, never D
                                    ;itself (PRRHEAD does that)
            lda   DIRSHOWN
            beq   :firsthdr
            lda   #$8D              ;blank line BETWEEN listings
            ldx   #FD_STDOUT
            jsr   PUTC
:firsthdr   lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$BA              ;':' high-bit
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #1
            sta   DIRSHOWN
:nohdr      lda   ARGIDX
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<PATHBUF
            ldx   #>PATHBUF
            jsr   LISTDIR
            bcc   :p2ok
            jsr   PRINTACCESERR
            lda   #1
            sta   ERRFLAG
            jmp   :p2next
:p2ok       lda   TRUNCATED
            beq   :p2rec
            jsr   PRINTTRUNCERR
            lda   #1
            sta   ERRFLAG
:p2rec      jsr   RUNREC
:p2next     inc   PATHIDX
            jmp   :p2loop
:p2done     lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* PRINTACCESERR / PRINTTRUNCERR -- "ls: <ARGIDX's path>: ...".
*---------------------------------------------------------------
PRINTACCESERR
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
            lda   #<ERRSUF_ACCESS
            sta   PTR0
            lda   #>ERRSUF_ACCESS
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

PRINTTRUNCERR
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
            lda   #<ERRSUF_TRUNC
            sta   PTR0
            lda   #>ERRSUF_TRUNC
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

*---------------------------------------------------------------
* PRINTARGFILE -- print the one-line report for a non-directory
* path ARGUMENT (ARGIDX), using GFIPARM's already-populated
* result fields. Short mode just prints the path text.
*---------------------------------------------------------------
PRINTARGFILE
            lda   SFLAG
            beq   :nosize
            lda   GFIPARM_BLKS
            sta   U2DEC_VAL
            lda   GFIPARM_BLKS+1
            sta   U2DEC_VAL+1
            jsr   PRINTBLKS
:nosize
            lda   LFLAG
            bne   :long
            lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDOUT
            jsr   PUTS
            jsr   PRINTARGSUF
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts
:long       lda   GFIPARM_STYP      ;a device (LS_DEVCHK, or the
            cmp   #RD_STYPE_BLK     ;kernel stat) is BLK/CHR,
            bne   :notblk           ;as PRINTENTLONG: not $00
            lda   #<BLKSTR
            ldx   #>BLKSTR
            bra   :tstr
:notblk     cmp   #RD_STYPE_CHR
            bne   :notchr
            lda   #<CHRSTR
            ldx   #>CHRSTR
:tstr       jsr   PRINTTSTR
            bra   :typedone
:notchr     lda   GFIPARM_FTYP
            jsr   PRINTTYPE
:typedone   lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PRINTBLKSCOL
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   GFIPARM_MDATE
            sta   DTDATE
            lda   GFIPARM_MDATE+1
            sta   DTDATE+1
            lda   GFIPARM_MTIME
            sta   DTTIME
            lda   GFIPARM_MTIME+1
            sta   DTTIME+1
            jsr   PRINTDATE
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDOUT
            jsr   PUTS
            jsr   PRINTARGSUF
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

PRINTARGSUF lda   FFLAG
            beq   :done
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :slash
            cmp   #$0F
            bne   :done
:slash      lda   #$AF
            ldx   #FD_STDOUT
            jsr   PUTC
:done       rts

*---------------------------------------------------------------
* LS_DEVCHK -- docs/DEVFS.md. PATHBUF is already built by MKPATH
* for the CURRENT operand. Detects one that names a device --
* "/dev/NAME" typed absolute, or a bare relative NAME while this
* process's cwd is the synthetic "/dev" (LS_CWDDEV, computed
* once
* in VALIDATE) -- and if so populates GFIPARM's RESULT fields
* exactly as a successful GET_FILE_INFO would, so pass 1's
* existing :gfiok/PRINTARGFILE path handles it unchanged. Skips
* the real MLI call entirely: there is no such ProDOS file, and
* GET_FILE_INFO would just fail.
*
* A "device" is one of readdir.s's 7 fixed names (RD_FN0-6/
* RD_FNLO/RD_FNHI, char devices) OR the shape `sNdM` (N a slot
* digit 1-7, M a drive digit 1-2) WITH that unit actually
* present
* in DEVLST right now (one SYS_DEVLIST call) -- a typo like
* `/dev/s9d1` is an ordinary "no such file", not a device.
*
* OUT: carry CLEAR = device found, GFIPARM_FTYP/STYP/BLKS/MDATE/
* MTIME populated (FTYP 0, STYP RD_STYPE_CHR or RD_STYPE_BLK,
* sizes/dates zero); carry SET = not a device, caller does the
* ordinary SC_GFI. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
*-- "/", "/dev", "/mnt" stat as directories in the KERNEL now
*-- (PRC_GFI, docs/VROOT.md); this file had its own copy.

*-- EVERY far transfer below is written `bxx! :okN / jmp :notdev
*-- / :okN` rather than a direct `bxx :notdev`: this routine is
*-- well past a branch's +-127 range end to end, and `jmp` has
*-- no
*-- such limit. The inverted-branch-over-a-jump shape keeps each
*-- individual test a fixed 5 bytes regardless of WHERE :notdev
*-- ends up after edits.
LS_DEVCHK   lda   PATHBUF
            bne   :ok1
            jmp   :notdev
:ok1        lda   PATHBUF+1
            and   #$7F
            cmp   #'/'
            bne   :relative
*-- absolute -- must be "/dev/NAME", length > 5, name starts at
*-- PATHBUF+6.
            lda   PATHBUF
            cmp   #6
            bcs   :ok2
            jmp   :notdev
:ok2        lda   PATHBUF+2
            jsr   RD_FOLD
            cmp   #'D'
            beq   :ok3
            jmp   :notdev
:ok3        lda   PATHBUF+3
            jsr   RD_FOLD
            cmp   #'E'
            beq   :ok4
            jmp   :notdev
:ok4        lda   PATHBUF+4
            jsr   RD_FOLD
            cmp   #'V'
            beq   :ok5
            jmp   :notdev
:ok5        lda   PATHBUF+5
            and   #$7F
            cmp   #'/'
            beq   :ok6
            jmp   :notdev
:ok6        lda   PATHBUF
            sec
            sbc   #5
            sta   LSD_NAMLEN
            ldx   #5                 ;name chars start at
                                     ;PATHBUF+6 -- see the copy
                                     ;loop's `inx` below
            bra   :havelen
:relative   lda   LS_CWDDEV
            bne   :ok7
            jmp   :notdev
:ok7        lda   PATHBUF
            sta   LSD_NAMLEN
            ldx   #0                 ;name chars start at
                                     ;PATHBUF+1
:havelen    lda   LSD_NAMLEN
            bne   :ok8
            jmp   :notdev
:ok8        cmp   #6
            bcc   :ok9               ;too long for any device
            jmp   :notdev
:ok9        ldy   #0
:cpname     cpy   LSD_NAMLEN
            beq   :havebuf
            inx
            lda   PATHBUF,x
            jsr   RD_FOLD
            sta   LSD_NAMBUF,y
            iny
            bra   :cpname
:havebuf    jsr   LSD_MATCH          ;one of the 7 fixed names?
            bcs   :cknotfix
            lda   #0
            sta   GFIPARM_FTYP
            lda   #RD_STYPE_CHR
            sta   GFIPARM_STYP
            jmp   :zerosize
:cknotfix
*-- sNdM shape: 's' slot-digit(1-7) 'd' drive-digit(1-2).
            lda   LSD_NAMLEN
            cmp   #4
            beq   :ok10
            jmp   :notdev
:ok10       lda   LSD_NAMBUF
            cmp   #'S'
            beq   :ok11
            jmp   :notdev
:ok11       lda   LSD_NAMBUF+1
            cmp   #'0'
            bcs   :ok12
            jmp   :notdev
:ok12       cmp   #'8'
            bcc   :ok13
            jmp   :notdev
:ok13       sec
            sbc   #'0'
            asl   a
            asl   a
            asl   a
            asl   a
            sta   LSD_UNIT           ;slot<<4
            lda   LSD_NAMBUF+2
            cmp   #'D'
            beq   :ok14
            jmp   :notdev
:ok14       lda   LSD_NAMBUF+3
            cmp   #'1'
            beq   :d1
            cmp   #'2'
            beq   :ok15
            jmp   :notdev
:ok15       lda   #$80
            ora   LSD_UNIT
            bra   :haveunit
:d1         lda   LSD_UNIT
:haveunit   sta   LSD_UNIT
*-- confirm the unit is really online right now.
            lda   #<LSD_DEVBUF
            sta   PTR0
            lda   #>LSD_DEVBUF
            sta   PTR0+1
            jsr   SC_DEVLIST
            sta   LSD_DEVN
            ldx   #0
:dscan      cpx   LSD_DEVN
            bcc   :ok16
            jmp   :notdev
:ok16       lda   LSD_DEVBUF,x
            and   #$F0
            cmp   LSD_UNIT
            beq   :isblk
            inx
            bra   :dscan
:isblk      lda   #0
            sta   GFIPARM_FTYP
            lda   #RD_STYPE_BLK
            sta   GFIPARM_STYP
:zerosize   stz   GFIPARM_BLKS
            stz   GFIPARM_BLKS+1
            stz   GFIPARM_MDATE
            stz   GFIPARM_MDATE+1
            stz   GFIPARM_MTIME
            stz   GFIPARM_MTIME+1
            clc
            rts
:notdev     sec
            rts

*---------------------------------------------------------------
* LSD_MATCH -- IN: LSD_NAMBUF/LSD_NAMLEN, already folded upper
* case. OUT: carry CLEAR = matches one of readdir.s's 7 fixed
* `/dev` names (RD_FNLO/RD_FNHI, RD_FOLD -- shared with the
* synthetic OPENDIR walk, not duplicated). CLOBBERS: A, X, Y,
* PTR0.
*---------------------------------------------------------------
LSD_MATCH   ldx   #0
:tloop      cpx   #7
            beq   :nomatch
            lda   RD_FNLO,x
            sta   PTR0
            lda   RD_FNHI,x
            sta   PTR0+1
            phx
            ldy   #0
            lda   (PTR0),y
            cmp   LSD_NAMLEN
            bne   :nexti
:cloop      cpy   LSD_NAMLEN
            beq   :hit
            iny
            lda   (PTR0),y
            jsr   RD_FOLD
            dey
            cmp   LSD_NAMBUF,y
            bne   :nexti
            iny
            bra   :cloop
:hit        plx
            clc
            rts
:nexti      plx
            inx
            bra   :tloop
:nomatch    sec
            rts
