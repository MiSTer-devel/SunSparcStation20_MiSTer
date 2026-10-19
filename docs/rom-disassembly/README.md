# Sun boot PROM disassembly

> **In this repository:** the files that reproduce Sun's code are not included:
> `listing.s`, `forth-dictionary.txt`, `forth-nodes.txt`, `forth.json` and
> the detokenized `fcode-*.txt`. What stays is our own analysis
> (`README.md`, `hardware-access.md`, `post-tests.md`, `device-tree.md`),
> the `romdis.json` label configs and the QEMU traces. To regenerate the
> rest from your own ROM images, run `tools/romdis/` (`romdis.py`,
> `obpforth.py`, `detok.py`). Keep the output out of git (the full set is in the gitignored `scratch/private/rom-disassembly/`). The links to
> those files below assume you have done that.

A complete disassembly of the two Sun OpenBoot PROMs that match the machines
this core models. It is the reference for what the hardware must do to boot
them: every register the PROMs touch,
every self-test and its expected values, and the device tree they build.

| Folder | Image | Machine / CPU | Firmware |
|---|---|---|---|
| [ss5-obp/](ss5-obp/) | `ss5.bin`, 256 KiB, MD5 `6364e9a6f5368e2ecc4e9c1d915a93ae` | SPARCstation 5, microSPARC-II (Swift) | OBP 2.15, 95/03/29 |
| [ss20-obp-2.25/](ss20-obp-2.25/) | `SparcSTATION 20 SunOBP2-25_525-1377-08.ROM`, 512 KiB, MD5 `910bd7306fcec38361fc4c3a2be50fa0` | SPARCstation 10/20 UP/MP, SuperSPARC ± MXCC, HyperSPARC | OBP 2.25 (525-1377-08), 95/09/15; POST VRV3.45 |

The ROM images are Sun/Oracle copyright and are **not** in the repository.
They live in `scratch/SparcStation/`, which is gitignored. Everything here
is generated from them or written by reading them.

## What is where

Each ROM folder has:

| File | What |
|---|---|
| `README.md` | image map, how the ROM is entered, instruction-level reset flow, trap handling, POST output and hand-off to OBP (SS20: CPU detection, MP start-up), open items |
| `post-tests.md` | every POST self-test: entry, algorithm, registers/ASIs touched, expected values, messages; a candidate CPU test-suite section |
| `hardware-access.md` | every physical address and ASI the machine code touches, grouped by device |
| `device-tree.md` | the device tree the PROM builds, from the decompiled Forth; the Forth-level self-tests |
| `listing.s` | the full annotated listing: machine code, data, strings, and the Forth dictionary printed as 16-bit token cells |
| `forth-dictionary.txt` | every Forth word: address, name, flags, type, decompiled body |
| `forth-nodes.txt` | device nodes built into the image |
| `fcode-*.txt` | the embedded FCode images, detokenized |
| `romdis.json` | the hand-written knowledge: entries, labels, comments, regions (**edit this**, not `listing.s`) |
| `forth.json`, `qemu-trace.json` | generated includes (Forth regions and labels; addresses QEMU executed) |
| `qemu-console.txt` | the PROM's serial console under `qemu-system-sparc` |

[OBP-FORTH-FORMAT.md](OBP-FORTH-FORMAT.md) describes the Forthmacs
dictionary format of both images: 16-bit tokens, origin and scale, header
layout, code-field types, and the inner interpreter.

## Key facts

- **Link addresses.**
  - SS5: the PROM is linked at pa `0x70000000`; POST reads itself there
    through ASI 0x20.
  - SS20: the PROM runs in boot mode from VA 0; its devices are reached
    through ASI 0x2e/0x2f (pa `0xe_…`/`0xf_…`).
  - Both: OBP maps the PROM at VA `0xffd00000` and runs the Forth kernel in
    place.
- **Forth.** It uses 16-bit tokens: `cfa = origin + token × S`.
  - SS5: S = 4, origin `0xffd15a00`.
  - SS20: S = 16, origin `0xffd3e600`.
  - NEXT is copied to `0xffef0000`.
- **POST.**
  - SS5: 55 tests in the service manual's order.
  - SS20: 148 routines, 115 of them called.
  - POST output only appears with `diag-switch?` true. The first failure ends
    POST but OBP still starts.
- **IDPROM.** OBP only accepts the IDPROM with byte 0 = 1, byte 1 = `0x80`
  (SS5) or `0x72` (SS20), and byte 15 = XOR of bytes 0-14.
- **QEMU as a reference.** Both PROMs run under `qemu-system-sparc` 8.2. The
  SS5 PROM boots to `ok`. The SS20 PROM stops early ("Data Access Error")
  after POST.

## Regenerating

From the repository root, with the images in `scratch/SparcStation/`:

```sh
R=docs/rom-disassembly/ss5-obp                  # or ss20-obp-2.25
python3 tools/romdis/qemu_trace.py $R/romdis.json --seconds 45   # qemu-trace.json
python3 tools/romdis/obpforth.py   $R/romdis.json                # forth-dictionary.txt, forth-nodes.txt, forth.json
python3 tools/romdis/detok.py      $R/romdis.json                # fcode-*.txt
python3 tools/romdis/romdis.py     $R/romdis.json -o $R/listing.s
```

`romdis.py` merges the config's `include`s (`forth.json`,
`qemu-trace.json`). All the tools are Python 3 standard library; only the
trace needs `qemu-system-sparc`.

## Tools

| Tool | Does |
|---|---|
| [`tools/romdis/sparcv8.py`](../../tools/romdis/sparcv8.py) | SPARC V8 decoder, including the privileged and ASI forms that Capstone gets wrong |
| [`tools/romdis/sun4m.py`](../../tools/romdis/sun4m.py) | ASI and MMU/MXCC register names; SS5/SS20 physical address maps |
| [`tools/romdis/romdis.py`](../../tools/romdis/romdis.py) | recursive descent from the trap table(s) and seeds, constant tracking, device/ASI annotation, strings, xrefs, the listing |
| [`tools/romdis/qemu_trace.py`](../../tools/romdis/qemu_trace.py) | runs a PROM under QEMU and turns every executed address into seeds |
| [`tools/romdis/obpforth.py`](../../tools/romdis/obpforth.py) | walks and decompiles the Forth dictionary |
| [`tools/romdis/detok.py`](../../tools/romdis/detok.py) | FCode detokenizer, using the ROM's own token tables |
