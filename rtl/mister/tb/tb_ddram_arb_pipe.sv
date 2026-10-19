// SPDX-License-Identifier: GPL-2.0-or-later
//
// Pipelined masters (Avalon bridges): a new command may be presented
// right after the previous one is accepted, before its read data returns;
// requests may also be withdrawn before acceptance. Checks per-master data
// order against a shadow copy and that the slave never sees overlapping reads.
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
wire s_wait; wire [7:0] s_bc; wire [28:0] s_addr; wire s_rd, s_wr; wire [63:0] s_wd; wire [7:0] s_be;
reg [63:0] s_rdata; reg s_rvalid;
ddram_arb dut (.clk(clk), .reset(reset),
 .m0_waitrequest(m_wait[0]), .m0_burstcount(m_bc[0]), .m0_address(m_addr[0]), .m0_read(m_rd[0]), .m0_write(m_wr[0]), .m0_writedata(m_wd[0]), .m0_byteenable(m_be[0]), .m0_readdata(m_rdata[0]), .m0_readdatavalid(m_rvalid[0]),
 .m1_waitrequest(m_wait[1]), .m1_burstcount(m_bc[1]), .m1_address(m_addr[1]), .m1_read(m_rd[1]), .m1_write(m_wr[1]), .m1_writedata(m_wd[1]), .m1_byteenable(m_be[1]), .m1_readdata(m_rdata[1]), .m1_readdatavalid(m_rvalid[1]),
 .s_waitrequest(s_wait), .s_burstcount(s_bc), .s_address(s_addr), .s_read(s_rd), .s_write(s_wr), .s_writedata(s_wd), .s_byteenable(s_be), .s_readdata(s_rdata), .s_readdatavalid(s_rvalid));
// slave: pipelined, accepts reads while earlier ones are pending (queue)
reg [63:0] mem [0:4095]; reg wait_r = 1; assign s_wait = wait_r;
integer wbeat=0, wlen=0, i; reg [28:0] waddr;
reg [63:0] qd[$]; integer ql[$]; integer rnext=0, rdelay=0, pend=0, overlap=0;
initial for (i=0;i<4096;i=i+1) mem[i] = {32'hdead0000|i, 32'hbeef0000|i};
always @(posedge clk) begin
  wait_r <= ($random & 3) == 0; s_rvalid <= 0;
  if (!s_wait && s_wr) begin
    if (wbeat==0) begin waddr = s_addr; wlen = s_bc; end
    for (i=0;i<8;i=i+1) if (s_be[i]) mem[(waddr+wbeat)&4095][i*8+:8] = s_wd[i*8+:8];
    wbeat = wbeat+1; if (wbeat==wlen) wbeat=0;
  end
  // in order: a read returns what memory held when it was accepted
  if (!s_wait && s_rd) begin if (pend) overlap = overlap+1; for (i=0;i<s_bc;i=i+1) qd.push_back(mem[(s_addr+i)&4095]); ql.push_back(s_bc); pend = pend+1; if (pend==1) rdelay = 3+($random&7); end
  if (ql.size()) begin
    if (rdelay>0) rdelay=rdelay-1;
    else if ($random & 1) begin s_rdata <= qd[0]; void'(qd.pop_front()); s_rvalid <= 1; rnext=rnext+1;
      if (rnext==ql[0]) begin void'(ql.pop_front()); rnext=0; pend=pend-1; rdelay = 2; end end
  end
end
reg [63:0] shadow [0:4095]; initial for (i=0;i<4096;i=i+1) shadow[i] = {32'hdead0000|i, 32'hbeef0000|i};
integer errors=0, reads=0, writes=0, withdrawn=0;
// expected read data per master, pushed at command acceptance
reg [63:0] exp0[$], exp1[$];
always @(posedge clk) begin
  if (m_rvalid[0]) begin if (exp0.size()==0 || m_rdata[0] !== exp0[0]) begin errors=errors+1; if (errors<10) $display("FAIL m0 data %h", m_rdata[0]); end if (exp0.size()) void'(exp0.pop_front()); end
  if (m_rvalid[1]) begin if (exp1.size()==0 || m_rdata[1] !== exp1[0]) begin errors=errors+1; if (errors<10) $display("FAIL m1 data %h", m_rdata[1]); end if (exp1.size()) void'(exp1.pop_front()); end
  if (m_rvalid[0] && m_rvalid[1]) begin errors=errors+1; $display("FAIL both rvalid"); end
end
task automatic master(input integer m, input integer n);
  integer t, len, b; reg [28:0] a; reg [63:0] d;
  begin
    for (t=0;t<n;t=t+1) begin
      len = 1 + ($unsigned($random)%4); a = m*2048 + ($unsigned($random)%2000);
      if (($random & 7)==0) begin // present a read, then withdraw it before acceptance (full FIFO style)
        m_rd[m] <= 1; m_addr[m] <= a; m_bc[m] <= len; @(posedge clk);
        if (m_wait[m]) begin m_rd[m] <= 0; withdrawn=withdrawn+1; @(posedge clk); end
        else begin for (b=0;b<len;b=b+1) if (m) exp1.push_back(shadow[(a+b)&4095]); else exp0.push_back(shadow[(a+b)&4095]); m_rd[m] <= 0; reads=reads+1; end
      end else if ($random & 1) begin
        for (b=0;b<len;b=b+1) begin d={$random,$random}; m_wr[m]<=1; m_wd[m]<=d; m_be[m]<=8'hff; if (b==0) begin m_addr[m]<=a; m_bc[m]<=len; end
          @(posedge clk); while (m_wait[m]) @(posedge clk); shadow[(a+b)&4095]=d; end
        m_wr[m] <= 0; writes=writes+1;
      end else begin // pipelined read: do not wait for data
        m_rd[m] <= 1; m_addr[m] <= a; m_bc[m] <= len; @(posedge clk); while (m_wait[m]) @(posedge clk);
        for (b=0;b<len;b=b+1) if (m) exp1.push_back(shadow[(a+b)&4095]); else exp0.push_back(shadow[(a+b)&4095]);
        m_rd[m] <= 0; reads=reads+1;
      end
    end
  end
endtask
initial begin
  m_rd[0]=0; m_wr[0]=0; m_rd[1]=0; m_wr[1]=0; m_bc[0]=1; m_bc[1]=1; m_addr[0]=0; m_addr[1]=0;
  repeat(4) @(posedge clk); reset<=0;
  fork begin master(0,4000); end begin master(1,4000); end join
  repeat(200) @(posedge clk);
  $display("pipe: %0d reads %0d writes %0d withdrawn, %0d errors, %0d slave overlaps, pending exp %0d/%0d", reads, writes, withdrawn, errors, overlap, exp0.size(), exp1.size());
  $finish;
end
initial begin #40000000; $display("FAIL timeout"); $finish; end
endmodule
