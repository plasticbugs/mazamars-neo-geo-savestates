#!/bin/sh
# sim/ssz80/run.sh at save and load points around the bench's sound commands
# (sent every 20000 bus cycles): none, an NMI pending at the request, the
# request inside the NMI handler; then with wait states on every read.
#
#   sim/ssz80/points.sh <m1rom>
set -e
here=$(cd "$(dirname "$0")" && pwd)
m1=$1
[ -f "$m1" ] || { echo "usage: $0 <m1rom>"; exit 2; }
status=0
while read save load want; do
    echo "== save at $save, load at $load"
    if out=$("$here/run.sh" "$m1" "$save" "$load" "$want" 2>&1); then :; else status=1; fi
    echo "$out" | grep -E "PASS|FAIL|waited|never|Error" || true
done <<LIST
150000 90000 60000
140001 80001 60000
140004 80003 60000
140008 80006 60000
140012 80010 60000
140040 80020 60000
LIST
# A stress: two wait states on every read, RAM too (the driver idles in RAM,
# so otherwise no entry meets one)
echo "== save at 150000, load at 90000, every read waits"
if out=$(SS_WAIT_ALL=1 "$here/run.sh" "$m1" 2>&1); then :; else status=1; fi
echo "$out" | grep -E "PASS|FAIL|never|Error" || true
exit $status
