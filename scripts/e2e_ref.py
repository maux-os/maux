#!/usr/bin/env python3
"""Host reference-binary resolution for e2e differential corpora.

Which host binary answered is provenance.  Search the explicit system
locations used by the filesystem corpus, record the result, and never
fall back to PATH.
"""
import os

REF_TOOL_PATHS = ('/bin', '/usr/bin')

_RESOLVED_REF_TOOLS = {}


def ref_tool(name):
    """Resolve `name` under REF_TOOL_PATHS, recording the chosen path."""
    for d in REF_TOOL_PATHS:
        path = os.path.join(d, name)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            _RESOLVED_REF_TOOLS[name] = path
            return path
    raise FileNotFoundError(
        f'no host reference binary named {name!r} found in '
        f'{REF_TOOL_PATHS} -- refusing to fall back to PATH')


def resolved_ref_tools():
    """{tool name: absolute path} for references invoked so far."""
    return dict(_RESOLVED_REF_TOOLS)
