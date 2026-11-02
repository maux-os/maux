*---------------------------------------------------------------
* readfold.s -- RD_FOLD, split out of readsyn.s (KFIX8,
* docs/KFIX8-NOTES.md sec 2). Only ls (lstop.s), mount and
* umount (mntcom.s) call it; the nine other programs that put
* readsyn.s carried its 13 bytes dead. A program that calls
* RD_FOLD puts this file; nothing else does.
*---------------------------------------------------------------
*-- RD_FOLD -- A = one raw path byte, returned 7-bit and folded
*-- to upper case -- the same rule procfile5.s's kernel-side
*-- PDEV_FOLD uses, duplicated here because liba and the kernel
*-- are separate assemblies. CLOBBERS: A.
RD_FOLD     and   #$7F
            cmp   #'a'
            bcc   :fdone
            cmp   #'z'+1
            bcs   :fdone
            and   #$DF
:fdone      rts
