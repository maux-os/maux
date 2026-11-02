"""Enables `python3 -m serbridge` (run from tools/, or with tools/ on
$PYTHONPATH) as an alias for `python3 tools/serbridge/serbridge.py`.

Relative import (not `from serbridge import main`): the package and
the CLI module are both named "serbridge", so an absolute import here
would resolve to this package's own __init__ instead of serbridge.py.
"""
from .serbridge import main

if __name__ == "__main__":
    raise SystemExit(main())
