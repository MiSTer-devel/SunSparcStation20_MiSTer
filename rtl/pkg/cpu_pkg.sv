// SPDX-License-Identifier: GPL-2.0-or-later
//
// cpu_pkg: the types the CPU module's blocks share: the IU's two memory
// ports, the trap codes, the PSR layout and the SuperSPARC identity.
//
// From: The SPARC Architecture Manual V8: §4.2 (PSR fields), §4.3 (WIM),
//   §4.4 (TBR), Table 7-1 (trap types), §7.3 (trap priorities), §B.* for
//   the ASI use of loads/stores; docs/arch/cpu.md §1.6 for the ports.

package cpu_pkg;

  // SuperSPARC (TI TMS390Z50): PSR impl 4, ver 0 (QEMU TI-SuperSparc-60)
  localparam logic [3:0] PSR_IMPL = 4'h4;
  localparam logic [3:0] PSR_VER  = 4'h0;
  localparam int NWINDOWS = 8;

  // PSR fields (V8 §4.2)
  typedef struct packed {
    logic [3:0] impl;   // 31:28
    logic [3:0] ver;    // 27:24
    logic       n, z, v, c;   // 23:20 icc
    logic [5:0] rsvd;   // 19:14 read as 0
    logic       ec;     // 13 (no coprocessor: reads 0)
    logic       ef;     // 12
    logic [3:0] pil;    // 11:8
    logic       s;      // 7
    logic       ps;     // 6
    logic       et;     // 5
    logic [4:0] cwp;    // 4:0 (3 bits used)
  } psr_t;

  // Trap types (V8 Table 7-1)
  localparam logic [7:0] TT_RESET            = 8'h00;
  localparam logic [7:0] TT_INST_ACCESS_EXC  = 8'h01;
  localparam logic [7:0] TT_ILLEGAL_INST     = 8'h02;
  localparam logic [7:0] TT_PRIV_INST        = 8'h03;
  localparam logic [7:0] TT_FP_DISABLED      = 8'h04;
  localparam logic [7:0] TT_WINDOW_OVERFLOW  = 8'h05;
  localparam logic [7:0] TT_WINDOW_UNDERFLOW = 8'h06;
  localparam logic [7:0] TT_MEM_ADDR_NOT_ALIGNED = 8'h07;
  localparam logic [7:0] TT_FP_EXCEPTION     = 8'h08;
  localparam logic [7:0] TT_DATA_ACCESS_EXC  = 8'h09;
  localparam logic [7:0] TT_TAG_OVERFLOW     = 8'h0A;
  localparam logic [7:0] TT_WATCHPOINT       = 8'h0B;
  localparam logic [7:0] TT_INTERRUPT_BASE   = 8'h10;   // + level
  localparam logic [7:0] TT_INST_ACCESS_ERR  = 8'h21;
  localparam logic [7:0] TT_CP_DISABLED      = 8'h24;
  localparam logic [7:0] TT_UNIMPL_FLUSH     = 8'h25;
  localparam logic [7:0] TT_CP_EXCEPTION     = 8'h28;
  localparam logic [7:0] TT_DATA_ACCESS_ERR  = 8'h29;
  localparam logic [7:0] TT_DIV_BY_ZERO      = 8'h2A;
  localparam logic [7:0] TT_DATA_STORE_ERR   = 8'h2B;
  localparam logic [7:0] TT_DATA_ACCESS_MMU_MISS = 8'h2C;
  localparam logic [7:0] TT_INST_ACCESS_MMU_MISS = 8'h3C;
  localparam logic [7:0] TT_TRAP_INST_BASE   = 8'h80;   // + ticc number

  // ASIs the IU issues itself (V8 §B, Appendix I)
  localparam logic [7:0] ASI_USER_INST = 8'h08;
  localparam logic [7:0] ASI_SUPV_INST = 8'h09;
  localparam logic [7:0] ASI_USER_DATA = 8'h0A;
  localparam logic [7:0] ASI_SUPV_DATA = 8'h0B;

  // ---------------------------------------------------------------------
  // The instruction fetch port: one request per cycle, in order, answered
  // in order with the word or a fault. `valid`/`ready` on the request;
  // the response is a `valid` with the data, matched to requests in order.
  // `ready` is the IU's: it takes a response this cycle (into D or its
  // buffer); a response not taken is held and offered again. The IU
  // decides a request from registered state, so the answer of one fetch
  // and the issue of the next do not form one long path.
  // ---------------------------------------------------------------------
  typedef struct packed {
    logic        valid;
    logic [31:0] va;
    logic        supv;        // ASI 9 (supervisor) or 8 (user)
    logic        ready;       // a response offered this cycle is taken
  } ifetch_req_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] inst;
    logic [1:0]  fault;       // 0 ok, 1 access exception (tt 1), 2 access error (tt 0x21)
  } ifetch_rsp_t;

  // ---------------------------------------------------------------------
  // The data port: one access at a time; the request is held until `ack`.
  // ---------------------------------------------------------------------
  typedef struct packed {
    logic        valid;
    logic        write;
    logic        atomic;      // ldstub / swap: a locked read-modify-write
    logic [7:0]  asi;
    logic [31:0] va;
    logic [1:0]  size;        // 0 byte, 1 half, 2 word, 3 doubleword (two beats)
    logic [63:0] wdata;       // size 3: {even register, odd register}; else the value right-aligned in [31:0]
  } dmem_req_t;

  typedef struct packed {
    logic        ack;
    logic [63:0] rdata;       // size 3: {word at va, word at va+4}; else the value right-aligned in [31:0]
    logic [1:0]  fault;       // 0 ok, 1 access exception (tt 9), 2 access error (tt 0x29)
  } dmem_rsp_t;


  // ---------------------------------------------------------------------
  // The decoded instruction (iu_decode)
  // ---------------------------------------------------------------------
  typedef enum logic [4:0] {
    C_ILLEGAL, C_NOP, C_SETHI, C_BICC, C_FBFCC, C_CALL, C_ALU, C_MUL, C_DIV,
    C_RDY, C_RDPSR, C_RDWIM, C_RDTBR, C_WRY, C_WRPSR, C_WRWIM, C_WRTBR,
    C_FPOP, C_JMPL, C_RETT, C_TICC, C_FLUSH, C_SAVE, C_RESTORE,
    C_LOAD, C_STORE, C_ATOMIC, C_FPLOAD, C_FPSTORE
  } cls_t;

  typedef struct packed {
    cls_t        cls;
    logic [4:0]  rd, rs1, rs2;
    logic        imm;              // i bit: rs2 is simm13
    logic [31:0] simm13;           // sign-extended
    logic [3:0]  cond;
    logic        annul;
    logic [7:0]  asi;
    logic [5:0]  op3;
    logic [8:0]  opf;
    logic [31:0] disp30;           // call displacement, already x4
    logic [31:0] disp22;           // branch displacement, sign-extended, x4
    logic [31:0] imm22;            // sethi value
    logic        wr_rd;            // writes rd (the pipeline suppresses on traps)
    logic        cc;               // mul/div: the cc form
    logic        sgn;              // mul/div signed; loads: sign-extend
    logic [1:0]  size;             // 0 byte, 1 half, 2 word, 3 doubleword
    logic        alt;              // alternate-space load/store
    logic        swap;             // the atomic is swap (else ldstub)
    logic        fsr;              // ldfsr/stfsr
    logic        fq;               // stdfq
    logic        stbar;
    logic        priv;             // a privileged instruction
    logic        trap_illegal;     // tt 0x02
    logic        trap_priv;        // tt 0x03
    logic        trap_fp_disabled; // tt 0x04
    logic        trap_cp_disabled; // tt 0x24
  } dec_t;

endpackage
