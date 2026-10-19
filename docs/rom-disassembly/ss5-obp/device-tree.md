# SPARCstation 5 device tree (OBP 2.15, `ss5.bin`)

How the PROM builds the device tree, which Forth words create each node and
property, and the tree it ends up with. Meant as the reference to hold
OpenBIOS (the core's BIOS) against: an OS sees exactly these nodes and
properties on a real SS5.

Sources: the decompiled dictionary [`forth-dictionary.txt`](forth-dictionary.txt)
(addresses below are listing / ROM addresses, `0x7xxxxxxx`; the ROM runs at
`0xffd00000 + (addr - 0x70000000)`), the tree the ROM image itself contains
[`forth-nodes.txt`](forth-nodes.txt), the onboard FCode
([`fcode-70011838-SUNW_CS4231.txt`](fcode-70011838-SUNW_CS4231.txt),
[`fcode-70011f00-espdma.txt`](fcode-70011f00-espdma.txt)), and the running ROM
under QEMU 8.2 (`-M SS-5 -m 64`, `cd <node>` / `.attributes` / `words` / `ls`;
the full dump is the appendix). Values that come from QEMU's model rather
than from the ROM are marked *(QEMU)*.

## 1. How the tree is built

1. **At metacompile time** (static, in the ROM image): `/`, `/virtual-memory`,
   `/memory`, `/obio` with `zs` x2, `eeprom`, `slavioconfig`, `auxio`,
   `counter`, `interrupt`, `power`, `SUNW,fdtwo`, `/iommu`, `/iommu/sbus`,
   `/openprom`, `/aliases`, `/options`, `/packages` with `obp-tftp`,
   `deblocker`, `disk-label`. Their static properties are words in each node's
   property vocabulary (`forth-nodes.txt` lists them with values).
2. **`cold`** (`0x7001b338`) runs `stand-init-io`, the `init` chain,
   `stand-init` and `(cold-hook` -> `startup`. `stand-init` (last definition
   `0x7003bd38`) and the words it chains to add, at run time:
   * the CPU node `/FMI,MB86904` (`0x70030118`, "Probing CPU"): `new-device`
     under the root, properties from the registers (section 3);
   * root `name` = `SUNW,SPARCstation-5` and `banner-name` =
     `SPARCstation 5` (`0x7003a89c`), `model` (`0x7003bc8c`: `SUNW,501-2572`
     when clock-frequency / 100000 = 850, i.e. 85 MHz, else `SUNW,501-2286`),
     `idprom` (`0x7002dd64`: the 32 IDPROM bytes from the NVRAM),
     `clock-frequency` (`0x7003b9c4`, below), `fb` when a console frame buffer
     is found (`0x70038e04`);
   * `clock-frequency` of `/` and of `/iommu/sbus` (`0x7003b9c4`): the CPU
     frequency is *measured*: `ms-factor` (the delay-loop calibration) gives
     f = (ms-factor + 250) / 500 * 10 in units of 100 kHz, so root
     `clock-frequency` = f * 100000 (whole MHz). From f the same word picks
     the DRAM refresh setting (0 below 60 MHz, 3 to 83, 4 to 99, 6 to 124,
     else 7; `0x7003b840`) and writes it into MCR bits 13:10 (`rcbitmask`
     `0x3c00`). The SBus `clock-frequency` is the CPU clock divided by
     (TRCR bits 24:23) + 2 (`0x7003b82c`); `module-info` prints both. QEMU runs
     the delay loop far too fast, hence its 1728 MHz *(QEMU)*;
   * `/memory` `reg` from "Probing Memory Bank #n" (`0x7002d4a0`, 8 banks
     of 32 MB address space, size found by writing 0x11111111..0x55555555 at
     +0, +2, +4, +8, +16 MB and reading back which aliased) and `available`;
     `/virtual-memory` `available` (computed on read);
   * `address` (the VA the PROM mapped the registers at) on every node
     `map-device` (`0x70029c9c`) is applied to: `iommu`, `sbus`, `zs` x2,
     `eeprom`, `auxio`, `counter` (2 VAs), `interrupt` (2 VAs), `power`;
   * `scsi-initiator-id` on `/iommu/sbus` (`0x70038b6c`, from the NVRAM
     option).
3. **SBus probing** (`probe-sbus` `0x70038dbc`, from `startup`): for each slot
   in `sbus-probe-list` (default `541230`), `probe-slot` selects
   `/iommu/sbus` and runs its `probe-self` -> `probe` (`0x70035ce4`): map the
   slot at offset 0 for 64 KiB (`/fcode-prom`), `cprobe` it, and if something
   answers run the FCode found there with `probe-virtual` (`new-device`,
   `byte-load`, `finish-device`). The SBus node's `map-in` (`0x7003a6a8`)
   **substitutes the PROM's own FCode for the on-board slots**:
   * slot 5, offset 0 -> `0xffd11f00` (ROM `0x70011f00`): `espdma`, `esp`,
     `sd`, `st`, `SUNW,bpp`, `ledma`, `le`;
   * slot 4, offset 0 -> `0xffd11838` (ROM `0x70011838`): `SUNW,CS4231`,
     `power-management`;
   * slot 0 is only mapped if `afx-slot-empty?` is false: bit 0 of the byte at
     PA `0x6e000000` (`afx_present-pa`, in slot 4's range);
   * slots 1-3: real SBus cards' FCode PROMs (the SS5's TCX, at slot 3 on a
     real machine, brings its own; under QEMU the TCX FCode is QEMU's).
4. `/aliases` and `/options` are filled by their own words (the NVRAM
   configuration variables are properties of `/options` computed on read).

## 2. The tree

| Node | Made by | Physical registers | Notes |
|---|---|---|---|
| `/` | static (`root-node`, `0x7002329c`) | - | `compatible sun4m`, `breakpoint-trap 0x7f`, `get-unum`; run time: `name`, `model`, `banner-name`, `idprom`, `clock-frequency`, `stdin-path`/`stdout-path`, `fb` |
| `/FMI,MB86904` | run time, `0x70030118` | - | cpu; see section 3 |
| `/virtual-memory@0,0` | static | - | `reg` 0..0x80000000, 0x80000000..0x100000000; `available` computed |
| `/memory@0,0` | static | RAM | `reg` per bank at run time; `available`; method `selftest` |
| `/obio` | static | `ranges` 0 -> PA `0x71000000`, 16 MB | `device_type hierarchical` |
| `/obio/zs@0,0` | static | `0x71000000`, 8 | keyboard/mouse; `slave 1`, `keyboard`, `port-a/b-ignore-cd` (empty), `intr 0x2c,0`, `interrupts 0xc`, `device_type serial` |
| `/obio/zs@0,100000` | static | `0x71100000`, 8 | ttya/ttyb; `slave 0`, same intr |
| `/obio/eeprom@0,200000` | static | `0x71200000`, 0x2000 | `model mk48t08` |
| `/obio/SUNW,fdtwo@0,400000` | static | `0x71400000`, 8 | 82077 floppy; `intr 0x2b,0`, `interrupts 0xb`, `device_type block` |
| `/obio/slavioconfig@0,800000` | static | `0x71800000`, 1 | |
| `/obio/auxio@0,900000` | static | `0x71900000`, 1 | |
| `/obio/power@0,910000` | static | `0x71910000`, 1 | `intr 0x22,0`, `interrupts 2` |
| `/obio/counter@0,d00000` | static | `0x71d00000`, `0x71d10000`, 0x10 each | per-CPU and system timers |
| `/obio/interrupt@0,e00000` | static | `0x71e00000`, `0x71e10000`, 0x10 each | per-CPU and system interrupt registers |
| `/iommu@0,10000000` | static | `0x10000000`, 0x300 | `page-size 0x1000` |
| `/iommu/sbus@0,10001000` | static | `0x10001000`, 0x28 | `ranges`: slot n -> PA `0x20000000 + n * 0x10000000`, 256 MB each, slots 0-5; `slot-address-bits 0x1c`, `burst-sizes 0x3f`, `device_type hierarchical` |
| `.../sbus/espdma@5,8400000` | FCode `0x70011f00` | `0x78400000`, 0x10 | DMA2 SCSI channel |
| `.../espdma/esp@5,8800000` | FCode | `0x78800000`, 0x40 | 53C9x; `intr 0x24,0`, `clock-frequency 40 MHz`, `device_type scsi` |
| `.../esp/sd`, `.../esp/st` | FCode | - | `device_type block` / `byte` |
| `.../sbus/ledma@5,8400010` | FCode | `0x78400010`, 0x20 | DMA2 ethernet channel; `burst-sizes 0x3f` |
| `.../ledma/le@5,8c00000` | FCode | `0x78c00000`, 4 | LANCE; `intr 0x26,0`, `busmaster-regval 7`, `alias le`, `device_type network` |
| `.../sbus/SUNW,bpp@5,c800000` | FCode | `0x7c800000`, 0x1c | parallel port; `intr 0x33,0`, `interrupts 2` |
| `.../sbus/SUNW,CS4231@4,c000000` | FCode `0x70011838` | `0x6c000000`, 0x40 | audio (APC + CS4231); `intr 0x39,0`, `device_type serial`, method `selftest` |
| `.../sbus/power-management@4,a000000` | FCode `0x70011838` | `0x6a000000`, 0x10 | |
| `.../sbus/SUNW,tcx@3,800000` | the card's FCode *(QEMU's)* | slot 3 | not in this ROM |
| `/openprom` | static | - | `decode-complete`, `aligned-allocator`, `relative-addressing` (empty properties) |
| `/aliases` | static | - | see appendix |
| `/options` | static | - | the NVRAM variables |
| `/packages/obp-tftp`, `/packages/deblocker`, `/packages/disk-label` | static | - | support packages; `deblocker` has `disk-write-fix` |

## 3. The CPU node (`0x70030118`)

`name FMI,MB86904` (a fixed string, `0x70030104`), `device_type cpu`, and
properties computed from the hardware:

| Property | Value / source |
|---|---|
| `mask_rev` | `swift_rev` (from the MMU control register) `<< 4 | ...`; QEMU: `0x23` *(QEMU)*. `mask_rev = 0x10` prints "WARNING: Swift Revision 1.0 is not supported." (`0x7003bc8c`) |
| `sparc-version` | 8 |
| `mmu-nctx` | 0x100 |
| `ncaches` | 2 |
| `icache-associativity` / `-nlines` / `-line-size` | 1 / 0x200 / 0x20 |
| `dcache-associativity` / `-nlines` / `-line-size` | 1 / 0x200 / 0x10 |
| `page-size` | 0x1000 |
| `cache-nlines` / `cache-line-size` | 0x200 / 0x20 |
| `version`, `implementation` | MCR (`mcr@`) bits 27:24 and 31:28 |
| `psr-version`, `psr-implementation` | PSR bits 27:24 and 31:28 |
| `context-table` | `ctpr@ << 4`, size to the next MB (`obmem` reg) |

## 4. Forth-level self-tests and diagnostics

| Word | ROM | What it does |
|---|---|---|
| `test` `<device>` | `0x7002be7c` (`0x70024920`) | runs the device's `selftest` method (`test-dev`), prints "selftest failed. Return code = n" |
| `test-all` | `0x7002be50` (`0x700255e8`) | `selftest` of every node below the current one that has a `reg` (`most-tests`, `scan-subtree`) |
| `test-memory` | `0x70030d2c` | `/memory selftest` |
| `/memory` `selftest` | `0x70030cc8` | tests `selftest-#megs` MB (all with `diag-switch?`) via `memory-test-suite` (`0x70035388`: data, address and pattern tests; extra tests in diagnostic mode) |
| `/obio/zs@0,100000` `selftest` | `0x70036d64` | serial port a/b: `utest` sends 0x20..0x7e |
| `/obio/zs@0,0` `selftest` | `0x700389c4` | keyboard reset and ID |
| `/obio/SUNW,fdtwo` `selftest` | `0x7003b2c0` | floppy: needs a formatted disk ("Testing floppy disk system...") |
| `SUNW,CS4231` `selftest` | FCode `+0x671` | `test-cs4231` (codec IAR/IDR register walk) and `test-l1a7192` (APC DMA loopback: "L1A7192 DMA Loopback SelfTest Passed.") |
| `le` `selftest` / `watch-net` | FCode `0x70011f00` | LANCE internal / external loopback; `watch-net`, `watch-aui`, `watch-tpe`, `watch-net-all` (`0x70038c6c`..) watch for packets |
| `esp` `selftest`, `sd`/`st` `selftest` | FCode | SCSI controller / target tests; `probe-scsi`, `probe-scsi-all` (`0x70038ba4`, `0x70038c3c`) list the targets |
| `watch-clock` | `0x7002db24` | shows the TOD seconds register ticking |
| `show-post-results` | `0x700261a4` | prints the POST result the boot code left in the user area |
| `startup` | `0x7003bb5c` | at boot: runs `/memory selftest` (sets `memory-test-ok?`), the `test-` / `test+` drop-ins, then auto-boot |

`diag-switch?` (NVRAM) selects `diagnostic-mode?`, which makes the probes and
tests verbose ("Probing ... at ...") and the memory test longer.

## 5. Things to check in OpenBIOS

* The NVRAM IDPROM (the 32 bytes the root `idprom` is made from) is only
  accepted (`0x7002ddd0`) with byte 0 = 1 (format), byte 1 = `0x80`
  (`real-machine-type`) and byte 15 = the XOR of bytes 0-14; the
  Ethernet address and host ID come from it.
* The static properties above, exactly: `intr` as (level, 0) pairs, the
  empty boolean properties (`keyboard`, `port-a-ignore-cd`,
  `port-b-ignore-cd`, `/openprom`'s three), `slave` on both `zs`,
  `slot-address-bits`, `burst-sizes`, the six `ranges` of `/iommu/sbus`.
* The `address` properties (VAs of the PROM's mappings) on `iommu`, `sbus`,
  `zs`, `eeprom`, `auxio`, `counter`, `interrupt`, `power`: an OS may use them
  instead of mapping the registers itself.
* `/obio/slavioconfig@0,800000` and `/obio/power@0,910000`: easy to forget.
* The CPU node's full property set (section 3), including `context-table`.
* On-board SBus devices are children of `/iommu/sbus` in slots 4 and 5, with
  `espdma`/`ledma` as parents of `esp`/`le` (DMA2 layout), not flat.
* `/aliases` (`disk`, `cdrom = .../sd@6,0:d`, `net`, `net-tpe`, `net-aui`,
  `ttya`, `ttyb`, `keyboard`, `keyboard!`, `floppy`, `audio`, `scsi`,
  `tape`, `tape0/1`, `disk0..3`) and `stdin-path` / `stdout-path`.
* Root `idprom`, `banner-name`, `model` and `clock-frequency` (the latter
  measured; a core that runs the delay loop at a realistic speed gets a
  realistic value, and `model` follows from it).

## Appendix: the running tree under QEMU (SS5)

`cd <path>`, `.attributes`, `words` and `ls` for every node `show-devs` lists, as printed by the ROM (QEMU 8.2, `-m 64`). Values that depend on the machine model: memory, `idprom`, `clock-frequency`, the TCX node, `mask_rev`.

<details><summary>full dump</summary>

```

/
    model                    SUNW,501-2286
    clock-frequency          66ff3000
    name                     SUNW,SPARCstation-5
    banner-name              SPARCstation 5
    idprom                   01 80 52 54 00 12 34 56 00 00 00 00 12 34 56 87
    breakpoint-trap          0000007f
    compatible               sun4m
    get-unum                 ffd0f580
    stdout-path              /obio/zs@0,100000:a
    stdin-path               /obio/zs@0,100000:a
  methods:
    decode-unit   decode-space  map-out       map-in        close
    open
  children:
    ffd3c190 FMI,MB86904
    ffd2d1e0 virtual-memory@0,0
    ffd2d124 memory@0,0
    ffd2c458 obio
    ffd2c184 iommu@0,10000000
    ffd2c114 openprom
    ffd24ef8 aliases
    ffd24ec4 options
    ffd24e90 packages

/FMI,MB86904
    context-table            00 00 00 00 03 ff f0 00 00 00 10 00
    psr-implementation       00000000
    psr-version              00000004
    implementation           00000000
    version                  00000004
    cache-line-size          00000020
    cache-nlines             00000200
    page-size                00001000
    dcache-line-size         00000010
    dcache-nlines            00000200
    dcache-associativity     00000001
    icache-line-size         00000020
    icache-nlines            00000200
    icache-associativity     00000001
    ncaches                  00000002
    mmu-nctx                 00000100
    sparc-version            00000008
    mask_rev                 00000023
    device_type              cpu
    name                     FMI,MB86904
  methods:
  children:

/virtual-memory@0,0
    available                00000000  fff00000  00100000
                             00000000  fef00000  00e00000
                             00000000  00000000  fe400000
                             00000000  ffd56000  000cc000
                             00000000  ffd00000  0000b000
                             00000000  fe400000  00b00000
    reg                      00000000  00000000  80000000
                             00000000  80000000  80000000
    name                     virtual-memory
  methods:
  children:

/memory@0,0
    reg                      00000000  00000000  02000000
                             00000000  02000000  02000000
    available                00000000  00000000  03fb4000
    name                     memory
  methods:
    selftest
  children:

/obio
    device_type              hierarchical
    ranges                   00000000  00000000  00000000  71000000  01000000
    name                     obio
  methods:
    decode-unit   decode-space  close         open          map-out
    map-in
  children:
    ffd3a7bc SUNW,fdtwo@0,400000
    ffd3a738 power@0,910000
    ffd2c8f8 interrupt@0,e00000
    ffd2c89c counter@0,d00000
    ffd2c84c auxio@0,900000
    ffd2c7f8 slavioconfig@0,800000
    ffd2c790 eeprom@0,200000
    ffd2c690 zs@0,0
    ffd2c5dc zs@0,100000

/iommu@0,10000000
    address                  ffee8000
    reg                      00000000  10000000  00000300
    page-size                00001000
    name                     iommu
  methods:
    decode-unit   decode-space  map-in        close         open
  children:
    ffd2c2c8 sbus@0,10001000

/openprom
    decode-complete
    aligned-allocator
    relative-addressing
    name                     openprom
  methods:
  children:

/aliases
    screen                   /iommu@0,10000000/sbus@0,10001000/SUNW,tcx@3,800000
    ttyb                     /obio/zs@0,100000:b
    ttya                     /obio/zs@0,100000:a
    keyboard!                /obio/zs@0,0:forcemode
    keyboard                 /obio/zs@0,0
    audio                    /iommu/sbus/SUNW,CS4231
    floppy                   /obio/SUNW,fdtwo
    scsi                     /iommu/sbus/espdma@5,8400000/esp@5,8800000
    net-aui                  /iommu/sbus/ledma@5,8400010:aui/le@5,8c00000
    net-tpe                  /iommu/sbus/ledma@5,8400010:tpe/le@5,8c00000
    net                      /iommu/sbus/ledma@5,8400010/le@5,8c00000
    disk                     /iommu/sbus/espdma@5,8400000/esp@5,8800000/sd@3,0
    cdrom                    /iommu/sbus/espdma@5,8400000/esp@5,8800000/sd@6,0:d
    tape                     /iommu/sbus/espdma@5,8400000/esp@5,8800000/st@4,0
    tape0                    /iommu/sbus/espdma@5,8400000/esp@5,8800000/st@4,0
    tape1                    /iommu/sbus/espdma@5,8400000/esp@5,8800000/st@5,0
    disk3                    /iommu/sbus/espdma@5,8400000/esp@5,8800000/sd@3,0
    disk2                    /iommu/sbus/espdma@5,8400000/esp@5,8800000/sd@2,0
    disk1                    /iommu/sbus/espdma@5,8400000/esp@5,8800000/sd@1,0
    disk0                    /iommu/sbus/espdma@5,8400000/esp@5,8800000/sd@0,0
    name                     aliases
  methods:
  children:

/options
    tpe-link-test?           true
    output-device            screen
    input-device             keyboard
    keyboard-click?          false
    keymap
    ttyb-rts-dtr-off         false
    ttyb-ignore-cd           true
    ttya-rts-dtr-off         false
    ttya-ignore-cd           true
    ttyb-mode                9600,8,n,1,-
    ttya-mode                9600,8,n,1,-
    fcode-debug?             false
    local-mac-address?       false
    screen-#columns          80
    screen-#rows             34
    selftest-#megs           1
    scsi-initiator-id        7
    silent-mode?             false
    auto-boot?               true
    watchdog-reboot?         false
    diag-file
    diag-device              net
    boot-file
    boot-device              disk net
    sbus-probe-list          541230
    use-nvramrc?             false
    nvramrc
    sunmon-compat?           false
    security-mode            none
    security-password
    security-#badlogins      0
    oem-logo
    oem-logo?                false
    oem-banner
    oem-banner?              false
    hardware-revision
    last-hardware-update     20 01 fb 66 72 65 65 00 00 00 00 00 00 00 00 00
    testarea                 0
    mfg-switch?              false
    diag-switch?             true
    name                     options
  methods:
  children:

/packages
    name                     packages
  methods:
  children:
    ffd393a0 obp-tftp
    ffd332b8 deblocker
    ffd32f14 disk-label

/obio/SUNW,fdtwo@0,400000
    device_type              block
    intr                     0000002b  00000000
    interrupts               0000000b
    reg                      00000000  00400000  00000008
    name                     SUNW,fdtwo
  methods:
    load          write         read          seek
    write-blocks  read-blocks   block-size    max-transfer  close
    open          reset         selftest      drive-present?
    fdc-init      eject         unmap-floppy  map-out       map-in
  children:

/obio/power@0,910000
    address                  ffee5000
    intr                     00000022  00000000
    interrupts               00000002
    reg                      00000000  00910000  00000001
    name                     power
  methods:
  children:

/obio/interrupt@0,e00000
    address                  ffeed000  ffeec000
    reg                      00000000  00e00000  00000010
                             00000000  00e10000  00000010
    name                     interrupt
  methods:
  children:

/obio/counter@0,d00000
    address                  ffeef000  ffeee000
    reg                      00000000  00d00000  00000010
                             00000000  00d10000  00000010
    name                     counter
  methods:
  children:

/obio/auxio@0,900000
    address                  ffee6000
    reg                      00000000  00900000  00000001
    name                     auxio
  methods:
  children:

/obio/slavioconfig@0,800000
    reg                      00000000  00800000  00000001
    name                     slavioconfig
  methods:
  children:

/obio/eeprom@0,200000
    address                  ffee9000
    reg                      00000000  00200000  00002000
    model                    mk48t08
    name                     eeprom
  methods:
  children:

/obio/zs@0,0
    address                  ffee4000
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
    port-b-ignore-cd
    port-a-ignore-cd
    address                  ffeeb000
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

/iommu@0,10000000/sbus@0,10001000
    clock-frequency          337f9800
    scsi-initiator-id        00000007
    address                  ffee7000
    ranges                   00000000  00000000  00000000  20000000  10000000
                             00000001  00000000  00000000  30000000  10000000
                             00000002  00000000  00000000  40000000  10000000
                             00000003  00000000  00000000  50000000  10000000
                             00000004  00000000  00000000  60000000  10000000
                             00000005  00000000  00000000  70000000  10000000
    reg                      00000000  10001000  00000028
    slot-address-bits        0000001c
    burst-sizes              0000003f
    device_type              hierarchical
    name                     sbus
  methods:
    map-out       map-in        probe-self    unique-key    close
    open          decode-unit   dma-map-out   dma-map-in    dma-sync
    dma-free      dma-alloc
  children:
    ffd423c4 SUNW,tcx@3,800000
    ffd42364 power-management@4,a000000
    ffd41c18 SUNW,CS4231@4,c000000
    ffd3ffbc ledma@5,8400010
    ffd3ff30 SUNW,bpp@5,c800000
    ffd3ce3c espdma@5,8400000

/iommu@0,10000000/sbus@0,10001000/SUNW,tcx@3,800000
    _address                 ffe22000
    character-set            ISO8859-1
    interrupts               00000005
    intr                     00000039  00000000
    linebytes                00000400
    width                    00000400
    height                   00000300
    vfreq                    0000003c
    pixfreq                  03dfd240
    hfporch                  00000018
    vfporch                  00000003
    hsync                    00000088
    vsync                    00000006
    hbporch                  000000a0
    vbporch                  0000001d
    tcx-8-bit                true
    reg                      00000003  00800000  00100000
                             00000003  02000000  00000001
                             00000003  04000000  00800000
                             00000003  06000000  00800000
                             00000003  0a000000  00000001
                             00000003  0c000000  00000001
                             00000003  0e000000  00000001
                             00000003  00701000  00001000
                             00000003  00200000  00000004
                             00000003  00300000  0000081c
                             00000003  00000000  00010000
                             00000003  00240000  00000004
                             00000003  00280000  00000001
    device_type              display
    name                     SUNW,tcx
  methods:
    restore       draw-logo     write         open          install
    color!
  children:

/iommu@0,10000000/sbus@0,10001000/power-management@4,a000000
    reg                      00000004  0a000000  00000010
    name                     power-management
  methods:
  children:

/iommu@0,10000000/sbus@0,10001000/SUNW,CS4231@4,c000000
    intr                     00000039  00000000
    reg                      00000004  0c000000  00000040
    device_type              serial
    name                     SUNW,CS4231
  methods:
    selftest
  children:

/iommu@0,10000000/sbus@0,10001000/ledma@5,8400010
    burst-sizes              0000003f
    reg                      00000005  08400010  00000020
    name                     ledma
  methods:
    open          close         open          dma-sync      dma-free
    dma-alloc     dma-map-out   dma-map-in    decode-unit   map-out
    map-in
  children:
    ffd402cc le@5,8c00000

/iommu@0,10000000/sbus@0,10001000/SUNW,bpp@5,c800000
    reg                      00000005  0c800000  0000001c
    intr                     00000033  00000000
    interrupts               00000002
    name                     SUNW,bpp
  methods:
  children:

/iommu@0,10000000/sbus@0,10001000/espdma@5,8400000
    reg                      00000005  08400000  00000010
    name                     espdma
  methods:
    close         open          dma-chip      decode-unit   map-out
    map-in        dma-map-out   dma-map-in    dma-free
    dma-alloc
  children:
    ffd3d218 esp@5,8800000

/iommu@0,10000000/sbus@0,10001000/ledma@5,8400010/le@5,8c00000
    device_type              network
    busmaster-regval         00000007
    intr                     00000026  00000000
    alias                    le
    reg                      00000005  08c00000  00000004
    name                     le
  methods:
    selftest      watch-net     write         close         open
    reset         seek          open          close         load
    watch-net     selftest      write         read
  children:

/iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000
    device_type              scsi
    clock-frequency          02625a00
    intr                     00000024  00000000
    reg                      00000005  08800000  00000040
    name                     esp
  methods:
    show-children close         reset         open
    tape-r/w-some fixed-or-variable           tape-block-size
    tape-skip-files             tape-scsiop   disk-block-size
    disk-r/w-blocks             timed-spin    read-capacity
    mode-sense    device-present?             block-limits
    send-diagnostic             set-timeout   short-data-go mbuf0
    scsi-execute  selftest      map-out       map-in
    dma-map-out   dma-map-in    dma-free      dma-alloc
    decode-unit
  children:
    ffd3f7ec st
    ffd3f0d4 sd

/iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000/st
    device_type              byte
    name                     st
  methods:
    selftest      eject         reset         load          write
    seek          read          open          write-blocks
    read-blocks   dma-free      dma-alloc     max-transfer
    block-size    close         st-selftest
  children:

/iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000/sd
    device_type              block
    name                     sd
  methods:
    selftest      eject         reset         load          write
    read          seek          sd-selftest   close         open
    write-blocks  read-blocks   dma-free      dma-alloc
    max-transfer  block-size    spin-up
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
