// SPDX-License-Identifier: GPL-2.0-or-later
//
// nvram_sd: the NVRAM (M48T08, 8 KB) saved to an image file on the SD card,
// with the IDPROM duties folded in, so that it sits directly on the image
// port of rtl/obio/m48t08.sv.
//
// One hps_io block device: the OSD's "NVRAM" slot (SD slot 3), an 8192-byte
// file. Main remembers the file and mounts it again at every core load,
// before it downloads boot.rom; it serves our sector requests once the
// download is over. So:
//  - on a mount of an 8192-byte image, its 16 sectors are read into the
//    NVRAM through m48t08's image port. A mount of any other size (an
//    unmount reports 0) disconnects the image: nothing is read from it or
//    written to it;
//  - `ready` holds the machine in reset until that load is over, so the
//    PROM never reads the NVRAM before it. Main sends no mount for an empty
//    slot: then `ready` rises TIMEOUT (3 s) after power-up. A load that has
//    not finished by LOADMAX (6 s) is given up on;
//  - a CPU write to the RAM (watched on the m48t08's own I/O bus, the
//    clock bytes 0x1FF8-0x1FFF excepted) makes its sector dirty; QUIET
//    (0.5 s) after the last one, the dirty sectors are written back to the
//    image, lowest first, one 512-byte block per request. Read-only images
//    are never written.
// The image is a plain byte image: file byte n = NVRAM byte n (the IDPROM
// at 0x1FD8, the clock registers at 0x1FF8; m48t08 ignores image writes to
// the clock and returns the clock on image reads, so a saved image carries
// the time).
//
// The IDPROM (Sun-4M §9.3.1; requirement ID). The built-in
// one is 16 bytes at 0x1FD8:
//   01 MACHINE 08 00 20 S2 S1 S0 00 00 00 00 S2 S1 S0 CK
// format 1, the machine type (0x72 = SS20), the Ethernet address
// 08:00:20:S2:S1:S0, a zero date, the serial again, and the XOR checksum of
// bytes 0-14 (the serial bytes pair off, so CK = 01^MACHINE^08^20). The
// serial is `seed` when Main sent one (ioctl index 64, the ID PROM: its
// bytes 5-7, byte 5 in seed[23:16]; the top level decodes the download and
// raises seed_ok), else 12:34:56 (the old bitstream's 08:00:20:12:34:56).
//  - power-up: the built-in IDPROM is written into the NVRAM once (the old
//    RAM's initial contents), so a machine with no image and no seed still
//    has an identity;
//  - a blank image (format byte 0x1FD8 = 0) gets the built-in IDPROM
//    instead of its 16 zero bytes at the load, and that sector is written
//    back after the load, so the machine keeps its Ethernet address and
//    hostid from then on;
//  - with no image and a seed, the same IDPROM (with the seed's serial) is
//    stamped into the NVRAM before `ready`, so the machine's identity
//    follows the MiSTer rather than the bitstream.
//
// The Sun PROM's defaults (rtl/pkg/obp_nvram_pkg.sv, from
// tools/obp_nvram.py). Sun's OBP 2.25 checks its options with a checksum;
// on an empty NVRAM it fails, and OBP then sets its defaults with
// diag-switch? true: the full POST, a test of all of memory (minutes) and
// a network boot at every start. So an empty NVRAM gets a valid OBP
// configuration (the defaults, diag-switch? false, boot-device disk)
// written into it, OBP_DFLT_N halfwords after the IDPROM at power-up, and
// after the load of an image that is zero below the IDPROM (a new file),
// whose sectors it touches are then written back at once. OpenBIOS keeps
// its own format: it reads such an NVRAM as unformatted, formats it in RAM
// and writes the chip only when a variable changes (bios/, nvram.c).
//
// The hps_io side (WIDE = 1): one 512-byte block per request (sd_blk_cnt
// = 0), sd_lba = the sector 0-15. sd_rd/sd_wr are held until sd_ack rises;
// the transfer is over when sd_ack falls. sd_buff_dout's halfword holds the
// file's even byte in [7:0] and the odd one in [15:8] (Main's order);
// sd_buff_wr strobes it into the NVRAM at sd_buff_addr. For a write-back
// sd_buff_din is the halfword at sd_buff_addr one clock later (hps_io
// leaves several clocks between moving the address and taking the data).
// Only sd_buff_addr[7:0] is used (one block).
//
// The m48t08 side: its image port (32-bit words, big-endian lanes: byte 0
// of a word in [31:24], data the cycle after the address). A halfword h of
// the file (12 bits) is word h[11:1], lanes 3:2 (h[0] = 0) or 1:0 (h[0] =
// 1), with its two bytes swapped from Main's order. `nv_bus_req`/
// `nv_bus_rsp` are a tap of the m48t08's bus_i/bus_o (inputs only): a
// write marks its sector dirty at the edge where m48t08 takes it, which is
// req & we & !ack (m48t08 answers every request the next cycle, and the
// master may drop req within the ack cycle).
//
// `por` returns the block to its power-up state (the power-up IDPROM
// write included). The NVRAM's image must survive an OSD or software
// reset, so tie `por` to 0 in the machine (or to a
// configuration-time reset); it is there for the benches.
//
// A blank image's IDPROM is replaced as a whole when the format byte is 0
// (a valid IDPROM with zero halfwords is left alone); a non-blank image
// loads byte for byte. A CPU write marks its sector dirty in the cycle the
// RAM takes it.

module nvram_sd
  import iobus_pkg::*;
#(
  parameter int         CLK_HZ  = 55_000_000,
  parameter bit         SIMU    = 1'b0,     // 1: short timers (benches, sim/)
  parameter logic [7:0] MACHINE = 8'h72     // the IDPROM's machine type (SS20)
)(
  input  logic        clk,
  input  logic        por,           // power-on reset only (see above)

  // hps_io, this image's slot (WIDE)
  input  logic        img_mounted,   // held by hps_io for the mount command
  input  logic        img_readonly,
  input  logic [63:0] img_size,
  output logic [31:0] sd_lba,
  output logic [5:0]  sd_blk_cnt,    // blocks - 1: always one block
  output logic        sd_rd,
  output logic        sd_wr,
  input  logic        sd_ack,
  input  logic [12:0] sd_buff_addr,
  input  logic [15:0] sd_buff_dout,
  output logic [15:0] sd_buff_din,
  input  logic        sd_buff_wr,

  // the serial for a built-in IDPROM (ioctl index 64, bytes 5-7)
  input  logic [23:0] seed,
  input  logic        seed_ok,

  // m48t08's image port
  output logic        nv_we,
  output logic [10:0] nv_addr,
  output logic [3:0]  nv_be,
  output logic [31:0] nv_wdata,
  input  logic [31:0] nv_rdata,

  // m48t08's bus, watched for CPU writes
  input  iob_req_t    nv_bus_req,
  input  iob_rsp_t    nv_bus_rsp,

  output logic        ready          // the NVRAM holds the image, or none came
);

  import obp_nvram_pkg::*;   // (Quartus 17 takes one import in the header)

  localparam int TIMEOUT = SIMU ? 2_000   : CLK_HZ * 3;
  localparam int LOADMAX = SIMU ? 200_000 : CLK_HZ * 6;
  localparam int QUIET   = SIMU ? 20_000  : CLK_HZ / 2;
  localparam int PW = $clog2(LOADMAX + 1);
  localparam int QW = $clog2(QUIET + 1);
  localparam int DW = $clog2(OBP_DFLT_N);

  // The IDPROM: sector 15, halfwords 0xEC-0xF3 (bytes 0x1FD8-0x1FE7)
  localparam logic [3:0] ID_SEC = 4'hF;
  localparam logic [7:0] ID_HW  = 8'hEC;
  localparam logic [7:0] ID_CK  = 8'h01 ^ MACHINE ^ 8'h08 ^ 8'h20;

  typedef enum logic [1:0] {S_IDLE, S_REQ, S_XFER} state_t;

  // Power-up values (the FPGA's configuration): there is no machine reset here, only `por`.
  /* verilator lint_off PROCASSINIT */
  state_t          state        = S_IDLE;
  logic            ena          = 1'b0;   // an image is connected
  logic            ro           = 1'b0;   // ... read-only
  logic            loading      = 1'b0;   // the transfers are reads
  logic            load_pending = 1'b0;
  logic            ready_q      = 1'b0;
  logic [3:0]      sec          = 4'd0;
  logic [15:0]     dirty        = 16'd0;
  logic            mnt_d        = 1'b0;
  logic            ack_d        = 1'b0;
  logic            rd_q         = 1'b0;
  logic            wr_q         = 1'b0;
  logic [PW-1:0]   pon          = '0;
  logic [QW-1:0]   quiet_cnt    = '0;
  logic            idgen        = 1'b0;   // the image's IDPROM was blank
  // The IDPROM writer: at power-up (st_seed = 0), then once with the seed
  // when no image came (st_seed = 1, which sets `stamped`).
  logic            st_run       = 1'b1;
  logic            st_seed      = 1'b0;
  logic            stamped      = 1'b0;
  logic [2:0]      st_k         = 3'd0;
  logic            a0_q         = 1'b0;
  // The OBP defaults writer: at power-up (after the IDPROM writer), then
  // after a blank image's load (df_ready: `ready` when it is done).
  logic            df_run       = 1'b1;
  logic            df_ready     = 1'b0;
  logic [DW-1:0]   df_k         = '0;
  logic            zero_img     = 1'b0;   // the image loaded so far is zero below the IDPROM
  /* verilator lint_on PROCASSINIT */

  // The lowest dirty sector
  function automatic logic [3:0] first(input logic [15:0] v);
    logic [3:0] r;
    r = 4'd0;
    for (int i = 15; i >= 0; i--)
      if (v[i]) r = 4'(i);
    return r;
  endfunction

  // Halfword k (0-7) of the built-in IDPROM, in Main's order (even byte low)
  function automatic logic [15:0] id_half(input logic [2:0] k, input logic [23:0] s);
    case (k)
      3'd0:    return {MACHINE, 8'h01};
      3'd1:    return {8'h00, 8'h08};
      3'd2:    return {s[23:16], 8'h20};
      3'd3:    return {s[7:0], s[15:8]};
      3'd6:    return {s[15:8], s[23:16]};
      3'd7:    return {ID_CK, s[7:0]};
      default: return 16'h0000;            // the date bytes
    endcase
  endfunction

  // The CPU's writes to the RAM (not to the clock bytes), in the cycle
  // m48t08 performs them
  logic       cpu_chg;
  logic [3:0] cpu_sec;
  assign cpu_chg = nv_bus_req.req & nv_bus_req.we & ~nv_bus_rsp.ack &
                   (nv_bus_req.addr[12:3] != 10'h3FF);
  assign cpu_sec = nv_bus_req.addr[12:9];

  always_ff @(posedge clk) begin : sync
    logic [3:0] s;
    mnt_d <= img_mounted;
    ack_d <= sd_ack;

    // No image after TIMEOUT: run with the NVRAM as it is (stamped with the
    // seed first, if there is one). A load still going at LOADMAX is given
    // up on.
    if (pon != PW'(LOADMAX)) pon <= pon + 1'b1;
    if (pon == PW'(LOADMAX)) begin
      ready_q <= 1'b1;
    end else if (pon >= PW'(TIMEOUT) && !ena && !load_pending && !ready_q) begin
      if (seed_ok && !stamped) begin
        st_run  <= 1'b1;
        st_seed <= 1'b1;
      end else if (!st_run && !df_run) begin
        ready_q <= 1'b1;
      end
    end
    if (st_run) begin
      st_k <= st_k + 1'b1;
      if (st_k == 3'd7) begin
        st_run <= 1'b0;
        if (st_seed) stamped <= 1'b1;
      end
    end else if (df_run) begin
      if (ena) dirty[df_e[27:24]] <= 1'b1;
      df_k <= df_k + 1'b1;
      if (df_k == DW'(OBP_DFLT_N - 1)) begin
        df_run   <= 1'b0;
        df_k     <= '0;
        df_ready <= 1'b0;
        if (df_ready) ready_q <= 1'b1;
      end
    end

    case (state)
      // (no transfer while a writer has the image port)
      S_IDLE: if (!st_run && !df_run) begin
        if (load_pending) begin
          load_pending <= 1'b0;
          loading      <= 1'b1;
          zero_img     <= 1'b1;
          sec          <= 4'd0;
          rd_q         <= 1'b1;
          state        <= S_REQ;
        end else if (ena && !ro && dirty != 16'd0 && quiet_cnt == '0) begin
          // Cleared first: a write during the transfer marks it again.
          s = first(dirty);
          dirty[s] <= 1'b0;
          loading  <= 1'b0;
          sec      <= s;
          wr_q     <= 1'b1;
          state    <= S_REQ;
        end
      end

      S_REQ: begin
        if (sd_ack) begin
          rd_q  <= 1'b0;
          wr_q  <= 1'b0;
          state <= S_XFER;
        end
      end

      S_XFER: begin
        if (ack_d && !sd_ack) begin
          state <= S_IDLE;
          if (loading) begin
            if (sec == 4'hF) begin
              loading <= 1'b0;
              if (zero_img) begin                 // a new file: the OBP defaults first
                df_run   <= 1'b1;
                df_ready <= 1'b1;
              end else begin
                ready_q  <= 1'b1;
              end
              if (idgen) dirty[ID_SEC] <= 1'b1;   // save the built-in IDPROM
            end else begin
              sec   <= sec + 1'b1;
              rd_q  <= 1'b1;
              state <= S_REQ;
            end
          end
        end
      end

      default: state <= S_IDLE;
    endcase

    if (loading && sd_ack && sd_buff_wr && sec == ID_SEC && sd_buff_addr[7:0] == ID_HW)
      idgen <= sd_buff_dout[7:0] == 8'h00;
    if (loading && sd_ack && sd_buff_wr && {sec, sd_buff_addr[7:0]} < {ID_SEC, ID_HW} &&
        sd_buff_dout != 16'h0000)
      zero_img <= 1'b0;

    // CPU writes (after the case: a mark wins over the clear above)
    if (cpu_chg && ena) begin
      dirty[cpu_sec] <= 1'b1;
      quiet_cnt      <= QW'(QUIET);
    end else if (quiet_cnt != '0) begin
      quiet_cnt <= quiet_cnt - 1'b1;
    end

    // A mount (hps_io holds img_mounted for the whole command)
    if (img_mounted && !mnt_d) begin
      if (img_size == 64'd8192) begin
        ena          <= 1'b1;
        ro           <= img_readonly;
        load_pending <= 1'b1;
      end else begin
        ena     <= 1'b0;
        ready_q <= 1'b1;
      end
      dirty <= 16'd0;
    end

    a0_q <= sd_buff_addr[0];

    if (por) begin
      state        <= S_IDLE;
      ena          <= 1'b0;
      ro           <= 1'b0;
      loading      <= 1'b0;
      load_pending <= 1'b0;
      ready_q      <= 1'b0;
      sec          <= 4'd0;
      dirty        <= 16'd0;
      rd_q         <= 1'b0;
      wr_q         <= 1'b0;
      pon          <= '0;
      quiet_cnt    <= '0;
      idgen        <= 1'b0;
      st_run       <= 1'b1;
      st_seed      <= 1'b0;
      stamped      <= 1'b0;
      st_k         <= 3'd0;
      df_run       <= 1'b1;
      df_ready     <= 1'b0;
      df_k         <= '0;
      zero_img     <= 1'b0;
    end
  end

  assign sd_lba     = {28'd0, sec};
  assign sd_blk_cnt = 6'd0;
  assign sd_rd      = rd_q;
  assign sd_wr      = wr_q;
  assign ready      = ready_q;

  // The sector buffer is the NVRAM itself. The halfword written, in Main's
  // order: the built-in IDPROM's (the writer, or a blank image's IDPROM
  // during the load: blank is decided at its first halfword, which holds
  // the format byte), an OBP default's (its writer), else the file's.
  logic [27:0] df_e;         // the OBP default entry df_k: {halfword address, halfword}
  logic [11:0] hw;           // the file halfword addressed
  logic [23:0] serial;
  logic        id_range, id_blank;
  logic [2:0]  id_k;
  logic [15:0] half;

  assign serial   = seed_ok ? seed : 24'h12_34_56;
  assign df_e     = obp_dflt(df_k);
  assign hw       = st_run ? {ID_SEC, ID_HW + 8'(st_k)} : df_run ? df_e[27:16] : {sec, sd_buff_addr[7:0]};
  assign id_range = hw >= {ID_SEC, ID_HW} && hw <= {ID_SEC, ID_HW + 8'd7};
  assign id_k     = 3'(hw[7:0] - ID_HW);
  assign id_blank = (hw[7:0] == ID_HW) ? sd_buff_dout[7:0] == 8'h00 : idgen;

  always_comb begin
    if (st_run)                     half = id_half(id_k, serial);
    else if (df_run)                half = df_e[15:0];
    else if (id_range && id_blank)  half = id_half(id_k, serial);
    else                            half = sd_buff_dout;
  end

  assign nv_we    = st_run | df_run | (loading & sd_ack & sd_buff_wr);
  assign nv_addr  = hw[11:1];
  assign nv_be    = hw[0] ? 4'b0011 : 4'b1100;
  assign nv_wdata = {half[7:0], half[15:8], half[7:0], half[15:8]};

  // Halfword 0 of a word is its high half; Main's order puts the even byte low.
  assign sd_buff_din = a0_q ? {nv_rdata[7:0], nv_rdata[15:8]} : {nv_rdata[23:16], nv_rdata[31:24]};

  logic unused_ok;
  assign unused_ok = &{1'b0, sd_buff_addr[12:8], nv_bus_req.be, nv_bus_req.wdata, nv_bus_req.pair,
                       nv_bus_req.addr[IOB_AW-1:13], nv_bus_req.addr[8:0], nv_bus_rsp.err,
                       nv_bus_rsp.rdata};

endmodule
