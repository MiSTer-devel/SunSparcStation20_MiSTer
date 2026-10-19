// SPDX-License-Identifier: GPL-2.0-or-later
//
// fdc82077: the SPARCstation 20's Intel 82077AA floppy controller, with no
// drive attached (PA 0xF_F170_0000, 8 byte registers).
//
// From: Intel 290166-007 82077AA datasheet (§2.1 registers, §2.2 resets,
//   §5 command set, §7.4 drive polling, §8 programming); behaviour of the
//   corner cases cross-checked with QEMU hw/block/fdc.c and fdc-sysbus.c
//   (the sun4m wiring: the registers at their natural offsets 0-7), and the
//   expectations of tests/cpu/src/t_chipset.S (t_fdc).
//
// Registers (byte offsets; AT mode, as the sun4m uses the chip):
//   0 SRA (R)  bit 7 INT pending, bit 6 = 1 (no drive 2); the rest 0
//   1 SRB (R)  0xC0 | DR0 select (5) | motor enables (1:0)
//   2 DOR (RW) 1:0 drive select, 2 /RESET (0 = held in reset), 3 DMAGATE,
//              7:4 motor enables. Power-on state 0: in reset.
//   3 TDR (RW) 1:0 tape select (stored, unused)
//   4 MSR (R) / DSR (W)   MSR: 7 RQM, 6 DIO, 4 CB (command busy); 0 in reset.
//                         DSR: 7 software reset (self-clearing), 1:0 rate
//   5 FIFO (RW) command bytes in, result bytes out
//   6 reserved (reads 0)
//   7 DIR (R) = 0 (no disk change) / CCR (W) 1:0 data rate
//
// A byte access picks the register of the lowest enabled byte lane
// (big-endian: be[3] = offset 0 of the word); anything wider than a byte is
// not something the Sun software does. Higher address bits alias.
//
// With no drive the commands that move data cannot succeed. The controller
// still answers as the datasheet's state machine does, completing each
// command immediately:
//   reset      leaving reset (DOR /RESET 0->1 or a DSR software reset) raises
//              the polling interrupt unless CONFIGURE disabled polling; four
//              SENSE INTERRUPT STATUS then return ST0 = 0xC0 + drive, PCN 0.
//   RECALIBRATE  no TRK0 ever comes: interrupt, ST0 = 0x70 + drive (abnormal
//              termination, seek end, equipment check), PCN 0.
//   SEEK / RELATIVE SEEK  interrupt, ST0 = 0x20 + drive, PCN = the new track
//              (step pulses go nowhere, as QEMU does).
//   READ/WRITE/DELETED/TRACK/VERIFY/SCAN, FORMAT, READ ID  seven result
//              bytes: ST0 = 0x40 + head/drive (abnormal termination), ST1 =
//              0x01 (missing address mark), ST2 = 0, then C H R N echoed
//              from the command (READ ID: PCN, head, 1, 2); interrupt, which
//              the first result byte read clears.
//   SENSE DRIVE STATUS  ST3 = 0x38 + head/drive: READY is internally tied
//              true, TRK0 set, two-sided; not write protected.
//   SENSE INTERRUPT STATUS with nothing pending: the single byte 0x80.
//   VERSION 0x90, DUMPREG (10 bytes), CONFIGURE, SPECIFY, PERPENDICULAR
//   MODE, LOCK are real. Any other opcode (including the 82078-only ones)
//   is invalid: result 0x80.
//
// INT is gated by DMAGATE (DOR bit 3) as in the datasheet's AT mode. The
// terminal-count input is accepted but unused: no transfer ever runs.
//
// Interface contract: iob_req_t/iob_rsp_t of iobus_pkg, addr = offset from
// 0xF_F170_0000, ack registered, exactly one cycle. irq_o is a level
// (the integrator maps it to SI_FL).

module fdc82077
  import iobus_pkg::*;
(
  input  logic     clk,
  input  logic     rst,

  input  iob_req_t bus_i,
  output iob_rsp_t bus_o,

  input  logic     tc_i,           // terminal count (AUXIO); unused with no drive
  output logic     irq_o           // level, to SI_FL
);

  // ---- command classes ----------------------------------------------------
  localparam logic [3:0] C_INVALID = 4'd0, C_XFER = 4'd1, C_FORMAT = 4'd2,
                         C_READID = 4'd3, C_SPECIFY = 4'd4, C_SENSEDRV = 4'd5,
                         C_RECAL = 4'd6, C_SENSEINT = 4'd7, C_SEEK = 4'd8,
                         C_RELSEEK = 4'd9, C_CONFIG = 4'd10, C_PERP = 4'd11,
                         C_LOCK = 4'd12, C_DUMPREG = 4'd13, C_VERSION = 4'd14;

  // {class, parameter-byte count} of an opcode
  function automatic logic [7:0] cmd_info(input logic [7:0] op);
    logic [3:0] c, n;
    c = C_INVALID; n = 4'd0;
    if ((op & 8'h1f) == 8'h06 || (op & 8'h3f) == 8'h05 || (op & 8'hbf) == 8'h02 ||
        (op & 8'h1f) == 8'h0c || (op & 8'h3f) == 8'h09 || (op & 8'h1f) == 8'h16 ||
        (op & 8'h1f) == 8'h11 || (op & 8'h1f) == 8'h19 || (op & 8'h1f) == 8'h1d) begin
      c = C_XFER; n = 4'd8;
    end else if ((op & 8'hbf) == 8'h0d) begin c = C_FORMAT;   n = 4'd5;
    end else if ((op & 8'hbf) == 8'h0a) begin c = C_READID;   n = 4'd1;
    end else if (op == 8'h03)           begin c = C_SPECIFY;  n = 4'd2;
    end else if (op == 8'h04)           begin c = C_SENSEDRV; n = 4'd1;
    end else if (op == 8'h07)           begin c = C_RECAL;    n = 4'd1;
    end else if (op == 8'h08)           begin c = C_SENSEINT; n = 4'd0;
    end else if (op == 8'h0f)           begin c = C_SEEK;     n = 4'd2;
    end else if ((op & 8'hbf) == 8'h8f) begin c = C_RELSEEK;  n = 4'd2;
    end else if (op == 8'h13)           begin c = C_CONFIG;   n = 4'd3;
    end else if (op == 8'h12)           begin c = C_PERP;     n = 4'd1;
    end else if ((op & 8'h7f) == 8'h14) begin c = C_LOCK;     n = 4'd0;
    end else if (op == 8'h0e)           begin c = C_DUMPREG;  n = 4'd0;
    end else if (op == 8'h10)           begin c = C_VERSION;  n = 4'd0;
    end
    return {c, n};
  endfunction

  // ---- state ---------------------------------------------------------------
  typedef enum logic [1:0] {P_CMD, P_EXEC, P_RES} phase_t;

  phase_t      phase;
  logic [3:0]  pos, len;            // FIFO index; bytes expected / returned
  logic [7:0]  fifo [16];
  logic        res_irq;             // the first result byte read clears INT

  logic [7:0]  dor;
  logic [1:0]  tdr, rate;
  logic        intpend;
  logic [7:0]  pend_st0;            // ST0 for the next SENSE INTERRUPT STATUS
  logic [1:0]  pend_ds;
  logic [2:0]  rst_cnt;             // polling-reset interrupts still to report
  logic [7:0]  pcn [4];
  logic [7:0]  spec0, spec1;        // SPECIFY bytes
  logic [7:0]  config_r;            // CONFIGURE byte 2: EIS EFIFO POLL FIFOTHR
  logic [7:0]  pretrk;
  logic        lock;
  logic [5:0]  perp;                // D3..D0 GAP WGATE
  logic [7:0]  eot;                 // SC/EOT as DUMPREG shows it

  assign irq_o = intpend & dor[3];

  // ---- the command that is in the FIFO ----------------------------------------
  logic [3:0] cls;
  logic [1:0] ds;
  logic       hd;
  logic [7:0] ci_f0, ci_wb;               // cmd_info of the FIFO's first byte / the byte written
  assign ci_f0 = cmd_info(fifo[0]);
  assign cls = ci_f0[7:4];
  logic unused_ci;
  assign unused_ci = ^ci_f0[3:0];
  assign ds  = fifo[1][1:0];
  assign hd  = fifo[1][2];

  // ---- register reads ------------------------------------------------------------
  logic [2:0] roff;                 // register addressed by the access
  logic       lane_ok;
  logic [7:0] wbyte;
  assign ci_wb = cmd_info(wbyte);
  logic [7:0] msr;
  logic [7:0] rbyte;

  always_comb begin
    lane_ok = |bus_i.be;
    roff = {bus_i.addr[2], 2'd0};
    if (bus_i.be[3])      roff[1:0] = 2'd0;
    else if (bus_i.be[2]) roff[1:0] = 2'd1;
    else if (bus_i.be[1]) roff[1:0] = 2'd2;
    else                  roff[1:0] = 2'd3;
    case (roff[1:0])
      2'd0:    wbyte = bus_i.wdata[31:24];
      2'd1:    wbyte = bus_i.wdata[23:16];
      2'd2:    wbyte = bus_i.wdata[15:8];
      default: wbyte = bus_i.wdata[7:0];
    endcase
  end

  always_comb begin
    msr = 8'h00;
    if (dor[2])
      msr = {(phase != P_EXEC), (phase == P_RES), 1'b0,
             (phase != P_CMD) || (pos != 4'd0), 4'b0000};
    case (roff)
      3'd0:    rbyte = {intpend, 7'b1000000};
      3'd1:    rbyte = {2'b11, dor[0], 3'b000, dor[5:4]};
      3'd2:    rbyte = dor;
      3'd3:    rbyte = {6'b0, tdr};
      3'd4:    rbyte = msr;
      3'd5:    rbyte = (dor[2] && phase == P_RES) ? fifo[pos] : 8'h00;
      default: rbyte = 8'h00;           // 6 reserved, 7 DIR: no disk change
    endcase
  end

  // ---- the controller --------------------------------------------------------------
  logic access;
  logic clr, rel;                   // a software reset: clear / leave it
  logic [7:0] nt;                   // relative seek target
  logic [1:0] sidx;                 // drive the next reset SENSE INT reports

  assign sidx = 2'(3'd4 - rst_cnt);

  assign access = bus_i.req & ~bus_o.ack & (phase != P_EXEC);

  always_comb begin
    clr = 1'b0;
    rel = 1'b0;
    if (access && bus_i.we && lane_ok) begin
      if (roff == 3'd2) begin
        clr = !wbyte[2];
        rel = wbyte[2] && !dor[2];
      end else if (roff == 3'd4 && dor[2] && wbyte[7]) begin
        clr = 1'b1;
        rel = 1'b1;
      end
    end
    // RELATIVE SEEK target; DIR (opcode bit 6) = 1 steps in
    if (fifo[0][6])
      nt = ({1'b0, pcn[ds]} + {1'b0, fifo[2]} > 9'd255) ? 8'hff : pcn[ds] + fifo[2];
    else
      nt = (pcn[ds] > fifo[2]) ? pcn[ds] - fifo[2] : 8'h00;
  end

  always_ff @(posedge clk) begin
    bus_o.ack <= 1'b0;
    bus_o.err <= 1'b0;

    if (phase == P_EXEC) begin
      // The command is complete in the FIFO; run it in one step.
      phase <= P_CMD; pos <= 4'd0; len <= 4'd1;
      case (cls)
        C_XFER: begin
          phase <= P_RES; len <= 4'd7; res_irq <= 1'b1; intpend <= 1'b1;
          eot <= fifo[6];
          fifo[1] <= 8'h01;  fifo[2] <= 8'h00;
          fifo[3] <= fifo[2]; fifo[4] <= fifo[3];
          fifo[5] <= fifo[4]; fifo[6] <= fifo[5];
          fifo[0] <= {2'b01, 3'b000, hd, ds};
        end
        C_FORMAT: begin
          phase <= P_RES; len <= 4'd7; res_irq <= 1'b1; intpend <= 1'b1;
          eot <= fifo[3];
          fifo[0] <= {2'b01, 3'b000, hd, ds};
          fifo[1] <= 8'h01;  fifo[2] <= 8'h00;
          fifo[3] <= pcn[ds]; fifo[4] <= {7'b0, hd};
          fifo[5] <= 8'h01;  fifo[6] <= fifo[2];
        end
        C_READID: begin
          phase <= P_RES; len <= 4'd7; res_irq <= 1'b1; intpend <= 1'b1;
          fifo[0] <= {2'b01, 3'b000, hd, ds};
          fifo[1] <= 8'h01;  fifo[2] <= 8'h00;
          fifo[3] <= pcn[ds]; fifo[4] <= {7'b0, hd};
          fifo[5] <= 8'h01;  fifo[6] <= 8'h02;
        end
        C_SPECIFY: begin
          spec0 <= fifo[1]; spec1 <= fifo[2];
        end
        C_SENSEDRV: begin
          phase <= P_RES; len <= 4'd1; res_irq <= 1'b0;
          fifo[0] <= {2'b00, 3'b111, hd, ds};        // RDY, T0, bit 3 fixed
        end
        C_RECAL: begin
          pcn[ds] <= 8'h00;
          pend_st0 <= {5'b01110, 1'b0, ds};         // 0x70 + drive
          pend_ds <= ds; intpend <= 1'b1; rst_cnt <= 3'd0;
        end
        C_SEEK: begin
          pcn[ds] <= fifo[2];
          pend_st0 <= {6'b001000, ds};              // 0x20 + drive
          pend_ds <= ds; intpend <= 1'b1; rst_cnt <= 3'd0;
        end
        C_RELSEEK: begin
          pcn[ds] <= nt;
          pend_st0 <= {6'b001000, ds};
          pend_ds <= ds; intpend <= 1'b1; rst_cnt <= 3'd0;
        end
        C_SENSEINT: begin
          phase <= P_RES; res_irq <= 1'b0;
          if (rst_cnt != 3'd0) begin
            // the polling reset reports drives 0-3 in turn
            len <= 4'd2;
            fifo[0] <= {6'b110000, sidx};
            fifo[1] <= pcn[sidx];
            rst_cnt <= rst_cnt - 3'd1;
            intpend <= 1'b0;
          end else if (intpend) begin
            len <= 4'd2;
            fifo[0] <= pend_st0;
            fifo[1] <= pcn[pend_ds];
            intpend <= 1'b0;
          end else begin
            len <= 4'd1;
            fifo[0] <= 8'h80;
          end
        end
        C_CONFIG: begin
          config_r <= {1'b0, fifo[2][6:0]}; pretrk <= fifo[3];
        end
        C_PERP: begin
          if (fifo[1][7]) perp[5:2] <= fifo[1][5:2];
          perp[1:0] <= fifo[1][1:0];
        end
        C_LOCK: begin
          lock <= fifo[0][7];
          phase <= P_RES; len <= 4'd1; res_irq <= 1'b0;
          fifo[0] <= {3'b000, fifo[0][7], 4'b0000};
        end
        C_DUMPREG: begin
          phase <= P_RES; len <= 4'd10; res_irq <= 1'b0;
          fifo[0] <= pcn[0]; fifo[1] <= pcn[1]; fifo[2] <= pcn[2]; fifo[3] <= pcn[3];
          fifo[4] <= spec0;  fifo[5] <= spec1;  fifo[6] <= eot;
          fifo[7] <= {lock, 1'b0, perp};
          fifo[8] <= config_r; fifo[9] <= pretrk;
        end
        C_VERSION: begin
          phase <= P_RES; len <= 4'd1; res_irq <= 1'b0;
          fifo[0] <= 8'h90;
        end
        default: begin
          phase <= P_RES; len <= 4'd1; res_irq <= 1'b0;
          fifo[0] <= 8'h80;
        end
      endcase
    end

    if (access) begin
      bus_o.ack   <= 1'b1;
      bus_o.rdata <= '0;
      if (!bus_i.we && lane_ok) begin
        case (roff[1:0])
          2'd0:    bus_o.rdata <= {rbyte, 24'b0};
          2'd1:    bus_o.rdata <= {8'b0, rbyte, 16'b0};
          2'd2:    bus_o.rdata <= {16'b0, rbyte, 8'b0};
          default: bus_o.rdata <= {24'b0, rbyte};
        endcase
        // reading the FIFO steps through the result
        if (roff == 3'd5 && dor[2] && phase == P_RES) begin
          if (res_irq && pos == 4'd0) begin
            intpend <= 1'b0; res_irq <= 1'b0;
          end
          pos <= pos + 4'd1;
          if (pos + 4'd1 == len) begin
            phase <= P_CMD; pos <= 4'd0; len <= 4'd1;
          end
        end
      end else if (bus_i.we && lane_ok) begin
        case (roff)
          3'd2: dor <= wbyte;               // DOR
          3'd3: if (dor[2]) tdr <= wbyte[1:0];
          3'd4: if (dor[2]) begin           // DSR
            rate <= wbyte[1:0];
          end
          3'd5: if (dor[2] && phase == P_CMD) begin   // FIFO: command byte
            fifo[pos] <= wbyte;
            pos <= pos + 4'd1;
            if (pos == 4'd0) begin
              if (ci_wb[7:4] == C_INVALID) begin
                fifo[0] <= 8'h80;
                phase <= P_RES; pos <= 4'd0; len <= 4'd1; res_irq <= 1'b0;
              end else if (ci_wb[3:0] == 4'd0) begin
                phase <= P_EXEC; len <= 4'd1;
              end else begin
                len <= ci_wb[3:0] + 4'd1;
              end
            end else if (pos + 4'd1 == len) begin
              phase <= P_EXEC;
            end
          end
          3'd7: if (dor[2]) rate <= wbyte[1:0];       // CCR
          default: ;
        endcase
      end
    end

    // A software reset (DOR /RESET low, or the DSR bit) clears the core. The
    // configuration survives when LOCK is set; leaving the reset starts the
    // drive polling, whose single interrupt SENSE INTERRUPT STATUS reports
    // four times.
    if (clr) begin
      phase <= P_CMD; pos <= 4'd0; len <= 4'd1;
      intpend <= 1'b0; res_irq <= 1'b0; rst_cnt <= 3'd0;
      for (int i = 0; i < 4; i++) pcn[i] <= 8'h00;
      perp[1:0] <= 2'b00;
      if (!lock) begin
        config_r[5] <= 1'b1; config_r[3:0] <= 4'd0; pretrk <= 8'h00;
      end
    end
    if (rel && !config_r[4]) begin
      intpend <= 1'b1; rst_cnt <= 3'd4; pend_st0 <= 8'hc0;
    end

    if (rst) begin
      phase <= P_CMD; pos <= 4'd0; len <= 4'd1; res_irq <= 1'b0;
      dor <= 8'h00; tdr <= 2'd0; rate <= 2'd2;
      intpend <= 1'b0; rst_cnt <= 3'd0; pend_st0 <= 8'h00; pend_ds <= 2'd0;
      for (int i = 0; i < 4; i++) pcn[i] <= 8'h00;
      spec0 <= 8'h00; spec1 <= 8'h00; eot <= 8'h00;
      config_r <= 8'h20; pretrk <= 8'h00; lock <= 1'b0; perp <= 6'd0;
      bus_o.ack <= 1'b0; bus_o.rdata <= '0;
    end
  end

  // The data rate is kept (DSR/CCR) but drives nothing: DENSEL is AUXIO's on
  // the sun4m and there is no drive. The byte lane comes from be, not addr.
  logic unused_ok;
  assign unused_ok = &{1'b0, tc_i, rate, bus_i.pair, bus_i.addr[IOB_AW-1:3],
                       bus_i.addr[1:0]};

endmodule
