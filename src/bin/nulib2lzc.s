*---------------------------------------------------------------
* nulib2lzc.s -- the LZW CODEC: the code loop, the string table
* it walks, the stack a string comes off, and the variable-width
* LSB-first bit reader underneath.
*
* One decoder serves both formats. LZW/1 clears the table at
* every chunk and so never meets a clear code; LZW/2 inherits
* it, clears on $0100, and needs a 4 KB stack rather than 100
* bytes. LZ_T2 is the only thing that differs.
*---------------------------------------------------------------

*---------------------------------------------------------------
* LZCODES -- decode one chunk's codes into LZ_OUT until LZ_RLEN
* bytes have been produced. LZ_USED comes back holding exactly
* how many stream bytes the codes consumed, which is how the
* caller finds the next chunk header.
*
* LZW/1 CLEARS ITS TABLE HERE, at every chunk, which is what
* makes this loop short: there is no clear code to recognise, no
* state to carry in, and NufxLib's `resetFix` -- the workaround
* for a chunk that ends one character after a clear -- cannot
* arise. All three belong to LZW/2.
*
* OUT: carry set = a malformed stream. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZCODES     stz   LZ_ACC
            stz   LZ_ACC+1
            stz   LZ_ACC+2
            stz   LZ_HAVE
            stz   LZ_USED
            stz   LZ_USED+1
            stz   LZ_BPOS
            stz   LZ_BLEN
            jsr   LZSTKRST
*-- WHOSE TABLE IS THIS? LZW/1 starts every chunk with an empty
*-- one. LZW/2 INHERITS the previous chunk's, and only takes a
*-- leading literal when the table really is empty; `reset_fix`
*-- marks the case where it only LOOKS empty, which is a chunk
*-- that ended one character after a clear. NufxLib advanced its
*-- next-free counter there without adding an entry, so code
*-- $0101 is simply lost and the next chunk must NOT re-read an
*-- initial literal. This replicates that rather than correcting
*-- it: the archives already exist.
            lda   LZ_T2
            bne   :t2tbl
            lda   #$01               ;LZW/1: always fresh
            sta   LZ_ENTRY
            sta   LZ_ENTRY+1
            lda   #1
            sta   LZ_CLRING
            bra   :tblok
:t2tbl      lda   #1
            sta   LZ_CLRING
            lda   LZ_ENTRY           ;empty == $0101 ?
            cmp   #$01
            bne   :notempty
            lda   LZ_ENTRY+1
            cmp   #$01
            bne   :notempty
            lda   LZ_RSTFIX
            beq   :tblok             ;empty and no fix: clear
:notempty   stz   LZ_CLRING
:tblok      stz   LZ_RSTFIX
            lda   #<LZ_OUT
            sta   LZOP
            lda   #>LZ_OUT
            sta   LZOP+1
            lda   LZ_RLEN
            sta   LZ_OLEFT
            lda   LZ_RLEN+1
            sta   LZ_OLEFT+1
            ora   LZ_OLEFT
            bne   :outer
            clc
            rts
*-- A CLEARED TABLE TAKES ITS FIRST CODE AS A LITERAL. It cannot
*-- be a table reference: nothing is in the table yet.
:outer      lda   LZ_CLRING
            beq   :mlp
            stz   LZ_CLRING
            lda   #$01
            sta   LZ_ENTRY
            sta   LZ_ENTRY+1
            lda   LZ_OLEFT           ;a chunk that ended ON the
            ora   LZ_OLEFT+1         ;clear has nothing to seed
            bne   :first
            stz   LZ_OLD
            stz   LZ_OLD+1
            stz   LZ_IN
            stz   LZ_IN+1
            stz   LZ_FIN
            bra   :mlp
:first      jsr   LZREAD
            bcc   :ok1
            jmp   :bad
:ok1
            lda   LZ_CODE+1
            beq   :jb100   ;an initial code above $FF
            jmp   :bad
:jb100
            lda   LZ_CODE
            sta   LZ_FIN
            sta   LZ_OLD
            stz   LZ_OLD+1
            sta   LZ_IN
            stz   LZ_IN+1
            jsr   LZPUTO
            bcc   :ok2
            jmp   :bad
:ok2        lda   LZ_OLEFT           ;the chunk ended one byte
            ora   LZ_OLEFT+1         ;after the clear: resetFix
            bne   :mlp
            lda   #1
            sta   LZ_RSTFIX
:mlp        lda   LZ_OLEFT
            ora   LZ_OLEFT+1
            bne   :more
            jmp   :done
:more
            jsr   LZREAD
            bcc   :ok3
            jmp   :bad
:ok3
*-- $0100 is LZW/2's CLEAR. LZW/1 never emits it, so the test is
*-- gated rather than unconditional -- a stored byte pair that
*-- happened to decode to $0100 in an LZW/1 stream would
*-- otherwise be read as a command.
            lda   LZ_T2
            beq   :notclr
            lda   LZ_CODE+1
            cmp   #$01
            bne   :notclr
            lda   LZ_CODE
            bne   :notclr
            lda   #1
            sta   LZ_CLRING
            jmp   :outer
:notclr     lda   LZ_CODE
            sta   LZ_IN
            sta   LZ_PTR
            lda   LZ_CODE+1
            sta   LZ_IN+1
            sta   LZ_PTR+1
*-- KwKwK: a code for the entry being built THIS step. Its
*-- expansion is the previous string plus that string's own
*-- first character, which is the only character already known.
            lda   LZ_PTR+1
            cmp   LZ_ENTRY+1
            bcc   :walk
            bne   :chkeq
            lda   LZ_PTR
            cmp   LZ_ENTRY
            bcc   :walk
:chkeq      lda   LZ_PTR
            cmp   LZ_ENTRY
            beq   :jb200   ;beyond the table entirely
            jmp   :bad
:jb200
            lda   LZ_PTR+1
            cmp   LZ_ENTRY+1
            beq   :jb300
            jmp   :bad
:jb300
            lda   LZ_FIN
            jsr   LZPUSH
            bcc   :ok4
            jmp   :bad
:ok4
            lda   LZ_OLD
            sta   LZ_PTR
            lda   LZ_OLD+1
            sta   LZ_PTR+1
*-- Walk the prefix chain to the root, stacking suffixes. The
*-- stack reverses them for free: they come off in the order the
*-- string is written.
:walk       lda   LZ_PTR+1
            beq   :root              ;ptr <= $FF: a literal
            jsr   LZCHKPTR
            bcc   :ok5
            jmp   :bad
:ok5
            jsr   LZSFX
            jsr   LZPUSH
            bcc   :ok6
            jmp   :bad
:ok6
            jsr   LZPFX
            bra   :walk
:root       lda   LZ_PTR
            sta   LZ_FIN
            jsr   LZPUTO
            bcc   :ok7
            jmp   :bad
:ok7
:poplp      jsr   LZPOP
            bcs   :added
            jsr   LZPUTO
            bcc   :ok8
            jmp   :bad
:ok8
            bra   :poplp
*-- The new entry: the PREVIOUS code, extended by this string's
*-- first character.
:added      lda   LZ_ENTRY+1
            cmp   #$10
            bcc   :ok9   ;the table overflowed
            jmp   :bad
:ok9
            jsr   LZSETENT
            inc   LZ_ENTRY
            bne   :noec
            inc   LZ_ENTRY+1
:noec       lda   LZ_IN
            sta   LZ_OLD
            lda   LZ_IN+1
            sta   LZ_OLD+1
            jmp   :mlp
:done       clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* LZCHKPTR -- carry clear if $0101 <= LZ_PTR < LZ_ENTRY. A code
* outside that is a corrupt stream, and following it would walk
* the prefix chain through uninitialised table bytes.
* CLOBBERS: A.
*---------------------------------------------------------------
LZCHKPTR    lda   LZ_PTR+1
            bne   :hi
            sec                      ;<= $FF cannot be here
            rts
:hi         cmp   #1                 ;$0100 is never assigned --
            bne   :notclr            ;LZW/1's table starts above
            lda   LZ_PTR             ;it, so following it would
            beq   :bad               ;walk uninitialised bytes
:notclr     lda   LZ_PTR+1
            cmp   LZ_ENTRY+1
            bcc   :ok
            bne   :bad
            lda   LZ_PTR
            cmp   LZ_ENTRY
            bcc   :ok
:bad        sec
            rts
:ok         clc
            rts

*---------------------------------------------------------------
* LZTBL -- LZP := <array base in A/X> + <code in LZ_TIX>. A FULL
* 16-bit add, and deliberately: the obvious trick aligns the
* arrays to a page and just add the code's high byte, which
* merlin32 assembles happily from `ds \` -- and `nas` refuses
* ("ds operand unresolved"), so the unit could not self-host.
* Eight cycles an access is the price of that.
* IN: A/X = base low/high. CLOBBERS: A.
*---------------------------------------------------------------
LZTBL       clc
            adc   LZ_TIX
            sta   LZP
            txa
            adc   LZ_TIX+1
            sta   LZP+1
            rts

*---------------------------------------------------------------
* LZSFX / LZPFX -- the table, indexed by LZ_PTR. LZSFX returns
* the suffix in A; LZPFX replaces LZ_PTR with the prefix.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZSFX       jsr   LZPTRIX
            lda   #<LZ_SFX
            ldx   #>LZ_SFX
            jsr   LZTBL
            ldy   #0
            lda   (LZP),y
            rts

LZPFX       jsr   LZPTRIX
            lda   #<LZ_PFXL
            ldx   #>LZ_PFXL
            jsr   LZTBL
            ldy   #0
            lda   (LZP),y
            pha
            lda   #<LZ_PFXH
            ldx   #>LZ_PFXH
            jsr   LZTBL
            ldy   #0
            lda   (LZP),y
            sta   LZ_PTR+1
            pla
            sta   LZ_PTR
            rts

*-- LZPTRIX / LZENTIX -- load the table index from LZ_PTR or
*-- LZ_ENTRY. LZPFX reads the index TWICE and must not see it
*-- change under it, which is why LZ_TIX is a copy rather than
*-- the live cell. CLOBBERS: A.
LZPTRIX     lda   LZ_PTR
            sta   LZ_TIX
            lda   LZ_PTR+1
            sta   LZ_TIX+1
            rts

LZENTIX     lda   LZ_ENTRY
            sta   LZ_TIX
            lda   LZ_ENTRY+1
            sta   LZ_TIX+1
            rts

*---------------------------------------------------------------
* LZSETENT -- table[LZ_ENTRY] := {prefix LZ_OLD, suffix LZ_FIN}.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZSETENT    jsr   LZENTIX
            lda   #<LZ_SFX
            ldx   #>LZ_SFX
            jsr   LZTBL
            ldy   #0
            lda   LZ_FIN
            sta   (LZP),y
            lda   #<LZ_PFXL
            ldx   #>LZ_PFXL
            jsr   LZTBL
            ldy   #0
            lda   LZ_OLD
            sta   (LZP),y
            lda   #<LZ_PFXH
            ldx   #>LZ_PFXH
            jsr   LZTBL
            ldy   #0
            lda   LZ_OLD+1
            sta   (LZP),y
            rts

*---------------------------------------------------------------
* LZPUSH / LZPUTO -- the decode stack, and the chunk's output.
* Both refuse to overrun rather than wrap: a string longer than
* the stack, or more output than the header promised, means the
* stream is not what it claims and the caller must not write it.
* LZW/1's stack stays under 100 bytes in practice, because a
* table built inside one 4 KB chunk cannot name a longer string.
* CLOBBERS: A, X (LZPUSH), Y (LZPUTO).
*---------------------------------------------------------------
LZSTKRST    lda   #<LZ_STACK
            sta   LZSTKP
            lda   #>LZ_STACK
            sta   LZSTKP+1
            stz   LZ_SP
            stz   LZ_SP+1
            rts

LZPUSH      ldx   LZ_SP+1            ;4096 deep, so the count is
            cpx   #LZSTKHI           ;16 bits and so is the walk
            bcs   :full
            ldy   #0
            sta   (LZSTKP),y
            inc   LZSTKP
            bne   :nohi
            inc   LZSTKP+1
:nohi       inc   LZ_SP
            bne   :done
            inc   LZ_SP+1
:done       clc
            rts
:full       sec
            rts

*-- LZPOP -- the top byte in A; carry set if the stack is empty.
LZPOP       lda   LZ_SP
            ora   LZ_SP+1
            beq   :empty
            lda   LZ_SP
            bne   :nodec
            dec   LZ_SP+1
:nodec      dec   LZ_SP
            lda   LZSTKP
            bne   :nohi
            dec   LZSTKP+1
:nohi       dec   LZSTKP
            ldy   #0
            lda   (LZSTKP),y
            clc
            rts
:empty      sec
            rts

LZPUTO      ldy   LZ_OLEFT
            cpy   #0
            bne   :room
            ldy   LZ_OLEFT+1
            beq   :over
:room       ldy   #0
            sta   (LZOP),y
            inc   LZOP
            bne   :nohi
            inc   LZOP+1
:nohi       lda   LZ_OLEFT
            bne   :nodec
            dec   LZ_OLEFT+1
:nodec      dec   LZ_OLEFT
            clc
            rts
:over       sec
            rts

*---------------------------------------------------------------
* LZREAD -- the next code into LZ_CODE. Its WIDTH follows from
* the next free table slot, which both sides compute the same
* way and neither transmits: NufxLib indexes a table by
* (entry + 1) >> 8, so the width grows from 9 to 12 as the table
* fills. Codes are packed LOW-ORDER BITS FIRST.
* OUT: carry set = the stream ended inside a code.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZREAD      lda   LZ_ENTRY           ;idx = (LZ_ENTRY + 1) >> 8
            clc
            adc   #1
            lda   LZ_ENTRY+1
            adc   #0
            tax
            lda   LZWIDTHS,x
            sta   LZ_W
            txa
            asl   a
            tax
            lda   LZMASKS,x
            sta   LZ_MSKL
            lda   LZMASKS+1,x
            sta   LZ_MSKH
:fill       lda   LZ_HAVE            ;enough bits yet?
            cmp   LZ_W
            bcs   :have
            jsr   LZGETB
            bcs   :eof
            jsr   LZORIN
            lda   LZ_HAVE
            clc
            adc   #8
            sta   LZ_HAVE
            bra   :fill
:have       lda   LZ_ACC
            and   LZ_MSKL
            sta   LZ_CODE
            lda   LZ_ACC+1
            and   LZ_MSKH
            sta   LZ_CODE+1
*-- Drop the width just taken. Every width here is 9..12, so it
*-- is one whole byte plus 1..4 bits -- the byte move first,
*-- then that many single-bit shifts.
            lda   LZ_ACC+1
            sta   LZ_ACC
            lda   LZ_ACC+2
            sta   LZ_ACC+1
            stz   LZ_ACC+2
            lda   LZ_W
            sec
            sbc   #8
            tax
            beq   :shdone            ;width 8: the byte move was
:shlp       lsr   LZ_ACC+2           ;the whole shift
            ror   LZ_ACC+1
            ror   LZ_ACC
            dex
            bne   :shlp
:shdone     lda   LZ_HAVE
            sec
            sbc   LZ_W
            sta   LZ_HAVE
            clc
            rts
:eof        sec
            rts

*---------------------------------------------------------------
* LZORIN -- OR the byte in A into LZ_ACC at bit LZ_HAVE. LZ_HAVE
* is under 12 whenever this is called, so the byte lands across
* at most LZ_ACC+1 and LZ_ACC+2. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZORIN      sta   LZ_TMP             ;the byte, shifted into
            stz   LZ_TMP+1           ;place as a 16-bit value
            lda   LZ_HAVE
            and   #7
            tax
            beq   :placed
:shlp       asl   LZ_TMP
            rol   LZ_TMP+1
            dex
            bne   :shlp
:placed     lda   LZ_HAVE
            lsr   a
            lsr   a
            lsr   a
            tax                      ;X = whole bytes in already
            lda   LZ_ACC,x
            ora   LZ_TMP
            sta   LZ_ACC,x
            inx
            lda   LZ_ACC,x
            ora   LZ_TMP+1
            sta   LZ_ACC,x
            rts

*---------------------------------------------------------------
* LZGETB -- one byte of the compressed stream, through a small
* window. It counts what the CODES consumed in LZ_USED, which is
* not the same as what the READS consumed: the window reads
* ahead, and the caller seeks to the chunk's true end using this
* count. OUT: carry set = the thread ended.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZGETB      lda   LZ_BPOS
            cmp   LZ_BLEN
            bcc   :have
            jsr   LZREFILL
            bcs   :eof
:have       ldx   LZ_BPOS
            lda   LZ_LBUF,x
            inc   LZ_BPOS
            inc   LZ_USED
            bne   :nohi
            inc   LZ_USED+1
:nohi       clc
            rts
:eof        sec
            rts

*---------------------------------------------------------------
* LZREFILL -- top the window up. A SHORT read is fine here and
* nowhere else in this program: the window is allowed to end at
* the file's end, and it is the CODE count that decides whether
* the stream was well formed.
* OUT: carry set = nothing left. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZREFILL    lda   #<LZ_LBUF
            sta   RPARM_BUF
            lda   #>LZ_LBUF
            sta   RPARM_BUF+1
            lda   #LZBUFSZ
            sta   RPARM_REQ
            stz   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :none
            lda   RPARM_TRANS+1
            bne   :none              ;more than a byte count: no
            lda   RPARM_TRANS
            beq   :none
            sta   LZ_BLEN
            stz   LZ_BPOS
            clc
            rts
:none       sec
            rts

*-- The code width for a given (entry + 1) >> 8, and the mask
*-- that goes with it. NufxLib's own table, which is why the
*-- 10s and 11s repeat the way they do.
LZWIDTHS    dfb   8,9,10,10,11,11,11,11
            dfb   12,12,12,12,12,12,12,12
            dfb   12
LZMASKS     da    $00FF,$01FF,$03FF,$03FF
            da    $07FF,$07FF,$07FF,$07FF
            da    $0FFF,$0FFF,$0FFF,$0FFF
            da    $0FFF,$0FFF,$0FFF,$0FFF
            da    $0FFF
