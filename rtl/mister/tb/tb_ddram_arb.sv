// SPDX-License-Identifier: GPL-2.0-or-later
//
// Randomised test of ddram_arb: two masters issuing read and write bursts
// (1-8 beats) to their own address ranges, each waiting for its read data;
// an in-order pipelined slave with random waitrequest, latency and gaps
// between data beats. Every read is checked against a shadow copy.
`timescale 1ns/1ps
module tb;

reg clk = 0, reset = 1;
always #5 clk = ~clk;

wire        m_wait[2];
reg   [7:0] m_bc[2];
reg  [28:0] m_addr[2];
reg         m_rd[2], m_wr[2];
reg  [63:0] m_wd[2];
reg   [7:0] m_be[2];
wire [63:0] m_rdata[2];
wire        m_rvalid[2];

wire        s_wait;
wire  [7:0] s_bc;
wire [28:0] s_addr;
wire        s_rd, s_wr;
wire [63:0] s_wd;
wire  [7:0] s_be;
reg  [63:0] s_rdata;
reg         s_rvalid;

ddram_arb dut (
	.clk(clk), .reset(reset),
	.m0_waitrequest(m_wait[0]), .m0_burstcount(m_bc[0]), .m0_address(m_addr[0]),
	.m0_read(m_rd[0]), .m0_write(m_wr[0]), .m0_writedata(m_wd[0]), .m0_byteenable(m_be[0]),
	.m0_readdata(m_rdata[0]), .m0_readdatavalid(m_rvalid[0]),
	.m1_waitrequest(m_wait[1]), .m1_burstcount(m_bc[1]), .m1_address(m_addr[1]),
	.m1_read(m_rd[1]), .m1_write(m_wr[1]), .m1_writedata(m_wd[1]), .m1_byteenable(m_be[1]),
	.m1_readdata(m_rdata[1]), .m1_readdatavalid(m_rvalid[1]),
	.s_waitrequest(s_wait), .s_burstcount(s_bc), .s_address(s_addr), .s_read(s_rd),
	.s_write(s_wr), .s_writedata(s_wd), .s_byteenable(s_be),
	.s_readdata(s_rdata), .s_readdatavalid(s_rvalid)
);

// ------------------------------------------------------------- slave ----
reg [63:0] mem [0:4095];
reg        wait_r = 1;
assign s_wait = wait_r;
integer    wbeat = 0, wlen = 0;
reg [28:0] waddr;
reg [63:0] rq[$];                        // read beats, snapshot at acceptance
integer    rgap = 0;
integer    i;

initial for (i = 0; i < 4096; i = i + 1) mem[i] = {32'hdead0000 | i, 32'hbeef0000 | i};

// an in-order, pipelined slave: read data is what memory held when the
// read was accepted, returned after a latency, with random gaps
always @(posedge clk) begin
	wait_r   <= ($random & 3) == 0;          // busy 25% of cycles
	s_rvalid <= 0;
	if (!s_wait && s_rd)
		for (i = 0; i < s_bc; i = i + 1) rq.push_back(mem[(s_addr + i) & 4095]);
	if (!s_wait && s_wr) begin
		if (wbeat == 0) begin waddr = s_addr; wlen = s_bc; end
		for (i = 0; i < 8; i = i + 1)
			if (s_be[i]) mem[(waddr + wbeat) & 4095][i*8 +: 8] = s_wd[i*8 +: 8];
		wbeat = wbeat + 1;
		if (wbeat == wlen) wbeat = 0;
	end
	if (rq.size() && rgap == 0 && ($random & 1)) begin
		s_rdata  <= rq[0];
		s_rvalid <= 1;
		void'(rq.pop_front());
	end
	rgap = rq.size() ? (rgap ? rgap - 1 : 0) : 3 + ($random & 7);
end

// ------------------------------------------------------------ masters ----
reg [63:0] shadow [0:4095];
initial for (i = 0; i < 4096; i = i + 1) shadow[i] = {32'hdead0000 | i, 32'hbeef0000 | i};
integer errors = 0, reads = 0, writes = 0;

task automatic master(input integer m, input integer n);
	integer t, len, b, k, got;
	reg [28:0] a;
	reg [63:0] d;
	begin
		for (t = 0; t < n; t = t + 1) begin
			len = 1 + ($unsigned($random) % 8);
			a   = m * 2048 + ($unsigned($random) % 2000);   // own half
			repeat ($unsigned($random) % 4) @(posedge clk);
			if ($random & 1) begin                   // write burst
				for (b = 0; b < len; b = b + 1) begin
					d = {$random, $random};
					m_wr[m] <= 1; m_wd[m] <= d; m_be[m] <= 8'hff;
					if (b == 0) begin m_addr[m] <= a; m_bc[m] <= len; end
					@(posedge clk);
					while (m_wait[m]) @(posedge clk);
					shadow[(a + b) & 4095] = d;
				end
				m_wr[m] <= 0;
				writes = writes + 1;
			end else begin                           // read burst
				m_rd[m] <= 1; m_addr[m] <= a; m_bc[m] <= len;
				@(posedge clk);
				while (m_wait[m]) @(posedge clk);
				m_rd[m] <= 0;
				got = 0;
				while (got < len) begin
					@(posedge clk);
					if (m_rvalid[m]) begin
						if (m_rdata[m] !== shadow[(a + got) & 4095]) begin
							errors = errors + 1;
							if (errors < 10)
								$display("FAIL m%0d read @%0d beat %0d: %h != %h", m, a, got,
								         m_rdata[m], shadow[(a + got) & 4095]);
						end
						got = got + 1;
					end
				end
				reads = reads + 1;
			end
		end
	end
endtask

// a master must never see data it did not ask for
always @(posedge clk)
	if (m_rvalid[0] && m_rvalid[1]) begin $display("FAIL: both rvalid"); errors = errors + 1; end

integer done0 = 0, done1 = 0;
initial begin
	m_rd[0] = 0; m_wr[0] = 0; m_rd[1] = 0; m_wr[1] = 0;
	m_bc[0] = 1; m_bc[1] = 1; m_addr[0] = 0; m_addr[1] = 0;
	repeat (4) @(posedge clk);
	reset <= 0;
	fork
		begin master(0, 3000); done0 = 1; end
		begin master(1, 3000); done1 = 1; end
	join
	repeat (20) @(posedge clk);
	$display("ddram_arb: %0d reads, %0d writes, %0d errors", reads, writes, errors);
	if (errors) $display("FAIL"); else $display("PASS");
	$finish;
end

initial begin #20000000; $display("FAIL: timeout (deadlock?)"); $finish; end

endmodule
