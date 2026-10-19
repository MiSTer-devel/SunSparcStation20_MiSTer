//============================================================================
//  Two Avalon-MM masters onto the one DDRAM port of the stock MiSTer
//  framework (Template_MiSTer provides one port).
//
//  The masters are 64-bit Avalon bridges. They pipeline: a bridge may
//  present its next command as soon as the previous one is accepted, before
//  that read's data has returned, and it may pause between the beats of a
//  write burst. So:
//
//  - Commands are granted combinationally, with no dead cycle, to master 0
//    (video: it must not underrun) unless it is idle, or is waiting to read
//    while the read FIFO is full and master 1 has a command that can go.
//  - Every accepted read pushes {master, burstcount} into a FIFO. The
//    single slave port returns read data in order, so the head of the FIFO
//    says whose beats are arriving. Up to RDEPTH reads may be outstanding,
//    from either master, interleaved with writes.
//  - A write burst locks the port to its master until its last beat, pauses
//    included. If a locked burst sees no beat for 2^WTO cycles (its master
//    was reset mid-burst), the arbiter completes it itself with the byte
//    enables off. Otherwise the slave would wait for those beats forever,
//    and with one shared port, so would the other master: for example the
//    RAM clear after an OSD reset that caught video in a write burst.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module ddram_arb #(parameter AW = 29, parameter RDEPTH = 8, parameter WTO = 16)
(
	input             clk,
	input             reset,

	// master 0 (priority)
	output            m0_waitrequest,
	input       [7:0] m0_burstcount,
	input    [AW-1:0] m0_address,
	input             m0_read,
	input             m0_write,
	input      [63:0] m0_writedata,
	input       [7:0] m0_byteenable,
	output     [63:0] m0_readdata,
	output            m0_readdatavalid,

	// master 1
	output            m1_waitrequest,
	input       [7:0] m1_burstcount,
	input    [AW-1:0] m1_address,
	input             m1_read,
	input             m1_write,
	input      [63:0] m1_writedata,
	input       [7:0] m1_byteenable,
	output     [63:0] m1_readdata,
	output            m1_readdatavalid,

	// slave (DDRAM_*)
	input             s_waitrequest,
	output      [7:0] s_burstcount,
	output   [AW-1:0] s_address,
	output            s_read,
	output            s_write,
	output     [63:0] s_writedata,
	output      [7:0] s_byteenable,
	input      [63:0] s_readdata,
	input             s_readdatavalid
);

localparam PW = $clog2(RDEPTH);

// ------------------------------------------------------ read tracking ----
reg          rf_m  [RDEPTH];          // master of each outstanding read
reg    [7:0] rf_bc [RDEPTH];          // its burst length
reg [PW-1:0] rf_wp, rf_rp;
reg   [PW:0] rf_n;                     // entries in use
reg    [7:0] rbeat;                    // beats received for the head read
wire         rf_full  = (rf_n == RDEPTH);
wire         rf_empty = (rf_n == 0);

// ------------------------------------------------------------ grant ------
reg          wlock;                    // inside a write burst
reg          wsel;                     // its master
reg    [7:0] wcnt;                     // beats still to come
reg  [WTO-1:0] widle;                  // cycles since the burst's last beat
wire         wflush = wlock & (&widle); // master gone: finish the burst

wire m0_can = m0_write | (m0_read & ~rf_full);
wire m1_can = m1_write | (m1_read & ~rf_full);
wire sel    = wlock ? wsel : (m0_can ? 1'b0 : m1_can ? 1'b1 : 1'b0);

wire       g_read  = sel ? m1_read  : m0_read;
wire       g_write = sel ? m1_write : m0_write;
wire [7:0] g_bc    = sel ? m1_burstcount : m0_burstcount;
wire       g_ok    = ~wflush & (wlock | (sel ? m1_can : m0_can));

assign s_burstcount = g_bc;
assign s_address    = sel ? m1_address    : m0_address;
assign s_writedata  = sel ? m1_writedata  : m0_writedata;
assign s_byteenable = wflush ? 8'h00 : sel ? m1_byteenable : m0_byteenable;
assign s_read       = g_ok & g_read & ~wlock;
assign s_write      = wflush | (g_ok & g_write);

assign m0_waitrequest = (g_ok & ~sel) ? s_waitrequest : 1'b1;
assign m1_waitrequest = (g_ok &  sel) ? s_waitrequest : 1'b1;

// ---------------------------------------------------------- read data ----
wire head_m = rf_m[rf_rp];
assign m0_readdata      = s_readdata;
assign m1_readdata      = s_readdata;
assign m0_readdatavalid = s_readdatavalid & ~rf_empty & ~head_m;
assign m1_readdatavalid = s_readdatavalid & ~rf_empty &  head_m;

wire push = s_read & ~s_waitrequest;
wire last = s_readdatavalid & ~rf_empty & (rbeat + 8'd1 == rf_bc[rf_rp]);

always @(posedge clk) begin
	// write burst lock
	// (once flushing, stay flushing until the burst's last beat)
	if (!wlock || (s_write & ~s_waitrequest & ~wflush)) widle <= 0;
	else if (!wflush) widle <= widle + 1'd1;
	if (s_write & ~s_waitrequest) begin
		if (!wlock) begin
			if (g_bc > 8'd1) begin
				wlock <= 1;
				wsel  <= sel;
				wcnt  <= g_bc - 8'd1;
			end
		end
		else begin
			wcnt <= wcnt - 8'd1;
			if (wcnt == 8'd1) wlock <= 0;
		end
	end

	// read FIFO
	if (push) begin
		rf_m[rf_wp]  <= sel;
		rf_bc[rf_wp] <= g_bc;
		rf_wp        <= rf_wp + 1'd1;
	end
	if (s_readdatavalid & ~rf_empty) begin
		if (last) begin
			rbeat <= 0;
			rf_rp <= rf_rp + 1'd1;
		end
		else rbeat <= rbeat + 8'd1;
	end
	rf_n <= rf_n + {{PW{1'b0}}, push} - {{PW{1'b0}}, last};

	if (reset) begin
		wlock <= 0;
		wsel  <= 0;
		wcnt  <= 0;
		widle <= 0;
		rf_wp <= 0;
		rf_rp <= 0;
		rf_n  <= 0;
		rbeat <= 0;
	end
end

endmodule
