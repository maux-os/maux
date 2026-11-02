*---------------------------------------------------------------
* nulib2msg.s -- nulib2's option string, its diagnostics and the
* two NuFX signature constants. `put` out of nulib2.s for the
* native assembler's source window: these are emitted data, so
* unlike the `dum` arena they can live in a put of their own.
*
* THEY NO LONGER HAVE TO SHARE A PAGE. Every site that names one
* passes the WHOLE pointer now -- see nulib2wlk.s's :fail for
* what went wrong when they did.
*---------------------------------------------------------------

NUOPTS      asc   'tvxpia0'
            dfb   0

*-- These no longer have to share a page: every site that names
*-- one passes the WHOLE pointer. They did once, with a note
*-- here claiming a gate enforced it. No gate existed, and
*-- the rename to `nulib2` broke it. See nulib2wlk.s's :fail.
TRUNCMSG    asc   'nulib2: archive ends early'
            dfb   $0D,0
NOTNUFX     asc   'nulib2: not a NuFX archive'
            dfb   $0D,0
TOOMANY     asc   'nulib2: too many records'
            dfb   $0D,0

BADMCRC     asc   'nulib2: master header CRC mismatch'
            dfb   $0D,0
NOTREC      asc   'nulib2: record header not found'
            dfb   $0D,0
BADATTR     asc   'nulib2: bad attrib_count'
            dfb   $0D,0
CANTOPEN    asc   'nulib2: cannot open '
            dfb   0
NONAME      asc   '(unnamed)'
            dfb   0
DISKTYP     asc   'Disk'
            dfb   0
USAGEMSG    asc   'usage: nulib2 -t|-v|-x|-p|-i archive'
            dfb   $0D
            asc   '       nulib2 -a archive file...'
            dfb   $0D,0

*-- nulib2ext.s's five warnings, which XWARN loads by LOW byte
*-- and pages from COMPRM -- so these five must share a page,
*-- exactly as TRUNCMSG's three do above.
COMPRM      asc   ': compressed, not extracted'
            dfb   $0D,0
BADTCRC     asc   ': thread CRC mismatch'
            dfb   $0D,0
NOSTAMPM    asc   ': extracted, type not set'
            dfb   $0D,0
NOCREATM    asc   ': cannot create'
            dfb   $0D,0
TOOBIGM     asc   ': too large to extract'
            dfb   $0D,0
BADSTRM     asc   ': damaged compressed stream'
            dfb   $0D,0
XPFX        asc   'nulib2: '
            dfb   0

WRERRM      asc   'nulib2: cannot write the archive'
            dfb   $0D,0
NOMAKEM     asc   'nulib2: cannot create the archive'
            dfb   $0D,0
CANTADDM    asc   ': cannot read, not added'
            dfb   $0D,0

MASTERID    dfb   $4E,$F5,$46,$E9,$6C,$E5
RECORDID    dfb   $4E,$F5,$46,$D8
