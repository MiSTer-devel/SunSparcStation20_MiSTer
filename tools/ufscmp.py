#!/usr/bin/env python3
"""Compare the regular files under a directory of two UFS images
(GPL-2.0-or-later).

    tools/ufscmp.py IMAGE_A OFFSET_A IMAGE_B OFFSET_B PATH [--max N]

Walks PATH in image A and, for every regular file, reads the same path in
image B and compares the contents: a check that what an installer copied
reached the disk intact (e.g. NeXTSTEP's /usr/lib/NextStep from its CD to
a disk the core installed; both file systems start at 0x28000). Prints the
files that differ or are missing in B, and a count. Uses tools/ufsread.py.
"""

import argparse
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ufsread  # noqa: E402


def walk(fs, ino, path):
    mode, data = fs.data(ino)
    for name, i in fs.entries(data):
        if name in (".", ".."):
            continue
        m, _, _, _ = fs.inode(i)
        p = path.rstrip("/") + "/" + name
        if m & 0xF000 == 0x4000:
            yield from walk(fs, i, p)
        elif m & 0xF000 == 0x8000:
            yield p, i


def find(fs, path):
    ino = 2
    for name in [p for p in path.split("/") if p]:
        mode, data = fs.data(ino)
        if mode & 0xF000 != 0x4000:
            return None
        ino = dict(fs.entries(data)).get(name)
        if ino is None:
            return None
    return ino


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("offa", type=lambda x: int(x, 0))
    ap.add_argument("b")
    ap.add_argument("offb", type=lambda x: int(x, 0))
    ap.add_argument("path")
    ap.add_argument("--max", type=int, default=0)
    a = ap.parse_args()
    fa = ufsread.UFS(ufsread.Disk(a.a, 0, a.offa))
    fb = ufsread.UFS(ufsread.Disk(a.b, 0, a.offb))
    root = find(fa, a.path)
    if root is None:
        sys.exit(f"{a.path}: not in {a.a}")
    n = same = 0
    nbytes = 0
    for p, ia in walk(fa, root, a.path):
        n += 1
        ib = find(fb, p)
        if ib is None:
            print(f"missing {p}")
            continue
        _, da = fa.data(ia)
        _, db = fb.data(ib)
        if hashlib.md5(da).digest() == hashlib.md5(db).digest():
            same += 1
            nbytes += len(da)
        else:
            print(f"differs {p} ({len(da)} / {len(db)} bytes)")
        if a.max and n >= a.max:
            break
    print(f"{same} of {n} files identical ({nbytes} bytes)")
    sys.exit(0 if same == n else 1)


if __name__ == "__main__":
    main()
