#!/usr/bin/env python3
"""Build a non-overwriting, versioned maux release bundle.

A RELEASE needs a clean commit carrying the exact ``vVERSION`` tag, and
that refusal stays. A CANDIDATE (``--candidate``, ``make release-candidate``)
needs only a clean tree: it is named ``maux-X.Y.Z-rc-<shortsha>`` (bundle,
image and source archive alike) and its MANIFEST.json says
``"candidate": true, "tag": null``, so it can never be mistaken for the
release. Every other step is the same code path. The packager never
promotes: a release is made by tagging and running the release path again,
and the release path refuses a VERSION that already looks like a candidate
(``-rc-<hex>``), so a candidate's name cannot be reproduced as a release.
The boot image is built by Make before this script runs. Source comes from
``git archive`` -- so ignored build inputs and operator ROMs cannot leak
into it -- MINUS the paths ``scripts/check_publish.py --list`` names, which
is the same oracle and the same subtraction ``make public-tree`` performs.
Measured 2026-11-02, before that subtraction was wired in here: the 1.0
tarball carried 1044 of the 1045 not-ship paths -- the project's internal
notes and the withheld gate drivers among them.
A bundle is published, so the archive is the PUBLIC tree or it is a leak.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

from build_play_image import FULL_BLOCKS as VOL_BLOCKS
from build_play_image import RELEASE_FILE_BLOCKS


#: The release disk is build/full.po (docs/FULLDISK.md), a 65,535-block
#: ProDOS volume -- not the 8,192-block play.po the gates boot.
IMAGE_BYTES = VOL_BLOCKS * 512
VERSION_RE = re.compile(r"[0-9][0-9A-Za-z.-]*\Z")
#: What a candidate's name ends in. A release VERSION may not end in it
#: (case-insensitively), or a tagged release could carry a candidate's name.
CANDIDATE_RE = re.compile(r"-rc-[0-9a-f]{7,40}\Z", re.IGNORECASE)
#: Hex digits of the commit in a candidate's name.
SHORT_SHA = 12


def run(*args: str, cwd: Path, text: bool = True) -> str:
    result = subprocess.run(
        args,
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
    )
    return result.stdout.strip() if text else result.stdout


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"[release] ERROR: {message}")


def _header_blocks(data: bytes) -> int:
    return int.from_bytes(data[2 * 512 + 0x29:2 * 512 + 0x2B], "little")


def validate_image(image: Path) -> None:
    """Keep the BUILT disk's size and ProDOS header tied to the image
    builder: build/full.po, FULL_BLOCKS (65,535) blocks, the shape every
    gate and a2til use."""
    if not image.is_file():
        fail(f"boot image is missing: {image}")
    if image.stat().st_size != IMAGE_BYTES:
        fail(f"boot image is {image.stat().st_size} bytes, expected {IMAGE_BYTES}")
    with image.open("rb") as source:
        source.seek(2 * 512 + 0x29)
        blocks = int.from_bytes(source.read(2), "little")
    if blocks != VOL_BLOCKS:
        fail(f"boot image header declares {blocks} blocks, expected {VOL_BLOCKS}")


RELEASE_FILE_BYTES = RELEASE_FILE_BLOCKS * 512


def not_shipped(root):
    """The paths that must not reach a published tree, from the one oracle.

    `check_publish.py` with no arguments is the gate; `--list` is its
    machine mode (human output goes to stderr -- a banner on stdout once
    arrived as a 1042nd "path"). Both are
    required: a red gate means the pin lists no longer describe the tree,
    and subtracting a stale list is how a withheld file survives into a
    release.
    """
    checker = str(Path(root) / "scripts" / "check_publish.py")
    gate = subprocess.run([sys.executable, checker], cwd=root,
                          capture_output=True, text=True)
    if gate.returncode:
        raise RuntimeError(
            "check-publish is RED (exit %d) -- it is the only oracle for "
            "what may ship, and a release cannot be cut against a stale "
            "one. Run: make check-publish\n%s"
            % (gate.returncode, gate.stdout[-2000:]))
    out = subprocess.run([sys.executable, checker, "--list"], cwd=root,
                         capture_output=True, text=True)
    if out.returncode not in (0, 1):
        raise RuntimeError("check_publish.py --list failed: %s" % out.stderr[-2000:])
    paths = [line.strip() for line in out.stdout.splitlines() if line.strip()]
    tracked = set(run("git", "ls-files", cwd=root).split("\n"))
    strays = [p for p in paths if p not in tracked]
    if strays:
        raise RuntimeError(
            "check_publish.py --list named %d path(s) git does not track, "
            "so the list is not a path list any more: %s"
            % (len(strays), strays[:5]))
    if not paths:
        raise RuntimeError("check_publish.py --list named nothing; the "
                           "subtraction would be a no-op")
    return set(paths)


def public_source_archive(root, out_path, prefix, source_date):
    """Write the source tarball: `git archive HEAD` minus the not-ship set.

    Deterministic: members sorted, owner root:root, every mtime the
    commit date, gzip with no embedded timestamp -- so two runs at one
    commit produce identical bytes, which is what SHA256SUMS promises.
    """
    drop = not_shipped(root)
    stamp = int(time.mktime(time.strptime(source_date[:19],
                                          "%Y-%m-%dT%H:%M:%S")))
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp) / "tree"
        tree.mkdir()
        tar = subprocess.run(["git", "archive", "--format=tar", "HEAD"],
                             cwd=root, capture_output=True, check=True)
        subprocess.run(["tar", "-x", "-C", str(tree)], input=tar.stdout,
                       check=True)
        removed = 0
        for rel in sorted(drop):
            victim = tree / rel
            if victim.is_file() or victim.is_symlink():
                victim.unlink()
                removed += 1
            elif victim.is_dir():
                shutil.rmtree(victim)
                removed += 1
        if (tree / "gates.mk").exists():
            raise RuntimeError("gates.mk survived the subtraction; the "
                               "public Makefile would name absent scripts")
        members = sorted(q for q in tree.rglob("*") if q.is_file())
        left = [str(q.relative_to(tree)) for q in members]
        still = sorted(drop.intersection(left))
        if still:
            raise RuntimeError("not-ship path(s) survived into the source "
                               "archive: %s" % still[:5])
        # gzip's own header carries an mtime, and tarfile's "w:gz" fills
        # it with the clock, so the same commit would hash differently on
        # every run. Drive the gzip layer directly with mtime=0.
        with open(out_path, "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", compresslevel=9,
                               fileobj=raw, mtime=0) as gz:
                with tarfile.open(fileobj=gz, mode="w",
                                  format=tarfile.GNU_FORMAT) as tf:
                    for q in members:
                        rel = q.relative_to(tree).as_posix()
                        info = tf.gettarinfo(str(q), f"{prefix}{rel}")
                        info.uid = info.gid = 0
                        info.uname = info.gname = "root"
                        info.mtime = stamp
                        with open(q, "rb") as fh:
                            tf.addfile(info, fh)
    return removed, len(members)


def pad_for_release(built: bytes) -> bytes:
    """The shipped file: the built volume plus exactly one zero block.
    MAME's AppleIISd (an SD-card model) refuses a 65,535-block file, and
    ProDOS ignores a block past its header's total_blocks."""
    return built + bytes(512)


def validate_release_file(image: Path) -> None:
    """The SHIPPED file, and nothing looser: RELEASE_FILE_BLOCKS blocks
    exactly, the ProDOS volume header still saying FULL_BLOCKS, and the
    one block past the volume all zero. A file of any other length, a
    header that grew with the file, or a pad that is not zero is
    refused -- the pad is a packaging device, not room for anything."""
    if not image.is_file():
        fail(f"release file is missing: {image}")
    data = image.read_bytes()
    if len(data) != RELEASE_FILE_BYTES:
        fail(f"release file is {len(data)} bytes, expected "
             f"{RELEASE_FILE_BYTES} ({RELEASE_FILE_BLOCKS} blocks)")
    if _header_blocks(data) != VOL_BLOCKS:
        fail(f"release file header declares {_header_blocks(data)} blocks, "
             f"expected {VOL_BLOCKS} (the volume stays {VOL_BLOCKS}; only "
             f"the file is one block longer)")
    if any(data[VOL_BLOCKS * 512:]):
        fail("the trailing block of the release file is not all zero")


def verify_bundle(bundle: Path) -> int:
    """Check a finished bundle against itself: SHA256SUMS lists exactly
    the files present and every hash matches, and the NAME, the manifest
    and the member names agree about whether this is a candidate or a
    release. A candidate directory renamed to a release name (or a
    manifest flag flipped) is red here: the rename changes the directory
    but not the members' names, and the flag change breaks the hash."""
    problems: list[str] = []
    if not bundle.is_dir():
        fail(f"not a bundle directory: {bundle}")
    sums = bundle / "SHA256SUMS"
    if not sums.is_file():
        fail(f"{bundle.name}: no SHA256SUMS")
    listed: dict[str, str] = {}
    for line in sums.read_text(encoding="ascii").splitlines():
        digest, _, name = line.partition("  ")
        if len(digest) != 64 or not name or "/" in name:
            problems.append(f"malformed SHA256SUMS line: {line!r}")
            continue
        listed[name] = digest
    present = {p.name for p in bundle.iterdir() if p.name != "SHA256SUMS"}
    for name in sorted(present - set(listed)):
        problems.append(f"{name} is in the bundle but not in SHA256SUMS")
    for name in sorted(set(listed) - present):
        problems.append(f"{name} is in SHA256SUMS but missing")
    for name in sorted(set(listed) & present):
        if sha256(bundle / name) != listed[name]:
            problems.append(f"{name}: sha256 differs from SHA256SUMS")
    try:
        manifest = json.loads((bundle / "MANIFEST.json").read_text("utf-8"))
        name = bundle.name
        version, commit = manifest["version"], manifest["commit"]
        if manifest["candidate"] is True:
            want = f"maux-{version}-rc-{commit[:SHORT_SHA]}"
            if manifest["tag"] is not None:
                problems.append("a candidate manifest must say tag null")
        elif manifest["candidate"] is False:
            want = f"maux-{version}"
            if manifest["tag"] != f"v{version}":
                problems.append(f"a release manifest must say tag v{version}")
            if CANDIDATE_RE.search(version):
                problems.append("a release version may not look like a candidate")
        else:
            want = None
            problems.append("manifest 'candidate' is not a boolean")
        if want is not None and name != want:
            problems.append(f"directory is named {name!r} but its manifest "
                            f"({'candidate' if manifest['candidate'] else 'release'}"
                            f", commit {commit[:SHORT_SHA]}) says {want!r}")
        if want is not None:
            for key, suffix in (("boot_image", ".po"),
                                ("source_archive", "-source.tar.gz")):
                if manifest[key] != want + suffix:
                    problems.append(f"manifest {key} is {manifest[key]!r}, "
                                    f"expected {want + suffix!r}")
    except (OSError, ValueError, KeyError) as error:
        problems.append(f"MANIFEST.json unreadable or incomplete: {error!r}")
    if problems:
        for problem in problems:
            print(f"[release] VERIFY FAIL: {problem}", file=sys.stderr)
        return 1
    print(f"[release] VERIFY PASS: {bundle.name} "
          f"({len(listed)} files hashed, "
          f"{'candidate' if manifest['candidate'] else 'release'})")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", type=Path, metavar="BUNDLE",
                        help="verify a finished bundle directory and exit")
    parser.add_argument("--version")
    parser.add_argument("--candidate", action="store_true",
                        help="release CANDIDATE: no tag needed, named "
                             "maux-VERSION-rc-<shortsha>, MANIFEST says "
                             "candidate true / tag null")
    parser.add_argument("--image", type=Path)
    parser.add_argument("--output-root", type=Path, default=Path("dist"))
    args = parser.parse_args()
    if not args.verify and not (args.version and args.image):
        parser.error("--version and --image are required (or --verify BUNDLE)")
    return args


def main() -> int:
    args = parse_args()
    if args.verify:
        return verify_bundle(args.verify)
    if not VERSION_RE.fullmatch(args.version):
        fail("version must start with a digit and contain only letters, digits, '.', and '-'")

    root = Path(run("git", "rev-parse", "--show-toplevel", cwd=Path.cwd())).resolve()
    if Path.cwd().resolve() != root:
        fail(f"run from the repository root: {root}")

    status = run("git", "status", "--porcelain", "--untracked-files=all", cwd=root)
    if status:
        fail("tracked or untracked source-tree changes are present")

    commit = run("git", "rev-parse", "HEAD", cwd=root)
    if CANDIDATE_RE.search(args.version):
        fail(f"version {args.version!r} ends in a candidate suffix "
             f"(-rc-<hex>); that name belongs to `--candidate` bundles "
             f"and a release may not carry it")
    if args.candidate:
        tag = None
        release_name = f"maux-{args.version}-rc-{commit[:SHORT_SHA]}"
    else:
        tag = f"v{args.version}"
        tags = run("git", "tag", "--points-at", "HEAD", cwd=root).splitlines()
        if tag not in tags:
            fail(f"HEAD {commit[:12]} is not tagged exactly {tag}")
        release_name = f"maux-{args.version}"

    image = (root / args.image).resolve() if not args.image.is_absolute() else args.image
    validate_image(image)

    lock = root / "dependencies.lock.json"
    support = root / "docs" / "SUPPORT.md"
    limitations = root / "docs" / "KNOWN-LIMITATIONS.md"
    for required in (lock, support, limitations):
        if not required.is_file():
            fail(f"required release input is missing: {required.relative_to(root)}")
    with lock.open(encoding="utf-8") as source:
        dependency_data = json.load(source)

    output_root = (root / args.output_root).resolve() if not args.output_root.is_absolute() else args.output_root
    destination = output_root / release_name
    staging = output_root / f".{release_name}.tmp-{os.getpid()}"
    if destination.exists():
        fail(f"destination already exists: {destination}")
    if staging.exists():
        fail(f"staging path already exists: {staging}")

    output_root.mkdir(parents=True, exist_ok=True)
    staging.mkdir()
    try:
        image_name = f"{release_name}.po"
        source_name = f"{release_name}-source.tar.gz"
        (staging / image_name).write_bytes(pad_for_release(image.read_bytes()))
        validate_release_file(staging / image_name)
        shutil.copyfile(lock, staging / "dependencies.lock.json")
        shutil.copyfile(support, staging / "SUPPORT.md")
        shutil.copyfile(limitations, staging / "KNOWN-LIMITATIONS.md")

        source_date = run("git", "show", "-s", "--format=%cI", "HEAD", cwd=root)
        dropped, kept = public_source_archive(
            root, staging / source_name, f"{release_name}/", source_date)
        print(f"[release] source archive: {kept} file(s), {dropped} "
              f"not-ship path(s) withheld (check_publish.py --list)")
        manifest = {
            "schema": 1,
            "project": "maux",
            "version": args.version,
            "candidate": args.candidate,
            "tag": tag,
            "commit": commit,
            "source_date": source_date,
            "boot_image": image_name,
            "boot_image_blocks": VOL_BLOCKS,
            "boot_image_file_blocks": RELEASE_FILE_BLOCKS,
            "source_archive": source_name,
            "dependency_lock": "dependencies.lock.json",
            "dependency_lock_schema": dependency_data.get("schema"),
            "support_matrix": "SUPPORT.md",
            "known_limitations": "KNOWN-LIMITATIONS.md",
            "roms_included": False,
        }
        (staging / "MANIFEST.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        hashed = sorted(path for path in staging.iterdir() if path.name != "SHA256SUMS")
        sums = "".join(f"{sha256(path)}  {path.name}\n" for path in hashed)
        (staging / "SHA256SUMS").write_text(sums, encoding="ascii")
        staging.rename(destination)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    print(f"[release] PASS: {destination}")
    print(f"[release] commit {commit} "
          + ("CANDIDATE (no tag)" if args.candidate else f"tag {tag}"))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() if error.stderr else str(error)
        fail(detail)
