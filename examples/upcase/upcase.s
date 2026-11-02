*---------------------------------------------------------------
* upcase.s -- a filter: read stdin to EOF, raise a-z, write
* stdout.
*
*   nas -o upcase.o upcase.s
*   ld -o upcase upcase.o -L /usr/lib -l a
*   ./upcase < /usr/man/ECHO
*
* GETC, PUTC and EXIT are liba's. GETC reads one byte from the
* fd in X and returns it in A; carry set means end of file.
* PUTC writes A to the fd in X.
*
* The test is made on the low seven bits, so it does not care
* whether the byte arrived as maux text (high bit set, lines
* ended by $8D) or as ProDOS-standard text (low ASCII, lines
* ended by $0D). Every byte that is not a-z goes out exactly
* as it came in, so the output has the same convention as the
* input. That is the README "Text" rule for a filter.
*
* Clearing bit 5 turns a into A in either polarity: $61 -> $41
* and $E1 -> $C1.
*---------------------------------------------------------------
            rel
            lst   off
            xc                     ;enable the 65C02 (bra)
GETC        ext
PUTC        ext
EXIT        ext
            put   /usr/inc/sc.fd.equ

LOWA        equ   $61
LOWZ1       equ   $7B              ;one past z
SEVEN       equ   $7F
CASEBIT     equ   $DF              ;clears bit 5

START       ldx   #FD_STDIN
            jsr   GETC
            bcs   :eof
            pha
            and   #SEVEN
            cmp   #LOWA
            bcc   :keep
            cmp   #LOWZ1
            bcs   :keep
            pla
            and   #CASEBIT
            bra   :emit
:keep       pla
:emit       ldx   #FD_STDOUT
            jsr   PUTC
            bra   START
:eof        lda   #0
            jsr   EXIT
