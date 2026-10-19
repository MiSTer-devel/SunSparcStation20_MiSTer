#!/usr/bin/env bash
# build-bios.sh - build OpenBIOS (bios/, its tacus-sparc32 target) into
# bios/build/boot.rom.
#
# Needs a SPARC cross compiler and xsltproc:
#   sudo apt install gcc-sparc64-linux-gnu xsltproc
# The sparc32 target builds with -m32 -mcpu=supersparc, so the sparc64
# compiler does (CROSS_COMPILE, default sparc64-linux-gnu-). toke, the FCode
# tokenizer, is built from bios/fcode-utils first. Everything happens in
# bios/build/ (gitignored); the sources stay clean.
#
#   scripts/build-bios.sh [--debug NAME]...
#   scripts/deploy.sh 5 --rom bios/build/boot.rom
#
# --debug NAME turns CONFIG_DEBUG_NAME on in the build's copy of the config
# (e.g. --debug OBP: every romvec call a client makes is printed).
set -eu
. "$(dirname "$0")/common.sh"
CROSS_COMPILE="${CROSS_COMPILE:-sparc64-linux-gnu-}"
command -v "${CROSS_COMPILE}gcc" >/dev/null || { log "no ${CROSS_COMPILE}gcc (sudo apt install gcc-sparc64-linux-gnu)"; exit 1; }
command -v xsltproc >/dev/null || { log "no xsltproc (sudo apt install xsltproc)"; exit 1; }

B=bios/build
rm -rf "$B"
mkdir -p "$B"
cp -a bios/fcode-utils bios/openbios "$B/"
while [ $# -gt 0 ]; do
    case "$1" in
        --debug)
            o="CONFIG_DEBUG_$2"
            grep -q "name=\"$o\"" "$B/openbios/config/examples/sparc32_config.xml" \
                || { log "no option $o"; exit 1; }
            sed -i "s/\(name=\"$o\" type=\"boolean\" value=\)\"false\"/\1\"true\"/" \
                "$B/openbios/config/examples/sparc32_config.xml"
            log "$o on"; shift ;;
        *) log "unknown argument $1"; exit 2 ;;
    esac; shift
done

log "fcode-utils (toke)"
find "$B/fcode-utils" -name '*.o' -delete    # stale objects are not PIE
make -C "$B/fcode-utils" -j"$(nproc)" > "$B/fcode-utils.log" 2>&1 \
    || { tail -20 "$B/fcode-utils.log"; exit 1; }
export PATH="$PWD/$B/fcode-utils/toke:$PWD/$B/fcode-utils/detok:$PATH"

log "OpenBIOS tacus-sparc32 with ${CROSS_COMPILE}gcc"
cd "$B/openbios"
chmod 755 config/scripts/switch-arch
CROSS_COMPILE="$CROSS_COMPILE" ./config/scripts/switch-arch tacus-sparc32 > ../configure.log 2>&1 \
    || { tail -20 ../configure.log; exit 1; }
make build-verbose > ../build.log 2>&1 || { grep -E 'error|Error' ../build.log | head -20; exit 1; }
"${CROSS_COMPILE}objcopy" -O binary obj-sparc32/openbios-builtin.elf ../boot.rom
cd - > /dev/null
log "$B/boot.rom: $(stat -c %s "$B/boot.rom") bytes, md5 $(md5sum < "$B/boot.rom" | cut -c1-8)"
