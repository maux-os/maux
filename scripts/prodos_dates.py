#!/usr/bin/env python3
"""prodos_dates.py -- one explicit timestamp for every ProDOS image the
tree builds and publishes (play.po, full.po, the demo images).

ProDOS directory entries carry minute-resolution wall-clock metadata and
a2til correctly defaults new entries to datetime.now(). That is useful for
an interactive filesystem and wrong for a release image: identical source
built in UTC and HST differed at byte 1055. Release media use one explicit
representable timestamp. Runtime-created files still receive the machine's
live clock in the ordinary way.

This is a small module of its own so that the builders (build_play_image,
build_full_image, build_demo_images) can share it without importing one
another: the demo films' freshness stamps bind every module a demo script
loads, and importing build_play_image would bind that file and everything it
imports (check_manifests) to every film booted from a demo image.
"""
from datetime import datetime
import os
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402

IMAGE_TIMESTAMP = datetime(2000, 1, 1, 0, 0)


def normalize_image_dates(image):
    """Set every directory header and entry date to IMAGE_TIMESTAMP.

    a2til's public metadata API covers file and directory entries. Directory
    headers carry a second creation field, so this narrowly uses the locked
    engine's directory resolver to normalise those headers in the same atomic
    edit. The release gate rebuilds under two time zones to keep this path
    load-bearing.
    """
    with prodos.Volume.edit(image) as volume:
        def visit(path):
            block = volume._resolve_dir(path)
            header = volume._dir_header(volume._dev.write_unit(block))
            header.creation = IMAGE_TIMESTAMP
            children = [(entry.name, entry.is_dir())
                        for entry in volume.scandir(path)]
            for name, is_dir in children:
                child = f'{path.rstrip("/")}/{name}'
                volume.set_file_info(
                    child,
                    creation=IMAGE_TIMESTAMP,
                    last_mod=IMAGE_TIMESTAMP,
                )
                if is_dir:
                    visit(child)

        visit(f'/{volume.name}')


def date_errors(image, limit=5):
    """Paths in `image` whose creation or modification date is not
    IMAGE_TIMESTAMP (read-only; [] for a normalised image). The cheap
    check of a built image: a clock-stamped entry is exactly what makes two
    builds differ."""
    bad = []
    vol = prodos.Volume(image, readonly=True)
    try:
        def visit(path):
            for entry in vol.scandir(path):
                child = f'{path.rstrip("/")}/{entry.name}'
                if entry.created != IMAGE_TIMESTAMP or \
                        entry.modified != IMAGE_TIMESTAMP:
                    bad.append(f'{child}: {entry.created} / '
                               f'{entry.modified}')
                    if len(bad) >= limit:
                        return
                if entry.is_dir():
                    visit(child)
                if len(bad) >= limit:
                    return

        visit(f'/{vol.name}')
    finally:
        vol.close()
    return bad
