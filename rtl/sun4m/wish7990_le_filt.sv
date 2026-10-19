// SPDX-License-Identifier: MIT
//
// Vendored from Wish7990 (MIT, rtl/sun4m/LICENSE.wish7990; MelkhiorVintageComputing,
// https://github.com/MelkhiorVintageComputing/Wish7990, commit 8610ef5,
// src/le_filt.sv, as pinned by Sun-3_FPGA). Local changes: the module and
// the modules it instantiates take a wish7990_ prefix. See
// rtl/sun4m/lance.sv for how the SS20 uses it.
//
// Address recognition: does this frame belong to us?
//
// Its own file because the hash is the one piece of this chip that no header
// writes down.  Everything else here can be checked against a datasheet bit
// number; this has to be checked against a transcription of the loop in
// doc/drivers/SunOS414/if_le.c lines 780-806, and against NetBSD's
// lance_setladrf(), because a hash that agrees only with our own testbench
// would filter perfectly in simulation and wrongly on a real network.
//
// Four ways in, in this order (datasheet pp. 25-26):
//
//   1. MODE.PROM accepts everything.
//   2. Broadcast - all forty-eight bits set - is always accepted and does not
//      go through the filter, so a LADRF of all zeroes still receives it.
//   3. Bit 0 of the first octet clear means a physical address, which must
//      equal PADR exactly.
//   4. Otherwise it is a logical address: all six octets go through the
//      Ethernet CRC-32 and the top six bits of the *running remainder* -
//      before any final complement or reflection - index the 64-bit LADRF.
//
// Note what the hash is not.  It is not the FCS: crc32_eth's fcs_o is the
// inverted residue and would give a different bucket entirely.  crc_o is the
// residue itself, which is what the driver's loop leaves in its variable.
//
// A hash lets through more than the driver asked for, and every LANCE driver
// knows it: p. 25, "The logical address filter only assures that there is a
// possibility that the incoming logical address belongs to the node", and the
// driver searches its own list afterwards.

module wish7990_le_filt (
    input  logic        clk,
    input  logic        rst,

    // ---- what the initialisation block said ---------------------------------
    input  logic [47:0] padr_i,      // octet 0 in bits 7:0
    input  logic [63:0] ladrf_i,
    input  logic        prom_i,

    // ---- the first six bytes of a frame -------------------------------------
    input  logic        start_i,      // one cycle, before the first byte
    input  logic        byte_valid_i,
    input  logic [7:0]  byte_i,

    output logic        done_o,       // six octets seen; accept_o is valid
    output logic        accept_o
);

  logic [2:0]  cnt;
  logic [47:0] addr_q;

  // Byte-wide whatever the PHY is: by the time an address reaches here it has
  // already been reassembled into bytes by mii_rx.
  logic        crc_init, crc_en;
  logic [31:0] crc_res, crc_fcs;
  logic        crc_ok_unused;

  wish7990_crc32_eth #(.DATA_W(8)) u_crc (
      .clk      (clk),
      .rst      (rst),
      .init     (crc_init),
      .en       (crc_en),
      .data_i   (byte_i),
      .crc_o    (crc_res),
      .fcs_o    (crc_fcs),
      .crc_ok_o (crc_ok_unused)
  );

  assign crc_init = start_i;
  assign crc_en   = byte_valid_i && !done_o;

  // The six most significant bits of the residue select one of the 64 buckets;
  // the rest of it is not a number this chip has any use for.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [25:0] crc_low = crc_res[25:0];
  /* verilator lint_on UNUSEDSIGNAL */
  // The six most significant bits of the residue select one of the 64 buckets.
  // The driver writes `crc >> 26` and then `ladrf[crc >> 4] |= 1 << (crc & 0xf)`,
  // which is this index into a flat 64-bit word.
  wire [5:0] hash = crc_res[31:26];

  wire is_broadcast = &addr_q;
  wire is_logical   = addr_q[0];       // bit 0 of octet 0, the I/G bit
  wire is_ours      = (addr_q == padr_i);

  always_comb begin
    if (prom_i)           accept_o = 1'b1;
    else if (is_broadcast) accept_o = 1'b1;
    else if (is_logical)   accept_o = ladrf_i[hash];
    else                   accept_o = is_ours;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt    <= 3'd0;
      addr_q <= 48'h0;
      done_o <= 1'b0;
    end else if (start_i) begin
      cnt    <= 3'd0;
      addr_q <= 48'h0;
      done_o <= 1'b0;
    end else if (byte_valid_i && !done_o) begin
      // Octet 0 lands in bits 7:0, so its bit 0 is the I/G bit - the same
      // place PADR(0) sits in the initialisation block.
      addr_q <= {byte_i, addr_q[47:8]};
      if (cnt == 3'd5) done_o <= 1'b1;
      else             cnt    <= cnt + 3'd1;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, crc_fcs, crc_ok_unused, crc_low, 1'b0};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
