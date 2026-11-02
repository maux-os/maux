*---------------------------------------------------------------
* ldargf.s -- `ld @FILE`: the argument file (KFIX3 item 0).
*
* A link line is limited by the SPAWNER's argv, not by ld: make
* hands a recipe MK_MAXARG (32) slots and sh's MAXARGV is 32, so
* a program whose line needs more words than 31 cannot be linked
* natively however small its pieces are. sh and more were both
* at 31 with none to spare, and every segment piece the planner
* cut, every liba module and every body module put after the
* last liba module costs one. Raising either cap is a design
* change (and MK_MAXARG, MAXARGV and the argv block are shared
* by every program); an argument file removes the limit at the
* one program that reads a long list.
*
*   ld @NAME      argv[1] is `@NAME` and nothing follows it:
*                 the words of file NAME, separated by blanks
* and
*                 line ends, replace argv[1..] before the
* ordinary
*                 argument loop runs. The loop cannot tell the
*                 difference, so every flag works in the file.
*
* WHERE THE WORDS GO. The strings stay in ARGFBUF (ld's arena,
* so
* a pointer to one -- `-o`'s OBJPTR, which ABORTOUT still reads
* after pass 2 -- stays good for the whole run) and the pointers
* are written over the kernel's argv array, ARGV, which ld never
* reads for anything else. ARGV_PTR_LIM is 255 bytes for argv
* AND
* envp, so at most ARGFMAXW-1 words (ARGFMAXW*2 <= 255).
*
* A word is a run of bytes >= $A1 (high-bit printable); anything
* below -- space, CR, LF, tab -- separates, which is what a
* staged
* text file (CR line ends, bit 7 set) holds. NAME is resolved
* like a module name (MKPATH), so a cwd-relative name works.
*
* A file that fills ARGFBUF is refused, not truncated (the same
* rule READTAIL applies to a dictionary): a link line cut in
* half
* links something else.
*
* CLOBBERS: A, X, Y, PTR0, PTR1, PATHBUF.
*---------------------------------------------------------------
ARGFILE     lda   ARGC
            cmp   #2
            bcs   :have
:none       rts
:fail       lda   #<PATHBUF         ;names the file
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            lda   #<M_ARGF
            ldx   #>M_ARGF
            jsr   SAYWHAT
            lda   #1
            jsr   EXIT
:have       lda   #1
            jsr   GETARG            ;PTR0 = argv[1]
            ldy   #0
            lda   (PTR0),y
            cmp   #ARGF_AT          ;'@' high-bit
            bne   :none
            lda   ARGC
            cmp   #2
            beq   :one
            jmp   USAGE             ;nothing may follow
:one        inc   PTR0              ;past the @
            bne   :nw
            inc   PTR0+1
:nw         lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :fail
            lda   OPARM_REF
            sta   RPARM_REF
            sta   CPARM_REF
            lda   #<ARGFBUF
            sta   RPARM_BUF
            lda   #>ARGFBUF
            sta   RPARM_BUF+1
            lda   #<ARGFLIM
            sta   RPARM_REQ
            lda   #>ARGFLIM
            sta   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            php                     ;read's carry survives the
            lda   #<CPARM           ;  close
            ldx   #>CPARM
            jsr   SC_CLOSE
            plp
            bcs   :fail
            lda   RPARM_TRN         ;a full buffer
            cmp   #<ARGFLIM
            bne   :fits
            lda   RPARM_TRN+1
            cmp   #>ARGFLIM
            bne   :fits
            jmp   :fail
:fits       clc
            lda   RPARM_TRN
            adc   #<ARGFBUF
            sta   PTR0
            lda   RPARM_TRN+1
            adc   #>ARGFBUF
            sta   PTR0+1
            lda   #0
            sta   (PTR0)            ;the buffer's own terminator
            lda   #<ARGFBUF
            sta   PTR0
            lda   #>ARGFBUF
            sta   PTR0+1
*-- one pass: a blank or line end becomes $20, anything else
*-- gets bit 7 (the file may be TXT or high-bit)
:cv         lda   (PTR0)
            beq   :cvd
            and   #$7F
            cmp   #$21
            bcs   :cvw
            lda   #$20
            bra   :cvs
:cvw        ora   #$80
:cvs        sta   (PTR0)
            jsr   :step
            bra   :cv
:cvd        lda   #<ARGFBUF
            sta   PTR0
            lda   #>ARGFBUF
            sta   PTR0+1
            ldx   #1                ;argv[0] is ld's own name
:next       lda   (PTR0)
            beq   :done
            cmp   #ARGF_WORD
            bcs   :word
            jsr   :step             ;a separator
            bra   :next
:word       cpx   #ARGFMAXW
            bcc   :room
            jmp   :fail
:room            txa
            asl   a
            tay
            lda   PTR0
            sta   ARGV,y
            lda   PTR0+1
            sta   ARGV+1,y
            inx
:eow        jsr   :step
            lda   (PTR0)
            beq   :done
            cmp   #ARGF_WORD
            bcs   :eow
            lda   #0                ;end the word in place
            sta   (PTR0)
            jsr   :step
            bra   :next
:done       stx   ARGC
            rts
:step       inc   PTR0
            bne   :stepd
            inc   PTR0+1
:stepd      rts
M_ARGF      asc   "ld: cannot read arguments from"
            dfb   0
