"""noissue.py -- a copy of a play-family disk with /ETC/ISSUE removed.

The boot splash (docs/ISSUE.md) puts two lines on the glass above the
first prompt. A few gates measure the DISPLAY LAYER from a bare boot and
bake the prompt's position into their geometry (the prompt on row 0,
the hardware cursor at col 2 of row 0, where a `bye` farewell lands in
the text page). Those gates are about the console, not the greeting, so
they boot this copy. check-issue is the gate that boots the real disk
and asserts the splash itself; ask there before adding a caller here.
"""
import atexit
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos                                   # noqa: E402
import vpath                                               # noqa: E402,F401

ISSUE = '/mnt/MAUX/ETC/ISSUE'


def copy_without_issue(src):
    """Return the path of a scratch copy of `src` with no /etc/issue.
    The copy is removed at interpreter exit."""
    tmp = tempfile.mkdtemp(prefix='maux-noissue-')
    atexit.register(shutil.rmtree, tmp, True)
    dst = os.path.join(tmp, os.path.basename(src))
    shutil.copyfile(src, dst)
    prodos.mount(dst, replace=True)
    try:
        prodos.remove(ISSUE)
    finally:
        prodos.unmount('MAUX')
    return dst
