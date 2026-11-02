*---------------------------------------------------------------
* makeinf2.s -- choosing an inference rule and carrying it
* out.
*
* Split out of makeinf.s for as's 16,128-byte source window
* (check-dialect 3b): as holds the MANIFEST resident and
* streams each `put` one at a time, so the charge is the
* manifest plus the LARGEST put.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_INFER -- can the name at MK_NAMEP be made by an inference
* rule? Carry CLEAR and INF_RULEI/INF_SRC/INF_SLEN set if so.
* Pure derivation: it reads the disk (a candidate source has to
* EXIST) but changes nothing, so it is safe to run twice, which
* is exactly what MK_INFRUN does after its recursion.
*---------------------------------------------------------------
MK_INFER    lda   NSUFFIX
            beq   :nope
            jsr   MK_NAMELEN
            stz   INF_I2
:s2loop     lda   INF_I2
            cmp   NSUFFIX
            bcs   :nope
            ldx   INF_I2
            lda   SUF_L,x
            sta   PTR1
            lda   SUF_H,x
            sta   PTR1+1
            jsr   MK_ENDSW
            bcs   :s2next
            sta   INF_SLEN
            stz   INF_I1
:s1loop     lda   INF_I1
            cmp   NSUFFIX
            bcs   :s2next
            jsr   MK_MKRULENM
            lda   #<INF_RNAME
            sta   MK_FNAME
            lda   #>INF_RNAME
            sta   MK_FNAME+1
            jsr   MK_FINDNM
            bcs   :s1next
            sta   INF_RULEI
            jsr   MK_MKSRC
            jsr   MK_SRCOK
            bcc   :hit
:s1next     inc   INF_I1
            bra   :s1loop
:s2next     inc   INF_I2
            bra   :s2loop
:hit        clc
            rts
:nope       sec
            rts

*-- INF_TLEN = length of the name at MK_NAMEP
MK_NAMELEN  lda   MK_NAMEP
            sta   PTR0
            lda   MK_NAMEP+1
            sta   PTR0+1
            ldy   #0
:scan       lda   (PTR0),y
            beq   :done
            iny
            bne   :scan
:done       sty   INF_TLEN
            rts

*---------------------------------------------------------------
* MK_ENDSW -- does the name at MK_NAMEP end with the suffix at
* PTR1? Carry CLEAR and A = the stem length if so. A name that
* is ONLY the suffix does not count: there would be no stem.
*---------------------------------------------------------------
MK_ENDSW    lda   PTR1
            sta   INF_SFP
            lda   PTR1+1
            sta   INF_SFP+1
            ldy   #0
:len        lda   (PTR1),y
            beq   :havelen
            iny
            bne   :len
:havelen    sty   INF_SFLEN
            cpy   #0
            beq   :no                  ;an empty suffix matches
            tya                        ;nothing
            cmp   INF_TLEN
            bcs   :no                  ;suffix >= the whole name
            lda   INF_TLEN
            sec
            sbc   INF_SFLEN
            sta   INF_STEM2
*-- point PTR0 straight at the name's TAIL, so the compare is a
*-- plain walk of two strings rather than two indices
            clc
            lda   MK_NAMEP
            adc   INF_STEM2
            sta   PTR0
            lda   MK_NAMEP+1
            adc   #0
            sta   PTR0+1
            ldy   #0
:cmp        lda   (PTR1),y
            beq   :yes
            cmp   (PTR0),y
            bne   :no
            iny
            bne   :cmp
:yes        lda   INF_STEM2
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* MK_MKRULENM -- INF_RNAME = suffix INF_I1 followed by suffix
* INF_I2, which is how an inference rule spells its target:
* `.S` + `.R` is the rule `.S.R`.
*---------------------------------------------------------------
MK_MKRULENM ldx   INF_I1
            lda   SUF_L,x
            sta   PTR0
            lda   SUF_H,x
            sta   PTR0+1
            ldx   #0
            ldy   #0
:one        lda   (PTR0),y
            beq   :two
            cpx   #INF_RNSZ-1
            bcs   :full
            sta   INF_RNAME,x
            inx
            iny
            bra   :one
:two        ldy   INF_I2
            lda   SUF_L,y
            sta   PTR0
            lda   SUF_H,y
            sta   PTR0+1
            ldy   #0
:cp2        lda   (PTR0),y
            beq   :end
            cpx   #INF_RNSZ-1
            bcs   :full
            sta   INF_RNAME,x
            inx
            iny
            bra   :cp2
:end        lda   #0
            sta   INF_RNAME,x
            rts
:full       lda   #<MANYSUFMSG
            ldx   #>MANYSUFMSG
            jmp   MK_DIE

*---------------------------------------------------------------
* MK_MKSRC -- INF_SRC = the target's first INF_SLEN characters
* (the stem) followed by suffix INF_I1.
*---------------------------------------------------------------
MK_MKSRC    lda   MK_NAMEP
            sta   PTR0
            lda   MK_NAMEP+1
            sta   PTR0+1
            ldx   #0
            ldy   #0
:stem       cpy   INF_SLEN
            beq   :suffix
            cpx   #INF_SRCSZ-1
            bcs   :full
            lda   (PTR0),y
            sta   INF_SRC,x
            inx
            iny
            bra   :stem
:suffix     ldy   INF_I1
            lda   SUF_L,y
            sta   PTR0
            lda   SUF_H,y
            sta   PTR0+1
            ldy   #0
:cp         lda   (PTR0),y
            beq   :end
            cpx   #INF_SRCSZ-1
            bcs   :full
            sta   INF_SRC,x
            inx
            iny
            bra   :cp
:end        lda   #0
            sta   INF_SRC,x
            rts
:full       lda   #<LONGMSG
            ldx   #>LONGMSG
            jmp   MK_DIE

*---------------------------------------------------------------
* MK_SRCOK -- is INF_SRC usable as an inferred prerequisite?
* POSIX: it must exist as a file, or be a target with a rule.
* INF_HASR remembers which, so MK_INFRUN knows whether it has
* to recurse at all -- and in maux's own graph it never does,
* every .S source being staged rather than generated.
*---------------------------------------------------------------
MK_SRCOK    stz   INF_HASR
            lda   #<INF_SRC
            sta   MK_FNAME
            lda   #>INF_SRC
            sta   MK_FNAME+1
            jsr   MK_FINDNM
            bcs   :tryfile
            inc   INF_HASR
            clc
            rts
:tryfile    lda   #<INF_SRC
            sta   MK_FNAME
            lda   #>INF_SRC
            sta   MK_FNAME+1
            jsr   MK_STATN
            lda   MK_EXISTS
            beq   :no
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* MK_INFRUN -- carry out the inference MK_INFER just derived for
* the target at MK_NAMEP.
*
* If the inferred source is itself a target with a rule it is
* built first, and the derivation is then REDONE rather than
* remembered: the recursion can run any number of other
* inferences underneath it, and re-deriving costs two stats
* against a per-depth buffer set the walk would have to carry
* for a chain nothing in this tree has. MK_NAMEP rides the DEPTH
* stack around the call for the same reason MK_DEPS puts it
* there.
*---------------------------------------------------------------
MK_INFRUN   lda   INF_HASR
            beq   :fresh
            ldx   DEPTH
            lda   MK_NAMEP
            sta   MK_SAVIL,x
            lda   MK_NAMEP+1
            sta   MK_SAVIH,x
            lda   #<INF_SRC
            sta   MK_NAMEP
            lda   #>INF_SRC
            sta   MK_NAMEP+1
            jsr   MK_BUILD
            ldx   DEPTH
            lda   MK_SAVIL,x
            sta   MK_NAMEP
            lda   MK_SAVIH,x
            sta   MK_NAMEP+1
            lda   STOPFLAG
            beq   :again
            rts
:again      jsr   MK_INFER
            bcc   :fresh
            rts
:fresh      lda   MK_NAMEP
            sta   MK_FNAME
            lda   MK_NAMEP+1
            sta   MK_FNAME+1
            jsr   MK_STATN
            lda   MK_EXISTS
            beq   :build               ;no target: always build
            ldy   #3
:cpt        lda   MK_STAMP,y
            sta   MK_TSTAMP,y
            dey
            bpl   :cpt
            lda   #<INF_SRC
            sta   MK_FNAME
            lda   #>INF_SRC
            sta   MK_FNAME+1
            jsr   MK_STATN
            lda   MK_EXISTS
            beq   :done                ;no source to be newer
            ldy   #3
:cpd        lda   MK_STAMP,y
            sta   MK_DSTAMP,y
            dey
            bpl   :cpd
            jsr   MK_NEWER
            bcc   :done
            bra   :run
*-- a missing target has no stamp to compare, so $? has to be
*-- told that everything counts
:build      stz   MK_TSTAMP
            stz   MK_TSTAMP+1
            stz   MK_TSTAMP+2
            stz   MK_TSTAMP+3
:run        lda   MK_NAMEP
            sta   MK_TGTP
            lda   MK_NAMEP+1
            sta   MK_TGTP+1
            lda   #<INF_SRC
            sta   MK_SRCP
            lda   #>INF_SRC
            sta   MK_SRCP+1
            lda   INF_SLEN
            sta   MK_STEML
            lda   #1
            sta   INF_ACTIVE
            lda   INF_RULEI
            sta   MK_RULEI
            jsr   MK_RECIPE
            stz   INF_ACTIVE
:done       rts

