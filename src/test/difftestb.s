*---------------------------------------------------------------
* difftestb.s -- image body for difftest.s (`make check-diff`).
* Same one-boot-many-spawns shape as fleettestb.s: a single
* PARENT_PROC, real syscalls live, one process in bank 1.
*
* PARENT_PROC spawns `diff` directly ten times, table-driven (a
* CASETBL row per case: argv ptr, output-capture-file path ptr,
* which fd to dup [stdout for the nine ed-script-format/overflow
* cases plus the -e case, stderr for the overflow case's
* diagnostic], and where to stash the WAIT status). Each
* invocation's captured file is read back BYTE-EXACT by
* scripts/check_diff.py straight off the built .po image
* (prodos.read) -- fleettestb.s's own phase-1 mechanism, applied
* to every case instead of just a few, since diff's whole output
* IS the thing under test.
*
* After the ten `diff` runs, this builds one more file by hand
* (BUILD_EDIN): "r <A5path>\r" + the -e case's own captured
* output + "w <RESULTpath>\rq\r", then spawns `ed` with stdin
* dup'd from it (RUN_ED) -- the diff-e-then-ed round trip the
* task brief calls "the strongest possible proof". RESULT is
* read back by check_diff.py and compared to B5 byte-exact.
*---------------------------------------------------------------

* -- this harness's own zero page: one indirect pointer, for the
* -- table-driven CASETBL read below. Bank 1's own ZP (ALTZP),
* -- no conflict with anything -- this image links no liba.
ROWPTR      equ   $30    ;2
NCASES      equ   10

* Result addresses, page $13 -- python peeks these via aux
* bank1.
R_STATUS1   equ   $1300
R_STATUS2   equ   $1301
R_STATUS3   equ   $1302
R_STATUS4   equ   $1303
R_STATUS5   equ   $1304
R_STATUS6   equ   $1305
R_STATUS7   equ   $1306
R_STATUS8   equ   $1307
R_STATUS9   equ   $1308
R_ESTATUS   equ   $1309
R_EDSTATUS  equ   $130A
* -- one spawn pid per diff run, indexed by CASEI (sec 25/37's
* -- poison-between-runs gate needs to know which bank each
* -- run used -- a pid IS its bank), plus ed's own pid and the
* -- R_GO handshake (check_ls.py's WAIT_GO protocol).
R_PIDS      equ   $1310   ;10 bytes
R_EDPID     equ   $131A
R_GO_REQ    equ   $131B
R_GO        equ   $131C
R_DONE      equ   $1390
R_ERR       equ   $1391
R_STEP      equ   $1392

* Scratch, page $14 -- set per-call by CASETBL rows /
* BUILD_EDIN/RUN_ED, consumed by RUN_DIFF/OPEN_COMMON/
* CREATE_COMMON/CLOSE_COMMON/WRITELIT/COPYFILE.
CUR_ARGV    equ   $1400   ;2
CUR_OUTPATH equ   $1402   ;2
CUR_DUPFD   equ   $1404   ;1
CUR_STATAD  equ   $1405   ;2
CUR_PATH    equ   $1407   ;2
THISFD      equ   $1409   ;1
SRCFD       equ   $140A   ;1
DSTFD       equ   $140B   ;1
LIT_PTR     equ   $140C   ;2
LIT_LEN     equ   $140E   ;1
LIT_FD      equ   $140F   ;1
CASEI       equ   $1410   ;1
ROWOFF      equ   $1411   ;1

* MLI/spawn parmlists, page $15.
OPEN_PARM   equ   $1500   ;6:  count,path(2),iobuf(2),ref
CREAT_PARM  equ   $1510   ;12: count,path(2),acc,ftyp,aux(2),
                          ;    styp,cdate(2),ctime(2)
READ_PARM   equ   $1520   ;8:  count,ref,buf(2),req(2),trans(2)
WRITE_PARM  equ   $1530   ;8:  same shape as READ_PARM
CLOSE_PARM  equ   $1540   ;2:  count,ref
WAIT_PARM   equ   $1544   ;2:  status-store address
SPAWN_PARM  equ   $1548   ;6:  path(2),argv(2),fdactions(2)
FDA_BUF     equ   $1550   ;7:  DUP+CLOSE+END
IO_BUF      equ   $1560   ;128: COPYFILE's chunk buffer

*---------------------------------------------------------------
* Boot helpers -- identical shape to fleettestb.s's own.
*---------------------------------------------------------------
BOOT_CPY_PAR
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PARENT_PROC
            sta   K_BC_SRCADDR
            lda   #>PARENT_PROC
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #<PARENT_PROC
            sta   K_BC_DSTADDR
            lda   #>PARENT_PROC
            sta   K_BC_DSTADDR+1
            lda   #1
            sta   K_BC_DSTBANK
            lda   #<PAR_PROC_LEN
            sta   K_BC_LEN
            lda   #>PAR_PROC_LEN
            sta   K_BC_LEN+1
            jsr   BankCopy
            rts

PATCH_PAR_FRM
            lda   #1
            sta   BANKSEL
            sta   ALTZPAUX
            lda   #<PARENT_PROC
            sta   $01FE
            lda   #>PARENT_PROC
            sta   $01FF
            sta   ALTZPMAIN
            rts

NOIRQ       rts

ENTRY       sei
            cld
            ldx   #$FF
            txs

            ldy   #0
:banner     lda   BANNER,y
            sta   $0400,y
            iny
            cpy   #BANNER_END-BANNER
            bne   :banner

            jsr   INSTALL_COPY
            lda   #<NOIRQ
            sta   K_IRQ_HOOK
            lda   #>NOIRQ
            sta   K_IRQ_HOOK+1
            jsr   SCH_INIT
            lda   #1                       ;gates pin 40 cols:
            sta   TTY_BKND_REQ             ;auto = best 80 now
            jsr   PRC_INIT

            lda   #1
            jsr   PRC_STMP_BANK
            lda   #1
            jsr   PRC_SYNTH_FRM
            jsr   PATCH_PAR_FRM
            jsr   BOOT_CPY_PAR

            lda   #1
            ldx   #1
            jsr   SCH_CREATE
            jsr   SCH_START

BANNER      asc   "MAUX DIFFTEST"
BANNER_END

*---------------------------------------------------------------
* PARENT_PROC -- copied verbatim to the same address in bank 1
* (BOOT_CPY_PAR above), same reason fleettestb.s's own is.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_STEP
            stz   R_GO
            stz   R_GO_REQ
            stz   CASEI
:cloop      lda   CASEI
            cmp   #NCASES
            bcc   :dorow
            jmp   :alldone
:dorow      lda   CASEI
            asl   a
            asl   a
            asl   a             ;A = CASEI*8
            sec
            sbc   CASEI         ;A = CASEI*7 (row width)
            sta   ROWOFF
            clc
            lda   ROWOFF
            adc   #<CASETBL
            sta   ROWPTR
            lda   #0
            adc   #>CASETBL
            sta   ROWPTR+1
            ldy   #0
            lda   (ROWPTR),y
            sta   CUR_ARGV
            iny
            lda   (ROWPTR),y
            sta   CUR_ARGV+1
            iny
            lda   (ROWPTR),y
            sta   CUR_OUTPATH
            iny
            lda   (ROWPTR),y
            sta   CUR_OUTPATH+1
            iny
            lda   (ROWPTR),y
            sta   CUR_DUPFD
            iny
            lda   (ROWPTR),y
            sta   CUR_STATAD
            iny
            lda   (ROWPTR),y
            sta   CUR_STATAD+1
            lda   CASEI
            sta   R_STEP
            jsr   RUN_DIFF
            lda   CASEI
            cmp   #NCASES-1
            beq   :skipgo
            lda   CASEI
            clc
            adc   #1
            jsr   WAIT_GO
:skipgo     inc   CASEI
            jmp   :cloop
:alldone    lda   #NCASES
            sta   R_STEP
            jsr   BUILD_EDIN
            lda   #NCASES+1
            sta   R_STEP
            jsr   RUN_ED
            lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

*---------------------------------------------------------------
* WAIT_GO -- A = gap number (the diff run that just finished,
* 1-based). Same four-line park as src/test/lstestb.s's own
* WAIT_GO: publish the gap in R_GO_REQ, spin until
* scripts/check_diff.py writes the same number to R_GO -- which
* it does only after poisoning the bank that run used
* (docs/STICKY.md sec 25/37's poison-between-runs gate). A
* step-and-poll driver instead would race the next SYS_SPAWN;
* parking here cannot.
*---------------------------------------------------------------
WAIT_GO     sta   R_GO_REQ
:spin       cmp   R_GO
            bne   :spin
            rts

*---------------------------------------------------------------
* OPEN_COMMON/CREATE_COMMON -- IN: CUR_PATH = MLI pathname
* buffer. OPEN_COMMON OUT: A = fd. Both jmp P_ERR (no return) on
* MLI failure.
*---------------------------------------------------------------
OPEN_COMMON lda   CUR_PATH
            sta   OPEN_PARM+1
            lda   CUR_PATH+1
            sta   OPEN_PARM+2
            stz   OPEN_PARM+3
            stz   OPEN_PARM+4
            lda   #PCOUNT_OPEN
            sta   OPEN_PARM
            lda   #<OPEN_PARM
            ldx   #>OPEN_PARM
            ldy   #SYS_OPEN
            jsr   $FF00
            bcc   :openok
            jmp   P_ERR
:openok     lda   OPEN_PARM+5
            rts

CREATE_COMMON
            lda   CUR_PATH
            sta   CREAT_PARM+1
            lda   CUR_PATH+1
            sta   CREAT_PARM+2
            lda   #PCOUNT_CREATE
            sta   CREAT_PARM
            lda   #ACCESS_UNLKD
            sta   CREAT_PARM+3
            lda   #FTYPE_TXT
            sta   CREAT_PARM+4
            stz   CREAT_PARM+5
            stz   CREAT_PARM+6
            lda   #STYP_SEEDLING
            sta   CREAT_PARM+7
            stz   CREAT_PARM+8
            stz   CREAT_PARM+9
            stz   CREAT_PARM+10
            stz   CREAT_PARM+11
            lda   #<CREAT_PARM
            ldx   #>CREAT_PARM
            ldy   #SYS_CREAT
            jsr   $FF00
            bcc   :creatok
            jmp   P_ERR
:creatok    rts

* CLOSE_COMMON -- IN: A = fd. Errors ignored (best effort, same
* posture as ed.s's own w/close).
CLOSE_COMMON
            sta   CLOSE_PARM+1
            lda   #1
            sta   CLOSE_PARM
            lda   #<CLOSE_PARM
            ldx   #>CLOSE_PARM
            ldy   #SYS_CLOSE
            jsr   $FF00
            rts

*---------------------------------------------------------------
* RUN_DIFF -- IN: CUR_ARGV, CUR_OUTPATH, CUR_DUPFD, CUR_STATAD
* (set by the CASETBL loop above). CREATE+OPEN CUR_OUTPATH,
* spawn `diff` with CUR_ARGV and CUR_DUPFD dup'd onto that fd,
* WAIT, store the exit status at CUR_STATAD. jmp P_ERR (no
* return) on any MLI/spawn failure.
*---------------------------------------------------------------
RUN_DIFF    lda   CUR_OUTPATH
            sta   CUR_PATH
            lda   CUR_OUTPATH+1
            sta   CUR_PATH+1
            jsr   CREATE_COMMON
            jsr   OPEN_COMMON
            sta   THISFD

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   CUR_DUPFD
            sta   FDA_BUF+1
            lda   THISFD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   THISFD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            stz   FDA_BUF+6

            lda   #<DIFF_PATH
            sta   SPAWN_PARM
            lda   #>DIFF_PATH
            sta   SPAWN_PARM+1
            lda   CUR_ARGV
            sta   SPAWN_PARM+2
            lda   CUR_ARGV+1
            sta   SPAWN_PARM+3
            lda   #<FDA_BUF
            sta   SPAWN_PARM+4
            lda   #>FDA_BUF
            sta   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :spok1
            jmp   P_ERR
:spok1      cmp   #0
            bne   :spok2
            jmp   P_ERR
:spok2      ldx   CASEI
            sta   R_PIDS,x
            lda   THISFD
            jsr   CLOSE_COMMON

            lda   CUR_STATAD
            sta   WAIT_PARM
            lda   CUR_STATAD+1
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :waitok1
            jmp   P_ERR
:waitok1    rts

*---------------------------------------------------------------
* WRITELIT -- IN: LIT_PTR, LIT_LEN, LIT_FD. Writes LIT_LEN bytes
* from LIT_PTR to LIT_FD. jmp P_ERR (no return) on failure.
*---------------------------------------------------------------
WRITELIT    lda   LIT_FD
            sta   WRITE_PARM+1
            lda   LIT_PTR
            sta   WRITE_PARM+2
            lda   LIT_PTR+1
            sta   WRITE_PARM+3
            lda   LIT_LEN
            sta   WRITE_PARM+4
            stz   WRITE_PARM+5
            lda   #PCOUNT_WRITE
            sta   WRITE_PARM
            lda   #<WRITE_PARM
            ldx   #>WRITE_PARM
            ldy   #SYS_WRITE
            jsr   $FF00
            bcc   :wlok
            jmp   P_ERR
:wlok       rts

*---------------------------------------------------------------
* COPYFILE -- IN: SRCFD, DSTFD (both already open). Copies
* SRCFD's remaining bytes (128B chunks) to DSTFD, to EOF. jmp
* P_ERR (no return) on a write failure; a read failure/EOF just
* ends the copy.
*---------------------------------------------------------------
COPYFILE
:cloop2     lda   SRCFD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #128
            sta   READ_PARM+4
            stz   READ_PARM+5
            lda   #PCOUNT_READ
            sta   READ_PARM
            lda   #<READ_PARM
            ldx   #>READ_PARM
            ldy   #SYS_READ
            jsr   $FF00
            bcs   :cdone
            lda   READ_PARM+6
            ora   READ_PARM+7
            beq   :cdone
            lda   DSTFD
            sta   WRITE_PARM+1
            lda   #<IO_BUF
            sta   WRITE_PARM+2
            lda   #>IO_BUF
            sta   WRITE_PARM+3
            lda   READ_PARM+6
            sta   WRITE_PARM+4
            lda   READ_PARM+7
            sta   WRITE_PARM+5
            lda   #PCOUNT_WRITE
            sta   WRITE_PARM
            lda   #<WRITE_PARM
            ldx   #>WRITE_PARM
            ldy   #SYS_WRITE
            jsr   $FF00
            bcc   :cfok
            jmp   P_ERR
:cfok       jmp   :cloop2
:cdone      rts

*---------------------------------------------------------------
* BUILD_EDIN -- writes /mnt/MAUX/EDIN = "r /mnt/MAUX/A5\r" + the
* -e
* case's own captured output (/mnt/MAUX/OUTE) + "w
* /mnt/MAUX/RESULT\r
* q\r". The diff-e-then-ed round trip's INPUT half; see file
* header.
*---------------------------------------------------------------
BUILD_EDIN  lda   #<EDIN_PATH
            sta   CUR_PATH
            lda   #>EDIN_PATH
            sta   CUR_PATH+1
            jsr   CREATE_COMMON
            jsr   OPEN_COMMON
            sta   DSTFD

            lda   #<RPREFIX
            sta   LIT_PTR
            lda   #>RPREFIX
            sta   LIT_PTR+1
            lda   #15 ;"r /mnt/MAUX/A5"+CR, 15 bytes
            sta   LIT_LEN
            lda   DSTFD
            sta   LIT_FD
            jsr   WRITELIT

            lda   #<OUTE_PATH
            sta   CUR_PATH
            lda   #>OUTE_PATH
            sta   CUR_PATH+1
            jsr   OPEN_COMMON
            sta   SRCFD
            jsr   COPYFILE
            lda   SRCFD
            jsr   CLOSE_COMMON

            lda   #<RSUFFIX
            sta   LIT_PTR
            lda   #>RSUFFIX
            sta   LIT_PTR+1
            lda   #21                ;"w /mnt/MAUX/RESULT"+CR+
                                     ;"q"+CR, 21 bytes
            sta   LIT_LEN
            lda   DSTFD
            sta   LIT_FD
            jsr   WRITELIT

            lda   DSTFD
            jsr   CLOSE_COMMON
            rts

*---------------------------------------------------------------
* RUN_ED -- spawn `ed` with stdin dup'd from /mnt/MAUX/EDIN. Its
* own `w`/`q` commands (inside EDIN) do the rest: write
* /mnt/MAUX/RESULT, exit. R_EDSTATUS = ed's exit status.
*---------------------------------------------------------------
RUN_ED      lda   #<EDIN_PATH
            sta   CUR_PATH
            lda   #>EDIN_PATH
            sta   CUR_PATH+1
            jsr   OPEN_COMMON
            sta   THISFD

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   #FD_STDIN
            sta   FDA_BUF+1
            lda   THISFD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   THISFD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            stz   FDA_BUF+6

            lda   #<ED_PATH
            sta   SPAWN_PARM
            lda   #>ED_PATH
            sta   SPAWN_PARM+1
            lda   #<ED_ARGV
            sta   SPAWN_PARM+2
            lda   #>ED_ARGV
            sta   SPAWN_PARM+3
            lda   #<FDA_BUF
            sta   SPAWN_PARM+4
            lda   #>FDA_BUF
            sta   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :reok1
            jmp   P_ERR
:reok1      cmp   #0
            bne   :reok2
            jmp   P_ERR
:reok2      sta   R_EDPID
            lda   THISFD
            jsr   CLOSE_COMMON

            lda   #<R_EDSTATUS
            sta   WAIT_PARM
            lda   #>R_EDSTATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :reok3
            jmp   P_ERR
:reok3      rts

*---------------------------------------------------------------
* CASETBL -- 7 bytes/row: argv ptr(2), out-capture MLI path
* ptr(2), fd to dup onto(1), status-store addr(2). Cases 1-8 are
* the required contract shapes (identical/add/delete/change/
* multi-hunk/first-line/last-line/one-empty); 9 is the overflow
* trigger (stderr captured); 10 is the -e case feeding the round
* trip below.
*---------------------------------------------------------------
CASETBL
            da    ARGV1,OUT1_PATH
            dfb   FD_STDOUT
            da    R_STATUS1
            da    ARGV2,OUT2_PATH
            dfb   FD_STDOUT
            da    R_STATUS2
            da    ARGV3,OUT3_PATH
            dfb   FD_STDOUT
            da    R_STATUS3
            da    ARGV4,OUT4_PATH
            dfb   FD_STDOUT
            da    R_STATUS4
            da    ARGV5,OUT5_PATH
            dfb   FD_STDOUT
            da    R_STATUS5
            da    ARGV6,OUT6_PATH
            dfb   FD_STDOUT
            da    R_STATUS6
            da    ARGV7,OUT7_PATH
            dfb   FD_STDOUT
            da    R_STATUS7
            da    ARGV8,OUT8_PATH
            dfb   FD_STDOUT
            da    R_STATUS8
            da    ARGV9,OUT9_PATH
            dfb   FD_STDERR
            da    R_STATUS9
            da    ARGV10,OUTE_PATH
            dfb   FD_STDOUT
            da    R_ESTATUS

*---------------------------------------------------------------
* argv arrays -- da lists, NUL-pointer-terminated (2 zero
* bytes).
*---------------------------------------------------------------
ARGV1       da    DIFF_ARG0,A1PATH,B1PATH
            da    0
ARGV2       da    DIFF_ARG0,A2PATH,B2PATH
            da    0
ARGV3       da    DIFF_ARG0,A3PATH,B3PATH
            da    0
ARGV4       da    DIFF_ARG0,A4PATH,B4PATH
            da    0
ARGV5       da    DIFF_ARG0,A5PATH,B5PATH
            da    0
ARGV6       da    DIFF_ARG0,A6PATH,B6PATH
            da    0
ARGV7       da    DIFF_ARG0,A7PATH,B7PATH
            da    0
ARGV8       da    DIFF_ARG0,A8PATH,B8PATH
            da    0
ARGV9       da    DIFF_ARG0,A9PATH,B9PATH
            da    0
ARGV10      da    DIFF_ARG0,EARG,A5PATH,B5PATH
            da    0
ED_ARGV     da    ED_ARG0
            da    0

*---------------------------------------------------------------
* argv/spawn-path strings -- liba high-bit convention (confirmed
* empirically: merlin32's `asc "..."` emits high-bit-set bytes
* in this dialect, same as every src/bin/*.s string literal).
*---------------------------------------------------------------
DIFF_PATH   asc   "/bin/DIFF"
            dfb   0
DIFF_ARG0   asc   "DIFF"
            dfb   0
ED_PATH     asc   "/bin/ED"
            dfb   0
ED_ARG0     asc   "ED"
            dfb   0
EARG        asc   "-e"
            dfb   0
A1PATH      asc   "/mnt/MAUX/A1"
            dfb   0
B1PATH      asc   "/mnt/MAUX/B1"
            dfb   0
A2PATH      asc   "/mnt/MAUX/A2"
            dfb   0
B2PATH      asc   "/mnt/MAUX/B2"
            dfb   0
A3PATH      asc   "/mnt/MAUX/A3"
            dfb   0
B3PATH      asc   "/mnt/MAUX/B3"
            dfb   0
A4PATH      asc   "/mnt/MAUX/A4"
            dfb   0
B4PATH      asc   "/mnt/MAUX/B4"
            dfb   0
A5PATH      asc   "/mnt/MAUX/A5"
            dfb   0
B5PATH      asc   "/mnt/MAUX/B5"
            dfb   0
A6PATH      asc   "/mnt/MAUX/A6"
            dfb   0
B6PATH      asc   "/mnt/MAUX/B6"
            dfb   0
A7PATH      asc   "/mnt/MAUX/A7"
            dfb   0
B7PATH      asc   "/mnt/MAUX/B7"
            dfb   0
A8PATH      asc   "/mnt/MAUX/A8"
            dfb   0
B8PATH      asc   "/mnt/MAUX/B8"
            dfb   0
A9PATH      asc   "/mnt/MAUX/A9"
            dfb   0
B9PATH      asc   "/mnt/MAUX/B9"
            dfb   0

* -- BUILD_EDIN's two literal fragments (high-bit text, $8D CR).
RPREFIX     asc   "r /mnt/MAUX/A5"
            dfb   $8D
RSUFFIX     asc   "w /mnt/MAUX/RESULT"
            dfb   $8D
            asc   "q"
            dfb   $8D

*---------------------------------------------------------------
* Output-capture MLI pathname buffers -- length-prefixed, 7-bit
* per the MLI (see mli.equ header) -- built statically since
* every one is a fixed compile-time string, no runtime copy
* needed (unlike fleettestb.s's mutable SCRIPT_PATH).
*---------------------------------------------------------------
OUT1_PATH   dfb   14
            asc   "/mnt/MAUX/OUT1"
OUT2_PATH   dfb   14
            asc   "/mnt/MAUX/OUT2"
OUT3_PATH   dfb   14
            asc   "/mnt/MAUX/OUT3"
OUT4_PATH   dfb   14
            asc   "/mnt/MAUX/OUT4"
OUT5_PATH   dfb   14
            asc   "/mnt/MAUX/OUT5"
OUT6_PATH   dfb   14
            asc   "/mnt/MAUX/OUT6"
OUT7_PATH   dfb   14
            asc   "/mnt/MAUX/OUT7"
OUT8_PATH   dfb   14
            asc   "/mnt/MAUX/OUT8"
OUT9_PATH   dfb   14
            asc   "/mnt/MAUX/OUT9"
OUTE_PATH   dfb   14
            asc   "/mnt/MAUX/OUTE"
EDIN_PATH   dfb   14
            asc   "/mnt/MAUX/EDIN"

PAR_PROC_LEN equ   *-PARENT_PROC
