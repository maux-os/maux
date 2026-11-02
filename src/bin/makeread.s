*---------------------------------------------------------------
* makeread.s -- read the makefile and parse it into the rule
* table. Split out of make.s for as's source window.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_READ -- slurp the makefile whole into MKTEXT. Held whole
* rather than streamed because every rule points INTO it: target
* and dependency names are NUL-terminated in place by the parser
* rather than copied, which is what keeps the rule table to
* offsets and no string storage of its own.
*---------------------------------------------------------------
MK_READ     lda   MKPATH_P
            sta   PTR0
            lda   MKPATH_P+1
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<MKOPARM
            ldx   #>MKOPARM
            jsr   SC_OPEN
            bcc   :opened
            jmp   MK_NOFILE
:opened     lda   MKOPARM_REF
            sta   MKRPARM_REF
            stz   MKLEN
            stz   MKLEN+1
*-- ONE read of MK_TXTSZ-1 bytes: the kernel chunks a request of
*-- any size (procfile2.s PRC_FILE_READ) and stops at EOF, so
*-- TRN is the file length or the buffer's limit. Refuse a
*-- makefile that fills the buffer rather than truncate it into
*-- something that parses but means something else; the last
*-- byte stays free for the NUL the parser walks to.
*-- (Was a 512-byte loop whose "still room?" test refused at
*-- MK_TXTSZ-512 -- the buffer's last 512 bytes were dead, the
*-- image builder asserted against the full size, and the
*-- self-make silently built nothing from 2026-09-02, when the
*-- staged MAKEFILE crossed 17,920 B. check-selfmake went red;
*-- the console said "makefile too large"; nobody was looking.)
            lda   #<MKTEXT
            sta   MKRPARM_BUF
            lda   #>MKTEXT
            sta   MKRPARM_BUF+1
            lda   #<MK_TXTLIM
            sta   MKRPARM_REQ
            lda   #>MK_TXTLIM
            sta   MKRPARM_REQ+1
            lda   #<MKRPARM
            ldx   #>MKRPARM
            jsr   SC_READ
            bcs   :rddone
            lda   MKRPARM_TRN
            sta   MKLEN
            lda   MKRPARM_TRN+1
            sta   MKLEN+1
            cmp   #>MK_TXTLIM
            bcc   :rddone
            lda   MKLEN
            cmp   #<MK_TXTLIM
            bcc   :rddone
            jmp   MK_TOOBIG
:rddone     lda   MKOPARM_REF
            sta   MKCPARM_REF
            lda   #<MKCPARM
            ldx   #>MKCPARM
            jsr   SC_CLOSE
*-- EITHER TEXT CONVENTION (KFIX10 item 5; README "Text").
*-- Everything the parser, the macro expander and the spawn
*-- compare is the maux form -- high bit set, tab $89, line end
*-- $8D -- so a Makefile in ProDOS standard text (low ASCII, tab
*-- $09, line end $0D: what a2til and tip deliver) is brought to
*-- it here, in place, with one ORA over the file. The blind
*-- mask is nas's polarity-blind line rule (item 2): a high-bit
*-- file is left as it was, so both conventions build the same
*-- bytes.
            lda   #<MKTEXT
            sta   PTR0
            lda   #>MKTEXT
            sta   PTR0+1
            ldx   MKLEN+1
            ldy   #0
            txa
            beq   :tail
:page       lda   (PTR0),y
            ora   #$80
            sta   (PTR0),y
            iny
            bne   :page
            inc   PTR0+1
            dex
            bne   :page
:tail       cpy   MKLEN
            beq   :masked
            lda   (PTR0),y
            ora   #$80
            sta   (PTR0),y
            iny
            bra   :tail
:masked
*-- terminate, so the parser can walk with a plain NUL test
            ldx   MKLEN
            ldy   MKLEN+1
            clc
            lda   #<MKTEXT
            adc   MKLEN
            sta   PTR0
            lda   #>MKTEXT
            adc   MKLEN+1
            sta   PTR0+1
            lda   #0
            sta   (PTR0)
            rts

*---------------------------------------------------------------
* MK_PARSE -- walk MKTEXT and fill the rule table.
*
* The shape, and the whole of it:
*   - a line whose FIRST character is a tab is a recipe line,
*     belonging to the rule above it
*   - a line whose first ':' or '=' is an '=' is a MACRO
*     DEFINITION
*   - any other line is a rule header: targets, ':',
*     dependencies, optionally ';' and one command
*   - a blank line, or one starting '#', is skipped
*
* WHAT IS TERMINATED IN PLACE AND WHAT IS NOT. Target names are
* still NUL-terminated where they sit, so the rule table stores
* offsets and needs no string arena -- unless the target
* contains a '$', in which case its expansion goes to MK_NAMES
* (docs/MAKE-POSIX.md sec 2). DEPENDENCY text is NOT terminated
* or split here at all: a macro can expand to any number of
* names, so the split happens at walk time, in MK_EXPDEPS.
*---------------------------------------------------------------
MK_PARSE    stz   NRULES
            stz   NSUFFIX
            stz   SUFLEN
            lda   #<MK_NAMES
            sta   MK_NAMESP
            lda   #>MK_NAMES
            sta   MK_NAMESP+1
            lda   #<MKTEXT
            sta   PTR0
            lda   #>MKTEXT
            sta   PTR0+1
:line       lda   (PTR0)
            bne   :haveline
            rts                        ;end of text
:haveline   cmp   #$89                 ;tab -> recipe line
            beq   :recipe
            cmp   #$A3                 ;'#' -> comment
            beq   :skipline
            cmp   #$8D                 ;bare CR -> blank
            beq   :skipline
            jsr   MK_LINEKND
            bcc   :ismacro
*-- jsr, NOT jmp: MK_RULEHDR ends in `rts`, so jumping to it
*-- returned out of MK_PARSE entirely after the first rule
*-- header -- the recipe lines below it were never seen, every
*-- rule got NCMD=0, and make decided targets were out of date
*-- and then ran nothing, exiting 0. Silent and plausible.
            jsr   MK_RULEHDR
            bra   :line
:ismacro    jsr   MK_MACDEF
            bra   :line
:skipline   jsr   MK_NEXTLN
            bra   :line
*-- MK_ADDCMD advances PTR0 itself: it REPLACES the line's CR
*-- with the command string's NUL, and MK_NEXTLN cannot cross a
*-- NUL -- calling it here stopped the parse at the FIRST recipe
*-- line, so the table held rule 0 plus one command and every
*-- later target read as a missing source. Found by
*-- check-selfmake on the first real graph (2026-09-01); the
*-- one-rule shape the smoke test used cannot see it.
:recipe     jsr   MK_ADDCMD
            bra   :line

*---------------------------------------------------------------
* MK_LINEKND -- is the line at PTR0 a macro definition? Carry
* CLEAR if the first of ':' and '=' is the '='. POSIX's own
* test, and the reason `TARGET: A=B` is still a rule.
*---------------------------------------------------------------
MK_LINEKND  lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
:scan       lda   (PTR1)
            beq   :rule
            cmp   #$8D
            beq   :rule
            cmp   #$BA                 ;':'
            beq   :rule
            cmp   #$BD                 ;'='
            beq   :macro
            jsr   MK_P1INC
            bra   :scan
:macro      clc
            rts
:rule       sec
            rts

*---------------------------------------------------------------
* MK_P1INC -- PTR1 += 1. Its own routine because the parser
* advances a cursor about thirty times and each one was four
* lines of carry-handling.
*---------------------------------------------------------------
MK_P1INC    inc   PTR1
            bne   :done
            inc   PTR1+1
:done       rts

*---------------------------------------------------------------
* MK_EOLS -- advance PTR1 to the LOGICAL end of line: the NUL,
* or the first CR that no backslash continues.
*
* Every line-consuming path goes through this one routine, so
* "what ends a line" is stated once -- and that is what made
* `\`-continuation a three-line change instead of a hunt.
*---------------------------------------------------------------
MK_EOLS     lda   (PTR1)
            beq   :done
            cmp   #$8D
            beq   :done
            cmp   #$DC                 ;'\' -- continued?
            bne   :next
            ldy   #1
            lda   (PTR1),y
            cmp   #$8D
            bne   :next
            jsr   MK_P1INC             ;step over the backslash
:next       jsr   MK_P1INC
            bra   MK_EOLS
:done       rts

*---------------------------------------------------------------
* MK_LINEEND -- HDR_EOL = where the line at PTR0 logically ends,
* HDR_NEXT = where the next one starts. BOTH ARE COMPUTED
* BEFORE ANYTHING IS WRITTEN INTO THE LINE, and that ordering is
* load-bearing: the parser NUL-terminates names in place, and a
* later scan for the CR would stop at the first of those NULs
* and never find the line's real end.
*---------------------------------------------------------------
MK_LINEEND  lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            jsr   MK_EOLS
            lda   PTR1
            sta   HDR_EOL
            lda   PTR1+1
            sta   HDR_EOL+1
            lda   (PTR1)
            beq   :atnul
            jsr   MK_P1INC
:atnul      lda   PTR1
            sta   HDR_NEXT
            lda   PTR1+1
            sta   HDR_NEXT+1
            rts

*---------------------------------------------------------------
* MK_ATEOL -- carry SET while PTR1 is still inside the line.
*---------------------------------------------------------------
MK_ATEOL    lda   PTR1+1
            cmp   HDR_EOL+1
            bcc   :inside
            bne   :outside
            lda   PTR1
            cmp   HDR_EOL
            bcc   :inside
:outside    clc
            rts
:inside     sec
            rts

*---------------------------------------------------------------
* MK_NEXTLN -- advance PTR0 past the logical end of line.
*---------------------------------------------------------------
MK_NEXTLN   jsr   MK_LINEEND
            lda   HDR_NEXT
            sta   PTR0
            lda   HDR_NEXT+1
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* MK_MACDEF -- `NAME = value`. Both halves are pointed at where
* they lie in MKTEXT rather than copied: the text is held whole
* for the life of the run, which is the same property the rule
* table already relies on.
*---------------------------------------------------------------
MK_MACDEF   jsr   MK_LINEEND
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
:skipsp     lda   (PTR1)
            cmp   #$A0
            bne   :atname
            jsr   MK_P1INC
            bra   :skipsp
:atname     lda   PTR1
            sta   MAC_NP
            lda   PTR1+1
            sta   MAC_NP+1
:nscan      lda   (PTR1)
            cmp   #$BD                 ;'='
            beq   :ateq
            cmp   #$A0
            beq   :nameend
            cmp   #$89
            beq   :nameend
            jsr   MK_P1INC
            bra   :nscan
*-- `NAME = v` puts blanks between the name and the '=': the
*-- name ends at the first of them and the '=' is found after
:nameend    lda   #0
            sta   (PTR1)
            jsr   MK_P1INC
:eqscan     lda   (PTR1)
            cmp   #$BD
            beq   :ateq2
            jsr   MK_P1INC
            bra   :eqscan
:ateq       lda   #0
            sta   (PTR1)
:ateq2      jsr   MK_P1INC
:vskip      lda   (PTR1)
            cmp   #$A0
            bne   :atval
            jsr   MK_P1INC
            bra   :vskip
:atval      lda   PTR1
            sta   MAC_VP
            lda   PTR1+1
            sta   MAC_VP+1
*-- a '#' ends the value; otherwise the logical end of line does
:cscan      jsr   MK_ATEOL
            bcc   :vend
            lda   (PTR1)
            cmp   #$A3                 ;'#'
            beq   :vend
            jsr   MK_P1INC
            bra   :cscan
:vend       lda   (PTR1)
            beq   :store               ;already the text's NUL
            lda   #0
            sta   (PTR1)
:store      lda   MAC_NP
            sta   PTR0
            lda   MAC_NP+1
            sta   PTR0+1
            lda   MAC_VP
            sta   PTR1
            lda   MAC_VP+1
            sta   PTR1+1
            lda   #0
            jsr   MK_MACSET
            lda   HDR_NEXT
            sta   PTR0
            lda   HDR_NEXT+1
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* MK_ADDCMD -- record a recipe line for the rules of the header
* above it. PTR0 is at the tab; the command starts after it and
* ends at the logical end of line, which is replaced by a NUL so
* the line is a plain string.
*
* The line is stored RAW. Macros in it are expanded when the
* command RUNS (makemac.s's header says why), which is also what
* lets one inference recipe serve every target it is chosen for.
*---------------------------------------------------------------
MK_ADDCMD   lda   NRULES
            bne   :haverule
            jmp   MK_NEXTLN      ;recipe before any rule --
                                 ;skip the line, not an error
:haverule   jsr   MK_LINEEND
            inc   PTR0                 ;past the tab
            bne   :nc
            inc   PTR0+1
:nc         lda   PTR0
            sta   HDR_CMDP
            lda   PTR0+1
            sta   HDR_CMDP+1
            jsr   MK_SETCMD
            lda   HDR_EOL
            sta   PTR1
            lda   HDR_EOL+1
            sta   PTR1+1
            lda   (PTR1)
            beq   :ended
            lda   #0
            sta   (PTR1)
:ended      lda   HDR_NEXT
            sta   PTR0
            lda   HDR_NEXT+1
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* MK_SETCMD -- attach the command at HDR_CMDP to every rule the
* current header made. `a.o b.o: incl` is one header and two
* rules, and they share their recipe.
*---------------------------------------------------------------
MK_SETCMD   ldx   HDR_FIRST
:each       cpx   NRULES
            bcs   :done
            lda   RULE_NCMD,x
            bne   :bump
            lda   HDR_CMDP
            sta   RULE_CMD,x
            lda   HDR_CMDP+1
            sta   RULE_CMD+MK_MAXRULE,x
:bump       inc   RULE_NCMD,x
            inx
            bra   :each
:done       rts

