#!/usr/bin/env python3
"""Provision maux's locked source dependencies without changing existing trees.

Two tiers (docs/DEPS-TIER.md, docs/DEPENDENCIES.md):

  build  PLASMA (public GitHub), a2til from PyPI into a project-local venv
         with `pip --require-hashes`, mandoc, and the tracked pinned/
         objects. No ROMs, no verilogapple, no Forgejo, no operator input.
  test   everything: also verilogapple and its build, and the operator's
         ROM set; a2til from the Forgejo checkout. The default, and byte
         for byte what this script did before tiers existed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
import http.client
import urllib.request

import check_dependencies


ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = ROOT / "dependencies.lock.json"
TIERS = ("build", "test")


class BootstrapError(RuntimeError):
    pass


def run(args, *, cwd=None, env=None, capture=False):
    print(f"[bootstrap-deps] + {shlex.join(map(str, args))}", flush=True)
    result = subprocess.run(
        list(map(str, args)), cwd=cwd, env=env, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        check=False,
    )
    if result.returncode:
        detail = f"\n{result.stdout.rstrip()}" if capture and result.stdout else ""
        raise BootstrapError(f"command failed ({result.returncode}): "
                             f"{shlex.join(map(str, args))}{detail}")
    return result


def load_lock():
    lock = json.loads(LOCK_PATH.read_text())
    if lock.get("schema") != 4:
        raise BootstrapError(f"unsupported lock schema {lock.get('schema')!r}; want 4")
    for name, spec in lock.get("repositories", {}).items():
        if not all(spec.get(key) for key in ("env", "url", "commit", "tiers")):
            raise BootstrapError(f"repository {name!r} has an incomplete lock entry")
        if Path(name).name != name:
            raise BootstrapError(f"unsafe repository name {name!r}")
        for rel in spec.get("generated_tracked", []):
            path = Path(rel)
            if path.is_absolute() or ".." in path.parts:
                raise BootstrapError(f"repository {name!r} has unsafe generated "
                                     f"path {rel!r}")
    for tier in TIERS:
        if tier not in lock.get("tiers", {}):
            raise BootstrapError(f"lock has no tier {tier!r}")
    package = lock.get("python_packages", {}).get("a2til", {})
    if not all(package.get(key) for key in
               ("version", "files", "source_commit", "git_url",
                "installed_manifest_sha256")):
        raise BootstrapError("python package 'a2til' has an incomplete lock entry")
    mandoc = lock.get("source_tools", {}).get("mandoc", {})
    if not all(mandoc.get(key) for key in
               ("url", "sha256", "directory", "executable", "build",
                "render_probe_sha256")):
        raise BootstrapError("source tool 'mandoc' has an incomplete lock entry")
    if Path(mandoc["directory"]).name != mandoc["directory"]:
        raise BootstrapError("source tool 'mandoc' has an unsafe directory")
    return lock


def tier_repositories(lock, tier):
    return {name: spec for name, spec in lock["repositories"].items()
            if tier in spec["tiers"]}


def verify_rom_sources(lock, rom_dir):
    failures = []
    for rom in lock["roms"]:
        source = rom_dir / rom["source"]
        if not source.is_file():
            failures.append(f"missing {source}")
            continue
        size = source.stat().st_size
        if size != rom["bytes"]:
            failures.append(f"{source}: {size} bytes, want {rom['bytes']}")
            continue
        digest = check_dependencies.sha256(source)
        if digest != rom["sha256"]:
            failures.append(f"{source}: sha256 {digest}, want {rom['sha256']}")
    if failures:
        raise BootstrapError("operator ROM set does not match the lock:\n  - " +
                             "\n  - ".join(failures))


def clone_repositories(lock, root, tier):
    for name, spec in tier_repositories(lock, tier).items():
        target = root / name
        print(f"[bootstrap-deps] cloning {name} at {spec['commit']}", flush=True)
        run(["git", "clone", "--quiet", "--no-checkout", spec["url"], target])
        run(["git", "checkout", "--quiet", "--detach", spec["commit"]], cwd=target)
        got = run(["git", "rev-parse", "HEAD"], cwd=target, capture=True).stdout.strip()
        if got != spec["commit"]:
            raise BootstrapError(f"{name}: checked out {got}, want {spec['commit']}")
        for rel in spec.get("generated_tracked", []):
            run(["git", "ls-files", "--error-unmatch", "--", rel], cwd=target)
            # This locked upstream revision rewrites its tracked revision stamp
            # on every build, then sees that write as source dirtiness on the
            # next build. Hide only that declared generated path from Git's
            # worktree scan; check-deps rejects hidden paths not in the lock.
            run(["git", "update-index", "--assume-unchanged", "--", rel],
                cwd=target)


def pip_env():
    """pip must neither read the operator's config nor see user site."""
    env = dict(os.environ)
    env["PIP_CONFIG_FILE"] = os.devnull
    env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    env["PIP_NO_INPUT"] = "1"
    env["PYTHONNOUSERSITE"] = "1"
    return env


def install_a2til_from_git(spec, purelib):
    """The fallback when PyPI cannot be reached: fetch the GitHub commit
    the release was cut from, check it is that commit, and copy its a2til/
    package into the venv's site-packages. NOT `pip install git+URL`:
    that builds with hatchling, which pip fetches UNPINNED from the very
    index that just failed (measured 2026-10-19: it dies with the index
    unreachable). a2til is dependency-free pure Python, and check-deps
    holds the copied files to the same installed-files hash as the wheel,
    which `pip install git+URL@commit` was also measured to produce."""
    with tempfile.TemporaryDirectory(prefix="maux-a2til-") as scratch:
        run(["git", "init", "--quiet", scratch])
        run(["git", "fetch", "--quiet", "--depth", "1", spec["git_url"],
             spec["source_commit"]], cwd=scratch)
        run(["git", "checkout", "--quiet", "--detach", "FETCH_HEAD"], cwd=scratch)
        got = run(["git", "rev-parse", "HEAD"], cwd=scratch,
                  capture=True).stdout.strip()
        if got != spec["source_commit"]:
            raise BootstrapError(f"a2til: fetched {got}, want "
                                 f"{spec['source_commit']}")
        shutil.copytree(Path(scratch) / "a2til", purelib / "a2til",
                        ignore=shutil.ignore_patterns("__pycache__"))


def make_venv(venv):
    """Create the project-local venv; True if it has pip. Debian's python3
    ships `venv` without `ensurepip` until python3-venv is installed (as
    root), so a missing pip is a normal host, not an error."""
    try:
        run([sys.executable, "-m", "venv", venv], capture=True)
        return True
    except BootstrapError:
        shutil.rmtree(venv, ignore_errors=True)
        run([sys.executable, "-m", "venv", "--without-pip", venv])
        return False


def install_a2til_wheel(spec, site):
    """pip-free install of the locked wheel: download it from the URL the
    lock records, hold it to the locked length and sha256 (a mismatch is
    final), and unzip it into site-packages. Same files `pip install
    --require-hashes` lays down, minus pip's dist-info bookkeeping."""
    wheel = next(f for f in spec["files"] if f["filename"].endswith(".whl"))
    print(f"[bootstrap-deps] downloading {wheel['filename']} (pip-free "
          "route: the lock's length and sha256 are the check)", flush=True)
    try:
        with urllib.request.urlopen(wheel["url"]) as response:
            data = response.read()
    except OSError as exc:
        raise NetworkError(f"cannot download {wheel['url']}: {exc}") from exc
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != wheel["bytes"] or digest != wheel["sha256"]:
        raise BootstrapError(
            f"a2til wheel is {len(data)} bytes sha256 {digest}; the lock "
            f"says {wheel['bytes']} bytes sha256 {wheel['sha256']}")
    with tempfile.TemporaryDirectory(prefix="maux-wheel-") as scratch:
        archive = Path(scratch) / wheel["filename"]
        archive.write_bytes(data)
        with zipfile.ZipFile(archive) as zf:
            for name in zf.namelist():
                parts = PurePosixPath(name).parts
                if name.startswith("/") or ".." in parts:
                    raise BootstrapError(f"a2til wheel has unsafe member {name!r}")
            zf.extractall(site)


class NetworkError(BootstrapError):
    """The index or host could not be reached (as opposed to a wrong hash)."""


def install_a2til(lock, root, source):
    """Install the locked a2til into <root>/venv and return its
    site-packages. The venv is project-local, so nothing under the system
    interpreter is touched. PyPI is the primary source and is pinned by
    HASH (`--require-hashes`; the version alone is not a pin). A hash
    mismatch is final -- it is never retried from git. Only an unreachable
    index falls back to the GitHub commit, and the result is then held to
    the same installed-files hash as the wheel by check-deps.

    source: auto (pip if the venv has it, else the pip-free wheel route;
    GitHub if the index cannot be reached), pypi (no fallback), wheel (the
    pip-free route, forced), git (the fallback, forced)."""
    spec = lock["python_packages"]["a2til"]
    venv = root / "venv"
    has_pip = make_venv(venv)
    python = venv / "bin" / "python"
    env = pip_env()
    purelib = Path(run([python, "-c",
                        "import sysconfig; print(sysconfig.get_paths()"
                        "['purelib'])"], env=env, capture=True).stdout.strip())
    requirements = root / "a2til-requirements.txt"
    requirements.write_text(
        f"a2til=={spec['version']} \\\n" +
        " \\\n".join(f"    --hash=sha256:{f['sha256']}" for f in spec["files"]) +
        "\n")
    pypi = [python, "-m", "pip", "install", "--require-hashes", "--no-deps",
            "--only-binary", ":all:", "-r", requirements]

    def from_pypi():
        if has_pip and source != "wheel":
            try:
                run(pypi, env=env, capture=True)
            except BootstrapError as exc:
                if "DO NOT MATCH THE HASHES" in str(exc):
                    raise
                raise NetworkError(str(exc)) from exc
        else:
            install_a2til_wheel(spec, purelib)

    if source == "git":
        install_a2til_from_git(spec, purelib)
    else:
        try:
            from_pypi()
        except NetworkError as exc:
            if source in ("pypi", "wheel"):
                raise
            print("[bootstrap-deps] PyPI could not supply the locked a2til "
                  f"({str(exc).splitlines()[-1][:120]}); falling back to "
                  f"{spec['git_url']}@{spec['source_commit'][:7]}", flush=True)
            install_a2til_from_git(spec, purelib)
    return purelib


#: mandoc.bsd.lv is the one origin of the locked mandoc source, and on
#: 2026-10-20 it failed three ways in an afternoon (a transfer whose sha256
#: was not the file's, connection timeouts, a closed connection): RC-1 F3.
#: Bounded, so an outage ends in a clear error instead of a hang.
FETCH_TIMEOUT = 30        # seconds, per socket operation
FETCH_ATTEMPTS = 4
FETCH_BACKOFF = 2.0       # seconds before the 2nd try; doubles each time


def download_with_retry(url, dest, *, accept, what, want,
                        timeout=None, attempts=None, backoff=None,
                        sleep=time.sleep):
    """Fetch `url` into `dest`, retrying a failed or refused transfer.

    `accept(path)` returns None to take the file, else a short reason
    (the caller's own hash check: this routine only decides whether to
    ask again, it never weakens it). Each socket operation has a timeout;
    attempts are bounded, with exponential backoff between them. On
    exhaustion the error names the URL, the lock's sha256 and what every
    attempt saw. `dest` is not left behind on failure."""
    timeout = FETCH_TIMEOUT if timeout is None else timeout
    attempts = FETCH_ATTEMPTS if attempts is None else attempts
    backoff = FETCH_BACKOFF if backoff is None else backoff
    seen = []
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as response, \
                    dest.open("wb") as out:
                shutil.copyfileobj(response, out)
            why = accept(dest)
            if why is None:
                return
            seen.append(f"attempt {attempt}: received {dest.stat().st_size} "
                        f"bytes, {why}")
        except (OSError, http.client.HTTPException) as exc:
            seen.append(f"attempt {attempt}: {type(exc).__name__}: {exc}")
        dest.unlink(missing_ok=True)
        if attempt < attempts:
            wait = backoff * 2 ** (attempt - 1)
            print(f"[bootstrap-deps] {what}: {seen[-1]}; retrying in "
                  f"{wait:g} s", flush=True)
            sleep(wait)
    raise BootstrapError(
        f"cannot download {what} from {url} after {attempts} attempts "
        f"(timeout {timeout:g} s each); the lock wants sha256 {want}:\n  - " +
        "\n  - ".join(seen))


def provision_mandoc(lock, root):
    """Download, verify, safely unpack, and build the locked manual renderer."""
    spec = lock["source_tools"]["mandoc"]
    archive = root / "mandoc.tar.gz"
    target = root / spec["directory"]
    print(f"[bootstrap-deps] downloading mandoc from {spec['url']}", flush=True)

    def locked(path):
        got = check_dependencies.sha256(path)
        return None if got == spec["sha256"] else f"sha256 {got}"
    download_with_retry(spec["url"], archive, accept=locked,
                        what="mandoc", want=spec["sha256"])
    digest = check_dependencies.sha256(archive)
    if digest != spec["sha256"]:
        raise BootstrapError(
            f"mandoc archive sha256 {digest}, want {spec['sha256']}"
        )

    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        prefix = spec["directory"]
        for member in members:
            parts = PurePosixPath(member.name).parts
            if (not parts or parts[0] != prefix or member.name.startswith("/") or
                    ".." in parts or member.issym() or member.islnk() or
                    member.isdev()):
                raise BootstrapError(
                    f"mandoc archive contains unsafe member {member.name!r}"
                )
        source.extractall(root)
    archive.unlink()
    if not target.is_dir():
        raise BootstrapError(f"mandoc archive did not create {target}")
    for command in spec["build"]:
        run(command, cwd=target)
    executable = target / spec["executable"]
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise BootstrapError(f"mandoc build did not create {executable}")


def stage_roms(lock, rom_dir, verilogapple):
    for rom in lock["roms"]:
        source = rom_dir / rom["source"]
        target = verilogapple / rom["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            raise BootstrapError(f"refusing to overwrite unexpected ROM path {target}")
        shutil.copyfile(source, target)


def build_repositories(lock, root, tier):
    for name, spec in tier_repositories(lock, tier).items():
        for command in spec.get("build", []):
            print(f"[bootstrap-deps] building {name}", flush=True)
            run(command, cwd=root / name)


def dependency_env(lock, root, tier, site=None):
    env = dict(os.environ)
    for name, spec in tier_repositories(lock, tier).items():
        env[spec["env"]] = str(root / name)
    if tier == "build":
        env["A2TIL"] = str(site)
        env["MAUX_TIER"] = "build"
    else:
        verilogapple = root / "verilogapple"
        env["MAUX_SUPERVISOR"] = str(
            verilogapple / "sim/mcp/obj_dir/mcp_supervisor"
        )
        env["VERILOGAPPLE_ROMS"] = str(verilogapple / "sim/roms")
    mandoc = lock["source_tools"]["mandoc"]
    env["MANDOC"] = str(root / mandoc["directory"] / mandoc["executable"])
    return env


def audit(lock, root, tier, site=None):
    env = dependency_env(lock, root, tier, site)
    run([sys.executable, ROOT / "scripts/check_dependencies.py",
         "--tier", tier, "--deps-root", root], env=env)


def write_configuration(lock, root, tier, site=None):
    assignments = []
    exports = []
    paths = {}
    if tier == "build":
        # The tier is recorded where Make reads it. The test tier writes
        # no such line: its generated files stay byte for byte what they
        # were before tiers existed, and an unrecorded tier IS test.
        assignments.append("MAUX_TIER = build")
        exports.append("export MAUX_TIER=build")
    for name, spec in tier_repositories(lock, tier).items():
        path = root / name
        paths[name] = str(path)
        assignments.append(f"{spec['env']} ?= {path}")
        exports.append(f"export {spec['env']}={shlex.quote(str(path))}")
    if tier == "build":
        assignments.append(f"A2TIL ?= {site}")
        exports.append(f"export A2TIL={shlex.quote(str(site))}")
    mandoc = lock["source_tools"]["mandoc"]
    mandoc_path = root / mandoc["directory"] / mandoc["executable"]
    assignments.append(f"MANDOC ?= {mandoc_path}")
    exports.append(f"export MANDOC={shlex.quote(str(mandoc_path))}")

    (root / "dependencies.mk").write_text(
        "# Generated by scripts/bootstrap_dependencies.py; do not edit.\n" +
        "\n".join(assignments) + "\n"
    )
    (root / "activate").write_text(
        "# Source this file to use maux's provisioned dependencies.\n" +
        "\n".join(exports) + "\n"
    )
    manifest = {
        "schema": 1,
        "lock_sha256": hashlib.sha256(LOCK_PATH.read_bytes()).hexdigest(),
        "repositories": paths,
        "source_tools": {"mandoc": str(mandoc_path)},
    }
    if tier == "build":
        manifest["tier"] = "build"
        manifest["python_packages"] = {"a2til": str(site)}
    (root / "provisioned.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )


def selftest():
    """The fetch has teeth: a flaky server is retried, a wrong file is
    retried then refused naming the URL and the lock's sha256, a server
    that never answers ends at the timeout, and backoff doubles. Local
    HTTP server, no network, no real sleeping."""
    import http.server  # noqa: PLC0415
    import threading  # noqa: PLC0415

    body = b"the locked mandoc archive stands in here\n" * 50
    want = hashlib.sha256(body).hexdigest()
    hits = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            n = hits[self.path] = hits.get(self.path, 0) + 1
            if self.path == "/flaky" and n <= 2:
                self.send_response(503)
                self.end_headers()
                return
            if self.path == "/cut" and n == 1:
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body[:10])      # then hang up
                return
            if self.path == "/hang":
                time.sleep(2.0)
            data = body
            if self.path == "/wrong" or (self.path == "/wrong-once" and n == 1):
                data = b"not the file\n" * 100
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except OSError:
                pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    bad = 0

    def row(label, ok):
        nonlocal bad
        print(f"[bootstrap-selftest] {'PASS' if ok else 'FAIL'}: {label}")
        bad += 0 if ok else 1

    def accept(path):
        got = hashlib.sha256(path.read_bytes()).hexdigest()
        return None if got == want else f"sha256 {got[:12]}..."

    def fetch(path, **kw):
        naps = []
        with tempfile.TemporaryDirectory(prefix="maux-fetch-") as scratch:
            dest = Path(scratch) / "x.tar.gz"
            try:
                download_with_retry(base + path, dest, accept=accept,
                                    what="mandoc", want=want,
                                    sleep=naps.append, **kw)
                return None, naps, dest.exists()
            except BootstrapError as exc:
                return str(exc), naps, dest.exists()

    try:
        err, naps, kept = fetch("/ok", timeout=2, backoff=1)
        row("a good server is fetched once, with no waiting",
            err is None and hits["/ok"] == 1 and naps == [] and kept)
        err, naps, kept = fetch("/flaky", timeout=2, backoff=1)
        row("two 503s are retried with doubling backoff, then it works",
            err is None and hits["/flaky"] == 3 and naps == [1, 2] and kept)
        err, naps, kept = fetch("/cut", timeout=2, backoff=1)
        row("a connection closed mid-body is retried",
            err is None and hits["/cut"] == 2 and kept)
        err, naps, kept = fetch("/wrong-once", timeout=2, backoff=1)
        row("bytes with the wrong sha256 are asked for again",
            err is None and hits["/wrong-once"] == 2 and kept)
        err, naps, kept = fetch("/wrong", timeout=2, attempts=3, backoff=1)
        row("a server that never sends the file ends in an error naming "
            "the URL, the lock's sha256 and the attempts, after exactly 3 "
            "tries, leaving no file",
            err is not None and base + "/wrong" in err and want in err
            and "3 attempts" in err and hits["/wrong"] == 3 and not kept
            and naps == [1, 2])
        t0 = time.time()
        err, naps, kept = fetch("/hang", timeout=0.3, attempts=2, backoff=1)
        row("a server that does not answer is cut at the timeout, not "
            "waited for",
            err is not None and "timed out" in err and not kept
            and time.time() - t0 < 1.9)
    finally:
        server.shutdown()
    rows = 6
    # KFIX12: a test-tier ROM_DIR missing any one declared file refuses,
    # naming it. The scratch ROM_DIR holds stand-in bytes and the check
    # runs against a copy of the real lock re-hashed to match them, so
    # the only difference between the passing row and a refusing row is
    # the one file taken away.
    import copy  # noqa: PLC0415
    lock = json.loads(check_dependencies.LOCK.read_text())
    with tempfile.TemporaryDirectory(prefix="maux-romdir-") as scratch:
        romdir = Path(scratch)
        stand_in = copy.deepcopy(lock)
        for rom in stand_in["roms"]:
            data = rom["source"].encode() * 3
            (romdir / rom["source"]).parent.mkdir(parents=True,
                                                  exist_ok=True)
            (romdir / rom["source"]).write_bytes(data)
            rom["bytes"] = len(data)
            rom["sha256"] = hashlib.sha256(data).hexdigest()

        def refusal(rom_dir):
            try:
                verify_rom_sources(stand_in, rom_dir)
            except BootstrapError as exc:
                return str(exc)
            return None

        rows += 1
        row("a ROM_DIR holding every declared file is accepted",
            refusal(romdir) is None)
        for gone in ("disk2.rom", "ssc.rom", "ultraterm/pal_u4_v3.jed",
                     "ultraterm/chargen_v1.bin"):
            rows += 1
            held = (romdir / gone).read_bytes()
            (romdir / gone).unlink()
            err = refusal(romdir)
            row(f"a ROM_DIR without {gone} is refused, naming it",
                err is not None and f"missing {romdir / gone}" in err)
            (romdir / gone).write_bytes(held)
    print(f"[bootstrap-selftest] {'PASS' if not bad else 'FAIL'}: "
          f"{rows - bad} of {rows} rows")
    return 1 if bad else 0


def parse_args():
    parser = argparse.ArgumentParser(
        description="Clone and build dependencies.lock.json into a new directory."
    )
    parser.add_argument("--selftest", action="store_true",
                        help="check the download retry against a local "
                             "server and exit")
    parser.add_argument("--dest", type=Path,
                        help="new directory to create (must not already exist)")
    parser.add_argument("--tier", choices=TIERS, default="test",
                        help="build: what makes the play and release disks "
                             "(no ROMs, no verilogapple, no Forgejo); test "
                             "(default): everything, as before")
    parser.add_argument("--rom-dir", type=Path,
                        help="operator ROM directory shaped like verilogapple/"
                             "sim/roms (required for --tier test, refused "
                             "for --tier build)")
    parser.add_argument("--a2til-source", choices=("auto", "pypi", "wheel", "git"),
                        default="auto",
                        help="build tier: auto = PyPI with hashes (pip, or a "
                             "hash-checked wheel unzip if the venv has no "
                             "pip), GitHub pin only if PyPI is unreachable")
    return parser.parse_args()


def main():
    args = parse_args()
    if args.selftest:
        return selftest()
    if args.dest is None:
        raise BootstrapError("--dest is required")
    tier = args.tier
    lock = load_lock()
    destination = args.dest.expanduser().resolve()
    rom_dir = args.rom_dir.expanduser().resolve() if args.rom_dir else None

    if destination.exists() or destination.is_symlink():
        raise BootstrapError(
            f"refusing to alter existing dependency path {destination}; "
            "choose a new --dest"
        )
    if tier == "test":
        if rom_dir is None:
            raise BootstrapError("--tier test needs --rom-dir (the operator "
                                 "ROM set); --tier build needs none")
        if not rom_dir.is_dir():
            raise BootstrapError(f"ROM directory does not exist: {rom_dir}")
    elif rom_dir is not None:
        raise BootstrapError("--rom-dir belongs to the test tier; the build "
                             "tier takes no ROMs")

    # The renderer is itself provisioned below. Audit it with every other
    # dependency after the locked source build, not as a seed prerequisite.
    failures = check_dependencies.tool_failures(lock, check_renderer=False,
                                                tier=tier)
    if failures:
        raise BootstrapError("host prerequisites do not match the lock:\n  - " +
                             "\n  - ".join(failures))
    if tier == "test":
        verify_rom_sources(lock, rom_dir)

    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        destination.mkdir()
    except FileExistsError as exc:
        raise BootstrapError(
            f"refusing to alter dependency path created during bootstrap: "
            f"{destination}"
        ) from exc
    try:
        site = None
        clone_repositories(lock, destination, tier)
        if tier == "build":
            site = install_a2til(lock, destination, args.a2til_source)
        provision_mandoc(lock, destination)
        if tier == "test":
            stage_roms(lock, rom_dir, destination / "verilogapple")
        # Verilator records absolute source paths in generated depfiles. Build
        # only at the permanent destination so published artifacts remain
        # rebuildable in place.
        build_repositories(lock, destination, tier)
        audit(lock, destination, tier, site)
        write_configuration(lock, destination, tier, site)
    except BaseException:
        # This invocation created the destination after refusing any existing
        # path above, so cleanup cannot alter an operator-managed checkout.
        shutil.rmtree(destination)
        raise

    print(f"[bootstrap-deps] PASS: provisioned locked dependencies "
          f"(tier {tier}) at {destination}")
    print(f"[bootstrap-deps] make will load {destination / 'dependencies.mk'}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BootstrapError as exc:
        print(f"[bootstrap-deps] FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
