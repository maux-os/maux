*---------------------------------------------------------------
* lsprint.s -- ls's entry-printing half,
* extracted from ls.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2 mains). One
* assembly stream: put exactly where the text sat; every rule
* in the manifest header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PRINTENTRIES -- print every collected (sorted) entry.
*---------------------------------------------------------------
PRINTENTRIES
            stz   PRIDX
            lda   LFLAG              ;-l: one record per line
            bne   :eloop
            lda   ONEFLAG            ;-1: one name per line
            bne   :eloop
            lda   SFLAG              ;-s: one entry per line
            bne   :eloop
            jsr   COLSETUP           ;columns? (a console, or
            bcs   :eloop             ;-C) -- carry set = no
            jmp   PRINTCOLS          ;lscol.s
:eloop      lda   PRIDX
            cmp   ENTRYCOUNT
            bcs   :edone
            tax
            lda   ENTIDX,x           ;sorted ORDER lives in the
            jsr   ENTADDR            ;index; the records stay
            lda   SFLAG
            beq   :nosize
            ldy   #RD_BLOCKS
            lda   (LS_ENT),y
            sta   U2DEC_VAL
            iny
            lda   (LS_ENT),y
            sta   U2DEC_VAL+1
            jsr   PRINTBLKS
:nosize
            lda   LFLAG
            beq   :shortline
            jsr   PRINTENTLONG
            jmp   :nextent
:shortline  jsr   PRINTENTNAME
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:nextent    inc   PRIDX
            jmp   :eloop
:edone      rts

PRINTENTLONG
*-- docs/DEVFS.md: a device entry's RD_FTYPE is always $00
*-- (readdir.s's own synthetic records) -- RD_STYPE is what
*-- distinguishes it from an ordinary typeless file, so it is
*-- checked FIRST, ahead of the normal file_type dispatch.
            ldy   #RD_STYPE
            lda   (LS_ENT),y
            cmp   #RD_STYPE_BLK
            bne   :notblk
            lda   #<BLKSTR
            ldx   #>BLKSTR
            jsr   PRINTTSTR
            bra   :typedone
:notblk     cmp   #RD_STYPE_CHR
            bne   :notchr
            lda   #<CHRSTR
            ldx   #>CHRSTR
            jsr   PRINTTSTR
            bra   :typedone
:notchr     ldy   #RD_FTYPE
            lda   (LS_ENT),y
            jsr   PRINTTYPE
:typedone   lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PRINTEOFCOL
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            ldy   #RD_MDATE
            lda   (LS_ENT),y
            sta   DTDATE
            iny
            lda   (LS_ENT),y
            sta   DTDATE+1
            ldy   #RD_MTIME
            lda   (LS_ENT),y
            sta   DTTIME
            iny
            lda   (LS_ENT),y
            sta   DTTIME+1
            jsr   PRINTDATE
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PRINTENTNAME
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PRINTENTNAME -- print RD_NAME. The GS/OS case-bitflag decode
* USED to happen fresh here, at print time, from a raw case word
* this record carried alongside the name; that decode now runs
* ONCE, inside src/liba/readdir.s's own READDIR (docs/FLEET.md's
* readdir ruling: "decode storage encodings" is the module's
* job) -- so RD_NAME is already display-ready and this is just a
* PUTS. IN: LS_ENT. No trailing CR.
*---------------------------------------------------------------
PRINTENTNAME
            clc
            lda   LS_ENT
            adc   #RD_NAME
            sta   PTR0
            lda   LS_ENT+1
            adc   #0
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   FFLAG
            beq   :done
            ldy   #RD_STYPE
            lda   (LS_ENT),y
            cmp   #STYP_DIR
            bne   :done
            lda   #$AF
            ldx   #FD_STDOUT
            jsr   PUTC
:done
            rts

*-- PRINTBLKS -- U2DEC_VAL in ProDOS blocks, then one space.
PRINTBLKS   lda   #<SIZEBUF
            sta   PTR1
            lda   #>SIZEBUF
            sta   PTR1+1
            jsr   U2DEC
            lda   #<SIZEBUF
            sta   PTR0
            lda   #>SIZEBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PRINTTYPE -- IN A = file_type byte; prints the 3-char TTT
* column (always exactly 3 chars, so no padding is ever needed).
*---------------------------------------------------------------
PRINTTYPE   cmp   #FTYPE_TXT
            bne   :n1
            lda   #<TXTSTR
            ldx   #>TXTSTR
            jmp   :pr
:n1         cmp   #FTYPE_BIN
            bne   :n2
            lda   #<BINSTR
            ldx   #>BINSTR
            jmp   :pr
:n2         cmp   #FTYPE_DIR
            bne   :n3
            lda   #<DIRSTR
            ldx   #>DIRSTR
            jmp   :pr
:n3         cmp   #FTYPE_SYS
            bne   :n4
            lda   #<SYSSTR
            ldx   #>SYSSTR
            jmp   :pr
:n4         cmp   #FTYPE_BAS
            bne   :n5
            lda   #<BASSTR
            ldx   #>BASSTR
            jmp   :pr
:n5         jsr   HEXPRINT
            rts
:pr         sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts

*---------------------------------------------------------------
* PRINTTSTR -- IN A/X = lo/hi of a NUL-terminated high-bit
* string; prints it to stdout. docs/DEVFS.md: PRINTENTLONG's own
* BLK/CHR case, factored out since PRINTTYPE's matching tail
* (`:pr`) is a LOCAL label out of this routine's scope.
*---------------------------------------------------------------
PRINTTSTR   sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS

*---------------------------------------------------------------
* HEXPRINT -- IN A = byte; prints "$xx", high-bit hex. The "$"
* is ls-specific rendering; the digit pair is liba's PRHEX8
* (docs/FAT.md sec 3).
*---------------------------------------------------------------
HEXPRINT    pha
            lda   #$A4              ;'$' high-bit
            ldx   #FD_STDOUT
            jsr   PUTC
            pla
            ldx   #FD_STDOUT
            jsr   PRHEX8
            rts

*---------------------------------------------------------------
* PR2DIG -- IN A = 0-99; prints two zero-padded high-bit digits.
*---------------------------------------------------------------
PR2DIG      ldy   #0
:tens       cmp   #10
            bcc   :ones
            sec
            sbc   #10
            iny
            bra   :tens
:ones       sta   PR2DIG_ONE
            tya
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   PR2DIG_ONE
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PRINTDATE -- IN DTDATE/DTTIME (2 bytes each); prints the fixed
* 16-char "YYYY-MM-DD HH:MM" field, or "-" padded to 16 chars
* for a zero date word or a date that fails the legacy validity
* check (docs/PRODOS-VERSION.md: hour<=23 AND minute<=59 =
* legacy).
*---------------------------------------------------------------
PRINTDATE   lda   DTDATE
            ora   DTDATE+1
            bne   :nz
            jmp   :dateblank
* -- validity check on the RAW bytes, never masked: a legacy
* -- time word has the hour's top 3 and the minute's top 2 bits
* -- ZERO by format, so raw hour<=23 / minute<=59 IS the
* -- legacy-vs-Extended discriminator (docs/PRODOS-VERSION.md).
* -- Masking first destroys it: the doc's own captured 2.5
* -- Extended stamp $97E4 masks to hour 23 minute 36 and would
* -- print as a plausible garbage date instead of "-". check-ls
* -- stages exactly those artifact bytes and fails the masked
* -- version (teeth run 2026-08-19).
:nz         lda   DTTIME+1          ;high byte = hour, RAW
            sta   HOURV
            cmp   #24
            bcc   :hourok
            jmp   :ext
:hourok     lda   DTTIME            ;low byte = minute, RAW
            sta   MINUTEV
            cmp   #60
            bcc   :minok
            jmp   :ext
:minok      lda   DTDATE
            and   #$1F
            sta   DAYV
            lda   DTDATE
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            and   #$07
            sta   MONTHV
            lda   DTDATE+1
            and   #$01
            asl   a
            asl   a
            asl   a
            ora   MONTHV
            sta   MONTHV
            lda   DTDATE+1
            lsr   a
            and   #$7F
            sta   YEAR7
            lda   YEAR7
            cmp   #78
            bcc   :y2k
            lda   #<CENT19
            ldx   #>CENT19
            jmp   :prcent
:y2k        lda   #<CENT20
            ldx   #>CENT20
:prcent     sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   YEAR7
            jsr   PR2DIG
            lda   #<DASH
            sta   PTR0
            lda   #>DASH
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   MONTHV
            jsr   PR2DIG
            lda   #<DASH
            sta   PTR0
            lda   #>DASH
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   DAYV
            jsr   PR2DIG
            lda   #<SPACECH
            sta   PTR0
            lda   #>SPACECH
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   HOURV
            jsr   PR2DIG
            lda   #<COLONCH
            sta   PTR0
            lda   #>COLONCH
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   MINUTEV
            jsr   PR2DIG
            rts
:ext                                 ;fall through -- Extended
                                     ;or invalid, same as a zero
                                     ;date
:dateblank  lda   #<DASHFIELD
            sta   PTR0
            lda   #>DASHFIELD
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts

*---------------------------------------------------------------
* PRINTEOFCOL -- IN LS_ENT; prints RD_EOF (3-byte, decimal)
* right-aligned width 8. Used only for directory ENTRIES.
*---------------------------------------------------------------
PRINTEOFCOL ldy   #RD_EOF
            lda   (LS_ENT),y
            sta   LS3_VAL
            iny
            lda   (LS_ENT),y
            sta   LS3_VAL+1
            iny
            lda   (LS_ENT),y
            sta   LS3_VAL+2
            lda   #<SIZEBUF
            sta   PTR1
            lda   #>SIZEBUF
            sta   PTR1+1
            jsr   U3DEC
            lda   #<SIZEBUF
            sta   PTR0
            lda   #>SIZEBUF
            sta   PTR0+1
            jsr   PRPAD8
            rts

*---------------------------------------------------------------
* PRINTBLKSCOL -- IN GFIPARM_BLKS (2-byte); prints blocks_used
* followed by "b", right-aligned width 8. Used only for a GFI
* file-argument's line (GET_FILE_INFO has no EOF field -- see
* file header).
*---------------------------------------------------------------
PRINTBLKSCOL
            lda   GFIPARM_BLKS
            sta   U2DEC_VAL
            lda   GFIPARM_BLKS+1
            sta   U2DEC_VAL+1
            lda   #<SIZEBUF
            sta   PTR1
            lda   #>SIZEBUF
            sta   PTR1+1
            jsr   U2DEC             ;A = digit count on return
            tay
            lda   #$E2               ;'b' high-bit
            sta   SIZEBUF,y
            iny
            lda   #0
            sta   SIZEBUF,y
            lda   #<SIZEBUF
            sta   PTR0
            lda   #>SIZEBUF
            sta   PTR0+1
            jsr   PRPAD8
            rts

*---------------------------------------------------------------
* PRPAD8 -- IN PTR0 = NUL-terminated digit string; print it
* right-aligned in an 8-char field (leading spaces, then PUTS).
*---------------------------------------------------------------
PRPAD8      jsr   STRLEN
            cpx   #0                ;16-bit length: a high byte
            bne   :nopad            ;overflows the field, so pad
                                    ;none -- the low byte alone
                                    ;could read as 3 and indent
            cmp   #8
            bcs   :nopad
            sta   PRPADTMP
            lda   #8
            sec
            sbc   PRPADTMP
            sta   PADCNT
:padloop    lda   PADCNT
            beq   :nopad
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            dec   PADCNT
            bra   :padloop
:nopad      ldx   #FD_STDOUT
            jsr   PUTS
            rts

*---------------------------------------------------------------
* U3DEC -- convert an unsigned 24-bit value (LS3_VAL, 3 bytes)
* to a decimal string (no leading zeros except a solitary "0")
* at (PTR1). Local to ls.s -- liba's U2DEC is 16-bit only, and
* EOF is a 3-byte field (up to 16,777,215 -- 8 digits, hence the
* -l column's width). Same repeated-subtraction shape as
* src/liba/num.s's U2DEC, one byte wider throughout.
*---------------------------------------------------------------
U3DEC       ldy   #0
            lda   #0
            sta   LS3_LZ
            ldx   #0
:digitloop  lda   #0
            sta   LS3_DIGIT
:sub8       lda   POW8+2,x
            sta   LS3_SUB+2
            lda   POW8+1,x
            sta   LS3_SUB+1
            lda   POW8,x
            sta   LS3_SUB
            lda   LS3_VAL+2
            cmp   LS3_SUB+2
            bcc   :nodig
            bne   :dosub
            lda   LS3_VAL+1
            cmp   LS3_SUB+1
            bcc   :nodig
            bne   :dosub
            lda   LS3_VAL
            cmp   LS3_SUB
            bcc   :nodig
:dosub      sec
            lda   LS3_VAL
            sbc   LS3_SUB
            sta   LS3_VAL
            lda   LS3_VAL+1
            sbc   LS3_SUB+1
            sta   LS3_VAL+1
            lda   LS3_VAL+2
            sbc   LS3_SUB+2
            sta   LS3_VAL+2
            inc   LS3_DIGIT
            bra   :sub8
:nodig      lda   LS3_DIGIT
            bne   :emit
            lda   LS3_LZ
            bne   :emit
            cpx   #21               ;units position (8th digit)
            beq   :emit
            bra   :skip
:emit       lda   #1
            sta   LS3_LZ
            lda   LS3_DIGIT
            ora   #$B0
            sta   (PTR1),y
            iny
:skip       inx
            inx
            inx
            cpx   #24
            bne   :digitloop
            lda   #0
            sta   (PTR1),y
            tya
            rts

*---------------------------------------------------------------
* LSINITPARM -- the constant fields of ls's two MLI parmlists,
* STORED rather than emitted. Both lists moved into the `dum`
* arena at the end of this file, and an MLI parameter list must
* be CONTIGUOUS bytes at one address -- so a list that is mostly
* scratch (GET_FILE_INFO's ten result fields, all written by the
* kernel before ls reads them) cannot leave its two constant
* fields behind in emitted text when the rest moves. The
* `param_count` byte is NONZERO, so no zeroing scheme could
* supply it either; it has to be a store. Same resolution as
* cat.s's INITPARMS and readdir.s's RD_INITPARM
* (docs/STICKY.md sec 24/sec 26,
* learning:01M0M9R7RT22JEPP2R0Y6J9MBX).
*
* This one does NOT pay for itself in bytes and that is stated
* rather than hidden: 24 emitted bytes go away, 34 bytes of code
* arrive, so ls is 10 bytes WORSE for it. What it buys is that
* the kernel's copyback into GFIPARM's ten result fields stops
* landing in emitted text -- which is what sec 21's immutable-
* text goal means, and the precondition for ls's bank being
* reused warm (docs/STICKY.md sec 27).
*---------------------------------------------------------------
LSINITPARM  lda   #1                ;GET_PREFIX param_count
            sta   GPPARM
            lda   #<PFXBUF
            sta   GPPARM_BUF
            lda   #>PFXBUF
            sta   GPPARM_BUF+1
            lda   #PCOUNT_GFI
            sta   GFIPARM
            lda   #<PATHBUF
            sta   GFIPARM_PATH
            lda   #>PATHBUF
            sta   GFIPARM_PATH+1
            rts

*---------------------------------------------------------------
* Data
*---------------------------------------------------------------
POW8        dfb   $80,$96,$98       ;10,000,000
            dfb   $40,$42,$0F       ;1,000,000
            dfb   $A0,$86,$01       ;100,000
            dfb   $10,$27,$00       ;10,000
            dfb   $E8,$03,$00       ;1,000
            dfb   $64,$00,$00       ;100
            dfb   $0A,$00,$00       ;10
            dfb   $01,$00,$00       ;1

TXTSTR      asc   "TXT"
            dfb   0
BINSTR      asc   "BIN"
            dfb   0
*-- docs/DEVFS.md: spelled as `dfb` hex, not `asc "..."` --
*-- check-encoding's ratchet (scripts/check_encoding.py) counts
*-- every double-quoted `asc` directive as encoding debt, and
*-- pinned counts are shrink-only. Same bytes as `asc "BLK"`/
*-- `asc "CHR"` would emit -- 'B'=$C2 'L'=$CC 'K'=$CB, 'C'=$C3
*-- 'H'=$C8 'R'=$D2, high-bit, matching TXTSTR/BINSTR's own
*-- convention above.
BLKSTR      dfb   $C2,$CC,$CB,0
CHRSTR      dfb   $C3,$C8,$D2,0
DIRSTR      asc   "DIR"
            dfb   0
SYSSTR      asc   "SYS"
            dfb   0
BASSTR      asc   "BAS"
            dfb   0

CENT19      asc   "19"
            dfb   0
CENT20      asc   "20"
            dfb   0
DASH        asc   "-"
            dfb   0
SPACECH     asc   " "
            dfb   0
COLONCH     asc   ":"
            dfb   0
* -- "-" + 15 spaces + NUL = the 16-char blank date field --
DASHFIELD   dfb   $AD,$A0,$A0,$A0,$A0,$A0
            dfb   $A0,$A0,$A0,$A0,$A0
            dfb   $A0,$A0,$A0,$A0,$A0,$00

USAGEMSG    asc   "usage: ls [-lC1trdFsR] [path ...]"
            dfb   $8D,0
NOCWDMSG    asc   "ls: no current directory"
            dfb   $8D,0
ERRPFX      asc   "ls: "
            dfb   0
ERRSUF_ACCESS
            asc   ": cannot access"
            dfb   $8D,0
ERRSUF_TRUNC
            asc   ": truncated at 255 entries"
            dfb   $8D,0
