// SPDX-License-Identifier: GPL-2.0-or-later
//
// mem_pkg: the interconnect between the CPU modules, the memory controller
// and the MSI (docs/arch/bus.md "The interconnect"): a 36-bit physical
// address, 64-bit data, single beats of 1-8 bytes and 32-byte line
// transfers, one request outstanding per port, a snoop broadcast of every
// write for the caches' invalidation.
//
// From: the requirements in docs/VERILOG-PLAN.md §2 and §6 (E3 snooping,
//   A3/B1 bus errors, t_smp_atomic); Sun-4M §7.3 (write-invalidate
//   coherence); the MBus Specification only as the model of what a module
//   needs (address, size, burst, lock, error replies) — the signal-level
//   MBus is not modelled.

package mem_pkg;

  typedef struct packed {
    logic        valid;      // held, with every other field, until the last ack
    logic        write;
    logic        burst;      // a 32-byte line: 4 doubleword beats in address order, pa[4:3] = 0
    logic        lock;       // this read is the first half of an atomic pair: hold the bus until the write
    logic [35:0] pa;         // byte address; a single beat does not cross its doubleword
    logic [7:0]  be;         // byte enables within the doubleword (be[7] = pa[2:0] == 0 = data[63:56]); all ones for a burst
    logic [63:0] wdata;      // the write's doubleword; a sub-doubleword write has its bytes in their lanes
  } mem_req_t;

  typedef struct packed {
    logic        ack;        // one beat done: rdata valid (read) or written (write)
    logic        err;        // this beat failed: bus error / time-out (FT 5, SFSR.TO); a burst stops here
    logic [63:0] rdata;
  } mem_rsp_t;

  // A write seen on the interconnect, for the caches: the line it hits is
  // dropped (write-through caches never own data). The master's own writes
  // are included (the I-cache must see the processor's own stores).
  typedef struct packed {
    logic        valid;
    logic [35:5] line;       // the 32-byte line
    logic [3:0]  mid;        // the writer's module ID
  } snoop_t;

endpackage
