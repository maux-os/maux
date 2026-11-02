#!/bin/bash
# sweep_par_selftest.sh -- prove scripts/sweep_par.sh cannot report a
# sweep green when it ran fewer gates than it launched (HYG-2).
#
# Hermetic: a stub `make` first on PATH answers the three questions the
# driver asks (`-pn`: the rule database, `-s image play-image`: build,
# `-s <gate>`: run one gate), so there is no emulator, no image, no
# lock on build/ and the whole file takes a couple of seconds. It does
# NOT touch the real tree: logs, pid file and the stub live in one
# mktemp directory, removed on exit.
#
# Usage: bash scripts/sweep_par_selftest.sh [path/to/sweep_par.sh]
# The optional argument runs the same rows against another copy of the
# driver, which is how the rows are shown red on the base:
#   git show 67c06a18:scripts/sweep_par.sh >/tmp/old.sh
#   bash scripts/sweep_par_selftest.sh /tmp/old.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="${1:-$HERE/scripts/sweep_par.sh}"
W=$(mktemp -d "${TMPDIR:-/tmp}/maux-sweeppar.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT INT TERM
mkdir "$W/bin"

# The stub gate's behaviour is its NAME, so a row is just a target list:
#   check-ok*    pass            check-red*   exit 1
#   check-kself* kill -9 its own make (the stub): the driver sees a
#                failed make and must print FAIL
#   check-klane* kill -9 the PARENT of the stub: in a serial lane that
#                is the lane subshell, in the pool it is xargs's sh -c.
#                No line is ever echoed for it, or for what follows it.
#   check-playk* as check-klane, inside the play.po lane
#   check-play*  names play-image as a prerequisite: the serial lane
cat >"$W/bin/make" <<'EOF'
#!/bin/sh
if [ "$1" = -pn ]; then
  for g in $FAKE_GATES; do
    case $g in check-play*) echo "$g: play-image" ;; *) echo "$g:" ;; esac
  done
  exit 0
fi
[ "$1" = -s ] && shift
case "$1" in
  image|play-image) exit 0 ;;
  check-ok*) exit 0 ;;
  check-red*) exit 1 ;;
  check-kself*) kill -9 $$ ;;
  check-klane*) kill -9 $PPID; sleep 1; exit 0 ;;
  check-playk*) kill -9 $PPID; sleep 1; exit 0 ;;
  check-play*) exit 0 ;;
esac
exit 0
EOF
chmod +x "$W/bin/make"

bad=0
# row NAME WANT_RC WANT_REGEX-or-"" GATES... (env: LOGDIR, GROUPS_ENV)
row() {
  name=$1; want_rc=$2; want_re=$3; shift 3
  ld=${ROW_LOGDIR:-$W/logs}
  mkdir -p "$ld"
  out=$(cd "$W" && PATH="$W/bin:$PATH" FAKE_GATES="$*" CHECKLOGDIR="$ld" \
        SWEEP_PIDFILE="$W/pid" SWEEP_GROUPS="${ROW_GROUPS:-}" \
        bash "$DRIVER" 4 "$@" 2>&1); rc=$?
  ok=1
  [ "$rc" = "$want_rc" ] || ok=0
  if [ -n "$want_re" ]; then printf '%s\n' "$out" | grep -Eq -- "$want_re" || ok=0; fi
  if [ $ok = 1 ]; then printf 'ok    %-34s rc=%s\n' "$name" "$rc"
  else
    printf 'FAIL  %-34s rc=%s (want %s, /%s/)\n' "$name" "$rc" "$want_rc" "$want_re"
    printf '%s\n' "$out" | sed 's/^/      | /' | tail -12
    bad=$((bad + 1))
  fi
  rm -rf "$ld"
}

# 1. A normal sweep: the count line keeps its shape and it exits 0.
row "normal sweep" 0 '^sweep_par: 6 PASS, 0 FAIL, [0-9]+s wall, 4 lanes \+ 1 play.po lane \(1 gates\)$' \
  check-ok1 check-ok2 check-ok3 check-ok4 check-ok5 check-play1
# 2. An ordinary red is still red, and still exit 1 (not the new code).
row "a red gate" 1 '^sweep_par: 2 PASS, 1 FAIL' check-ok1 check-red1 check-ok2
# 3. The trigger: a 400+ character CHECKLOGDIR. Every gate must run.
long="$W/logs"; while [ ${#long} -lt 420 ]; do long="$long/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; done
ROW_LOGDIR=$long row "420-char CHECKLOGDIR, all run" 0 '^sweep_par: 5 PASS, 0 FAIL' \
  check-ok1 check-ok2 check-ok3 check-ok4 check-ok5
rm -rf "$W/logs"
# 4. A gate whose own make is killed: FAIL, exit 1.
row "gate's make killed -> FAIL" 1 '^check-kself1 FAIL$' check-ok1 check-kself1
# 5. A serial-lane subshell killed mid-lane: the gate that killed it and
#    the one behind it never report. Red, naming both.
ROW_GROUPS="check-ok1,check-klane1,check-ok2" \
row "lane subshell killed" 3 'never reported: check-klane1 check-ok2' \
  check-ok1 check-klane1 check-ok2 check-ok3
# 6. The play.po lane killed.
row "play lane killed" 3 'never reported: check-play2 check-playk1' \
  check-ok1 check-play1 check-playk1 check-play2 check-ok2
# 7. A pool worker (xargs's sh -c) killed: xargs says so, the name is missing.
row "xargs worker killed" 3 'never reported: check-klane2' check-ok1 check-klane2 check-ok2
# 8. A target requested twice would be reported twice: red, not silently
#    counted as two passes.
row "duplicate target" 3 'reported more than once: check-ok1' check-ok1 check-ok1 check-ok2

if [ $bad -eq 0 ]; then echo "sweep_par_selftest: PASS"; else echo "sweep_par_selftest: $bad row(s) FAILED"; exit 1; fi
