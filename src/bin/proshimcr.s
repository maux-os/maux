*---------------------------------------------------------------
* proshimcr.s -- proshim's MLI core (TASKS.md #19, docs/EDASM-
* SHIM.md). Assembled STANDALONE at PS_CORE ($E000, the process
* bank's own LC common region -- nothing claims it in a native
* bank but the kernel's $FFxx page) and embedded in proshim.bin
* via putbin. Entered from the shim page with LC RAM read AND
* write enabled in the tenant's own bank group; leaves through
* PS_EXITA ($BFB0, below $C000) so the LC restore never pulls
* the rug from under the code doing it.
*
* The adapter: the MLI contract is `JSR $BF00 / DFB cmd / DA
* parmlist`, resume after the three inline bytes, A = error
* (0 = none), C = error, X/Y preserved (ProDOS 8 TRM ch. 4).
* The maux gate is `Y=cmd, A/X=parmlist, JSR $FF00` with the
* SAME numbers and the SAME parmlists for every file call
* (inc/sc.file.equ), so the file set passes straight
* through -- the kernel answers ERR_P8_UNWIRE for numbers it
* has not wired, loudly. Handled here instead:
*   $65 QUIT      -> SYS_EXIT(0)
*   $82 GET_TIME  -> SYS_CLOCK stamped into $BF90-$BF93
*   $C9 NEWLINE   -> per-fd (mask,char) table in the page
*   $CA READ      -> if that fd has NEWLINE on: READ, scan the
*                    buffer for byte&mask==char, SET_MARK back
*                    to just past it, shorten trans_count
*   anything else outside $C0-$D3 -> MLI error $01, C set --
*                    never a silent success
*
* PS_GATE re-enables LC write after every kernel call because
* the kernel's MLI bracket leaves the LC write-protected
* (src/kernel/mli.s) and this code self-modifies its operands.
* No zero page: the tenant owns all of $00-$FF.
*---------------------------------------------------------------
            lst   off
            xc
            org   $E000
            dsk   ../../build/proshimcr.bin
            typ   $00
            put   proshim.equ
            put   ../../inc/mm.hw.equ
            put   ../../inc/sc.proc.equ

* -- fixed entry table at $E000 (stable addresses proshim
* -- the copied ROM's console leaves to reach): --
            jmp   PS_START       ;$E000 = PS_CORE entry
            jmp   PS_FDOUT       ;$E003 = PS_CORE_FDOUT
            jmp   PS_FDIN        ;$E006 = PS_CORE_FDIN
            jmp   PS_GETLN       ;$E009 = PS_CORE_GETLN

* -- entry: pull the JSR's return (= address of the inline
* -- cmd byte minus 1), fetch cmd + parmlist through a patched
* -- absolute,Y load, push return+3 so the final RTS resumes
* -- past the inline bytes.
PS_START    pla
            sta   PS_RET
            sta   PS_RDR+1
            pla
            sta   PS_RET+1
            sta   PS_RDR+2
            ldy   #1
            jsr   PS_RDR
            sta   PS_CMD
            iny
            jsr   PS_RDR
            sta   PS_PARM
            iny
            jsr   PS_RDR
            sta   PS_PARM+1
            clc
            lda   PS_RET
            adc   #3
            sta   PS_RET
            lda   PS_RET+1
            adc   #0
            pha
            lda   PS_RET
            pha
            lda   PS_CMD
            cmp   #$65
            bne   :n1
            jmp   PS_QUIT
:n1         cmp   #$82
            bne   :n2
            jmp   PS_GTIME
:n2         cmp   #$C9
            bne   :n3
            jmp   PS_NEWLIN
:n3         cmp   #$CA
            bne   :n4
            jmp   PS_READ
:n4         cmp   #$C0
            bcc   PS_BADCMD
            cmp   #$D4
            bcs   PS_BADCMD
* -- pass-through: same number, same parmlist --
PS_PASS     ldy   PS_CMD
            lda   PS_PARM
            ldx   PS_PARM+1
            jsr   PS_GATE
            jmp   PS_EXITA
PS_BADCMD   lda   #$01                   ;MLI: bad call number
            sec
            jmp   PS_EXITA

* PS_RDR -- lda (return address),y ; operand patched above
PS_RDR      lda   $FFFF,y
            rts

* PS_GATE -- the kernel door, then re-enable LC write (the
* MLI bracket write-protects). Preserves A and C.
PS_GATE     jsr   $FF00
            sta   PS_RESULT
            php
            lda   LCBANK2_RAM
            lda   LCBANK2_RAM
            plp
            lda   PS_RESULT
            rts

* PS_SETP -- point PS_RDP/PS_WRP at the tenant's parmlist
PS_SETP     lda   PS_PARM
            sta   PS_RDP+1
            sta   PS_WRP+1
            lda   PS_PARM+1
            sta   PS_RDP+2
            sta   PS_WRP+2
            rts
PS_RDP      lda   $FFFF,y
            rts
PS_WRP      sta   $FFFF,y
            rts
PS_RDB      lda   $FFFF,y                ;data buffer, hi byte
            rts                          ;walks with the scan

*---------------------------------------------------------------
PS_QUIT     lda   #0
            sta   PS_PROCP
            lda   #<PS_PROCP
            ldx   #>PS_PROCP
            ldy   #SYS_EXIT
            jsr   $FF00
:hang       jmp   :hang

PS_GTIME    lda   #<PS_DATE
            sta   PS_PROCP
            lda   #>PS_DATE
            sta   PS_PROCP+1
            lda   #<PS_PROCP
            ldx   #>PS_PROCP
            ldy   #SYS_CLOCK
            jsr   PS_GATE
            jmp   PS_EXITA

* NEWLINE: {3, ref_num, enable_mask, newline_char}
PS_NEWLIN   jsr   PS_SETP
            ldy   #0
            jsr   PS_RDP
            cmp   #3
            beq   :cnt
            lda   #$04                   ;MLI: bad param count
            sec
            jmp   PS_EXITA
:cnt        ldy   #1
            jsr   PS_RDP
            and   #$07
            asl
            tax
            ldy   #2
            jsr   PS_RDP
            sta   PS_NLTAB,x
            ldy   #3
            jsr   PS_RDP
            sta   PS_NLTAB+1,x
            lda   #0
            clc
            jmp   PS_EXITA

* READ: {4, ref_num, data_buffer, request_count, trans_count}
PS_READ     jsr   PS_SETP
            ldy   #1
            jsr   PS_RDP
            and   #$07
            asl
            tax
            lda   PS_NLTAB,x
            bne   :nl
            jmp   PS_PASS                ;NEWLINE off: plain
:nl         sta   PS_MASK
            lda   PS_NLTAB+1,x
            sta   PS_CHAR
            ldy   #$CA
            lda   PS_PARM
            ldx   PS_PARM+1
            jsr   PS_GATE
            bcc   :ok
            jmp   PS_EXITA
:ok         ldy   #6
            jsr   PS_RDP
            sta   PS_TLO
            ldy   #7
            jsr   PS_RDP
            sta   PS_THI
            ldy   #2
            jsr   PS_RDP
            sta   PS_RDB+1
            ldy   #3
            jsr   PS_RDP
            sta   PS_RDB+2
            lda   #0
            sta   PS_ILO
            sta   PS_IHI
:scan       lda   PS_IHI
            cmp   PS_THI
            bcc   :in
            lda   PS_ILO
            cmp   PS_TLO
            bcc   :in
            lda   #0                     ;no newline in the
            clc                          ;transfer: as read
            jmp   PS_EXITA
:in         ldy   PS_ILO
            jsr   PS_RDB
            and   PS_MASK
            cmp   PS_CHAR
            beq   :found
            inc   PS_ILO
            bne   :scan
            inc   PS_IHI
            inc   PS_RDB+2
            jmp   :scan
:found      inc   PS_ILO                 ;i+1 = bytes to keep
            bne   :nt
            inc   PS_IHI
:nt         sec
            lda   PS_TLO
            sbc   PS_ILO
            sta   PS_DLO                 ;delta = trans - kept
            lda   PS_THI
            sbc   PS_IHI
            sta   PS_DHI
            ldy   #6
            lda   PS_ILO
            jsr   PS_WRP
            ldy   #7
            lda   PS_IHI
            jsr   PS_WRP
            ldy   #1
            jsr   PS_RDP
            sta   PS_MKREF
            lda   #<PS_MKPARM
            ldx   #>PS_MKPARM
            ldy   #$CF                   ;GET_MARK
            jsr   PS_GATE
            bcs   :err
            sec
            lda   PS_MKPOS
            sbc   PS_DLO
            sta   PS_MKPOS
            lda   PS_MKPOS+1
            sbc   PS_DHI
            sta   PS_MKPOS+1
            lda   PS_MKPOS+2
            sbc   #0
            sta   PS_MKPOS+2
            lda   #<PS_MKPARM
            ldx   #>PS_MKPARM
            ldy   #$CE                   ;SET_MARK
            jsr   PS_GATE
            bcs   :err
            lda   #0
            clc
:err        jmp   PS_EXITA

* -- fd console leaves: the copied monitor ROM's COUT1 and KEYIN
* -- are patched (by proshim.s at install) to JMP here, so every
* -- monitor console call routes through the process's fd 0/1
* -- while the ROM's own screen pokes go to the bank text page.
* PS_FDOUT -- write A to fd 1; A preserved (COUT1 shape).
PS_FDOUT    sta   PS_WBUF
            jsr   PS_PAGE                ;$BF00
            dfb   $CB                    ;WRITE
            da    PS_WPARM
            lda   PS_WBUF
            rts
* PS_FDIN -- read one byte from fd 0 into A (high bit set, KEYIN
* shape); at end of input QUIT the tenant.
PS_FDIN     jsr   PS_PAGE
            dfb   $CA                    ;READ
            da    PS_RPARM
            bcs   :eof
            lda   PS_RPARM+6             ;trans_count lo
            beq   :eof
            lda   PS_RBUF
            ora   #$80
            rts
:eof        jsr   PS_PAGE
            dfb   $65                    ;QUIT (parms ignored)
            da    PS_RPARM
:hang       jmp   :hang
* PS_GETLN -- a headless line reader (the copied ROM's own
* GETLN is 80-col-firmware-integrated and does not terminate off
* the glass). Reads fd 0 through PS_FDIN into $0200 until CR,
* honouring backspace; returns X = length, the CR at $0200,X --
* the GETLN contract a caller (BASIC, ed) expects.
PS_GETLN    ldx   #0
:gl         jsr   PS_FDIN
            cmp   #$8D                   ;CR -> done
            beq   :gd
            cmp   #$88                   ;backspace / left-arrow
            beq   :gb
            cmp   #$FF                   ;DEL
            beq   :gb
            sta   $0200,x
            inx
            bpl   :gl
            dex                          ;full at 127: hold
            bne   :gl
:gb         cpx   #0
            beq   :gl
            dex
            jmp   :gl
:gd         sta   $0200,x
            rts

* -- core scratch: a `dum` arena above the emitted core image
* -- (LC common RAM at $E300), every cell write-before-read in
* -- PS_READ. PS_MKPARM/PS_MKREF/PS_MKPOS are page cells
* -- (proshim.equ) because the kernel cannot copyin a parmlist
* -- from the LC core.
            dum   $E300
PS_MASK     ds    1
PS_CHAR     ds    1
PS_TLO      ds    1
PS_THI      ds    1
PS_ILO      ds    1
PS_IHI      ds    1
PS_DLO      ds    1
PS_DHI      ds    1
            dend
