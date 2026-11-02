*---------------------------------------------------------------
* ps.s -- report process status.
*
* Usage: ps
*
* Prints one line per live process:
*
*  PID S BANK PPID COMMAND
*    1 S   01    0 [init]
*    2 R   02    0 [idle]
*    3 S   03    1 sh
*    4 R   04    3 sleep 30
*    5 R   05    3 (clob)
*    6 R   06    3 ps
*
* COMMAND is the process's argument vector, joined with single
* spaces and truncated to the console's width (one column is
* left free; a stdout that is not a console gets the full 63
* characters). A zombie shows <defunct> (V7's word). When the
* process has reused the low memory spawn staged its argv in
* (PRC_LOWFREE, docs/SYSCALL.md ruling 13 -- the program may
* legally overwrite it after startup) the argv fails
* validation and ps falls back to the program's name in
* parentheses, BSD-style, from the kernel's lazy-free tag for
* the bank; failing that, `?`. A process the KERNEL made
* (PPID 0: pid 1, then idle) was never spawned, so its $0200
* was never staged: it shows [init] / [idle], unread. The three
* markers: [ ] kernel-made, ( ) argv gone, <defunct>.
* See docs/PS-ARGS.md.
*
* WHO DOES WHAT. Only the kernel can read another bank, so
* SYS_PSTAT's slot byte carries a MODE in bits 6-7 (inc/
* sc.status.equ): mode 0 the head record, mode 1 the raw
* PSTAT_BLK bytes at the target's $0200, mode 2 its spawn
* pathname tag. Everything that gives those bytes a meaning --
* validate argc and every pointer, require printable text, join,
* truncate, fall back -- is HERE, because the kernel image has
* no bytes to spare and ps has plenty. A caller that never
* sets a
* mode bit (sh's job control) is byte-for-byte the old call.
*
* BANK is the physical aux bank the process occupies, and it is
* the column that makes this maux rather than a generic ps: a
* process here IS a bank. The whole address space, its own zero
* page, its own stack. That number is not an allocation detail,
* it is the identity of the process at the hardware level.
*
* STATE letters, chosen to read like V7's:
*   R  runnable or running
*   S  blocked (sleeping on a wait channel)
*   Z  zombie -- exited, not yet reaped by wait()
*   T  stopped by ^Z (docs/JOB-CONTROL.md), resumable
*
* Running and runnable share a letter deliberately. Exactly one
* process is RUNNING at any instant and by construction it is
* this one, so a separate letter would only ever mark `ps`
* itself, which is noise.
*
* The kernel exposes one slot per SYS_PSTAT call and never hands
* out a pointer into the process table. Unused slots come back
* with STATE = PCB_UNUSED and are skipped here rather than
* compacted in the kernel, which keeps slot index == pid.
*
* WHY A SYSCALL, WHEN UNIX DID NOT HAVE ONE. V6/V7 ps had no
* kernel call: it opened /dev/kmem, found _proc via nlist() on
* the kernel binary's symbol table, and read the proc array
* straight out of kernel memory (plus /dev/swap for the args of
* swapped-out processes). The kernel exposed ITSELF as a file
* and ps was a program that happened to know the struct layout
* -- which is why V6 ps had to be rebuilt whenever that layout
* changed, and read garbage when it was not.
*
* maux cannot do that at all. A process sees one bank; the PCB
* array is in the annex, outside every process's address space,
* so ANY read of it crosses a bank boundary and therefore needs
* the kernel. SYS_PSTAT is our /dev/kmem, narrowed to a fixed
* six-byte record instead of a struct layout userland has to
* agree with. That puts this closer to /proc or sysctl than to
* V6 -- a stable ABI rather than a shared-layout handshake.
* Forced by the memory model, but the better end of the trade.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.procbnk2.equ
            put   ../../inc/mm.annex.equ
            put   ../../inc/mm.annex2.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.status.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/ps.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*-- offsets within the record SYS_PSTAT returns
PS_PID      equ   0
PS_STATE    equ   1
PS_WCHAN    equ   2
PS_BANK     equ   3
PS_PARENT   equ   4
CMDMAX      equ   63                ;most COMMAND ever shows:
                                    ;the 64 string bytes the
                                    ;kernel's block read covers

START       jsr   GETWIDTH
            lda   #<HEADER
            sta   PTR0
            lda   #>HEADER
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS

            lda   #1               ;slot 0 is never a process
            sta   SLOT
            lda   #<REC
            sta   PTR0
            lda   #>REC
            sta   PTR0+1
:loop       lda   #<REC           ;PTR0 is clobbered by the call
            sta   PTR0
            lda   #>REC
            sta   PTR0+1
            lda   SLOT
            jsr   SC_PSTAT
            bcs   :next            ;bad slot -- skip, keep going
            lda   REC+PS_STATE
            beq   :next            ;PCB_UNUSED
            jsr   REPORT
:next       inc   SLOT
            lda   SLOT
            cmp   #PCB_COUNT
            bcc   :loop
            lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* REPORT -- one process line.
*---------------------------------------------------------------
REPORT      lda   REC+PS_PID
            ldx   #4
            jsr   PRCOL             ;PID, right-aligned in 4
            jsr   PUTSP

            ldx   REC+PS_STATE      ;state letter
            cpx   #6                ;STATETAB's length
            bcc   :known
            ldx   #0
:known      lda   STATETAB,x
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PUTSP

            jsr   PUTSP             ;BANK is right-aligned in
            jsr   PUTSP             ;4 columns its header owns
            lda   REC+PS_BANK
            jsr   PRHEX2            ;bank, as hex -- it is a
                                    ;hardware bank number, not a
                                    ;count
            jsr   PUTSP

            lda   REC+PS_PARENT
            ldx   #4
            jsr   PRCOL
            jsr   PUTSP
            lda   REC+PS_STATE
            cmp   #PCB_ZOMBIE
            bne   :live
            lda   #<DEFUNCT
            sta   PTR0
            lda   #>DEFUNCT
            sta   PTR0+1
            bra   :put
:live       lda   REC+PS_PARENT
            bne   :user
            lda   #<IDLESTR         ;PPID 0: made by the kernel
            ldx   #>IDLESTR
            ldy   REC+PS_PID
            cpy   #1
            bne   :setp
            lda   #<INITSTR
            ldx   #>INITSTR
:setp       sta   PTR0
            stx   PTR0+1
            bra   :put
:user       jsr   GETCMD            ;CMD, NUL-terminated
            lda   #<CMD
            sta   PTR0
            lda   #>CMD
            sta   PTR0+1
:put        ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

PUTSP       lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* GETWIDTH -- CMDW = how many COMMAND characters fit: the
* console's columns less the 17-column prefix less one column
* (so a full line never wraps), clamped to 8..CMDMAX. Not a
* console (SC_TTYGEO refuses): CMDMAX.
*---------------------------------------------------------------
GETWIDTH    lda   #CMDMAX
            sta   CMDW
            lda   #<GEO
            sta   PTR0
            lda   #>GEO
            sta   PTR0+1
            lda   #FD_STDOUT
            jsr   SC_TTYGEO
            bcs   :done
            lda   GEO               ;columns
            sec
            sbc   #18
            bcc   :min
            cmp   #8
            bcc   :min
            cmp   #CMDMAX+1
            bcs   :done
            sta   CMDW
:done       rts
:min        lda   #8
            sta   CMDW
            rts

*---------------------------------------------------------------
* GETCMD -- CMD = the text for COMMAND for the process in SLOT.
*---------------------------------------------------------------
GETCMD      lda   #<BLK
            sta   PTR0
            lda   #>BLK
            sta   PTR0+1
            lda   SLOT
            ora   #PSTAT_M_BLK
            jsr   SC_PSTAT
            bcs   :name
            jsr   JOIN
            bcc   :ret
:name       lda   #<PTH
            sta   PTR0
            lda   #>PTH
            sta   PTR0+1
            lda   SLOT
            ora   #PSTAT_M_PTH
            jsr   SC_PSTAT
            bcs   :q                ;untagged
            jmp   BASENAME
:q          lda   #$BF              ;'?'
            sta   CMD
            stz   CMD+1
:ret        rts

*---------------------------------------------------------------
* JOIN -- validate BLK (the target's raw $0200..$033F) as a
* spawn-staged argv block and join it into CMD. Carry SET = not
* a valid block. Valid means: 1 <= argc <= 127; argv[i] is
* exactly where spawn's packer puts it (argv[0] = $0300, each
* next one right after the previous one's NUL -- PSTG_LIST); and
* every byte up to the cut is a NUL or printable text (either
* polarity: maux's high-bit now, the low ASCII it is moving
* to). Text is cut when CMD is full (CMDW) or the copied
* strings run out (64 bytes); that is NOT an error.
*---------------------------------------------------------------
JOIN        lda   BLK
            beq   :bad
            bmi   :bad              ;above 127
            bra   :go
:bad        sec
            rts
:go         stz   POS
            stz   OUT
            stz   ARGI
:arg        lda   ARGI
            asl   a
            tax
            lda   BLK+1,x           ;argv[i] lo
            cmp   POS
            bne   :bad
            lda   BLK+2,x           ;argv[i] hi
            cmp   #>PRC_ARGV_STR
            bne   :bad
:chr        ldx   POS
            cpx   #64
            bcs   :done
            lda   BLK+$100,x
            beq   :nul
            tay
            and   #$7F              ;either polarity
            cmp   #$20
            bcc   :bad
            cmp   #$7F
            bcs   :bad
            tya
            ldy   OUT
            cpy   CMDW
            bcs   :done
            sta   CMD,y
            inc   OUT
            inc   POS
            bra   :chr
:nul        inc   POS
            inc   ARGI
            lda   ARGI
            cmp   BLK
            bcs   :done             ;that was the last one
            ldy   OUT
            cpy   CMDW
            bcs   :done
            lda   #$A0
            sta   CMD,y
            inc   OUT
            bra   :arg
:done       ldy   OUT
:trim       beq   :empty            ;nothing left: not an argv
            lda   CMD-1,y
            and   #$7F
            cmp   #$20
            bne   :end
            dey                     ;never end on a bare space
            bra   :trim
:end        lda   #0
            sta   CMD,y
            clc
            rts
:empty      sec
            rts

*---------------------------------------------------------------
* BASENAME -- CMD = "(" last path component ")" from PTH (a
* length byte and up to 64 characters), cut to fit CMDW. No
* printable test: the tag is a canonical pathname the MLI
* already accepted, which cannot hold a control byte.
*---------------------------------------------------------------
BASENAME    lda   CMDW
            dec   a
            sta   LIM
            lda   PTH               ;kernel writes <= 64; PTH
            cmp   #PSTAT_PTH        ;is 65 B: clamp anyway
            bcc   :lenok
            lda   #PSTAT_PTH-1
            sta   PTH
:lenok      ldx   PTH
:scan       beq   :found
            lda   PTH,x
            and   #$7F              ;the tag may be either ASCII
            cmp   #$2F              ;'/'
            beq   :found
            dex
            bra   :scan
:found      lda   #$A8              ;'('
            sta   CMD
            ldy   #1
:cp         cpy   LIM
            bcs   :close
            inx
            cpx   PTH
            beq   :take
            bcs   :close
:take       lda   PTH,x
            sta   CMD,y
            iny
            bra   :cp
:close      lda   #$A9              ;')'
            sta   CMD,y
            iny
            lda   #0
            sta   CMD,y
            rts

*---------------------------------------------------------------
* PRCOL -- print A as decimal, right-aligned in X columns.
*---------------------------------------------------------------
PRCOL       stx   COLW
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            lda   #<NUMBUF
            sta   PTR1
            lda   #>NUMBUF
            sta   PTR1+1
            jsr   U2DEC             ;A = digit count
            sta   NDIGITS
            lda   COLW
            sec
            sbc   NDIGITS
            beq   :emit
            bcc   :emit             ;wider than the column: let
                                    ;it run rather than truncate
            tax
:pad        phx
            jsr   PUTSP
            plx
            dex
            bne   :pad
:emit       lda   #<NUMBUF
            sta   PTR0
            lda   #>NUMBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts

*---------------------------------------------------------------
* PRHEX2 -- print A as two hex digits.
*---------------------------------------------------------------
PRHEX2      pha
            lsr
            lsr
            lsr
            lsr
            jsr   :nyb
            pla
            and   #$0F
:nyb        cmp   #10
            bcc   :dig
            clc
            adc   #7                ;'A'-'0'-10
:dig        clc
            adc   #"0"
            ora   #$80
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

HEADER      asc   " PID S BANK PPID COMMAND"
            dfb   $8D,$00
DEFUNCT     asc   "<defunct>"
            dfb   $00
INITSTR     asc   "[init]"
            dfb   $00
IDLESTR     asc   "[idle]"
            dfb   $00
STATETAB    dfb   $AD              ;0 unused  '-'
            dfb   $D2              ;1 runnable 'R'
            dfb   $D2              ;2 running  'R'
            dfb   $D3              ;3 blocked  'S'
            dfb   $DA              ;4 zombie   'Z'
            dfb   $D4              ;5 stopped  'T' (^Z, docs/
                                   ;JOB-CONTROL.md Increment B;
                                   ;V7's own letter)

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s    ;SC_PSTAT -- ps IS this
            put   ../liba/libabss.s
                                        ;call

*---------------------------------------------------------------
* ps's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - SLOT: `lda #1 / sta SLOT` before the scan loop reads it.
*  - COLW: `stx COLW` as PRCOL's first instruction.
*  - NDIGITS: `sta` from U2DEC's returned digit count, before
*    the padding subtraction reads it.
*  - NUMBUF: U2DEC always emits at least the units digit and
*    always writes the NUL, before PUTS scans for it.
*  - REC: filled COMPLETELY by SC_PSTAT -- PRC_PSTAT
*    (src/kernel/procfile4.s) BankCopies all PSTAT_LEN bytes of
*    K_PCB_SCRATCH in one block. And ps checks the carry
*    (`bcs :next`), so on a bad slot REC is skipped, not read.
*
*  - CMDW: GETWIDTH stores it first thing in START.
*  - POS/OUT/ARGI: JOIN `stz`es all three on entry.
*  - LIM: BASENAME stores it before its first read.
*  - GEO: SC_TTYGEO fills it; GETWIDTH reads it only on carry
*    clear.
*  - CMD: JOIN and BASENAME NUL-terminate what they build, and
*    the `?` path stores both bytes; PUTS reads up to that NUL.
*  - PTH/BLK: filled by SC_PSTAT modes 2/1; only read when the
*    call returned carry clear.
*
* No parmlist here: SC_PSTAT goes through liba's shared
* PROCPARM, which already lives in libabss.s's arena.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
SLOT        ds    1
COLW        ds    1
NDIGITS     ds    1
NUMBUF      ds    8
REC         ds    PSTAT_LEN
CMDW        ds    1                 ;COMMAND characters that fit
POS         ds    1                 ;JOIN: byte of the strings
OUT         ds    1                 ;JOIN: characters in CMD
ARGI        ds    1                 ;JOIN: which argument
LIM         ds    1                 ;BASENAME: CMDW-1
GEO         ds    4                 ;SC_TTYGEO's answer
CMD         ds    CMDMAX+1          ;the COMMAND text
PTH         ds    PSTAT_PTH         ;mode 2: spawn pathname tag
BLK         ds    PSTAT_BLK         ;mode 1: raw argv block
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
