# Buses

Two buses inside the machine (VERILOG-PLAN.md §2): the **interconnect**
between the CPU modules, memory and the MSI, and the **I/O bus** behind the
MSI and the system-space decoder, which every chipset register block sits
on. This page defines both: the I/O bus (`rtl/pkg/iobus_pkg.sv`) and the
interconnect (`rtl/pkg/mem_pkg.sv`).

## The I/O bus (`iobus_pkg`)

The slave side of the SBus and of the sun4m system control space
(PA `0xF_F1xx_xxxx`), as a device sees it: 32 bits wide with byte enables,
one access at a time.

```systemverilog
typedef struct packed {
  logic        req;      // request valid, held until ack/err
  logic        we;
  logic [27:0] addr;     // byte address within the slave's window
  logic [3:0]  be;       // byte enables, be[3] = data[31:24] = byte offset 0
  logic [31:0] wdata;
  logic        pair;     // both beats of a 64-bit access (high word first)
} iob_req_t;

typedef struct packed {
  logic        ack;
  logic        err;      // bus error: time-out or an access the device rejects
  logic [31:0] rdata;    // valid in the ack cycle
} iob_rsp_t;
```

Protocol:

- the master raises `req` with `we`, `addr`, `be`, `wdata` and holds them
  until the slave answers with `ack` or `err` for exactly one cycle;
- `ack`/`err` are registered: never in the cycle `req` rises;
- a read's `rdata` is valid in the `ack` cycle; a write takes effect at
  the edge that sets `ack`;
- in the cycle after `ack` the master may present a new request;
- `err` becomes a data access exception (SFSR FT 5 with TO/BE) in the
  CPU, as on an SBus time-out;
- `pair` marks both beats of a 64-bit access (an SBus double-word is two
  consecutive 32-bit beats, high word first, at `addr` and `addr+4`).
  Slaves with 64-bit registers (the user timers) snapshot the low word on
  the first beat and return it on the second, so the pair is consistent;
- byte lanes are big-endian: byte offset 0 of a word is `data[31:24]` and
  `be[3]`; offset 3 is `data[7:0]` and `be[0]`. A byte device takes the
  lane its address selects and may return its byte in every lane.
- `addr` is the byte address within the slave's window; the decoder in
  front of a slave passes the low bits it needs (28 bits cover one SBus
  slot, 256 MB, and the whole system control space).

A slave that is given an address it does not implement acks with 0
(requirement DEC-3: registers no device answers read 0); only the
*decoder* raises `err`, for empty SBus slots and unassigned control
space (requirement B1/A3).

Slaves so far: `slavio_timer` (addr[19:0] of `0xF_F130_0000`),
`slavio_intctl` (`0xF_F140_0000`), `slavio_misc` (addr[23:0] of
`0xF_F1xx_xxxx`, pages 6, 8, A, F), `m48t08` (addr[12:0] of
`0xF_F120_0000`), `escc` (addr[2:1] of `0xF_F100_0000` and
`0xF_F110_0000`).

## The interconnect (`mem_pkg`)

The port of a CPU module (and of a DMA master) towards memory, the PROM
and the system space: 36-bit physical addresses, 64 bits of data, single
beats of 1-8 bytes and 32-byte line transfers, one request outstanding
per port, in order. It is what the modules need from the MBus and the
MSI, not the MBus signal by signal.

```systemverilog
typedef struct packed {
  logic        valid;      // held, with every other field, until the last ack
  logic        write;
  logic        burst;      // a 32-byte line: 4 doubleword beats in address order, pa[4:3] = 0
  logic        lock;       // this read is the first half of an atomic pair: hold the bus until the write
  logic [35:0] pa;         // byte address; a single beat does not cross its doubleword
  logic [7:0]  be;         // byte enables within the doubleword (be[7] = pa[2:0] == 0 = data[63:56])
  logic [63:0] wdata;      // the write's doubleword, bytes in their lanes
} mem_req_t;

typedef struct packed {
  logic        ack;        // one beat done
  logic        err;        // this beat failed (bus error / time-out): FT 5, SFSR.TO
  logic [63:0] rdata;
} mem_rsp_t;

typedef struct packed {    // every write on the interconnect, broadcast to the caches
  logic        valid;
  logic [35:5] line;
  logic [3:0]  mid;
} snoop_t;
```

Protocol:

- the master raises `valid` with the request and holds everything until
  the beat is acked (a burst: until its fourth `ack`); `ack` is never in
  the cycle `valid` rises;
- a read beat's `rdata` is valid in its `ack` cycle; a write beat is done
  at the edge that sets `ack`; a burst read returns the four doublewords
  of the line in address order (the cache fills the line it asked for in
  that order and keeps the CPU side blocked until the fourth beat, so a
  store into the line during the fill cannot be lost: `t_cache_fill_words`);
- `err` with `ack` ends the request: a single beat fails, a burst stops at
  that beat and the cache does not validate the line; the module turns it
  into FT 5 with TO (the MSI's time-out for an empty slot, B1) or, for a
  table-walk read, FT 4 with L (A3). A failed write is reported by the
  chipset (AFSR/AFAR and a level-15 interrupt), never by this port;
- `lock` on a read keeps the interconnect for this master until its next
  write completes: `ldstub`/`swap` to uncached memory, and the SRMMU's
  R-bit update (V8 §H.7 asks for atomicity against other table accesses);
- every write (CPU or DMA, the master's own included) is reported on the
  `snoop` broadcast in the cycle of its ack, as the line it touches; a
  cache drops a valid line with that address (write-through caches never
  hold the only copy, so dropping is always safe; E3, `t_smp_coherent`,
  `t_selfmod`); a module whose snoop queue is nearly full raises
  `snoop_hold_o`, and the interconnect delivers it no snoop while that is
  high (it queues them, holding write acceptance if its own queue fills) —
  a snoop may never be dropped: a DMA transfer writes a line every few
  cycles for thousands of lines, and one lost snoop is a stale line;
- the module ID `mid` (8 + n on the SS20) comes from the module's `mid_i`
  and goes with every request; the arbiter and the MSI's MID register use
  it; the arbiter-enable register (`t_msi`) parks a module by not granting
  it;
- the boot-PROM window at `0xF_F000_0000` (mirrored through 16 MB) is a
  slave like any other; the module forms the boot-mode address itself
  (MCNTL.BM: fetches to `0xF_F000_0000 + VA[27:0]`);
- the system-space decoder answers unassigned addresses with `err` after
  a time-out count (B1); registers no device implements read 0 (DEC-3) —
  this is the I/O bus's rule above.

Masters so far: the CPU modules (phase 3); the DMA masters (IOMMU,
ESP/LANCE) come with their phases. The slave side is the memory
controller (SDRAM / DDR3 through the MiSTer framework, phase 4), the
PROM, and the bridge to the I/O bus.
