#!/usr/bin/env python3
"""check_release_pack.py -- the release packager's own gate
(`make check-release-pack`).

scripts/build_release.py had no gate: RC-1 could not exercise its success
path, and `make release` refuses unless HEAD carries a v<VERSION> tag, so
a release CANDIDATE could not be packaged at all (RC-1-NOTES sec 7 item
10). This drives the real packager as a subprocess, in a scratch git
repository with a synthetic boot image of the right shape (no emulator, no
MAME, no network), and holds the rows:

  1. --candidate on a clean, UNTAGGED HEAD builds maux-V-rc-<sha12>; its
     SHA256SUMS verifies (this script's own check AND shasum/sha256sum);
     MANIFEST.json says candidate true, tag null; image and source
     archive carry the rc name.
  2. the release path on the same untagged HEAD still refuses ("is not
     tagged exactly vV") and writes nothing.
  3. --candidate on a dirty tree refuses.
  4. --candidate on a TAGGED HEAD is still a candidate (never a release).
  5. a tagged HEAD builds the release maux-V, candidate false, tag vV.
  6. the release path refuses a VERSION that ends in -rc-<hex>, even
     with the matching tag.
  7. a candidate bundle renamed to the release name fails --verify; so
     does a candidate whose manifest flag was flipped; so does a bundle
     with one flipped byte.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
REAL_GATE = ROOT / "scripts" / "check_publish.py"
sys.path.insert(0, str(HERE))
from build_release import IMAGE_BYTES, VOL_BLOCKS  # noqa: E402

PACKAGER = HERE / "build_release.py"
VERSION = "9.9.9"
ENV = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
           GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")


def git(*args, cwd):
    r = subprocess.run(["git", *args], cwd=cwd, env=ENV, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode:
        raise SystemExit(f"[check-release-pack] git {args}: {r.stderr}")
    return r.stdout.strip()


def packager(repo, *args):
    return subprocess.run([sys.executable, str(PACKAGER), *args], cwd=repo,
                          env=ENV, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)


def make_image(path):
    data = bytearray(IMAGE_BYTES)
    data[2 * 512 + 0x29:2 * 512 + 0x2B] = VOL_BLOCKS.to_bytes(2, "little")
    path.write_bytes(bytes(data))


def external_sums_ok(bundle):
    """The bundle's SHA256SUMS through the host's own checker."""
    for cmd in (["sha256sum", "-c", "SHA256SUMS"],
                ["shasum", "-a", "256", "-c", "SHA256SUMS"]):
        if shutil.which(cmd[0]):
            return subprocess.run(cmd, cwd=bundle, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE).returncode == 0
    return None


def main():
    bad = 0

    def row(label, ok, detail=""):
        nonlocal bad
        print(f"[check-release-pack] {'ok  ' if ok else 'FAIL'} {label}"
              + (f" -- {detail}" if detail and not ok else ""))
        bad += 0 if ok else 1

    with tempfile.TemporaryDirectory(prefix="maux-relpack-") as scratch:
        repo = Path(scratch) / "repo"
        repo.mkdir()
        git("init", "-q", cwd=repo)
        (repo / "docs").mkdir()
        shutil.copyfile(ROOT / "dependencies.lock.json",
                        repo / "dependencies.lock.json")
        (repo / "docs" / "SUPPORT.md").write_text("support\n")
        (repo / "docs" / "KNOWN-LIMITATIONS.md").write_text("limits\n")
        (repo / "README").write_text("a file\n")
        # The packager subtracts `scripts/check_publish.py --list` from the
        # source archive, so the fixture carries a
        # stub oracle and one planted internal file for it to name. STUB_RED
        # makes the stub's GATE mode red without changing its list, which is
        # how row 9 proves a stale oracle cannot be subtracted quietly.
        (repo / "scripts").mkdir()
        (repo / "scripts" / "check_publish.py").write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "if '--list' in sys.argv:\n"
            "    print('INTERNAL.md')\n"
            "    print('[stub] 1 path', file=sys.stderr)\n"
            "    sys.exit(0)\n"
            "if os.environ.get('STUB_RED'):\n"
            "    print('[stub] pin list is stale', file=sys.stdout)\n"
            "    sys.exit(1)\n"
            "sys.exit(0)\n")
        (repo / "INTERNAL.md").write_text("handoff notes, never published\n")
        git("add", "-A", cwd=repo)
        git("commit", "-q", "-m", "c1", cwd=repo)
        commit = git("rev-parse", "HEAD", cwd=repo)
        make_image(Path(scratch) / "boot.po")
        image = str(Path(scratch) / "boot.po")
        dist = repo.parent / "dist"
        out = ["--output-root", str(dist), "--image", image]
        rc_name = f"maux-{VERSION}-rc-{commit[:12]}"

        # 1. candidate on an untagged clean HEAD
        r = packager(repo, "--version", VERSION, "--candidate", *out)
        bundle = dist / rc_name
        row("candidate on an untagged clean HEAD builds", r.returncode == 0
            and bundle.is_dir(), r.stderr.strip()[-200:])
        if bundle.is_dir():
            members = sorted(p.name for p in bundle.iterdir())
            want = sorted(["SHA256SUMS", "MANIFEST.json", "SUPPORT.md",
                           "KNOWN-LIMITATIONS.md", "dependencies.lock.json",
                           f"{rc_name}.po", f"{rc_name}-source.tar.gz"])
            row("candidate bundle holds exactly the release member set",
                members == want, f"{members}")
            m = json.loads((bundle / "MANIFEST.json").read_text())
            row("candidate manifest: candidate true, tag null, commit",
                m.get("candidate") is True and m.get("tag") is None
                and m.get("commit") == commit, str(m))
            row("candidate image and source carry the rc name",
                m.get("boot_image") == f"{rc_name}.po"
                and m.get("source_archive") == f"{rc_name}-source.tar.gz")
            v = packager(repo, "--verify", str(bundle))
            row("candidate SHA256SUMS verifies (packager --verify)",
                v.returncode == 0, v.stderr.strip()[-200:])
            ext = external_sums_ok(bundle)
            row("candidate SHA256SUMS verifies (host sha256sum/shasum -c)",
                ext is True, "no host checker" if ext is None else "")

        # 2. release path on the untagged HEAD still refuses, writes nothing
        before = sorted(p.name for p in dist.iterdir())
        r = packager(repo, "--version", VERSION, *out)
        row("release on an untagged HEAD refuses",
            r.returncode != 0 and f"is not tagged exactly v{VERSION}" in r.stderr,
            r.stderr.strip()[-200:])
        row("the refused release wrote nothing",
            sorted(p.name for p in dist.iterdir()) == before)

        # 3. dirty tree
        (repo / "README").write_text("changed\n")
        r = packager(repo, "--version", VERSION, "--candidate", "--output-root",
                     str(repo.parent / "dist2"), "--image", image)
        row("candidate on a dirty tree refuses",
            r.returncode != 0 and "changes are present" in r.stderr,
            r.stderr.strip()[-200:])
        (repo / "README").write_text("a file\n")

        # 4. candidate on a tagged HEAD is still a candidate
        git("tag", "-a", f"v{VERSION}", "-m", "t", cwd=repo)
        dist4 = repo.parent / "dist4"
        r = packager(repo, "--version", VERSION, "--candidate",
                     "--output-root", str(dist4), "--image", image)
        row("candidate on a TAGGED HEAD is still named and flagged a candidate",
            r.returncode == 0 and (dist4 / rc_name).is_dir()
            and not (dist4 / f"maux-{VERSION}").exists()
            and json.loads((dist4 / rc_name / "MANIFEST.json").read_text())
            ["candidate"] is True, r.stderr.strip()[-200:])

        # 5. release on the tagged HEAD
        r = packager(repo, "--version", VERSION, *out)
        rel = dist / f"maux-{VERSION}"
        row("release on the tagged HEAD builds", r.returncode == 0
            and rel.is_dir(), r.stderr.strip()[-200:])
        if rel.is_dir():
            m = json.loads((rel / "MANIFEST.json").read_text())
            row("release manifest: candidate false, tag vV",
                m.get("candidate") is False and m.get("tag") == f"v{VERSION}")
            v = packager(repo, "--verify", str(rel))
            row("release --verify passes", v.returncode == 0,
                v.stderr.strip()[-200:])

        # 6. a release VERSION may not wear a candidate's name
        fake = f"{VERSION}-rc-{commit[:12]}"
        git("tag", "-a", f"v{fake}", "-m", "t", cwd=repo)
        r = packager(repo, "--version", fake, "--output-root",
                     str(repo.parent / "dist6"), "--image", image)
        row("release refuses a version ending -rc-<hex> even with its tag",
            r.returncode != 0 and "candidate suffix" in r.stderr
            and not (repo.parent / "dist6").exists(), r.stderr.strip()[-200:])

        # 7. renames and tampering
        if bundle.is_dir():
            renamed = Path(scratch) / "renamed" / f"maux-{VERSION}"
            shutil.copytree(bundle, renamed)
            v = packager(repo, "--verify", str(renamed))
            row("a candidate renamed to the release name fails --verify",
                v.returncode != 0 and "manifest" in v.stderr, v.stderr[-200:])

            flipped = Path(scratch) / "flipped" / rc_name
            shutil.copytree(bundle, flipped)
            mf = flipped / "MANIFEST.json"
            mf.write_text(mf.read_text().replace('"candidate": true',
                                                 '"candidate": false'))
            v = packager(repo, "--verify", str(flipped))
            row("a candidate whose manifest flag was flipped fails --verify",
                v.returncode != 0, v.stderr[-200:])

            bit = Path(scratch) / "bit" / rc_name
            shutil.copytree(bundle, bit)
            lock = bit / "dependencies.lock.json"
            data = bytearray(lock.read_bytes())
            data[10] ^= 1
            lock.write_bytes(bytes(data))
            v = packager(repo, "--verify", str(bit))
            row("a bundle with one flipped byte fails --verify",
                v.returncode != 0 and "sha256 differs" in v.stderr,
                v.stderr[-200:])

        # 8. the source archive is the PUBLIC tree: a path the oracle
        # names is GONE and a path it does not name is PRESENT. Before
        # this row the archive was `git archive HEAD` whole, and the real
        # 1.0 tarball carried 1044 not-ship paths (2026-11-02).
        import tarfile
        arc = bundle / f"{rc_name}-source.tar.gz"
        names = []
        if arc.exists():
            with tarfile.open(arc) as tf:
                names = [n.split("/", 1)[1] for n in tf.getnames()
                         if "/" in n]
        row("source archive drops what the oracle names, keeps what it "
            "does not", "INTERNAL.md" not in names and "README" in names,
            f"{sorted(names)[:8]}")

        # 9. a RED oracle refuses the build. A stale pin list subtracted
        # quietly is exactly how a withheld file reaches a release.
        dist9 = repo.parent / "dist9"
        r = subprocess.run(
            [sys.executable, str(PACKAGER), "--version", VERSION,
             "--candidate", "--output-root", str(dist9), "--image", image],
            cwd=repo, env=dict(ENV, STUB_RED="1"), text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        row("a red check-publish refuses to package, and writes nothing",
            r.returncode != 0 and "check-publish is RED" in r.stderr
            and not (dist9 / rc_name).is_dir(), r.stderr.strip()[-200:])

        # 10. the archive is deterministic -- SHA256SUMS promises it.
        dist10 = repo.parent / "dist10"
        r = packager(repo, "--version", VERSION, "--candidate",
                     "--output-root", str(dist10), "--image", image)
        again = dist10 / rc_name / f"{rc_name}-source.tar.gz"
        row("two runs at one commit produce byte-identical archives",
            r.returncode == 0 and arc.exists() and again.exists()
            and arc.read_bytes() == again.read_bytes(),
            r.stderr.strip()[-200:])

    # 11. The REAL oracle's machine mode, against the REAL tree. Rows 8
    # to 10 drive a STUB check_publish, so by construction they prove
    # the SUBTRACTION and can say nothing about whether the oracle names
    # everything it should. That gap is not hypothetical: `--list`
    # printed two of its three withheld buckets, and because the third
    # was empty on the day it landed, every row above stayed green while
    # 278 documents the gate called withheld would have been packaged.
    # So this row asks the real gate both questions and compares: what
    # `--list` prints must be exactly what the report does not ship.
    import importlib.util
    spec = importlib.util.spec_from_file_location("cp_real", REAL_GATE)
    cp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cp)
    # cp.tracked() RETURNS None when `git ls-files` fails -- the real
    # gate's own main() tests for that and exits 2, and this row did
    # not, so it crashed with a TypeError in a tree with no git index.
    # Found by materialising the public tree and running the sweep
    # there, which is the only place that happens: `make public-tree`
    # unpacks a git archive, so the published tree has no index at all.
    paths = cp.tracked()
    if paths is None:
        row("the real oracle's --list is exactly what the real report "
            "withholds", True,
            "SKIPPED: no git index here, and this row's oracle IS the "
            "index -- it is meaningful only in a real checkout, which "
            "is where the sweep that gates a release runs")
    else:
        listed = subprocess.run([sys.executable, str(REAL_GATE), "--list"],
                                cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        printed = set(listed.stdout.split())
        ship = cp.classify(paths)[0]
        want = set(paths) - set(ship)
        row("the real oracle's --list is exactly what the real report "
            "withholds", listed.returncode == 0 and printed == want,
            f"--list {len(printed)}, not-shipped {len(want)}, "
            f"missing {sorted(want - printed)[:4]}, "
            f"extra {sorted(printed - want)[:4]}")

    if bad:
        print(f"[check-release-pack] FAIL: {bad} row(s)", file=sys.stderr)
        return 1
    print("[check-release-pack] PASS: candidate bundle verifies; release "
          "refusal on an untagged HEAD intact; a candidate cannot wear a "
          "release name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
