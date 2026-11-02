*---------------------------------------------------------------
* tail.s -- print the last N lines of a file, or of fd 0.
*
* Usage: tail [-f] [-n N | -N | -c N] [file]
*
* -n N is the POSIX spelling (FLEET F.2 A12, 2026-09-01); the
* bare -N form stays -- both feed the same accumulator and the
* same MAXLINES fence.
*
* -c N (SHIPPED 2026-09-17): the last N BYTES instead of lines,
* same ring-buffer shape as the line path but with a 1-byte slot
* (plain `RING,x` indexing, no per-slot hi-byte trick) and no
* CR/line concept in either the read or the print loop -- raw
* bytes in, raw bytes out. Capped at MAXBYTES=255, loud error
* past it (same posture as MAXLINES for -n), which keeps CNBYTES
* and the whole byte-ring index math 8-bit -- no 16-bit ring
* offset arithmetic anywhere. -c and -n/-N are mutually
* exclusive in practice (MODEBYTE picks one path at :run); ANY
* -c anywhere on the line switches to byte mode for the whole
* run (MODEBYTE is a sticky flag, never cleared by a later
* -n/-N) -- untested combined usage, not a POSIX requirement
* either way (the utility takes one counting mode).
*
* -f (SHIPPED 2026-10-08): after the usual output, keep going.
* A FOLLOW LOOP in tailin.s reopens the file once a second (60
* SYS_TICK ticks, sleep.s's clock), seeks to where the last
* read stopped, copies whatever is new to stdout as raw bytes,
* closes, and waits again. It never returns -- a typed ^C is
* how it ends, and the shell then reports 130. It REOPENS
* rather than re-checking GET_EOF because a ProDOS file control
* block keeps its OWN copy of the EOF: a writer elsewhere
* changes the directory entry, not the reader's FCB, so the
* open reader would never see the file grow. It holds no file
* open between polls, which is also why a writer's own OPEN
* never meets ours. A file that has become SHORTER than our
* position (truncated and rewritten) is followed from its
* start, as GNU tail does. With no file operand (standard
* input) -f is ignored, as POSIX allows for a pipe. With no
* usable tick source it refuses, like sleep.
*
* V6 semantics; lines are CR ($8D) terminated, same convention
* as wc.s/uniq.s. A final unterminated line IS counted as a
* line (matches uniq.s's GETLINE header) -- see OUTPUT POLICY
* below for what happens to it on the way back out.
*
* DESIGN: RING BUFFER, not seek-from-end. Justification: fd 0
* may be a pipe (task brief), where SEEK_END is impossible, so
* a seek-based tail STILL needs a ring-buffer fallback for that
* path -- implementing seek would not remove the ring buffer,
* only add a second code path alongside it. Given the fixtures
* here are small files, the seek variant's only real payoff
* (avoiding a full read of a huge file) is not worth doubling
* the code for a v1 util. One code path, works identically on a
* real file or a pipe: keep the last NLINES lines in a fixed-
* size ring as they stream past, in ONE pass. A seek-from-end
* fast path (real files only) is the natural follow-up if a
* huge-file case ever shows up -- not implemented now.
*
* BUFFER SIZING. LINEMAX=255 (matches uniq.s's own line-buffer
* cap) -- each ring slot is LINEMAX+1=256 bytes so slot
* addresses fall out of pure hi-byte arithmetic (see RING
* addressing below: slot lo byte never changes, only the hi
* byte gets + WIDX -- no multiply, no lookup table). MAXLINES=64
* bounds how large NLINES may be: ring = MAXLINES*(LINEMAX+1) =
* 64*256 = 16384 bytes, a `dum` arena (not `ds` -- see its own
* comment below). Requesting -N with N > MAXLINES is a LOUD
* error (`tail: -N too large`, exit 2), never a silent clamp --
* same posture uniq.s takes on LINEMAX overflow: a bound the
* user can hit must say so, not misbehave quietly.
*
* LINE OVERFLOW POLICY: identical to uniq.s's GETLINE -- once
* LINEMAX(255) bytes have accumulated without a CR, the line is
* returned AS IS, unterminated by input, and the very next byte
* starts a new logical line. Every byte still reaches some line;
* nothing is silently dropped.
*
* OUTPUT POLICY: a stored line is NORMALIZED on the way out --
* PRINT always appends one CR after it, whether or not the
* SOURCE line had one. This matches uniq.s's OUTRUN (which also
* cannot tell, after GETLINE, whether a line's CR was real or
* synthesized by EOF) rather than preserving raw bytes. A file
* whose last line lacks a trailing CR still gets one on output.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/tail.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;read chunk -- see GETBYTE
LINEMAX     equ   255              ;max stored line bytes
MAXLINES    equ   64               ;ring capacity cap -- header
MAXBYTES    equ   255              ;-c cap, CNBYTES stays 8-bit
DEFN        equ   10               ;default N
RINGSZ      equ   16384            ;MAXLINES*(LINEMAX+1) =
                                   ;64*256 -- literal, not a
                                   ;computed expr (no parens/
                                   ;precedence across dialects,
                                   ;sort.s's ARENA_SIZE
                                   ;precedent). MAXLINES is a
                                   ;genuine slot COUNT, not a
                                   ;byte-budget proxy in count's
                                   ;clothing (street-library
                                   ;learning
                                   ;01M07V2D0T25FYD6ASCMPJYNWQ's
                                   ;own anti-pattern): each slot
                                   ;is a FIXED 256B
                                   ;regardless of line content,
                                   ;so count and bytes never
                                   ;disagree the way a packed
                                   ;variable-length region (that
                                   ;learning's argv case) would.

START       lda   #DEFN
            sta   NLINES
            stz   HAVEOPT
            stz   HAVEFILE
            stz   NEWNLO
            stz   NEWNHI
            stz   MODEBYTE
            stz   FFLAG

            lda   #<TAILOPTS
            ldx   #>TAILOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$BF                  ;'?' unrecognised
            beq   :usage
            cmp   #$EE                  ;'n': the POSIX spelling
            beq   :nopt                 ;(-n N), count as OPTARG
            cmp   #$E3                  ;'c': byte count
            beq   :copt
            cmp   #$E6                  ;'f': follow
            beq   :fopt
            sta   HAVEOPT
            and   #$0F                  ;hi-bit digit -> 0-9
            jsr   MUL10ADD
            bra   :optlp
*-- -n N (FLEET F.2, 2026-09-01): same accumulator, digits from
*-- OPTARG instead of the cluster; bare -N stays. A non-digit
*-- anywhere in N is usage, never a silent partial parse.
:nopt       sta   HAVEOPT
            bra   :ndigparse
:fopt       lda   #1
            sta   FFLAG
            jmp   :optlp
*-- -c N: last N BYTES, same digit accumulator as -n, routed to
*-- CNBYTES instead of NLINES at :optdone via MODEBYTE.
:copt       sta   HAVEOPT
            lda   #1
            sta   MODEBYTE
:ndigparse  lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            ldy   #0
:ndig       lda   (PTR0),y
            beq   :nde
            and   #$7F
            cmp   #'0'
            bcc   :usage
            cmp   #'9'+1
            bcs   :usage
            and   #$0F
            phy
            jsr   MUL10ADD
            ply
            iny
            bne   :ndig
:nde        cpy   #0
            beq   :usage                ;-n '' -- an empty count
            bra   :optlp
:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

:optdone    lda   HAVEOPT
            beq   :ncheck                ;no -N/-c: keep DEFN
            lda   MODEBYTE
            bne   :cbound
            lda   NEWNHI
            bne   :toobig
            lda   NEWNLO
            cmp   #MAXLINES+1
            bcs   :toobig
            lda   NEWNLO
            sta   NLINES
            bra   :ncheck
:toobig     lda   #<TOOBIGMSG
            sta   PTR0
            lda   #>TOOBIGMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT
*-- -c's bound: CNBYTES is 8-bit (MAXBYTES=255, the biggest
*-- value it can hold at all), so the only overflow is a nonzero
*-- high byte out of MUL10ADD -- no separate ceiling compare
*-- needed the way MAXLINES(64) needs one against a wider cell.
:cbound     lda   NEWNHI
            bne   :ctoobig
            lda   NEWNLO
            sta   CNBYTES
            bra   :ncheck
:ctoobig    lda   #<CTOOBIGMSG
            sta   PTR0
            lda   #>CTOOBIGMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

:ncheck     lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            cmp   #2
            bcs   :usage                 ;>1 operand -- error

            lda   NARGS
            bne   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            jmp   :run

:havefile   lda   OPTIND
            sta   ARGIDX
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opened
            lda   #<CANTOPEN
            sta   PTR0
            lda   #>CANTOPEN
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG                ;PUTS clobbered PTR0
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jsr   EXIT
:opened     lda   OPARM_REF
            sta   SRCFD
            lda   #1
            sta   HAVEFILE

:run        stz   OFFLO
            stz   OFFMID
            stz   OFFHI
            stz   WIDX
            stz   CNTLO
            stz   CNTHI
            stz   BUFPOS
            stz   BUFLEN
            lda   MODEBYTE
            bne   :brun
            lda   NLINES
            beq   :rddone                ;-0: nothing to buffer
:rdloop     lda   #<RING
            sta   PTR0
            lda   #>RING
            clc
            adc   WIDX
            sta   PTR0+1
            jsr   RDLINE
            bcs   :rddone
            inc   WIDX
            lda   WIDX
            cmp   NLINES
            bne   :nowrap
            stz   WIDX
:nowrap     jsr   BUMPCNT
            bra   :rdloop

*-- -c's byte ring: same wrap-and-count shape as the line ring
*-- above, one byte per slot (RING,x direct, no per-slot hi-byte
*-- trick since a slot IS a byte), no CR/line concept at all.
:brun       lda   CNBYTES
            beq   :rddone                ;-c 0: nothing
            stz   WBPOS
:bloop      jsr   GETBYTE
            bcs   :rddone
            ldx   WBPOS
            sta   RING,x
            inc   WBPOS
            lda   WBPOS
            cmp   CNBYTES
            bne   :bnowrap
            stz   WBPOS
:bnowrap    jsr   BUMPCNT
            bra   :bloop

:rddone     lda   HAVEFILE
            beq   :noclose
            lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:noclose
            lda   MODEBYTE
            bne   :bprint

            lda   CNTHI
            bne   :full
            lda   CNTLO
            cmp   NLINES
            bcs   :full
            sta   PRINTCNT
            stz   PRINTSTRT
            bra   :havecnt
:full       lda   NLINES
            sta   PRINTCNT
            lda   WIDX
            sta   PRINTSTRT
:havecnt    stz   PIDX
:ploop      lda   PIDX
            cmp   PRINTCNT
            beq   :pdone
            clc
            lda   PRINTSTRT
            adc   PIDX
            cmp   NLINES
            bcc   :noadj
            sbc   NLINES
:noadj      sta   CURIDX
            lda   #<RING
            sta   PTR0
            lda   #>RING
            clc
            adc   CURIDX
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   PIDX
            bra   :ploop

*-- -c's print path: raw bytes straight from the ring, no PUTS
*-- (which would stop at an embedded NUL) and no CR framing.
:bprint     lda   CNTHI
            bne   :bfull
            lda   CNTLO
            cmp   CNBYTES
            bcs   :bfull
            sta   PRINTCNT
            stz   PRINTSTRT
            bra   :bhavecnt
:bfull      lda   CNBYTES
            sta   PRINTCNT
            lda   WBPOS
            sta   PRINTSTRT
:bhavecnt   stz   PIDX
:bploop     lda   PIDX
            cmp   PRINTCNT
            beq   :pdone
            clc
            lda   PRINTSTRT
            adc   PIDX
            cmp   CNBYTES
            bcc   :bnoadj
            sbc   CNBYTES
:bnoadj     tax
            lda   RING,x
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   PIDX
            bra   :bploop

:pdone      lda   FFLAG
            beq   :exit0
            lda   HAVEFILE
            beq   :exit0                ;stdin: -f is ignored
            jmp   FOLLOW                ;never returns
:exit0      lda   #0
            jsr   EXIT

            put   tailin.s

USAGEMSG    asc   "usage: tail [-f] [-n N | -N | -c N] [file]"
            dfb   $8D,$00
TOOBIGMSG   asc   "tail: -N too large (max 64)"
            dfb   $8D,$00
CTOOBIGMSG  asc   "tail: -c count too large (max 255)"
            dfb   $8D,$00
CANTOPEN    asc   "tail: cannot open "
            dfb   $00
NOTICKMSG   asc   "tail: -f: no timer (needs a mouse card"
            asc   " or Mockingboard)"
            dfb   $8D,$00
TICKFAILMSG asc   "tail: tick syscall failed"
            dfb   $8D,$00
TAILOPTS    asc   "0123456789n:c:f"
            dfb   0

OPARM       dfb   OPEN_RO
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* RING -- the last-NLINES ring buffer, MAXLINES slots of
* LINEMAX+1 (256) bytes each. `dum`/`dend`, not `ds`: `ds` would
* emit all 16384 bytes as zeros into the binary (sort.s's own
* 46397B->2825B finding for exactly this reason); `dum` only
* computes the address, emits nothing. Must stay the textually
* LAST thing in the file (dum's addresses are relative to the
* real PC where it opens; real code after it would collide).
*
* `dum` memory is NOT zeroed -- read-before-write trace:
*
*   Every byte a reader touches was written by RDLINE first.
*   RDLINE always writes a NUL terminator at CURBUF-equivalent
*   offset RL_LEN before returning carry-clear, so PUTS (which
*   stops at the first NUL, print.s's STRLEN) never reads past
*   what RDLINE actually wrote for that call, regardless of what
*   stale bytes sit later in the 256-byte slot.
*
*   A slot is only READ by the print loop if its ring index
*   falls in [PRINTSTRT, PRINTSTRT+PRINTCNT) mod NLINES.
*   PRINTCNT is either CNTLO (the true number of lines RDLINE
*   wrote, when the ring never filled) or NLINES (when it did,
*   in which case every one of the NLINES slots has been
*   overwritten at least once by then, since WIDX only wraps
*   after a full lap). Either way, every slot the print loop
*   indexes was written by RDLINE at least once before that read
*   -- an UNWRITTEN slot (e.g. slots 3..9 of a 10-slot ring when
*   the file has 3 lines) is never in range, since PRINTCNT==3
*   and PRINTSTRT==0 there.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
*-- tail's scalars, 341 bytes that were still emitted `ds`
*-- zeros outside this arena. Trace (sec 21):
*--  - NLINES: `lda #DEFN / sta NLINES` are START's FIRST TWO
*--    instructions, so the default is a store, not a zero.
*--  - HAVEOPT/HAVEFILE/NEWNLO/NEWNHI: `stz`'d in the same
*--    opening run.
*--  - NARGS: `sta` before the argument-count test.
*--  - SRCFD: written on both the stdin and opened-file paths;
*--    its guarded reader also tests HAVEFILE first.
*--  - ARGIDX: `sta` at :havefile; never read on the stdin
*--    path.
*--  - MD_DIGIT/MD_TWOLO/MD_TWOHI: MUL10ADD stores each before
*--    its own later read.
*--  - WIDX/CNTLO/CNTHI: `stz`'d at :run BEFORE the `lda
*--    NLINES / beq` early-out, so even `tail -0`, which skips
*--    the whole read loop, reaches the print logic with real
*--    zeros. This is the ring-buffer case where an
*--    un-wrapped ring would otherwise be relying on a zero
*--    start; it is not.
*--  - MODEBYTE: `stz` in START's opening run (line mode is the
*--    default; -c is the only thing that ever sets it).
*--  - CNBYTES: written at :cbound, only reached when MODEBYTE
*--    is set (HAVEOPT nonzero and -c was the option seen).
*--  - WBPOS: `stz` at :brun BEFORE the `lda CNBYTES / beq`
*--    early-out, same posture as WIDX above -- `tail -c 0`
*--    reaches :bprint with a real zero, not a stale one.
*--  - PRINTSTRT/PRINTCNT: written on BOTH arms of the
*--    has-the-ring-wrapped test.
*--  - PIDX/CURIDX: `stz`/`sta` at the head of the print loop.
*--  - RL_LEN: `stz` as RDLINE's first instruction.
*--  - BUFPOS/BUFLEN: `stz`'d at :run, making GETBYTE's
*--    `pos >= len` refill test a decision rather than an
*--    accident. tail takes at most one file, so once is
*--    enough.
*--  - PATHBUF: MKPATH writes chars then the count byte.
*--  - CBUF: filled by SC_READ, indexed only below BUFLEN.
SRCFD       ds    1
ARGIDX      ds    1
NARGS       ds    1
HAVEOPT     ds    1
HAVEFILE    ds    1
NLINES      ds    1                 ;requested/effective N
NEWNLO      ds    1                 ;-N accum., see MUL10ADD
NEWNHI      ds    1
MD_DIGIT    ds    1
MD_TWOLO    ds    1
MD_TWOHI    ds    1
WIDX        ds    1                 ;ring write index, 0..N-1
CNTLO       ds    1                 ;lines/bytes, saturating
CNTHI       ds    1
PRINTSTRT   ds    1                 ;ring index of oldest kept
PRINTCNT    ds    1                 ;lines/bytes to print
PIDX        ds    1
CURIDX      ds    1
RL_LEN      ds    1
BUFPOS      ds    1
BUFLEN      ds    1
MODEBYTE    ds    1                 ;-c given: byte, not lines
FFLAG       ds    1                 ;-f given
OFFLO       ds    1                 ;file bytes consumed so far
OFFMID      ds    1                 ;(24-bit: ProDOS mark width)
OFFHI       ds    1
TF_CNT      ds    1                 ;bytes in this follow chunk
TF_IDX      ds    1
TF_TICKBUF  ds    5                 ;SYS_TICK reply
TF_TARGET   ds    4
SMCNT       ds    1                 ;SET_MARK parmlist, built at
SMREF       ds    1                 ;use (writable text is not
SMPOS       ds    3                 ;allowed -- docs/STICKY.md)
CNBYTES     ds    1                 ;-c N, 8-bit (MAXBYTES=255)
WBPOS       ds    1                 ;byte-ring write index

PATHBUF     ds    65
CBUF        ds    BUFSZ

RING        ds    RINGSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
            err   */$BF00
            dend
