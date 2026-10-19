#!/usr/bin/env bash
#
# run-scsi.sh [20] [--no-build] - the SCSI path in simulation: the
# scsitest ROM (tests/cpu/src/scsitest.S) against two disk images of known
# content, run twice in parallel:
#   one  HD0 only (OSD "SCSI disks: HD0")
#   two  HD0 and HD1 (OSD "HD0+HD1"; t3 and t1)
#   cd   HD0 and a CD at t6 (HD0's image as its data track) with two audio
#        tracks (--cd-audio 2: the track table and frames Main serves), for
#        the CD audio test (PLAN S2)
# Each image: 2048 blocks of 512 bytes, block n = 'SCSI', the tag ('HD0',
# 'HD1'), n, then (n << 8 | k) ^ 0xa5a5a5a5. The write test restores what it
# writes, so both images must be unchanged afterwards. Prints each run's
# probe report and test lines; exit 0 when both runs finish (whatever their
# results: compare them with the expectations in the file's history).
set -uo pipefail
REV="${1:-20}"
case "$REV" in
    20) T=ss20 ;;
    *)  echo "usage: $0 [20] [--no-build]" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ "${2:-}" = "--no-build" ] || sim/build.sh "$REV" > /dev/null || exit 1
python3 tests/cpu/build.py "$T" --main=scsitest -DSCSI_POLLS=200000 > /dev/null || exit 1
ROM=tests/cpu/out/$T/scsitest.rom
mkdir -p sim/out
O=sim/out/scsi-ss$REV
for t in hd0 hd1; do
    python3 tests/cpu/mkscsiimg.py "$O-$t.orig" "$(printf %s "$t" | tr a-z A-Z)" || exit 1   # not ${t^^}: macOS bash 3
    cp "$O-$t.orig" "$O-$t.img"
done
cp "$O-hd0.orig" "$O-one-hd0.img"
cp "$O-hd0.orig" "$O-cd-hd0.img"
cp "$O-hd0.orig" "$O-cd.iso"
"sim/obj_ss$REV/Vsim_top" --rom "$ROM" --hd0 "$O-one-hd0.img" --stop "CPUTEST DONE" --sd-latency 20000 \
    --cycles 150M --quiet --log "$O-one.log" 2> "$O-one.err" &
"sim/obj_ss$REV/Vsim_top" --rom "$ROM" --hd0 "$O-hd0.img" --hd1 "$O-hd1.img" \
    --stop "CPUTEST DONE" --cycles 150M --quiet --log "$O-two.log" 2> "$O-two.err" &
"sim/obj_ss$REV/Vsim_top" --rom "$ROM" --hd0 "$O-cd-hd0.img" --cd "$O-cd.iso" --cd-audio 2 \
    --stop "CPUTEST DONE" --cycles 250M --quiet --log "$O-cd.log" 2> "$O-cd.err" &
wait
clean() { tr -d '\r' < "$1" | tr -cd '\11\12\40-\176' | grep -v '^$'; }
for k in one two cd; do
    echo "== $k: $(tail -1 "$O-$k.err")"
    clean "$O-$k.log" | grep -v "^CPUTEST ss\|^ *$"
done
for f in one-hd0 hd0 hd1; do
    o=hd0; [ "$f" = hd1 ] && o=hd1
    cmp -s "$O-$f.img" "$O-$o.orig" || echo "image $f changed"
done
