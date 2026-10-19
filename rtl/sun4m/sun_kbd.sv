// SPDX-License-Identifier: GPL-2.0-or-later
//
// sun_kbd: a Sun Type 5 keyboard as the host sees it on the keyboard/mouse
// ESCC's channel A, driven by hps_io's PS/2 key events.
//
// From: the SPARC International Keyboard Specification (1999) §3.1 (the
//   key numbers and make codes) and §3.2 (the host commands and the
//   keyboard's replies); the Type 4/5 layouts in MAME's sunkbd/hlekbd.cpp
//   (comment block; the Type 5 PC layout is the one used here) and its
//   command/reply behaviour; QEMU hw/char/escc.c (reset/layout replies);
//   the PC-keyboard chords (Right Alt + F keys as L-keys) are our own. The PS/2 set 2 ->
//   Sun table below is written new.
//
// Host -> keyboard (byte taps of the ESCC, tx_*): 01 reset (clears the
// queue; reply FF 04, the make codes of the keys held, 7F), 02/03 bell
// on/off, 0A/0B click on/off, 0E + byte LEDs (bit0 Num, 1 Compose, 2 Scroll,
// 3 Caps), 0F (and 07) layout request (reply FE, layout byte).
// Keyboard -> host: make = key number, break = number | 80, and 7F (idle)
// after a break that leaves no key down. A key repeat (a make of a key
// already down) is dropped: the host repeats keys itself.
//
// The ESCC takes bytes from its byte port at once, so the keyboard line's
// 1200 baud 8N1 is paced here: a byte reaches the ESCC BYTE_CLKS after the
// one before (or after it was queued, when the line was idle), which also
// gives the 8 ms before the reset reply that NetBSD's kbd driver wants.
// A byte waits while the ESCC's receiver is off or its FIFO full.
//
// PC keys that a Sun has and a PC lacks (PLAN B2): Right Alt + F1..F11 are
// L1 Stop, L2 Again, L3 Props, L4 Undo, L5 Front, L6 Copy, L7 Open, L8 Paste,
// L9 Find, L10 Cut, Help. A function key keeps the meaning it went down
// with until released. Right Alt with any other key is AltGraph (0D): it
// goes down just before that key and comes up with Right Alt; nothing is
// sent for Right Alt alone, nor for Right Alt while an L-key is held
// (Stop-A with Stop and A down is the abort sequence, with no AltGraph
// between). Pause arrives from hps_io as the extended 77 (or 7E, Ctrl+Break),
// a make only (PS/2 has no break for it, and Main sends none: the board's
// kbd test saw Pause stay held): its break is made here, after the make;
// Print Screen as the extended 7C (the extended 12 "fake shift" is
// dropped); the Menu key is Compose, the Windows keys the Meta diamonds.
//
// Left out: Type 5's power/volume keys, the Kana LED and key-click timing
// beyond a pulse (click_o is one cycle per make; kbd_beep shapes it).

module sun_kbd #(
  parameter int CLK_HZ     = 55_000_000,
  parameter int BAUD       = 1200,
  parameter int BYTE_CLKS  = CLK_HZ * 10 / BAUD   // clocks per 8N1 character
)(
  input  logic         clk,
  input  logic         rst,

  input  logic [10:0]  ps2_key_i,       // [7:0] set-2 code, [8] E0, [9] pressed, [10] toggles per event
  input  logic [7:0]   layout_i,        // the Type 5 layout code to report

  // the ESCC channel A byte ports (escc.sv tx_byte_a_*, rx_byte_a_*)
  input  logic [7:0]   tx_byte_i,       // host -> keyboard
  input  logic         tx_byte_valid_i,
  output logic [7:0]   rx_byte_o,       // keyboard -> host
  output logic         rx_byte_valid_o,
  input  logic         rx_byte_ready_i,

  output logic         bell_o,          // level: bell on
  output logic         click_o,         // one-clock pulse per key make with click on
  output logic [3:0]   leds_o,          // Num, Compose, Scroll, Caps (bit 0..3)
  output logic         any_key_o        // some key is down
);

  // ---------------------------------------------------------------------
  // PS/2 set 2 -> Sun Type 5 key number
  // ---------------------------------------------------------------------
  // {valid, key[6:0]}; the extended Right Alt (E0 11) is handled apart.
  function automatic logic [7:0] to_sun(input logic ext, input logic [7:0] c);
    logic [6:0] k;
    logic       v;
    v = 1'b1;
    k = 7'h00;
    if (!ext) begin
      case (c)
        8'h01: k = 7'h12;  8'h03: k = 7'h0C;  8'h04: k = 7'h08;  8'h05: k = 7'h05;   // F9 F5 F3 F1
        8'h06: k = 7'h06;  8'h07: k = 7'h0B;  8'h09: k = 7'h07;  8'h0A: k = 7'h11;   // F2 F12 F10 F8
        8'h0B: k = 7'h0E;  8'h0C: k = 7'h0A;  8'h78: k = 7'h09;  8'h83: k = 7'h10;   // F6 F4 F11 F7
        8'h0D: k = 7'h35;  8'h0E: k = 7'h2A;  8'h11: k = 7'h13;  8'h12: k = 7'h63;   // Tab ` LAlt LShift
        8'h14: k = 7'h4C;  8'h15: k = 7'h36;  8'h16: k = 7'h1E;  8'h1A: k = 7'h64;   // LCtrl Q 1 Z
        8'h1B: k = 7'h4E;  8'h1C: k = 7'h4D;  8'h1D: k = 7'h37;  8'h1E: k = 7'h1F;   // S A W 2
        8'h21: k = 7'h66;  8'h22: k = 7'h65;  8'h23: k = 7'h4F;  8'h24: k = 7'h38;   // C X D E
        8'h25: k = 7'h21;  8'h26: k = 7'h20;  8'h29: k = 7'h79;  8'h2A: k = 7'h67;   // 4 3 Space V
        8'h2B: k = 7'h50;  8'h2C: k = 7'h3A;  8'h2D: k = 7'h39;  8'h2E: k = 7'h22;   // F T R 5
        8'h31: k = 7'h69;  8'h32: k = 7'h68;  8'h33: k = 7'h52;  8'h34: k = 7'h51;   // N B H G
        8'h35: k = 7'h3B;  8'h36: k = 7'h23;  8'h3A: k = 7'h6A;  8'h3B: k = 7'h53;   // Y 6 M J
        8'h3C: k = 7'h3C;  8'h3D: k = 7'h24;  8'h3E: k = 7'h25;  8'h41: k = 7'h6B;   // U 7 8 ,
        8'h42: k = 7'h54;  8'h43: k = 7'h3D;  8'h44: k = 7'h3E;  8'h45: k = 7'h27;   // K I O 0
        8'h46: k = 7'h26;  8'h49: k = 7'h6C;  8'h4A: k = 7'h6D;  8'h4B: k = 7'h55;   // 9 . / L
        8'h4C: k = 7'h56;  8'h4D: k = 7'h3F;  8'h4E: k = 7'h28;  8'h52: k = 7'h57;   // ; P - '
        8'h54: k = 7'h40;  8'h55: k = 7'h29;  8'h58: k = 7'h77;  8'h59: k = 7'h6E;   // [ = Caps RShift
        8'h5A: k = 7'h59;  8'h5B: k = 7'h41;  8'h5D: k = 7'h58;  8'h61: k = 7'h7C;   // Return ] \ ISO-<
        8'h66: k = 7'h2B;  8'h76: k = 7'h1D;  8'h77: k = 7'h62;  8'h7E: k = 7'h17;   // Bksp Esc NumLk ScrLk
        8'h69: k = 7'h70;  8'h72: k = 7'h71;  8'h7A: k = 7'h72;  8'h6B: k = 7'h5B;   // KP1 KP2 KP3 KP4
        8'h73: k = 7'h5C;  8'h74: k = 7'h5D;  8'h6C: k = 7'h44;  8'h75: k = 7'h45;   // KP5 KP6 KP7 KP8
        8'h7D: k = 7'h46;  8'h70: k = 7'h5E;  8'h71: k = 7'h32;  8'h79: k = 7'h7D;   // KP9 KP0 KP. KP+
        8'h7B: k = 7'h47;  8'h7C: k = 7'h2F;                                          // KP- KP*
        default: v = 1'b0;
      endcase
    end else begin
      case (c)
        8'h14: k = 7'h4C;  8'h1F: k = 7'h78;  8'h27: k = 7'h7A;  8'h2F: k = 7'h43;   // RCtrl LWin RWin Menu
        8'h4A: k = 7'h2E;  8'h5A: k = 7'h5A;  8'h70: k = 7'h2C;  8'h6C: k = 7'h34;   // KP/ KPEnter Ins Home
        8'h7D: k = 7'h60;  8'h71: k = 7'h42;  8'h69: k = 7'h4A;  8'h7A: k = 7'h7B;   // PgUp Del End PgDn
        8'h75: k = 7'h14;  8'h6B: k = 7'h18;  8'h72: k = 7'h1B;  8'h74: k = 7'h1C;   // Up Left Down Right
        8'h7C: k = 7'h16;  8'h77: k = 7'h15;  8'h7E: k = 7'h15;                        // PrSc Pause Pause
        default: v = 1'b0;
      endcase
    end
    return {v, k};
  endfunction

  // F1..F11 -> index 0..10 (bit 7 set: not an F key), and the Sun key the
  // index means with Right Alt held
  function automatic logic [3:0] fidx(input logic ext, input logic [7:0] c);
    logic [3:0] i;
    i = 4'hF;
    if (!ext) begin
      case (c)
        8'h05: i = 4'd0;  8'h06: i = 4'd1;  8'h04: i = 4'd2;  8'h0C: i = 4'd3;
        8'h03: i = 4'd4;  8'h0B: i = 4'd5;  8'h83: i = 4'd6;  8'h0A: i = 4'd7;
        8'h01: i = 4'd8;  8'h09: i = 4'd9;  8'h78: i = 4'd10;
        default: i = 4'hF;
      endcase
    end
    return i;
  endfunction

  function automatic logic [6:0] lkey(input logic [3:0] i);
    case (i)
      4'd0:    return 7'h01;   // L1 Stop
      4'd1:    return 7'h03;   // L2 Again
      4'd2:    return 7'h19;   // L3 Props
      4'd3:    return 7'h1A;   // L4 Undo
      4'd4:    return 7'h31;   // L5 Front
      4'd5:    return 7'h33;   // L6 Copy
      4'd6:    return 7'h48;   // L7 Open
      4'd7:    return 7'h49;   // L8 Paste
      4'd8:    return 7'h5F;   // L9 Find
      4'd9:    return 7'h61;   // L10 Cut
      default: return 7'h76;   // Help
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // The output queue (host-bound bytes) and the baud pacing
  // ---------------------------------------------------------------------
  localparam int QD = 32;
  logic [7:0] q [QD];
  logic [5:0] q_cnt;
  logic [4:0] q_wp, q_rp;
  logic       q_push, q_pop, q_clear;
  logic [7:0] q_din;

  always_ff @(posedge clk) begin
    if (rst || q_clear) begin
      q_cnt <= '0;
      q_wp  <= '0;
      q_rp  <= '0;
    end else begin
      if (q_push) begin
        q[q_wp] <= q_din;
        q_wp    <= q_wp + 5'd1;
      end
      if (q_pop) q_rp <= q_rp + 5'd1;
      q_cnt <= q_cnt + {5'd0, q_push} - {5'd0, q_pop};
    end
  end

  logic        pend;                    // a byte waits for the ESCC
  logic [7:0]  pend_byte;
  logic [31:0] baud_cnt;

  assign q_pop = !pend && q_cnt != 6'd0 && baud_cnt == 32'(BYTE_CLKS - 1);

  assign rx_byte_o       = pend_byte;
  assign rx_byte_valid_o = pend && rx_byte_ready_i;

  always_ff @(posedge clk) begin
    if (rst || q_clear) begin
      pend     <= 1'b0;
      baud_cnt <= '0;
    end else begin
      if (rx_byte_valid_o) pend <= 1'b0;
      if (q_pop) begin
        pend      <= 1'b1;
        pend_byte <= q[q_rp];
        baud_cnt  <= '0;
      end else if (!pend && q_cnt != 6'd0) begin
        baud_cnt <= baud_cnt + 32'd1;
      end else if (!pend) begin
        baud_cnt <= '0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Host commands and the replies that scan the held keys
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {R_IDLE, R_FF, R_TYPE, R_KEYS, R_7F, R_FE, R_LAY} rep_t;
  rep_t       rep;
  logic [6:0] scan;
  logic       scan_ph;                  // R_KEYS: 0 read the key's bit, 1 push it
  logic       led_arg;
  logic       click_en;
  logic       cmd_reset;

  assign cmd_reset = tx_byte_valid_i && !led_arg && tx_byte_i == 8'h01;
  assign q_clear   = cmd_reset;

  // ---------------------------------------------------------------------
  // The keys down: a bit per Sun key number, in RAM (one copy per read
  // port: the event's key, the reset reply's scan; both read a cycle ahead),
  // cleared by a sweep after reset; the AltGraph key (0x0D), which goes down
  // and up in the same event as another key, in a flop of its own; n_held
  // counts the keys down (the idle byte follows the last release). In
  // flops, the bits with their decoders cost ~350 ALUTs.
  // ---------------------------------------------------------------------
  (* ramstyle = "no_rw_check" *) logic held_a [128];
  (* ramstyle = "no_rw_check" *) logic held_b [128];
  logic       held_ev_q, held_sc_q;     // the bits read: the event's key, the scan's
  logic       held_we, held_wv;         // the event's write ...
  logic       ev_take;                  // ... in the cycle the event is decoded (below)
  logic       altgr_held;
  logic [7:0] n_held;
  logic       clr_busy;                 // the sweep after reset
  logic [6:0] clr_idx;
  logic [6:0] dec_key;                  // (the event's Sun key, below)

  always_ff @(posedge clk) begin
    if (clr_busy) begin
      held_a[clr_idx] <= 1'b0;
      held_b[clr_idx] <= 1'b0;
    end else if (ev_take && held_we && dec_key != 7'h0D) begin
      held_a[dec_key] <= held_wv;
      held_b[dec_key] <= held_wv;
    end
    held_ev_q <= held_a[dec_key];
    held_sc_q <= held_b[scan];
  end
  logic held_ev, held_sc;               // ... with the AltGraph key from its flop
  assign held_ev = (dec_key == 7'h0D) ? altgr_held : held_ev_q;
  assign held_sc = (scan == 7'h0D) ? altgr_held : held_sc_q;

  assign any_key_o = n_held != 8'd0;

  // the reply pusher's byte (valid in rep_push when it pushes this cycle)
  logic       rep_push;
  logic [7:0] rep_byte;
  always_comb begin
    rep_push = 1'b0;
    rep_byte = 8'h00;
    case (rep)
      R_FF:   begin rep_push = 1'b1; rep_byte = 8'hFF; end
      R_TYPE: begin rep_push = 1'b1; rep_byte = 8'h04; end
      R_KEYS: begin rep_push = scan_ph && held_sc; rep_byte = {1'b0, scan}; end
      R_7F:   begin rep_push = 1'b1; rep_byte = 8'h7F; end
      R_FE:   begin rep_push = 1'b1; rep_byte = 8'hFE; end
      R_LAY:  begin rep_push = 1'b1; rep_byte = layout_i; end
      default: ;
    endcase
  end
  logic rep_busy, q_full;
  assign rep_busy = (rep != R_IDLE);
  assign q_full   = (q_cnt == 6'(QD));

  // ---------------------------------------------------------------------
  // The key events
  // ---------------------------------------------------------------------
  logic        tog_q;
  logic        pause_brk;                // a Pause make was taken: its break follows
  logic        ev_pend, ev_ext, ev_make;
  logic        ev_rdy;                   // ev_pend for a cycle: the key's bit has been read
  logic [7:0]  ev_code;

  logic        ralt_down, altgr_sent;
  logic [10:0] chord;                   // F key i went down as an L-key

  // an event is decoded in one cycle into up to three queue bytes
  logic [7:0] ob [3];
  logic [1:0] ob_n, ob_i;
  logic       ev_busy, ev_push;

  // decode (combinational, from the latched event and the key state)
  logic [7:0] dec_sun;                  // {valid, key}
  logic [3:0] dec_f;
  logic       dec_is_ralt, dec_is_f, dec_chord_now;
  logic       dec_altgr;                // push AltGraph make first
  logic       dec_emit;                 // push the key's make/break
  logic       dec_idle;                 // push 7F after the break
  logic       dec_ralt_up_altgr;        // Right Alt up with AltGraph down
  logic       altgr_nx;
  logic [7:0] n_held_nx;

  logic [3:0] dec_fi;                   // dec_f, in range for indexing
  assign dec_f  = fidx(ev_ext, ev_code);
  assign dec_fi = (dec_f > 4'd10) ? 4'd0 : dec_f;

  always_comb begin
    dec_sun     = to_sun(ev_ext, ev_code);
    dec_is_ralt = ev_ext && ev_code == 8'h11;
    dec_is_f    = dec_f != 4'hF;
    dec_chord_now = dec_is_f && (ev_make ? ralt_down : chord[dec_fi]);
    dec_key     = dec_sun[6:0];
    if (dec_is_f && dec_chord_now) dec_key = lkey(dec_f);
    dec_altgr   = 1'b0;
    dec_emit    = 1'b0;
    dec_idle    = 1'b0;
    dec_ralt_up_altgr = 1'b0;
    held_we     = 1'b0;
    held_wv     = 1'b0;
    altgr_nx    = altgr_held;
    n_held_nx   = n_held;
    if (dec_is_ralt) begin
      dec_ralt_up_altgr = !ev_make && altgr_sent;
      if (dec_ralt_up_altgr) begin altgr_nx = 1'b0; n_held_nx = n_held - 8'd1; end
      dec_idle = dec_ralt_up_altgr && (n_held_nx == 8'd0);
    end else if (dec_sun[7]) begin
      if (ev_make) begin
        if (!held_ev) begin
          dec_emit = 1'b1;
          dec_altgr = ralt_down && !altgr_sent && !dec_chord_now && (chord == 11'd0);
          held_we = 1'b1; held_wv = 1'b1;
          n_held_nx = n_held + 8'd1;
          if (dec_altgr) begin altgr_nx = 1'b1; n_held_nx = n_held + 8'd2; end
        end
      end else if (held_ev) begin
        dec_emit = 1'b1;
        held_we = 1'b1; held_wv = 1'b0;
        n_held_nx = n_held - 8'd1;
        dec_idle = (n_held_nx == 8'd0);
      end
    end
    // (a key numbered 0x0D, were there one, would live in the flop)
    if (held_we && dec_key == 7'h0D) altgr_nx = held_wv;
  end

  // the decode of the pending event: once its key's bit is read (ev_rdy),
  // the queue has room and no reply is being built or sweep running
  assign ev_take = ev_pend && ev_rdy && !ev_busy && !rep_busy && !clr_busy && q_cnt <= 6'(QD - 4);

  always_ff @(posedge clk) begin
    click_o <= 1'b0;
    ev_rdy  <= ev_pend;
    if (rst) begin
      tog_q      <= ps2_key_i[10];
      pause_brk  <= 1'b0;
      ev_pend    <= 1'b0;
      ev_rdy     <= 1'b0;
      ev_ext     <= 1'b0;
      ev_make    <= 1'b0;
      ev_code    <= 8'h00;
      altgr_held <= 1'b0;
      n_held     <= '0;
      clr_busy   <= 1'b1;
      clr_idx    <= '0;
      ralt_down  <= 1'b0;
      altgr_sent <= 1'b0;
      chord      <= '0;
      ob_n       <= 2'd0;
      ob_i       <= 2'd0;
      ev_busy    <= 1'b0;
      rep        <= R_IDLE;
      scan       <= '0;
      scan_ph    <= 1'b0;
      led_arg    <= 1'b0;
      click_en   <= 1'b0;
      bell_o     <= 1'b0;
      leds_o     <= 4'h0;
    end else begin
      // the sweep that clears the key bits after reset
      if (clr_busy) begin
        clr_idx <= clr_idx + 7'd1;
        if (clr_idx == 7'd127) clr_busy <= 1'b0;
      end

      // capture a PS/2 event (one pending; a second before the first is
      // decoded is dropped -- hps_io events are milliseconds apart)
      tog_q <= ps2_key_i[10];
      if (pause_brk && !ev_pend && !ev_busy) begin
        pause_brk <= 1'b0;
        ev_pend <= 1'b1;
        ev_ext  <= 1'b1;
        ev_make <= 1'b0;
        ev_code <= 8'h77;
      end else if (ps2_key_i[10] != tog_q && !ev_pend && !ev_busy &&
                   !(ps2_key_i[8] && (ps2_key_i[7:0] == 8'h77 || ps2_key_i[7:0] == 8'h7E) && !ps2_key_i[9])) begin
        ev_pend <= 1'b1;
        ev_ext  <= ps2_key_i[8];
        ev_make <= ps2_key_i[9];
        ev_code <= ps2_key_i[7:0];
        if (ps2_key_i[8] && (ps2_key_i[7:0] == 8'h77 || ps2_key_i[7:0] == 8'h7E) && ps2_key_i[9])
          pause_brk <= 1'b1;
      end

      // decode (the key bits are written above: held_we)
      if (ev_take) begin
        ev_pend    <= 1'b0;
        altgr_held <= altgr_nx;
        n_held     <= n_held_nx;
        ob_n    <= 2'd0;
        ob_i    <= 2'd0;
        if (dec_is_ralt) begin
          ralt_down <= ev_make;
          if (dec_ralt_up_altgr) begin
            altgr_sent <= 1'b0;
            ob[0] <= 8'h8D;
            ob[1] <= 8'h7F;
            ob_n  <= dec_idle ? 2'd2 : 2'd1;
            ev_busy <= 1'b1;
          end
        end else if (dec_emit) begin
          if (dec_is_f) chord[dec_fi] <= ev_make ? dec_chord_now : 1'b0;
          if (ev_make) begin
            if (dec_altgr) begin
              altgr_sent <= 1'b1;
              ob[0] <= 8'h0D;
              ob[1] <= {1'b0, dec_key};
              ob_n  <= 2'd2;
            end else begin
              ob[0] <= {1'b0, dec_key};
              ob_n  <= 2'd1;
            end
            click_o <= click_en;
          end else begin
            ob[0] <= {1'b1, dec_key};
            ob[1] <= 8'h7F;
            ob_n  <= dec_idle ? 2'd2 : 2'd1;
          end
          ev_busy <= 1'b1;
        end
      end

      // hand the decoded bytes to the queue one a cycle
      if (ev_push) begin
        if (ob_i + 2'd1 >= ob_n) ev_busy <= 1'b0;
        ob_i <= ob_i + 2'd1;
      end

      // host commands
      if (tx_byte_valid_i) begin
        if (led_arg) begin
          leds_o  <= tx_byte_i[3:0];
          led_arg <= 1'b0;
        end else begin
          case (tx_byte_i)
            8'h01: begin
              bell_o   <= 1'b0;
              click_en <= 1'b0;
              leds_o   <= 4'h0;
              ev_busy  <= 1'b0;
              rep      <= R_FF;
            end
            8'h02: bell_o   <= 1'b1;
            8'h03: bell_o   <= 1'b0;
            8'h0A: click_en <= 1'b1;
            8'h0B: click_en <= 1'b0;
            8'h0E: led_arg  <= 1'b1;
            8'h07, 8'h0F: rep <= R_FE;
            default: ;
          endcase
        end
      end

      // the reply state machine (the held keys two cycles each: the bit is
      // read, then pushed if set)
      if (rep_busy && !tx_byte_valid_i && !q_full && !clr_busy) begin
        case (rep)
          R_FF:   rep <= R_TYPE;
          R_TYPE: begin rep <= R_KEYS; scan <= 7'd0; scan_ph <= 1'b0; end
          R_KEYS: begin
            scan_ph <= !scan_ph;
            if (scan_ph) begin
              scan <= scan + 7'd1;
              if (scan == 7'd127) rep <= R_7F;
            end
          end
          R_7F:   rep <= R_IDLE;
          R_FE:   rep <= R_LAY;
          R_LAY:  rep <= R_IDLE;
          default: rep <= R_IDLE;
        endcase
      end
    end
  end

  // queue writes: the event's bytes, or the reply's
  assign ev_push = ev_busy && !rep_busy && !q_full;

  always_comb begin
    q_push = 1'b0;
    q_din  = 8'h00;
    if (ev_push) begin
      q_push = 1'b1;
      q_din  = ob[ob_i];
    end else if (rep_busy && !tx_byte_valid_i && !q_full && rep_push) begin
      q_push = 1'b1;
      q_din  = rep_byte;
    end
  end

endmodule
