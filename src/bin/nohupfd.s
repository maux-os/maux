*---------------------------------------------------------------
* nohupfd.s -- nohup's own NOHUP.OUT redirection package:
* NH_ISTTY (tty.s's device-name isatty check), NH_APPOPEN
* (CREATE+OPEN+lseek-to-EOF, tee.s's `-a` package), NH_HOMEPTH
* ($HOME + "/NOHUP.OUT" text builder), NH_FDADD1/NH_FDADD2 (the
* fdactions FDACT_DUP record builder), plus every message
* string nohup.s prints. `put` by src/bin/nohup.s (NOT a
* standalone binary -- the same put-module shape as cal.s's own
* calcalc.s), split out for the same reason units split
* anywhere: `as`'s 16,128-byte source window holds the resident
* manifest plus one put file at a time, and nohup.s's own text
* alone was past it (measured 17,800 B stripped, over by
* 1,674). Every symbol here resolves against nohup.s's own
* equates and data (NH_ISOUT/NH_ISERR/NH_SRCFD/NH_FI/NH_TMPFD/
* NH_SEEKOF/NH_RAWBUF/NH_MLIBUF/FDABUF/NH_CRPARM/NH_OPARM/
* NH_CPARM) -- see nohup.s's own header for the design.
*---------------------------------------------------------------
*---------------------------------------------------------------
* NH_ISTTY -- IN: A = fd. OUT: A = 1 if that fd is one of the
* device handles tty.s itself names (FD_TTY0-3, FD_SER0) -- NOT
* FD_NULL, same narrowing tty.s's own header explains; A = 0
* otherwise (including SC_FDSTAT failure). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
NH_ISTTY    jsr   SC_FDSTAT
            bcs   :no
            cmp   #FD_TTY0
            bcc   :no
            cmp   #FD_TTY3+1
            bcc   :yes
            cmp   #FD_SER0
            bne   :no
:yes        lda   #1
            rts
:no         lda   #0
            rts

*---------------------------------------------------------------
* NH_APPOPEN -- CREATE (ignore "already exists") + OPEN + lseek
* to EOF on NH_MLIBUF, the tee.s `-a` / sh `>>` package. OUT:
* carry CLEAR, A = the opened fd; carry SET on an OPEN or seek
* failure (the fd is closed again in the seek-failure case).
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
NH_APPOPEN  lda   #<NH_CRPARM
            ldx   #>NH_CRPARM
            jsr   SC_CREAT           ;ignore dup-name error
            lda   #<NH_OPARM
            ldx   #>NH_OPARM
            jsr   SC_OPEN
            bcs   :fail
            lda   NH_OPARM_RF
            sta   NH_TMPFD
            stz   NH_SEEKOF
            stz   NH_SEEKOF+1
            stz   NH_SEEKOF+2
            lda   #<NH_SEEKOF
            sta   PTR0
            lda   #>NH_SEEKOF
            sta   PTR0+1
            lda   NH_TMPFD
            ldy   #SEEK_END
            jsr   LSEEK
            bcs   :seekfail
            lda   NH_TMPFD
            clc
            rts
:seekfail   lda   NH_TMPFD
            sta   NH_CPARM_RF
            lda   #<NH_CPARM
            ldx   #>NH_CPARM
            jsr   SC_CLOSE
:fail       sec
            rts

*---------------------------------------------------------------
* NH_HOMEPTH -- IN: PTR1 = $HOME's value (high-bit, NUL-term).
* OUT: NH_RAWBUF = PTR1 + '/' + "NOHUP.OUT", NUL-terminated;
* carry SET if it does not fit. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
NH_HOMEPTH  ldy   #0
            ldx   #0
:cplp       lda   (PTR1),y
            beq   :cpdone
            cpx   #NH_RAWSZ-11
            bcs   :over
            sta   NH_RAWBUF,x
            iny
            inx
            bra   :cplp
:cpdone     lda   #$AF                ;'/' high-bit
            sta   NH_RAWBUF,x
            inx
            ldy   #0
:sfxlp      lda   NHOUTNAME,y
            beq   :sfxdone
            sta   NH_RAWBUF,x
            inx
            iny
            bra   :sfxlp
:sfxdone    stz   NH_RAWBUF,x
            clc
            rts
:over       sec
            rts

NOTICEMSG   asc   "nohup: appending output to nohup.out"
            dfb   $8D,$00
USAGEMSG    asc   "usage: nohup utility [argument...]"
            dfb   $8D,$00
TOOLARGEM   asc   "nohup: environment too large"
            dfb   $8D,$00
TOOMANYMS   asc   "nohup: argument list too long"
            dfb   $8D,$00
ENVFULLMS   asc   "nohup: too many environment vars"
            dfb   $8D,$00
CANTCREATM  asc   "nohup: cannot create nohup.out"
            dfb   $8D,$00
NOTFOUND1   asc   "nohup: "
            dfb   $00
NOTFOUND2   asc   ": not found"
            dfb   $8D,$00
NHSPFX      asc   'nohup: '
            dfb   0
CANTEXEC1   asc   "nohup: "
            dfb   $00
CANTEXEC2   asc   ": cannot execute"
            dfb   $8D,$00
NHOUTNAME   asc   "NOHUP.OUT"
            dfb   $00
HOMENAME    asc   "HOME"
            dfb   $00

NH_CRPARM      dfb   PCOUNT_CREATE
NH_CRPARM_PTH da    NH_MLIBUF
NH_CRPARM_ACC  dfb   ACCESS_UNLKD
NH_CRPARM_TYP  dfb   FTYPE_TXT
NH_CRPARM_AUX  da    0
NH_CRPARM_STO  dfb   STYP_SEEDLING
NH_CRPARM_CDT  da    0
NH_CRPARM_CTM  da    0

NH_OPARM       dfb   OPEN_APPEND
NH_OPARM_PATH  da    NH_MLIBUF
NH_OPARM_IOBF  da    0
NH_OPARM_RF    dfb   0

NH_CPARM       dfb   PCOUNT_CLOSE
NH_CPARM_RF    dfb   0

*---------------------------------------------------------------
* NH_FDADD1/NH_FDADD2 -- append one FDACT_DUP record (target,
* NH_SRCFD) to FDABUF at NH_FI, advancing it by 3. Two entries
* rather than a loop over a tiny fixed set -- the same "just
* write it twice" shape kill.s's own SAYERR/SAYOPRND callers use
* for a two-case fanout. CLOBBERS: A, X.
*---------------------------------------------------------------
NH_FDADD1   lda   #FD_STDOUT
*-- falls into NH_FDADD2 with A = the target fd
NH_FDADD2   ldx   NH_FI
            pha
            lda   #FDACT_DUP
            sta   FDABUF,x
            pla
            sta   FDABUF+1,x
            lda   NH_SRCFD
            sta   FDABUF+2,x
            txa
            clc
            adc   #3
            sta   NH_FI
            rts
