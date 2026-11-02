*---------------------------------------------------------------
* cat.s -- concatenate files to stdout.
*
* CONTRACT: for each FILE argument, in order, copy its contents
* to stdout (fd 1). If no FILE arguments are given (argc == 1),
* copy stdin (fd 0) to stdout instead (classic V6 `cat` no-args
* behavior). Each FILE is opened O_RDONLY; a file that fails to
* open prints "cat: cannot open <name>" to stderr (fd 2) and is
* SKIPPED -- cat continues with the remaining arguments. No
* flags (no -n, -v, -s, ...). Exit status: 0 if every named file
* opened successfully, 1 if any file failed to open (stdin-copy
* mode always exits 0 -- there's nothing to fail to open).
*
* REWORKED this round against the RATIFIED ABI
* (docs/SYSCALL.md): file calls are now real ProDOS MLI
* OPEN/READ/WRITE/CLOSE, verbatim parmlist shapes
* (inc/mli.equ). request_count/trans_count are 2 BYTES now
* -- this round's copy loop reads the actual bytes-transferred
* count out of the parmlist's trans_count field, not a 1-byte
* SC_READ return.
*
* io_buffer (architect review, merge-blocking finding, corrected
* this round): OPEN's io_buffer field is NOT a process-owned
* buffer this util reserves -- the MLI dereferences it
* CONTINUOUSLY while the file stays open (per-file state lives
* there between calls) and the MLI itself runs in MAIN memory
* with no visibility into process banks at all. A process-bank
* address in that field would point at whatever unrelated byte
* happens to share that address in main once the kernel
* dereferences it, not at anything cat reserved. The kernel
* (task #11) must own the 1024-byte-per-open-file buffers in
* MAIN, keyed by the same fd->refnum table ruling 5 already
* requires, and rewrite this field when it translates the
* parmlist on delegation. cat sets it to $0000 (PROPOSED
* convention, task #11 ratifies -- see docs/USERLAND.md "ABI
* RESOLUTIONS") and reserves NO buffer for it -- contrast with
* data_buffer below (RPARM_BUF/WPARM_BUF), which correctly IS a
* process-bank address, since copyin/copyout moves that data
* through bankcopy rather than the MLI touching process memory
* directly.
*
* Uses ONLY liba (src/liba) -- no direct syscalls, no raw gate
* address, no equates; see docs/USERLAND.md and syscalls.s's
* header for why.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/cat.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   512              ;read/write chunk size
                                   ;(data_buffer -- a real
                                   ;process-bank address;
                                   ;arbitrary v1 choice,
                                   ;unrelated to io_buffer)

*---------------------------------------------------------------
* START -- INITPARMS first, because everything below reads
* storage that `dum` does not initialise.
*
* THE SIXTEEN-BYTE PROLOGUE THAT USED TO BE HERE IS GONE
* (docs/STICKY.md sec 21, which supersedes sec 17's per-program
* `jsr ZEROBSS` convention). Nothing zeroes cat's arena now:
* every variable in it is write-before-read -- that is what
* made the `dum` conversion legal in the first place -- and the
* handful of parmlist fields that genuinely needed a zero start
* are stored by INITPARMS below instead of being supplied by a
* 604-byte sweep. The one region the system does zero is the
* kernel's 256-byte page at the image end, and it belongs to
* liba (src/liba/libabss.s), not to cat.
*---------------------------------------------------------------
START       jsr   INITPARMS

            lda   ARGC
            cmp   #1
            bne   :haveargs
            ; no FILE args: copy stdin -> stdout, exit 0
            lda   #FD_STDIN
            sta   SRCFD
            jsr   COPYFD
            lda   #0
            jsr   EXIT

:haveargs   lda   #0
            sta   ERRFLAG
            lda   #1
            sta   ARGIDX
*-- -u IS ALREADY WHAT THIS PROGRAM DOES, so accepting it is
*-- honesty rather than a stub. POSIX's -u asks for bytes to be
*-- written without delay; COPYFD reads and writes through the
*-- MLI parmlists directly and never goes near liba's buffered
*-- stdio, so every byte is already written as soon as it is
*-- read. Refusing the flag made `cat -u FILE` treat "-u" as a
*-- pathname, fail to open it, and exit 1 with the right output
*-- and the wrong status.
*--
*-- LEADING ONLY, which is all POSIX guarantees (Utility Syntax
*-- Guideline 9: options precede operands). A "-u" after a file
*-- name stays an operand, and a file really called -u is still
*-- reachable as ./-u, the same escape hatch every Unix offers.
:optskip    lda   ARGIDX
            cmp   ARGC
            bcs   :onlyopts               ;nothing but options
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD                    ;'-'
            bne   :looparg
            iny
            lda   (PTR0),y
            cmp   #$F5                    ;'u'
            bne   :looparg
            iny
            lda   (PTR0),y
            bne   :looparg                ;"-u" EXACTLY, not a
            inc   ARGIDX                  ;name that starts so
            bra   :optskip
*-- `cat -u` with no operand is `cat` with no operand: stdin.
:onlyopts   lda   #FD_STDIN
            sta   SRCFD
            jsr   COPYFD
            lda   #0
            jsr   EXIT
:looparg    lda   ARGIDX
            jsr   GETARG                 ;-> PTR0 = argv[ARGIDX]
                                         ;(path)
*-- A lone "-" IS STDIN, mid-sequence and as often as it appears
*-- -- `cat a - b` is the documented way to splice the terminal
*-- between two files. Checked here, before MKPATH, because
*-- MKPATH would translate it into an ordinary one-character
*-- pathname and the open would fail on a name ProDOS cannot
*-- even hold.
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD                    ;'-'
            bne   :notdash
            iny
            lda   (PTR0),y
            bne   :notdash                ;"-" EXACTLY
            lda   #FD_STDIN
            sta   SRCFD
            jsr   COPYFD
            jmp   :nextarg                ;nothing to close: the
                                          ;fd is not ours
:notdash    lda   ARGIDX
            jsr   GETARG                 ;PTR0 again -- the test
                                         ;above left it, but a
                                         ;re-fetch costs 5 bytes
                                         ;and survives an edit
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH                 ;liba string -> MLI
                                         ;pathname
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :openerr
            lda   OPARM_REF              ;fd, kernel-translated
                                         ;(ruling 5)
            sta   SRCFD
            jsr   COPYFD
            ldx   SRCFD
            stx   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            bra   :nextarg

:openerr    lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG                 ;re-fetch -- PUTS above
                                         ;clobbered PTR0
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG

:nextarg    lda   ARGIDX
            clc
            adc   #1
            sta   ARGIDX
            cmp   ARGC
            bcs   :argsdone
            jmp   :looparg                ;the -u/- checks grew
:argsdone
            lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* COPYFD -- copy SRCFD to fd 1 (stdout) in BUFSZ-byte chunks
* until EOF. IN: SRCFD (module-local, pre-set by caller) A read
* error is treated as EOF for v1 -- see docs/USERLAND.md "ABI
* RESOLUTIONS" (raw MLI error codes are not decoded by any v1
* util yet). Writes may complete partially when stdout is a
* pipe, so every read buffer is written in a loop until
* WPARM_REQ reaches zero.
*---------------------------------------------------------------
COPYFD      lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :stop                  ;read error -- treated
                                         ;as EOF, v1
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :stop                  ;trans_count == 0 --
                                         ;EOF
            lda   RPARM_TRANS
            sta   WPARM_REQ
            lda   RPARM_TRANS+1
            sta   WPARM_REQ+1
            lda   #<CBUF
            sta   WPARM_BUF
            lda   #>CBUF
            sta   WPARM_BUF+1
            jsr   WRITE_ALL
            bra   COPYFD
:stop       rts

WRITE_ALL   lda   WPARM_REQ
            ora   WPARM_REQ+1
            beq   :done
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcs   :done                  ;write error -- stop,
                                         ;v1
            lda   WPARM_TRANS
            ora   WPARM_TRANS+1
            beq   :done                  ;defensive: avoid an
                                         ;infinite loop
            sec
            lda   WPARM_REQ
            sbc   WPARM_TRANS
            sta   WPARM_REQ
            lda   WPARM_REQ+1
            sbc   WPARM_TRANS+1
            sta   WPARM_REQ+1
            clc
            lda   WPARM_BUF
            adc   WPARM_TRANS
            sta   WPARM_BUF
            lda   WPARM_BUF+1
            adc   WPARM_TRANS+1
            sta   WPARM_BUF+1
            bra   WRITE_ALL
:done       rts

*---------------------------------------------------------------
* INITPARMS -- the parmlist fields that are genuinely CONSTANT.
* START's first act.
*
* An MLI parmlist must be CONTIGUOUS, so a block that is mostly
* scratch (ref_num, trans_count, the patched buffer/count
* fields)
* cannot leave its two or three constant bytes behind in text --
* it is, in docs/STICKY.md sec 17's phrase, bss wearing a hat.
* The constants therefore get stored rather than emitted.
*
* NOTHING ZEROES THIS ARENA ANY MORE (sec 21), and nothing in
* it needs a zero: OPARM_IOBUF used to rely on ZEROBSS for its
* $0000, but the kernel REPOINTS io_buffer at its own allocated
* buffer before issuing the real MLI call
* (src/kernel/procfile3.s's `sta PRC_PARM+MLI_IOBUFLO/HI`) and
* never copies that field back, so its incoming value is read
* and discarded. Every result field is written by the kernel
* before the program reads it. Fields patched before each use
* (RPARM_REF, WPARM_BUF, WPARM_REQ, CPARM_REF) are deliberately
* absent -- see the read-before-write trace on the arena below.
*---------------------------------------------------------------
INITPARMS   lda   #OPEN_RO             ;read intent: cat only
            sta   OPARM                ;reads (OPEN-RW-2)
            lda   #<PATHBUF
            sta   OPARM_PATH
            lda   #>PATHBUF
            sta   OPARM_PATH+1
            lda   #PCOUNT_READ
            sta   RPARM
            lda   #<CBUF
            sta   RPARM_BUF
            lda   #>CBUF
            sta   RPARM_BUF+1
            lda   #<BUFSZ
            sta   RPARM_REQ
            lda   #>BUFSZ
            sta   RPARM_REQ+1
            lda   #PCOUNT_WRITE
            sta   WPARM
            lda   #FD_STDOUT
            sta   WPARM_REF
            lda   #PCOUNT_CLOSE
            sta   CPARM
            rts

ERRMSG      asc   "cat: cannot open "
            dfb   $00

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* cat's bss -- `dum`/`dend` at the TEXTUAL END of the file, so
* the arena begins past every emitted byte (`dum` computes
* addresses relative to the real PC where it opens, and `dend`
* restores that PC, so anything emitted after `dend` would
* overlay the arena). 580 bytes that were `ds` -- real zeros in
* the image, carried on every disk read and every 39.07
* cyc/byte bank copy -- plus the 24 bytes of parmlist that used
* to be emitted alongside them.
*
* Anchored at LIBA_BSSEND, not at `*`: src/liba/libabss.s has
* already opened its own block at `*` (the image end, which is
* where the kernel's zeroed page is), and two blocks anchored
* at `*` are the SAME BYTES.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21 retired sec
* 17's entry-time sweep). The read-before-write trace below is
* what makes that safe, and it is the same trace every other
* `dum` conversion in this tree rests on:
*
*  - SRCFD: written by START (stdin case) or from OPARM_REF
*    (file case) before COPYFD reads it.
*  - ARGIDX: `lda #1 / sta ARGIDX` before the first GETARG.
*  - ERRFLAG: `lda #0 / sta ERRFLAG` before the arg loop; the
*    no-args path exits with a literal 0 and never reads it.
*  - PATHBUF: written whole by MKPATH (count-prefixed, not
*    NUL-scanned) every iteration before OPEN reads it.
*  - CBUF: filled by SC_READ; WPARM_REQ is set from
*    RPARM_TRANS, so WRITE_ALL never reads past what this
*    call actually wrote.
*  - the four parmlists: constants stored by INITPARMS, result
*    fields written by the kernel before cat reads them,
*    OPARM_IOBUF read-and-discarded by the kernel (see
*    INITPARMS above), patched fields written before each call
*    (RPARM_REF from SRCFD, WPARM_BUF/WPARM_REQ per chunk in
*    COPYFD, CPARM_REF from SRCFD).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
SRCFD       ds    1
ARGIDX      ds    1
ERRFLAG     ds    1

PATHBUF     ds    65             ;1 count byte + up to 64 chars
                                 ;(MLI shape)
CBUF        ds    BUFSZ          ;data_buffer -- process-bank
                                 ;address, kernel copyin/outs
                                 ;through it (unlike io_buffer)

OPARM       ds    1              ;param_count
OPARM_PATH  ds    2
OPARM_IOBUF ds    2              ;kernel-owned (main memory) --
                                 ;NOT a process buffer; see file
                                 ;header
OPARM_REF   ds    1              ; result: fd

RPARM       ds    1
RPARM_REF   ds    1              ;patched from SRCFD before each
                                 ;call
RPARM_BUF   ds    2
RPARM_REQ   ds    2
RPARM_TRANS ds    2              ; result: bytes actually read

WPARM       ds    1
WPARM_REF   ds    1              ;constant -- cat always writes
                                 ;to stdout
WPARM_BUF   ds    2
WPARM_REQ   ds    2              ;patched from RPARM_TRANS each
                                 ;chunk
WPARM_TRANS ds    2

CPARM       ds    1
CPARM_REF   ds    1              ; patched from SRCFD
CAT_BSSEND                       ;scripts/check_catread.py's
                                 ;poison window ends here -- a
                                 ;`dum` label, emits nothing
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
            err   */$BF00
            dend
