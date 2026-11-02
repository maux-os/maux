*---------------------------------------------------------------
* bufwriter.s -- docs/PROCIO.md sec 6 gate (c): "exit flushes."
* A REAL liba-linked userland program (not a raw $FF00 harness
* -- the point is to prove liba's own EXIT, not a hand-rolled
* imitation of it). Opens a fixed path, writes a handful of
* bytes via PUTC to the returned fd (>=3, so full-buffered per
* stdio.s's policy -- BUFSIZ=512, well above what's written
* here, and none of the bytes is $8D, so NEITHER buffering
* trigger ever fires), then calls EXIT with NO explicit flush
* call anywhere in this file. If EXIT's flush-on-exit is missing
* or wrong, the bytes never reach the file -- companion
* src/test/bufiotest.s/bufiotestb.s spawns this, waits, then
* reads the file back and checks it byte-exact.
*---------------------------------------------------------------

            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/bufwriter.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

PAYLOAD_LEN equ   5

START       lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :done            ;can't open -- nothing to
                                   ;write, exit anyway (parent's
                                   ;read-back will show the
                                   ;miss)
            lda   OPARM_REF
            sta   WFD

            ldy   #0
:wrloop     lda   PAYLOAD,y
            ldx   WFD
            jsr   PUTC              ;buffered -- fd>=3, full
                                   ;buffering, no CR in the
                                   ;payload, BUFSIZ=512 never
                                   ;reached -- NEITHER flush
                                   ;trigger fires
            iny
            cpy   #PAYLOAD_LEN
            bne   :wrloop

* Deliberately NO explicit flush/SC_WRITE here -- the whole
* point. Only EXIT's own SIO_FLUSHALL (stdio.s) may land these
* bytes.
:done       lda   #0
            jsr   EXIT

PAYLOAD     asc   "BFWRT"          ;5 bytes, no CR, high-bit-set
                                   ;liba string convention
WFD         ds    1

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    BOPATH
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

BOPATH      dfb   16
            asc   "/mnt/MAUX/BUFOUT"

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s
