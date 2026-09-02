#!/usr/bin/bash
# Run an allowlisted /usr/bin tool with producer-side stdout/stderr byte caps.
#
# Invoked as:
#   /usr/bin/timeout --kill-after=2s <deadline>s /usr/bin/bash run-capped.sh \
#     <max-out> <max-err> <tool> [args...]
#
# timeout puts this script in its own process group and tears the group down
# on deadline, on SIGTERM (plugin stop/destroy), and with SIGKILL after 2s.
set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin

usage() {
  echo "usage: run-capped.sh <max-out> <max-err> <tool> [args...]" >&2
  exit 2
}

is_uint() { [[ ${1:-} =~ ^[1-9][0-9]*$ ]]; }

[[ $# -ge 3 ]] || usage
max_out=$1
max_err=$2
tool=$3
shift 3

is_uint "$max_out" && is_uint "$max_err" || usage
case $tool in
  hyprpicker|wl-copy|notify-send) ;;
  *) echo "run-capped.sh: tool not allowlisted: $tool" >&2; exit 2 ;;
esac
[[ $tool != */* ]] || exit 2

bin=/usr/bin/$tool
[[ -x $bin ]] || exit 127

# head -c closes the pipe at the cap, so a runaway producer gets SIGPIPE
# instead of filling the long-lived shell. stderr is discarded after the cap
# and is never copied into the collector.
"$bin" "$@" 2> >(/usr/bin/head -c "$max_err" >/dev/null) | /usr/bin/head -c "$max_out"
