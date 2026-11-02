*---------------------------------------------------------------
* nulib2lze.s -- the LZW ENCODER: the match loop, the hash index
* that makes it affordable, and the variable-width LSB-first bit
* writer underneath.
*
* This is the inverse of nulib2lzc.s and shares its TABLE: an
* entry is {prefix, suffix} at LZ_PFXL/LZ_PFXH/LZ_SFX indexed by
* code, which is exactly what the decoder builds. Only the
* direction of use differs, so the two can never disagree about
* what an entry means.
*
* WHY AN INDEX IS NEEDED AT ALL. The decoder looks a code UP and
* walks its prefix chain; the encoder has to go the other way --
* given (prefix, suffix), which code is that? -- and a linear
* scan of 4096 entries per input byte is not a program anyone
* would run. So the encoder adds a hash index over the same
* table: the buckets are hashed on the pair and LZ_NEXT chains
* the collisions. Neither is written to the archive; both are
* pure acceleration, and a reader never sees them.
*
* WHERE THEY LIVE, AND WHY THAT IS FREE. Compression and
* expansion never run in the same process, so the whole decode
* side is dead while this runs. The buckets ARE LZ_STACK, the
* 4096-byte decode stack, referred to by that name throughout
* because the readable alias does not survive the REL link (the
* reason is written out in nulib2.s); only LZ_NEXT is new
* memory, and it lives in the process language card common
* region ($E000), where nulib2.s says why that costs nothing:
* write-enable is already latched machine-wide for every maux
* process, so no bracket is opened and none is held (the
* 2026-09-20 hazard is a bracket that holds it across a
* preemptible copy; learning:01M2Y920F5DM0YKMCFVZDEBR6F). An
* earlier version of this paragraph REJECTED the language card
* on that ground; it predated the finding and was wrong here.
* LZ_NEXT is only ever reached through (LZP),y.
*
* THE ENCODER RUNS TWICE OVER EVERY FILE, once to price the
* thread and once to write it, and the table must evolve
* IDENTICALLY both times or comp_thread_eof is a lie. That is
* not left to two routines agreeing: CHUNKPREP in nulib2rle.s is
* the single decision point and both passes call it. Stage 1
* paid for this lesson with an escape byte set in one pass and
* not the other.
*---------------------------------------------------------------

*---------------------------------------------------------------
* LZEINIT -- start a thread. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZEINIT     stz   LZE_PEND
            jmp   LZECLRT

*---------------------------------------------------------------
* LZECLRT -- empty the table: next free code back to $0101, the
* whole hash index blanked, no string in hand and nothing owed
* to the next chunk.
*
* Code 0 doubles as "no entry" in both arrays, which
* costs nothing: entries are $0101..$0FFF and 0 is never one.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZECLRT     lda   #$01
            sta   LZE_E
            sta   LZE_E+1
            lda   #$FF               ;no string in hand
            sta   LZE_W
            sta   LZE_W+1
            sta   LZE_LAST
            sta   LZE_LAST+1
            stz   LZE_PEND
            lda   #<LZ_STACK         ;the buckets: 2048 words
            sta   LZP                ;over the decode stack
            lda   #>LZ_STACK
            sta   LZP+1
            ldx   #LZSTKHI           ;4096 bytes, a page at a
            ldy   #0                 ;time
            lda   #0
:pg         sta   (LZP),y
            iny
            bne   :pg
            inc   LZP+1
            dex
            bne   :pg
            rts

*---------------------------------------------------------------
* LZEBUCK -- LZP := the address of the bucket for the pair
* (LZE_W, LZE_K), and LZE_H the byte offset it came from.
*
* The suffix is folded into BOTH halves of the prefix so that
* the bucket depends on all eight of its bits; masking the top
* to 3 leaves 2048 buckets for at most 3839 live entries, so the
* chains stay near one. The doubling to a byte offset falls out
* of the shift that is already there -- `asl` then `rol` carries
* bit 8 across for free. CLOBBERS: A.
*---------------------------------------------------------------
*-- IT PRODUCES THE ADDRESS, not an index. Hashing and then
*-- turning the hash into a pointer were two routines and two
*-- `jsr`/`rts` pairs on a path taken once per input byte, and a
*-- profile showed that fixed cost exceeding the chain walk it
*-- was setting up -- chains average 1.27 entries, so there is
*-- barely any walk to pay for. Still ONE definition of the
*-- hash, which is the property worth keeping.
LZEBUCK     lda   LZE_W
            eor   LZE_K
            asl   a                  ;the doubling to a byte
            sta   LZE_H              ;offset, carry to bit 8
            lda   LZE_W+1
            eor   LZE_K
            and   #7
            rol   a
            clc
            adc   #>LZ_STACK         ;the buckets live over the
            sta   LZP+1              ;decode stack
            lda   LZE_H
            clc
            adc   #<LZ_STACK
            sta   LZP
            bcc   :done
            inc   LZP+1
:done       rts

*---------------------------------------------------------------
* LZENPTR / LZEEIX -- address the chain array and the string
* table. LZ_NEXT is indexed by a DOUBLED code, the byte arrays
* by the code itself. CLOBBERS: A.
*---------------------------------------------------------------
*-- LZENPTR SUBTRACTS $0100 FIRST. A chain node is always a
*-- table ENTRY, and entries begin at $0101 -- so the first 256
*-- slots of a code-indexed array can never be reached, and
*-- sizing it for them wastes 512 bytes of an arena that has
*-- about 280 to spare. Four cycles an access buys them back.
LZENPTR     sta   LZ_TIX             ;IN: A/X = code low/high
            txa
            sec
            sbc   #$01
            sta   LZ_TIX+1
            asl   LZ_TIX
            rol   LZ_TIX+1
            lda   LZ_TIX
            clc
            adc   #<LZ_NEXT
            sta   LZP
            lda   LZ_TIX+1
            adc   #>LZ_NEXT
            sta   LZP+1
            rts

LZEEIX      lda   LZE_E
            sta   LZ_TIX
            lda   LZE_E+1
            sta   LZ_TIX+1
            rts

*---------------------------------------------------------------
* LZELOOK -- is (LZE_W, LZE_K) in the table? Carry clear and the
* code in LZE_C if it is.
*
* The chain is verified against the SHARED table, not against
* anything the index stores, so a hash collision costs a compare
* and never a wrong answer. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZELOOK     jsr   LZEBUCK
            lda   LZP                ;LZEADD is always the next
            sta   LZE_BK             ;thing a MISS does, and it
            lda   LZP+1              ;wants this same bucket
            sta   LZE_BK+1
            ldy   #0
            lda   (LZP),y
            sta   LZE_C
            iny
            lda   (LZP),y
            sta   LZE_C+1
*-- THE THREE COMPARES ARE INLINE. A profile put this routine at
*-- 18.5% of `nulib2 -a` and LZTBL at another 4.7%, and most of
*-- that was the `jsr`/`rts` and the LZ_TIX round-trip rather
*-- than the arithmetic. The addends are ZERO (`#<SYM`, `#>SYM`)
*-- so the REL link carries them exactly; nulib2.s says why
*-- `#>SYM+n` would not.
:walk       lda   LZE_C
            ora   LZE_C+1
            beq   :miss
            ldy   #0
            lda   LZE_C              ;SFX[c] first: eight bits
            clc                      ;of suffix reject fastest
            adc   #<LZ_SFX
            sta   LZP
            lda   LZE_C+1
            adc   #>LZ_SFX
            sta   LZP+1
            lda   (LZP),y
            cmp   LZE_K
            bne   :next
            lda   LZE_C
            clc
            adc   #<LZ_PFXL
            sta   LZP
            lda   LZE_C+1
            adc   #>LZ_PFXL
            sta   LZP+1
            lda   (LZP),y
            cmp   LZE_W
            bne   :next
            lda   LZE_C
            clc
            adc   #<LZ_PFXH
            sta   LZP
            lda   LZE_C+1
            adc   #>LZ_PFXH
            sta   LZP+1
            lda   (LZP),y
            cmp   LZE_W+1
            bne   :next
            lda   LZE_C              ;a hit IS the new string,
            sta   LZE_W              ;so say so here rather than
            lda   LZE_C+1            ;make the caller copy it
            sta   LZE_W+1
            clc
            rts
:next       lda   LZE_C
            ldx   LZE_C+1
            jsr   LZENPTR
            ldy   #0
            lda   (LZP),y
            sta   LZE_TT
            iny
            lda   (LZP),y
            sta   LZE_C+1
            lda   LZE_TT
            sta   LZE_C
            bra   :walk
:miss       sec
            rts

*---------------------------------------------------------------
* LZEADD -- table[LZE_E] := {LZE_W, LZE_K}, linked into its
* bucket, and LZE_E advanced.
*
* It hashes AGAIN rather than trusting LZELOOK to have left the
* bucket in LZE_H. The saving would be a dozen cycles and the
* cost would be a coupling between two routines that are also
* called separately -- which is precisely the shape of stage 1's
* escape-byte bug. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- LZE_BK COMES FROM THE CALLER, and there are exactly two.
*-- LZELOOK leaves it there on its way to a miss, which is the
*-- path that reaches here for every code the encoder emits; the
*-- chunk-boundary debt in LZECHUNK hashes a DIFFERENT pair and
*-- calls LZEBUCK itself first. Hashing again here was ~50
*-- cycles on a path taken once per emitted code, and a profile
*-- put this routine at 14.6% of `nulib2 -a`.
LZEADD      ldy   #0
            lda   LZE_E
            clc
            adc   #<LZ_SFX
            sta   LZP
            lda   LZE_E+1
            adc   #>LZ_SFX
            sta   LZP+1
            lda   LZE_K
            sta   (LZP),y
            lda   LZE_E
            clc
            adc   #<LZ_PFXL
            sta   LZP
            lda   LZE_E+1
            adc   #>LZ_PFXL
            sta   LZP+1
            lda   LZE_W
            sta   (LZP),y
            lda   LZE_E
            clc
            adc   #<LZ_PFXH
            sta   LZP
            lda   LZE_E+1
            adc   #>LZ_PFXH
            sta   LZP+1
            lda   LZE_W+1
            sta   (LZP),y
            lda   LZE_BK             ;NEXT[E] := HEAD[h]
            sta   LZP
            lda   LZE_BK+1
            sta   LZP+1
            ldy   #0
            lda   (LZP),y
            sta   LZE_TT
            iny
            lda   (LZP),y
            sta   LZE_TT+1
            lda   LZE_E
            ldx   LZE_E+1
            jsr   LZENPTR
            ldy   #0
            lda   LZE_TT
            sta   (LZP),y
            iny
            lda   LZE_TT+1
            sta   (LZP),y
            lda   LZE_BK             ;HEAD[h] := E
            sta   LZP
            lda   LZE_BK+1
            sta   LZP+1
            ldy   #0
            lda   LZE_E
            sta   (LZP),y
            iny
            lda   LZE_E+1
            sta   (LZP),y
            inc   LZE_E
            bne   :done
            inc   LZE_E+1
:done       rts

*---------------------------------------------------------------
* LZEPUT -- one byte of coded output. Carry set means the coding
* has already lost and the caller should stop: the threshold is
* the size of the form this chunk would take WITHOUT LZW, so
* there is no point spending more cycles proving it.
*
* THE BYTE ARRIVES IN A and the test needs A, so it is parked
* first. A version that compared first wrote the comparison's
* own result into the stream.
* CLOBBERS: A, Y.
*---------------------------------------------------------------
LZEPUT      sta   LZE_PB
            lda   LZE_OLEN+1         ;OLEN >= OMAX: already lost
            cmp   LZE_OMAX+1
            bcc   :room
            bne   :over
            lda   LZE_OLEN
            cmp   LZE_OMAX
            bcs   :over
:room       lda   LZE_PB
            ldy   #0
            sta   (LZE_OP),y
            inc   LZE_OP
            bne   :nohi
            inc   LZE_OP+1
:nohi       inc   LZE_OLEN
            bne   :done
            inc   LZE_OLEN+1
:done       clc
            rts
:over       sec
            rts

*---------------------------------------------------------------
* LZEMIT -- append LZE_CODE at the current width.
*
* THE WIDTH IS NOT TRANSMITTED. Both sides derive it from the
* next free entry, and they hold DIFFERENT numbers at the same
* point in the stream: the encoder adds an entry when it emits a
* code, the decoder when it reads the NEXT one, so the encoder
* runs exactly one entry ahead. The decoder's rule is
* `(ENTRY + 1) >> 8`; substituting ENTRY = LZE_E - 1 leaves
* `LZE_E >> 8`, which is the high byte and nothing else. Get
* this wrong by one and the streams stay in step until the
* table crosses a 256-entry boundary, then diverge silently.
*
* Codes go out LOW-ORDER BITS FIRST. The accumulator needs three
* bytes: at most 7 bits are already there and a code is at most
* 12. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZEMIT      ldx   LZE_E+1
            lda   LZWIDTHS,x
            sta   LZE_WID
            lda   LZE_CODE
            sta   LZE_T
            lda   LZE_CODE+1
            sta   LZE_T+1
            stz   LZE_T+2
            ldx   LZE_HAVE
            beq   :placed
:shl        asl   LZE_T
            rol   LZE_T+1
            rol   LZE_T+2
            dex
            bne   :shl
:placed     lda   LZE_ACC
            ora   LZE_T
            sta   LZE_ACC
            lda   LZE_ACC+1
            ora   LZE_T+1
            sta   LZE_ACC+1
            lda   LZE_ACC+2
            ora   LZE_T+2
            sta   LZE_ACC+2
            lda   LZE_HAVE
            clc
            adc   LZE_WID
            sta   LZE_HAVE
:outlp      lda   LZE_HAVE
            cmp   #8
            bcc   :done
            lda   LZE_ACC
            jsr   LZEPUT
            bcs   :over
            lda   LZE_ACC+1
            sta   LZE_ACC
            lda   LZE_ACC+2
            sta   LZE_ACC+1
            stz   LZE_ACC+2
            lda   LZE_HAVE
            sec
            sbc   #8
            sta   LZE_HAVE
            bra   :outlp
:done       clc
            rts
:over       sec
            rts

*---------------------------------------------------------------
* LZEFLSH -- the last partial byte, zero-filled. The decoder
* stops on the OUTPUT count, not on the input, so trailing bits
* that name no code are never looked at.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZEFLSH     lda   LZE_HAVE
            beq   :done
            stz   LZE_HAVE
            lda   LZE_ACC
            jmp   LZEPUT
:done       clc
            rts

*---------------------------------------------------------------
* LZENEXTB -- the next input byte into LZE_K. Carry set at the
* end of the chunk. CLOBBERS: A, Y.
*---------------------------------------------------------------
LZENEXTB    lda   LZE_ILEFT
            ora   LZE_ILEFT+1
            beq   :none
            ldy   #0
            lda   (LZE_IP),y
            sta   LZE_K
            inc   LZE_IP
            bne   :nohi
            inc   LZE_IP+1
:nohi       lda   LZE_ILEFT
            bne   :nodec
            dec   LZE_ILEFT+1
:nodec      dec   LZE_ILEFT
            clc
            rts
:none       sec
            rts

*---------------------------------------------------------------
* LZECHUNK -- code LZE_ILEFT bytes at LZE_IP into LZE_OP,
* stopping early if the result reaches LZE_OMAX.
*
* IN:  LZE_IP/LZE_ILEFT the chunk to code, LZE_OP where to put
*      it, LZE_OMAX the size at which it has already lost.
* OUT: carry set = abandoned; LZE_OLEN = bytes written.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- A CHUNK BOUNDARY DOES NOT BREAK THE STRING. LZW/2 carries
*-- its table across compressed chunks, and the decoder carries
*-- LZ_OLD with it -- so the first code of the next chunk still
*-- extends the last code of this one, and an entry is added
*-- linking them. The encoder cannot add that entry when it
*-- flushes, because the byte that completes it has not been
*-- read yet; it owes it, and pays at the top of the next chunk.
LZECHUNK    stz   LZE_ACC
            stz   LZE_ACC+1
            stz   LZE_ACC+2
            stz   LZE_HAVE
            stz   LZE_OLEN
            stz   LZE_OLEN+1
            lda   LZE_PEND
            beq   :loop
            stz   LZE_PEND
            jsr   LZENEXTB
            bcc   :paid
            jmp   :flush
:paid       lda   LZE_LAST
            sta   LZE_W
            lda   LZE_LAST+1
            sta   LZE_W+1
            jsr   LZEBUCK            ;a different pair from any
            lda   LZP                ;LZELOOK has looked at
            sta   LZE_BK
            lda   LZP+1
            sta   LZE_BK+1
            jsr   LZEADD
            lda   LZE_K
            sta   LZE_W
            stz   LZE_W+1
*-- THE INPUT FETCH IS INLINE HERE. It is the one call taken
*-- once per input byte, and LZENEXTB survives for the chunk-
*-- boundary debt above, which is taken once per CHUNK.
:loop       lda   LZE_ILEFT
            ora   LZE_ILEFT+1
            bne   :gotb
            jmp   :flush
:gotb       ldy   #0
            lda   (LZE_IP),y
            sta   LZE_K
            inc   LZE_IP
            bne   :inohi
            inc   LZE_IP+1
:inohi      lda   LZE_ILEFT
            bne   :inodec
            dec   LZE_ILEFT+1
:inodec     dec   LZE_ILEFT
            lda   LZE_W
            and   LZE_W+1
            cmp   #$FF               ;no string in hand yet
            bne   :have
            lda   LZE_K
            sta   LZE_W
            stz   LZE_W+1
            bra   :loop
:have       jsr   LZELOOK            ;on a hit it has already
            bcc   :loop              ;set LZE_W
:miss
*-- The string in hand is the longest that IS in the table, so
*-- it goes out as one code and the pair that failed becomes the
*-- next entry. That is the whole of LZW.
            lda   LZE_W
            sta   LZE_CODE
            lda   LZE_W+1
            sta   LZE_CODE+1
            jsr   LZEMIT
            bcs   :over
            jsr   LZEADD
*-- $1000 entries is the most a 12-bit code can name. LZW/2
*-- sends $0100 and both sides start again; LZW/1 never gets
*-- here, which is why it has no clear code at all.
            lda   LZE_E+1
            cmp   #$10
            bcc   :nofull
            stz   LZE_CODE
            lda   #$01
            sta   LZE_CODE+1
            jsr   LZEMIT
            bcs   :over
            jsr   LZECLRT
:nofull     lda   LZE_K
            sta   LZE_W
            stz   LZE_W+1
            jmp   :loop
*-- The codes must account for EXACTLY the chunk's bytes, so
*-- whatever is in hand goes out here whether or not it would
*-- have grown. What it owes the next chunk is recorded.
:flush      lda   LZE_W
            and   LZE_W+1
            cmp   #$FF
            beq   :noflush
            lda   LZE_W
            sta   LZE_CODE
            lda   LZE_W+1
            sta   LZE_CODE+1
            jsr   LZEMIT
            bcs   :over
            lda   LZE_W
            sta   LZE_LAST
            lda   LZE_W+1
            sta   LZE_LAST+1
            lda   #1
            sta   LZE_PEND
            lda   #$FF
            sta   LZE_W
            sta   LZE_W+1
:noflush    jsr   LZEFLSH
            bcs   :over
            clc
            rts
:over       sec
            rts
