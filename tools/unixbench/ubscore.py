#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""ubscore.py LOG [LOG...] - the UnixBench System Benchmarks Index from the
UB| lines tools/unixbench/ub.sh prints (a console capture is fine: other
lines are ignored), computed as UnixBench's Run does:

  - a pass's score: its copies' counts summed, their times averaged; with a
    timebase > 0 the rate is count / (time / timebase), time being the
    program's TIME if it reported one, else the elapsed time;
  - a test's score: the worst third of its passes dropped (by count), the
    geometric mean of the rest;
  - its index: score / baseline * 10, the baseline being UnixBench's
    pgms/index.base, "George", a SPARCstation 20-61 (so 10.0 = that SS20);
  - the overall index: the geometric mean of the tests' indexes.

With several logs, one column per log (named by the file name).
"""
import math
import os
import sys

# pgms/index.base (byte-unixbench), the System Benchmarks
BASE = {
    "dhry2reg": (116700, "lps"), "whetstone-double": (55.0, "MWIPS"),
    "execl": (43.0, "lps"), "fstime": (3960, "KBps"), "fsbuffer": (1655, "KBps"),
    "fsdisk": (5800, "KBps"), "pipe": (12440, "lps"), "context1": (4000, "lps"),
    "spawn": (126, "lps"), "shell8": (6, "lpm"), "syscall": (15000, "lps"),
    "shell1": (42.4, "lpm"),
}
NAMES = {
    "dhry2reg": "Dhrystone 2 using register variables",
    "whetstone-double": "Double-Precision Whetstone",
    "execl": "Execl Throughput",
    "fstime": "File Copy 1024 bufsize 2000 maxblocks",
    "fsbuffer": "File Copy 256 bufsize 500 maxblocks",
    "fsdisk": "File Copy 4096 bufsize 8000 maxblocks",
    "pipe": "Pipe Throughput",
    "context1": "Pipe-based Context Switching",
    "spawn": "Process Creation",
    "shell1": "Shell Scripts (1 concurrent)",
    "shell8": "Shell Scripts (8 concurrent)",
    "syscall": "System Call Overhead",
}


def parse(path):
    """{test: {pass: [(count, timebase, time), ...]}}, copies"""
    res, copies = {}, 1
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip().replace("\r", "")
            i = line.find("UB|")
            if i < 0:
                if "UB-START copies=" in line:
                    copies = int(line.split("copies=")[1].split()[0])
                continue
            f_ = line[i:].split("|")
            # UB|test|pass|copy|elapsed|COUNT|count|timebase|label[|TIME|t]
            if len(f_) < 9 or f_[5] != "COUNT":
                continue
            test, pas, el = f_[1], int(f_[2]), float(f_[4] or 0)
            count, tb = float(f_[6]), float(f_[7])
            t = float(f_[10]) if len(f_) >= 11 and f_[9] == "TIME" else el
            res.setdefault(test, {}).setdefault(pas, []).append((count, tb, t))
    return res, copies


def score(passes):
    pres = []
    for cps in passes.values():
        count = sum(c for c, _, _ in cps)
        t = sum(x for _, _, x in cps) / len(cps)
        pres.append((count, cps[0][1], t))
    pres.sort(key=lambda p: p[0])
    keep = pres[len(pres) // 3:]
    logs = []
    for count, tb, t in keep:
        if count <= 0:
            continue
        logs.append(math.log(count) - math.log(t / tb) if tb > 0 and t > 0 else math.log(count))
    return math.exp(sum(logs) / len(logs)) if logs else None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cols = []
    for p in sys.argv[1:]:
        res, copies = parse(p)
        scores = {t: score(v) for t, v in res.items()}
        cols.append((os.path.basename(p), copies, scores))
    w = 40
    print(f"{'System Benchmarks Index (SS20-61 = 10.0)':{w}}" +
          "".join(f"{n[:22] + ' x' + str(c):>26}" for n, c, _ in cols))
    totals = [[] for _ in cols]
    for t in BASE:
        row = f"{NAMES[t]:{w}}"
        for k, (_, _, s) in enumerate(cols):
            if s.get(t):
                idx = s[t] / BASE[t][0] * 10
                totals[k].append(math.log(idx / 10))
                row += f"{s[t]:>14.1f} {BASE[t][1]:>5} {idx:>5.1f}"
            else:
                row += f"{'-':>26}"
        print(row)
    print(f"{'System Benchmarks Index Score':{w}}" + "".join(
        f"{(math.exp(sum(l) / len(l)) * 10 if l else 0):>26.1f}" +
        ("" if len(l) == len(BASE) else f" ({len(l)}/{len(BASE)})") for l in totals))


if __name__ == "__main__":
    main()
