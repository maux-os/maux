*-----------------------------------------------------------------------------
* check.memmap.s -- trivial build-check source for `make check-memmap`.
*
* Purpose: prove merlin32 accepts inc/memmap.equ as authored -- this is
* NOT kernel code and produces no meaningful program. It `use`s the shared
* symbol file (task #2, docs/MEMMAP.md) and references one symbol out of
* each major section/dum block, so a future edit that breaks memmap.equ's
* syntax (a bad `dum`/`dend` pair, a duplicate label, a malformed `equ`)
* fails this gate instead of only being discovered when task #3+ tries to
* build real code against it.
*-----------------------------------------------------------------------------

            lst   off
            xc                              ;65C02 instruction set
            org   $0800
            dsk   ../build/check_memmap.bin
            typ   $00
            put   ../inc/mm.procbank.equ
            put   ../inc/mm.procbnk2.equ
            put   ../inc/mm.hw.equ
            put   ../inc/mm.mlibuf.equ
            put   ../inc/mm.annex.equ
            put   ../inc/mm.annex2.equ
            put   ../inc/mm.main.equ

START       sei
            ldx   #$FF
            txs
            cld

            ;-- section 1: main 64K --
            lda   #<K_ZP
            lda   #<TEXT_PAGE1
            lda   #<TEXT_PAGE2
            lda   #<K_CODE_A
            lda   #<HIRES_PAGE1
            lda   #<HIRES_PAGE2
            lda   #<K_CODE_C
            lda   #<K_LC_COMMON
            lda   #<K_STACK_FLOOR    ;task #13 stack-floor invariant
            lda   #K_STCK_BUDGET    ;fits in a byte (128)

            ;-- section 2: aux bank 0 annex, incl. the one remaining dum'd
            ;-- struct (INODE_ENTRY removed, task #11 amendment -- the
            ;-- inode cache it described was cut by the ProDOS ruling;
            ;-- PIPE_META removed, task #13 amendment -- superseded by the
            ;-- OFT/pipe object graph, see inc/memmap.equ's own
            ;-- removal notes for both) --
            lda   #<ANNEX_TEXT80
            lda   #<ANNEX_TEXT2
            lda   #<ANNX_DHR_PG1
            lda   #<ANNX_DHR_PG2
            lda   #<ANNEX_STRCT_C
            lda   #PCB_ENTRY_LEN            ;fits in a byte (16)
            ldy   #PCB_FDTABLE              ;offset within PCB_ENTRY
            ldy   #PCB_BRK                  ;process break PAGE
                                             ;(0 = unset)

            ;-- task #13 amendment: OFT object graph (docs/MEMMAP.md
            ;-- sec 2.2a, code review C3) --
            lda   #OFT_COUNT                ;fits in a byte (16)
            lda   #OFT_FREE
            lda   #OFT_PIPE_R
            lda   #OFT_PIPE_W
            lda   #OFT_FILE
            lda   #PIPE_COUNT               ;fits in a byte (8)
            lda   #<PIPE_RNG_SIZE

            ;-- task #11 amendment: MLI file-buffer budget (docs/PRODOS-
            ;-- SPIKE.md answer (e)), replacing the removed K_DISKBUF_SIZE --
            lda   #<MLI_IBF_SIZE
            lda   #MLI_IOBUF_CNT          ;fits in a byte (6)

            ;-- section 3: process-bank layout, incl. the $FFxx dum block --
            lda   #<LOAD_BASE
            lda   #<BF00_OVERLAY
            lda   #<FFXX_PAGE
            lda   #LC_DFLT_BANK          ;fits in a byte (2)
            lda   #<SYSCALL_ENTRY
            lda   #<IRQ_ENTRY
            lda   #<EXIT_TAIL
            lda   #<BANK_ID
            lda   #<NMI_VEC
            lda   #<RESET_VEC
            lda   #<IRQ_VEC

            ;-- section 4: softswitch steady-state addresses --
            sta   CLR80STORE
            lda   KBD_DATA
            sta   KBD_STROBE
            sta   TEXTMODEON
            sta   MIXEDOFF
            sta   RAMRDMAIN
            sta   RAMWRTMAIN
            sta   ALTZPMAIN
            sta   PAGE2OFF
            sta   HIRESOFF
            sta   LCBANK2_RAM
            lda   BANKSEL                   ;never actually done for real --
                                             ;write-only hw; smoke test only

:halt       jmp   :halt

            ds    $0800+512-*
