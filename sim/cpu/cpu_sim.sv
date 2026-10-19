// SPDX-License-Identifier: GPL-2.0-or-later
//
// cpu_sim: the phase-3 harness (docs/arch/mmu.md §5): one cpu_module (IU,
// FPU, SRMMU, caches) on a behavioural interconnect (mem_pkg) with the
// PROM image, 16 MB of RAM, the escc on ttya, bus errors for the empty SBus
// slots, and the snoop broadcast of every write. Verilator, --binary
// --timing; prints the ROM's serial output and stops at "CPUTEST DONE", at
// a watchdog reset (unless +wd), or at the cycle budget.
//
// Address map (docs/arch/memory-map.md): RAM at PA 0 (16 MB); the PROM at
// 0xF_F000_0000 (1 MB, mirrored through the 16 MB window); the ESCC at
// 0xF_F110_0000; the timers (slavio_timer) at 0xF_F130_0000; the system
// control registers (slavio_misc) at
// 0xF_F1{6,8,A,F}0_0000; 0xE_0xxx_xxxx-0xE_3xxx_xxxx are empty SBus slots (bus
// error) but for the harness's DMA engine in the page at 0xE_0000_1000
// (below; the board's slot 0 times out there, so t_dma_snoop skips).
// Anything else reads 0 and takes writes.
//
// Plusargs: +lat=N (memory latency, default 1), +gaps (a bubble between
// burst beats), +trace (every commit), +dmem (every data access), +mem
// (every memory-port beat), +from=N +to=N (pipeline state per cycle),
// +cycles=N (the budget).

module cpu_sim
  import cpu_pkg::*;
  import iobus_pkg::*;
  import mem_pkg::*;
#(
  parameter string ROM = "tests/cpu/out/ss20/cputest.rom",
  parameter int     RESNOOP = 128,        // the delayed second DMA snoop (bus cycles; -GRESNOOP=0 turns it off)
  parameter longint CYCLES = 400_000_000
);
  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  // ---- the module ----
  mem_req_t mr;                      // the interconnect model's side
  mem_rsp_t ms;
  snoop_t   sn;
  snoop_t   csn;                     // the snoops the module sees (through u_dsnq)
  logic     wd_reset, si_reset, halt;
  logic     cpu_clk;
  assign cpu_clk = clk;

  // The module's snoop hold, honoured by the snoop queue (u_dsnq).
  logic     c_hold, c_hold_q;
  always_ff @(posedge cpu_clk) c_hold_q <= c_hold;

  logic boot_mode;                    // (the harness's memory model has no PROM pace)
  cpu_module #(.HAS_FPU(1'b1)) u_cpu (
    .clk(cpu_clk), .rst, .mid_i(4'd8), .irl_i(h_irl), .cache_en_i(1'b1), .ram_mb_i(12'd16),
    .mem_req_o(mr), .mem_rsp_i(ms), .snoop_i(csn), .snoop_hold_o(c_hold),
    .wd_reset_o(wd_reset), .si_reset_o(si_reset), .halt_o(halt), .boot_mode_o(boot_mode),
    .dbg_commit_o(dbg_commit), .dbg_trap_o(dbg_trap), .dbg_tt_o(dbg_tt), .dbg_pc_o(dbg_pc),
    .dbg_psr_o(dbg_psr), .dbg_w_o(dbg_w));

  // the board's hang reporter, as ss20_machine has it (+hangdump prints its
  // line, decoded from its serial output; it fires after 2^20 cycles
  // without a commit or 2^26 without a trap)
  logic        dbg_commit, dbg_trap, dbg_txd, dbg_act;
  logic [7:0]  dbg_tt;
  logic [31:0] dbg_pc, dbg_psr;
  logic [5:0][31:0] dbg_w;
  hang_dump #(.DIV(8), .CBITS(20), .TBITS(26)) u_hang (
    .clk(cpu_clk), .rst, .commit_i(dbg_commit), .trap_i(dbg_trap), .tt_i(dbg_tt), .pc_i(dbg_pc),
    .psr_i(dbg_psr), .w_i(dbg_w), .x_i(32'd0), .txd_o(dbg_txd), .act_o(dbg_act));
  int hd_st = 0, hd_cnt = 0;
  logic [7:0] hd_b;
  always @(posedge cpu_clk) begin
    if (hd_st == 0) begin
      if (dbg_act && !dbg_txd) begin hd_st = 1; hd_cnt = 0; end
    end else begin
      hd_cnt++;
      if (hd_cnt == 4 + 8 * hd_st) begin
        if (hd_st <= 8) hd_b[hd_st - 1] = dbg_txd;
        if (hd_st == 9) begin $write("%c", hd_b); $fflush(); hd_st = 0; end else hd_st++;
      end
    end
  end

  // ---- the harness's DMA engine (t_dma_snoop): registers at 0xE_0000_1000 ----
  // +0 ID "DMA1", +4 destination PA, +8 lines, +C seed (a write starts the
  // transfer), +10 busy, +14 cycles a line (>= 1). Each step writes one
  // 32-byte line of RAM, word k = (pa + 4k) ^ seed, and broadcasts its snoop
  // (module ID 0) in the same cycle, as the interconnect does for a DMA
  // write; it waits while the snoop queue is nearly full (a real DMA master
  // never writes faster than a line per eight bus cycles). +dmalag=N: each
  // line reaches the RAM N cycles after its snoop (a memory path where the
  // bus accepts a DMA write well before the DDR has it).
  logic        dma_run, dma_step, dma_wr, dma_full;
  logic [30:0] dma_line;
  logic [35:0] dma_dst;
  logic [31:0] dma_left, dma_seed, dma_rate, dma_cnt, dma_rd, dma_wr_word;
  logic [2:0]  dma_reg;
  // The harness's interrupt source (same page): +18 period in cycles (0
  // stops it), +1C a write acknowledges, a read gives the count raised.
  // Every period cycles it raises level 10 until acknowledged.
  logic [31:0] h_period, h_cnt, h_raised;
  logic        h_pend;
  logic [3:0]  h_irl;
  assign h_irl = h_pend ? 4'd10 : 4'd0;
  assign dma_step    = dma_run && dma_cnt == 32'd0 && !dma_full;
  assign dma_wr      = dma_step;
  assign dma_line    = dma_dst[35:5];
  assign dma_reg     = {mr.pa[4:3], mr.be[7:4] == 4'h0};
  assign dma_wr_word = (mr.be[7:4] != 4'h0) ? mr.wdata[63:32] : mr.wdata[31:0];
  always_comb begin
    case (dma_reg)
      3'd0: dma_rd = 32'h444D_4131;
      3'd1: dma_rd = dma_dst[31:0];
      3'd2: dma_rd = dma_left;
      3'd3: dma_rd = dma_seed;
      3'd4: dma_rd = {31'd0, dma_run || lag_rp != lag_wp || (dma_lag != 0 && cyc - last_land < 300)};   // busy until 300 cycles after the last line landed (a controller's interrupt and status reads)
      3'd5: dma_rd = dma_rate;
      3'd6: dma_rd = h_period;
      3'd7: dma_rd = h_raised;
      default: dma_rd = '0;
    endcase
  end

  // The interconnect's snoop broadcast: the model's own writes and the DMA
  // engine's lines through one queue (which honours the module's hold)
  snoop_t dsn;
  logic   dsn_full;
  snoop_queue #(.DEPTH(16), .OWN_MID(4'd8), .DMA_MID(4'd0), .RESNOOP(RESNOOP), .RW(512)) u_dsnq (
    .clk, .rst, .ld_i(1'b1), .hold_i(c_hold_q),
    .own_valid_i(sn.valid), .own_line_i(sn.line),
    .dma_valid_i(dma_wr), .dma_line_i(dma_line),
    .full_o(dsn_full), .snoop_o(dsn));
  assign csn      = dsn;
  assign dma_full = dsn_full;

  // ---- memories ----
  logic [31:0] rom [0:262143];       // 1 MB of words
  logic [63:0] ram [0:2097151];      // 16 MB
  initial $readmemh(ROM, rom);

  // ---- the ESCC on the I/O bus ----
  iob_req_t esc_req;
  iob_rsp_t esc_rsp;
  logic txd_a, txd_b, rts_a, dtr_a, rts_b, dtr_b, irq;
  logic [7:0] tx_byte_a, tx_byte_b;
  logic tx_byte_valid_a, tx_byte_valid_b, rx_byte_ready_a, rx_byte_ready_b;
  escc #(.CLK_HZ(9_830_400)) u_escc (
    .clk, .rst, .bus_i(esc_req), .bus_o(esc_rsp),
    .txd_a_o(txd_a), .rxd_a_i(1'b1), .dcd_a_i(1'b1), .cts_a_i(1'b1), .rts_a_o(rts_a), .dtr_a_o(dtr_a),
    .txd_b_o(txd_b), .rxd_b_i(1'b1), .dcd_b_i(1'b1), .cts_b_i(1'b1), .rts_b_o(rts_b), .dtr_b_o(dtr_b),
    .tx_byte_a_o(tx_byte_a), .tx_byte_valid_a_o(tx_byte_valid_a), .rx_byte_a_i(8'h00), .rx_byte_valid_a_i(1'b0), .rx_byte_ready_a_o(rx_byte_ready_a),
    .tx_byte_b_o(tx_byte_b), .tx_byte_valid_b_o(tx_byte_valid_b), .rx_byte_b_i(8'h00), .rx_byte_valid_b_i(1'b0), .rx_byte_ready_b_o(rx_byte_ready_b),
    .irq_o(irq));

  // ---- the system control/status registers (slavio_misc, pages 6/8/A/F) ----
  iob_req_t misc_req;
  iob_rsp_t misc_rsp;
  logic [15:0] leds;
  logic led, fd_tc, power_off, pwr_irq, misc_sw_reset;
  slavio_misc u_misc (
    .clk, .rst, .rst_swr_i(1'b0), .rst_switch_i(1'b0), .wd_i(wd_reset),
    .bus_i(misc_req), .bus_o(misc_rsp),
    .leds_o(leds), .led_o(led), .fd_tc_o(fd_tc), .fd_density_i(1'b0), .power_off_o(power_off),
    .pwr_fail_i(1'b0), .pwr_irq_o(pwr_irq), .diag_sw_i(1'b0), .sw_reset_o(misc_sw_reset),
    .cfg_cg3_i(1'b0), .cfg_noautoboot_i(1'b0), .cfg_serial_i(1'b1), .cfg_ram_mb_i(10'd16));

  // ---- the counter/timers (slavio_timer, page 3), for the benchmarks ----
  iob_req_t tmr_req;
  iob_rsp_t tmr_rsp;
  logic       tmr_irq_sys;
  logic [0:0] tmr_irq_cpu;
  slavio_timer #(.NCPU(1), .CLK_HZ(100_000_000)) u_timer (
    .clk, .rst, .swr_i(1'b0), .bus_i(tmr_req), .bus_o(tmr_rsp), .irq_sys(tmr_irq_sys), .irq_cpu(tmr_irq_cpu));

  // ---- the interconnect slave ----
  logic is_ram, is_rom, is_escc, is_misc, is_timer, is_io, is_sbus_empty, is_dma;
  always_comb begin
    is_ram  = mr.pa[35:24] == 12'h000;
    is_rom  = mr.pa[35:24] == 12'hFF0;
    is_escc = mr.pa[35:20] == 16'hFF11;
    is_misc = mr.pa[35:24] == 12'hFF1 && (mr.pa[23:20] == 4'h6 || mr.pa[23:20] == 4'h8 || mr.pa[23:20] == 4'hA || mr.pa[23:20] == 4'hF);
    is_timer = mr.pa[35:20] == 16'hFF13;
    is_io   = is_escc | is_misc | is_timer;
    is_dma  = mr.pa[35:12] == 24'hE00001;
    is_sbus_empty = mr.pa[35:32] == 4'hE && mr.pa[31:30] == 2'b00 && !is_dma;
  end

  int lat;
  logic gaps;
  initial begin
    if (!$value$plusargs("lat=%d", lat)) lat = 1;
    gaps = $test$plusargs("gaps");
  end

  typedef enum logic [1:0] {M_IDLE, M_WAIT, M_BEAT, M_ESCC} mstate_t;
  mstate_t   mst;
  int        m_cnt;
  logic [1:0] beat;
  logic       gap_q;

  function automatic logic [63:0] read_dw(input logic [35:0] pa);
    if (pa[35:24] == 12'h000) return ram[pa[23:3]];
    if (pa[35:24] == 12'hFF0) return {rom[{pa[19:3], 1'b0}], rom[{pa[19:3], 1'b1}]};
    return 64'd0;
  endfunction

  logic [35:0] bpa;                  // the beat's address
  assign bpa = mr.burst ? {mr.pa[35:5], beat, 3'b000} : mr.pa;

  // The I/O bus wants the byte address (the ESCC decodes addr[2:1]) and
  // the lanes within the word: both from the doubleword's byte enables.
  // One request per access, to the slave the address selects.
  logic [2:0] io_off;
  iob_req_t io_req;
  iob_rsp_t io_rsp;
  assign io_rsp = is_escc ? esc_rsp : is_timer ? tmr_rsp : misc_rsp;
  always_comb begin
    io_off = 3'd0;
    for (int i = 0; i < 8; i++) if (mr.be[i]) io_off = 3'(7 - i);    // the first enabled byte
    io_req = IOB_REQ_IDLE;
    io_req.req   = mst == M_ESCC && !io_rsp.ack && !esc_started;
    io_req.we    = mr.write;
    io_req.addr  = {4'h0, mr.pa[23:3], io_off};
    io_req.be    = (mr.be[7:4] != 4'h0) ? mr.be[7:4] : mr.be[3:0];
    io_req.wdata = (mr.be[7:4] != 4'h0) ? mr.wdata[63:32] : mr.wdata[31:0];
    esc_req = io_req;  esc_req.req  = io_req.req & is_escc;  esc_req.addr = {8'h0, io_req.addr[19:0]};
    misc_req = io_req; misc_req.req = io_req.req & is_misc;
    tmr_req  = io_req; tmr_req.req  = io_req.req & is_timer; tmr_req.addr = {8'h0, io_req.addr[19:0]};
  end
  logic esc_started;

  int dma_lag;
  initial begin
    if (!$value$plusargs("dmalag=%d", dma_lag)) dma_lag = 0;
    if (dma_lag != 0) $display("cpu_sim: DMA lines land %0d cycles after their snoop; second snoop after %0d", dma_lag, RESNOOP);
  end
  logic [35:0] lag_dst  [0:255];
  logic [31:0] lag_seed [0:255];
  longint      lag_due  [0:255];
  logic [7:0]  lag_wp, lag_rp;
  longint      last_land;
  initial begin lag_wp = '0; lag_rp = '0; last_land = 0; end
  always_ff @(posedge clk) begin
    ms <= '0;
    sn <= '0;
    // the DMA engine's delayed RAM writes
    if (lag_rp != lag_wp && cyc >= lag_due[lag_rp]) begin
      for (int k = 0; k < 4; k++)
        ram[lag_dst[lag_rp][23:3] + 21'(k)] <= {(lag_dst[lag_rp][31:0] + 32'(8 * k)) ^ lag_seed[lag_rp],
                                                 (lag_dst[lag_rp][31:0] + 32'(8 * k + 4)) ^ lag_seed[lag_rp]};
      lag_rp <= lag_rp + 8'd1;
      last_land <= cyc;
    end
    if (rst) begin
      mst <= M_IDLE; m_cnt <= 0; beat <= '0; gap_q <= 1'b0; esc_started <= 1'b0;
      dma_run <= 1'b0; dma_dst <= '0; dma_left <= '0; dma_seed <= '0; dma_rate <= 32'd1; dma_cnt <= '0;
      h_period <= '0; h_cnt <= '0; h_raised <= '0; h_pend <= 1'b0;
    end else begin
      // ---- the interrupt source ----
      if (h_period != 32'd0) begin
        if (h_cnt <= 32'd1) begin h_cnt <= h_period; h_pend <= 1'b1; h_raised <= h_raised + 32'd1; end
        else h_cnt <= h_cnt - 32'd1;
      end
      // ---- the DMA engine: a line a step ----
      if (dma_step) begin
        if (dma_lag == 0) begin
          for (int k = 0; k < 4; k++)
            ram[dma_dst[23:3] + 21'(k)] <= {(dma_dst[31:0] + 32'(8 * k)) ^ dma_seed, (dma_dst[31:0] + 32'(8 * k + 4)) ^ dma_seed};
        end else begin
          lag_dst[lag_wp] <= dma_dst; lag_seed[lag_wp] <= dma_seed; lag_due[lag_wp] <= cyc + longint'(dma_lag);
          lag_wp <= lag_wp + 8'd1;
        end
        dma_dst  <= dma_dst + 36'd32;
        dma_left <= dma_left - 32'd1;
        dma_cnt  <= dma_rate - 32'd1;
        if (dma_left == 32'd1) dma_run <= 1'b0;
      end else if (dma_run && dma_cnt != 32'd0) begin
        dma_cnt <= dma_cnt - 32'd1;
      end
      case (mst)
        M_IDLE: begin
          if (mr.valid && !ms.ack) begin        // not the request just acked
            m_cnt <= lat;
            beat <= '0;
            gap_q <= 1'b0;
            if (is_io) begin mst <= M_ESCC; esc_started <= 1'b0; end
            else mst <= M_WAIT;
          end
        end
        M_WAIT: begin
          if (m_cnt <= 1) mst <= M_BEAT;
          else m_cnt <= m_cnt - 1;
        end
        M_BEAT: begin
          if (gaps && !gap_q) begin
            gap_q <= 1'b1;                      // a bubble before each beat
          end else begin
            gap_q <= 1'b0;
            ms.ack <= 1'b1;
            if (is_sbus_empty) begin
              ms.err <= 1'b1;
              mst <= M_IDLE;
            end else if (is_dma) begin                // the harness's DMA engine
              ms.rdata <= {2{dma_rd}};
              if (mr.write) begin
                case (dma_reg)
                  3'd1: dma_dst  <= {4'h0, dma_wr_word};
                  3'd2: dma_left <= dma_wr_word;
                  3'd3: begin dma_seed <= dma_wr_word; dma_run <= dma_left != 32'd0; dma_cnt <= '0; end
                  3'd5: dma_rate <= (dma_wr_word == 32'd0) ? 32'd1 : dma_wr_word;
                  3'd6: begin h_period <= dma_wr_word; h_cnt <= dma_wr_word; h_pend <= 1'b0; end
                  3'd7: h_pend <= 1'b0;
                  default: ;
                endcase
              end
              mst <= M_IDLE;
            end else begin
              ms.rdata <= read_dw(bpa);
              if (mr.write && is_ram) begin
                for (int i = 0; i < 8; i++) if (mr.be[i]) ram[bpa[23:3]][i*8 +: 8] <= mr.wdata[i*8 +: 8];
              end
              if (mr.write) begin
                sn.valid <= 1'b1; sn.line <= bpa[35:5]; sn.mid <= 4'd8;
              end
              if (mr.burst && beat != 2'd3) beat <= beat + 2'd1;
              else mst <= M_IDLE;
            end
          end
        end
        M_ESCC: begin                         // any I/O-bus slave
          if (io_req.req) esc_started <= 1'b1;
          if (io_rsp.ack) begin
            ms.ack <= 1'b1;
            ms.rdata <= {2{io_rsp.rdata}};      // a word in both halves (the ESCC's byte in every lane)
            if (mr.write) begin sn.valid <= 1'b1; sn.line <= mr.pa[35:5]; sn.mid <= 4'd8; end
            mst <= M_IDLE;
          end
        end
        default: mst <= M_IDLE;
      endcase
    end
  end

  // ---- cycle count, stop rules ----
  longint cyc;
  logic [95:0] last12;               // the last twelve ttya bytes
  logic        done_seen;            // "CPUTEST DONE" went by: stop at the end of its line
  logic quiet;
  initial quiet = $test$plusargs("dmem") || $test$plusargs("trace") || $test$plusargs("mem");
  logic keep_wd;
  initial keep_wd = $test$plusargs("wd");
  longint budget;
  initial if (!$value$plusargs("cycles=%d", budget)) budget = CYCLES;
  initial begin
    cyc = 0; last12 = '0; done_seen = 1'b0;
    repeat (4) @(posedge clk);
    rst = 0;
  end
  always_ff @(posedge clk) begin
    cyc <= cyc + 1;
    if (u_escc.dat_wr_a) begin
      if (!quiet) begin $write("%c", u_escc.wbyte); $fflush(); end
      last12 <= {last12[87:0], u_escc.wbyte};
      if ({last12[87:0], u_escc.wbyte} == "CPUTEST DONE") done_seen <= 1'b1;
      if (done_seen && u_escc.wbyte == 8'h0A) begin
        $display("\ncpu_sim: done after %0d cycles", cyc);
        $finish;
      end
    end
    if (wd_reset && !keep_wd) begin
      $display("\ncpu_sim: watchdog reset (error mode) at cycle %0d", cyc);
      $finish;
    end
    if (cyc >= budget) begin
      $display("\ncpu_sim: cycle budget exhausted");
      $finish;
    end
  end

  // ---- +escc: the transmitter of channel A whenever its status is read ----
  always_ff @(posedge clk) begin
    if ($test$plusargs("escc") && esc_rsp.ack && !mr.write)
      $display("%8d  escc rd addr=%05x rdata=%02x | A: tx_busy=%0d buf_full=%0d tx_en=%0d cts_ok=%0d wr5=%02x brg=%0d",
               cyc, esc_req.addr[19:0], esc_rsp.rdata[7:0], u_escc.chan_a.tx_busy, u_escc.chan_a.tx_buf_full,
               u_escc.chan_a.tx_en, u_escc.chan_a.tx_cts_ok, u_escc.chan_a.wr5, u_escc.chan_a.tx_clk);
  end

  // ---- +trace: every instruction as it commits, and the traps ----
  logic trace;
  initial trace = $test$plusargs("trace");
  always_ff @(posedge clk) begin
    if (trace && u_cpu.u_iu.w_valid && !u_cpu.u_iu.w_stall) begin
      if (u_cpu.u_iu.w_trap)
        $display("%8d  %08x  TRAP tt=%02x  (npc %08x) cwp %0d et %0d", cyc, u_cpu.u_iu.w_pc, u_cpu.u_iu.w_tt, u_cpu.u_iu.w_npc, u_cpu.u_iu.cwp, u_cpu.u_iu.et);
      else
        $display("%8d  %08x  %-10s rd=%0d r=%08x  icc=%b cwp=%0d", cyc, u_cpu.u_iu.w_pc, u_cpu.u_iu.w_dec.cls.name(), u_cpu.u_iu.w_dec.rd,
                 u_cpu.u_iu.w_rdval, u_cpu.u_iu.icc, u_cpu.u_iu.cwp);
    end
  end

  // ---- +dmem: every data access as it is acknowledged ----
  always_ff @(posedge clk) begin
    if ($test$plusargs("dmem") && u_cpu.dmr.valid && u_cpu.dms.ack)
      $display("%8d  dmem %s asi=%02x va=%08x pa=%09x size=%0d wdata=%016x rdata=%016x fault=%0d",
               cyc, u_cpu.dmr.write ? "W" : (u_cpu.dmr.atomic ? "A" : "R"), u_cpu.dmr.asi, u_cpu.dmr.va, u_cpu.d_pa,
               u_cpu.dmr.size, u_cpu.dmr.wdata, u_cpu.dms.rdata, u_cpu.dms.fault);
  end

  // ---- +mem: every beat on the interconnect ----
  always_ff @(posedge clk) begin
    if ($test$plusargs("mem") && ms.ack)
      $display("%8d  mem %s%s pa=%09x be=%02x wdata=%016x rdata=%016x err=%0d owner=%0d",
               cyc, mr.write ? "W" : "R", mr.burst ? "b" : " ", bpa, mr.be, mr.wdata, ms.rdata, ms.err, u_cpu.owner);
  end

  // ---- +from=N +to=N: pipeline internals in a cycle window ----
  longint dbg_from, dbg_to;
  initial begin
    if (!$value$plusargs("from=%d", dbg_from)) dbg_from = 0;
    if (!$value$plusargs("to=%d", dbg_to)) dbg_to = -1;
  end
  always_ff @(posedge clk) begin
    if (cyc >= dbg_from && cyc <= dbg_to)
      $display("%8d D v%0d pc=%08x go%0d | E v%0d pc=%08x go%0d | M v%0d pc=%08x | W v%0d pc=%08x | F pc=%08x pend%0d | is=%s ds=%s ws=%s ic=%s dc=%s",
               cyc, u_cpu.u_iu.d_valid, u_cpu.u_iu.d_pc, u_cpu.u_iu.d_go, u_cpu.u_iu.e_valid, u_cpu.u_iu.e_pc, u_cpu.u_iu.e_go,
               u_cpu.u_iu.m_valid, u_cpu.u_iu.m_pc, u_cpu.u_iu.w_valid, u_cpu.u_iu.w_pc,
               u_cpu.u_iu.f_pc, u_cpu.u_iu.f_pending,
               u_cpu.is.name(), u_cpu.ds.name(), u_cpu.u_mmu.ws.name(), u_cpu.u_ic.st.name(), u_cpu.u_dc.st.name());
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, boot_mode, tmr_irq_sys, tmr_irq_cpu, tx_byte_a, tx_byte_b, tx_byte_valid_a, tx_byte_valid_b, rx_byte_ready_a, rx_byte_ready_b, txd_a, txd_b, rts_a, dtr_a, rts_b, dtr_b, irq, halt, si_reset, leds, led, fd_tc, power_off, pwr_irq, misc_sw_reset};

endmodule
