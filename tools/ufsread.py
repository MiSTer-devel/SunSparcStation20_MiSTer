#!/usr/bin/env python3
"""Read files out of a Solaris (SPARC) UFS or NetBSD/sparc FFSv1 slice in a
raw disk image.

    tools/ufsread.py IMAGE ls PATH [--slice N | --offset BYTES]
    tools/ufsread.py IMAGE get PATH OUT [--slice N | --offset BYTES]

The image starts with a Sun disk label (VTOC); the slice (default 0) holds
a big-endian UFS1 file system. --offset gives the file system's byte offset
instead, for images without a Sun label (NeXTSTEP's: its 4.3BSD UFS starts
at 0x28000 on the NeXTSTEP 3.3 CD). Read-only, no fragments of indirect-indirect
blocks beyond triple indirection, no symlinks followed. Meant for pulling
kernel modules out of the test images to read their symbols.
"""

import argparse
import struct
import sys

SECTOR = 512


class Disk:
    def __init__(self, path, slice_no, offset=None):
        self.f = open(path, "rb")
        if offset is not None:
            self.base, self.size = offset, 1 << 40
            return
        label = self.read(0, SECTOR)
        magic, = struct.unpack(">H", label[0x1FC:0x1FE])
        if magic != 0xDABE:
            sys.exit("no Sun disk label (magic %04x)" % magic)
        nhead, nsect = struct.unpack(">HH", label[0x1B4:0x1B8])
        cyl, nblk = struct.unpack(">II", label[0x1BC + 8 * slice_no:
                                               0x1BC + 8 * slice_no + 8])
        self.base = cyl * nhead * nsect * SECTOR
        self.size = nblk * SECTOR

    def read(self, off, n):
        self.f.seek(off)
        return self.f.read(n)


class UFS:
    def __init__(self, disk):
        self.d = disk
        sb = disk.read(disk.base + 8192, 2048)
        magic, = struct.unpack(">I", sb[1372:1376])
        if magic != 0x011954:
            sys.exit("no UFS superblock (magic %08x)" % magic)
        (self.sblkno, self.cblkno, self.iblkno, self.dblkno, self.cgoffset,
         self.cgmask) = struct.unpack(">iiiiii", sb[8:32])
        self.bsize, self.fsize, self.frag = struct.unpack(">iii", sb[48:60])
        self.ipg, self.fpg = struct.unpack(">ii", sb[184:192])
        self.nindir, = struct.unpack(">i", sb[116:120])
        self.inopb, = struct.unpack(">i", sb[120:124])

    def frag_off(self, f):
        return self.d.base + f * self.fsize

    def inode(self, ino):
        cg = ino // self.ipg
        cgstart = self.fpg * cg + self.cgoffset * (cg & ~self.cgmask)
        blk = cgstart + self.iblkno + ((ino % self.ipg) // self.inopb) * self.frag
        off = self.frag_off(blk) + (ino % self.inopb) * 128
        raw = self.d.read(off, 128)
        mode, = struct.unpack(">H", raw[0:2])
        size, = struct.unpack(">Q", raw[8:16])
        db = struct.unpack(">12i", raw[40:88])
        ib = struct.unpack(">3i", raw[88:100])
        return mode, size, db, ib

    def blocks(self, db, ib, nblocks):
        out = list(db)
        def indir(b, level):
            if b == 0:
                return [0] * (self.nindir ** (level + 1))
            ptrs = struct.unpack(">%di" % self.nindir,
                                 self.d.read(self.frag_off(b), self.bsize))
            if level == 0:
                return list(ptrs)
            res = []
            for p in ptrs:
                res += indir(p, level - 1)
                if len(res) + len(out) >= nblocks:
                    break
            return res
        for level, b in enumerate(ib):
            if len(out) >= nblocks:
                break
            out += indir(b, level)
        return out[:nblocks]

    def data(self, ino):
        mode, size, db, ib = self.inode(ino)
        nblocks = (size + self.bsize - 1) // self.bsize
        buf = bytearray()
        for b in self.blocks(db, ib, nblocks):
            buf += (self.d.read(self.frag_off(b), self.bsize) if b
                    else bytes(self.bsize))
        return mode, bytes(buf[:size])

    def lookup(self, path):
        ino = 2
        for name in [p for p in path.split("/") if p]:
            mode, data = self.data(ino)
            if mode & 0xF000 != 0x4000:
                sys.exit("%s: not a directory" % name)
            found = None
            for n, i in self.entries(data):
                if n == name:
                    found = i
            if found is None:
                sys.exit("%s: not found" % path)
            ino = found
        return ino

    @staticmethod
    def entries(data):
        off = 0
        while off < len(data):
            ino, reclen, namlen = struct.unpack(">IHH", data[off:off + 8])
            # 4.4BSD FFS (NetBSD): a type byte, then an 8-bit name length
            namlen &= 0xFF
            if reclen == 0:
                break
            if ino:
                yield data[off + 8:off + 8 + namlen].decode("latin-1"), ino
            off += reclen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("cmd", choices=["ls", "get"])
    ap.add_argument("path")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--slice", type=int, default=0)
    ap.add_argument("--offset", type=lambda x: int(x, 0), default=None)
    a = ap.parse_args()
    fs = UFS(Disk(a.image, a.slice, a.offset))
    ino = fs.lookup(a.path)
    mode, data = fs.data(ino)
    if a.cmd == "ls":
        if mode & 0xF000 == 0x4000:
            for n, i in sorted(fs.entries(data)):
                m, s, _, _ = fs.inode(i)
                print("%06o %10d %s" % (m, s, n))
        else:
            print("%06o %10d %s" % (mode, len(data), a.path))
    else:
        open(a.out, "wb").write(data)
        print("%s: %d bytes" % (a.out, len(data)))


if __name__ == "__main__":
    main()
