// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_nvram_sd: the NVRAM image on the SD card (rtl/mister/nvram_sd.sv) with
// the real m48t08 behind it, against a behavioural model of hps_io's SD
// side as sim/sim_main.cpp plays it (Main's latency, then 256 halfwords per
// block at four clocks each, the even byte low). The checks are those of
// the old repository's whole-machine sim/run-nvram.sh, made unit-sized:
//  - a random image (a valid format byte, a wrong IDPROM checksum) is
//    loaded byte for byte as the CPU sees it on the m48t08's bus, with 16
//    sector reads in order; `ready` holds until the load is over; nothing
//    is written back until the CPU writes; a byte written and restored is
//    written back (one sector) and leaves the file unchanged; writes in
//    sectors 3 and 15 come back byte for byte, lowest sector first, QUIET
//    after the last write; clock-byte writes are not saved;
//  - a blank image gets the built-in IDPROM (format 1, type 0x72,
//    08:00:20 + the seed's serial, checksum 0), written back at once: the
//    file is zeros but for that IDPROM and the Sun OBP's defaults
//    (obp_nvram_pkg), sectors 0-3 and 15 written back, lowest first; with
//    no seed the serial is 123456;
//  - a valid IDPROM with zero bytes in it loads unchanged;
//  - read-only images are loaded and never written;
//  - no image: `ready` after TIMEOUT, the IDPROM stamped with the seed if
//    one came, else the power-up one, the OBP defaults written at power-up;
//    no SD traffic;
//  - a mount of another size, or an unmount, disconnects the image;
//  - a load Main never serves is given up on at LOADMAX.
// The file's clock bytes (0x1FF8-0x1FFF) are left out of the comparisons:
// the write-back carries the clock there by design.

/* verilator lint_off PROCASSINIT */   // a bench: its variables start at their declared values
/* verilator lint_off BLKSEQ */        // its hps_io model is behavioural, like sim_main.cpp's
module tb_nvram_sd;
  import iobus_pkg::*;
  import obp_nvram_pkg::*;
  import tb_pkg::*;

  localparam int TIMEOUT = 2_000, LOADMAX = 200_000, QUIET = 20_000;   // nvram_sd's SIMU timers

  logic clk = 1'b0;
  always #5 clk = ~clk;
  int unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ------------------------------------------------------------------ DUT --
  logic        por = 1'b0;
  logic        img_mounted = 1'b0, img_readonly = 1'b0;
  logic [63:0] img_size = '0;
  logic [31:0] sd_lba;
  logic [5:0]  sd_blk_cnt;
  logic        sd_rd, sd_wr;
  logic        sd_ack = 1'b0;
  logic [12:0] sd_buff_addr = '0;
  logic [15:0] sd_buff_dout = '0, sd_buff_din;
  logic        sd_buff_wr = 1'b0;
  logic [23:0] seed = '0;
  logic        seed_ok = 1'b0;
  logic        nv_we;
  logic [10:0] nv_addr;
  logic [3:0]  nv_be;
  logic [31:0] nv_wdata, nv_rdata;
  iob_req_t    req = IOB_REQ_IDLE;
  iob_rsp_t    rsp;
  logic        ready;

  nvram_sd #(.CLK_HZ(1_000_000), .SIMU(1'b1)) dut (
    .clk, .por,
    .img_mounted, .img_readonly, .img_size,
    .sd_lba, .sd_blk_cnt, .sd_rd, .sd_wr, .sd_ack,
    .sd_buff_addr, .sd_buff_dout, .sd_buff_din, .sd_buff_wr,
    .seed, .seed_ok,
    .nv_we, .nv_addr, .nv_be, .nv_wdata, .nv_rdata,
    .nv_bus_req(req), .nv_bus_rsp(rsp),
    .ready);

  m48t08 #(.CLK_HZ(1_000_000)) rtc (
    .clk, .rst(1'b0), .bus_i(req), .bus_o(rsp),
    .img_we(nv_we), .img_addr(nv_addr), .img_be(nv_be), .img_wdata(nv_wdata), .img_rdata(nv_rdata),
    .seed_valid(1'b0), .seed_sec(8'h0), .seed_min(8'h0), .seed_hour(8'h0), .seed_day(8'h1),
    .seed_date(8'h1), .seed_month(8'h1), .seed_year(8'h0));

  // ------------------------------------------------- hps_io's SD side --
  logic [7:0]  file [8192];             // the image file
  bit          serve = 1'b1;            // Main answers requests
  int          latency = 40;
  int unsigned n_reads = 0, n_writes = 0, n_bad = 0;
  int unsigned lba_log [$];              // reads and writes, in order (writes + 100)

  typedef enum {H_IDLE, H_DELAY, H_RD, H_WR, H_END} hstate_t;
  hstate_t     hs = H_IDLE;
  int          h_word = 0, h_sub = 0, h_wait = 0;
  bit          h_write = 1'b0;
  logic [31:0] h_lba = '0;

  always @(posedge clk) begin
    sd_buff_wr <= 1'b0;
    case (hs)
      H_IDLE: if (serve && (sd_rd || sd_wr)) begin
        if (sd_rd && sd_wr) n_bad++;
        if (sd_blk_cnt != 6'd0 || sd_lba > 32'd15) n_bad++;
        h_write = sd_wr;
        h_lba   = sd_lba;
        lba_log.push_back(int'(sd_lba) + (h_write ? 100 : 0));
        if (h_write) n_writes++; else n_reads++;
        h_wait = latency;
        hs     = H_DELAY;
      end
      H_DELAY: if (--h_wait <= 0) begin
        sd_ack       <= 1'b1;
        sd_buff_addr <= '0;
        h_word = 0;
        h_sub  = 0;
        hs     = h_write ? H_WR : H_RD;
      end
      H_RD: begin
        // address and data, then the write strobe, then the next address
        if (h_sub == 0) begin
          sd_buff_addr <= 13'(h_word);
          sd_buff_dout <= {file[512 * h_lba + 2 * h_word + 1], file[512 * h_lba + 2 * h_word]};
        end else if (h_sub == 1) begin
          sd_buff_wr <= 1'b1;
        end
        if (++h_sub == 4) begin
          h_sub = 0;
          if (++h_word == 256) begin hs = H_END; h_wait = 4; end
        end
      end
      H_WR: begin
        if (h_sub == 0) sd_buff_addr <= 13'(h_word);
        else if (h_sub == 3) begin
          file[512 * h_lba + 2 * h_word]     = sd_buff_din[7:0];
          file[512 * h_lba + 2 * h_word + 1] = sd_buff_din[15:8];
        end
        if (++h_sub == 4) begin
          h_sub = 0;
          if (++h_word == 256) begin hs = H_END; h_wait = 4; end
        end
      end
      H_END: if (--h_wait <= 0) begin
        sd_ack <= 1'b0;
        hs     = H_IDLE;
      end
      default: hs = H_IDLE;
    endcase
  end

  // ---------------------------------------------------------------- tasks --
  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic bus_write(input logic [12:0] a, input logic [3:0] be, input logic [31:0] d);
    req.req = 1; req.we = 1; req.addr = 28'(a); req.be = be; req.wdata = d;
    do cycles(1); while (!rsp.ack);
    req.req = 0; req.we = 0;
  endtask

  task automatic bus_read(input logic [12:0] a, output logic [31:0] d);
    req.req = 1; req.we = 0; req.addr = 28'(a); req.be = '1;
    do cycles(1); while (!rsp.ack);
    d = rsp.rdata;
    req.req = 0;
  endtask

  task automatic wr8(input logic [12:0] a, input logic [7:0] d);
    bus_write(a, 4'b1000 >> a[1:0], {4{d}});
  endtask

  task automatic rd8(input logic [12:0] a, output logic [7:0] d);
    logic [31:0] w;
    bus_read(a, w);
    d = w[8 * (3 - int'(a[1:0])) +: 8];
  endtask

  // Power-on: the whole block back to its configuration state
  task automatic power_on();
    por = 1'b1;
    cycles(2);
    por = 1'b0;
    n_reads = 0; n_writes = 0;
    lba_log.delete();
  endtask

  task automatic mount(input logic [63:0] size, input bit ro);
    img_size = size; img_readonly = ro; img_mounted = 1'b1;
    cycles(3);
    img_mounted = 1'b0;
  endtask

  task automatic wait_ready(input int limit, output int at);
    int n;
    n = 0;
    while (!ready && n < limit) begin cycles(1); n++; end
    at = int'(cyc);
  endtask

  // Wait until the host is idle and no request is pending for `n` cycles
  task automatic settle(input int n);
    int q;
    q = 0;
    while (q < n) begin
      cycles(1);
      if (hs == H_IDLE && !sd_rd && !sd_wr) q++; else q = 0;
    end
  endtask

  // Every NVRAM byte below the clock, as the CPU reads it, against `exp`
  task automatic compare_nvram(input logic [7:0] exp [8192], input string what);
    logic [31:0] w;
    int bad, first_bad;
    bad = 0; first_bad = -1;
    for (int a = 0; a < 'h1FF8; a += 4) begin
      bus_read(13'(a), w);
      for (int b = 0; b < 4; b++)
        if (w[8 * (3 - b) +: 8] !== exp[a + b]) begin
          if (first_bad < 0) first_bad = a + b;
          bad++;
        end
    end
    check(bad == 0, $sformatf("%s: %0d NVRAM bytes differ (first at %04x)", what, bad, first_bad));
  endtask

  task automatic compare_file(input logic [7:0] exp [8192], input string what);
    int bad, first_bad;
    bad = 0; first_bad = -1;
    for (int a = 0; a < 'h1FF8; a++)
      if (file[a] !== exp[a]) begin
        if (first_bad < 0) first_bad = a;
        bad++;
      end
    check(bad == 0, $sformatf("%s: %0d file bytes differ (first at %04x: %02x, expected %02x)",
                              what, bad, first_bad, first_bad < 0 ? 8'h0 : file[first_bad],
                              first_bad < 0 ? 8'h0 : exp[first_bad]));
  endtask

  // The built-in IDPROM with a serial, and its checks
  function automatic void builtin(input logic [23:0] s, output logic [7:0] id [16]);
    id = '{8'h01, 8'h72, 8'h08, 8'h00, 8'h20, s[23:16], s[15:8], s[7:0],
           8'h00, 8'h00, 8'h00, 8'h00, s[23:16], s[15:8], s[7:0], 8'h00};
    for (int i = 0; i < 15; i++) id[15] ^= id[i];
  endfunction

  task automatic check_idprom(input logic [23:0] s, input string what);
    logic [7:0] id [16];
    logic [7:0] b, x;
    int bad;
    builtin(s, id);
    bad = 0; x = 0;
    for (int i = 0; i < 16; i++) begin
      rd8(13'h1FD8 + 13'(i), b);
      x ^= b;
      if (b !== id[i]) bad++;
    end
    check(bad == 0, $sformatf("%s: the NVRAM's IDPROM is not the built-in one with serial %06x", what, s));
    check(x == 8'h00, $sformatf("%s: the NVRAM's IDPROM checksum", what));
  endtask

  // The Sun OBP's defaults over an image
  function automatic void add_defaults(inout logic [7:0] img [8192]);
    logic [27:0] e;
    for (int k = 0; k < OBP_DFLT_N; k++) begin
      e = obp_dflt(6'(k));
      img[2 * e[27:16]]     = e[7:0];
      img[2 * e[27:16] + 1] = e[15:8];
    end
  endfunction

  // The OBP's configuration checksum (tools/obp_nvram.py) holds in the NVRAM
  task automatic check_obp(input string what);
    logic [7:0] x, b, ck;
    x = 8'h38 ^ 8'hf0;
    for (int a = 'h20; a < 'h1cd8; a++) begin
      rd8(13'(a), b);
      x ^= b;
    end
    rd8(13'h0, ck);
    check(ck == x, $sformatf("%s: the OBP checksum (%02x, expected %02x)", what, ck, x));
    rd8(13'h5a8, b);
    check(b == 8'hff, $sformatf("%s: OBP auto-boot? true", what));
    rd8(13'h001, b);
    check(b == 8'h00, $sformatf("%s: OBP diag-switch? false", what));
  endtask

  function automatic bit log_is(input int unsigned exp [$]);
    if (lba_log.size() != exp.size()) return 0;
    foreach (exp[i]) if (lba_log[i] != exp[i]) return 0;
    return 1;
  endfunction

  function automatic string log_str();
    string s;
    s = "";
    foreach (lba_log[i]) s = {s, $sformatf(" %0d", lba_log[i])};
    return s;
  endfunction

  // ----------------------------------------------------------------- test --
  logic [7:0]  orig [8192];
  logic [7:0]  exp  [8192];
  logic [7:0]  id   [16];
  int          at, t0;
  logic [7:0]  b;
  int unsigned reads16 [$];

  initial begin
    for (int i = 0; i < 16; i++) reads16.push_back(i);

    // ================= a random image, read-write
    begin : random_rw
      logic [31:0] r;
      r = 32'd1;
      for (int i = 0; i < 8192; i++) begin
        r = r * 32'd1664525 + 32'd1013904223;                   // a fixed pseudo-random image
        orig[i] = r[31:24];
      end
      id = '{8'h01, 8'h72, 8'h08, 8'h00, 8'h20, 8'hab, 8'hcd, 8'hef,
             8'h00, 8'h00, 8'h00, 8'h00, 8'hab, 8'hcd, 8'hef, 8'h00};
      for (int i = 0; i < 15; i++) id[15] ^= id[i];
      id[15] ^= 8'h5a;                                          // a wrong checksum
      for (int i = 0; i < 16; i++) orig['h1FD8 + i] = id[i];
      file = orig;
    end
    power_on();
    cycles(100);
    check(!ready, "random: not ready before the mount");
    mount(64'd8192, 1'b0);
    cycles(TIMEOUT + 500 - 103);
    check(!ready, "random: ready held through TIMEOUT while the load runs");
    wait_ready(LOADMAX, at);
    check(ready, "random: ready after the load");
    check(hs == H_END || hs == H_IDLE, "random: ready only once the last sector is in");
    check(n_reads == 16 && log_is(reads16), $sformatf("random: 16 sector reads in order, got%s", log_str()));
    compare_nvram(orig, "random: loaded");
    t0 = int'(cyc);
    cycles(QUIET + 2000);
    check(n_writes == 0, "random: nothing written back without a CPU write");

    // a byte written and restored: sector 0 saved, the file unchanged
    rd8(13'h100, b);
    wr8(13'h100, 8'h5a);
    wr8(13'h100, b);
    cycles(QUIET - 100);
    check(n_writes == 0, "random: no write-back before QUIET");
    settle(QUIET + 200);
    check(n_writes == 1 && lba_log[16] == 100, $sformatf("random: sector 0 written back once, got%s", log_str()));
    compare_file(orig, "random: written back unchanged");

    // clock bytes are not saved
    wr8(13'h1FFB, 8'h00);
    cycles(QUIET + 2000);
    check(n_writes == 1, "random: a clock-byte write is not saved");

    // sectors 15 and 3 (written in that order, saved lowest first); a later
    // write restarts QUIET
    exp = orig;
    bus_write(13'h1F00, 4'b1111, 32'hDEAD_BEEF);
    exp['h1F00] = 8'hDE; exp['h1F01] = 8'hAD; exp['h1F02] = 8'hBE; exp['h1F03] = 8'hEF;
    cycles(QUIET / 2);
    wr8(13'h0601, 8'h42);
    exp['h0601] = 8'h42;
    cycles(QUIET / 2 + 500);
    check(n_writes == 1, "random: a second write restarts the quiet time");
    settle(QUIET + 200);
    check(n_writes == 3 && lba_log[17] == 103 && lba_log[18] == 115,
          $sformatf("random: sectors 3 then 15 written back, got%s", log_str()));
    compare_file(exp, "random: CPU writes saved byte for byte");
    compare_nvram(exp, "random: the NVRAM after the write-back");

    // ================= a blank image, with a seed
    for (int i = 0; i < 8192; i++) file[i] = 8'h00;
    seed = 24'h61_56_F1; seed_ok = 1'b1;
    power_on();
    cycles(50);
    mount(64'd8192, 1'b0);
    wait_ready(LOADMAX, at);
    check(ready, "blank: ready after the load");
    check_idprom(24'h61_56_F1, "blank+seed");
    settle(200);
    check(n_reads == 16 && n_writes == 5 && log_is('{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
          14, 15, 100, 101, 102, 103, 115}),
          $sformatf("blank+seed: the defaults' and the IDPROM's sectors written back at once, got%s",
                    log_str()));
    builtin(24'h61_56_F1, id);
    for (int i = 0; i < 8192; i++) exp[i] = 8'h00;
    for (int i = 0; i < 16; i++) exp['h1FD8 + i] = id[i];
    add_defaults(exp);
    compare_file(exp, "blank+seed: zeros but for the IDPROM and the OBP defaults");
    compare_nvram(exp, "blank+seed: the NVRAM");
    check_obp("blank+seed");

    // ================= a blank image, no seed: serial 12:34:56
    for (int i = 0; i < 8192; i++) file[i] = 8'h00;
    seed_ok = 1'b0;
    power_on();
    cycles(50);
    mount(64'd8192, 1'b0);
    wait_ready(LOADMAX, at);
    settle(200);
    check_idprom(24'h12_34_56, "blank, no seed");
    check(n_writes == 5, "blank, no seed: the IDPROM and the defaults written back");
    builtin(24'h12_34_56, id);
    for (int i = 0; i < 8192; i++) exp[i] = 8'h00;
    for (int i = 0; i < 16; i++) exp['h1FD8 + i] = id[i];
    add_defaults(exp);
    compare_file(exp, "blank, no seed: the file");

    // ================= an image with only a valid IDPROM is blank too
    for (int i = 0; i < 8192; i++) file[i] = 8'h00;
    builtin(24'h00_00_09, id);
    for (int i = 0; i < 16; i++) file['h1FD8 + i] = id[i];
    power_on();
    cycles(50);
    mount(64'd8192, 1'b0);
    wait_ready(LOADMAX, at);
    settle(200);
    check(n_writes == 4 && log_is('{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
          100, 101, 102, 103}), $sformatf("IDPROM only: the defaults' sectors saved, got%s", log_str()));
    check_idprom(24'h00_00_09, "IDPROM only");
    check_obp("IDPROM only");

    // ================= one nonzero byte below the IDPROM: not blank
    for (int i = 0; i < 8192; i++) file[i] = 8'h00;
    file['h1F4F] = 8'h01;
    exp = file;
    builtin(24'h12_34_56, id);
    for (int i = 0; i < 16; i++) exp['h1FD8 + i] = id[i];
    power_on();
    cycles(50);
    mount(64'd8192, 1'b0);
    wait_ready(LOADMAX, at);
    settle(200);
    check(n_writes == 1 && lba_log[16] == 115, $sformatf("one byte: only the IDPROM saved, got%s", log_str()));
    compare_file(exp, "one byte: no defaults");

    // ================= a valid IDPROM with zero serial bytes loads unchanged
    file = orig;
    builtin(24'h00_00_07, id);
    for (int i = 0; i < 16; i++) file['h1FD8 + i] = id[i];
    exp = file;
    seed = 24'hAA_BB_CC; seed_ok = 1'b1;
    power_on();
    cycles(50);
    mount(64'd8192, 1'b0);
    wait_ready(LOADMAX, at);
    settle(QUIET + 200);
    check_idprom(24'h00_00_07, "zero serial");
    check(n_writes == 0, "zero serial: not taken for blank, nothing written");

    // ================= read-only images
    file = orig;
    power_on();
    cycles(50);
    mount(64'd8192, 1'b1);
    wait_ready(LOADMAX, at);
    compare_nvram(orig, "random, read-only: loaded");
    wr8(13'h0010, 8'h99);
    cycles(2 * QUIET + 500);
    check(n_reads == 16 && n_writes == 0, "random, read-only: never written");
    compare_file(orig, "random, read-only: the file unchanged");

    for (int i = 0; i < 8192; i++) file[i] = 8'h00;
    seed = 24'h01_02_03; seed_ok = 1'b1;
    power_on();
    cycles(50);
    mount(64'd8192, 1'b1);
    wait_ready(LOADMAX, at);
    cycles(2 * QUIET + 500);
    check_idprom(24'h01_02_03, "blank, read-only");
    check_obp("blank, read-only");
    check(n_writes == 0, "blank, read-only: the IDPROM and the defaults not written back");

    // ================= no image, a seed: stamped at TIMEOUT
    for (int a = 'h1FD8; a < 'h1FE8; a++) wr8(13'(a), 8'h77);   // junk first
    seed_ok = 1'b0;
    power_on();
    t0 = int'(cyc);
    cycles(300);
    seed = 24'h65_43_21; seed_ok = 1'b1;
    wait_ready(LOADMAX, at);
    check(at - t0 >= TIMEOUT && at - t0 < TIMEOUT + 40,
          $sformatf("no image + seed: ready %0d cycles after power-up (TIMEOUT %0d)", at - t0, TIMEOUT));
    check_idprom(24'h65_43_21, "no image + seed");
    wr8(13'h0020, 8'h11);
    cycles(2 * QUIET);
    check(n_reads == 0 && n_writes == 0, "no image + seed: no SD traffic");

    // ================= no image, no seed: the power-up IDPROM
    for (int a = 'h1FD8; a < 'h1FE8; a++) wr8(13'(a), 8'h77);
    seed_ok = 1'b0;
    power_on();
    t0 = int'(cyc);
    wait_ready(LOADMAX, at);
    check(at - t0 >= TIMEOUT && at - t0 < TIMEOUT + 10,
          $sformatf("no image: ready %0d cycles after power-up", at - t0));
    check_idprom(24'h12_34_56, "no image, no seed");
    begin : no_image_defaults
      logic [27:0] e;
      logic [7:0]  b0, b1;
      int          bad;
      bad = 0;
      for (int k = 0; k < OBP_DFLT_N; k++) begin
        e = obp_dflt(6'(k));
        rd8(13'(2 * e[27:16]), b0);
        rd8(13'(2 * e[27:16] + 1), b1);
        if ({b1, b0} != e[15:0]) bad++;
      end
      check(bad == 0, $sformatf("no image: %0d OBP default halfwords missing", bad));
    end

    // ================= a mount of another size disconnects
    file = orig;
    power_on();
    cycles(50);
    mount(64'd4096, 1'b0);
    cycles(5);
    check(ready, "4 KB image: ready at once");
    wr8(13'h0030, 8'h55);
    cycles(2 * QUIET);
    check(n_reads == 0 && n_writes == 0, "4 KB image: neither read nor written");

    // ================= an unmount after a load disconnects
    file = orig;
    power_on();
    cycles(50);
    mount(64'd8192, 1'b0);
    wait_ready(LOADMAX, at);
    mount(64'd0, 1'b0);
    wr8(13'h0040, 8'h66);
    cycles(2 * QUIET);
    check(n_reads == 16 && n_writes == 0, "unmounted: the CPU's writes are not saved");
    compare_file(orig, "unmounted: the file unchanged");

    // ================= Main never serves the load: given up on at LOADMAX
    serve = 1'b0;
    power_on();
    t0 = int'(cyc);
    cycles(50);
    mount(64'd8192, 1'b0);
    wait_ready(2 * LOADMAX, at);
    check(at - t0 >= LOADMAX && at - t0 < LOADMAX + 10,
          $sformatf("no service: ready at LOADMAX (%0d cycles)", at - t0));
    serve = 1'b1;

    check(n_bad == 0, "the SD requests were well-formed (one block, sector < 16, rd xor wr)");
    tb_done("tb_nvram_sd");
  end

  initial begin
    #100ms;
    $display("FAIL: tb_nvram_sd timed out");
    $fatal(1, "timeout");
  end

endmodule
