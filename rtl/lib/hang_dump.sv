// SPDX-License-Identifier: GPL-2.0-or-later
//
// hang_dump: a board-side debugging aid (ss20_machine's HANG_DUMP). It watches the IU's commits and traps; when no instruction has committed for 2^CBITS
// CPU cycles ("C"), or no trap has been taken for 2^TBITS cycles ("T": a
// running kernel takes clock interrupts, so this is a spin with traps
// off; armed once an interrupt trap and a user-mode commit have both been
// seen since reset, as firmware runs for seconds at PIL 15 without the
// first, and a PROM's POST spins for seconds with traps off after it but
// never runs user code), it snapshots the CPU's state and prints it once as one text line
// on its own serial output (8N1, DIV clocks a bit), which the core muxes
// onto the console's line while act_o is high:
//
//   #HANG<C|T> cpc psr w0 w1 w2 w3 w4 w5 x  r0 .. r15  t0 .. t7  tt0-3 tt4-7
//
// all 32-bit hex: cpc the last committed PC; psr; w0-w5 the CPU module's
// debug words (cpu_module.sv: pipeline + memory request, data request VA,
// data request / state bits, fetch VA, cache and walker states, memory
// PA); x a word of the instantiator's (0 in ss20_machine); r0-r15 the last sixteen
// committed PCs, oldest first; t0-t7 the PCs of the last eight traps,
// oldest first, and their tts packed four to a word (t0's in the top
// byte). After the line it re-arms: a further hang of the other kind, or
// the same kind after progress, prints again.

module hang_dump #(
  parameter int DIV   = 239,          // CPU clocks per bit: 27.5 MHz / 115200
  parameter int CBITS = 24,           // ~0.6 s without a commit
  parameter int TBITS = 27            // ~4.9 s without a trap
)(
  input  logic             clk,
  input  logic             rst,
  input  logic             commit_i,
  input  logic             trap_i,
  input  logic [7:0]       tt_i,
  input  logic [31:0]      pc_i,
  input  logic [31:0]      psr_i,
  input  logic [5:0][31:0] w_i,
  input  logic [31:0]      x_i,
  output logic             txd_o,
  output logic             act_o
);

  localparam int NW = 35;

  logic [31:0] ring [16];
  logic [3:0]  rp;
  logic [31:0] tpc [8];
  logic [7:0]  ttt [8];
  logic [2:0]  tp;
  logic [CBITS:0] nc;                 // saturates with its top bit set
  logic [TBITS:0] nt;                 // wraps
  logic        fire_c, fire_t;
  logic        t_armed;               // an interrupt trap was seen
  logic        u_seen;                // a user-mode commit was seen
  assign fire_c = nc == {1'b0, {CBITS{1'b1}}};
  assign fire_t = t_armed && u_seen && nt == {1'b0, {TBITS{1'b1}}};

  logic [31:0] snap [NW];
  logic        kind;                  // 0: no commit, 1: no trap
  logic        busy;

  // the printer: header "\r\n#HANG" + kind, then per word ' ' + 8 nibbles, then "\r\n"
  logic [1:0]  ph;                    // 0 header, 1 words, 2 tail
  logic [3:0]  hi;
  logic [5:0]  wi;
  logic [3:0]  ni;
  logic        ti;
  logic [7:0]  ch;
  logic [3:0]  nib;

  function automatic logic [7:0] hex(input logic [3:0] v);
    return v < 4'd10 ? 8'h30 + 8'(v) : 8'h57 + 8'(v);
  endfunction

  always_comb begin
    nib = snap[wi][31 - 4*(ni - 4'd1) -: 4];
    case (ph)
      2'd0: case (hi)
              4'd0: ch = 8'h0d;  4'd1: ch = 8'h0a;  4'd2: ch = "#";  4'd3: ch = "H";
              4'd4: ch = "A";    4'd5: ch = "N";    4'd6: ch = "G";
              default: ch = kind ? "T" : "C";
            endcase
      2'd1: ch = ni == 4'd0 ? 8'h20 : hex(nib);
      default: ch = ti ? 8'h0a : 8'h0d;
    endcase
  end

  // 8N1 transmitter
  logic [9:0]  sh;
  logic [3:0]  nbits;
  logic [$clog2(DIV)-1:0] dcnt;
  logic        last;                  // the character in flight is the line's last

  always_ff @(posedge clk) begin
    if (rst) begin
      rp <= '0; tp <= '0; nc <= '0; nt <= '0; t_armed <= 1'b0; u_seen <= 1'b0;
      busy <= 1'b0; kind <= 1'b0;
      ph <= '0; hi <= '0; wi <= '0; ni <= '0; ti <= 1'b0;
      sh <= '1; nbits <= '0; dcnt <= '0; last <= 1'b0;
      txd_o <= 1'b1; act_o <= 1'b0;
    end else begin
      if (commit_i) begin
        ring[rp] <= pc_i; rp <= rp + 4'd1; nc <= '0;
        if (!psr_i[7]) u_seen <= 1'b1;
      end else if (!nc[CBITS]) begin
        nc <= nc + 1'b1;
      end
      if (trap_i) begin
        tpc[tp] <= pc_i; ttt[tp] <= tt_i; tp <= tp + 3'd1; nt <= '0;
        if (tt_i >= 8'h11 && tt_i <= 8'h1f) t_armed <= 1'b1;
      end else begin
        nt <= nt + 1'b1;
      end

      if (!busy && (fire_c || fire_t)) begin
        busy <= 1'b1; act_o <= 1'b1; kind <= !fire_c;
        ph <= '0; hi <= '0; wi <= '0; ni <= '0; ti <= 1'b0;
        snap[0] <= ring[rp - 4'd1];
        snap[1] <= psr_i;
        for (int k = 0; k < 6; k++) snap[2 + k] <= w_i[k];
        snap[8] <= x_i;
        for (int k = 0; k < 16; k++) snap[9 + k] <= ring[rp + 4'(k)];
        for (int k = 0; k < 8; k++) snap[25 + k] <= tpc[tp + 3'(k)];
        snap[33] <= {ttt[tp], ttt[tp + 3'd1], ttt[tp + 3'd2], ttt[tp + 3'd3]};
        snap[34] <= {ttt[tp + 3'd4], ttt[tp + 3'd5], ttt[tp + 3'd6], ttt[tp + 3'd7]};
        nbits <= '0; dcnt <= '0; last <= 1'b0;
      end else if (busy) begin
        if (nbits == 4'd0) begin
          // load the next character (or finish after the last)
          if (last) begin
            busy <= 1'b0; act_o <= 1'b0; txd_o <= 1'b1;
          end else begin
            sh <= {1'b1, ch, 1'b0};
            nbits <= 4'd10; dcnt <= '0;
            // advance the printer
            case (ph)
              2'd0: if (hi == 4'd7) begin ph <= 2'd1; wi <= '0; ni <= '0; end else hi <= hi + 4'd1;
              2'd1: if (ni == 4'd8) begin
                      ni <= '0;
                      if (wi == 6'(NW - 1)) ph <= 2'd2; else wi <= wi + 6'd1;
                    end else ni <= ni + 4'd1;
              default: begin if (ti) last <= 1'b1; ti <= 1'b1; end
            endcase
          end
        end else begin
          txd_o <= sh[0];
          if (dcnt == $bits(dcnt)'(DIV - 1)) begin
            dcnt <= '0; sh <= {1'b1, sh[9:1]}; nbits <= nbits - 4'd1;
          end else begin
            dcnt <= dcnt + 1'b1;
          end
        end
      end
    end
  end

endmodule
