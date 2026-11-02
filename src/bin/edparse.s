*---------------------------------------------------------------
* edparse.s -- ed's command input, address parsing and the
* forward/backward searches, `put` by src/bin/ed.s (NOT a
* standalone binary -- the same put-module shape as
* sedexec.s/expr.eval.s, and split from ed.s for the same
* reason units split anywhere: real Merlin-8's 41,215-byte
* source buffer holds the resident manifest plus one put file
* at a time, and ed.s alone was 31KB past it). Every symbol
* here resolves against ed.s's own equates, data and arena;
* see that file's header for the scope and the divergences.
*---------------------------------------------------------------
*---------------------------------------------------------------
* Entry: spawn() JMPs here after loading the image, per
* startup.equ's contract (same as every other util -- see
* echo.s's header, unchanged).
*
* SPLIT (docs/VI-DESIGN.md sec 5 item 1, 2026-09-02): the file-
* load half is now ED_STARTFILE, ending in `rts` instead of
* falling through into MAINLOOP's fd-0 loop. `ed`/`ex`'s own CLI
* wrapper is this tiny START, unchanged in OBSERVABLE behavior
* (same file-load then MAINLOOP sequence, just through one more
* jsr/jmp). vi.s's own entry calls ED_STARTFILE directly and
* falls into its OWN command loop instead of MAINLOOP -- see
* vicmd.s. ED_D1FLAG is zeroed here (not in ED_STARTFILE) so
* `ed`/`ex` -- which always fall through this START -- start
* every session with it known-clear; vi.s bypasses START
* entirely (jmps straight to its own entry) and never relies on
* this zero-init (see edparse.s's MAINLOOP comment for why: vi
* always WRITES ED_D1FLAG itself before ED_DISPATCH1 ever reads
* it).
*---------------------------------------------------------------
START       stz   ED_D1FLAG
            jsr   ED_STARTFILE
            jmp   MAINLOOP

ED_STARTFILE
            stz   ED_CURLINE
            stz   ED_CURLINE+1
            stz   ED_NLINES
            stz   ED_NLINES+1

            ;-- Establish the break at the top of this image's
            ;-- own storage. The heap starts EMPTY and ED_ROOM
            ;-- grows it 4K at a time as text arrives -- the
            ;-- opposite of sort.s, which takes the whole bank
            ;-- at once. A break that tracks live use is what
            ;-- lets a future fork() copy [LOAD_BASE, brk) and
            ;-- stop, so an editor holding three lines is cheap
            ;-- to duplicate and one holding 36K is not.
            lda   #<ED_HEAP
            sta   PTR0
            lda   #>ED_HEAP
            sta   PTR0+1
            jsr   SC_BRK
            bcs   :noheap
            stz   PTR0            ;sbrk(0) -- pure query, the
            stz   PTR0+1          ;  page-aligned heap base
            jsr   SC_SBRK
            bcc   :heapok
:noheap     lda   #<ED_NOHEAPMSG
            sta   PTR0
            lda   #>ED_NOHEAPMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT
:heapok     lda   PTR0
            sta   ED_TEXTPTR
            sta   ED_TEND
            lda   PTR0+1
            sta   ED_TEXTPTR+1
            sta   ED_TEND+1

            stz   CMD_RDPOS
            stz   CMD_RDLEN
            stz   ED_CURFNAME        ;2026-08-19: no remembered
                                     ;filename yet (finding 3)
            stz   LASTPAT            ;2026-09-02: no "last
                                     ;regular expression" yet
                                     ;(ED_LASTRE, edsubst.s) --
                                     ;NUL first byte marks it
                                     ;empty
            stz   ED_GMODE            ;2026-09-02: widened g/v
            stz   ED_GMCOUNT          ;-- no g/v mid-flight yet
                                     ;(edsub2.s's own header)
            stz   ED_ERRSTAT          ;EX2 2026-09-06: no
                                     ;refused/failed command yet
                                     ;this session

            ;-- 2026-09-02: `ed FILE` / `ex FILE` -- a leading
            ;-- filename argument is loaded into the buffer at
            ;-- startup and becomes the REMEMBERED filename,
            ;-- exactly like real ed/ex: "an initial filename
            ;-- argument is read into the buffer" (Ex Reference
            ;-- Manual v1.1,
            ;-- learning:01M1FX8HT89CKR9CB8T8VKCW1S).
            ;-- No banner on success -- r/w are silent in real
            ;-- ed/ex, and this reuses their own load path
            ;-- (ED_READLOOP, excmd.s's `e` extraction),
            ;-- unchanged. ARGC<2 (incl. the NULL-argv ARGC==0
            ;-- convention, procspawn3.s): no filename arg --
            ;-- today's bare-launch behavior, unchanged.
            lda   ARGC
            cmp   #2
            bcs   :hasarg
            rts
:hasarg     lda   #1
            jsr   GETARG              ;PTR0 = argv[1]
            ;-- SH-DEFECTS 14: POSIX `ex -s` (and the obsolete
            ;-- `-`) is an OPTION, not a filename. It used to be
            ;-- opened as a file, failed, and left the buffer
            ;-- empty so a script's `p` had nothing to print.
            ;-- Error `?` is already script-silent
            ;-- (ED_ERR_QUIET).
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD                ;'-'
            bne   :argfile
            iny
            lda   (PTR0),y
            beq   :optskip            ;bare "-"
            cmp   #$F3                ;'s'
            bne   :argfile
            iny
            lda   (PTR0),y
            bne   :argfile
:optskip    lda   ARGC
            cmp   #3
            bcs   :argf2
            rts                       ;option only: empty buffer
:argf2      lda   #2
            jsr   GETARG              ;PTR0 = argv[2]
:argfile
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            stz   ROPARM_IOBUF
            stz   ROPARM_IOBUF+1
            lda   #<ROPARM
            ldx   #>ROPARM
            jsr   SC_OPEN
            bcc   :opok
            ;-- NOSUCHFILE etc: `?`, empty buffer, filename NOT
            ;-- remembered -- the SAME path `e NOSUCHFILE` takes
            ;-- (excmd.s's EX_CEDIT, its own open-fail branch).
            jsr   ED_ERR
            rts
:opok       jsr   ED_RMBR_FNAME
            lda   ROPARM_REF
            sta   ED_RFD
            stz   R_RDPOS
            stz   R_RDLEN
            stz   ED_RAFTER
            stz   ED_RAFTER+1
            jsr   ED_READLOOP
            lda   ED_RFD
            sta   RCPARM_REF
            lda   #<RCPARM
            ldx   #>RCPARM
            jsr   SC_CLOSE
            jsr   EX_ONWRITE          ;ex: EX_DIRTY=0, matches
                                      ;disk; ed: no-op stub
            rts

*---------------------------------------------------------------
* MAINLOOP -- normally reads one command line from fd 0
* (ED_RDCMDLINE) and dispatches it. Widened g/v (2026-09-02,
* edsub2.s's ED_CMD_G/ED_CMD_V) reuses this SAME address-parse-
* then-dispatch path for its own pass 2, re-entrantly, WITHOUT
* reading stdin and WITHOUT duplicating any command handler:
* every classic command handler still ends with `jmp MAINLOOP`
* (never `rts` -- excmd.s's own header states the same contract
* for EX_CMD), so pass 2 cannot JSR into the dispatch chain and
* get a return; instead it makes MAINLOOP's own TOP branch, on
* ED_GMODE, straight into the dispatch path with a synthesized
* "command line" (ED_GCMDPTR, the command-list text ED_CMD_G
* saved) instead of a fresh read. When ED_GNEXT_MARK (edsub2.s)
* finds no marks left, it clears ED_GMODE itself and this same
* branch falls through to the normal stdin read on the very next
* MAINLOOP iteration -- ED_CMD_G's `jmp MAINLOOP` is the only
* place that ever sets ED_GMODE, so nothing else can enter pass
* 2 and normal (non-g) commands never see any of this.
*
* Two more ED_GMODE checks appear further down, both because
* pass 2's iterations are NOT "the outer command" a second time:
*   - :bareaddr -- an EMPTY cmds item always implies `p` (ed's
*     own `global` convention), unlike the top-level bare
*     address rule below it, which requires an address to have
*     actually been given.
*   - :havecmd -- EX_MUTCHECK's one-snapshot-per-outer-command
*     undo hook is SKIPPED for pass 2's own sub-dispatches. It
*     already fired exactly once for the outer g/v letter itself
*     (the top-level :havecmd, before ED_CMD_G/V ever ran) --
*     firing it again per marked line would keep overwriting the
*     undo shadow with the state before only the LAST line's
*     edit, so `u` after a whole g/v would undo just that one
*     line instead of the whole g/v ("Undo is its own inverse"
*     against the ONE pre-g/v snapshot, not a moving target).
*
* ED_DISPATCH1 (docs/VI-DESIGN.md sec 5 item 2, 2026-09-02):
* vi's `:` bridge needs to run exactly ONE command line --
* caller-supplied, not read from fd 0 -- and get control back,
* which this dispatch chain cannot do as written (every handler
* ends `jmp MAINLOOP`, never `rts`, all the way down through
* EX_CMD and the classic a/i/c/... chain -- excmd.s's header).
* Rather than touch every one of those call sites, MAINLOOP's
* OWN top-of-loop -- :m_readstdin, the ONE place every command,
* however deep its own internal jmp chain, always funnels back
* through before the next line would be read -- checks
* ED_D1FLAG first. vi sets it (with ED_D1RET = its own
* continuation address) immediately before `jmp ED_DISPATCH1`;
* MAINLOOP clears it and `jmp (ED_D1RET)`s back instead of
* blocking on fd 0. ed/ex never set ED_D1FLAG (START zeroes it
* once at boot, per this file's own header note), so
* :m_readstdin's normal ED_RDCMDLINE path is completely
* unchanged for them -- this is the SAME no-op-in-ed-and-ex /
* real-in-vi hook discipline the other three vi hooks use, just
* keyed on a flag instead of a per-binary subroutine body
* (there is no third "vi-side" put file to hang a real
* definition on the way EX_ONWRITE/ED_QCLEANUP hang theirs off
* edbuf.s vs exbuf.s -- vi.s owns ED_D1RET's target instead).
*
* A g/v command's OWN internal pass-2 iterations (:m_gdispatch,
* above) never trip this: they re-enter MAINLOOP's top with
* ED_GMODE still nonzero, checked BEFORE :m_readstdin is ever
* reached, so ED_D1FLAG is only consulted once the WHOLE outer
* command (g/v included) is actually finished -- exactly the
* single redirect point vi's one-shot dispatch needs.
*---------------------------------------------------------------
MAINLOOP    lda   ED_GMODE
            beq   :m_readstdin
            jsr   ED_GNEXT_MARK       ;edsub2.s -- carry set +
                                      ;ED_CURLINE = next marked
                                      ;line (mark consumed);
                                      ;carry clear = none left,
                                      ;ED_GMODE/ED_GMCOUNT both
                                      ;already cleared by it
            bcs   :m_gdispatch
            jmp   MAINLOOP            ;GMODE=0 now, falls to
                                      ;:m_readstdin next pass
:m_readstdin
            lda   ED_D1FLAG          ;2026-09-02, vi's `:`
            beq   :m_normrd          ;bridge -- see this file's
                                     ;header note just above
            stz   ED_D1FLAG
            jmp   (ED_D1RET)
:m_normrd
            jsr   ED_RDCMDLINE
            bcc   :haveline          ;carry clear -- a real CR-
                                     ;terminated line, process
                                     ;it even if empty
            cmp   #0
            bne   :haveline          ;EOF, but a final line with
                                     ;no CR
            jmp   ED_DOEXIT0         ;EOF and nothing left --
                                     ;implicit quit
:m_gdispatch
            ;-- pass 2: re-parse cmds fresh from its OWN saved
            ;-- start every iteration (a sub-command may carry
            ;-- its own address prefix; ED_CMDPTR must not carry
            ;-- over wherever the PREVIOUS parse left it).
            lda   ED_GCMDPTR
            sta   ED_CMDPTR
            lda   ED_GCMDPTR+1
            sta   ED_CMDPTR+1
            bra   :parseit
:haveline
            lda   #<CMDBUF
            sta   ED_CMDPTR
            lda   #>CMDBUF
            sta   ED_CMDPTR+1
* -- ED_DISPATCH1 -- vi's `:` bridge entry (docs/VI-DESIGN.md
* -- sec 5 item 2, this file's MAINLOOP comment above). IN:
* -- ED_CMDPTR already pointing at a caller-supplied NUL-
* -- terminated command line (vi's own status-line read
* -- buffer, NOT CMDBUF/fd 0); ED_D1FLAG/ED_D1RET already
* -- armed by the caller. `jmp` here, never `jsr` -- nothing
* -- on this path ever `rts`s.
ED_DISPATCH1
:parseit
            jsr   ED_PARSEADDR
            bcc   :addrok
            jsr   ED_ERR
            jmp   MAINLOOP
:addrok
            ldy   #0
            lda   (ED_CMDPTR),y
            pha                  ;M2: EX_PREMOVE may clobber --
                                 ;restored below so :bareaddr's
                                 ;own test is unaffected (ed's
                                 ;stub is a no-op anyway)
            jsr   EX_PREMOVE     ;ex: snapshot '' (the previous-
                                 ;context mark) if an explicit
                                 ;address was given; ed: no-op
                                 ;stub (edbuf.s)
            pla
            bne   :ga_notbare         ;NUL right after the
                                     ;address(es) -- a genuinely
                                     ;bare address (or a wholly
                                     ;blank line) -- `jmp` here,
                                     ;not `beq`: 2026-09-02's
                                     ;widened g/v pushed
                                     ;:bareaddr out of `beq`'s
                                     ;+/-127-byte range
            jmp   :bareaddr
:ga_notbare jsr   EX_CMD              ;ex: q!/wq/x/u/e/#/nu/
                                       ;mark/k -- fully handles
                                       ;and jmps MAINLOOP itself
                                       ;when recognized; returns
                                       ;(carry clear, ED_CMDPTR
                                       ;UNCHANGED) only when not
                                       ;recognized. ed: no-op
                                       ;stub (edbuf.s), always
                                       ;"not handled".
            ldy   #0
            lda   (ED_CMDPTR),y
            inc   ED_CMDPTR
            bne   :havecmd
            inc   ED_CMDPTR+1
:havecmd
            ldx   ED_GMODE       ;2026-09-02: skip the per-
            bne   :skipmut       ;command undo snapshot during
                                 ;a g/v pass-2 sub-dispatch
                                 ;(this file's own header)
            jsr   EX_MUTCHECK          ;ex: if A is a mutating
                                       ;verb (a i c d s g m t j
                                       ;r), snapshot the line
                                       ;table for `u` BEFORE it
                                       ;runs -- preserves A. ed:
                                       ;no-op stub (edbuf.s).
:skipmut
            cmp   #"a"
            bne   :nota
            jmp   ED_CMD_A
:nota       cmp   #"i"
            bne   :noti
            jmp   ED_CMD_I
:noti       cmp   #"c"
            bne   :notc
            jmp   ED_CMD_C
:notc       cmp   #"d"
            bne   :notd
            jmp   ED_CMD_D
:notd       cmp   #"p"
            bne   :notp
            jmp   ED_CMD_P
:notp       cmp   #"n"
            bne   :notn
            jmp   ED_CMD_N
:notn       cmp   #"q"
            bne   :notq
            jmp   ED_CMD_Q
:notq       cmp   #"r"
            bne   :notr
            jmp   ED_CMD_R
:notr       cmp   #"w"
            bne   :notw
            jmp   ED_CMD_W
:notw       cmp   #"s"
            bne   :nots
            jmp   ED_CMD_S
:nots       cmp   #"g"
            bne   :notg
            jmp   ED_CMD_G
:notg       cmp   #"v"
            bne   :notv
            jmp   ED_CMD_V
:notv       cmp   #"m"
            bne   :notm
            jmp   ED_CMD_M
:notm       cmp   #"t"
            bne   :nott
            jmp   ED_CMD_T
:nott       cmp   #"j"
            bne   :notj
            jmp   ED_CMD_J
:notj       cmp   #"="
            bne   :noteq
            jmp   ED_CMD_EQ
:noteq      cmp   #$A6               ;'&' high-bit-set -- repeat
            bne   :notamp            ;the last substitution
            jmp   ED_CMD_AMP
:notamp     jsr   ED_ERR             ;byte after the address(es)
                                     ;didn't NUL-terminate AND
                                     ;isn't a known verb --
                                     ;always a hard error
                                     ;(2026-08-19: the
                                     ;`1,2;3p`-shape audit case
                                     ;must stay `?`, never fall
                                     ;into the bare-address
                                     ;print below)
            jmp   MAINLOOP

:bareaddr   ldx   ED_GMODE            ;2026-09-02: an EMPTY g/v
            bne   :g_bareisp          ;cmds item ALWAYS implies
                                     ;`p` (ed's own `global`
                                     ;convention) regardless of
                                     ;whether cmds happened to
                                     ;carry its own address --
                                     ;unlike the top-level rule
                                     ;just below, which requires
                                     ;ED_ADDRCNT!=0
            lda   ED_ADDRCNT         ;2026-08-19: a bare address
                                     ;implies `p` (classic ed);
                                     ;a wholly blank line (0
                                     ;addresses) stays `?`
            beq   :nocmd
            lda   ED_D1FLAG          ;vi's `:` bridge (2026-09-
            beq   :g_bareisp         ;07): `:N` is a MOTION in
                                     ;vi (real vi) -- dot to the
                                     ;last address, print
                                     ;nothing. ED_CMD_P's own
                                     ;defaulting + range check,
                                     ;minus its ED_PUTLINE loop.
            jsr   ED_DFLT_DTDT
            jsr   ED_CHC_RNG12N
            bcc   :vi_setdot
            jmp   ED_ERR_JMP
:vi_setdot  lda   ED_ADDR2
            sta   ED_CURLINE
            lda   ED_ADDR2+1
            sta   ED_CURLINE+1
            jmp   MAINLOOP
:g_bareisp  jmp   ED_CMD_P
:nocmd      jsr   ED_ERR
            jmp   MAINLOOP

ED_DOEXIT0  lda   ED_ERRSTAT       ;EX2 2026-09-06
            jsr   EXIT

*---------------------------------------------------------------
* ED_ERR -- the classic "?" + CR, to fd 1.
*---------------------------------------------------------------
ED_ERR      lda   #1                 ;EX2 2026-09-06: a refused
            sta   ED_ERRSTAT         ;command is a session error
                                     ;whether or not the `?`
                                     ;below is actually printed
            lda   #ED_ERR_QUIET      ;ex is silent on a refused
            beq   :ee_show           ;command WHEN stdin is a
                                     ;script (POSIX `ex -s`);
                                     ;ed/vi always print `?`
            lda   #0                 ;fdstat(fd 0): stdin a tty?
            jsr   SC_FDSTAT          ;liba wrapper -- the $FF00
                                     ;choke point stays in liba
            bcs   :ee_show           ;probe failed -- show, safe
            bmi   :ee_show           ;high bit = DEVICE/tty ->
                                     ;interactive ex, show `?`
            rts                       ;file/pipe -> script mode,
                                     ;silent (error only in the
                                     ;exit status)
:ee_show    lda   #"?"
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* ED_RDCMDLINE -- read one CR-terminated line from fd 0 into
* CMDBUF (NUL-terminated, CR itself not stored). OUT: A = length
* (0-249), carry set if EOF was hit reading this line (A may
* still be >0 for a final line with no trailing CR); carry clear
* = a normal CR-terminated line, more input may follow.
*---------------------------------------------------------------
ED_RDCMDLINE
            ldy   #0
:copy       lda   CMD_RDPOS
            cmp   CMD_RDLEN
            bcc   :havebyte
            jsr   ED_REFILL_CMD
            lda   CMD_RDLEN
            bne   :copy
            ; EOF, nothing left in this refill
            lda   #0
            sta   CMDBUF,y
            tya
            sec
            rts
:havebyte   ldx   CMD_RDPOS
            lda   CMD_RDBUF,x
            inc   CMD_RDPOS
            cmp   #$8D
            bne   :notcr
            lda   #0
            sta   CMDBUF,y
            tya
            clc
            rts
:notcr      cpy   #CMDBUF_MAXLEN-1
            bcs   :trunc
            sta   CMDBUF,y
            iny
:trunc      bra   :copy

ED_REFILL_CMD
            tya
            pha
            lda   #<CMDRPARM
            ldx   #>CMDRPARM
            jsr   SC_READ
            pla
            tay
            bcs   :err
            lda   CMDRPRM_TRANS
            sta   CMD_RDLEN
            stz   CMD_RDPOS
            rts
:err        stz   CMD_RDLEN
            stz   CMD_RDPOS
            rts

CMDRPARM       dfb   PCOUNT_READ
CMDRPARM_REF   dfb   FD_STDIN
CMDRPARM_BUF   da    CMD_RDBUF
CMDRPARM_REQ   da    128
CMDRPRM_TRANS da    0

*---------------------------------------------------------------
* ED_PUTLINE -- print a NUL-terminated liba string at PTR0, then
* CR, to fd 1. CLOBBERS: A, X, Y, PTR0. Marks ED_GLASSOUT: the
* command put text on the glass, so vi's `:` landing keeps it
* readable ([Hit return to continue]) before repainting -- real
* vi's rule for p/nu/#/=/l output. ed/ex never read the cell.
*---------------------------------------------------------------
ED_PUTLINE  ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #1
            sta   ED_GLASSOUT
            rts

*---------------------------------------------------------------
* ED_PARSEADDR -- parse an optional address / address,address
* prefix at ED_CMDPTR, advancing it past whatever was consumed
* and leaving it at the command letter. OUT: carry clear +
* ED_ADDRCNT (0/1/2), ED_ADDR1, ED_ADDR2 set as parsed. Carry
* set = a malformed `addr,` with no second address (a genuine
* syntax error -- everything else that "isn't an address" is
* legitimately zero addresses, not an error, here).
*
* 2026-08-19: a BARE `,` (both sides omitted) is the classic
* `1,$` whole-buffer shorthand; a bare `;` is `.,$`. Checked
* FIRST, before ED_PARSE1ADDR ever runs, so it only fires when
* NO address token precedes the separator -- `1,2` etc. are
* unaffected, still handled below. A partially-bare range (`,5`
* or `1,`) is still NOT supported (unchanged v1 scope, B.ED.TXT)
* -- only the fully-bare separator gets this shorthand.
*---------------------------------------------------------------
ED_PARSEADDR
            stz   ED_ADDRCNT
            ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #$AC               ;',' high-bit-set
            beq   :barecomma
            cmp   #$BB               ;';' high-bit-set
            beq   :baresemi
            cmp   #$A5               ;'%' high-bit-set = 1,$
            beq   :pctwhole          ;ALWAYS whole buffer, both
                                     ;engines -- NOT subject to
                                     ;ED_BARE_CUR like `,`
            jsr   ED_PA1OFF
            bcc   :done0             ;nothing address-shaped --
                                     ;0 addresses
            lda   ED_TMP16
            sta   ED_ADDR1
            lda   ED_TMP16+1
            sta   ED_ADDR1+1
            lda   #1
            sta   ED_ADDRCNT
            ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #$AC        ;',' high-bit-set -- #"," confuses
                              ;merlin32's comma-as-field-
                              ;separator parser
            beq   :havesep
            cmp   #$BB        ;';' high-bit-set -- a non-bare
                             ;separator (POSIX): like ',' but
                             ;set '.' to ADDR1 first, so a
                             ;relative ADDR2 (e.g. .+2) is
                             ;measured from ADDR1
            bne   :done0
            lda   ED_ADDR1
            sta   ED_CURLINE
            lda   ED_ADDR1+1
            sta   ED_CURLINE+1
:havesep    inc   ED_CMDPTR
            bne   :haveaddr2
            inc   ED_CMDPTR+1
:haveaddr2  jsr   ED_PA1OFF
            bcc   :syntaxerr
            lda   ED_TMP16
            sta   ED_ADDR2
            lda   ED_TMP16+1
            sta   ED_ADDR2+1
            lda   #2
            sta   ED_ADDRCNT
:done0      clc
            rts
:syntaxerr  sec
            rts

:pctwhole   inc   ED_CMDPTR          ;'%' -- consume it, then
            bne   :pw_nb             ;the shared 1,$ body below
            inc   ED_CMDPTR+1        ;(not the ED_BARE_CUR test)
:pw_nb      bra   :whole1s

:barecomma  inc   ED_CMDPTR
            bne   :bc_nb
            inc   ED_CMDPTR+1
:bc_nb      lda   #ED_BARE_CUR       ;ex/vi: bare `,` = `.,.`
            bne   :baredot           ;ed: bare `,` = `1,$`
:whole1s    lda   #1
            sta   ED_ADDR1
            stz   ED_ADDR1+1
            lda   ED_NLINES
            sta   ED_ADDR2
            lda   ED_NLINES+1
            sta   ED_ADDR2+1
            lda   #2
            sta   ED_ADDRCNT
            clc
            rts

:baresemi   inc   ED_CMDPTR
            bne   :bs_nb
            inc   ED_CMDPTR+1
:bs_nb      lda   #ED_BARE_CUR       ;ex/vi: bare `;` = `.,.`
            bne   :baredot           ;ed: bare `;` = `.,$`
            lda   ED_CURLINE
            sta   ED_ADDR1
            lda   ED_CURLINE+1
            sta   ED_ADDR1+1
            lda   ED_NLINES
            sta   ED_ADDR2
            lda   ED_NLINES+1
            sta   ED_ADDR2+1
            lda   #2
            sta   ED_ADDRCNT
            clc
            rts

:baredot    lda   ED_CURLINE         ;POSIX ex/vi: an omitted
            sta   ED_ADDR1           ;side of a bare `,`/`;`
            sta   ED_ADDR2           ;defaults to `.`, so both
            lda   ED_CURLINE+1       ;ends are the current line
            sta   ED_ADDR1+1
            sta   ED_ADDR2+1
            lda   #2
            sta   ED_ADDRCNT
            clc
            rts

*---------------------------------------------------------------
* ED_PARSE1ADDR -- parse ONE address token at ED_CMDPTR: `.` `$`
* a decimal number, `/re/`, or (M2, ex only via the EX_MARKREF/
* EX_SEARCHBACK hooks -- ed's own stubs always say "not
* recognized" so ed's parsing is unchanged) `'x`/`''` or `?re?`.
* OUT: carry set + ED_TMP16/ED_TMP16+1 = the resulting line
* number, ED_CMDPTR advanced past the token; carry clear = no
* address token here (ED_CMDPTR unchanged).
*---------------------------------------------------------------
*---------------------------------------------------------------
* ED_PA1OFF -- ED_PARSE1ADDR plus POSIX `+N`/`-N`
* a base address optionally followed by any number of `+N`/`-N`
* (bare `+`/`-` is +1/-1); a LEADING `+`/`-` means `.`. Same
* OUT contract as ED_PARSE1ADDR. (2026-09-05, check_posixex.)
*---------------------------------------------------------------
ED_PA1OFF
            ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #"+"
            beq   :po_lead
            cmp   #"-"
            beq   :po_lead
            jsr   ED_PARSE1ADDR
            bcs   :po_loop           ;base found -> offsets
            rts                      ;no address token
:po_lead    lda   ED_CURLINE         ;leading +/- : base = .
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
:po_loop    ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #"+"
            beq   :po_plus
            cmp   #"-"
            beq   :po_minus
            sec                      ;done: address in ED_TMP16
            rts
:po_plus    lda   ED_TMP16           ;base on stack across the
            pha                      ;number parse (ED_PARSENUM
            lda   ED_TMP16+1         ;clobbers ED_TMP16B)
            pha
            jsr   :po_getn           ;ED_TMP16 = offset N
            pla
            sta   ED_TMP16B+1
            pla
            sta   ED_TMP16B
            clc
            lda   ED_TMP16B
            adc   ED_TMP16
            sta   ED_TMP16
            lda   ED_TMP16B+1
            adc   ED_TMP16+1
            sta   ED_TMP16+1
            bra   :po_loop
:po_minus   lda   ED_TMP16
            pha
            lda   ED_TMP16+1
            pha
            jsr   :po_getn
            pla
            sta   ED_TMP16B+1
            pla
            sta   ED_TMP16B
            sec
            lda   ED_TMP16B
            sbc   ED_TMP16
            sta   ED_TMP16
            lda   ED_TMP16B+1
            sbc   ED_TMP16+1
            sta   ED_TMP16+1
            bra   :po_loop
* :po_getn -- consume the +/- , parse the offset number (bare =
:po_getn    inc   ED_CMDPTR
            bne   :po_g1
            inc   ED_CMDPTR+1
:po_g1      ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #"0"
            bcc   :po_g0
            cmp   #"9"+1
            bcs   :po_g0
            jmp   ED_PARSENUM        ;ED_TMP16 = N, rts
:po_g0      lda   #1
            sta   ED_TMP16
            stz   ED_TMP16+1
            rts
ED_PARSE1ADDR
            ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #"."
            bne   :notdot
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            inc   ED_CMDPTR
            bne   :ok
            inc   ED_CMDPTR+1
:ok         sec
            rts

:notdot     cmp   #"$"
            bne   :notdollar
            lda   ED_NLINES
            sta   ED_TMP16
            lda   ED_NLINES+1
            sta   ED_TMP16+1
            inc   ED_CMDPTR
            bne   :ok2
            inc   ED_CMDPTR+1
:ok2        sec
            rts

:notdollar  cmp   #"/"
            beq   :dosearch
            cmp   #"'"
            beq   :domark
            cmp   #"?"
            beq   :dobackward
            cmp   #"0"
            bcc   :none
            cmp   #"9"+1
            bcs   :none
            jmp   ED_PARSENUM

:none       clc
            rts

:domark     jmp   EX_MARKREF
:dobackward jmp   EX_SEARCHBACK

:dosearch   lda   ED_CMDPTR          ;2026-08-19: save the
                                     ;token's OWN start (the
                                     ;`/`) so a failed search
                                     ;can restore ED_CMDPTR and
                                     ;keep THIS routine's own
                                     ;"carry clear = unchanged"
                                     ;contract honest -- see
                                     ;ED_SEARCHFWD's failure
                                     ;returns
            sta   ED_ADDRSTRT
            lda   ED_CMDPTR+1
            sta   ED_ADDRSTRT+1
            inc   ED_CMDPTR
            bne   :sok
            inc   ED_CMDPTR+1
:sok        jmp   ED_SEARCHFWD

*---------------------------------------------------------------
* ED_PARSENUM -- decimal digits at ED_CMDPTR -> ED_TMP16
* (16-bit). Always succeeds with carry set (caller already
* confirmed a digit is present).
*---------------------------------------------------------------
ED_PARSENUM stz   ED_TMP16
            stz   ED_TMP16+1
:loop       ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #"0"
            bcc   :done
            cmp   #"9"+1
            bcs   :done
            and   #$0F               ;digit value (works on both
                                     ;'0'..'9' and $B0..$B9 --
                                     ;low nibble is the same
                                     ;either way)
            pha
            jsr   ED_MUL10
            pla
            clc
            adc   ED_TMP16
            sta   ED_TMP16
            lda   #0
            adc   ED_TMP16+1
            sta   ED_TMP16+1
            inc   ED_CMDPTR
            bne   :loop
            inc   ED_CMDPTR+1
            bra   :loop
:done       sec
            rts

*---------------------------------------------------------------
* ED_MUL10 -- ED_TMP16 *= 10 (val*8 + val*2). CLOBBERS:
* ED_TMP16B.
*---------------------------------------------------------------
ED_MUL10    lda   ED_TMP16
            sta   ED_TMP16B
            lda   ED_TMP16+1
            sta   ED_TMP16B+1
            asl   ED_TMP16            ;*2
            rol   ED_TMP16+1
            asl   ED_TMP16            ;*4
            rol   ED_TMP16+1
            asl   ED_TMP16            ;*8
            rol   ED_TMP16+1
            clc
            lda   ED_TMP16
            adc   ED_TMP16B
            sta   ED_TMP16
            lda   ED_TMP16+1
            adc   ED_TMP16B+1
            sta   ED_TMP16+1
            clc
            lda   ED_TMP16
            adc   ED_TMP16B
            sta   ED_TMP16
            lda   ED_TMP16+1
            adc   ED_TMP16B+1
            sta   ED_TMP16+1
            rts

*---------------------------------------------------------------
* ED_SEARCHFWD -- parse a /re/ address: copy the pattern
* (respecting backslash-escapes of the delimiter) out of
* ED_CMDPTR into PATBUF, then search forward from the line after
* `.`, wrapping through line 1 back to `.`, for the first line
* containing a match anywhere. OUT: carry set + ED_TMP16 = the
* matching line number; carry clear = no match anywhere (or an
* empty buffer) -- treated by the caller as a syntax/range
* error.
*---------------------------------------------------------------
ED_SEARCHFWD
            lda   #<PATBUF
            sta   ED_DST
            lda   #>PATBUF
            sta   ED_DST+1
            ldy   #0
:copyloop   lda   (ED_CMDPTR),y
            beq   :endpat            ;unterminated -- lenient,
                                     ;EOL ends it
            cmp   #"/"
            beq   :endpat
            cmp   #"\"
            bne   :plain
            ;copy the backslash AND whatever follows it verbatim
            ;(even
            ;if that's the delimiter) -- RE_ATOM_PARSE
            ;interprets the
            ;escape itself; this loop must not treat an escaped
            ;'/' as
            ; the terminator.
            sta   (ED_DST)
            jsr   ED_BUMPDST
            iny
            lda   (ED_CMDPTR),y
            beq   :storeandend
            sta   (ED_DST)
            jsr   ED_BUMPDST
            iny
            bra   :copyloop
:storeandend
            bra   :endpat2
:plain      sta   (ED_DST)
            jsr   ED_BUMPDST
            iny
            bra   :copyloop
:endpat     ;advance ED_CMDPTR past the closing delimiter, if
            ;present
            lda   (ED_CMDPTR),y
            bne   :hasdelim
            bra   :endpat2
:hasdelim   iny
:endpat2    lda   #0
            sta   (ED_DST)
            ; advance ED_CMDPTR by Y bytes
            tya
            clc
            adc   ED_CMDPTR
            sta   ED_CMDPTR
            bcc   :nocarry
            inc   ED_CMDPTR+1
:nocarry

            ; empty pattern -- reuse LASTPAT, or `?` if there is
            ; none (2026-09-02, "last regular expression")
            jsr   ED_LASTRE
            bcc   :nomatch

            ; empty buffer -- no lines to search
            lda   ED_NLINES
            ora   ED_NLINES+1
            bne   :havelines
            bra   :nomatch

:havelines
            ;try each of the NLINES lines exactly once, starting
            ;right
            ; after `.` and wrapping line NLINES+1 -> 1
            lda   ED_NLINES
            sta   ED_TMP16B
            lda   ED_NLINES+1
            sta   ED_TMP16B+1
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
:tryline    inc   ED_TMP16
            bne   :chkwrap
            inc   ED_TMP16+1
:chkwrap    lda   ED_TMP16+1
            cmp   ED_NLINES+1
            bcc   :nowrap
            bne   :dowrap
            lda   ED_TMP16
            cmp   ED_NLINES
            bcc   :nowrap
            beq   :nowrap
:dowrap     lda   #1
            sta   ED_TMP16
            stz   ED_TMP16+1
:nowrap     jsr   ED_LINETEXT         ;PTR0 = text of line
                                      ;ED_TMP16
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            lda   PTR0
            sta   PTR2
            lda   PTR0+1
            sta   PTR2+1
            jsr   RE_MATCH
            bcc   :found
            lda   ED_TMP16B
            bne   :dec1
            dec   ED_TMP16B+1
:dec1       dec   ED_TMP16B
            lda   ED_TMP16B
            ora   ED_TMP16B+1
            bne   :tryline
:nomatch    ;2026-08-19: no match anywhere (or an empty buffer)
            ;-- restore ED_CMDPTR to the token's own start so
            ;ED_PARSE1ADDR's "carry clear = ED_CMDPTR unchanged"
            ;contract is actually true, not just documented.
            ;Before this fix ED_CMDPTR was left past the
            ;consumed pattern, which the caller read as "no
            ;address token here" -- `/zzz/p` with no match
            ;silently ran `p` on `.` instead of erroring.
            lda   ED_ADDRSTRT
            sta   ED_CMDPTR
            lda   ED_ADDRSTRT+1
            sta   ED_CMDPTR+1
            clc
            rts
:found      sec
            rts
