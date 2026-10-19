#!/usr/bin/env python3
"""Run a boot PROM under qemu-system-sparc and record which ROM addresses
it executes, as a romdis include file.

    qemu_trace.py CONFIG.json [-o qemu-trace.json] [--seconds 45]
                  [--log console.log] [--keep-asm in_asm.log]

QEMU's sun4m machines (SS-5, SS-20) run the real Sun OBP images far enough
to be a useful oracle: POST prints its test names and results, and
`-d in_asm` logs every translated block. Every instruction in that log was
executed, so each one mapped back to the ROM is a known code address -
seeds for romdis's recursive descent, and a check on its code/data split.

The ROM is seen at several virtual addresses during boot (boot mode, the
physical PROM address with the MMU off, the OBP mapping at 0xffd00000);
ALIASES gives, per profile, the ranges that map onto ROM offset 0.
Addresses outside them (RAM copies such as the Forth NEXT at 0xffef0000)
are listed separately in the output as "ram_pcs".
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from romdis import REPO, num                               # noqa: E402

MACHINE = {"ss5": ("SS-5", "64"), "ss20": ("SS-20", "128")}
# virtual address ranges that alias ROM offset 0, per profile
ALIASES = {
    "ss5": [0x00000000, 0x70000000, 0xffd00000],
    "ss20": [0x00000000, 0xf0000000, 0xffd00000],
}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("config")
    ap.add_argument("-o", "--out", default=None,
                    help="include file (default: qemu-trace.json beside "
                    "the config)")
    ap.add_argument("--seconds", type=int, default=45)
    ap.add_argument("--log", help="save the serial console output here")
    ap.add_argument("--keep-asm", help="save the raw in_asm log here")
    args = ap.parse_args()

    cfg = json.load(open(args.config))
    rom = cfg["rom"] if os.path.isabs(cfg["rom"]) else \
        os.path.join(REPO, cfg["rom"])
    size = os.path.getsize(rom)
    base = num(cfg.get("base", 0))
    prof = cfg.get("profile", "ss5")
    machine, mem = MACHINE[prof]

    with tempfile.TemporaryDirectory() as tmp:
        asm = args.keep_asm or os.path.join(tmp, "in_asm.log")
        cmd = ["timeout", str(args.seconds), "qemu-system-sparc",
               "-M", machine, "-m", mem, "-bios", rom, "-nographic",
               "-serial", "mon:stdio", "-monitor", "none", "-display",
               "none", "-d", "in_asm", "-D", asm]
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if args.log:
            open(args.log, "wb").write(p.stdout)
        pcs = set()
        for line in open(asm, errors="replace"):
            m = re.match(r"0x([0-9a-f]{8}):", line)
            if m:
                pcs.add(int(m.group(1), 16))

    rom_pcs, ram_pcs = set(), set()
    for pc in pcs:
        for alias in ALIASES[prof]:
            if alias <= pc < alias + size:
                rom_pcs.add(base + pc - alias)
                break
        else:
            ram_pcs.add(pc)

    out = args.out or os.path.join(os.path.dirname(
        os.path.abspath(args.config)), "qemu-trace.json")
    doc = {
        "_generated": "tools/romdis/qemu_trace.py - ROM addresses executed "
                      f"under qemu-system-sparc -M {machine} in "
                      f"{args.seconds}s; regenerate, do not edit",
        "entries": {f"0x{a:08x}": "" for a in sorted(rom_pcs)},
        "ram_pcs": [f"0x{a:08x}" for a in sorted(ram_pcs)],
    }
    json.dump(doc, open(out, "w"), indent=0)
    print(f"{len(rom_pcs)} ROM addresses, {len(ram_pcs)} RAM addresses "
          f"-> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
