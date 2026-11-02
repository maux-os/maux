*---------------------------------------------------------------
* mntcom.s -- what mount.s and umount.s share (docs/VROOT.md):
* the /dev/sNdM operand parser, one-unit ON_LINE, the SYS_VROOT
* gate and the error line. A put file, not a program.
*
* THE ONLY MLI POLL HERE is MNT_ONLINE on ONE unit the user
* named or one the kernel says is already mounted -- never
* unit 0 (operator ruling: never poll a 5.25" drive to list
* anything; `mount` is the user asking).
*---------------------------------------------------------------

*---------------------------------------------------------------
* MNT_UNIT -- PTR0 = a hi-bit NUL string. If it is "/dev/sNdM"
* (any case) carry CLEAR and A = the unit_num, DSSS0000; else
* carry SET. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MNT_UNIT    ldy   #0
:pf         lda   (PTR0),y
            jsr   RD_FOLD
            cmp   MNT_DEVPFX,y
            bne   :no
            iny
            cpy   #6                ;"/DEV/S"
            bne   :pf
            lda   (PTR0),y          ;slot digit 1-7
            and   #$7F
            sec
            sbc   #'0'
            beq   :no
            cmp   #8
            bcs   :no
            asl   a
            asl   a
            asl   a
            asl   a
            sta   MNT_TMP
            iny
            lda   (PTR0),y
            jsr   RD_FOLD
            cmp   #'D'
            bne   :no
            iny
            lda   (PTR0),y          ;drive digit 1-2
            and   #$7F
            cmp   #'1'
            beq   :d1
            cmp   #'2'
            bne   :no
            lda   MNT_TMP
            ora   #$80
            sta   MNT_TMP
:d1         iny
            lda   (PTR0),y
            bne   :no               ;must end here
            lda   MNT_TMP
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* MNT_ONLINE -- ON_LINE on the ONE unit in A. OUT: carry CLEAR,
* MNT_NM = "/NAME" as a hi-bit NUL string with its length just
* before it (MNT_NMLP, the shape SYS_VROOT op 2 reads); or carry
* SET, A = the MLI's reason. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MNT_ONLINE  sta   MNT_OPARM+1
            lda   #2
            sta   MNT_OPARM
            lda   #<MNT_ONBUF
            sta   MNT_OPARM+2
            lda   #>MNT_ONBUF
            sta   MNT_OPARM+3
            lda   #<MNT_OPARM
            ldx   #>MNT_OPARM
            jsr   SC_ONLINE
            bcs   :out
            lda   MNT_ONBUF
            and   #$0F
            bne   :named
            lda   MNT_ONBUF+1       ;no volume: the error byte
            sec
            rts
:named      tax
            inx
            stx   MNT_NMLP          ;"/" + name
            lda   #$AF
            sta   MNT_NM
            ldy   #0
:cp         lda   MNT_ONBUF+1,y
            ora   #$80
            sta   MNT_NM+1,y
            iny
            cpy   MNT_NMLP
            bcc   :cp
            lda   #0
            sta   MNT_NM,y
            clc
:out        rts

*---------------------------------------------------------------
* MNT_VROOT -- SYS_VROOT. IN: X = op, A = arg (unit_num); op 2
* names the volume by MNT_NMLP. OUT: carry as the kernel left
* it, A = its error. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MNT_VROOT   sta   MNT_VPARM+3
            stx   MNT_VPARM
            lda   #<MNT_NMLP
            sta   MNT_VPARM+1
            lda   #>MNT_NMLP
            sta   MNT_VPARM+2
            lda   #<MNT_VPARM
            ldx   #>MNT_VPARM
            jmp   SC_VROOT

*---------------------------------------------------------------
* MNT_DEVNAME -- print "/dev/sNdM" for the unit in A to stdout.
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
MNT_DEVNAME pha
            lda   #<MNT_DEVSTR
            sta   PTR0
            lda   #>MNT_DEVSTR
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            pla
            pha
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            and   #7
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$E4              ;'d'
            ldx   #FD_STDOUT
            jsr   PUTC
            pla
            bmi   :two
            lda   #$B1
            bra   :dr
:two        lda   #$B2
:dr         ldx   #FD_STDOUT
            jmp   PUTC

*---------------------------------------------------------------
* MNT_FAIL -- "<program>: <arg>: <reason>" to stderr, exit 1.
* IN: A = the MLI code, MNT_PROG = hi-bit NUL program name,
* PTR1 = the operand. Does not return.
*---------------------------------------------------------------
MNT_FAIL    pha
            lda   MNT_PROG
            sta   PTR0
            lda   MNT_PROG+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<MNT_COLON
            sta   PTR0
            lda   #>MNT_COLON
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<MNT_COLON
            sta   PTR0
            lda   #>MNT_COLON
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            pla
            ldx   #0
:t          ldy   MNT_REASON,x      ;code, pointer triples
            beq   :hex              ;a zero code ends the table
            cmp   MNT_REASON,x
            beq   :found
            inx
            inx
            inx
            bra   :t
:found      lda   MNT_REASON+1,x
            sta   PTR0
            lda   MNT_REASON+2,x
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            bra   :nl
:hex        pha
            lda   #<MNT_ERRSTR
            sta   PTR0
            lda   #>MNT_ERRSTR
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            pla
            ldx   #FD_STDERR
            jsr   PRHEX8
:nl         lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jsr   EXIT

MNT_DEVPFX  asc   '/DEV/S'
MNT_DEVSTR  asc   "/dev/s"
            dfb   0
MNT_COLON   asc   ": "
            dfb   0
MNT_ERRSTR  asc   "error $"
            dfb   0
MNT_R28     asc   "no device connected"
            dfb   0
MNT_R52     asc   "not a ProDOS volume"
            dfb   0
MNT_R50     asc   "busy"
            dfb   0
MNT_R48     asc   "disk full"
            dfb   0
MNT_R45     asc   "not mounted"
            dfb   0
MNT_RE1     asc   "not a mountable unit"
            dfb   0
MNT_R46     asc   "no such file"
            dfb   0
MNT_RD1     asc   "sparse image (holes below EOF)"
            dfb   0
MNT_RD2     asc   "2IMG layout not supported"
            dfb   0
MNT_RD3     asc   "not a tree file (need a .po/.hdv over 128K)"
            dfb   0
MNT_RD4     asc   "no free device slot"
            dfb   0
MNT_RD5     asc   "needs ProDOS 2.4 (bitmap cells)"
            dfb   0
*-- code, pointer; a zero code ends the table
MNT_REASON  dfb   $28
            da    MNT_R28
            dfb   $52
            da    MNT_R52
            dfb   $50
            da    MNT_R50
            dfb   $48
            da    MNT_R48
            dfb   $45
            da    MNT_R45
            dfb   $E1
            da    MNT_RE1
            dfb   $46
            da    MNT_R46
            dfb   $D1
            da    MNT_RD1
            dfb   $D2
            da    MNT_RD2
            dfb   $D3
            da    MNT_RD3
            dfb   $D4
            da    MNT_RD4
            dfb   $D6
            da    MNT_RD5
            dfb   0
