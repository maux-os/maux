*---------------------------------------------------------------
* argv.s -- simple argv access against the DRAFT process-startup
* convention in startup.equ. See that file for the full proposal
* and its open questions.
*---------------------------------------------------------------
* Full design notes: L.ARGV.TXT (docs/a2/)
*---------------------------------------------------------------

GETARG      cmp   ARGC
            bcs   :bad
            asl   a
            tax
            lda   ARGV,x
            sta   PTR0
            lda   ARGV+1,x
            sta   PTR0+1
            clc
            rts
:bad        sec
            rts
