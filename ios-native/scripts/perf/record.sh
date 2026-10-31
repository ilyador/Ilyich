#!/bin/bash
# Records one perf scenario on the phone, over Wi-Fi, and prints its summary table.
#
#   scripts/perf/record.sh <build> <scenario> [seed]
#
# Run it on the Mac from any directory. The app measures itself while the scenario runs and
# writes a summary into its own container; this launches the app with the scenario, waits for
# that file, copies it to build/perf/<build>/ and runs summarize.py. relaunch-check launches the
# app five times. The phone must be unlocked, on the same network, and signed in.
#
# Environment: ILYICH_PERF_TIMEOUT (seconds to wait for a summary, default 300),
# ILYICH_PERF_DEVICE and ILYICH_PERF_BUNDLE to aim at another phone or build, and
# ILYICH_PERF_LANES=<n> to run with n decode lanes instead of the phone's default, and
# ILYICH_PERF_DRIVE=finger to drive the grid as a finger does (the rail's lens and haptics, a
# fling's landing) instead of as C4's driver did; those numbers compare only with each other.
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <build> <scenario> [seed]" >&2
  exit 2
fi
BUILD=$1
SCENARIO=$2
SEED=${3:-7}
DEVICE=${ILYICH_PERF_DEVICE:-00008130-000E0C910C38001C}
BUNDLE=${ILYICH_PERF_BUNDLE:-io.ilyador.ilyich}
TIMEOUT=${ILYICH_PERF_TIMEOUT:-300}
DRIVE=${ILYICH_PERF_DRIVE:-baseline}
REMOTE=Library/Caches/IlyichPerf
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

case $SCENARIO in
  rail-random|rail-sweep|fling|reverse|relaunch-check|memory-warning|background-load) ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac
case $SEED in
  ''|*[!0-9]*) echo "the seed must be a whole number: $SEED" >&2; exit 2 ;;
esac
case $DRIVE in
  baseline) TABLE=$SCENARIO-$SEED ;;
  finger) TABLE=$SCENARIO-$SEED-finger ;;
  *) echo "ILYICH_PERF_DRIVE must be baseline or finger: $DRIVE" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/../.."
OUT=build/perf/$BUILD
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# This scenario's summaries in the app's container, sorted. The listing's layout is not relied
# on: the file names are picked out of it wherever they appear.
summaries() {
  rm -f "$WORK/files.json"
  xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --subdirectory "$REMOTE" --timeout 60 \
    --json-output "$WORK/files.json" >/dev/null 2>&1 || true
  [ -f "$WORK/files.json" ] || return 0
  grep -oE "$SCENARIO-$SEED-[0-9]{8}T[0-9]{6}Z\.json" "$WORK/files.json" | sort -u || true
}

# Launches the scenario and prints the path of its copied summary.
record_once() {
  local before name="" deadline
  before=$(summaries)
  echo "Launching $SCENARIO, seed $SEED, $DRIVE drive" >&2
  xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --timeout 120 \
    "$BUNDLE" -- -IlyichPerfScenario "$SCENARIO" -IlyichPerfSeed "$SEED" -IlyichPerfDrive "$DRIVE" \
    ${ILYICH_PERF_LANES:+-IlyichDecodeLanes "$ILYICH_PERF_LANES"} >&2
  deadline=$((SECONDS + TIMEOUT))
  while [ -z "$name" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "No summary after ${TIMEOUT} s. Is the phone unlocked and the library on screen?" >&2
      return 1
    fi
    sleep 5
    name=$(comm -13 <(printf '%s\n' "$before") <(summaries) | tail -n 1)
  done
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source "$REMOTE/$name" --destination "$OUT/$name" --timeout 120 >&2
  echo "$OUT/$name"
}

RUNS=1
if [ "$SCENARIO" = relaunch-check ]; then RUNS=5; fi
FILES=()
for run in $(seq 1 "$RUNS"); do
  if [ "$RUNS" -gt 1 ]; then echo "Launch $run of $RUNS" >&2; fi
  file=$(record_once) || exit 1
  FILES+=("$file")
done
python3 scripts/perf/summarize.py "${FILES[@]}" | tee "$OUT/$TABLE.md"
echo "Summaries are in $OUT" >&2
