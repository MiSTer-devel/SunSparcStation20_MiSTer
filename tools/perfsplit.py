#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""perfsplit.py OUT [CPU] - split a simulation's +perf/+promlog output into
the phases a workload marks on the console (lines "M-NAME" its commands
echo), and print each phase's cycle breakdown for one CPU (default 0) and
the memory controller's figures.

OUT is Vsim_top's stdout: the $display lines of +perf ("perf ...g_cpu[N]...
<C>M: commit user U sup S | w2 .. | mem ld L st T | muldiv .. | fp .. |
hazard .. | fetch .. | other .. | taken .. traps ..") and +promlog, with the
console's characters interleaved. A window counts towards the phase whose
marker came last before it ended.
"""
import re
import sys

PERF = re.compile(r"perf \S*g_cpu\[(\d)\]\S* (\d+)M: commit user (\d+) sup (\d+) \| w2 (\d+) \| "
                  r"mem ld (\d+) st (\d+) \| muldiv (\d+) \| fp (\d+) \| hazard (\d+) \| fetch (\d+) \| "
                  r"other (\d+) \| taken (\d+) traps (\d+)")
PROM = re.compile(r"promlog (\d+)M: requests cpu0 (\d+) \((\d+) writes, (\d+) line reads\) cpu1 (\d+) "
                  r"\((\d+), (\d+)\) dvma (\d+);.*busy (\d+)% \((\d+) cycles a request\)")
MARK = re.compile(r"M-([A-Z]+)")
KEYS = ["user", "sup", "w2", "ld", "st", "muldiv", "fp", "hazard", "fetch", "other", "taken", "traps"]


def main():
    path = sys.argv[1]
    cpu = sys.argv[2] if len(sys.argv) > 2 else "0"
    phase, text = "boot", ""
    last = [0]
    order = ["boot"]
    acc = {"boot": {k: 0 for k in KEYS + ["cyc", "req", "wr", "ln", "busy", "nprom"]}}
    with open(path, errors="replace") as f:
        for line in f:
            # a $display can start in the middle of a console line: what
            # precedes it is console text
            cut = len(line)
            for tag in ("perf ", "promlog ", "iu: ", "[sim]"):
                i = line.find(tag)
                if i >= 0:
                    cut = min(cut, i)
            pre = line[:cut]
            if pre.strip():
                text = (text + pre)[-200:]
                for mm in MARK.finditer(text):
                    name = mm.group(1)
                    if name != phase and '""' not in text[max(0, mm.start() - 3):mm.start() + 2]:
                        if name not in acc:
                            acc[name] = {k: 0 for k in KEYS + ["cyc", "req", "wr", "ln", "busy", "nprom"]}
                            order.append(name)
                        phase = name
                        text = ""
                        break
            line = line[cut:]
            m = PERF.search(line)
            if m:
                if m.group(1) == cpu:
                    a = acc[phase]
                    for k, v in zip(KEYS, m.groups()[2:]):
                        a[k] += int(v)
                    # the window: from the previous line's stamp (any
                    # +perf_period; the stamps are in millions of cycles)
                    stamp = int(m.group(2))
                    a["cyc"] += (stamp - last[0]) * 1_000_000
                    last[0] = stamp
                continue
            m = PROM.search(line)
            if m:
                g = list(map(int, m.groups()))
                a = acc[phase]
                a["req"] += g[1]; a["wr"] += g[2]; a["ln"] += g[3]
                a["busy"] += g[8]; a["nprom"] += 1
                continue

    print(f"cpu {cpu}: % of cycles per cause; CPI = cycles / commits")
    print(f"{'phase':8} {'Mcyc':>6} {'CPI':>5} {'user':>5} {'sup':>5} {'ld':>5} {'st':>5} {'fetch':>5} "
          f"{'hazard':>6} {'muldiv':>6} {'fp':>4} {'w2':>4} {'other':>5} | {'req/10M':>8} {'wr%':>4} {'line%':>5} {'busy%':>5}")
    for p in order:
        a = acc[p]
        if a["cyc"] == 0:
            continue
        c = a["cyc"]
        commits = a["user"] + a["sup"]
        pct = lambda k: 100.0 * a[k] / c
        n = max(a["nprom"], 1)
        req = a["req"] / n
        print(f"{p:8} {c / 1e6:6.0f} {c / max(commits, 1):5.2f} {pct('user'):5.1f} {pct('sup'):5.1f} {pct('ld'):5.1f} "
              f"{pct('st'):5.1f} {pct('fetch'):5.1f} {pct('hazard'):6.1f} {pct('muldiv'):6.1f} {pct('fp'):4.1f} "
              f"{pct('w2'):4.1f} {pct('other'):5.1f} | {req:8.0f} {100.0 * a['wr'] / max(a['req'], 1):4.0f} "
              f"{100.0 * a['ln'] / max(a['req'], 1):5.0f} {a['busy'] / n:5.0f}")


if __name__ == "__main__":
    main()
