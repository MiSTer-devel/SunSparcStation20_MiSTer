// SPDX-License-Identifier: MIT
//
// Vendored from Wish7990 (MIT, rtl/sun4m/LICENSE.wish7990; MelkhiorVintageComputing,
// https://github.com/MelkhiorVintageComputing/Wish7990, commit 8610ef5,
// src/wish7990_pkg.sv, as pinned by Sun-3_FPGA), unmodified. Used by
// rtl/sun4m/wish7990_*.sv and rtl/sun4m/lance.sv.
//
// Wish7990 - shared constants for the AMD Am79C90 (C-LANCE) compatible MAC.
//
// Bit positions and structure offsets come from doc/Am79c90.pdf, which is the
// authority; doc/drivers/NetBSD/am7990reg.h is the independent cross-check and
// tb/cpp/tests/test_layout.cpp pins both.  tb/cpp/am7990.h holds the same
// values for the testbench and is kept in step by hand - deliberately, so that
// the testbench is not deriving its expectations from the RTL.
//
// Everything the chip exchanges with the host lives in shared memory as
// little-endian 16-bit words.  The offsets below are byte offsets inside each
// structure.  The Sun headers in doc/drivers describe a byte-swapped view of
// the same words and must not be read for bit positions; doc/drivers/README.md
// has the correspondence table.

// Many of these describe layouts consumed by blocks still to be written, so
// they read as unused for now.
/* verilator lint_off UNUSEDPARAM */
package wish7990_pkg;

  // -------------------------------------------------------------------------
  // Memory port access sizes.
  //
  // How much one access on wb_master's internal port moves.  BUS_SZ_WORD
  // carries the caller's own byte lanes in sel_i, which is how frame data goes
  // in and out four bytes at a time - one transaction per word of buffer
  // touched, whatever the alignment.  doc/interface.md has the table of which
  // size each kind of access uses and why.
  // -------------------------------------------------------------------------
  localparam logic [1:0] BUS_SZ_BYTE = 2'd0;
  localparam logic [1:0] BUS_SZ_HALF = 2'd1;
  localparam logic [1:0] BUS_SZ_WORD = 2'd2;

  // -------------------------------------------------------------------------
  // The Register Address Port, and which CSR it selects (datasheet p. 20).
  // Two significant bits; the rest read as zero.
  // -------------------------------------------------------------------------
  localparam int RAP_W = 2;

  localparam logic [1:0] CSR0 = 2'd0;   // control and status
  localparam logic [1:0] CSR1 = 2'd1;   // IADR[15:0]
  localparam logic [1:0] CSR2 = 2'd2;   // IADR[23:16]
  localparam logic [1:0] CSR3 = 2'd3;   // bus master interface

  // -------------------------------------------------------------------------
  // CSR0 (datasheet pp. 20-22).
  //
  // The chip sets these bits and the host clears them by writing a one: "the
  // C-LANCE updates CSR0 by logical ORing the previous and present value".
  // Access classes, which le_regs implements one group at a time:
  //
  //   read only            ERR, INTR, RXON, TXON
  //   read / clear by 1    BABL, CERR, MISS, MERR, RINT, TINT, IDON
  //   read / write         INEA - and it must be rewritten on every access,
  //                        which is why the drivers OR it into every ack
  //   write 1 only         TDMD, self-clearing
  //   read / set by 1      STOP, STRT, INIT - and STOP wins over the other two
  // -------------------------------------------------------------------------
  localparam int C0_ERR  = 15;
  localparam int C0_BABL = 14;
  localparam int C0_CERR = 13;
  localparam int C0_MISS = 12;
  localparam int C0_MERR = 11;
  localparam int C0_RINT = 10;
  localparam int C0_TINT = 9;
  localparam int C0_IDON = 8;
  localparam int C0_INTR = 7;
  localparam int C0_INEA = 6;
  localparam int C0_RXON = 5;
  localparam int C0_TXON = 4;
  localparam int C0_TDMD = 3;
  localparam int C0_STOP = 2;
  localparam int C0_STRT = 1;
  localparam int C0_INIT = 0;

  // ERR is the OR of these four.
  localparam logic [15:0] C0_ERR_MASK =
      (16'b1 << C0_BABL) | (16'b1 << C0_CERR) |
      (16'b1 << C0_MISS) | (16'b1 << C0_MERR);

  // INTR is the OR of these six.  CERR is deliberately absent: "CERR error
  // will not cause an interrupt to occur (INTR = 0)" (p. 20).
  localparam logic [15:0] C0_INTR_MASK =
      (16'b1 << C0_BABL) | (16'b1 << C0_MISS) | (16'b1 << C0_MERR) |
      (16'b1 << C0_RINT) | (16'b1 << C0_TINT) | (16'b1 << C0_IDON);

  // Everything the host clears by writing a one, and that STOP and RESET clear.
  localparam logic [15:0] C0_STATUS_MASK = C0_ERR_MASK |
      (16'b1 << C0_RINT) | (16'b1 << C0_TINT) | (16'b1 << C0_IDON);

  // -------------------------------------------------------------------------
  // CSR1 and CSR2 hold the initialisation block address.  CSR1 bit 0 must be
  // zero (the block is 16-bit aligned) and CSR2 carries only the low byte.
  // -------------------------------------------------------------------------
  localparam int IADR_W = 24;

  // -------------------------------------------------------------------------
  // CSR3 (datasheet p. 23).  ACON and BCON describe pins a Wishbone port does
  // not have, so they are carried, read back, and brought out inert; BSWP
  // swaps the bytes of frame data only.  See doc/interface.md.
  // -------------------------------------------------------------------------
  localparam int C3_BSWP = 2;
  localparam int C3_ACON = 1;
  localparam int C3_BCON = 0;

  localparam logic [15:0] C3_MASK =
      (16'b1 << C3_BSWP) | (16'b1 << C3_ACON) | (16'b1 << C3_BCON);

  // -------------------------------------------------------------------------
  // Initialisation block: twelve 16-bit words at IADR (datasheet p. 23).
  // -------------------------------------------------------------------------
  localparam int IB_MODE_OFF  = 0;
  localparam int IB_PADR_OFF  = 2;    // three words, PADR[15:0] first
  localparam int IB_LADRF_OFF = 8;    // four words, LADRF[15:0] first
  localparam int IB_RDRA_OFF  = 16;   // RDRA[15:0]
  localparam int IB_RLEN_OFF  = 18;   // {RLEN[2:0], 5'b0, RDRA[23:16]}
  localparam int IB_TDRA_OFF  = 20;   // TDRA[15:0]
  localparam int IB_TLEN_OFF  = 22;   // {TLEN[2:0], 5'b0, TDRA[23:16]}
  localparam int IB_SIZE      = 24;

  // In the ring pointer words, the length is the top three bits and the high
  // address byte is the bottom eight.  The five between are reserved.
  localparam int RING_LEN_LSB = 13;
  localparam int RING_LEN_W   = 3;    // entries = 1 << LEN, so up to 128
  localparam int RING_MAX_LEN = 7;

  // -------------------------------------------------------------------------
  // MODE, the first word of the initialisation block (datasheet pp. 24-25).
  // Normal operation is all zeroes.  Bits 14:8 are reserved; EMBA at 7 exists
  // on the C-LANCE only, which is why this is an Am79C90 and not an Am7990.
  // -------------------------------------------------------------------------
  localparam int MODE_PROM = 15;
  localparam int MODE_EMBA = 7;
  localparam int MODE_INTL = 6;
  localparam int MODE_DRTY = 5;
  localparam int MODE_COLL = 4;
  localparam int MODE_DTCR = 3;
  localparam int MODE_LOOP = 2;
  localparam int MODE_DTX  = 1;
  localparam int MODE_DRX  = 0;

  // -------------------------------------------------------------------------
  // Descriptors: four 16-bit words, on a quadword boundary (pp. 27-30).
  // -------------------------------------------------------------------------
  localparam int MD0_OFF = 0;   // LADR, low 16 address bits
  localparam int MD1_OFF = 2;   // flags in [15:8], HADR in [7:0]
  localparam int MD2_OFF = 4;   // 4'hF then BCNT[11:0], two's complement
  localparam int MD3_OFF = 6;   // RMD: MCNT.  TMD: the error word.
  localparam int MD_SIZE = 8;

  // Receive descriptor word 1.
  localparam int R1_OWN  = 15;
  localparam int R1_ERR  = 14;   // OR of FRAM, OFLO, CRC, BUFF
  localparam int R1_FRAM = 13;   // valid only with ENP set and OFLO clear,
                                 // and only alongside a CRC error
  localparam int R1_OFLO = 12;   // valid only when ENP is clear
  localparam int R1_CRC  = 11;   // valid only with ENP set and OFLO clear
  localparam int R1_BUFF = 10;
  localparam int R1_STP  = 9;
  localparam int R1_ENP  = 8;

  localparam logic [15:0] R1_ERR_MASK =
      (16'b1 << R1_FRAM) | (16'b1 << R1_OFLO) |
      (16'b1 << R1_CRC)  | (16'b1 << R1_BUFF);

  // Transmit descriptor word 1.
  localparam int T1_OWN     = 15;
  localparam int T1_ERR     = 14;   // OR of LCOL, LCAR, UFLO, RTRY
  localparam int T1_ADD_FCS = 13;   // C-LANCE only; valid only with STP
  localparam int T1_MORE    = 12;
  localparam int T1_ONE     = 11;   // not valid when LCOL is set
  localparam int T1_DEF     = 10;
  localparam int T1_STP     = 9;
  localparam int T1_ENP     = 8;

  // Transmit descriptor word 3.  Bit 13 is reserved and written as zero.
  localparam int T3_BUFF = 15;
  localparam int T3_UFLO = 14;
  localparam int T3_LCOL = 12;
  localparam int T3_LCAR = 11;
  localparam int T3_RTRY = 10;

  localparam logic [15:0] T3_ERR_MASK =
      (16'b1 << T3_LCOL) | (16'b1 << T3_LCAR) |
      (16'b1 << T3_UFLO) | (16'b1 << T3_RTRY);

  // The TDR counter is ten bits.  doc/drivers/SunOS414/if_lereg.h says six;
  // it is wrong, and doc/drivers/NetBSD/am7990reg.h agrees with the datasheet.
  localparam logic [15:0] T3_TDR_MASK = 16'h03ff;

  // Buffer byte counts are twelve-bit negative two's complement numbers with
  // the top nibble set: length = (~BCNT[11:0]) + 1.
  localparam logic [15:0] MD2_ONES     = 16'hf000;
  localparam logic [15:0] BCNT_MASK    = 16'h0fff;
  localparam logic [15:0] MCNT_MASK    = 16'h0fff;

  // -------------------------------------------------------------------------
  // wb_le, this project's Wishbone slave: the two ports laid out as
  // struct le_device { u_short le_rdp; u_short le_rap; }, little endian.
  // Byte offsets; the word address is the offset over four.
  // -------------------------------------------------------------------------
  localparam logic [7:0]  REG_RDP = 8'h00;
  localparam logic [7:0]  REG_RAP = 8'h02;
  localparam logic [7:0]  REG_ID  = 8'h04;

  // Not on the real part; nothing in doc/drivers may depend on it.
  localparam logic [31:0] ID_VALUE = 32'h7990_0001;

endpackage
/* verilator lint_on UNUSEDPARAM */
