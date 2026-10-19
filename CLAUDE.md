# SunSparcStation20_MiSTer: working notes for Claude

A SPARCstation 20 (sun4m) core for MiSTer in SystemVerilog.
**Read [docs/VERILOG-PLAN.md](docs/VERILOG-PLAN.md) first**: clean-room
rules, compatibility contracts, architecture, phases, work queue.

## Rules

- **Clean room.** All RTL here is our own or carries a GPL-2-compatible
  license. Never open, quote or translate the source of another
  SPARCstation core without a GPL-compatible license (the earlier VHDL
  core of this machine included). Work from datasheets, QEMU, OpenBIOS,
  OS drivers, our own docs and tests.
- Sun PROM images and any listing, decompiled Forth or detokenized FCode
  made from them stay out of git, in the gitignored `scratch/private/`.
- Keep Main's `hps_io` protocol and OpenBIOS's address map unchanged
  (plan §1.2).
- New files are GPL-2.0-or-later. Use outside RTL only under GPL-2 or a
  permissive license unless the user has decided on GPL-3 (plan §5).
- SystemVerilog that both Quartus 17.0 and Verilator 5 accept; a unit
  bench for each block; comments in English.
- `sys/` is the verbatim Template_MiSTer framework: do not edit it.

## Tools (as set up on the original dev box; adjust per machine)

- Quartus 17.0.2 Lite (`scripts/build.sh`); one flow at a time, restore
  the `.qsf` after Quartus rewrites it.
- Verilator 5 and iverilog for benches and `sim/`.
- QEMU 11.1.1 (`qemu-system-sparc`, built from source; Ubuntu's 8.2.2
  cannot install Solaris and has an `sdiv` bug) for the CPU suite's
  references and running the real PROMs.
- LLVM 18 (`clang --target=sparc-unknown-elf -mcpu=v8`) plus
  `tools/sparc_link.py` for the test suite; SPARC cross GCC
  (`sparc64-linux-gnu-`) and `xsltproc` for `scripts/build-bios.sh`.
- A test MiSTer, set in the gitignored `scripts/local.env`
  (`local.env.sample`); disk images built as in
  [docs/disk-images.md](docs/disk-images.md).
- Main: upstream Main_MiSTer `support/sun` (#1344); CD audio on the
  `sun-ss20-cdaudio` branch (#1345).
