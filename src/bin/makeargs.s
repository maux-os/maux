*---------------------------------------------------------------
* makeargs.s -- make's command line: the options, the
* command-line macros and the targets.
*
* Split out of make.s for as's 16,128-byte source window
* (check-dialect 3b): as holds the MANIFEST resident and
* streams each `put` one at a time, so the charge is the
* manifest plus the LARGEST put, and make's manifest plus its
* walk came to 29,388 B.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_ARGS -- parse the options, the command-line macros and the
* targets. Unknown flags are a usage error rather than a
* filename, so a typo cannot silently become a target that does
* not exist.
*
* A COMMAND-LINE MACRO IS RECORDED HERE, before the makefile is
* read, and MK_MACSET refuses to let a makefile definition
* overwrite one. That is POSIX's precedence written as an
* ordering rather than as a second pass.
*---------------------------------------------------------------
MK_ARGS     stz   NFLAG
            stz   NTARGETS
            stz   IFLAG
            stz   KFLAG
            stz   SFLAG
            stz   EFLAG
            stz   TFLAG
            stz   QFLAG
            stz   RFLAG
            stz   PFLAG
            stz   NMACROS
            lda   #<DFLTMK
            sta   MKPATH_P
            lda   #>DFLTMK
            sta   MKPATH_P+1
            lda   #1
            sta   ARGI
*-- GETARG returns the argument pointer in PTR0, not in A/X --
*-- storing A/X over it put garbage in PTR0 and every argument
*-- read as whatever happened to be there.
:loop       lda   ARGI
            jsr   GETARG
            bcs   :done
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD                   ;'-'
            beq   :isflag
            jsr   MK_ISMACRO
            bcc   :next
            bra   :istarget
:isflag     jsr   MK_FLAGS
            bra   :next
:istarget   ldx   NTARGETS
            cpx   #MK_MAXTGT
            bcc   :room
            jmp   MK_USAGE
:room
            lda   PTR0
            sta   TGTLO,x
            lda   PTR0+1
            sta   TGTHI,x
            inc   NTARGETS
:next       inc   ARGI
            bra   :loop
:done       rts

*---------------------------------------------------------------
* MK_FLAGS -- the option letters of one `-xyz` word.
*
* Case is folded for every letter EXCEPT 's': POSIX gives -s and
* -S opposite jobs (silent, and cancel -k), so folding them
* together would make one of them silently mean the other.
*---------------------------------------------------------------
MK_FLAGS    lda   #1
            sta   OPTI
:ch         ldy   OPTI
            lda   (PTR0),y
            bne   :have
            rts
:have       inc   OPTI
*-- 's' and 'S' are settled BEFORE the case fold, because that
*-- fold is what would otherwise make them the same letter
            cmp   #$F3                   ;'s' -- silent
            beq   :iss
            cmp   #$D3                   ;'S' -- cancels -k
            beq   :isbigs
            and   #$DF                   ;fold to upper case
            cmp   #$C6                   ;'F' takes an argument
            beq   :isf
            sta   OPTCH
            ldx   #0
:find       lda   OPTTAB,x
            beq   :bad
            cmp   OPTCH
            beq   :found
            inx
            bra   :find
*-- the flag cells are declared consecutively from NFLAG, so a
*-- letter is an index and the whole dispatch is one `inc`
:found      lda   OPTIDX,x
            tax
            inc   NFLAG,x
            bra   :ch
:bad        jmp   MK_USAGE
:iss        inc   SFLAG
            bra   :ch
:isbigs     stz   KFLAG
            bra   :ch
:isf        ldy   OPTI
            lda   (PTR0),y
            beq   :fnext
*-- `-fNAME`: the pathname is the rest of this word
            tya
            clc
            adc   PTR0
            sta   MKPATH_P
            lda   PTR0+1
            adc   #0
            sta   MKPATH_P+1
            rts
:fnext      inc   ARGI
            lda   ARGI
            jsr   GETARG
            bcc   :fok
            jmp   MK_USAGE
:fok        lda   PTR0
            sta   MKPATH_P
            lda   PTR0+1
            sta   MKPATH_P+1
            rts

*-- -r clears the initial .SUFFIXES list. There are no built-in
*-- inference rules here and no built-in suffixes to clear --
*-- there is no cc to write one for -- so RFLAG is recorded and
*-- nothing acts on it, which is the honest reading rather than
*-- a silent rejection of a flag a portable makefile passes.
OPTTAB      asc   "NIKETQRP"
            dfb   0
OPTIDX      dfb   0,1,2,4,5,6,7,8

*---------------------------------------------------------------
* MK_ISMACRO -- is this argument a `NAME=value` macro? Carry
* CLEAR if it was one and it has been recorded. The '=' is
* overwritten with the NUL that terminates the name, in the
* argv block this process owns.
*---------------------------------------------------------------
MK_ISMACRO  ldy   #0
:scan       lda   (PTR0),y
            beq   :no
            cmp   #$BD                   ;'='
            beq   :yes
            cmp   #$3D                   ;the same, high bit
            beq   :yes                   ;clear
            iny
            bne   :scan
:no         sec
            rts
:yes        cpy   #0
            beq   :no                    ;`=value` has no name
            lda   #0
            sta   (PTR0),y
            iny
            tya
            clc
            adc   PTR0
            sta   PTR1
            lda   PTR0+1
            adc   #0
            sta   PTR1+1
            lda   #1
            jsr   MK_MACSET
            clc
            rts

MK_USAGE    lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

