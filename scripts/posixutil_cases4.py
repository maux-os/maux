#!/usr/bin/env python3
r"""posixutil_cases4.py -- CASES4/KNOWN_GAPS4 for `patch`
(src/bin/patch.s + patchio/patchtgt/patchwr/patchhnk/patchprs/
patchapp.s), and the one `diff` row that closes the loop by feeding
maux's own `diff -u` output straight into it.

Round 4, kept a separate module for the same reason as rounds 2 and 3:
one gate, one summary line, unchanged format, no single file growing
past a comfortable edit. check_posixutil.py imports this and appends
CASES4 onto its own CASES.

WHY EVERY PATCH ROW IS `hand=`, once, instead of in each `reason=`:

  patch(1) reports what it did on STANDARD OUTPUT ("patching file F",
  and on a failure a line naming the reject file), and this suite
  compares stdout BYTE-EXACT against a host run. The two reference
  implementations do not agree on that text -- BSD (this Mac's
  /usr/bin/patch, 2.0-12u11-Apple) writes "1 out of 1 hunks
  failed--saving rejects to F.rej" where GNU (the Linux box's, where
  the same suite also runs) writes "1 out of 1 hunk FAILED -- saving
  rejects to file F.rej" -- so no single expected-stdout string can be
  right on both hosts. maux writes its own progress line to fd 2
  instead, exactly as every other util in this tree reports itself, so
  its redirected stdout is EMPTY and the assertion moves to where
  POSIX actually specifies behaviour: the CONTENT OF THE FILES.
  `results=` carries that, and mkdir's own '-p creates missing
  intermediate components' row is the precedent for asserting a
  filesystem side effect this way.

  The expected file contents are NOT captured from a maux run. Every
  one was produced by running this host's own /usr/bin/patch over the
  SAME fixture and the SAME argv while these rows were written
  (scratch harness, 2026-09-17): the patched file, the .orig, the
  .rej and the untouched original in the -o case all came back exactly
  as written below, including the reject file's contents -- BSD patch
  writes a rejected unified hunk as the "@@" line plus its body,
  verbatim, which is what patchwr.s's REJPUT does too.

  The one DELIBERATE divergence from this host is `.orig`: BSD patch
  saves one unconditionally, POSIX makes it conditional on -b, and
  maux follows POSIX. The '-b saves the original' row asserts the
  file's contents; there is no row asserting its ABSENCE without -b,
  because a2til read-back of a missing file and a failed read are the
  same None here -- it is stated in docs/man/patch.1 instead.
"""


def C(tool, name, spec, argv, *, files=None, dirs=None, predirs=None,
      stdin=None, results=None, post=None, hand=None, known_gap=None,
      reset=None, norm=None):
    return dict(tool=tool, name=name, spec=spec, argv=list(argv),
                files=files or {}, dirs=dirs or {},
                predirs=list(predirs or []), stdin=stdin,
                results=list(results or []), post=list(post or []),
                hand=hand, known_gap=known_gap, reset=reset, norm=norm)


#: The one fixture every row shares: five unique lines, one of them
#: changed. Unique lines mean the hunk can only match in one place, so
#: a row that passes says the MATCHER found the right line, not that
#: two candidates happened to tie.
PA = ['alpha', 'bravo', 'charlie', 'delta', 'echo']
PB = ['alpha', 'BRAVO', 'charlie', 'delta', 'echo']
#: ...the same file with that line DELETED rather than changed,
#: which is what makes a context diff's second section empty.
PD = ['alpha', 'charlie', 'delta', 'echo']
#: ...and a file the patch cannot possibly apply to.
PZ = ['quebec', 'romeo', 'sierra', 'tango', 'uniform']

#: The same change written in all three forms patch must detect.
UPATCH = ['--- F', '+++ F',
          '@@ -1,5 +1,5 @@',
          ' alpha', '-bravo', '+BRAVO', ' charlie', ' delta', ' echo']
CPATCH = ['*** F', '--- F',
          '***************',
          '*** 1,5 ****',
          '  alpha', '! bravo', '  charlie', '  delta', '  echo',
          '--- 1,5 ----',
          '  alpha', '! BRAVO', '  charlie', '  delta', '  echo']
#: a context diff of a pure DELETION: its second section is its
#: header line and nothing else (captured from this host's diff -c).
CDPATCH = ['*** F', '--- F',
           '***************',
           '*** 1,5 ****',
           '  alpha', '- bravo', '  charlie', '  delta', '  echo',
           '--- 1,4 ----']
NPATCH = ['2c2', '< bravo', '---', '> BRAVO']
#: TWO hunks, the first of which shortens the file -- so the second
#: hunk's stated line number is NOT where its text is any more.
MA = ['l%02d' % i for i in range(1, 13)]
MB = ['l01', 'l03', 'l04', 'l05', 'l06', 'l07', 'l08', 'l09',
      'CHANGED', 'l11', 'l12']
MPATCH = ['--- F', '+++ F',
          '@@ -1,5 +1,4 @@',
          ' l01', '-l02', ' l03', ' l04', ' l05',
          '@@ -7,6 +6,6 @@',
          ' l07', ' l08', ' l09', '-l10', '+CHANGED', ' l11', ' l12']
#: and a unified one whose header names carry a directory, for -p.
PPATCH = ['--- a/F', '+++ b/F',
          '@@ -1,5 +1,5 @@',
          ' alpha', '-bravo', '+BRAVO', ' charlie', ' delta', ' echo']
#: what a rejected UPATCH hunk leaves behind, host-verified.
UREJ = ['@@ -1,5 +1,5 @@',
        ' alpha', '-bravo', '+BRAVO', ' charlie', ' delta', ' echo']

_WHY = ('stdout is not the assertion here -- see this module\'s own '
        'docstring: patch(1) reports itself on stdout in words BSD '
        'and GNU spell differently, maux reports on fd 2 instead, and '
        'the specified behaviour is the CONTENT of the files, which '
        'results= compares. The expected contents below were produced '
        'by running this host\'s own /usr/bin/patch over the same '
        'fixture and argv, not captured from maux.')


CASES4 = [
    # ==================================================================
    # patch -- XCU patch.html
    # ==================================================================
    C('patch', 'a unified diff is detected and applied',
      'The patch utility shall read a source (patch) file containing '
      'any of the three forms of difference (diff) listing produced '
      'by the diff utility... and apply those differences',
      ['-i', '@P@', '@F@'],
      files={'F': PA, 'P': UPATCH}, results=['F'],
      hand=dict(stdout=[], rc=0, files={'F': PB}, reason=_WHY)),
    C('patch', 'a context diff is detected and applied',
      '...any of the three forms of difference (diff) listing '
      'produced by the diff utility',
      ['-i', '@P@', '@F@'],
      files={'F': PA, 'P': CPATCH}, results=['F'],
      hand=dict(stdout=[], rc=0, files={'F': PB}, reason=_WHY)),
    C('patch', 'a context diff whose second section is header-only',
      '...any of the three forms of difference (diff) listing '
      'produced by the diff utility',
      ['-i', '@P@', '@F@'],
      files={'F': PA, 'P': CDPATCH}, results=['F'],
      hand=dict(stdout=[], rc=0, files={'F': PD},
                reason=_WHY + ' This listing is what a real `diff -c` '
                              'writes for a pure DELETION: the '
                              '"--- 1,4 ----" section has no body at '
                              'all, so the new text is not in the '
                              'patch -- it has to be rebuilt from the '
                              'first section\'s own context lines '
                              '(patchprs.s RECONNEW). Captured from '
                              'this host\'s diff -c, then applied '
                              'with this host\'s patch.')),
    C('patch', 'a normal diff is detected and applied',
      '...any of the three forms of difference (diff) listing '
      'produced by the diff utility',
      ['-i', '@P@', '@F@'],
      files={'F': PA, 'P': NPATCH}, results=['F'],
      hand=dict(stdout=[], rc=0, files={'F': PB}, reason=_WHY)),
    C('patch', 'two hunks, the second one shifted by the first',
      'The patch utility shall... apply those differences',
      ['-i', '@P@', '@F@'],
      files={'F': MA, 'P': MPATCH}, results=['F'],
      hand=dict(stdout=[], rc=0, files={'F': MB},
                reason=_WHY + ' Every other row here carries ONE hunk, '
                              'which never exercises the correction '
                              'that makes a multi-hunk patch work: the '
                              'first hunk DELETES a line, so the '
                              'second one\'s stated start (7) is one '
                              'line further along than where its text '
                              'now sits. patchapp.s carries that in '
                              'two unsigned cursors rather than a '
                              'signed offset. Captured from this '
                              'host\'s diff -u and applied with this '
                              'host\'s patch.')),
    C('patch', 'the patch is read from standard input by default',
      'If the -i option is not specified, the patch file shall be '
      'read from the standard input.',
      ['@F@'],
      files={'F': PA, 'P': UPATCH}, stdin='P', results=['F'],
      hand=dict(stdout=[], rc=0, files={'F': PB}, reason=_WHY)),
    C('patch', '-R applies the patch backwards',
      '-R Specify that the patch file contains differences which have '
      'the old and new files interchanged.',
      ['-R', '-i', '@P@', '@F@'],
      files={'F': PB, 'P': UPATCH}, results=['F'],
      hand=dict(stdout=[], rc=0, files={'F': PA}, reason=_WHY)),
    C('patch', 'a hunk that does not match is rejected, exit 1',
      'If the hunk cannot be applied, patch shall... write the hunk '
      'to the reject file... 1 One or more lines were written to a '
      'reject file.',
      ['-i', '@P@', '@F@'],
      files={'F': PZ, 'P': UPATCH, 'F.rej': None},
      results=['F', 'F.rej'],
      hand=dict(stdout=[], rc=1, files={'F': PZ, 'F.rej': UREJ},
                reason=_WHY + ' The reject file\'s own contents are '
                              'host-verified too: BSD patch writes a '
                              'rejected unified hunk as its "@@" line '
                              'plus its body, verbatim, exactly as '
                              'patchwr.s REJPUT does.')),
    C('patch', '-b saves the unpatched original as .orig',
      '-b Save a copy of the original contents of each modified file, '
      'before the differences are applied, in a file of the same name '
      'with the suffix .orig appended to it.',
      ['-b', '-i', '@P@', '@F@'],
      files={'F': PA, 'P': UPATCH, 'F.orig': None},
      results=['F', 'F.orig'],
      hand=dict(stdout=[], rc=0, files={'F': PB, 'F.orig': PA},
                reason=_WHY)),
    C('patch', '-o writes elsewhere and leaves the original alone',
      '-o outfile Instead of modifying the files (specified by the '
      'file operand or the difference listings) directly, write a '
      'copy of the file referenced by each patch, with the '
      'appropriate differences applied, to outfile.',
      ['-o', '@G@', '-i', '@P@', '@F@'],
      files={'F': PA, 'P': UPATCH, 'G': None}, results=['F', 'G'],
      hand=dict(stdout=[], rc=0, files={'F': PA, 'G': PB},
                reason=_WHY)),
    C('patch', '-p1 strips one component off the header pathname',
      '-p num For all pathnames in the patch file that indicate the '
      'names of files to be patched, delete num pathname components '
      'from the beginning of each pathname.',
      ['-p', '1', '-i', '@P@'],
      files={'F': PA, 'P': PPATCH}, results=['F'],
      hand=dict(stdout=[], rc=0, files={'F': PB},
                reason=_WHY + ' No file operand is given at all here, '
                              'so this row also proves the target is '
                              'taken from the patch header -- "a/F" '
                              'with one component stripped.')),
    C('patch', 'a patch file with no difference listing is an error',
      '2 An error occurred.',
      ['-i', '@P@', '@F@'],
      files={'F': PA, 'P': ['this is not a patch', 'nor is this']},
      results=['F'],
      hand=dict(stdout=[], rc=2, files={'F': PA},
                reason=_WHY + ' BSD patch on the same input exits 2 '
                              'with "I can\'t seem to find a patch in '
                              'there anywhere." and leaves F '
                              'untouched, which is what is asserted.')),

    # ==================================================================
    # diff + patch, the loop closed -- maux's own diff feeding maux's
    # own patch. The measured command is the diff; the post step is
    # the patch; the assertion is that the patched file is F2.
    # ==================================================================
    C('diff', 'round trip: patch applies what diff -u wrote',
      'The [diff] output... shall be sufficient to convert file1 into '
      'file2 [and] patch shall... apply those differences',
      ['-u', '@F1@', '@F2@'],
      files={'F1': PA, 'F2': PB},
      post=[['PATCH', '-i', 'OUT', '@F1@']],
      results=['F1'],
      hand=dict(stdout=['--- F1', '+++ F2', '@@ -1,5 +1,5 @@',
                        ' alpha', '-bravo', '+BRAVO', ' charlie',
                        ' delta', ' echo'],
                rc=1, files={'F1': PB},
                reason="the assertion is a filesystem side effect -- "
                       "maux's diff writes a unified patch to OUT, "
                       "then a `post` step runs maux's PATCH over it "
                       "in the same shell session, and F1 must come "
                       "back byte-identical to F2. oracle()'s host "
                       "path runs exactly ONE process per case and "
                       "never a post step (check_posixutil._host_once "
                       "has no such hook), so a post-verified result "
                       "is necessarily hand-authored, the same shape "
                       "as mkdir's '-p creates missing intermediate "
                       "components'. The expected stdout is maux's "
                       "own -u output for this fixture, which the "
                       "'-u unified context output' row above "
                       "compares against the host byte for byte (the "
                       "header lines carry no timestamp -- see "
                       "check_posixutil.NORMALIZERS)."),),
]

KNOWN_GAPS4 = [(c['tool'], c['name'], c['known_gap'])
               for c in CASES4 if c['known_gap']]
