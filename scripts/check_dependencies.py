#!/usr/bin/env python3
"""Verify maux's external source/tool lock and the emulator actually in use.

Audits ONE dependency tier (docs/DEPS-TIER.md): `build` (what makes the
play and release disks: merlin32, ACME, PLASMA, a2til from PyPI, mandoc,
the tracked pinned/ objects) or `test` (everything: also verilogapple, its
build tools and the operator ROMs). The tier is the one the tree was
bootstrapped as; `--tier test` on a build-tier tree fails naming the tier.
"""

import argparse
import base64
import json
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK = Path(os.environ.get("MAUX_LOCK") or ROOT / "dependencies.lock.json")
TIERS = ("build", "test")

MANDOC_PROBE = r'''.TH MAUX 1 "September 18, 2026" maux
.SH NAME
maux \- reproducible renderer probe
.SH SYNOPSIS
.B maux
.RI [ option ]
.SH DESCRIPTION
.PP
A deliberately long paragraph exercises deterministic wrapping across hosts while
.B bold
and
.I italic
exercise overstrike output.
.TP
.B -x
Option text.
.RS
.IP item
Indented text.
.RE
.nf
literal  spacing
.fi
'''


def run(*args, cwd=None):
    try:
        return subprocess.run(args, cwd=cwd, text=True,
                              stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, check=False)
    except FileNotFoundError:
        return subprocess.CompletedProcess(args, 127, "command not found")


def repo_path(spec):
    return Path(os.path.expanduser(os.environ.get(spec["env"], spec["default"])))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def nlohmann_version():
    """Return the installed nlohmann/json version without compiling code."""
    pkg = run("pkg-config", "--modversion", "nlohmann_json")
    if pkg.returncode == 0 and pkg.stdout.strip():
        return pkg.stdout.strip()

    include_roots = []
    for variable in ("CPATH", "CPLUS_INCLUDE_PATH"):
        include_roots.extend(filter(None, os.environ.get(variable, "").split(os.pathsep)))
    include_roots.extend(("/opt/homebrew/include", "/usr/local/include", "/usr/include"))
    pattern = re.compile(r"^#define NLOHMANN_JSON_VERSION_(MAJOR|MINOR|PATCH)\s+(\d+)")
    for root in map(Path, include_roots):
        header = root / "nlohmann/detail/abi_macros.hpp"
        if not header.is_file():
            continue
        parts = {}
        for line in header.read_text(errors="replace").splitlines():
            match = pattern.match(line)
            if match:
                parts[match.group(1)] = match.group(2)
        if len(parts) == 3:
            return ".".join(parts[key] for key in ("MAJOR", "MINOR", "PATCH"))
    return None


def mandoc_failure(lock):
    """Return a failure when the selected renderer is absent or non-canonical."""
    spec = lock["source_tools"]["mandoc"]
    executable = os.path.expanduser(os.environ.get("MANDOC", "mandoc"))
    try:
        rendered = subprocess.run(
            [executable, "-Tascii", "-O", "width=64"],
            input=MANDOC_PROBE.encode("ascii"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError:
        return f"mandoc: selected renderer is missing: {executable}"
    if rendered.returncode:
        detail = rendered.stderr.decode(errors="replace").strip()
        return f"mandoc: render probe failed ({rendered.returncode}): {detail}"
    digest = hashlib.sha256(rendered.stdout).hexdigest()
    if digest != spec["render_probe_sha256"]:
        return (f"mandoc: render probe sha256 {digest}, want "
                f"{spec['render_probe_sha256']}")
    return None


def tool_failures(lock, *, check_renderer=True, tier="test"):
    versions = lock["tools"]
    spec = lock["tiers"][tier]
    failures = []
    if sys.version_info[:2] < tuple(versions["python_min"]):
        failures.append(f"python: {sys.version_info.major}.{sys.version_info.minor}, "
                        f"want >= {'.'.join(map(str, versions['python_min']))}")

    for command in spec["required_commands"]:
        if shutil.which(command) is None:
            failures.append(f"host tool: missing required command {command}")
    for group in versions.get("required_command_groups", []):
        if not any(shutil.which(command) for command in group):
            failures.append(f"host tool: need one of {', '.join(group)}")

    probes = {
        "merlin32": ("merlin32", [], versions["merlin32"]),
        "acme": ("acme", ["--version"], versions["acme"]),
        "verilator": ("verilator", ["--version"],
                      f"Verilator {versions['verilator']}"),
    }
    for name in ("merlin32", "acme", "verilator"):
        if name not in spec["tools"]:
            continue
        exe, args, needle = probes[name]
        got = run(exe, *args)
        if got.returncode not in (0, 1) or needle not in got.stdout:
            failures.append(f"{exe}: expected {needle!r}, got {got.stdout.strip()!r}")

    if "sdl2" in spec["tools"]:
        got_sdl = run("sdl2-config", "--version")
        if got_sdl.returncode != 0 or got_sdl.stdout.strip() != versions["sdl2"]:
            failures.append(f"sdl2: expected {versions['sdl2']!r}, "
                            f"got {got_sdl.stdout.strip()!r}")

    if "nlohmann_json" in spec["tools"]:
        got_nlohmann = nlohmann_version()
        if got_nlohmann != versions["nlohmann_json"]:
            failures.append(f"nlohmann_json: {got_nlohmann or 'not found'}, "
                            f"want {versions['nlohmann_json']}")
    # OPTIONAL tools (the tier's `optional_tools`): absent is fine, present
    # must be capable. ffmpeg is only `make demos`'s encoder; no sweep uses
    # it and the Linux box has none, so a host without it passes -- but a
    # host WITH an old or half-built one is named here, before a recording
    # fails minutes in. The floor, encoders and filters are the lock's.
    for name in spec.get("optional_tools", []):
        if name == "ffmpeg":
            import ffmpeg_probe  # noqa: PLC0415
            if ffmpeg_probe.installed():
                for problem in ffmpeg_probe.problems(versions["ffmpeg"]):
                    failures.append(f"ffmpeg (optional, `make demos`): "
                                    f"{problem}")
    if check_renderer:
        renderer_failure = mandoc_failure(lock)
        if renderer_failure:
            failures.append(renderer_failure)
    return failures


def tree_manifest(path, commit, excluded):
    """sha256 of a commit's file manifest -- `mode blob path` per file,
    in git's order, minus the mirror's declared exclusions.

    WHY A MANIFEST AND NOT A TREE HASH (docs/DEPS-TIER.md): the GitHub
    mirror is built by a2til's tools/publish-mirror.sh as one flat
    snapshot commit that DROPS a declared set of private paths
    (.forgejo/, three notes), so its git tree hash can never equal the
    Forgejo commit's -- measured 2026-10-19: Forgejo 8771012 tree
    0531fef, mirror 3a9e88e tree e6ae814, 7 files apart. Blob ids are
    content hashes, so the manifest over the paths both sides carry is
    exactly 'same content', and it ignores what the mirror removes on
    purpose. Returns (sha256, file count) or None if git cannot list it."""
    got = subprocess.run(["git", "ls-tree", "-r", "-z", "--full-tree", commit],
                         cwd=path, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=False)
    if got.returncode:
        return None
    lines = []
    for entry in got.stdout.split(b"\0"):
        if not entry:
            continue
        meta, name = entry.split(b"\t", 1)
        rel = name.decode("utf-8", "surrogateescape")
        if any(rel == x or rel.startswith(x + "/") for x in excluded):
            continue
        mode, _kind, blob = meta.decode().split()
        lines.append(f"{mode} {blob} {rel}")
    return hashlib.sha256("\n".join(lines).encode()).hexdigest(), len(lines)


def lock_failures(lock):
    """Checks that need nothing but the lock itself (and pinned/): both
    tiers run them, and --selftest plants a fault in each."""
    failures = []
    for tier in TIERS:
        if tier not in lock.get("tiers", {}):
            failures.append(f"lock: no tier {tier!r}")
    for tier, tspec in lock.get("tiers", {}).items():
        for name in tspec.get("optional_tools", []):
            block = lock["tools"].get(name)
            if not isinstance(block, dict):
                failures.append(f"lock: tier {tier!r} lists optional tool "
                                f"{name!r} but tools.{name} is not a block")
            elif name == "ffmpeg":
                if not (isinstance(block.get("min"), list) and
                        len(block["min"]) == 2 and
                        all(isinstance(n, int) for n in block["min"])):
                    failures.append("lock: tools.ffmpeg.min must be "
                                    "[major, minor]")
                for key in ("encoders", "filters"):
                    if not (isinstance(block.get(key), list) and
                            block[key]):
                        failures.append(f"lock: tools.ffmpeg.{key} must "
                                        f"name at least one entry")
        if tier == "build" and tspec.get("optional_tools"):
            failures.append("lock: the build tier has no optional tools "
                            "(ffmpeg is `make demos`, a test-tier step)")
    a2til = lock["repositories"]["a2til"]
    mirror = a2til.get("mirror", {})
    # The drift hazard: if the Forgejo pin moves, someone must run
    # publish-mirror.sh and re-pin the GitHub hash. Both pins record the
    # manifest of the tree they name; they must name the same one.
    if a2til.get("manifest_sha256") != mirror.get("manifest_sha256"):
        failures.append(
            f"a2til: the Forgejo pin {a2til['commit'][:7]} and the GitHub "
            f"pin {mirror.get('commit', '?')[:7]} name different trees "
            f"(content manifests {str(a2til.get('manifest_sha256'))[:12]} "
            f"vs {str(mirror.get('manifest_sha256'))[:12]}) -- run "
            "tools/publish-mirror.sh in a2til and re-pin the GitHub hash")
    # The two manifests above are both numbers the lock carries, so they can
    # be edited to agree. This ties the mirror to the Forgejo pin by commit:
    # moving `commit` without re-pinning the mirror (or the reverse) is red.
    if mirror.get("mirrors") != a2til.get("commit"):
        failures.append(
            f"a2til: the GitHub pin {mirror.get('commit', '?')[:7]} says it "
            f"mirrors {str(mirror.get('mirrors'))[:7]}, but the Forgejo pin is "
            f"{a2til['commit'][:7]} -- one moved without the other; run "
            "tools/publish-mirror.sh and re-pin (docs/DEPENDENCIES.md)")
    package = lock.get("python_packages", {}).get("a2til", {})
    if package.get("source_commit") != mirror.get("commit"):
        failures.append(
            f"a2til: the PyPI pin's source commit "
            f"{str(package.get('source_commit'))[:7]} is not the GitHub "
            f"pin {mirror.get('commit', '?')[:7]}")
    sys.path.insert(0, str(ROOT / "scripts"))
    import pinned  # noqa: PLC0415
    failures.extend(pinned.audit(ROOT, str(LOCK)))
    failures.extend(rom_table_failures(lock))
    return failures


# KFIX12: every ROM file the emulator can load for a maux configuration is
# declared in the lock's `roms` table, or exempted there with a reason that
# this audit holds to the tree. verilogapple's source is the authority on
# what it loads (learning:01M1QYXWW0WXMCY6E20V2BTTZK: the peripheral
# loaders each carry their own file name and never consult the ROM
# directory); the lock was written by hand from what someone remembered.
ROM_SOURCE_DIRS = ("sim/core", "sim/fast", "sim/mcp", "sim/top")
ROM_LITERAL = re.compile(r'"([^"\n]*\.(?:rom|bin|jed))"')
ROM_PREFIXES = ("/Users/mdj/src/verilogapple/sim/roms/", "../roms/",
                "sim/roms/")
# maux's own readers of the verilogapple ROM tree (the MAME romset builder
# takes the PAL jedec from it, which no verilogapple source mentions).
MAUX_ROM_READERS = ("scripts/vendor_mame_roms.py",)
ABSOLUTE_ROOTS = ("Users", "home", "opt", "usr", "tmp", "var", "Volumes")
VA_ROM_CALL = re.compile(r"""va_rom\(\s*['"]([^'"]+)['"]\s*\)""")


def rom_names_read(va, maux_root):
    """{name relative to ROM_DIR (or an absolute path outside it): [where]}
    for every ROM-shaped file name verilogapple's loaders and maux's own
    MAME builder read. Testbenches (tb_*) are not loaders anyone runs."""
    found = {}

    def note(name, where):
        found.setdefault(name, []).append(where)

    for sub in ROM_SOURCE_DIRS:
        base = va / sub
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if (path.suffix not in (".h", ".hpp", ".cpp") or
                    path.name.startswith("tb_") or "obj_dir" in path.parts):
                continue
            for number, line in enumerate(
                    path.read_text(errors="replace").splitlines(), 1):
                for lit in ROM_LITERAL.findall(line):
                    name = lit
                    for prefix in ROM_PREFIXES:
                        if name.startswith(prefix):
                            name = name[len(prefix):]
                            break
                    else:
                        # "/ultraterm/x.bin" joined onto roms_dir is
                        # relative to ROM_DIR; "/Users/..." is not.
                        if (name.startswith("/") and name.split("/")[1]
                                not in ABSOLUTE_ROOTS):
                            name = name[1:]
                    note(name, f"{path.relative_to(va)}:{number}")
    for rel in MAUX_ROM_READERS:
        path = maux_root / rel
        if path.is_file():
            for number, line in enumerate(path.read_text().splitlines(), 1):
                for name in VA_ROM_CALL.findall(line):
                    note(name, f"{rel}:{number}")
    return found


def exemption_selectors(maux_root, markers):
    """{marker: file} for each marker some maux build or gate file names.
    check_dependencies.py and the lock are the only files that may mention
    an exempted ROM without selecting it."""
    hits = {}
    files = [maux_root / "Makefile"]
    files += sorted((maux_root / "scripts").glob("*.py"))
    files += sorted((maux_root / "scripts").glob("*.sh"))
    for path in files:
        if path.name == "check_dependencies.py" or not path.is_file():
            continue
        text = path.read_text(errors="replace")
        for marker in markers:
            if marker in text:
                hits.setdefault(marker, str(path.relative_to(maux_root)))
    return hits


def rom_table_failures(lock):
    """The roms table and its exemptions are well formed (lock only)."""
    failures = []
    declared = set()
    for rom in lock.get("roms", []):
        if rom.get("path") != "sim/roms/" + rom.get("source", "?"):
            failures.append(f"lock: ROM {rom.get('source')!r} has path "
                            f"{rom.get('path')!r}, want sim/roms/<source>")
        if not rom.get("feeds"):
            failures.append(f"lock: ROM {rom.get('source')!r} names no "
                            "gate it feeds (docs/DEPENDENCIES.md)")
        if rom.get("source") in declared:
            failures.append(f"lock: ROM {rom['source']!r} is listed twice")
        declared.add(rom.get("source"))
    for ex in lock.get("roms_exempt", []):
        for key in ("name", "reason", "selected_by"):
            if not ex.get(key):
                failures.append(f"lock: roms_exempt entry {ex.get('name')!r} "
                                f"has no {key}")
        if ex.get("name") in declared:
            failures.append(f"lock: {ex.get('name')!r} is both declared in "
                            "roms and exempted")
    return failures


def rom_coverage_failures(lock, va, maux_root=ROOT):
    """Red when verilogapple (or maux's MAME builder) reads a ROM the lock
    neither declares nor exempts, when an exemption no longer matches
    anything read, and when a maux file selects an exempted ROM."""
    failures = []
    read = rom_names_read(va, maux_root)
    declared = {rom["source"] for rom in lock.get("roms", [])}
    exempt = {ex["name"]: ex for ex in lock.get("roms_exempt", [])}
    for name in sorted(read):
        if name in declared or name in exempt:
            continue
        failures.append(
            f"verilogapple reads ROM {name!r} ({', '.join(read[name][:2])}) "
            "but the lock's roms table neither declares nor exempts it -- "
            "a clean ROM_DIR would lack it (docs/DEPENDENCIES.md)")
    for name, ex in exempt.items():
        if name not in read:
            failures.append(f"lock: exempted ROM {name!r} is not read by "
                            "anything now; drop the exemption")
        for marker, where in exemption_selectors(
                maux_root, ex.get("selected_by", [])).items():
            failures.append(
                f"lock: ROM {name!r} is exempted ({ex['reason']}) but "
                f"{where} contains {marker!r}, which selects it")
    return failures


def mirror_failures(lock, *, online):
    """The content half of the drift check: the test-tier checkout's own
    manifest must be the one the lock records; with --verify-mirror the
    GitHub commit is fetched and held to the same manifest."""
    failures = []
    a2til = lock["repositories"]["a2til"]
    mirror = a2til["mirror"]
    excluded = mirror["excluded_paths"]
    if online:
        with tempfile.TemporaryDirectory(prefix="maux-mirror-") as scratch:
            ok = (run("git", "init", "-q", scratch).returncode == 0 and
                  run("git", "fetch", "-q", "--depth", "1", mirror["url"],
                      mirror["commit"], cwd=scratch).returncode == 0)
            got = tree_manifest(scratch, mirror["commit"], excluded) if ok else None
            if got is None:
                failures.append(f"a2til: cannot fetch the GitHub pin "
                                f"{mirror['commit']} from {mirror['url']}")
            elif got[0] != mirror["manifest_sha256"]:
                failures.append(
                    f"a2til: GitHub {mirror['commit'][:7]} has manifest "
                    f"{got[0]}, the lock says {mirror['manifest_sha256']}")
    return failures


def lock_pins(lock):
    """Every (label, url, commit) the lock pins, once each: the three
    repositories, the a2til GitHub mirror, and the commit the PyPI
    release was cut from (which is the mirror pin when the lock is
    consistent, so it collapses into it)."""
    pins = []
    for name, spec in lock["repositories"].items():
        pins.append((name, spec["url"], spec["commit"]))
        mirror = spec.get("mirror")
        if mirror:
            pins.append((f"{name} (mirror)", mirror["url"], mirror["commit"]))
    pkg = lock["python_packages"]["a2til"]
    pins.append(("a2til (PyPI source_commit)", pkg["git_url"],
                 pkg["source_commit"]))
    seen, unique = set(), []
    for label, url, commit in pins:
        if (url, commit) not in seen:
            seen.add((url, commit))
            unique.append((label, url, commit))
    return unique


def remote_pin_failures(pins, *, timeout=180, report=print):
    """RC-1 F1 (docs/RC-1-NOTES.md): verilogapple 296d93a was on the dev
    host and NOT on the Forgejo, and no gate noticed, because every gate
    runs against a local checkout. Prove each pinned commit can be
    fetched from its URL with NO local checkout and no credentials: an
    empty scratch repo, git's global/system config ignored, everything
    the server advertises first (what a plain clone gets), then the SHA
    by itself. Reachable only by SHA passes but says so -- a plain clone
    would not have it. Needs the network (git fetch of each URL)."""
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null",
               GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")

    def git(*args, cwd):
        try:
            return subprocess.run(["git", *args], cwd=cwd, env=env, text=True,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=timeout)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(args, 124, "",
                                               f"timed out after {timeout} s")

    failures = []
    for label, url, commit in pins:
        with tempfile.TemporaryDirectory(prefix="maux-remote-") as scratch:
            git("init", "-q", cwd=scratch)

            def have():
                return git("cat-file", "-e", f"{commit}^{{commit}}",
                           cwd=scratch).returncode == 0
            got = git("fetch", "-q", "--no-tags", url,
                      "+refs/heads/*:refs/remotes/o/*",
                      "+refs/tags/*:refs/tags/*", cwd=scratch)
            how = None
            if have():
                how = "reachable from a branch or tag (a plain clone gets it)"
            else:
                got = git("fetch", "-q", "--no-tags", url, commit, cwd=scratch)
                if have():
                    how = "only by SHA (a plain clone would NOT have it)"
            if how is None:
                tail = (got.stderr or "").strip().splitlines()[-1:] or ["?"]
                failures.append(f"{label}: {commit[:12]} is not fetchable "
                                f"from {url}: {tail[0][:110]}")
                report(f"[verify-remote] FAIL {label}: {commit[:12]} @ {url}")
            else:
                report(f"[verify-remote] PASS {label}: {commit[:12]} @ "
                       f"{url} -- {how}")
    return failures


def remote_file_failures(lock, *, timeout=120, report=print):
    """The PyPI files the build tier installs: fetched from their lock
    URLs and held to the lock's length and sha256."""
    failures = []
    for entry in lock["python_packages"]["a2til"]["files"]:
        try:
            req = urllib.request.Request(entry["url"],
                                         headers={"User-Agent": "maux-lock"})
            data = urllib.request.urlopen(req, timeout=timeout).read()
        except Exception as exc:  # noqa: BLE001 - any fetch fault is red
            failures.append(f"a2til {entry['filename']}: cannot fetch "
                            f"{entry['url']}: {exc}")
            report(f"[verify-remote] FAIL a2til {entry['filename']}: {exc}")
            continue
        ok = (len(data) == entry["bytes"]
              and hashlib.sha256(data).hexdigest() == entry["sha256"])
        if not ok:
            failures.append(f"a2til {entry['filename']}: {len(data)} B / "
                            f"sha256 {hashlib.sha256(data).hexdigest()[:12]} "
                            f"differ from the lock")
        report(f"[verify-remote] {'PASS' if ok else 'FAIL'} a2til "
               f"{entry['filename']}: {len(data)} B")
    return failures


def verify_remote(lock):
    """`make verify-remote`: needs no checkout, no .deps tree and no
    tier; it reads only the lock. A lock URL that is not https cannot be
    what a stranger fetches, so it is red before any fetch."""
    pins = lock_pins(lock)
    failures = [f"{label}: lock URL {url!r} is not https"
                for label, url, _ in pins if not url.startswith("https://")]
    failures += remote_pin_failures(pins)
    failures += remote_file_failures(lock)
    if failures:
        print("[verify-remote] FAIL:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"[verify-remote] PASS: {len(pins)} pinned commit(s) and the "
          f"PyPI files fetched from their lock URLs")
    return 0


def remote_selftest():
    """Teeth, offline: a local bare repo stands in for the server. A
    commit pushed to a branch passes, a commit that exists only in the
    pusher's clone (RC-1 F1, 'planted unpushed') is red, so is a SHA
    that exists nowhere, and a commit reachable only by SHA (a deleted
    branch, still in the server's object store) passes with the SHA-only
    wording. Returns the number of failed expectations."""
    bad = 0

    def row(label, ok):
        nonlocal bad
        print(f"[check-deps-selftest] {'ok  ' if ok else 'FAIL'} {label}")
        bad += 0 if ok else 1

    def sh(*args, cwd):
        r = subprocess.run(["git", *args], cwd=cwd, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null",
                                    GIT_CONFIG_NOSYSTEM="1",
                                    GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                                    GIT_COMMITTER_NAME="t",
                                    GIT_COMMITTER_EMAIL="t@t"))
        if r.returncode:
            raise RuntimeError(f"git {args}: {r.stderr}")
        return r.stdout.strip()

    with tempfile.TemporaryDirectory(prefix="maux-remote-st-") as scratch:
        server = Path(scratch) / "server.git"
        work = Path(scratch) / "work"
        sh("init", "-q", "--bare", str(server), cwd=scratch)
        sh("init", "-q", str(work), cwd=scratch)
        sh("checkout", "-q", "-b", "main", cwd=work)
        (work / "f").write_text("one\n")
        sh("add", "f", cwd=work)
        sh("commit", "-q", "-m", "pushed", cwd=work)
        pushed = sh("rev-parse", "HEAD", cwd=work)
        sh("push", "-q", str(server), "main", cwd=work)
        sh("checkout", "-q", "-b", "scratch", cwd=work)
        (work / "f").write_text("two\n")
        sh("commit", "-q", "-am", "side branch, pushed then deleted", cwd=work)
        sidesha = sh("rev-parse", "HEAD", cwd=work)
        sh("push", "-q", str(server), "scratch", cwd=work)
        sh("push", "-q", str(server), ":scratch", cwd=work)
        sh("checkout", "-q", "main", cwd=work)
        (work / "f").write_text("three\n")
        sh("commit", "-q", "-am", "never pushed", cwd=work)
        unpushed = sh("rev-parse", "HEAD", cwd=work)
        url = str(server)

        quiet = lambda *_: None  # noqa: E731
        row("a pinned commit that is on the server",
            not remote_pin_failures([("pushed", url, pushed)], report=quiet))
        row("a planted commit that exists only in the pusher's clone",
            bool(remote_pin_failures([("unpushed", url, unpushed)],
                                     report=quiet)))
        row("a SHA that exists nowhere",
            bool(remote_pin_failures([("nowhere", url, "0" * 40)],
                                     report=quiet)))
        row("a URL that is not a repository",
            bool(remote_pin_failures(
                [("nourl", str(Path(scratch) / "absent.git"), pushed)],
                report=quiet)))
        # git's own answer for an unadvertised SHA depends on the server's
        # uploadpack.allowAnySHA1InWant; either outcome is legitimate, but
        # the wording must not call it a plain-clone success.
        lines = []
        side = remote_pin_failures([("sidebranch", url, sidesha)],
                                   report=lines.append)
        row("a commit only reachable by SHA says so (or is refused)",
            bool(side) or any("only by SHA" in l for l in lines))
        planted = {"repositories": {"x": {"url": url, "commit": unpushed}},
                   "python_packages": {"a2til": {
                       "git_url": url, "source_commit": unpushed,
                       "files": []}}}
        row("lock_pins collapses the repeated url+commit",
            len(lock_pins(planted)) == 1)
    return bad


def package_failures(lock, root_dir):
    """Build tier: the venv's a2til is the locked one, file for file."""
    spec = lock["python_packages"]["a2til"]
    site = Path(os.path.expanduser(os.environ.get("A2TIL", "")))
    failures = []
    init = site / "a2til" / "__init__.py"
    if not os.environ.get("A2TIL") or not init.is_file():
        return [f"a2til: no installed package at A2TIL={site} (bootstrap the "
                "build tier: make bootstrap-deps TIER=build)"]
    version = re.search(r"__version__\s*=\s*['\"]([^'\"]+)", init.read_text())
    if not version or version.group(1) != spec["version"]:
        failures.append(f"a2til: installed version "
                        f"{version.group(1) if version else '?'}, want "
                        f"{spec['version']}")
    got = installed_manifest(site / "a2til")
    if got != spec["installed_manifest_sha256"]:
        failures.append(f"a2til: installed files hash to {got}, want "
                        f"{spec['installed_manifest_sha256']} (the PyPI "
                        f"wheel's contents)")
    return failures


def installed_manifest(package_dir):
    """sha256 over `relpath sha256(file)` for every file of the package,
    so the PyPI wheel and the pinned-git fallback are held to ONE value."""
    lines = []
    for path in sorted(package_dir.rglob("*")):
        if path.is_file() and "__pycache__" not in path.parts:
            rel = path.relative_to(package_dir).as_posix()
            lines.append(f"{rel} {sha256(path)}")
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


def recorded_tier(deps_root):
    """The tier the tree was bootstrapped as, or None if unrecorded.
    A test-tier tree records nothing (its generated files are byte for byte
    what they were before tiers existed), so a provisioned.json without a
    tier means test."""
    manifest = Path(deps_root) / "provisioned.json"
    if manifest.is_file():
        try:
            return json.loads(manifest.read_text()).get("tier", "test")
        except ValueError:
            return None
    # No manifest: the Makefile still exports the tier it read from
    # dependencies.mk, and only a build tree ever writes one.
    return "build" if os.environ.get("MAUX_TIER") == "build" else None


def adopt_provisioned(deps_root, lock):
    """Make a bare `python3 scripts/check_dependencies.py ...` find the
    environment `.deps/activate` and `make` would have given it.

    The repository paths, MANDOC and (build tier) A2TIL come from the
    environment; only `make check-deps` (dependencies.mk) and a sourced
    `.deps/activate` supplied them, so the documented bare command ran
    against ~/src/* on a provisioned clean host and failed with "not a
    Git checkout" (RC-1 F2). `provisioned.json` records the same paths,
    so they are adopted from it -- WITHOUT overriding anything already
    set, so a developer's own environment still wins. No manifest, no
    change. Returns the variable names it set."""
    manifest = Path(deps_root) / "provisioned.json"
    if not manifest.is_file():
        return []
    try:
        data = json.loads(manifest.read_text())
    except ValueError:
        return []
    adopted = []

    def put(name, value):
        if value and name not in os.environ:
            os.environ[name] = str(value)
            adopted.append(name)

    for repo, path in data.get("repositories", {}).items():
        spec = lock["repositories"].get(repo)
        if spec:
            put(spec["env"], path)
    put("MANDOC", data.get("source_tools", {}).get("mandoc"))
    put("A2TIL", data.get("python_packages", {}).get("a2til"))
    if data.get("tier") == "build":
        put("MAUX_TIER", "build")
    return adopted


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--tier", choices=TIERS,
                        help="tier to audit (default: the one the tree was "
                             "bootstrapped as, else test)")
    parser.add_argument("--deps-root", type=Path,
                        default=Path(os.environ.get("DEPS_ROOT") or ROOT / ".deps"),
                        help="dependency tree holding provisioned.json")
    parser.add_argument("--verify-mirror", action="store_true",
                        help="also fetch the GitHub pin and hold it to the "
                             "lock's content manifest (needs the network)")
    parser.add_argument("--verify-remote", action="store_true",
                        help="ONLY prove every commit and PyPI file the lock "
                             "pins is fetchable from its lock URL with no "
                             "local checkout (needs the network; the release "
                             "packagers run it first)")
    parser.add_argument("--selftest", action="store_true",
                        help="plant a fault in each lock check and require "
                             "each to fail")
    return parser.parse_args()


def adopt_selftest(lock):
    """A bare run on a provisioned host finds its own environment
    (RC-1 F2): the paths come from provisioned.json, an explicit
    environment wins over it, and no manifest means no change. Returns
    the number of rows that failed."""
    names = ["MANDOC", "A2TIL", "MAUX_TIER"] + [
        spec["env"] for spec in lock["repositories"].values()]
    saved = {n: os.environ.pop(n, None) for n in names}
    bad = 0

    def row(label, ok):
        nonlocal bad
        print(f"[check-deps-selftest] {'PASS' if ok else 'FAIL'}: {label}")
        bad += 0 if ok else 1

    try:
        with tempfile.TemporaryDirectory(prefix="maux-adopt-") as scratch:
            root = Path(scratch)
            repos = {name: str(root / name) for name in lock["repositories"]}
            (root / "provisioned.json").write_text(json.dumps({
                "schema": 1, "repositories": repos,
                "source_tools": {"mandoc": str(root / "mandoc")}}))
            got = adopt_provisioned(root, lock)
            first = next(iter(lock["repositories"].values()))
            row("a bare run adopts the repository paths from "
                "provisioned.json",
                os.environ.get(first["env"]) == repos[next(iter(repos))]
                and repo_path(first) == Path(repos[next(iter(repos))])
                and os.environ.get("MANDOC") == str(root / "mandoc")
                and first["env"] in got)
            for n in names:
                os.environ.pop(n, None)
            os.environ[first["env"]] = "/explicit/choice"
            adopt_provisioned(root, lock)
            row("an explicit environment variable wins over the manifest",
                os.environ[first["env"]] == "/explicit/choice")
            for n in names:
                os.environ.pop(n, None)
            empty = root / "no-manifest"
            empty.mkdir()
            row("no provisioned.json means nothing is adopted",
                adopt_provisioned(empty, lock) == []
                and first["env"] not in os.environ)
    finally:
        for n in names:
            os.environ.pop(n, None)
        for n, v in saved.items():
            if v is not None:
                os.environ[n] = v
    return bad


def rom_selftest(lock):
    """The ROM coverage row has teeth. A scratch verilogapple source tree
    with the real loaders' shapes (and a testbench that must be ignored)
    and a scratch maux tree are scanned with the real lock, then with one
    fault planted in the lock or in the maux tree. Returns the number of
    rows that failed."""
    import copy  # noqa: PLC0415
    bad = 0

    def row(label, ok):
        nonlocal bad
        print(f"[check-deps-selftest] {'PASS' if ok else 'FAIL'}: {label}")
        bad += 0 if ok else 1

    with tempfile.TemporaryDirectory(prefix="maux-romscan-") as scratch:
        va, maux = Path(scratch) / "va", Path(scratch) / "maux"
        (va / "sim/core").mkdir(parents=True)
        (va / "sim/fast").mkdir(parents=True)
        (maux / "scripts").mkdir(parents=True)
        (va / "sim/core/loaders.h").write_text(
            'const std::string key = "/iie_cd_ef.rom";\n'
            '  "../roms/applemouse.rom",\n'
            '  "/Users/mdj/src/verilogapple/sim/roms/disk2.rom",\n'
            '  "sim/roms/ssc.rom",\n'
            '  "../roms/ultraterm/firmware_v3.bin",\n'
            # every exemption the lock actually carries, so the planted
            # faults below cannot go vacuous when the exempt set moves
            + "".join('  "%s",\n' % e["name"]
                      for e in lock.get("roms_exempt", [])))
        (va / "sim/fast/fast_sdl.cpp").write_text(
            'std::string a = roms_dir + "/iie_video.rom";\n'
            'std::string b = roms_dir + (v1 ? "/ultraterm/firmware_v1.bin"'
            ' : "/ultraterm/firmware_v3.bin");\n'
            'std::string c = roms_dir + (v1 ? "/ultraterm/chargen_v1.bin"'
            ' : "/ultraterm/chargen_v3.bin");\n')
        (va / "sim/fast/tb_scratch.cpp").write_text(
            'load("../roms/only_a_testbench.rom");\n')
        (maux / "scripts/vendor_mame_roms.py").write_text(
            "x = va_rom('ultraterm/pal_u4_v3.jed')\n")
        (maux / "Makefile").write_text("play:\n\tfast_sdl --ut\n")

        def red(broken, needle, where=maux):
            got = rom_coverage_failures(broken, va, where)
            return any(needle in f for f in got)

        row("a ROM tree where the lock covers every file the loaders read, "
            "a testbench-only ROM is ignored: green",
            rom_coverage_failures(lock, va, maux) == [])
        for gone in ("disk2.rom", "ssc.rom", "ultraterm/pal_u4_v3.jed",
                     "ultraterm/chargen_v1.bin"):
            broken = copy.deepcopy(lock)
            broken["roms"] = [r for r in broken["roms"]
                              if r["source"] != gone]
            row(f"{gone} removed from the lock's roms table is red, "
                "naming it", red(broken, repr(gone)))
        # Both rows below plant against a REAL exemption taken from the
        # lock, never a name written out here. They used to name
        # ultraterm/firmware_v1.bin; UT-CELL vendored that ROM, so it
        # moved from roms_exempt to roms, and deleting an exemption that
        # no longer existed became a no-op -- two rows that could not
        # fail, sitting green-adjacent in a red gate for days.
        exempt_entries = lock.get("roms_exempt", [])
        row("the lock still carries an exemption to plant against",
            bool(exempt_entries))
        ex0 = exempt_entries[0] if exempt_entries else None
        if ex0 is not None:
            broken = copy.deepcopy(lock)
            broken["roms_exempt"] = [e for e in broken["roms_exempt"]
                                     if e["name"] != ex0["name"]]
            row("an exemption deleted leaves its ROM undeclared: red",
                red(broken, repr(ex0["name"])))
        broken = copy.deepcopy(lock)
        broken["roms_exempt"].append({
            "name": "nothing_reads_this.rom", "reason": "stale",
            "selected_by": ["nothing_reads_this"]})
        row("an exemption for a ROM nothing reads is red",
            red(broken, "nothing_reads_this.rom"))
        if ex0 is not None and ex0.get("selected_by"):
            marker = ex0["selected_by"][0]
            (maux / "Makefile").write_text(
                "play:\n\tfast_sdl %s\n" % marker)
            row("an exempted ROM that a maux Makefile selects is red",
                red(lock, repr(marker)))
    return bad


def selftest(lock):
    """The lock checks must have teeth: each planted fault is a copy of
    the real lock with one value changed, and each must come back red."""
    import copy  # noqa: PLC0415
    plants = []

    def plant(label, edit):
        broken = copy.deepcopy(lock)
        edit(broken)
        plants.append((label, broken))

    def other_tree(d):
        d["repositories"]["a2til"]["mirror"]["manifest_sha256"] = "0" * 64
    plant("a GitHub pin naming a different tree from the Forgejo pin",
          other_tree)
    plant("a Forgejo pin moved without re-pinning the mirror",
          lambda d: d["repositories"]["a2til"].update(commit="0" * 40))
    plant("a PyPI source commit that is not the GitHub pin",
          lambda d: d["python_packages"]["a2til"].update(source_commit="0" * 40))
    plant("an optional tool the tier lists but the lock has no block for",
          lambda d: d["tiers"]["test"].update(optional_tools=["ffmpeg", "x264"]))
    plant("an ffmpeg block with no encoders",
          lambda d: d["tools"]["ffmpeg"].update(encoders=[]))
    plant("an ffmpeg floor that is not [major, minor]",
          lambda d: d["tools"]["ffmpeg"].update(min="9.0"))
    plant("ffmpeg listed as an optional tool of the BUILD tier",
          lambda d: d["tiers"]["build"].update(optional_tools=["ffmpeg"]))
    plant("a pinned object whose lock length is wrong",
          lambda d: d["pinned"]["files"][0].update(bytes=1))
    plant("a LIBA pin whose lock sha256 has one hex digit flipped",
          lambda d: d["pinned"]["liba"]["objects"][0].update(
              sha256=("0" if d["pinned"]["liba"]["objects"][0]["sha256"][0] != "0"
                      else "1") + d["pinned"]["liba"]["objects"][0]["sha256"][1:]))
    plant("a ROM declared without the gates it feeds",
          lambda d: d["roms"][0].pop("feeds"))
    plant("a ROM exemption with no reason",
          lambda d: d["roms_exempt"][0].pop("reason"))
    plant("a ROM both declared and exempted",
          lambda d: d["roms_exempt"][0].update(name=d["roms"][0]["source"]))
    bad = adopt_selftest(lock) + rom_selftest(lock) + remote_selftest()
    if lock_failures(lock):
        print("[check-deps-selftest] FAIL: the real lock is already red:")
        for f in lock_failures(lock):
            print(f"  - {f}")
        return 1
    for label, broken in plants:
        # pinned.audit reads the lock FILE, so write the planted copy out.
        with tempfile.TemporaryDirectory(prefix="maux-lock-") as scratch:
            path = Path(scratch) / "dependencies.lock.json"
            path.write_text(json.dumps(broken))
            global LOCK
            saved, LOCK = LOCK, path
            try:
                failures = lock_failures(broken)
            finally:
                LOCK = saved
        if failures:
            print(f"[check-deps-selftest] red as required on {label}: "
                  f"{failures[0][:110]}")
        else:
            print(f"[check-deps-selftest] FAIL: {label} was NOT detected")
            bad += 1
    if not bad:
        print(f"[check-deps-selftest] PASS: {len(plants)} planted faults "
              "all detected")
    return 1 if bad else 0


def main():
    args = parse_args()
    lock = json.loads(LOCK.read_text())
    if lock.get("schema") != 4:
        print(f"[check-deps] FAIL: unsupported lock schema "
              f"{lock.get('schema')!r}; want 4")
        return 1
    if args.selftest:
        return selftest(lock)
    if args.verify_remote:
        return verify_remote(lock)
    adopt_provisioned(args.deps_root, lock)
    recorded = recorded_tier(args.deps_root)
    tier = args.tier or recorded or "test"
    if recorded == "build" and tier == "test":
        print("[check-deps] FAIL: a TIER=test audit was asked of a tree "
              "bootstrapped as TIER=build.\n"
              "  - the build tier has no verilogapple, Verilator, SDL2 or "
              "ROMs, so the emulator gates and this audit cannot pass here;\n"
              "  - provision the test tier into a new DEPS_ROOT: "
              "make bootstrap-deps ROM_DIR=/path/to/roms (docs/DEPENDENCIES.md)")
        return 1
    failures = []
    paths = {}
    clean_except_generated = {}
    failures.extend(lock_failures(lock))
    failures.extend(mirror_failures(lock, online=args.verify_mirror))

    for name, spec in lock["repositories"].items():
        if tier not in spec["tiers"]:
            continue
        path = repo_path(spec)
        paths[name] = path
        if not path.is_dir():
            failures.append(f"{name}: missing checkout {path}")
            continue
        got = run("git", "rev-parse", "HEAD", cwd=path)
        if got.returncode:
            failures.append(f"{name}: {path} is not a Git checkout")
            continue
        commit = got.stdout.strip()
        if commit != spec["commit"]:
            failures.append(f"{name}: commit {commit}, want {spec['commit']}")
        elif spec.get("manifest_sha256"):
            # The checkout really holds the content the lock says both
            # pins name (the Forgejo half of the drift check).
            have = tree_manifest(path, commit, spec["mirror"]["excluded_paths"])
            if have is None or have[0] != spec["manifest_sha256"]:
                failures.append(f"{name}: {commit[:7]} has content manifest "
                                f"{have[0] if have else '?'}, the lock says "
                                f"{spec['manifest_sha256']}")

        listed = run("git", "ls-files", "-v", cwd=path)
        allowed_hidden = set(spec.get("generated_tracked", []))
        hidden = set()
        if listed.returncode:
            failures.append(f"{name}: cannot inspect Git index flags")
        else:
            for line in listed.stdout.splitlines():
                if len(line) > 2 and (line[0].islower() or line[0] == "S"):
                    hidden.add(line[2:])
        unexpected_hidden = sorted(hidden - allowed_hidden)
        if unexpected_hidden:
            failures.append(f"{name}: unexpected assume-unchanged/skip-worktree "
                            f"paths: {', '.join(unexpected_hidden)}")

        diff_args = ["git", "diff", "--quiet", "HEAD", "--", "."]
        # The lock may identify generated files that upstream unfortunately
        # tracks. All other hidden paths are rejected above before this narrow
        # dirty-check exclusion is applied.
        diff_args += [f":(exclude){rel}" for rel in allowed_hidden]
        dirty = run(*diff_args, cwd=path)
        if dirty.returncode:
            failures.append(f"{name}: tracked source differs from {commit}")
        clean_except_generated[name] = not dirty.returncode

    if tier == "build":
        failures.extend(package_failures(lock, args.deps_root))
    failures.extend(tool_failures(lock, tier=tier))

    va = paths.get("verilogapple")
    plasma = paths.get("plasma")
    if va and va.is_dir():
        for rom in lock["roms"]:
            path = va / rom["path"]
            if not path.is_file():
                failures.append(f"verilogapple: missing required ROM {rom['path']}")
                continue
            size = path.stat().st_size
            if size != rom["bytes"]:
                failures.append(f"verilogapple: ROM {rom['path']} is {size} bytes, "
                                f"want {rom['bytes']}")
                continue
            digest = sha256(path)
            if digest != rom["sha256"]:
                failures.append(f"verilogapple: ROM {rom['path']} sha256 {digest}, "
                                f"want {rom['sha256']}")
        failures.extend(rom_coverage_failures(lock, va))
        frontend = va / "sim/fast/fast_sdl"
        if not frontend.is_file() or not os.access(frontend, os.X_OK):
            failures.append(f"verilogapple: interactive frontend missing at {frontend}")
    if plasma and plasma.is_dir():
        if not (plasma / "src/xplasm").is_file():
            failures.append("plasma: src/xplasm is not built")
        if not (plasma / "src/vmsrc/apple/plvmzp.inc").is_file():
            failures.append("plasma: tracked Apple plvmzp.inc is missing")

    # Ask the exact supervisor path every gate imports, then ask its worker.
    # A source SHA without this check had certified a stale binary in practice.
    if va and va.is_dir():
        sys.path.insert(0, str(ROOT / "scripts"))
        from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: PLC0415
        expected = lock["repositories"]["verilogapple"]["commit"][:7]
        if not os.path.isfile(SUPERVISOR):
            failures.append(f"verilogapple: supervisor missing at {SUPERVISOR}")
        else:
            env = dict(os.environ)
            env["VERILOGAPPLE_ROMS"] = ROMS_DIR
            client = MCPClient([SUPERVISOR], env)
            try:
                client.initialize()
                status = client.call_tool("instance_status", {})
                # verilogapple TRACKS sim/mcp/.build-rev and its own build
                # rewrites it, so after the first build `git diff --quiet
                # HEAD` fails on that one generated file and every binary
                # self-reports `<rev>-dirty` forever (2026-10-07: the Mac
                # and the box both at 296d93a, both "-dirty", both clean
                # apart from .build-rev). Accept the suffix ONLY when the
                # checkout passed the dirty check above, which already
                # excludes the lock's generated_tracked paths -- that is
                # independent evidence the dirt is the generated file.
                ok = {expected}
                if clean_except_generated.get("verilogapple"):
                    ok.add(expected + "-dirty")
                for who, rev in (("supervisor", status.get("build_rev")),
                                 ("worker", status.get("worker", {}).get("build_rev"))):
                    if rev not in ok:
                        failures.append(f"verilogapple: {who} built from {rev!r}, "
                                        f"want {expected!r}")
            except Exception as exc:  # noqa: BLE001
                failures.append(f"verilogapple: cannot query worker revision: {exc}")
            finally:
                client.close()

    if failures:
        print("[check-deps] FAIL:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    if tier == "build":
        print("[check-deps] PASS (tier build): PLASMA revision, locked a2til "
              "wheel contents, tools, mandoc, pinned/ objects and the a2til "
              "mirror pin match dependencies.lock.json")
    else:
        print("[check-deps] PASS: source revisions, tools, ROM identities, "
              "and emulator binaries match dependencies.lock.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
