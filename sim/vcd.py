#!/usr/bin/env python3
"""vcd.py - query a VCD written by Vsim_top --trace.

  vcd.py FILE list REGEX                 signals whose full name matches
  vcd.py FILE show REGEX... [--from C] [--to C] [--max N]
                                         value changes of the matching
                                         signals, one line per change

Times are printed in cycles (the harness dumps cycle C at 2C+1 and 2C+2);
values in hex. REGEX is matched against the dotted hierarchical name
(TOP.sim_top.machine....).
"""
import re
import sys


def parse_header(f):
    scope, sigs = [], {}
    for line in f:
        tok = line.split()
        if not tok:
            continue
        if tok[0] == '$scope':
            scope.append(tok[2])
        elif tok[0] == '$upscope':
            scope.pop()
        elif tok[0] == '$var':
            width, ident, name = int(tok[2]), tok[3], tok[4]
            sigs.setdefault(ident, []).append(('.'.join(scope + [name]), width))
        elif tok[0] == '$enddefinitions':
            break
    return sigs


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    path, cmd, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    t_from, t_to, maxn, pats = 0, 1 << 62, 1 << 62, []
    i = 0
    while i < len(rest):
        if rest[i] == '--from':
            t_from = int(rest[i + 1]); i += 2
        elif rest[i] == '--to':
            t_to = int(rest[i + 1]); i += 2
        elif rest[i] == '--max':
            maxn = int(rest[i + 1]); i += 2
        else:
            pats.append(re.compile(rest[i])); i += 1
    with open(path) as f:
        sigs = parse_header(f)
        if cmd == 'list':
            for ident, names in sigs.items():
                for n, w in names:
                    if any(p.search(n) for p in pats):
                        print(f'{n} [{w}]')
            return
        want = {}
        for ident, names in sigs.items():
            for n, w in names:
                if any(p.search(n) for p in pats):
                    want[ident] = (n, w)
                    break
        if not want:
            sys.exit('no signal matches')
        t, n = 0, 0
        for line in f:
            if line[0] == '#':
                t = (int(line[1:]) - 1) // 2
                if t > t_to:
                    break
                continue
            if line[0] == 'b':
                val, ident = line[1:].split()
            elif line[0] in '01xzXZ':
                val, ident = line[0], line[1:].strip()
            else:
                continue
            if ident in want and t >= t_from:
                name, w = want[ident]
                try:
                    v = '%x' % int(val, 2)
                except ValueError:
                    v = val
                print(f'{t:10d}  {name} = {v}')
                n += 1
                if n >= maxn:
                    break


if __name__ == '__main__':
    main()
