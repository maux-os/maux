#!/bin/sh
# box_provision.sh -- make the Linux emulator box able to run maux's gate
# suite ITSELF (verilogapple#18 / spec-11; docs/TOOLCHAIN.md).
#
# Shape: the box runs `make check-all-cross` with its OWN local supervisor.
# Not "remote worker, local images": 70 gates mount build/*.po by a path the
# WORKER must see and 15 read the mutated image back on the host -- with no
# shared filesystem that is a shuttle problem. Running the suite on the box
# needs none of that, only the toolchain below.
#
# Idempotent; `sudo -n` only for the apt packages (mandoc, nulib2, vim:
# if it refuses, stop and say so); every step verifies itself. Run from the Mac:
#   sh scripts/box_provision.sh            (HOST defaults below)
# Then run the suite there with scripts/box_gate.sh.
set -eu

HOST="${BOX_HOST:-verilogapple.cornflower.au}"
VA_LOCAL="${VA_LOCAL:-$HOME/src/verilogapple}"          # this Mac's checkout
VA_BOX="${VA_BOX:-/opt/verilogapple}"                    # spec-11 deployment
MERLIN_TGZ="https://github.com/lscharen/merlin32/archive/refs/tags/v1.1.10.tar.gz"
A2TIL_LOCAL="${A2TIL_LOCAL:-$HOME/src/a2til}"            # this Mac's checkout
PLASMA_LOCAL="${PLASMA_LOCAL:-$HOME/src/PLASMA}"          # this Mac's PLASMA fork
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 $HOST"

say() { printf '\n[box] %s\n' "$*"; }

say "0/7 mandoc -- check-man-image renders the manual corpus with it"
# The box had groff and nroff but not mandoc, so check-man-image died at
# build/man/admin.TXT and the WHOLE box sweep stopped 71 seconds in --
# two-host verification silently unavailable from 2026-09-11 (02a2478)
# until 2026-09-20. groff is NOT a substitute: the rendering is pinned
# byte-for-byte (828309c), so a different renderer is a different corpus.
# This is the one step here that needs sudo; it is a no-op once done.
$SSH 'command -v mandoc >/dev/null || sudo -n apt-get install -y mandoc'
$SSH 'command -v mandoc >/dev/null' \
  || { echo "!!! mandoc still missing on the box; check-man-image cannot run"; exit 1; }
echo "mandoc present: $($SSH 'dpkg-query -W -f=\${Version} mandoc 2>/dev/null')"
# nulib2(1): the host NuFX oracle. check_nulib2.py SKIPS its host
# cross-checks when it is missing (silently green on the box since the
# gate landed), and check_ls_case.py (prodos-case, 2026-10-09) builds a
# mixed-case .shk fixture with it and FAILS without it -- the first box
# sweep of that merge went 124/1 on exactly this. Debian ships 3.1.0.
$SSH 'command -v nulib2 >/dev/null || sudo -n apt-get install -y nulib2'
$SSH 'command -v nulib2 >/dev/null' \
  || { echo "!!! nulib2 still missing on the box; check-ls (case phase) cannot run"; exit 1; }
echo "nulib2 present: $($SSH 'dpkg-query -W -f=\${Version} nulib2 2>/dev/null')"
# vim(1): check-tip-vim drives a HOST vim on a vt102 pty and asserts the
# maux console's screen against it. check_tip_vim.py SKIPs when there is
# no vim -- on a box without one that was a silent green, so SER-1 kept
# the gate off the box list (HYG-1, 2026-10-20). The full `vim` package,
# not vim-tiny: the gate needs the editor itself, not a vi alias.
$SSH 'command -v vim >/dev/null || sudo -n apt-get install -y vim'
$SSH 'command -v vim >/dev/null' \
  || { echo "!!! vim still missing on the box; check-tip-vim cannot run"; exit 1; }
echo "vim present: $($SSH 'dpkg-query -W -f=\${Version} vim 2>/dev/null')"

say "1/7 ROM dumps the worker needs but the deployment lacks (your own dumps, not build products)"
#   The set is dependencies.lock.json's `roms` table -- the same nine files
#   `make bootstrap-deps ROM_DIR=...` demands -- read here, not listed:
#   the hand-kept list (mouse + UltraTerm) is what let disk2.rom, ssc.rom
#   and the MAME PAL jedec go missing on a clean host (RC-1 F7-F9, KFIX12).
#   Each file is checked against the lock's length and sha256 on the Mac
#   BEFORE it is sent, and again on the box after.
LOCK_JSON="${LOCK_JSON:-$(dirname "$0")/../dependencies.lock.json}"
ROM_ROWS=$(python3 - "$LOCK_JSON" "$VA_LOCAL/sim/roms" <<'PY'
import hashlib, json, os, sys
lock, roms = sys.argv[1], sys.argv[2]
bad = []
for rom in json.load(open(lock))["roms"]:
    path = os.path.join(roms, rom["source"])
    if not os.path.isfile(path):
        bad.append(f"missing {path}")
        continue
    data = open(path, "rb").read()
    if len(data) != rom["bytes"] or hashlib.sha256(data).hexdigest() != rom["sha256"]:
        bad.append(f"{path} does not match the lock ({rom['bytes']} bytes, {rom['sha256']})")
        continue
    print(rom["source"], rom["sha256"])
if bad:
    sys.exit("!!! " + "\n!!! ".join(bad))
PY
) || { printf '%s\n' "$ROM_ROWS"; echo "!!! this Mac's ROM tree does not match the lock; fix it first"; exit 1; }
#   Also link them into the in-tree sim/roms/: find_roms_dir() honours
#   VERILOGAPPLE_ROMS for the SYSTEM ROMs, but the PERIPHERAL loaders in
#   sim/core/loaders.h (load_applemouse_rom, load_ultraterm_firmware,
#   load_disk2_rom, load_ssc_rom) ignore it and search only ../roms/
#   relative to the worker's cwd (sim/top) and a hard-coded Mac path.
#   Found 2026-09-05 by this script's own step 5 -- files present, worker
#   still said missing. One link PER FILE: an older run of this script
#   linked the whole ultraterm/ directory, and a per-file link made
#   through that directory link would replace the real file with a link
#   to itself, so a leftover directory link is removed first (and so is
#   the ultraterm/ultraterm link that `ln -sfn` made INSIDE an existing
#   real directory, which the box had grown by hand).
#   TWO ssh connections for the whole set, not three per file: the box's
#   sshd was measured (2026-10-20) timing out every other connection.
ROM_FILES=$(printf '%s\n' "$ROM_ROWS" | cut -d' ' -f1)
COPYFILE_DISABLE=1 tar --format=ustar -C "$VA_LOCAL/sim/roms" -cf - $ROM_FILES | $SSH "mkdir -p $VA_BOX/roms && tar -C $VA_BOX/roms -xf -"
{
  echo "set -e"
  echo "cd $VA_BOX/src/sim/roms"
  printf '%s\n' "$ROM_ROWS" | while read -r rel sha; do
    d=$(dirname "$rel")
    if [ "$d" != . ]; then
      echo "if [ -L $d ]; then rm $d; fi; mkdir -p $d"
      echo "if [ -L $d/$(basename "$d") ]; then rm $d/$(basename "$d"); fi"
    fi
    echo "ln -sfn $VA_BOX/roms/$rel $rel"
    echo "echo '$sha  $rel' | sha256sum -c --quiet - && echo 'rom ok on the box: $rel'"
  done
} | $SSH "sh -s"

say "2/7 merlin32 v1.1.10 (the Mac runs exactly this) -> ~/bin, built from source"
$SSH 'set -eu; mkdir -p ~/bin ~/src
  if [ -x ~/bin/merlin32 ]; then echo "merlin32 already built: $(~/bin/merlin32 2>&1 | head -1)"; exit 0; fi
  cd ~/src && rm -rf merlin32-1.1.10 && curl -sSL '"$MERLIN_TGZ"' | tar xz
  cd merlin32-1.1.10/Source && make >/dev/null && cp merlin32 ~/bin/merlin32
  ~/bin/merlin32 2>&1 | grep v1.1.10'

say "3/7 slot-card firmwares: BUILD products, assembled on the box from their .s sources"
#   (copying the Mac's binaries would be "presence taken as fitness" -- spec-11's own lesson)
$SSH "set -eu; export PATH=\$HOME/bin:\$PATH
  make -C $VA_BOX/src/sim/smartport firmware >/dev/null && ls -l $VA_BOX/src/sim/smartport/firmware | awk '{print \$5, \$9}'
  make -C $VA_BOX/src/sim/timemaster timemaster >/dev/null && ls -l $VA_BOX/src/sim/timemaster/timemaster | awk '{print \$5, \$9}'"

say "4/7 a2til (pure stdlib, python>=3.10) at the path 94 gate scripts expect: ~/src/a2til"
#   rsync'd from THIS Mac's checkout, not cloned: the forgejo remote wants
#   credentials the box has no business holding, and the gates were written
#   against exactly this checkout anyway (same shape as spec-11's deploy).
rsync -az --delete --exclude '.git/' --exclude '__pycache__/' "$A2TIL_LOCAL/" "$HOST:src/a2til/"
$SSH "cd ~/src/a2til && python3 -c 'import a2til.prodos; print(\"a2til import OK\")'"

say "5/7 verify with a REAL reset(ultraterm:true) over the line protocol, not an empty stdin"
#   Exercises every load that was missing: mouse ROM + smartport/timemaster
#   firmware on reset, the two UltraTerm images when the card is requested.
out=$($SSH "printf '%s\n' \
  '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"box-provision\",\"version\":\"0\"}}}' \
  '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}' \
  '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"reset\",\"arguments\":{\"backend\":\"fast\",\"ultraterm\":true}}}' \
  '{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"ultraterm_state\",\"arguments\":{}}}' \
  | $VA_BOX/src/sim/mcp/obj_dir/mcp_supervisor 2>&1")
if printf '%s' "$out" | grep -iqE 'not found|missing|no such file'; then
  printf '%s\n' "$out" | grep -iE 'not found|missing|no such file'
  echo "!!! worker still reports a missing ROM/firmware -- stop here"; exit 1
fi
printf '%s' "$out" | grep -q 'installed.*true' \
  || { echo "!!! reset(ultraterm:true) did not install the card:"; printf '%s\n' "$out" | tail -3; exit 1; }
echo "worker clean: no missing ROM/firmware, UltraTerm installs"

say "6/7 PLASMA fork (the Mac's checkout, rsync'd like a2til) + xplasm built on the box"
#   The six PLASMA gates (check-plasma/plasm/nas/nas-rel/plascut/nas-librel)
#   compile .pla on the HOST with xplasm (C, from the fork's toolsrc) and
#   assemble with acme. It is rsync'd at the revision pinned by maux;
#   xplasm is a Mac binary and is rebuilt here. maux stages the tracked
#   vmsrc/apple/plvmzp.inc itself, so no untracked PLASMA input is required.
#   box_gate.sh exports PLASMA=~/src/PLASMA for the Makefile.
rsync -az --delete --exclude '.git/' --exclude 'src/xplasm' --exclude '*.o' \
  "$PLASMA_LOCAL/" "$HOST:src/PLASMA/"
$SSH 'set -eu; cd ~/src/PLASMA/src && rm -f xplasm && make xplasm >/dev/null && ls -l xplasm | awk "{print \$5, \$9}"'

say "7/7 acme 0.97 (the Mac runs brew's 0.97 = svn r266 \"Zem\") -> ~/bin, built from that exact revision"
#   Neither machine has svn and the GitHub mirror stops at 0.96.4; SourceForge's
#   mod_dav_svn serves any revision over plain HTTP via the !svn/bc/<rev> form.
$SSH 'set -eu; export PATH=$HOME/bin:$PATH
  if acme --version 2>/dev/null | grep -q "release 0.97"; then echo "acme already built: $(acme --version | head -1)"; exit 0; fi
  base="https://svn.code.sf.net/p/acme-crossass/code-0/!svn/bc/266/trunk/src"
  rm -rf ~/src/acme-0.97 && mkdir -p ~/src/acme-0.97 && cd ~/src/acme-0.97
  for f in $(curl -s "$base/" | grep -o "href=\"[^\"]*\"" | sed "s/href=\"//;s/\"$//" | grep -v "/$"); do
    curl -s -o "$f" "$base/$f"
  done
  test -f version.h && grep -q "\"0.97\"" version.h
  make >/dev/null 2>&1 && cp acme ~/bin/acme && ~/bin/acme --version | head -1'

say "done. Next: sh scripts/box_gate.sh  (rsyncs the tree and runs the suite on the box)"
