#!/bin/sh
# tip_live.sh -- the live serial session (docs/SERIAL.md sec 3f):
#   window 1: fast_sdl with the Super Serial Card in slot 1 and its RS-232
#             line on a Unix socket (verilogapple e60be40);
#   this terminal: serbridge answering that line with YOUR shell on a pty.
# Then, in the maux window:  $ tip      (~. to hang up)
#
# Usage: sh scripts/tip_live.sh [disk.po] [command...]
#   disk defaults to build/play.po (make play-image first);
#   command defaults to "$SHELL -l"; e.g.  sh scripts/tip_live.sh build/play.po /bin/sh
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VA="${VERILOGAPPLE:-$HOME/src/verilogapple}"
DISK="${1:-$HERE/build/play.po}"; [ $# -gt 0 ] && shift
SOCK="${TIP_SOCK:-/tmp/maux-ssc.sock}"
COLS="${TIP_COLS:-80}"; ROWS="${TIP_ROWS:-24}"; TERMNAME="${TIP_TERM:-vt102}"   # match the maux console
case "$DISK" in /*) ;; *) DISK="$HERE/$DISK" ;; esac
[ -f "$DISK" ] || { echo "tip_live: no disk image $DISK (make play-image)"; exit 2; }
[ -x "$VA/sim/fast/fast_sdl" ] || { echo "tip_live: $VA/sim/fast/fast_sdl not built (make -C $VA/sim/fast fast_sdl)"; exit 2; }

( cd "$VA/sim/fast" && exec ./fast_sdl --sdl --disk "$DISK" --ssc --ssc-socket "$SOCK" ) &
SDL=$!
trap 'kill $SDL 2>/dev/null; rm -f "$SOCK"' EXIT INT TERM
# wait for the listener
i=0; while [ ! -S "$SOCK" ]; do sleep 0.2; i=$((i+1)); [ $i -lt 50 ] || { echo "tip_live: $SOCK never appeared"; exit 1; }; done
if [ $# -gt 0 ]; then CMD="$*"; else CMD="${SHELL:-/bin/sh} -l"; fi
echo "tip_live: line on $SOCK; host end = $CMD; in the maux window type: tip"
cd "$HERE/tools" && exec python3 -m serbridge --socket "$SOCK" --backend exec --exec "$CMD" --term "$TERMNAME" --cols "$COLS" --rows "$ROWS"
