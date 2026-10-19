// SPDX-License-Identifier: GPL-2.0-or-later
//
// ss20_msi: the SPARCstation 20's MBus-to-SBus interface (MSI) as software
// sees it: the IOMMU, the M-to-S asynchronous fault registers, the arbiter
// enable register, the SBus slot configuration registers and the MID
// register (the window at PA 0xF_E000_0000), and the DVMA path that
// translates the on-board SBus masters' virtual addresses to memory.
//
// From: Sun-4M System Architecture, 950-1373-01 Rev 50, §3.2.2.4 (the
//   address map), §5.1.2 (arbiter enable), §5.2 (M-to-S AFSR/AFAR), §5.4.3
//   (MID), §5.8 (IOMMU control/base), §5.9 and §7.2.5 (slot configuration),
//   §7.2 (the IOMMU: IOPTE, range, flushes, diagnostic access); the OBP 2.25
//   POST as docs/rom-disassembly/ss20-obp-2.25/post-tests.md §8 describes it
//   (MSI/MSBI control register walk: slot configuration mask 0x3800f;
//   IOMMU CAM/TLB NTA, comparator and flush tests: 16 entries); QEMU
//   hw/sparc/sun4m_iommu.c and sun4m.c (SS-20: IMPL/VER 0x13); NetBSD
//   iommureg.h/sbusreg.h; OpenBIOS drivers/iommu.c; tests/cpu/src/t_msi.S.
//
// Registers (iob addr = offset in the window; addr[27:14] must be 0, the
// rest reads 0 and ignores writes: DEC-3; every access acks, never err —
// §3.2.2.4: "no error checking on accesses to SBus control space"; writes
// are whole-word, the byte enables are not looked at):
//   0x0000 IOMMU control: [31:24] IMPL/VER (0x13, R), [4:2] RANGE, [1] DE,
//          [0] ME. 16 MB << RANGE of DVMA space at the top of the 4 GB.
//   0x0004 IOMMU base: [31:10] IBA = PA[35:14] of the IOPTE table.
//   0x0014 flush all (W): every TLB entry invalid.
//   0x0018 address flush (W): entries whose tag = FA[30:12] invalid.
//   0x0100+4i tag i (DE = 1): [31] 1, [30:12] TAG, [3:0] LRUQ.
//   0x0140 diagnostic VA (W, DE = 1), 0x0150 comparator output (R, DE = 1):
//          bit i = tag i equals the diagnostic VA's [30:12] (V ignored).
//   0x0200+4i TLB data i (DE = 1): [31:8] PPN, [7] C, [2] W, [1] V.
//          With DE = 0 the diagnostic words read 0 and ignore writes (§5.8.1:
//          "treated as NOOPs"; the POST's flush test reads V = 0 there).
//   0x1000 M-to-S AFSR: ERR LE TO BERR SIZ S MID ME RD SA SSIZ WM PA. Any
//          write clears ERR/LE/TO/BERR/ME and the interrupt and unlocks the
//          pair; the other fields keep the last error.
//   0x1004 M-to-S AFAR (R): PA[31:0] of the error.
//   0x1008 arbiter enable: [0] reads 1, [3:1] MBus masters 9-B, [20:16]
//          SBus slots 0-3 and on-board, [31] SBW (stored, no effect).
//   0x1010+4N slot N configuration (N = 0..3): SEGA[31:30] at [17:16], CP
//          [15], BA32/BA16/BA8/BY [3:0] (the bits the POST's walk finds
//          writable; stored only: no bypass DVMA, see below).
//   0x2000 MID (R): the MBus ID of the master doing this access (bus_mid_i).
//
// The DVMA path. NDVMA master ports (0 = ESP DMA, 1 = LANCE DMA, 2 = the
// slot-3 audio's APC; the first two on-board SBus devices) are granted
// round robin (the port after the last one served that is asking), a whole
// request (single beat or 32-byte burst) at a time, and only while the
// arbiter enable's EN<F> (bit 20, on-board devices) is set: clearing it
// parks them all before their next request (a granted request completes).
// The APC is a slot-3 master, which EN<3> would govern on a real SS20; it
// is parked by EN<F> with the others, as OpenBIOS writes neither. The
// address:
//   - ME = 0: pass-through, PA[31:0] = VA, PA[35:32] = 0 (§5.8.1; QEMU
//     translates regardless, the specification is followed);
//   - ME = 1: VA[31:X+1] must be all ones (X = 23 + RANGE) or the master
//     gets err; then the 16-entry fully associative TLB (§7.2.1: "There are
//     16 TLB entries"; the POST needs all 16), and on a miss a one-beat
//     read of the IOPTE at {IBA[35:X-9], VA[X:12], 00} on the memory port.
//     V = 0, or a write with W = 0, is a translation fault: err to the
//     master and nothing else (§7.2.1 "Translation faults are indicated
//     with an error acknowledge to the DVMA master"; the M-to-S AFSR is for
//     the MBus-to-SBus write buffer, §5.2.2. QEMU also latches its AFSR and
//     raises level 15 here, which a real SS20 does not). A walk that
//     memory answers with err is a fault as well. Only valid IOPTEs are
//     put in the TLB; the victim is a round-robin pointer, which the tags'
//     LRUQ fields report as the queue (address 0 = the next victim).
//   Then the request goes to the memory port with the translated PA, its
//   other fields passed through live (a burst's write data per beat), and
//   the memory's acks go back to the master unchanged.
// The TLB is flushed by the flush registers only, not by writes to control
// or base: the POST fills it diagnostically and rewrites control between
// checks. A flush (or a control/base write) during a walk keeps that walk
// from filling the TLB.
//
// M-to-S write errors are not seen here: the integrator's SBus decoder,
// which times out empty slots (B1) and posts writes, reports a failed
// posted write on mts_err_*; it is latched in the AFSR/AFAR (first error
// only, ME for the next) and raises irq_err_o (level 15, SI_I) until the
// AFSR is written.
//
// Left out: IOMMU bypass (BY: expansion-slot masters only, none here) and
// the DVMA access to a slot's own configuration register (VA[31:30] = 01,
// also bypass-only); the C bit (stored and returned, not used: the memory
// controller snoops every DVMA write); the "reads of the AFSR stall while
// the write buffer is busy" synchronisation (the integrator's decoder
// completes a write before the next access).

module ss20_msi
  import iobus_pkg::*, mem_pkg::*, sbus_pkg::*;
#(
  parameter logic [7:0]  IMPL_VER  = 8'h13,         // SS20 (QEMU sun4m.c, t_msi)
  // Masters 8 and 9 on (§5.1.2), and EN<F> on, unlike §5.1.2's POR state:
  // OpenBIOS never writes this register, and the DVMA ports park on EN<F>.
  parameter logic [31:0] AER_RESET = 32'h0010_0003,
  parameter int          NDVMA     = 3              // DVMA master ports (1 to 8)
)(
  input  logic            clk,
  input  logic            rst,

  input  iob_req_t        bus_i,          // addr = offset in 0xF_E000_0000
  output iob_rsp_t        bus_o,
  input  logic [3:0]      bus_mid_i,      // MID of the master of this access

  input  dvma_req_t [NDVMA-1:0] dvma_req_i,  // 0 = ESP DMA, 1 = LANCE DMA, 2 = APC
  output mem_rsp_t  [NDVMA-1:0] dvma_rsp_o,

  output mem_req_t        mem_req_o,      // to the memory controller's DMA port
  input  mem_rsp_t        mem_rsp_i,

  // A posted MBus-to-SBus write failed (one-cycle pulse).
  input  logic            mts_err_i,
  input  logic            mts_err_to_i,   // 1 = time-out (TO), 0 = error ack (BERR)
  input  logic [35:0]     mts_err_pa_i,
  input  logic [2:0]      mts_err_siz_i,  // MBus size: 0 byte, 1 half, 2 word, 3 double
  input  logic            mts_err_s_i,    // supervisor access
  input  logic [3:0]      mts_err_mid_i,

  output logic            irq_err_o,      // level 15: M-to-S write buffer error (SI_I)
  output logic [31:0]     arb_en_o        // the arbiter enable register
);

  localparam int NTLB = 16;
  localparam int PW   = (NDVMA > 1) ? $clog2(NDVMA) : 1;   // port number width

  // ---------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------
  logic [2:0]  range_q;
  logic        de_q, me_q;
  logic [21:0] iba_q;                     // PA[35:14]
  logic [31:0] afsr_q, afar_q;
  logic [31:0] aer_q;
  logic [6:0]  sbcfg_q [4];               // {SEGA[1:0], CP, BA32, BA16, BA8, BY}
  logic [18:0] diag_va_q;                 // VA[30:12]

  logic [18:0] tag_q [NTLB];              // VA[30:12]
  logic [NTLB-1:0] v_q, w_q;
  // {PPN (PA[35:12]), C} in MLAB, one copy per read port (the hit, the
  // diagnostic read); a fill and a bus write never come in the same cycle
  // (a TLB write stops the fill)
  logic        pd_we;
  logic [3:0]  pd_wa, hit_idx;
  logic [24:0] pd_wd, pd_hit, pd_diag;
  (* ramstyle = "MLAB, no_rw_check" *) logic [24:0] pd_hit_m  [NTLB];
  (* ramstyle = "MLAB, no_rw_check" *) logic [24:0] pd_diag_m [NTLB];
  always_ff @(posedge clk)
    if (pd_we) begin
      pd_hit_m[pd_wa]  <= pd_wd;
      pd_diag_m[pd_wa] <= pd_wd;
    end
  logic [3:0]  rr_q;                      // next victim

  assign irq_err_o = afsr_q[31];
  assign arb_en_o  = aer_q;

  // ---------------------------------------------------------------------
  // Bus decode
  // ---------------------------------------------------------------------
  logic        access, wr, rd_hit_ok;
  logic [11:0] word;

  assign access    = bus_i.req & ~bus_o.ack;
  assign wr        = access & bus_i.we;
  assign word      = bus_i.addr[13:2];
  assign rd_hit_ok = (bus_i.addr[IOB_AW-1:14] == '0);

  logic w_ctrl, w_base, w_flall, w_flpg, w_tag, w_dva, w_data, w_afsr, w_aer, w_sbcfg;
  assign w_ctrl  = wr & rd_hit_ok & (word == 12'h000);
  assign w_base  = wr & rd_hit_ok & (word == 12'h001);
  assign w_flall = wr & rd_hit_ok & (word == 12'h005);
  assign w_flpg  = wr & rd_hit_ok & (word == 12'h006);
  assign w_tag   = wr & rd_hit_ok & de_q & (word[11:4] == 8'h04);
  assign w_dva   = wr & rd_hit_ok & de_q & (word == 12'h050);
  assign w_data  = wr & rd_hit_ok & de_q & (word[11:4] == 8'h08);
  assign w_afsr  = wr & rd_hit_ok & (word == 12'h400);
  assign w_aer   = wr & rd_hit_ok & (word == 12'h402);
  assign w_sbcfg = wr & rd_hit_ok & (word[11:2] == 10'h101);

  // Two sets of tag comparators: the bus's (the address flush and the
  // diagnostic comparator) and the translation's, so that the translation
  // does not wait on (or sit at the end of) the bus's long path through
  // the interconnect.
  logic [18:0] cmp_va;
  logic [NTLB-1:0] match, dv_match;
  logic [PW-1:0] cur_q;
  dvma_req_t   creq;

  assign creq    = dvma_req_i[cur_q];
  assign cmp_va  = (word == 12'h006) ? bus_i.wdata[30:12] : diag_va_q;

  always_comb
    for (int i = 0; i < NTLB; i++) begin
      match[i]    = tag_q[i] == cmp_va;
      dv_match[i] = tag_q[i] == creq.va[30:12];
    end

  // ---------------------------------------------------------------------
  // Read data
  // ---------------------------------------------------------------------
  logic [31:0] rdata;
  logic [3:0]  idx;
  assign idx = word[3:0];

  always_comb begin
    rdata = '0;
    if (rd_hit_ok)
      unique casez (word)
        12'h000: rdata = {IMPL_VER, 19'b0, range_q, de_q, me_q};
        12'h001: rdata = {iba_q, 10'b0};
        12'h04?: if (de_q) rdata = {1'b1, tag_q[idx], 8'b0, rr_q + idx};
        12'h054: if (de_q) rdata = {16'b0, match};
        12'h08?: if (de_q) rdata = {pd_diag, 4'b0, w_q[idx], v_q[idx], 1'b0};
        12'h400: rdata = afsr_q;
        12'h401: rdata = afar_q;
        12'h402: rdata = aer_q;
        12'b0100_0000_01??: rdata = {14'b0, sbcfg_q[word[1:0]][6:5], sbcfg_q[word[1:0]][4],
                                     11'b0, sbcfg_q[word[1:0]][3:0]};
        12'h800: rdata = {28'b0, bus_mid_i};
        default: rdata = '0;
      endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      bus_o <= IOB_RSP_IDLE;
    end else begin
      bus_o.ack   <= access;
      bus_o.err   <= 1'b0;
      bus_o.rdata <= rdata;
    end
  end

  // ---------------------------------------------------------------------
  // The DVMA path
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {S_IDLE, S_XLATE, S_WALK, S_ACC, S_FAULT} state_t;
  state_t      st_q;
  logic [PW-1:0] last_q;                  // the port served last
  logic [35:0] pa_q;                      // translated PA of the request
  logic [33:0] pte_pa_q;                  // IOPTE address [35:2]
  logic [1:0]  beat_q;
  logic        stale_q;                   // the TLB changed during this walk

  // Range check and IOPTE address (§7.2.3), X = 23 + RANGE.
  logic [7:0]  hi_mask;
  logic [18:0] idx_mask;
  logic        in_range;
  logic [33:0] pte_pa;
  assign hi_mask  = 8'hFF << range_q;
  assign idx_mask = ~(19'h7FFFF << (5'd12 + 5'(range_q)));
  assign in_range = &(creq.va[31:24] | ~hi_mask);
  assign pte_pa   = ({iba_q, 12'b0} & ~{15'b0, idx_mask}) | {15'b0, creq.va[30:12] & idx_mask};

  // TLB hit
  logic [NTLB-1:0] hit_vec;
  logic            hit, hit_w;
  logic [23:0]     hit_ppn;
  assign hit_vec = dv_match & v_q;
  assign hit     = |hit_vec;
  // The PPN's RAM address: the hit's index. Two valid entries with the
  // same tag, which only diagnostic writes can make, give the lower one's
  // PPN.
  always_comb begin
    hit_w   = 1'b0;
    hit_idx = '0;
    for (int i = 0; i < NTLB; i++) hit_w = hit_w | (hit_vec[i] & w_q[i]);
    for (int i = NTLB - 1; i >= 0; i--)
      if (hit_vec[i]) hit_idx = 4'(i);
  end
  assign pd_hit  = pd_hit_m[hit_idx];
  assign pd_diag = pd_diag_m[idx];
  assign hit_ppn = pd_hit[24:1];

  // The walked IOPTE
  logic [31:0] pte;
  assign pte = pte_pa_q[0] ? mem_rsp_i.rdata[31:0] : mem_rsp_i.rdata[63:32];

  logic tlb_change;
  assign tlb_change = w_ctrl | w_base | w_flall | w_flpg | w_tag | w_data;

  // Round robin: the first asking port after last_q.
  logic          any_req;
  logic [PW-1:0] next_port;
  // (the modulo is taken on loop constants only: a modulo of last_q itself
  // was synthesised as 32-bit dividers, ~500 ALUTs, 2026-10-17)
  always_comb begin
    any_req   = 1'b0;
    next_port = last_q;
    for (int p = 0; p < NDVMA; p++) any_req |= dvma_req_i[p].valid;
    for (int l = 0; l < NDVMA; l++)
      if (last_q == PW'(l))
        for (int i = NDVMA; i >= 1; i--)
          if (dvma_req_i[(l + i) % NDVMA].valid) next_port = PW'((l + i) % NDVMA);
  end

  logic fill;
  assign fill = (st_q == S_WALK) & mem_rsp_i.ack & ~mem_rsp_i.err & pte[1] & ~stale_q & ~tlb_change;

  always_ff @(posedge clk) begin
    if (rst) begin
      st_q    <= S_IDLE;
      cur_q   <= '0;
      last_q  <= PW'(NDVMA - 1);            // port 0 goes first
      pa_q    <= '0;
      pte_pa_q <= '0;
      beat_q  <= '0;
      stale_q <= 1'b0;
    end else begin
      if (tlb_change) stale_q <= 1'b1;
      unique case (st_q)
        S_IDLE:
          if (aer_q[20] & any_req) begin
            cur_q  <= next_port;
            last_q <= next_port;
            st_q   <= S_XLATE;
          end
        S_XLATE:
          if (!me_q) begin
            pa_q <= {4'h0, creq.va};
            st_q <= S_ACC;
          end else if (!in_range) begin
            st_q <= S_FAULT;
          end else if (hit) begin
            pa_q <= {hit_ppn, creq.va[11:0]};
            st_q <= (creq.write & ~hit_w) ? S_FAULT : S_ACC;
          end else begin
            pte_pa_q <= pte_pa;
            stale_q  <= tlb_change;
            st_q     <= S_WALK;
          end
        S_WALK:
          if (mem_rsp_i.ack) begin
            pa_q <= {pte[31:8], creq.va[11:0]};
            st_q <= (mem_rsp_i.err | ~pte[1] | (creq.write & ~pte[2])) ? S_FAULT : S_ACC;
          end
        S_ACC:
          if (mem_rsp_i.ack) begin
            if (mem_rsp_i.err | ~creq.burst | (beat_q == 2'd3)) begin
              beat_q <= '0;
              st_q   <= S_IDLE;
            end else
              beat_q <= beat_q + 2'd1;
          end
        S_FAULT:
          st_q <= S_IDLE;
        default:
          st_q <= S_IDLE;
      endcase
    end
  end

  always_comb begin
    mem_req_o = '0;
    if (st_q == S_WALK) begin
      mem_req_o.valid = 1'b1;
      mem_req_o.pa    = {pte_pa_q, 2'b00};
      mem_req_o.be    = pte_pa_q[0] ? 8'h0F : 8'hF0;
    end else if (st_q == S_ACC) begin
      mem_req_o.valid = 1'b1;
      mem_req_o.write = creq.write;
      mem_req_o.burst = creq.burst;
      mem_req_o.pa    = pa_q;
      mem_req_o.be    = creq.be;
      mem_req_o.wdata = creq.wdata;
    end
  end

  always_comb
    for (int p = 0; p < NDVMA; p++) begin
      dvma_rsp_o[p].rdata = mem_rsp_i.rdata;
      dvma_rsp_o[p].ack   = (cur_q == PW'(p)) & (((st_q == S_ACC) & mem_rsp_i.ack) | (st_q == S_FAULT));
      dvma_rsp_o[p].err   = (cur_q == PW'(p)) & (((st_q == S_ACC) & mem_rsp_i.err) | (st_q == S_FAULT));
    end

  // ---------------------------------------------------------------------
  // Register and TLB writes
  // ---------------------------------------------------------------------
  // SBus size of the failed access (§5.2.1 SSIZ): byte 001, half 010,
  // word (and a double, done as words) 000.
  logic [2:0] mts_ssiz;
  always_comb
    unique case (mts_err_siz_i)
      3'd0:    mts_ssiz = 3'b001;
      3'd1:    mts_ssiz = 3'b010;
      default: mts_ssiz = 3'b000;
    endcase

  always_ff @(posedge clk) begin
    if (rst) begin
      range_q   <= '0;
      de_q      <= 1'b0;
      me_q      <= 1'b0;
      iba_q     <= '0;
      afsr_q    <= '0;
      afar_q    <= '0;
      aer_q     <= AER_RESET;
      diag_va_q <= '0;
      for (int n = 0; n < 4; n++) sbcfg_q[n] <= '0;
      v_q       <= '0;
      rr_q      <= '0;
    end else begin
      if (w_ctrl) {range_q, de_q, me_q} <= bus_i.wdata[4:0];
      if (w_base) iba_q <= bus_i.wdata[31:10];
      if (w_aer)  aer_q <= (bus_i.wdata & 32'h801F_000F) | 32'h1;
      if (w_sbcfg) sbcfg_q[word[1:0]] <= {bus_i.wdata[17:15], bus_i.wdata[3:0]};
      if (w_dva)  diag_va_q <= bus_i.wdata[30:12];

      // AFSR: a write clears the error; a new error is latched after it
      if (w_afsr) afsr_q[31:28] <= 4'b0;
      if (w_afsr) afsr_q[19]    <= 1'b0;
      if (mts_err_i) begin
        if (afsr_q[31] & ~w_afsr)
          afsr_q[19] <= 1'b1;             // ME
        else begin
          afsr_q <= {1'b1, 1'b0, mts_err_to_i, ~mts_err_to_i, mts_err_siz_i, mts_err_s_i,
                     mts_err_mid_i, 1'b0, 1'b0, 1'b0, mts_err_pa_i[4:0], mts_ssiz, 1'b0,
                     4'b0, mts_err_pa_i[35:32]};
          afar_q <= mts_err_pa_i[31:0];
        end
      end

      // TLB: a fill, or the bus's changes (never both: a TLB write is a
      // tlb_change, which stops the fill), through one write port per
      // vector (one index decoder each, not one per writer)
      if (fill) rr_q <= rr_q + 4'd1;
      if (fill || w_tag) tag_q[w_tag ? idx : rr_q] <= w_tag ? bus_i.wdata[30:12] : creq.va[30:12];
      if (fill || w_data) w_q[w_data ? idx : rr_q] <= w_data ? bus_i.wdata[2] : pte[2];
      if (w_flall)             v_q <= '0;
      else if (w_flpg)         v_q <= v_q & ~match;
      else if (fill || w_data) v_q[w_data ? idx : rr_q] <= w_data ? bus_i.wdata[1] : 1'b1;
    end
  end

  // the PPN/C write (the RAMs above)
  assign pd_we = !rst && (fill || w_data);
  assign pd_wa = w_data ? idx : rr_q;
  assign pd_wd = w_data ? bus_i.wdata[31:7] : pte[31:7];

  logic unused_ok;
  assign unused_ok = &{1'b0, pd_hit[0], bus_i.be, bus_i.pair, bus_i.addr[1:0], creq.valid, pte[6:3], pte[0]};

endmodule
