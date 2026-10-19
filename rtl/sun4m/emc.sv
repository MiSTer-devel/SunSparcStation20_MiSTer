// SPDX-License-Identifier: GPL-2.0-or-later
//
// emc: the SS20's memory controller registers (the SMC, implementation 2 of
// the EMC) at PA 0xF_0000_0000, and a model of its ECC error reporting.
//
// The core's memory has no check bits. What firmware can observe of the ECC
// is what it injects itself: in diagnostic generate mode (DR.DMODE = 01)
// a doubleword is written with the check bits of DR instead of its own, and
// a later access to it finds the error. This block keeps those doublewords
// (their addresses and syndromes, NENT of them, the oldest replaced) by watching the memory
// controller's accesses, and reports what the SMC would: a read with a
// correctable syndrome sets CE, a partial write (the SMC's read-modify-
// write) sets CE or UE, with the syndrome, the fault address registers and
// the level-15 MEM_ERR interrupt; with checking on, a read returns the
// corrected data (the memory controller applies fix_v_o/fix_bit_o). That is enough for OBP 2.25's POST
// ("EMC/SMC Control Regs Tests", "ECC Multiple UE/CE/CE,UE Tests").
//
// From: Sun-4M System Architecture 950-1373-01 §3.2.2.1 (the space), §5.5
//   (MER, EFSR, EFAR0/1, the diagnostic register, the SEC/S4ED code's
//   syndrome table, from which the 64 data-bit columns below are taken);
//   docs/rom-disassembly/ss20-obp-2.25/post-tests.md §7 (what the POST
//   writes, reads and expects); the register write masks from QEMU
//   hw/misc/eccmemctl.c (SS-20: version 0x2000_0000).
//
// Registers (32-bit; addr is the offset from 0xF_0000_0000):
//   0x00  MER  [31:24] IMPL/VER (2, 0) read-only; [11:0] DCI, A, MRR[7:0],
//              EI, EE as written (mask 0xBFF); 0x3FC at reset (every slot
//              refreshed: the POST checks it)
//   0x04  MDR  memory delay: [30:0] as written; 0x20 at reset
//   0x08  EFSR {ME[16], SYND[15:8], DW[7:4], UE[3], TO[2], CE[0]}; any
//              write clears it and unfreezes the EFARs
//   0x0C  VCR  video configuration: as written (no VSIMM)
//   0x10  EFAR0 {MID, S, rsvd (1s), VA[19:12] (0xFF: not carried), MBL,
//              LOCK, C, SIZ, TYPE, PA[35:32]} of the captured error
//   0x14  EFAR1 PA[31:0] of the captured error
//   0x18  DR   diagnostic: as written (DMODE[11:10], check bits [7:0])
//   0x1C  ECR0, 0x20 ECR1 event counters: as written
//   0x1000-0x1003  the four diagnostic message bytes (byte wide)
// Anything else reads 0 and ignores writes.
//
// Errors are detected only with MER.EE; MEM_ERR (irq_o, level) is UE, or
// CE with MER.EI, raised IRQ_DELAY cycles after the error so that stores
// that follow the faulting one (in the SMC's write buffer on the real
// machine) are seen first: the POST expects two back-to-back injected
// errors to show as one interrupt with ME set. A higher-priority error
// (UE over CE) replaces the captured syndrome and addresses; any later
// error sets ME. A load that hits an uncorrectable syndrome is reported as
// UE but not made a bus error (the POST never does one). Expansion memory
// time-outs (TO) do not exist here.
//
// The memory port: mem_v_i pulses once per main-memory access the memory
// controller accepts, with that request (mem_pkg) and its master's MID.

module emc
  import iobus_pkg::*, mem_pkg::*;
#(
  parameter int NENT      = 8,           // doublewords with injected check bits
                                         // (4, with the report a cycle late,
                                         // failed OBP's ECC Multiple CE test
                                         // on CPU 1 on the board)
  parameter int IRQ_DELAY = 32
)(
  input  logic       clk,
  input  logic       rst,
  input  iob_req_t   bus_i,              // addr = PA[27:0]
  output iob_rsp_t   bus_o,

  input  logic       mem_v_i,
  input  mem_req_t   mem_req_i,
  input  logic [3:0] mem_mid_i,
  // the correction of the last read accepted, per doubleword (a burst's
  // beats in address order; a single read: [0]): flip data bit fix_bit_o[j]
  // of beat j when fix_v_o[j]
  output logic [3:0]      fix_v_o,
  output logic [3:0][5:0] fix_bit_o,
  output logic       irq_o               // MEM_ERR, level 15
);

  localparam logic [31:0] MER_ID = 32'h2000_0000;
  localparam int EW = $clog2(NENT);

  // The check-bit column of each data bit (§5.5.2's table: the syndrome of
  // a single-bit error in data bit n), bit 63 first.
  localparam logic [511:0] COLS = {
    8'h85, 8'h6b, 8'h25, 8'h9e, 8'h45, 8'h9b, 8'h15, 8'h6e, 8'h8a, 8'h67, 8'h2a, 8'h9d, 8'h4a, 8'h97, 8'h1a, 8'h6d,
    8'h83, 8'h4f, 8'h2c, 8'h1f, 8'h8f, 8'h43, 8'h2f, 8'h1c, 8'h46, 8'h98, 8'h19, 8'h62, 8'h8c, 8'h4c, 8'h23, 8'h13,
    8'h58, 8'hb6, 8'h52, 8'he9, 8'h54, 8'hb9, 8'h51, 8'he6, 8'ha8, 8'h76, 8'ha2, 8'hd9, 8'ha4, 8'h79, 8'ha1, 8'hd6,
    8'h38, 8'hf4, 8'hc2, 8'hf1, 8'hf8, 8'h34, 8'hf2, 8'hc1, 8'h64, 8'h89, 8'h91, 8'h26, 8'hc8, 8'hc4, 8'h32, 8'h31};

  function automatic logic [7:0] check_bits(input logic [63:0] d);
    logic [7:0] c;
    c = '0;
    for (int i = 0; i < 64; i++)
      if (d[i]) c ^= COLS[8*i +: 8];
    return c;
  endfunction

  // a syndrome the code corrects: one data bit's column, or one check bit
  function automatic logic correctable(input logic [7:0] s);
    logic r;
    r = s != 8'h00 && (s & (s - 8'h01)) == 8'h00;
    for (int i = 0; i < 64; i++)
      if (s == COLS[8*i +: 8]) r = 1'b1;
    return r;
  endfunction

  // the data bit a correctable syndrome flips (none for a check-bit error)
  function automatic logic [6:0] data_bit(input logic [7:0] s);
    logic [6:0] r;
    r = '0;
    for (int i = 0; i < 64; i++)
      if (s == COLS[8*i +: 8]) r = {1'b1, 6'(i)};
    return r;
  endfunction

  // ------------------------------------------------------------ registers
  logic [11:0] mer;
  logic [30:0] mdr;
  logic [31:0] vcr, dr, ecr0, ecr1;
  logic [31:0] diag;                     // the message bytes, byte 0 in 31:24
  logic        e_me, e_ue, e_ce;
  logic [7:0]  e_synd;
  logic [1:0]  e_dw;
  logic [31:0] efar0, efar1;

  logic regs, msg;
  assign regs = bus_i.addr[27:6] == '0;
  assign msg  = bus_i.addr[27:2] == 26'(32'h1000 >> 2);

  function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] wd, input logic [3:0] be);
    for (int k = 0; k < 4; k++)
      if (be[k]) old[8*k +: 8] = wd[8*k +: 8];
    return old;
  endfunction

  logic [31:0] rd;
  always_comb begin
    rd = '0;
    if (regs)
      case (bus_i.addr[5:2])
        4'h0: rd = MER_ID | {20'd0, mer};
        4'h1: rd = {1'b0, mdr};
        4'h2: rd = {15'd0, e_me, e_synd, 2'b00, e_dw, e_ue, 2'b00, e_ce};
        4'h3: rd = vcr;
        4'h4: rd = efar0;
        4'h5: rd = efar1;
        4'h6: rd = dr;
        4'h7: rd = ecr0;
        4'h8: rd = ecr1;
        default: rd = '0;
      endcase
    else if (msg)
      rd = diag;
  end

  // a write's new value: the addressed register (as read) with the
  // enabled bytes replaced
  logic [31:0] wm;
  assign wm = merge(rd, bus_i.wdata, bus_i.be);

  logic efsr_we;
  assign efsr_we = bus_i.req && !bus_o.ack && bus_i.we && regs && bus_i.addr[5:2] == 4'h2;

  // ------------------------------------------------- the injected words
  logic [NENT-1:0] ent_v;
  logic [35:3]     ent_pa [NENT];
  logic [7:0]      ent_s  [NENT];        // the syndrome a check of it gives
  logic [6:0]      ent_b  [NENT];        // data_bit(ent_s): what a read corrects
  logic [NENT-1:0] ent_ce;               // correctable(ent_s)
  logic [EW-1:0]   victim;               // replaced when every entry is in use

  logic            m_full, m_diag;
  logic [NENT-1:0] m_ent;                // the entries the access touches
  always_comb begin
    m_full = mem_req_i.burst || mem_req_i.be == 8'hFF;
    m_diag = dr[11:10] == 2'b01;
    for (int k = 0; k < NENT; k++)
      m_ent[k] = ent_v[k] && ent_pa[k][35:5] == mem_req_i.pa[35:5]
                 && (mem_req_i.burst || ent_pa[k][4:3] == mem_req_i.pa[4:3]);
  end

  // the error an access finds: the lowest entry it touches, its syndrome
  logic       f_any, f_ce;
  logic [7:0] f_synd;
  logic [1:0] f_dw;
  always_comb begin
    f_any = 1'b0; f_synd = '0; f_dw = '0; f_ce = 1'b0;
    for (int k = NENT - 1; k >= 0; k--)
      if (m_ent[k]) begin
        f_any  = 1'b1;
        f_synd = ent_s[k];
        f_ce   = ent_ce[k];
        f_dw   = mem_req_i.burst ? ent_pa[k][4:3] : 2'd0;
      end
  end

  // the access's EFAR0 size field
  function automatic logic [2:0] siz_of(input logic burst, input logic [7:0] be);
    int n;
    if (burst) return 3'd5;              // the 32-byte line
    n = 0;
    for (int i = 0; i < 8; i++) n += int'(be[i]);
    case (n)
      1:       return 3'd0;
      2:       return 3'd1;
      4:       return 3'd2;
      default: return 3'd3;
    endcase
  endfunction
  /* verilator lint_off UNUSEDSIGNAL */  // (be[0]: the last byte, the default)
  function automatic logic [2:0] first_byte(input logic [7:0] be);
    for (int i = 7; i >= 1; i--)
      if (be[i]) return 3'(7 - i);
    return 3'd7;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // the entry a new injection takes: the one already holding this
  // doubleword, else the first free one, else the oldest
  logic [EW-1:0] slot;
  logic [7:0]    inj_s;                  // the syndrome a new injection gives
  assign inj_s = check_bits(mem_req_i.wdata) ^ dr[7:0];

  // What a syndrome means, {correctable, data_bit}, from a ROM read as the
  // injection is seen and written into the entry a cycle later: the
  // entry's first use is at least two cycles away (the memory controller
  // has a gap cycle after every access). The 64 comparators of the two
  // functions cost ~200 ALUTs.
  (* ramstyle = "M10K, no_rw_check" *) logic [7:0] syn_rom [256];
  initial for (int s = 0; s < 256; s++) syn_rom[s] = {correctable(8'(s)), data_bit(8'(s))};
  logic [7:0]    syn_q;
  logic          inj_q;                  // an injection was written last cycle, into slot_q
  logic [EW-1:0] slot_q;
  always_ff @(posedge clk) syn_q <= syn_rom[inj_s];
  always_comb begin
    slot = victim;
    for (int k = NENT - 1; k >= 0; k--)
      if (!ent_v[k]) slot = EW'(k);
    for (int k = NENT - 1; k >= 0; k--)
      if (m_ent[k]) slot = EW'(k);
  end

  // an error to report this cycle: a read or a partial write that finds an
  // injected word (whose syndrome is never 0), with ECC checking on
  logic rep, rep_ue, cap_any;
  assign rep     = mem_v_i && mer[0] && f_any && !(mem_req_i.write && m_full);
  assign rep_ue  = !f_ce;
  assign cap_any = e_ue || e_ce;

  // what a read corrects in each doubleword it returns (with EE)
  logic [3:0]      fx_v;
  logic [3:0][5:0] fx_bit;
  always_comb begin
    for (int j = 0; j < 4; j++) begin
      logic [6:0] b;
      b = '0;
      // (m_ent: the line, or for a single access the doubleword; a burst's
      // beat j is the entry's own doubleword in the line)
      for (int k = 0; k < NENT; k++)
        if (m_ent[k] && (mem_req_i.burst ? ent_pa[k][4:3] == 2'(j) : j == 0))
          b = ent_b[k];
      fx_v[j]   = b[6] && mer[0];
      fx_bit[j] = b[5:0];
    end
  end

  localparam int CW = $clog2(IRQ_DELAY + 1);
  logic [CW-1:0] irq_cnt;
  logic          irq_cond;
  assign irq_cond = mer[0] && (e_ue || (e_ce && mer[1]));

  always_ff @(posedge clk) begin
    bus_o <= IOB_RSP_IDLE;
    if (rst) begin
      mer <= 12'h3FC; mdr <= 31'h20; vcr <= '0; dr <= '0; ecr0 <= '0; ecr1 <= '0; diag <= '0;
      e_me <= 1'b0; e_ue <= 1'b0; e_ce <= 1'b0; e_synd <= '0; e_dw <= '0;
      efar0 <= 32'h07C0_0000; efar1 <= '0;
      ent_v <= '0; victim <= '0; inj_q <= 1'b0; slot_q <= '0;
      fix_v_o <= '0; fix_bit_o <= '0;
      irq_cnt <= '0; irq_o <= 1'b0;
    end else begin
      // ---- the register bus
      if (bus_i.req && !bus_o.ack) begin
        bus_o.ack   <= 1'b1;
        bus_o.rdata <= rd;
        if (bus_i.we) begin
          if (regs)
            case (bus_i.addr[5:2])
              4'h0: mer  <= wm[11:0] & 12'hBFF;
              4'h1: mdr  <= wm[30:0];
              4'h3: vcr  <= wm;
              4'h6: dr   <= wm;
              4'h7: ecr0 <= wm;
              4'h8: ecr1 <= wm;
              default: ;
            endcase
          else if (msg)
            diag <= wm;
        end
      end

      // ---- memory accesses: a write's check bits are new (a partial
      // write: the SMC's read-modify-write, after it reported what it
      // read); in diagnostic generate mode a whole doubleword gets DR's
      if (mem_v_i) begin
        fix_v_o   <= mem_req_i.write ? 4'd0 : fx_v;
        fix_bit_o <= fx_bit;
      end
      inj_q <= 1'b0;
      if (mem_v_i && mem_req_i.write) begin
        ent_v <= ent_v & ~m_ent;
        if (m_full && m_diag && !mem_req_i.burst && inj_s != 8'h00) begin
          ent_v[slot]  <= 1'b1;
          ent_pa[slot] <= mem_req_i.pa[35:3];
          ent_s[slot]  <= inj_s;
          inj_q <= 1'b1; slot_q <= slot;   // ent_b, ent_ce next cycle, from the ROM
          if (&ent_v) victim <= victim + 1'b1;
        end
      end
      if (inj_q) begin
        ent_b[slot_q]  <= syn_q[6:0];
        ent_ce[slot_q] <= syn_q[7];
      end

      if (efsr_we) begin
        e_me <= 1'b0; e_ue <= 1'b0; e_ce <= 1'b0; e_synd <= '0; e_dw <= '0;
      end else if (rep) begin
        if (rep_ue) e_ue <= 1'b1; else e_ce <= 1'b1;
        if (cap_any) e_me <= 1'b1;
        // the registers hold the highest-priority error (UE over CE)
        if (!cap_any || (rep_ue && !e_ue)) begin
          e_synd <= f_synd;
          e_dw   <= f_dw;
          efar0  <= {mem_mid_i, 1'b1, 5'h1F, 8'hFF, 1'b0, mem_req_i.lock, 1'b0,
                     siz_of(mem_req_i.burst, mem_req_i.be), 3'b000, !mem_req_i.write, mem_req_i.pa[35:32]};
          efar1  <= {mem_req_i.pa[31:3], mem_req_i.burst ? 3'd0 : first_byte(mem_req_i.be)};
        end
      end

      // ---- MEM_ERR, after the write buffer's worth of delay
      if (!irq_cond) begin
        irq_cnt <= '0;
        irq_o   <= 1'b0;
      end else if (irq_cnt != CW'(IRQ_DELAY))
        irq_cnt <= irq_cnt + 1'b1;
      else
        irq_o <= 1'b1;
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, bus_i.pair, bus_i.addr[1:0], mem_req_i.valid, mem_req_i.pa[2:0]};

endmodule
