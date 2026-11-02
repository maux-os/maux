*---------------------------------------------------------------
* patchio.s -- patch's front half: option parsing, the patch
* stream's line reader (with the one-line pushback every one of
* the three parsers needs), the target file's whole-file read,
* and the output stream's creation. The writers themselves are
* patchwr.s, split from this file for check-dialect's as-window
* budget.
*
* `put` into src/bin/patch.s; one assembly stream, every rule in
* that manifest's header applies unchanged.
*---------------------------------------------------------------
START       stz   WANTB
            stz   WANTR
            stz   PSTRIP
            stz   HAVEOP
            stz   OPIDX
            stz   HAVEI
            stz   HAVEOUT
            stz   PFD               ;default: the patch is stdin
            stz   OFD
            stz   RFD
            stz   RJOPEN
            stz   FORM
            stz   NT
            stz   NHOK
            stz   NHFAIL
            stz   PREVEND
            stz   LASTSTAR
            stz   PBFLAG
            stz   HADHUNK
            stz   BUFPOS
            stz   BUFLEN
            stz   OLDNAME
            stz   NEWNAME
            stz   NAMEBUF
            stz   OUTNAME
            stz   INAME
            lda   #1
            sta   CURT
            inc   PREVEND           ;PREVEND = 1: the next
                                    ;un-consumed ORIGINAL line

            lda   #<POPTS
            ldx   #>POPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$E2              ;'b' high-bit-set
            beq   :bflag
            cmp   #$D2              ;'R'
            beq   :rflag
            cmp   #$F0              ;'p'
            beq   :pflag
            cmp   #$E9              ;'i'
            beq   :iflag
            cmp   #$EF              ;'o'
            beq   :oflag
            jmp   USAGERR
:bflag      sta   WANTB
            bra   :optlp
:rflag      sta   WANTR
            bra   :optlp
:pflag      jsr   PTPARSED
            sta   PSTRIP
            bra   :optlp
:iflag      lda   #<INAME
            ldx   #>INAME
            jsr   SAVEOPT           ;-i's pathname
            lda   #1
            sta   HAVEI
            bra   :optlp
:oflag      lda   #<OUTNAME
            ldx   #>OUTNAME
            jsr   SAVEOPT
            lda   #1
            sta   HAVEOUT
            bra   :optlp

:optdone    lda   ARGC
            sec
            sbc   OPTIND
            beq   :noop
            cmp   #1
            beq   :oneop
            jmp   USAGERR
:oneop      lda   #1
            sta   HAVEOP
            lda   OPTIND
            sta   OPIDX
:noop
* -- -i names a FILE to read the patch from; without it the
* -- patch is stdin, which is what `patch f < p` means.
            lda   HAVEI
            beq   :usestdin
            lda   #<INAME
            sta   PTR0
            lda   #>INAME
            sta   PTR0+1
            jsr   MKPATH1
            lda   #<IOPARM
            ldx   #>IOPARM
            jsr   SC_OPEN
            bcc   :ipok
            jmp   NOPATCH
:ipok       lda   IOPARM_REF
            sta   PFD
:usestdin

            jsr   SCANHDR           ;form + header names, or
                                    ;exit 2 if there is no patch
            jsr   SETTGT            ;NAMEBUF = the file to patch
            jsr   READTGT           ;whole target -> ARENA/TGTLP
            jsr   OPENOUT           ;OFD = the output stream
            lda   WANTB
            beq   :nobak
            jsr   WRBACKUP
:nobak      jsr   APPLYALL
            jsr   FLUSHREST
            ldx   OFD
            jsr   FCLOSE
            lda   RJOPEN
            beq   :norej
            ldx   RFD
            jsr   FCLOSE
:norej      jsr   REPORT
            lda   NHFAIL
            beq   :allok
            lda   #1
            jsr   EXIT
:allok      lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* SAVEOPT -- IN: A/X = lo/hi of a NAMEMAX-byte destination.
* Copy OPTARG's text into it, NUL-terminated, stopping at
* NAMEMAX-1 bytes (OPTARG is only valid until the next GETOPT,
* and STRCPY has no bound -- this tree's own four-caller lesson,
* liba/string.s's STRCPY header).
*---------------------------------------------------------------
SAVEOPT     sta   PT_NBUF
            stx   PT_NBUF+1
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            ldy   #0
:cl         cpy   #NAMEMAX-1
            bcs   :cdone
            lda   (PTR0),y
            beq   :cdone
            sta   (PT_NBUF),y
            iny
            bra   :cl
:cdone      lda   #0
            sta   (PT_NBUF),y
            rts

*---------------------------------------------------------------
* PTPARSED -- -p's decimal argument. OUT: A, saturating at 239.
* A non-digit or an empty argument is a usage error, not a
* silent 0.
*---------------------------------------------------------------
PTPARSED    lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            stz   PT_TMP
            ldy   #0
            lda   (PTR0),y
            beq   :bad
:ploop      lda   (PTR0),y
            beq   :pdone
            and   #$7F
            cmp   #'0'
            bcc   :bad
            cmp   #'9'+1
            bcs   :bad
            and   #$0F
            sta   PT_TMP2
            lda   PT_TMP
            cmp   #24
            bcs   :sat
            asl   a
            sta   PT_TMP2+1
            asl   a
            asl   a
            clc
            adc   PT_TMP2+1
            clc
            adc   PT_TMP2
            sta   PT_TMP
            iny
            bra   :ploop
:sat        lda   #239
            sta   PT_TMP
            iny
            bra   :ploop
:pdone      lda   PT_TMP
            rts
:bad        jmp   USAGERR

*---------------------------------------------------------------
* MKPATH1/MKPATH2 -- PTR0 = a liba string; build the MLI
* count-prefixed pathname in PATHBUF (PATH2BUF). Clobbers the
* usual MKPATH set.
*---------------------------------------------------------------
MKPATH1     lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jmp   MKPATH

MKPATH2     lda   #<PATH2BUF
            sta   PTR1
            lda   #>PATH2BUF
            sta   PTR1+1
            jmp   MKPATH

*---------------------------------------------------------------
* GETPB -- one byte of the patch stream, A = byte, carry set at
* EOF. cmp.s's own buffered-reader shape over PFD.
*---------------------------------------------------------------
GETPB       ldx   BUFPOS
            cpx   BUFLEN
            bcc   :have
            jsr   REFILP
            bcs   :eof
            ldx   BUFPOS
:have       lda   PBUF,x
            inc   BUFPOS
            clc
            rts
:eof        sec
            rts

REFILP      lda   PFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :rerr
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :rerr
            lda   RPARM_TRANS
            sta   BUFLEN
            stz   BUFPOS
            clc
            rts
:rerr       sec
            rts

*---------------------------------------------------------------
* PGETLN -- read one line of the patch stream into the hunk
* arena at PT_HPOS, CR-stripped and NUL-terminated, and leave
* its start address in PT_LP. Carry SET = end of patch (nothing
* was read). A pushed-back line is returned instead, once.
*
* The arena is NOT rewound here: a hunk's lines accumulate so
* that a REJECTED hunk can be written out verbatim. HUNKINIT
* rewinds it, once per hunk.
*---------------------------------------------------------------
PGETLN      lda   PBFLAG
            beq   :fresh
            stz   PBFLAG
            clc
            rts
:fresh      lda   PT_HPOS
            sta   PT_LP
            lda   PT_HPOS+1
            sta   PT_LP+1
            stz   PT_TMP            ;bytes stored this line
:loop       jsr   GETPB
            bcs   :eof
            cmp   #$8D
            beq   :eol
            sta   PT_CBYTE
            jsr   CHKHROOM
            lda   PT_CBYTE
            sta   (PT_HPOS)
            inc   PT_HPOS
            bne   :nb
            inc   PT_HPOS+1
:nb         inc   PT_TMP
            bra   :loop
:eol        jsr   CHKHROOM
            lda   #0
            sta   (PT_HPOS)
            inc   PT_HPOS
            bne   :nb2
            inc   PT_HPOS+1
:nb2        clc
            rts
:eof        lda   PT_TMP
            beq   :none             ;EOF with no bytes at all
            bra   :eol              ;a final unterminated line
:none       sec
            rts

* PUSHBACK -- the line in PT_LP is handed back to the next
* PGETLN. Only ever one deep, which is all any of the three
* forms needs to decide that a hunk has ended.
PUSHBACK    lda   #1
            sta   PBFLAG
            rts

*---------------------------------------------------------------
* CHKHROOM -- rts if the hunk arena has a free byte; OVERFLOW
* (no return) otherwise.
*---------------------------------------------------------------
CHKHROOM    lda   PT_HPOS+1
            cmp   #>HARENAEND
            bcc   :ok
            bne   :full
            lda   PT_HPOS
            cmp   #<HARENAEND
            bcc   :ok
:full       jmp   OVERFLOW
:ok         rts

*---------------------------------------------------------------
* HUNKINIT -- start a new hunk: rewind the hunk arena and empty
* the three line lists. Every parser calls this FIRST.
*
* A PUSHED-BACK LINE IS MOVED, not abandoned. The line that
* ended the previous hunk lives in the arena this rewind is
* about to hand out again, and the next PGETLN would write over
* the very bytes it is holding. So it is copied down to the
* base first and PT_LP re-aimed at the copy -- one line, once
* per hunk, and the only place in this program where any text
* is copied at all.
*---------------------------------------------------------------
HUNKINIT    stz   NRAW
            stz   NOLD
            stz   NNEW
            lda   #<HARENA
            sta   PT_TMP
            lda   #>HARENA
            sta   PT_TMP+1
            lda   PBFLAG
            bne   :move
            lda   PT_TMP
            sta   PT_HPOS
            lda   PT_TMP+1
            sta   PT_HPOS+1
            rts
:move       ldy   #0
:ml         lda   (PT_LP),y
            sta   (PT_TMP),y
            beq   :mdone
            iny
            bne   :ml
:mdone      iny                     ;past the NUL
            lda   PT_TMP
            sta   PT_LP
            lda   PT_TMP+1
            sta   PT_LP+1
            tya
            clc
            adc   PT_TMP
            sta   PT_HPOS
            lda   PT_TMP+1
            adc   #0
            sta   PT_HPOS+1
            rts

*---------------------------------------------------------------
* HRAW/HOLD/HNEW -- append PT_LP (HRAW/HOLD) or PT_LP2 (HNEW)
* to the raw / old / new list. OVERFLOW (no return) past
* MAXHLINES. The three lists index the SAME arena text: a raw
* line is the whole line, an old/new line is its text past the
* format's prefix, so nothing is ever copied twice.
*---------------------------------------------------------------
HRAW        lda   NRAW
            cmp   #MAXHLINES
            bcs   :hfull
            asl   a
            sta   PT_TMP
            lda   #0
            rol   a
            sta   PT_TMP+1
            clc
            lda   PT_TMP
            adc   #<RAWLP
            sta   PT_TMP
            lda   PT_TMP+1
            adc   #>RAWLP
            sta   PT_TMP+1
            lda   PT_LP
            sta   (PT_TMP)
            ldy   #1
            lda   PT_LP+1
            sta   (PT_TMP),y
            inc   NRAW
            rts
:hfull      jmp   OVERFLOW

HOLD        lda   NOLD
            cmp   #MAXHLINES
            bcs   :ofull
            asl   a
            sta   PT_TMP
            lda   #0
            rol   a
            sta   PT_TMP+1
            clc
            lda   PT_TMP
            adc   #<OLDLP
            sta   PT_TMP
            lda   PT_TMP+1
            adc   #>OLDLP
            sta   PT_TMP+1
            lda   PT_LP2
            sta   (PT_TMP)
            ldy   #1
            lda   PT_LP2+1
            sta   (PT_TMP),y
            inc   NOLD
            rts
:ofull      jmp   OVERFLOW

HNEW        lda   NNEW
            cmp   #MAXHLINES
            bcs   :nfull
            asl   a
            sta   PT_TMP
            lda   #0
            rol   a
            sta   PT_TMP+1
            clc
            lda   PT_TMP
            adc   #<NEWLP
            sta   PT_TMP
            lda   PT_TMP+1
            adc   #>NEWLP
            sta   PT_TMP+1
            lda   PT_LP2
            sta   (PT_TMP)
            ldy   #1
            lda   PT_LP2+1
            sta   (PT_TMP),y
            inc   NNEW
            rts
:nfull      jmp   OVERFLOW

*---------------------------------------------------------------
* LPGET -- IN: A = 0-based index, X/Y = lo/hi of a pointer
* table (RAWLP/OLDLP/NEWLP/TGTLP). OUT: PT_LP2 = that entry.
*---------------------------------------------------------------
LPGET       stx   PT_TMP2
            sty   PT_TMP2+1
            asl   a
            sta   PT_TMP
            lda   #0
            rol   a
            sta   PT_TMP+1
            clc
            lda   PT_TMP
            adc   PT_TMP2
            sta   PT_TMP
            lda   PT_TMP+1
            adc   PT_TMP2+1
            sta   PT_TMP+1
            lda   (PT_TMP)
            sta   PT_LP2
            ldy   #1
            lda   (PT_TMP),y
            sta   PT_LP2+1
            rts
