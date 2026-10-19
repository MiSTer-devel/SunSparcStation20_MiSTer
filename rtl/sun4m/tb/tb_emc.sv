// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_emc: the SMC register file (reset values, write masks, read-only
// registers, byte enables, the message bytes, unassigned offsets) and the
// ECC model, with OBP 2.25's three POST injections (post-tests.md §7):
// two uncorrectable errors on partial writes, two correctable errors on
// loads, a correctable then an uncorrectable one; the expected EFSR/EFAR
// values are the POST's.

module tb_emc;
  import iobus_pkg::*;
  import mem_pkg::*;
  import tb_pkg::*;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  iob_req_t req = IOB_REQ_IDLE;
  iob_rsp_t rsp;
  logic     mv = 1'b0;
  mem_req_t mr = '0;
  logic     irq;

  logic [3:0]      fix_v;
  logic [3:0][5:0] fix_bit;
  emc #(.IRQ_DELAY(8)) dut (.clk, .rst, .bus_i(req), .bus_o(rsp),
    .mem_v_i(mv), .mem_req_i(mr), .mem_mid_i(4'h8), .fix_v_o(fix_v), .fix_bit_o(fix_bit), .irq_o(irq));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic acc(input bit we, input int off, input logic [3:0] be, input logic [31:0] wd,
                     output logic [31:0] d);
    int t;
    req.req = 1; req.we = we; req.addr = 28'(off); req.be = be; req.wdata = wd; req.pair = 0;
    t = 0;
    do begin cycles(1); t++; end while (!rsp.ack && t < 20);
    check(rsp.ack && !rsp.err, "acked");
    d = rsp.rdata;
    req.req = 0; req.we = 0;
    cycles(1);
    check(!rsp.ack, "one ack");
  endtask

  task automatic ck32(input int off, input logic [31:0] exp, input string what);
    logic [31:0] d;
    acc(1'b0, off, 4'hF, 32'd0, d);
    check32(d, exp, what);
  endtask
  task automatic wr32(input int off, input logic [31:0] v);
    logic [31:0] d;
    acc(1'b1, off, 4'hF, v, d);
  endtask
  task automatic wrb(input int off, input logic [7:0] v);
    logic [31:0] d;
    acc(1'b1, off, 4'b1000 >> (off & 3), {4{v}}, d);
  endtask
  task automatic ckb(input int off, input logic [7:0] exp, input string what);
    logic [31:0] d;
    acc(1'b0, off, 4'b1000 >> (off & 3), 32'd0, d);
    check32(32'(8'(d >> (8 * (3 - (off & 3))))), 32'(exp), what);
  endtask

  // a memory access as the memory controller accepts it (one pulse)
  task automatic mem(input bit we, input logic [35:0] pa, input logic [7:0] be, input logic [63:0] wd);
    mr = '0;
    mr.valid = 1'b1; mr.write = we; mr.pa = {pa[35:3], 3'b000}; mr.be = be; mr.wdata = wd;
    mv = 1'b1;
    cycles(1);
    mv = 1'b0; mr.valid = 1'b0;
    cycles(1);
  endtask

  localparam int MER = 'h0, MDR = 'h4, EFSR = 'h8, VCR = 'hC, EFAR0 = 'h10, EFAR1 = 'h14, DR = 'h18;
  localparam logic [31:0] DEF = 32'h2000_03FC;

  // the POST's level-15 handler, as far as the EMC sees it
  task automatic handler(input logic [31:0] efsr, input logic [31:0] efar0, input logic [31:0] efar1,
                         input bit check_efar0, input string what);
    int t;
    t = 0;
    while (!irq && t < 100) begin cycles(1); t++; end
    check(irq, {what, ": MEM_ERR"});
    wr32(MER, DEF);                      // EE off
    ck32(EFSR, efsr, {what, ": EFSR"});
    if (check_efar0) ck32(EFAR0, efar0, {what, ": EFAR0"});
    ck32(EFAR1, efar1, {what, ": EFAR1"});
    wr32(EFSR, 0);
    ck32(EFSR, 0, {what, ": EFSR cleared"});
    cycles(2);
    check(!irq, {what, ": MEM_ERR released"});
  endtask

  initial begin
    cycles(3); rst = 0; cycles(2);
    // ---- the POST's EMC/SMC Control Regs Tests
    ck32(MER, DEF, "MER: SMC, every slot refreshed");
    wr32(MER, DEF); ck32(MER, DEF, "MER written back");
    wr32(MER, 0); ck32(MER, 32'h2000_0000, "MER 0, IMPL/VER read-only");
    wr32(MER, 32'hFFFF_FFFF); ck32(MER, 32'h2000_0BFF, "MER mask");
    wr32(MER, DEF);
    ck32(MDR, 32'h20, "MDR reset");
    wr32(MDR, 32'hFFDF); ck32(MDR, 32'hFFDF, "MDR as written");
    wr32(MDR, 32'hFFFF_FFFF); ck32(MDR, 32'h7FFF_FFFF, "MDR bit 31 reads 0");
    wr32(MDR, 32'h20);
    ck32(VCR, 0, "VCR reset");
    wr32(VCR, 32'hFF00); ck32(VCR, 32'hFF00, "VCR");
    wr32(VCR, 0); ck32(VCR, 0, "VCR 0");
    ck32(EFSR, 0, "EFSR reset");
    ck32(DR, 0, "DR reset");
    wr32(DR, 32'h4FF); ck32(DR, 32'h4FF, "DR");
    wr32(DR, 0);
    ck32(EFAR0, 32'h07C0_0000, "EFAR0 reset");
    wr32(EFAR0, 32'hFFFF_FFFF); ck32(EFAR0, 32'h07C0_0000, "EFAR0 read-only");
    wr32(32'h1C, 32'h11); wr32(32'h20, 32'h22);
    ck32(32'h1C, 32'h11, "ECR0"); ck32(32'h20, 32'h22, "ECR1");
    wrb(32'h0E, 8'hAA); ck32(VCR, 32'h0000_AA00, "VCR byte 2");
    wr32(VCR, 0);
    wrb(32'h1000, 8'h01); wrb(32'h1001, 8'h02); wrb(32'h1002, 8'h03); wrb(32'h1003, 8'h04);
    ckb(32'h1002, 8'h03, "message byte 2");
    ck32(32'h1000, 32'h0102_0304, "message bytes");
    wr32(32'h40, 32'hFFFF_FFFF); ck32(32'h40, 0, "unassigned reads 0");
    ck32(32'h24, 0, "past ECR1 reads 0");

    // ---- no checking without injected words, nor with EE off
    wr32(MER, DEF | 3);
    mem(1'b1, 36'h50_3000, 8'hC0, 64'h1234_0000_0000_0000);
    mem(1'b0, 36'h50_3000, 8'hFF, 64'h0);
    cycles(12);
    check(!irq, "clean memory: no error");
    ck32(EFSR, 0, "clean memory: EFSR 0");
    wr32(MER, DEF);

    // The POST's three ECC tests, each a loop over fp = 0, 8, run by each
    // CPU in turn (CPU 0 then CPU 1). Each test first rewrites its area
    // (mem_quick_check, DR = 0); the CE words its reads found stay bad, so
    // CPU 1 injects with several of CPU 0's still live.
    for (int cpu = 0; cpu < 2; cpu++) begin
      // ---- ECC Multiple UE Test
      for (int q = 0; q < 8; q++) mem(1'b1, 36'h50_32C0 + 36'(8 * q), 8'hFF, 64'h0);
      for (int fp = 0; fp <= 8; fp += 8) begin
        wr32(DR, 32'h400);
        mem(1'b1, 36'h50_32C0 + 36'(fp), 8'hFF, 64'hD5A5_A5A5_A5A5_A5A5);
        mem(1'b1, 36'h50_32E0 + 36'(fp), 8'hFF, 64'hA5A5_A5A5_55A5_A5A6);
        wr32(DR, 0); wr32(EFSR, 0);
        wr32(MER, DEF | 1);
        mem(1'b1, 36'h50_32C0 + 36'(fp), 8'hC0, 64'h0);       // stha
        mem(1'b1, 36'h50_32E0 + 36'(fp), 8'h80, 64'h0);       // stba
        handler(32'h0001_D008, 32'h8FFF_C100, 32'h50_32C0 + fp, 1'b1, "UE");
        wr32(MER, DEF);
      end

      // ---- ECC Multiple CE Test
      for (int q = 0; q < 8; q++) mem(1'b1, 36'h50_3B20 + 36'(8 * q), 8'hFF, 64'h0);
      for (int fp = 0; fp <= 8; fp += 8) begin
        wr32(DR, 32'h400);
        mem(1'b1, 36'h50_3B20 + 36'(fp), 8'hFF, 64'h8000_0000_0000_0000);
        mem(1'b1, 36'h50_3B40 + 36'(fp), 8'hFF, 64'hFFFF_FFFF_FFFF_FFFE);
        wr32(DR, 0); wr32(EFSR, 0);
        wr32(MER, DEF | 3);
        mem(1'b0, 36'h50_3B20 + 36'(fp), 8'hFF, 64'h0);       // ldda
        mem(1'b0, 36'h50_3B40 + 36'(fp), 8'hFF, 64'h0);
        handler(32'h0001_8501, 32'h8FFF_C310, 32'h50_3B20 + fp, 1'b1, "CE");
        wr32(MER, DEF);
      end

      // ---- ECC Multiple CE, UE Test
      for (int q = 0; q < 64; q++) mem(1'b1, 36'h50_3300 + 36'(8 * q), 8'hFF, 64'h0);
      for (int fp = 0; fp <= 8; fp += 8) begin
        wr32(DR, 32'h400);
        mem(1'b1, 36'h50_3300 + 36'(fp), 8'hFF, 64'hFFFF_FFFF_FFBF_FFFF);
        mem(1'b1, 36'h50_34E0 + 36'(fp), 8'hFF, 64'hA5A5_A555_A5A5_A5A5);
        wr32(DR, 0); wr32(EFSR, 0);
        wr32(MER, DEF | 1);
        mem(1'b0, 36'h50_3300 + 36'(fp), 8'hFF, 64'h0);       // ldda: CE, EI off: no interrupt
        cycles(12);
        check(!irq, "CE with EI off: no interrupt");
        mem(1'b1, 36'h50_34E0 + 36'(fp), 8'h80, 64'h0);       // stba: UE
        handler(32'h0001_A509, 32'h8FFF_C000, 32'h50_34E0 + fp, 1'b1, "CE,UE");
        wr32(MER, DEF);
      end
    end

    // a bad word stays bad until a whole write; a burst finds it, with DW
    wr32(MER, DEF | 3);
    mem(1'b1, 36'h50_3B20, 8'hFF, 64'h0);
    mem(1'b0, 36'h50_3B20, 8'hFF, 64'h0);
    cycles(12);
    check(!irq, "rewritten word: no error");
    wr32(DR, 32'h400);
    mem(1'b1, 36'h70_0018, 8'hFF, 64'h8000_0000_0000_0000);
    wr32(DR, 0);
    mr = '0; mr.valid = 1'b1; mr.burst = 1'b1; mr.pa = 36'h70_0000; mr.be = 8'hFF;
    mv = 1'b1; cycles(1); mv = 1'b0; cycles(1);
    check32(32'(fix_v), 32'b1000, "burst: beat 3 corrected");
    check32(32'(fix_bit[3]), 63, "burst: bit 63");
    handler(32'h0000_8531, 32'h8FFF_C510, 32'h70_0000, 1'b1, "CE in a burst");
    wr32(MER, DEF);

    // FPU DP CE Trap Priority: with EE (EI off) a load returns corrected
    // data, without an interrupt; with EE off, the raw data
    wr32(DR, 32'h400);
    mem(1'b1, 36'h50_3260, 8'hFF, 64'h0000_0008_0000_0000);
    wr32(DR, 0); wr32(EFSR, 0);
    wr32(MER, DEF | 1);
    mem(1'b0, 36'h50_3260, 8'hFF, 64'h0);
    check32(32'(fix_v), 32'b0001, "CE load: corrected");
    check32(32'(fix_bit[0]), 35, "CE load: bit 35");
    cycles(12);
    check(!irq, "CE load, EI off: no interrupt");
    ck32(EFSR, 32'h0000_8C01, "CE load: EFSR (syndrome of bit 35)");
    wr32(MER, DEF);
    mem(1'b0, 36'h50_3260, 8'hFF, 64'h0);
    check32(32'(fix_v), 0, "EE off: raw data");
    mem(1'b1, 36'h50_3260, 8'hFF, 64'h0);
    wr32(EFSR, 0);

    // reset
    rst = 1; cycles(2); rst = 0; cycles(1);
    ck32(MER, DEF, "MER after reset");
    ck32(MDR, 32'h20, "MDR after reset");
    tb_done("tb_emc");
  end

endmodule
