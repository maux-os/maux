*---------------------------------------------------------------
* nm.s -- symbol-table inspector for maux REL object files.
*
* Usage: nm [-u] [-g] file...
*
* For each REL file, print its symbols one per line, sorted by
* name: "ADDR TYPE NAME". -u undefined only, -g global only.
* Both together -> always empty (the format's two categories
* are mutually exclusive, so the intersection is empty; this
* is a mechanical consequence, not a special case). >1 file ->
* "path:" header per block, one blank line between blocks.
* Unreadable file -> "nm: cannot open <path>" to fd 2, skip it,
* continue with the rest, exit 1 at the end (0 if every file
* opened). No file args, or a bad flag -> usage to fd 2, exit 2.
*
* REL FORMAT. docs/REL-LIBA-SPIKE.md is the format spec, but it
* stops at ENT/EXT SEMANTICS, not the dictionary's on-disk BYTE
* layout. ld.s (per its own header/docs/LD-DESIGN.md) embeds
* real Merlin's LINKER.S wholesale and bridges its MLI calls --
* it never itself decodes an ENT/EXT dictionary byte, so ld.s
* carries NO format knowledge to reuse or duplicate here; this
* would otherwise be a first (not second) hand-derived reading,
* which the task called out as suspect -- so it was checked
* against real bytes instead of derived from source reading.
* The byte layout below was reverse-engineered from FIVE real
* Merlin-8 2.59 built REL files: RTLIB/RTMAIN (from `make
* check-rel`'s own RTLIB.S/RTMAIN.S, src/relspike/) plus three
* throwaway probes (a double reference to one external, two
* distinct externals, and a hi-byte `#>` reference) assembled
* the same way and read back off the disk image byte for byte.
*
* On disk: [code, aux_type bytes][dictionary]. The dictionary
* is two lists back to back:
*
*  1. FIXUP LIST -- one entry per EXTERNAL REFERENCE SITE.
*     Irrelevant to nm's output (skipped, never printed) --
*     these locate where the LINKER patches code, not names.
*     Each entry is 4 bytes: [kind][code_off lo][hi][refnum].
*     kind is nonzero for a real entry ($9F seen for a full
*     2-byte fixup, $50 for a hi-byte-only `#>` one -- nm does
*     not need to know what kind MEANS, only that it is
*     nonzero). A lone $00 ends the list.
*  2. SYMBOL LIST -- one entry per NAME (an ENT export or an
*     EXT reference), each: [flag|len][name, LEN raw 7-bit
*     ASCII bytes, NOT liba high-bit][addr lo][addr hi]. flag
*     is $40 (ENT) or $80 (EXT) or'd with LEN (low 6 bits,
*     0-63). addr is always $8000 + something: an ENT's
*     MODULE-RELATIVE OFFSET for a defined symbol, or the
*     EXTERNAL's REFNUM (0-$FE) as a placeholder for an
*     undefined one. A lone $00 ends the list.
*
* TYPE MAPPING -- the honest one, per the task's own ruling not
* to invent distinctions the format cannot express. Merlin-8
* REL has exactly TWO symbol categories, ENT and EXT, nothing
* between them: ENT -> X (this module's only "defined and
* visible outside it" category -- ENT literally IS the export
* mechanism, so it is the task's "external/global definition").
* EXT -> U (undefined here, defined elsewhere). T is NEVER
* emitted: Merlin-8 has no notion of a plain internal label
* that still reaches the object's symbol table at all -- an
* ordinary (non-ENT) label is pure assembly-time state and
* leaves no dictionary byte, so there is no "local text symbol"
* category left for T to honestly describe.
*
* ADDR is the MODULE-RELATIVE offset (stored value - $8000),
* not the raw stored value: a REL file is unlinked, so $8000
* is a fictional assembly-time base (docs/REL-LIBA-SPIKE.md),
* not a real load address -- printing it unadjusted would
* misrepresent an unlinked object as though it already had one.
* Every stored addr has hi byte >= $80 (proven across all five
* specimens), so the subtraction is just "hi AND $7F"; the lo
* byte is untouched (unaffected by subtracting $8000). EXT
* symbols print 4 spaces regardless of their refnum placeholder
* -- that stored value is not an address at all, and printing
* it would be actively wrong, not merely imprecise.
*
* ARENA. REL_BUF/SYMDESC below are a `dum`/`dend` block (task
* ruling: `ds` would emit them as real zero bytes into the
* binary). Read-before-write trace, both reused per file with
* no reset between files:
*   REL_BUF -- every byte is written by READFILE's SC_READ
*   loop, at increasing offsets, before FILELEN is extended
*   past it. PARSEDICT only ever walks NM_DPTR up to NM_DEND
*   (REL_BUF+FILELEN) in both phases, so it never reads past
*   what THIS file's read loop actually wrote -- stale bytes
*   left over from a larger PRIOR file, past the current
*   FILELEN, are never touched by any pointer.
*   SYMDESC -- every slot 0..NSYMS-1 is written by PARSESYM
*   (SDSET) before NSYMS is incremented past it; SORTSYMS and
*   PRINTALL both bound their own walk by the CURRENT NSYMS,
*   so a stale slot from a larger prior file (beyond the new,
*   possibly smaller, NSYMS) is never read either.
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
            dsk   ../../build/nm.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

REL_BUF_SIZE equ  4096         ;generous vs. real REL modules --
                               ;see docs/REL-LIBA-SPIKE.md's own
                               ;measured sizes (largest liba
                               ;candidate ~750B)
MAXSYMS     equ   200          ;symbols per file -- ample for a
                               ;small REL module (task ruling:
                               ;one routine/cluster per module)
BUFSZ       equ   255          ;read-chunk cap, house BUFSZ
                               ;convention (wc.s/od.s/sort.s)

TYPE_ENT    equ   $40
TYPE_EXT    equ   $80
LEN_MASK    equ   $3F

* -- nm's own ZP window, $30 up (ed.s/sort.s precedent) --
NM_DPTR     equ   $30   ;2  dictionary walk cursor
NM_DEND     equ   $32   ;2  dictionary end address
NM_I        equ   $34   ;2  SORTSYMS outer index
NM_J        equ   $36   ;2  SORTSYMS inner index
NM_JM       equ   $38   ;2  SORTSYMS J-GAP scratch
NM_GAP      equ   $3A   ;2  SORTSYMS shell-sort gap
NM_TVAL     equ   $3C   ;2  element being inserted (descriptor)
NM_APTR     equ   $3E   ;2  SDADDR out: &SYMDESC[NM_SIDX]
NM_AVAL     equ   $40   ;2  SDGET out / SDSET in
NM_DA       equ   $42   ;2  CMPNAME operand A (descriptor ptr)
NM_DB       equ   $44   ;2  CMPNAME operand B (descriptor ptr)
NM_ROOM     equ   $46   ;2  READFILE: buffer room remaining
NM_SIDX     equ   $48   ;2  SDADDR/SDGET/SDSET: symbol index

            put   nmtop.s
            put   nmscan.s
            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/hex.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* SYMDESC (pointer array) then REL_BUF (file bytes) -- `dum`/
* `dend`, anchored at the TEXTUAL END of the file (task ruling:
* a `dum` opened mid-file hands out addresses the code AFTER
* `dend` then occupies). See file header for the read-before-
* write trace covering both arrays.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
*-- nm's scalars, 88 bytes that were still emitted `ds` zeros
*-- outside this arena. Trace (sec 21):
*--  - WANT_U/WANT_G/ERRFLAG/BLKFLAG: `stz`'d as START's
*--    opening run. BLKFLAG is deliberately entry-only, not
*--    per-file: it means "has a block header been printed
*--    yet", which must persist across the argv loop.
*--  - NFILES: `sta` at :havefls; the zero-operand case jumps
*--    to USAGE and exits before any read.
*--  - ARGIDX: `sta` before its own next read.
*--  - SRCFD: `sta` only after SC_OPEN succeeded; both failure
*--    exits return through CANTOPEN without reading it.
*--  - CODE_LEN: `sta` from GFIPARM_AUX immediately after a
*--    SUCCESSFUL SC_GFI; PARSEDICT, its only reader, is
*--    reachable only downstream of that `bcs CANTOPEN`.
*--  - FILELEN/NSYMS: `stz`'d as the first instructions of
*--    READFILE and PARSEDICT respectively -- per file.
*--  - NAMEPTR: `sta` from GETARG's result before ANY failure
*--    branch, so even the error printers see it written.
*--  - REQLO: `sta` on both arms of the room test.
*--  - PROBEBYTE: written by the kernel's copyout and in fact
*--    never read -- PROBE1 tests the transfer count, not the
*--    byte.
*--  - RECFLAG/RECLEN: written by PARSEDICT and PRINTSYM
*--    before their own readers.
*--  - RECIDX: `stz` at PRINTSYM's head.
*--  - CMP_LENA/CMP_LENB/CMP_MIN: CMPNAME stores all three in
*--    its opening block; CMP_MIN is written on BOTH arms of
*--    the shorter-of test, which converge on :havemin.
*--  - PATHBUF: MKPATH writes chars then the count byte,
*--    before SC_GFI and SC_OPEN; the MLI reads only count+1.
WANT_U      ds    1
WANT_G      ds    1
ERRFLAG     ds    1
BLKFLAG     ds    1
NFILES      ds    1
ARGIDX      ds    1
SRCFD       ds    1
CODE_LEN    ds    2
FILELEN     ds    2
NSYMS       ds    2
NAMEPTR     ds    2
REQLO       ds    1
PROBEBYTE   ds    1
RECFLAG     ds    1
RECLEN      ds    1
RECIDX      ds    1
CMP_LENA    ds    1
CMP_LENB    ds    1
CMP_MIN     ds    1

PATHBUF     ds    65

SYMDESC     ds    MAXSYMS*2
REL_BUF     ds    REL_BUF_SIZE
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
            err   */$BF00
            dend
