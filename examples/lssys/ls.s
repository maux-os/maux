*---------------------------------------------------------------
* ls.s -- LS.SYSTEM, a ProDOS 8 program built on maux.
*
*   nas -o ls.o ls.s
*   ld -t FF -a 2000 -o LS.SYSTEM ls.o
*   bye LS.SYSTEM
*
* This knows nothing of maux. It calls the real ProDOS MLI at
* $BF00 and the monitor ROM's COUT, and runs on any ProDOS 8
* machine, with or without maux under it.
*
* It finds its prefix directory (GET_PREFIX), opens it like a
* file and READs it a block at a time. The first block's header
* says how long an entry is ($23) and how many fit in a block
* ($24); the entries follow a 4-byte block header. The high
* nibble of an entry's first byte is its storage type and the
* low nibble the name length; the name follows. Storage type 0
* is a deleted entry, $E and $F are directory headers, anything
* else is a file or a subdirectory.
*
* It collects the names, writes them to a file GOT, prints them
* on the screen (after clearing it with the monitor's HOME),
* waits for a key and QUITs, which brings maux back. Any MLI
* error prints a short message and QUITs: no reference number
* of 0 ever reaches READ or CLOSE (CLOSE 0 closes every file).
*
* GOT is written the way maux writes text (high bit set, each
* line ended by $8D), so maux's own tools compare it with no
* conversion. The names are the ones ProDOS stores: upper case.
* GOT is created only after the directory has been read, so it
* does not list itself.
*
* A SYSTEM file loads flat at $2000, so everything the program
* allocates above itself is its size limit. The MLI's two 1 KB
* io_buffers start at $9800 and the other buffers sit above
* them, below the ProDOS global page at $BF00, so the image may
* grow to 30,720 bytes, which is also the limit bye enforces.
*
* Pathnames in raw MLI calls are plain 7-bit ASCII (single
* quotes). COUT wants the high bit set, so the program ORs
* HIBIT in as it copies each name.
*
* This file is staged on the release disk as MAUX TEXT (high
* bit set, lines ended by $8D), exactly what `vi` writes. nas
* reads that or ProDOS-standard text (low ASCII, $0D) alike.
*---------------------------------------------------------------
            rel
            lst   off
            xc                     ;enable the 65C02 (bra)
TMLI        equ   $BF00
COUT        equ   $FDED
HOME        equ   $FC58
KBD         equ   $C000
KBDSTRB     equ   $C010
STACKTOP    equ   $FF
HIBIT       equ   $80
CR          equ   $8D
SLASH       equ   $2F
EOFERR      equ   $4C              ;end of data: not an error
DUPERR      equ   $47              ;CREATE of a name that exists
TYPEMASK    equ   $F0
LENMASK     equ   $0F
HDRTYPE     equ   $E0              ;$E0 and $F0 are headers
IOBUF1      equ   $9800            ;io_buffer, 1 KB, aligned
IOBUF2      equ   $9C00
DIRBUF      equ   $A000            ;one directory block
ENTRIES     equ   $A004            ;DIRBUF + 4
HDRLEN      equ   $A023            ;DIRBUF+$23 entry_length
HDRPER      equ   $A024            ;DIRBUF+$24 entries_per
NAMES       equ   $A200            ;collected names
LIMITHI     equ   $BA              ;stop collecting at $BA00
TMPNAME     equ   $BB00
PREFIX      equ   $BC00
ENT         equ   $06              ;zero page, free for programs
COUNT       equ   $08
NLEN        equ   $09
LEN2        equ   $0A
OUT         equ   $0B
ELEN        equ   $0D
PERBLK      equ   $0E

START       ldx   #STACKTOP
            txs
            cld
            jsr   HOME             ;clear the screen
            bit   KBDSTRB          ;drop any key already down
            lda   #<NAMES
            sta   OUT
            lda   #>NAMES
            sta   OUT+1
            jsr   TMLI
            dfb   $C7              ;GET_PREFIX
            da    GPPARM
            bcs   ERR
            ldx   PREFIX           ;length
            lda   PREFIX,x         ;last character
            cmp   #SLASH
            bne   :open
            dec   PREFIX           ;OPEN wants no trailing slash
:open       jsr   TMLI
            dfb   $C8              ;OPEN the prefix directory
            da    OPDPARM
            bcs   ERR
            lda   OPDREF
            sta   RDREF
            sta   CLDREF
            jsr   TMLI
            dfb   $CA              ;READ the first block
            da    RDPARM
            bcs   ERR
            lda   HDRLEN           ;sizes come from the header
            sta   ELEN
            lda   HDRPER
            sta   PERBLK
:walk       jsr   WALK
            jsr   TMLI
            dfb   $CA              ;READ the next block
            da    RDPARM
            bcc   :walk
            cmp   #EOFERR
            bne   ERR              ;a real error
            jsr   TMLI
            dfb   $CC              ;CLOSE the directory
            da    CLDPARM
            bcs   ERR
            bra   MAKEGOT

*---------------------------------------------------------------
* ERR -- an MLI call failed: say so, wait for a key, QUIT.
*---------------------------------------------------------------
ERR         ldx   #0
:say        lda   ERRTXT,x
            beq   :said
            phx
            jsr   COUT
            plx
            inx
            bra   :say
:said       jsr   KEY
QUIT        jsr   TMLI
            dfb   $65              ;QUIT: maux comes back
            da    QUPARM

KEY         lda   KBD              ;wait for a key
            bpl   KEY
            bit   KBDSTRB
            rts

MAKEGOT     jsr   TMLI
            dfb   $C0              ;CREATE GOT
            da    CRPARM
            bcc   :made
            cmp   #DUPERR          ;it may already be there
            bne   ERR
:made       jsr   TMLI
            dfb   $C8              ;OPEN GOT
            da    OPGPARM
            bcs   ERR
            lda   OPGREF
            sta   WRREF
            sta   EOFREF
            sta   CLGREF
            sec
            lda   OUT
            sbc   #<NAMES
            sta   WRREQ
            sta   EOFLO
            lda   OUT+1
            sbc   #>NAMES
            sta   WRREQ+1
            sta   EOFLO+1
            jsr   TMLI
            dfb   $CB              ;WRITE the names
            da    WRPARM
            bcs   ERR
            jsr   TMLI
            dfb   $D0              ;SET_EOF (old GOT)
            da    EOFPARM
            bcs   ERR
            jsr   TMLI
            dfb   $CC              ;CLOSE GOT
            da    CLGPARM
            bcs   ERR
            jsr   SHOW
            jsr   KEY
            bra   QUIT

*---------------------------------------------------------------
* WALK -- the entries of the block just read: append each live
* name, high bit set and CR-ended, at OUT.
*---------------------------------------------------------------
WALK        lda   #<ENTRIES
            sta   ENT
            lda   #>ENTRIES
            sta   ENT+1
            lda   PERBLK
            sta   COUNT
:entry      ldy   #0
            lda   (ENT),y
            and   #LENMASK
            sta   NLEN
            lda   (ENT),y
            and   #TYPEMASK
            beq   :next            ;storage type 0: deleted
            cmp   #HDRTYPE
            bcs   :next            ;a directory header
            lda   OUT+1
            cmp   #LIMITHI
            bcs   :next            ;buffer full: drop the name
            ldy   #0
:copy       iny
            lda   (ENT),y
            ora   #HIBIT
            sta   TMPNAME-1,y
            cpy   NLEN
            bne   :copy
            lda   #CR
            sta   TMPNAME,y
            iny
            sty   LEN2
            ldy   #0
:move       lda   TMPNAME,y
            sta   (OUT),y
            iny
            cpy   LEN2
            bne   :move
            tya
            clc
            adc   OUT
            sta   OUT
            bcc   :next
            inc   OUT+1
:next       clc
            lda   ENT
            adc   ELEN
            sta   ENT
            bcc   :more
            inc   ENT+1
:more       dec   COUNT
            bne   :entry
            rts

*---------------------------------------------------------------
* SHOW -- print the collected names through the monitor ROM.
*---------------------------------------------------------------
SHOW        lda   #<NAMES
            sta   ENT
            lda   #>NAMES
            sta   ENT+1
:again      lda   ENT
            cmp   OUT
            bne   :more
            lda   ENT+1
            cmp   OUT+1
            beq   :end
:more       ldy   #0
            lda   (ENT),y
            jsr   COUT
            inc   ENT
            bne   :again
            inc   ENT+1
            bra   :again
:end        rts

ERRTXT      asc   "MLI ERROR",8D,00
GPPARM      dfb   1
            da    PREFIX
OPDPARM     dfb   3
            da    PREFIX
            da    IOBUF1
OPDREF      dfb   0
RDPARM      dfb   4
RDREF       dfb   0
            da    DIRBUF
            da    512
            da    0
CLDPARM     dfb   1
CLDREF      dfb   0
CRPARM      dfb   7
            da    GOTNAME
            dfb   $C3
            dfb   $04
            da    0
            dfb   1
            da    0
            da    0
OPGPARM     dfb   3
            da    GOTNAME
            da    IOBUF2
OPGREF      dfb   0
WRPARM      dfb   4
WRREF       dfb   0
            da    NAMES
WRREQ       da    0
            da    0
EOFPARM     dfb   2
EOFREF      dfb   0
EOFLO       da    0
            dfb   0
CLGPARM     dfb   1
CLGREF      dfb   0
QUPARM      dfb   4
            dfb   0
            da    0
            dfb   0
            da    0

GOTNAME     dfb   3
            asc   'GOT'
