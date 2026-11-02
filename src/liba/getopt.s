*---------------------------------------------------------------
* getopt.s -- option parsing for the utils: flags, and flags
* that take an argument.
*
* Every util shipped with "no flags in v1" hardcoded in its
* header, and in every case the DATA was already there -- wc
* counts lines, words and characters and prints all three; ls
* walks a directory entry it only reads the name out of. What
* was missing was a way to say which. This is that, once, so it
* is not reinvented per util.
*
* USAGE
*     lda   #<OPTLIST         ;permitted letters, high-bit
*     ldx   #>OPTLIST         ;ASCII, NUL-terminated
*     jsr   OPTINIT
* :optlp
*     jsr   GETOPT
*     bcs   :optdone          ;carry SET = no options left
*     cmp   #$EC              ;'l'
*     beq   :want_l
*     ...
*     jmp   :usage            ;anything else, incl. '?' ($BF)
* :optdone
*     ;-- OPTIND is now the first operand's argv index
*
* An unrecognised letter returns '?' ($BF) with the offender in
* OPTOPT, so a util can name it in its usage message.
*
* OPTION-ARGUMENTS. A letter in OPTLIST followed by ':' ($BA,
* high-bit) takes an argument, POSIX-style, either attached
* (`-eSCRIPT`) or separated (`-e SCRIPT`). On a match GETOPT
* still returns the letter in A with carry CLEAR, and points
* OPTARG (src/liba/libabss.s) at the argument text -- liba's
* usual NUL-terminated high-bit string. OPTARG is only good for
* the instant between that GETOPT and the next one; nothing
* preserves it across a second call. If a separated-form letter
* is the last word in argv -- no argument to take -- GETOPT
* returns '?' with OPTOPT set to the letter, the same shape as
* an unrecognised letter, so an existing `jmp :usage` on '?'
* already handles a missing argument too.
*
* SCOPE. Clustering works (`-lw` is `-l -w`) but only among
* flags that take no argument -- an argument-taking letter
* consumes the rest of its word (or the next word) and GETOPT
* starts a fresh word on the following call, the same as if
* `--` had ended a cluster there. `--` ends options. A bare `-`
* is an OPERAND, not an option, so the usual "read stdin"
* convention stays available.
*
* Strings are liba's high-bit-set convention (docs/USERLAND.md),
* so the comparisons below are against high-bit constants --
* '-' is $AD, not $2D. Same house style as sh.s's `cmp #$BC` for
* '<'.
*---------------------------------------------------------------

*---------------------------------------------------------------
* OPTINIT -- A/X = lo/hi of the permitted-letters string.
* Must be called before the first GETOPT.
*---------------------------------------------------------------
OPTINIT     sta   OPTPTR
            stx   OPTPTR+1
            lda   #1                 ;argv[0] is the name
            sta   OPTIND
            stz   OPTPOS
            stz   OPTOPT
            stz   OPTARG
            stz   OPTARG+1
            rts

*---------------------------------------------------------------
* GETOPT -- next option letter in A, carry CLEAR.
*   carry SET  = options exhausted; OPTIND indexes the first
*                operand.
*   A = '?'    = unrecognised; OPTOPT holds the letter.
*---------------------------------------------------------------
GETOPT      lda   OPTPOS
            bne   :cluster           ;mid `-lw`, keep going

            lda   OPTIND             ;start a fresh argv word
            jsr   GETARG             ;-> PTR0; carry = end
            bcs   :nomore
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD               ;'-' high-bit-set
            bne   :nomore            ;first non-option word
                                     ;ends option parsing
            iny
            lda   (PTR0),y
            beq   :nomore            ;bare "-" is an OPERAND
            cmp   #$AD               ;"--" ?
            bne   :first
            iny
            lda   (PTR0),y
            bne   :first             ;"--x": 'x' falls through
                                     ;to the unknown path
            inc   OPTIND             ;bare "--" ends options and
            bra   :nomore            ;is itself consumed
:first      lda   #1
            sta   OPTPOS
            bra   :fetch

:cluster    lda   OPTIND
            jsr   GETARG
            bcs   :nomore
:fetch      ldy   OPTPOS
            lda   (PTR0),y
            bne   :haveopt
            inc   OPTIND             ;cluster exhausted; advance
            stz   OPTPOS             ;to the next word
            bra   GETOPT

:haveopt    inc   OPTPOS
            sta   OPTOPT
            ldy   #0
*-- POLARITY-BLIND against the OPTION STRING, both here and on
*-- the ':' marker below. The letter from argv is high-bit today
*-- and the caller's own OPTLIST has had to match that, so every
*-- `asc "t:a:"` in the tree is a site of the encoding debt
*-- check-encoding counts. Masking bit 7 on the COMPARISON lets
*-- an OPTLIST be written either way while `:retok` still hands
*-- the caller the ORIGINAL argv byte -- so every existing
*-- `cmp #$F4` keeps working unchanged, and a new program can
*-- write its OPTLIST in the target encoding today. Bit 7 is not
*-- case (that is bit 5), so this merges $74 with $F4 and
*-- nothing else.
:vlp        lda   (OPTPTR),y
            beq   :unknown
            eor   OPTOPT
            and   #$7F
            beq   :ok
            iny
            bra   :vlp
:ok         iny                      ;peek OPTLIST's next byte
            lda   (OPTPTR),y
            and   #$7F
            cmp   #$3A               ;':' in either polarity
            bne   :retok
            jmp   :takesarg          ;bne/jmp trampoline -- kept
                                     ;out-of-line, see below
:retok      lda   OPTOPT
            clc
            rts
:unknown    lda   #$BF               ;'?' high-bit-set
            clc
            rts
:nomore     sec
            rts

* -- Argument-taking letter, out of line: inline here would push
* -- every early bcs/beq/bra above past the 6502's +/-127-byte
* -- branch range (the same branch/jmp trampoline shape as
* -- src/bin/find.s's :haveent and src/test/lstestb.s's
* -- FAIL_RB). Reached only from :ok's `jmp` above, so a plain
* -- fall-in from :vlp/:ok never happens.
*
* Attached if the current word has more left at OPTPOS, else
* separated: fetch the NEXT argv word and use all of it.
:takesarg   ldy   OPTPOS
            lda   (PTR0),y
            bne   :attached
            inc   OPTIND             ;this word is spent
            lda   OPTIND
            jsr   GETARG             ;-> PTR0; carry = no more
            bcc   :sepok
            jmp   :unknown           ;none left -- '?', same as
                                     ;an unrecognised letter
:sepok      lda   PTR0
            sta   OPTARG
            lda   PTR0+1
            sta   OPTARG+1
            inc   OPTIND             ;consume the arg word too
            stz   OPTPOS
            lda   OPTOPT
            clc
            rts

:attached   lda   PTR0               ;OPTARG = PTR0 + OPTPOS,
            clc                      ;a 16-bit add (may carry)
            adc   OPTPOS
            sta   OPTARG
            lda   PTR0+1
            adc   #0
            sta   OPTARG+1
            inc   OPTIND
            stz   OPTPOS
            lda   OPTOPT
            clc
            rts

* -- OPTIND (argv index examined), OPTPOS (offset in a cluster;
* -- 0 means not inside one) and OPTOPT (the offending letter on
* -- '?') used to be declared here as emitted `ds` text that
* -- OPTINIT/GETOPT then wrote -- writable text, which
* -- docs/STICKY.md sec 21 forbids. They are in
* -- src/liba/libabss.s's `dum` arena now (sec 25), alongside
* -- OPTARG (the current option-argument pointer, added when
* -- GETOPT learned option-arguments) -- never emitted here at
* -- all, for the same reason. OPTINIT writes all four and MUST
* -- still be called before the first GETOPT -- which every
* -- caller in the tree already does, in the exact idiom this
* -- file's header documents.
