*---------------------------------------------------------------
* procfd2.s -- Open-file table and pipe helpers: OFT allocation
* and refcounting, pipe ring allocation, the interrupt-enabled
* MLI call wrappers, and the PRC_READ/PRC_WRITE syscall bodies
* (including K2's bulk pipe transfer, docs/PROCIO.md sec 3).
* Split out of procfd.s (task #8, docs/SELFHOST-CONVERSION.md
* phase 2) to keep each kernel module under 28000 bytes for
* compatibility with the maux assembler's shared symbol-table
* window. procfd.s keeps path/cwd helpers and the PCB/fd-table
* accessors this file's OFT/pipe code calls.
* Full design notes: K.PROCESS.TXT (docs/a2/)
*---------------------------------------------------------------

*---------------------------------------------------------------
* Open-file table and pipe helpers.
*---------------------------------------------------------------
PRC_ALLC_PIPE
            ldx   #1
:loop       cpx   #PIPE_COUNT+1
            beq   :none
            lda   PIPE_USED,x
            beq   :found
            inx
            bra   :loop
:found      txa
            sta   P_PIPE
            lda   #1
            sta   PIPE_USED,x
            lda   #0
            sta   PIPE_RDP,x
            sta   PIPE_WRP,x
            sta   PIPE_BYTES,x
            sta   PIPE_RREFS,x
            sta   PIPE_WREFS,x
            clc
            rts
:none       lda   #ERR_AGAIN
            jsr   PRC_FAIL_A
            sec
            rts

PALOBJ_R
            lda   #OFT_PIPE_R
            bra   PALOBJ_TYPED
PALOBJ_W
            lda   #OFT_PIPE_W
PALOBJ_TYPED
            sta   P_TMP
            ldx   #1
:loop       cpx   #OFT_COUNT
            beq   :none
            lda   OFT_TYPE,x
            beq   :found
            inx
            bra   :loop
:found      lda   P_TMP
            sta   OFT_TYPE,x
            lda   P_PIPE
            sta   OFT_PIPE,x
            tay
            lda   #1
            sta   OFT_REFCNT,x
            lda   P_TMP
            cmp   #OFT_PIPE_R
            bne   :w
            lda   PIPE_RREFS,y
            clc
            adc   #1
            sta   PIPE_RREFS,y
            bra   :ret
:w          lda   PIPE_WREFS,y
            clc
            adc   #1
            sta   PIPE_WREFS,y
:ret        txa
            clc
            rts
:none       lda   #ERR_AGAIN
            jsr   PRC_FAIL_A
            sec
            rts

PALOBJ_FILE
            ldx   #1
:loop       cpx   #OFT_COUNT
            beq   :none
            lda   OFT_TYPE,x
            beq   :found
            inx
            bra   :loop
:found      lda   #OFT_FILE
            sta   OFT_TYPE,x
            lda   #0
            sta   OFT_PIPE,x
            sta   LZ_OFTARM,x      ;not armed (lazyfree.s)
            lda   P_TMP
            sta   OFT_REFNUM,x
            lda   PRC_IOBUF_ID
            sta   OFT_IOBUF,x
            lda   #1
            sta   OFT_REFCNT,x
            txa
            clc
            rts
:none       lda   #ERR_NFILE
            jsr   PRC_FAIL_A
            sec
            rts

PRC_INC_OBJ_A
            cmp   #FD_DEV_BASE
            bcs   :done
            tax
            inc   OFT_REFCNT,x
            lda   OFT_PIPE,x
            tay
            lda   OFT_TYPE,x
            cmp   #OFT_PIPE_R
            bne   :w
            lda   PIPE_RREFS,y
            clc
            adc   #1
            sta   PIPE_RREFS,y
            rts
:w          cmp   #OFT_PIPE_W
            bne   :done
            lda   PIPE_WREFS,y
            clc
            adc   #1
            sta   PIPE_WREFS,y
:done       rts

PRC_DEC_OBJ
            lda   P_OBJ
            cmp   #FD_DEV_BASE
            bcc   :isobj
            rts                        ;a device fd -- no object
:isobj      ldx   P_OBJ
            lda   OFT_PIPE,x
            tay
            lda   OFT_TYPE,x
            cmp   #OFT_PIPE_R
            bne   :notr
            lda   PIPE_RREFS,y
            sec
            sbc   #1
            sta   PIPE_RREFS,y
            lda   PIPE_WREFS,y
            beq   :skipw
            tya
            clc
            adc   #PIPE_WR_CHAN
            jsr   SCH_WAKEUP
:skipw      bra   :dec
:notr       cmp   #OFT_PIPE_W
            bne   :dec
            lda   PIPE_WREFS,y
            sec
            sbc   #1
            sta   PIPE_WREFS,y
            tya
            clc
            adc   #PIPE_RD_CHAN
            jsr   SCH_WAKEUP
:dec        ldx   P_OBJ
            dec   OFT_REFCNT,x
            lda   OFT_REFCNT,x
            bne   :done
*-- PIPE SLOT RECLAIM (2026-08-21). PRC_ALLC_PIPE sets
*-- PIPE_USED and NOTHING ever cleared it again: the whole
*-- machine got PIPE_COUNT pipes per BOOT and then pipe()
*-- returned ERR_AGAIN forever, however many had since been
*-- closed. docs/SH-FEATURES.md sec 13 predicted exactly this
*-- shape ("monotonically growing consumption -- a leaked
*-- io_buffer or fd on some path -- not a fixed cap") and asked
*-- for the cheap discriminator. Measured 2026-08-21 with a
*-- script of N command substitutions: 1-8 succeeded, the 9th
*-- and every one after it failed, and a peek at the kernel
*-- showed OFT_TYPE/OFT_REFCNT/PIPE_RREFS/PIPE_WREFS ALL back
*-- to zero with PIPE_USED[1..8] still 1. That is PIPE_COUNT,
*-- not MLI_IOBUF_CNT -- the io_buffer theory in that section
*-- is refuted, not merely unproven.
*-- Placed HERE, on the "this OFT entry is being freed" path,
*-- and BEFORE the OFT_FILE branch below -- both file and pipe
*-- objects fall through this point, and only a pipe object has
*-- a nonzero OFT_PIPE. The slot goes free only when BOTH ends'
*-- reference counts are zero: the two ends own SEPARATE OFT
*-- entries, so this path is reachable with the other end still
*-- open. OFT_PIPE,x is read fresh rather than trusting Y --
*-- SCH_WAKEUP ran above and promises nothing about Y.
            lda   OFT_TYPE,x       ;OPEN-RO: a file's OFT_PIPE
            cmp   #OFT_FILE        ;is a flag byte, not a pipe
            bcs   :notpipe
            phx
            lda   OFT_PIPE,x
            tax
            lda   PIPE_RREFS,x
            ora   PIPE_WREFS,x
            bne   :stillref
            lda   #0
            sta   PIPE_USED,x
:stillref   plx
:notpipe
            lda   OFT_TYPE,x
            cmp   #OFT_FILE
            bne   :clear
*-- A PARKED file (OFT_IOBUF 0, see PRC_PARK_ONE) is already
*-- closed in ProDOS: nothing to close, nothing to free.
            lda   OFT_IOBUF,x
            beq   :clear
*-- OPEN-RO: a group shares one ProDOS file, hence one buffer
*-- id: a mate holding the same id keeps the refnum open.
            ldy   #OFT_COUNT-1
:mate       cpy   P_OBJ
            beq   :nomate
            cmp   OFT_IOBUF,y
            beq   :mated
:nomate     dey
            bne   :mate
            lda   OFT_REFNUM,x
            jsr   PCLS_RAWREF_A
            bcs   :qfail
            ldx   P_OBJ
            lda   OFT_IOBUF,x
            jsr   PRC_FR_IBF_A
            bra   :refx
*-- OPEN-RW-2: a failed final CLOSE QUARANTINES the page and the
*-- refnum (ProDOS may still own both): the entry goes, the page
*-- is never lent again, the leak is counted (K_QUAR_CNT), and
*-- the error is left in K_CLSERR for PRC_CLOSE.
:qfail      sta   K_CLSERR
            inc   K_QUAR_CNT
            bra   :refx
*-- ... and the WRITER leaving a group with mates left FLUSHes,
*-- so what it wrote is on the disk even if a mate never closes.
:mated      lda   OFT_PIPE,x
            bmi   :clear
            lda   OFT_REFNUM,x
            jsr   PRC_FLUSH_A
            bcc   :refx
            sta   K_CLSERR
:refx       ldx   P_OBJ
:clear
            lda   #0
            sta   OFT_TYPE,x
            sta   OFT_PIPE,x
            sta   OFT_REFNUM,x
            sta   OFT_IOBUF,x
            cpx   K_ROOWN          ;OPEN-RO: the holder is gone
            bne   :done
            sta   K_ROOWN
:done       rts

*---------------------------------------------------------------
* io_buffer LENDING (2026-09-07, docs/IOBUF-LENDING.md).
*
* The pool is MLI_IOBUF_CNT=6 buffers, kernel-wide (B1; 8 is
* ProDOS 8's own open-file ceiling, so it can never go higher).
* What happens when it is empty: PRC_ALLC_IBF
* PARKS the least-recently-used open file -- GET_MARK, CLOSE,
* release its buffer -- and the next read/write/seek on that
* file UNPARKS it: allocate (parking another if it must),
* OPEN the path saved at open time, SET_MARK. Every refnum
* consumer goes through PRC_OFT_REF, which is the whole
* contract: nothing else may read OFT_REFNUM directly.
*
* Per-slot store (OFT_SLOT_BASE, main memory above the xfer
* buffer, NOT in the image): 65 path bytes + 3 mark bytes.
* OFTF_PIN (OFT_PIPE) = PINNED, never a victim itself -- a path
* that stayed relative (no cwd recorded, PRC_ABSPATH) is pinned.
* Its slot still holds the CANONICAL path (prefix + path at open
* time) as its identity; length 0 = no identity.
*
* Semantics kept: ProDOS refuses a second OPEN, DESTROY or
* RENAME of an open file ($50); PRC_PARK_SAME makes a parked
* file refuse the same way, so nothing observable changes
* except that the ceiling is gone.
*
* Clobbers P_PTR3 throughout (unused elsewhere in the kernel).
*---------------------------------------------------------------

*-- PRC_ALLC_IBF -- A = buffer id (1-based), carry clear; or
*-- carry set + reported: ERR_NFILE when nothing is lendable,
*-- else the victim's own GET_MARK/CLOSE error (IB4).
PRC_ALLC_IBF
            ldx   #0
:loop       cpx   #MLI_IOBUF_CNT
            beq   :full
            lda   MLI_BUF_USED,x
            beq   :found
            inx
            bra   :loop
:found      lda   #1
            sta   MLI_BUF_USED,x
            inc   K_IBF_INUSE
            lda   K_IBF_INUSE
            cmp   K_IBF_HIWAT
            bcc   :nohw
            sta   K_IBF_HIWAT
:nohw       txa
            inc
            clc
            rts
:full       jsr   PRC_PARK_ONE
            bcc   PRC_ALLC_IBF
            tax                        ;A=0: nothing lendable
            bne   :evict               ;else a real eviction
            lda   #ERR_NFILE           ;error (GET_MARK/CLOSE)
:evict      jsr   PRC_FAIL_A           ;-- IB4: never flattened
            sec                        ;into ERR_NFILE
            rts

PRC_FR_IBF_A
            beq   :done
            sec
            sbc   #1
            tax
            lda   #0
            sta   MLI_BUF_USED,x
            dec   K_IBF_INUSE
:done       rts

*-- PRC_OFT_SLOTP -- P_PTR3 = OFT_SLOT_BASE + X*OFT_SLOT_SZ.
*-- X preserved.
PRC_OFT_SLOTP
            lda   #<OFT_SLOT_BASE
            sta   P_PTR3
            lda   #>OFT_SLOT_BASE
            sta   P_PTR3+1
            phx
:add        cpx   #0
            beq   :done
            clc
            lda   P_PTR3
            adc   #OFT_SLOT_SZ
            sta   P_PTR3
            bcc   :nc
            inc   P_PTR3+1
:nc         dex
            bra   :add
:done       plx
            rts

*-- PRC_CANONPATH -- PRC_CANON := the ABSOLUTE form of
*-- PRC_PATHBUF slot 0, exactly as the MLI will resolve it:
*-- copied if it already starts with '/', else ProDOS's own
*-- current prefix (GET_PREFIX -- what the MLI prepends itself)
*-- + the path. OUT: carry clear, PRC_CANLEN = length; carry
*-- set, PRC_CANLEN = 0 when it cannot be made canonical (an
*-- EMPTY path, no prefix set, or the result would pass 64) --
*-- callers treat that identity as UNKNOWN. Clobbers A, X, Y.
*-- Never touches PRC_PARM (GET_PREFIX has its own PML_GPFX2).
*--
*-- THE EMPTY-PATH GUARD IS LOAD-BEARING, and it was missing
*-- until 2026-09-16. A zero-length slot is legal here -- bare
*-- `cd` is exactly that (PRC_SETPFX reads PRC_PATHBUF and
*-- branches on 0), and PCPY_PATH_G bounds the length only from
*-- ABOVE -- so byte +1 is then the PREVIOUS call's leftover,
*-- and the branch below was chosen by stale data. Worse, when
*-- that leftover happened to be '/' the absolute arm returned
*-- carry CLEAR with PRC_CANLEN = 0, and a zero-length identity
*-- compares unequal to every saved path (PRC_FILE_BUSY's
*-- `cmp PRC_CANLEN`), so the open-file guard reported NOT BUSY
*-- and the allocator was free to park a victim for an open that
*-- could never succeed. An empty path has no identity: say so
*-- with the carry, the way the header always claimed, and let
*-- :unknown's fail-safe decide. PRC_ABSPATH (procfd.s) has
*-- tested its own length byte first all along; this is the same
*-- test in the routine that forgot it.
PRC_CANONPATH
            stz   PRC_CANLEN
            lda   PRC_PATHBUF
            beq   :cant
            lda   PRC_PATHBUF+1
            cmp   #"/"+$80
            bne   :rel
            ldx   #0
:cpabs      lda   PRC_PATHBUF,x
            sta   PRC_CANON,x
            cpx   PRC_PATHBUF
            beq   :absdone
            inx
            bra   :cpabs
:absdone    lda   PRC_PATHBUF
            sta   PRC_CANLEN
            bra   :trim
:rel        jsr   PMLI_GPFX2_CL        ;PRC_CANON := prefix
            bne   :cant
            ldx   PRC_CANON            ;prefix length
            beq   :cant                ;no prefix set
*-- GET_PREFIX ALWAYS ends the prefix in '/': the P8 TRM says
*-- the returned prefix is "preceded by a length byte and
*-- bracketed by slashes" ($7/APPLE/, $D/APPLE/BYTES/). A guard
*-- that appended one when missing (7 instructions, 16 B) was
*-- read by none of 51 gates nor any raw-boot image
*-- (docs/KGAPS-NOTES.md): dead on a conforming ProDOS, deleted.
            txa
            clc
            adc   PRC_PATHBUF          ;prefix + path
            cmp   #65
            bcs   :cant
            sta   PRC_CANLEN
            ldy   #0
:app        cpy   PRC_PATHBUF
            beq   :appdone
            iny
            inx
            lda   PRC_PATHBUF,y
            sta   PRC_CANON,x
            bra   :app
:appdone    lda   PRC_CANLEN
            sta   PRC_CANON
*-- ProDOS drops an empty final component, so `G/` names G: the
*-- identity has no trailing '/' (the root "/" keeps its one).
:trim       ldx   PRC_CANLEN
            lda   PRC_CANON,x
            cmp   #"/"+$80
            bne   :ok
            dex
            beq   :ok
            stx   PRC_CANLEN
            stx   PRC_CANON
:ok         clc
            rts
:cant       stz   PRC_CANLEN
            sec
            rts

*-- PRC_ANYPARKED -- carry set if any OFT_FILE entry is parked
*-- (OFT_IOBUF 0). Clobbers A, X.
PRC_ANYPARKED
            ldx   #1
:s          cpx   #OFT_COUNT
            beq   :no
            lda   OFT_TYPE,x
            cmp   #OFT_FILE
            bne   :n
            lda   OFT_IOBUF,x
            beq   :yes
:n          inx
            bra   :s
:yes        sec
            rts
:no         clc
            rts

*-- PRC_OFT_SETP -- X = freshly allocated OFT_FILE slot. Record
*-- the open's CANONICAL path (PRC_CANON, which PRC_OPEN's
*-- PRC_FILE_FIND has just computed for THIS path and nothing
*-- since has touched: an absolute path as typed, a relative one
*-- as ProDOS's prefix + the path) as the entry's identity; len
*-- 0 if it could not be made canonical (no prefix, too long).
*-- A RELATIVE open is also PINNED -- OFTF_PIN: never a park
*-- victim ITSELF. HEAD's rule, kept deliberately: making
*-- relatively-opened files parkable regressed the deep nested-
*-- shell case, whose actively-read fds must stay resident.
*-- (A pinned entry that shares a group is parked WITH it, and
*-- reopens by its canonical path: the saved identity is real.)
*-- OAPPEND-1: the identity is recorded for a pinned entry too.
*-- Without it a process that never cd'd (relative LOG) was
*-- invisible to the admission scan, so its second `>>`, or a
*-- reader beside its writer, drew ProDOS's $50, not a join.
*-- IB2 (a relative alias of a parked file) is caught the other
*-- way, in PRC_FILE_BUSY, which canonicalises the INCOMING path
*-- before comparing. Stamps the LRU. X preserved.
PRC_OFT_SETP
            jsr   PRC_OFT_SLOTP
            ldy   #0
:cp         lda   PRC_CANON,y
            sta   (P_PTR3),y
            iny
            cpy   #OFT_SLOT_MRK
            bne   :cp
            lda   PRC_CANLEN       ;0: no identity, the copy
            sta   (P_PTR3)         ;above was junk
            lda   PRC_PATHBUF+1
            cmp   #"/"+$80
            beq   :stamp
            lda   OFT_PIPE,x
            ora   #OFTF_PIN
            sta   OFT_PIPE,x
:stamp      ldy   #OFT_SLOT_MRK    ;OPEN-RO: a joiner starts at
            lda   #0               ;mark 0
            sta   (P_PTR3),y
            iny
            sta   (P_PTR3),y
            iny
            sta   (P_PTR3),y
            lda   K_FTICK
            sta   OFT_LRU,x
            inc   K_FTICK
            rts
*-- PRC_OFT_REF -- X = OFT index of an OFT_FILE entry. Makes it
*-- resident (unparking if needed), stamps the LRU, and returns
*-- A = its ProDOS refnum with carry clear. Carry set: the
*-- reopen failed and PRC_FAIL_A has already reported why. X
*-- preserved either way.
PRC_OFT_REF
            jsr   PRC_OFT_RES
            bcs   :ret
            lda   OFT_PIPE,x       ;OPEN-RO: a shared group's
            and   #OFTF_MG         ;mark is swapped in first
            bne   PRC_ROACQ
            lda   OFT_REFNUM,x
            clc
:ret        rts

*-- PRC_OFT_RES -- PRC_OFT_REF WITHOUT the mark acquire
*-- (OPEN-RW-2): resident, LRU stamped, A = the shared refnum,
*-- carry clear; or carry set, reported. For a call that needs
*-- the FCB but no member's mark: GET_EOF (an FCB value) and
*-- SET_MARK (it replaces the mark, so it must not load a
*-- virtual one first).
PRC_OFT_RES
            lda   K_FTICK
            sta   OFT_LRU,x
            inc   K_FTICK
            lda   OFT_IOBUF,x
            bne   :res
            jsr   PRC_UNPARK
            bcs   :ret
:res        lda   OFT_REFNUM,x
            clc
:ret        rts

*-- OPEN-RO. A shared group is the entries of one path that were
*-- opened with read intent: one ProDOS refnum, one buffer id,
*-- one mark in ProDOS. Every member keeps its own mark in its
*-- slot store (OFT_SLOT_MRK) EXCEPT the one named by K_ROOWN,
*-- whose live mark is in ProDOS. PRC_ROACQ makes X the holder:
*-- save the old holder's mark, load X's. X in; A = refnum,
*-- carry clear out; or carry set, reported. X preserved.
PRC_ROACQ
            cpx   K_ROOWN
            beq   :have
            jsr   PRC_ROSAVE
            bne   :err
            ldx   PRC_ROX
            lda   OFT_REFNUM,x
            jsr   PRC_MARK_LOAD
            bne   :err
            ldx   PRC_ROX
            stx   K_ROOWN
:have       lda   OFT_REFNUM,x
            clc
            rts
:err        ldx   PRC_ROX
            jsr   PRC_FAIL_A
            sec
            rts

*-- PRC_ROSAVE -- X = the entry about to become the holder:
*-- PRC_ROX := X, and the current holder's live mark (if any)
*-- goes to its slot. A = MLI error, Z set = ok. Clobbers X, Y.
PRC_ROSAVE
            stx   PRC_ROX
            ldx   K_ROOWN
            bne   PRC_MARK_SAVE
            txa
            rts

*-- PRC_OFT_REFW -- PRC_OFT_REF for a caller about to WRITE or
*-- SET_EOF (X = an OFT_FILE entry). An entry opened with read
*-- intent is refused: carry set, MLIE_ACCESS reported, nothing
*-- reaches ProDOS. X preserved.
PRC_OFT_REFW
            lda   OFT_PIPE,x
            asl   a
            bcs   :ro
            and   #$40             ;OAPPEND-1: was OFTF_AP ($20)
            beq   PRC_OFT_REF
            bra   PRC_APPSEEK      ;append intent: seek to EOF
:ro         lda   #MLIE_ACCESS
            jsr   PRC_FAIL_A
            sec
            rts

*-- PRC_APPSEEK -- OAPPEND-1: the per-write half of O_APPEND.
*-- X = a writable OFT_FILE entry with OFTF_AP. Makes it
*-- resident (PRC_OFT_RES: LRU stamped, NO mark load), then puts
*-- the shared FCB's mark at the file's CURRENT EOF: GET_EOF,
*-- SET_MARK(EOF). Every carry checked and reported
*-- (learning:01M3PMQ72TCBDCCECQAQ66JN1S). A = the refnum,
*-- carry clear; or carry set, reported. X preserved.
*--
*-- WHY NOT PRC_ROACQ. A group member's acquire loads its SAVED
*-- mark, and an appender's saved mark can be past the EOF
*-- (virtual after a truncate, or stale after an unpark): the
*-- acquire alone would die $4D before GET_EOF ran. So: save the
*-- current holder's mark if it is another member (PRC_ROSAVE;
*-- the appender's own saved mark is NEVER loaded), then
*-- GET_EOF, SET_MARK(EOF), and ONLY THEN publish K_ROOWN =
*-- this entry
*-- (a failed step leaves the old holder named: a failed
*-- SET_MARK leaves the mark where it was, learning
*-- 01M5GC9KBF31WTHJ9533B30A3H). The appender's slot store stays
*-- stale by the standing invariant: its LIVE mark is in ProDOS
*-- and a later ROSAVE copies it out. A solo (non-group) entry
*-- owns its FCB outright and is never named in K_ROOWN.
*--
*-- ATOMIC, WITHOUT A LOCK: nothing below blocks. Each MLI call
*-- runs under K_NOSWITCH (procmli.s PMLI_*_CL: set, cli, MLI,
*-- sei, clear); between calls the syscall is masked (ffpage.s
*-- sei); and the main-context IRQ path that can fire inside the
*-- bracket never calls SCH_TICK (timer.s MAIN_IRQ_SHIM header:
*-- "NO SCH_TICK from here"). No other process runs between the
*-- GET_EOF and the WRITE that follows in the same syscall.
PRC_APPSEEK
            jsr   PRC_OFT_RES
            bcs   :ret
            sta   PML_GTF_PARMS+MLI_REF
            sta   PML_SMARK_PRM+MLI_REF
            phx                    ;the MLI calls clobber X
            lda   OFT_PIPE,x
            and   #OFTF_MG
            beq   :seek            ;solo: its own FCB
            cpx   K_ROOWN
            beq   :seek            ;already the holder
            jsr   PRC_ROSAVE
            bne   :err
:seek       jsr   PMLI_GTF_CALL
            bne   :err
            ldy   #2
:eof        lda   PML_GTF_PARMS+MLI_EOFLO,y
            sta   PML_SMARK_PRM+MLI_EOFLO,y
            dey
            bpl   :eof
            jsr   PMLI_SMARK_CL
            bne   :err
            plx
            lda   OFT_PIPE,x
            and   #OFTF_MG
            beq   :solo
            stx   K_ROOWN
:solo       lda   OFT_REFNUM,x
            clc
:ret        rts
:err        plx
            jsr   PRC_FAIL_A
            sec
            rts

*-- PRC_MARK_SAVE -- X = a resident OFT_FILE entry: GET_MARK its
*-- refnum into its slot store. A = MLI error, Z set = ok.
*-- Clobbers X, Y.
PRC_MARK_SAVE
            jsr   PRC_OFT_SLOTP    ;P_PTR3 survives the MLI call
            lda   OFT_REFNUM,x
            sta   PML_GMARK_PRM+MLI_REF
            jsr   PMLI_GMARK_CL
            bne   :ret
            ldy   #OFT_SLOT_MRK
:m          lda   PML_GMARK_PRM+MLI_EOFLO-OFT_SLOT_MRK,y
            sta   (P_PTR3),y
            iny
            cpy   #OFT_SLOT_MRK+3
            bne   :m
            lda   #0
:ret        rts

*-- PRC_MARK_LOAD -- A = a refnum, X = an OFT_FILE entry:
*-- SET_MARK the refnum to X's slot-store mark. A = MLI error,
*-- Z set = ok. Clobbers X, Y.
PRC_MARK_LOAD
            sta   PML_SMARK_PRM+MLI_REF
            jsr   PRC_OFT_SLOTP
            ldy   #OFT_SLOT_MRK
:m          lda   (P_PTR3),y
            sta   PML_SMARK_PRM+MLI_EOFLO-OFT_SLOT_MRK,y
            iny
            cpy   #OFT_SLOT_MRK+3
            bne   :m
            jmp   PMLI_SMARK_CL

*-- PRC_UNPARK -- X = a parked OFT_FILE entry. Get a buffer,
*-- reopen the saved path, restore the saved mark. The entry
*-- becomes resident (OFT_IOBUF/OFT_REFNUM set) ONLY once
*-- SET_MARK has succeeded: a reopen whose mark could not be
*-- restored is closed again and the entry stays parked, so no
*-- later access can silently run at position 0 (IB5). Carry
*-- set on failure, reported. X preserved.
PRC_UNPARK
            stx   PRC_LENDX
            jsr   PRC_ALLC_IBF
            bcs   :fail
            sta   PRC_UNPKID
            jsr   PRC_IBF_HI_A
            sta   PML_UNPK_PRM+MLI_IOBUFHI
            stz   PML_UNPK_PRM+MLI_IOBUFLO
            ldx   PRC_LENDX
            jsr   PRC_OFT_SLOTP
            lda   P_PTR3
            sta   PML_UNPK_PRM+MLI_PATHLO
            lda   P_PTR3+1
            sta   PML_UNPK_PRM+MLI_PATHHI
            jsr   PMLI_UNPK_CL
            beq   :opened
            pha                        ;the MLI error
            lda   PRC_UNPKID
            jsr   PRC_FR_IBF_A
            pla
            jsr   PRC_FAIL_A
            sec
            bra   :fail
:opened     lda   PML_UNPK_PRM+MLI_OPEN_REF
            ldx   PRC_LENDX
            jsr   PRC_MARK_LOAD
            beq   :ok
            cmp   #MLIE_RANGE          ;OPEN-RW-2: a member's
            bne   :mfail               ;mark above the live EOF
            ldx   PRC_LENDX            ;(file shrank below it)
            bit   OFT_PIPE,x           ;is VIRTUAL: it stays in
            bvs   :ok                  ;the slot, reopen at 0
:mfail      pha                        ;the SET_MARK error
            lda   PML_UNPK_PRM+MLI_OPEN_REF
            jsr   PCLS_RAWREF_A        ;back to parked -- but if
            bcc   :freed               ;this CLOSE ALSO fails,
            inc   K_QUAR_CNT          ;LEAK the buffer (counted:
            bra   :leaked              ;OPEN-RW-2) rather than
:freed      lda   PRC_UNPKID           ;free a page ProDOS still
            jsr   PRC_FR_IBF_A         ;owns and re-lend it to a
                                       ;second open (F4). The
                                      ;entry stays parked either
                                      ;way; a later unpark takes
                                       ;a fresh buffer.
:leaked     pla
            jsr   PRC_FAIL_A
            sec
            bra   :fail
:ok         ldx   PRC_LENDX
            lda   PML_UNPK_PRM+MLI_OPEN_REF
            sta   OFT_REFNUM,x
            lda   PRC_UNPKID
            sta   OFT_IOBUF,x
            lda   OFT_PIPE,x
            and   #OFTF_MG
            beq   :solo
            jsr   PRC_ROMATES
:solo       clc
:fail       ldx   PRC_LENDX
            rts

*-- PRC_ROMATES -- PRC_LENDX is a shared-group entry that is now
*-- resident: every other entry of its path is its mate, parked
*-- with it, and takes the same refnum and buffer id. Clobbers
*-- PRC_CANON (the caller's scan is over by now).
PRC_ROMATES
            ldx   PRC_LENDX
            jsr   PRC_OFT_SLOTP
            ldy   #0
            lda   (P_PTR3)
            sta   PRC_CANLEN
:cp         lda   (P_PTR3),y
            sta   PRC_CANON,y
            iny
            cpy   PRC_CANLEN
            bcc   :cp
            beq   :cp
            ldx   #1
:next       jsr   PRC_FIND_FROM
            bcc   :done
            cpx   PRC_LENDX
            beq   :skip
            ldy   PRC_LENDX
            lda   OFT_REFNUM,y
            sta   OFT_REFNUM,x
            lda   OFT_IOBUF,y
            sta   OFT_IOBUF,x
:skip       inx
            bra   :next
:done       rts

*-- PRC_PARK_ONE -- park the least-recently-used resident,
*-- unpinned OFT_FILE entry. Carry clear = one buffer freed.
*-- Carry set + A = 0: no victim. Carry set + A = MLI error:
*-- the victim's GET_MARK or CLOSE failed -- the victim is left
*-- exactly as it was, resident and open, and the error is the
*-- caller's to report (IB4: a failed CLOSE is not a park).
*-- Clobbers X.
PRC_PARK_ONE
            stz   PRC_VICT
            stz   PRC_VAGE
            ldx   #1
:scan       cpx   #OFT_COUNT
            beq   :scanned
            lda   OFT_TYPE,x
            cmp   #OFT_FILE
            bne   :next
            lda   OFT_IOBUF,x
            beq   :next
            lda   OFT_PIPE,x           ;pinned (relative open):
            and   #OFTF_PIN            ;never a victim
            bne   :next
            lda   K_FTICK
            sec
            sbc   OFT_LRU,x
            cmp   PRC_VAGE
            bcc   :next                ;younger than the pick
            sta   PRC_VAGE
            stx   PRC_VICT
:next       inx
            bra   :scan
:scanned    ldx   PRC_VICT
            beq   :none
*-- OPEN-RO: the whole group parks with its victim. Whose mark
*-- is live in ProDOS? A lone entry's own; a group's, K_ROOWN's
*-- if it is one of this file's (the rest are in their slots
*-- already).
            lda   OFT_PIPE,x
            and   #OFTF_MG
            beq   :save
            lda   OFT_IOBUF,x
            ldy   K_ROOWN
            beq   :close
            cmp   OFT_IOBUF,y
            bne   :close
            ldx   K_ROOWN
:save       jsr   PRC_MARK_SAVE
            bne   :err
:close      ldx   PRC_VICT
            lda   OFT_REFNUM,x
            jsr   PCLS_RAWREF_A
            bcs   :err                 ;CLOSE failed: not parked
            ldx   PRC_VICT
            lda   OFT_IOBUF,x
            sta   PRC_VAGE
            jsr   PRC_FR_IBF_A
            ldx   #OFT_COUNT-1
:unbuf      lda   OFT_IOBUF,x          ;all on this buffer
            cmp   PRC_VAGE
            bne   :unext
            stz   OFT_IOBUF,x
            cpx   K_ROOWN
            bne   :unext
            stz   K_ROOWN
:unext      dex
            bne   :unbuf
            inc   K_PARK_CNT
            bne   :nowrap              ;saturate at 255, never
            dec   K_PARK_CNT           ;wrap to a false zero
:nowrap     clc
            rts
:none       lda   #0
:err        sec
            rts

*-- PRC_FILE_BUSY -- does PRC_PATHBUF (slot 0) name a file that
*-- is OPEN anywhere on the machine, resident OR parked?
*-- Canonical absolute paths compared, case-folded, against
*-- every OFT_FILE entry's saved identity. Carry set +
*-- MLIE_FILOPEN reported on a match. ProDOS refuses a second
*-- OPEN/DESTROY/RENAME of an open file with $50; a parked file
*-- is closed in ProDOS, so the kernel refuses on its behalf --
*-- and a RESIDENT match is refused HERE as well, so the
*-- allocator can never park the very file being opened and let
*-- the second open through (IB1). An incoming path whose
*-- identity cannot be made canonical is refused whenever
*-- anything is parked (IB2's unknown-identity rule). Leaves
*-- PRC_CANON/PRC_CANLEN for PRC_ANCESTBSY.
*--
*-- ACCEPTED GAP (over-refusal, fail-safe): PRC_CANONPATH gives
*-- up (:unknown) when there is no ProDOS prefix or the absolute
*-- form would pass 64 chars. Rather than let an unverifiable
*-- identity through, :unknown refuses the open if ANYTHING is
*-- parked -- so a legitimately distinct long/prefixless
*-- relative open can be refused $50 while lending is active.
*-- This is a false POSITIVE (safe: it never aliases a parked
*-- file), it fires only under park pressure, and the caller
*-- can retry once buffers free. Chosen over the alternative:
*-- reopening the parked victim just to compare, which would
*-- defeat lending.
PRC_FILE_BUSY
            jsr   PRC_FILE_FIND
            bcc   :ok
            lda   #MLIE_FILOPEN
            jsr   PRC_FAIL_A
            sec
:ok         rts

*-- PRC_FILE_FIND -- the scan, unreported. Carry set = busy, X =
*-- the matching OFT entry (0: identity unknown, something
*-- parked). PRC_FIND_FROM resumes at X (PRC_ROMATES walks every
*-- entry of one path, PRC_CANON loaded by its caller).
PRC_FILE_FIND
            jsr   PRC_CANONPATH
            bcc   :go
            jsr   PRC_ANYPARKED    ;unknown identity: busy iff
            ldx   #0               ;anything is parked
            rts
:go         ldx   #1
PRC_FIND_FROM
:scan       cpx   #OFT_COUNT
            beq   :nomatch
            lda   OFT_TYPE,x
            cmp   #OFT_FILE
            bne   :next
            jsr   PRC_OFT_SLOTP
            lda   (P_PTR3)
            beq   :next                ;pinned, no identity
            cmp   PRC_CANLEN
            bne   :next
            tay                        ;compare len..1
:cmp        lda   (P_PTR3),y
            ora   #$20
            sta   PRC_VAGE
            lda   PRC_CANON,y
            ora   #$20
            cmp   PRC_VAGE
            bne   :next
            dey
            bne   :cmp
            beq   :match
:next       inx
            bra   :scan
:nomatch    clc
            rts
:match      sec
            rts

*-- PRC_ANCESTBSY -- is PRC_CANON (the RENAME's OLD path, as
*-- PRC_FILE_BUSY just left it) an ANCESTOR directory of any
*-- open file's saved identity? Renaming it would orphan every
*-- descendant's reopen path, parked or not (IB3): refuse with
*-- $50. A trailing '/' on the old path is ignored. An unknown
*-- identity is refused whenever anything is parked.
*--
*-- A file opened RELATIVELY is PINNED (OFTF_PIN) and, since
*-- OAPPEND-1, carries its canonical identity too (length 0 only
*-- if it could not be made canonical, and then this scan cannot
*-- see it: ProDOS still holds its refnum and enforces its own
*-- open-file rules on the subtree).
PRC_ANCESTBSY
            ldx   PRC_CANLEN
            beq   :unknown
            dex                        ;(CANONPATH dropped any
            beq   :unknown             ;trailing '/'): the old
                                       ;path was just "/": no
                                       ;ancestor (F6)
            ldx   #1
:scan       cpx   #OFT_COUNT
            beq   :nomatch
            lda   OFT_TYPE,x
            cmp   #OFT_FILE
            bne   :next
            jsr   PRC_OFT_SLOTP
            lda   (P_PTR3)             ;saved length L
            beq   :next
            cmp   PRC_CANLEN           ;need L > C
            bcc   :next
            beq   :next
            ldy   PRC_CANLEN
            iny
            lda   (P_PTR3),y           ;saved[C+1] must be '/'
            cmp   #"/"+$80
            bne   :next
            ldy   PRC_CANLEN
:cmp        lda   (P_PTR3),y
            ora   #$20
            sta   PRC_VAGE
            lda   PRC_CANON,y
            ora   #$20
            cmp   PRC_VAGE
            bne   :next
            dey
            bne   :cmp
            beq   :match
:next       inx
            bra   :scan
:unknown    jsr   PRC_ANYPARKED
            bcs   :match
:nomatch    clc
            rts
:match      lda   #MLIE_FILOPEN
            jsr   PRC_FAIL_A
            sec
            rts

PRC_IBF_HI_A
            sec
            sbc   #1
            asl   a
            asl   a
            clc
            adc   #>PMLI_IBF_BASE
            rts

PCLS_RAWREF_A
            sta   PML_CLS_PARMS+MLI_REF
            jsr   PMLI_CLS_CALL
            rts

*-- PRC_FLUSH_A -- A = a refnum: MLI FLUSH. Carry + A = error.
PRC_FLUSH_A
            sta   PML_CLS_PARMS+MLI_REF
            jmp   PMLI_FLSH_CL

PRC_RET_MLI_A
            beq   :ok
            jsr   PRC_FAIL_A
            rts
:ok         jsr   PRC_RET_OK0
            rts
