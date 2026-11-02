*---------------------------------------------------------------
* mli.s -- the liba/MLI string-encoding boundary. See mli.equ's
* header for why this conversion is mandatory, not stylistic:
* liba strings are high-bit-set (docs/USERLAND.md); ProDOS
* pathnames are 7-bit-clean, length-prefixed, NOT NUL-terminated
* (TRM ch. 2/4, confirmed live this round, not from memory).
*
* OUT: carry CLEAR = the source fit whole, <= MLI_PTH_MAXLN
* chars, copied verbatim (count byte = the real length, even
* when that length is exactly MLI_PTH_MAXLN -- the loop checks
* for the source's OWN terminator one slot past the last char
* copied, before it ever asks whether the 64-char cap was hit,
* so a legal 64-character pathname is never mistaken for an
* overflow). carry SET = the source was LONGER than
* MLI_PTH_MAXLN.
*
* On overflow this does NOT hand the caller a truncated -- and
* possibly coincidentally REAL -- prefix of the source. Measured
* on hardware: a 65-character argument silently cut to its first
* 64 named a real, different, SHORTER directory, and the
* caller's next MLI call SUCCEEDED on it (docs/E2E.md sec 10.6
* finding 1 -- two independent fixtures found this). Instead the
* LAST byte of the 64 already copied is overwritten with $00
* before the count byte is written. $00 can never be part of any
* real ProDOS directory-entry name (a catalog entry's name field
* holds exactly name_length characters from ProDOS's own legal
* set -- letters, digits, period -- nothing that ever wrote a
* name to a volume put a NUL byte in one), so the resulting
* 64-byte pathname cannot byte-match any catalog entry at ANY
* depth. Unlike a plain truncation it cannot land on a shorter,
* different, real object -- the very next MLI call this pathname
* feeds (OPEN/CREATE/DESTROY/RENAME/GET_FILE_INFO/SET_PREFIX)
* fails with its OWN carry-set/error-code return, the same path
* every one of MKPATH's 29 callers already checks after issuing
* that call. So this closes the defect for EVERY caller, not
* only the ones updated to check MKPATH's own carry first: a
* caller that ignores MKPATH's carry gets a clean "cannot
* access" from the MLI call it was always going to make, never a
* confident wrong answer.
*
* Deliberately does NOT leave the destination empty or garbage
* on overflow: some callers issue the MLI call and explicitly
* ignore ITS carry too (e.g. sh.s's DESTROY-ignore paths, rm.s's
* missing-file tolerance). Writing a well-formed MLI parameter
* list (a legal count byte, 64 bytes of data) that simply cannot
* resolve keeps that behaviour intact -- a malformed one would
* not.
*
* PRESERVES: X (never touched). CLOBBERS: A, Y, PTR2.
*
* IT IS ALSO WHERE "." / "./" / ".." / "../" ARE RESOLVED
* (2026-08-23). ProDOS has no such directory entries and cannot
* have any: its pathname PARSER requires a component to begin
* with a letter, so "." is not merely absent from a volume, it
* is unspeakable (learning:01M07G8WT2R3G2P87EK1DNPVYP). Nothing
* in maux substituted the cwd for them, so `find .`, `cat .` and
* `ls ./SED` all failed while `find /mnt/MAUX` worked -- the
* tools
* were fine and only the idiom was missing. This routine is the
* choke point 31 of 33 programs already funnel through, so one
* fix here covers the fleet. Full argument: docs/SH-DOTPATH.md.
*---------------------------------------------------------------
* Full design notes: L.MLI.TXT (docs/a2/)
*---------------------------------------------------------------

*---------------------------------------------------------------
* A NOTE ON THE CHARACTER CONSTANTS BELOW, because the polarity
* is inverted from the kernel's and both spellings assemble.
* Merlin's `"x"` IS the high-bit form ($AE for "."), and `'x'`
* is the low one ($2E) -- so the kernel's familiar `#"."+$80`
* idiom WRAPS back down to $2E, which is right there because
* PRC_PATHBUF is already a 7-bit ProDOS path. Here the SOURCE is
* a liba string, high-bit by convention, so the source compares
* are bare `#"."` / `#"/"`; MKP_POP scans GET_PREFIX's answer,
* which is 7-bit, so it uses `#'/'`. Measured, not remembered:
* `lda #"."+$80` assembles to A9 2E.
*---------------------------------------------------------------
MKPATH      stz   MKP_ADJ
            ldy   #0
            lda   (PTR0)
            cmp   #"."
            bne   :dst
            jsr   MKP_DOT         ;Y = source chars consumed;
                                  ;MKP_ADJ = destination bytes
                                  ;already written, MINUS Y
:dst        ldx   #0
            lda   MKP_ADJ
            bpl   :pos            ;MKP_ADJ is SIGNED: a pop past
            dex                   ;the dots it ate (../x from
                                  ;/bin/ is "/"+x) goes < 0
:pos        sec                   ;the +1 past the count byte
            adc   PTR1
            sta   PTR2            ;PTR2 = PTR1+1+MKP_ADJ, so one
            txa                   ;index Y walks the source AND
            adc   PTR1+1          ;the destination even though
            sta   PTR2+1          ;they sit at different offsets
:loop       tya
            clc
            adc   MKP_ADJ         ;characters written so far
            cmp   #MLI_PTH_MAXLN
            bcs   :atcap          ;total written hit the cap
            lda   (PTR0),y
            beq   :done
            and   #$7F             ;STRIPHI, inlined -- ProDOS
                                   ;wants 7-bit
            sta   (PTR2),y
            iny
            bne   :loop            ;Y wraps only past 256; the
                                   ;64 cap above always fires
                                   ;first
* -- Y+MKP_ADJ = MLI_PTH_MAXLN here: 64 characters already
* -- written. Peek ONE more source byte before calling this an
* -- overflow -- a source ending EXACTLY at the cap is legal and
* -- must not be flagged; that off-by-one would reject the
* -- longest pathname the MLI accepts.
:atcap      lda   (PTR0),y
            beq   :done             ;exactly 64 chars: legal
            dey                     ;the last byte this loop
                                    ;actually wrote
            lda   #0
            sta   (PTR2),y          ;corrupt it -- see header
            iny
            sec                     ;OUT: overflow
            bra   :cnt
:done       clc                     ;OUT: fit whole
* -- The count is Y+MKP_ADJ, not Y: a resolved dot run put
* -- MKP_ADJ bytes in the destination that Y never indexed. That
* -- add clobbers carry, which is this routine's OUT flag, so it
* -- is bracketed -- merging T4's carry contract with S2's dot
* -- resolution is exactly where that collision lives.
:cnt        php                     ;save the OUT carry
            tya
            clc
            adc   MKP_ADJ
            sta   (PTR1)            ;count byte, offset 0
            plp                     ;restore the OUT carry
            rts

*---------------------------------------------------------------
* MKP_DOT -- resolve a LEADING RUN of "." and ".." components.
*
* A run, not one: `cd ../..` already worked before this landed,
* through the kernel's own PRC_DOTDOT, and PRC_DOTDOT pops any
* number of leading "..". Resolving only the first here would
* have handed SET_PREFIX "/mnt/MAUX/.." and broken a case that
* was
* working -- so the loop is a compatibility requirement, not
* generosity. Scoped to the LEADING run for the same reason
* PRC_DOTDOT is: "A/../B" resolves nowhere; nothing types it.
*
* IN:  PTR0 -> the word, whose first character is "."; PTR1 ->
*      the destination buffer; MKP_ADJ = 0.
* OUT: Y = source characters consumed, MKP_ADJ = (bytes already
*      in the destination) - Y. Both come back 0 when the word
*      is not a dot idiom (".PROFILE", "..X"), when the cwd
*      cannot be read, or when the run is longer than the cwd it
*      is being subtracted from -- MKPATH then copies the word
*      literally and the caller's MLI call fails exactly as it
*      did before. That last case is what keeps MKP_ADJ
*      unsigned, so it is an arithmetic guard, not politeness.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MKP_DOT     jsr   MKP_PFX
            bcc   :bad
            ldx   #0               ;X = source chars consumed
:scan       txa
            tay
            lda   (PTR0),y
            cmp   #"."
            bne   :fin             ;an ordinary component: stop
            iny
            lda   (PTR0),y
            cmp   #"."
            beq   :dd
* -- "." or "./" ----------------------------------------------
            inx
            cmp   #0
            beq   :fin
            cmp   #"/"
            bne   :bad             ;".PROFILE" and friends
            inx
            bra   :scan
* -- ".." or "../" --------------------------------------------
:dd         iny
            lda   (PTR0),y         ;read BEFORE the pop:
            pha                    ;MKP_POP clobbers A and Y
            inx
            inx
            jsr   MKP_POP
            pla
            cmp   #0
            beq   :fin
            cmp   #"/"
            bne   :bad             ;"..X"
            inx
            bra   :scan
:fin        txa                    ;MKP_ADJ = length - consumed
            eor   #$FF
            sec
            adc   MKP_ADJ
            sta   MKP_ADJ
            txa
            tay
            rts
:bad        stz   MKP_ADJ          ;the prefix MKP_PFX wrote is
            ldy   #0               ;simply overwritten from zero
            rts

*---------------------------------------------------------------
* MKP_PFX -- write the cwd into the destination buffer. The MLI
* hands GET_PREFIX's answer back COUNT-PREFIXED and 7-bit, which
* is already exactly the shape MKPATH builds -- so this is a
* direct write into (PTR1), with no conversion at either end.
* OUT: carry SET and MKP_ADJ = the prefix length; carry CLEAR if
*      the call failed or the answer is too short to be a real
*      prefix ("/A/", three characters, is the shortest one that
*      can exist).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MKP_PFX     lda   #1
            sta   MKP_GPARM        ;param_count for GET_PREFIX
            lda   PTR1
            sta   MKP_GPARM+1      ;data_buffer = the caller's
            lda   PTR1+1           ;own pathname buffer
            sta   MKP_GPARM+2
            lda   #<MKP_GPARM
            ldx   #>MKP_GPARM
            jsr   SC_GETPFX
            bcs   :no
            lda   (PTR1)
            beq   :no
            sta   MKP_ADJ
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* MKP_POP -- drop the last component of the cwd now sitting in
* the destination, which is what ".." means.
*
* TRIMMING THE TEXT *IS* THE PARENT HERE, not an approximation
* of it: a ProDOS prefix is always absolute, and ProDOS has
* neither symbolic links nor a second hard link to a directory,
* so the lexical parent and the real parent cannot disagree.
* Walking the volume to find it would cost an MLI call per
* component and could not return a different answer.
*
* Lands on the PSEUDO-root "/" when no interior "/" is found --
* docs/DEVFS.md, 2026-09-30: "/" is now a REAL directory (unlike
* when this comment was first written, and Unix's own "cd /.."
* == "/" was modelled as a same-place clamp because ProDOS had
* no level above a volume to land on), so popping past a BARE
* volume root ("/mnt/MAUX/") or the synthetic "/dev/" -- both
* ONE
* component, no interior "/" -- must actually MOVE, not clamp.
* Found the hard way: the kernel's OWN PRC_DOTDOT/PRC_ROOTLIKE
* (procfile4.s/kdevblk.s) never fires for `cd ..` at all -- sh's
* CHCK_BLTN_CD (shparse.s) resolves ".." via MKPATH/THIS routine
* BEFORE ever calling SC_SETPFX, so the kernel only ever sees an
* already-popped absolute path, never a raw ".." to short-
* circuit.
* GET_PREFIX always answers with a trailing slash (docs/CD.md
* ruling 3), so the scan starts one character in from the end.
* CLOBBERS: A, Y. PRESERVES X.
*---------------------------------------------------------------
MKP_POP     ldy   MKP_ADJ          ;index of the trailing "/"
:back       dey
            cpy   #2
            bcc   :clamped         ;character 1 is the leading
                                   ;"/" -- no interior "/" found
            lda   (PTR1),y
            cmp   #'/'
            bne   :back
            bra   :store           ;keep the "/" we landed on
:clamped    ldy   #1               ;(PTR1)'s own byte 1 is
                                   ;ALREADY "/" (every prefix
                                   ;MKP_PFX writes starts with
                                   ;it), so only the length
                                   ;moves
:store      sty   MKP_ADJ
            rts
