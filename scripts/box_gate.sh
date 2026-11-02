#!/bin/sh
# box_gate.sh -- run maux's gate suite ON the Linux emulator box instead of
# this laptop (verilogapple#18 / spec-11). Provision once with
# scripts/box_provision.sh. Usage:
#   sh scripts/box_gate.sh                 # rsync, then make check-all-box
#   sh scripts/box_gate.sh check-vi        # rsync, then any make target(s)
#   sh scripts/box_gate.sh --prune [DAYS] [--force]   # stale branch trees
#
# check-all-box = check-all-cross minus the three gates whose ORACLE is this
# Mac: check-boot's rtl leg (the box is built without Verilator by design),
# and the two differential e2e gates (check-e2e, check-e2e-fs) whose host
# reference is BSD coreutils -- maux mirrors V7/BSD forms, and GNU cmp's
# wording/-l format and GNU ls's exit 2 for a missing operand are a
# DIFFERENT oracle, not a better one (first box run, 2026-09-05: those
# were the only reds left). Run those three on the Mac (~1 min).
#
# The box builds and gates a fresh copy: build/ is NOT synced (it is generated,
# and the reference artifacts check-all relies on -- see docs/TOOLCHAIN.md,
# never `make clean` -- are created there by `make image play-image` first).
#
# THE DEFAULT SWEEP IS PARALLEL (2026-09-15): check-all-box-par runs
# scripts/sweep_par.sh -- four gates in flight plus serial lanes for
# the gates that share an image or depend on other gates -- 268 s
# for 85 gates on the box against ~600 s serial, validated 85/85 at
# the same commit as the serial loop. `sh scripts/box_gate.sh
# check-all-box` still runs the serial loop.
#
# THREE knobs, all required (PLASMA since 2026-09-14: the six PLASMA
# gates compile .pla with the fork's xplasm + acme, provisioned by
# box_provision.sh steps 6-7 -- the Makefile's default is the Mac path): MAUX_SUPERVISOR is what the gate SCRIPTS spawn
# (scripts/mcp_drive.py); VERILOGAPPLE is what the MAKEFILE derives its
# $(MCP_SUPERVISOR) prerequisite from -- left unset, make tries to BUILD
# ~/src/verilogapple on the box and every emulator gate dies
# before launching (first box run, 2026-09-05: 60 reds in 154 s).
#
# HOST PACKAGES THE BOX NEEDS beyond a stock Debian: check-e2e-host
# (which DOES run here -- it only generates the host references; the
# comparison is the Mac's) refuses to run without every oracle binary
# in /bin or /usr/bin, and Debian ships uuencode/uudecode in
# `sharutils`, not coreutils, and cal in `ncal`, not util-linux.
# Installed 2026-09-14/15 (`sudo apt-get install sharutils ncal`)
# after the uuencode and cal landings' first sweeps each died at that
# gate with 0 PASS -- check-all-box stops at the first red. The box's
# OWN output format never matters for these (the comparison is the
# Mac's); only the binary's presence does.
#
# NODE, installed 2026-10-31 so check-apple2ts can join the box sweep
# instead of sitting in no sweep at all. NOT from apt: Debian 12 ships
# nodejs 18.20.4 and Apple2TS at the pinned commit declares
# `node >=24.22.1 <25 || >=26.12.1 <27` with `npm >=11`, so the distro
# package cannot satisfy it. v26.13.0 (LTS, npm 11.20.0) is unpacked at
# /opt/node-v26.13.0-linux-x64 with /opt/node symlinked to it and
# node/npm/npx linked into /usr/local/bin -- which IS on the PATH of a
# non-interactive ssh (verified: box_gate never gets a login shell, so
# an nvm-style install sourced from a profile would have been invisible
# here). Tarball sha256 checked against nodejs.org's SHASUMS256.txt.
set -eu

HOST="${BOX_HOST:-verilogapple.cornflower.au}"
VA_BOX="${VA_BOX:-/opt/verilogapple}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# One box tree PER BRANCH: src/maux for main, src/maux--<branch> otherwise,
# with slashes in the branch turned into dashes (fix/gate-infra syncs to
# src/maux--fix-gate-infra). Two sessions syncing different branches into
# ONE src/maux with --delete clobbered each other (2026-09-14: a run found
# the other branch's tree, minus this branch's files, minutes after its own
# sync); the first fix keyed the name on the local DIRECTORY, which reads
# fine for a hand-made worktree and not at all for an agent's
# (src/agent-aa1550e05091c6b4d tells a reader nothing), and left two agents
# working the SAME checkout colliding as before. The branch is what a reader
# of `ls ~/src` on the box wants to see, and git already guarantees one
# checkout per branch. BOX_TREE still overrides -- pass it for a scratch
# tree, or to share one deliberately.
#
# Each tree is a FULL build (~450-500 MB on the box, and its first run there
# pays the whole `make image play-image` from scratch), so branches you are
# done with should go: `sh scripts/box_gate.sh --prune [DAYS]` LISTS every
# maux tree with no file touched in DAYS (default 14) and their sizes;
# adding --force removes exactly those, one `rm -rf` per name (the house
# rule for any cleanup loop: print the list and a count first, delete by
# explicit name). It never offers src/maux or this checkout's own tree.
proj_branch_tree() {
  _c=$(cd "$HERE" && git rev-parse --git-common-dir 2>/dev/null) || _c=''
  case "$_c" in
    '') printf 'src/%s\n' "$(basename "$HERE")"; return ;;   # not a git tree at all
    /*) ;;
    *)  _c="$HERE/$_c" ;;                                    # ".git", a plain checkout
  esac
  _proj=$(basename "$(dirname "$_c")")                       # the MAIN checkout's name
  _br=$(cd "$HERE" && git symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || _br="detached-$(cd "$HERE" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  _br=$(printf '%s' "$_br" | tr '/ ' '--' | tr -cd 'A-Za-z0-9._-')
  case "$_br" in
    main|master) printf 'src/%s\n' "$_proj" ;;
    *)           printf 'src/%s--%s\n' "$_proj" "$_br" ;;
  esac
}

if [ "${1:-}" = "--prune" ]; then
  DAYS="${2:-14}"
  KEEP="${BOX_TREE:-$(proj_branch_tree)}"
  printf '[box-gate] stale trees on %s: nothing touched in %s days, keeping src/maux and %s\n' \
    "$HOST" "$DAYS" "$KEEP"
  stale=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" \
    "cd ~/src 2>/dev/null || exit 0; for d in */; do d=\${d%/};
       [ -f \"\$d/scripts/box_gate.sh\" ] || continue;
       [ \"src/\$d\" = src/maux ] && continue;
       [ \"src/\$d\" = '$KEEP' ] && continue;
       [ -n \"\$(find \"\$d\" -newermt '-$DAYS days' -print -quit 2>/dev/null)\" ] && continue;
       printf '%s\t%s\n' \"\$d\" \"\$(du -sh \"\$d\" 2>/dev/null | cut -f1)\";
     done")
  [ -n "$stale" ] || { echo '[box-gate] none'; exit 0; }
  printf '%s\n' "$stale"
  printf '[box-gate] %s tree(s) listed\n' "$(printf '%s\n' "$stale" | wc -l | tr -d ' ')"
  case " $* " in
    *" --force "*) ;;
    *) echo '[box-gate] listing only -- add --force to remove these'; exit 0 ;;
  esac
  # Delete BY EXPLICIT NAME, one rm per name -- never a find -delete loop.
  for name in $(printf '%s\n' "$stale" | cut -f1); do
    printf '[box-gate] rm -rf ~/src/%s\n' "$name"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" "rm -rf ~/src/$name"
  done
  exit 0
fi

TARGETS="${*:-check-all-box-par J=4}"   # parallel sweep (scripts/sweep_par.sh); pass check-all-box for the serial loop
TREE="${BOX_TREE:-$(proj_branch_tree)}"                   # relative to $HOME on the box

# PREFLIGHT (RULINGS-1 F13): before a FULL sweep syncs anything, run the
# static front-door gates here (make preflight, ~30 s: kledger table,
# encoding, modules, dialect, ascii, kbss, kernel images). Over a week
# 19 of 39 box sweeps went red and 215 box-minutes were spent, mostly
# on exactly these. A red preflight aborts with its output and syncs
# nothing. Single-gate runs (box_gate.sh check-vi) skip it.
case " $TARGETS " in
  *" check-all-box-par "*|*" check-all-box "*)
    printf '[box-gate] make preflight (local)\n'
    pf_start=$(date +%s)
    if ! pf=$(cd "$HERE" && make preflight 2>&1); then
      printf '%s\n' "$pf"
      printf '[box-gate] ABORT: make preflight is red; nothing was synced\n'
      exit 1
    fi
    printf '[box-gate] preflight green in %ss\n' "$(( $(date +%s) - pf_start ))"
    ;;
esac

printf '[box-gate] rsync %s -> %s:%s\n' "$HERE" "$HOST" "$TREE"
# -i: itemise what was transferred, and TOUCH exactly those files on the
# box afterwards. rsync -a preserves the SOURCE mtime, and build/ is not
# synced: a file edited at 00:13 arrives on the box with mtime 00:13,
# while an artifact the previous sweep built from the OLD source at
# 00:19 sits there newer -- make calls it up to date and the gate
# compares against a stale reference (2026-10-08: check-nas-librel red
# on six kernels, "nas 8 B longer than ref", Mac green on the same
# commit; build/MAUXDUTEST.SYSTEM was the previous sweep's). Touching
# the changed files makes them newer than every artifact, which is the
# invariant make needs and the one a normal edit-then-build gives.
changed=$(rsync -azi --delete \
  --exclude 'build/' --exclude '.git/' --exclude '.claude/' --exclude '.DS_Store' \
  --exclude '__pycache__/' \
  "$HERE/" "$HOST:$TREE/" | awk '/^[<>]f/ {print $2}')
if [ -n "$changed" ]; then
  printf '[box-gate] %s file(s) changed; touching them on the box\n' \
    "$(printf '%s\n' "$changed" | wc -l | tr -d ' ')"
  printf '%s\n' "$changed" | ssh -o BatchMode=yes "$HOST" "cd ~/$TREE && xargs -r touch"
fi

printf '[box-gate] on %s: make image play-image %s\n' "$HOST" "$TARGETS"
REMOTE="set -eu; export PATH=\$HOME/bin:\$PATH
   export MAUX_SUPERVISOR=$VA_BOX/src/sim/mcp/obj_dir/mcp_supervisor
   export VERILOGAPPLE=$VA_BOX/src
   export PLASMA=\$HOME/src/PLASMA
   cd ~/$TREE && make image play-image >/dev/null && make $TARGETS"
# BOX_DETACH=1: a gate that outlives a laptop session (the make-driven
# nas self-make is ~40 min in one boot; a killed local ssh takes the
# remote job with it). Runs under nohup ON the box, log at
# ~/$TREE/box-gate.log there; poll it with
#   ssh $HOST tail -5 $TREE/box-gate.log
# and read '[box-gate] exit N' from it.
if [ -n "${BOX_DETACH:-}" ]; then
  # The box has no user session manager (no tmux/screen, systemd-run
  # --user cannot reach a bus), so the job runs under nohup with every
  # fd redirected, launched by a LOCAL ssh that is backgrounded and
  # then left alone: sshd holds the channel open while the job's
  # process group lives, and killing that ssh -- even ten seconds
  # after the launch -- took the remote job with it (2026-09-14).
  # The orphaned local ssh exits by itself when the job ends.
  nohup ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$HOST" \
    "cd ~/$TREE && nohup sh -c '($(printf '%s' "$REMOTE" | tr '\n' ';')) 2>&1; echo \"[box-gate] exit \$?\"' > box-gate.log 2>&1 < /dev/null & echo \"[box-gate] detached: ~/$TREE/box-gate.log\"" \
    > /dev/null 2>&1 < /dev/null &
  printf '[box-gate] detached on %s: poll with  ssh %s tail -5 %s/box-gate.log\n' "$HOST" "$HOST" "$TREE"
  exit 0
fi
start=$(date +%s)
rc=0
ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" "$REMOTE" 2>&1 || rc=$?
printf '[box-gate] exit %s, wall time %ss\n' "$rc" "$(( $(date +%s) - start ))"
exit $rc
