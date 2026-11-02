*---------------------------------------------------------------
* plasma.s -- PLASMA bytecode VM ported to maux (VM seed). The
* interpreter core is plasmavm.s/plasmals.s/plasmaop.s; the
* loader is plasmald.s. Ported from ~/src/PLASMA/src/
* vmsrc/apple/plvm02.s (interpreter, lines 127-1492) and
* cmdstub.s (env init, lines 36-44) -- see the task report for
* the full source and every judgment call. liba-free by design:
* liba's own PTR0 lives at $E0, inside the VM's own zero page
* (VMZP starts at $E0 too), so this program hand-rolls its
* handful of syscalls instead.
*
* MILESTONE 2 (docs/PLASMA-PORT.md): the seed loads the FIXED
* runtime path /mnt/MAUX/PLASMA/RT into $2000, not argv[1] --
* rt's
* own init reads argc()/argv() itself and execmods the real
* target. `plasma MODULE` still means what it always meant; the
* module name now resolves one layer up, inside rt.
*
* MEMORY MODEL (exact, do not deviate):
*   $0000-$00F8  VM zero page (plvmzp.inc verbatim) + LDPTR
*   $0100-$01FF  hardware stack -- left as the kernel set it
*   $0200-$07FF  kernel argv block -- read-only, never written
*   $0800        this file's fixed entry jump table
*   $0900        OPTBL, page-aligned (the `ds` pad below)
*   $0900+       interpreter + loader + this program's bss arena
*   ...          FRAME STACK region up to $2000 (>= 1 KB, err'd)
*   $2000        module load addr = maux RELADDR = heap base
*   LC $D000     never touched -- no $C08x anywhere in this seed
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/plasma.bin
            typ   $00

*---------------------------------------------------------------
* PLASMA VM zero page -- plvmzp.inc VERBATIM (same addresses:
* this is the ABI a compiled module's inline asm assumes), plus
* plvm02.s's own inner-loop equates (its lines 32-42). ESTKL's
* original formula (ESTK+ESTKSZ/2) needed splitting across two
* equ lines -- this dialect allows only one operator per
* expression (no `a+b/c`).
*---------------------------------------------------------------
SRC         equ   $06
SRCL        equ   SRC
SRCH        equ   SRC+1
DST         equ   SRC+2
DSTL        equ   DST
DSTH        equ   DST+1
ESGUARD     equ   $9E
ESTKSZ      equ   $40
ESTKHALF    equ   ESTKSZ/2
ESTK        equ   $A0
ESTKH       equ   ESTK
ESTKL       equ   ESTK+ESTKHALF
VMZP        equ   ESTK+ESTKSZ
IFP         equ   VMZP
IFPL        equ   IFP
IFPH        equ   IFP+1
PP          equ   IFP+2
PPL         equ   PP
PPH         equ   PP+1
IPY         equ   PP+2
ESP         equ   IPY+1
JMPTMP      equ   ESP+1
TMP         equ   JMPTMP+1
TMPL        equ   TMP
TMPH        equ   TMP+1
DVSIGN      equ   TMP+3
DROP        equ   $EF
NEXTOP      equ   $F0
FETCHOP     equ   NEXTOP+1
IP          equ   FETCHOP+1
IPL         equ   IP
IPH         equ   IPL+1
OPIDX       equ   FETCHOP+6
OPPAGE      equ   OPIDX+1
LDPTR       equ   $F9              ;loader-only scratch ptr --
                                   ;free zp after the copied
                                   ;template ($EF-$F8)

*---------------------------------------------------------------
* fixed entry jump table, at LOAD_BASE ($0800): the addresses
* plasmald.s's def-thunk and any future native caller depend on.
* Padded to $0900 so OPTBL lands page-aligned. PLVM_DINTRP/
* PLVM_IINTRP name the table SLOTS, not the routines behind them
* -- the thunk plasmald.s builds targets $0806 through this
* equate, not the IINTRP label directly, so the table is the
* real ABI a caller goes through (and stays load-bearing: a
* sabotaged $0806 now breaks the thunk too).
*---------------------------------------------------------------
PLVM_DINTRP equ   $0803
PLVM_IINTRP equ   $0806
            jmp   START
            jmp   DINTRP
            jmp   IINTRP
*---------------------------------------------------------------
* Cooked-image header (docs/PLASCUT.md), at $0809, right after
* the jump table so plascut.py finds it by OFFSET, not symbol.
* plascut patches CKFLAG/CKEND in the FILE it writes; the
* running seed never writes them (text-immutable). CKFLAG=0 is
* the ordinary `plasma MODULE` seed; nonzero means the image
* already holds rt + the modules, relocated and bound, and START
* must not load anything: brk(SET, CKEND), VM env, JMP $2000
* (plasmald.s cooked branch).
*---------------------------------------------------------------
CKMAGIC     asc   'CK'
CKFLAG      dfb   0
CKEND       da    0
            ds    $0900-*

            put   plasmavm.s
            put   plasmals.s
            put   plasmaop.s
            put   plasmald.s

*---------------------------------------------------------------
* plasma's bss -- dum/dend at the textual end (the image end),
* same discipline as every other maux util (docs/STICKY.md sec
* 21): nothing zeroes this arena, every cell is write-before-
* read. TEXT-IMMUTABLE (the brief's own requirement -- a warm
* bank reuse never recopies the image): the six MLI/maux
* parmlists live HERE, not as dfb/da text, so every `sta` that
* patches a field (ref/buf/req, the exit status, ...) writes
* bss, never code. cat.s's INITPARMS is the precedent -- see
* plasmald.s's own INITPARMS, START's first act, for the
* constant fields (pcounts, WPARM_REF, BRKPARM_MODE) this arena
* does NOT arrive pre-set with. OPARM_PATH points at
* plasmald.s's RTPATH -- a fixed TEXT constant (milestone 2: the
* seed loads the runtime, not argv[1] -- docs/PLASMA-PORT.md),
* never written, so no bss cell for it any more.
*  - HDRBUF: written by the 2-byte header READ; never read back
*    (its only job is to consume the modsize word).
*  - BUFPTR: seeded from TENANT before the read loop, advanced
*    by RPARM_TRANS each iteration before anything reads it.
*  - THUNK: all 5 bytes stored by START before the one `jsr
*    THUNK` that executes them.
*  - OPARM/RPARM/WPARM/CPARM/BRKPARM: constant fields stored
*    once by INITPARMS; the remaining fields (result fields,
*    and RPARM_BUF/RPARM_REQ/WPARM_BUF/WPARM_REQ, which change
*    call to call) are patched by START before each use.
*  - EXITPARM: status byte stored by DOEXIT just before the one
*    SYS_EXIT call that reads it; the other 7 bytes are never
*    read (syscalls.s SC_EXIT's own PROCPARM shape -- only byte
*    0 matters to the kernel).
* Between this arena's end and $2000 (module load address) sits
* the interpreter's FRAME STACK region -- unused space a PLASMA
* function's ENTER/LEAVE grows into, required >= 1 KB (asserted
* below).
*---------------------------------------------------------------
            dum   *
HDRBUF      ds    2
BUFPTR      ds    2
THUNK       ds    5

OPARM       ds    1
OPARM_PATH  ds    2
OPARM_IOBUF ds    2
OPARM_REF   ds    1

RPARM       ds    1
RPARM_REF   ds    1
RPARM_BUF   ds    2
RPARM_REQ   ds    2
RPARM_TRANS ds    2

WPARM       ds    1
WPARM_REF   ds    1
WPARM_BUF   ds    2
WPARM_REQ   ds    2
WPARM_TRANS ds    2

CPARM       ds    1
CPARM_REF   ds    1

BRKPARM     ds    2              ;value lo/hi
BRKPARM_MODE ds   1              ;mode: 0=set, nonzero=grow

EXITPARM    ds    8              ;status byte at [0]

* -- OPTBL must land exactly at $0900 --
            err   OPTBL-$0900
* -- image+bss end must leave >= 1 KB of frame stack under the
* -- $2000 module load address --
            err   */$1C00
            dend
