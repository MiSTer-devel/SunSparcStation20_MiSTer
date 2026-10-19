#!/usr/bin/env bash
# setopt.sh [name=value ...] - set the core's OSD options without the OSD.
#
# MiSTer keeps a core's OSD state in /media/fat/config/<CORENAME>.CFG: the
# 128-bit status word, 16 bytes, bit N in byte N/8 bit N%8. It is read when the
# core starts, so this writes the file and the caller relaunches the core.
# Names follow CONF_STR in SunSparcStation.sv (and rtl/machine/ss20_osd.sv);
# keep them in step.
#
#   memory=464|256|128|64    O[23:22] Memory (top page)
#   network=eth0|none|eth1|macvlan|tap0 O[26:24] Network interface (top page;
#                            Main's sun_enet; "off" is the old name of none)
#   console=video|serial     O[9]    Display (P2 Video)
#   aspect=4:3|full|arc1|arc2 O[7:6]  Aspect ratio (P2 Video)
#   scale=vint|normal|hvint-|hvint+|hvint O[30:28] Scale (P2 Video)
#   kbd=us|fr|de|es          O[13:12] Keyboard layout (P3 Input)
#   swap=no|yes              O[27]   Swap Alt/Win keys (P3 Input)
#   autoboot=on|off          O[8]    Autoboot (P5 Advanced)
# Not in the OSD, meaning kept (the core ignores them for now):
#   video=tcx|cg3            O[10]   no CG3 in this core: always TCX
#   l2tlb=on|off             O[17]   no L2 TLB in this core yet
#   iommu=26|11|23|30        O[21:20] unused (the SS20's IOMMU is fixed)
# Not in the OSD, bring-up only:
#   sdram_rd=0|1|2|3         [33:32] sdram64's read capture point (0: clk
#                            edge 3; 1: clk_sdram 2.75; 2: falling 2.5;
#                            3: edge 4, the simulation's)
# The disks and the CD are always there (a disk while its image is
# mounted). Retired: O[1] (two disks), O[4] (CD block size), O[5] (CD off),
# O[11] (framebuffer output), O[15:14] (the old Scale), O[16] (cache),
# O[18] (write-back), O[19].
#
#   scripts/setopt.sh console=serial kbd=fr
#   scripts/setopt.sh            # all defaults
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
TMP=$(mktemp)
# SETOPT_FORCE="name=value ..." is applied after the arguments: one option
# held for a whole test run (the board scripts set the others themselves),
# e.g. SETOPT_FORCE="l2tlb=off" scripts/hwtest.sh 20 netbsd solaris
# shellcheck disable=SC2086
python3 - "$@" ${SETOPT_FORCE:-} > "$TMP" <<'PY' || { rm -f "$TMP"; exit 2; }
import sys
F = {
    "aspect":   (6, 2, {"4:3": 0, "full": 1, "arc1": 2, "arc2": 3}),
    "autoboot": (8, 1, {"on": 0, "off": 1}),
    "console":  (9, 1, {"video": 0, "serial": 1}),
    "video":    (10, 1, {"tcx": 0, "cg3": 1}),
    "kbd":      (12, 2, {"us": 0, "fr": 1, "de": 2, "es": 3}),
    "scale":    (28, 3, {"vint": 0, "normal": 1, "hvint-": 2, "hvint+": 3, "hvint": 4}),
    "swap":     (27, 1, {"no": 0, "yes": 1}),
    "l2tlb":    (17, 1, {"on": 0, "off": 1}),
    "iommu":    (20, 2, {"26": 0, "11": 1, "23": 2, "30": 3}),
    "memory":   (22, 2, {"464": 0, "256": 1, "128": 2, "64": 3}),
    "network":  (24, 3, {"eth0": 0, "none": 1, "off": 1, "eth1": 2, "macvlan": 3, "tap0": 4}),
    "sdram_rd": (32, 2, {"0": 0, "1": 1, "2": 2, "3": 3}),
}
st = 0
for a in sys.argv[1:]:
    k, _, v = a.partition("=")
    if k not in F or v not in F[k][2]:
        sys.exit(f"setopt: bad option {a!r}; see the header of scripts/setopt.sh")
    lo, w, m = F[k]
    st = (st & ~(((1 << w) - 1) << lo)) | (m[v] << lo)
sys.stdout.buffer.write(st.to_bytes(16, "little"))
sys.stderr.write(f"status = 0x{st:032x}\n")
PY
scp -q "${SSH_OPTS[@]}" "$TMP" "$DEV:/media/fat/config/$GAMES_DIR.CFG" && log "wrote /media/fat/config/$GAMES_DIR.CFG"
rm -f "$TMP"
