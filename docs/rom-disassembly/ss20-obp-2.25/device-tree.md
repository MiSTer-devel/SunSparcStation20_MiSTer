# SPARCstation 10/20 device tree (OBP 2.25, `525-1377-08`)

How this PROM builds the device tree, which Forth words create the nodes and
properties, and the result. The reference to hold OpenBIOS (the core's BIOS)
against for the SS20 build.

Sources: [`forth-dictionary.txt`](forth-dictionary.txt) (listing addresses =
file offsets; the ROM runs at `0xffd00000 + addr`),
[`forth-nodes.txt`](forth-nodes.txt) (the nodes in the ROM image itself), the
FCode images ([`fcode-00029ae0-espdma.txt`](fcode-00029ae0-espdma.txt) slot f
on-board devices, [`fcode-000299a0-dbri-regs-pa.txt`](fcode-000299a0-dbri-regs-pa.txt)
slot e DBRI stub, [`fcode-0002e680-cgfourteen.txt`](fcode-0002e680-cgfourteen.txt)
SX / VSIMM frame buffer), and the ROM under QEMU 8.2 (`-M SS-20 -m 128`). Under
QEMU this ROM stops early ("Cpu #0 Data Access Error") before the CPU nodes,
the clocks and the SBus probe, and reads garbage NVRAM options, so the QEMU
dump in the appendix covers only the static part; the rest below is from the
code. Compare with [`../ss5-obp/device-tree.md`](../ss5-obp/device-tree.md):
same OBP, same mechanisms.

## 1. How the tree is built

1. **Static** (in the ROM image): `/` (with `name SUNW,SPARCstation-20`,
   `model SUNW,S20,501-2324`, `compatible sun4m`, `breakpoint-trap 0x7f`,
   `get-unum`), `/SUNW,sx@f,80000000`, `/eccmemctl@f,0`,
   `/virtual-memory@0,0`, `/memory`, `/obio` with `power`, `auxio`,
   `SUNW,fdtwo`, `interrupt`, `counter`, `eeprom`, `zs` x2, `/iommu@f,e0000000`,
   `/iommu/sbus@f,e0001000`, `/openprom`, `/aliases`, `/options`,
   `/packages/{obp-tftp,deblocker,disk-label}`.
2. **`stand-init`** (run from `cold`) adds, among others:
   * `0x0005c9a0`: AER setup (`aer@ 0x801f0000 or aer!`), `map-device` of
     `/eccmemctl`, `/iommu`, `/iommu/sbus` (their `address` properties);
     `/iommu` `version` and `implementation` from the IOMMU control register
     (bits 27:24, 31:28); `/iommu/sbus` `ranges` (slots 0-3, `e` when the IOMMU
     implementation is non-zero, `f`: slot n -> PA `0xe_n0000000`, 256 MB) and
     `burst-sizes` (`0xf8007f` with a non-zero implementation, i.e. 64-bit
     SBus bursts, else `0x7f`); then one **CPU node per module** (`0x0005c8b0`);
   * the CPU clock of every module (`0x0006e9a0`, run on each CPU with
     `xcall-execute`): measured from `ms-factor` (MHz = ms-factor * 40 / 20000),
     plus `version`/`implementation` (MCR) and `psr-version` /
     `psr-implementation` (PSR) of that CPU;
   * root and SBus `clock-frequency` (`0x0006f210` / `0x0006f160`): the
     MBus clock = the slowest CPU clock (at most 40 MHz), snapped with an
     E-cache module to 33, 36, 40 (or 50) MHz, and programs the low byte of
     `mdelay` from it (MHz * 0xa0 / 0x190); SBus = MBus / 2;
   * root `banner-name` (`0x00061430`: "SPARCstation 20 " + the module list),
     `idprom` (`0x0005f310`: the 32 NVRAM IDPROM bytes), `fb`, `stdin-path` /
     `stdout-path`;
   * `/memory` `reg` / `available`, `/virtual-memory` `available`;
   * `scsi-initiator-id` on `/iommu/sbus`.
3. **`probe-all`** (`0x0006f270`): drop-in `probe-`, `probe-video` (for each
   VSIMM memory range, `probe-virtual` the built-in **cgfourteen** FCode
   (`0x2e680`) under `/obio`), `probe-simm-fcode` (FCode on SIMMs, 8 slots),
   `probe-sbus`, drop-in `probe+`.
4. **SBus probing**: `sbus-probe-list` default `fe0123` (IOMMU implementation
   non-zero, the SS20) or `f0123` (SS10). The SBus `map-in` substitutes the
   built-in FCode for:
   * slot f, offset 0 (`0x0005c1b0`, `sbus-slot-f` = `0xffd29ae0`): `espdma`,
     `esp`, `sd`, `st`, `ledma`, `le`, `SUNW,bpp`, and on an SS10 (IOMMU
     implementation 0) also the DBRI at slot f `+0x8000000` / `+0x8010000`
     (its own FCode is `byte-load`ed, then a `mmcodec` child);
   * slot e, offset 0 (`0x000612e0`, `0xffd299a0`): the DBRI stub:
     `byte-load` the DBRI's own FCode from slot e `+0x1000`, write -1 to its
     register at `+0x10000`, then add `isdn-disabled` and the SpeakerBox
     `speaker`, `input-microphone`, `output-headphone`, `input-line`,
     `output-line` properties;
   * slots 0-3: the cards' FCode PROMs.

## 2. The tree

| Node | Made by | Physical registers (36-bit) | Notes |
|---|---|---|---|
| `/` | static (`root-node`, `0x0004eb30`) | - | name, model static; `banner-name`, `idprom`, `clock-frequency`, `fb`, paths at run time |
| `/<cpu>@f,f8fffffc` (one per module) | run time `0x0005c8b0` | `0xf_f8fffffc` + (mid - 8) << 24 | name `TI,TMS390Z50` (SuperSPARC) / `TI,TMS390Z55` (with MXCC E-cache) / `Ross,...RT625` / `Cypress,CY605`; see section 3 |
| `/SUNW,sx@f,80000000` | static | `0xf_80000000`, `0xf_80001000`, 0x500 each | SX pixel processor |
| `/eccmemctl@f,0` | static | `0xf_00000000`, 0x20 | `mc-type SMC`, `width 0x20`; `address` at run time |
| `/virtual-memory@0,0` | static | - | as SS5 |
| `/memory` | static | RAM | `reg` / `available` at run time; `selftest` |
| `/obio` | static | `ranges`: space 0 -> `0xf_f1000000` (16 MB); 1 -> `0x0_90000000`, 2 -> `0x0_9c000000`, 3 -> `0x0_f0000000`, 4 -> `0x0_fc000000` (64 MB each) | `device_type hierarchical` |
| `/obio/zs@0,0` | static | `0xf_f1000000`, 8 | keyboard/mouse; `slave 1`, `intr 0x2c,0`, `interrupts 0xc`, `keyboard`, `port-a/b-ignore-cd` |
| `/obio/zs@0,100000` | static | `0xf_f1100000`, 8 | ttya/b; `slave 0` |
| `/obio/eeprom@0,200000` | static | `0xf_f1200000`, 0x2000 | `model mk48t08` |
| `/obio/counter@0,300000` | static | `0xf_f1300000`..`f1303000` (per CPU), `0xf_f1310000` (system), 0x10 each | |
| `/obio/interrupt@0,400000` | static | `0xf_f1400000`..`f1403000` (per CPU), `0xf_f1410000` (system), 0x10 each | |
| `/obio/SUNW,fdtwo@0,700000` | static | `0xf_f1700000`, 8 | `intr 0x2b,0`, `interrupts 0xb`, `device_type block` |
| `/obio/auxio@0,800000` | static | `0xf_f1800000`, 1 | |
| `/obio/power@0,a01000` | static | `0xf_f1a01000`, 1 | `intr 0x22,0`, `interrupts 2` |
| `/obio/cgfourteen@...` | FCode `0x2e680`, per VSIMM | VSIMM | only with a VSIMM |
| `/iommu@f,e0000000` | static | `0xf_e0000000`, 0x300 | `page-size 0x1000`, `cache-coherence?`; `version`, `implementation`, `address` at run time |
| `/iommu/sbus@f,e0001000` | static | `0xf_e0001000`, 0x20 | `slot-address-bits 0x1c`, `up-burst-sizes 0x3f`, `device_type hierarchical`; `ranges`, `burst-sizes`, `clock-frequency`, `scsi-initiator-id`, `address` at run time |
| `.../sbus/espdma@f,400000` | FCode `0x29ae0` | `0xe_f0400000`, 0x10 | |
| `.../espdma/esp@f,800000` | FCode | `0xe_f0800000`, 0x40 | `intr 0x24,0` (`esp-intr`), `clock-frequency 40 MHz`, `device_type scsi` |
| `.../esp/sd`, `.../esp/st` | FCode | - | |
| `.../sbus/ledma@f,400010` | FCode | `0xe_f0400010`, 0x20 | `burst-sizes 0x3f` |
| `.../ledma/le@f,c00000` | FCode | `0xe_f0c00000`, 4 | `intr 0x26,0` (`le-intr`), `busmaster-regval 7`, `alias le`, `device_type network` |
| `.../sbus/SUNW,bpp@f,4800000` | FCode | `0xe_f4800000`, 0x1c | `interrupts 2` (SBus level), `intr` made by the `intr` word from level 2 |
| `.../sbus/SUNW,DBRI@e,...` | DBRI's own FCode, via the stub `0x299a0` | slot e | + `isdn-disabled`, `speaker`, `input-*`, `output-*`; child `mmcodec` |
| `/openprom`, `/aliases`, `/options`, `/packages/...` | static | - | as SS5; aliases point at slot f devices |

## 3. The CPU nodes (`0x0005c8b0` and the module words)

Common: `mailbox` (reg), `mailbox-virtual`, `context-table`, `page-size 0x1000`,
`mid`, `cache-coherence?`, `device_type cpu`; per CPU at run time `version`,
`implementation`, `psr-version`, `psr-implementation`, and with an E-cache or
a Ross 625 `clock-frequency`.

| Module | Name | Properties |
|---|---|---|
| SuperSPARC, no E-cache (`viking?`, `0x000585b0`) | `TI,TMS390Z50` | `reg` = (0xf, mid<<24 \| 0xf0fffffc, 4), `sparc-version 8`, `ncaches 2`, `mmu-nctx 0x10000`, `icache-associativity 5`, `icache-nlines 0x40`, `icache-line-size 0x40`, `dcache-associativity 4`, `dcache-nlines 0x80`, `dcache-line-size 0x20`, `cache-physical?` |
| SuperSPARC with MXCC (`ecache?`) | `TI,TMS390Z55` | the above, `reg` + three MXCC pages (`0xf0c00000`, `0xf0000000`, `0xf0800000` \| mid<<24), `ecache-associativity 1`, `ecache-nlines 0x8000`, `ecache-line-size 0x20`, `bcopy?`, `bfill?`, `mxcc-version`, `ecache-parity?` (when the MXCC control register shows parity) |
| Ross 625 (`0x00059e40`) | `Ross,` + module string | `bcopy?`, `sparc-version 8`, `nmmus 1`, `ncaches 1`, `cache-associativity 1`, `mmu-nctx 0x1000`, `cache-nlines`, `cache-line-size` |
| Cypress 605 (`0x0005a610`) | `Cypress,CY605` | `sparc-version 7`, `nmmus 1`, `ncaches 1`, `cache-line-size 0x20`, `cache-nlines 0x800`, `cache-associativity 1`, `mmu-nctx 0x1000` |

The banner's CPU list (`0x00061340`) prints "(390Z50)", "(390Z55)", "(605..)"
or the Ross string per module.

## 4. Forth-level self-tests and diagnostics

The same words as on the SS5 (addresses here): `test <dev>` (`0x0005ded0`),
`test-all` (`0x0005de90`), `test-memory` (`0x00062210`), `/memory selftest`
(`0x000621a0`, `memory-test-suite` `0x000675c0`), `zs@0,100000 selftest`
(`0x000693e0`, `utest`), `zs@0,0 selftest` (`0x0006b5d0`, keyboard),
`SUNW,fdtwo selftest` (`0x0006e3e0`), `watch-clock` (`0x0005f060`),
`watch-net`, `watch-aui`, `watch-tpe`, `watch-net-all`, `probe-scsi`,
`probe-scsi-all` (`0x0006b7c0`..), and in the slot f FCode the `esp`, `sd`,
`st` and `le` `selftest` methods (`esp-test-reg`, `dmaread`/`dmawrite` DMA
tests, LANCE loopback). The SS20 has no CS4231 test (no CS4231); the DBRI's
tests come from its own FCode.

## 5. Things to check in OpenBIOS

* The NVRAM IDPROM (the 32 bytes the root `idprom` is made from) is only
  accepted (`0x0005f390`) with byte 0 = 1 (format), byte 1 = `0x72`
  (`real-machine-type`) and byte 15 = the XOR of bytes 0-14; the
  Ethernet address and host ID come from it.
* The 36-bit physical addresses: `reg` = (space = PA bits 35:32, PA 31:0);
  obio devices in space `0xf` at `0xf_f1xxxxxx`, SBus slots in space `0xe`.
* Per-CPU `counter` and `interrupt` register sets (4 CPUs + system) in `reg`.
* `/eccmemctl@f,0` and `/SUNW,sx@f,80000000` exist statically; a machine
  without SX still has the node.
* `/iommu` `version`/`implementation`: they decide slot e in `ranges`,
  `burst-sizes` and `sbus-probe-list`.
* CPU node names and property sets per module type (section 3); `mid`,
  `mailbox`, `mailbox-virtual` for MP.
* `clock-frequency` on root (MBus) and SBus (MBus / 2) and per CPU.
* SBus `up-burst-sizes` (static) and `burst-sizes` (run time) are distinct.

## Appendix: the tree under QEMU (SS20, partial)

Printed by the ROM under QEMU 8.2 after its early stop: static nodes only; no CPU node (the unnamed node is the half-built one), no SBus devices, and `/options` shows QEMU's uninitialised NVRAM.

<details><summary>full dump</summary>

```

/
    model                    SUNW,S20,501-2324
    name                     SUNW,SPARCstation-20
    breakpoint-trap          0000007f
    compatible               sun4m
    get-unum                 ffd3db10
    stdout-path              10 80 98 88 a1 48 00
    stdin-path               10 80 98 88 a1 48 00
  methods:
    decode-unit   decode-space  map-out       map-in        close
    open
  children:
    ffd70150 <Unnamed>@f,f8fffffc
    ffd60eb0 SUNW,sx@f,80000000
    ffd60e00 eccmemctl@f,0
    ffd5e1f0 virtual-memory@0,0
    ffd5e0e0 memory
    ffd5c360 obio
    ffd5bf50 iommu@f,e0000000
    ffd5bec0 openprom
    ffd50cb0 aliases
    ffd50c60 options
    ffd50c10 packages

/<Unnamed>@f,f8fffffc
    model                    SUNW,S20,501-2324
    name                     SUNW,SPARCstation-20
    breakpoint-trap          0000007f
    compatible               sun4m
    get-unum                 ffd3db10
    stdout-path              10 80 98 88 a1 48 00
    stdin-path               10 80 98 88 a1 48 00
  methods:
    decode-unit   decode-space  map-out       map-in        close
    open
  children:
    ffd70150 <Unnamed>@f,f8fffffc
    ffd60eb0 SUNW,sx@f,80000000
    ffd60e00 eccmemctl@f,0
    ffd5e1f0 virtual-memory@0,0
    ffd5e0e0 memory
    ffd5c360 obio
    ffd5bf50 iommu@f,e0000000
    ffd5bec0 openprom
    ffd50cb0 aliases
    ffd50c60 options
    ffd50c10 packages

/SUNW,sx@f,80000000
    reg                      0000000f  80000000  00000500
                             0000000f  80001000  00000500
    name                     SUNW,sx
  methods:
  children:

/eccmemctl@f,0
    address                  ffeee000
    mc-type                  SMC
    width                    00000020
    reg                      0000000f  00000000  00000020
    name                     eccmemctl
  methods:
  children:

/virtual-memory@0,0
    available                00000000  fff00000  00100000
                             00000000  fef00000  00e00000
                             00000000  00000000  fe400000
                             00000000  ffe3f000  000ad000
                             00000000  fe400000  00b00000
    reg                      00000000  00000000  80000000
                             00000000  80000000  80000000
    name                     virtual-memory
  methods:
  children:

/memory
    available                00000000  07fa8000  00004000
                             00000000  04000000  03fa0000
    name                     memory
  methods:
    selftest
  children:

/obio
    ranges                   00000000  00000000  0000000f  f1000000  01000000
                             00000001  00000000  00000000  90000000  04000000
                             00000002  00000000  00000000  9c000000  04000000
                             00000003  00000000  00000000  f0000000  04000000
                             00000004  00000000  00000000  fc000000  04000000
    device_type              hierarchical
    name                     obio
  methods:
    decode-unit   close         open          map-out       map-in
  children:
    ffd61220 power@0,a01000
    ffd611b0 auxio@0,800000
    ffd61090 SUNW,fdtwo@0,700000
    ffd5c750 interrupt@0,400000
    ffd5c690 counter@0,300000
    ffd5c5e0 eeprom@0,200000
    ffd5c4a0 zs@0,0
    ffd5c3c0 zs@0,100000

/iommu@f,e0000000
    implementation           00000001
    version                  00000003
    address                  ffeed000
    reg                      0000000f  e0000000  00000300
    page-size                00001000
    cache-coherence?
    name                     iommu
  methods:
    decode-unit   decode-space  map-in        close         open
  children:
    ffd5c0e0 sbus@f,e0001000

/openprom
    decode-complete
    aligned-allocator
    relative-addressing
    name                     openprom
  methods:
  children:

/aliases
    ttyb                     /obio/zs@0,100000:b
    ttya                     /obio/zs@0,100000:a
    keyboard!                /obio/zs@0,0:forcemode
    keyboard                 /obio/zs@0,0
    floppy                   /obio/SUNW,fdtwo
    scsi                     /iommu/sbus/espdma@f,400000/esp@f,800000
    net-aui                  /iommu/sbus/ledma@f,400010:aui/le@f,c00000
    net-tpe                  /iommu/sbus/ledma@f,400010:tpe/le@f,c00000
    net                      /iommu/sbus/ledma@f,400010/le@f,c00000
    disk                     /iommu/sbus/espdma@f,400000/esp@f,800000/sd@3,0
    cdrom                    /iommu/sbus/espdma@f,400000/esp@f,800000/sd@6,0:d
    tape                     /iommu/sbus/espdma@f,400000/esp@f,800000/st@4,0
    tape1                    /iommu/sbus/espdma@f,400000/esp@f,800000/st@5,0
    tape0                    /iommu/sbus/espdma@f,400000/esp@f,800000/st@4,0
    disk3                    /iommu/sbus/espdma@f,400000/esp@f,800000/sd@3,0
    disk2                    /iommu/sbus/espdma@f,400000/esp@f,800000/sd@2,0
    disk1                    /iommu/sbus/espdma@f,400000/esp@f,800000/sd@1,0
    disk0                    /iommu/sbus/espdma@f,400000/esp@f,800000/sd@0,0
    name                     aliases
  methods:
  children:

/options
    tpe-link-test?           true
    output-device
    input-device             00 00 a1 48 00 00 29 00 00 11 a8 15 23 d0 81 c5
    keyboard-click?          true
    keymap                   23 d0 81 c5 00 00 a1 48 00 00 29 00 00 11 a8 15
    ttyb-rts-dtr-off         true
    ttyb-ignore-cd           false
    ttya-rts-dtr-off         false
    ttya-ignore-cd           true
    ttyb-mode
    ttya-mode                48 00 00 29 00 00 11 a8 15 23 d0 81 c5 00 00 a1
    fcode-debug?             false
    local-mac-address?       false
    screen-#columns          197
    screen-#rows             129
    selftest-#megs           2819957712
    scsi-initiator-id        17
    sbus-probe-list          00 00 a1 48 00 00 29 00 00 11 a8 15 23 d0 81 c5
    auto-boot?               true
    watchdog-reboot?         true
    diag-file                23 d0 81 c5 00 00 a1 48 00 00 29 00 00 11 a8 15
    diag-device              a8 15 23 d0 81 c5 00 00 a1 48 00 00 29 00 00 11
    boot-file
    boot-device
    silent-mode?             false
    use-nvramrc?             true
    nvramrc                  15 23 d0 81 c5 00 00 a1 48 00 00 29 00 00 11 a8
    sunmon-compat?           false
    security-mode            none
    security-password
    security-#badlogins      687865873
    oem-logo                 00 00 a1 48 00 00 29 00 00 11 a8 15 23 d0 81 c5
    oem-logo?                true
    oem-banner
    oem-banner?              true
    hardware-revision        00 00 a1 48 00 00 29 00 00 11 a8 15 23 d0 81 c5
    last-hardware-update     00 00 11 a8 15 23 d0 81 c5 00 00 a1 48 00 00 29
    testarea                 136
    mfg-switch?              true
    diag-switch?             true
    name                     options
  methods:
  children:

/packages
    name                     packages
  methods:
  children:
    ffd6c100 obp-tftp
    ffd64de0 deblocker
    ffd64980 disk-label

/obio/power@0,a01000
    intr                     00000022  00000000
    interrupts               00000002
    reg                      00000000  00a01000  00000001
    name                     power
  methods:
  children:

/obio/auxio@0,800000
    reg                      00000000  00800000  00000001
    name                     auxio
  methods:
  children:

/obio/SUNW,fdtwo@0,700000
    device_type              block
    intr                     0000002b  00000000
    interrupts               0000000b
    reg                      00000000  00700000  00000008
    name                     SUNW,fdtwo
  methods:
    load          write         read          seek
    write-blocks  read-blocks   block-size    max-transfer  close
    open          reset         selftest      drive-present?
    fdc-init      eject         unmap-floppy  map-out       map-in
  children:

/obio/interrupt@0,400000
    reg                      00000000  00400000  00000010
                             00000000  00401000  00000010
                             00000000  00402000  00000010
                             00000000  00403000  00000010
                             00000000  00410000  00000010
    name                     interrupt
  methods:
    close         open
  children:

/obio/counter@0,300000
    reg                      00000000  00300000  00000010
                             00000000  00301000  00000010
                             00000000  00302000  00000010
                             00000000  00303000  00000010
                             00000000  00310000  00000010
    name                     counter
  methods:
    close         open
  children:

/obio/eeprom@0,200000
    reg                      00000000  00200000  00002000
    model                    mk48t08
    name                     eeprom
  methods:
    close         open
  children:

/obio/zs@0,0
    port-b-ignore-cd
    port-a-ignore-cd
    keyboard
    device_type              serial
    slave                    00000001
    intr                     0000002c  00000000
    interrupts               0000000c
    reg                      00000000  00000000  00000008
    name                     zs
  methods:
    selftest      ring-bell     read          remove-abort
    install-abort close         open          abort?        restore
    clear         reset         initkbdmouse  keyboard-addr mouse
    1200baud      setbaud       initport      port-addr
  children:

/obio/zs@0,100000
    device_type              serial
    slave                    00000000
    intr                     0000002c  00000000
    interrupts               0000000c
    reg                      00000000  00100000  00000008
    name                     zs
  methods:
    remove-abort  install-abort write         read          selftest
    utest         close         open          set-mode      restore
    (set-mode)    set-reg       poll-tty      disable-tty-interrupts
    disable-channel             write-uctl    uwait         uread
    uwrite        ukey          ukey?         uemit         uemit?
    clear-break   ubreak?       inituarts     inituart      udata@
    udata!        uctl@         uctl!         useb          usea
    masks         mode-buf      mask-#data    uart          line#
    column#
  children:

/iommu@f,e0000000/sbus@f,e0001000
    burst-sizes              00f8007f
    ranges                   00000000  00000000  0000000e  00000000  10000000
                             00000001  00000000  0000000e  10000000  10000000
                             00000002  00000000  0000000e  20000000  10000000
                             00000003  00000000  0000000e  30000000  10000000
                             0000000e  00000000  0000000e  e0000000  10000000
                             0000000f  00000000  0000000e  f0000000  10000000
    address                  ffeec000
    reg                      0000000f  e0001000  00000020
    slot-address-bits        0000001c
    up-burst-sizes           0000003f
    device_type              hierarchical
    name                     sbus
  methods:
    probe-self    unique-key    map-out       map-in        close
    open          decode-unit   dma-map-out   dma-map-in    dma-sync
    dma-free      dma-alloc     map-out       map-in
  children:

/packages/obp-tftp
    name                     obp-tftp
  methods:
    load          close         open          seek          write
    read          server        tftpwrite     tftpread
    clear-net-addresses         clear-his-address           do-rarp
    do-arp        his-ip-addr   my-ip-addr
  children:

/packages/deblocker
    disk-write-fix
    name                     deblocker
  methods:
    close         write         read          seek          open
  children:

/packages/disk-label
    name                     disk-label
  methods:
    load          close         open          offset        seek
    write         read          get-dkl-info  set-start-block
    label-valid?  label@        dkl_nsect     dkl_nhead     dkl_acyl
    dkl_ncyl      partition#    dklabel       /bootblk      ublock
  children:
```

</details>
