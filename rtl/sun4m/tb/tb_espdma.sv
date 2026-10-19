// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_espdma: esp.sv (on scsi_targets) and dma2.sv together, as software
// drives them, with a behavioural DVMA memory (random latency) behind the
// espdma channel, a model of hps_io's block interface serving two disk
// images (tb_scsi_targets' model: block n holds 'SCSI', the tag, n, then
// (n << 8 | k) ^ 0xa5a5a5a5) and a responder behind the ledma channel.
// The cases:
//   - registers: the DMA2 CSRs' reset values (DEV_ID, E_BASE_ADDR 0xFF),
//     byte writes, the ESP100A probe (CFG2 read back, no CFG3), the FIFO,
//     the counter's load and readback;
//   - resets: D_RESET reaches the ESP, RESET chip, the SCSI bus reset's
//     interrupt (and CFG1's disable), interrupt gating by D_CSR INT_EN;
//   - scsitest's scsi_cmd in its three modes (tests/cpu/src/scsitest.S):
//     a selection time-out (Disconnected), INQUIRY, TEST UNIT READY and
//     its UNIT ATTENTION, REQUEST SENSE of 18 bytes into 255 (DMA-5: the
//     last partial doubleword written, nothing beyond), READ(10) of
//     several blocks into memory, WRITE(10) and the read-back (the data
//     phase's interrupt with STATUS), an unaligned buffer, mode 0
//     (OpenBIOS: no ICCS after a command without data), mode 2 (ICCS not
//     awaited) with the bus reset's interrupt left pending into the probe;
//   - ESP-7: no interrupt visible before HOLD_CYCLES after a select;
//   - ESP-8: SDTR sent by SELATNS + TI, the reply taken a byte at a time,
//     each MESSAGE ACCEPTED a Bus Service, then the CDB through the FIFO
//     (ESP-9: its first bytes one per TI, written after the command);
//     a queue tag; COMMAND COMPLETE then MESSAGE ACCEPTED disconnects;
//   - a DVMA error: ERR_PEND, the interrupt, INVALIDATE;
//   - ledma: the LANCE's requests with E_BASE_ADDR as va[31:24], the
//     answers back, E_TST_CSR, INT_PEND ungated, irq_le_o gated, E_RESET,
//     E_ERR_PEND.

module tb_espdma;
  import tb_pkg::*;
  import iobus_pkg::*;
  import sbus_pkg::*;
  import mem_pkg::*;

  localparam int CLK_HZ = 8_000_000;
  localparam int HOLD   = 300;            // ESP-7 hold, cycles
  localparam int HD0_BLKS = 1024, HD1_BLKS = 512;
  localparam logic [2:0] ID_HD0 = 3'd3, ID_HD1 = 3'd1, ID_CD = 3'd6;
  localparam int TO = 400_000;

  logic clk;
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end
  logic rst = 1'b1;

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  // ---------------------------------------------------------------------
  // The DUTs
  // ---------------------------------------------------------------------
  iob_req_t  eb_req = IOB_REQ_IDLE, db_req = IOB_REQ_IDLE;
  iob_rsp_t  eb_rsp, db_rsp;
  logic      esp_irq, dreq, dtomem, dack, esp_rst, irq_esp;
  logic [7:0] ddo, ddi;
  dvma_req_t esp_dvma;
  mem_rsp_t  esp_mrsp;
  dvma_req_t le_req = DVMA_REQ_IDLE;
  mem_rsp_t  le_rsp;
  dvma_req_t le_dvma;
  mem_rsp_t  le_mrsp;
  logic      le_irq = 1'b0, irq_le, le_rst;
  logic      le_serr = 1'b0;

  logic [2:0]  img_mounted = 3'b000;
  logic [63:0] img_size = '0;
  logic [31:0] sd_lba;
  logic [5:0]  sd_blk_cnt;
  logic [2:0]  sd_rd, sd_wr, sd_ack;
  logic [12:0] sd_buff_addr;
  logic [15:0] sd_buff_dout, sd_buff_din;
  logic        sd_buff_wr;
  logic        busy;
  logic [15:0] cd_l, cd_r;

  esp #(.CLK_HZ(CLK_HZ), .HOLD_CYCLES(HOLD), .BRST_CYCLES(16), .SIMU(1'b1)) u_esp (
    .clk, .rst, .chip_rst_i(esp_rst),
    .bus_i(eb_req), .bus_o(eb_rsp), .irq_o(esp_irq),
    .dreq_o(dreq), .dtomem_o(dtomem), .ddata_o(ddo), .dack_i(dack), .ddata_i(ddi),
    .id0_i(ID_HD0), .id1_i(ID_HD1), .id2_i(ID_CD), .ena_i(3'b011), .cd2048_i(1'b1),
    .img_mounted_i(img_mounted), .img_size_i(img_size), .img_readonly_i(1'b0),
    .sd_lba_o(sd_lba), .sd_blk_cnt_o(sd_blk_cnt), .sd_rd_o(sd_rd), .sd_wr_o(sd_wr),
    .sd_ack_i(sd_ack), .sd_buff_addr_i(sd_buff_addr), .sd_buff_dout_i(sd_buff_dout),
    .sd_buff_din_o(sd_buff_din), .sd_buff_wr_i({3{sd_buff_wr}} & sd_ack),
    .busy_o(busy), .cd_l_o(cd_l), .cd_r_o(cd_r));

  dma2 u_dma (
    .clk, .rst,
    .bus_i(db_req), .bus_o(db_rsp),
    .esp_irq_i(esp_irq), .esp_dreq_i(dreq), .esp_dtomem_i(dtomem), .esp_ddata_i(ddo),
    .esp_dack_o(dack), .esp_ddata_o(ddi), .esp_rst_o(esp_rst), .irq_esp_o(irq_esp),
    .esp_dvma_o(esp_dvma), .esp_dvma_i(esp_mrsp),
    .le_req_i(le_req), .le_rsp_o(le_rsp), .le_dvma_o(le_dvma), .le_dvma_i(le_mrsp),
    .le_irq_i(le_irq), .le_size_err_i(le_serr), .irq_le_o(irq_le), .le_rst_o(le_rst));

  // ---------------------------------------------------------------------
  // The DVMA memory behind espdma: 64 KB at DVMA 0xFF00_0000; anything
  // else answers err. Random latency; protocol checks.
  // ---------------------------------------------------------------------
  localparam logic [31:0] DVMA = 32'hFF00_0000;
  localparam int CMDB = 32'h0000, DATAB = 32'h1000;
  logic [7:0] mem [65536];
  int         m_wait;
  bit         m_busy;
  int         m_beats, m_wbeats, m_errs, m_proto;
  logic [31:0] m_va_hold;

  initial begin
    esp_mrsp = '{ack: 1'b0, err: 1'b0, rdata: '0};
    m_busy = 1'b0; m_beats = 0; m_wbeats = 0; m_errs = 0; m_proto = 0;
  end

  /* verilator lint_off BLKSEQ */
  always @(posedge clk) begin : dvma_mem
    int a;
    esp_mrsp.ack <= 1'b0;
    esp_mrsp.err <= 1'b0;
    if (esp_dvma.valid && esp_dvma.burst) m_proto++;
    if (m_busy && esp_dvma.va != m_va_hold) m_proto++;      // held until the ack
    if (esp_dvma.valid && !esp_mrsp.ack) begin
      if (!m_busy) begin
        m_busy <= 1'b1;
        m_wait <= $urandom_range(6);
        m_va_hold <= esp_dvma.va;
      end else if (m_wait > 0)
        m_wait <= m_wait - 1;
      else begin
        m_busy <= 1'b0;
        esp_mrsp.ack <= 1'b1;
        m_beats++;
        if (esp_dvma.va[31:16] != DVMA[31:16]) begin
          esp_mrsp.err <= 1'b1;
          m_errs++;
        end else begin
          a = int'(esp_dvma.va[15:3]) * 8;
          for (int k = 0; k < 8; k++) begin
            if (esp_dvma.write && esp_dvma.be[7 - k]) mem[a + k] <= esp_dvma.wdata[63 - 8 * k -: 8];
            esp_mrsp.rdata[63 - 8 * k -: 8] <= mem[a + k];
          end
          if (esp_dvma.write) m_wbeats++;
        end
      end
    end
  end
  /* verilator lint_on BLKSEQ */

  // ---------------------------------------------------------------------
  // The ledma responder: acks after a few cycles, rdata = the address;
  // va[31:24] = 0x66 answers err
  // ---------------------------------------------------------------------
  int         l_wait;
  bit         l_busy;
  logic [31:0] l_va;
  initial begin le_mrsp = '{ack: 1'b0, err: 1'b0, rdata: '0}; l_busy = 1'b0; end
  always @(posedge clk) begin : le_mem
    le_mrsp.ack <= 1'b0;
    le_mrsp.err <= 1'b0;
    if (le_dvma.valid && !le_mrsp.ack) begin
      if (!l_busy) begin l_busy <= 1'b1; l_wait <= 3; end
      else if (l_wait > 0) l_wait <= l_wait - 1;
      else begin
        l_busy <= 1'b0;
        le_mrsp.ack <= 1'b1;
        le_mrsp.err <= le_dvma.va[31:24] == 8'h66;
        le_mrsp.rdata <= {le_dvma.va, ~le_dvma.va};
        l_va <= le_dvma.va;
      end
    end
  end

  // ---------------------------------------------------------------------
  // The images and the hps_io model (tb_scsi_targets')
  // ---------------------------------------------------------------------
  logic [7:0] img0 [HD0_BLKS * 512];
  logic [7:0] img1 [HD1_BLKS * 512];
  localparam logic [31:0] TAG_HD0 = 32'h48443000, TAG_HD1 = 32'h48443100;

  function automatic logic [7:0] pat(input logic [31:0] tag, input int n, input int off);
    logic [31:0] w;
    int k;
    k = off / 4;
    if (k == 0)      w = 32'h53435349;
    else if (k == 1) w = tag;
    else if (k == 2) w = 32'(n);
    else             w = ((32'(n) << 8) | 32'(k)) ^ 32'ha5a5a5a5;
    return w[8 * (3 - off % 4) +: 8];
  endfunction

  function automatic logic [7:0] img_rd(input int slot, input int a);
    if (slot == 0) return img0[a];
    else           return img1[a];
  endfunction
  task automatic img_wr(input int slot, input int a, input logic [7:0] d);
    if (slot == 0) img0[a] <= d;
    else           img1[a] <= d;
  endtask

  typedef enum {SD_IDLE, SD_DELAY, SD_RD, SD_WR, SD_END} sd_e;
  sd_e         sd_st;
  int          sd_slot, sd_word, sd_sub, sd_wait, sd_nblk;
  bit          sd_isw;
  logic [31:0] sd_rlba;
  int          img_blks [2];
  initial begin
    sd_st = SD_IDLE; sd_ack = 3'b000; sd_buff_addr = '0; sd_buff_dout = '0; sd_buff_wr = 1'b0;
  end

  always @(posedge clk) begin : sd_model
    longint a;
    int     pick, sub_n, word_n;
    sd_buff_wr <= 1'b0;
    case (sd_st)
      SD_IDLE: begin
        pick = -1;
        for (int n = 0; n < 2; n++)
          if (pick < 0 && (sd_rd[n] || sd_wr[n])) pick = n;
        if (pick >= 0) begin
          sd_slot <= pick;
          sd_isw  <= sd_wr[pick];
          sd_rlba <= sd_lba;
          sd_nblk <= int'(sd_blk_cnt) + 1;
          sd_wait <= 20 + $urandom_range(40);
          sd_st <= SD_DELAY;
        end
      end
      SD_DELAY: begin
        if (sd_wait > 1) sd_wait <= sd_wait - 1;
        else begin
          sd_ack[sd_slot] <= 1'b1;
          sd_buff_addr <= '0;
          sd_word <= 0;
          sd_sub  <= 0;
          sd_st <= sd_isw ? SD_WR : SD_RD;
        end
      end
      SD_RD, SD_WR: begin
        a = longint'(sd_rlba) * 512 + longint'(2 * sd_word);
        if (sd_st == SD_RD) begin
          if (sd_sub == 0) begin
            sd_buff_addr <= 13'(sd_word);
            if (a + 1 < longint'(img_blks[sd_slot]) * 512)
              sd_buff_dout <= {img_rd(sd_slot, int'(a) + 1), img_rd(sd_slot, int'(a))};
            else
              sd_buff_dout <= 16'h0000;
          end else if (sd_sub == 1)
            sd_buff_wr <= 1'b1;
        end else begin
          if (sd_sub == 0)
            sd_buff_addr <= 13'(sd_word);
          else if (sd_sub == 3 && a + 1 < longint'(img_blks[sd_slot]) * 512) begin
            img_wr(sd_slot, int'(a), sd_buff_din[7:0]);
            img_wr(sd_slot, int'(a) + 1, sd_buff_din[15:8]);
          end
        end
        sub_n = sd_sub + 1;
        word_n = sd_word;
        if (sub_n == 4) begin
          sub_n = 0;
          word_n = sd_word + 1;
          if (word_n == 256 * sd_nblk) begin sd_st <= SD_END; sd_wait <= 4; end
        end
        sd_sub  <= sub_n;
        sd_word <= word_n;
      end
      default: begin
        if (sd_wait > 1) sd_wait <= sd_wait - 1;
        else begin sd_ack <= 3'b000; sd_st <= SD_IDLE; end
      end
    endcase
  end

  task automatic mount(input int slot, input int blks);
    img_blks[slot] = blks;
    img_size = 64'(blks) * 512;
    img_mounted[slot] = 1'b1;
    cycles(2);
    img_mounted[slot] = 1'b0;
    cycles(2);
  endtask

  // ---------------------------------------------------------------------
  // The CPU: iobus accesses to the two slaves
  // ---------------------------------------------------------------------
  int iob_to = 0;
  bit iob_err;                            // the last access had an error ack
  task automatic iob(input bit to_dma, input bit we, input logic [27:0] a, input logic [3:0] be,
                     input logic [31:0] wd, output logic [31:0] rd);
    iob_req_t r;
    int t;
    r = '{req: 1'b1, we: we, addr: a, be: be, wdata: wd, pair: 1'b0};
    if (to_dma) db_req = r; else eb_req = r;
    t = 0;
    rd = 32'hDEADBEEF;
    forever begin
      @(posedge clk); #1;
      iob_err = to_dma ? db_rsp.err : eb_rsp.err;
      if (to_dma ? db_rsp.ack || db_rsp.err : eb_rsp.ack || eb_rsp.err) begin
        rd = to_dma ? db_rsp.rdata : eb_rsp.rdata;
        break;
      end
      if (++t > 10000) begin iob_to++; check(1'b0, "iobus: no ack"); break; end
    end
    if (to_dma) db_req = IOB_REQ_IDLE; else eb_req = IOB_REQ_IDLE;
  endtask

  task automatic esp_w(input int r, input logic [7:0] v);
    logic [31:0] d;
    iob(1'b0, 1'b1, 28'(r * 4), 4'b1000, {v, 24'h0}, d);
  endtask
  task automatic esp_r(input int r, output logic [7:0] v);
    logic [31:0] d;
    iob(1'b0, 1'b0, 28'(r * 4), 4'b1000, 32'h0, d);
    v = d[31:24];
  endtask
  task automatic dma_w(input int off, input logic [31:0] v);
    logic [31:0] d;
    iob(1'b1, 1'b1, 28'(off), 4'hF, v, d);
  endtask
  task automatic dma_r(input int off, output logic [31:0] v);
    iob(1'b1, 1'b0, 28'(off), 4'hF, 32'h0, v);
  endtask

  // ESP registers, commands; D_CSR bits (scsitest.S's names)
  localparam int R_TCL = 0, R_TCM = 1, R_FIFO = 2, R_CMD = 3, R_STAT = 4, R_INTR = 5,
                 R_SEQ = 6, R_FFLG = 7, R_CFG1 = 8, R_CFG2 = 11, R_CFG3 = 12, R_TCHI = 14;
  localparam logic [7:0] C_DMA = 8'h80, C_NOP = 8'h00, C_FLUSH = 8'h01, C_RESET = 8'h02,
                         C_BUSRESET = 8'h03, C_TI = 8'h10, C_ICCS = 8'h11, C_MSGACC = 8'h12,
                         C_SELATN = 8'h42, C_SELATNS = 8'h43;
  localparam logic [7:0] I_FC = 8'h08, I_BS = 8'h10, I_DC = 8'h20, I_ILL = 8'h40, I_RST = 8'h80;
  localparam logic [31:0] D_INT = 32'h001, D_INTEN = 32'h010, D_INVAL = 32'h020,
                          D_RESET = 32'h080, D_WRITE = 32'h100, D_EN = 32'h200;
  localparam int E_NOTARGET = -1, E_TO_SEL = -2, E_TO_DATA = -3, E_TO_ICCS = -4,
                 E_TO_MSGACC = -5, E_NODATA = -6, E_ILLEGAL = -7;

  // wait_int: D_CSR INT_PEND, polled (as scsitest.S); the cycles it took
  int wi_cycles;
  task automatic wait_int(output bit got);
    logic [31:0] v;
    int t0;
    t0 = int'($time / 10);
    got = 1'b0;
    for (int i = 0; i < TO / 4; i++) begin
      dma_r(0, v);
      if (v[0]) begin got = 1'b1; break; end
    end
    wi_cycles = int'($time / 10) - t0;
  endtask

  task automatic esp_go(input logic [7:0] c, output logic [7:0] intr, output logic [7:0] stat);
    bit got;
    esp_w(R_CMD, c);
    wait_int(got);
    if (!got) begin intr = 8'hFF; stat = 8'hFF; return; end
    esp_r(R_STAT, stat);
    esp_r(R_INTR, intr);
  endtask

  // scsi_cmd: tests/cpu/src/scsitest.S's, in SystemVerilog
  //   mode 0 OpenBIOS's sequence, 1 the whole sequence, 2 OpenBIOS's
  //   without waiting for ICCS -> status (or E_*), the ESP status after the
  //   data phase
  task automatic scsi_cmd(input logic [2:0] id, input byte unsigned cdb [$], input int dlen,
                          input bit dout, input int mode, input int buf_off,
                          output int status, output logic [7:0] st_data);
    bit got;
    logic [7:0] st, in, sb;
    int l7;
    mem[CMDB] = 8'h80;
    for (int i = 0; i < cdb.size(); i++) mem[CMDB + 1 + i] = cdb[i];
    esp_w(R_STAT, 8'(id));
    esp_w(R_TCL, 8'(cdb.size() + 1));
    esp_w(R_TCM, 8'h00);
    dma_w(4, DVMA + CMDB);
    dma_w(0, D_EN);
    esp_w(R_CMD, C_SELATN | C_DMA);
    wait_int(got);
    st_data = 8'hFF;
    if (!got) begin status = E_TO_SEL; dma_w(0, 0); return; end
    esp_r(R_STAT, st);
    esp_r(R_INTR, in);
    if ((in & I_ILL) != 0) begin status = E_ILLEGAL; dma_w(0, 0); return; end
    if ((in & I_DC) != 0)  begin status = E_NOTARGET; dma_w(0, 0); return; end
    st_data = st;
    l7 = 0;
    if (dlen == 0) begin
      if (mode != 1) begin status = 0; dma_w(0, 0); return; end
    end else if (st[2:0] == 3'd3)
      l7 = E_NODATA;
    else begin
      dma_w(4, DVMA + DATAB + buf_off);
      esp_w(R_TCL, 8'(dlen));
      esp_w(R_TCM, 8'(dlen >> 8));
      dma_w(0, dout ? D_EN : (D_EN | D_WRITE));
      esp_w(R_CMD, C_TI | C_DMA);
      wait_int(got);
      if (!got) begin status = E_TO_DATA; dma_w(0, 0); return; end
      esp_r(R_STAT, st_data);
      esp_r(R_INTR, in);
    end
    // ICCS
    dma_w(0, 0);
    esp_w(R_CMD, C_ICCS);
    if (mode == 2) begin
      esp_r(R_FIFO, sb);
      esp_r(R_FIFO, sb);
      esp_r(R_INTR, in);
      sb = 8'h00;
    end else begin
      wait_int(got);
      if (!got) begin status = E_TO_ICCS; return; end
      esp_r(R_FIFO, sb);
      esp_r(R_FIFO, in);
      esp_r(R_INTR, in);
      if (mode == 1) begin
        esp_w(R_CMD, C_MSGACC);
        wait_int(got);
        if (!got) begin status = E_TO_MSGACC; return; end
        esp_r(R_INTR, in);
      end
    end
    status = l7 != 0 ? l7 : int'(sb);
    dma_w(0, 0);
  endtask

  // esp_init: scsitest.S's (DMA2 reset, chip reset, bus reset, NOP, the
  // interrupt cleared)
  task automatic esp_init();
    logic [7:0] v;
    bit got;
    dma_w(0, D_RESET);
    dma_w(0, 0);
    esp_w(R_CMD, C_RESET);
    esp_w(R_CMD, C_BUSRESET);
    esp_w(R_CMD, C_NOP);
    wait_int(got);
    esp_r(R_INTR, v);
  endtask

  // the DATAB bytes of a READ: n blocks from lba
  function automatic int bad_blocks(input int slot, input int lba, input int n, input int off);
    int bad;
    bad = 0;
    for (int i = 0; i < n * 512; i++)
      if (mem[DATAB + off + i] != img_rd(slot, lba * 512 + i)) bad++;
    return bad;
  endfunction

  // ---------------------------------------------------------------------
  initial begin : main
    logic [31:0] v;
    logic [7:0]  b, b2, in, st;
    int          status, t0, bad;
    bit          got;
    byte unsigned c [$];

    for (int i = 0; i < HD0_BLKS * 512; i++) img0[i] = pat(TAG_HD0, i / 512, i % 512);
    for (int i = 0; i < HD1_BLKS * 512; i++) img1[i] = pat(TAG_HD1, i / 512, i % 512);
    for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
    img_blks[0] = 0; img_blks[1] = 0;
    cycles(10);
    rst = 1'b0;
    cycles(5);
    mount(0, HD0_BLKS);
    mount(1, HD1_BLKS);

    // ================================================================
    // Registers
    dma_r(0, v);    check32(v, 32'hA000_0000, "D_CSR after reset");
    dma_r(16, v);   check32(v, 32'hA000_0000, "E_CSR after reset");
    dma_r(28, v);   check32(v, 32'hFF00_0000, "E_BASE_ADDR after reset");
    dma_r(32, v);   check32(v, 32'hA000_0000, "P_CSR after reset");
    iob(1'b1, 1'b1, 28'h1c, 4'b1000, 32'h12AB_CDEF, v);
    dma_r(28, v);   check32(v, 32'h1200_0000, "E_BASE_ADDR: a byte store at +0x1c");
    iob(1'b1, 1'b1, 28'h1c, 4'b0001, 32'h0000_0034, v);
    dma_r(28, v);   check32(v, 32'h1200_0000, "E_BASE_ADDR: other lanes ignored");
    dma_w(28, 32'hFF00_0000);
    dma_w(4, 32'h1234_5678);
    dma_r(4, v);    check32(v, 32'h1234_5678, "D_ADDR read back");
    dma_r(0, v);    check32(v & 32'h0400_0000, 32'h0400_0000, "D_CSR A_LOADED after a D_ADDR write");
    dma_w(0, D_INTEN | D_WRITE | 32'h0004_0000);
    dma_r(0, v);    check32(v, 32'hA404_0110, "D_CSR stored bits");
    dma_w(0, 0);
    dma_w(8, 32'hFFAB_CDEF);
    dma_r(8, v);    check32(v, 32'h00AB_CDEF, "D_BCNT: 24 bits");
    dma_w(48, 32'h1234_5678);
    dma_r(48, v);   check32(v, 32'h1234_5678, "P_HCR/P_OCR read back");
    dma_r(52, v);   check32(v & 32'h0000_00FF, 32'h0, "P_IR: no printer lines");

    esp_w(R_CFG1, 8'h47);
    esp_r(R_CFG1, b);  check32({24'h0, b}, 32'h47, "ESP CFG1 read back");
    esp_w(R_CFG2, 8'h0A);
    esp_r(R_CFG2, b);  check32({24'h0, b}, 32'h0A, "ESP CFG2 read back (not an ESP100)");
    esp_w(R_CFG3, 8'h18);
    esp_r(R_CFG3, b);  check32({24'h0, b}, 32'h00, "ESP CFG3 absent (an ESP100A)");
    esp_r(R_TCHI, b);  check32({24'h0, b}, 32'h00, "ESP reg E (TCHI/UID) absent");
    esp_w(R_CFG2, 8'h00);
    esp_w(R_CMD, C_FLUSH);
    esp_w(R_FIFO, 8'h11); esp_w(R_FIFO, 8'h22); esp_w(R_FIFO, 8'h33);
    esp_r(R_FFLG, b);  check32({24'h0, b & 8'h1f}, 32'd3, "FIFO flags: 3 bytes");
    esp_r(R_FIFO, b);  esp_r(R_FIFO, b2);
    check(b == 8'h11 && b2 == 8'h22, "FIFO: first in, first out");
    esp_w(R_CMD, C_FLUSH);
    esp_r(R_FFLG, b);  check32({24'h0, b & 8'h1f}, 32'd0, "FIFO: FLUSH empties it");
    esp_w(R_TCL, 8'h34); esp_w(R_TCM, 8'h12);
    esp_w(R_CMD, C_NOP | C_DMA);
    esp_r(R_TCL, b); esp_r(R_TCM, b2);
    check32({16'h0, b2, b}, 32'h1234, "the counter: loaded by NOP|DMA, read back");
    esp_r(R_CMD, b);   check32({24'h0, b}, 32'h80, "the command register reads the last command");
    esp_w(R_CMD, C_TI);
    esp_r(R_INTR, b);  check32({24'h0, b}, {24'h0, I_ILL}, "TI while disconnected: Illegal Command");
    // word access to a byte register
    iob(1'b0, 1'b0, 28'h20, 4'hF, 32'h0, v);
    check32(v, 32'h4747_4747, "ESP: a word read returns the byte in every lane");

    // ================================================================
    // Resets, the bus reset's interrupt, gating
    dma_w(0, D_RESET);
    cycles(1);
    check(esp_rst == 1'b1, "D_RESET drives esp_rst_o");
    esp_r(R_CFG1, b);  check32({24'h0, b}, 32'h00, "D_RESET resets the ESP (CFG1)");
    dma_w(0, 0);
    check(esp_rst == 1'b0, "D_RESET released");
    esp_w(R_CMD, C_BUSRESET);
    cycles(40);
    dma_r(0, v);
    check(v[0] && !irq_esp, "bus reset: INT_PEND, no interrupt with INT_EN clear");
    dma_w(0, D_INTEN);
    cycles(1);
    check(irq_esp, "bus reset: the interrupt with INT_EN");
    esp_r(R_STAT, b);  check(b[7], "STATUS.INT");
    esp_r(R_INTR, b);  check32({24'h0, b}, {24'h0, I_RST}, "INTR: SCSI reset");
    cycles(1);
    check(!irq_esp && !esp_irq, "reading INTR clears the interrupt");
    esp_w(R_CFG1, 8'h47);
    esp_w(R_CMD, C_BUSRESET);
    cycles(40);
    check(!esp_irq, "CFG1 bit 6: the bus reset not reported");
    esp_w(R_CFG1, 8'h07);
    dma_w(0, 0);

    // ================================================================
    // Selection time-out and the ESP-7 hold
    esp_init();
    t0 = int'($time / 10);
    c = '{8'h12, 0, 0, 0, 36, 0}; scsi_cmd(0, c, 36, 0, 1, 0, status, st);
    check32(32'(status), 32'(E_NOTARGET), "t0: no target (Disconnected)");
    check(wi_cycles >= HOLD - 20, $sformatf("ESP-7: a select's interrupt held (%0d cycles)", wi_cycles));

    // INQUIRY at t3 (mode 1), the hold measured from the command
    for (int i = 0; i < 64; i++) mem[DATAB + i] = 8'hEE;
    c = '{8'h12, 0, 0, 0, 36, 0}; scsi_cmd(ID_HD0, c, 36, 0, 1, 0, status, st);
    check32(32'(status), 0, "INQUIRY t3: GOOD");
    check(mem[DATAB] == 8'h00 && mem[DATAB + 2] == 8'h02 && mem[DATAB + 8] == "M" &&
          mem[DATAB + 9] == "i" && mem[DATAB + 13] == "r" && mem[DATAB + 16] == "S",
          "INQUIRY t3: the reply in memory");
    check(mem[DATAB + 35] != 8'hEE && mem[DATAB + 36] == 8'hEE, "INQUIRY t3: 36 bytes, no more");
    check32({29'd0, st[2:0]}, 32'd3, "INQUIRY: STATUS phase after the data");
    check(st[4], "INQUIRY: STATUS.TC after the data");
    dma_r(4, v);    check32(v, DVMA + DATAB + 36, "D_ADDR after 36 bytes");

    // UNIT ATTENTION (the bus reset), then REQUEST SENSE 18 of 255 (DMA-5)
    c = '{8'h00, 0, 0, 0, 0, 0}; scsi_cmd(ID_HD0, c, 0, 0, 1, 0, status, st);
    check32(32'(status), 2, "TUR after the bus reset: CHECK CONDITION");
    for (int i = 0; i < 32; i++) mem[DATAB + i] = 8'hEE;
    c = '{8'h03, 0, 0, 0, 255, 0}; scsi_cmd(ID_HD0, c, 255, 0, 1, 0, status, st);
    check32(32'(status), 0, "REQUEST SENSE: GOOD");
    check(mem[DATAB] == 8'h70 && mem[DATAB + 7] == 8'd10, "REQUEST SENSE: fixed format, length 10");
    check32({28'd0, mem[DATAB + 2][3:0]}, 32'h6, "REQUEST SENSE: UNIT ATTENTION");
    check32({24'd0, mem[DATAB + 12]}, 32'h29, "REQUEST SENSE: ASC 29h");
    check(mem[DATAB + 16] == 8'h00 && mem[DATAB + 17] == 8'h00,
          "DMA-5: bytes 16, 17 (the last partial doubleword) in memory");
    check32({24'd0, mem[DATAB + 18]}, 32'hEE, "DMA-5: byte 18 untouched");
    check(!st[4], "REQUEST SENSE: the counter not at 0 (the target stopped early)");
    dma_r(4, v);    check32(v, DVMA + DATAB + 18, "D_ADDR after 18 bytes");
    c = '{8'h00, 0, 0, 0, 0, 0}; scsi_cmd(ID_HD0, c, 0, 0, 1, 0, status, st);
    check32(32'(status), 0, "TUR: GOOD");

    // READ(10): 4 blocks at lba 5, then 1 block at an unaligned buffer
    for (int i = 0; i < 4 * 512 + 16; i++) mem[DATAB + i] = 8'hEE;
    c = '{8'h28, 0, 0, 0, 0, 5, 0, 0, 4, 0}; scsi_cmd(ID_HD0, c, 4 * 512, 0, 1, 0, status, st);
    check32(32'(status), 0, "READ(10) t3 lba 5 x4: GOOD");
    check32(32'(bad_blocks(0, 5, 4, 0)), 0, "READ(10) t3 lba 5 x4: the data in memory");
    check32({24'd0, mem[DATAB + 2048]}, 32'hEE, "READ(10): nothing past the transfer");
    check32({29'd0, st[2:0]}, 32'd3, "READ(10): the interrupt with STATUS");
    for (int i = 0; i < 520; i++) mem[DATAB + i] = 8'hEE;
    c = '{8'h28, 0, 0, 0, 0, 7, 0, 0, 1, 0}; scsi_cmd(ID_HD1, c, 512, 0, 1, 3, status, st);
    check32(32'(status), 32'(E_NODATA), "READ(10) t1: UNIT ATTENTION first (STATUS, no data phase)");
    c = '{8'h28, 0, 0, 0, 0, 7, 0, 0, 1, 0}; scsi_cmd(ID_HD1, c, 512, 0, 1, 3, status, st);
    check32(32'(status), 0, "READ(10) t1 lba 7, buffer +3: GOOD");
    check32(32'(bad_blocks(1, 7, 1, 3)), 0, "READ(10) t1, unaligned: the data");
    check(mem[DATAB] == 8'hEE && mem[DATAB + 2] == 8'hEE && mem[DATAB + 515] == 8'hEE,
          "READ(10), unaligned: the bytes around it untouched");

    // WRITE(10): block 9's content to block 8, the read-back
    for (int i = 0; i < 512; i++) mem[DATAB + i] = img0[9 * 512 + i];
    c = '{8'h2a, 0, 0, 0, 0, 8, 0, 0, 1, 0}; scsi_cmd(ID_HD0, c, 512, 1, 1, 0, status, st);
    check32(32'(status), 0, "WRITE(10) t3 lba 8: GOOD");
    check32({29'd0, st[2:0]}, 32'd3, "WRITE(10): the data phase's interrupt with STATUS");
    bad = 0;
    for (int i = 0; i < 512; i++) if (img0[8 * 512 + i] != pat(TAG_HD0, 9, i)) bad++;
    check32(32'(bad), 0, "WRITE(10): the image holds the block");
    for (int i = 0; i < 512; i++) mem[DATAB + i] = 8'h00;
    c = '{8'h28, 0, 0, 0, 0, 8, 0, 0, 1, 0}; scsi_cmd(ID_HD0, c, 512, 0, 1, 0, status, st);
    bad = 0;
    for (int i = 0; i < 512; i++) if (mem[DATAB + i] != pat(TAG_HD0, 9, i)) bad++;
    check(status == 0 && bad == 0, "WRITE(10): read back");
    for (int i = 0; i < 512; i++) mem[DATAB + i] = pat(TAG_HD0, 8, i);
    c = '{8'h2a, 0, 0, 0, 0, 8, 0, 0, 1, 0}; scsi_cmd(ID_HD0, c, 512, 1, 1, 0, status, st);
    bad = 0;
    for (int i = 0; i < 512; i++) if (img0[8 * 512 + i] != pat(TAG_HD0, 8, i)) bad++;
    check(status == 0 && bad == 0, "WRITE(10): block 8 restored");

    // ================================================================
    // Mode 0 (OpenBIOS: TUR leaves the target in STATUS) and mode 2
    c = '{8'h00, 0, 0, 0, 0, 0}; scsi_cmd(ID_HD0, c, 0, 0, 0, 0, status, st);
    check32(32'(status), 0, "mode 0: TUR (status not read)");
    c = '{8'h00, 0, 0, 0, 0, 0}; scsi_cmd(ID_HD1, c, 0, 0, 0, 0, status, st);
    check32(32'(status), 0, "mode 0: TUR at t1 with t3 left in STATUS");
    c = '{8'h00, 0, 0, 0, 0, 0}; scsi_cmd(ID_HD1, c, 0, 0, 0, 0, status, st);
    for (int i = 0; i < 36; i++) mem[DATAB + i] = 8'hEE;
    c = '{8'h12, 0, 0, 0, 36, 0}; scsi_cmd(ID_HD1, c, 36, 0, 0, 0, status, st);
    check(status == 0 && mem[DATAB + 8] == "M", "mode 0: INQUIRY after TURs without ICCS");
    c = '{8'h25, 0, 0, 0, 0, 0, 0, 0, 0, 0}; scsi_cmd(ID_HD0, c, 8, 0, 0, 0, status, st);
    check(status == 0 && {mem[DATAB], mem[DATAB + 1], mem[DATAB + 2], mem[DATAB + 3]} == 32'(HD0_BLKS - 1) &&
          {mem[DATAB + 4], mem[DATAB + 5], mem[DATAB + 6], mem[DATAB + 7]} == 32'd512,
          "mode 0: READ CAPACITY");

    // mode 2 with the bus reset's interrupt left pending (scsitest
    // t_scsi_probe2: OpenBIOS's ob_esp_init)
    esp_init();
    esp_w(R_CMD, C_BUSRESET);
    esp_w(R_CMD, C_NOP);
    cycles(40);
    c = '{8'h12, 0, 0, 0, 36, 0}; scsi_cmd(0, c, 36, 0, 2, 0, status, st);
    check32(32'(status), 32'(E_NOTARGET), "mode 2: t0 absent, with the bus reset's interrupt pending");
    c = '{8'h12, 0, 0, 0, 36, 0}; scsi_cmd(ID_HD0, c, 36, 0, 2, 0, status, st);
    check32(32'(status), 0, "mode 2: INQUIRY t3");
    c = '{8'h00, 0, 0, 0, 0, 0}; scsi_cmd(ID_HD0, c, 0, 0, 2, 0, status, st);   // the UNIT ATTENTION goes
    for (int lba = 0; lba < 6; lba++) begin
      for (int i = 0; i < 512; i++) mem[DATAB + i] = 8'hEE;
      c = '{8'h28, 0, 0, 0, 0, 8'(lba), 0, 0, 1, 0}; scsi_cmd(ID_HD0, c, 512, 0, 2, 0, status, st);
      check(status == 0 && bad_blocks(0, lba, 1, 0) == 0, $sformatf("mode 2: READ(10) t3 lba %0d", lba));
    end

    // ================================================================
    // ESP-8: the esp driver's SDTR, the reply byte by byte (scsitest
    // t_scsi_sdtr1), then a queue tag (t_scsi_tag1)
    dma_w(0, 0);
    esp_w(R_STAT, 8'(ID_HD0));
    esp_w(R_CMD, C_FLUSH);
    esp_w(R_FIFO, 8'hC0);
    esp_go(C_SELATNS, in, st);
    check((in & I_DC) == 0 && (in & (I_FC | I_BS)) == (I_FC | I_BS), "SELATNS: selected, FC|BS");
    check32({29'd0, st[2:0]}, 32'd6, "SELATNS: stopped in MESSAGE OUT");
    esp_r(R_SEQ, b);   // cleared by the INTR read
    c = '{8'h01, 8'h03, 8'h01, 8'h19, 8'h0f};
    foreach (c[i]) esp_w(R_FIFO, c[i]);
    esp_go(C_TI, in, st);
    check32({29'd0, st[2:0]}, 32'd7, "SDTR sent: the target answers in MESSAGE IN");
    c = '{8'h01, 8'h03, 8'h01, 8'h19, 8'h00};
    for (int i = 0; i < 5; i++) begin
      esp_go(C_TI, in, st);
      check32({24'd0, in}, {24'd0, I_FC}, $sformatf("SDTR reply byte %0d: Function Complete", i));
      // ACK held until MESSAGE ACCEPTED: still MESSAGE IN, even after the
      // last byte (Solaris's esp driver under OBP waits otherwise)
      check32({29'd0, st[2:0]}, 32'd7, $sformatf("SDTR reply byte %0d: the phase, ACK held", i));
      esp_r(R_FIFO, b);
      check32({24'd0, b}, {24'd0, c[i]}, $sformatf("SDTR reply byte %0d", i));
      esp_go(C_MSGACC, in, st);
      check32({24'd0, in}, {24'd0, I_BS}, $sformatf("ESP-8: MESSAGE ACCEPTED %0d: Bus Service", i));
      check32({29'd0, st[2:0]}, i == 4 ? 32'd2 : 32'd7, $sformatf("after MESSAGE ACCEPTED %0d: the phase", i));
    end
    // ESP-9: NeXTSTEP's sc driver sends the first CDB bytes one per TI,
    // each written to the FIFO after the command: the TI waits for it
    c = '{8'h12, 0, 0, 0, 36, 0};
    for (int i = 0; i < 3; i++) begin
      esp_w(R_CMD, C_FLUSH);
      esp_w(R_CMD, C_TI);
      cycles(200);
      esp_r(R_STAT, st);
      check(st[7] == 1'b0, $sformatf("ESP-9: TI with an empty FIFO waits (byte %0d)", i));
      esp_w(R_FIFO, c[i]);
      wait_int(got);
      esp_r(R_STAT, st);
      esp_r(R_INTR, in);
      check32({24'd0, in}, {24'd0, I_BS}, $sformatf("ESP-9: CDB byte %0d sent: Bus Service", i));
      check32({29'd0, st[2:0]}, 32'd2, $sformatf("ESP-9: after CDB byte %0d: still COMMAND", i));
    end
    for (int i = 3; i < 6; i++) esp_w(R_FIFO, c[i]);
    esp_go(C_TI, in, st);
    check32({29'd0, st[2:0]}, 32'd1, "the CDB by TI: DATA IN");
    for (int i = 0; i < 40; i++) mem[DATAB + i] = 8'hEE;
    dma_w(4, DVMA + DATAB);
    esp_w(R_TCL, 8'd36); esp_w(R_TCM, 8'd0);
    dma_w(0, D_EN | D_WRITE);
    esp_go(C_TI | C_DMA, in, st);
    check32({29'd0, st[2:0]}, 32'd3, "INQUIRY by DMA TI: STATUS");
    dma_w(0, 0);
    esp_go(C_ICCS, in, st);
    check32({24'd0, in}, {24'd0, I_FC}, "ICCS: Function Complete");
    esp_r(R_FIFO, b); esp_r(R_FIFO, b2);
    check(b == 8'h00 && b2 == 8'h00, "ICCS: GOOD, COMMAND COMPLETE");
    esp_go(C_MSGACC, in, st);
    check32({24'd0, in}, {24'd0, I_DC}, "MESSAGE ACCEPTED after COMMAND COMPLETE: Disconnected");
    check(mem[DATAB] == 8'h00 && mem[DATAB + 8] == "M" && mem[DATAB + 36] == 8'hEE, "INQUIRY after SDTR: in memory");

    esp_w(R_CMD, C_FLUSH);
    esp_w(R_FIFO, 8'hC0);
    esp_go(C_SELATNS, in, st);
    check32({29'd0, st[2:0]}, 32'd6, "tag: SELATNS in MESSAGE OUT");
    esp_w(R_FIFO, 8'h20); esp_w(R_FIFO, 8'h05);
    esp_go(C_TI, in, st);
    check32({29'd0, st[2:0]}, 32'd2, "tag: SIMPLE QUEUE TAG taken, COMMAND next");
    c = '{8'h00, 0, 0, 0, 0, 0};
    foreach (c[i]) esp_w(R_FIFO, c[i]);
    esp_go(C_TI, in, st);
    check32({29'd0, st[2:0]}, 32'd3, "tag: TUR, STATUS");
    esp_go(C_ICCS, in, st);
    esp_r(R_FIFO, b); esp_r(R_FIFO, b2);
    check(in == I_FC && b == 8'h00, "tag: ICCS GOOD");
    esp_go(C_MSGACC, in, st);
    check32({24'd0, in}, {24'd0, I_DC}, "tag: Disconnected");

    // ================================================================
    // SELATN3 (IDENTIFY + a queue tag from the FIFO), TRANSFER PAD,
    // ABORT, DISSEL
    esp_w(R_CMD, C_FLUSH);
    c = '{8'h80, 8'h20, 8'h07, 8'h12, 0, 0, 0, 36, 0};
    foreach (c[i]) esp_w(R_FIFO, c[i]);
    esp_w(R_CMD, 8'h46);
    wait_int(got);
    esp_r(R_STAT, st);
    esp_r(R_SEQ, b);
    esp_r(R_INTR, in);
    check(in == (I_FC | I_BS) && b[2:0] == 3'd4, "SELATN3: Function Complete, Bus Service, step 4");
    check32({29'd0, st[2:0]}, 32'd1, "SELATN3: INQUIRY's DATA IN");
    esp_w(R_TCL, 8'd36); esp_w(R_TCM, 8'd0);
    esp_go(C_DMA | 8'h18, in, st);
    check(in == I_BS && st[2:0] == 3'd3 && st[4], "TRANSFER PAD: 36 bytes discarded, STATUS, TC");
    esp_r(R_FFLG, b);
    check32({27'd0, b[4:0]}, 32'd0, "TRANSFER PAD: nothing in the FIFO");
    esp_go(C_ICCS, in, st);
    esp_r(R_FIFO, b); esp_r(R_FIFO, b2);
    esp_go(C_MSGACC, in, st);
    check(b == 8'h00 && in == I_DC, "after the pad: GOOD, Disconnected");

    esp_w(R_CMD, C_FLUSH);
    esp_w(R_FIFO, 8'hC0);
    esp_go(C_SELATNS, in, st);
    esp_w(R_FIFO, 8'h06);
    esp_go(C_TI, in, st);
    check32({24'd0, in}, {24'd0, I_DC}, "ABORT: the target leaves (Disconnected)");
    esp_w(R_CMD, 8'h45);
    esp_r(R_INTR, in);
    check32({24'd0, in}, {24'd0, I_FC}, "DISSEL: Function Complete");
    for (int i = 0; i < 36; i++) mem[DATAB + i] = 8'hEE;
    c = '{8'h12, 0, 0, 0, 36, 0}; scsi_cmd(ID_HD0, c, 36, 0, 1, 0, status, st);
    check(status == 0 && mem[DATAB + 8] == "M", "after ABORT: INQUIRY");

    // ================================================================
    // A DVMA error: ERR_PEND, the interrupt, INVALIDATE
    mem[CMDB] = 8'h80;
    c = '{8'h12, 0, 0, 0, 36, 0};
    foreach (c[i]) mem[CMDB + 1 + i] = c[i];
    esp_w(R_STAT, 8'(ID_HD0));
    esp_w(R_TCL, 8'd7); esp_w(R_TCM, 8'd0);
    dma_w(4, DVMA + CMDB);
    dma_w(0, D_EN);
    esp_go(C_SELATN | C_DMA, in, st);
    check32({29'd0, st[2:0]}, 32'd1, "error case: selected, DATA IN");
    dma_w(4, 32'h0012_0000);                       // no memory there
    esp_w(R_TCL, 8'd36); esp_w(R_TCM, 8'd0);
    dma_w(0, D_EN | D_WRITE | D_INTEN);
    esp_w(R_CMD, C_TI | C_DMA);
    t0 = 0;
    do begin dma_r(0, v); t0++; end while (!v[1] && t0 < 2000);
    check(v[1], "DVMA error: ERR_PEND");
    check(irq_esp, "DVMA error: the interrupt");
    dma_w(0, D_INVAL | D_INTEN);
    dma_r(0, v);
    check(!v[1], "INVALIDATE clears ERR_PEND");
    dma_w(0, 0);
    esp_init();                                    // recover the ESP and the bus
    c = '{8'h00, 0, 0, 0, 0, 0}; scsi_cmd(ID_HD0, c, 0, 0, 1, 0, status, st);
    c = '{8'h12, 0, 0, 0, 36, 0}; scsi_cmd(ID_HD0, c, 36, 0, 1, 0, status, st);
    check(status == 0 && mem[DATAB + 8] == "M", "after the error and a reset: INQUIRY");

    // ================================================================
    // ledma
    le_req = '{valid: 1'b1, write: 1'b0, burst: 1'b0, va: 32'hAB12_3456, be: 8'hFF, wdata: '0};
    cycles(1);
    check32(le_dvma.va, 32'hFF12_3456, "ledma: va[31:24] from E_BASE_ADDR (0xFF)");
    t0 = 0;
    while (!le_rsp.ack && t0 < 100) begin cycles(1); t0++; end
    check(le_rsp.ack && le_rsp.rdata == {32'hFF12_3456, ~32'hFF12_3456}, "ledma: the answer comes back");
    le_req = DVMA_REQ_IDLE;
    cycles(2);
    dma_r(20, v);   check32(v, 32'h0012_3456, "E_TST_CSR: the LANCE's address");
    dma_w(28, 32'h1200_0000);
    le_req = '{valid: 1'b1, write: 1'b1, burst: 1'b1, va: 32'h0000_0100, be: 8'hFF, wdata: 64'h1};
    cycles(1);
    check(le_dvma.va == 32'h1200_0100 && le_dvma.write && le_dvma.burst, "ledma: E_BASE_ADDR 0x12, the request's fields");
    while (!le_rsp.ack) cycles(1);
    le_req = DVMA_REQ_IDLE;
    le_irq = 1'b1;
    cycles(1);
    dma_r(16, v);
    check(v[0] && !irq_le, "E_CSR INT_PEND follows the LANCE ungated; no interrupt without E_INT_EN");
    dma_w(16, 32'h10);
    cycles(1);
    check(irq_le, "irq_le_o with E_INT_EN");
    le_irq = 1'b0;
    cycles(1);
    check(!irq_le, "irq_le_o follows the LANCE");
    dma_w(28, 32'h6600_0000);
    le_req = '{valid: 1'b1, write: 1'b0, burst: 1'b0, va: 32'h0000_0200, be: 8'hFF, wdata: '0};
    while (!le_rsp.ack) cycles(1);
    check(le_rsp.err, "ledma: an error comes back");
    le_req = DVMA_REQ_IDLE;
    cycles(1);
    dma_r(16, v);
    check(v[1] && irq_le, "E_ERR_PEND and the interrupt");
    dma_w(16, 32'h30);
    dma_r(16, v);
    check(!v[1], "E_INVALIDATE clears E_ERR_PEND");
    dma_w(16, 32'h80);
    cycles(1);
    check(le_rst, "E_RESET drives le_rst_o");
    dma_w(16, 0);
    dma_w(28, 32'hFF00_0000);

    // SLAVE_ERR: a byte write to a word-only register is dropped with an
    // error ack (OBP 2.25's POST, DMA2/MACIO register tests)
    begin
      logic [31:0] d;
      dma_w(0, 32'h80); dma_w(0, 0);
      iob(1'b1, 1'b1, 28'd0, 4'b1000, 32'h8000_0000, d);
      check(iob_err, "D_CSR byte write: error ack");
      dma_r(0, v);
      check32(v & ~32'hC, 32'hA000_0040, "D_CSR: dropped, SLAVE_ERR");
      dma_w(0, 32'h40);
      dma_r(0, v);
      check32(v & ~32'hC, 32'hA000_0000, "SLAVE_ERR: write 1 clears");
      iob(1'b1, 1'b1, 28'd4, 4'b0001, 32'h0000_0055, d);
      check(iob_err, "D_ADDR byte write: error ack");
      dma_r(0, v);
      check32(v & ~32'hC, 32'hA000_0040, "D_ADDR byte write: SLAVE_ERR, A_LOADED clear");
      dma_w(0, 32'h80);
      dma_r(0, v);
      check32(v & ~32'hC, 32'hA000_0080, "RESET clears SLAVE_ERR");
      dma_w(0, 0);
      iob(1'b1, 1'b1, 28'd16, 4'b1000, 32'h0, d);
      check(iob_err, "E_CSR byte write: error ack");
      dma_r(16, v);
      check32(v & ~32'hC, 32'hA000_0040, "E_CSR: SLAVE_ERR");
      dma_w(16, 32'h40);
      dma_r(16, v);
      check32(v & ~32'hC, 32'hA000_0000, "E_CSR SLAVE_ERR cleared");
      le_serr = 1'b1; cycles(1); le_serr = 1'b0; cycles(1);
      dma_r(16, v);
      check32(v & ~32'hC, 32'hA000_0040, "a LANCE size error sets E_CSR SLAVE_ERR");
      dma_w(16, 32'h40);
      iob(1'b1, 1'b1, 28'd28, 4'b1000, 32'hFF00_0000, d);
      check(!iob_err, "E_BASE_ADDR takes a byte");
    end

    check32(32'(m_proto), 0, "DVMA protocol: single beats, fields held to the ack");
    check32(32'(iob_to), 0, "iobus: every access answered");
    $display("     (%0d DVMA beats, %0d writes, %0d errors)", m_beats, m_wbeats, m_errs);
    tb_done("tb_espdma");
  end

  initial begin
    #500_000_000;
    $display("FAIL tb_espdma: global time-out");
    $fatal(1, "time-out");
  end

endmodule
