// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_fdc82077: the 82077AA with no drive. Reproduces t_fdc of
// tests/cpu/src/t_chipset.S (reset interrupt and its four SENSE INTERRUPT
// STATUS results, VERSION, RECALIBRATE -> 0x71) and exercises the other
// commands against the 82077AA datasheet and QEMU hw/block/fdc.c.

module tb_fdc82077;
  import iobus_pkg::*;
  import tb_pkg::*;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  iob_req_t req = IOB_REQ_IDLE;
  iob_rsp_t rsp;
  logic     irq;

  fdc82077 dut (.clk, .rst, .bus_i(req), .bus_o(rsp), .tc_i(1'b0), .irq_o(irq));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  // byte accesses, big-endian lane of the register
  task automatic wr(input int off, input logic [7:0] d);
    int t;
    req.req = 1; req.we = 1; req.addr = 28'(off); req.pair = 0;
    req.be = 4'b1000 >> (off & 3);
    req.wdata = {24'b0, d} << (8 * (3 - (off & 3)));
    t = 0;
    do begin cycles(1); t++; end while (!rsp.ack && t < 20);
    check(rsp.ack && !rsp.err, "write acked");
    req.req = 0; req.we = 0;
    cycles(1);
  endtask

  task automatic rd(input int off, output logic [7:0] d);
    int t;
    req.req = 1; req.we = 0; req.addr = 28'(off); req.pair = 0;
    req.be = 4'b1000 >> (off & 3);
    t = 0;
    do begin cycles(1); t++; end while (!rsp.ack && t < 20);
    check(rsp.ack && !rsp.err, "read acked");
    d = 8'(rsp.rdata >> (8 * (3 - (off & 3))));
    req.req = 0;
    cycles(1);
  endtask

  localparam int DOR = 2, TDR = 3, MSR = 4, DSR = 4, FIFO = 5, DIR = 7, CCR = 7;

  logic [7:0] v;

  // as fdc_put/fdc_get of t_chipset.S
  task automatic put(input logic [7:0] d);
    rd(MSR, v);
    check((v & 8'hc0) == 8'h80, "put: RQM, !DIO");
    wr(FIFO, d);
  endtask
  task automatic get(output logic [7:0] d);
    rd(MSR, v);
    check((v & 8'hc0) == 8'hc0, "get: RQM, DIO");
    rd(FIFO, d);
  endtask
  task automatic idle_check(input string what);
    rd(MSR, v);
    check32(32'(v), 32'h80, {what, ": back to the command phase"});
  endtask

  logic [7:0] b [16];

  task automatic sense_int(output logic [7:0] st0, output logic [7:0] pcn);
    put(8'h08); get(st0); get(pcn);
  endtask

  initial begin
    logic [7:0] st0, pcn;
    cycles(4);
    rst = 0;
    cycles(2);

    // ---- power-on: held in reset ------------------------------------------
    rd(DOR, v);  check32(32'(v), 32'h00, "DOR at power-on");
    rd(MSR, v);  check32(32'(v), 32'h00, "MSR in reset");
    check(!irq, "no interrupt at power-on");
    wr(FIFO, 8'h10);                       // ignored in reset
    wr(TDR, 8'h03);
    rd(TDR, v);  check32(32'(v), 32'h00, "TDR write ignored in reset");

    // ---- t_fdc: leave reset ---------------------------------------------------
    wr(DOR, 8'h0c);
    check(irq, "polling interrupt after leaving reset");
    rd(0, v);    check32(32'(v), 32'hc0, "SRA: INT pending, no drive 2");
    rd(DOR, v);  check32(32'(v), 32'h0c, "DOR reads back");
    for (int d = 0; d < 4; d++) begin
      sense_int(st0, pcn);
      check32(32'(st0), 32'hc0 + d, $sformatf("reset SENSE INT %0d ST0", d));
      check32(32'(pcn), 32'h00, $sformatf("reset SENSE INT %0d PCN", d));
      if (d == 0) check(!irq, "INT cleared by the first SENSE INTERRUPT");
    end
    put(8'h08); get(st0);
    check32(32'(st0), 32'h80, "nothing pending: invalid");
    rd(MSR, v);  check32(32'(v), 32'h80, "one result byte only");
    put(8'h10); get(st0);
    check32(32'(st0), 32'h90, "VERSION");
    idle_check("VERSION");

    // RECALIBRATE drive 1; the interrupt is up before a CPU load could ask
    put(8'h07); put(8'h01);
    cycles(1);
    check(irq, "RECALIBRATE interrupt");
    rd(0, v);    check32(32'(v), 32'hc0, "SRA INT pending");
    sense_int(st0, pcn);
    check32(32'(st0), 32'h71, "RECALIBRATE: abnormal, SE, EC, drive 1");
    check32(32'(pcn), 32'h00, "RECALIBRATE PCN");
    check(!irq, "INT cleared by SENSE INTERRUPT");

    // ---- SEEK / RELATIVE SEEK --------------------------------------------------
    put(8'h0f); put(8'h02);
    rd(MSR, v);  check32(32'(v), 32'h90, "MSR with a parameter outstanding: RQM, CB");
    put(8'd17);
    check(irq, "SEEK interrupt");
    sense_int(st0, pcn);
    check32(32'(st0), 32'h22, "SEEK ST0 (seek end, drive 2)");
    check32(32'(pcn), 32'd17, "SEEK PCN");
    put(8'hcf); put(8'h02); put(8'd5);      // relative seek in
    sense_int(st0, pcn);
    check32(32'(pcn), 32'd22, "relative seek in");
    put(8'h8f); put(8'h02); put(8'd30);     // relative seek out, clamps at 0
    sense_int(st0, pcn);
    check32(32'(pcn), 32'd0, "relative seek out clamps");
    check32(32'(st0), 32'h22, "relative seek ST0");

    // ---- SENSE DRIVE STATUS ------------------------------------------------------
    put(8'h04); put(8'h05);                 // head 1, drive 1
    get(st0);    check32(32'(st0), 32'h3d, "ST3: RDY, T0, two-sided, head, drive");
    idle_check("SENSE DRIVE");

    // ---- SPECIFY / CONFIGURE / PERPENDICULAR / LOCK / DUMPREG ------------------------
    put(8'h03); put(8'hdf); put(8'h03);
    idle_check("SPECIFY (no result)");
    put(8'h13); put(8'h00); put(8'h47); put(8'h0a);   // EIS, FIFO on, thr 7
    idle_check("CONFIGURE");
    put(8'h12); put(8'h8c);                            // OW, D1, D0 = 3
    idle_check("PERPENDICULAR");
    put(8'h94); get(st0);
    check32(32'(st0), 32'h10, "LOCK set");
    put(8'h0e);
    for (int i = 0; i < 10; i++) get(b[i]);
    check32(32'(b[0]), 0, "DUMPREG PCN0");
    check32(32'(b[1]), 0, "DUMPREG PCN1");
    check32(32'(b[2]), 0, "DUMPREG PCN2 (seek target 0 after clamp)");
    check32(32'(b[4]), 32'hdf, "DUMPREG SRT/HUT");
    check32(32'(b[5]), 32'h03, "DUMPREG HLT/ND");
    check32(32'(b[7]), 32'h80 | 32'h0c, "DUMPREG LOCK + perpendicular");
    check32(32'(b[8]), 32'h47, "DUMPREG CONFIGURE");
    check32(32'(b[9]), 32'h0a, "DUMPREG PRETRK");
    idle_check("DUMPREG");
    put(8'h14); get(st0);
    check32(32'(st0), 32'h00, "LOCK cleared");

    // ---- data commands, no drive --------------------------------------------------
    // READ DATA MT MFM SK: drive 1, head 1; C=3 H=1 R=4 N=2 EOT=9 GPL DTL
    put(8'hE6); put(8'h05); put(8'd3); put(8'd1); put(8'd4); put(8'd2);
    put(8'd9);  put(8'h1b); put(8'hff);
    check(irq, "READ interrupt");
    for (int i = 0; i < 7; i++) begin
      get(b[i]);
      if (i == 0) check(!irq, "INT cleared by the first result byte");
    end
    check32(32'(b[0]), 32'h45, "READ ST0: abnormal termination, head 1, drive 1");
    check32(32'(b[1]), 32'h01, "READ ST1: missing address mark");
    check32(32'(b[2]), 32'h00, "READ ST2");
    check32(32'({b[3], b[4], b[5], b[6]}), {8'd3, 8'd1, 8'd4, 8'd2}, "READ C H R N");
    idle_check("READ");
    // WRITE DATA, drive 0
    put(8'h45); put(8'h00); put(8'd0); put(8'd0); put(8'd1); put(8'd2);
    put(8'd9);  put(8'h1b); put(8'hff);
    for (int i = 0; i < 7; i++) get(b[i]);
    check32(32'(b[0]), 32'h40, "WRITE ST0");
    check32(32'(b[1]), 32'h01, "WRITE ST1");
    idle_check("WRITE");
    // READ ID, drive 2 (PCN 0 after the clamp)
    put(8'h4a); put(8'h02);
    check(irq, "READ ID interrupt");
    for (int i = 0; i < 7; i++) get(b[i]);
    check32(32'(b[0]), 32'h42, "READ ID ST0");
    check32(32'(b[1]), 32'h01, "READ ID ST1");
    idle_check("READ ID");
    // FORMAT TRACK, drive 0
    put(8'h4d); put(8'h00); put(8'd2); put(8'd18); put(8'h54); put(8'hf6);
    for (int i = 0; i < 7; i++) get(b[i]);
    check32(32'(b[0]), 32'h40, "FORMAT ST0");
    check32(32'(b[1]), 32'h01, "FORMAT ST1");
    check(!irq, "FORMAT interrupt cleared");
    idle_check("FORMAT");

    // ---- invalid commands -------------------------------------------------------------
    put(8'h00); get(st0);
    check32(32'(st0), 32'h80, "invalid opcode 0x00");
    idle_check("invalid");
    put(8'h18); get(st0);
    check32(32'(st0), 32'h80, "PARTID is 82078-only: invalid");
    put(8'h33); get(st0);
    check32(32'(st0), 32'h80, "OPTION is 82078-only: invalid");
    idle_check("invalid 2");
    check(!irq, "invalid commands raise no interrupt");

    // ---- registers --------------------------------------------------------------------
    wr(TDR, 8'h02);   rd(TDR, v); check32(32'(v), 32'h02, "TDR");
    wr(CCR, 8'h01);   rd(DIR, v); check32(32'(v), 32'h00, "DIR: no disk change");
    wr(DOR, 8'h3d);   rd(DOR, v); check32(32'(v), 32'h3d, "DOR motors");
    rd(1, v);         check32(32'(v), 32'hc0 | 32'h20 | 32'h03, "SRB: select + motors");
    rd(6, v);         check32(32'(v), 32'h00, "reserved register");

    // ---- DMAGATE gates INT, not the status ------------------------------------------------
    wr(DOR, 8'h04);
    put(8'h07); put(8'h00);
    check(!irq, "INT tristated without DMAGATE");
    rd(0, v);   check32(32'(v), 32'hc0, "SRA still shows INT pending");
    wr(DOR, 8'h0c);
    check(irq, "INT with DMAGATE");
    sense_int(st0, pcn);
    check32(32'(st0), 32'h70, "RECALIBRATE drive 0");

    // ---- a DOR reset mid-command forgets the command ----------------------------------------
    put(8'h0f); put(8'h01);
    wr(DOR, 8'h00);
    rd(MSR, v); check32(32'(v), 32'h00, "MSR in DOR reset");
    wr(DOR, 8'h0c);
    for (int d = 0; d < 4; d++) begin
      sense_int(st0, pcn);
      check32(32'(st0), 32'hc0 + d, $sformatf("after DOR reset SENSE INT %0d", d));
    end
    idle_check("after the DOR reset");

    // ---- DSR software reset, self-clearing --------------------------------------------------
    wr(DSR, 8'h80);
    check(irq, "DSR reset interrupt");
    rd(DOR, v); check32(32'(v), 32'h0c, "DSR reset leaves DOR");
    for (int d = 0; d < 4; d++) begin
      sense_int(st0, pcn);
      check32(32'(st0), 32'hc0 + d, $sformatf("after DSR reset SENSE INT %0d", d));
    end
    // polling disabled by CONFIGURE: no reset interrupt (datasheet 5.2.7)
    put(8'h13); put(8'h00); put(8'h10); put(8'h00);
    wr(DSR, 8'h80);
    check(!irq, "no interrupt with polling disabled");
    put(8'h0e);
    for (int i = 0; i < 10; i++) get(b[i]);
    check32(32'(b[8]), 32'h30, "software reset: EFIFO back to default, POLL kept");

    // ---- a hardware reset puts everything back ------------------------------------------------
    rst = 1; cycles(2); rst = 0; cycles(2);
    rd(DOR, v); check32(32'(v), 32'h00, "DOR after hardware reset");
    check(!irq, "no interrupt after hardware reset");
    wr(DOR, 8'h0c);
    check(irq, "polling enabled again after hardware reset");

    tb_done("tb_fdc82077");
  end

  initial begin
    #5_000_000;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule
