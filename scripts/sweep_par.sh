#!/bin/sh
# sweep_par.sh -- run a gate sweep with several gates in flight.
#
# The serial sweep (Makefile check-all-box / check-all-cross) is a
# shell loop calling `make -s <gate>` one at a time: ~10 min on the
# box for 85 gates, one emulator on one core at a time. Every gate
# spawns its own supervisor+emulator over a private pipe and steps in
# CYCLES, not wall clock, so gates do not interfere through timing.
# What DOES stop them running together, and how this driver copes:
#   1. BUILDS. Two `make <gate>` calls racing to build one
#      prerequisite image corrupt it -- so every image the requested
#      gates depend on is built FIRST, serially, from make's own
#      database of prerequisites (NOT every *-image target: the parked
#      self-host cluster's do not build standalone).
#   2. play.po. The emulator's mount is WRITE-THROUGH (guest writes
#      land in the file), which many gates and image builders RELY on
#      to read results back -- so copy-on-write mounts are NOT the
#      answer (tried: the ld image builder reads /SOURCE/RTLIB back
#      from the image it just booted, and check-posixutil/textaudit
#      read outputs off their own copies). The gates that boot the
#      shared build/play.po directly (their prerequisite is
#      play-image; 23 of 85) therefore run in ONE SERIAL LANE, in the
#      serial sweep's own order; every other gate has a private image
#      and runs in the parallel pool alongside that lane.
#   2a. BUILDING an image is not the same as BOOTING it, and the lane
#      above only covers booting. play-image is PHONY (deliberately:
#      a gate's write-through boot leaves its own files on the volume,
#      so the image must be regenerated per gate, never kept by mtime)
#      -- and PHONY means make re-runs its recipe for EVERY dependent,
#      including the 13 gates that reach it TRANSITIVELY through their
#      own image (check-proshim, check-mlival, check-plasm, check-nas*,
#      check-jobctl-b, check-play80, check-plasma, ...). Those sit in
#      13 different lanes, so two of them rebuilt build/play.po at once
#      and the loser faulted on its mmap: sporadic `make: ***
#      [Makefile:1800: play-image] Bus error` reds on gates that never
#      touch play.po. Note what does NOT fix this: the `make -s image
#      play-image $images` pre-build below is pointless against a phony
#      target -- it has no up-to-date state to leave behind, so every
#      later `make -s <gate>` builds it again. Making the lane
#      TRANSITIVE would pull ~44 gates into one serial lane and roughly
#      double the sweep. The fix is in the BUILDER: it stages to a temp
#      file under an exclusive lock and publishes by rename
#      (scripts/imglock.py), so concurrent builders queue and no reader
#      ever sees a half-written image. build_play_image.py and
#      build_proshim_image.py (proshim.po is rebuilt by check-proshim
#      and check-mlival, which share no make edge) do this; the check
#      below WARNS if a new image target needs it and lacks it.
#   3. HIDDEN SHARING. check-ascore, check-ascore-process and
#      check-ascore-warm each rebuild their own image through
#      scripts/build_ascore.py, whose DISK is the hardware image
#      (build/ascore.po) for every variant -- so the trio shares one
#      file even though their make prerequisites differ (found by the
#      first parallel trials: run beside the others, check-ascore saw
#      a TDSKOBJ another variant's build had left on the volume).
#      SWEEP_GROUPS names such groups (space-separated groups, gates
#      within a group comma-separated); each group is its own serial
#      lane. Add a group when a gate is green alone and red in the
#      pool.
#      The third group is check-nas-librel + check-kledger (it reads
#      the same listings, host-side, and fails on a half-written one):
#      the nas-librel stager regenerates all 32 kernel listings
#      build/MAUX*.SYSTEM_Output.txt itself, reads label addresses back
#      out of them for its hazard-1 literal rewrites, and rewrites them
#      while check-kledger reads. THAT pairing is the group's reason and
#      it stays. It used to hold six more gates (check-du/diff/find/ls/
#      sed/tail), whose scripts ran `merlin32 -v1` on a src/test kernel
#      source UNCONDITIONALLY for a symbol dump and so rewrote
#      build/MAUXDUTEST.SYSTEM_Output.txt etc. under the stager
#      (2026-10-01, sweep of 11e1088: check-du's merlin32 rewrote the
#      listing in the same second the stager read it; "cross-module
#      difference '<SIMG_EXIT_END-SIMG_EXIT' ... labels missing from the
#      listing" on a source nobody had touched). Those six were removed
#      by HYG-3: every gate that assembles only to read symbols now does
#      it in a private temp tree (scripts/arena.py private_listing),
#      writing nothing in build/ or src/, so none of them is a writer of
#      a shared listing any more. Their make prerequisites still build
#      the kernel listing, but as TARGETS in the serial pre-build below
#      (du-image, ls-image, ...), up to date by the time any lane runs,
#      like every ungrouped gate's. scripts/check_listings.py (in
#      check-modules) fails the next script that reintroduces the old
#      idiom, so the class needs no new group per gate.
#      The same fix retired the other half of the class: check-shwarm
#      (sh.bin_Output.txt deleted under it by another lane's reassembly
#      of sh.s, HYG-3) was never in any group.
#      The second group is check-proshim + check-mlival, and it did
#      not need a trial to find: both recipes pass $(PROSHIMIMAGE) to
#      their checker, so both BOOT build/proshim.po -- write-through,
#      at the same time, in two different lanes, because they share no
#      make edge. It failed as `/mnt/MAUX/SHIM/T2 unreadable after the
#      run` (2026-09-16, the two logs one second apart) -- the file
#      the tenant had just written, gone because the other gate's lane
#      had republished the image underneath it. A gate's OWN recipe
#      naming an image is the readable form of this hazard, and the
#      lane partition below now WARNS when two lanes name one image;
#      today exactly one pair does, and it is grouped here.
#      The fourth group is check-nas-selfmake-image + check-nas-selfmake
#      (KFIX4, 2026-10-17): the full gate boots the image the -image
#      gate builds, and both rebuild it (the target is not a file), so
#      the lane analysis refused to run the sweep with them apart
#      ("nas-selfmake-image is rebuilt from 2 lanes at once").
#   4. GATES THAT DEPEND ON GATES. check-as lists check-ascore and
#      check-ascore-warm as prerequisites, check-ld lists
#      check-ascore-process: `make -s check-as` in the pool RE-RUNS
#      those gates beside the ascore lane (trial 6: both red). So
#      gate-to-gate edges from make's database are folded into the
#      grouping: every gate connected to another by such an edge, or
#      by a SWEEP_GROUPS entry, shares one serial lane, members in
#      the sweep's own order (which already puts dependencies first).
#   5. GATES THAT DEPEND ON A GATE'S ARTIFACT. check-dialect and
#      check-stagebin depend on build/ascore-*-as.obj, whose RULE
#      runs check_ascore.py -- and the ascore lane rewrites those
#      files while it runs, so a pool `make` saw them stale and ran
#      the ascore gate beside the lane (first sweep after landing
#      ccf8168: both red, green alone). So a prerequisite FILE whose
#      recipe runs a check_*.py joins its gate to every gate that
#      runs the same script (matched by basename: make's database
#      prints recipes unexpanded, `$(SCRIPTS)/check_ascore.py`).
# Usage: sh scripts/sweep_par.sh JOBS TARGET...  Logs land in
# build/checklogs/<target>.log like the serial loop's; the summary and
# exit status take the same shape as check-all-box's.
set -u
# INTERPRETER: run this under bash (>= 4) or dash, NOT under macOS's
# /bin/sh, which is bash 3.2.57 and exits 1 here with no diagnostic
# whatsoever, immediately after the `make -pn` capture below, for any
# target list (found 2026-09-20; the Makefile now names $(SWEEP_SH),
# default bash). NOT zsh either: it does not word-split the unquoted
# $pool below, so every gate becomes one impossible target name.
J="$1"; shift
# The driver's own pid, so a stale run can be stopped by PID TREE
# (`pkill -P`), never by name -- a name-based kill matches the ssh
# shell that launched it (house rule: never pkill by name).
echo $$ >"${SWEEP_PIDFILE:-build/sweep_par.pid}" 2>/dev/null || true
# Run as a recipe, this script's own `make` calls would inherit the
# parent's MAKEFLAGS; they are plain top-level builds here.
unset MAKEFLAGS MFLAGS MAKELEVEL
# A sweep is a claim that every gate ran: a gate that cannot find its
# host oracle (vim, nulib2) must FAIL here, not SKIP green. The gates
# decide, from this variable (scripts/hostoracle.py).
export MAUX_SWEEP=1
LOGDIR="${CHECKLOGDIR:-build/checklogs}"
mkdir -p "$LOGDIR"
db=$(make -pn 2>/dev/null)
images=$(printf '%s\n' "$db" | awk -v want="$*" '
  BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) t[w[i]] = 1 }
  /^[a-z0-9-]+:/ { tgt = $1; sub(":", "", tgt); if (tgt in t)
    for (i = 2; i <= NF; i++) if ($i ~ /-image$/) print $i }' | sort -u)
make -s image play-image $images >"$LOGDIR/images.log" 2>&1 \
  || { echo "image build failed:"; tail -5 "$LOGDIR/images.log"; exit 1; }
# Partition: gates whose prerequisites name play-image -> serial lane.
playgates=$(printf '%s\n' "$db" | awk -v want="$*" '
  BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) t[w[i]] = 1 }
  /^[a-z0-9-]+:/ { tgt = $1; sub(":", "", tgt); if (tgt in t)
    for (i = 2; i <= NF; i++) if ($i == "play-image") print tgt }' | sort -u | tr '\n' ' ')
# NOT named `GROUPS`: that is a bash SPECIAL variable holding the
# caller's group IDs. Assigning to it is ignored and reading it back
# gives the primary GID -- "20" (staff) on macOS -- so the default
# below never reached the analysis and EVERY DECLARED SERIAL GROUP
# HAS BEEN INERT since this file was written. check-proshim with
# check-mlival, and the ascore trio, have been running in parallel
# lanes booting one write-through image, which is precisely the
# nondeterminism this file exists to remove: measured 2026-09-20
# after two sweeps in a row failed on different gates, each of
# which passed standalone. The tripwire below had been reporting it
# correctly and in an ignored warning.
SWEEPGRP="${SWEEP_GROUPS:-check-ascore,check-ascore-process,check-ascore-warm check-proshim,check-mlival check-nas-librel,check-kledger check-nas-selfmake-image,check-nas-selfmake check-fork,check-wait}"
# Union-find over gate-to-gate edges (make database) plus SWEEP_GROUPS
# (python: sh has no arrays; the input is the target list in order).
lanes=$(printf '%s\n' "$db" | python3 -c '
import sys
targets = sys.argv[1].split()
groups = [g.split(",") for g in sys.argv[2].split()]
playgates = set(sys.argv[3].split())
tset = set(targets)
parent = {t: t for t in targets}
def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]; x = parent[x]
    return x
def union(a, b):
    if a in tset and b in tset:
        parent[find(a)] = find(b)
import re
rules = {}      # target -> (prereqs, recipe text)
cur = None
for line in sys.stdin:
    if line.startswith("\t") and cur:
        rules[cur][1].append(line)
    elif line.startswith("#"):
        continue            # make annotates each rule with comments
    elif re.match(r"^[A-Za-z0-9_./$()-]+:", line):
        cur, _, rest = line.partition(":")
        rules.setdefault(cur, [rest.split(), []])
    else:
        cur = None
script_gates = {}   # scripts/check_X.py -> gates whose recipe runs it
for g in targets:
    for l in rules.get(g, [[], []])[1]:
        for m in re.findall(r"check_[a-z0-9_]+\.py", l):
            script_gates.setdefault(m, set()).add(g)
for g in targets:
    pre, _ = rules.get(g, [[], []])
    for w in pre:
        if w.startswith("check-"): union(g, w)
        elif w.startswith("build/") and w in rules:
            for l in rules[w][1]:
                for m in re.findall(r"check_[a-z0-9_]+\.py", l):
                    for other in script_gates.get(m, ()): union(g, other)
for g in groups:
    for t in g[1:]: union(g[0], t)
lanes = {}
for t in targets:
    lanes.setdefault(find(t), []).append(t)
for r, mem in lanes.items():
    if len(mem) > 1: print(",".join(mem))
# TRIPWIRE for the hazard in header note 2a: an image target that two
# LANES can rebuild at once needs an atomic-publish builder
# (scripts/imglock.py), or the sweep goes back to sporadic Bus errors
# on gates that merely depend on it. Silent unless a new one appears.
lane_of = {}
for r, mem in lanes.items():
    for t in mem: lane_of[t] = r
for t in targets: lane_of.setdefault(t, t)
# One serial play.po lane -- and a GROUP that contains a play gate goes
# there WHOLE. Assigning only the play gates used to tear declared
# groups in half, which is what put two boots of one write-through
# image in two lanes and made the tripwire below fire (2026-09-20).
playroots = {find(t) for t in playgates if t in tset}
for t in targets:
    if find(t) in playroots: lane_of[t] = "PLAY"
def reach(t, seen):
    if t in seen: return seen
    seen.add(t)
    for p in rules.get(t, [[], []])[0]: reach(p, seen)
    return seen
import os
builders = {}
for g in targets:
    for t in reach(g, set()):
        if t.endswith("-image"): builders.setdefault(t, set()).add(lane_of[g])
for t, ls in sorted(builders.items()):
    if len(ls) < 2: continue
    srcs = re.findall(r"build_[a-z0-9_]+\.py", "".join(rules.get(t, [[], []])[1]))
    for s in srcs:
        p = os.path.join("scripts", s)
        if os.path.exists(p) and "imglock" not in open(p, errors="replace").read():
            print("sweep_par: WARNING: %s is rebuilt from %d lanes at once and "
                  "%s does not publish atomically -- see scripts/imglock.py"
                  % (t, len(ls), p), file=sys.stderr)
# TRIPWIRE for header note 3: two gates that BOOT one write-through
# image must share a lane. A gate booting an image names it on its own
# recipe line, so this catches the next pair before it flakes.
booters = {}
for g in targets:
    for l in rules.get(g, [[], []])[1]:
        for m in re.findall(r"\$\([A-Z0-9_]*IMAGE[A-Z0-9_]*\)|build/[a-z0-9_-]+\.po", l):
            booters.setdefault(m, set()).add(g)
for m, gs in sorted(booters.items()):
    ls = {lane_of[g] for g in gs}
    if len(gs) > 1 and len(ls) > 1:
        print("sweep_par: WARNING: %s is booted by %s in %d lanes at once -- "
              "add them to SWEEP_GROUPS" % (m, ",".join(sorted(gs)), len(ls)),
              file=sys.stderr)
' "$*" "$SWEEPGRP" "$playgates" 2>"$LOGDIR/lanes.warn")
cat "$LOGDIR/lanes.warn" >&2

# A declared GROUP whose members include a play.po gate must move WHOLE
# into the serial play lane. The loop below puts play gates in that lane
# FIRST, which used to tear a group in half -- and the two halves then
# booted a shared write-through image concurrently, which is exactly the
# condition the python tripwire above reports. Measured 2026-09-20:
# check-proshim and check-mlival both boot $(PROSHIMIMAGE), are grouped
# for that reason, and were landing in two lanes anyway, flaking one or
# both about half the time while every gate passed standalone.
newlanes=""
for g in $lanes; do
  ghit=""
  for m in $(printf '%s' "$g" | tr ',' ' '); do
    case " $playgates " in *" $m "*) ghit=1 ;; esac
  done
  if [ -n "$ghit" ]; then
    for m in $(printf '%s' "$g" | tr ',' ' '); do
      case " $playgates " in
        *" $m "*) ;;
        *) playgates="$playgates $m" ;;
      esac
    done
  else
    newlanes="$newlanes $g"
  fi
done
lanes="$newlanes"

# AND THE TRIPWIRE IS NOW FATAL. It has been correct and ignored: a
# warning printed into a 400-second sweep's output is not a gate, and
# the whole point of this file is that the suite's answer is supposed
# to be deterministic. If a NEW shared-image pair appears, stop.
if grep -q 'WARNING:' "$LOGDIR/lanes.warn" 2>/dev/null; then
  echo "sweep_par: the lane analysis above reported a hazard; the sweep" >&2
  echo "sweep_par: would be nondeterministic, so it is not being run." >&2
  echo "sweep_par: group the named gates in SWEEP_GROUPS and re-run." >&2
  exit 2
fi
lanegates=$(printf '%s\n' "$lanes" | tr ',\n' '  ')
lane=""; pool=""
for t in "$@"; do
  case " $playgates " in *" $t "*) lane="$lane $t"; continue ;; esac
  case " $lanegates " in *" $t "*) continue ;; esac
  pool="$pool $t"
done
start=$(date +%s)
: >"$LOGDIR/sweep_par.out"
# THE LAUNCH SET, and the contract on it (HYG-2, 2026-10-21): a gate
# that never ran is no evidence. $lane, every member of $lanes and $pool
# are what the code below launches; each must report exactly one
# "<gate> PASS|FAIL" line, and xargs and every lane subshell must exit 0.
# Measured on the base: a 400-character CHECKLOGDIR made xargs die with
# "command line cannot be assembled, too long" before it ran ONE gate
# (87 of 152 in the sweep that found it), and the verdict -- fail == 0 --
# printed its count and exited 0. LOGDIR is exported, not spliced into
# the xargs template, so that trigger is gone; the count check below is
# for the next one (a lane subshell killed, a gate's make dying before
# it echoes, xargs gone for a reason nobody has met yet).
launched=$(printf '%s\n' $lane $(printf '%s' "$lanes" | tr ',\n' '  ') $pool)
export SWEEP_LOGDIR="$LOGDIR"
run1() { if make -s "$1" >"$LOGDIR/$1.log" 2>&1; then echo "$1 PASS"; else echo "$1 FAIL"; fi; }
( for t in $lane; do run1 "$t"; done ) >>"$LOGDIR/sweep_par.out" &
lanepid=$!
gpids=""
for g in $lanes; do
  members=$(printf '%s' "$g" | tr ',' ' ')
  ( for t in $members; do run1 "$t"; done ) >>"$LOGDIR/sweep_par.out" &
  gpids="$gpids $!"
done
printf '%s\n' $pool | xargs -P "$J" -I{} sh -c \
  'if make -s "$1" >"$SWEEP_LOGDIR/$1.log" 2>&1; then echo "$1 PASS"; else echo "$1 FAIL"; fi' sh {} \
  >>"$LOGDIR/sweep_par.out"
xrc=$?
bad=""
[ "$xrc" -eq 0 ] || bad="$bad xargs(exit $xrc)"
wait $lanepid || bad="$bad play-lane(exit $?)"
for p in $gpids; do wait $p || bad="$bad lane-subshell-$p(exit $?)"; done
cat "$LOGDIR/sweep_par.out"
fail=$(grep -c ' FAIL$' "$LOGDIR/sweep_par.out")
pass=$(grep -c ' PASS$' "$LOGDIR/sweep_par.out")
echo "sweep_par: $pass PASS, $fail FAIL, $(( $(date +%s) - start ))s wall, $J lanes + 1 play.po lane ($(echo $lane | wc -w | tr -d ' ') gates)"
# Reconcile against the launch set: every name exactly once, nothing
# reported that was not launched, and the set is the one requested.
printf '%s\n' $launched | sort >"$LOGDIR/sweep_par.launched"
printf '%s\n' $* | sort >"$LOGDIR/sweep_par.requested"   # split like $pool: one word of many is tolerated
audit=$(cmp -s "$LOGDIR/sweep_par.requested" "$LOGDIR/sweep_par.launched" ||
    echo "partition lost or invented a gate: launched set differs from the request"
  awk -v want="$LOGDIR/sweep_par.launched" '
    BEGIN { while ((getline l < want) > 0) { w[l] = 1; ord[n++] = l } }
    $2 == "PASS" || $2 == "FAIL" { seen[$1]++; next }
    { junk++ }
    END {
      for (i = 0; i < n; i++) { t = ord[i]; if (!(t in seen)) m = m " " t; else if (seen[t] > 1) d = d " " t }
      for (t in seen) if (!(t in w)) u = u " " t
      if (m != "") print "never reported:" m
      if (d != "") print "reported more than once:" d
      if (u != "") print "reported but not launched:" u
      if (junk) print junk " unparseable line(s) in sweep_par.out"
    }' "$LOGDIR/sweep_par.out")
if [ -n "$bad" ] || [ -n "$audit" ]; then
  echo "sweep_par: INCOMPLETE -- a gate that did not run is not a pass" >&2
  [ -z "$bad" ] || echo "sweep_par: abnormal exit:$bad" >&2
  [ -z "$audit" ] || printf 'sweep_par: %s\n' "$audit" >&2
  echo "sweep_par: $(( pass + fail )) of $(printf '%s\n' $launched | grep -c .) launched gates reported; logs in $LOGDIR" >&2
  exit 3
fi
[ "$fail" -eq 0 ]
