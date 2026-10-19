// SPDX-License-Identifier: GPL-2.0-or-later
//
// sbus_pkg: the DVMA port of the SBus masters (DMA2's ESP and LANCE
// channels) towards the MSI, which translates the DVMA address through the
// IOMMU and passes the access on to memory as an interconnect request
// (mem_pkg).
//
// It is mem_pkg's request with a 32-bit DVMA (virtual) address in place of
// the physical one and no lock; the answer is mem_pkg::mem_rsp_t. Protocol
// as mem_pkg's (docs/arch/bus.md "The interconnect"):
//  - the master raises `valid` with the request and holds every field
//    until the beat is acked (a burst: until its fourth ack); `ack` is
//    registered, never in the cycle `valid` rises;
//  - a single beat stays within one doubleword (be says which bytes, be[7]
//    = va[2:0] == 0 = data[63:56]: big-endian lanes); a burst is a 32-byte
//    line, four doubleword beats in address order, va[4:0] = 0, be all ones;
//  - `err` with `ack` ends the request: the IOMMU had no valid mapping, or
//    memory answered err; the MSI records it in its M-to-S AFSR/AFAR; a
//    burst stops at that beat;
//  - the cycle after the last ack the master may present its next request.

package sbus_pkg;

  typedef struct packed {
    logic        valid;
    logic        write;
    logic        burst;      // a 32-byte line: 4 doubleword beats, va[4:0] = 0
    logic [31:0] va;         // DVMA byte address
    logic [7:0]  be;
    logic [63:0] wdata;      // bytes in their lanes
  } dvma_req_t;

  localparam dvma_req_t DVMA_REQ_IDLE = '{valid: 1'b0, write: 1'b0, burst: 1'b0,
                                          va: '0, be: '0, wdata: '0};

endpackage
