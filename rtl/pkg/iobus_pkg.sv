// SPDX-License-Identifier: GPL-2.0-or-later
//
// iobus: the register bus of the chipset's slaves.
//
// This is the slave side of the SBus and of the sun4m system control space
// (PA 0xF_F1xx_xxxx), as a device sees it: 32 bits wide with byte enables,
// one access at a time. The MSI bridge and the system-space decoder turn
// MBus transactions into these.
//
// Protocol:
//  - the master raises `req` with `we`, `addr`, `be`, `wdata` and holds them
//    until the slave answers with `ack` (or `err`) for exactly one cycle;
//  - `ack`/`err` are registered: never in the same cycle as `req` rises;
//  - a read's `rdata` is valid in the `ack` cycle; a write takes effect at
//    the edge that sets `ack`;
//  - in the cycle after `ack` the master may present a new request;
//  - `err` instead of `ack` is a bus error (timeout or an access the device
//    rejects): the bridge turns it into a data access exception;
//  - `pair` marks both beats of a 64-bit access (an SBus double-word is two
//    consecutive 32-bit beats, high word first, at addr and addr+4). Slaves
//    with 64-bit registers (the user timers) snapshot the low word on the
//    first beat and return it on the second, so the two are consistent.
//
// Byte lanes are big-endian: byte offset 0 of a word is data[31:24] and
// be[3]; offset 3 is data[7:0] and be[0].
//
// `addr` is the byte address within the slave's window. The decoder in
// front of a slave passes the low bits it needs: 28 bits covers one SBus
// slot (256 MB) and the whole system control space.

package iobus_pkg;

  localparam int IOB_AW = 28;

  typedef struct packed {
    logic              req;
    logic              we;
    logic [IOB_AW-1:0] addr;
    logic [3:0]        be;
    logic [31:0]       wdata;
    logic              pair;
  } iob_req_t;

  typedef struct packed {
    logic        ack;
    logic        err;
    logic [31:0] rdata;
  } iob_rsp_t;

  localparam iob_req_t IOB_REQ_IDLE = '{req: 1'b0, we: 1'b0, addr: '0,
                                        be: '0, wdata: '0, pair: 1'b0};
  localparam iob_rsp_t IOB_RSP_IDLE = '{ack: 1'b0, err: 1'b0, rdata: '0};

endpackage
