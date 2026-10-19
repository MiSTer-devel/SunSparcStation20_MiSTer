#!/usr/bin/env bash
# Full Quartus flow for one revision: build_id, synthesis, fit, assemble, STA.
#   scripts/build.sh 20 [--seed N] [--log FILE]
# Output: output_files/SunSparcStation20.rbf and a summary of the fit
# (resources) and of the worst slack per clock. The new core has only the
# SS20 revision (SunSparcStation.qpf, SunSparcStation20.qsf).
#
# The stages run one by one (not --flow compile) so the register count after
# synthesis can be checked before the long fit: an array that fails to infer
# as memory turns into flip-flops silently, and the first symptom is a fit
# that fails at several times the device.
#
# Do not edit the .qsf files or check out other commits while a build runs:
# Quartus rewrites a settings file that changes under it. Only one Quartus
# flow at a time on this machine.
set -u
. "$(dirname "$0")/common.sh"
REV=$(rev_of "${1:-}") || exit 2; shift
[ -f "$REV.qsf" ] || { log "no $REV.qsf: this tree builds SunSparcStation20 only"; exit 2; }
SEED=""; LOG="build_${REV}.log"
while [ $# -gt 0 ]; do
    case "$1" in
        --seed) SEED="$2"; shift ;;
        --log)  LOG="$2"; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
: "${MAX_REGISTERS:=150000}"
Q="$QUARTUS_BIN"
[ -x "$Q/quartus_sh" ] || { log "no quartus_sh in $Q (set QUARTUS_BIN in scripts/local.env)"; exit 1; }
# One flow per project directory: two flows on the same db/ corrupt it.
# Flows of other projects (the machine is shared) are not our business.
# Match on the process name and the working directory, never with
# "pgrep -f": its pattern is in this script's own command line.
busy=""
for pid in $(ps -eo pid=,comm= | awk '$2 ~ /^quartus_(map|fit|asm|sta|sh)$/ {print $1}'); do
    [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$PWD" ] && busy="$busy $pid"
done
if [ -n "$busy" ]; then
    log "a Quartus flow is already running in $PWD (pid$busy); refusing to start a second one"; exit 1
fi
: > "$LOG"
# build_id.v is the version date the OSD shows. It is written here rather
# than by running sys/build_id.tcl standalone: that script opens and closes
# the project, and project_close writes every assignment sys/sys.tcl sources
# back into the .qsf (300 inlined pin lines). BUILD_DATE=YYMMDD pins it.
printf '`define BUILD_DATE "%s"' "${BUILD_DATE:-$(date +%y%m%d)}" > build_id.v
log "=== $REV: build date $(sed 's/.*"\(.*\)"/\1/' build_id.v) ==="
log "=== $REV: synthesis ==="
"$Q/quartus_map" "$PROJECT" -c "$REV" >> "$LOG" 2>&1
RC=$?
MAPSUM="output_files/$REV.map.summary"
if [ $RC -ne 0 ] || [ ! -f "$MAPSUM" ]; then
    log "synthesis failed ($RC):"; grep -E "^Error|Error \([0-9]+\)" "$LOG" | head -30 | sed 's/^/    /'; exit 1
fi
REGS=$(awk -F': *' '/Total registers/ {gsub(/[^0-9]/,"",$2); print $2}' "$MAPSUM")
log "total registers after synthesis: $REGS"
if [ -n "$REGS" ] && [ "$REGS" -gt "$MAX_REGISTERS" ]; then
    log "over $MAX_REGISTERS registers: an array probably did not infer as memory; not fitting"
    grep -E "Info \(2760(03|04|07|14)\)" "$LOG" | sed 's/^/    /' | head -20; exit 1
fi
for S in fit asm sta; do
    X=""; [ "$S" = fit ] && [ -n "$SEED" ] && X="--seed=$SEED"
    log "=== $REV: $S ${X} ==="
    "$Q/quartus_$S" "$PROJECT" -c "$REV" $X >> "$LOG" 2>&1 || {
        log "quartus_$S failed:"; grep -E "^Error|Error \([0-9]+\)" "$LOG" | head -30 | sed 's/^/    /'; exit 1; }
done
FITSUM="output_files/$REV.fit.summary"; STASUM="output_files/$REV.sta.summary"
[ -f "$FITSUM" ] && { log "--- fit summary ---"; sed -n '1,16p' "$FITSUM" | sed 's/^/    /'; }
[ -f "$STASUM" ] && { log "--- worst setup slack per clock ---"; grep -A2 "^Type  : .*Setup" "$STASUM" | sed 's/^/    /' | head -40; }
[ -f "output_files/$REV.rbf" ] && log "OK: output_files/$REV.rbf" || { log "no rbf produced"; exit 1; }
if ! git diff --quiet -- "$REV.qsf" 2>/dev/null; then
    log "warning: Quartus changed $REV.qsf; review with git diff (git checkout -- $REV.qsf to discard)"
fi
