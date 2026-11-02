*---------------------------------------------------------------
* plasmald.s -- plasma's loader: MILESTONE 2 -- loads the FIXED
* runtime path /mnt/MAUX/PLASMA/RT (not argv[1]) into $2000, raw
* syscalls (Y=call#, A/X=parmlist, JSR $FF00, carry=error -- the
* proshimcr.s PS_GATE convention), the OPEN/READ/CLOSE/brk
* sequence that stages the module, and the hand-off into the
* interpreter via the "JSR PLVM_IINTRP / da addr" def-thunk
* shape (built in bss, invoked with a real `jsr`, targeting the
* $0806 ABI slot, not the IINTRP label directly). put by
* plasma.s after plasmaop.s.
*
* argv is left INTACT at $0200 -- the seed never consumes
* argv[1] now (M1 did); rt's own init reads argc()/argv() itself
* (docs/PLASMA-PORT.md M2). The ARGC<2 usage check stays: it
* saves loading rt at all when there is nothing to run.
*
* PCNT_*/TENANT are hand-rolled here rather than pulled from
* inc/mli.equ -- the seed is liba-free (task spec: "no liba
* modules, only the inc/*.equ files").
*---------------------------------------------------------------
TENANT      equ   $2000            ;module load addr = heap base
PCNT_OPEN   equ   3
PCNT_READ   equ   4
PCNT_WRITE  equ   4
PCNT_CLOSE  equ   1

START       jsr   INITPARMS
*-- cooked image (docs/PLASCUT.md, plasma.s CKFLAG): rt and the
*-- modules are already in the image, relocated and bound. No
*-- usage check (the cooked program owns its argv), no rt load:
*-- the initial break is CKEND (the cooked image's end), then
*-- the same VM env + JMP $2000 the loaded path takes.
            lda   CKFLAG
            beq   :seedpath
            lda   CKEND
            sta   BUFPTR
            lda   CKEND+1
            sta   BUFPTR+1
            jmp   :brkimg
:seedpath   lda   PRC_ARGV_HDR     ;argc
            cmp   #2
            bcs   :haveargs
            lda   #<USAGEMSG
            ldx   #>USAGEMSG
            jsr   PRINTERR
            lda   #2
            jmp   DOEXIT
:haveargs

* -- brk(SET, TENANT): a break must exist before it can grow --
            lda   #<TENANT
            sta   BRKPARM
            lda   #>TENANT
            sta   BRKPARM+1
            lda   #<BRKPARM
            ldx   #>BRKPARM
            ldy   #SYS_BRK
            jsr   $FF00
            bcc   :brkok
            lda   #<MSG_BRK
            ldx   #>MSG_BRK
            jsr   PRINTERR
            lda   #1
            jmp   DOEXIT
:brkok

* -- OPEN the module -- OPARM/OPARM_PATH/OPARM_IOBUF are already
* -- constant (INITPARMS) --
            lda   #<OPARM
            ldx   #>OPARM
            ldy   #SYS_OPEN
            jsr   $FF00
            bcc   :openok
            lda   #<MSG_OPEN
            ldx   #>MSG_OPEN
            jsr   PRINTERR
            lda   #1
            jmp   DOEXIT
:openok     lda   OPARM_REF
            sta   RPARM_REF
            sta   CPARM_REF

* -- rt is a FLAT self-linking binary (built -AOW --setpc 8192):
* -- no length word, no $6502 header -- it begins with JMP _INIT
* -- at $2000. Read the whole file straight to $2000 and JMP
* -- there; rt's own defs are inline `JSR INTERP` thunks acme
* -- resolved, so the bootstrap module needs no loadmod. --
            bra   :rdstart
:rderr      lda   #<MSG_READ
            ldx   #>MSG_READ
            jsr   PRINTERR
            lda   #1
            jmp   DOEXIT
:rdstart    lda   #<TENANT
            sta   BUFPTR
            lda   #>TENANT
            sta   BUFPTR+1
:rdloop     lda   BUFPTR
            sta   RPARM_BUF
            lda   BUFPTR+1
            sta   RPARM_BUF+1
            stz   RPARM_REQ
            lda   #$08
            sta   RPARM_REQ+1       ;req = $0800
            lda   #<RPARM
            ldx   #>RPARM
            ldy   #SYS_READ
            jsr   $FF00
            bcs   :rderr
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :rddone           ;trans==0 -> eof
            clc
            lda   BUFPTR
            adc   RPARM_TRANS
            sta   BUFPTR
            lda   BUFPTR+1
            adc   RPARM_TRANS+1
            sta   BUFPTR+1
            lda   RPARM_TRANS+1
            cmp   #$08
            bcc   :rddone           ;trans<req: short read, eof
            bra   :rdloop           ;trans==req($0800) -> more
:rddone

* -- CLOSE (best-effort -- nothing to do if it fails) --
            lda   #<CPARM
            ldx   #>CPARM
            ldy   #SYS_CLOSE
            jsr   $FF00

* -- brk(SET, BUFPTR) -- BUFPTR is already TENANT+total, so this
* -- covers exactly the loaded module (or, cooked, CKEND). --
:brkimg     lda   BUFPTR
            sta   BRKPARM
            lda   BUFPTR+1
            sta   BRKPARM+1
            lda   #<BRKPARM
            ldx   #>BRKPARM
            ldy   #SYS_BRK
            jsr   $FF00
            bcc   :brk2ok
            lda   #<MSG_BRK
            ldx   #>MSG_BRK
            jsr   PRINTERR
            lda   #1
            jmp   DOEXIT
:brk2ok

* -- VM env (cmdstub.s 36-44 / plvm02.s 207-216): copy the ZP
* -- inner-loop template to $EF, arm JMPTMP's self-mod JMP,
* -- IFP=$2000 (grows DOWN into the frame region below $2000),
* -- eval-stack index in X. Then JMP $2000: rt begins with a
* -- JMP _INIT and its defs are inline JSR INTERP thunks (acme-
* -- self-linked, -AOW), so control needs no def table. --
            ldy   #TMPLEN-1
:tcopy      lda   INNERTMP,y
            sta   DROP,y
            dey
            bpl   :tcopy
            lda   #$4C
            sta   JMPTMP
            stz   IFPL
            lda   #>TENANT
            sta   IFPH
            ldx   #ESTKHALF
            jmp   TENANT
            jmp   DOEXIT

*---------------------------------------------------------------
* PRINTERR -- write a NUL-terminated, high-bit-set message (IN:
* A/X = address) to fd 2, looping on partial writes (cat.s's
* WRITE_ALL shape). The NUL is the length terminator, not part
* of the write; the message's own trailing $8D is.
*---------------------------------------------------------------
PRINTERR    sta   LDPTR
            stx   LDPTR+1
            ldy   #$00
:len        lda   (LDPTR),y
            beq   :havelen
            iny
            bne   :len
:havelen    sty   WPARM_REQ
            stz   WPARM_REQ+1
            lda   LDPTR
            sta   WPARM_BUF
            lda   LDPTR+1
            sta   WPARM_BUF+1
:wr         lda   WPARM_REQ
            ora   WPARM_REQ+1
            beq   :wrdone
            lda   #<WPARM
            ldx   #>WPARM
            ldy   #SYS_WRITE
            jsr   $FF00
            bcs   :wrdone           ;write error -- stop, v1
            lda   WPARM_TRANS
            ora   WPARM_TRANS+1
            beq   :wrdone           ;defensive: avoid a hang
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
            bra   :wr
:wrdone     rts

*---------------------------------------------------------------
* DOEXIT -- exit(status). IN: A = status. Does not return.
* 8-byte parmlist, status at [0] (syscalls.s SC_EXIT's own
* PROCPARM shape) -- only byte 0 is read by the kernel
* (src/kernel/process2.s PRC_EXIT: `lda #1 / jsr PCPI_CALLPARM`)
* but the 8-byte reservation matches the house convention.
*---------------------------------------------------------------
DOEXIT      sta   EXITPARM
            lda   #<EXITPARM
            ldx   #>EXITPARM
            ldy   #SYS_EXIT
            jsr   $FF00
:hang       jmp   :hang

*---------------------------------------------------------------
* Messages -- "plasma: <msg>" + CR, high-bit ASCII (`asc`), NUL-
* terminated for PRINTERR's own length scan. Usage carries no
* "plasma: " prefix per the milestone spec's own wording.
*---------------------------------------------------------------
USAGEMSG    asc   "usage: plasma MODULE"
            dfb   $8D,$00
MSG_BRK     asc   "plasma: brk failed"
            dfb   $8D,$00
MSG_OPEN    asc   "plasma: cannot open"
            dfb   $8D,$00
MSG_READ    asc   "plasma: read error"
            dfb   $8D,$00
MSG_MAGIC   asc   "plasma: not a PLASMA module"
            dfb   $8D,$00

* -- the fixed runtime path (MLI shape: count byte + 7-bit
* -- chars, NOT high-bit-set, NOT NUL-terminated -- mli.equ's
* -- own pathname shape). Single-quoted `asc` is the low-bit
* -- form (mli.s's own header note on merlin32's quote
* -- polarity). Matches where the module is staged. --
RTPATH      dfb   14
            asc   '/mnt/MAUX/PLRT'

*---------------------------------------------------------------
* INITPARMS -- the parmlist fields that are genuinely CONSTANT
* for this program's whole run (cat.s's own INITPARMS is the
* precedent, docs/STICKY.md sec 17's "bss wearing a hat"): all
* six parmlists now live in plasma.s's `dum` arena (TEXT-
* IMMUTABLE requirement -- a warm bank reuse never recopies the
* image, so nothing may self-modify text), and START's first act
* is to store the fields here that the arena does not arrive
* pre-set with. Every field NOT stored here genuinely changes
* call to call (RPARM_BUF/RPARM_REQ, WPARM_BUF/WPARM_REQ, the
* three *_REF fields copied from OPARM_REF, BRKPARM's value, the
* exit status) and is patched by START/PRINTERR/DOEXIT before
* each use, same as before.
*---------------------------------------------------------------
INITPARMS   lda   #PCNT_OPEN
            sta   OPARM
            lda   #<RTPATH
            sta   OPARM_PATH
            lda   #>RTPATH
            sta   OPARM_PATH+1
            stz   OPARM_IOBUF       ;kernel-owned, discarded
            stz   OPARM_IOBUF+1
            lda   #PCNT_READ
            sta   RPARM
            lda   #PCNT_WRITE
            sta   WPARM
            lda   #FD_STDERR
            sta   WPARM_REF
            lda   #PCNT_CLOSE
            sta   CPARM
            stz   BRKPARM_MODE      ;mode 0 = SET, always
            rts
