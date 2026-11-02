*---------------------------------------------------------------
* cmdpath.s -- POSIX's rule for a command word that contains a
* slash: it is NEVER searched on PATH, and a relative one is
* taken against the current directory (KFIX10 items 3 and 4).
* sh's RSLV_PTH_STG and make's MK_SPAWN share this one routine.
* The PATH walk stays where it was: sh's BUILD_PATH reads the
* shell's own variable table, a child's PATHRSLV reads the
* environment (pathres.s says why they are two).
*
* Before this, `./hello` and `dir/hello` were looked up as
* /bin/./hello and /bin/dir/hello: "command not found" for the
* first thing the first lesson types
* (learning:01M59SNKKXY1C1006WK9CW33F7).
*
* CMDSLASH -- IN: PTR0 = a NUL-terminated command word (liba
*                  text, high-bit)
*                  PTR1 = a scratch buffer of 66 bytes (the
*                  count, 64 characters and the NUL)
* OUT: carry SET   no slash in the word: the caller searches
*                  PATH. PTR0 is unchanged.
*      carry CLEAR the word is a path, and PTR0 names what to
*                  spawn: an absolute word as typed; a relative
*                  one made absolute against the cwd, as a liba
*                  string at PTR1+1 (high-bit, always NUL-
*                  terminated, up to ProDOS's 64 characters).
*                  The kernel's spawn takes absolute paths only
*                  -- measured: `sub/hello` is refused where
*                  /mnt/MAUX/K/sub/hello runs -- and ProDOS
*                  cannot spell `.` or `..`. A word starting
*                  with '.' (`./x`, `../x`) goes through MKPATH,
*                  the resolution `cat ./x` already uses
*                  (docs/SH-DOTPATH.md), not a second resolver.
*                  Any other relative word (`dir/x`) is the cwd
*                  that MKPATH's own MKP_PFX fetches, then the
*                  word. A result over 64 characters is not
*                  built: the word comes back as typed and
*                  fails at the spawn.
* CLOBBERS: A, X, Y, PTR1, PTR2, MKPATH's.
*---------------------------------------------------------------
CMDSLASH    ldy   #0
:scan       lda   (PTR0),y
            beq   :bare
            cmp   #"/"
            beq   :slash
            iny
            bne   :scan
:bare       sec                          ;no slash: search PATH
            rts
:slash      lda   (PTR0)
            cmp   #"/"
            beq   :asis                  ;absolute: as typed
            cmp   #"."
            beq   :dot
*-- `dir/x`: the cwd, then the word
            jsr   MKP_PFX                ;PTR1 <- count + cwd
            bcc   :asis                  ;MKP_ADJ = its length
            lda   MKP_ADJ
            sec                          ;PTR2 = PTR1+1+MKP_ADJ:
            adc   PTR1                   ;one index Y walks the
            sta   PTR2                   ;word AND its landing
            lda   #0
            adc   PTR1+1
            sta   PTR2+1
            ldy   #0
:app        tya
            clc
            adc   MKP_ADJ
            cmp   #65
            bcs   :asis                  ;over 64: not built
            lda   (PTR0),y
            sta   (PTR2),y
            beq   :joined
            iny
            bne   :app
:joined     tya
            clc
            adc   MKP_ADJ
            sta   (PTR1)                 ;the count (MKPATH's)
            bra   :fix
:dot        jsr   MKPATH                 ;PTR0 -> PTR1, 7-bit;
            bcs   :asis                  ;it never moves PTR0
:fix        lda   (PTR1)                 ;the count
            tax
            ldy   #1
:hi         lda   (PTR1),y
            ora   #$80                   ;back to liba text
            sta   (PTR1),y
            iny
            dex
            bne   :hi
            lda   #0                     ;Y <= 65: in the buffer
            sta   (PTR1),y
            lda   PTR1                   ;PTR0 = PTR1+1
            clc
            adc   #1
            sta   PTR0
            lda   PTR1+1
            adc   #0
            sta   PTR0+1
            clc
            rts
:asis       clc
            rts
