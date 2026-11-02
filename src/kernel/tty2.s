*---------------------------------------------------------------
* tty2.s -- TTY0/VC0 output pipeline: byte-level VT/ANSI escape
* parsing, the screen-backend abstraction (40-column text page
* and UltraTerm), and cursor handling. Split out of tty.s (task
* #8, docs/SELFHOST-CONVERSION.md phase 2) to keep each kernel
* module under 28000 bytes for compatibility with the maux
* assembler's shared symbol-table window. tty.s keeps the
* cooked line discipline (read/write syscalls, the raw
* type-ahead ring, ^C) and calls TTY_PUT_BYTE here to render.
* Full design notes: K.TTY.TXT (docs/a2/)
*---------------------------------------------------------------

*-- Table sizes for the ESC / CSI dispatch below, hoisted here:
*-- an equ used in an immediate operand BEFORE its definition is
*-- an "Illegal forward reference" on real Merlin-8 (and an equ
*-- between two locals would split their zone).
ESC_NSTATES equ   10
*-- 16->19 (VT102 slice 2): 'P' (DCH, TT9_DCH) + 'h'/'l' (the
*-- non-private mode family, TT9_MODE -- CSI 4 h/l is IRM).
CSI_N       equ   19

TTY_PUT_BYTE
            sta   PRC_BYTE
            and   #$7F
            sta   PRC_BYTE
*-- VT102 slice 6 (VT8, DEC VT102 UG ch. 5 sec 5.5.1): C0
*-- controls are classified BEFORE the parser state sees the
*-- byte. ESC restarts a sequence from any state; CAN/SUB abort
*-- one; every other control EXECUTES (CR, LF, BS, BEL, SO/SI
*-- ...) while a sequence in progress keeps its parameters --
*-- `ESC [ 2 ; LF 3 H` is a linefeed and then CUP 2;3. NUL and
*-- DEL are ignored everywhere. The pending xenl wrap is NO
*-- LONGER cleared here for every byte < $20 (finding VT4): the
*-- operations that cancel it on DEC hardware do so themselves.
            cmp   #$20
            bcs   :graphic
            cmp   #$1B
            beq   :esc
            cmp   #$18                  ;CAN
            beq   :cancel
            cmp   #$1A                  ;SUB: as CAN
            beq   :cancel
            jmp   TTY_PUT_CTL           ;execute, in any state
:graphic    cmp   #$7F
            beq   :ignore               ;DEL: ignored
            lda   VC_ESC_STATE
            beq   :normal
            cmp   #1
            beq   TTY_ESC_BYTE
            cmp   #4                    ;ESC ( / ) / # -- one
            bne   TTY_CSI_BYTE          ;designator byte
            jmp   TT9_SWALLOW
:normal     lda   PRC_BYTE
            jmp   TTY_PUT_PRNTB
:esc        lda   #1
            sta   VC_ESC_STATE
            stz   VC_SCS                ;a restart drops a half
            rts                         ;SCS designation
:cancel     stz   VC_ESC_STATE
:ignore     rts

*-- Two-byte ESC additions (VT102 slice 1, docs/CONSOLE-VT102.md
*-- sec 2): D/M/E -> IND/RI/NEL (tty9.s). H (HTS), = (DECKPAM),
*-- > (DECKPNM) need no branch at all -- "any other byte after
*-- ESC: drop it" (the fallthrough to :done, unchanged) already
*-- does exactly "accept and ignore". ( / ) / # swallow ONE more
*-- byte (VC_ESC_STATE=4, TT9_SWALLOW) so `ESC ( B` / `ESC ) 0`
*-- paint nothing.
TTY_ESC_BYTE
            stz   VC_ESC_STATE
            lda   PRC_BYTE
            ldx   #ESC_NSTATES-1            ;table dispatch: jmp
:scan       cmp   ESC_CH,x               ;(abs,x) 65C02, 3 B
            beq   :hit                   ;an entry, not the 7 of
            dex                          ;a cmp/bne/jmp chain --
            bpl   :scan                  ;bought back the 70 B
            rts                          ;MAUXEDTEST overran by
:hit        txa                          ;(check-kernel-images,
            asl   a                      ;2026-09-12). Any other
            tax                          ;other byte: dropped
            jmp   (ESC_JT,x)
*-- The two tables are parallel: ESC_CH[i] dispatches to
*-- ESC_JT[i]. Keep them in step.
ESC_CH      dfb   '[','7','8','c','D','M','E','(',')','#'
ESC_JT      da    TTY_CSI_START,TTY_CRSR_SAVE,TTY_CRSR_RSTR
            da    TTY_TRM_RESET,TT9_LBRK,TT9_RI,TT9_NEL
            da    TT9_SCS_SET,TT9_SCS_SET,TTY_ESC_SWL

*-- ESC # : swallow ONE more byte (VC_ESC_STATE=4, TT9_SWALLOW).
*-- ESC ( / ESC ) go through TT9_SCS_SET (tty9.s), which records
*-- the introducer so the swallowed designator can select a set.
TTY_ESC_SWL lda   #4
            sta   VC_ESC_STATE
            rts

TTY_CSI_START
            lda   #2
            sta   VC_ESC_STATE
            ldx   #4                   ;ROW, COL, P3, P4, PARAM
:zero       stz   VC_CSI_ROW,x         ;(contiguous, tty.s)
            dex
            bpl   :zero
            rts

TTY_CSI_BYTE
            lda   PRC_BYTE
            cmp   #'0'
            bcc   :nondigit
            cmp   #':'
            bcs   :nondigit
            sec
            sbc   #'0'
            sta   P_TMP
            lda   VC_ESC_STATE
            cmp   #3                   ;ESC [ ? n: the private
            bne   :plaindig            ;mode number is 16-bit
            jmp   TTY_CSI_PRVD
*-- the parameter number (0-3, saturating) indexes the four
*-- contiguous cells ROW/COL/P3/P4 (tty.s) -- one accumulate,
*-- not a copy per cell (TTY_CSI_AC10 keeps X).
:plaindig   ldx   VC_CSI_PARAM
            lda   VC_CSI_ROW,x
            jsr   TTY_CSI_AC10
            sta   VC_CSI_ROW,x
            rts

:nondigit   lda   PRC_BYTE
            cmp   #'?'
            beq   :priv
            cmp   #';'
            bne   :final
            ldx   VC_ESC_STATE         ;a second private param
            cpx   #3                   ;names no mode we know:
            beq   :pin                 ;pin it, swallow the rest
            lda   VC_CSI_PARAM
            cmp   #3
            bcc   :nextp               ;0 -> 1 -> 2 -> 3: four
*-- A FIFTH+ parameter (finding VT5): the count saturates at 3
*-- (no byte wrap after 256 semicolons) and the completed fourth
*-- FOLDS into P3 when it is an attribute SGR acts on (0/7/27 --
*-- TTY_SGR_CLASS), so `CSI 0;1;4;7;5 m`, the stock vt102
*-- entry's five-parameter standout, reaches TTY_CSI_ATTR as
*-- 0;1;7;5 -- exact, since SGR here is "last of 0/7/27 wins".
*-- P4 then starts the new parameter. The mode escape (`v`)
*-- takes four parameters at most, so nothing else sees this.
            lda   VC_CSI_P4
            jsr   TTY_SGR_CLASS
            bcs   :zp4
            lda   VC_CSI_P4
            sta   VC_CSI_P3
:zp4        stz   VC_CSI_P4
            rts
:nextp      inc   VC_CSI_PARAM         ;params (VIDMODE V2.0)
            rts
*-- ESC [ ? -- a DEC/xterm PRIVATE mode (TTY_CSI_PRIV). State 3
*-- swallows the whole sequence to its final byte, so an unknown
*-- mode is never rendered as text or dispatched as a plain CSI.
*-- A `?` that is not the first byte (or a second `?`) pins the
*-- number to $FFFF, which matches nothing.
:priv       ldx   VC_ESC_STATE
            cpx   #3
            beq   :pin
            lda   #3
            sta   VC_ESC_STATE
            lda   VC_CSI_ROW
            ora   VC_CSI_PARAM
            beq   :swallow
:pin        lda   #$FF
            sta   VC_CSI_ROW
            sta   VC_CSI_COL
:swallow    rts
:final      ldx   VC_ESC_STATE
            stz   VC_ESC_STATE
            cpx   #3
            bne   :not_priv
            jmp   TTY_CSI_PRIV
*-- xenl (finding VT4, wraptest's DEC columns): every cursor,
*-- edit and erase final cancels a pending wrap; SGR (`m`) and
*-- the mode families (`h`/`l`, private ones above) keep it.
:not_priv   cmp   #'m'
            beq   :keepx
            cmp   #'h'
            beq   :keepx
            cmp   #'l'
            beq   :keepx
            stz   VC_XENL
*-- ...and the same finals end the ^L shadow's line (KFIX9,
*-- TTY_SHDW_TAP): the replay is an append, and these are not.
            stz   VC_OSHDW_LEN
:keepx      ldx   #CSI_N-1              ;final-byte table (see
:scan       cmp   CSI_CH,x               ;ESC_CH above for why)
            beq   :hit
            dex
            bpl   :scan
            rts                          ;unknown final: dropped
:hit        txa
            asl   a
            tax
            jmp   (CSI_JT,x)
*-- Parallel tables; keep in step. H/f CUP, A-D CUU/CUD/CUF/CUB
*-- (A/B margin-clamped, tty9.s), J/K ED/EL 0-2, m SGR, z VT
*-- switch, v VIDMODE, S/T SU/SD, L/M IL/DL, r DECSTBM (all the
*-- scroll ones margin-bounded, tty9.s).
CSI_CH      dfb   'H','f','A','B','C','D','J','K'
            dfb   'm','z','v','S','T','L','M','r'
*-- VT102 slice 2: P = DCH, h/l = the non-private mode family
*-- (TT9_MODE decides what Pn means -- 4 is IRM, everything else
*-- accepted and ignored, same convention TTY_CSI_PRIV uses).
            dfb   'P','h','l'
CSI_JT      da    TTY_CSI_HOME,TTY_CSI_HOME,TT9_CUU,TT9_CUD
            da    TTY_CSI_RIGHT,TTY_CSI_LEFT,TT9_ED,TT9_EL
            da    TTY_CSI_ATTR,TTY_CSI_VT,TTY_CSI_MODE,TT9_SU
            da    TT9_SD,TT9_IL,TT9_DL,TT9_DECSTBM
            da    TT9_DCH,TT9_MODE,TT9_MODE

*-- TTY_CSI_SU/SD/IL/DL and their TTY_SCLAMP/TTY_CSI_RGN
*-- prologues moved to tty9.s (TT9_SU/TT9_SD/TT9_IL/TT9_DL/
*-- TT9_SCLAMP/TT9_RGN, VT102 slice 1): DECSTBM makes every one
*-- of
*-- them margin-bounded rather than
*-- whole-screen/cursor-to-bottom,
*-- new logic that belongs beside the rest of the margin math,
*-- not
*-- grown in this file. The dispatch above already points there.

*---------------------------------------------------------------
* TTY_CSI_VT -- ESC [ n z : make console n the active one.
*
* n is ONE-BASED, because that is what a person types: `chvt 1`
* is the console you boot on. Out of range or absent is a no-op
* --
* a terminal must not be steerable into a console that does not
* exist by a stray byte in a text file.
*
* WHY A CSI SEQUENCE AND NOT A SYSCALL. maux has no ioctl, and
* switching is not worth inventing one for on its own -- this
* rides the escape parser that is already here, costs no syscall
* number, and is reachable by any program that can write to its
* own terminal. GNO/ME's ioctl() is still the right long-term
* home for device properties (see the GNO learning); when maux
* grows one, this becomes its front-end, not its competitor.
*---------------------------------------------------------------

*-- A*10 + P_TMP with SATURATION -- placed AFTER TTY_CSI_BYTE's
*-- whole local zone: dropped mid-zone it orphans :nondigit
*-- from its branches under real Merlin (loud there, silent
*-- under merlin32 -- the cross-zone :local family; caught by
*-- check-librel's emulated assembly, Errors: 2).
*-- A*10 + P_TMP with SATURATION: any overflow pins $FF, which
*-- no validator accepts -- so ESC [ 296 ; 24 ; 1 v cannot alias
*-- to 40 through the byte wrap (review V1 finding 4). A base of
*-- 26+ already overflows the *10; the shifts would drop bits
*-- silently, so the pre-check does the catching there.
TTY_CSI_AC10
            cmp   #26
            bcs   :sat
            asl
            sta   P_TMP2
            asl
            asl
            clc
            adc   P_TMP2
            adc   P_TMP
            bcs   :sat
            rts
:sat        lda   #$FF
            rts

*---------------------------------------------------------------
* TTY_CSI_PRVD -- one more digit of a PRIVATE mode number. 1049
* does not fit a byte, so VC_CSI_ROW/COL are its lo/hi and the
* step is a 16-bit x10 + P_TMP: x4 (two shifts), + v (x5), x2
* (x10), + digit. VC_CSI_P3 is the hi scratch -- the mode escape
* (`v`) is the only user of P3, and it is never a `?` sequence.
* Pinned at $FFFF once hi reaches 25 (no mode that large
* exists; a pinned value matches nothing in TTY_CSI_PRIV).
*---------------------------------------------------------------
TTY_CSI_PRVD
            lda   VC_CSI_COL
            cmp   #25
            bcs   :sat
            lda   VC_CSI_ROW
            asl
            sta   P_TMP2
            lda   VC_CSI_COL
            rol
            sta   VC_CSI_P3
            asl   P_TMP2
            rol   VC_CSI_P3            ;x4
            clc
            lda   P_TMP2
            adc   VC_CSI_ROW
            sta   P_TMP2
            lda   VC_CSI_P3
            adc   VC_CSI_COL
            sta   VC_CSI_P3            ;x5
            asl   P_TMP2
            rol   VC_CSI_P3            ;x10
            clc
            lda   P_TMP2
            adc   P_TMP
            sta   VC_CSI_ROW
            lda   VC_CSI_P3
            adc   #0
            sta   VC_CSI_COL
            rts
:sat        lda   #$FF
            sta   VC_CSI_ROW
            sta   VC_CSI_COL
            rts

*---------------------------------------------------------------
* TTY_CSI_PRIV -- ESC [ ? n h / l, the DEC/xterm private modes.
* A = the final byte, VC_CSI_ROW/COL = n (TTY_CSI_PRVD). ?1049
* --
* xterm's alternate screen, smcup/rmcup (tty5.s VCA_ENTER/
* VCA_EXIT, docs/VI-ALTSCREEN.md) -- and ?1 (DECCKM, tty9.s
* TT9_CKM, VT102 slice 1) are implemented. EVERY other private
* mode (?7 autowrap, ?25 cursor, ?47/?1047/?1048, anything) is
* swallowed and silently ignored: the xterm convention, and the
* one that lets a future serial backend pass the same bytes
* through to a real terminal untouched -- ?7 in particular is
* correct-by-ignoring, since autowrap-on is the V1 console's
* only
* mode anyway (docs/CONSOLE-VT102.md gap table).
*---------------------------------------------------------------
TTY_CSI_PRIV
            ldx   VC_CSI_COL           ;hi byte: 0 for both 1
            bne   :not1                ;and 7 (1049's hi is 4)
            ldx   VC_CSI_ROW
            cpx   #1
            beq   :ckm
            cpx   #7                   ;?7 = DECAWM (slice 7)
            bne   :out                 ;anything else with
            jmp   TT9_AWM              ;hi=0: ignore
:ckm        jmp   TT9_CKM
:not1       cpx   #>1049
            bne   :not1049             ;hi 4: ?1049; else ?3001
            ldx   VC_CSI_ROW
            cpx   #<1049
            bne   :out                 ;hi 4: not ?3001 either
            cmp   #'h'
            beq   :enter
            cmp   #'l'
            bne   :out
            jmp   VCA_EXIT
:enter      jmp   VCA_ENTER
*-- ?3001 (maux-private, 2026-09-11): what the emphasis bit
*-- MEANS on the UltraTerm -- h = highlight (bright), l =
*-- inverse
*-- (the default; `reset` restores it). One bit per cell, two
*-- attribute sets per screen, so bold and inverse are the same
*-- thing here; a pager meeting bold text turns this on for its
*-- run and off at exit. No effect on the //e backends, where
*-- emphasis is always inverse.
:not1049    cpx   #>3001               ;X = VC_CSI_COL still
            bne   :out
            ldx   VC_CSI_ROW
            cpx   #<3001
            bne   :out
            cmp   #'h'
            beq   :hl
            cmp   #'l'
            bne   :out
            lda   #0
            beq   :st                  ;always
:hl         lda   #1
:st         sta   VC_ATTRMODE
            jmp   TTY_ATTR_APP
:out        rts

TTY_CSI_VT
            lda   VC_CSI_ROW
            beq   :out
            dec   a                  ;1-based to 0-based
            cmp   #VC_COUNT
            bcs   :out
*-- MID-REDIRECT, THE SWITCH IS PARKED, NOT RUN. Inside a
*-- background write (TTY_WR_ENTER holds the TARGET's struct
*-- in VC_STATE and TTY_DSTBASE aims at its store), an inline
*-- VC_SWITCH would save the target's struct into the ACTIVE
*-- console's slot and shred both. Seen, not theorized:
*-- `chvt 1` run while console 2 held the glass writes its
*-- ESC [ 1 z to fd 1 = console 1 = background, and the glass
*-- flooded with garbage. TTY_WR_LEAVE runs the parked switch
*-- once the structs are back home (+1 so 0 means none).
            ldx   TTY_WR_SWAP          ;(swapped, not merely
            beq   :now                 ;redirected: an owner's
            inc   a                    ;background write has
            sta   VC_SW_PEND           ;no redirect either)
            rts
:now        jmp   VC_SWITCH
:out        rts

TTY_CSI_HOME
            lda   VC_CSI_ROW
            bne   :row
            lda   #1
:row        cmp   #1
            bcs   :rowmin
            lda   #1
:rowmin     cmp   TTY_ROWS                ;clamp to 1..TTY_ROWS
            beq   :rowok
            bcc   :rowok
            lda   TTY_ROWS
:rowok      sec                           ;CSI rows are
                                          ;1-based
            sbc   #1
            sta   VC_ROW
            lda   VC_CSI_COL
            bne   :col
            lda   #1
:col        cmp   #1
            bcs   :colmin
            lda   #1
:colmin     cmp   TTY_COLS                ;clamp to 1..TTY_COLS
            beq   :colok
            bcc   :colok
            lda   TTY_COLS
:colok      sec                           ;CSI columns are
                                          ;1-based
            sbc   #1
            sta   VC_COL
            rts

*-- TTY_CSI_UP/DOWN moved to tty9.s (TT9_CUU/TT9_CUD, VT102
*-- slice
*-- 1): CUU/CUD now clamp at the MARGIN, not just the physical
*-- edge (docs/CONSOLE-VT102.md sec 2 item 7). The dispatch
*-- above
*-- already points there.

TTY_CSI_RIGHT
            lda   VC_CSI_ROW
            bne   :n
            lda   #1                      ;absent param defaults
                                          ;to 1
:n          sta   P_TMP
            lda   VC_COL
            clc
            adc   P_TMP
            cmp   TTY_COLS                ;clamp to the last
                                          ;column, 0-based
            bcc   :store
            lda   TTY_COLS
            sec
            sbc   #1
:store      sta   VC_COL
            rts

TTY_CSI_LEFT
            lda   VC_CSI_ROW
            bne   :n
            lda   #1                      ;absent param defaults
                                          ;to 1
:n          sta   P_TMP
            lda   VC_COL
            sec
            sbc   P_TMP
            bcs   :store
            lda   #0
:store      sta   VC_COL
            rts

*-- TTY_CSI_CLEAR (ESC [ 2 J) moved to tty9.s (TT9_ED/TT9_ED2,
*-- VT102
*-- slice 1): ED never moves the cursor on a real VT102, so 2J
*-- is
*-- TTY_CLR_BODY directly now, NOT this routine -- see
*-- TTY_CLR_SCRN's
*-- own note just below, updated the same day.

* TTY_CLR_SCRN -- the clear-screen COMMAND: `TTY_CLR_BODY` +
* home + column 0. ONE caller now -- the line discipline's ^L
* (docs/CONSOLE.md section 1's layering: ^L calls the command
* directly rather than injecting `ESC [ 2 J` bytes through
* TTY_PUT_BYTE, which would route through the byte parser's
* shared VC_ESC_STATE while TTY_POLL's tick-hook can land
* mid-sequence in someone else's write()). It used to also be
* `ESC [ 2 J`'s implementation, but VT102's ED never moves the
* cursor (docs/CONSOLE-VT102.md sec 2), and this DOES home it --
* so 2J parted ways with ^L's clear 2026-09-11 (TT9_ED2 calls
* TTY_CLR_BODY alone). Anything that changes what ^L's clear
* means still only has to change it here.
TTY_CLR_SCRN
            jsr   TTY_CLR_BODY
            jsr   TTY_HOME_ROW
            stz   VC_COL
            rts

* TTY_HOME_ROW -- VC_ROW = the home row: 0 on every backend now
* that the UltraTerm's status-line reservation went the way of
* the motherboard one (docs/CONSOLE.md sec 6, 2026-09-03). Kept
* as the one call site for "home" so a future indicator row has
* somewhere to live.
TTY_HOME_ROW
            stz   VC_ROW
            rts

* TTY_ERS_SPAN -- blank columns [VC_COL, A) of VC_ROW, cursor
* unchanged (VC_COL is saved and restored -- erase must not move
* it). The ONE row-blank primitive: ESC [ K is [VC_COL,
* TTY_COLS)
* (TTY_CSI_ERSLN, the entry below), ESC [ 1 K is [0, VC_COL]
* (tty9.s TT9_EL1), and a whole-row clear (TT9_CLRROW, so ED's
* 0/1/2 rows too) is [0, TTY_COLS). Each foreground backend
* blanks its span in ONE setup:
*   40-column: the text-page row is 40 contiguous bytes at
*     TTY_ROW_LO/HI (TTY_STORE_Y's plain `sta (P_PTR2),y` for
*     the glass), so a direct fill -- the per-cell TTY_BLNK_CELL
*     walk cost ~120 cycles a cell, 116k for an ED 0 from home
*     against 34k for ED 2 (2026-09-12 performance review,
*     item 3).
*   native-80: N8_ERSSPAN (tty5.s), one masked aux window for
*     the whole even half instead of one per even cell (~40
*     brackets, each with a PCB read; docs/CONSOLE-OPT.md 1a,
*     2026-09-03).
*   UltraTerm: UT_ERS_SPAN (ultraterm.s), one claim + one ring
*     walk, VRAM only -- the store is rebuilt from VRAM on
*     switch-away (VCS_UTSAVE) since 2026-09-10, and the store
*     tail fill this path still carried (VCS_ERS_TAIL, tty4.s)
*     was a quarter of every ESC [ K (retired 2026-09-12).
* Redirected stores keep the cell walk: TTY_BLNK_CELL's linear
* store path IS the redirect path (TTY_WR_CELL's note -- N8's
* interleave arithmetic aimed at a store address would shred
* kernel main memory). CLOBBERS: A, X, Y, P_PTR2, TT9_EEND.
TTY_CSI_ERSLN
            lda   TTY_COLS                ;ESC [ K: the tail
TTY_ERS_SPAN
            sta   TT9_EEND
            lda   VC_COL
            pha
            ldx   TTY_DSTBASE+1
            bne   :clear                  ;redirected: cell walk
            lda   TTY_BKND
            cmp   #TTY_BKN8
            bne   :tryut
            jsr   N8_ERSSPAN              ;one aux window,
            bra   :done                   ;whole even span
:tryut      cmp   #TTY_BKUT
            bne   :bk40
            ldx   VC_ROW                  ;UltraTerm: one ring
            ldy   VC_COL                  ;walk, VRAM only
            lda   TT9_EEND
            jsr   UT_ERS_SPAN
            bra   :done
:bk40       lda   VC_ROW                  ;40-column: a direct
            jsr   TTY_ROW_DST_A           ;text-page fill
            ldy   VC_COL
            lda   #$A0
:f40        cpy   TT9_EEND
            bcs   :done
            sta   (P_PTR2),y
            iny
            bra   :f40
:clear      lda   VC_COL
            cmp   TT9_EEND
            bcs   :done
            jsr   TTY_BLNK_CELL
            inc   VC_COL
            bra   :clear
:done       pla
            sta   VC_COL
            rts

* TTY_CSI_ATTR -- SGR. EVERY supplied parameter is applied, in
* order (finding VT5): `ESC [ 0 ; 7 m` is the ordinary "reset,
* then inverse", and curses' stock vt102 standout is
* `ESC [ 0 ; 1 ; 7 m` -- reading fewer parameters than were
* sent silently dropped the inverse. A fifth+ parameter was
* folded into P3 by the parser (TTY_CSI_BYTE's `;`), so the
* four slots are the whole list here.
TTY_CSI_ATTR
            ldx   #0
:lp         lda   VC_CSI_ROW,x            ;parameters 0..PARAM
            jsr   TTY_SGR_APP_A           ;(contiguous, tty.s;
            cpx   VC_CSI_PARAM            ;TTY_SGR_APP_A keeps
            bcs   :done                   ;X)
            inx
            cpx   #4
            bcc   :lp
:done       rts

* TTY_SGR_APP_A -- apply SGR parameter A to VC_ATTR.
* TTY_SGR_CLASS -- classify it: C clear + A = the attribute
* value (0 = normal, 1 = inverse) for 0 / 7 / 27, and for 1
* (bold) on a console whose emphasis bit renders BRIGHT; C set
* for anything else (bold where it cannot be seen, underline,
* blink... -- ignored, per docs/CONSOLE.md section 6). The
* parser's fifth-parameter fold uses the classifier alone.
TTY_SGR_APP_A
            jsr   TTY_SGR_CLASS
            bcs   :out
            sta   VC_ATTR
:out        rts

TTY_SGR_CLASS
            cmp   #7
            beq   :inverse                ;SGR 7 -- inverse on
            cmp   #0
            beq   :reset                  ;SGR 0 -- reset all
            cmp   #1
            beq   :bold                   ;SGR 1 -- bold: the
                                          ;SAME emphasis bit
                                          ;(one per cell), but
                                          ;only where that bit
                                          ;is BRIGHTNESS
            cmp   #22
            beq   :reset                  ;SGR 22 -- bold off
            cmp   #27
            bne   :ignore                 ;SGR 27 -- inverse off
:reset      lda   #0
            clc
            rts
:bold       lda   VC_ATTRMODE             ;bold asks for
            beq   :ignore                 ;brightness. A console
            lda   TTY_BKND                ;showing emphasis as
            cmp   #TTY_BKUT               ;inverse (every //e
            bne   :ignore                 ;one) cannot say it,
                                          ;and inverse mid-
                                          ;sentence reads worse
                                          ;than plain: ignored,
                                          ;the way a terminfo
                                          ;entry without `bold`
                                          ;is. SGR 7 still sets
                                          ;the bit everywhere.
                                          ;Falls THROUGH.
:inverse    lda   #1
            clc
            rts
:ignore     sec
            rts

* TTY_ATTR_APP -- push THIS console's emphasis meaning
* (VC_ATTRMODE) into the card's attribute register -- only when
* this console is the live card console (UltraTerm backend and
* not a redirected store), since the register is the screen's.
TTY_ATTR_APP
            lda   TTY_BKND
            cmp   #TTY_BKUT
            bne   :out
            ldx   TTY_DSTBASE+1
            bne   :out
            lda   VC_ATTRMODE
            beq   :inv
            lda   #UT_ATTR_HL
            bne   :wr                  ;always (\$10)
:inv        lda   #UT_ATTR_INV
:wr         jmp   UT_WR_ATTR
:out        rts

* TTY_CRSR_SAVE / TTY_CRSR_RSTR -- DECSC / DECRC (ESC 7/ESC 8).
* The whole DECSC block (tty.s VC_ROW..VC_ACS, VC_DSC_N bytes:
* position, rendition, pending wrap, character sets -- the
* VT102 UG's own list, plus the wrap DEC hardware restores;
* finding VT4/VT7). The restore CLAMPS the column to the live
* geometry (VT6): the stash is homed on a geometry change
* (tty7.s), and this keeps 0 <= VC_COL < TTY_COLS true on every
* path regardless -- TT9_ICHSH's descending loop would walk off
* TT9_RBUF on a column past the width. Rows are 24 in every
* geometry, so the row needs no clamp yet.
TTY_CRSR_SAVE
            ldx   #VC_DSC_N-1
:lp         lda   VC_ROW,x
            sta   VC_SAVE_ROW,x
            dex
            bpl   :lp
            rts

TTY_CRSR_RSTR
            stz   VC_OSHDW_LEN          ;cursor jumps (KFIX9)
            ldx   #VC_DSC_N-1
:lp         lda   VC_SAVE_ROW,x
            sta   VC_ROW,x
            dex
            bpl   :lp
            lda   VC_COL
            cmp   TTY_COLS
            bcc   :ok
            lda   TTY_COLS
            dec   a
            sta   VC_COL
:ok         rts

TTY_TRM_RESET
            stz   VC_OSHDW_LEN          ;blank glass (KFIX9)
            stz   VC_ATTR
            stz   VC_ATTRMODE             ;emphasis -> inverse
            jsr   TTY_ATTR_APP
            jsr   TTY_CLR_BODY
            jsr   TTY_HOME_ROW
            stz   VC_COL
            stz   VC_DECCKM             ;RIS resets DECCKM +
            stz   VC_IRM                ;IRM (slice 2) + the
            stz   VC_XENL               ;pending wrap (slice 3)
            lda   #1
            sta   VC_AWM                ;autowrap on (slice 7)
            jsr   TT9_CSRESET           ;character sets (sl 5)
            jmp   TT9_MRESET            ;margins (VT102 sl 1)

* TTY_PUT_CTL -- a C0 control (PRC_BYTE < $20, not ESC/CAN/SUB
* -- TTY_PUT_BYTE keeps those), executed whatever the parser
* state (VT102 slice 6). CR depends on TMD_OPOST (TT9_CR,
* CONSOLE-VT102.md sec 3); LF, VT and FF are all IND (down one,
* same column, region scroll at the margin -- the col-0 half of
* a newline is CR's, under OPOST); SO/SI invoke G1/G0; BS and
* HT are cursor motions (finding VT2/VT3); BEL arms the visual
* bell (TTY_FLSH, tty9.s); anything else (NUL, ENQ...) is
* ignored.
TTY_PUT_CTL
            lda   PRC_BYTE
            cmp   #$0D
            bne   :notcr
            jmp   TT9_CR
:notcr      cmp   #$0A
            bcc   :low
            cmp   #$0D                  ;LF, VT, FF: index
            bcc   :ind
            cmp   #$0E
            bne   :notso
            jmp   TT9_SO                ;SO: G1 (line drawing)
:notso      cmp   #$0F
            bne   :done
            jmp   TT9_SI                ;SI: G0 (ASCII)
:ind        jmp   TT9_LBRK
:low        cmp   #$08
            beq   TTY_BACKSPACE
            cmp   #$09
            beq   TTY_TAB
            cmp   #$07                  ;BEL: the visual bell --
            bne   :done                 ;arm it; TTY_TICK draws
            lda   #1                    ;it (tty9.s TTY_FLSH)
            sta   TTY_FLSH
:done       rts

* See K.PROCESS.TXT: "TTYINVERSEA -- A in ASCII $20-$7F"
TTY_INVERSE_A
            and   #$7F
            cmp   #$60
            bcs   :done                   ;lowercase is already
                                          ;inverse here
            and   #$3F
:done       rts

*---------------------------------------------------------------
* TTY_PUT_PRNTB -- store the printable in A at (VC_ROW,VC_COL)
* and advance. VT102 slices 2/3 (docs/CONSOLE-VT102.md sec 2/4)
* both hang off this one entry point:
*
*   xenl (slice 3): a PENDING wrap (VC_XENL, set the last time
*   a printable landed in the last column) is consumed HERE,
*   before this character is placed -- clear the flag and
*   newline first, so the deferred wrap happens on the character
*   that provoked it, not the one that set it.
*
*   IRM (slice 2): while VC_IRM is set, every printable pushes
*   the row's tail right by one (TT9_ICHSH) before it is
*   stored -- the row-shift-in-reverse of DCH.
*
* TT9_PCHAR carries the character across both (a cell, not a
* register: TT9_ICHSH/TTY_NEWLINE reach BankCopy and the scroll
* primitives, which do not promise to leave A alone).
*---------------------------------------------------------------
TTY_PUT_PRNTB
            sta   TT9_PCHAR
            lda   VC_XENL
            beq   :noxenl
            stz   VC_XENL
            jsr   TTY_NEWLINE
:noxenl     lda   VC_IRM
            beq   :noirm
            jsr   TT9_ICHSH
:noirm      lda   TT9_PCHAR
            jsr   TTY_WR_CELL              ;ASCII in, backend
                                           ;encodes + applies
                                           ;VC_ATTR
            inc   VC_COL
            lda   VC_COL
            cmp   TTY_COLS                 ;40 or 80, per
                                           ;backend
            bcc   :done
*-- xenl: stay LOGICALLY at the last column -- the wrap is
*-- deferred to the top of this routine, on the NEXT printable
*-- (docs/CONSOLE-VT102.md sec 2/4, VT102 slice 3). With
*-- autowrap OFF (DECAWM, slice 7) there is no wrap to defer:
*-- the cursor just stays on the last column.
            dec   VC_COL
            lda   VC_AWM
            beq   :done
            lda   #1
            sta   VC_XENL
:done       rts

* TTY_TAB -- HT: cursor to the next 8-column stop, clamped at
* the last column; paints NOTHING and never leaves the row (DEC
* VT102 UG ch. 5: "moves cursor to next tab stop, or to right
* margin if there are no more tab stops"). It used to print
* spaces through TTY_PUT_PRNTB -- overwriting cells, inserting
* under IRM and wrapping onto the next row -- which turned every
* curses cursor motion by tab into an erase (finding VT3). A
* pending wrap is kept (wraptest: TAB does not cancel it). vi
* paints its own tabs as spaces now (viscreen.s VI_PUTCT).
TTY_TAB
            lda   VC_COL
            ora   #7
            inc   a
            cmp   TTY_COLS
            bcc   :store
            lda   TTY_COLS
            dec   a
:store      sta   VC_COL
            rts

* TTY_BACKSPACE -- BS: one column left, none at column 0, and
* the cell is NOT blanked (VT102: "if cursor is at left margin,
* no action occurs"). The old destructive, row-crossing erase
* (review finding VT2) belongs to readline-lite alone -- tty6.s
* TTY_ED_KILL steps and blanks for itself now. Cancels a pending
* wrap (wraptest: "BS works at margin" on every DEC terminal).
TTY_BACKSPACE
            stz   VC_XENL
            lda   VC_COL
            beq   :done
            dec   VC_COL
:done       rts

* Off the bottom MARGIN row: TTY_JSCROLL (tty8.s) scrolls by the
* whole staged burst and leaves VC_ROW where the burst's last
* line will land -- one row copy per write(), not per line. Real
* body (the DECSTBM margin bound) is TT9_NEWLINE (tty9.s, VT102
* slice 1) -- this label stays so every existing caller (CR
* under
* TMD_OPOST, LF, the col-N wrap) is unchanged.
TTY_NEWLINE
            jmp   TT9_NEWLINE

*---------------------------------------------------------------
* TTY_WR_CELL -- put ASCII A at VC_ROW/VC_COL, honouring
* VC_ATTR. Backends own the ENCODING, because the two are not
* the same alphabet:
*
*   //e text page: Apple display codes. Normal text is
*     ASCII OR $80; inverse is a range-dependent fold
*     (TTY_INVERSE_A) because inverse lowercase only exists in
*     the alternate character set.
*   UltraTerm:     plain ASCII in bits 6-0, bit 7 is the
*     inverse-video ATTRIBUTE. No fold -- applying the //e one
*     here would corrupt the glyph.
*
* Callers pass ASCII and set VC_ATTR. Nothing above this line
* knows a display code.
*---------------------------------------------------------------
TTY_WR_CELL
            and   #$7F
            ldx   VC_ACS                   ;active set graphics?
            beq   :ascii                   ;(VT102 slice 5)
            jsr   TT9_ACSMAP               ;DEC special -> ASCII
:ascii      sta   PRC_BYTE
            lda   TTY_BKND
            cmp   #TTY_BKUT
            beq   :ultra
            ;-- Apple text page -- the 40-column and native
            ;-- 80-column backends share one alphabet (display
            ;-- codes + the sec 6 fold); only the STORE differs.
            lda   PRC_BYTE
            ora   #$80
            sta   PRC_BYTE
            lda   VC_ATTR
            beq   :apstore
            lda   PRC_BYTE
            jsr   TTY_INVERSE_A
            sta   PRC_BYTE
*-- REDIRECTED STORES BYPASS THE BACKEND (review finding
*-- 4, 2026-08-31): the console store is its own linear target,
*-- and N8_STORE's interleave arithmetic + 80STORE flips aimed
*-- at a store address would shred kernel main memory, while
*-- UT_PUT_CELL would paint the FOREGROUND card. TTY_ROW_DST_A
*-- already answers with the store row when TTY_DSTBASE is set,
*-- so the 40-column store path IS the redirect path -- rows
*-- are VC_STR_COLS wide, so any TTY_COLS fits.
:apstore    ldx   TTY_DSTBASE+1
            bne   :apglass
            lda   TTY_BKND
            cmp   #TTY_BKN8
            beq   :n8
:apglass    lda   VC_ROW
            jsr   TTY_ROW_DST_A
            ldy   VC_COL
            lda   PRC_BYTE
            jsr   TTY_STORE_Y
            rts
:n8         lda   PRC_BYTE
            jmp   N8_STORE
:ultra      lda   VC_ATTR
            beq   :storeut
            lda   PRC_BYTE
            ora   #$80                     ;bit 7 IS the inverse
                                           ;attribute here
            sta   PRC_BYTE
:storeut    ldx   TTY_DSTBASE+1
            bne   :utstore                 ;redirected: annex
                                           ;store, UT encoding
                                           ;kept for the blit
            ldx   VC_ROW
            ldy   VC_COL
            lda   PRC_BYTE
*-- VRAM only. The store is refreshed on switch-away (VCS_UTSAVE
*-- reads VRAM back), not per cell -- the window reads now.
            jmp   UT_PUT_CELL
:utstore    lda   VC_ROW
            jsr   TTY_ROW_DST_A
            ldy   VC_COL
            lda   PRC_BYTE
            jsr   TTY_STORE_Y
            rts

*---------------------------------------------------------------
* TTY_BLNK_CELL -- blank VC_ROW/VC_COL ignoring VC_ATTR.
* Erase is erase: a backspace or ESC [ K while inverse is set
* must leave a normal space, not an inverse block.
*---------------------------------------------------------------
TTY_BLNK_CELL
            ldx   TTY_DSTBASE+1
            bne   :store                   ;redirected: linear
                                           ;store whatever the
                                           ;glass backend (see
                                           ;TTY_WR_CELL's note;
                                           ;a UT store gets $A0
                                           ;not $20 -- accepted
                                           ;until the UT blit
                                           ;path is real)
            lda   TTY_BKND
            cmp   #TTY_BKUT
            beq   :ultra
            cmp   #TTY_BKN8
            beq   :n8
:store      lda   VC_ROW
            jsr   TTY_ROW_DST_A
            ldy   VC_COL
            lda   #$A0
            jsr   TTY_STORE_Y
            rts
:n8         lda   #$A0
            jmp   N8_STORE
:ultra      ldx   VC_ROW
            ldy   VC_COL
            lda   #$20
            jmp   UT_PUT_CELL              ;VRAM only (store via
                                          ;VCS_UTSAVE on switch)
