#!/usr/bin/env python3
"""Prove that two release-disk builds are byte-identical.

The release disk is build/full.po (docs/FULLDISK.md); it is built FROM
play.po, so building it twice rebuilds play.po twice too, and both
images are compared. The two child builds use deliberately different
host time zones. This gives the gate teeth against a2til's default
``datetime.now()`` metadata without a minute-long sleep: a file that was
not given the image timestamp differs immediately.

It also pins the SHIPPED file's shape (docs/RELEASE.md): the release is
the built volume plus exactly one zero block, because MAME's AppleIISd
refuses a 65,535-block file. This gate refuses every looser shape and
boots the packaged file in MAME -- and requires MAME to refuse the
unpadded one, so the reason for the extra block stays pinned.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

from build_release import (IMAGE_BYTES, RELEASE_FILE_BYTES, pad_for_release,
                           validate_image, validate_release_file)


ROOT = Path(__file__).resolve().parent.parent
PLAY = ROOT / "build" / "play.po"
IMAGE = ROOT / "build" / "full.po"


def build(timezone: str) -> tuple[bytes, bytes]:
    env = os.environ.copy()
    env["TZ"] = timezone
    # Both builds assemble liba with nas afresh: with the cache, the
    # second build would reuse the first's objects and the determinism
    # row would never compare nas with itself (build_full_image.py).
    env["FULL_LIBA_FRESH"] = "1"
    result = subprocess.run(
        ["make", "-s", "full-image"],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if result.returncode:
        print(result.stdout, end="")
        raise SystemExit(
            f"[check-release-image] FAIL: {timezone} build exited "
            f"{result.returncode}"
        )
    return PLAY.read_bytes(), IMAGE.read_bytes()


def first_difference(a: bytes, b: bytes) -> int:
    return next(
        (i for i, pair in enumerate(zip(a, b)) if pair[0] != pair[1]),
        min(len(a), len(b)),
    )


def mame_rows(built: bytes, shipped: bytes, scratch: str) -> None:
    """Boot the packaged file in MAME, and require MAME to refuse the
    unpadded one (scripts/check_mame.py's bye phase, one round trip)."""
    import check_mame as cm
    if cm.MAME is None:
        raise SystemExit("[check-release-image] FAIL: mame is not on PATH "
                         "(brew install mame); the packaged file's MAME "
                         "row cannot run")
    if not os.path.isdir(cm.ROMS):
        raise SystemExit("[check-release-image] FAIL: vendor/mameroms "
                         "missing -- run `make vendor-mame-roms`")
    sym = ROOT / "build" / "MAUXPLAY.SYSTEM_Output.txt"
    os.makedirs(cm.WORK, exist_ok=True)
    padded = Path(scratch) / "shipped.po"
    padded.write_bytes(shipped)
    problems, _hits, out = cm.bye_phase(str(padded), str(sym), False)
    if problems:
        print(out)
        raise SystemExit("[check-release-image] FAIL: the packaged "
                         "(65,536-block) file does not boot in MAME: "
                         + "; ".join(problems))
    unpadded = Path(scratch) / "unpadded.po"
    unpadded.write_bytes(built)
    problems, _hits, out = cm.bye_phase(str(unpadded), str(sym), False)
    if not problems or "not supported by SD or SDHC" not in out:
        print(out)
        raise SystemExit("[check-release-image] FAIL: MAME did not refuse "
                         "the unpadded 65,535-block file -- the reason the "
                         "release is one block longer than its volume no "
                         "longer holds; re-read docs/RELEASE.md")
    print("[check-release-image] MAME 0.286 a2sd: the packaged 65,536-block "
          "file boots and completes a bye round trip; the unpadded "
          "65,535-block file is refused (\"not supported by SD or SDHC\")")


def prerequisites() -> None:
    """Everything the MAME rows need, checked BEFORE the two ~70 s image
    builds: this gate used to say vendor/mameroms was missing only after
    ~140 s of building (RC-1 F8)."""
    import check_mame as cm
    missing = []
    if cm.MAME is None:
        missing.append("mame is not on PATH (brew install mame; the "
                       "packaged file's MAME row cannot run)")
    absent = [z for z in ("apple2ee.zip", "a2ultrme.zip", "a2sd.zip",
                          "a2mouse.zip")
              if not os.path.isfile(os.path.join(cm.ROMS, z))]
    if absent:
        missing.append(f"vendor/mameroms lacks {', '.join(absent)} (make vendor-mame-roms "
                       "builds it from the provisioned verilogapple ROM "
                       "tree, which needs ultraterm/pal_u4_v3.jed from "
                       "ROM_DIR; `make check-release-image` does it for you)")
    if missing:
        raise SystemExit("[check-release-image] FAIL: missing before any "
                         "build: " + "; ".join(missing))


def main() -> int:
    prerequisites()
    play1, first = build("UTC0")
    play2, second = build("HST10")
    validate_image(IMAGE)
    # Exercise the packager's size/header refusals without tagging or writing
    # a release bundle. Do not mutate the user's built image.
    with TemporaryDirectory(prefix="maux-release-image-") as scratch:
        probe = Path(scratch) / "invalid.po"
        for label, data in (
            ("old 800K size", first[:819_200]),
            ("old 4 MiB play-image size", play1),
            ("truncated image", first[:-512]),
            ("wrong volume header", first[:1065] + b"\x40\x06" + first[1067:]),
        ):
            probe.write_bytes(data)
            try:
                validate_image(probe)
            except SystemExit:
                pass
            else:
                raise SystemExit(f"[check-release-image] FAIL: accepted {label}")
    # -- the SHIPPED file: exactly the volume + one zero block
    shipped = pad_for_release(first)
    with TemporaryDirectory(prefix="maux-release-file-") as scratch:
        probe = Path(scratch) / "release.po"
        probe.write_bytes(shipped)
        validate_release_file(probe)                  # the good shape passes
        bad_header = bytearray(shipped)
        bad_header[1065:1067] = (65536 & 0xFFFF).to_bytes(2, "little")
        nonzero_pad = bytearray(shipped)
        nonzero_pad[-1] = 1
        for label, data in (
            ("release file with no pad (the built shape)", first),
            ("release file two blocks long", shipped + bytes(512)),
            ("release file one byte long", shipped + b"\0"),
            ("release file with a non-zero pad", bytes(nonzero_pad)),
            ("release file whose header grew with it", bytes(bad_header)),
            ("release file of the old 4 MiB size", play1),
        ):
            probe.write_bytes(data)
            try:
                validate_release_file(probe)
            except SystemExit:
                pass
            else:
                raise SystemExit(f"[check-release-image] FAIL: the release "
                                 f"validator accepted {label}")
        # the BUILT validator must not accept the shipped shape either:
        # the two shapes are different files for different readers
        probe.write_bytes(shipped)
        try:
            validate_image(probe)
        except SystemExit:
            pass
        else:
            raise SystemExit("[check-release-image] FAIL: the built-image "
                             "validator accepted the padded file")
        mame_rows(first, shipped, scratch)
    if play1 != play2:
        raise SystemExit(
            "[check-release-image] FAIL: play.po depends on host state; "
            f"first difference at byte {first_difference(play1, play2)}"
        )
    if first != second:
        raise SystemExit(
            "[check-release-image] FAIL: full.po depends on host state; "
            f"first difference at byte {first_difference(first, second)} "
            f"(sizes {len(first)} and {len(second)})"
        )
    vol_digest = hashlib.sha256(first).hexdigest()
    ship_digest = hashlib.sha256(shipped).hexdigest()
    print(f"[check-release-image] PASS: built volume {IMAGE_BYTES} bytes, "
          f"shipped file {RELEASE_FILE_BYTES} bytes; size/header/pad "
          f"refusals; MAME takes the shipped file and refuses the unpadded "
          f"one; two builds (nas run afresh in each) byte-identical")
    print(f"[check-release-image] sha256 of the built volume "
          f"(build/full.po): {vol_digest}")
    print(f"[check-release-image] sha256 of the SHIPPED file (the one in "
          f"SHA256SUMS): {ship_digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
